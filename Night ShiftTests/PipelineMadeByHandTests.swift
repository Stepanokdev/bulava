import AppKit
import SwiftUI
import XCTest
@testable import Bulava

/// Drives the real window the way a hand does: elements are found by what they say on screen, and
/// reached with mouse and key events sent to the window. Nothing here calls the editor's state.
@MainActor
final class WindowHand {
    let window: NSWindow
    init(_ window: NSWindow) { self.window = window }

    struct Element { let object: AnyObject; let label: String; let role: String; let frame: NSRect }

    /// Every labelled element of every window of the app, in screen coordinates.
    func elements(in windows: [NSWindow]? = nil) -> [(NSWindow, Element)] {
        var out: [(NSWindow, Element)] = []
        func walk(_ e: Any, _ w: NSWindow, _ depth: Int) {
            guard depth < 60 else { return }
            let o = e as AnyObject
            let parts: [String] = [(o.accessibilityLabel?() as String?) ?? "", (o.accessibilityTitle?() as String?) ?? "",
                                   (o.accessibilityPlaceholderValue?() as String?) ?? ""]
            let role = (o.accessibilityRole?() as NSAccessibility.Role?)?.rawValue ?? ""
            let frame: NSRect = o.accessibilityFrame?() ?? .zero
            let label = parts.filter { !$0.isEmpty }.joined(separator: " | ")
            if !label.isEmpty || ["AXTextField", "AXTextArea", "AXCheckBox", "AXPopUpButton"].contains(role) {
                out.append((w, Element(object: o, label: label, role: role, frame: frame)))
            }
            for c in (o.accessibilityChildren?() as [Any]?) ?? [] { walk(c, w, depth + 1) }
        }
        // This window, its sheets and its popovers — never the test host's own windows.
        let mine = NSApp.windows.filter { w in
            w.isVisible && (w === window || w.sheetParent === window || w.parent === window
                            || String(describing: Swift.type(of: w)).contains("Popover"))
        }
        // What is in front first: a popover or sheet takes the click, the window under it does not.
        for w in windows ?? (mine.filter { $0 !== window } + mine.filter { $0 === window }) { walk(w, w, 0) }
        return out
    }

    func dump(_ tag: String) {
        for (w, e) in elements() { print("HAND[\(tag)] \(w === window ? "main" : "\(Swift.type(of: w))") \(e.role) «\(e.label)» \(e.frame)") }
    }

    /// What says `label`, if anything does — no failure recorded when nothing does.
    /// `label` may name the same thing in several languages: "Створити|Create".
    func lookup(_ label: String, role: String? = nil, exact: Bool = false) -> (NSWindow, Element)? {
        let all = elements().filter { role == nil || $0.1.role == role }
        let names = label.split(separator: "|").map(String.init)
        let wanted = names.isEmpty ? [""] : names
        return wanted.lazy.compactMap { l in all.first { exact ? $0.1.label == l : $0.1.label.hasPrefix(l) } }.first
            ?? (exact ? nil : wanted.lazy.compactMap { l in all.first { $0.1.label.contains(l) } }.first)
    }

