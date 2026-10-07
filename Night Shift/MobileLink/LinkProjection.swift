import Foundation
import CryptoKit

/// What pressing a button on the phone does, once the Mac has checked the button is still real.
typealias LinkActionHandler = @MainActor (LinkJSON?) async -> LinkError?

/// One reading of the app, turned into what a phone is sent.
///
/// Built fresh every time something changes, and thrown away the next time. It carries three
/// things: the DTOs, the buttons those DTOs offer (`actions`), and the files they mention (`files`).
/// A button pressed on the phone is looked up in the NEWEST projection — so a request answered on
/// the Mac in the meantime is simply not there any more, and the phone is told "already handled"
/// instead of answering it a second time. A file is readable only if some projection mentioned it,
/// which is what keeps `file.read` from being a way to read anything on this disk.
@MainActor
struct LinkProjection {
    var home: HomeDTO
    var chats: [UUID: ChatDTO]
    var actions: [String: LinkActionHandler]
    var files: [String: URL]
    var reports: [String: LinkProjection.ReportTarget]

    struct ReportTarget {
        var task: BacklogTask?
        var chatReportPath: String?
        var title: String
        /// A piece of work with several streams: its one combined report.
        var workItemID: UUID? = nil
        /// A whole product: everything done so far.
        var productID: UUID? = nil
    }

    static let window = 60

    /// `live` is the stretch of work as `LiveTracker` tells it; the projection itself keeps no
    /// history, so it comes from the link.
    static func build(_ model: AppModel, desktop: LinkDesktop, openChats: Set<UUID>,
                      live: LiveDTO? = nil) -> LinkProjection {
        var b = Builder(model: model)
        var home = b.home(desktop: desktop)
        home.live = live
        var chats: [UUID: ChatDTO] = [:]
        for id in openChats {
            if let chat = b.chat(id) { chats[id] = chat }
        }
        return LinkProjection(home: home, chats: chats, actions: b.actions, files: b.files,
                              reports: b.reports)
    }

    /// The run control for one chat — its own models and depths — or, with none, the default.
    static func composer(_ model: AppModel, chatID: UUID?) -> ComposerOptionsDTO {
        Builder(model: model).composerOptions(for: chatID)
    }

    /// An older stretch of a chat, for scrolling back. The buttons it carries are registered in
    /// `into`, so they can be pressed like any other.
    static func earlier(_ model: AppModel, chatID: UUID, before: UUID?, limit: Int,
                        into projection: inout LinkProjection) -> (entries: [EntryDTO], hasEarlier: Bool) {
        var b = Builder(model: model)
        let all = b.visible(chatID)
        let end = before.flatMap { id in all.firstIndex { $0.id == id } } ?? all.count
        let start = max(0, end - max(1, min(limit, 200)))
        let slice = all[start..<end].compactMap { b.entry($0, chatID: chatID, readOnly: b.isArchived(chatID)) }
        projection.actions.merge(b.actions) { _, new in new }
        projection.files.merge(b.files) { _, new in new }
        projection.reports.merge(b.reports) { _, new in new }
        return (slice, start > 0)
    }
}

extension LinkProjection {
    static var staleError: LinkError { Builder.stale }

    static func localized(_ key: String) -> String { Builder.localized(key) }

    static func status(_ state: WorkState) -> StatusDTO { Builder.status(state) }

    /// Task cards built the way a chat builds its report cards, for places outside a chat.
    static func cards(_ tasks: [BacklogTask], model: AppModel)
        -> (cards: [CardDTO], actions: [String: LinkActionHandler], reports: [String: ReportTarget]) {
        var b = Builder(model: model)
        let cards = tasks.map { b.card($0, readOnly: false) }
        return (cards, b.actions, b.reports)
    }

    static func status(_ phase: DirectChatPhase) -> StatusDTO { Builder.status(phase) }

    /// What works by itself right now, by name — the lines of `HomeDTO.live` before a stretch's
    /// history is added to them.
    static func runningLines(_ model: AppModel) -> [LiveLineDTO] { Builder(model: model).runningLines() }

    /// How a line that stopped running stopped — finished, stopped on the director, failed — and
    /// the Mac's words for it.
    static func outcome(of line: LiveLineDTO, model: AppModel) -> (code: String, label: String?) {
        Builder(model: model).outcome(of: line)
    }

    /// The foot of the sidebar, for the phone: what `SidebarView.limits` shows of each engine the
    /// Mac has heard from, by the same rules — a window only once something is used or its reset is
    /// known, none after its reset has passed, dimmed when read over half an hour ago.
    static func limits(_ capacity: CapacitySnapshot, now: Date = Date()) -> LimitsDTO? {
        func pressure(_ used: Int) -> String {
            switch UsagePressure(usedPercent: Double(used)) {
            case .comfortable: "comfortable"
            case .tight: "tight"
            case .nearlyOut: "nearlyOut"
            }
        }
        func engine(_ name: String, _ usage: UsageSnapshot) -> EngineLimitsDTO? {
            guard usage.present else { return nil }
            var windows: [LimitWindowDTO] = []
            for (label, window) in [("Session", Optional(usage.fiveHour)), ("Weekly", usage.sevenDay)] {
                guard let window, let used = window.shownPercent(now: now) else { continue }
                windows.append(LimitWindowDTO(
                    label: localized(label), used: used,
                    usedLabel: String(format: localized("%lld%% used"), used), pressure: pressure(used),
                    resets: Fmt.resetsCompact(window.resetsAt)))
            }
            let stale = usage.isStale(now: now)
            let tightest = usage.tightestShown(now: now)
            return EngineLimitsDTO(
                name: name, used: tightest, pressure: pressure(tightest ?? 0), windows: windows,
                note: windows.isEmpty ? localized("Not known yet — it fills in when something runs") : nil,
                stale: stale, readAgo: stale ? usage.updatedAt.map(Fmt.ago) : nil)
        }
        let engines = [engine("Claude", capacity.claude), engine("Codex", capacity.codex)].compactMap { $0 }
        return engines.isEmpty ? nil : LimitsDTO(title: localized("Limits"), engines: engines)
    }

    /// An attachment as the phone sees it, readable through `into` from now on.
    static func fileDTO(for attachment: Attachment, model: AppModel,
                        into projection: inout LinkProjection) -> FileDTO {
        var b = Builder(model: model)
        let dto = b.attachment(attachment)
        projection.files.merge(b.files) { _, new in new }
        return dto
    }
}

// MARK: - Builder

@MainActor
private struct Builder {
    let model: AppModel
    var actions: [String: LinkActionHandler] = [:]
    var files: [String: URL] = [:]
    /// The folders each chat's answers name files in (`fileRoots`), read once per projection.
    var rootsByChat: [UUID: [URL]] = [:]
    var reports: [String: LinkProjection.ReportTarget] = [:]

    init(model: AppModel) { self.model = model }

    // MARK: Home

