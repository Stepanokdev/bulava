import Foundation

// The wire contract between Bulava on the Mac and Bulava on a phone.
//
// Everything that crosses the network is one of the types in this file, and none of them is a
// model the app keeps. They are PROJECTIONS: built from `Product`, `Chat`, `ConversationEntry` and the
// rest at the moment they are sent, and never decoded back into them. That separation is the whole
// compatibility story — a property renamed on the Mac changes a projection function, not what a
// phone installed three months ago reads.
//
// The rules a change here has to follow are in `link-protocol/README.md`, and the golden files in
// `link-protocol/fixtures/` are checked by tests on both sides. In short: within one protocol
// version, fields are only ever ADDED; nothing already sent changes meaning or disappears; every
// enum-like value is a string the phone treats as "unknown" when it does not recognise it.

nonisolated enum LinkProtocol {
    /// The version this build speaks, and the oldest a phone may speak to it.
    static let version = 1
    static let minimumVersion = 1

    /// What this Mac can do for a phone. A phone hides whatever it does not find here, which is how
    /// an older Mac and a newer phone stay usable together.
    static let capabilities: [String] = [
        "home", "chat.read", "chat.history", "chat.send", "chat.create", "chat.rename",
        "chat.archive", "chat.pin", "chat.stop", "entry.retry", "entry.takeBack",
        "actions", "questions", "attachments.upload", "files", "reports", "settings.models",
        "attention", "products.manage", "commands", "context", "skills", "push",
        "finished", "liveActivity", "audio.transcribe", "files.open", "reports.decide",
    ]

    static let defaultPort: UInt16 = 47_291
    static let bonjourType = "_bulava-link._tcp"
    /// Where the pairing code points when it is scanned with the phone's own camera instead of
    /// the app: the page that offers the download. The pairing secret travels in the fragment,
    /// which a browser never sends to a server.
    static let pairingPage = "https://bulava.app/pair"
    /// The phone's download page, in the language this Mac speaks: the site has it in English at
    /// /mobile/ and in Ukrainian at /uk/mobile/, and a Ukrainian Mac opening the English one is the
    /// first thing its owner would notice.
    static var downloadPage: String { downloadPage(for: Bundle.main.preferredLocalizations.first) }
    static func downloadPage(for language: String?) -> String {
        language == "uk" ? "https://bulava.app/uk/mobile/" : "https://bulava.app/mobile/"
    }
    static let maximumFrame = 4 * 1024 * 1024
    /// Where bulava.app says which phone app is the newest, per platform. Written by
    /// `scripts/release.sh` beside the APK it publishes; read here, never by the phone, which
    /// talks to nothing but this Mac (`LinkReleases.swift`).
    static let phoneAppsManifest = URL(string: "https://bulava.app/mobile/version.json")!
}

// MARK: - Envelope

/// The first thing a phone says. Carries either the one-time pairing token from the QR code or
/// the credential it was given the first time.
nonisolated struct LinkHello: Codable, Equatable, Sendable {
    var type: String = "hello"
    var protocolVersion: Int
    var minimumVersion: Int
    var app: LinkClientApp
    var pairing: Pairing?
    var credential: LinkCredential?

    nonisolated struct Pairing: Codable, Equatable, Sendable {
        var token: String
    }
}

nonisolated struct LinkClientApp: Codable, Equatable, Sendable {
    var platform: String        // "android" | "ios" — anything else is shown as it came
    var version: String
    var deviceName: String
    var osVersion: String?
}

nonisolated struct LinkCredential: Codable, Equatable, Sendable {
    var deviceID: String
    var secret: String
}

/// The Mac's answer to a hello it accepted.
nonisolated struct LinkWelcome: Codable, Equatable, Sendable {
    var type: String = "welcome"
    var protocolVersion: Int
    var desktop: LinkDesktop
    var capabilities: [String]
    var deviceID: String
    /// Only in the answer to a pairing: what the phone presents from now on. Sent once.
    var credential: LinkCredential?
}

nonisolated struct LinkDesktop: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var version: String
    var language: String
}

/// The Mac's answer to a hello it did not accept. The connection closes after it.
nonisolated struct LinkRefusal: Codable, Equatable, Sendable {
    var type: String = "refused"
    var code: String
    var message: String
    var desktopVersion: String?
    var protocolVersion: Int?
    /// The newest phone app bulava.app offers, as this Mac last read it — so a phone turned away
    /// as too old can say which version to get, and where. Absent from an older Mac.
    var phoneApps: PhoneAppsDTO? = nil
}

