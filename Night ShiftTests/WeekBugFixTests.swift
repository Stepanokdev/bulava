import AppKit
import SwiftUI
import XCTest
@testable import Bulava

/// The app's half of the fixes to the bugs found in the week of 9–16 Oct.
nonisolated final class WeekBugFixTests: XCTestCase {

    private var state: URL!

    override func setUp() async throws {
        state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-week-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        FixtureState.use(state.appendingPathComponent("app").path)
    }

    override func tearDown() async throws {
        FixtureState.restore()
        LanguageBundle.adopt(.system)
        try? FileManager.default.removeItem(at: state)
    }

    // MARK: A finished chat with work still under way keeps its folder

    func testAFinishedHolderWithWorkUnderWayIsNotTakeable() {
        XCTAssertFalse(ProjectHandoff.holderHasWorkUnderWay(queuedMessages: 0, backgroundCommands: 0))
        XCTAssertTrue(ProjectHandoff.holderHasWorkUnderWay(queuedMessages: 1, backgroundCommands: 0),
                      "a message accepted for it and not delivered yet")
        XCTAssertTrue(ProjectHandoff.holderHasWorkUnderWay(queuedMessages: 0, backgroundCommands: 2),
                      "commands it left running in the background")
    }

    /// The count is of the shells Claude Code starts for its Bash tool, under the session's pane —
    /// here a real tmux session holding one such shell, and one that is not.
    @MainActor
    func testBackgroundCommandsAreCountedInTheSession() async throws {
        let which = await Shell.run("command -v tmux", timeout: 5)
        guard which.exitCode == 0 else { throw XCTSkip("tmux is not installed") }
        let session = "bulava-bg-\(UUID().uuidString.prefix(8))"
        let snapshots = state.appendingPathComponent("shell-snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let snapshot = snapshots.appendingPathComponent("snapshot-zsh-1-test.sh")
        try "true\n".write(to: snapshot, atomically: true, encoding: .utf8)
        // What Claude Code runs for a background command, and a process it did not start that way.
        // Started from a script, so the pane's own command line does not carry the marker.
        let start = state.appendingPathComponent("start.sh")
        try "sleep 60 &\nbash -c 'source \(snapshot.path) && sleep 60' &\nwait\n"
            .write(to: start, atomically: true, encoding: .utf8)
        _ = await Shell.run("tmux new-session -d -s \"$1\" \"bash $2\"", args: [session, start.path], timeout: 10)
        defer { Task { _ = await Shell.run("tmux kill-session -t \"$1\"", args: [session], timeout: 10) } }
        try await Task.sleep(for: .milliseconds(500))

        let client = SupervisorClient(paths: SupervisorPaths(stateDir: state))
        let counted = await client.backgroundCommandCount(session: session)
        XCTAssertEqual(counted, 1, "the snapshot shell, and only it")
        let none = await client.backgroundCommandCount(session: "no-such-session-\(UUID().uuidString)")
        XCTAssertEqual(none, 0)
    }

    // MARK: The phone is given addresses it can reach

    func testAVirtualMachineNetworkIsNotOfferedBesideWiFi() {
        XCTAssertEqual(ShareAddresses.preferringWiFi(wired: ["10.0.1.7"], bridged: ["192.168.64.1"]),
                       ["10.0.1.7"], "13 Oct the phone was given the UTM bridge, which it cannot reach")
        XCTAssertEqual(ShareAddresses.preferringWiFi(wired: [], bridged: ["192.168.2.1"]), ["192.168.2.1"],
                       "with nothing else, a bridge is still better than no address")
        XCTAssertEqual(ShareAddresses.preferringWiFi(wired: ["fe80::1", "10.0.1.7"], bridged: []),
                       ["10.0.1.7", "fe80::1"], "IPv4 first")
    }

    // MARK: The product's writable folders reach the engine's write gate

    @MainActor
    func testTheFoldersAChatMayChangeAreWrittenForTheEngine() async throws {
        let main = state.appendingPathComponent("Night Shift")
        let extra = state.appendingPathComponent("n8n benchmark bulava")
        let asked = state.appendingPathComponent("Client repo")
        for url in [main, extra, asked] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let model = AppModel()
        let a = model.projects.add(path: main.path), b = model.projects.add(path: extra.path),
            c = model.projects.add(path: asked.path)
        let product = model.products.add(name: "Bulava", resources: [
            ProductResource(name: "Night Shift", access: .workspace, projectID: a.id),
            ProductResource(name: "n8n benchmark", access: .workspace, projectID: b.id),
            ProductResource(name: "Client", access: .source, projectID: c.id),
        ])
        let chat = model.conversations.newChat(for: product.id)
        let files = try XCTUnwrap(model.writeSessionContext(chatID: chat.id, product: product, primary: a))
        let writable = files.directories.deletingLastPathComponent().appendingPathComponent("writable-directories.txt")
        let lines = try String(contentsOf: writable, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Set(lines), Set([Slug.canonicalPath(extra.path), Slug.canonicalPath(asked.path)]),
                       "the other folders, the ask-first one included: asking first is an agreement, and his yes has to be able to take effect")
        XCTAssertFalse(lines.contains(Slug.canonicalPath(main.path)), "the main folder is the run's own")
    }

    // MARK: One new line does not make every chat read the whole history again

    @MainActor
    func testAChangeInOneChatLeavesTheOthersCachedAndRight() {
        let store = ConversationStore(fileURL: state.appendingPathComponent("c.json"), chatsURL: state.appendingPathComponent("ch.json"))
        let product = UUID()
        let a = store.newChat(for: product), b = store.newChat(for: product)
        for n in 0..<3 {
            store.appendUser("a\(n)", productID: product, chatID: a.id)
            store.appendUser("b\(n)", productID: product, chatID: b.id)
        }
        XCTAssertEqual(store.entries(inChat: a.id).map(\.text), ["a0", "a1", "a2"])
        XCTAssertEqual(store.entries(inChat: b.id).map(\.text), ["b0", "b1", "b2"])
        store.appendUser("a3", productID: product, chatID: a.id)
        XCTAssertEqual(store.entries(inChat: a.id).map(\.text), ["a0", "a1", "a2", "a3"], "the changed chat is read again")
        XCTAssertEqual(store.entries(inChat: b.id).map(\.text), ["b0", "b1", "b2"], "the other is still right")
        // A removal in the middle shifts everything after it: both chats must still be right.
        let first = store.entries(inChat: a.id)[0]
        store.remove(entryID: first.id)
        XCTAssertEqual(store.entries(inChat: a.id).map(\.text), ["a1", "a2", "a3"])
        XCTAssertEqual(store.entries(inChat: b.id).map(\.text), ["b0", "b1", "b2"])
    }

    // MARK: A save that cannot happen is not tried for ever

    func testASaveIntoAFolderThatIsGoneIsDroppedAndAnotherFailureIsRetriedWithoutEncodingAgain() throws {
        let encodes = LockedBox(0)
        let gone = state.appendingPathComponent("removed-\(UUID().uuidString)/history.json")
        CoalescedWrites.shared.schedule(gone, delay: 0) { encodes.set(encodes.get() + 1); return Data("[]".utf8) }
        CoalescedWrites.shared.flush(gone)
        Thread.sleep(forTimeInterval: 2.5)
        CoalescedWrites.shared.flush(gone)
        XCTAssertEqual(encodes.get(), 1, "its folder is gone: tried once, not every two seconds")

        // The folder is there but the save fails (the name is taken by a folder): tried again with
        // the same bytes, until it can be written.
        let blocked = state.appendingPathComponent("blocked.json")
        try FileManager.default.createDirectory(at: blocked.appendingPathComponent("x"), withIntermediateDirectories: true)
        let tries = LockedBox(0)
        CoalescedWrites.shared.schedule(blocked, delay: 0) { tries.set(tries.get() + 1); return Data("[\"kept\"]".utf8) }
        CoalescedWrites.shared.flush(blocked)
        try FileManager.default.removeItem(at: blocked)
        Thread.sleep(forTimeInterval: 2.5)
        CoalescedWrites.shared.flush(blocked)
        XCTAssertEqual(try? Data(contentsOf: blocked), Data("[\"kept\"]".utf8), "retried, and written once it could be")
        XCTAssertEqual(tries.get(), 1, "with the bytes it had made, not by encoding again")
    }

    // MARK: The automation sheet fits its window

    /// Drawn at the sheet's smallest width in Ukrainian, where the work-mode switch alone was wider
    /// than the sheet and pushed the form off both its edges. The frame is written for a person to
    /// look at; the check is that the form's own width stays inside the sheet.
    @MainActor
    func testTheAutomationFormFitsTheSheetInUkrainian() async throws {
        LanguageBundle.adopt(.uk)
        let folder = state.appendingPathComponent("Ledger")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel()
        let project = model.projects.add(path: folder.path)
        let product = model.products.add(name: "Дуже довга назва продукту для перевірки ширини",
                                         resources: [ProductResource(name: "Ledger", projectID: project.id)])
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.appendUser("Щопонеділка перевіряй пошукові запити й пиши статтю", productID: product.id, chatID: chat.id)

        let sheet: CGFloat = 600
        // Offered the width inside the sheet's padding, the section takes no more than that. A
        // segmented switch of fixed width made it ask for more, and the form was cut on both sides.
        let work = NSHostingController(rootView: AutomationWorkSection(draft: .constant(AutomationDraft()))
            .environment(\.locale, Locale(identifier: "uk")))
        let taken = work.sizeThatFits(in: CGSize(width: sheet - 36, height: 2000))
        XCTAssertLessThanOrEqual(taken.width, sheet - 36,
                                 "the work-mode section stays inside the sheet")

        let host = NSHostingView(rootView: AutomationEditor(request: .fromChat(chat.id))
            .environment(model)
            .environment(\.locale, Locale(identifier: "uk"))
            .frame(width: sheet, height: 900))
        host.frame = CGRect(x: 0, y: 0, width: sheet, height: 900)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let dir = ProcessInfo.processInfo.environment["TEST_RUNNER_BULAVA_RENDER_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("bulava-frames").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: dir).appendingPathComponent("automation-editor-uk-600.png")
        try png.write(to: url)
        print("FRAME \(url.path)")
    }
}

/// The test host runs against a fixture state folder of its own (`BULAVA_STATE_DIR`). A test that
/// points it elsewhere puts the host's own value back afterwards — removing it instead left every
/// test after it without its fixture, and the settings tests saw that.
nonisolated enum FixtureState {
    /// What each `use` replaced, so each `restore` puts back exactly that.
    nonisolated(unsafe) private static var replaced: [String?] = []
    static func use(_ path: String) {
        replaced.append(ProcessInfo.processInfo.environment["BULAVA_STATE_DIR"])
        setenv("BULAVA_STATE_DIR", path, 1)
    }
    static func restore() {
        let previous = replaced.popLast() ?? nil
        if let previous { setenv("BULAVA_STATE_DIR", previous, 1) } else { unsetenv("BULAVA_STATE_DIR") }
    }
}
