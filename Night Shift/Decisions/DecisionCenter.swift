import Foundation
import CryptoKit
import Observation

/// What was answered to a report with decisions, kept by Bulava itself.
nonisolated struct DecisionAnswerLog: Codable, Equatable, Sendable {
    var reportPath: String
    var chatID: UUID?
    /// What is ticked and written so far, not sent yet. The phone keeps its own until it sends.
    var draft: DecisionAnswers = DecisionAnswers()
    var submissions: [DecisionSubmission] = []

    var latest: DecisionSubmission? { submissions.last }
}

/// What the Mac's panel knows about the answers already sent: which one he had in front of him.
///
/// A new answer corrects THAT one. An answer sent from the phone after he looked is shown to him
/// first, and nothing goes until he has seen it — his draft never silently becomes a correction of
/// an answer he never read.
nonisolated struct DecisionReview: Equatable, Sendable {
    /// The last answer he has seen; nil when he has seen none (or there was none).
    private(set) var seen: UUID?
    private var opened = false

    /// The panel opened on this record: what was sent before is what he sees.
    mutating func open(_ record: DecisionAnswerLog) {
        guard !opened else { return }
        opened = true
        seen = record.latest?.id
    }

    /// An answer sent since he looked, from anywhere but this panel.
    func unseen(in record: DecisionAnswerLog) -> DecisionSubmission? {
        guard let latest = record.latest, latest.id != seen else { return nil }
        return latest
    }

    /// He read it: his answer will correct it.
    mutating func acknowledge(_ record: DecisionAnswerLog) { seen = record.latest?.id }

    func canSend(_ answers: DecisionAnswers, in record: DecisionAnswerLog) -> Bool {
        !answers.isEmpty && unseen(in: record) == nil
    }

    /// The answer his would correct.
    func corrected(in record: DecisionAnswerLog) -> DecisionSubmission? {
        seen.flatMap { id in record.submissions.first { $0.id == id } }
    }

    mutating func sent(_ submission: DecisionSubmission) { seen = submission.id }
}

/// Reports that ask the director to decide, and the answers to them.
///
/// The agent writes the questions (`decisions.json` beside its report) and publishes the report to
/// its chat with `$IDIR/decide`. The director answers on the Mac (`DecisionPanel`) or the phone
/// (`report.decide`); either way the answer becomes his message in that chat, through the same
/// addressed send as anything he types (`sendDirectMessage(…entryID:)`), so the agent reads it as
/// his words and goes on.
///
/// The record of what was answered lives here, in Bulava's own store — never in the report's
/// folder, which the agent can rewrite. Two rules keep an answer honest:
/// - it answers the questions as they are now: a report whose `decisions.json` changed since it was
///   read is a different set of questions, and an answer to the old one is refused (`stale`);
/// - it builds on the last answer sent: one sent from another device in between is shown first
///   rather than silently overwritten (`conflict`).
/// A submission carries its own id, used as the chat message's id: sending it again after a lost
/// reply finds the message already there instead of writing a second one.
@MainActor
@Observable
final class DecisionCenter {
    @ObservationIgnored weak var model: AppModel?
    /// Bumped on every write: what views watch. The records themselves are read lazily, from a
    /// view's body too, so reading one must not count as a change.
    private(set) var version = 0
    @ObservationIgnored private var records: [String: DecisionAnswerLog] = [:]
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var requests: URL?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Set<String> = []

    init(folder: URL = AppSupport.file("decisions")) {
        self.folder = folder
    }

    // MARK: Reading

    func record(for report: URL) -> DecisionAnswerLog {
        _ = version
        let key = Self.key(report)
        if let known = records[key] { return known }
        let loaded = stored(key) ?? DecisionAnswerLog(reportPath: report.standardizedFileURL.path)
        records[key] = loaded
        return loaded
    }

    /// How a phone names a report it was shown with decisions. Its place in a chat's list of
    /// reports moves as reports are added; this does not.
    func ref(for report: URL) -> String {
        let key = Self.key(report)
        if stored(key) == nil { store(record(for: report)) }
        return "dec:" + key
    }

    /// The report a phone names, if Bulava ever showed it with decisions.
    func report(forRef ref: String) -> URL? {
        guard ref.hasPrefix("dec:") else { return nil }
        let key = String(ref.dropFirst(4))
        guard key.range(of: "^[0-9a-f]{24}$", options: .regularExpression) != nil else { return nil }
        guard let log = records[key] ?? stored(key) else { return nil }
        return URL(fileURLWithPath: log.reportPath)
    }

    private func stored(_ key: String) -> DecisionAnswerLog? {
        (try? Data(contentsOf: file(key))).flatMap { try? JSONDecoder().decode(DecisionAnswerLog.self, from: $0) }
    }

    /// The questions and what is known about the answers, for a report that has decisions.
    func state(for report: URL) -> (set: DecisionSet, record: DecisionAnswerLog)? {
        guard let set = DecisionSet.load(besides: report) else { return nil }
        return (set, record(for: report))
    }

    func saveDraft(_ answers: DecisionAnswers, for report: URL) {
        var r = record(for: report)
        guard r.draft != answers else { return }
        r.draft = answers
        store(r)
    }