nonisolated enum LinkErrorCode {
    static let unauthorized = "unauthorized"
    static let revoked = "revoked"
    static let pairingExpired = "pairing_expired"
    static let pairingUsed = "pairing_used"
    static let protocolTooOld = "protocol_too_old"
    static let protocolTooNew = "protocol_too_new"
    static let badRequest = "bad_request"
    static let unknownOperation = "unknown_operation"
    static let notFound = "not_found"
    /// The thing the phone pressed a button about is not there any more — it was answered on the
    /// Mac, or it went away by itself. Nothing was done.
    static let stale = "stale"
    /// The report's questions changed since the phone read them: nothing was sent. Read it again.
    static let decisionsChanged = "decisions_changed"
    /// Another device answered the report meanwhile: nothing was sent. Its answer comes with the
    /// report when it is read again, and a correction builds on it.
    static let decisionsConflict = "decisions_conflict"
    /// Deliberately not offered to a phone. Adding folders is the one such thing today.
    static let notOnPhone = "not_on_phone"
    static let tooLarge = "too_large"
    static let failed = "failed"
    /// A recording sent for transcription found no Whisper here: this build has none, or its model
    /// is not on disk yet (it is then being fetched, and a retry in a few minutes works).
    static let dictationUnavailable = "dictation_unavailable"
    /// Whisper ran and made out no words — silence, noise, a recording cut too short.
    static let notTranscribed = "not_transcribed"
}

/// A request from the phone. `args` is decoded per operation by `LinkCommands`.
nonisolated struct LinkRequest: Decodable, Sendable {
    var type: String
    var id: String
    var op: String
    var args: LinkJSON?
}

nonisolated struct LinkResponse<Result: Encodable & Sendable>: Encodable, Sendable {
    var type: String = "response"
    var id: String
    var ok: Bool
    var result: Result?
    var error: LinkError?
}

nonisolated struct LinkError: Codable, Equatable, Sendable {
    var code: String
    var message: String
}

nonisolated struct LinkEvent<Payload: Encodable & Sendable>: Encodable, Sendable {
    var type: String = "event"
    var event: String
    var data: Payload
}

nonisolated struct LinkEmpty: Codable, Equatable, Sendable {}

// MARK: - Home

/// Everything the phone's drawer and inbox need: products, their chats, and what is waiting.
nonisolated struct HomeDTO: Codable, Equatable, Sendable {
    var desktop: LinkDesktop
    var products: [ProductDTO]
    var attention: [AttentionDTO]
    var composer: ComposerOptionsDTO
    var readiness: [ReadinessDTO]
    /// Work that finished and waits to be read: a report nobody has acted on yet.
    var finished: [FinishedDTO] = []
    /// How much is going on, at a glance — what a Live Activity on an iPhone shows.
    var summary: SummaryDTO = SummaryDTO(working: 0, waiting: 0, ready: 0)
    /// What is working right now, by name, and what just stopped — the Lock Screen's lines, the
    /// same work the Mac's menu bar lists under "Working now". Absent from a Mac older than this.
    var live: LiveDTO? = nil
    /// Claude's and Codex's usage, as the foot of the Mac's sidebar shows it. Absent while neither
    /// is known, and from a Mac older than this.
    var limits: LimitsDTO? = nil
    /// The newest phone app bulava.app offers, per platform, as this Mac last read it. The phone
    /// compares it with itself and offers the update; absent until the Mac has read it once.
    var phoneApps: PhoneAppsDTO? = nil
}

/// What `https://bulava.app/mobile/version.json` says, passed on as it was read. The phone opens
/// nothing on the internet itself — its only connection is this Mac — so the Mac reads it for it.
nonisolated struct PhoneAppsDTO: Codable, Equatable, Sendable {
    var android: PhoneAppDTO?
    var ios: PhoneAppDTO?
}

nonisolated struct PhoneAppDTO: Codable, Equatable, Sendable {
    /// "1.1" — what the phone's About line shows.
    var version: String
    /// The build number, which only ever rises: what an update is decided by.
    var build: Int
    /// Where the update is: the APK on bulava.app, the TestFlight invitation.
    var url: String
}

/// The sidebar's "Limits": each engine the Mac has heard from, with its session and weekly windows.
/// Every word is the Mac's, in its language, like the rest of what it sends; the time until a window
/// comes back is re-said as it runs down (the link's slower beat).
nonisolated struct LimitsDTO: Codable, Equatable, Sendable {
    /// "Limits".
    var title: String
    var engines: [EngineLimitsDTO]
}

