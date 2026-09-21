import SwiftUI
import OSLog
import AppKit

extension AppModel {

    func addProjectViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Connect")
        panel.message = String(localized: "Choose a folder for Bulava to work in")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await connectFolder(at: url.path) }
    }

    /// Turn a chosen folder into a product.
    ///
    /// A workspace becomes one product made of its repositories, not one project laid over all of
    /// them: that is what the director would have built by hand, and the only shape a night run can
    /// actually work in. The scan is off the main actor — a nine-gigabyte folder must not freeze
    /// the window while it is looked at.
    func connectFolder(at path: String) async {
        let connection = await WorkspaceScan.connection(for: path)

        let resources: [ProductResource] = connection.folders.map { folder in
            let project = projects.add(path: folder.path)
            enrichProjectGit(project.id)
            return ProductResource(name: folder.name,
                                   kind: project.kind == .unknown ? .folder : .repository,
                                   access: .workspace,
                                   projectID: project.id)
        }
        guard !resources.isEmpty else {
            toast = ToastMessage(text: String(localized: "Nothing to connect in that folder."), kind: .error)
            return
        }

        let name = ((connection.container ?? connection.folders[0].path) as NSString).lastPathComponent
        let product = products.add(name: name, resources: resources)
        open(product: product.id)
        toast = connection.isExpansion
            ? ToastMessage(text: String(format: String(localized: "Added %1$@ — %2$@"), product.name,
                                        String(format: String(localized: "%lld repositories"), resources.count)),
                           kind: .success)
            : ToastMessage(text: String(format: String(localized: "Added %@"), product.name), kind: .success)
    }

    nonisolated static func logDispatch(_ line: String) {

        Log.dispatch.notice("\(line, privacy: .public)")
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/supervisor/app-dispatch.log")

        guard let data = "\(Trace.stamp(Date()))  \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    private func refuseStructurally(task: BacklogTask, reason: String, note noteTitle: String,
                                    blocker: String, toast toastText: String,
                                    tone: ConversationEntry.Tone = .problem) {
        let firstTime = task.externalBlocker != blocker
        backlog.setExternalBlocker(task.id, blocker)
        guard firstTime else { return }
        if let productID = productID(for: task) {
            conversations.postEventOnce(reason, productID: productID, tone: tone, taskID: task.id)
        }
        note(.taskStateChanged, tone == .problem ? .problem : .attention, noteTitle,
             detail: reason, projectPath: task.projectPath, taskID: task.id, link: .task(task.id))
        toast = ToastMessage(text: toastText, kind: tone == .problem ? .error : .info)
    }

    func dispatch(task: BacklogTask, continuing: Bool = false, autostartRunner: Bool = true,
                  userInitiated: Bool = true, onDispatched: (() -> Void)? = nil) {
        guard let path = task.projectPath else {
            toast = ToastMessage(text: "Task has no project", kind: .error); onDispatched?(); return
        }

        if userInitiated, let productID = task.productID { products.worked(productID) }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue

        if !exists || !FileManager.default.isReadableFile(atPath: path) {
            let proj = name(of: path) ?? task.title
            let msg = exists
                ? "Теку проєкту «\(proj)» не читаю (\(path)). Дай Bulava доступ до неї в Системних налаштуваннях або підключи інший шлях."
                : "Теку проєкту «\(proj)» не знайдено (\(path)). Її перемістили чи видалили? Онови шлях проєкту й запусти ще раз."

            refuseStructurally(task: task, reason: msg,
                               note: exists ? "Не запустив «\(task.title)» — теку не читаю"
                                            : "Не запустив «\(task.title)» — теки проєкту нема",
                               blocker: exists
                                   ? String(format: String(localized: "Folder cannot be read: %@"), path)
                                   : String(format: String(localized: "Folder not found: %@"), path),
                               toast: exists
                                   ? String(format: String(localized: "%@ cannot be read — see the conversation"), proj)
                                   : String(format: String(localized: "%@ not found — see the conversation"), proj))
            onDispatched?(); return
        }
        if backlog.isBlocked(task) {
            toast = ToastMessage(text: backlog.blockReason(task) ?? "Task is blocked", kind: .info); onDispatched?(); return
        }

        let projectKey = Slug.canonicalPath(path)
        if launching.contains(projectKey) {
            if userInitiated, let productID = productID(for: task) {
                conversations.postEventOnce(
                    String(format: String(localized: "“%@” waits its turn — %@ is busy with other work."),
                           task.title, name(of: path) ?? path),
                    productID: productID, tone: .neutral, taskID: task.id)
            }
            onDispatched?(); return
        }

        if blockedByReadiness(task: task) { onDispatched?(); return }

        if let productID = productID(for: task),
           let project = projects.project(path: path),
           products.product(id: productID)?.access(forProjectID: project.id) == .source {
            let msg = "«\(project.name)» підключено лише для читання, тому я туди не пишу. "
                    + "Скажи, якщо треба змінити режим доступу, або куди зробити цю роботу."
            refuseStructurally(task: task, reason: msg,
                               note: "Не запустив «\(task.title)» — ресурс лише для читання",
                               blocker: String(format: String(localized: "%@ is read-only"), project.name),
                               toast: String(format: String(localized: "%@ is connected read-only"), project.name),
                               tone: .attention)
            onDispatched?(); return
        }

        if let working = instances.first(where: { $0.slug == Slug.forPath(path) && $0.watchdogAlive && $0.doneResult == nil }) {

            if userInitiated {
                toast = ToastMessage(
                    text: String(format: String(localized: "%@ is busy — this stays next in line"),
                                 working.projectName),
                    kind: .info)
                if let productID = productID(for: task) {
                    conversations.postEventOnce(
                        String(format: String(localized: "“%@” waits its turn — %@ is busy with other work."),
                               task.title, working.projectName),
                        productID: productID, tone: .neutral, taskID: task.id)
                }
            }
            onDispatched?(); return
        }
        let hasFinishedLingering = instances.contains { $0.slug == Slug.forPath(path) && $0.watchdogAlive && $0.doneResult != nil }

        let strategy = RunStrategy.decide(for: task, projectIsBusy: hasFinishedLingering)
            .speaking(settings.reportLanguage.reportLanguageName)
            .onBranch(task.requestedBranch)
            .written(by: settings.reportWriter.rawValue)
            .overridden(by: settings, claudeModels: claudeModels)

        if !continuing {
            verifiedEvidence[task.id] = nil
            reportPaths[task.id] = nil
        }
        let text = dispatchInstructions(for: task, continuing: continuing)

        let spec = task.runSpec(projectPath: path)

        backlog.markDispatched(task.id, keepBindings: continuing)

        let dispatchID = UUID().uuidString
        backlog.bindDispatch(task.id, dispatchID: dispatchID)
        Trace.note(continuing ? "dispatch-continue" : "dispatch", task: task.id, dispatch: dispatchID,
                   report: task.reportKey, project: path,
                   detail: "isolated=\(strategy.isolated) branch=\(task.requestedBranch ?? "—")")
        busy = true
        launching.insert(projectKey)
        Task {
            defer { onDispatched?(); launching.remove(projectKey) }

            var execPath = path

            let sessionName = "night-\(Slug.forPath(path))"
            let noInstance = !hasFinishedLingering
                && !instances.contains { $0.slug == Slug.forPath(path) }

            var orphanSession = false
            if noInstance { orphanSession = await client.sessionExists(sessionName) }
            if (hasFinishedLingering || orphanSession), task.worktree == nil {
                if orphanSession {
                    Self.logDispatch("orphan session \(sessionName) (no instance) — closing before dispatch")
                }
                _ = await client.stopNightShift(project: path)
                _ = await client.killSession(sessionName)
                try? await Task.sleep(for: .milliseconds(600))
            }
            if let wt = task.worktree {
                execPath = wt
            } else if strategy.isolated {
                if let wt = await client.createWorktree(projectPath: path, taskID: String(task.id.uuidString.prefix(8))) {
                    execPath = wt; backlog.setWorktree(task.id, wt)
                }
            }

            let result: CommandResult
            if await client.canDispatchConcurrently {

                result = await client.dispatchConcurrent(project: execPath, task: text, runspec: spec,
                                                         strategy: strategy, reportKey: task.reportKey,
                                                         dispatchID: dispatchID)
            } else {
                let add = await client.queueAdd(project: execPath, task: text)
                if add.ok, !(await client.snapshot().queue.runnerAlive) { _ = await client.queueRun(strategy: strategy) }
                result = add
            }
            busy = false

            Self.logDispatch("project=\(execPath.hasSuffix(path) || execPath == path ? path : execPath) launched=\(result.launched) exit=\(result.exitCode) ok=\(result.ok) out=[\(result.combined.replacingOccurrences(of: "\n", with: " | ").prefix(1000))]")
            Trace.note(result.ok ? "launched" : "launch-failed", task: task.id, dispatch: dispatchID,
                       project: execPath,
                       detail: "exit=\(result.exitCode) launched=\(result.launched) \(result.combined.prefix(200))")
            if result.ok {
                note(.taskDispatched, .info, "Запущено: \(task.title)",
                     projectPath: path, taskID: task.id, link: .task(task.id))
                toast = ToastMessage(text: "Dispatched “\(task.title)” — worker starting", kind: .success)
            } else {

                backlog.undoDispatch(task.id)
                launchFailures[task.id] = Date()

                let raw = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
                let reason: String
                if !result.launched {
                    reason = raw.isEmpty
                        ? "не вдалося запустити процес рушія — перевір PATH/дозволи (застосунок піднімає термінал/tmux-сесію)."
                        : "не вдалося запустити процес рушія: \(raw)"
                } else if raw.isEmpty {
                    reason = "рушій завершився без відповіді (код \(result.exitCode)). Найімовірніше застосунок чекає на дозвіл macOS — він піднімає tmux-сесію для воркера; або сесія зависла. Дай дозвіл у System Settings ▸ Privacy і спробуй ще раз."
                } else {
                    reason = raw
                }

                postForemanText("Не зміг запустити «\(task.title)»: \(reason)", link: .task(task.id))
                note(.taskStateChanged, .problem, "Запуск не вдався: «\(task.title)» (launched=\(result.launched), exit=\(result.exitCode))",
                     detail: raw.isEmpty ? "Порожній вивід рушія — див. reason." : raw,
                     projectPath: path, taskID: task.id, link: .task(task.id))
                toast = ToastMessage(text: reason, kind: .error)
            }
            await refresh()
        }
    }

    func dispatchInstructions(for task: BacklogTask, continuing: Bool = false) -> String {
        var text = task.dispatchText
        if continuing { text = continueFraming(for: task) + "\n\n" + text }
        guard task.wantsReport else { return text }
        return text + reportDirective(for: task, continuing: continuing)
    }

    private func continueFraming(for task: BacklogTask) -> String {
        var lines = ["🔁 ЦЕ ПРОДОВЖЕННЯ вже розпочатої роботи — НЕ починай з нуля, НЕ викидай уже зроблене."]
        if let b = task.boundBranch, !b.isEmpty {
            lines.append("Попередня робота вже закомічена на гілці `\(b)`. НАЙПЕРШЕ перейди на неї: `git checkout \(b)` — і продовжуй саме там.")
        }
        if let base = task.boundBaseSHA, !base.isEmpty {
            lines.append("Базовий комміт усієї задачі — `\(base)`. Звіт роби КУМУЛЯТИВНИМ: before = стан на `\(base)`, after = поточний, щоб він показував УСЮ роботу (початкову + ці правки), а не лише останні зміни.")
        }
        lines.append("Усе, що вже зроблено нормально, — залиш. Виправ лише те, що у зауваженнях рев'ю нижче, і доведи до кінця.")
        return lines.joined(separator: "\n")
    }

    private func reportDirective(for task: BacklogTask, continuing: Bool = false) -> String {
        let dir = settings.paths.reportDir(task8: task.reportKey).path
        let lang = settings.reportLanguage.reportLanguageName
        let cumulativeNote = continuing
            ? "\n(ПРОДОВЖЕННЯ: онови й РОЗШИР наявний звіт у цій теці — збережи попередні пункти, зроби before/after кумулятивними від базового комміту задачі; не видаляй уже показане.)"
            : ""
        let engineRoot = OrchestratorHome.detect()
            ?? settings.orchestratorHomePath.map { URL(fileURLWithPath: $0) }
        if let shared = Self.sharedReportDirective(engineRoot: engineRoot) {
            return "\n\n" + shared
                .replacingOccurrences(of: "{{DIR}}", with: dir)
                .replacingOccurrences(of: "{{LANG}}", with: lang)
                .replacingOccurrences(of: "{{CONTINUING}}", with: cumulativeNote)
        }
        return """

        ---
        ЗВІТ ПРО РЕЗУЛЬТАТ (обовʼязково, коли задача реально завершена — не заглушка):
        Збери справжній візуальний звіт про зміну і поклади все СЮДИ (створи теку): \(dir)\(cumulativeNote)
        Маніфест \(dir)/report.json:
        {"format":"photos"|"video"|"notes","language":"\(lang)","title":"…","summary":"1–3 речення",
         "items":[{"caption":"…","before":"before-1.png","after":"after-1.png"}],
         "video":"demo.mp4","poster":"poster.png","body":"повний markdown/текст звіту"}
        Реальні кадри/відео справжнього застосунку. Якщо зняти неможливо — напиши чому в summary.
        """
    }

    private static func sharedReportDirective(engineRoot: URL?) -> String? {
        guard let engineRoot else { return nil }
        let url = engineRoot.appendingPathComponent("supervisor/REPORT-DIRECTIVE.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.contains("{{DIR}}") else { return nil }
        return text
    }

    // MARK: Review

    func loadReview(for task: BacklogTask) async -> ReviewPackage? {
        guard let path = task.projectPath else { return nil }
        let canon = Slug.canonicalPath(path)
        let inst = snapshot.instances.first { Slug.canonicalPath($0.projectPath) == canon }
        return await client.loadReview(
            projectPath: path,
            branchHint: task.boundBranch ?? inst?.branch,
            baseHint: task.boundBaseSHA ?? inst?.baseSHA,
            baseBranchHint: task.boundBaseBranch ?? inst?.baseBranch,
            sessionID: task.boundSessionID ?? inst?.sessionID,
            runID: task.boundRunID ?? inst?.runID)
    }

    func evidence(for task: BacklogTask, package: ReviewPackage?) -> Evidence? {
        verifiedEvidence[task.id] ?? package?.evidence
    }

    func approvalBlocker(task: BacklogTask, package: ReviewPackage?) -> String? {
        AcceptanceGate.evaluate(acceptanceSnapshot(task: task, package: package))
    }

    func acceptanceSnapshot(task: BacklogTask, package: ReviewPackage?, headStable: Bool = true) -> AcceptanceSnapshot {
        let ev = evidence(for: task, package: package)
        let real = (ev?.criteria ?? []).filter { $0.status != .skipped }
        let cls: ReviewClassKind
        switch task.reviewClass {
        case .visual:        cls = .visual
        case .code:          cls = .code
        case .informational: cls = .informational
        }
        return AcceptanceSnapshot(
            reviewClass: cls,
            hasScopeViolation: package?.hasScopeViolation == true,
            disposition: package?.disposition,
            evidencePresent: ev != nil,
            evidenceOverallPass: ev?.overallStatus == .pass,
            evidenceCleanGreen: !real.isEmpty && !real.contains { $0.status != .pass || $0.exitCode != 0 },
            evidenceBoundToHead: {
                guard let ev else { return false }

                guard !ev.headSHA.isEmpty, let head = package?.headSHA, !head.isEmpty else { return true }
                return ev.headSHA == head
            }(),
            frameValid: task.reviewClass != .visual || visualFrameBlocker(package) == nil,
            headStable: headStable)
    }

    func canApprove(task: BacklogTask, package: ReviewPackage?) -> Bool {
        approvalBlocker(task: task, package: package) == nil
    }

    private func visualFrameBlocker(_ package: ReviewPackage?) -> String? {
        guard let m = package?.reportManifest, let dir = package?.reportDirectory else {
            return "Візуальна задача без before/after кадру — потрібен доказ, перш ніж приймати."
        }

        guard let item = (m.items ?? []).first(where: { ($0.before?.isEmpty == false) && ($0.after?.isEmpty == false) }) else {
            return "Нема валідної пари before/after — потрібні обидва кадри."
        }
        guard item.before != item.after else { return "before і after — той самий файл, це не пара." }

        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path
        for name in [item.before!, item.after!] {
            let url = dir.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            guard url.path == root || url.path.hasPrefix(root + "/") else { return "Кадр веде поза report-теку — відхиляю." }
            guard let data = try? Data(contentsOf: url), !data.isEmpty, NSImage(data: data) != nil else {
                return "Кадр before/after відсутній або не є картинкою."
            }
        }
        return nil
    }

    func verify(task: BacklogTask) {

        let home = OrchestratorHome.detect()?.path ?? settings.orchestratorHomePath
        guard let path = task.projectPath, let home else {
            toast = ToastMessage(text: "Set the engine path in Settings to verify", kind: .info); return
        }
        verifying.insert(task.id)
        Task {
            let sid = task.boundSessionID ?? "app-verify-\(task.id.uuidString.prefix(8))"
            let ev = await client.runVerify(projectPath: path, orchestratorHome: home, sessionID: sid)
            verifying.remove(task.id)
            if let ev {
                verifiedEvidence[task.id] = ev
                let ok = ev.overallStatus == .pass
                toast = ToastMessage(text: ok ? "Verified: build + tests pass" : "Verify: \(ev.overallStatus.rawValue)",
                                     kind: ok ? .success : .error)
            } else {
                toast = ToastMessage(text: "Verifier produced no evidence", kind: .error)
            }
        }
    }

    // MARK: Run report (before/after + HTML)

    private func reportSessionID(for task: BacklogTask) -> String {
        task.boundSessionID ?? "app-verify-\(task.id.uuidString.prefix(8))"
    }

    func reportPath(for task: BacklogTask) -> String? {
        if let p = reportPaths[task.id], FileManager.default.fileExists(atPath: p) { return p }

        let byTask = settings.paths.reportDir(task8: task.reportKey).appendingPathComponent("report.html")
        guard let path = task.projectPath,
              let base = settings.paths.artifactBase(runID: task.boundRunID, projectPath: path) else {
            return FileManager.default.fileExists(atPath: byTask.path) ? byTask.path : nil
        }

        var candidates = [byTask, base.appendingPathComponent("report/report.html")]
        if let sid = task.boundSessionID ?? newestEvidenceSID(in: base) {
            candidates.append(base.appendingPathComponent("evidence/\(sid)/report/report.html"))
        }

        let fm = FileManager.default
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
        }
        return candidates
            .filter { fm.fileExists(atPath: $0.path) }
            .max { modified($0) < modified($1) }?
            .path
    }

    private func newestEvidenceSID(in base: URL) -> String? {
        let evDir = base.appendingPathComponent("evidence")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let subs = try? FileManager.default.contentsOfDirectory(
            at: evDir, includingPropertiesForKeys: keys) else { return nil }
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return subs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .max { mtime($0) < mtime($1) }?
            .lastPathComponent
    }

    func generateReport(task: BacklogTask) {
        let home = OrchestratorHome.detect()?.path ?? settings.orchestratorHomePath
        guard let path = task.projectPath, let home else {
            toast = ToastMessage(text: "Set the engine path in Settings to build a report", kind: .info); return
        }
        guard !generatingReport.contains(task.id) else { return }
        generatingReport.insert(task.id)
        let sid = reportSessionID(for: task)
        let lang = settings.reportLanguage.reportLanguageName
        Task {
            let out = await client.generateReport(projectPath: path, orchestratorHome: home,
                                                  sessionID: sid, language: lang)
            generatingReport.remove(task.id)
            if let out {
                reportPaths[task.id] = out
                toast = ToastMessage(text: "Run report ready", kind: .success)
            } else {
                toast = ToastMessage(text: "Could not build the report (see engine path)", kind: .error)
            }
        }
    }

    func deliveryMode(for task: BacklogTask) -> DeliveryMode {
        task.projectID.flatMap { projects.project(id: $0)?.deliveryMode } ?? .personal
    }

    func approve(task: BacklogTask, package: ReviewPackage, onResult: ((String, Bool) -> Void)? = nil) {
        guard let path = task.projectPath else { onResult?("У задачі нема проєкту — не можу прийняти.", false); return }
        busy = true
        Task {

            let package = await loadReview(for: task) ?? package
            if let blocker = approvalBlocker(task: task, package: package) {
                busy = false; toast = ToastMessage(text: blocker, kind: .error); onResult?(blocker, false); return
            }
            let mode = deliveryMode(for: task)

            let hasRemote = (task.projectID.flatMap { projects.project(id: $0)?.gitRemote }?.isEmpty == false)
            let usePR = !mode.mergesOnApprove && hasRemote
            if !usePR {
                let result = await client.merge(projectPath: path, branch: package.branch, target: package.mergeTarget)
                busy = false
                let localNote = (!mode.mergesOnApprove && !hasRemote) ? " (локальний git — без PR)" : ""
                if result.isSuccess {
                    backlog.setState(task.id, .merged)
                    note(.merged, .good, "Прийнято та злито: \(task.title)",
                         projectPath: path, taskID: task.id, link: .task(task.id))
                    toast = ToastMessage(text: "Approved & merged \(package.branch ?? "") → \(package.mergeTarget ?? "")", kind: .success)
                    onResult?("Готово — змерджив \(package.branch ?? "гілку") → \(package.mergeTarget ?? "основну")\(localNote). «\(task.title)» закрито.", true)
                } else {

                    toast = ToastMessage(text: result.message, kind: .error)
                    onResult?("Мердж не пройшов: \(result.message). Лишив у Review — глянь вручну.", false)
                }
            } else {

                guard let branch = package.branch, let target = package.mergeTarget else {
                    busy = false
                    toast = ToastMessage(text: "Can't open a PR — no branch/target resolved", kind: .error)
                    onResult?("Не зміг відкрити PR — не вдалось визначити гілку/ціль. Глянь у Review.", false)
                    return
                }
                let pr = await client.openPR(projectPath: path, branch: branch, target: target, title: task.title)
                busy = false
                if pr.ok {
                    backlog.setState(task.id, .approved)
                    note(.prOpened, .good, "Прийнято · PR відкрито: \(task.title)",
                         projectPath: path, taskID: task.id, link: .task(task.id))
                    toast = ToastMessage(text: "Approved · PR opened \(branch) → \(target)", kind: .success)
                    if let urlStr = pr.url, let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
                    onResult?("PR відкрито: \(branch) → \(target)\(pr.url.map { "\n\($0)" } ?? ""). Відкрив у браузері.", true)
                } else {
                    toast = ToastMessage(text: pr.message, kind: .error)
                    onResult?("Не зміг відкрити PR: \(pr.message).", false)
                }
            }
            await refresh()
        }
    }

    func mergeLocally(task: BacklogTask, package: ReviewPackage, onResult: ((String, Bool) -> Void)? = nil) {
        guard let path = task.projectPath else { onResult?("У задачі нема проєкту — не можу змерджити.", false); return }
        busy = true
        Task {

            let package = await loadReview(for: task) ?? package
            if let blocker = approvalBlocker(task: task, package: package) {
                busy = false; toast = ToastMessage(text: blocker, kind: .error); onResult?(blocker, false); return
            }
            let result = await client.mergeToMainLocal(projectPath: path, branch: package.branch,
                                                        target: package.mergeTarget, label: task.title)
            busy = false
            if result.isSuccess {
                backlog.setState(task.id, .merged)
                closeFinishedSession(path)
                note(.merged, .good, "Змерджено локально в \(package.mergeTarget ?? "main"): \(task.title)",
                     projectPath: path, taskID: task.id, link: .task(task.id))
                toast = ToastMessage(text: "Merged \(package.branch ?? "") → \(package.mergeTarget ?? "")", kind: .success)
                onResult?("Готово — локально змерджив \(package.branch ?? "гілку") → \(package.mergeTarget ?? "main"). «\(task.title)» закрито.", true)
            } else {
                toast = ToastMessage(text: result.message, kind: .error)
                onResult?("Локальний мердж не пройшов: \(result.message). Лишив у Review — глянь вручну.", false)
            }
            await refresh()
        }
    }

    func approveOnly(task: BacklogTask, package: ReviewPackage?) {
        if let blocker = approvalBlocker(task: task, package: package) {
            toast = ToastMessage(text: blocker, kind: .info); return
        }
        backlog.setState(task.id, .approved)
        note(.approved, .good, "Прийнято: \(task.title)",
             projectPath: task.projectPath, taskID: task.id, link: .task(task.id))
        toast = ToastMessage(text: "Approved", kind: .success)
    }

    func markReviewed(task: BacklogTask) {

        guard task.reviewClass == .informational else {
            toast = ToastMessage(text: "Ця задача не інформаційна — приймай через Review з доказами.", kind: .info); return
        }
        backlog.setState(task.id, .approved)
        note(.approved, .good, "Переглянуто: \(task.title)",
             projectPath: task.projectPath, taskID: task.id, link: .task(task.id))
        toast = ToastMessage(text: "Marked reviewed", kind: .success)
        if let p = task.projectPath { closeFinishedSession(p) }
    }

    func closeOut(task: BacklogTask, reason: String? = nil) {
        let why = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.state.isActive || task.state == .blocked || task.state == .needsClarification,
           let path = task.projectPath {
            Task { _ = await client.stopNightShift(project: path); await refresh() }
        }
        backlog.setState(task.id, .closed)
        note(.closedOut, .info, "Закрито: \(task.title)",
             detail: why?.isEmpty == false ? why : nil,
             projectPath: task.projectPath, taskID: task.id, link: .task(task.id))
        if let p = task.projectPath { closeFinishedSession(p) }
        toast = ToastMessage(text: String(localized: "Closed"), kind: .success)
    }

    func closeOut(item: WorkItem, reason: String? = nil) {
        for id in item.streamIDs {
            guard let task = backlog.task(id: id), !isFinished(task) else { continue }
            closeOut(task: task, reason: reason)
        }
    }

    func requestChanges(task: BacklogTask, feedback: String) {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        backlog.appendFeedback(task.id, text)
        Trace.note("changes-requested", task: task.id, dispatch: task.boundDispatchID,
                   project: task.projectPath, detail: "«\(text.prefix(160))»")
        note(.changesRequested, .info, "Повернено з правками: \(task.title)",
             detail: text, projectPath: task.projectPath, taskID: task.id, link: .task(task.id))
        guard let updated = backlog.task(id: task.id) else { return }

        let hasLiveSession = task.projectPath.map { p in
            instances.contains { $0.slug == Slug.forPath(p) && $0.watchdogAlive && $0.doneResult == nil }
        } ?? false
        if hasLiveSession {
            relayToWorker(updated, framing: .freeform("Правки від рев'ю — виправ і доведи до кінця, не переробляючи вже готове:\n\(text)"),
                          onNoSession: { self.dispatch(task: updated, continuing: true) })
            toast = ToastMessage(text: "Continuing in the live session", kind: .info)
        } else {
            dispatch(task: updated, continuing: true)
            toast = ToastMessage(text: "Continuing on its branch with your changes", kind: .info)
        }
    }

    // MARK: Decisions / parked work

    func retryParked(_ entry: QueueDoneEntry) {
        busy = true
        Task {
            let add = await client.queueAdd(project: entry.projectPath, task: entry.task)
            if add.ok {
                await client.clearParked(dirName: entry.dirName)
                if !snapshot.queue.runnerAlive { _ = await client.queueRun(strategy: RunStrategy.standing.overridden(by: settings, claudeModels: claudeModels)) }
            }
            busy = false
            toast = add.ok ? ToastMessage(text: "Re-queued \(entry.projectName)", kind: .success)
                           : ToastMessage(text: "Couldn't re-queue", kind: .error)
            await refresh()
        }
    }

    func dismissParked(_ entry: QueueDoneEntry) {
        Task {
            await client.clearParked(dirName: entry.dirName)
            await refresh()
            toast = ToastMessage(text: "Dismissed", kind: .info)
        }
    }

    func respondParked(_ entry: QueueDoneEntry, decision: String) {
        let text = decision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let task = "\(entry.task)\n\n— Рішення користувача: \(text)\nПродовжуй з урахуванням цього."
        beginResuming(entry.projectPath)
        note(.decisionSent, .info, "Рішення надіслано — «\(entry.projectName)» продовжує.",
             detail: text, projectPath: entry.projectPath)
        busy = true
        Task {
            let add = await client.queueAdd(project: entry.projectPath, task: task)
            if add.ok {
                await client.clearParked(dirName: entry.dirName)
                if !snapshot.queue.runnerAlive { _ = await client.queueRun(strategy: RunStrategy.standing.overridden(by: settings, claudeModels: claudeModels)) }
            }
            busy = false
            toast = add.ok ? ToastMessage(text: "Decision sent — resuming \(entry.projectName)", kind: .success)
                           : ToastMessage(text: "Couldn't resume", kind: .error)
            await refresh()
        }
    }

    func respondBlocker(projectPath: String, projectName: String, blocker: String, decision: String) {
        let text = decision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        beginResuming(projectPath)
        note(.decisionSent, .info, "Рішення по блокеру надіслано — «\(projectName)».",
             detail: text, projectPath: projectPath)
        busy = true
        Task {
            let task = """
            Робота раніше зупинилась на блокері:
            \(blocker.prefix(1200))

            Рішення користувача: \(text)
            Розблокуй за цим рішенням і доведи задачу до кінця — без заглушок.
            """
            let add = await client.queueAdd(project: projectPath, task: task)
            if add.ok, !snapshot.queue.runnerAlive { _ = await client.queueRun(strategy: RunStrategy.standing.overridden(by: settings, claudeModels: claudeModels)) }
            busy = false
            toast = add.ok ? ToastMessage(text: "Sent to the shift for \(projectName)", kind: .success)
                           : ToastMessage(text: "Failed to send", kind: .error)
            await refresh()
        }
    }

    nonisolated struct ShapedMission: Sendable {
        var text: String
        var acceptance: [String]
    }

    func shapeMission(text: String, projectName: String?, projectPath: String?) async -> ShapedMission? {
        let prompt = """
        Ти — тех-лід. Перетвори сирий запис користувача на чітку місію для інженера й поверни РІВНО ОДИН JSON-обʼєкт (без пояснень, без code fences):
        {"mission":"<стислий бриф українською: Ціль (1 речення); Контекст/де шукати; Кроки (до 6); Ризики (до 3); Автономно вночі: так/ні + чому>","acceptance":["<до 6 ПЕРЕВІРЮВАНИХ критеріїв — збірка/тести/поведінка, кожен окремим елементом масиву>"]}

        Проєкт: \(projectName ?? "—")
        Сирий запис:
        \(text)
        """
        guard let raw = await client.askCodex(prompt: prompt, cwd: projectPath) else { return nil }

        if let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
           let data = String(raw[s...e]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let mission = (obj["mission"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let acceptance = ((obj["acceptance"] as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let brief = mission.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : mission
            return ShapedMission(text: brief, acceptance: acceptance)
        }
        return ShapedMission(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), acceptance: [])
    }

    func decomposeMission(text: String, defaultProject: Project?, visual: Bool,
                          allowed: [Project]?,
                          refining: [SubtaskDraft] = [], remark: String = "") async -> [SubtaskDraft] {
        let candidates = allowed ?? projects.sorted

        guard !candidates.isEmpty else { return [] }

        let host = allowed == nil ? defaultProject
            : defaultProject.flatMap { d in candidates.first { $0.id == d.id } }
        let projList = candidates.map { "- \($0.name)" }.joined(separator: "\n")
        let def = host?.name ?? "(не вказано)"
        let revision = refining.isEmpty ? "" : """

        === ВЖЕ УЗГОДЖЕНИЙ ПЛАН (користувач його НЕ скасовував) ===
        \(refining.enumerated().map { i, d in
            let deps = d.dependsOn.isEmpty ? "" : " (після \(d.dependsOn.map { String($0 + 1) }.joined(separator: ", ")))"
            return "\(i + 1). \(d.title) [\(d.projectName)]\(deps)"
        }.joined(separator: "\n"))

        === УТОЧНЕННЯ ДИРЕКТОРА ДО ЦЬОГО ПЛАНУ ===
        \(remark)

        Це УТОЧНЕННЯ, а не нова задача. Поверни ПОВНИЙ виправлений план — усі потоки, яких
        уточнення не стосується, залиш як були (той самий зміст і порядок). Не видаляй потоки,
        якщо користувач явно не просив їх прибрати: «все інше ок» означає, що решта лишається.
        """
        let prompt = """
        Ти — тех-лід. Розбий повідомлення користувача на ОКРЕМІ, незалежно-здавані задачі (кожну можна прийняти й змерджити окремо). НЕ склеюй різні напрями в одну задачу; але й не дроби одну цілісну роботу на дрібниці. Якщо це насправді ОДНА задача — поверни масив з одного елемента. Поверни РІВНО ОДИН JSON-масив (без пояснень, без code fences):
        [{"title":"<однорядковий заголовок>","mission":"<бриф укр: Ціль (1 реч.); Контекст/де шукати; Кроки (до 6); Ризики (до 3)>","acceptance":["<до 6 ПЕРЕВІРЮВАНИХ критеріїв>"],"project":"<назва проєкту ТОЧНО зі списку, або порожньо=дефолт>","depends_on":[<0-based індекси ПОПЕРЕДНІХ задач у ЦЬОМУ ж масиві (лише менший індекс за цю задачу), які МАЮТЬ завершитись до неї; лише реальні залежності, інакше []>],"visual":<true якщо це зміна ВИГЛЯДУ/UI>,"changes_behavior":<true якщо після цього кроку продукт ПОВОДИТЬСЯ інакше: нова логіка, новий ендпойнт, новий стан, зміна даних>,"changes_user_text":<true якщо змінюється текст, який читає користувач: копірайт в UI, повідомлення, листи, тексти в сторі>,"preparation":<true ЛИШЕ якщо цей крок нічого не здає сам, а лише приводить робоче середовище до відомого стану: підтягнути гілку, синхронізувати, встановити залежності, оновити оточення>,"reads_only":<true ЛИШЕ якщо цей крок НІЧОГО не змінює у своєму проєкті — тільки читає/вивчає/звіряє контракти. Якщо крок створює, править або видаляє хоч один файл — false>}]
        Максимум 8 задач. Впорядкуй так, щоб залежна задача стояла ПІСЛЯ тієї, від якої залежить.\(revision)

        Ресурси ЦЬОГО продукту — це ЄДИНІ можливі місця для роботи. Назву бери точно зі списку.
        Якщо робота за змістом схожа на інший продукт, якого тут НЕМА — не вигадуй його, залиш
        "project" порожнім: застосунок перепитає користувача.
        \(projList)
        Дефолтний ресурс, якщо із задачі не зрозуміло: \(def)

        Повідомлення користувача:
        \(text)
        """
        guard let raw = await client.askCodex(prompt: prompt, cwd: host?.path) else { return [] }
        guard let s = raw.firstIndex(of: "["), let e = raw.lastIndex(of: "]"), s < e,
              let data = String(raw[s...e]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !arr.isEmpty, arr.count <= 12 else { return [] }
        var out: [SubtaskDraft] = []
        for (idx, obj) in arr.enumerated() {

            guard let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { return [] }
            let mission = (obj["mission"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? title
            let acceptance = ((obj["acceptance"] as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                .prefix(8).map { String($0.prefix(400)) }
            let projName = (obj["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let proj = projName.isEmpty ? host
                : candidates.first { $0.name.caseInsensitiveCompare(projName) == .orderedSame }

            let deps = ((obj["depends_on"] as? [Any])?.compactMap { $0 as? Int } ?? []).filter { $0 >= 0 && $0 < idx }
            let vis = (obj["visual"] as? Bool) ?? visual
            let prep = (obj["preparation"] as? Bool) ?? false

            let readsOnly = (obj["reads_only"] as? Bool) ?? false

            let behavior = (obj["changes_behavior"] as? Bool) ?? false
            let copy = (obj["changes_user_text"] as? Bool) ?? false
            out.append(SubtaskDraft(title: String(title.prefix(140)), detail: String(mission.prefix(4000)),
                                    acceptance: Array(acceptance), projectID: proj?.id, projectPath: proj?.path,
                                    projectName: proj?.name ?? def, dependsOn: deps, visual: vis,
                                    behavior: behavior, userFacingCopy: copy,
                                    preparation: prep, readsOnly: readsOnly))
        }
        return out
    }

    func draftMemo(projectPath: String, context: String) async -> String? {
        let prompt = """
        Ти — бригадир нічної зміни. Ось записаний блокер проєкту. Склади коротку управлінську записку українською:
        Проблема (1-2 речення), Варіант A, Варіант B, Рекомендація (+ чому). Без води.

        \(context)
        """
        return await client.askCodex(prompt: prompt, cwd: projectPath)
    }

    func dispatchAllReady() {

        let ready = backlog.readyToDispatch.filter { task in
            guard let productID = productID(for: task),
                  let project = project(for: task) else { return true }
            return products.product(id: productID)?.access(forProjectID: project.id) != .source
        }
        guard !ready.isEmpty else {
            toast = ToastMessage(text: String(localized: "Nothing is waiting to start"), kind: .info)
            return
        }
        for task in ready { dispatch(task: task) }
        note(.dispatchedBatch, .info, "Запускаю \(ready.count) готових задач за пріоритетом.")
    }

    func adoptNote(_ task: BacklogTask) {
        var promoted = task
        promoted.type = .chore
        promoted.state = .ready
        promoted.priority = .p2
        backlog.update(promoted)
        note(.taskCreated, .info, "Взяв у роботу нотатку: «\(task.title)»",
             projectPath: task.projectPath, taskID: task.id, link: .task(task.id))
        dispatch(task: promoted)
    }

    // MARK: Findings → backlog (§10.3)

    private static let findingMarker = "\n\n[finding-id: "

    func clearFindingsFromTheFeed() {
        let removed = backlog.removeFindingNotes()
        guard !removed.isEmpty else { return }
        archiveRemovedFindings(removed)
        note(.taskCreated, .info,
             "Прибрав \(removed.count) технічних нотаток із черги — вони тепер у звітах прогонів, "
             + "що їх помітили.")
    }

    private func archiveRemovedFindings(_ removed: [BacklogTask]) {
        let url = AppSupport.file("findings-archive.jsonl")
        var lines = ""
        let stamp = ISO8601DateFormatter().string(from: Date())
        for t in removed {
            let obj: [String: Any] = ["archived_at": stamp, "title": t.title, "detail": t.detail,
                                      "projectPath": t.projectPath ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let line = String(data: data, encoding: .utf8) {
                lines += line + "\n"
            }
        }
        guard let data = lines.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInEditor(_ path: String) {
        let script = "for a in 'Cursor' 'Visual Studio Code' 'Xcode'; do open -a \"$a\" \"$1\" 2>/dev/null && exit 0; done; open \"$1\""
        Task { _ = await Shell.run(script, args: [path], timeout: 10) }
    }

    func openInTerminal(_ path: String) {
        let script = "open -a Terminal \"$1\""
        Task { _ = await Shell.run(script, args: [path], timeout: 10) }
    }

    func attachInTerminal(session: String, projectPath: String) {
        let script = "osascript -e 'tell application \"Terminal\" to do script \"tmux attach -t \" & quoted form of (system attribute \"NS_SESSION\")' -e 'tell application \"Terminal\" to activate' >/dev/null 2>&1 || true"
        Task { _ = await Shell.run(script, extraEnv: ["NS_SESSION": session], timeout: 10) }
    }

    func workerActivity(session: String, lines: Int = 140) async -> String {
        await client.capturePane(session: session, lines: lines)
    }
}
