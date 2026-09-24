import SwiftUI
import AppKit

extension AppModel {

    // MARK: - Selection

    var selectedProductID: UUID? { route.productID }
    var selectedProduct: Product? { products.product(id: selectedProductID) }

    func open(product id: UUID) { navigate(to: .product(id)) }

    // MARK: - Chats

    func openChat(_ chat: Chat) {
        conversations.open(chat.id, for: chat.productID)
        if route != .product(chat.productID) { navigate(to: .product(chat.productID)) }
        composerIntent = .newTask
        composerFocusRequest = UUID()
    }

    func newChat(in productID: UUID) {
        let chat = conversations.newChat(for: productID)
        openChat(chat)
    }

    func beginRenamingChat(_ chat: Chat) { renamingChatID = chat.id }

    /// Asked by the sidebar only after the reader confirmed. The chat is looked up again by id: the
    /// dialog may have stayed open while it was archived some other way, and a stale copy must
    /// not move anything.
    func archiveChat(_ chat: Chat) {
        guard let live = conversations.chat(id: chat.id), !live.archived else { return }
        // Read before the flag flips — afterwards the store no longer counts it as open and
        // answers with some other chat.
        let wasOpen = conversations.currentChatID(for: live.productID) == live.id
        conversations.setArchived(live.id, true)
        if wasOpen {
            conversations.open(conversations.chats(for: live.productID).first?.id
                               ?? conversations.newChat(for: live.productID).id,
                               for: live.productID)
        }
    }

    /// Opens an archived chat to read. It stays in Archives, and the screen shows it without a
    /// composer until the reader unarchives it; the live chat stays where the app writes.
    func viewArchivedChat(_ chat: Chat) {
        conversations.viewArchived(chat.id, for: chat.productID)
        if route != .product(chat.productID) { navigate(to: .product(chat.productID)) }
    }

    /// Back to the chat list, and opened, with the composer ready.
    func unarchiveChat(_ chat: Chat) {
        conversations.setArchived(chat.id, false)
        if let restored = conversations.chat(id: chat.id) { openChat(restored) }
    }
    func openProducts() { navigate(to: .products) }
    func openPreflight() { navigate(to: .preflight) }
    func openSkills() { navigate(to: .skills) }

    // MARK: - Getting a fresh machine ready
    //
    // These are the readiness screen's buttons. Everything that can be done for the reader is done
    // for them; the one thing that cannot — signing in to an account — opens a terminal and says
    // so, instead of pretending a button could do it.

    /// - Parameter quietly: true when the app decided to do this itself at launch. The work is
    ///   identical; only the talking differs — nobody asked, so a success says nothing and a
    ///   refusal leaves the readiness screen to explain itself.
    @discardableResult
    func installEngine(quietly: Bool = false) async -> Bool {
        guard !installingEngine else { return false }
        // Claimed here, before the first await. Read it after one and the launch-time install and
        // a button press can both pass the guard on their way to the same directory.
        installingEngine = true
        defer { installingEngine = false }

        // Asked of the machine before anything is written. Installing means rsyncing over the
        // engine's directory and rewriting Claude Code's hooks; a worker mid-turn would find the
        // scripts it is about to call replaced underneath it. The engine outlives the app on
        // purpose, so "the app just started" proves nothing — this looks for the processes.
        if let busy = EngineBusy.reason(instances: await client.readInstances()) {
            if !quietly {
                toast = ToastMessage(
                    text: String(format: String(localized:
                        "The engine cannot be replaced while %@. Try again when the work is done."), busy),
                    kind: .error)
            }
            return false
        }

        let outcome = await EngineInstaller.install()
        note(.taskEdited, outcome.ok ? .info : .problem,
             outcome.ok ? "Движок встановлено" : "Не вдалося встановити движок",
             detail: outcome.log)
        if outcome.ok && quietly { return true }
        toast = ToastMessage(text: outcome.ok
                             ? String(localized: "The engine is ready — night-shift works in the terminal too.")
                             : SkillsPanelBody.plainMessage(outcome.log),
                             kind: outcome.ok ? .success : .error)
        return outcome.ok
    }

    /// What is holding the engine, refreshed alongside readiness so the screen can offer a way
    /// through rather than only a reason.
    func refreshEngineBlocker() async {
        switch EngineInstaller.state() {
        case .stale, .notInstalled:
            engineBlocker = EngineBusy.blocker(instances: await client.readInstances())
        case .development, .ready, .unavailable:
            engineBlocker = nil
        }
    }