    // MARK: Answering

    /// One answer, from the Mac or the phone. Sends it as the director's message in the report's
    /// chat and returns what was recorded — or why it was not taken.
    func submit(report: URL, answers: DecisionAnswers, revision: String, basedOn: UUID?,
                submissionID: UUID, device: String) -> Result<DecisionSubmission, DecisionRefusal> {
        var r = record(for: report)
        if let already = r.submissions.first(where: { $0.id == submissionID }) { return .success(already) }
        guard let model else { return .failure(DecisionRefusal(code: .gone, message: String(localized: "Bulava is not ready yet."))) }
        guard let set = DecisionSet.load(besides: report) else {
            return .failure(DecisionRefusal(code: .gone, message: String(localized: "The report's decisions are not there any more.")))
        }
        guard set.revision == revision else {
            return .failure(DecisionRefusal(code: .stale, message: String(localized: "The report changed while it was open. Look at it again before sending.")))
        }
        guard basedOn == r.latest?.id else {
            return .failure(DecisionRefusal(code: .conflict, message: String(localized: "Decisions for this report were sent from another device meanwhile. Look at them before sending yours.")))
        }
        let clean: DecisionAnswers
        switch answers.checked(against: set) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let ok): clean = ok
        }
        guard !clean.isEmpty else {
            return .failure(DecisionRefusal(message: String(localized: "Nothing is chosen or written yet.")))
        }
        guard let chatID = r.chatID ?? chat(holding: report)?.id, let chat = model.conversations.chat(id: chatID) else {
            return .failure(DecisionRefusal(code: .gone, message: String(localized: "The chat this report belongs to is not there any more.")))
        }
        let text = Self.message(set: set, answers: clean, correcting: r.latest)
        switch model.sendDirectMessage(text, productID: chat.productID, chatID: chat.id, entryID: submissionID) {
        case .sent, .alreadySent:
            break
        case .noSuchProduct, .empty:
            return .failure(DecisionRefusal(code: .gone, message: String(localized: "The chat this report belongs to is not there any more.")))
        }
        let submission = DecisionSubmission(id: submissionID, revision: revision, basedOn: basedOn, answers: clean,
                                            sentAt: Date(), device: device)
        r.chatID = chat.id
        r.submissions.append(submission)
        r.draft = DecisionAnswers()
        store(r)
        return .success(submission)
    }

    /// "Send" in the Mac's panel: his answer, correcting the one he saw — refused while one he has
    /// not seen is there.
    func send(from review: inout DecisionReview, report: URL, answers: DecisionAnswers, revision: String,
              submissionID: UUID = UUID()) -> Result<DecisionSubmission, DecisionRefusal> {
        if review.unseen(in: record(for: report)) != nil {
            return .failure(DecisionRefusal(code: .conflict, message: String(localized: "Decisions for this report were sent from another device meanwhile. Look at them before sending yours.")))
        }
        let result = submit(report: report, answers: answers, revision: revision, basedOn: review.seen,
                            submissionID: submissionID, device: "mac")
        if case .success(let submission) = result { review.sent(submission) }
        return result
    }

    /// The director's message: every item with what he chose, or that he left it open; what he
    /// wrote; and, for a second answer, which earlier one it replaces.
    static func message(set: DecisionSet, answers: DecisionAnswers, correcting earlier: DecisionSubmission?) -> String {
        var lines: [String] = []
        if let earlier {
            let time = DateFormatter.localizedString(from: earlier.sentAt, dateStyle: .none, timeStyle: .short)
            lines.append(String(format: String(localized: "Corrected decisions on “%@” (they replace the ones sent at %@):"), set.title, time))
        } else {
            lines.append(String(format: String(localized: "My decisions on “%@”:"), set.title))
        }
        for (index, item) in set.items.enumerated() {
            let choice = answers.choices[item.id] ?? String(localized: "not decided — do not start it, ask me")
            lines.append("\(index + 1). \(item.title) — \(choice)")
            if let comment = answers.comments[item.id] { lines.append("   " + String(format: String(localized: "Comment: %@"), comment)) }
        }
        if !answers.general.isEmpty {
            lines.append("")
            lines.append(String(format: String(localized: "Overall: %@"), answers.general))
        }
        return lines.joined(separator: "\n")
    }

    /// A link to a report with decisions, clicked in a chat: it opens in the report window with
    /// its choices beside it, not as a bare page. A note's page made by `serve` stands in for the note.
    func open(_ file: URL) -> Bool {
        guard let model else { return false }
        let page: URL
        switch file.pathExtension.lowercased() {
        case "html", "htm": page = file
        case "md", "markdown": page = file.deletingPathExtension().appendingPathExtension("html")
        default: return false
        }
        guard FileManager.default.fileExists(atPath: page.path), let set = DecisionSet.load(besides: page) else { return false }
        model.openChatReport(path: page.path, title: set.title)
        return true
    }

    /// The center of the running app, for views that have no model at hand (`MarkdownProse`).
    static weak var current: DecisionCenter?

    // MARK: Publishing (`$IDIR/decide`)

    /// Puts a report with decisions into a chat: it shows there as the chat's report, on the Mac
    /// and on the phone.
    func publish(_ report: URL, to chatID: UUID) {
        guard let model else { return }
        var r = record(for: report)
        r.chatID = chatID
        store(r)
        model.conversations.addReport(report.path, to: chatID)
    }

    func attach(_ model: AppModel, stateDir: URL?) {
        self.model = model
        requests = stateDir?.appendingPathComponent("decision-requests", isDirectory: true)
        guard let requests else { return }
        try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        announce()
        timer = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                self?.drain()
                ticks += 1
                if ticks % 12 == 0 { self?.announce() }
            }
        }
    }

    func detach() {
        timer?.cancel()
        timer = nil
        if let requests { try? FileManager.default.removeItem(at: requests.appendingPathComponent("service.json")) }
    }

    private func announce() {
        guard let requests else { return }
        let payload: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "since": Int(Date().timeIntervalSince1970)]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: requests.appendingPathComponent("service.json"), options: .atomic)
        }
    }

    private func drain() {
        guard let requests, let names = try? FileManager.default.contentsOfDirectory(atPath: requests.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") && name != "service.json" {
            let id = String(name.dropLast(5))
            let done = requests.appendingPathComponent("\(id).done")
            guard !inFlight.contains(id), !FileManager.default.fileExists(atPath: done.path) else { continue }
            inFlight.insert(id)
            let answer = serve(requests.appendingPathComponent(name))
            if let data = try? JSONSerialization.data(withJSONObject: answer) { try? data.write(to: done, options: .atomic) }
            inFlight.remove(id)
        }
    }

    /// `{"path", "project"}`: a report (`.html`, or `.md` made into one) inside a project Bulava
    /// knows, with a sound `decisions.json` beside it, published to the chat of the run working in
    /// that project.
    func serve(_ request: URL) -> [String: Any] {
        guard let model, let data = try? Data(contentsOf: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["path"] as? String, let project = obj["project"] as? String else {
            return ["ok": false, "error": String(localized: "The request is not readable.")]
        }
        let folder = URL(fileURLWithPath: project).resolvingSymlinksInPath().standardizedFileURL
        let target = URL(fileURLWithPath: path, relativeTo: folder).standardizedFileURL.resolvingSymlinksInPath()
        guard ShareRules.inside(target, folder) else {
            return ["ok": false, "error": String(localized: "Only what is inside a project folder Bulava knows can be shared.")]
        }
        guard !target.path.dropFirst(folder.path.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            return ["ok": false, "error": String(localized: "Hidden files and folders are never shared.")]
        }
        let decisions = target.deletingLastPathComponent().appendingPathComponent(DecisionSet.fileName)
        guard let raw = try? Data(contentsOf: decisions) else {
            return ["ok": false, "error": "no \(DecisionSet.fileName) next to \(target.lastPathComponent)"]
        }
        if case .failure(let refusal) = DecisionSet.parse(raw) { return ["ok": false, "error": refusal.message] }
        let report: URL
        switch target.pathExtension.lowercased() {
        case "html", "htm":
            report = target
        case "md", "markdown":
            // A note made into a page next to it, so every viewer of reports can show it.
            report = target.deletingPathExtension().appendingPathExtension("html")
            let text = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
            let set = try? DecisionSet.parse(raw).get()
            try? MarkdownHTML.page(title: set?.title ?? target.lastPathComponent, markdown: text)
                .write(to: report, atomically: true, encoding: .utf8)
        default:
            return ["ok": false, "error": "a report with decisions is an .html or .md file"]
        }
        guard FileManager.default.fileExists(atPath: report.path) else {
            return ["ok": false, "error": String(localized: "There is nothing at that path to share.")]
        }
        guard let chat = runChat(in: folder, model: model) else {
            return ["ok": false, "error": String(localized: "No chat is working in that project now.")]
        }
        publish(report, to: chat.id)
        return ["ok": true, "chat": chat.title, "report": report.path]
    }

    /// The chat whose run is working in this project: the one a decision report goes back to.
    private func runChat(in project: URL, model: AppModel) -> Chat? {
        let path = Slug.canonicalPath(project.path)
        let running = model.snapshot.instances.filter { Slug.canonicalPath($0.projectPath) == path }
        return model.conversations.chats.first { chat in
            guard let binding = chat.session, let instance = model.matchingInstance(for: binding) else { return false }
            return running.contains { $0.slug == instance.slug }
        }
    }

    /// A chat that has this report among its reports.
    private func chat(holding report: URL) -> Chat? {
        model?.conversations.chats.first { $0.session?.reportPaths.contains(report.path) == true }
    }

    // MARK: Storage

    static func key(_ report: URL) -> String {
        SHA256.hash(data: Data(report.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ key: String) -> URL { folder.appendingPathComponent("\(key).json") }

    private func store(_ record: DecisionAnswerLog) {
        let key = Self.key(URL(fileURLWithPath: record.reportPath))
        records[key] = record
        version += 1
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: file(key), options: .atomic)
        }
    }
}