    mutating func home(desktop: LinkDesktop) -> HomeDTO {
        var products: [ProductDTO] = []
        var attention: [AttentionDTO] = []
        for product in model.products.sorted {
            let chats = model.conversations.chats(for: product.id).map { summary($0) }
            let archived = model.conversations.archivedChats(for: product.id).map { summary($0) }
            products.append(ProductDTO(
                id: product.id.uuidString, name: product.name, initials: product.initials,
                pinned: product.pinned, brief: product.brief, icon: icon(product),
                status: model.state(forProductID: product.id).map(Self.status),
                lastWorkedAtMs: product.lastWorkedAt.map(LinkCoding.ms),
                chats: chats, archivedChats: archived))
            attention += attentionItems(product)
        }
        attention += readinessAttention()
        attention += taskAsks()
        attention.sort { $0.atMs > $1.atMs }
        let done = finishedItems()
        let working = model.instances.filter { PowerKeeper.keepsAwake($0) }.count + model.codexTurns.count
        return HomeDTO(desktop: desktop, products: products, attention: attention,
                       composer: composerOptions(), readiness: readiness(), finished: done,
                       summary: SummaryDTO(working: working, waiting: attention.count, ready: done.count),
                       limits: LinkProjection.limits(model.capacity))
    }

    /// Every task whose report is in and waits for the director — the same ones the Mac's menu
    /// bar counts as "ready to read" — with the button that opens the report.
    mutating func finishedItems() -> [FinishedDTO] {
        var out: [FinishedDTO] = []
        for product in model.products.sorted {
            for task in model.openTasks(for: product.id) where task.state == .review {
                let target = "done.report:\(task.id.uuidString)"
                reports[target] = LinkProjection.ReportTarget(task: task, chatReportPath: nil, title: task.title)
                out.append(FinishedDTO(
                    id: "done:\(task.id.uuidString)", productID: product.id.uuidString,
                    chatID: task.chatID?.uuidString, title: task.title,
                    body: String(localized: "Report ready"), atMs: LinkCoding.ms(task.updatedAt),
                    report: ActionDTO(id: target, label: String(localized: "Open the report"),
                                      style: "primary", kind: "report", target: target)))
            }
        }
        return out.sorted { $0.atMs > $1.atMs }
    }

    // MARK: Working now

    /// Every chat whose answer is being written and every run going on by itself, newest first:
    /// the menu bar's "Working now", by the names the director gave them. A run that answers a
    /// chat is the chat's line, not a second one.
    func runningLines() -> [LiveLineDTO] {
        var out: [LiveLineDTO] = []
        for product in model.products.sorted {
            var listed = Set<UUID>()
            for chat in model.conversations.chats(for: product.id, includingAutomationRuns: true) {
                guard model.directPhase(for: chat.id).isActive || model.codexTurns[chat.id] != nil else { continue }
                listed.insert(chat.id)
                // The turn began with the director's last message; the chat itself may be months old.
                let asked = model.visibleEntries(inChat: chat.id).last(where: { $0.kind == .user })?.at
                out.append(LiveLineDTO(id: "chat:\(chat.id.uuidString)", productID: product.id.uuidString,
                                       chatID: chat.id.uuidString, title: chat.title, product: product.name,
                                       sinceMs: LinkCoding.ms(asked ?? chat.updatedAt), outcome: nil))
            }
            for task in model.openTasks(for: product.id) {
                if let chatID = task.chatID, listed.contains(chatID) { continue }
                guard let instance = model.liveInstance(for: task), PowerKeeper.keepsAwake(instance) else { continue }
                out.append(LiveLineDTO(id: "task:\(task.id.uuidString)", productID: product.id.uuidString,
                                       chatID: task.chatID?.uuidString, title: task.title, product: product.name,
                                       sinceMs: instance.startedAt.map(LinkCoding.ms), outcome: nil))
            }
        }
        return out.sorted { ($0.sinceMs ?? 0) > ($1.sinceMs ?? 0) }
    }

