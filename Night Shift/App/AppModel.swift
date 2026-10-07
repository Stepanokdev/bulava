import SwiftUI
import OSLog
import Observation

@MainActor
@Observable
final class AppModel {
    /// True while the engine is being copied out of the app and installing itself, so the
    /// readiness screen can say so instead of looking like nothing happened.
    var installingEngine = false
    /// What holds the engine while it needs replacing, when the app can name it. The readiness
    /// screen turns this into a way out instead of a second wall.
    var engineBlocker: EngineBusy.Blocker?
    var stoppingForEngine = false

    var settings: AppSettings {
        didSet {
            settings.save()
            if settings.appearance != oldValue.appearance { settings.appearance.apply() }

            if settings.workersMayDriveApps != oldValue.workersMayDriveApps {
                uiControl?.enabled = settings.workersMayDriveApps
                uiControl?.announce()
            }
            if settings.shareLinksEnabled != oldValue.shareLinksEnabled {
                shares.setEnabled(settings.shareLinksEnabled)
            }
            if settings.accountBrowserEnabled != oldValue.accountBrowserEnabled {
                browser.setEnabled(settings.accountBrowserEnabled)
            }
            if settings.interfaceLanguage != oldValue.interfaceLanguage {
                LanguageBundle.adopt(settings.interfaceLanguage)
                LanguageBundle.relaunch(to: settings.interfaceLanguage)
            }
            let paths = settings.paths
            let askEnabled = settings.askUserEnabled
            let askWait = settings.askUserWaitMinutes * 60
            Task {
                await client.updatePaths(paths)
                await client.writeAskUserConfig(enabled: askEnabled, waitSeconds: askWait)
                // The engine refuses a decision it cannot verify, so the public half has to be
                // where it looks before the first question is ever asked.
                DecisionSigner.publishPublicKey(stateDir: paths.stateDir)
            }
        }
    }
    var route: Route = .products {
        didSet {
            guard route != oldValue else { return }
            if let id = route.productID { products.touch(id) }

            composerIntent = .newTask
        }
    }

    private(set) var backStack: [Route] = []
    private(set) var forwardStack: [Route] = []
    private static let historyDepth = 20