nonisolated struct EngineLimitsDTO: Codable, Equatable, Sendable {
    /// "Claude" or "Codex".
    var name: String
    /// The tightest window's share used, for the folded line; nil while none is known.
    var used: Int?
    /// comfortable | tight | nearlyOut — of that tightest window. Unknown values read as comfortable.
    var pressure: String
    var windows: [LimitWindowDTO]
    /// Said in place of the windows while none is known yet.
    var note: String?
    /// Read over half an hour ago, or never: the meters are dimmed.
    var stale: Bool
    /// How long ago it was read, when it is stale and that is known: "2 hours ago".
    var readAgo: String?
}

nonisolated struct LimitWindowDTO: Codable, Equatable, Sendable {
    /// "Session" — Claude's five hours, Codex's short window — or "Weekly".
    var label: String
    /// 0…100.
    var used: Int
    /// "34% used".
    var usedLabel: String
    /// comfortable | tight | nearlyOut.
    var pressure: String
    /// When it comes back, as the sidebar says it: "2h 5m". Absent when the Mac does not know.
    var resets: String?
}

/// The stretch of work going on now, by name: what the Lock Screen of an iPhone says.
///
/// `running` is what works by itself right now; `ended` is what stopped since the stretch began,
/// each with how it stopped. `over` is true once nothing has run for a while — the stretch is done
/// and the Live Activity ends on the last of it. A line that stops only for the moment between
/// Claude and Codex's review does not count as stopped: it has to stay stopped first.
nonisolated struct LiveDTO: Codable, Equatable, Sendable {
    var running: [LiveLineDTO]
    var ended: [LiveLineDTO]
    var over: Bool
}

nonisolated struct LiveLineDTO: Codable, Equatable, Sendable {
    /// "chat:<uuid>" or "task:<uuid>".
    var id: String
    var productID: String
    var chatID: String?
    var title: String
    var product: String
    /// When this piece of work started — the message it answers, or the run.
    var sinceMs: Int64?
    /// For an ended line: "done" | "attention" | "failed" | "stopped".
    var outcome: String?
    /// For an ended line, how the Mac words where it stopped — "Night Shift replied".
    var label: String? = nil
}

nonisolated struct FinishedDTO: Codable, Equatable, Sendable {
    var id: String
    var productID: String
    var chatID: String?
    var title: String
    var body: String
    var atMs: Int64
    /// Opens the report.
    var report: ActionDTO?
}

/// Counts and nothing else: runs going on by themselves, things waiting for the director, reports
/// ready to read. It is all a notification relay ever hears about the work.
nonisolated struct SummaryDTO: Codable, Equatable, Sendable {
    var working: Int
    var waiting: Int
    var ready: Int
}

nonisolated struct ProductDTO: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var initials: String
    var pinned: Bool
    var brief: String
    var icon: FileDTO?
    var status: StatusDTO?
    var lastWorkedAtMs: Int64?
    var chats: [ChatSummaryDTO]
    var archivedChats: [ChatSummaryDTO]
}

nonisolated struct ChatSummaryDTO: Codable, Equatable, Sendable {
    var id: String
    var productID: String
    var title: String
    var pinned: Bool
    var archived: Bool
    var createdAtMs: Int64
    var updatedAtMs: Int64
    var status: StatusDTO
}

/// A state as the Mac words it. `code` is for the phone's own logic (icons, sorting) and may be a
/// value the phone has never seen; `label` is always safe to show as it is.
nonisolated struct StatusDTO: Codable, Equatable, Sendable {
    var code: String
    var label: String
    /// neutral | active | attention | problem | good
    var tone: String
    var active: Bool
}

nonisolated struct AttentionDTO: Codable, Equatable, Sendable {
    var id: String
    var productID: String
    var chatID: String?
    /// question | ask | review | failure | readiness — or something newer
    var kind: String
    var title: String
    var body: String
    var tone: String
    var atMs: Int64
    var actions: [ActionDTO]
    /// What the question is about, as the Mac's dialog lists it: files, servers, a folder.
    var code: String? = nil
}

nonisolated struct ComposerOptionsDTO: Codable, Equatable, Sendable {
    var groups: [OptionGroupDTO]
    /// What the next message runs on, in the words of the Mac's composer pill: each engine in the
    /// order they work — Claude writes, Codex reviews — with its model and depth.
    var summary: [RunPartDTO]? = nil
}

