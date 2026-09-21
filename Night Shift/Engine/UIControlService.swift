import Foundation
import AppKit
import ApplicationServices

/// Driving another app's interface ON BEHALF OF a worker.
///
/// This is the second half of a thing Bulava already does for screenshots, and it exists for the
/// same reason. macOS grants Accessibility to the code identity of the process it sees. A worker
/// runs under a tmux daemon that holds no grant and whose identity changes with every rebuild, so
/// "let the worker drive the app" means granting Accessibility to `node`, or to a terminal, or to
/// whatever launched it — which hands those rights to everything else that runs through the same
/// binary. Every serious tool on this platform arrives at the same answer: route the privileged
/// action through ONE signed helper with a stable bundle identifier. Bulava is that helper.
///
/// So the worker never touches the Accessibility API. It writes a request; Bulava performs it and
/// writes back what happened. One grant, given once to Bulava, covers every project and every
/// night — which is exactly what was asked for.
///
/// The protocol is deliberately the same shape as `CaptureService`: a JSON file per request in a
/// watched directory, a `.done` file with the answer, and a `service.json` saying Bulava is alive.
/// Anything that can write a file can drive a UI, and nothing needs a socket or a daemon.
@MainActor
final class UIControlService {

    private let dir: URL
    private let service: URL
    private let journal: URL
    private var timer: Task<Void, Never>?
    private var inFlight: Set<String> = []

    /// Whether requests are served at all. Off means every request is answered with a refusal
    /// rather than ignored — a worker waiting on silence is worse than a worker told no.
    var enabled = true

    init(stateDir: URL) {
        dir = stateDir.appendingPathComponent("ui-requests", isDirectory: true)
        service = dir.appendingPathComponent("service.json")
        journal = stateDir.appendingPathComponent("ui-actions.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func start() {
        announce()
        timer = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                self?.drain()
                ticks += 1
                if ticks % 16 == 0 { self?.announce() }
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        try? FileManager.default.removeItem(at: service)
    }

    func announce() {
        let payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "since": Int(Date().timeIntervalSince1970),
            "trusted": AXIsProcessTrusted(),
            "enabled": enabled,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: service)
        }
    }

    // MARK: - Serving

    private func drain() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") && name != "service.json" {
            let id = String(name.dropLast(5))
            guard !inFlight.contains(id) else { continue }
            let done = dir.appendingPathComponent("\(id).done")
            guard !FileManager.default.fileExists(atPath: done.path) else { continue }
            inFlight.insert(id)
            serve(request: dir.appendingPathComponent(name), done: done)
            inFlight.remove(id)
        }
    }

    private func serve(request: URL, done: URL) {
        guard let data = try? Data(contentsOf: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = obj["action"] as? String else {
            answer(done, .failure("request is not readable"))
            return
        }
        guard enabled else {
            answer(done, .failure("UI control is switched off in Bulava's settings"))
            return
        }
        let outcome = perform(action: action, request: obj)
        record(action: action, request: obj, outcome: outcome)
        answer(done, outcome)
    }

    enum Outcome {
        case ok(String)
        case failure(String)

        var isOK: Bool { if case .ok = self { return true }; return false }
        var text: String {
            switch self {
            case .ok(let s), .failure(let s): return s
            }
        }
    }

    private func answer(_ done: URL, _ outcome: Outcome) {
        var payload: [String: Any] = ["ok": outcome.isOK]
        if outcome.isOK { payload["result"] = outcome.text } else { payload["error"] = outcome.text }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: done)
        }
    }

    /// Every action, appended, whether it worked or not.
    ///
    /// A permission to control the machine that leaves no trace is not one anybody should give.
    /// This is the record he can read afterwards to see what was actually done in his name.
    private func record(action: String, request: [String: Any], outcome: Outcome) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let target = (request["pid"] as? NSNumber)?.intValue
        let name = target.flatMap { NSRunningApplication(processIdentifier: pid_t($0))?.localizedName } ?? "-"
        let detail = [request["ref"] as? String, request["text"] as? String,
                      request["keys"] as? String, request["path"] as? String]
            .compactMap { $0 }.joined(separator: " ")
        let line = "\(stamp)\t\(action)\t\(name)(\(target.map(String.init) ?? "-"))"
            + "\t\(detail)\t\(outcome.isOK ? "ok" : "refused: " + outcome.text)\n"
        if let handle = try? FileHandle(forWritingTo: journal) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: journal)
        }
    }

    // MARK: - Doing it

    private func perform(action: String, request: [String: Any]) -> Outcome {
        if action == "apps" { return .ok(UIControl.runningApps()) }
        if action == "status" {
            return .ok(AXIsProcessTrusted()
                       ? "Bulava may drive other apps."
                       : "Bulava is NOT trusted for Accessibility yet.")
        }

        guard AXIsProcessTrusted() else {
            return .failure("Bulava is not trusted for Accessibility. System Settings → Privacy & "
                            + "Security → Accessibility → add Bulava. One grant covers every "
                            + "project, and it survives rebuilds because Bulava is signed.")
        }
        guard let pid = (request["pid"] as? NSNumber)?.int32Value, pid > 0 else {
            return .failure("this action needs a target pid")
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return .failure("no running app with pid \(pid)")
        }
        if let refusal = UIControl.refusalForTarget(app) { return .failure(refusal) }

        let root = AXUIElementCreateApplication(pid)
        switch action {
        case "tree":
            let depth = (request["depth"] as? NSNumber)?.intValue ?? 12
            return UIControl.tree(of: root, depth: depth)
        case "click":
            return UIControl.click(root: root, app: app, ref: request["ref"] as? String,
                                   at: request["at"] as? String)
        case "type":
            guard let text = request["text"] as? String, !text.isEmpty else {
                return .failure("nothing to type")
            }
            return UIControl.type(root: root, app: app, ref: request["ref"] as? String, text: text)
        case "key":
            guard let keys = request["keys"] as? String, !keys.isEmpty else {
                return .failure("no key named")
            }
            return UIControl.key(app: app, keys: keys)
        case "menu":
            guard let path = request["path"] as? String, !path.isEmpty else {
                return .failure("no menu path named")
            }
            return UIControl.menu(root: root, app: app, path: path)
        default:
            return .failure("unknown action: \(action)")
        }
    }
}

