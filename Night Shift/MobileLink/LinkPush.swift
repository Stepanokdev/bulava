import Foundation
import OSLog

/// Reaching an iPhone whose app is not running, through the push relay (`bulava-mobile/push-relay`).
///
/// Only an iPhone needs this: Android keeps its connection in a foreground service. And only
/// fixed sentences, counts and sealed boxes travel — the relay is sent a device token, which of its
/// sentences to show ("Bulava needs you", "a report is ready", "the work is done"), and for a Live
/// Activity three numbers plus the names sealed with the phone's own key (`LiveSeal`), which the
/// relay cannot open. What is waiting, and where, is read over the local link when the phone opens.
///
/// Bulava's relay is the default. `BulavaPushRelayURL` in the app's defaults (or the
/// `BULAVA_PUSH_RELAY` environment variable) points somewhere else, and `off` turns it off.
extension MobileLink {

    static let relayDefaultsKey = "BulavaPushRelayURL"
    static let defaultRelay = URL(string: "https://bulava-push.stepanok.com")!

    /// Every push a phone may say it has words for. "done" is a chat whose answer is in.
    nonisolated static let pushKinds = ["attention", "finished", "done"]

    /// How often a running Live Activity is re-sent while nothing changes, so its "as of" stays
    /// fresh. The relay marks it stale after 25 minutes without one — a Mac that went to sleep.
    static let activityHeartbeatInterval: Duration = .seconds(10 * 60)

    /// Where the relay is, if this Mac has one.
    var pushRelay: URL? {
        if let override = relayOverride { return override }
        let raw = ProcessInfo.processInfo.environment["BULAVA_PUSH_RELAY"]
            ?? UserDefaults.standard.string(forKey: Self.relayDefaultsKey)
        guard let raw else {
            // A test host never reaches the real relay unless a test points it somewhere.
            return Self.isTestHost ? nil : Self.defaultRelay
        }
        guard let url = URL(string: raw), url.scheme == "https" || url.host == "127.0.0.1" else { return nil }
        return url
    }

    var pushReady: Bool { pushRelay != nil }

    /// What the relay takes. Until it has said — or when it is older than the question — only
    /// what every relay takes goes to it: the first two kinds, and counts without names.
    var relayTakes: RelayFeatures { relayFeatures ?? .legacy }