/// One menu of choices — which model, how deep — as the Mac offers them today.
nonisolated struct OptionGroupDTO: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var options: [OptionDTO]
    var selected: String?
    /// The engine this choice is for: "claude" | "codex". A phone groups the menus by it, the way
    /// the Mac's panel has one page per engine.
    var engine: String? = nil
    /// "model" | "depth". Depth is an ordered scale, drawn as one.
    var kind: String? = nil
}

nonisolated struct OptionDTO: Codable, Equatable, Sendable {
    var id: String
    var label: String
    var detail: String?
    /// The heading this option sits under in the Mac's menu ("Newest of each", "A fixed version").
    var section: String? = nil
}

/// One engine in the pill: "Opus 5.5 · Very high".
nonisolated struct RunPartDTO: Codable, Equatable, Sendable {
    var engine: String
    var name: String
    var model: String
    var depth: String?
}

nonisolated struct ReadinessDTO: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var detail: String
    /// ready | attention | problem | checking
    var state: String
    var actions: [ActionDTO]
}

// MARK: - Chat

nonisolated struct ChatDTO: Codable, Equatable, Sendable {
    var id: String
    var productID: String
    var title: String
    var archived: Bool
    var status: StatusDTO
    var activity: String?
    var degradation: String?
    var queueCount: Int
    var busy: Bool
    var entries: [EntryDTO]
    var hasEarlier: Bool
    var actions: [ActionDTO]
    /// What this chat's next message runs on — its own model and depth for Claude and for Codex,
    /// which the Mac keeps per chat. Absent from an older Mac: the phone then reads `home.composer`.
    var composer: ComposerOptionsDTO? = nil
}

/// What changed in an open chat since the last thing the phone was sent.
nonisolated struct ChatDeltaDTO: Codable, Equatable, Sendable {
    var id: String
    var header: ChatHeaderDTO
    var upserts: [EntryDTO]
    var removed: [String]
    /// The ids of the window, oldest first, whenever membership or order changed.
    var order: [String]?
}

nonisolated struct ChatHeaderDTO: Codable, Equatable, Sendable {
    var title: String
    var archived: Bool
    var status: StatusDTO
    var activity: String?
    var degradation: String?
    var queueCount: Int
    var busy: Bool
    var hasEarlier: Bool
    var actions: [ActionDTO]
    /// The chat's run control, as in `ChatDTO.composer`: a choice made on the Mac for this chat
    /// reaches the phone's chip as it is made.
    var composer: ComposerOptionsDTO? = nil
}

nonisolated struct EntryDTO: Codable, Equatable, Sendable {
    var id: String
    /// user | agent | codex | event | question | decision | report | unknown
    var kind: String
    var atMs: Int64
    var author: String
    var text: String
    var blocks: [BlockDTO]
    var attachments: [FileDTO]
    var tone: String
    var delivery: DeliveryDTO?
    var asks: [AskDTO]
    var actions: [ActionDTO]
    var question: QuestionDTO?
    var card: CardDTO?
    var finished: Bool?
    /// "Explain what happened", when the Mac offers it for this answer.
    var explanation: ExplanationDTO? = nil
}

nonisolated struct ExplanationDTO: Codable, Equatable, Sendable {
    var brief: String?
    var stepByStep: String?
    var running: Bool
    /// The answer changed after the explanation was written.
    var stale: Bool
    var failure: String?
    var actions: [ActionDTO]
}

nonisolated struct DeliveryDTO: Codable, Equatable, Sendable {
    /// queued | failed | replaced
    var code: String
    var label: String
}

nonisolated struct BlockDTO: Codable, Equatable, Sendable {
    var id: String
    /// markdown | activity | consult | file | gallery | error | unknown
    var kind: String
    var text: String
    var activity: ActivityDTO?
    var files: [FileDTO]
    /// Files the text names that the phone may open (`file.open`); absent when there are none.
    var links: [FileDTO]? = nil
}

nonisolated struct ActivityDTO: Codable, Equatable, Sendable {
    var sentence: String
    /// running | done | failed
    var status: String
    var detail: String?
}

/// A file the phone may fetch with `file.read`, by the opaque `ref` — never by path.
/// What `file.open` answers: where the phone opens it, on this Mac's home Wi-Fi.
nonisolated struct FileOpenDTO: Codable, Equatable, Sendable {
    var url: String
    var title: String
    /// site | file
    var scope: String
}

