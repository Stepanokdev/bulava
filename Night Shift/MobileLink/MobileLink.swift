import Foundation
import Network
import OSLog
import SystemConfiguration

/// Bulava on the phone, as seen from the Mac: which phones are paired, which are here right now,
/// and everything they are allowed to ask for.
///
/// The phone runs nothing. Every button it shows was sent from here with an id, every press comes
/// back as that id, and the handler behind it is the same `AppModel` function the Mac's own button
/// calls. There is one brain, on the Mac; the phone is a window onto it that happens to be in
/// another room.
@MainActor
@Observable
final class MobileLink {

    // MARK: What the toolbar shows

    enum Status: Equatable {
        /// Nothing paired and nothing being paired: the link is not even listening.
        case noPhone
        /// Paired, and no paired phone is connected right now.
        case offline
        case connected([String])
        /// The link should be listening and is not — a port, a firewall, a certificate.
        case unavailable(String)
    }

    var status: Status {
        if case .failed(let why) = serverState { return .unavailable(why) }
        let here = sessions.compactMap { s in s.deviceID.flatMap { id in devices.devices.first { $0.id == id }?.name } }
        if !here.isEmpty { return .connected(here) }
        if devices.devices.isEmpty { return .noPhone }
        return .offline
    }

    let devices: LinkDevices
    private(set) var serverState: LinkServer.State = .stopped
    private(set) var sessions: [LinkSession] = []

    /// The code on screen while the pairing panel is open.
    private(set) var pairingPayload: PairingPayload?

    nonisolated struct PairingPayload: Equatable, Sendable {
        var url: String
        var expiresAt: Date
        var hosts: [String]
        var port: UInt16
    }

    func isConnected(_ deviceID: String) -> Bool { sessions.contains { $0.deviceID == deviceID } }

    // MARK: Parts

    private let root: URL
    private var identity: LinkIdentity?
    private let server = LinkServer()
    weak var model: AppModel?
    private let log = Logger(subsystem: "com.stepanok.bulava", category: "mobile-link")

    /// Files that arrived from a phone and have not been sent in a message yet, by attachment id.
    private var arrived: [UUID: Attachment] = [:]
    private var failedHandshakes: [String: [Date]] = [:]
    private var refreshScheduled = false
    private var ticker: Task<Void, Never>?
    private var pairingExpiry: Task<Void, Never>?
    private var everPaired: Bool { !devices.devices.isEmpty || pairedThisRun }
    private var pairedThisRun = false

    // The push relay (LinkPush.swift).
    var pushWatching = false
    /// The Mac's own notices of what waits for the director (`DesktopNotices`), read like the phones'.
    let desktopNotices = DesktopNotices()
    var desktopWatching = false
    var seenAttention: Set<String>?
    /// A wake-up the relay refused as too soon after the last one, by phone and sentence, and how
    /// long to hold it. Tests shorten the wait.
    var pendingWakes: [String: PendingWake] = [:]
    var wakeRetryAfter: Duration = .seconds(31)
    var seenFinished: Set<String>?
    /// The stretch of work by name (`LinkLive.swift`), the look it takes again once a line has
    /// waited out its settle, and what the Live Activities were last given of it.
    var live = LiveTracker()
    var liveCheck: Task<Void, Never>?
    var lastLive: LiveDTO?
    /// The counts as last read, and what each iPhone's Live Activity was last sent.
    var lastSummary: SummaryDTO?
    var activitySent: [String: SentActivity] = [:]
    /// When the relay took a start for each iPhone, so an activity the director swiped away is not
    /// started again until the next stretch of work.
    var activityStartedAt: [String: Date] = [:]
    /// A push on the wire, a wait before the next one, consecutive transient failures, and when the
    /// last one went — per phone.
    var activityInFlight: Set<String> = []
    var activityRetry: [String: Task<Void, Never>] = [:]
    var activityFailures: [String: Int] = [:]
    /// A push the relay refused, or that was given up on after its retries: not sent again until
    /// the counts change or the ten-minute beat.
    var activityHeld: [String: ActivityPush] = [:]
    var activityLastAttempt: [String: ContinuousClock.Instant] = [:]
    /// The shortest gap between two Live Activity updates to one phone; changes in between are
    /// folded into the next one. Apple budgets these pushes. Tests shorten it.
    var activityGap: Duration = .seconds(6)
    /// How a push the relay could not take is tried again: after 2 s, then twice as long each time
    /// up to a minute, eight times. Tests shorten these.
    var activityRetryBase: Duration = .seconds(2)
    var activityRetryCap: Duration = .seconds(60)
    var maxActivityRetries = 8
    var activityHeartbeat: Task<Void, Never>?
    /// A relay address set by a test, in place of the defaults.
    var relayOverride: URL?
    /// What the relay said it takes, and when (`checkRelayFeatures`).
    var relayFeatures: RelayFeatures?
    var relayFeaturesCheckedAt: Date?
    var relayFeaturesInFlight = false
    var pushSession = URLSession(configuration: .ephemeral)
    /// How many wake-ups, and how many Live Activity pushes, the relay accepted.
    var pushesSent = 0
    var activityPushesSent = 0

    /// Port the listener asks for. Tests pass 0 for any free one.
    var preferredPort: UInt16 = LinkProtocol.defaultPort

    // The newest phone app (`LinkReleases.swift`): as last read from bulava.app, when, and where a
    // test points the reading instead.
    var phoneApps: PhoneAppsDTO?
    var phoneAppsCheckedAt: Date?
    var phoneAppsInFlight = false
    var phoneAppsSource: URL?
    var phoneAppsFile: URL { root.appendingPathComponent("phone-apps.json") }
    /// What waited for the director at the last reading, so a restart knows what is new (LinkPush).
    var attentionSeenFile: URL { root.appendingPathComponent("attention-seen.json") }