    /// Asks the relay what it takes, at most once an hour. A relay that does not know the question
    /// (404) is an older one; one that cannot be reached is asked again next time.
    func checkRelayFeatures() {
        guard let relay = pushRelay, !relayFeaturesInFlight else { return }
        if let at = relayFeaturesCheckedAt, Date().timeIntervalSince(at) < 3600 { return }
        relayFeaturesInFlight = true
        let url = relay.appendingPathComponent("v1/features")
        Task { [weak self] in
            guard let self else { return }
            let request = URLRequest(url: url, timeoutInterval: 15)
            let answer = try? await self.pushSession.data(for: request)
            self.relayFeaturesInFlight = false
            let status = (answer?.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data = answer?.0, let features = try? JSONDecoder().decode(RelayFeatures.self, from: data) {
                self.relayFeatures = features
                self.relayFeaturesCheckedAt = Date()
            } else if status == 404 {
                self.relayFeatures = .legacy
                self.relayFeaturesCheckedAt = Date()
            } else {
                return
            }
            // What the Live Activities may carry has just been learned: they are brought in line.
            for device in self.devices.devices { self.steerActivity(device.id) }
        }
    }

    /// Starts watching the work, once there is a phone to reach and a relay to reach it through.
    /// Idempotent.
    func startPushWatch() {
        guard pushWatching == false, model != nil, pushRelay != nil,
              devices.devices.contains(where: { $0.pushToken != nil || $0.activityStartToken != nil || $0.activityToken != nil })
        else { return }
        pushWatching = true
        checkRelayFeatures()
        watchHome()
        activityHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.activityHeartbeatInterval)
                self?.checkRelayFeatures()
                self?.refreshActivities()
            }
        }
    }

    /// Reads the app inside the observation, and acts on the reading outside it: what the pushes
    /// themselves change — a token spent, a device's activity — must not count as a change in the
    /// work and send the reading round again.
    private func watchHome() {
        guard pushWatching, let model else { return }
        let reading = withObservationTracking {
            readForPush(model)
        } onChange: { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self?.watchHome()
            }
        }
        act(on: reading)
    }

    /// One reading of the app for the phones that are not listening. Registers nothing, so the
    /// settle check can take one without adding a second watch.
    func pushReading() {
        guard pushWatching, let model else { return }
        act(on: readForPush(model))
    }

    private func readForPush(_ model: AppModel) -> (home: HomeDTO, live: LiveDTO, stopped: [LiveLineDTO]) {
        let (live, stopped) = liveReading(model)
        let home = LinkProjection.build(model, desktop: desktop, openChats: [], live: live).home
        return (home, live, stopped)
    }

    private func act(on reading: (home: HomeDTO, live: LiveDTO, stopped: [LiveLineDTO])) {
        liveStopped(reading.stopped)
        attentionChanged(reading.home.attention)
        finishedChanged(Set(reading.home.finished.map(\.id)))
        summaryChanged(reading.home.summary, live: reading.live)
    }

    // MARK: The Mac's own notices

    /// The phones' reading of what waits for the director, for the Mac itself (`DesktopNotices`).
    /// Apart from the push watch, which starts only once a phone is paired, and from the live
    /// tracker, which only the phones' reading moves on.
    func startDesktopWatch() {
        guard !desktopWatching, model != nil else { return }
        desktopWatching = true
        watchDesktop()
    }

    private func watchDesktop() {
        guard desktopWatching, let model else { return }
        let attention = withObservationTracking {
            LinkProjection.build(model, desktop: desktop, openChats: []).home.attention
        } onChange: { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self?.watchDesktop()
            }
        }
        desktopNotices.changed(attention)
    }

    // MARK: The stretch of work, by name

    /// Moves `live` on by one reading of the app: what it now tells, and what counts as stopped
    /// as of this reading — each of those is returned once, for `liveStopped`.
    func liveReading(_ model: AppModel, now: Date = Date()) -> (live: LiveDTO, stopped: [LiveLineDTO]) {
        let lines = LinkProjection.runningLines(model)
        let working = model.instances.filter { PowerKeeper.keepsAwake($0) }.count + model.codexTurns.count
        let stopped = live.observe(lines, working: working, now: now) { LinkProjection.outcome(of: $0, model: model) }
        // Nothing may change in the app while a line waits out its settle, and nothing would then
        // look again: this does.
        if live.settling { scheduleLiveCheck() }
        return (live.detail, stopped)
    }

    /// A chat whose answer is in wakes the phones that can say so.
    func liveStopped(_ stopped: [LiveLineDTO]) {
        for line in stopped where line.outcome == "done" && line.id.hasPrefix("chat:") {
            wakeAll(kind: "done", route: LiveSeal.Route(productID: line.productID, chatID: line.chatID))
        }
    }

    private func scheduleLiveCheck() {
        guard liveCheck == nil else { return }
        liveCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds((self?.live.settle ?? 20) + 0.5))
            guard !Task.isCancelled else { return }
            self?.liveCheck = nil
            self?.refresh()
            self?.pushReading()
        }
    }

    /// Whether this phone has the app on screen and hears everything over the link already.
    private func listening(_ device: PairedDevice) -> Bool {
        sessions.contains { $0.deviceID == device.id && $0.foreground }
    }

    // MARK: Notifications

    /// Anything new waiting for the director wakes every iPhone that is not listening right now,
    /// and a tap opens the chat of the newest of it.
    ///
    /// What was waiting is kept on disk (`attention-seen.json`), so "new" survives a restart: a
    /// question that came while Bulava was quit, crashed or rebuilt in the night used to be taken
    /// for the starting line and never pushed. Only with no record at all — a Mac that never
    /// pushed — is the first reading the starting line.
    func attentionChanged(_ items: [AttentionDTO]) {
        let ids = Set(items.map(\.id))
        let seen = seenAttention ?? loadSeenAttention()
        if ids != seen { saveSeenAttention(ids) }
        seenAttention = ids
        guard let seen else { return }
        let new = items.filter { !seen.contains($0.id) }
        guard let newest = new.max(by: { $0.atMs < $1.atMs }) else { return }
        // Without a chat there is nowhere particular to go; the phone opens the newest of its kind.
        let route = newest.chatID.map { LiveSeal.Route(productID: newest.productID, chatID: $0) }
        wakeAll(kind: nil, route: route)
    }

    private func loadSeenAttention() -> Set<String>? {
        guard let data = try? Data(contentsOf: attentionSeenFile),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(ids)
    }

    private func saveSeenAttention(_ ids: Set<String>) {
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        try? FileManager.default.createDirectory(at: attentionSeenFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: attentionSeenFile, options: .atomic)
    }

    /// A report that came in is told the same way, with its own sentence.
    func finishedChanged(_ ids: Set<String>) {
        defer { seenFinished = ids }
        guard let seen = seenFinished, !ids.subtracting(seen).isEmpty else { return }
        wakeAll(kind: "finished")
    }

    /// `route`, sealed for each phone that has a key, lets a tap open the chat it is about; the
    /// relay passes it on unread. A kind the phone has no words for is not sent to it.
    private func wakeAll(kind: String?, route: LiveSeal.Route? = nil) {
        guard let relay = pushRelay else { return }
        for device in devices.devices where !listening(device) {
            guard let token = device.pushToken else { continue }
            if let kind, !relayTakes.kinds.contains(kind) { continue }
            if kind == "done", device.pushKinds?.contains("done") != true { continue }
            let environment = device.pushEnvironment ?? "production"
            let sealed = relayTakes.sealed
                ? route.flatMap { r in LiveSeal.key(device.sealKey).flatMap { LiveSeal.seal(r, key: $0) } } : nil
            // Already held back for the relay's gap: that push goes later, now leading here.
            let held = Self.wakeKey(token, kind)
            if pendingWakes[held] != nil { pendingWakes[held]?.sealed = sealed; continue }
            Task { await self.wake(token: token, environment: environment, kind: kind, sealed: sealed, relay: relay) }
        }
    }

    private func wake(token: String, environment: String, kind: String?, sealed: String?, relay: URL,
                      attempt: Int = 0) async {
        var body: [String: Any] = ["token": token, "environment": environment]
        if let kind { body["kind"] = kind }
        if let sealed { body["sealed"] = sealed }
        let status = await post(body, to: relay.appendingPathComponent("v1/notify"))
        if status == 410 {
            // The phone no longer has the app, or the token is for the other APNs: forget it,
            // and the phone registers a fresh one next time it connects.
            devices.forgetPushToken(token)
        }
        if status == 429, attempt < 3 {
            wakeLater(token: token, environment: environment, kind: kind, sealed: sealed, relay: relay, attempt: attempt + 1)
        }
        pushesSent += status == 202 ? 1 : 0
    }

    /// One push held back for a phone, until the relay's gap is over.
    struct PendingWake { var sealed: String? }

    static func wakeKey(_ token: String, _ kind: String?) -> String { token + "|" + (kind ?? "attention") }

    /// The relay wakes one phone at most once every 30 s with the same sentence and answers 429
    /// to the rest. A second question inside that gap was dropped — and already counted as seen,
    /// so nothing ever pushed it. It now goes once the gap is over: one push for whatever came in
    /// meanwhile, leading to the newest of it, and only if something still waits by then. A relay
    /// that keeps refusing is tried three times.
    private func wakeLater(token: String, environment: String, kind: String?, sealed: String?, relay: URL, attempt: Int) {
        let key = Self.wakeKey(token, kind)
        if pendingWakes[key] != nil { pendingWakes[key]?.sealed = sealed; return }
        pendingWakes[key] = PendingWake(sealed: sealed)
        Task { [weak self] in
            try? await Task.sleep(for: self?.wakeRetryAfter ?? .seconds(31))
            guard let self, let pending = self.pendingWakes.removeValue(forKey: key) else { return }
            let still = kind != nil || !(self.seenAttention ?? []).isEmpty
            guard still, self.devices.devices.contains(where: { $0.pushToken == token }) else { return }
            await self.wake(token: token, environment: environment, kind: kind, sealed: pending.sealed,
                            relay: relay, attempt: attempt)
        }
    }

    // MARK: Live Activity

    /// Keeps each iPhone's Live Activity in step with the work: started by a push when a stretch
    /// begins and the app is closed, updated as what runs changes, ended on the last of it once the
    /// stretch is over. What waits for the director is not the Lock Screen's business — its own
    /// push says so. A phone with the app on screen runs its activity itself.
    func summaryChanged(_ summary: SummaryDTO, live: LiveDTO) {
        lastSummary = summary
        lastLive = live
        // A stretch of work is over: the next one may start an activity again, even on a phone
        // whose director swiped this one away.
        if live.over { activityStartedAt = [:] }
        for device in devices.devices { steerActivity(device.id) }
    }

    /// The ten-minute beat. Every running activity is sent its counts again, whether or not they
    /// changed, and whatever the relay refused or was given up on is tried once more — a start
    /// included, for a phone that has none yet. A start the relay already took is not repeated.
    func refreshActivities() {
        activityHeld = [:]
        for device in devices.devices {
            if device.activityToken != nil { activitySent[device.id] = nil }
            steerActivity(device.id)
        }
    }

    /// What this phone's activity should be sent now, if anything. Nothing here changes until the
    /// relay has accepted it: a start, an update or an end that did not get through is still due.
    private func activityDue(_ id: String) -> ActivityPush? {
        guard let summary = lastSummary, let live = lastLive,
              let device = devices.devices.first(where: { $0.id == id }), !listening(device) else { return nil }
        let environment = device.pushEnvironment ?? "production"
        // The names go only to a phone that can open them; the comparison is by what they say,
        // never by the sealed string, which is new every time.
        let key = relayTakes.sealed && LiveSeal.key(device.sealKey) != nil ? device.sealKey : nil
        let box = key == nil ? nil : LiveSeal.box(live)
        if let token = device.activityToken {
            if live.over {
                return ActivityPush(event: "end", token: token, environment: environment, state: summary, box: box, key: key)
            }
            if let sent = activitySent[id], sent.state == summary, sent.box == box { return nil }
            return ActivityPush(event: "update", token: token, environment: environment, state: summary, box: box, key: key)
        }
        // No activity on the phone. One is started while work goes on — when it begins, or when
        // this Mac finds it already going — and not again in this stretch once one was accepted:
        // an activity the director swiped away stays away until the next piece of work.
        guard let start = device.activityStartToken, !live.over, activityStartedAt[id] == nil else { return nil }
        return ActivityPush(event: "start", token: start, environment: environment, state: summary, box: box, key: key)
    }

    func steerActivity(_ id: String) {
        guard let relay = pushRelay, !activityInFlight.contains(id), activityRetry[id] == nil else { return }
        guard let push = activityDue(id) else {
            activityFailures[id] = nil
            activityHeld[id] = nil
            return
        }
        // The very push the relay refused, or that was given up on, waits for new counts or the
        // beat rather than going round again at every change of anything else.
        if activityHeld[id] == push { return }
        // Updates keep their gap; whatever the counts are when it is over is what goes.
        if push.event == "update", let last = activityLastAttempt[id], last.duration(to: .now) < activityGap {
            retryActivity(id, after: activityGap - last.duration(to: .now))
            return
        }
        activityInFlight.insert(id)
        activityLastAttempt[id] = .now
        Task { await self.deliverActivity(push, to: id, relay: relay) }
    }

    private func deliverActivity(_ push: ActivityPush, to id: String, relay: URL) async {
        let status = await sendActivity(push, relay: relay)
        activityInFlight.remove(id)
        let log = Logger(subsystem: "com.stepanok.bulava", category: "mobile-link")
        switch status {
        case 202:
            // Only this marks it delivered.
            activityFailures[id] = nil
            activityHeld[id] = nil
            activityPushesSent += 1
            accepted(push, for: id)
        case 410:
            // Definitive: Apple no longer knows this token. It is forgotten, and with it whatever
            // was due for it.
            activityFailures[id] = nil
            activityHeld[id] = nil
            devices.forgetActivityToken(push.token)
            if push.event == "end" { activitySent[id] = nil }
        case 0, 408, 429, 500...:
            // The relay or Apple could not take it now. Tried again, sooner rather than later,
            // then less often; after that the next change or the ten-minute beat tries again.
            let failures = (activityFailures[id] ?? 0) + 1
            if failures > maxActivityRetries {
                activityFailures[id] = nil
                activityHeld[id] = push
                log.error("Live Activity \(push.event, privacy: .public) given up after \(failures - 1) retries")
                return
            }
            activityFailures[id] = failures
            retryActivity(id, after: activityBackoff(failures))
            return
        default:
            // Refused. Nothing about the phone's activity changes — its token stays, a start is
            // still due — but the same push is not sent again until the counts move or the beat
            // comes: it would be refused the same way.
            activityFailures[id] = nil
            activityHeld[id] = push
            log.error("Live Activity \(push.event, privacy: .public) refused by the relay: \(status)")
            return
        }
        steerActivity(id)
    }

    /// The relay took it: only now does the Mac's picture of the phone's activity move.
    private func accepted(_ push: ActivityPush, for id: String) {
        switch push.event {
        case "start":
            activityStartedAt[id] = Date()
            activitySent[id] = SentActivity(state: push.state, box: push.box, at: .now)
        case "end":
            // Its token is spent with it; the phone's next activity brings a new one.
            if devices.devices.first(where: { $0.id == id })?.activityToken == push.token {
                devices.setActivityToken(nil, start: false, for: id)
            }
            activitySent[id] = nil
            activityStartedAt[id] = nil
        default:
            activitySent[id] = SentActivity(state: push.state, box: push.box, at: .now)
        }
    }

    /// The wait before the `failures`-th retry: doubling from `activityRetryBase`, never past
    /// `activityRetryCap`.
    func activityBackoff(_ failures: Int) -> Duration {
        let doubled = activityRetryBase * (1 << min(max(failures - 1, 0), 16))
        return min(doubled, activityRetryCap)
    }

    private func retryActivity(_ id: String, after wait: Duration) {
        activityRetry[id]?.cancel()
        activityRetry[id] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.activityRetry[id] = nil
            self?.steerActivity(id)
        }
    }

    private func sendActivity(_ push: ActivityPush, relay: URL) async -> Int {
        var state: [String: Any] = ["working": push.state.working, "waiting": push.state.waiting, "ready": push.state.ready]
        if let box = push.box, let key = LiveSeal.key(push.key), let sealed = LiveSeal.seal(box, key: key) {
            state["sealed"] = sealed
        }
        let body: [String: Any] = [
            "token": push.token, "environment": push.environment, "event": push.event, "state": state,
        ]
        return await post(body, to: relay.appendingPathComponent("v1/activity"))
    }

    // MARK: Sending

    /// POSTs `body` to the relay and returns its status, 0 when it could not be reached.
    private func post(_ body: [String: Any], to url: URL) async -> Int {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let log = Logger(subsystem: "com.stepanok.bulava", category: "mobile-link")
        do {
            let (_, response) = try await pushSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 202 && status != 410 && status != 429 {
                log.error("push relay answered \(status) for \(url.lastPathComponent, privacy: .public)")
            }
            return status
        } catch {
            log.error("push relay unreachable: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}

/// What an iPhone's Live Activity was last sent, and when the relay took it.
nonisolated struct SentActivity: Equatable, Sendable {
    var state: SummaryDTO
    var box: LiveSeal.Box? = nil
    var at: ContinuousClock.Instant
}

/// One Live Activity push, as it goes to the relay: the counts, and for a phone with a key what
/// the names say (`box`), sealed with `key` only as it is sent.
nonisolated struct ActivityPush: Equatable, Sendable {
    var event: String
    var token: String
    var environment: String
    var state: SummaryDTO
    var box: LiveSeal.Box? = nil
    var key: String? = nil
}

/// What a relay takes beyond its first version (`GET /v1/features`).
nonisolated struct RelayFeatures: Codable, Equatable, Sendable {
    var kinds: [String]
    var sealed: Bool

    /// Every relay: "Bulava needs you", "a report is ready", and counts.
    static let legacy = RelayFeatures(kinds: ["attention", "finished"], sealed: false)
    static let current = RelayFeatures(kinds: MobileLink.pushKinds, sealed: true)
}