nonisolated struct FileDTO: Codable, Equatable, Sendable {
    var ref: String?
    var name: String
    /// image | video | audio | archive | document | code | log | link | other
    var kind: String
    var size: Int64?
    var url: String?
}

/// Something standing between a message and its answer — a folder to trust, git to allow, work to
/// commit — with the buttons that clear it. The Mac decides the words and the buttons; the phone
/// draws them.
nonisolated struct AskDTO: Codable, Equatable, Sendable {
    var id: String
    var kind: String
    var tone: String
    var title: String
    var detail: String?
    var code: String?
    var actions: [ActionDTO]
}

nonisolated struct ActionDTO: Codable, Equatable, Sendable {
    var id: String
    var label: String
    /// primary | secondary | destructive
    var style: String
    /// invoke — send `action.invoke` with this id;
    /// compose — put the cursor in the composer with `placeholder`;
    /// report — open the report named by `target`;
    /// mac — cannot be done from a phone; `label` says what to do at the Mac.
    var kind: String
    var confirm: String?
    var input: ActionInputDTO?
    var target: String?
    var disabledReason: String?
}

nonisolated struct ActionInputDTO: Codable, Equatable, Sendable {
    var placeholder: String
    var required: Bool
    /// What the field starts with, when the Mac has a better start than nothing.
    var value: String? = nil
    /// When the Mac asks for this in a sheet of its own — «Commit as me…» — what that sheet shows,
    /// so the phone's shows the same before anything is pressed: its heading, the lines above and
    /// below the field, and the words on its button. A phone older than this shows the field alone.
    var title: String? = nil
    var above: [InputNoteDTO]? = nil
    var below: [InputNoteDTO]? = nil
    var submit: String? = nil
    /// Why it cannot be done as it stands — the sheet says so, and its button stays off.
    var blocked: String? = nil
}

/// One line of such a sheet.
nonisolated struct InputNoteDTO: Codable, Equatable, Sendable {
    var text: String
    /// nil (secondary) | faint | attention | problem
    var tone: String? = nil
    /// Set for a file list: drawn in a fixed-width face, and scrolls when long.
    var mono: Bool? = nil
}

nonisolated struct QuestionDTO: Codable, Equatable, Sendable {
    var eyebrow: String
    var headline: String
    var situation: String?
    var recommendation: String?
    var ifUnanswered: String?
    var unblocks: String?
    var items: [QuestionItemDTO]
    var answerable: Bool
}

nonisolated struct QuestionItemDTO: Codable, Equatable, Sendable {
    var question: String
    var header: String?
    var options: [OptionDTO]
    var multiSelect: Bool
}

/// A piece of work shown in a chat — a task card or a report card — with what can be done to it.
nonisolated struct CardDTO: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    var status: StatusDTO
    var actions: [ActionDTO]
}

// MARK: - Files

nonisolated struct FileChunkDTO: Codable, Equatable, Sendable {
    var ref: String
    var offset: Int64
    var total: Int64
    var data: String      // base64
    var mime: String
    var name: String
}

nonisolated struct ReportDTO: Codable, Equatable, Sendable {
    var title: String
    /// The page itself. Anything it loads by a relative path is fetched with `file.read`, using
    /// `root` as the ref prefix.
    var html: String
    var root: String
    /// What the Mac's report window offers at its top: merge, open a pull request, "that answers
    /// it", ask for changes. Empty for a chat's own report.
    var actions: [ActionDTO] = []
    /// What the report asks him to decide, drawn by the phone itself beside the page — never by
    /// the page. Nil for a report that asks nothing, and from an older Mac.
    var decisions: DecisionsDTO? = nil
}

/// A report's questions (`decisions.json` beside it), and the answer last sent to them.
nonisolated struct DecisionsDTO: Codable, Equatable, Sendable {
    /// What `report.decide` names: the report itself, not its place in a list.
    var ref: String
    var title: String
    /// The questions as they are now. An answer carries it back; questions that changed in between
    /// refuse it with `decisions_changed`.
    var revision: String
    var items: [DecisionItemDTO]
    /// The answer last sent, from this phone or anywhere else. A new one names it as `basedOn`;
    /// one sent meanwhile from elsewhere refuses it with `decisions_conflict`.
    var latest: DecisionSentDTO?
}

nonisolated struct DecisionItemDTO: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var detail: String?
    var options: [String]
    /// The agent's advice: a hint beside the options, never a preselected answer.
    var recommended: String?
    var comment: Bool
}