    /// Recordings from a phone, heard by Whisper (`LinkTranscription.swift`). Tests hand in their
    /// own ears.
    let transcriptions = LinkTranscriptions()
    var transcriber: LinkTranscriptions.Engine = LinkTranscriptions.whisper

    init(root: URL = AppSupport.file("mobile-link")) {
        self.root = root
        devices = LinkDevices(url: root.appendingPathComponent("devices.json"))
        server.onState = { [weak self] state in
            self?.serverState = state
            self?.refreshPairingIfPortMoved()
        }
        server.onConnection = { [weak self] connection, peer in self?.connected(connection, peer: peer) }
    }

    static var isTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }

    /// Hooked up at launch. Listens only when a phone is already paired: a Mac that never met a
    /// phone should not open a port — or ask for Local Network access — for nothing. The test host
    /// never listens on its own; a test that wants a server says so with `allowInTests`.
    func attach(_ model: AppModel, allowInTests: Bool = false) {
        self.model = model
        loadPhoneApps()
        guard allowInTests || !Self.isTestHost else { return }
        if !devices.devices.isEmpty { startServer() }
        startPushWatch()
        desktopNotices.attach(model)
        startDesktopWatch()
    }

    func shutdown() {
        for s in sessions { s.close() }
        server.stop()
        ticker?.cancel()
        ticker = nil
        activityHeartbeat?.cancel()
        activityHeartbeat = nil
        activityRetry.values.forEach { $0.cancel() }
        activityRetry = [:]
        liveCheck?.cancel()
        liveCheck = nil
    }

    // MARK: Listening

    var desktopID: String { String(identity?.pin.prefix(22) ?? "") }

    var desktopName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    var desktop: LinkDesktop {
        LinkDesktop(id: desktopID, name: desktopName,
                    version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    language: LanguageBundle.currentCode)
    }

    func startServer() {
        if identity == nil {
            identity = LinkIdentity.loadOrCreate(at: root.appendingPathComponent("identity.json"),
                                                 commonName: "Bulava \(desktopName)")
        }
        guard let identity else {
            serverState = .failed(String(localized: "Bulava could not make its own certificate for the phone link."))
            return
        }
        switch serverState {
        case .listening, .starting: return
        case .stopped, .failed: break
        }
        server.start(identity: identity, port: preferredPort, serviceName: desktopName, desktopID: desktopID)
        startTicker()
    }

    /// Only when the pairing panel closes without a phone ever having been paired here. A phone
    /// removed a minute ago keeps being answered — with "you were removed" — for as long as this
    /// Mac runs, rather than meeting a closed port and concluding the Mac is asleep.
    private func stopServerIfIdle() {
        guard devices.devices.isEmpty, pairingPayload == nil, sessions.isEmpty, !everPaired else { return }
        server.stop()
        ticker?.cancel()
        ticker = nil
    }

    // MARK: Pairing

    /// Opens a fresh one-time code and returns what the QR code shows. Starts listening if it was
    /// not. The code dies in five minutes, when the panel closes, or at its first use.
    @discardableResult
    func beginPairing() -> PairingPayload? {
        startServer()
        guard let identity else { return nil }
        let code = devices.openPairing()
        let port: UInt16
        if case .listening(let p) = serverState { port = p } else { port = preferredPort }
        let hosts = LinkServer.hostCandidates()
        // Kept short: every character makes the code denser and harder to read off a screen. The
        // desktop id is not in it — it is the first 22 characters of the key fingerprint `k`.
        let body: [String: Any] = [
            "v": LinkProtocol.version, "n": desktopName, "k": identity.pin,
            "p": Int(port), "h": hosts, "t": code.token,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        let payload = PairingPayload(url: LinkProtocol.pairingPage + "#" + LinkIdentity.base64url(json),
                                     expiresAt: code.expiresAt, hosts: hosts, port: port)
        pairingPayload = payload
        pairingExpiry?.cancel()
        pairingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LinkDevices.pairingLifetime))
            guard let self, !Task.isCancelled, self.pairingPayload == payload else { return }
            self.pairingPayload = nil
            self.devices.closePairing()
        }
        return payload
    }

    /// The listener's port can settle after the code was drawn (a busy default port). Redrawn
    /// then, so the QR code never points at a port nobody is listening on.
    private func refreshPairingIfPortMoved() {
        guard let payload = pairingPayload, case .listening(let port) = serverState, port != payload.port else { return }
        beginPairing()
    }

    func endPairing() {
        pairingExpiry?.cancel()
        pairingPayload = nil
        devices.closePairing()
        stopServerIfIdle()
    }

    func revoke(_ deviceID: String) {
        devices.revoke(deviceID)
        for s in sessions where s.deviceID == deviceID { s.revoked() }
    }

    // MARK: Connections

    private func connected(_ connection: NWConnection, peer: String) {
        let recent = (failedHandshakes[peer] ?? []).filter { Date().timeIntervalSince($0) < 60 }
        guard recent.count < 5 else {
            log.notice("phone link: \(peer, privacy: .public) is failing to authenticate, refusing for a minute")
            connection.cancel()
            return
        }
        let session = LinkSession(connection: connection, peer: peer, link: self)
        sessions.append(session)
        session.start()
    }

    func sessionClosed(_ session: LinkSession) {
        sessions.removeAll { $0 === session }
    }

    func handshake(_ session: LinkSession, _ hello: LinkHello) {
        let version = desktop.version
        // A phone at the door is when knowing its newest version is worth a request (`LinkReleases`).
        checkPhoneApps()
        if hello.protocolVersion < LinkProtocol.minimumVersion {
            session.refuse(LinkErrorCode.protocolTooOld,
                           String(localized: "This version of the app is too old for Bulava on your Mac. Update the app."),
                           desktopVersion: version, phoneApps: phoneApps)
            return
        }
        if hello.minimumVersion > LinkProtocol.version {
            session.refuse(LinkErrorCode.protocolTooNew,
                           String(localized: "Bulava on your Mac is older than this app. Update Bulava on the Mac."),
                           desktopVersion: version)
            return
        }
        let negotiated = min(hello.protocolVersion, LinkProtocol.version)

        if let pairing = hello.pairing {
            switch devices.consumePairing(pairing.token) {
            case .ok:
                let credential = devices.register(name: hello.app.deviceName, platform: hello.app.platform,
                                                  appVersion: hello.app.version)
                pairingExpiry?.cancel()
                pairingPayload = nil
                pairedThisRun = true
                session.accept(deviceID: credential.deviceID, app: hello.app,
                               welcome: LinkWelcome(protocolVersion: negotiated, desktop: desktop,
                                                    capabilities: LinkProtocol.capabilities,
                                                    deviceID: credential.deviceID, credential: credential))
                log.notice("phone link: paired \(hello.app.platform, privacy: .public)")
            case .expired:
                failed(session)
                session.refuse(LinkErrorCode.pairingExpired,
                               String(localized: "This code has expired. Open the phone panel on your Mac for a new one."))
            case .used:
                failed(session)
                session.refuse(LinkErrorCode.pairingUsed,
                               String(localized: "This code was already used. Open the phone panel on your Mac for a new one."))
            }
            return
        }
        if let credential = hello.credential {
            if let device = devices.authenticate(credential) {
                devices.touch(device.id, name: hello.app.deviceName, appVersion: hello.app.version)
                session.accept(deviceID: device.id, app: hello.app,
                               welcome: LinkWelcome(protocolVersion: negotiated, desktop: desktop,
                                                    capabilities: LinkProtocol.capabilities,
                                                    deviceID: device.id, credential: nil))
                scheduleRefresh()
                return
            }
            failed(session)
            if devices.devices.contains(where: { $0.id == credential.deviceID }) {
                session.refuse(LinkErrorCode.unauthorized,
                               String(localized: "This Mac does not recognise the phone. Pair it again."))
            } else {
                session.refuse(LinkErrorCode.revoked,
                               String(localized: "This phone was removed on the Mac. Pair it again to use it."))
            }
            return
        }
        failed(session)
        session.refuse(LinkErrorCode.unauthorized, String(localized: "Pair the phone first."))
    }

    private func failed(_ session: LinkSession) {
        failedHandshakes[session.peer, default: []].append(Date())
    }

    // MARK: Keeping phones up to date

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    /// Projects the app for every connected phone and sends what changed.
    ///
    /// The projection is built inside `withObservationTracking`, so whatever it read — a chat's
    /// entries, a run's phase, a setting — calls back here the moment it changes. Nothing polls the
    /// app; the phone hears about a new line of an answer about as fast as the Mac's own window.
    func refresh() {
        refreshPairingIfPortMoved()
        guard let model else { return }
        let ready = sessions.filter { $0.deviceID != nil }
        guard !ready.isEmpty else { return }
        let desktop = self.desktop
        var results: [(LinkSession, LinkProjection, [UUID: Set<String>])] = []
        var stopped: [LiveLineDTO] = []
        withObservationTracking {
            let reading = liveReading(model)
            let live = reading.live
            stopped = reading.stopped
            for s in ready {
                var p = LinkProjection.build(model, desktop: desktop, openChats: s.openChats, live: live)
                p.home.phoneApps = phoneApps
                var visible: [UUID: Set<String>] = [:]
                for id in s.openChats where model.conversations.chat(id: id) != nil {
                    visible[id] = Set(model.visibleEntries(inChat: id).map(\.id.uuidString))
                }
                results.append((s, p, visible))
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        for (s, p, v) in results { s.apply(p, visibleIDs: v) }
        liveStopped(stopped)
    }

    /// A second, slower beat for what changes without anything being written: the minutes-and-
    /// seconds a preparation has been running, the time a usage window comes back.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                let busy = self?.sessions.contains { $0.projection?.chats.values.contains { $0.status.active } == true } ?? false
                try? await Task.sleep(for: .seconds(busy ? 1 : 10))
                self?.refresh()
            }
        }
    }

    // MARK: Requests

    enum Outcome {
        case success(any Encodable)
        case failure(LinkError)
    }

    func perform(_ request: LinkRequest, from session: LinkSession) async -> Outcome {
        guard let model else { return .failure(LinkError(code: LinkErrorCode.failed, message: "Bulava is starting.")) }
        let args = request.args
        func bad(_ what: String) -> Outcome {
            .failure(LinkError(code: LinkErrorCode.badRequest, message: what))
        }
        func missing(_ what: String) -> Outcome {
            .failure(LinkError(code: LinkErrorCode.notFound, message: what))
        }

        switch request.op {
        case "home.subscribe":
            session.subscribedHome = true
            refresh()
            return .success(LinkEmpty())

        case "chat.open":
            guard let chatID = args?["chatID"]?.uuid else { return bad("chatID") }
            guard model.conversations.chat(id: chatID) != nil else { return missing("chat") }
            session.open(chatID)
            refresh()
            return .success(LinkEmpty())

        case "chat.close":
            guard let chatID = args?["chatID"]?.uuid else { return bad("chatID") }
            session.closeChat(chatID)
            return .success(LinkEmpty())

        case "chat.history":
            guard let chatID = args?["chatID"]?.uuid else { return bad("chatID") }
            guard model.conversations.chat(id: chatID) != nil else { return missing("chat") }
            var projection = session.projection
                ?? LinkProjection.build(model, desktop: desktop, openChats: session.openChats)
            let page = LinkProjection.earlier(model, chatID: chatID, before: args?["before"]?.uuid,
                                              limit: args?["limit"]?.int ?? 40, into: &projection)
            session.projection = projection
            session.remember(projection.files)
            return .success(HistoryPageDTO(entries: page.entries, hasEarlier: page.hasEarlier))

        case "chat.create":
            guard let productID = args?["productID"]?.uuid, let chatID = args?["chatID"]?.uuid else {
                return bad("productID, chatID")
            }
            guard model.products.product(id: productID) != nil else { return missing("product") }
            if let existing = model.conversations.chat(id: chatID), existing.productID != productID {
                return bad("chatID belongs to another product")
            }
            let chat = model.conversations.adoptChat(id: chatID, for: productID)
            refresh()
            return .success(ChatSummaryDTO(
                id: chat.id.uuidString, productID: chat.productID.uuidString, title: chat.title,
                pinned: chat.pinned, archived: chat.archived, createdAtMs: LinkCoding.ms(chat.createdAt),
                updatedAtMs: LinkCoding.ms(chat.updatedAt),
                status: LinkProjection.status(model.directPhase(for: chat.id))))

        case "chat.send":
            guard let productID = args?["productID"]?.uuid, let chatID = args?["chatID"]?.uuid,
                  let entryID = args?["entryID"]?.uuid else { return bad("productID, chatID, entryID") }
            if let existing = model.conversations.chat(id: chatID) {
                guard existing.productID == productID else { return bad("chatID belongs to another product") }
                guard !existing.archived else {
                    return .failure(LinkError(code: LinkErrorCode.badRequest,
                                              message: String(localized: "This chat is archived. Unarchive it to write in it.")))
                }
            }
            var attachments: [Attachment] = []
            for ref in args?["attachments"]?.array?.compactMap(\.string) ?? [] {
                guard let attachment = attachment(forRef: ref, model: model) else {
                    return missing("attachment \(ref)")
                }
                attachments.append(attachment)
            }
            let text = args?["text"]?.string ?? ""
            switch model.sendDirectMessage(text, attachments: attachments, productID: productID,
                                           chatID: chatID, entryID: entryID) {
            case .sent(let id):
                for a in attachments { arrived[a.id] = nil }
                refresh()
                return .success(SentDTO(entryID: id.uuidString, duplicate: false))
            case .alreadySent(let id):
                return .success(SentDTO(entryID: id.uuidString, duplicate: true))
            case .noSuchProduct:
                return missing("product")
            case .empty:
                return bad(String(localized: "Write something or attach a file first."))
            }

        case "chat.stop":
            guard let chatID = args?["chatID"]?.uuid else { return bad("chatID") }
            model.stopDirectChat(chatID)
            return .success(LinkEmpty())

        case "chat.rename":
            guard let chatID = args?["chatID"]?.uuid, let title = args?["title"]?.string else { return bad("chatID, title") }
            guard model.conversations.chat(id: chatID) != nil else { return missing("chat") }
            model.conversations.rename(chatID, to: title)
            refresh()
            return .success(LinkEmpty())

        case "chat.archive":
            guard let chatID = args?["chatID"]?.uuid, let archived = args?["archived"]?.bool else {
                return bad("chatID, archived")
            }
            guard let chat = model.conversations.chat(id: chatID) else { return missing("chat") }
            if archived { model.archiveChat(chat) } else { model.conversations.setArchived(chatID, false) }
            refresh()
            return .success(LinkEmpty())

        case "chat.pin":
            guard let chatID = args?["chatID"]?.uuid, let pinned = args?["pinned"]?.bool else {
                return bad("chatID, pinned")
            }
            guard let chat = model.conversations.chat(id: chatID) else { return missing("chat") }
            if chat.pinned != pinned { model.conversations.togglePinned(chatID) }
            refresh()
            return .success(LinkEmpty())

        case "entry.retry":
            guard let entryID = args?["entryID"]?.uuid else { return bad("entryID") }
            guard let entry = model.conversations.entry(id: entryID), entry.delivery == .failed else {
                return .failure(LinkProjection.staleError)
            }
            model.retryDirectMessage(entryID: entryID)
            return .success(LinkEmpty())

        case "entry.takeBack":
            guard let entryID = args?["entryID"]?.uuid else { return bad("entryID") }
            guard model.canTakeBack(entryID: entryID) else { return .failure(LinkProjection.staleError) }
            let entry: ConversationEntry = await withCheckedContinuation { continuation in
                model.takeBackMessage(entryID: entryID) { continuation.resume(returning: $0) }
            }
            for a in entry.attachments { arrived[a.id] = a }
            var p = session.projection ?? LinkProjection.build(model, desktop: desktop, openChats: [])
            let files = entry.attachments.map { LinkProjection.fileDTO(for: $0, model: model, into: &p) }
            session.remember(p.files)
            refresh()
            return .success(TakenBackDTO(text: entry.text, attachments: files))

        case "action.invoke":
            guard let id = args?["id"]?.string else { return bad("id") }
            // Checked against a projection made NOW, not the one the phone was last sent: the Mac
            // may have answered the same request a second ago.
            let fresh = LinkProjection.build(model, desktop: desktop, openChats: session.openChats)
            session.projection = fresh
            guard let handler = fresh.actions[id] ?? session.extraActions[id] else {
                return .failure(LinkProjection.staleError)
            }
            if let error = await handler(args?["input"]) { return .failure(error) }
            refresh()
            return .success(LinkEmpty())

        case "file.open":
            guard let ref = args?["ref"]?.string else { return bad("ref") }
            return await openFile(ref: ref, session: session, model: model)

        case "question.answer":
            guard let entryID = args?["entryID"]?.uuid else { return bad("entryID") }
            return await answer(entryID: entryID, args: args, model: model)

        case "upload.begin":
            guard let name = args?["name"]?.string, let size = args?["size"]?.int else { return bad("name, size") }
            let kind = AttachmentKind(rawValue: args?["kind"]?.string ?? "file") ?? .file
            guard session.uploads.count < 8 else { return bad("Too many uploads at once.") }
            guard let upload = LinkUpload(filename: name, kind: kind == .link ? .file : kind, size: Int64(size)) else {
                return .failure(LinkError(code: LinkErrorCode.tooLarge,
                                          message: String(localized: "Files up to 50 MB can be sent from the phone.")))
            }
            session.uploads[upload.id.uuidString] = upload
            return .success(UploadStartedDTO(uploadID: upload.id.uuidString, chunkSize: 256 * 1024))

        case "upload.chunk":
            guard let id = args?["uploadID"]?.string, let upload = session.uploads[id] else { return missing("upload") }
            guard let offset = args?["offset"]?.int, let base64 = args?["data"]?.string,
                  let data = Data(base64Encoded: base64) else { return bad("offset, data") }
            if let error = upload.append(offset: Int64(offset), data) { return .failure(error) }
            return .success(UploadProgressDTO(received: upload.received))

        case "upload.finish":
            guard let id = args?["uploadID"]?.string, let upload = session.uploads.removeValue(forKey: id) else {
                return missing("upload")
            }
            guard let attachment = upload.finish() else {
                return .failure(LinkError(code: LinkErrorCode.failed, message: String(localized: "The file did not arrive whole. Try again.")))
            }
            arrived[attachment.id] = attachment
            var p = session.projection ?? LinkProjection.build(model, desktop: desktop, openChats: [])
            let dto = LinkProjection.fileDTO(for: attachment, model: model, into: &p)
            session.remember(p.files)
            return .success(dto)

        case "upload.cancel":
            if let id = args?["uploadID"]?.string { session.uploads.removeValue(forKey: id)?.discard() }
            return .success(LinkEmpty())

        case "audio.transcribe":
            // Dictation recorded on the phone and uploaded like any file: its words, for the
            // phone's composer. Only a file that arrived from a phone and went into no message may
            // be named — it is deleted once heard — never an attachment a message already carries.
            guard let requestID = args?["requestID"]?.string, !requestID.isEmpty, requestID.count <= 100 else {
                return bad("requestID")
            }
            var audio: URL?
            if let ref = args?["ref"]?.string, ref.hasPrefix("att:"),
               let id = UUID(uuidString: String(ref.dropFirst(4))), let upload = arrived[id] {
                arrived[id] = nil
                audio = model.capture.url(for: upload)
            }
            let language = model.settings.dictationLanguage.code(interface: model.settings.interfaceLanguage)
            guard let outcome = await transcriptions.transcribe(requestID, audio: audio, language: language,
                                                                engine: transcriber) else {
                return missing(String(localized: "The recording did not reach the Mac. Send it again."))
            }
            switch outcome {
            case .text(let text):
                return .success(TranscriptDTO(requestID: requestID, chatID: args?["chatID"]?.string, text: text))
            case .unavailable(let why):
                return .failure(LinkError(code: LinkErrorCode.dictationUnavailable, message: why))
            case .notTranscribed:
                return .failure(LinkError(code: LinkErrorCode.notTranscribed,
                                          message: String(localized: "Could not make out the dictation")))
            }

        case "file.read":
            guard let ref = args?["ref"]?.string else { return bad("ref") }
            return read(ref: ref, offset: Int64(args?["offset"]?.int ?? 0),
                        length: args?["length"]?.int ?? 512 * 1024, session: session)

        case "report.open":
            guard let target = args?["target"]?.string else { return bad("target") }
            guard let report = session.reports[target] ?? session.projection?.reports[target] else {
                return .failure(LinkProjection.staleError)
            }
            return await openReport(report, session: session, model: model)

        case "report.decide":
            return decide(args, session: session, model: model)

        case "commands.list":
            guard let productID = args?["productID"]?.uuid else { return bad("productID") }
            let roots = model.slashCommandRoots(for: productID)
            let found = await Task.detached(priority: .utility) { SlashCommandCatalog.discover(roots) }.value
            return .success(found.map {
                OptionDTO(id: $0.invocation, label: $0.invocation,
                          detail: [$0.argumentHint, $0.description].filter { !$0.isEmpty }.joined(separator: " — "))
            })

        case "context.get":
            guard let productID = args?["productID"]?.uuid else { return bad("productID") }
            return await context(productID: productID, chatID: args?["chatID"]?.uuid, session: session, model: model)

        case "context.diff":
            guard let ref = args?["ref"]?.string else { return bad("ref") }
            return await diff(ref: ref, session: session, model: model)

        case "skills.get":
            return await skills(productID: args?["productID"]?.uuid, full: args?["full"]?.bool ?? false,
                                session: session, model: model)

        case "push.register":
            guard let id = session.deviceID else { return bad("device") }
            let token = args?["token"]?.string?.lowercased()
            guard let token, token.range(of: "^[0-9a-f]{64,200}$", options: .regularExpression) != nil else {
                return bad("token")
            }
            let environment = args?["environment"]?.string == "development" ? "development" : "production"
            devices.setPushToken(token, environment: environment, for: id)
            // A newer phone also hands over the key its Lock Screen reads names with, and which
            // pushes it has words for. An older one sends neither and keeps what it had.
            if args?["seal"] != nil || args?["kinds"] != nil {
                let seal = args?["seal"]?.string.flatMap { LiveSeal.key($0) == nil ? nil : $0 }
                let kinds = args?["kinds"]?.array?.compactMap(\.string).filter { Self.pushKinds.contains($0) }
                devices.setPushAbilities(sealKey: seal, kinds: kinds, for: id)
            }
            startPushWatch()
            return .success(LinkEmpty())

        case "activity.register":
            // An iPhone's Live Activity tokens: `kind` "start" is the one that lets a push begin an
            // activity, "update" the one of the activity running now; an empty token forgets it.
            guard let id = session.deviceID else { return bad("device") }
            let start = args?["kind"]?.string == "start"
            let raw = args?["token"]?.string?.lowercased() ?? ""
            if raw.isEmpty {
                devices.setActivityToken(nil, start: start, for: id)
                return .success(LinkEmpty())
            }
            guard raw.range(of: "^[0-9a-f]{64,400}$", options: .regularExpression) != nil else { return bad("token") }
            devices.setActivityToken(raw, start: start, for: id)
            if let environment = args?["environment"]?.string {
                devices.setPushToken(devices.devices.first { $0.id == id }?.pushToken,
                                     environment: environment == "development" ? "development" : "production", for: id)
            }
            startPushWatch()
            return .success(LinkEmpty())

        case "presence.set":
            session.foreground = args?["foreground"]?.bool ?? true
            return .success(LinkEmpty())

        case "settings.set":
            guard let group = args?["group"]?.string, let value = args?["value"]?.string else { return bad("group, value") }
            // `chat` is newer than the operation: with it the choice is that chat's own, as it is
            // in the Mac's composer. An older phone sends none and sets the default, as before.
            let chat = args?["chat"]?.string.flatMap(UUID.init(uuidString:))
            return setting(group: group, value: value, chat: chat, model: model)

        case "device.forget":
            if let id = session.deviceID {
                devices.revoke(id)
                Task { [weak session] in
                    try? await Task.sleep(for: .milliseconds(300))
                    session?.close()
                }
            }
            return .success(LinkEmpty())

        case "product.rename":
            guard let productID = args?["productID"]?.uuid, let name = args?["name"]?.string else { return bad("productID, name") }
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return bad("name") }
            guard model.products.product(id: productID) != nil else { return missing("product") }
            model.products.rename(productID, to: clean)
            refresh()
            return .success(LinkEmpty())

        case "product.pin":
            guard let productID = args?["productID"]?.uuid, let pinned = args?["pinned"]?.bool else { return bad("productID, pinned") }
            guard let product = model.products.product(id: productID) else { return missing("product") }
            if product.pinned != pinned { model.products.togglePin(productID) }
            refresh()
            return .success(LinkEmpty())

        case "product.remove":
            // Takes the product and its chats out of Bulava; the folders on disk are not touched.
            // The phone asks first, as the Mac does.
            guard let productID = args?["productID"]?.uuid else { return bad("productID") }
            guard let product = model.products.product(id: productID) else { return missing("product") }
            model.removeProduct(product)
            refresh()
            return .success(LinkEmpty())

        case "product.add", "folder.connect", "resource.add", "resource.remove":
            // Folders are connected at the Mac, where their contents are. A phone that asks anyway
            // — an old build, a hand-made request — is told so, and nothing happens.
            return .failure(LinkError(code: LinkErrorCode.notOnPhone,
                                      message: String(localized: "Folders are added on the Mac.")))

        default:
            return .failure(LinkError(code: LinkErrorCode.unknownOperation, message: request.op))
        }
    }

    // MARK: Attachments

    private func attachment(forRef ref: String, model: AppModel) -> Attachment? {
        guard ref.hasPrefix("att:"), let id = UUID(uuidString: String(ref.dropFirst(4))) else { return nil }
        if let a = arrived[id] { return a }
        return model.conversations.entries.lazy.flatMap(\.attachments).first { $0.id == id }
    }

    // MARK: Files

    static let maximumChunk = 512 * 1024

    private func read(ref: String, offset: Int64, length: Int, session: LinkSession) -> Outcome {
        guard let url = resolve(ref: ref, session: session) else {
            return .failure(LinkError(code: LinkErrorCode.notFound, message: ref))
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(LinkError(code: LinkErrorCode.notFound, message: ref))
        }
        defer { try? handle.close() }
        let total = (try? handle.seekToEnd()).map(Int64.init) ?? 0
        guard offset >= 0, offset <= total else {
            return .failure(LinkError(code: LinkErrorCode.badRequest, message: "offset"))
        }
        try? handle.seek(toOffset: UInt64(offset))
        let data = (try? handle.read(upToCount: max(1, min(length, Self.maximumChunk)))) ?? Data()
        return .success(FileChunkDTO(ref: ref, offset: offset, total: total,
                                     data: data.base64EncodedString(),
                                     mime: Self.mime(url.pathExtension), name: url.lastPathComponent))
    }

    /// A ref the phone was actually sent, or a path under a report folder it opened — and never
    /// anything a `..` or a symlink could lead out of.
    private func resolve(ref: String, session: LinkSession) -> URL? {
        if let url = session.files[ref] { return url }
        guard ref.hasPrefix("rep:"), let slash = ref.firstIndex(of: "/") else { return nil }
        let rootRef = String(ref[..<slash])
        let relative = String(ref[ref.index(after: slash)...]).removingPercentEncoding ?? ""
        guard let root = session.files[rootRef], !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else { return nil }
        let candidate = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        let fence = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(fence), FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "pdf": "application/pdf"
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "js": "text/javascript"
        case "json": "application/json"
        case "md", "txt", "log", "swift", "kt", "py", "sh", "ts", "go", "yml", "yaml", "diff", "patch": "text/plain"
        default: "application/octet-stream"
        }
    }

    // MARK: Reports

    private func openReport(_ target: LinkProjection.ReportTarget, session: LinkSession,
                            model: AppModel) async -> Outcome {
        let url: URL?
        if let task = target.task {
            url = await model.client.renderReport(task8: task.reportKey, fallbackTitle: task.title)
        } else if let itemID = target.workItemID, let item = model.workItems.items.first(where: { $0.id == itemID }) {
            url = await model.renderItemReport(item)
        } else if let productID = target.productID {
            url = await model.renderProductReport(productID: productID)
        } else if let path = target.chatReportPath {
            url = FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        } else {
            url = nil
        }
        guard let url, let html = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(LinkError(code: LinkErrorCode.notFound, message: String(localized: "No report yet for this task")))
        }
        let rootRef = "rep:" + LinkDevices.randomToken().prefix(16)
        session.rememberReportRoot(rootRef, url.deletingLastPathComponent())
        var actions: [ActionDTO] = []
        if let task = target.task {
            actions = await finalActions(for: task, session: session, model: model)
        }
        return .success(ReportDTO(title: target.title, html: html, root: rootRef, actions: actions,
                                  decisions: decisions(for: url, model: model)))
    }

    // MARK: Decisions

    /// The questions beside a report, for the phone to draw itself, with the answer last sent.
    private func decisions(for report: URL, model: AppModel) -> DecisionsDTO? {
        guard let state = model.decisions.state(for: report) else { return nil }
        return DecisionsDTO(
            ref: model.decisions.ref(for: report), title: state.set.title, revision: state.set.revision,
            items: state.set.items.map {
                DecisionItemDTO(id: $0.id, title: $0.title, detail: $0.detail, options: $0.options,
                                recommended: $0.recommended, comment: $0.comment)
            },
            latest: state.record.latest.map(Self.sent))
    }

    nonisolated static func sent(_ s: DecisionSubmission) -> DecisionSentDTO {
        DecisionSentDTO(id: s.id.uuidString, sentAt: LinkCoding.ms(s.sentAt), device: s.device,
                        choices: s.answers.choices, comments: s.answers.comments, general: s.answers.general)
    }

    /// His answer to a report, from the phone: the same as pressing Send beside it on the Mac.
    /// The phone keeps `submissionID` until it hears back, so a lost reply is followed by the same
    /// request, which finds the message already sent.
    private func decide(_ args: LinkJSON?, session: LinkSession, model: AppModel) -> Outcome {
        guard let ref = args?["ref"]?.string, let revision = args?["revision"]?.string,
              let submissionID = args?["submissionID"]?.uuid else {
            return .failure(LinkError(code: LinkErrorCode.badRequest, message: "ref, revision, submissionID"))
        }
        guard let report = model.decisions.report(forRef: ref) else { return .failure(LinkProjection.staleError) }
        func map(_ key: String) -> [String: String] {
            guard case .object(let o)? = args?[key] else { return [:] }
            return o.compactMapValues(\.string)
        }
        let answers = DecisionAnswers(choices: map("choices"), comments: map("comments"),
                                      general: args?["general"]?.string ?? "")
        let basedOn = args?["basedOn"]?.string.flatMap(UUID.init(uuidString:))
        switch model.decisions.submit(report: report, answers: answers, revision: revision, basedOn: basedOn,
                                      submissionID: submissionID, device: session.deviceID ?? "phone") {
        case .success(let submission):
            refresh()
            return .success(Self.sent(submission))
        case .failure(let refusal):
            let code: String = switch refusal.code {
            case .stale: LinkErrorCode.decisionsChanged
            case .conflict: LinkErrorCode.decisionsConflict
            case .gone: LinkErrorCode.notFound
            case .invalid: LinkErrorCode.badRequest
            }
            return .failure(LinkError(code: code, message: refusal.message))
        }
    }

    /// The report window's own buttons, as `ReportDocumentView` shows them, turned into ones a
    /// phone can press. Merging and opening a pull request wait for the Mac's own verdict, so the
    /// phone hears "merge did not go through" in the Mac's words rather than nothing.
    private func finalActions(for task: BacklogTask, session: LinkSession, model: AppModel) async -> [ActionDTO] {
        let package = await model.loadReview(for: task)
        let blocker = model.approvalBlocker(task: task, package: package)
        let seenState = task.state
        var out: [ActionDTO] = []
        for action in TaskPresentation.finalActions(for: task, package: package, blocker: blocker, model: model) {
            let style = action.emphasis == .primary ? "primary" : action.emphasis == .danger ? "destructive" : "secondary"
            let id = "report.\(action.id):\(task.id.uuidString)"
            switch action.id {
            case "changes", "followup":
                out.append(ActionDTO(id: id, label: action.title, style: style, kind: "compose",
                                     input: ActionInputDTO(placeholder: action.title, required: true)))
            case "open":
                continue
            case "unavailable":
                out.append(ActionDTO(id: id, label: action.title, style: style, kind: "mac",
                                     disabledReason: action.disabledReason))
            default:
                let taskID = task.id
                let perform = action.perform
                let kind = action.id
                session.extraActions[id] = { [weak model] _ in
                    guard let model, let live = model.backlog.task(id: taskID), live.state == seenState else {
                        return LinkProjection.staleError
                    }
                    if kind == "merge" || kind == "pr", let package {
                        let (message, ok) = await withCheckedContinuation { continuation in
                            model.approve(task: live, package: package) { continuation.resume(returning: ($0, $1)) }
                        }
                        return ok ? nil : LinkError(code: LinkErrorCode.failed, message: message)
                    }
                    perform(model)
                    return nil
                }
                out.append(ActionDTO(id: id, label: action.title, style: style, kind: "invoke",
                                     confirm: kind == "merge" || kind == "pr" ? action.title : nil,
                                     disabledReason: action.disabledReason))
            }
        }
        return out
    }

    // MARK: Questions

    /// The answer as the Mac's question card would have written it: one option as itself, several
    /// with commas, several questions as numbered lines — and anything typed after them.
    private func answer(entryID: UUID, args: LinkJSON?, model: AppModel) async -> Outcome {
        guard let entry = model.conversations.entry(id: entryID), entry.kind == .question,
              let chatID = entry.chatID,
              model.visibleEntries(inChat: chatID).contains(where: { $0.id == entryID }) else {
            return .failure(LinkProjection.staleError)
        }
        let selections: [[String]] = args?["selections"]?.array?.map { $0.array?.compactMap(\.string) ?? [] } ?? []
        let typed = (args?["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = Self.composeAnswer(selections: selections, typed: typed)
        guard !text.isEmpty else {
            return .failure(LinkError(code: LinkErrorCode.badRequest, message: String(localized: "Pick an answer or write one.")))
        }
        if let taskID = entry.taskID, model.backlog.task(id: taskID) != nil {
            model.sendDirectMessage(text, productID: entry.productID, chatID: chatID)
        } else if let refused = await model.answerUnboundQuestionWaiting(entry: entry, text: text) {
            refresh()
            return .failure(LinkError(code: LinkErrorCode.failed, message: refused))
        }
        refresh()
        return .success(LinkEmpty())
    }

    /// A file the phone was handed — named in an answer (`lnk:`) or made by a run (`art:`) —
    /// shared on the home Wi-Fi, and the address the phone opens it at. The folders it may come
    /// from are read again now: a chat's own, or the runs' artifacts.
    private func openFile(ref: String, session: LinkSession, model: AppModel) async -> Outcome {
        guard let url = session.files[ref] else { return .failure(LinkProjection.staleError) }
        let roots: [URL]
        if ref.hasPrefix("lnk:") {
            let parts = ref.split(separator: ":")
            guard parts.count == 3, let chatID = UUID(uuidString: String(parts[1])),
                  let chat = model.conversations.chat(id: chatID) else { return .failure(LinkProjection.staleError) }
            roots = model.fileRoots(forProductID: chat.productID, chatID: chatID)
        } else if ref.hasPrefix("art:") {
            roots = [model.artifactBase]
        } else {
            return .failure(LinkError(code: LinkErrorCode.badRequest, message: String(localized: "This file cannot be opened from the phone.")))
        }
        switch await model.shares.share(url, within: roots) {
        case .failure(let refusal):
            return .failure(LinkError(code: LinkErrorCode.failed, message: refusal.message))
        case .success(let link):
            let address = session.localHost.flatMap { model.shares.url(for: link, host: $0) }
                ?? model.shares.urls(for: link).first
            guard let address else {
                return .failure(LinkError(code: LinkErrorCode.failed,
                                          message: String(localized: "Bulava could not open a port for links to the phone.")))
            }
            return .success(FileOpenDTO(url: address.absoluteString, title: link.title, scope: link.scope.rawValue))
        }
    }

    nonisolated static func composeAnswer(selections: [[String]], typed: String) -> String {
        let picked: String
        if selections.count <= 1 {
            picked = (selections.first ?? []).joined(separator: ", ")
        } else {
            picked = selections.enumerated().compactMap { index, values in
                values.isEmpty ? nil : "\(index + 1): \(values.joined(separator: ", "))"
            }.joined(separator: "\n")
        }
        if picked.isEmpty { return typed }
        if typed.isEmpty { return picked }
        return picked + "\n" + typed
    }

    // MARK: Settings

    /// Only values the Mac is offering right now are accepted — the same list the phone's menu was
    /// drawn from — so a phone cannot set a model this Mac has never heard of. "mode" is not among
    /// them: an older phone that still shows "Who answers" is told its menu is out of date.
    private func setting(group: String, value: String, chat: UUID?, model: AppModel) -> Outcome {
        if let chat, model.conversations.chat(id: chat) == nil {
            return .failure(LinkError(code: LinkErrorCode.notFound, message: "chat"))
        }
        let offered = LinkProjection.composer(model, chatID: chat).groups
        guard let options = offered.first(where: { $0.id == group })?.options,
              options.contains(where: { $0.id == value }) else {
            return .failure(LinkProjection.staleError)
        }
        switch group {
        case "claudeModel":
            model.chooseClaudeModel(ClaudeModelChoice(rawValue: value), for: chat)
        case "claudeEffort":
            if let effort = ClaudeEffortChoice(rawValue: value) {
                model.updateRunChoices(for: chat) { $0.claudeEffort = effort }
            }
        case "codexModel":
            model.chooseCodexModel(value, for: chat)
        case "codexEffort":
            if let effort = CodexEffortChoice(rawValue: value) {
                model.updateRunChoices(for: chat) { $0.codexEffort = effort }
            }
        default:
            return .failure(LinkError(code: LinkErrorCode.unknownOperation, message: group))
        }
        refresh()
        return .success(LinkEmpty())
    }
}

// MARK: - Results

nonisolated struct HistoryPageDTO: Codable, Equatable, Sendable {
    var entries: [EntryDTO]
    var hasEarlier: Bool
}

nonisolated struct SentDTO: Codable, Equatable, Sendable {
    var entryID: String
    var duplicate: Bool
}

nonisolated struct TakenBackDTO: Codable, Equatable, Sendable {
    var text: String
    var attachments: [FileDTO]
}

nonisolated struct UploadStartedDTO: Codable, Equatable, Sendable {
    var uploadID: String
    var chunkSize: Int
}

nonisolated struct UploadProgressDTO: Codable, Equatable, Sendable {
    var received: Int64
}