    func navigate(to destination: Route) {
        guard route != destination else { return }
        backStack.append(route)
        if backStack.count > Self.historyDepth { backStack.removeFirst() }
        forwardStack.removeAll()
        withAnimation(Motion.standard) { route = destination }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(route)
        withAnimation(Motion.standard) { route = previous }
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(route)
        withAnimation(Motion.standard) { route = next }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    var inspectorShown = false
    var sidebarVisibility: NavigationSplitViewVisibility = .all

    // MARK: Pipelines

    /// What each open chat's latest run is doing, as the engine's journal tells it. Kept fresh only
    /// for chats somebody is looking at (`watchChatRun`).
    var chatRuns: [UUID: ChatRun] = [:]
    var pipelineLibrary: [PipelineSummary] = []
    var pipelineRegistry: PipelineRegistry?
    /// Size and date of the journal last read for a chat: an unchanged file is not parsed again.
    @ObservationIgnored var chatRunStamps: [UUID: String] = [:]
    /// The description each run was compiled from, by its snapshot folder. A run never changes it.
    @ObservationIgnored var runDocuments: [String: PipelineDocument] = [:]
    /// The conversation about each pipeline in its editor, kept while the app runs.
    @ObservationIgnored var pipelineChatSessions: [String: PipelineChatSession] = [:]
    /// What he asked for when he created a pipeline from a description; its editor sends it first.
    var pendingPipelineRequests: [String: String] = [:]

    // MARK: Composer

    var composerIntent: ComposerIntent = .newTask

    var composerFocusRequest = UUID()

    var composerAttachments: [UUID: [Attachment]] = [:]

    var conversationTarget: UUID?

    var searchPresented = false

    // MARK: Find in the open conversation
    //
    // Only the triggers live here. The session itself — the phrase, the results, where the reader
    // is among them — belongs to `ConversationView`, together with the scrolling and the focus it
    // has to drive; it must die with the conversation it was searching. But a `CommandGroup`
    // cannot see a view's state, so ⌘F and ⌘G reach it by pulsing these.

    var findOpenRequest = UUID()
    var findNextRequest = UUID()
    var findPreviousRequest = UUID()

    /// Set by the conversation while its find bar is up, so Find Next and Find Previous are not
    /// offered when there is nothing to walk.
    var findBarOpen = false

    /// Whether there is an open conversation to search at all.
    ///
    /// A report or a gallery covers the thread entirely, and the palette and the sheets take the
    /// keyboard; opening a find bar over a thread nobody can see would be a search of nothing.
    var conversationFindReachable: Bool {
        route.productID != nil
            && selectedProduct != nil
            && !fullScreenSurfacePresented
            && !searchPresented
            && productSheet == nil
            && taskDetailID == nil
            && renamingProductID == nil
            && renamingChatID == nil
            && webPreview == nil
    }

    var productSheet: ProductSheetMode?

    var renamingProductID: UUID?

    var renamingChatID: UUID?

    var taskDetailID: UUID?

    var variantGalleryItemID: UUID?

    var taskDetail: BacklogTask? { taskDetailID.flatMap { backlog.task(id: $0) } }
    func openTaskDetail(_ task: BacklogTask) { taskDetailID = task.id }

    private(set) var snapshot = SupervisorSnapshot()
    private(set) var loadedOnce = false

    /// The cards in the top-right corner, oldest first. `toast` (Toasts.swift) posts one.
    var toasts: [ToastMessage] = []

    /// Products holding a folder that turned out to be a workspace, found when the product was
    /// opened. Keyed by resource id, because that is what the offer to fix it acts on.
    var workspaceResources: [UUID: FolderConnection] = [:]

    var busy = false

    var pendingProposals: [UUID: ForemanProposal] = [:]

    var pendingProposal: ForemanProposal? {
        get { selectedProductID.flatMap { pendingProposals[$0] } }
        set {
            guard let id = selectedProductID else { return }
            if let newValue { pendingProposals[id] = newValue } else { pendingProposals[id] = nil }
        }
    }

    private var rounds = ForemanRounds()

    @discardableResult
    func bumpForemanGen(_ productID: UUID) -> Int { rounds.bump(productID) }

    func isCurrentForemanGen(_ gen: Int, _ productID: UUID) -> Bool { rounds.isCurrent(gen, productID) }

    func foremanGen(_ productID: UUID) -> Int { rounds.current(productID) }

    var launchFailures: [UUID: Date] = [:]

    private static let launchCooldown: TimeInterval = 600
    func recentlyFailedToLaunch(_ taskID: UUID) -> Bool {
        guard let at = launchFailures[taskID] else { return false }
        return Date().timeIntervalSince(at) < Self.launchCooldown
    }

    var verifiedEvidence: [UUID: Evidence] = [:]
    var verifying: Set<UUID> = []

    var reportPaths: [UUID: String] = [:]

    private(set) var screenshots: CaptureService?

    /// Drives other apps' interfaces on a worker's behalf. The second half of the same idea as
    /// `screenshots`: macOS trusts THIS process, so this process does the privileged thing and
    /// the worker only asks for it. See `UIControlService`.
    private(set) var uiControl: UIControlService?
    /// What is shared with the phone over the home Wi-Fi: agents' links and files opened from a chat.
    let shares = ShareCenter()
    /// Reports that ask him to decide, and what he answered — on the Mac and from the phone.
    let decisions = DecisionCenter()
    /// Bulava's own Chrome, signed in to once and lent to one run at a time.
    let browser = AccountBrowser()
    var generatingReport: Set<UUID> = []

    struct ReportViewer: Equatable {

        var taskID: UUID?
        var itemID: UUID? = nil
        var title: String
        var htmlURL: URL
        var isVideo: Bool
    }
    var reportViewer: ReportViewer?
    private(set) var preparingReport: Set<UUID> = []

    func openReport(_ task: BacklogTask) {
        guard !preparingReport.contains(task.id) else { return }
        preparingReport.insert(task.id)
        let key = task.reportKey, title = task.title
        Task {
            let url = await client.renderReport(task8: key, fallbackTitle: title)
            let manifest = await client.reportManifest(task8: key)
            preparingReport.remove(task.id)
            if let url {
                reportViewer = ReportViewer(taskID: task.id, title: title, htmlURL: url,
                                            isVideo: manifest?.format == .video)
            } else {
                toast = ToastMessage(text: String(localized: "No report for this task yet"), kind: .info)
            }
        }
    }
    func closeReport() { reportViewer = nil }

    var fullScreenSurfacePresented: Bool { reportViewer != nil || variantGalleryItemID != nil }

    func markPreparing(_ id: UUID) { preparingReport.insert(id) }
    func clearPreparing(_ id: UUID) { preparingReport.remove(id) }

    func reportManifest(for task: BacklogTask) async -> ReportManifest? {
        await client.reportManifest(task8: task.reportKey)
    }

    let client: SupervisorClient

    let products = ProductsStore()
    let conversations = ConversationStore()

    // MARK: Explaining a result

    let explanations = ExplanationStore()

    /// Records with an explanation being written right now, keyed the same way the store is.
    ///
    /// Keyed by RECORD and depth rather than by chat, unlike `generatingChatReportIDs`: keyed by
    /// chat, explaining one answer would lock every other answer in the same conversation, and a
    /// night task and the turn above it could not be read at the same time.
    private(set) var explainInFlight: Set<String> = []

    /// Why the last attempt on a record came to nothing, in words worth showing. Cleared on the
    /// next attempt, so a refusal is never permanent.
    private(set) var explainErrors: [String: String] = [:]

    func beginExplaining(_ key: String) { explainInFlight.insert(key); explainErrors[key] = nil }
    func endExplaining(_ key: String) { explainInFlight.remove(key) }
    func failExplaining(_ key: String, _ reason: String) { explainErrors[key] = reason }

    let icons = ProductIcons()

    let workItems = WorkItemStore()
    let projects = ProjectsStore()
    let capture = CaptureStore()
    let backlog = BacklogStore()

    let events = EventLog()

    /// The phone link: pairing, the paired phones, and the server they talk to. See `MobileLink`.
    let mobileLink = MobileLink()

    /// Keeps the Mac awake while work goes on without the director. See `PowerKeeper`.
    let power = PowerKeeper()
    /// Whether the Mac is on its battery, as of the last refresh — for saying so before a night.
    var runningOnBattery = false

    let foremanSessions = ForemanSessions()

    // MARK: Automations

    let automations = AutomationStore()
    /// Runs whose copy and conversation are being made right now.
    var automationPreparing: Set<UUID> = []
    /// Automations whose watch is out looking.
    var automationChecking: Set<UUID> = []
    var lastCopySweep: Date?
    var sweepingCopies = false
    @ObservationIgnored var folderWatchers: [UUID: FolderWatcher] = [:]
    /// A watched folder changed and has not been looked at since.
    var folderChangedAt: [UUID: Date] = [:]
    /// Copies something is being done with: a merge, a removal.
    var copyOperations: Set<UUID> = []
    /// The automation form, when it is opened from somewhere other than the automations screens —
    /// a conversation he wants to happen again by itself.
    var automationEditor: AutomationEditorRequest?
    /// Chats whose copy is being made by their first message.
    @ObservationIgnored var chatCopyMaking: [UUID: Task<Result<WorkCopy, ChatCopyRefusal>, Never>] = [:]
    /// Where a run's brief goes. The conversation's own send, unless a test is listening instead —
    /// the real one starts an engine.
    @ObservationIgnored var sendAutomationBrief: (@MainActor (_ message: String, _ productID: UUID,
                                                               _ chatID: UUID, _ entryID: UUID) -> Void)?
    /// Readying a copy for unattended work writes his Claude config and the engine's MCP record.
    /// A test stands in here so it never writes to the real ones.
    @ObservationIgnored var readyCopyOverride: (@MainActor (WorkCopy) async -> Void)?

    var artifactBase: URL { settings.paths.reportsDir }

    var foremanLiveEnabled: Bool { settings.foremanLive && claudeAvailable }

    var foremanBriefed: Set<ForemanSession.Key> = []

    var foremanTurnEntries: [ForemanSession.Key: [UUID]] = [:]

    var foremanSendChain: [ForemanSession.Key: Task<Void, Never>] = [:]

    var foremanApplyChain: [ForemanSession.Key: Task<Void, Never>] = [:]

    var foremanCheckpoint: [ForemanSession.Key: Date] = [:]

    private(set) var claudeAvailable = false

    private var loop: Task<Void, Never>?
    private var tick = 0

    init() {
        let s = AppSettings.load()
        settings = s

        LanguageBundle.adopt(s.interfaceLanguage)
        client = SupervisorClient(paths: s.paths)

        Trace.destination = s.paths.stateDir

        products.adoptProjectsIfNeeded(from: projects)

        products.clearGeneratedSummariesOnce()

        clearFindingsFromTheFeed()

        backlog.stripRunLabelPrefixes()

        backlog.adoptRealRunCards { [products, projects] path in
            guard let project = projects.project(path: path),
                  let product = products.products.first(where: { $0.allProjectIDs.contains(project.id) })
            else { return nil }
            return (product.id, project.name)
        }

        _ = conversations.dropDeadAnchors(
            known: Set(backlog.tasks.map(\.id)).union(workItems.items.map(\.id)))
        // Cards aimed at a copy that is not on disk any more — removed by hand or by a cleanup —
        // stop aiming there; the path stays in their history for the transcripts filed under it.
        backlog.retireDeadWorktrees()
        let ghosts = backlog.removeGhostRunCards()
        if !ghosts.isEmpty {

            note(.taskStateChanged, .info,
                 "Прибрав \(ghosts.count) зайвих карток прогонів "
                 + "(другі копії того самого прогону, ізольовані копії або зниклі теки).")
        }
        conversations.repairEnglishOutcomeLeaks()

        if let last = products.lastVisited ?? products.sorted.first {
            route = .product(last.id)
        }
    }

    // MARK: Lifecycle

    private var testDrive: TestDrive?

    /// Whether `start()` has run. It is called from the main window's `.task`, and a window is not
    /// the app: closing the window and opening it again, or a second one appearing, ran the whole
    /// start again — a second poll loop beside the first, a second capture service and control
    /// socket, the readiness screen re-opened. Starting is something the app does once.
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        settings.appearance.apply()

        // A state directory that no longer exists was corrected on load; this is where the
        // correction reaches disk. See `AppSettings.storedStateDirPath()` for why it cannot
        // happen during init.
        if AppSettings.storedStateDirPath() != settings.stateDirPath {
            settings.save()
        }

        screenshots = CaptureService(stateDir: settings.paths.stateDir)
        screenshots?.start()
        uiControl = UIControlService(stateDir: settings.paths.stateDir)
        uiControl?.enabled = settings.workersMayDriveApps
        uiControl?.start()
        // Not in the test host: a test that wants a share server starts its own.
        if NSClassFromString("XCTestCase") == nil {
            shares.attach(self, enabled: settings.shareLinksEnabled, stateDir: settings.paths.stateDir)
            ShareCenter.current = shares
            decisions.attach(self, stateDir: settings.paths.stateDir)
            DecisionCenter.current = decisions
            browser.attach(self, enabled: settings.accountBrowserEnabled, stateDir: settings.paths.stateDir)
        }
        if let drive = TestDrive.make() { testDrive = drive; drive.start(self) }
        // Reports a quit or a lost connection kept from going out last time, and any repair a
        // crash left running in somebody's folder.
        flushIncidentReports()
        sweepOrphanedRepairs()
        // His phone is paired with his Bulava. A Dev build answering it, or pushing to it, would
        // be a second desktop he never paired.
        if AppChannel.current.ownsPhoneLink { mobileLink.attach(self) }
        requestNotifyAuth()

        // On a machine that is not ready, the readiness screen IS the first screen. Someone who
        // just installed Bulava should be told what is missing and given the buttons, not left to
        // discover it when their first task fails.
        //
        // But an engine that came in the app's own bundle is not something to ASK about. A tester
        // updating to 1.6 met a red wall whose only instruction was to press a button that copies
        // a file out of the application he had just installed, and asked the obvious question:
        // why is this not automatic. It is now. The one thing that made it a question rather than
        // an action is that replacing the engine under a running worker breaks it — so the
        // install asks the machine whether anything is working first, and falls back to the wall,
        // with the reason, whenever the answer is yes or the install does not take.
        switch EngineInstaller.state() {
        case .unavailable:
            openPreflight()
        case .notInstalled, .stale:
            Task { [weak self] in
                guard let self else { return }
                _ = await self.installEngine(quietly: true)
                await self.refreshReadiness(depth: .free)
                switch EngineInstaller.state() {
                case .ready, .development: break
                case .notInstalled, .stale, .unavailable: self.openPreflight()
                }
            }
        case .ready:
            break
        case .development(let engine):
            // Bulava Dev runs this checkout's engine against a state folder of its own; its
            // workers need hook settings there that name this checkout, and nothing global moved.
            Task.detached(priority: .utility) { _ = await EngineInstaller.writeWorkerSettings(engine: engine) }
        }

        let askEnabled = settings.askUserEnabled
        let askWait = settings.askUserWaitMinutes * 60
        Task { await client.writeAskUserConfig(enabled: askEnabled, waitSeconds: askWait) }

        Task { _ = await client.reapAbandonedTemporarySessions() }
        // The free depth: the paid probes are re-proven from what the last launch remembered, and
        // asked for real only when that memory is a day old or empty. Every launch used to pay
        // both — including every launch of the test host.
        Task { await refreshReadiness(depth: .free) }
        Task { await loadCodexModels() }

        Task {
            await ForemanSession.primePath()
            let probe = await Shell.run("command -v claude >/dev/null 2>&1", timeout: 10)
            claudeAvailable = probe.ok
            // The catalogue is a file on disk, and it is worth reading even where the probe found
            // no CLI on this PATH — the version check simply goes unfiltered.
            await loadClaudeModels()
        }
        Task { await refresh(codex: true); loadedOnce = true; enrichProjects() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let secs = await MainActor.run { self?.settings.pollSeconds ?? 4 }
                try? await Task.sleep(for: .seconds(secs))
                guard let self, !Task.isCancelled else { break }
                self.tick += 1
                await self.refresh(codex: self.tick % 12 == 0)
                await self.refreshModelCataloguesIfStale()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        stopRepairs()
        foremanSessions.shutdownAll()
        uiControl?.stop()
        shares.detach()
        decisions.detach()
        browser.detach()
        mobileLink.shutdown()
        power.hold(false)
        stopChatFeeds()
    }

    func refresh(codex: Bool = false) async {
        if codex {
            await client.refreshCodexUsage()
            await client.refreshClaudeUsage()

            await client.refreshWorkerEnvironment()
        }
        let snap = await client.snapshot()
        snapshot = withAnsweredCodexDecisionsHidden(snap)
        reviveDeadRuns()
        updatePower()
        // Re-asserted on every refresh, not only at launch.
        //
        // The engine verifies decisions against a file, and a worker running as this user can
        // overwrite that file — through a helper script, where no command-text matching reaches
        // it. There is no file on this disk it could not reach, so the answer is not to hide the
        // key but to keep putting it back: a swapped one survives until the next refresh, and
        // because a permission is re-verified at every use and carries the fingerprint of the key
        // it was granted under, anything minted in that window dies the moment the real key
        // returns. It writes nothing when the bytes already match.
        let stateDir = settings.paths.stateDir
        Task.detached(priority: .utility) { DecisionSigner.publishPublicKey(stateDir: stateDir) }

        projects.reconcile(with: snap)

        syncDirectChats()

        automationsTick()

        await refreshWorkerActivity()

        // The branch each folder is on, for the inspector and the phone. The call went missing in
        // the move to direct chats and both have shown no branch since.
        if tick % 5 == 0 { await refreshCurrentBranches() }

        // Free checks only. The paid probes have their own day-long clock inside the runner, so
        // this loop no longer spends a Codex turn every twenty minutes to learn what it already
        // knew.
        if tick % 300 == 0 {
            readinessCheckedAt = nil
            await refreshReadiness(depth: .free)
        }
    }

    var workerActivity: [String: WorkerActivity.Line] = [:]

    private func refreshWorkerActivity() async {
        let paths = instances.filter { $0.active || $0.turnRunning }.map(\.projectPath)
        guard !paths.isEmpty else {
            if !workerActivity.isEmpty { workerActivity = [:] }
            return
        }
        let found = await Task.detached(priority: .utility) { () -> [String: WorkerActivity.Line] in
            var out: [String: WorkerActivity.Line] = [:]
            for path in paths {
                if let line = WorkerActivity.current(projectPath: path) { out[path] = line }
            }
            return out
        }.value

        var merged = found
        for path in paths where merged[path] == nil {
            if let previous = workerActivity[path] { merged[path] = previous }
        }
        if merged != workerActivity { workerActivity = merged }
    }

    var pendingPriority: WorkPriority?
    var pendingDeadline: Date?

    var pendingVariantCount: Int?

    var pendingAttachments: [Attachment] = []

    /// Which Codex models exist, as the CLI's own catalogue reports them. Read from disk rather
    /// than compiled in, so a model released this morning appears in the menu without a release
    /// of Bulava.
    var codexModels = CodexModelCatalog.empty

    func loadCodexModels() async {
        let found = await CodexModelCatalog.load()
        if found.loaded, found != codexModels { codexModels = found }
    }

    /// When the model lists were last read. Both CLIs refresh their catalogues from the service as
    /// they run, so a model released while Bulava is open reaches the menus on the next reading
    /// rather than at the next launch.
    private var modelCataloguesReadAt = Date()

    func refreshModelCataloguesIfStale() async {
        guard Date().timeIntervalSince(modelCataloguesReadAt) >= 600 else { return }
        modelCataloguesReadAt = Date()
        await loadCodexModels()
        await loadClaudeModels()
    }

    /// Which Claude models exist, as the CLI's own catalogue reports them — today's Opus and the
    /// versions before it. Read from disk for the same reason the Codex list is: a model released
    /// this morning belongs in the menu this afternoon, without a release of Bulava.
    var claudeModels = ClaudeModelCatalog.empty

    /// The version of the Claude CLI on this machine, as it reports itself. The catalogue names a
    /// minimum version per model, and a model the installed CLI has never heard of must not be
    /// offered — choosing it would fail the run rather than run something older.
    var claudeCLIVersion = ""

    func loadClaudeModels() async {
        let version = await Task.detached(priority: .utility) { () -> String in
            let probe = await Shell.run("claude --version 2>/dev/null | head -1", timeout: 20)
            return probe.stdout.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        }.value
        claudeCLIVersion = version
        let found = await Task.detached(priority: .utility) {
            ClaudeModelCatalog.read(cliVersion: version)
        }.value
        guard found.loaded, found != claudeModels else { return }
        claudeModels = found
        // The catalogue arrives after the settings do, and the pair they make may be impossible —
        // a depth saved against one model, read now against another that does not take it. The
        // slider would show `Automatic` while the runs kept sending the old level.
        if !found.levels(for: settings.claudeModel).contains(settings.claudeEffort) {
            settings.claudeEffort = .auto
        }
    }

    // MARK: What a chat runs on

    /// The default a chat starts from, which is what Settings shows.
    var defaultRunChoices: RunChoices {
        RunChoices(claudeModel: settings.claudeModel, claudeEffort: settings.claudeEffort,
                   codexModel: settings.codexModel, codexEffort: settings.codexEffort)
    }

    /// What this chat runs on: its own choices, or the default when it has none yet. Nil is the
    /// default itself — Settings, and anything that is not one conversation.
    func runChoices(for chatID: UUID?) -> RunChoices {
        guard let chatID else { return defaultRunChoices }
        return conversations.chat(id: chatID)?.run ?? defaultRunChoices
    }

    /// Change what one chat runs on — or, with no chat, the default for new ones. A chat that had
    /// no choices of its own gets them here, so the change cannot reach any other chat.
    func updateRunChoices(for chatID: UUID?, _ change: (inout RunChoices) -> Void) {
        var choices = runChoices(for: chatID)
        change(&choices)
        guard let chatID, conversations.chat(id: chatID) != nil else {
            settings.claudeModel = choices.claudeModel
            settings.claudeEffort = choices.claudeEffort
            settings.codexModel = choices.codexModel
            settings.codexEffort = choices.codexEffort
            return
        }
        conversations.setRunChoices(choices, for: chatID)
    }

    /// A chat keeps what it was sent with. Called on its first message, so a later change to the
    /// default in Settings does not quietly move a conversation already under way.
    func settleRunChoices(for chatID: UUID) {
        guard let chat = conversations.chat(id: chatID), chat.run == nil else { return }
        conversations.setRunChoices(defaultRunChoices, for: chatID)
    }

    /// Pick the Claude model, and keep the depth to one that model accepts.
    ///
    /// Haiku has no reasoning levels at all, and the versions differ in which ones they take — a
    /// depth left behind from the previous model is a setting the CLI ignores while the composer
    /// goes on claiming it.
    func chooseClaudeModel(_ choice: ClaudeModelChoice, for chatID: UUID? = nil) {
        let levels = claudeModels.levels(for: choice)
        updateRunChoices(for: chatID) { run in
            run.claudeModel = choice
            if !levels.contains(run.claudeEffort) { run.claudeEffort = .auto }
        }
    }

    /// Pick the Codex model, and keep the depth to one that model accepts.
    ///
    /// A depth the model refuses is not a harmless setting: the CLI rejects its config and the
    /// turn dies with a message nobody reads. Both places that choose a model come through here
    /// so neither can leave the pair impossible.
    func chooseCodexModel(_ slug: String, for chatID: UUID? = nil) {
        let levels = codexModels.levels(forSlug: slug)
        updateRunChoices(for: chatID) { run in
            run.codexModel = slug
            if !levels.contains(run.codexEffort) { run.codexEffort = .auto }
        }
    }

    let readiness = PreflightRunner()
    var readinessCheckedAt: Date?

    var readinessChecking = false

    var lastListedDecisions: [UUID] = []

    var launching: Set<String> = []

    var chatFeeds: [UUID: ChatTranscriptFeed] = [:]
    var sendingChatIDs: Set<UUID> = []
    /// Chats whose run is being started right now, and the folder it is started in. Until the start
    /// returns the chat is bound to no run, so a screen Claude asks on while starting is found
    /// through this (`startingInstance(for:)`).
    var startingChats: [UUID: String] = [:]
    var stoppingChatIDs: Set<UUID> = []

    var codexTurns: [UUID: CodexChatRunner] = [:]

    var composerDrafts: [UUID: String] = [:]
    /// How one Codex turn is run. The real runner in the app; a test puts a stand-in here to hold
    /// a turn open and end it however it needs to — a quota refusal, say.
    var runCodexTurn: @MainActor (CodexTurnRequest) async -> CodexChatRunner.Outcome = { request in
        await CodexChatRunner.send(prompt: request.prompt, threadID: request.threadID, cwd: request.cwd,
                                   effort: request.effort, model: request.model, path: request.path,
                                   register: request.register, onProgress: request.onProgress)
    }
    /// Told the choices a delivery to Claude starts with. Nil in the app; a test listens here.
    var claudeDeliveryStarted: ((UUID, RunChoices) -> Void)?

    /// The chat each product's recording belongs to, fixed when the recording starts.
    var dictationSlots: [UUID: UUID] = [:]

    var webPreview: URL?
    var generatingChatReportIDs: Set<UUID> = []
    /// Runs being brought back after their watchdog died (`reviveDeadRuns`), by slug.
    var revivals: [String: RevivalAttempt] = [:]
    var chatErrors: [UUID: String] = [:]
    /// Failures being put right, or offered to be, by chat (AppModel+Repair.swift).
    var repairs: [UUID: ChatRepair] = [:]
    /// When a failure of each kind was last handed to a repair, by chat and fingerprint — so the
    /// same failure is not repaired in a loop.
    var repairAttempts: [String: Date] = [:]
    /// Messages the engine said it delivered — a turn confirmed running, or Codex's answer back.
    /// What a repair's verification takes as proof that the message went (AppModel+Repair.swift).
    var confirmedDeliveries: Set<UUID> = []

    /// Chats where a message was taken back after the agent had already read it.
    ///
    /// It cannot be un-said, so the next message in that chat carries one line telling the agent
    /// the previous one is superseded. Held per chat and cleared the moment it is used.
    var supersededChatIDs: Set<UUID> = []

    var trustBlocked: [UUID: String] = [:]

    /// Chats whose send stopped because Claude Code has not been through its first run here, so a
    /// worker would sit on the theme picker where nobody can answer it (`ClaudeOnboarding`).
    var setupBlocked: Set<UUID> = []

    /// A folder with no git where the run stopped to ask: create git here or not.
    ///
    /// Connecting a folder is not consent to change it. The engine no longer runs `git init`
    /// silently; instead of silence it leaves a wall, and that wall has a door rather than advice
    var gitConsentBlocked: [UUID: String] = [:]

    /// The same question, asked by a task card rather than a chat message: the folder has no git,
    /// and the engine stopped to ask before creating one. The chat shows a row with a button; a
    /// card has no row to show it in, so it is a dialog — and never a command to type.
    var gitConsentAsk: GitConsentAsk?

    struct GitConsentAsk: Identifiable, Equatable {
        let id = UUID()
        let task: BacklogTask
        let folder: String
        static func == (a: GitConsentAsk, b: GitConsentAsk) -> Bool { a.id == b.id }
    }

    /// Chats whose message stopped because the project brings MCP servers Claude has not been told
    /// about (engine exit 78). Claude would ask about them before its session starts, where nobody
    /// can answer; an MCP server can run code, so the answer is the director's — given here.
    var mcpBlocked: [UUID: McpBlock] = [:]

    struct McpBlock: Equatable {
        let entryID: UUID
        let folder: String
        let servers: [String]
    }

    /// The same question raised by a task card, as a dialog.
    var mcpAsk: McpAsk?

    struct McpAsk: Identifiable, Equatable {
        let id = UUID()
        let task: BacklogTask
        let folder: String
        let servers: [String]
        static func == (a: McpAsk, b: McpAsk) -> Bool { a.id == b.id }
    }

    /// Chats whose message stopped on the director's uncommitted work (engine exit 77).
    ///
    /// The engine used to commit it all as `night-shift` and start. Now it asks, and the chat shows
    /// the list with the answers under the message: leave the changes, commit them as the director,
    /// or sort them out another way — while the row is up, the folder is watched and the message
    /// goes out by itself once it is clean.
    var dirtyTreeBlocked: [UUID: DirtyTreeBlock] = [:]

    struct DirtyTreeBlock: Equatable {
        let entryID: UUID
        let folder: String
        var tree: DirtyTree
        /// Why the last answer did not go through — a commit git refused, say — shown in the row.
        var problem: String?
        /// Earlier messages in this chat that stopped on the same question, oldest first. The row sits
        /// under the newest; when it is answered, these go out too, in the order they were written.
        var waiting: [UUID] = []

        /// Every held message, oldest first — the order they are sent in.
        var held: [UUID] { waiting + [entryID] }
    }

    /// The answer the next start of this chat carries. Consumed by that start and by nothing else.
    var dirtyTreeAnswer: [UUID: DirtyTreeChoice] = [:]

    /// Chats whose message stopped because the checkpoint would be too big, and the engine named the
    /// files that make it so (exit 79). The row lists them with «leave them out and send».
    var heavyFilesBlocked: [UUID: HeavyFilesBlock] = [:]

    struct HeavyFilesBlock: Equatable {
        let entryID: UUID
        let folder: String
        var files: HeavyFiles
        /// «Leave my changes» was the answer this start carried. It is carried again on the retry,
        /// so leaving the files out does not bring the uncommitted-work question back.
        var keepChanges: Bool = false
        /// Pressed and not finished yet — the buttons wait.
        var applying: Bool = false
        /// Why the last «leave them out» did not go through.
        var problem: String?
    }

    /// The same question, raised by a task card. A card has no row to put it under, so it is a dialog.
    var dirtyTreeAsk: DirtyTreeAsk?

    struct DirtyTreeAsk: Identifiable, Equatable {
        let id = UUID()
        let task: BacklogTask
        let folder: String
        let tree: DirtyTree
        static func == (a: DirtyTreeAsk, b: DirtyTreeAsk) -> Bool { a.id == b.id }
    }

    /// The answer a task's next dispatch carries, and the tasks waiting for their folder to be clean.
    var dirtyTaskAnswer: [UUID: DirtyTreeChoice] = [:]
    var dirtyTaskWaiting: [UUID: String] = [:]

    /// «Commit as me…»: the sheet where the director sees the list, their own name and the message.
    var commitAsMe: CommitAsMeRequest?

    struct CommitAsMeRequest: Identifiable, Equatable {
        enum Target: Equatable { case chat(entryID: UUID, chatID: UUID), task(BacklogTask) }
        let id = UUID()
        let target: Target
        let folder: String
        let tree: DirtyTree
        static func == (a: CommitAsMeRequest, b: CommitAsMeRequest) -> Bool { a.id == b.id }
    }

    /// One watcher per chat or task while the director is sorting the folder out their own way.
    var dirtyTreeWatchers: [String: Task<Void, Never>] = [:]

    /// A send that met a live run belonging to another chat, and what it would take to proceed.
    ///
    /// The run is NOT stopped on its own: it may be holding a question, waiting out a usage
    /// window or paused on a network outage — idle at this instant and far from over. But being
    /// told "stop it there" with nothing to press is an errand, so the offer lives here and the
    /// director decides with one button.
    var handoffBlocked: [UUID: PendingHandoff] = [:]

    /// Chats whose worker answered with the CLI's "your login has run out" notice.
    ///
    /// Not an error the app ever saw: Claude Code replies with that sentence, so it arrives as the
    /// worker's answer and the conversation looks like it worked. Held here so the chat can say
    /// what actually happened and put the sign-in within reach, instead of leaving someone reading
    /// an instruction to type `/login` into a window that has no such command.
    var signInBlocked: [UUID: SignInBlock] = [:]


    /// Both halves of it, because a chat is not the right granularity for either one.
    ///
    /// Keyed by chat alone, the panel attached itself to every message in the chat that had ever
    /// failed — including ones that failed last week for unrelated reasons — and a second expired
    /// answer after a retry changed nothing, because the chat was already marked.
    nonisolated struct SignInBlock: Equatable {

        /// The entry carrying the CLI's notice, kept out of the conversation. Deleting it from the
        /// store would not hold: the feed re-reads the session transcript and would write it
        /// straight back.
        var noticeEntryID: UUID

        /// The message that never got an answer. The only place the sign-in panel appears.
        var askedEntryID: UUID?
    }

    nonisolated struct PendingHandoff: Equatable {
        var holderTitle: String
        var projectPath: String
        var session: String
        var resumesOwnSession: Bool
    }

    func refreshNow() { Task { await refresh() } }

    func enrichProjects() {
        for p in projects.needingGitInfo { enrichProjectGit(p.id) }
    }

    private(set) var currentBranches: [UUID: String] = [:]

    func refreshCurrentBranches() async {
        var out: [UUID: String] = [:]
        for project in projects.sorted {
            guard FileManager.default.fileExists(atPath: project.path + "/.git") else { continue }
            let r = await Shell.run(
                "git -C \"$1\" symbolic-ref --short HEAD 2>/dev/null || git -C \"$1\" rev-parse --short HEAD 2>/dev/null",
                args: [project.path], timeout: 6)
            let branch = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !branch.isEmpty { out[project.id] = branch }
        }
        if out != currentBranches { currentBranches = out }
    }

    func branch(forProjectID id: UUID?) -> String? { id.flatMap { currentBranches[$0] } }

    func enrichProjectGit(_ id: UUID) {
        guard let p = projects.project(id: id) else { return }
        Task {
            let info = await client.projectGitInfo(p.path)
            projects.setGitInfo(id, remote: info.remote, defaultBranch: info.defaultBranch)
        }
    }

    // MARK: Derived

    var capacity: CapacitySnapshot { snapshot.capacity }
    var instances: [SupervisorInstance] { snapshot.instances }
    var activeInstances: [SupervisorInstance] { snapshot.instances.filter { $0.active } }
    var queue: QueueState { snapshot.queue }
    var nightModeActive: Bool { snapshot.nightModeActive }

    // MARK: Task ⇄ live worker (one source of truth for "is this working")

    func liveInstance(for task: BacklogTask) -> SupervisorInstance? {
        if let runID = task.boundRunID, !runID.isEmpty {
            return instances.first { $0.runID == runID && $0.active }
        }
        guard let dispatched = task.dispatchedAt, task.state.isActive || task.state == .blocked,
              let path = task.projectPath else { return nil }

        let sameProject = backlog.tasks.filter {
            $0.id != task.id && $0.dispatchedAt != nil
                && ($0.state.isActive || $0.state == .blocked)
                && Slug.canonicalPath($0.worktree ?? $0.projectPath ?? "") == Slug.canonicalPath(task.worktree ?? path)
        }
        if sameProject.contains(where: { ($0.dispatchedAt ?? .distantFuture) < dispatched }) { return nil }
        return liveInstance(forProjectPath: task.worktree ?? path)
    }

    func questionInstance(for task: BacklogTask) -> SupervisorInstance? {
        if let live = liveInstance(for: task) { return live }
        guard let runID = task.boundRunID, !runID.isEmpty else { return nil }
        return instances.first { $0.runID == runID && $0.pendingQuestion != nil }
    }

    func liveInstance(forProjectPath path: String) -> SupervisorInstance? {
        let slug = Slug.forPath(path)
        return instances.first { $0.slug == slug && $0.active }
    }

    /// Requests he has already answered, and when.
    ///
    /// The engine takes the answer out of the run's folder on the watchdog's next turn, and that is
    /// forty-five seconds away. Leaving his own decision on screen for three quarters of a minute
    /// reads as a button that did nothing, so the card goes at the press — but only for as long as
    /// it takes the engine to agree. If the question is somehow still standing after that, it comes
    /// back rather than leaving him with a parked run and nothing to press.
    private var answeredCodexRequests: [String: Date] = [:]

    private static let codexAnswerGrace: TimeInterval = 180

    private func withAnsweredCodexDecisionsHidden(_ snap: SupervisorSnapshot) -> SupervisorSnapshot {
        guard !answeredCodexRequests.isEmpty else { return snap }
        var snap = snap
        let now = Date()
        answeredCodexRequests = answeredCodexRequests.filter {
            now.timeIntervalSince($0.value) < Self.codexAnswerGrace
        }
        for index in snap.instances.indices {
            guard let id = snap.instances[index].codexDecision?.id,
                  answeredCodexRequests[id] != nil else { continue }
            snap.instances[index].pendingQuestion = nil
            snap.instances[index].codexDecision = nil
        }
        return snap
    }

    func answerQuestion(_ inst: SupervisorInstance, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        if let productID = task(forInstance: inst)?.productID { products.worked(productID) }

        // A decision about Codex goes to the engine's own channel, not to the ask-user one.
        //
        // They look identical on screen and must not share a file. The ask-user channel answers
        // itself after an hour and lets the work continue — right for a question about the work,
        // and the exact bug this feature exists to remove if it ever touched this question. Here
        // an unanswered question means the run stays parked, for days if that is what it takes.
        if let decision = inst.codexDecision,
           inst.pendingQuestion?.reasonCode == "codex_unavailable",
           let options = inst.pendingQuestion?.questions.first?.options,
           let index = options.firstIndex(of: t), index < decision.choices.count {
            let choice = decision.choices[index]
            answeredCodexRequests[decision.id] = Date()
            Task {
                // Signed, or not sent. A locked keychain or a denied prompt has to look like a
                // decision that did not go through — the alternative is a card that disappears
                // while the engine goes on waiting for an answer it will never accept.
                let sent = await client.answerCodexDecision(slug: inst.slug,
                                                            requestID: decision.id, choice: choice)
                guard sent else {
                    answeredCodexRequests[decision.id] = nil
                    toast = ToastMessage(
                        text: String(localized: "Could not sign that decision — unlock the keychain and try again."),
                        kind: .error)
                    await refresh()
                    return
                }
                note(.answerSent, .info,
                     choice == "claude"
                       ? "«\(inst.projectName)» продовжує з Claude замість Codex."
                       : "«\(inst.projectName)» чекає на Codex.",
                     detail: t, projectPath: inst.projectPath,
                     taskID: task(forInstance: inst)?.id)
                toast = ToastMessage(text: t, kind: .success)
                await refresh()
            }
            return
        }

        Task {
            if let pending = inst.pendingQuestion, pending.source == .terminal {
                let result = await client.answerTerminalQuestion(session: inst.session,
                                                                 expected: pending, answer: t)
                if result.ok {
                    note(.answerSent, .info, "Відповідь надіслано — «\(inst.projectName)» продовжує.",
                         detail: t, projectPath: inst.projectPath,
                         taskID: task(forInstance: inst)?.id)
                    toast = ToastMessage(text: String(format: String(localized: "Answer sent — %@ carries on"), inst.projectName),
                                         kind: .success)
                } else {
                    let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                    toast = ToastMessage(text: detail.isEmpty ? String(localized: "Could not answer Claude.") : detail,
                                         kind: .error)
                }
            } else if await client.answerUserQuestion(slug: inst.slug, answer: t) == .taken {
                note(.answerSent, .info, "Відповідь надіслано — «\(inst.projectName)» продовжує.",
                     detail: t, projectPath: inst.projectPath,
                     taskID: task(forInstance: inst)?.id)
                toast = ToastMessage(text: String(format: String(localized: "Answer sent — %@ carries on"), inst.projectName),
                                     kind: .success)
            } else {
                deliverLateAnswer(inst, answer: t)
            }
            await refresh()
        }
    }

    /// An answer that came after the run stopped waiting for it. At the deadline the hook took the
    /// safe default — or, for what only the director may decide, left that part undone — and went
    /// on; its question is gone, so there is nowhere for the answer to be read. It goes to the run's
    /// chat instead, as his message, and the worker reads it like anything else he says: the
    /// director's answer closes the blocker and continues that very run (AUTONOMY Р5).
    func deliverLateAnswer(_ inst: SupervisorInstance, answer: String) {
        let chat = conversations.chats.first { chat in
            chat.session.flatMap { matchingInstance(for: $0) }?.slug == inst.slug
        }
        guard let chat else {
            toast = ToastMessage(text: String(localized: "That question had already expired, and its run has no chat to take the answer."),
                                 kind: .error)
            return
        }
        let asked = inst.pendingQuestion?.summary ?? inst.pendingQuestion?.questions.first?.question
        let about = asked.map { "«" + String($0.prefix(200)) + "»" } ?? ""
        let text = String(format: String(localized: "A late answer to your question %@ (you had already gone on without it):"), about)
            + "\n\n" + answer
        sendDirectMessage(text, productID: chat.productID, chatID: chat.id)
        note(.answerSent, .info, "Відповідь прийшла після дедлайну — надіслано в чат «\(inst.projectName)».",
             detail: answer, projectPath: inst.projectPath, taskID: task(forInstance: inst)?.id)
        toast = ToastMessage(text: String(localized: "The question had expired. The answer went to its chat."), kind: .success)
    }

    func watch(instance inst: SupervisorInstance) {
        if let task = task(forInstance: inst), let id = productID(for: task) {
            open(product: id)
            openTaskDetail(task)
        } else if let id = productID(for: inst) {
            open(product: id)
        }
    }

    func task(forInstance inst: SupervisorInstance) -> BacklogTask? {

        if let rid = inst.runID, !rid.isEmpty {
            return backlog.tasks.first { $0.boundRunID == rid }
        }

        let matches = backlog.tasks.filter {
            guard $0.boundRunID == nil, let p = $0.projectPath else { return false }
            return Slug.forPath($0.worktree ?? p) == inst.slug
        }
        return matches.first { $0.state.isActive || $0.dispatchedAt != nil }
            ?? matches.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    func canDispatch(_ task: BacklogTask) -> Bool {
        task.isDispatchable && !backlog.isBlocked(task)
    }

    var completions: [Completion] {
        var out: [Completion] = []
        for d in queue.done {
            out.append(Completion(id: "q-\(d.dirName)", projectName: d.projectName,
                                  detail: d.task, outcome: d.outcome, time: d.finishedAt ?? .distantPast))
        }
        for i in instances where !i.active && i.doneResult != nil {
            out.append(Completion(id: "i-\(i.slug)", projectName: i.projectName,
                                  detail: i.branch.map { "branch \($0)" } ?? "night run",
                                  outcome: QueueOutcome(raw: i.doneResult ?? ""),
                                  time: i.finishedAt ?? i.lastActivity ?? .distantPast))
        }
        return out.sorted { $0.time > $1.time }
    }

    var completedToday: Int {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return completions.filter { $0.outcome.isSuccess && $0.time > cutoff }.count
    }

    var blockedCount: Int {
        queue.needsUser.count + instances.filter { $0.phase == .blocked }.count
    }

    // MARK: Commands

    func runQueue()          { note(.queueRun, .info, "Запущено чергу."); let s = RunStrategy.standing.overridden(by: settings, claudeModels: claudeModels); perform("Queue started") { await self.client.queueRun(strategy: s) } }
    func stopAllWorkers()    { note(.workersStopped, .attention, "Зупиняю всіх воркерів."); perform("Stopping all workers") { await self.client.stopAll() } }
    func startNightShift(project: String) { note(.taskDispatched, .info, "Нічна зміна для «\(name(of: project) ?? project)».", projectPath: project); let s = RunStrategy.standing.overridden(by: settings, claudeModels: claudeModels); perform("Night shift started")  { await self.client.startNightShift(project: project, strategy: s) } }
    func stopNightShift(project: String)  { note(.workersStopped, .info, "Зупинено воркера «\(name(of: project) ?? project)».", projectPath: project); perform("Worker stopped")       { await self.client.stopNightShift(project: project) } }

    func perform(_ success: String, _ op: @escaping () async -> CommandResult) {
        busy = true
        Task {
            let r = await op()
            busy = false
            if r.ok {
                toast = ToastMessage(text: success, kind: .success)
            } else {
                let msg = r.combined.split(separator: "\n").first.map(String.init) ?? "Command failed"
                toast = ToastMessage(text: msg, kind: .error)
            }
            await refresh()
        }
    }
}

struct Completion: Identifiable, Equatable {
    let id: String
    var projectName: String
    var detail: String
    var outcome: QueueOutcome
    var time: Date
}

/// One Codex turn, as `AppModel.runCodexTurn` is asked for it.
struct CodexTurnRequest {
    var prompt: String
    var threadID: String?
    var cwd: URL
    var effort: String
    var model: String
    var path: String
    var register: ((CodexChatRunner) -> Void)?
    var onProgress: (@Sendable ([ConversationBlock]) -> Void)?
}