// MARK: - The Accessibility work, kept testable where it can be

nonisolated enum UIControl {

    /// Targets Bulava will not drive, whatever it is asked.
    ///
    /// Not security theatre and not a complete defence — macOS itself refuses synthetic events on
    /// its own consent dialogs. It is a line about intent: these are the windows where a click
    /// grants a permission, reveals a secret or runs a command, and a worker has no business
    /// clicking in them even by accident. Matched on bundle identifier, because a window title is
    /// whatever the app feels like saying.
    static let neverDrive: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.SystemPreferences",
        "com.apple.keychainaccess",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.Console",
        "com.apple.ScriptEditor2",
        "com.apple.SecurityAgent",
        "com.apple.TCC",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    static func refusalForTarget(_ app: NSRunningApplication) -> String? {
        guard let bundle = app.bundleIdentifier else { return nil }
        guard neverDrive.contains(bundle) else { return nil }
        return "Bulava will not drive \(app.localizedName ?? bundle): a click there grants a "
            + "permission, shows a secret or runs a command. Do that one yourself."
    }

    static func isRefused(bundleIdentifier: String) -> Bool {
        neverDrive.contains(bundleIdentifier)
    }

    // MARK: Reading

    static func runningApps() -> String {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        var lines = ["pid\tname\tbundle\tdrivable"]
        for app in apps {
            let bundle = app.bundleIdentifier ?? "-"
            let drivable = isRefused(bundleIdentifier: bundle) ? "refused" : "yes"
            lines.append("\(app.processIdentifier)\t\(app.localizedName ?? "-")\t\(bundle)\t\(drivable)")
        }
        return lines.joined(separator: "\n")
    }

    /// The window tree, as indented lines each carrying a ref that `click` and `type` accept.
    ///
    /// A ref is a PATH — `w0.c4.c1` — not a promise: it means "window 0, child 4, child 1" and it
    /// is resolved again at the moment of the click. If the layout moved in between, resolving
    /// fails loudly instead of clicking whatever now sits at those coordinates.
    static func tree(of root: AXUIElement, depth: Int) -> UIControlService.Outcome {
        guard let windows = copy(root, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            return .failure("that app has no accessible window right now")
        }
        var lines: [String] = []
        for (index, window) in windows.enumerated() {
            lines.append("w\(index)\t[window] \(string(window, kAXTitleAttribute) ?? "untitled")")
            describe(window, ref: "w\(index)", depth: depth, indent: 1, into: &lines)
        }
        // A whole window is thousands of nodes on a real app; a worker reading it needs the shape,
        // not every leaf of a text run.
        let cap = 600
        if lines.count > cap {
            lines = Array(lines.prefix(cap))
            lines.append("… (\(cap) rows shown; ask for a smaller --depth or a specific window)")
        }
        return .ok(lines.joined(separator: "\n"))
    }

    private static func describe(_ element: AXUIElement, ref: String, depth: Int,
                                 indent: Int, into lines: inout [String]) {
        guard depth > 0 else { return }
        guard let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for (index, child) in children.enumerated() {
            let childRef = "\(ref).c\(index)"
            let role = string(child, kAXRoleAttribute) ?? "?"
            let label = [string(child, kAXTitleAttribute),
                         string(child, kAXDescriptionAttribute),
                         string(child, kAXValueAttribute).map { String($0.prefix(60)) },
                         string(child, kAXIdentifierAttribute).map { "#\($0)" }]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            let pad = String(repeating: "  ", count: indent)
            lines.append("\(childRef)\t\(pad)[\(role)] \(label)")
            describe(child, ref: childRef, depth: depth - 1, indent: indent + 1, into: &lines)
        }
    }

    // MARK: Acting

    static func click(root: AXUIElement, app: NSRunningApplication,
                      ref: String?, at point: String?) -> UIControlService.Outcome {
        if let ref, !ref.isEmpty {
            guard let element = resolve(root: root, ref: ref) else {
                return .failure("no element at \(ref) — read the tree again, the layout has moved")
            }
            app.activate()
            let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if error == .success { return .ok("pressed \(ref)") }
            // Not everything answers to press; a real click at its centre is the honest fallback.
            guard let frame = frame(of: element) else {
                return .failure("\(ref) does not respond to a press and has no position")
            }
            return clickScreen(at: CGPoint(x: frame.midX, y: frame.midY), what: ref)
        }
        guard let point, let spot = Self.point(from: point) else {
            return .failure("click needs either a ref from the tree or --at x,y")
        }
        app.activate()
        return clickScreen(at: spot, what: "\(Int(spot.x)),\(Int(spot.y))")
    }

    private static func clickScreen(at point: CGPoint, what: String) -> UIControlService.Outcome {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            return .failure("could not synthesise a click")
        }
        down.post(tap: .cghidEventTap)
        usleep(60_000)
        up.post(tap: .cghidEventTap)
        return .ok("clicked \(what)")
    }

    static func type(root: AXUIElement, app: NSRunningApplication,
                     ref: String?, text: String) -> UIControlService.Outcome {
        if let ref, !ref.isEmpty {
            guard let element = resolve(root: root, ref: ref) else {
                return .failure("no element at \(ref) — read the tree again")
            }
            app.activate()
            // Setting the value is exact where it works: no keyboard layout, no dropped
            // characters, no autocorrect. Typing is the fallback for things that refuse it.
            let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString,
                                                    text as CFTypeRef)
            if error == .success { return .ok("set the value of \(ref)") }
        } else {
            app.activate()
        }
        usleep(120_000)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            return .failure("could not synthesise typing")
        }
        // One event carrying the whole string: keeps multi-byte characters intact, which matters
        // for the language he actually writes in.
        var utf16 = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        event.post(tap: .cghidEventTap)
        if let release = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            release.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            release.post(tap: .cghidEventTap)
        }
        return .ok("typed \(text.count) characters")
    }

    static func key(app: NSRunningApplication, keys: String) -> UIControlService.Outcome {
        guard let stroke = Keystroke(keys) else {
            return .failure("don't know the key “\(keys)”. Try: return, escape, tab, space, "
                            + "delete, up, down, left, right, or cmd+s / cmd+shift+k")
        }
        app.activate()
        usleep(120_000)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: false)
        else { return .failure("could not synthesise the keystroke") }
        down.flags = stroke.flags
        up.flags = stroke.flags
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
        return .ok("pressed \(keys)")
    }

    /// A menu item by its path: `File/Save`, or `Bulava/Settings…`.
    static func menu(root: AXUIElement, app: NSRunningApplication,
                     path: String) -> UIControlService.Outcome {
        guard let barValue = copy(root, kAXMenuBarAttribute),
              CFGetTypeID(barValue) == AXUIElementGetTypeID() else {
            return .failure("that app has no menu bar")
        }
        let bar = unsafeDowncast(barValue, to: AXUIElement.self)
        let wanted = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return .failure("menu path is empty") }

        var element = bar
        for (step, name) in wanted.enumerated() {
            guard let found = child(of: element, titled: name) else {
                let available = (copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                    .compactMap { string($0, kAXTitleAttribute) }
                    .filter { !$0.isEmpty }
                return .failure("no menu item “\(name)” at step \(step + 1) of \(path). "
                                + "There: \(available.prefix(20).joined(separator: ", "))")
            }
            element = found
            // A menu title's own submenu is the thing that holds the items.
            if step < wanted.count - 1,
               let submenu = (copy(element, kAXChildrenAttribute) as? [AXUIElement])?.first {
                element = submenu
            }
        }
        app.activate()
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return error == .success ? .ok("chose \(path)")
                                 : .failure("\(path) refused to be pressed")
    }

    private static func child(of element: AXUIElement, titled name: String) -> AXUIElement? {
        guard let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        // Exact first, then a forgiving match — menu titles carry ellipses and trailing spaces.
        if let exact = children.first(where: { string($0, kAXTitleAttribute) == name }) { return exact }
        let folded = name.replacingOccurrences(of: "…", with: "").lowercased()
        return children.first {
            guard let title = string($0, kAXTitleAttribute) else { return false }
            return title.replacingOccurrences(of: "…", with: "").lowercased() == folded
        }
    }

    // MARK: Refs

    /// `w0.c4.c1` → the element at that path, or nil when the layout no longer has it.
    static func resolve(root: AXUIElement, ref: String) -> AXUIElement? {
        guard isWellFormed(ref: ref) else { return nil }
        let steps = ref.split(separator: ".").map(String.init)
        guard let first = steps.first, first.hasPrefix("w"),
              let windowIndex = Int(first.dropFirst()),
              let windows = copy(root, kAXWindowsAttribute) as? [AXUIElement],
              windows.indices.contains(windowIndex) else { return nil }

        var element = windows[windowIndex]
        for step in steps.dropFirst() {
            guard step.hasPrefix("c"), let index = Int(step.dropFirst()),
                  let children = copy(element, kAXChildrenAttribute) as? [AXUIElement],
                  children.indices.contains(index) else { return nil }
            element = children[index]
        }
        return element
    }

    /// Whether a ref is even shaped like one, so a typo is refused before anything is clicked.
    ///
    /// Strict about two things a lenient split would wave through: an empty component, because
    /// `"w0.c1."` splits to the same pieces as `"w0.c1"` and is not the same text; and a negative
    /// index, because `Int("-1")` parses perfectly and is not a child position.
    static func isWellFormed(ref: String) -> Bool {
        let steps = ref.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let first = steps.first, first.hasPrefix("w"),
              let window = Int(first.dropFirst()), window >= 0 else { return false }
        return steps.dropFirst().allSatisfy { step in
            guard step.hasPrefix("c"), let index = Int(step.dropFirst()) else { return false }
            return index >= 0
        }
    }

    static func point(from text: String) -> CGPoint? {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
        return CGPoint(x: x, y: y)
    }

    // MARK: AX plumbing

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute) else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copy(element, kAXPositionAttribute),
              let sizeValue = copy(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

// MARK: - Keys

/// A key name a person would type, turned into what CoreGraphics wants.
nonisolated struct Keystroke: Equatable, Sendable {
    var code: CGKeyCode
    var flags: CGEventFlags

    static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "comma": 43, "period": 47, "slash": 44,
        // Punctuation, by symbol AND by name. `cmd+[` is Back in this app and half the others on
        // the platform, and it was simply missing — found by trying to use it. The names matter
        // because the parser splits on `+` and `-`, so a literal `cmd+-` cannot be written: it is
        // `cmd+minus`.
        "[": 33, "leftbracket": 33, "]": 30, "rightbracket": 30,
        "minus": 27, "equal": 24, "semicolon": 41, "quote": 39,
        "backslash": 42, "grave": 50, "backtick": 50,
    ]

    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "ctrl": .maskControl,
        "control": .maskControl, "alt": .maskAlternate, "opt": .maskAlternate,
        "option": .maskAlternate, "shift": .maskShift, "fn": .maskSecondaryFn,
    ]

    init?(_ text: String) {
        let parts = text.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = parts.last, let code = Self.named[last] else { return nil }
        var flags = CGEventFlags()
        for part in parts.dropLast() {
            guard let modifier = Self.modifiers[part] else { return nil }
            flags.insert(modifier)
        }
        self.code = code
        self.flags = flags
    }
}