    /// Stop the work that holds the engine, then install it.
    ///
    /// The wall this ends: the engine is older than the app, so Bulava starts nothing until it is
    /// replaced — and replacing it was refused because a run was still supervised. Stopping that
    /// run from the other screen did not help either, because `night-shift stop` deliberately
    /// leaves the tmux session open and an open session holds the engine too. So the refusal named
    /// the run, and there was no way to act on the name.
    ///
    /// It is one press and it interrupts real work, so the screen asks first.
    func stopHolderAndInstallEngine() async {
        guard !installingEngine, !stoppingForEngine else { return }
        stoppingForEngine = true
        defer { stoppingForEngine = false }

        // Asked again here, not taken from the screen. What was drawn a minute ago may have
        // finished on its own, restarted under a new session, or been joined by a second run.
        await refreshEngineBlocker()
        let holders = engineBlocker?.holders ?? []
        guard !holders.isEmpty else {
            // Nothing identifiable holds it any more. Either it is free — in which case installing
            // is exactly right — or a process with no run behind it does, and installEngine says so.
            await installEngine()
            await refreshEngineBlocker()
            await refreshReadiness(force: true)
            return
        }

        for holder in holders {
            if let failure = await releaseProject(path: holder.projectPath, session: holder.session) {
                toast = ToastMessage(text: Self.engineHolderProblem(failure, name: holder.name),
                                     kind: .error)
                await refreshEngineBlocker()
                await refreshReadiness(force: true)
                return
            }
        }
        // Stopped is not the same as gone. The pump and the pipeline exit on their own next poll,
        // and installing inside that gap is refused for a process already on its way out.
        let stillHeld = await EngineBusy.waitUntilFree(
            check: { [client] in EngineBusy.blocker(instances: await client.readInstances()) },
            wait: { try? await Task.sleep(for: .milliseconds(250)) })
        engineBlocker = stillHeld
        if let stillHeld {
            // Something else holds it — another product's work, a review, a process with no run
            // left behind it. Naming it is the whole point; installing over it is not.
            toast = ToastMessage(
                text: String(format: String(localized:
                    "The engine cannot be replaced while %@. Try again when the work is done."),
                             stillHeld.text),
                kind: .error)
            await refreshReadiness(force: true)
            return
        }
        await installEngine()
        await refreshEngineBlocker()
        await refreshReadiness(force: true)
    }

    /// Why the work could not be stopped, in the words that say what to do next.
    nonisolated static func engineHolderProblem(_ failure: ProjectRelease.Failure,
                                                name: String) -> String {
        switch failure {
        case .stopRefused(let detail):
            return detail.isEmpty
                ? String(format: String(localized: "Could not stop “%@”."), name)
                : String(format: String(localized: "Could not stop “%@”: %@"), name, detail)
        case .instanceRemains:
            return String(format: String(localized: "“%@” still counts as running. Try again in a moment."), name)
        case .sessionRemains:
            return String(format: String(localized: "“%@” stopped, but its session is still open."), name)
        }
    }

    /// Runs Homebrew in a terminal the reader can watch. Installing packages silently, in the
    /// background, on someone's machine is not something this app does.
    func installWithHomebrew(_ names: [String], cask: Bool = false) {
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let brew else {
            toast = ToastMessage(text: String(localized: "Homebrew is not installed on this Mac."),
                                 kind: .error)
            if let url = URL(string: "https://brew.sh") { NSWorkspace.shared.open(url) }
            return
        }
        // `brew install` would work out on its own that these are casks, but saying so is what
        // keeps a formula of the same name from being installed instead.
        let flag = cask ? "--cask " : ""
        runInTerminal("\(brew) install \(flag)\(names.joined(separator: " "))")
    }

    func signIn(command: String) {
        runInTerminal(command)
    }