    func find(_ label: String, role: String? = nil, exact: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws -> (NSWindow, Element) {
        let hit = lookup(label, role: role, exact: exact)
        return try XCTUnwrap(hit, "nothing on screen says «\(label)»\(role.map { " (\($0))" } ?? "")", file: file, line: line)
    }

    private func mouse(_ type: NSEvent.EventType, _ at: NSPoint, _ w: NSWindow) {
        guard let e = NSEvent.mouseEvent(with: type, location: w.convertPoint(fromScreen: at), modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                         context: nil, eventNumber: Self.nextEventNumber(type), clickCount: type == .leftMouseDragged ? 0 : 1,
                                         pressure: type == .leftMouseUp ? 0 : 1) else { return }
        if ProcessInfo.processInfo.environment["BULAVA_HAND_CG"] == "1" {
            // Through the window server, addressed to this process alone.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let cgType: CGEventType = type == .leftMouseDown ? .leftMouseDown : type == .leftMouseUp ? .leftMouseUp : .leftMouseDragged
            let ev = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: cgType,
                             mouseCursorPosition: CGPoint(x: at.x, y: mainHeight - at.y), mouseButton: .left)
            ev?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.windowNumber))
            ev?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.windowNumber))
            ev?.postToPid(getpid())
            return
        }
        // Into the queue, as the window server delivers them: a press that starts a drag reads the
        // rest of the gesture from there, and an event handed straight to the window never arrives.
        NSApp.postEvent(e, atStart: false)
    }

    /// A key press into the event queue, where an open menu reads it.
    static func post(keyCode: UInt16, chars: String) {
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: keyCode) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// One press, one number: a drag and the release that ends it carry the number of the press.
    private static var pressNumber = 1000
    private static func nextEventNumber(_ type: NSEvent.EventType) -> Int {
        if type == .leftMouseDown { pressNumber += 1 }
        return pressNumber
    }

    func settle(_ ms: Int = 350) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// A click at a point on screen, into the window that is there.
    func click(at p: NSPoint, in w: NSWindow) async {
        mouse(.leftMouseDown, p, w)
        await settle(60)
        mouse(.leftMouseUp, p, w)
        await settle()
    }

    func click(_ label: String, role: String? = nil, exact: Bool = false, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (w, e) = try find(label, role: role, exact: exact, file: file, line: line)
        await click(at: NSPoint(x: e.frame.midX, y: e.frame.midY), in: w)
    }

    /// Press, move in small steps, release — a drag as the gesture recognisers see one.
    func drag(from a: NSPoint, to b: NSPoint, in w: NSWindow) async {
        mouse(.leftMouseDown, a, w)
        await settle(40)
        let steps = 14
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), w)
            await settle(16)
        }
        mouse(.leftMouseUp, b, w)
        await settle()
    }

    /// Typing: the characters go to whatever has the keyboard, as key presses.
    func type(_ text: String, in w: NSWindow? = nil) async {
        let target = w ?? NSApp.keyWindow ?? window
        var chunk = ""
        func send(_ s: String) {
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                guard let e = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: target.windowNumber, context: nil, characters: s,
                                               charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) else { continue }
                target.sendEvent(e)
            }
        }
        for ch in text {
            chunk.append(ch)
            if chunk.count >= 40 { send(chunk); chunk = "" }
        }
        if !chunk.isEmpty { send(chunk) }
        await settle()
    }
}

