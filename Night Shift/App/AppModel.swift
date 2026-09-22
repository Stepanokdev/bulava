import SwiftUI
import OSLog
import Observation
import CryptoKit

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

    var toast: ToastMessage?

    /// Products holding a folder that turned out to be a workspace, found when the product was
    /// opened. Keyed by resource id, because that is what the offer to fix it acts on.
    var workspaceResources: [UUID: FolderConnection] = [:]

    var postedReviewVerdicts: Set<String> = []
    var busy = false

    var thinkingProductIDs: Set<UUID> = []
    func isThinking(_ productID: UUID?) -> Bool {
        guard let productID else { return false }
        return thinkingProductIDs.contains(productID)
    }

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

    private(set) var finalizeVerifyInFlight: Set<UUID> = []
    func beginFinalizeVerify(_ id: UUID) { finalizeVerifyInFlight.insert(id) }
    func endFinalizeVerify(_ id: UUID) { finalizeVerifyInFlight.remove(id) }

    var reviewMergeChecked: [UUID: Date] = [:]

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
                toast = ToastMessage(text: "No report yet for this task", kind: .info)
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

    private(set) var resuming: [String: Date] = [:]
    func beginResuming(_ path: String) { resuming[Slug.canonicalPath(path)] = Date() }
    func isResuming(path: String) -> Bool { resuming[Slug.canonicalPath(path)] != nil }

    private let dismissedBlockersFile = JSONFile<[String]>(url: AppSupport.file("dismissed-blockers.json"))
    private(set) var dismissedBlockers: Set<String> = []

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

    let foremanSessions = ForemanSessions()

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
    private var monitorTick = 0
    private var autoDispatchInFlight: Set<UUID> = []

    init() {
        let s = AppSettings.load()
        settings = s

        LanguageBundle.adopt(s.interfaceLanguage)
        client = SupervisorClient(paths: s.paths)

        Trace.destination = s.paths.stateDir
        dismissedBlockers = Set(dismissedBlockersFile.load() ?? [])

        announcedReports = Set(conversations.entries.compactMap { $0.kind == .report ? $0.taskID : nil })

        deliveredArtifacts = Set(conversations.entries.compactMap { entry in
            entry.blocks.contains { $0.kind == .file || $0.kind == .gallery } ? entry.taskID : nil
        })

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

    func start() {
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
        if let drive = TestDrive.make() { testDrive = drive; drive.start(self) }
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
                await self.refreshReadiness()
                switch EngineInstaller.state() {
                case .ready, .development: break
                case .notInstalled, .stale, .unavailable: self.openPreflight()
                }
            }
        case .ready, .development:
            break
        }

        let askEnabled = settings.askUserEnabled
        let askWait = settings.askUserWaitMinutes * 60
        Task { await client.writeAskUserConfig(enabled: askEnabled, waitSeconds: askWait) }

        Task { _ = await client.reapAbandonedTemporarySessions() }
        Task { await refreshReadiness() }
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
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        foremanSessions.shutdownAll()
        uiControl?.stop()
        stopWorkerFeeds()
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

        await refreshWorkerActivity()

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
        let found = await Task.detached(priority: .utility) { CodexModelCatalog.read() }.value
        if found.loaded { codexModels = found }
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
        guard found.loaded else { return }
        claudeModels = found
        // The catalogue arrives after the settings do, and the pair they make may be impossible —
        // a depth saved against one model, read now against another that does not take it. The
        // slider would show `Automatic` while the runs kept sending the old level.
        if !found.levels(for: settings.claudeModel).contains(settings.claudeEffort) {
            settings.claudeEffort = .auto
        }
    }

    /// Pick the Claude model, and keep the depth to one that model accepts.
    ///
    /// Haiku has no reasoning levels at all, and the versions differ in which ones they take — a
    /// depth left behind from the previous model is a setting the CLI ignores while the composer
    /// goes on claiming it.
    func chooseClaudeModel(_ choice: ClaudeModelChoice) {
        settings.claudeModel = choice
        if !claudeModels.levels(for: choice).contains(settings.claudeEffort) {
            settings.claudeEffort = .auto
        }
    }

    /// Pick the Codex model, and keep the depth to one that model accepts.
    ///
    /// A depth the model refuses is not a harmless setting: the CLI rejects its config and the
    /// turn dies with a message nobody reads. Both places that choose a model come through here
    /// so neither can leave the pair impossible.
    func chooseCodexModel(_ slug: String) {
        settings.codexModel = slug
        if !codexModels.levels(forSlug: slug).contains(settings.codexEffort) {
            settings.codexEffort = .auto
        }
    }

    let readiness = PreflightRunner()
    var readinessCheckedAt: Date?

    var readinessChecking = false

    var lastListedDecisions: [UUID] = []

    var launching: Set<String> = []

    var announcedReports: Set<UUID> = []

    var deliveredArtifacts: Set<UUID> = []

    var undeliveredSeen: Set<UUID> = []

    var workerFeeds: [UUID: WorkerFeed] = [:]

    var chatFeeds: [UUID: ChatTranscriptFeed] = [:]
    var sendingChatIDs: Set<UUID> = []
    var stoppingChatIDs: Set<UUID> = []

    var codexTurns: [UUID: CodexChatRunner] = [:]

    var composerDrafts: [UUID: String] = [:]

    var webPreview: URL?
    var generatingChatReportIDs: Set<UUID> = []
    var chatErrors: [UUID: String] = [:]

    /// Chats where a message was taken back after the agent had already read it.
    ///
    /// It cannot be un-said, so the next message in that chat carries one line telling the agent
    /// the previous one is superseded. Held per chat and cleared the moment it is used.
    var supersededChatIDs: Set<UUID> = []

    var trustBlocked: [UUID: String] = [:]

    /// A folder with no git where the run stopped to ask: create git here or not.
    ///
    /// Connecting a folder is not consent to change it. The engine no longer runs `git init`
    /// silently; instead of silence it leaves a wall, and that wall has a door rather than advice
    var gitConsentBlocked: [UUID: String] = [:]

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

    // MARK: Autonomous scheduling

    private func scheduleAutoResumeAndMonitor() {

        if !resuming.isEmpty {
            let now = Date()
            resuming = resuming.filter { path, started in
                let slug = Slug.forPath(path)
                let running = snapshot.instances.contains { $0.slug == slug && $0.active }
                return !running && now.timeIntervalSince(started) < 120
            }
        }

        for t in backlog.resumable() where !autoDispatchInFlight.contains(t.id) {
            let id = t.id
            autoDispatchInFlight.insert(id)

            dispatch(task: t, userInitiated: false) { [weak self] in self?.autoDispatchInFlight.remove(id) }
        }
        monitorTick += 1
        guard monitorTick % 15 == 0 else { return }
        for t in backlog.withExternalPRBlocker() {
            guard let blocker = t.externalBlocker,
                  let r = blocker.range(of: #"#\d+"#, options: .regularExpression),
                  let project = t.projectID.flatMap({ projects.project(id: $0) }),
                  let remote = project.gitRemote else { continue }
            let number = blocker[r].replacingOccurrences(of: "#", with: "")
            let repo = ghRepo(from: remote)
            let taskID = t.id, title = t.title, name = project.name, path = project.path
            Task {
                if await client.checkPRMerged(number: number, repo: repo, cwd: path) == true {
                    backlog.setExternalBlocker(taskID, nil)
                    toast = ToastMessage(text: "\(name): PR #\(number) merged — \(title) unblocked", kind: .success)
                }
            }
        }
    }

    private func ghRepo(from remote: String) -> String {
        var s = remote
        if let at = s.range(of: "@") { s = String(s[at.upperBound...]) }
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: ":", with: "/").replacingOccurrences(of: ".git", with: "")
        let parts = s.split(separator: "/")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: "/") : s
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

    // MARK: Blocker resolution

    func blockerKey(projectID: UUID, note: String) -> String {
        let hex = Insecure.SHA1.hash(data: Data(note.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        return "\(projectID.uuidString)|\(hex)"
    }

    func isBlockerDismissed(projectID: UUID, note: String) -> Bool {
        dismissedBlockers.contains(blockerKey(projectID: projectID, note: note))
    }

    func resolveBlocker(projectID: UUID, note: String) {
        dismissedBlockers.insert(blockerKey(projectID: projectID, note: note))
        dismissedBlockersFile.save(Array(dismissedBlockers))
        toast = ToastMessage(text: "Blocker marked resolved", kind: .success)
    }

    static func isActiveBlocker(_ note: String) -> Bool {
        let low = note.lowercased()
        if low.contains("nothing blocks") || low.contains("nothing is blocked") { return false }
        let signals = ["— blocked", "- blocked", "secret-scan", "не закомічено", "waiting for",
                       "чекає", "needs user", "needs-user", "потрібен доступ", "requires access"]
        if signals.contains(where: { low.contains($0) }) { return true }
        return note.range(of: "## 20", options: .literal) != nil
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
                if choice == "claude" { beginResuming(inst.projectPath) }
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
                    beginResuming(inst.projectPath)
                    note(.answerSent, .info, "Відповідь надіслано — «\(inst.projectName)» продовжує.",
                         detail: t, projectPath: inst.projectPath,
                         taskID: task(forInstance: inst)?.id)
                    toast = ToastMessage(text: "Answer sent — resuming \(inst.projectName)", kind: .success)
                } else {
                    let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                    toast = ToastMessage(text: detail.isEmpty ? "Could not answer Claude." : detail,
                                         kind: .error)
                }
            } else {
                await client.answerUserQuestion(slug: inst.slug, answer: t)
                beginResuming(inst.projectPath)
                note(.answerSent, .info, "Відповідь надіслано — «\(inst.projectName)» продовжує.",
                     detail: t, projectPath: inst.projectPath,
                     taskID: task(forInstance: inst)?.id)
                toast = ToastMessage(text: "Answer sent — resuming \(inst.projectName)", kind: .success)
            }
            await refresh()
        }
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

    var agentUptimeHours: Double {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return instances.reduce(0.0) { acc, inst in
            guard let started = inst.startedAt, started > cutoff else { return acc }
            let end = inst.active ? (inst.lastActivity ?? Date())
                                  : (inst.finishedAt ?? inst.lastActivity ?? started)
            return acc + max(0, end.timeIntervalSince(started))
        } / 3600.0
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

    var decisionsWaiting: Int {
        instances.filter { $0.awaitingUntil != nil }.count + queue.needsUser.count
    }

    // MARK: Commands

    func runQueue()          { note(.queueRun, .info, "Запущено чергу."); let s = RunStrategy.standing.overridden(by: settings, claudeModels: claudeModels); perform("Queue started") { await self.client.queueRun(strategy: s) } }
    func stopQueue()         { note(.queueStopped, .info, "Черга зупиниться після поточного."); perform("Queue will stop after current") { await self.client.queueStop() } }
    func killRunner()        { note(.queueStopped, .info, "Раннер зупинено."); perform("Runner stopped") { await self.client.queueKillRunner() } }
    func stopAllWorkers()    { note(.workersStopped, .attention, "Зупиняю всіх воркерів."); perform("Stopping all workers") { await self.client.stopAll() } }
    func startNightShift(project: String) { note(.taskDispatched, .info, "Нічна зміна для «\(name(of: project) ?? project)».", projectPath: project); let s = RunStrategy.standing.overridden(by: settings, claudeModels: claudeModels); perform("Night shift started")  { await self.client.startNightShift(project: project, strategy: s) } }
    func stopNightShift(project: String)  { note(.workersStopped, .info, "Зупинено воркера «\(name(of: project) ?? project)».", projectPath: project); perform("Worker stopped")       { await self.client.stopNightShift(project: project) } }
    func enqueue(project: String, task: String) { perform("Added to the queue") { await self.client.queueAdd(project: project, task: task) } }
    func removeFromQueue(number: Int) { perform("Removed from queue")   { await self.client.queueRemove(number: number) } }

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

struct ToastMessage: Identifiable, Equatable {
    enum Kind { case success, error, info }
    let id = UUID()
    var text: String
    var kind: Kind
}

struct Completion: Identifiable, Equatable {
    let id: String
    var projectName: String
    var detail: String
    var outcome: QueueOutcome
    var time: Date
}
