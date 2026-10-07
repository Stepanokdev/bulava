import ActivityKit
import Foundation
import OSLog
import Shared
import UIKit

/// The iPhone's Live Activity: what the Mac is working on, on the Lock Screen.
///
/// Two ways in. With the app open, what runs arrives over the local link and the activity is
/// started, updated and ended here. With it closed, the Mac does the same through the push relay
/// with the tokens this hands it — the one iOS gives for starting an activity by push, and the one
/// of the activity that is running. Either way it starts when a stretch of work begins, names what
/// runs and for how long, and ends on how it went once the stretch is over. What waits for the
/// director is left to its own notification: the Lock Screen is for the work.
final class LiveShift {
    static let shared = LiveShift()
    private let log = Logger(subsystem: "com.stepanok.bulava", category: "live-activity")

    /// How long a count is trusted without a fresh one. The Mac re-sends every ten minutes; past
    /// this the activity shows that the Mac has gone quiet.
    static let staleAfter: TimeInterval = 25 * 60
    /// How long a finished activity stays, showing what is ready to read.
    static let lingers: TimeInterval = 60 * 60

    private var watched: Set<String> = []
    /// Each activity's own update token, and the one the Mac was last handed: an older activity
    /// ending must not take the newer one's token away from the Mac.
    private var tokens: [String: Data] = [:]
    private var handedUpdate: Data?
    private var lastLocal: (state: ShiftAttributes.ContentState, at: Date)?
    private var active = false

    /// Swiped away while work was going on: not started again from here until that work is over.
    private var dismissedDuringWork: Bool {
        get { UserDefaults.standard.bool(forKey: "bulava.activity.dismissed") }
        set { UserDefaults.standard.set(newValue, forKey: "bulava.activity.dismissed") }
    }

    /// Starts listening for the tokens iOS hands out. Called once, at launch — including a launch in
    /// the background because a push just started an activity.
    func start() {
        Task {
            for await token in ActivityKit.Activity<ShiftAttributes>.pushToStartTokenUpdates {
                hand(kind: "start", token: token)
            }
        }
        Task {
            for await activity in ActivityKit.Activity<ShiftAttributes>.activityUpdates {
                // A new one — most likely started by a push while the app was closed — replaces
                // whatever was left: the Mac starts one only when it knows of none.
                for other in ActivityKit.Activity<ShiftAttributes>.activities where other.id != activity.id {
                    await other.end(nil, dismissalPolicy: .immediate)
                }
                await watch(activity)
            }
        }
        Task {
            for activity in ActivityKit.Activity<ShiftAttributes>.activities { await watch(activity) }
        }
    }

    @MainActor
    private func watch(_ activity: ActivityKit.Activity<ShiftAttributes>) {
        guard watched.insert(activity.id).inserted else { return }
        Task { @MainActor in
            for await token in activity.pushTokenUpdates {
                tokens[activity.id] = token
                handedUpdate = token
                hand(kind: "update", token: token)
            }
        }
        Task { @MainActor in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                if state == .dismissed, active { dismissedDuringWork = true }
                // Its token is spent; the Mac forgets it and waits for the next activity's — unless
                // a newer activity's token is the one the Mac holds now.
                if let token = tokens.removeValue(forKey: activity.id), token == handedUpdate {
                    handedUpdate = nil
                    hand(kind: "update", token: nil)
                }
                watched.remove(activity.id)
                break
            }
        }
    }

    // MARK: From the app

    /// What the Mac just sent over the link, with the app open: the counts, and `live` — the Mac's
    /// `HomeDTO.live`, the work by name — from a Mac that sends it.
    @MainActor
    func show(working: Int, waiting: Int, ready: Int, live: Live?) {
        let box = live.map(LiveBox.init)
        let state = ShiftAttributes.ContentState(working: working, waiting: waiting, ready: ready, box: box)
        // A Mac that names the work says when its stretch is over; an older one is judged by the counts.
        let over = live?.over ?? (working == 0 && waiting == 0)
        active = !over
        if over { dismissedDuringWork = false }
        let running = ActivityKit.Activity<ShiftAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }

        if over {
            lastLocal = nil
            for activity in running {
                Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + Self.lingers)) }
            }
            return
        }
        if let current = running.first {
            // One at a time: anything older left over from a restart goes.
            for extra in running.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
            // Unchanged, it is re-sent only to keep the activity from going stale.
            if let last = lastLocal, last.state == state, Date().timeIntervalSince(last.at) < Self.staleAfter / 3 { return }
            lastLocal = (state, Date())
            Task { await current.update(ActivityContent(state: state, staleDate: .now + Self.staleAfter)) }
            return
        }
        guard !dismissedDuringWork, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Nothing to show until something actually runs: a stretch that is only being settled has no line yet.
        guard working > 0 || !(live?.running.isEmpty ?? true) else { return }
        do {
            _ = try ActivityKit.Activity<ShiftAttributes>.request(attributes: ShiftAttributes(),
                                     content: ActivityContent(state: state, staleDate: .now + Self.staleAfter),
                                     pushType: .token)
            lastLocal = (state, Date())
        } catch {
            log.error("could not start the Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The Mac's `LiveDTO`, as the link carries it.
    struct Live: Decodable {
        struct Line: Decodable {
            var productID: String
            var chatID: String?
            var title: String
            var product: String
            var sinceMs: Int64?
            var outcome: String?
        }
        var running: [Line]
        var ended: [Line]
        var over: Bool
    }

    // MARK: To the Mac

    /// Hands a token to the shared code, which gives it to the Mac over the link. In the background
    /// — a push just started the activity — the app connects long enough to deliver it.
    private func hand(kind: String, token: Data?) {
        let hex = token.map { $0.map { String(format: "%02x", $0) }.joined() } ?? ""
        DispatchQueue.main.async {
            MainViewControllerKt.setActivityToken(kind: kind, token: hex, environment: BulavaHost.apnsEnvironment)
            if UIApplication.shared.applicationState != .active { self.deliverInBackground() }
        }
    }

    private func deliverInBackground() {
        var task = UIBackgroundTaskIdentifier.invalid
        let finish = {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "bulava.activity", expirationHandler: finish)
        MainViewControllerKt.backgroundCheck(host: BulavaHost.shared) { _ in finish() }
    }
}

extension LiveBox {
    /// The app's own box from what the link said — the same trimming the Mac gives what it seals.
    init(_ live: LiveShift.Live) {
        func line(_ l: LiveShift.Live.Line) -> Line {
            Line(title: String(l.title.prefix(60)), product: String(l.product.prefix(40)), sinceMs: l.sinceMs, outcome: l.outcome)
        }
        let first = live.running.first ?? live.ended.first
        self.init(running: live.running.prefix(3).map(line), count: live.running.count,
                  ended: live.ended.prefix(3).map(line), over: live.over,
                  productID: first?.productID, chatID: first?.chatID)
    }
}