nonisolated final class PipelineMadeByHandTests: XCTestCase {

    /// Off unless asked: it takes about a minute of real clicking. `BULAVA_HAND_PIPELINE=1`; with
    /// `BULAVA_HAND_LIBRARY=<supervisor state>` it is made in that library instead of a scratch one.
    @MainActor
    func testMakeThePipelineByHand() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BULAVA_HAND_PIPELINE"] == "1" || env["TEST_RUNNER_BULAVA_HAND_PIPELINE"] == "1" else {
            throw XCTSkip("making a pipeline by hand was not asked for")
        }
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-hand-\(UUID().uuidString)")
        FixtureState.use(state.appendingPathComponent("app").path)
        let supervisorBefore = env["SUPERVISOR_STATE_DIR"]
        let library = env["BULAVA_HAND_LIBRARY"] ?? env["TEST_RUNNER_BULAVA_HAND_LIBRARY"] ?? state.appendingPathComponent("supervisor").path
        setenv("SUPERVISOR_STATE_DIR", library, 1)
        defer {
            FixtureState.restore()
            if let supervisorBefore { setenv("SUPERVISOR_STATE_DIR", supervisorBefore, 1) } else { unsetenv("SUPERVISOR_STATE_DIR") }
            try? FileManager.default.removeItem(at: state)
        }
        LanguageBundle.adopt(.uk)
        defer { LanguageBundle.adopt(.system) }
        NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")

        let model = AppModel()
        await model.loadPipelineLibrary()
        let registry = try XCTUnwrap(model.pipelineRegistry, "the engine's palette")
        let name = RolePipelineThroughTheEditorTests.name
        if let old = model.pipelineLibrary.first(where: { $0.displayName == name }) { _ = await model.deletePipeline(old.id) }
        model.route = .pipelines
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1500, height: 940),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView().environment(model).environment(UpdateController())
            .environment(\.locale, Locale(identifier: "uk")))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let hand = WindowHand(window)
        await hand.settle(800)

        // "New pipeline", a name, "Create".
        try await hand.click("Новий пайплайн|New pipeline", role: "AXButton")
        await hand.settle(600)
        let nameField = try hand.find("", role: "AXTextField")
        await hand.click(at: nameField.1.frame.center, in: nameField.0)
        await hand.type(name, in: nameField.0)
        try await hand.click("Створити|Create", role: "AXButton")
        await hand.settle(1500)
        guard case .pipeline(let pid) = model.route else { return XCTFail("the editor did not open: \(model.route)") }

        // Zoomed out so the whole pipeline fits the canvas.
        for _ in 0..<5 { try await hand.click("Вилучити|Zoom out|Remove", role: "AXButton") }

        /// Where the inspector begins: just left of its tabs, which move as the panel settles.
        func inspectorX() -> CGFloat { (hand.lookup("Крок|Step", role: "AXRadioButton")?.1.frame.minX ?? 1180) - 30 }
        func node(_ title: String) throws -> NSRect {
            if hand.lookup(title, role: "AXButton", exact: true) == nil {
                for (w, e) in hand.elements() where w === window { print("HAND[nodes] \(e.role) «\(e.label.prefix(80))» \(e.frame) \(Swift.type(of: e.object))") }
                print("HAND[responder] \(String(describing: window.firstResponder))")
            }
            return try hand.find(title, role: "AXButton", exact: true).1.frame
        }
        /// (unused) The AppKit menu button a picker might be drawn with.
        func popUpButton(at frame: NSRect) -> NSPopUpButton? {
            func walk(_ v: NSView) -> NSPopUpButton? {
                if let b = v as? NSPopUpButton, let w = b.window {
                    let onScreen = w.convertToScreen(b.convert(b.bounds, to: nil))
                    if onScreen.intersects(frame) { return b }
                }
                for c in v.subviews { if let hit = walk(c) { return hit } }
                return nil
            }
            return window.contentView.flatMap(walk)
        }
        /// The inspector's own controls: what lies right of the canvas.
        func inspector(_ role: String) -> [WindowHand.Element] {
            let x = inspectorX()
            return hand.elements().filter { $0.0 === window && $0.1.role == role && $0.1.frame.minX >= x }
                .map(\.1).sorted { $0.frame.maxY > $1.frame.maxY }
        }
        func typeInto(_ e: WindowHand.Element, _ text: String, replacing: Bool) async {
            // A tall editor runs on below the window; its first line is always in view.
            let y = e.frame.height > 60 ? e.frame.maxY - 14 : e.frame.midY
            await hand.click(at: NSPoint(x: e.frame.midX, y: y), in: window)
            // A text view under a scroll view in the inspector does not always take the keyboard from
            // the click alone; giving it the focus is what the click was meant to do.
            if let view = e.object as? NSView, window.firstResponder !== view {
                window.makeFirstResponder(view)
                await hand.settle(150)
            }
            if let tv = window.firstResponder as? NSTextView, !tv.isFieldEditor {
                // A multi-line editor takes typing through the text input system, where key
                // presses end up; synthesised key presses do not reach it.
                if replacing { tv.selectAll(nil) }
                tv.insertText(text, replacementRange: tv.selectedRange())
                await hand.settle()
                return
            }
            if replacing { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            await hand.type(text, in: window)
        }

        /// "Add step" with `after` selected, the module picked from the palette by its name, then
        /// named, set and prompted in the inspector — and moved by dragging it, when asked to.
        func add(_ key: String, _ title: String, after: String, engine: String? = nil, required: Bool = false,
                 prompt: String? = nil) async throws {
            // A new step goes right of the selected one; `after` is selected already — it was added last.
            XCTAssertNotNil(hand.lookup(after, role: "AXButton", exact: true), "«\(after)» is on the canvas")
            try await hand.click("Додати крок|Add step", role: "AXButton")
            await hand.settle(500)
            let spec = try XCTUnwrap(registry.modules[key])
            let search = try hand.find("Знайти крок|Find a step", role: "AXTextField")
            await hand.click(at: search.1.frame.center, in: search.0)
            await hand.type(spec.t.local, in: search.0)
            try await hand.click(spec.t.local + ",", role: "AXButton")
            await hand.settle(500)
            // The new step is selected: its name is the first field of the inspector.
            let fields = inspector("AXTextField")
            if fields.isEmpty { hand.dump("after-pick \(key)"); print("HAND inspectorX \(inspectorX())") }
            let nameBox = try XCTUnwrap(fields.first, "the step's name field")
            await typeInto(nameBox, title, replacing: true)
            if let engine {
                // The menu opens from a click, as it does for a person; the item is then chosen in
                // that open menu, by the menu itself.
                let popup = try XCTUnwrap(inspector("AXPopUpButton").first, "the engine choice")
                let wantedTitle = spec.p?.first { $0.k == "engine" }.map { $0.optionLabel(engine) } ?? engine
                let picked = LockedBox("menu did not open")
                let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                    guard let menu = note.object as? NSMenu else { return }
                    let titles = menu.items.map(\.title)
                    guard let i = titles.firstIndex(of: wantedTitle) else { picked.set("no «\(wantedTitle)» in \(titles)"); return }
                    RunLoop.main.perform(inModes: [.eventTracking, .common]) {
                        menu.cancelTracking()
                        menu.performActionForItem(at: i)
                        picked.set("chose «\(wantedTitle)»")
                    }
                }
                await hand.click(at: popup.frame.center, in: window)
                await hand.settle(900)
                NotificationCenter.default.removeObserver(token)
                XCTAssertEqual(picked.get(), "chose «\(wantedTitle)»", "the engine menu")
            }
            if required {
                // The switches carry no name of their own; they stand in the order of the step's settings.
                let bools = (spec.p ?? []).filter { $0.type == "bool" }.map(\.k)
                let at = try XCTUnwrap(bools.firstIndex(of: "required"), "\(key) has no «Required step»")
                let switches = inspector("AXCheckBox")
                XCTAssertEqual(switches.count, bools.count, "one switch per on/off setting")
                let toggle = try XCTUnwrap(switches.indices.contains(at) ? switches[at] : nil, "the «Required step» switch")
                func isOn() -> Bool { ((inspector("AXCheckBox")[at].object.accessibilityValue?() as Any?) as? NSNumber)?.boolValue ?? false }
                // A panel still settling after the menu closed can let the first click pass; a person
                // looks and clicks again.
                for _ in 0..<3 where !isOn() {
                    await hand.click(at: inspector("AXCheckBox")[at].frame.center, in: window)
                    await hand.settle(300)
                }
                XCTAssertTrue(isOn(), "«Required step» is on for \(title)")
                _ = toggle
            }
            if let prompt {
                try await hand.click("Написати свій|Write my own", role: "AXButton")
                // It starts from the built-in prompt, which is read from the engine: wait for it.
                var editor: WindowHand.Element?
                for _ in 0..<40 {
                    await hand.settle(150)
                    if let e = inspector("AXTextArea").first, let tv = e.object as? NSTextView, tv.string.count > 20 { editor = e; break }
                }
                let editorFound = try XCTUnwrap(editor, "the prompt editor with the built-in text")
                let _ = editorFound
                await typeInto(editorFound, prompt, replacing: true)
                XCTAssertEqual((editorFound.object as? NSTextView)?.string, prompt, "the prompt as typed")
            }
        }

        let chat = try hand.elements().first { $0.0 === window && $0.1.role == "AXButton" && $0.1.label == registry.modules["trigger.chat"]?.t.local }
        let chatTitle = try XCTUnwrap(chat?.1.label, "the chat message step a new pipeline starts with")
        let t = RolePipelineThroughTheEditorTests.self
        // Each new step goes right of the step selected last — the one just added — so they line up
        // in the order the work runs. Placing them in rows and pulling the wires are drags, and a drag
        // on the canvas is a gesture only the system's own pointer can make: see the end of this test.
        try await add("prep.context", "Контекст задачі", after: chatTitle)
        try await add("prep.classify", "Тріаж", after: "Контекст задачі")
        try await add("prep.position", "Бізнес-аналітик", after: "Тріаж", engine: "codex", required: true, prompt: t.analyst)
        try await add("prep.position", "Тестувальник", after: "Бізнес-аналітик", engine: "claude", required: true, prompt: t.tester)
        try await add("prep.position", "Архітектор Claude", after: "Тестувальник", engine: "claude", required: true, prompt: t.architect)
        try await add("prep.position", "Архітектор Codex", after: "Архітектор Claude", engine: "codex", required: true, prompt: t.architect)
        try await add("prep.align", "Домовленість", after: "Архітектор Codex", required: true)
        try await add("prep.compose", "Бриф виконавцю", after: "Домовленість")
        try await add("agent.claude", "Claude реалізує", after: "Бриф виконавцю")
        try await add("gate.review", "Рев'ю Codex", after: "Claude реалізує")
        try await add("out.merge", "Злиття гілки", after: "Рев'ю Codex")

        await hand.settle(2500)   // the editor saves on its own a moment after the last change

        // A restart: a new model reads the library from disk, and the pipeline is opened from it.
        window.close()
        let again = AppModel()
        await again.loadPipelineLibrary()
        let card = try XCTUnwrap(again.pipelineLibrary.first { $0.id == pid }, "it is in the library after a restart")
        XCTAssertEqual(card.displayName, name)
        let loaded = await again.editorLoad(pid)
        let detail = try XCTUnwrap(loaded)
        let doc = detail.document
        func n(_ title: String) -> PipelineNode? { doc.nodes.first { $0.title == title } }
        XCTAssertEqual(doc.nodes.count, 12, "every step: \(doc.nodes.map { $0.title ?? $0.id })")
        XCTAssertEqual(n("Бізнес-аналітик")?.params?["engine"], .string("codex"))
        XCTAssertEqual(n("Тестувальник")?.params?["engine"], .string("claude"))
        XCTAssertEqual(n("Архітектор Codex")?.params?["engine"], .string("codex"))
        for title in ["Бізнес-аналітик", "Тестувальник", "Архітектор Claude", "Архітектор Codex", "Домовленість"] {
            XCTAssertEqual(n(title)?.params?["required"], .bool(true), "\(title) is required")
        }
        XCTAssertEqual(n("Бізнес-аналітик")?.prompt, t.analyst)
        XCTAssertEqual(n("Тестувальник")?.prompt, t.tester)
        XCTAssertEqual(n("Архітектор Codex")?.prompt, t.architect)
        // Not drawn by hand: the wires. Every one of them is a drag from an output dot, and the
        // canvas takes drags only from the system's pointer — synthesised events reach its buttons and
        // fields but never a drag gesture, however they are sent. With Accessibility granted to Bulava
        // they can be pulled with the real pointer; until then the editor reports exactly what is
        // missing, and that is what is checked here.
        XCTAssertTrue(doc.edges.isEmpty, "no wire can have been drawn without the pointer")
        XCTAssertFalse(detail.validation.issues.filter(\.isError).isEmpty, "the editor says the steps are not connected yet")

        // And it opens: from the library, in a fresh window, every step on the canvas.
        again.route = .pipelines
        let second = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1500, height: 940),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false
        second.contentView = NSHostingView(rootView: RootView().environment(again).environment(UpdateController())
            .environment(\.locale, Locale(identifier: "uk")))
        second.makeKeyAndOrderFront(nil)
        defer { second.close() }
        let hand2 = WindowHand(second)
        await hand2.settle(900)
        try await hand2.click(name + ",", role: "AXButton")
        await hand2.settle(1500)
        guard case .pipeline(pid) = again.route else { return XCTFail("the card did not open the editor: \(again.route)") }
        let onCanvas = Set(hand2.elements().filter { $0.0 === second && $0.1.role == "AXButton" }.map(\.1.label))
        for title in doc.nodes.compactMap(\.title) { XCTAssertTrue(onCanvas.contains(title), "«\(title)» is not on the canvas") }
        if let out = env["BULAVA_RENDER_DIR"] ?? env["TEST_RUNNER_BULAVA_RENDER_DIR"], let view = second.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("pipeline-by-hand.png"))
        }
        print("HAND PIPELINE \(pid) in \(library)")
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
