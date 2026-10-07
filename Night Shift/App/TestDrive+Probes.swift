import Foundation
import AppKit

/// Checks that run inside the live app, on its real window — for the things a unit test cannot
/// show: whether one answer selects and copies as a whole, whether the field grows after a long
/// dictation or a narrower window, whether a long thread keeps up while an answer streams in, and
/// whether a long recording is transcribed without the window standing still.
///
/// Reached only through `TestDrive`, so only when `BULAVA_TEST_INBOX` is set. Each probe answers
/// in the reply file with what it measured; the frames are taken from outside, of this window.
///
///     {"do":"probe","probe":"selectcopy"}
///     {"do":"probe","probe":"draft","product":"Night","text":"…"}
///     {"do":"probe","probe":"width","width":900}
///     {"do":"probe","probe":"stream","product":"Night","seconds":8}
///     {"do":"probe","probe":"scrolltop"}
///     {"do":"probe","probe":"find","text":"Whisper"}
///     {"do":"probe","probe":"transcribe","path":"/tmp/three-minutes.m4a","language":"uk"}
///     {"do":"probe","probe":"blankwatch","seconds":12}
///     {"do":"probe","probe":"order","to":"back"}
extension TestDrive {

    func probe(_ obj: [String: Any], _ model: AppModel) {
        let which = (obj["probe"] as? String) ?? ""
        switch which {
        case "selectcopy": selectAndCopy()
        case "draft":      dictateIntoField(obj, model)
        case "width":      resizeWindow(obj, model)
        case "stream":     streamAnswer(obj, model)
        case "scrolltop":  scrollThreadToTop()
        case "find":       findInThread(obj, model)
        case "transcribe": transcribe(obj)
        case "thread":     note("thread: " + threadState())
        case "chat":       openChat(obj, model)
        case "click":      pointer(obj, drag: false)
        case "drag":       pointer(obj, drag: true)
        case "key":        key(obj)
        case "blur":       window?.makeFirstResponder(nil); note("blur: no field has the keyboard")
        case "send":
            // What a menu item does once chosen: its action, down the responder chain.
            let action = (obj["action"] as? String) ?? ""
            let handled = NSApp.sendAction(Selector(action), to: nil, from: nil)
            note("send \(action): handled=\(handled)")
        case "undo":
            let u = window?.undoManager
            // {"probe":"undo","perform":"undo"|"redo"} — what Edit → Undo does in a key window.
            switch obj["perform"] as? String {
            case "undo": u?.undo()
            case "redo": u?.redo()
            default: break
            }
            note("undo: manager=\(u.map { "\(ObjectIdentifier($0))" } ?? "none") canUndo=\(u?.canUndo ?? false) "
                 + "canRedo=\(u?.canRedo ?? false) action=\(u?.undoActionName ?? "") responder=\(window?.firstResponder.map { "\(type(of: $0))" } ?? "none")")
        case "run":        Task { @MainActor [weak self] in self?.note("run: " + (await self?.runState(model) ?? "")) }
        case "wheel":      wheel(obj)
        case "blankwatch": watchForBlankThread(obj)
        case "order":      orderWindow(obj)
        case "findnext":
            let phrase = (obj["text"] as? String) ?? ""
            model.findNextRequest = UUID()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(4000))
                guard let self else { return }
                self.note("findnext “\(phrase)”: match on screen: \(self.phraseOnScreen(phrase)); " + self.threadState())
            }
        case "onscreen":   note("onscreen “\((obj["text"] as? String) ?? "")”: "
                                + "\(phraseOnScreen((obj["text"] as? String) ?? "")); " + threadState())
        default:           note("probe: unknown “\(which)”")
        }
    }

    // MARK: - The pointer, inside the window

    /// A click or a drag at window points measured from the top-left corner — the same corner a
    /// drawn shot (`shot` with `what: drawn`) starts from, at half its pixel size. Events go to the
    /// window directly, so no Accessibility grant is involved.
    /// {"do":"probe","probe":"click","x":420,"y":310}
    /// {"do":"probe","probe":"drag","x":420,"y":310,"toX":600,"toY":330}
    private func pointer(_ obj: [String: Any], drag: Bool) {
        guard let window else { note("pointer: no window"); return }
        let height = window.frame.height
        func point(_ x: Any?, _ y: Any?) -> NSPoint {
            NSPoint(x: (x as? Double) ?? Double((x as? Int) ?? 0), y: height - ((y as? Double) ?? Double((y as? Int) ?? 0)))
        }
        let start = point(obj["x"], obj["y"])
        let end = drag ? point(obj["toX"], obj["toY"]) : start
        func send(_ type: NSEvent.EventType, _ at: NSPoint) {
            guard let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            window.sendEvent(e)
        }
        // A covered window does not redraw, and a view that has not been drawn does not take a
        // click: up for the length of the gesture, never key, then back.
        window.orderFrontRegardless()
        Task { @MainActor [weak self] in
            defer { window.orderBack(nil) }
            try? await Task.sleep(for: .milliseconds(400))
            send(.leftMouseDown, start)
            if drag {
                let steps = 16
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    send(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                    try? await Task.sleep(for: .milliseconds(16))
                }
            } else {
                try? await Task.sleep(for: .milliseconds(60))
            }
            send(.leftMouseUp, end)
            self?.note(drag ? "drag: \(start) → \(end)" : "click: \(start)")
        }
    }

    /// A key to the window's first responder: {"do":"probe","probe":"key","chars":"z","command":true}
    private func key(_ obj: [String: Any]) {
        guard let window else { note("key: no window"); return }
        let chars = (obj["chars"] as? String) ?? ""
        var flags: NSEvent.ModifierFlags = []
        if obj["command"] as? Bool == true { flags.insert(.command) }
        if obj["shift"] as? Bool == true { flags.insert(.shift) }
        let code = UInt16((obj["code"] as? Int) ?? 0)
        var byMenu = false
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { continue }
            if flags.contains(.command), type == .keyDown, NSApp.mainMenu?.performKeyEquivalent(with: e) == true {
                byMenu = true
                continue
            }
            window.sendEvent(e)
        }
        note("key: \(chars) \(flags.rawValue) menu=\(byMenu)")
    }

    // MARK: - A chat's run, as the run view reads it

    /// What the run view would draw for the open chat, and every step it took to get there.
    private func runState(_ model: AppModel) async -> String {
        guard let productID = model.route.productID ?? model.selectedProductID,
              let chatID = model.conversations.displayedChatID(for: productID) else { return "no chat open" }
        guard let binding = model.conversations.chat(id: chatID)?.session else { return "chat \(chatID) has no session" }
        let events = await model.client.runEvents(projectPath: binding.projectPath, runID: binding.activeRunID)
        let ids = model.conversations.entries(inChat: chatID).filter { $0.kind == .user }.map(\.id.uuidString)
        let latest = RunReducer.latestMessage(in: events, among: ids)
        await model.refreshChatRun(chatID: chatID)
        let run = model.chatRuns[chatID]
        return "path=\(binding.projectPath) events=\(events.count) users=\(ids.count) latest=\(latest ?? "-") "
            + "document=\(run?.document?.id ?? "-") overall=\(run.map { "\($0.graph.overall)" } ?? "-")"
    }

    // MARK: - The window and what is in it

    private var window: NSWindow? {
        NSApp.windows.first { MainWindow.isMain($0) && $0.isVisible } ?? NSApp.windows.first { $0.isVisible }
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        var out: [T] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let hit = view as? T { out.append(hit) }
            stack.append(contentsOf: view.subviews)
        }
        return out
    }

    /// The conversation's own scroll view: the tallest document in the window.
    private var thread: NSScrollView? {
        views(NSScrollView.self, in: window?.contentView)
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private func threadState() -> String {
        guard let scroll = thread, let doc = scroll.documentView else { return "no thread" }
        let visible = scroll.contentView.documentVisibleRect
        let fromBottom = doc.isFlipped ? doc.frame.height - visible.maxY : visible.minY
        return "content \(Int(doc.frame.height)) pt, viewport \(Int(visible.height)) pt, "
            + "offset \(Int(visible.minY)), \(Int(max(0, fromBottom))) pt from the end"
    }

    /// The composer's text view: the editable one.
    private var composerText: NSTextView? {
        views(NSTextView.self, in: window?.contentView).first { $0.isEditable && $0.isFieldEditor == false }
    }

    private func composerHeight() -> String {
        guard let text = composerText, let scroll = text.enclosingScrollView else { return "no composer" }
        let lines = text.string.split(separator: "\n", omittingEmptySubsequences: false).count
        return "field \(Int(scroll.frame.height)) pt tall, width \(Int(scroll.frame.width)) pt, "
            + "\(lines) line(s) of text, scrolls inside: \(scroll.hasVerticalScroller)"
    }

    // MARK: - Probes

    /// Select everything in the longest answer on screen and copy it, the way ⌘A ⌘C would — then
    /// put back whatever was on the clipboard before.
    private func selectAndCopy() {
        let prose = views(ProseNSTextView.self, in: window?.contentView)
        guard let longest = prose.max(by: { $0.string.count < $1.string.count }) else {
            note("selectcopy: no answer text on screen"); return
        }
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        window?.makeFirstResponder(longest)
        longest.selectAll(nil)
        let selected = longest.selectedRange()
        longest.copy(nil)
        let copied = board.string(forType: .string) ?? ""
        let paragraphs = copied.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        note("selectcopy: \(prose.count) answer text view(s) on screen; one selection covers "
             + "\(selected.length) of \(longest.string.utf16.count) characters; copied \(copied.count) "
             + "characters in \(paragraphs) non-empty lines; bullets: \(copied.contains("• ")); "
             + "numbered: \(copied.range(of: #"(?m)^\s*\d+\. "#, options: .regularExpression) != nil)\n"
             + "----- copied, first 600 characters -----\n\(copied.prefix(600))\n-----")
        board.clearContents()
        if !saved.isEmpty { board.writeObjects(saved) }
    }

    /// What a finished dictation does: words appended to the open chat's field from outside it.
    private func dictateIntoField(_ obj: [String: Any], _ model: AppModel) {
        guard let product = productNamed(obj["product"] as? String, model) else { return }
        let text = (obj["text"] as? String) ?? Self.longDictation
        if obj["clear"] as? Bool == true { model.setDraftText("", for: product.id) }
        model.appendToDraft(text, slot: model.draftSlot(for: product.id))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.note("draft: " + (self?.composerHeight() ?? ""))
        }
    }

    private func resizeWindow(_ obj: [String: Any], _ model: AppModel) {
        guard let window, let width = obj["width"] as? Double else { note("width: needs a width"); return }
        var frame = window.frame
        frame.size.width = width
        let beat = Heartbeat()
        beat.start()
        let started = Date()
        window.setFrame(frame, display: true, animate: false)
        let laidOut = Date().timeIntervalSince(started)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            let worst = beat.stop()
            self?.note("width \(Int(width)): resize took \(Int(laidOut * 1000)) ms, longest main-thread "
                       + "stall \(Int(worst * 1000)) ms; " + (self?.composerHeight() ?? "")
                       + "; " + (self?.threadState() ?? ""))
        }
    }

    private func scrollThreadToTop() {
        guard let scroll = thread, let doc = scroll.documentView else { note("scrolltop: no thread"); return }
        let top = doc.isFlipped ? NSPoint(x: 0, y: 0)
            : NSPoint(x: 0, y: doc.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: top)
        scroll.reflectScrolledClipView(scroll.contentView)
        note("scrolltop: " + threadState())
    }

    /// An answer written into the open chat ten times a second, the way the engine streams one,
    /// while a heartbeat measures how long the main thread goes without answering.
    private func streamAnswer(_ obj: [String: Any], _ model: AppModel) {
        guard let product = productNamed(obj["product"] as? String, model) else { return }
        let seconds = (obj["seconds"] as? Double) ?? 8
        let chat = model.conversations.currentChat(for: product.id)
        let turn = model.conversations.beginForemanTurn(productID: product.id, chatID: chat.id)
        let before = threadState()
        let beat = Heartbeat()
        beat.start()
        Task { @MainActor [weak self] in
            var text = ""
            let started = Date()
            var chunks = 0
            while Date().timeIntervalSince(started) < seconds {
                chunks += 1
                text += chunks % 6 == 0
                    ? "\n\n- пункт \(chunks): перевіряю, що тред встигає за відповіддю\n"
                    : "Шматок \(chunks) відповіді, що надходить потоком. "
                model.conversations.updateBlocks(entryID: turn, blocks: [.markdown(id: "m", text)],
                                                 text: text, persist: true)
                try? await Task.sleep(for: .milliseconds(100))
            }
            model.conversations.setTurnFinished(entryID: turn, true)
            try? await Task.sleep(for: .milliseconds(600))
            let worst = beat.stop()
            self?.note("stream: \(chunks) chunks in \(Int(seconds)) s into a thread of "
                       + "\(model.visibleEntries(inChat: chat.id).count) messages; longest main-thread "
                       + "stall \(Int(worst * 1000)) ms\n  before: \(before)\n  after:  \(self?.threadState() ?? "")")
        }
    }

    /// Open Find and type the phrase into its field, as he would.
    private func findInThread(_ obj: [String: Any], _ model: AppModel) {
        guard let phrase = obj["text"] as? String, !phrase.isEmpty else { note("find: needs text"); return }
        model.findOpenRequest = UUID()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let editor = self?.window?.firstResponder as? NSTextView else {
                self?.note("find: the find field did not take focus"); return
            }
            editor.insertText(phrase, replacementRange: editor.selectedRange())
            try? await Task.sleep(for: .milliseconds(4000))
            self?.note("find “\(phrase)”: " + (self?.threadState() ?? "")
                       + "; match on screen: \(self?.phraseOnScreen(phrase) ?? false)")
        }
    }

    /// Whether an answer holding the phrase is drawn inside the visible part of the thread, with
    /// the phrase itself in view.
    private func phraseOnScreen(_ phrase: String) -> Bool {
        guard let scroll = thread else { return false }
        let viewport = scroll.convert(scroll.bounds, to: nil)
        for text in views(ProseNSTextView.self, in: window?.contentView) where text.window != nil {
            let range = (text.string as NSString).range(of: phrase)
            guard range.location != NSNotFound, let layout = text.layoutManager,
                  let container = text.textContainer else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += text.textContainerOrigin.x
            rect.origin.y += text.textContainerOrigin.y
            if viewport.intersects(text.convert(rect, to: nil)) { return true }
        }
        return false
    }

    /// Watches the thread frame by frame for the moment its text is gone: the visible part of the
    /// thread holding no answer at all, or scrolled past the end of what is there, or holding an
    /// answer that was never drawn. Reports how often each happened and what the first one looked
    /// like, so a scenario run beside it says whether the thread went blank and how.
    private func watchForBlankThread(_ obj: [String: Any]) {
        let seconds = (obj["seconds"] as? Double) ?? 10
        Task { @MainActor [weak self] in
            let started = Date()
            var samples = 0, empty = 0, beyond = 0, undrawn = 0, faded = 0, longest = 0, run = 0
            var first: String?
            while Date().timeIntervalSince(started) < seconds {
                guard let self else { return }
                samples += 1
                let look = self.lookAtViewport()
                if look.empty { empty += 1 }
                if look.beyond { beyond += 1 }
                if look.undrawn { undrawn += 1 }
                if look.faded { faded += 1 }
                let blank = look.empty || look.beyond || look.undrawn || look.faded
                run = blank ? run + 1 : 0
                longest = max(longest, run)
                if blank, first == nil {
                    first = String(format: "%.2f s: ", Date().timeIntervalSince(started)) + look.detail
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.note("blankwatch: \(samples) frames; no answer in view \(empty), past the end \(beyond), "
                       + "answer not drawn \(undrawn), every answer in view see-through \(faded); "
                       + "longest blank stretch \(longest) frames"
                       + (first.map { "\n  first: \($0)" } ?? "")
                       + "\n  now: " + (self?.lookAtViewport().detail ?? ""))
        }
    }

    private func lookAtViewport() -> (empty: Bool, beyond: Bool, undrawn: Bool, faded: Bool, detail: String) {
        guard let scroll = thread, let doc = scroll.documentView else {
            return (false, false, false, false, "no thread")
        }
        let visible = scroll.contentView.documentVisibleRect
        let height = doc.frame.height
        // The bars over the thread — Find and the work copy above, the composer below — are insets
        // the thread scrolls under, so the visible rect runs past the content by exactly them.
        let insets = scroll.contentView.contentInsets
        let low = doc.isFlipped ? insets.top : insets.bottom
        let high = doc.isFlipped ? insets.bottom : insets.top
        let beyond = visible.minY < -low - 2 || visible.maxY > height + high + 2
        let prose = views(ProseNSTextView.self, in: doc).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        let inView = prose.filter { visible.intersects(doc.convert($0.bounds, from: $0)) }
        // Drawn means the layer holds what the text view drew into it. A view that is in place
        // with no contents shows nothing, whatever its frame says.
        let undrawn = inView.filter { $0.layer != nil && $0.layer?.contents == nil && !$0.string.isEmpty }
        // How opaque each one really is on screen: its own alpha and its layers', all the way up to
        // the thread — what is on screen, so the presentation layer when one is animating. A row
        // left behind by a fade is in place, drawn, and invisible.
        // Walked by layer, not by view: SwiftUI fades a row on a layer of its own between the views.
        func opacity(_ view: NSView) -> CGFloat {
            var value: CGFloat = 1
            var v: NSView? = view
            while let current = v, current !== doc {
                value *= current.alphaValue
                v = current.superview
            }
            var l = view.layer
            while let layer = l, layer !== doc.layer {
                let shown = layer.presentation() ?? layer
                value *= CGFloat(shown.opacity)
                if shown.isHidden { value = 0 }
                l = layer.superlayer
            }
            return value
        }
        let seeThrough = inView.filter { opacity($0) < 0.05 }
        let detail = "content \(Int(height)) pt, visible \(Int(visible.minY))…\(Int(visible.maxY)) "
            + "(insets \(Int(insets.top))/\(Int(insets.bottom))), "
            + "\(prose.count) answer view(s) built, \(inView.count) in view, \(undrawn.count) of them undrawn, "
            + "\(seeThrough.count) see-through"
        // A thread longer than the window with no answer anywhere in view. Built or not does not
        // matter: the way it went blank was with nothing built at all around the place it stood.
        return (inView.isEmpty && height > visible.height, beyond, !undrawn.isEmpty,
                !inView.isEmpty && seeThrough.count == inView.count, detail)
    }

    /// The window behind every other one, or back in front — what happens to Bulava while he works
    /// in another app and comes back to it. {"do":"probe","probe":"order","to":"back"|"front"}
    private func orderWindow(_ obj: [String: Any]) {
        guard let window else { note("order: no window"); return }
        switch obj["to"] as? String {
        case "front": window.orderFrontRegardless()
        case "back": window.orderBack(nil)
        default: note("order: to front or back"); return
        }
        note("order \((obj["to"] as? String) ?? ""): occluded=\(!window.occlusionState.contains(.visible))")
    }

    /// A recording transcribed the way the composer does it, with the heartbeat running.
    private func transcribe(_ obj: [String: Any]) {
        guard let path = obj["path"] as? String else { note("transcribe: needs a path"); return }
        let language = (obj["language"] as? String) ?? "uk"
        let recorder = VoiceRecorder()
        let beat = Heartbeat()
        beat.start()
        let started = Date()
        Task { @MainActor [weak self] in
            let text = await recorder.transcribe(url: URL(fileURLWithPath: path), language: language)
            let worst = beat.stop()
            self?.note("transcribe: \(Int(Date().timeIntervalSince(started))) s, longest main-thread "
                       + "stall \(Int(worst * 1000)) ms, \(text?.count ?? 0) characters\n"
                       + "  \(text?.prefix(300) ?? "(nothing)")")
        }
    }

    /// A scroll by hand: the wheel events a trackpad sends, with their phases, delivered to the
    /// thread's own scroll view — the only way to tell it apart from the app scrolling itself.
    private func wheel(_ obj: [String: Any]) {
        guard let scroll = thread else { note("wheel: no thread"); return }
        let lines = Int32((obj["lines"] as? Int) ?? 40)
        let steps = 12
        Task { @MainActor [weak self] in
            for step in 0...(steps + 1) {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: step == 0 || step > steps ? 0 : lines * 10,
                                          wheel2: 0, wheel3: 0) else { continue }
                // 1 began, 2 changed, 4 ended — kCGScrollPhase*.
                event.setIntegerValueField(.scrollWheelEventScrollPhase,
                                           value: step == 0 ? 1 : (step > steps ? 4 : 2))
                if let ns = NSEvent(cgEvent: event) { scroll.scrollWheel(with: ns) }
                try? await Task.sleep(for: .milliseconds(16))
            }
            // The fling after the fingers lift, as a trackpad sends it: momentum begin, a few
            // shrinking steps, end.
            for (index, delta) in [Int32(60), 30, 12, 0].enumerated() {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: delta, wheel2: 0, wheel3: 0) else { continue }
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
                event.setIntegerValueField(.scrollWheelEventMomentumPhase,
                                           value: index == 0 ? 1 : (delta == 0 ? 3 : 2))
                if let ns = NSEvent(cgEvent: event) { scroll.scrollWheel(with: ns) }
                try? await Task.sleep(for: .milliseconds(16))
            }
            try? await Task.sleep(for: .milliseconds(300))
            self?.note("wheel: " + (self?.threadState() ?? ""))
        }
    }

    private func openChat(_ obj: [String: Any], _ model: AppModel) {
        guard let title = obj["title"] as? String,
              let chat = model.conversations.chats.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) else {
            note("chat: none titled like that"); return
        }
        model.open(product: chat.productID)
        model.conversations.open(chat.id, for: chat.productID)
        note("chat: opened “\(chat.title)” — \(model.visibleEntries(inChat: chat.id).count) messages")
    }

    private func productNamed(_ name: String?, _ model: AppModel) -> Product? {
        if let name, let hit = model.products.products.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            return hit
        }
        if let id = model.route.productID ?? model.selectedProductID { return model.products.product(id: id) }
        note("probe: no product"); return nil
    }

    private static let longDictation = (1...15).map {
        "Рядок \($0) надиктованого тексту, достатньо довгий, щоб переноситися на наступний рядок у полі."
    }.joined(separator: "\n")
}

/// How long the main thread went without running a timer that asks every 16 ms.
@MainActor
private final class Heartbeat {
    private var timer: Timer?
    private var last = Date()
    private var worst: TimeInterval = 0

    func start() {
        last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                self.worst = max(self.worst, now.timeIntervalSince(self.last))
                self.last = now
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() -> TimeInterval {
        timer?.invalidate(); timer = nil
        return worst
    }
}
