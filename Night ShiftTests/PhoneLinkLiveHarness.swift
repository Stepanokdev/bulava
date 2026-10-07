import XCTest
@testable import Bulava

/// A Mac for a real phone to talk to, for as long as it takes to try the app by hand.
///
/// Not a test that runs with the suite: it is skipped unless `BULAVA_LINK_HARNESS_SECONDS` is set,
/// and then it serves the link on an isolated state directory — nothing of the director's own
/// products, chats or runs is involved. The pairing link goes to `BULAVA_LINK_HARNESS_OUT`, so an
/// emulator can be paired with `adb shell am start -d "bulava://pair#…"`. How to run it is in
/// `link-protocol/README.md`.
///
/// Whatever the phone says gets an answer written into the same chat, a few words at a time, so
/// the live stream to the phone can be watched. "start work" and "finish work" begin and end a run,
/// fifteen seconds later, the way the engine does — a watchdog process and its instance folder, read by the Mac's own
/// snapshot code — so the counts, the Live Activity and the quiet "report ready" can be watched.
nonisolated final class PhoneLinkLiveHarness: XCTestCase {

    nonisolated(unsafe) private var watchdog: Process?
    nonisolated(unsafe) private var supervisor: URL!

    @MainActor
    func testServeAPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["BULAVA_LINK_HARNESS_SECONDS"], let seconds = Double(raw), seconds > 0 else {
            throw XCTSkip("Set BULAVA_LINK_HARNESS_SECONDS to serve a phone by hand.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-link-harness")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        supervisor = dir.appendingPathComponent("supervisor")
        try FileManager.default.createDirectory(at: supervisor.appendingPathComponent("instances"), withIntermediateDirectories: true)
        setenv("SUPERVISOR_STATE_DIR", supervisor.path, 1)
        defer {
            unsetenv("BULAVA_STATE_DIR")
            unsetenv("SUPERVISOR_STATE_DIR")
            watchdog?.terminate()
        }

        let model = AppModel()
        let link = MobileLink(root: dir.appendingPathComponent("mobile-link"))
        // `BULAVA_LINK_HARNESS_PORT=0` takes any free port: the Mac's own Bulava may hold the usual one.
        if let port = env["BULAVA_LINK_HARNESS_PORT"].flatMap(UInt16.init) { link.preferredPort = port }
        link.attach(model, allowInTests: true)
        seed(model)

        _ = link.beginPairing()
        for _ in 0..<100 {
            if case .listening = link.serverState { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let url = try XCTUnwrap(link.pairingPayload?.url)
        if let out = env["BULAVA_LINK_HARNESS_OUT"] {
            try url.write(toFile: out, atomically: true, encoding: .utf8)
        }
        print("PAIRING \(url)")

        var answered: Set<UUID> = Set(model.conversations.entries.map(\.id))
        let end = Date().addingTimeInterval(seconds)
        var ticks = 0
        while Date() < end {
            try await Task.sleep(for: .milliseconds(400))
            // The app's own poll is not running here; the runs are read the same way, less often.
            ticks += 1
            if ticks % 5 == 0 { await model.refresh() }
            // A code lasts five minutes and is spent by the first phone; a fresh one is always open,
            // so a second phone — or the same one after a reinstall — can pair too.
            if link.pairingPayload == nil {
                _ = link.beginPairing()
                if let out = env["BULAVA_LINK_HARNESS_OUT"], let fresh = link.pairingPayload?.url {
                    try? fresh.write(toFile: out, atomically: true, encoding: .utf8)
                }
            }
            for entry in model.conversations.entries where entry.kind == .user && !answered.contains(entry.id) {
                answered.insert(entry.id)
                await reply(to: entry, in: model)
            }
        }
        link.shutdown()
    }

    @MainActor
    private func reply(to entry: ConversationEntry, in model: AppModel) async {
        guard let chatID = entry.chatID else { return }
        let said = entry.text.lowercased()
        // "ask for trust" stops a message on an untrusted folder, in a chat of its own, ten seconds
        // later: a request whose notification carries its button.
        if said.contains("ask for trust") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                let chat = model.conversations.newChat(for: entry.productID)
                let stopped = model.conversations.appendUser("Start on the release notes", productID: entry.productID, chatID: chat.id)
                model.conversations.updateDelivery(entryID: stopped.id, .failed)
                model.trustBlocked[chat.id] = "/Users/you/Developer/Narada"
            }
            return
        }
        // "ask to commit" stops this message on uncommitted work, as the engine's exit 77 would, and
        // "task asks to commit" does the same to a task card — the Mac's dialog, on the phone.
        if said.contains("ask to commit") || said.contains("task asks to commit") {
            let tree = DirtyTree(dirty: true, unborn: false, head: "d484d74", branch: "bulava-mobile-assistant", digest: "harness",
                                 author: "IvanStepanok <ivan@example.com>", keepPossible: true, total: 13,
                                 files: ["App/AppModel.swift", "App/AppSettings.swift", "Features/MenuBar/MenuBarView.swift",
                                         "Features/Settings/SettingsView.swift", "Localizable.xcstrings", "MobileLink/LinkPush.swift"]
                                    .map { DirtyTree.Entry(xy: " M", path: "Night Shift/" + $0) })
            if said.contains("task asks") {
                var task = BacklogTask(title: "Keep the Mac awake while work runs", type: .feature, priority: .p2, state: .ready)
                task.productID = entry.productID
                task = model.backlog.add(task)
                model.dirtyTreeAsk = AppModel.DirtyTreeAsk(task: task, folder: "/tmp/bulava-link-harness-narada", tree: tree)
            } else {
                model.conversations.updateDelivery(entryID: entry.id, .failed)
                model.dirtyTreeBlocked[chatID] = AppModel.DirtyTreeBlock(entryID: entry.id, folder: "/tmp/bulava-link-harness-narada", tree: tree)
            }
            return
        }
        // Both happen fifteen seconds later — time to put the app away and watch the Lock Screen.
        if said.contains("start work") || said.contains("finish work") {
            let start = said.contains("start work")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                if start { self.startRun(model, product: entry.productID, chat: chatID) }
                else { self.finishRun(model, product: entry.productID, chat: chatID) }
                await model.refresh()
            }
        }
        // "setup breaks" takes tmux away ten seconds later: the Mac's setup has a problem, which
        // asks for the director with no chat of its own — its notification leads to the settings.
        if said.contains("setup breaks") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                model.readiness.overrideChecksForTesting(model.readiness.checks.filter { $0.id != "tmux" } + [
                    PreflightCheck(id: "tmux", titleKey: "tmux is installed",
                                   detailKey: "Night Shift runs each worker in a tmux session.", status: .missing, gate: .allWork),
                ])
            }
            return
        }
        // "ask me" puts a question into the chat ten seconds later — time enough to send the app
        // to the background and watch the Mac wake it.
        if entry.text.lowercased().contains("ask me") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                var ask = ConversationEntry(productID: entry.productID, kind: .question, text: "Ready to ship?")
                ask.chatID = chatID
                ask.decision = DecisionRecord(
                    headline: "Ready to ship?", situation: "The build passed on the Mac.",
                    items: [.init(question: "Ship it", header: nil, options: ["Yes", "Not yet"], multiSelect: false,
                                  optionDescriptions: [:])],
                    recommendation: "Yes")
                model.conversations.append(ask)
            }
            return
        }
        let words = "Got it on the Mac: **\(entry.text.isEmpty ? "a file" : entry.text)**. This answer is written a few words at a time, so the phone shows it growing."
            .split(separator: " ")
        let answerID = model.conversations.beginForemanTurn(productID: entry.productID, chatID: chatID)
        var text = ""
        for (i, word) in words.enumerated() {
            text += (i == 0 ? "" : " ") + word
            model.conversations.updateBlocks(entryID: answerID,
                                             blocks: [.activity(BlockActivity(toolCallID: "read", verbKey: "Reading %@",
                                                                             object: "README.md", status: .done)),
                                                      .markdown(id: "a", text)],
                                             text: text, persist: false)
            try? await Task.sleep(for: .milliseconds(120))
        }
        model.conversations.updateBlocks(entryID: answerID,
                                         blocks: [.activity(BlockActivity(toolCallID: "read", verbKey: "Reading %@",
                                                                         object: "README.md", status: .done)),
                                                  .markdown(id: "a", text)],
                                         text: text, persist: true)
        model.conversations.setTurnFinished(entryID: answerID, true)
    }

    // MARK: A run, as the engine leaves it on disk

    private static let slug = "harness-narada"

    /// A watchdog process and the instance folder it keeps, as the engine writes them: the Mac
    /// reads it as a run working by itself.
    @MainActor
    private func startRun(_ model: AppModel, product: UUID, chat: UUID) {
        // The chat that asked is the one working, as a message to Night Shift would be: its line
        // on the Lock Screen carries its name. This Mac has no engine, so the send itself stopped
        // on the folder; that is forgotten for the run.
        model.chatErrors[chat] = nil
        model.sendingChatIDs.insert(chat)
        guard watchdog == nil else { return }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("bulava-link-harness-narada")
        let instance = supervisor.appendingPathComponent("instances/\(Self.slug)")
        try? fm.createDirectory(at: instance, withIntermediateDirectories: true)
        let script = supervisor.appendingPathComponent("watchdog.sh")
        try? "#!/bin/sh\nsleep 3600\n".write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, Self.slug]
        try? process.run()
        watchdog = process
        try? folder.path.write(to: instance.appendingPathComponent("project"), atomically: true, encoding: .utf8)
        try? "night-\(Self.slug)".write(to: instance.appendingPathComponent("session"), atomically: true, encoding: .utf8)
        try? "\(process.processIdentifier)".write(to: instance.appendingPathComponent("watchdog.pid"), atomically: true, encoding: .utf8)
        let started = instance.appendingPathComponent("started-at")
        try? "".write(to: started, atomically: true, encoding: .utf8)
        // Started a minute ago, so it reads as working rather than starting.
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: started.path)
    }

    /// The run ends and its report comes in, waiting for the director; the chat that asked has its
    /// answer.
    @MainActor
    private func finishRun(_ model: AppModel, product: UUID, chat: UUID) {
        model.chatErrors[chat] = nil
        model.sendingChatIDs.remove(chat)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: "/tmp/bulava-link-harness-narada",
                                                           outcomeAt: Date()), to: chat)
        watchdog?.terminate()
        watchdog = nil
        try? FileManager.default.removeItem(at: supervisor.appendingPathComponent("instances/\(Self.slug)"))
        var task = BacklogTask(title: "Export fix", type: .feature, priority: .p2, state: .review)
        task.productID = product
        task.dispatchedAt = Date()
        _ = model.backlog.add(task)
    }

    /// A product with a few chats that show what the phone has to draw: prose with code, tool
    /// steps, an event, a question with options, and a message stopped on an untrusted folder.
    @MainActor
    private func seed(_ model: AppModel) {
        let product = model.products.add(name: "Narada", brief: "Meeting recorder for macOS")
        let release = model.conversations.newChat(for: product.id)
        model.conversations.appendUser("Why does the export button stay grey after a recording?",
                                       productID: product.id, chatID: release.id)
        let answer = model.conversations.beginForemanTurn(productID: product.id, chatID: release.id)
        model.conversations.updateBlocks(entryID: answer, blocks: [
            .activity(BlockActivity(toolCallID: "t1", verbKey: "Reading %@", object: "ExportController.swift", status: .done)),
            .activity(BlockActivity(toolCallID: "t2", verbKey: "Searching for %@", object: "isExportable", status: .done)),
            .markdown(id: "m1", """
            The button reads `isExportable`, and that flag is only set when the **transcript** finishes — not the recording.

            1. `RecordingSession.stop()` saves the audio.
            2. The transcript is written a few seconds later.
            3. Nothing tells the button to look again.

            ```swift
            session.onTranscriptReady = { exportButton.isEnabled = true }
            ```

            Want me to wire that up?
            """),
        ], text: "The button reads isExportable…", persist: true)
        model.conversations.setTurnFinished(entryID: answer, true)
        model.conversations.postEventOnce("Night shift finished the run — changes are on branch night/export-fix.",
                                          productID: product.id, chatID: release.id, tone: .good)

        let question = model.conversations.newChat(for: product.id)
        model.conversations.appendUser("Ship the new onboarding to TestFlight", productID: product.id, chatID: question.id)
        var ask = ConversationEntry(productID: product.id, kind: .question, text: "Which build number should this upload use?")
        ask.chatID = question.id
        ask.decision = DecisionRecord(
            headline: "Which build number should this upload use?",
            situation: "TestFlight already has build 41 for version 2.3. Uploading 41 again will be rejected.",
            items: [.init(question: "Build number", header: nil, options: ["42", "Keep 41 and bump the version"],
                          multiSelect: false,
                          optionDescriptions: ["42": "The next number, nothing else changes"])],
            recommendation: "42 — it is the smallest change that goes through.")
        model.conversations.append(ask)

        let blocked = model.conversations.newChat(for: product.id)
        let stopped = model.conversations.appendUser("Start on the settings redesign", productID: product.id, chatID: blocked.id)
        model.conversations.updateDelivery(entryID: stopped.id, .failed)
        model.trustBlocked[blocked.id] = "/Users/you/Developer/Narada"

        seedProbeReport(model, product: product.id)
        // `BULAVA_LINK_HARNESS_REPORT=<report.html>` adds a chat whose report is that file — a long
        // one, with its pictures beside it, for the phone's PDF.
        if let path = ProcessInfo.processInfo.environment["BULAVA_LINK_HARNESS_REPORT"], !path.isEmpty {
            let chat = model.conversations.newChat(for: product.id)
            model.conversations.appendUser("Show me the long report", productID: product.id, chatID: chat.id)
            model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: "/tmp/bulava-link-harness-narada",
                                                               claudeSessionID: "harness", outcomeAt: Date(),
                                                               reportPaths: [path]), to: chat.id)
            model.conversations.rename(chat.id, to: "Long report")
        }
        seedContext(model, product: product.id)
        _ = model.products.add(name: "Bulava site", brief: "")
    }

    /// What the phone's Context screen draws: a folder Night Shift may edit and a website it only
    /// reads, a finished task (so "everything done so far" exists), one running now, and a piece
    /// of work asked for in three variants with two of them in.
    @MainActor
    private func seedContext(_ model: AppModel, product: UUID) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-link-harness-narada")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = model.projects.add(path: folder.path)
        model.products.addResource(ProductResource(name: "Narada", kind: .folder, access: .workspace, projectID: project.id),
                                   to: product)
        model.products.addResource(ProductResource(name: "narada.app", kind: .website, access: .source,
                                                   urlString: "https://narada.app"), to: product)
        func task(_ title: String, _ state: TaskState) -> BacklogTask {
            var t = BacklogTask(title: title, type: .feature, priority: .p2, state: state)
            t.productID = product
            t.dispatchedAt = Date()
            return model.backlog.add(t)
        }
        _ = task("Export stays grey after a recording", .merged)
        _ = task("Settings redesign", .executing)
        let a = task("Onboarding, variant 1", .review)
        let b = task("Onboarding, variant 2", .review)
        _ = model.workItems.add(WorkItem(productID: product, title: "Onboarding in three variants", kind: .variants,
                                         streams: [.init(id: a.id, title: a.title, projectName: "Narada", variantNumber: 1),
                                                   .init(id: b.id, title: b.title, projectName: "Narada", variantNumber: 2)],
                                         requestedVariants: 3))
    }

    /// A chat whose report tries every way a page can reach out — a picture, a script, a frame, a
    /// style sheet, a font, `fetch`, a beacon, a redirect, a link — at `BULAVA_LINK_HARNESS_PROBE`
    /// (host:port, or several separated by commas, of a server that logs what it is asked for). A
    /// phone that shows it must leave that log empty, and still show the report's own picture.
    @MainActor
    private func seedProbeReport(_ model: AppModel, product: UUID) {
        guard let probe = ProcessInfo.processInfo.environment["BULAVA_LINK_HARNESS_PROBE"], !probe.isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-link-harness-report")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A 2×2 red PNG, the report's own picture, which must still be drawn.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGP8z8DAwMDAxMDAwMDAAAANHQEDasKb6QAAAABJRU5ErkJggg==")!
        try? png.write(to: folder.appendingPathComponent("local.png"))
        // Several addresses may be named, because a simulator and an emulator reach the Mac
        // differently (127.0.0.1 and 10.0.2.2); every one of them gets every kind of request.
        let hosts = probe.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let head = hosts.map { host in
            let base = "http://\(host)"
            return """
            <link rel="stylesheet" href="\(base)/style.css">
            <link rel="prefetch" href="\(base)/prefetch">
            <style>@font-face { font-family: X; src: url(\(base)/font.woff2); } body { font-family: X, sans-serif; }
            .bg { background: url(\(base)/background.png); height: 20px; }</style>
            <script src="\(base)/script.js"></script>
            """
        }.joined(separator: "\n")
        let body = hosts.map { host in
            let base = "http://\(host)"
            return """
            <img alt="remote" src="\(base)/image.png" width="10" height="10">
            <div class="bg"></div>
            <iframe src="\(base)/frame.html" width="40" height="20"></iframe>
            <video src="\(base)/video.mp4"></video>
            <script>
              try { fetch("\(base)/fetch"); } catch (e) {}
              try { new Image().src = "\(base)/js-image.png"; } catch (e) {}
              try { navigator.sendBeacon("\(base)/beacon", "x"); } catch (e) {}
              try { var x = new XMLHttpRequest(); x.open("GET", "\(base)/xhr"); x.send(); } catch (e) {}
              try { new WebSocket("ws://\(host)/socket"); } catch (e) {}
              setTimeout(function () { try { location.href = "\(base)/redirect"; } catch (e) {} }, 1500);
              setTimeout(function () { try { window.open("\(base)/popup"); } catch (e) {} }, 2000);
            </script>
            """
        }.joined(separator: "\n")
        let first = "http://\(hosts[0])"
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        \(head)
        </head><body>
        <h1>Probe report</h1>
        <p>The picture below is the report's own and should be visible:</p>
        <img alt="local" src="local.png" width="80" height="80" style="image-rendering: pixelated">
        \(body)
        <form action="\(first)/form" method="get"><button id="f">Form</button></form>
        <p><a id="out" href="\(first)/link">An outside link</a></p>
        <p><a id="blank" target="_blank" href="\(first)/blank">A link to a new window</a></p>
        <script>
          // A script clicking a link for the reader: the phone must ask, not go.
          setTimeout(function () { try { document.getElementById("out").click(); } catch (e) {} }, 3000);
        </script>
        </body></html>
        """
        let file = folder.appendingPathComponent("report.html")
        try? html.write(to: file, atomically: true, encoding: .utf8)
        let chat = model.conversations.newChat(for: product)
        model.conversations.appendUser("Show me the probe report", productID: product, chatID: chat.id)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: folder.path,
                                                           reportPaths: [file.path]), to: chat.id)
        model.conversations.rename(chat.id, to: "Probe report")
    }
}