    /// Opens Terminal and types the command in.
    ///
    /// This needs permission to control Terminal, which is asked for the first time it happens and
    /// can be refused. A refusal used to be silent — the button simply did nothing, which is worse
    /// than not having the button. So a failure hands the command over instead, and it is on the
    /// clipboard by the time the message is read.
    private func runInTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        Task { [weak self] in
            let result = await Shell.run("/usr/bin/osascript -e \"$1\" 2>&1", args: [script], timeout: 30)
            guard !result.ok else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            self?.toast = ToastMessage(
                text: String(format: String(localized: "Bulava could not open Terminal. The command is on your clipboard: %@"),
                             command),
                kind: .error)
        }
    }

    // MARK: - Attribution

    func productID(for task: BacklogTask) -> UUID? {
        if let id = task.productID, products.product(id: id) != nil { return id }
        if let pid = task.projectID, let p = products.product(forProjectID: pid) { return p.id }
        if let path = task.projectPath,
           let p = products.product(forProjectPath: path, projects: projects) { return p.id }
        return nil
    }

    func productID(for instance: SupervisorInstance) -> UUID? {
        products.product(forProjectPath: instance.projectPath, projects: projects)?.id
    }

    // MARK: - Tasks by product

    func tasks(for productID: UUID) -> [BacklogTask] {
        backlog.tasks.filter { self.productID(for: $0) == productID }
    }

    func openTasks(for productID: UUID) -> [BacklogTask] {
        tasks(for: productID)
            .filter { !isFinished($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func isFinished(_ task: BacklogTask) -> Bool {
        task.state == .merged || task.state == .approved || task.state == .closed
    }

    func isFinished(taskID: UUID) -> Bool {
        guard let t = backlog.task(id: taskID) else { return true }
        return isFinished(t)
    }

    func state(forProductID id: UUID) -> WorkState? {
        var states = openTasks(for: id).map { task in
            workState(of: task)
        }

        if let instance = liveInstance(forProductID: id) {
            switch instance.phase {
            case .awaitingDecision, .blocked:
                states.append(.needsAnswer)
            case .pausedForLimit:
                states.append(.paused)
            case .offline:

                states.append(.paused)
            case .stalled:

                states.append(.needsAnswer)
            case .done, .idle:
                break
            case .starting, .working, .reviewing:
                states.append(instance.pendingQuestion != nil ? .needsAnswer : .running)
            }
        }

        for item in workItems.items(forProductID: id) where state(of: item) == .partial {
            states.append(.partial)
        }
        guard !states.isEmpty else { return nil }
        let order: [WorkState] = [.needsAnswer, .stopped, .partial, .failed, .reportReady,
                                  .running, .paused, .planned]
        return order.first { states.contains($0) } ?? states.first
    }

    func reportsWaiting(forProductID id: UUID) -> Int {
        openTasks(for: id).filter { $0.state == .review }.count
    }

    func liveInstance(forProductID id: UUID) -> SupervisorInstance? {
        guard let product = products.product(id: id) else { return nil }
        let paths = product.allProjectIDs.compactMap { projects.project(id: $0)?.path }
        for path in paths {
            if let inst = liveInstance(forProjectPath: path) { return inst }
        }
        return nil
    }

    // MARK: - History

    func history(for productID: UUID) -> [HistoryItem] {
        tasks(for: productID)
            .filter { isFinished($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { task in
                HistoryItem(
                    id: task.id,
                    title: task.title,
                    finishedAt: task.finalizingSince ?? task.updatedAt,
                    summary: conversations.closingLine(taskID: task.id) ?? task.detail,
                    hasReport: reportPaths[task.id] != nil,
                    outcome: task.lastOutcome,
                    closedByYou: task.state == .closed)
            }
    }

    // MARK: - Queue projection ("Now and next")

    func nowAndNext(for productID: UUID) -> [BacklogTask] {

        let open = openTasks(for: productID).filter { !$0.isNote }

        let live = open.filter { task in
            switch workState(of: task) {
            case .running, .needsAnswer, .paused: return true

            case .planned, .reportReady, .partial, .failed, .stopped, .done: return false
            }
        }
        let liveIDs = Set(live.map(\.id))
        let queued = open
            .filter { !liveIDs.contains($0.id) }
            .filter { workState(of: $0) == .planned }
            .sorted { a, b in
                a.priority != b.priority ? a.priority < b.priority : a.createdAt < b.createdAt
            }
        return live + queued
    }

    // MARK: - Keeping conversations in step with the work

    func syncConversations() {
        for task in backlog.tasks {
            guard let productID = productID(for: task) else { continue }

            let parent = workItems.item(forStreamID: task.id)
            let isStreamOfPackage = parent?.isMultiStream == true

            if !isFinished(task), task.dispatchedAt != nil || task.state != .ready, !isStreamOfPackage {
                conversations.anchorTask(task.id, productID: productID, title: task.title)
            }

            if let parent, parent.isMultiStream {

                if allStreamsSettled(parent), parent.reportAnnouncedAt == nil {
                    workItems.markReportAnnounced(parent.id)

                    postDelivery(forItem: parent, productID: productID)
                    note(.reportReady, .good, "Звіт готовий: \(parent.title)",
                         projectPath: task.projectPath, taskID: parent.id, link: .report(parent.id))
                }
            } else if Self.hasStopped(task), announcedReports.contains(task.id),
                      let shown = conversations.lastReportAt(taskID: task.id),
                      let written = Self.reportWrittenAt(settings.paths.reportDir(task8: task.reportKey)),
                      written > shown.addingTimeInterval(60) {

                Trace.note("report-updated", task: task.id, report: task.reportKey,
                           detail: "written \(Trace.stamp(written)), card shown \(Trace.stamp(shown))")
                conversations.postUpdatedReport(task.title, productID: productID, taskID: task.id)

                deliveredArtifacts.remove(task.id)
                postDelivery(for: task, productID: productID)
                note(.reportReady, .good, "Звіт оновлено: \(task.title)",
                     projectPath: task.projectPath, taskID: task.id, link: .report(task.id))
            } else if Self.hasStopped(task), !announcedReports.contains(task.id) {

                announcedReports.insert(task.id)
                Trace.note("report", task: task.id, report: task.reportKey,
                           detail: "state=\(task.state.rawValue) outcome=\(task.lastOutcome ?? "—")")
                conversations.postReport(task.title, productID: productID, taskID: task.id)

                postDelivery(for: task, productID: productID)
                note(.reportReady, .good, "Звіт готовий: \(task.title)",
                     projectPath: task.projectPath, taskID: task.id, link: .report(task.id))
            }

            if let instance = questionInstance(for: task), let question = instance.pendingQuestion {
                conversations.postQuestion(question.headline, productID: productID, taskID: task.id,
                                           decision: question.record)
            } else if task.state != .blocked, conversations.hasOpenQuestion(taskID: task.id) {
                conversations.resolveQuestion(taskID: task.id)
            }
        }
    }

    // MARK: - Blockers

    func scanBlockers() async {
        for product in products.products {
            for projectID in product.allProjectIDs {
                guard let project = projects.project(id: projectID) else { continue }
                guard let note = await client.repoNote(projectPath: project.path, filename: "BLOCKED.md"),
                      Self.isActiveBlocker(note),
                      !isBlockerDismissed(projectID: project.id, note: note) else { continue }

                if liveInstance(forProjectPath: project.path) != nil { continue }

                let headline = note
                    .split(separator: "\n")
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
                    .map(String.init) ?? String(localized: "Something is blocking this work.")

                conversations.postEventOnce(
                    String(format: String(localized: "Blocked in %@ — %@"), project.name, headline),
                    productID: product.id, tone: .attention)
            }
        }
    }

    // MARK: - The product sheet

    func beginNewProduct() { productSheet = .newProduct }

    func beginAddingResource(to productID: UUID) { productSheet = .addResource(productID: productID) }

    // MARK: - Product lifecycle

    func beginRenaming(_ product: Product) { renamingProductID = product.id }

    func removeProduct(_ product: Product) {
        let wasSelected = route.productID == product.id
        conversations.removeAll(for: product.id)
        products.remove(product.id)
        pendingProposals[product.id] = nil
        if wasSelected {
            if let next = products.sorted.first { route = .product(next.id) } else { route = .products }
        }
        toast = ToastMessage(text: String(format: String(localized: "Removed %@"), product.name),
                             kind: .success)
    }

    // MARK: - Product resources

    struct ResolvedResource: Identifiable {
        var id: UUID
        var resource: ProductResource
        var project: Project?
        var isLive: Bool
    }

    func tasks(ofProduct productID: UUID?) -> [BacklogTask] {
        guard let productID else { return backlog.tasks }
        return backlog.tasks.filter { self.productID(for: $0) == productID }
    }

    func productProjects(_ productID: UUID?) -> [Project]? {

        guard let scope = scope(forProductID: productID) else { return nil }
        return scope.all
    }

    func resources(for product: Product) -> [ResolvedResource] {
        product.resources.map { r in
            let project = r.projectID.flatMap { projects.project(id: $0) }
            let live = project.map { liveInstance(forProjectPath: $0.path) != nil } ?? false
            return ResolvedResource(id: r.id, resource: r, project: project, isLive: live)
        }
    }

    // MARK: Folders that turned out to be workspaces

    /// Look over a product's folders for one that is really a workspace.
    ///
    /// Products connected before Bulava knew the difference still hold the container itself, and a
    /// run in one cannot start — the engine refuses it, correctly, and the director is left with a
    /// refusal and no way to act on it. This is that way: found once when the product is opened, off
    /// the main actor, and offered as something to press.
    func findWorkspaceResources(in product: Product) async {
        let folders: [(UUID, String)] = product.resources.compactMap { resource in
            guard let id = resource.projectID, let project = projects.project(id: id) else { return nil }
            return (resource.id, project.path)
        }
        guard !folders.isEmpty else { return }
        for (resourceID, path) in folders {
            let connection = await WorkspaceScan.connection(for: path)
            if connection.isExpansion { workspaceResources[resourceID] = connection }
        }
    }

    /// Connect a workspace's repositories one by one, and let go of the workspace itself.
    ///
    /// The folder is only disconnected, never touched on disk — including a `.git` a failed start
    /// may have left in it. Whose repository that is cannot be known from here, and a product
    /// screen is not the place to find out by deleting it.
    func connectRepositoriesInside(resourceID: UUID, productID: UUID) {
        guard let product = products.product(id: productID),
              let container = product.resources.first(where: { $0.id == resourceID }),
              let connection = workspaceResources[resourceID], connection.isExpansion else { return }

        // The container's access policy is the director's decision about that whole tree. Expanding
        // it must not quietly turn "ask before editing" into write access to fifteen repositories.
        let access = container.access
        let containerProjectID = container.projectID
        var added: [UUID] = []

        for folder in connection.folders {
            let project = projects.add(path: folder.path)
            enrichProjectGit(project.id)
            added.append(project.id)
            guard !product.allProjectIDs.contains(project.id) else { continue }
            products.addResource(ProductResource(name: folder.name,
                                                 kind: project.kind == .unknown ? .folder : .repository,
                                                 access: access,
                                                 projectID: project.id),
                                 to: productID)
        }
        products.removeResource(resourceID, from: productID)
        workspaceResources[resourceID] = nil

        // A conversation bound to the folder that just stopped being a resource would keep starting
        // its worker there — in the one folder the engine now refuses.
        if let containerProjectID {
            rebindChats(inProduct: productID, awayFrom: containerProjectID, to: added.first)
        }
        toast = ToastMessage(text: String(format: String(localized: "Connected %lld repositories"),
                                          connection.folders.count), kind: .success)
    }

    /// Move conversations off a folder that is no longer part of the product.
    ///
    /// A chat remembers the folder it was started in, and it wins over the product's own resources
    /// every time a message is sent. Left alone, every old chat in a repaired product would keep
    /// launching its worker in the container — the one folder the engine now refuses — and the
    /// repair would look like it had done nothing.
    ///
    /// The engine session ids go with it. A Claude session and a Codex thread belong to the
    /// directory they were started in; carrying their ids into a different repository would resume
    /// a conversation about somebody else's files. The next message starts a session where the work
    /// actually is.
    func rebindChats(inProduct productID: UUID, awayFrom projectID: UUID, to replacement: UUID?) {
        let destination = replacement.flatMap { projects.project(id: $0) }
            ?? products.product(id: productID)?.defaultProjectID.flatMap { projects.project(id: $0) }

        for chat in conversations.chats(for: productID) {
            guard let session = chat.session else { continue }
            let boundToIt = session.primaryProjectID == projectID
                || projects.project(id: projectID).map {
                    Slug.canonicalPath($0.path) == Slug.canonicalPath(session.projectPath)
                } == true
            guard boundToIt else { continue }

            guard let destination else {
                // Nothing to move it to. Dropping the binding is still better than keeping one that
                // points at a folder the product no longer has: the next message picks a primary.
                conversations.updateSession(for: chat.id) { $0.primaryProjectID = nil }
                continue
            }
            conversations.bindSession(ChatSessionBinding(primaryProjectID: destination.id,
                                                         projectPath: destination.path),
                                      to: chat.id)
        }
    }
}

// MARK: - Readiness

extension AppModel {

    /// - Parameter depth: `.free` skips the two probes that spend quota and reuses their last
    ///   verdict. The background refresh passes it; anything a person or a dispatch is waiting on
    ///   asks for the full check.
    func refreshReadiness(force: Bool = false,
                          depth: PreflightRunner.Depth = .full) async {
        if !force, let checked = readinessCheckedAt, Date().timeIntervalSince(checked) < 1200 { return }
        readinessChecking = true
        await readiness.run(model: self, depth: depth)
        await refreshEngineBlocker()
        readinessChecking = false
        readinessCheckedAt = Date()
        liftResolvedReadinessHolds()
    }

    private func liftResolvedReadinessHolds() {

        for task in backlog.tasks where !task.holds.isEmpty {
            let still = task.holds.filter { holdStillApplies($0, for: task) }
            guard still.count != task.holds.count else { continue }

            if still.isEmpty {
                backlog.setHolds(task.id, [])
                backlog.setExternalBlocker(task.id, nil)
                if let productID = productID(for: task) {
                    conversations.postEventOnce(
                        String(format: String(localized: "Everything “%@” needs is in place — starting it."), task.title),
                        productID: productID, tone: .neutral, taskID: task.id)
                }

                if task.autoResume, let fresh = backlog.task(id: task.id), fresh.state == .ready {
                    dispatch(task: fresh, userInitiated: false)
                }
            } else {

                backlog.setHolds(task.id, still)
                backlog.setExternalBlocker(task.id, still.map(\.sentence).joined(separator: " · "))
            }
        }

        let prefix = String(localized: "Waiting on: ").trimmingCharacters(in: .whitespaces)
        for task in backlog.tasks where task.holds.isEmpty {
            guard let blocker = task.externalBlocker, blocker.hasPrefix(prefix) else { continue }
            let reasons = PreflightRunner.reasonsBlockingDispatch(
                summary: readiness.summary,
                deliversPullRequest: deliversPullRequest(task),
                needsAppDriving: task.surfaceVisual)
            guard reasons.isEmpty else { continue }
            backlog.setExternalBlocker(task.id, nil)
            if let productID = productID(for: task) {
                conversations.postEventOnce(
                    String(format: String(localized: "Everything “%@” needs is in place — starting it."), task.title),
                    productID: productID, tone: .neutral, taskID: task.id)
            }
        }
    }

    func holdStillApplies(_ hold: TaskHold, for task: BacklogTask) -> Bool {
        let fm = FileManager.default
        let path = hold.path.isEmpty ? (task.projectPath ?? "") : hold.path
        switch ReadinessGap.Kind(rawValue: hold.kind) {
        case .folderMissing:
            var isDir: ObjCBool = false
            return !(fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
        case .folderUnreadable:
            return !fm.isReadableFile(atPath: path)
        case .nowhereToWrite:

            guard let project = projects.project(path: path) else { return true }
            let writable = products.products.contains { $0.writableProjectIDs.contains(project.id) }
            return !writable
        case .missingTool:
            guard readinessCheckedAt != nil else { return true }
            return PreflightRunner.reasonsBlockingDispatch(
                summary: readiness.summary,
                deliversPullRequest: deliversPullRequest(task),
                needsAppDriving: task.surfaceVisual).contains(hold.what)
        default:

            return false
        }
    }

    func blockedByReadiness(task: BacklogTask) -> Bool {

        guard readinessCheckedAt != nil else {
            if !readinessChecking { Task { await refreshReadiness(force: true) } }
            if let productID = productID(for: task) {
                conversations.postEventOnce(
                    String(localized: "Checking what Bulava needs before starting — one moment."),
                    productID: productID, tone: .neutral, taskID: task.id)
            }
            return true
        }

        let reasons = PreflightRunner.reasonsBlockingDispatch(
            summary: readiness.summary,
            deliversPullRequest: deliversPullRequest(task),
            needsAppDriving: task.surfaceVisual)
        guard !reasons.isEmpty else { return false }

        let joined = reasons.joined(separator: " · ")

        let blocker = String(format: String(localized: "Waiting on: %@"), joined)
        if task.externalBlocker != blocker {
            backlog.setExternalBlocker(task.id, blocker)
            if let productID = productID(for: task) {
                conversations.postEventOnce(
                    String(format: String(localized: "Cannot start work yet — %@"), joined),
                    productID: productID, tone: .attention, taskID: task.id)
            }
            toast = ToastMessage(text: String(localized: "Bulava is not ready to work — open Check readiness"),
                                 kind: .error)
        }
        return true
    }

    func deliversPullRequest(_ task: BacklogTask) -> Bool {
        guard let projectID = task.projectID, let project = projects.project(id: projectID) else {
            return false
        }
        return project.deliveryMode == .client
    }
}

// MARK: - What is actually waiting on the director

extension AppModel {

    struct PendingDecision: Identifiable, Sendable {
        var id: UUID
        var title: String
        var productName: String

        var needs: [String]
        var outcome: String?

        var hasRealReason: Bool = true
    }

    nonisolated static func reportWrittenAt(_ dir: URL) -> Date? {
        let url = dir.appendingPathComponent("report.json")
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    nonisolated static func hasStopped(_ task: BacklogTask) -> Bool {
        switch task.state {
        case .review, .blocked, .failed: return true
        default: return false
        }
    }

    func pendingDecisions() async -> [PendingDecision] {
        var out: [PendingDecision] = []
        for task in backlog.tasks where task.state == .blocked {
            let product = productID(for: task).flatMap { products.product(id: $0) }
            var needs: [String] = []
            if let runID = task.boundRunID {
                let findings = await client.runFindings(runID: runID)
                needs = findings
                    .filter { ["blocker", "needs_scope", "needs-user"].contains($0.cls.lowercased()) }
                    .map(\.text)
            }

            if needs.isEmpty, let path = task.projectPath,
               let reason = await client.reviewReason(slug: Slug.forPath(path)) {
                needs = [reason]
            }

            if needs.isEmpty, let blocker = task.externalBlocker { needs = [blocker] }
            var explained = !needs.isEmpty
            if needs.isEmpty, task.lastOutcome != nil {
                needs = [String(localized: "The run stopped and did not say why in a form I can read. What it did is in the report.")]
                explained = false
            }
            out.append(PendingDecision(id: task.id, title: task.title,
                                       productName: product?.name ?? "",
                                       needs: needs, outcome: task.lastOutcome,
                                       hasRealReason: explained))
        }
        return out
    }

    func surfacePendingDecisions() async {
        for decision in await pendingDecisions() {
            guard let task = backlog.task(id: decision.id),
                  let productID = productID(for: task) else { continue }

            guard !decision.needs.isEmpty, decision.hasRealReason else { continue }
            let body = decision.needs
                .map { String($0.prefix(700)) }
                .joined(separator: "\n\n")
            conversations.postEventOnce(
                String(format: String(localized: "“%@” is waiting on you. What the worker itself said it needs:\n\n%@"),
                       task.title, body),
                productID: productID, tone: .attention, taskID: task.id)
        }
    }
}

// MARK: - Finishing what a silent worker left behind

extension AppModel {

    func surfaceUndeliveredWork(_ runs: [SupervisorInstance]? = nil) {
        for inst in runs ?? instances {
            guard let reason = inst.injectFailure else { continue }

            let mine = backlog.tasks.first { task in
                if let id = inst.injectFailureDispatchID, let bound = task.boundDispatchID { return bound == id }
                return task.boundRunID == inst.runID && task.dispatchedAt != nil
            }
            guard let task = mine, task.state == .executing || task.state == .verifying else { continue }
            guard !undeliveredSeen.contains(task.id) else { continue }
            undeliveredSeen.insert(task.id)

            Trace.note("undelivered", task: task.id, dispatch: inst.injectFailureDispatchID,
                       project: inst.projectPath, detail: reason)
            backlog.undoDispatch(task.id)
            if let productID = productID(for: task) {
                conversations.postEventOnce(
                    String(format: String(localized: "“%@” did not reach the worker (%@). The session started and the task never arrived, so nothing was running. I have put it back — start it again."),
                           task.title, reason),
                    productID: productID, tone: .problem, taskID: task.id)
            }
            note(.taskStateChanged, .problem, "Задача не дійшла до воркера: «\(task.title)»",
                 detail: reason, projectPath: task.projectPath, taskID: task.id, link: .task(task.id))
        }
    }

    func resolveSilentlyFinishedRuns() async {

        for task in backlog.tasks where [.executing, .verifying, .blocked].contains(task.state) {
            guard task.externalBlocker == nil else { continue }
            guard let inst = liveInstance(for: task), inst.stalled,
                  inst.doneResult == nil, inst.pendingQuestion == nil else { continue }

            guard let manifest = await client.reportManifest(task8: task.reportKey),
                  manifest.hasContent else { continue }
            guard backlog.task(id: task.id)?.state == task.state else { continue }

            backlog.setState(task.id, .review)
            if let productID = productID(for: task) {
                conversations.postEventOnce(
                    String(format: String(localized: "“%@” finished but never signed off. The report is on disk, so it is on your desk — nothing was merged."),
                           task.title),
                    productID: productID, tone: .attention, taskID: task.id)
            }
            note(.workerFinished, .attention,
                 "Воркер не оголосив результат: «\(task.title)» — звіт на диску, ставлю на ревʼю",
                 detail: "stalled + report present → .review (не approved: гейт приймання лишається)",
                 projectPath: task.projectPath, taskID: task.id, link: .review(task.id))

            _ = await client.stopNightShift(project: task.projectPath ?? "")
            _ = await client.killSession("night-\(Slug.forPath(task.projectPath ?? ""))")
        }
    }
}

// MARK: - Work items in the conversation

extension AppModel {

    func openItems(for productID: UUID) -> [WorkItem] {
        workItems.items(forProductID: productID)
            .filter { !isItemFinished($0) }
            .sorted(by: WorkItemStore.precedes)
    }

    func openItems(inChat chatID: UUID?, productID: UUID) -> [WorkItem] {
        let home = homeChatID(for: productID)
        return openItems(for: productID).filter { owningChat($0.chatID, home: home) == chatID }
    }

    func looseTasks(inChat chatID: UUID?, productID: UUID) -> [BacklogTask] {
        looseTasks(for: productID).filter { chatShowing($0, productID: productID) == chatID }
    }

    func chatShowing(_ task: BacklogTask, productID: UUID) -> UUID? {
        let asked = workItems.item(forStreamID: task.id)?.chatID ?? task.chatID
        return owningChat(asked, home: homeChatID(for: productID))
    }

    private func owningChat(_ asked: UUID?, home: UUID?) -> UUID? {
        guard let asked, conversations.chat(id: asked) != nil else { return home }
        return asked
    }

    private func homeChatID(for productID: UUID) -> UUID? {
        let mine = conversations.chats.filter { $0.productID == productID }
        let live = mine.filter { !$0.archived }
        return (live.isEmpty ? mine : live).min { $0.createdAt < $1.createdAt }?.id
    }

    func looseTasks(for productID: UUID) -> [BacklogTask] {
        openTasks(for: productID).filter { workItems.item(forStreamID: $0.id) == nil }
    }

    func openItemReport(_ item: WorkItem) {
        let tasks = streamTasks(of: item)
        guard !tasks.isEmpty else {
            toast = ToastMessage(text: String(localized: "No report yet for this task"), kind: .info)
            return
        }
        guard item.isMultiStream else { openReport(tasks[0]); return }
        guard !preparingReport.contains(item.id) else { return }
        markPreparing(item.id)

        let title = item.title
        let productName = products.product(id: item.productID)?.name ?? ""
        let key = String(item.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let delivered = deliveredStreamCount(item)
        let failed = failedStreamCount(item)
        let unfinished = item.streams.count - delivered - failed
        let missing = item.missingVariants

        Task {
            var sections: [ReportHTML.ItemSection] = []
            for (index, stream) in item.streams.enumerated() {
                guard let task = backlog.task(id: stream.id) else { continue }
                sections.append(await itemSection(number: index + 1, stream: stream, task: task))
            }
            let url = await client.renderItemReport(
                itemKey: key, title: title, productName: productName, sections: sections,
                delivered: delivered, failed: failed, unfinished: unfinished, missing: missing,
                generatedAt: Fmt.stamp(Date()))
            clearPreparing(item.id)
            guard let url else {
                toast = ToastMessage(text: String(localized: "Could not build the report"), kind: .error)
                return
            }
            reportViewer = ReportViewer(taskID: nil, itemID: item.id, title: title,
                                        htmlURL: url, isVideo: false)
        }
    }

    func openProductReport(productID: UUID) {
        guard let product = products.product(id: productID) else { return }

        let finished = tasks(for: productID)
            .filter { Self.hasStopped($0) || isFinished($0) }
            .sorted { ($0.dispatchedAt ?? $0.createdAt) > ($1.dispatchedAt ?? $1.createdAt) }
        guard !finished.isEmpty else {
            toast = ToastMessage(text: String(localized: "Nothing has finished in this product yet"), kind: .info)
            return
        }
        let key = "product-" + String(productID.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        guard !preparingReport.contains(productID) else { return }
        markPreparing(productID)

        let shown = Array(finished.prefix(20))
        let openCount = openTasks(for: productID).count

        Task {
            var sections: [ReportHTML.ItemSection] = []
            for (index, task) in shown.enumerated() {
                let stream = WorkItem.Stream(id: task.id, title: task.title,
                                             projectName: name(of: task.projectPath) ?? "")
                sections.append(await itemSection(number: index + 1, stream: stream, task: task))
            }
            let delivered = sections.filter { $0.outcome == .delivered }.count
            let failed = sections.filter { $0.outcome == .failed }.count
            let unfinished = sections.count - delivered - failed
            let url = await client.renderItemReport(
                itemKey: key,
                title: String(format: String(localized: "%@ — everything done so far"), product.name),
                productName: product.name, sections: sections,
                delivered: delivered, failed: failed, unfinished: unfinished,
                missing: max(0, finished.count - shown.count),
                generatedAt: Fmt.stamp(Date()))
            clearPreparing(productID)
            guard let url else {
                toast = ToastMessage(text: String(localized: "Could not build the report"), kind: .error)
                return
            }
            reportViewer = ReportViewer(taskID: nil, itemID: productID,
                                        title: product.name, htmlURL: url, isVideo: false)
            note(.reportReady, .good, "Звіт по всій роботі: \(product.name)",
                 taskID: nil, link: .report(productID))
            _ = openCount
        }
    }

    private func itemSection(number: Int, stream: WorkItem.Stream,
                             task: BacklogTask) async -> ReportHTML.ItemSection {
        let package = await loadReview(for: task)
        let ev = evidence(for: task, package: package)
        let manifest = await client.reportManifest(task8: task.reportKey)
        let state = workState(of: task)

        let outcome: ReportHTML.ItemSection.Outcome = switch state {
        case .reportReady, .done: .delivered
        case .failed:             .failed
        default:                  .unfinished
        }

        let hasResidue = !(ev?.criteria.isEmpty ?? true) || !(package?.findings.isEmpty ?? true)
        let absence: String? = {
            if manifest?.hasContent == true { return nil }

            if !task.wantsReport {
                return String(localized: "Groundwork: it brought the workspace to a known state. Its checks are below.")
            }
            switch state {
            case .failed:  return hasResidue
                ? String(localized: "This stream failed before it produced a result. The checks and the reviewer's notes below are what it left behind.")
                : String(localized: "This stream failed before it produced a result, and left nothing behind to look at.")
            case .running: return String(localized: "This stream was still running when the report was built.")
            case .planned: return String(localized: "This stream had not started yet.")
            default:       return String(localized: "This stream produced no before/after — nothing visual was captured.")
            }
        }()

        return ReportHTML.ItemSection(
            number: number,
            title: stream.title,
            projectName: stream.projectName.isEmpty ? (package?.projectName ?? "") : stream.projectName,
            outcome: outcome,
            stateLabel: String(localized: state.labelKey),
            gateBlocker: approvalBlocker(task: task, package: package),
            summary: manifest?.summary,
            manifest: manifest,
            assetPrefix: "\(task.reportKey)/",
            criteria: (ev?.criteria ?? []).map {
                ReportHTML.ItemSection.Criterion(name: $0.criterion, status: $0.status.rawValue,
                                                 command: $0.command, note: $0.note)
            },
            evidenceOverall: ev?.overallStatus.rawValue,
            commits: package?.commits ?? [],
            filesChanged: package?.changedFiles.count ?? 0,
            insertions: package?.insertions ?? 0,
            deletions: package?.deletions ?? 0,
            findings: package?.findings ?? [],
            absenceNote: absence)
    }

    func deliveredParts(of item: WorkItem) -> [BacklogTask] {
        streamTasks(of: item).filter { $0.state == .review || $0.state == .merged }
    }

    nonisolated static func aimOfRemark(parts: [UUID], explicit: UUID?) -> UUID? {
        if let explicit, parts.contains(explicit) || parts.isEmpty { return explicit }
        if let explicit { return explicit }
        if parts.count == 1 { return parts[0] }
        return nil
    }

    func beginAskingChangesOnItem(_ item: WorkItem, streamID: UUID? = nil) {
        let parts = deliveredParts(of: item)
        if let aim = Self.aimOfRemark(parts: parts.map(\.id), explicit: streamID),
           let aimed = parts.first(where: { $0.id == aim }) ?? backlog.task(id: aim) {
            beginAskingChanges(aimed); return
        }
        if parts.count > 1 {
            let names = parts.enumerated()
                .map { "\($0.offset + 1). \(partName($0.element, in: item))" }
                .joined(separator: "\n")
            postForemanText(String(format: String(localized: "Which part do you mean?\n%@"), names),
                            productID: item.productID)
            return
        }
        guard let target = parts.first ?? streamTasks(of: item).last else { return }
        beginAskingChanges(target)
    }

    func partName(_ task: BacklogTask, in item: WorkItem) -> String {
        if let stream = item.streams.first(where: { $0.id == task.id }) {
            if !stream.projectName.isEmpty { return stream.projectName }
            if !stream.title.isEmpty { return stream.title }
        }
        return task.title
    }

    func openVariantGallery(_ item: WorkItem) { variantGalleryItemID = item.id }
}

// MARK: - What a conversation may open

extension AppModel {

    func fileRoots(forProductID id: UUID?, chatID: UUID? = nil) -> [URL] {
        guard let id else { return [] }
        var roots: [URL] = []

        if let product = products.product(id: id) {
            for resource in product.resources {
                guard let projectID = resource.projectID,
                      let project = projects.project(id: projectID),
                      !project.path.isEmpty else { continue }
                roots.append(URL(fileURLWithPath: project.path))
            }
        }

        for task in backlog.tasks where task.productID == id {
            roots.append(settings.paths.reportDir(task8: task.reportKey))
        }
        for item in workItems.items where item.productID == id {
            let key = String(item.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            roots.append(settings.paths.reportDir(task8: key))
        }
        let productKey = "product-" + String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        roots.append(settings.paths.reportDir(task8: productKey))

        if let chatID, let session = conversations.chat(id: chatID)?.session {
            for path in session.reportPaths where !path.isEmpty {
                roots.append(URL(fileURLWithPath: path))
            }
        }

        return roots.filter { $0.path != "/" && FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Skills

extension AppModel {

    private func actionProjectPath(for skill: InstalledSkill, productID: UUID?) -> String? {
        if !skill.projectPath.isEmpty { return skill.projectPath }
        if skill.scope == .project {

            guard let productID, let path = skillProjectPath(productID) else { return nil }
            return path
        }
        if let productID, let path = skillProjectPath(productID) { return path }
        return projects.projects.first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func skillProjectPath(_ productID: UUID) -> String? {
        guard let product = products.product(id: productID) else { return nil }
        if let id = product.defaultProjectID, let p = projects.project(id: id), !p.path.isEmpty {
            return p.path
        }

        for resource in product.resources {
            guard let id = resource.projectID, let p = projects.project(id: id),
                  !p.path.isEmpty else { continue }
            return p.path
        }
        return nil
    }

    func skillInventory(fast: Bool = false) async -> SkillInventory {
        await client.skillInventory(projectPaths: projects.projects.map(\.path), fast: fast)
    }

    func mcpInventory(fast: Bool = false) async -> MCPInventory {
        await client.mcpInventory(fast: fast)
    }

    func skillProjectPaths(_ productID: UUID) -> [String] {
        guard let product = products.product(id: productID) else { return [] }
        return product.resources.compactMap { resource in
            guard let id = resource.projectID, let p = projects.project(id: id),
                  !p.path.isEmpty else { return nil }
            return p.path
        }
    }

    @discardableResult
    func removeSkill(_ skill: InstalledSkill, productID: UUID?) async -> (ok: Bool, message: String) {
        guard let path = actionProjectPath(for: skill, productID: productID) else {
            let m = String(localized: "No project to act on.")
            toast = ToastMessage(text: m, kind: .error)
            return (false, m)
        }
        let r = await client.removeSkill(skill, projectPath: path)
        note(.taskEdited, r.ok ? .info : .problem,
             r.ok ? "Скіл «\(skill.name)» видалено" : "Не вдалося видалити скіл «\(skill.name)»",
             detail: r.message, projectPath: path)
        toast = ToastMessage(text: r.ok ? String(format: String(localized: "Deleted %@"), skill.name)
                                        : r.message,
                             kind: r.ok ? .success : .error)
        return r
    }

    @discardableResult
    func updateSkill(_ skill: InstalledSkill, productID: UUID?) async -> (ok: Bool, message: String) {
        guard let path = actionProjectPath(for: skill, productID: productID) else {
            let m = String(localized: "No project to act on.")
            toast = ToastMessage(text: m, kind: .error)
            return (false, m)
        }
        toast = ToastMessage(text: String(format: String(localized: "Updating %@ — it is re-audited first"),
                                          skill.name), kind: .info)
        let r = await client.updateSkill(skill, projectPath: path)
        note(.taskEdited, r.ok ? .info : .problem,
             r.ok ? "Скіл «\(skill.name)» оновлено" : "Оновлення скіла «\(skill.name)» не пройшло",
             detail: r.message, projectPath: path)
        toast = ToastMessage(text: r.ok ? String(format: String(localized: "Updated %@"), skill.name)
                                        : r.message,
                             kind: r.ok ? .success : .error)
        return r
    }
}
