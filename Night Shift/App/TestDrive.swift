import Foundation
import AppKit
import SwiftUI

@MainActor
final class TestDrive {
    private let inbox: URL
    private let reply: URL
    private var consumed = 0
    private var timer: Task<Void, Never>?
    /// Windows a picture was asked for; kept so they stay open.
    private var previews: [NSWindow] = []

    static func make() -> TestDrive? {
        guard let path = ProcessInfo.processInfo.environment["BULAVA_TEST_INBOX"], !path.isEmpty else {
            return nil
        }
        return TestDrive(inbox: URL(fileURLWithPath: path))
    }

    private init(inbox: URL) {
        self.inbox = inbox
        self.reply = URL(fileURLWithPath: inbox.path + ".reply")
        if !FileManager.default.fileExists(atPath: inbox.path) {
            FileManager.default.createFile(atPath: inbox.path, contents: nil)
        }

        if let raw = try? String(contentsOf: inbox, encoding: .utf8) {
            consumed = raw.split(separator: "\n", omittingEmptySubsequences: true).count
        }
    }

    func start(_ model: AppModel) {
        note("test-drive armed on \(inbox.path) — skipping \(consumed) line(s) already there")
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                self?.drain(model)
            }
        }
    }

    func stop() { timer?.cancel(); timer = nil }

    // MARK: - Reading

    private func drain(_ model: AppModel) {
        guard let raw = try? String(contentsOf: inbox, encoding: .utf8) else { return }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > consumed else { return }
        for line in lines[consumed...] {
            perform(line, model)
        }
        consumed = lines.count
    }

    private func perform(_ line: String, _ model: AppModel) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verb = obj["do"] as? String else {
            note("ignored (not a JSON action): \(line.prefix(80))")
            return
        }
        let productName = obj["product"] as? String

        switch verb {
        case "open":
            guard let product = resolveProduct(productName, model) else { return }
            model.open(product: product.id)
            note("opened \(product.name)")

        case "say":
            guard let product = resolveProduct(productName, model),
                  let text = obj["text"] as? String, !text.isEmpty else {
                note("say: needs product + text"); return
            }

            let files = (obj["attach"] as? [String]) ?? []
            let attachments = files.compactMap { path in
                model.capture.importFile(from: URL(fileURLWithPath: path))
            }
            if attachments.count != files.count {
                note("say: \(files.count - attachments.count) attachment(s) could not be imported")
            }
            model.open(product: product.id)
            model.foremanSend(text, productID: product.id, attachments: attachments)
            note("said to \(product.name)\(attachments.isEmpty ? "" : " (+\(attachments.count) вкладень)"): \(text.prefix(90))")

        case "confirm", "decline":
            guard let product = resolveProduct(productName, model) else { return }
            guard let proposal = model.pendingProposals[product.id] else {
                note("\(verb): nothing pending in \(product.name)"); return
            }
            model.pendingProposals[product.id] = nil
            if verb == "confirm" {
                model.executeProposal(proposal)
                note("confirmed in \(product.name): \(proposal.label.prefix(90))")
            } else {
                note("declined in \(product.name): \(proposal.label.prefix(90))")
            }

        case "tap":
            guard let needle = obj["task"] as? String,
                  let action = obj["action"] as? String else { note("tap: needs task + action"); return }
            guard let task = model.backlog.tasks.first(where: {
                $0.title.localizedCaseInsensitiveContains(needle)
            }) else { note("tap: no task matching “\(needle)”"); return }
            switch action {
            case "start":    model.dispatch(task: task)
            case "report":   model.openReport(task)
            case "instruct": model.beginInstructing(task)
            case "adopt":    model.adoptNote(task)
            case "drop":     model.deleteTask(task)
            case "decide":   model.askForDecision(task: task)
            case "trail":    model.showWorkerTrail(task: task)

            case "restate":
                guard let want = obj["state"] as? String,
                      let state = TaskState(rawValue: want) else { note("restate: needs a state"); return }
                model.backlog.restate(task.id, as: state)
                note("restated “\(task.title.prefix(50))” as \(want)")
            default:         note("tap: unknown action \(action)"); return
            }
            note("tapped \(action) on “\(task.title.prefix(70))”")

        case "route":
            // {"do":"route","to":"automations"} · {"do":"route","to":"automation","name":"…"}
            // · {"do":"route","to":"run","name":"…"} opens the newest run of that automation.
            let to = (obj["to"] as? String) ?? ""
            let named = (obj["name"] as? String) ?? ""
            let automation = model.automations.automations.first { $0.name == named }
            switch to {
            case "automations": model.navigate(to: .automations)
            case "skills": model.navigate(to: .skills)
            case "pipelines": model.navigate(to: .pipelines)
            case "pipeline":
                // {"do":"route","to":"pipeline","name":"<pipeline id>"}
                guard !named.isEmpty else { note("route: pipeline needs a name (its id)"); return }
                // With "ask", the editor opens on its chat and sends that request first.
                if let ask = obj["ask"] as? String, !ask.isEmpty { model.pendingPipelineRequests[named] = ask }
                model.navigate(to: .pipeline(named))
            case "automation":
                guard let automation else { note("route: no automation named \(named)"); return }
                model.navigate(to: .automation(automation.id))
            case "run":
                guard let automation, let run = model.automations.runs(for: automation.id)
                    .first(where: { $0.chatID != nil }) else { note("route: no run with a chat for \(named)"); return }
                model.openRunChat(run)
            case "run-now":
                guard let automation else { note("route: no automation named \(named)"); return }
                model.runAutomationNow(automation.id)
            case "merge":
                guard let automation, let run = model.automations.runs(for: automation.id)
                    .first(where: { $0.result == .changes && $0.handoff == .waiting }) else {
                    note("route: nothing waiting to merge for \(named)"); return
                }
                Task { note("merge: " + ((await model.mergeRun(run.id)) ?? "ok")) }
            case "editor":
                // {"do":"route","to":"editor","template":"parity"} — the form, filled from a template;
                // {"do":"route","to":"editor","close":true} puts it away.
                let wanted = obj["template"] as? String
                let template = AutomationTemplate.all().first { $0.id == wanted }
                // A named template that does not exist says so, instead of quietly opening a blank form.
                if let wanted, template == nil { note("route: no template \(wanted)"); return }
                let request = AutomationEditorRequest.new(productID: model.products.sorted.first?.id, template: template)
                if obj["close"] as? Bool == true {
                    model.automationEditor = nil
                } else if model.automationEditor != nil {
                    model.automationEditor = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(700))
                        model.automationEditor = request
                    }
                } else {
                    model.automationEditor = request
                }
            default:
                note("route: needs automations|automation|skills|pipelines|pipeline|run|editor"); return
            }
            note("route: \(to) \(named)")

        case "inspector":
            guard let product = resolveProduct(productName, model) else { return }
            model.open(product: product.id)
            model.inspectorShown = ((obj["action"] as? String) ?? "open") != "close"
            note("inspector: \(model.inspectorShown ? "shown" : "hidden") for \(product.name)")

        case "theme":

            guard let want = obj["theme"] as? String else { note("theme: needs light|dark"); return }
            model.settings.appearance = (want == "dark") ? .dark : .light
            note("theme: \(want)")

        case "language":

            guard let want = obj["language"] as? String,
                  let lang = AppLanguage(rawValue: want) else {
                note("language: needs system|en|uk|ru"); return
            }
            model.settings.interfaceLanguage = lang
            LanguageBundle.adopt(lang)
            note("language: \(want)")

        case "chat-report":
            // A chat's report opened the way a click on it in a chat opens it — with the choices
            // beside it when the report asks to decide something.
            guard let path = obj["path"] as? String else { note("chat-report: needs path"); return }
            model.openChatReport(path: path, title: (obj["title"] as? String) ?? "Report")
            note("chat-report: \(path)")

        case "settings":
            // The Settings scene has no model action of its own: the app menu's "Settings…" opens
            // it, as a person would.
            NSApp.activate(ignoringOtherApps: true)
            if let menu = NSApp.mainMenu?.items.first?.submenu,
               let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                menu.performActionForItem(at: index)
                note("settings: opened")
            } else {
                note("settings: no Settings… item in the app menu")
            }

        case "browser-site":
            // A site in Bulava's browser, as if added in Settings — without opening Chrome.
            guard let url = obj["url"] as? String, let site = model.browser.addSite(url) else {
                note("browser-site: needs a site's url"); return
            }
            model.browser.setWithoutMe(site.id, (obj["withoutMe"] as? Bool) ?? false)
            note("browser-site: \(site.host)")

        case "browser-settings":
            // The Settings section of Bulava's browser in a window of its own, for a picture of it:
            // in Settings it sits far down a long scroll.
            let view = AccountBrowserSection(browser: model.browser)
                .environment(model)
                .padding(20)
                .frame(width: 620)
                .background(Palette.window)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "Bulava's browser")
            window.makeKeyAndOrderFront(nil)
            // The only window left on screen, so a capture of this app's window is this one.
            for other in NSApp.windows where other !== window && other.isVisible { other.orderOut(nil) }
            NSApp.activate(ignoringOtherApps: true)
            previews.append(window)
            note("browser-settings: shown")

        case "learning":

            // The same shape as `theme` and `language` above: a setting a fixture has to be able
            // to put the app into, because the surface being checked only exists when it is on and
            // the Settings window it lives in is a separate scene.
            let on = (obj["on"] as? Bool) ?? true
            model.settings.devLearningEnabled = on
            if let profile = obj["profile"] as? String {
                model.settings.learningProfile = profile
            }
            note("learning: \(on ? "on" : "off")"
                 + (model.settings.learningProfile.isEmpty
                    ? "" : " · profile «\(model.settings.learningProfile)»"))

        case "explain":

            // Presses the action on the newest finished answer in this product's open chat.
            // The only way to see the panel itself without a mouse, and it goes through exactly
            // the code the button goes through — including the paid call, which is why this is
            // driven by hand and not by a check that reruns.
            guard let product = resolveProduct(productName, model) else { return }
            model.open(product: product.id)
            guard let chatID = model.conversations.currentChatID(for: product.id) else {
                note("explain: no chat open in \(product.name)"); return
            }
            guard let entry = model.conversations.entries(inChat: chatID)
                .last(where: { model.explainState(turn: $0).available }) else {
                note("explain: nothing finished to explain in \(product.name)"); return
            }
            let depth: ExplainDepth = (obj["depth"] as? String) == "steps" ? .stepByStep : .brief
            model.explain(turn: entry, depth: depth)
            note("explain: asked for \(depth.rawValue) on \(entry.id)")

        case "snapshot":
            note(snapshot(model))

        // What the readiness screen is actually showing, from the running application. The screen
        // is meant to be one row and one action per thing that can be wrong; it once showed two of
        // each for a missing agent CLI, and only a dump from the real app settles which it is.
        case "readiness":
            // `states` asks the same screen what it would show for each way an agent CLI can fail.
            // These are built by the application's own code, not by a fixture, so the answer is
            // what a person on a broken Mac would actually read — on a machine where nothing is
            // broken and the states cannot be provoked.
            if obj["states"] as? Bool == true {
                let runner = model.readiness
                var lines: [String] = []
                for failure in [PreflightRunner.ProbeFailure.notOnPath, .executableMissing,
                                .wrongArchitecture, .blockedBySystem, .notSignedIn, .unknown] {
                    for row in [runner.claudeFailureRow(failure, evidence: "…"),
                                runner.codexFailureRow(failure, evidence: "…")] {
                        lines.append("  \(failure) → \(row.titleKey) · \(describe(row.fix))")
                    }
                }
                note(lines.joined(separator: "\n"))
                return
            }
            Task { @MainActor in
                await model.refreshReadiness(force: true)
                note(model.readiness.checks.map { check in
                    let action = check.fix == nil && check.settingsURL != nil
                        ? "open Settings" : describe(check.fix)
                    return "  ROW \(check.id) [\(check.status)] \(check.titleKey) → \(action)"
                }.joined(separator: "\n"))
            }

        case "shot":

            guard let path = obj["path"] as? String, !path.isEmpty else { note("shot: needs a path"); return }
            let what = (obj["what"] as? String) ?? "feed"
            let dark = (obj["theme"] as? String) == "dark"
            // The window drawn by the app itself: no Screen Recording grant, so a fixture build
            // nobody has granted anything can still show what it looks like.
            if what == "drawn" {
                // A window covered by other apps' windows is not redrawn at all, so it is brought
                // up for a moment — never made key, never taking the keyboard — drawn, and sent back.
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) else {
                    note("shot: no visible window to draw"); return
                }
                window.orderFrontRegardless()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard let self else { return }
                    self.note(self.drawOwnWindow(to: path))
                    window.orderBack(nil)
                }
                return
            }
            note(capture(to: path, what: what, dark: dark,
                         report: (obj["report"] as? String) ?? "",
                         taskRef: (obj["task"] as? String) ?? "", model))

        case "probe":
            probe(obj, model)

        default:
            note("unknown action: \(verb)")
        }
    }

    private func resolveProduct(_ name: String?, _ model: AppModel) -> Product? {
        guard let name, !name.isEmpty else {
            note("action needs a \"product\""); return nil
        }
        let hit = model.products.products.first { $0.name.localizedCaseInsensitiveContains(name) }
        if hit == nil { note("no product matching “\(name)”") }
        return hit
    }

    // MARK: - Reporting back

    /// The one thing a readiness row offers to do about itself, in words.
    private func describe(_ fix: PreflightCheck.Fix?) -> String {
        switch fix {
        case .brew(let f)?:     "brew install " + f.joined(separator: " ")
        case .brewCask(let c)?: "brew install --cask " + c.joined(separator: " ")
        case .signIn(let c)?:   "sign in: " + c
        case .installEngine?:   "install the engine"
        case .trustFolders?:    "trust the folders"
        case .finishClaudeSetup?: "finish Claude Code's setup"
        case .revealInFinder?:  "show it in Finder"
        case .askForScreenRecording?: "ask macOS for screen recording"
        case .updateCodex(let c)?: "update codex: " + c
        case nil:               "no button"
        }
    }

    private func snapshot(_ model: AppModel) -> String {
        var out: [String] = []
        for product in model.products.sorted {
            let items = model.workItems.items(forProductID: product.id)
            let open = model.openTasks(for: product.id)
            guard !items.isEmpty || !open.isEmpty else { continue }
            out.append("PRODUCT \(product.name)")
            for item in items {
                out.append("  ITEM [\(model.state(of: item))] \(item.title.prefix(70))")
                for stream in item.streams {
                    let t = model.backlog.task(id: stream.id)
                    out.append("    - [\(t?.state.rawValue ?? "gone")] \(stream.title.prefix(60))"
                               + (t?.externalBlocker.map { " HELD: \($0.prefix(60))" } ?? ""))
                }
            }
            for task in open where model.workItems.item(forStreamID: task.id) == nil {
                out.append("  TASK [\(task.state.rawValue)]\(task.isNote ? " NOTE" : "") \(task.title.prefix(70))")
            }
            if let pending = model.pendingProposals[product.id] {
                out.append("  PENDING CONFIRMATION: \(pending.label.prefix(100))")
            }
            let spoken = model.conversations.all(for: product.id).filter(\.isSpoken).suffix(3)
            for entry in spoken {
                let who = entry.kind == .user ? "director" : "foreman"
                out.append("  … \(who): \(entry.text.replacingOccurrences(of: "\n", with: " ").prefix(150))")
            }
        }
        return out.isEmpty ? "(nothing anywhere)" : out.joined(separator: "\n")
    }

    @MainActor private func capture(to path: String, what: String, dark: Bool,
                                    report: String = "", taskRef: String = "",
                                    _ model: AppModel) -> String {
        guard let productID = model.route.productID ?? model.selectedProductID else {
            return "shot: no product selected"
        }
        let width: CGFloat = 760

        let body: AnyView
        switch what {
        case "confirm":

            guard let entry = model.conversations.all(for: productID).last(where: {
                $0.kind == .foreman && $0.proposalID != nil
            }) else { return "shot: no pending confirmation in this product" }
            body = AnyView(EntryView(entry: entry, productID: productID))

        case "decision":
            guard let entry = model.conversations.all(for: productID).last(where: {
                $0.kind == .question || $0.kind == .decision
            }) else { return "shot: no decision in this product" }
            body = AnyView(EntryView(entry: entry, productID: productID))

        case "work":

            let items = model.workItems.items(forProductID: productID)
            guard !items.isEmpty else { return "shot: no work items in this product" }
            body = AnyView(VStack(alignment: .leading, spacing: 12) {
                ForEach(items) { WorkItemCard(item: $0) }
            })

        case "delivery":

            let key = report
            let dir = model.settings.paths.reportDir(task8: key)
            let blocks = AppModel.deliveryBlocks(runID: key, directory: dir,
                                                 manifest: AppModel.manifest(in: dir))
            guard !blocks.isEmpty else { return "shot: nothing to deliver in report \(key)" }

            for ref in blocks.filter({ $0.kind == .gallery }).flatMap(\.artifacts) {
                if let url = ref.resolve(base: model.artifactBase) {
                    ThumbnailCache.shared.loadNow(url)
                }
            }
            body = AnyView(VStack(alignment: .leading, spacing: 14) {
                Text(AppModel.deliveryCaption(blocks))
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                BlockStack(blocks: blocks, artifactBase: model.artifactBase)
            })

        case "card":

            let wanted = taskRef.lowercased()
            guard let task = model.backlog.tasks.first(where: {
                wanted.isEmpty || $0.title.lowercased().contains(wanted)
            }) else { return "shot: no task matching “\(wanted)”" }
            body = AnyView(TaskCard(task: task))

        case "spoken":

            let entries = model.conversations.all(for: productID).suffix(4)
            guard !entries.isEmpty else { return "shot: nothing said in this product" }
            body = AnyView(VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(entries)) { EntryView(entry: $0, productID: productID) }
            })

        case "window":

            return captureWindow(to: path, model)

        default:
            return "shot: unknown surface “\(what)” (confirm | decision | work | spoken | delivery | card | window)"
        }

        let content = body
            .frame(width: width)
            .padding(18)
            .background(Palette.content)
            .environment(model)
            .environment(\.colorScheme, dark ? .dark : .light)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            return "shot: could not render \(what)"
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return "shot: \(what) (\(dark ? "dark" : "light")) \(Int(image.size.width))x\(Int(image.size.height)) → \(path)"
        } catch {
            return "shot: write failed — \(error.localizedDescription)"
        }
    }

    @MainActor private func drawOwnWindow(to path: String) -> String {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView else {
            return "shot: no visible window to draw"
        }
        // A window behind other apps' windows is not redrawn by itself; ask for it before drawing.
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        window.displayIfNeeded()
        let rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return "shot: could not draw the window" }
        view.cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "shot: could not encode the window" }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return "shot: drawn \(Int(rect.width))x\(Int(rect.height)) → \(path)"
        } catch {
            return "shot: \(error.localizedDescription)"
        }
    }

    @MainActor private func captureWindow(to path: String, _ model: AppModel) -> String {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) else {
            return "shot: no visible window to capture"
        }
        guard let service = model.screenshots else {
            return "shot: the capture service is not running"
        }
        window.makeKeyAndOrderFront(nil)
        let pid = ProcessInfo.processInfo.processIdentifier
        let size = "\(Int(window.frame.width))x\(Int(window.frame.height))"

        Task { [weak self] in
            do {
                try await service.captureNow(to: path, windowPID: pid)
                self?.note("shot: window \(size) → \(path)")
            } catch {
                self?.note("shot: \(error.localizedDescription)")
            }
        }
        return "shot: window \(size) requested"
    }

    func note(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: reply) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: reply)
        }
    }
}