    func outcome(of line: LiveLineDTO) -> (code: String, label: String?) {
        let parts = line.id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return ("stopped", nil) }
        if parts[0] == "chat" {
            let phase = model.directPhase(for: id)
            let code: String
            if phase == .ready { code = "done" }
            else if phase.isFailure { code = "failed" }
            else if phase.wantsAttention { code = "attention" }
            else { code = "stopped" }
            return (code, phase.label)
        }
        guard let task = model.backlog.task(id: id) else { return ("stopped", nil) }
        let code: String
        switch task.state {
        case .review, .approved, .merged, .closed: code = "done"
        case .failed: code = "failed"
        case .blocked, .needsClarification: code = "attention"
        default: code = "stopped"
        }
        return (code, task.state == .review ? String(localized: "Report ready") : Self.localized(task.state.label))
    }

    func summary(_ chat: Chat) -> ChatSummaryDTO {
        ChatSummaryDTO(id: chat.id.uuidString, productID: chat.productID.uuidString,
                       title: chat.title, pinned: chat.pinned, archived: chat.archived,
                       createdAtMs: LinkCoding.ms(chat.createdAt),
                       updatedAtMs: LinkCoding.ms(chat.updatedAt),
                       status: Self.status(model.directPhase(for: chat.id)))
    }

    mutating func icon(_ product: Product) -> FileDTO? {
        guard let path = product.iconPath, FileManager.default.fileExists(atPath: path) else { return nil }
        let ref = "icon:\(product.id.uuidString)"
        files[ref] = URL(fileURLWithPath: path)
        return FileDTO(ref: ref, name: (path as NSString).lastPathComponent, kind: "image",
                       size: Self.size(of: URL(fileURLWithPath: path)), url: nil)
    }

    // MARK: Attention

    /// What is waiting for the director in one product: every chat that stopped on something, with
    /// the same buttons the chat itself offers.
    mutating func attentionItems(_ product: Product) -> [AttentionDTO] {
        var out: [AttentionDTO] = []
        for chat in model.conversations.chats(for: product.id, includingAutomationRuns: true) {
            let entries = visible(chat.id)
            var asked = false
            for entry in entries.suffix(LinkProjection.window) where entry.kind == .user {
                for ask in asks(for: entry, chatID: chat.id, readOnly: false) {
                    asked = true
                    out.append(AttentionDTO(
                        id: "ask:\(ask.id)", productID: product.id.uuidString,
                        chatID: chat.id.uuidString, kind: "ask", title: chat.title,
                        body: ask.title, tone: ask.tone, atMs: LinkCoding.ms(entry.at),
                        actions: ask.actions, code: ask.code))
                }
            }
            if let question = entries.last(where: { $0.kind == .question }),
               let dto = entry(question, chatID: chat.id, readOnly: false), let q = dto.question {
                asked = true
                out.append(AttentionDTO(
                    id: "question:\(question.id.uuidString)", productID: product.id.uuidString,
                    chatID: chat.id.uuidString, kind: "question", title: chat.title,
                    body: q.headline, tone: "attention", atMs: LinkCoding.ms(question.at), actions: []))
            }
            // A report that asks him to decide and has no answer to its questions as they are now.
            if !asked, let paths = chat.session?.reportPaths, let index = paths.indices.last {
                let report = URL(fileURLWithPath: paths[index])
                if let set = DecisionSet.load(besides: report),
                   model.decisions.record(for: report).latest?.revision != set.revision {
                    asked = true
                    let target = "chatReport:\(chat.id.uuidString):\(index)"
                    reports[target] = LinkProjection.ReportTarget(task: nil, chatReportPath: report.path, title: chat.title)
                    out.append(AttentionDTO(
                        id: "decide:\(chat.id.uuidString):\(set.revision)", productID: product.id.uuidString,
                        chatID: chat.id.uuidString, kind: "decide", title: chat.title,
                        body: String(format: String(localized: "“%@” waits for your decisions"), set.title),
                        tone: "attention", atMs: LinkCoding.ms(chat.updatedAt),
                        actions: [ActionDTO(id: target, label: String(localized: "Open the report"),
                                            style: "primary", kind: "report", target: target)]))
                }
            }
            let phase = model.directPhase(for: chat.id)
            if !asked, phase.wantsAttention {
                out.append(AttentionDTO(
                    id: "chat:\(chat.id.uuidString):\(Self.code(phase))",
                    productID: product.id.uuidString, chatID: chat.id.uuidString,
                    kind: phase.isFailure ? "failure" : "chat", title: chat.title,
                    body: phase.label, tone: phase.isFailure ? "problem" : "attention",
                    atMs: LinkCoding.ms(chat.updatedAt), actions: []))
            }
        }
        return out
    }

    mutating func readinessAttention() -> [AttentionDTO] {
        readiness().filter { $0.state == "problem" }.map { item in
            AttentionDTO(id: "readiness:\(item.id)", productID: "", chatID: nil, kind: "readiness",
                         title: item.title, body: item.detail, tone: "problem",
                         atMs: LinkCoding.ms(model.readiness.lastRun ?? Date()), actions: item.actions)
        }
    }

    // MARK: Readiness

    mutating func readiness() -> [ReadinessDTO] {
        model.readiness.checks.map { check in
            let state: String
            switch check.status {
            case .ready: state = "ready"
            case .checking: state = "checking"
            case .missing, .unknown: state = check.required ? "problem" : "attention"
            }
            var buttons: [ActionDTO] = []
            if check.status != .ready {
                buttons = fixActions(check)
            }
            return ReadinessDTO(id: check.id, title: Self.localized(check.titleKey),
                                detail: Self.localized(check.detailKey), state: state, actions: buttons)
        }
    }

    mutating func fixActions(_ check: PreflightCheck) -> [ActionDTO] {
        let id = "readiness:\(check.id)"
        switch check.fix {
        case .trustFolders(let folders)?:
            return [register(id, label: String(localized: "Trust the folders"), style: "primary") { model, _ in
                model.trustFolders(folders); return nil
            }]
        case .finishClaudeSetup?:
            return [register(id, label: String(localized: "Finish setup"), style: "primary") { model, _ in
                model.finishClaudeSetup(); return nil
            }]
        case .installEngine?:
            return [register(id, label: String(localized: "Install the engine"), style: "primary") { model, _ in
                await model.installEngine() ? nil
                    : LinkError(code: LinkErrorCode.failed,
                                message: String(localized: "The engine did not install. Open Bulava on your Mac to see why."))
            }]
        case .signIn?:
            return [Self.onMac(String(localized: "Sign in on your Mac"))]
        case .updateCodex?:
            // It runs in a Terminal on the Mac, where somebody can watch it — not from a pocket.
            return [Self.onMac(String(localized: "Update Codex on your Mac"))]
        case .askForScreenRecording?:
            return [Self.onMac(String(localized: "Allow it in System Settings on your Mac"))]
        case .brew?, .brewCask?, .revealInFinder?:
            return [Self.onMac(String(localized: "Finish this on your Mac"))]
        case nil:
            return check.settingsURL != nil
                ? [Self.onMac(String(localized: "Allow it in System Settings on your Mac"))]
                : []
        }
    }

    // MARK: Composer options

    /// The Mac composer's run control, for the phone: a page per engine in the order they work —
    /// Claude writes, Codex reviews — each with its model and its depth, worded the way the Mac's
    /// panel words them (`RunControl`), and `summary` saying what the pill says.
    ///
    /// Claude alone or Codex alone is not a choice the Mac offers at the moment — `RunControlPanel`
    /// has the mode switch commented out and `AppSettings` pins the pair — so it is not offered
    /// here either, and `settings.set` refuses it: a phone that could switch the mode would leave
    /// the Mac in one it has no control to leave.
    func composerOptions(for chatID: UUID? = nil) -> ComposerOptionsDTO {
        let s = model.settings
        // The models and depths are the chat's own; the mode is still one for the whole app.
        let r = model.runChoices(for: chatID)
        var groups: [OptionGroupDTO] = []
        if s.chatMode.usesClaude {
            let catalogue = model.claudeModels
            func family(_ choice: ClaudeModelChoice) -> String {
                let name = Self.localized(choice.label)
                return catalogue.versionName(for: choice).map { "\(name) · \($0)" } ?? name
            }
            let newest = Self.localized("Newest of each")
            let fixed = Self.localized("A fixed version")
            var claude = [OptionDTO(id: ClaudeModelChoice.auto.rawValue, label: family(.auto),
                                    detail: Self.localized(ClaudeModelChoice.auto.help))]
            claude += ClaudeModelChoice.families.map {
                OptionDTO(id: $0.rawValue, label: family($0), detail: Self.localized($0.help), section: newest)
            }
            claude += catalogue.models.map { OptionDTO(id: $0.id, label: $0.name, detail: nil, section: fixed) }
            if r.claudeModel.isPinnedVersion, !claude.contains(where: { $0.id == r.claudeModel.rawValue }) {
                claude.append(OptionDTO(id: r.claudeModel.rawValue, label: r.claudeModel.rawValue, detail: nil, section: fixed))
            }
            groups.append(OptionGroupDTO(id: "claudeModel", title: "Claude", options: claude,
                                         selected: r.claudeModel.rawValue, engine: Engine.claude.rawValue, kind: "model"))
            if catalogue.thinks(r.claudeModel) {
                groups.append(OptionGroupDTO(
                    id: "claudeEffort", title: String(localized: "Claude thinks"),
                    options: catalogue.levels(for: r.claudeModel).map {
                        // Automatic says which level it resolves to, as the panel's label does.
                        OptionDTO(id: $0.rawValue,
                                  label: $0 == .auto ? catalogue.depthLabel(.auto, for: r.claudeModel) : Self.localized($0.label),
                                  detail: Self.localized($0.help))
                    },
                    selected: r.claudeEffort.rawValue, engine: Engine.claude.rawValue, kind: "depth"))
            }
        }
        if s.chatMode.usesCodex {
            let catalogue = model.codexModels
            var codex = [OptionDTO(id: "", label: String(localized: "Automatic"), detail: nil)]
            codex += catalogue.models.map { OptionDTO(id: $0.slug, label: $0.shortLabel, detail: nil) }
            if !r.codexModel.isEmpty, !codex.contains(where: { $0.id == r.codexModel }) {
                codex.append(OptionDTO(id: r.codexModel, label: r.codexModel, detail: nil))
            }
            groups.append(OptionGroupDTO(id: "codexModel", title: "Codex", options: codex,
                                         selected: r.codexModel, engine: Engine.codex.rawValue, kind: "model"))
            let automatic = String(format: String(localized: "Automatic · %@"),
                                   String(localized: catalogue.automaticLevel(forSlug: r.codexModel).label))
            groups.append(OptionGroupDTO(
                id: "codexEffort", title: String(localized: "Codex thinks"),
                options: catalogue.levels(forSlug: r.codexModel).map {
                    OptionDTO(id: $0.rawValue, label: $0 == .auto ? automatic : Self.localized($0.label), detail: nil)
                },
                selected: r.codexEffort.rawValue, engine: Engine.codex.rawValue, kind: "depth"))
        }
        let summary = s.chatMode.engines.map { engine in
            let depth = RunChoice.depthName(engine, model, chatID)
            return RunPartDTO(engine: engine.rawValue, name: engine.name,
                              model: RunChoice.modelName(engine, model, chatID), depth: depth.isEmpty ? nil : depth)
        }
        return ComposerOptionsDTO(groups: groups, summary: summary)
    }

    // MARK: Chat

    func visible(_ chatID: UUID) -> [ConversationEntry] { model.visibleEntries(inChat: chatID) }

    func isArchived(_ chatID: UUID) -> Bool { model.conversations.chat(id: chatID)?.archived ?? false }

    mutating func chat(_ chatID: UUID) -> ChatDTO? {
        guard let chat = model.conversations.chat(id: chatID) else { return nil }
        let all = visible(chatID)
        let window = all.suffix(LinkProjection.window)
        let entries = window.compactMap { entry($0, chatID: chatID, readOnly: chat.archived) }
        let h = header(chat, hasEarlier: all.count > window.count)
        return ChatDTO(id: chat.id.uuidString, productID: chat.productID.uuidString,
                       title: h.title, archived: h.archived, status: h.status, activity: h.activity,
                       degradation: h.degradation, queueCount: h.queueCount, busy: h.busy,
                       entries: entries, hasEarlier: h.hasEarlier, actions: h.actions, composer: h.composer)
    }

    mutating func header(_ chat: Chat, hasEarlier: Bool) -> ChatHeaderDTO {
        let phase = model.directPhase(for: chat.id)
        let busy = model.isDirectChatBusy(chat.id)
        var buttons: [ActionDTO] = []
        if busy && !chat.archived {
            let chatID = chat.id
            buttons.append(register("stop:\(chat.id.uuidString)", label: String(localized: "Stop"),
                                    style: "secondary") { model, _ in
                model.stopDirectChat(chatID); return nil
            })
        }
        if !chat.archived, model.shouldOfferReport(for: chat.id) {
            let chatID = chat.id
            buttons.append(register("chatReport:\(chat.id.uuidString)",
                                    label: String(localized: "Make a report"), style: "secondary") { model, _ in
                model.generateChatReport(chatID: chatID); return nil
            })
        }
        for (index, path) in (chat.session?.reportPaths ?? []).enumerated().reversed().prefix(1) {
            let target = "chatReport:\(chat.id.uuidString):\(index)"
            reports[target] = LinkProjection.ReportTarget(task: nil, chatReportPath: path, title: chat.title)
            buttons.append(ActionDTO(id: target, label: String(localized: "Open the report"),
                                     style: "secondary", kind: "report", target: target))
        }
        let phaseActive = phase.isActive
        return ChatHeaderDTO(
            title: chat.title, archived: chat.archived, status: Self.status(phase),
            activity: phaseActive ? model.directActivity(for: chat.id)?.sentence : nil,
            degradation: phaseActive ? model.directDegradation(for: chat.id) : nil,
            queueCount: model.directQueueCount(for: chat.id), busy: busy,
            hasEarlier: hasEarlier, actions: buttons,
            // This chat's own model and depth: the Mac keeps them per chat, and its pill shows them.
            composer: composerOptions(for: chat.id))
    }

    // MARK: Entries

    mutating func entry(_ e: ConversationEntry, chatID: UUID, readOnly: Bool) -> EntryDTO? {
        let kind: String
        let author: String
        switch e.kind {
        case .user:     kind = "user";     author = String(localized: "You")
        case .foreman:  kind = "agent";    author = "Night Shift"
        case .codex:    kind = "codex";    author = "Codex"
        case .event:    kind = "event";    author = ""
        case .question: kind = "question"; author = "Night Shift"
        case .decision: kind = "decision"; author = ""
        case .report:   kind = "report";   author = ""
        case .task:     return nil
        }
        // An agent's answer names files; the phone gets them as things to open under it.
        let roots = e.kind == .foreman || e.kind == .codex ? roots(forChat: chatID, product: e.productID) : []
        var dto = EntryDTO(id: e.id.uuidString, kind: kind, atMs: LinkCoding.ms(e.at), author: author,
                           text: e.text, blocks: e.blocks.renderable.map { block($0, roots: roots, chatID: chatID) },
                           attachments: e.attachments.map { attachment($0) },
                           tone: e.tone.rawValue, delivery: nil, asks: [], actions: [],
                           question: nil, card: nil, finished: e.turnFinished)
        switch e.kind {
        case .user:
            dto.delivery = e.delivery.map { delivery($0, chatID: chatID) }
            if !readOnly {
                dto.asks = asks(for: e, chatID: chatID, readOnly: readOnly)
                dto.actions = userActions(e)
            }
        case .foreman:
            dto.explanation = explanation(e, readOnly: readOnly)
            if !readOnly, let proposalID = e.proposalID,
               let proposal = model.pendingProposals[e.productID], proposal.id == proposalID {
                dto.actions = proposalActions(proposal, productID: e.productID, chatID: chatID)
            }
        case .question:
            dto.question = question(e, chatID: chatID, readOnly: readOnly)
        case .report:
            if let taskID = e.taskID, let task = model.backlog.task(id: taskID) {
                dto.card = card(task, readOnly: readOnly)
            } else {
                return nil
            }
        default:
            break
        }
        return dto
    }

    /// The same offer `ExplainRow` makes under an answer: a short explanation first, the
    /// walk-through once the short one is there.
    mutating func explanation(_ e: ConversationEntry, readOnly: Bool) -> ExplanationDTO? {
        let state = model.explainState(turn: e)
        guard state.available || state.hasAnything else { return nil }
        var buttons: [ActionDTO] = []
        if !readOnly, state.available {
            let key = e.id.uuidString
            if state.brief == nil && state.stepByStep == nil {
                buttons.append(register("explain.brief:\(key)",
                                        label: state.briefRunning ? String(localized: "Working out what happened…")
                                                                  : String(localized: "Explain what happened"),
                                        style: "secondary",
                                        disabledReason: state.briefRunning ? String(localized: "Working out what happened…") : nil) { model, _ in
                    guard let live = model.conversations.entry(id: e.id) else { return Self.stale }
                    model.explain(turn: live, depth: .brief); return nil
                })
            } else if state.stepByStep == nil {
                buttons.append(register("explain.steps:\(key)",
                                        label: state.stepByStepRunning ? String(localized: "Going through it…")
                                                                       : String(localized: "Go through it step by step"),
                                        style: "secondary",
                                        disabledReason: state.stepByStepRunning ? String(localized: "Going through it…") : nil) { model, _ in
                    guard let live = model.conversations.entry(id: e.id) else { return Self.stale }
                    model.explain(turn: live, depth: .stepByStep); return nil
                })
            }
        }
        return ExplanationDTO(brief: state.brief?.text, stepByStep: state.stepByStep?.text,
                              running: state.isRunning, stale: state.stale, failure: state.failure,
                              actions: buttons)
    }

    func delivery(_ d: ConversationEntry.Delivery, chatID: UUID) -> DeliveryDTO {
        switch d {
        case .queued:
            let why = model.isDirectChatBusy(chatID)
                ? model.directWaitReason(for: chatID)
                : String(localized: "Not delivered to the worker yet")
            return DeliveryDTO(code: "queued", label: String(localized: "Queued up") + " · " + why)
        case .failed:
            return DeliveryDTO(code: "failed", label: String(localized: "Not delivered"))
        case .replaced:
            return DeliveryDTO(code: "replaced", label: String(localized: "Replaced — it had already been read"))
        }
    }

    mutating func userActions(_ e: ConversationEntry) -> [ActionDTO] {
        var out: [ActionDTO] = []
        let id = e.id
        if e.delivery == .failed {
            out.append(register("retry:\(id.uuidString)", label: String(localized: "Send again"),
                                style: "secondary") { model, _ in
                model.retryDirectMessage(entryID: id); return nil
            })
        }
        if e.delivery != .replaced, model.canTakeBack(entryID: id) {
            // Answered by `entry.takeBack`, which hands the words back to the PHONE's composer.
            out.append(ActionDTO(id: "takeBack:\(id.uuidString)",
                                 label: model.isDirectChatBusy(e.chatID)
                                    ? String(localized: "Stop and edit") : String(localized: "Edit"),
                                 style: "secondary", kind: "takeBack", target: id.uuidString))
        }
        return out
    }

    mutating func proposalActions(_ proposal: ForemanProposal, productID: UUID, chatID: UUID) -> [ActionDTO] {
        let key = proposal.id.uuidString
        return [
            register("proposal.yes:\(key)", label: String(localized: "Yes, do it"), style: "primary") { model, _ in
                guard let live = model.pendingProposals[productID], live.id == proposal.id else {
                    return Self.stale
                }
                model.pendingProposals[productID] = nil
                model.executeProposal(live)
                return nil
            },
            register("proposal.no:\(key)", label: String(localized: "Not now"), style: "secondary") { model, _ in
                guard model.pendingProposals[productID]?.id == proposal.id else { return Self.stale }
                model.pendingProposals[productID] = nil
                model.conversations.appendForeman("Гаразд, скасував — нічого не роблю.",
                                                  productID: productID, chatID: chatID)
                return nil
            },
        ]
    }

    // MARK: Asks under a message

    /// The rows the Mac shows under a message that did not go through, as the phone draws them.
    /// Each condition here is the one `MessageEntry` uses — see EntryViews.swift.
    mutating func asks(for e: ConversationEntry, chatID: UUID, readOnly: Bool) -> [AskDTO] {
        guard e.kind == .user else { return [] }
        var out: [AskDTO] = []
        let entryID = e.id
        let key = "\(chatID.uuidString):\(entryID.uuidString)"

        if e.delivery == .failed, let folder = model.trustBlocked[chatID] {
            out.append(AskDTO(
                id: "trust:\(key)", kind: "folderTrust", tone: "attention",
                title: String(localized: "Claude Code asks before working in a folder for the first time."),
                detail: nil, code: folder,
                actions: [register("trust:\(key)", label: String(localized: "Trust and send"), style: "primary") { model, _ in
                    guard model.trustBlocked[chatID] == folder else { return Self.stale }
                    model.trustFolder(folder, thenRetry: entryID, in: chatID); return nil
                }]))
        }
        if e.delivery == .failed, model.setupBlocked.contains(chatID) {
            out.append(AskDTO(
                id: "setup:\(key)", kind: "claudeSetup", tone: "attention",
                title: String(localized: "On its first start Claude Code waits for a colour theme to be picked, and a worker in the background cannot pick one."),
                detail: nil, code: nil,
                actions: [register("setup:\(key)", label: String(localized: "Finish setup and send"), style: "primary") { model, _ in
                    guard model.setupBlocked.contains(chatID) else { return Self.stale }
                    model.finishClaudeSetup(thenRetry: entryID, in: chatID); return nil
                }]))
        }
        if e.delivery == .failed, let folder = model.gitConsentBlocked[chatID] {
            out.append(AskDTO(
                id: "git:\(key)", kind: "gitConsent", tone: "attention",
                title: String(localized: "There is no git here, so a run would have no way back and nothing to show a review."),
                detail: nil, code: folder,
                actions: [register("git:\(key)", label: String(localized: "Create git and send"), style: "primary") { model, _ in
                    guard model.gitConsentBlocked[chatID] == folder else { return Self.stale }
                    model.allowGitIn(folder, thenRetry: entryID, in: chatID); return nil
                }]))
        }
        if e.delivery == .failed, let block = model.mcpBlocked[chatID], block.entryID == entryID {
            let fresh: @MainActor (AppModel) -> Bool = { $0.mcpBlocked[chatID]?.entryID == entryID }
            out.append(AskDTO(
                id: "mcp:\(key)", kind: "mcpServers", tone: "attention",
                title: String(localized: "This project brings its own MCP servers. Claude asks whether to enable them before it starts, and in the background nobody can answer. An MCP server can run code, so it is your call."),
                detail: nil, code: AppModel.mcpServerList(block.servers),
                actions: [
                    register("mcp.no:\(key)", label: String(localized: "Send without them"), style: "secondary") { model, _ in
                        guard fresh(model) else { return Self.stale }
                        model.answerMcp(enable: false, entryID: entryID, in: chatID); return nil
                    },
                    register("mcp.yes:\(key)", label: String(localized: "Enable and send"), style: "primary") { model, _ in
                        guard fresh(model) else { return Self.stale }
                        model.answerMcp(enable: true, entryID: entryID, in: chatID); return nil
                    },
                ]))
        }
        if e.delivery == .failed, let block = model.dirtyTreeBlocked[chatID], block.entryID == entryID {
            out.append(dirtyTreeAsk(block, key: key, chatID: chatID, entryID: entryID))
        }
        if e.delivery == .failed, let block = model.heavyFilesBlocked[chatID], block.entryID == entryID {
            out.append(heavyFilesAsk(block, key: key, chatID: chatID, entryID: entryID))
        }
        if e.delivery == .failed, let plan = model.handoffBlocked[chatID] {
            out.append(AskDTO(
                id: "handoff:\(key)", kind: "projectBusy", tone: "attention",
                title: String(localized: "One project, one run at a time. Stopping it ends whatever it is doing now."),
                detail: nil, code: plan.projectPath,
                actions: [register("handoff:\(key)",
                                   label: String(format: String(localized: "Stop “%@” and send"), plan.holderTitle),
                                   style: "primary",
                                   confirm: String(localized: "Stopping it ends whatever it is doing now.")) { model, _ in
                    guard model.handoffBlocked[chatID] == plan else { return Self.stale }
                    model.stopHolderAndRetry(entryID: entryID, in: chatID); return nil
                }]))
        }
        if e.delivery == .failed, let wall = e.codexWall {
            out.append(AskDTO(
                id: "codexOut:\(key)", kind: "codexUnavailable", tone: "attention",
                title: wall,
                detail: String(localized: "Nothing was sent to anybody else. Claude can take this one if you want it now."),
                code: nil,
                actions: [register("codexOut:\(key)", label: String(localized: "Answer with Claude"), style: "primary") { model, _ in
                    guard model.conversations.entry(id: entryID)?.codexWall != nil else { return Self.stale }
                    model.answerWithClaudeInstead(entryID: entryID, in: chatID); return nil
                }]))
        }
        if model.signInPromptEntryID(inChat: chatID) == entryID {
            // A login happens in a terminal on the Mac, and nothing a phone sends can do it.
            out.append(AskDTO(
                id: "signIn:\(key)", kind: "signIn", tone: "attention",
                title: String(localized: "Claude asked to be signed in again. It happens in a terminal — a login cannot be done for you."),
                detail: nil, code: "claude auth login",
                actions: [Self.onMac(String(localized: "Sign in on your Mac"))]))
        }
        return out
    }

    mutating func dirtyTreeAsk(_ block: AppModel.DirtyTreeBlock, key: String,
                               chatID: UUID, entryID: UUID) -> AskDTO {
        let tree = block.tree
        let fresh: @MainActor (AppModel) -> AppModel.DirtyTreeBlock? = {
            guard let live = $0.dirtyTreeBlocked[chatID], live.entryID == entryID else { return nil }
            return live
        }
        var listing = tree.files.prefix(8).map { "\($0.xy) \($0.path)" }.joined(separator: "\n")
        if tree.total > 8 { listing += "\n" + String(format: String(localized: "and %lld more"), tree.total - 8) }
        var buttons: [ActionDTO] = []
        if tree.keepPossible {
            buttons.append(register("dirty.leave:\(key)", label: String(localized: "Start, leave my changes"),
                                    style: "primary") { model, _ in
                guard fresh(model) != nil else { return Self.stale }
                model.leaveChangesAndSend(entryID: entryID, in: chatID); return nil
            })
        }
        buttons.append(register("dirty.commit:\(key)",
                                label: tree.unborn ? String(localized: "Make the first commit…")
                                                   : String(localized: "Commit as me…"),
                                style: tree.keepPossible ? "secondary" : "primary",
                                input: Self.commitSheet(tree, submit: String(localized: "Commit and send"))) { model, input in
            guard let live = fresh(model) else { return Self.stale }
            guard live.tree.author != nil else { return Self.noAuthor }
            let message = (input?["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                return LinkError(code: LinkErrorCode.badRequest, message: String(localized: "Write a commit message first."))
            }
            model.confirmCommitAsMe(AppModel.CommitAsMeRequest(target: .chat(entryID: entryID, chatID: chatID),
                                                               folder: live.folder, tree: live.tree),
                                    message: message)
            return nil
        })
        buttons.append(register("dirty.dismiss:\(key)", label: String(localized: "Not now"), style: "secondary") { model, _ in
            guard fresh(model) != nil else { return Self.stale }
            model.dismissDirtyTree(chatID: chatID); return nil
        })
        return AskDTO(
            id: "dirty:\(key)", kind: "uncommittedWork", tone: "attention",
            title: tree.unborn
                ? String(localized: "This repository has no commits yet, so a run has nothing to measure its work against. The first commit is yours.")
                : String(localized: "This folder has uncommitted changes. They are as you left them, and nothing was committed."),
            detail: block.problem.map(AppModel.firstLine) ?? Self.dirtyTreeHint(block), code: listing, actions: buttons)
    }

    /// The Mac's `HeavyFilesRow`: the headline, the files with their sizes, why a tracked file cannot
    /// be left out, and the same three answers.
    mutating func heavyFilesAsk(_ block: AppModel.HeavyFilesBlock, key: String,
                                chatID: UUID, entryID: UUID) -> AskDTO {
        let files = block.files
        let fresh: @MainActor (AppModel) -> Bool = {
            guard let live = $0.heavyFilesBlocked[chatID] else { return false }
            return live.entryID == entryID && !live.applying
        }
        var listing = files.files.prefix(8).map { file -> String in
            var line = "\(file.path) — \(Fmt.bytes(Int(file.size)))"
            if file.tracked { line += " · " + String(localized: "in git") }
            return line
        }.joined(separator: "\n")
        if files.files.count > 8 {
            listing += "\n" + String(format: String(localized: "and %lld more"), files.files.count - 8)
        }
        var buttons: [ActionDTO] = []
        if files.canLeaveOut {
            buttons.append(register("heavy.local:\(key)", label: String(localized: "Leave out of the checkpoint and send"),
                                    style: "primary") { model, _ in
                guard fresh(model) else { return Self.stale }
                model.leaveOutHeavyFiles(entryID: entryID, in: chatID, rule: .local); return nil
            })
            buttons.append(register("heavy.gitignore:\(key)", label: String(localized: "Add to .gitignore and send"),
                                    style: "secondary") { model, _ in
                guard fresh(model) else { return Self.stale }
                model.leaveOutHeavyFiles(entryID: entryID, in: chatID, rule: .gitignore); return nil
            })
        }
        buttons.append(register("heavy.dismiss:\(key)", label: String(localized: "Not now"), style: "secondary") { model, _ in
            guard model.heavyFilesBlocked[chatID]?.entryID == entryID else { return Self.stale }
            model.dismissHeavyFiles(chatID: chatID); return nil
        })
        let detail = block.problem
            ?? HeavyFilesRow.trackedNote(files)
            ?? (files.canLeaveOut
                ? String(localized: "Leaving them out changes nothing in the project: git just stops offering them for commits here.")
                : nil)
        return AskDTO(id: "heavy:\(key)", kind: "largeFiles", tone: "attention",
                      title: HeavyFilesRow.headline(files), detail: detail, code: listing, actions: buttons)
    }

    /// The row's second line on the Mac (`DirtyTreeRow`): the folder is watched, and what happens
    /// to the messages that stopped here.
    static func dirtyTreeHint(_ block: AppModel.DirtyTreeBlock) -> String {
        var hint = block.tree.unborn
            ? String(localized: "Make it here, or in your own tool: the message goes out once there is a commit.")
            : String(localized: "Pick an option, or commit or stash them yourself. The message goes out once the folder is clean.")
        if !block.waiting.isEmpty {
            hint += " " + String(localized: "Earlier messages that stopped here go out too, in the order you wrote them.")
        }
        return hint
    }

    /// «Commit as me…» as the Mac's `CommitAsMeSheet` has it: the director's name before they
    /// press, the message, the branch and every file the commit takes, and why it cannot be made
    /// when git does not know who they are.
    static func commitSheet(_ tree: DirtyTree, submit: String) -> ActionInputDTO {
        var above: [InputNoteDTO] = []
        if let author = tree.author {
            above.append(InputNoteDTO(text: String(format: String(localized: "Author: %@"), author)))
        }
        var below = [InputNoteDTO(text: tree.branch.isEmpty
                                        ? String(localized: "Everything below goes into one commit.")
                                        : String(format: String(localized: "Everything below goes into one commit on “%@”."), tree.branch),
                                  tone: "faint")]
        if tree.hasStagedSplit {
            below.append(InputNoteDTO(text: String(localized: "Some of it is staged and some is not. The commit takes all of it."),
                                      tone: "attention"))
        }
        var files = tree.files.map { "\(DirtyFileList.letter($0.kind))  \($0.path)" }.joined(separator: "\n")
        if tree.total > tree.files.count {
            files += "\n" + String(format: String(localized: "and %lld more"), tree.total - tree.files.count)
        }
        if !files.isEmpty { below.append(InputNoteDTO(text: files, mono: true)) }
        return ActionInputDTO(
            placeholder: String(localized: "Commit message"), required: true, value: tree.suggestedMessage,
            title: tree.unborn ? String(localized: "The first commit") : String(localized: "A commit in your name"),
            above: above, below: below, submit: submit,
            blocked: tree.author == nil
                ? String(localized: "Git does not know who you are here: user.name and user.email are not set. Set them, or start without committing.")
                : nil)
    }

    /// The Mac's sheet cannot make a commit git does not know the author of, and neither can this.
    static var noAuthor: LinkError {
        LinkError(code: LinkErrorCode.failed,
                  message: String(localized: "Git does not know who you are here: user.name and user.email are not set. Set them, or start without committing."))
    }

    // MARK: Asks a task card raised

    /// The questions a task met on its way to starting — uncommitted work, MCP servers, a folder with
    /// no git. A card has no row to put them under, so on the Mac each is a dialog; here each is an
    /// item that needs the director, with the dialog's own buttons, and a push when the phone is
    /// away. Answered on either side, it is gone from both.
    mutating func taskAsks() -> [AttentionDTO] {
        var out: [AttentionDTO] = []
        if let ask = model.dirtyTreeAsk { out.append(dirtyTaskAsk(ask)) }
        if let ask = model.mcpAsk { out.append(mcpTaskAsk(ask)) }
        if let ask = model.gitConsentAsk { out.append(gitTaskAsk(ask)) }
        return out
    }

    private func taskItem(_ id: String, task: BacklogTask, body: String, code: String?,
                          actions: [ActionDTO]) -> AttentionDTO {
        AttentionDTO(id: id, productID: model.productID(for: task)?.uuidString ?? "",
                     chatID: task.chatID?.uuidString, kind: "ask", title: task.title, body: body,
                     tone: "attention", atMs: LinkCoding.ms(task.updatedAt), actions: actions, code: code)
    }

    mutating func dirtyTaskAsk(_ ask: AppModel.DirtyTreeAsk) -> AttentionDTO {
        let key = ask.id.uuidString
        let tree = ask.tree
        let live: @MainActor (AppModel) -> Bool = { $0.dirtyTreeAsk?.id == ask.id }
        var buttons: [ActionDTO] = []
        if tree.keepPossible {
            buttons.append(register("task.dirty.leave:\(key)", label: String(localized: "Start, leave my changes"),
                                    style: "primary") { model, _ in
                guard live(model) else { return Self.stale }
                model.leaveChangesAndDispatch(ask); return nil
            })
        }
        buttons.append(register("task.dirty.commit:\(key)",
                                label: tree.unborn ? String(localized: "Make the first commit…")
                                                   : String(localized: "Commit as me…"),
                                style: tree.keepPossible ? "secondary" : "primary",
                                input: Self.commitSheet(tree, submit: String(localized: "Commit and start"))) { model, input in
            guard live(model) else { return Self.stale }
            guard tree.author != nil else { return Self.noAuthor }
            let message = (input?["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                return LinkError(code: LinkErrorCode.badRequest, message: String(localized: "Write a commit message first."))
            }
            model.dirtyTreeAsk = nil
            model.confirmCommitAsMe(AppModel.CommitAsMeRequest(target: .task(ask.task), folder: ask.folder, tree: tree),
                                    message: message)
            return nil
        })
        buttons.append(register("task.dirty.wait:\(key)", label: String(localized: "I’ll sort it out — start when it’s clean"),
                                style: "secondary") { model, _ in
            guard live(model) else { return Self.stale }
            model.dispatchWhenClean(ask); return nil
        })
        buttons.append(register("task.dirty.no:\(key)", label: String(localized: "Not now"), style: "secondary") { model, _ in
            guard live(model) else { return Self.stale }
            model.dirtyTreeAsk = nil; return nil
        })
        return taskItem("task.dirty:\(key)", task: ask.task,
                        body: String(format: String(localized: "“%@” did not start: the folder has uncommitted changes. Nothing was committed."),
                                     ask.task.title),
                        code: DirtyTreePrompts.fileSummary(tree), actions: buttons)
    }

    mutating func mcpTaskAsk(_ ask: AppModel.McpAsk) -> AttentionDTO {
        let key = ask.id.uuidString
        let live: @MainActor (AppModel) -> Bool = { $0.mcpAsk?.id == ask.id }
        let buttons = [
            register("task.mcp.yes:\(key)", label: String(localized: "Enable them and start"), style: "primary") { model, _ in
                guard live(model) else { return Self.stale }
                model.answerMcpAndDispatch(ask, enable: true); return nil
            },
            register("task.mcp.no:\(key)", label: String(localized: "Start without them"), style: "secondary") { model, _ in
                guard live(model) else { return Self.stale }
                model.answerMcpAndDispatch(ask, enable: false); return nil
            },
            register("task.mcp.later:\(key)", label: String(localized: "Not now"), style: "secondary") { model, _ in
                guard live(model) else { return Self.stale }
                model.mcpAsk = nil; return nil
            },
        ]
        return taskItem("task.mcp:\(key)", task: ask.task,
                        body: String(format: String(localized: "“%@” did not start: the project brings MCP servers Claude has to ask about, and an MCP server can run code."),
                                     ask.task.title),
                        code: AppModel.mcpServerList(ask.servers, limit: 8), actions: buttons)
    }

    mutating func gitTaskAsk(_ ask: AppModel.GitConsentAsk) -> AttentionDTO {
        let key = ask.id.uuidString
        let live: @MainActor (AppModel) -> Bool = { $0.gitConsentAsk?.id == ask.id }
        let buttons = [
            register("task.git.yes:\(key)", label: String(localized: "Create git and start the task"), style: "primary") { model, _ in
                guard live(model) else { return Self.stale }
                model.allowGitAndDispatch(ask); return nil
            },
            register("task.git.no:\(key)", label: String(localized: "Not now"), style: "secondary") { model, _ in
                guard live(model) else { return Self.stale }
                model.gitConsentAsk = nil; return nil
            },
        ]
        return taskItem("task.git:\(key)", task: ask.task,
                        body: String(localized: "There is no git here, so a run would have no way back and nothing to show a review."),
                        code: ask.folder, actions: buttons)
    }

    // MARK: Questions

    func question(_ e: ConversationEntry, chatID: UUID, readOnly: Bool) -> QuestionDTO? {
        let task = e.taskID.flatMap { model.backlog.task(id: $0) }
        let instance = task.flatMap { model.questionInstance(for: $0) }
        guard let decision = e.decision ?? instance?.pendingQuestion?.record else {
            return QuestionDTO(eyebrow: String(localized: "Needs your answer"), headline: e.text,
                               situation: nil, recommendation: nil, ifUnanswered: nil, unblocks: nil,
                               items: [], answerable: !readOnly)
        }
        let eyebrow = decision.gateLabelKey.map(Self.localized) ?? String(localized: "Needs your answer")
        return QuestionDTO(
            eyebrow: eyebrow, headline: decision.headline.isEmpty ? e.text : decision.headline,
            situation: decision.situation, recommendation: decision.recommendation,
            ifUnanswered: decision.defaultAction, unblocks: decision.unblockAction,
            items: decision.items.map { item in
                QuestionItemDTO(question: item.question, header: item.header,
                                options: item.options.map {
                                    OptionDTO(id: $0, label: $0, detail: item.optionDescriptions?[$0])
                                },
                                multiSelect: item.multiSelect)
            },
            answerable: !readOnly)
    }

    // MARK: Cards

    /// A report card, with the buttons `ReportCard` shows. Buttons that only make sense at the desk
    /// — they open a window or prime the Mac's composer — become their phone equivalents here, by id.
    mutating func card(_ task: BacklogTask, readOnly: Bool) -> CardDTO {
        let state = model.workState(of: task)
        var buttons: [ActionDTO] = []
        if !readOnly {
            for action in TaskPresentation.cardActions(for: task, model: model) {
                let style = action.emphasis == .primary ? "primary" : action.emphasis == .danger ? "destructive" : "secondary"
                let id = "card.\(action.id):\(task.id.uuidString)"
                switch action.id {
                case "report", "read":
                    reports[id] = LinkProjection.ReportTarget(task: task, chatReportPath: nil, title: task.title)
                    buttons.append(ActionDTO(id: id, label: action.title, style: style, kind: "report",
                                             target: id, disabledReason: action.disabledReason))
                case "changes", "instruct", "followup":
                    buttons.append(ActionDTO(id: id, label: action.title, style: style, kind: "compose",
                                             input: ActionInputDTO(placeholder: action.title, required: true),
                                             disabledReason: action.disabledReason))
                case "trail", "open":
                    continue
                default:
                    let perform = action.perform
                    let taskID = task.id
                    let seen = state
                    buttons.append(register(id, label: action.title, style: style,
                                            confirm: action.emphasis == .danger ? action.title : nil,
                                            disabledReason: action.disabledReason) { model, _ in
                        guard let live = model.backlog.task(id: taskID), model.workState(of: live) == seen else {
                            return Self.stale
                        }
                        perform(model); return nil
                    })
                }
            }
        }
        return CardDTO(id: task.id.uuidString, title: task.title,
                       subtitle: TaskPresentation.subtitle(for: task, model: model),
                       status: Self.status(state), actions: buttons)
    }

    // MARK: Blocks and files

    mutating func roots(forChat chatID: UUID, product: UUID) -> [URL] {
        if let known = rootsByChat[chatID] { return known }
        let roots = model.fileRoots(forProductID: product, chatID: chatID)
        rootsByChat[chatID] = roots
        return roots
    }

    mutating func block(_ b: ConversationBlock, roots: [URL] = [], chatID: UUID? = nil) -> BlockDTO {
        let kind: String
        switch b.kind {
        case .markdown: kind = "markdown"
        case .activity: kind = "activity"
        case .consult:  kind = "consult"
        case .file:     kind = "file"
        case .gallery:  kind = "gallery"
        case .error:    kind = "error"
        case .unknown:  kind = "unknown"
        }
        var activity: ActivityDTO?
        if let a = b.activity {
            let verb = Self.localized(a.verbKey)
            let sentence = verb.contains("%@") ? String(format: verb, a.object ?? "")
                : [verb, a.object].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            activity = ActivityDTO(sentence: sentence, status: a.status.rawValue, detail: a.detail)
        }
        var links: [FileDTO]?
        if b.kind == .markdown, let chatID, !roots.isEmpty {
            let named = FilePathLinks.files(in: b.text, roots: roots)
            if !named.isEmpty { links = named.map { link($0, chatID: chatID) } }
        }
        return BlockDTO(id: b.id, kind: kind, text: b.text, activity: activity,
                        files: b.artifacts.map { artifact($0) }, links: links)
    }

    /// A file an answer names, as something the phone can open (`file.open`). Its ref carries the
    /// chat, so the Mac reads that chat's folders again when it is opened, and the path only as a
    /// digest: the phone never learns where on the disk it is.
    mutating func link(_ url: URL, chatID: UUID) -> FileDTO {
        let digest = SHA256.hash(data: Data(url.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let ref = "lnk:\(chatID.uuidString):\(digest)"
        files[ref] = url
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let name = isDirectory.boolValue ? url.lastPathComponent + "/" : url.lastPathComponent
        let kind = isDirectory.boolValue ? "document" : ArtifactRef.Kind.of(url.lastPathComponent).rawValue
        return FileDTO(ref: ref, name: name, kind: kind, size: isDirectory.boolValue ? nil : Self.size(of: url), url: nil)
    }

    mutating func artifact(_ a: ArtifactRef) -> FileDTO {
        let ref = "art:\(a.runID)/\(a.relativePath)"
        let url = a.resolve(base: model.artifactBase)
        if let url { files[ref] = url }
        return FileDTO(ref: url == nil ? nil : ref, name: a.displayName, kind: a.kind.rawValue,
                       size: a.byteSize.map(Int64.init) ?? url.flatMap(Self.size), url: nil)
    }

    mutating func attachment(_ a: Attachment) -> FileDTO {
        let kind: String
        switch a.kind {
        case .image: kind = "image"
        case .audio: kind = "audio"
        case .file:  kind = "document"
        case .link:  kind = "link"
        }
        let ref = "att:\(a.id.uuidString)"
        let url = model.capture.url(for: a)
        if let url { files[ref] = url }
        return FileDTO(ref: url == nil ? nil : ref, name: a.filename, kind: kind,
                       size: url.flatMap(Self.size), url: a.urlString)
    }

    // MARK: Registration

    mutating func register(_ id: String, label: String, style: String, confirm: String? = nil,
                           input: ActionInputDTO? = nil, disabledReason: String? = nil,
                           _ handler: @escaping @MainActor (AppModel, LinkJSON?) async -> LinkError?) -> ActionDTO {
        let model = model
        actions[id] = { [weak model] input in
            guard let model else { return Self.stale }
            return await handler(model, input)
        }
        return ActionDTO(id: id, label: label, style: style, kind: "invoke", confirm: confirm,
                         input: input, disabledReason: disabledReason)
    }

    static func onMac(_ label: String) -> ActionDTO {
        ActionDTO(id: "mac", label: label, style: "secondary", kind: "mac")
    }

    static var stale: LinkError {
        LinkError(code: LinkErrorCode.stale,
                  message: String(localized: "This was already handled on your Mac."))
    }

    // MARK: Status words

    static func code(_ phase: DirectChatPhase) -> String {
        switch phase {
        case .new: "new"
        case .starting: "starting"
        case .preparing: "preparing"
        case .queued: "queued"
        case .waitingForLimit: "waitingForLimit"
        case .waitingForCodex: "waitingForCodex"
        case .engineMismatch: "engineMismatch"
        case .restartingFrozen: "restartingFrozen"
        case .frozen: "frozen"
        case .working: "working"
        case .verifying: "verifying"
        case .reviewing: "reviewing"
        case .auditing: "auditing"
        case .needsAttention: "needsAttention"
        case .needsReview: "needsReview"
        case .ready: "ready"
        case .resumable: "resumable"
        case .reviving: "reviving"
        case .revivalFailed: "revivalFailed"
        case .failed: "failed"
        }
    }

    static func status(_ phase: DirectChatPhase) -> StatusDTO {
        let tone: String
        if phase.isFailure { tone = "problem" }
        else if phase.wantsAttention { tone = "attention" }
        else if phase.isActive { tone = "active" }
        else if phase == .ready { tone = "good" }
        else { tone = "neutral" }
        return StatusDTO(code: code(phase), label: phase.label, tone: tone, active: phase.isActive)
    }

    static func status(_ state: WorkState) -> StatusDTO {
        let tone: String
        switch state {
        case .needsAnswer, .stopped, .partial: tone = "attention"
        case .failed: tone = "problem"
        case .running: tone = "active"
        case .reportReady, .done: tone = "good"
        case .planned, .paused: tone = "neutral"
        }
        return StatusDTO(code: state.rawValue, label: localized(state.labelKey), tone: tone,
                         active: state == .running)
    }

    static func localized(_ key: String) -> String {
        LanguageBundle.current.localizedString(forKey: key, value: key, table: nil)
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
