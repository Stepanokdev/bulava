import Foundation
import AppKit
import SwiftUI

@MainActor
final class TestDrive {
    private let inbox: URL
    private let reply: URL
    private var consumed = 0
    private var timer: Task<Void, Never>?

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
            note(capture(to: path, what: what, dark: dark,
                         report: (obj["report"] as? String) ?? "",
                         taskRef: (obj["task"] as? String) ?? "", model))

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
        case .revealInFinder?:  "show it in Finder"
        case .askForScreenRecording?: "ask macOS for screen recording"
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

    private func note(_ text: String) {
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
