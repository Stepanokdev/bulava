import Foundation
import Network
import OSLog

/// One phone, connected.
///
/// A strict little state machine: the first frame must be a `hello` that pairs or authenticates,
/// within ten seconds, or the socket closes. Nothing else is read before that. After it, requests
/// are answered one by one and the phone is kept up to date with whatever it has open.
@MainActor
final class LinkSession: Identifiable {
    let id = UUID()
    let peer: String
    private let connection: NWConnection
    private weak var link: MobileLink?
    private let log = Logger(subsystem: "com.stepanok.bulava", category: "mobile-link")

    enum Phase: Equatable {
        case handshaking
        case ready(deviceID: String)
        case closed
    }
    private(set) var phase: Phase = .handshaking
    private(set) var app: LinkClientApp?

    var deviceID: String? { if case .ready(let id) = phase { return id }; return nil }

    /// The address of this Mac the phone reached it at. A link made for this phone uses it: it is
    /// the one address known to work from where the phone is.
    var localHost: String? {
        guard case .hostPort(let host, _)? = connection.currentPath?.localEndpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: return nil
        }
        return text.split(separator: "%").first.map(String.init)
    }

    /// Whether the phone's app is on screen. An iPhone that goes to the background keeps its socket
    /// for a while and then is frozen with it still open — it says so first, so the Mac wakes it
    /// through the push service instead of talking to a phone that is not listening.
    var foreground = true

    // What the phone is looking at, and what it was last sent about it.
    var subscribedHome = false
    private(set) var openChats: Set<UUID> = []
    private var sentHome: HomeDTO?
    private var sentChats: [UUID: ChatDTO] = [:]

    /// The newest projection this phone was sent — its buttons are the only ones it may press.
    var projection: LinkProjection?
    /// Files this phone has been told about, kept beyond one projection so a picture further up a
    /// chat stays readable. Bounded, oldest out first.
    private(set) var files: [String: URL] = [:]
    private var fileOrder: [String] = []
    private(set) var reports: [String: LinkProjection.ReportTarget] = [:]

    var uploads: [String: LinkUpload] = [:]

    /// Buttons handed over outside a projection — a report's final actions. Each checks for itself
    /// that what it acts on is still as it was when the report was opened.
    var extraActions: [String: LinkActionHandler] = [:]

    /// Files whose diff this phone was offered, by the ref it was given: project folder and path.
    var diffTargets: [String: (String, String)] = [:]

    func addReport(_ target: String, _ report: LinkProjection.ReportTarget) { reports[target] = report }

    /// Cards shown outside a chat — "now and next", the parts of a piece of work. Their buttons are
    /// kept with the session; each checks for itself that the card is still as it was.
    func cards(_ tasks: [BacklogTask], model: AppModel) -> [CardDTO] {
        let built = LinkProjection.cards(tasks, model: model)
        extraActions.merge(built.actions) { _, new in new }
        reports.merge(built.reports) { _, new in new }
        return built.cards
    }

    init(connection: NWConnection, peer: String, link: MobileLink) {
        self.connection = connection
        self.peer = peer
        self.link = link
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionChanged(state) }
        }
        connection.start(queue: .main)
        receive()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.phase == .handshaking else { return }
            self.log.notice("phone link: no hello from \(self.peer, privacy: .public) in time")
            self.close()
        }
    }

    func close() {
        guard phase != .closed else { return }
        phase = .closed
        uploads.values.forEach { $0.discard() }
        uploads.removeAll()
        connection.cancel()
        link?.sessionClosed(self)
    }

    private func connectionChanged(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled: close()
        default: break
        }
    }

    // MARK: Receiving

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, self.phase != .closed else { return }
                if error != nil { self.close(); return }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                if meta?.opcode == .close { self.close(); return }
                if let data, !data.isEmpty {
                    guard data.count <= LinkProtocol.maximumFrame else { self.close(); return }
                    self.handle(data)
                }
                if self.phase != .closed { self.receive() }
            }
        }
    }

    private func handle(_ data: Data) {
        switch phase {
        case .handshaking:
            guard let hello = try? JSONDecoder().decode(LinkHello.self, from: data), hello.type == "hello" else {
                refuse(LinkErrorCode.badRequest, "Expected hello.")
                return
            }
            link?.handshake(self, hello)
        case .ready:
            guard let request = try? JSONDecoder().decode(LinkRequest.self, from: data),
                  request.type == "request" else {
                return
            }
            Task { await self.respond(to: request) }
        case .closed:
            break
        }
    }

    private func respond(to request: LinkRequest) async {
        guard let link else { return }
        let outcome = await link.perform(request, from: self)
        switch outcome {
        case .success(let result):
            send(LinkResponse(id: request.id, ok: true, result: AnyLinkEncodable(result), error: nil))
        case .failure(let error):
            send(LinkResponse<AnyLinkEncodable>(id: request.id, ok: false, result: nil, error: error))
        }
    }

    // MARK: Handshake outcomes

    func accept(deviceID: String, app: LinkClientApp, welcome: LinkWelcome) {
        self.app = app
        phase = .ready(deviceID: deviceID)
        send(welcome)
    }

    func refuse(_ code: String, _ message: String, desktopVersion: String? = nil, phoneApps: PhoneAppsDTO? = nil) {
        send(LinkRefusal(code: code, message: message, desktopVersion: desktopVersion,
                         protocolVersion: LinkProtocol.version, phoneApps: phoneApps))
        // Give the refusal a moment to leave before the socket goes: a phone told nothing cannot
        // say why it was turned away.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.close()
        }
    }

    /// The Mac forgot this phone while it was connected. It is told, then cut off.
    func revoked() {
        send(LinkEvent(event: "revoked", data: LinkError(code: LinkErrorCode.revoked,
                                                           message: String(localized: "This phone was removed on the Mac. Pair it again to use it."))))
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.close()
        }
    }

    // MARK: Sending

    func send<T: Encodable>(_ value: T) {
        guard phase != .closed, let data = try? LinkCoding.encoder().encode(value) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            MainActor.assumeIsolated { self?.close() }
        })
    }

    // MARK: Subscriptions

    static let maximumOpenChats = 4

    func open(_ chatID: UUID) {
        openChats.insert(chatID)
        sentChats[chatID] = nil
        if openChats.count > Self.maximumOpenChats, let drop = openChats.first(where: { $0 != chatID }) {
            openChats.remove(drop)
            sentChats[drop] = nil
        }
    }

    func closeChat(_ chatID: UUID) {
        openChats.remove(chatID)
        sentChats[chatID] = nil
    }

    /// Sends whatever the phone does not yet have, and adopts `next` as the projection its buttons
    /// are checked against.
    func apply(_ next: LinkProjection, visibleIDs: [UUID: Set<String>]) {
        projection = next
        remember(next.files)
        reports.merge(next.reports) { _, new in new }
        if subscribedHome, next.home != sentHome {
            sentHome = next.home
            send(LinkEvent(event: "home", data: next.home))
        }
        for chatID in openChats {
            guard let chat = next.chats[chatID] else {
                if sentChats[chatID] != nil || visibleIDs[chatID] == nil {
                    sentChats[chatID] = nil
                    send(LinkEvent(event: "chat.gone", data: ChatGoneDTO(id: chatID.uuidString)))
                    openChats.remove(chatID)
                }
                continue
            }
            if let old = sentChats[chatID] {
                if let delta = Self.delta(from: old, to: chat, visible: visibleIDs[chatID] ?? []) {
                    send(LinkEvent(event: "chat.delta", data: delta))
                }
            } else {
                send(LinkEvent(event: "chat", data: chat))
            }
            sentChats[chatID] = chat
        }
    }

    nonisolated static func delta(from old: ChatDTO, to new: ChatDTO, visible: Set<String>) -> ChatDeltaDTO? {
        let previous = Dictionary(old.entries.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let upserts = new.entries.filter { previous[$0.id] != $0 }
        // Gone from the conversation, not merely scrolled out of the window: a phone that loaded
        // older messages keeps them.
        let removed = old.entries.map(\.id).filter { !visible.contains($0) }
        let oldOrder = old.entries.map(\.id), newOrder = new.entries.map(\.id)
        let header = ChatHeaderDTO(title: new.title, archived: new.archived, status: new.status,
                                   activity: new.activity, degradation: new.degradation,
                                   queueCount: new.queueCount, busy: new.busy,
                                   hasEarlier: new.hasEarlier, actions: new.actions, composer: new.composer)
        let oldHeader = ChatHeaderDTO(title: old.title, archived: old.archived, status: old.status,
                                      activity: old.activity, degradation: old.degradation,
                                      queueCount: old.queueCount, busy: old.busy,
                                      hasEarlier: old.hasEarlier, actions: old.actions, composer: old.composer)
        guard !upserts.isEmpty || !removed.isEmpty || oldOrder != newOrder || header != oldHeader else {
            return nil
        }
        return ChatDeltaDTO(id: new.id, header: header, upserts: upserts, removed: removed,
                            order: oldOrder != newOrder ? newOrder : nil)
    }

    private static let fileMemory = 4_000

    func remember(_ more: [String: URL]) {
        for (ref, url) in more {
            if files[ref] == nil { fileOrder.append(ref) }
            files[ref] = url
        }
        if fileOrder.count > Self.fileMemory {
            for ref in fileOrder.prefix(fileOrder.count - Self.fileMemory) { files[ref] = nil }
            fileOrder.removeFirst(fileOrder.count - Self.fileMemory)
        }
    }

    func rememberReportRoot(_ ref: String, _ url: URL) { remember([ref: url]) }
}

nonisolated struct ChatGoneDTO: Codable, Equatable, Sendable {
    var id: String
}

/// Lets `perform` return results of different types through one response envelope.
nonisolated struct AnyLinkEncodable: Encodable, @unchecked Sendable {
    private let encodeValue: (Encoder) throws -> Void
    init(_ value: any Encodable) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}