nonisolated struct DecisionSentDTO: Codable, Equatable, Sendable {
    /// The phone's own id for it: sending the same id again is answered with this, not a second message.
    var id: String
    var sentAt: Int64
    /// "mac", or the device that sent it.
    var device: String
    var choices: [String: String]
    var comments: [String: String]
    var general: String
}

// MARK: - Any JSON

/// Arguments arrive as arbitrary JSON and are read per operation.
nonisolated enum LinkJSON: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: LinkJSON])
    case array([LinkJSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([LinkJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: LinkJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> LinkJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var int: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    var uuid: UUID? { string.flatMap(UUID.init(uuidString:)) }
    var array: [LinkJSON]? { if case .array(let a) = self { return a }; return nil }
}

nonisolated enum LinkCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

// MARK: - Context of a product

/// What the Mac's inspector pane shows beside a chat: the product's folders and their access, what
/// the run changed, its checks, the instructions, what is next, and the work it holds.
nonisolated struct ContextDTO: Codable, Equatable, Sendable {
    var productID: String
    var resources: [ResourceDTO]
    var changes: [ChangeDTO]
    var checks: ChecksDTO?
    var instructions: InstructionsDTO?
    var nowAndNext: [CardDTO]
    var work: [WorkDTO]
    /// "Everything done so far", when anything has finished.
    var report: ActionDTO?
    /// This chat's reports, as the Mac's panel lists them, with "Create report". Nil when the chat
    /// has no session yet — the Mac shows no such section then — and from an older Mac.
    var chatReports: ChatReportsDTO? = nil
}

nonisolated struct ChatReportsDTO: Codable, Equatable, Sendable {
    /// Newest first.
    var items: [ChatReportDTO]
    /// A report is being made for this chat right now.
    var generating: Bool
    /// "Create report"; nil for an archived chat, which is read only.
    var create: ActionDTO?
    /// What the Mac says under it: where the report is saved.
    var note: String
}

nonisolated struct ChatReportDTO: Codable, Equatable, Sendable {
    /// "Latest report" or "Report".
    var title: String
    /// When and what, from the report's folder.
    var detail: String
    /// Opens it (`kind: report`).
    var open: ActionDTO
}

nonisolated struct ResourceDTO: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// repository | folder | website | integration
    var kind: String
    var kindLabel: String
    /// workspace | source
    var access: String
    var accessLabel: String
    var path: String?
    var url: String?
    var branch: String?
    var primary: Bool
    var live: Bool
    var actions: [ActionDTO]
}

nonisolated struct ChangeDTO: Codable, Equatable, Sendable {
    /// Pass to `context.diff`.
    var ref: String
    var project: String
    var path: String
    var kindLabel: String
    var added: Int?
    var removed: Int?
}

nonisolated struct ChecksDTO: Codable, Equatable, Sendable {
    /// pass | fail | inconclusive | skipped | unknown
    var status: String
    var items: [CheckDTO]
}

nonisolated struct CheckDTO: Codable, Equatable, Sendable {
    var criterion: String
    var status: String
    var note: String
}

nonisolated struct InstructionsDTO: Codable, Equatable, Sendable {
    var summary: String
    var brief: String
}

/// A piece of work with its parts — one task, several streams, or variants of the same thing.
nonisolated struct WorkDTO: Codable, Equatable, Sendable {
    var id: String
    var title: String
    /// job | variants
    var kind: String
    var status: StatusDTO
    var parts: [CardDTO]
    var missing: Int
    var report: ActionDTO?
}

nonisolated struct DiffDTO: Codable, Equatable, Sendable {
    var text: String
}

// MARK: - Skills and MCP servers

nonisolated struct SkillsDTO: Codable, Equatable, Sendable {
    var skills: [SkillDTO]
    var servers: [ServerDTO]
    /// Whether use was counted in the transcripts — otherwise the numbers are not in yet.
    var counted: Bool
    var transcripts: Int
}

nonisolated struct SkillDTO: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// project | global | plugin
    var scope: String
    var description: String
    var uses: Int
    var usesHere: Int?
    var lastUsed: String?
    var source: String?
    var actions: [ActionDTO]
}

nonisolated struct ServerDTO: Codable, Equatable, Sendable {
    var name: String
    var target: String
    /// connected | failed | needs_auth | unknown
    var health: String
    var transport: String
    var scope: String
    var description: String
    var uses: Int
    var lastUsed: String?
}
