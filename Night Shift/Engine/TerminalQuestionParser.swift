import Foundation

nonisolated enum TerminalQuestionParser {
    static let reviewSubmitLabel = "Надіслати відповіді"
    static let reviewCancelLabel = "Повернутися до питань"

    private struct Option {
        var index: Int
        var label: String
        var description: [String]
    }

    /// The pane without the countdown Claude Code prints on a screen it will close by itself.
    ///
    /// In a session nobody seems to be at, its safety check asks and then answers itself:
    /// "⚠ Claude Code will automatically deny this request in 0:22, to avoid blocking progress on
    /// an unattended session". The number changes every second, so the screen read a second ago
    /// and the same screen now were two different questions, and every answer was refused as
    /// "Claude is already showing another question". On 6 Oct the director answered from the phone
    /// four times within the window; none reached Claude, the dialog denied itself, and the card
    /// kept showing "0:22" the whole time. Read without the number, it is one question for as long
    /// as it waits — and nothing on a card claims a time that stopped being true a second later.
    ///
    /// Only the number goes, and the line breaks around it stay: the phrase can wrap anywhere in a
    /// narrow pane, and the parser reads lines.
    static func steady(_ pane: String) -> String {
        pane.replacingOccurrences(
            of: #"(deny[\s│]+this[\s│]+request[\s│]+in[\s│]+)(?:\d{1,2}:\d{2}|\d+\s?s\b)"#,
            with: "$1a moment",
            options: [.regularExpression, .caseInsensitive])
    }

    static func parse(_ pane: String) -> PendingUserQuestion? {
        let lines = steady(pane).components(separatedBy: .newlines)
        let reviewIndex = lines.lastIndex(where: { $0.contains("Review your answers") })
        let footerIndex = lines.lastIndex(where: {
            $0.contains("Enter to select") && $0.contains("Arrow keys to navigate")
        })

        if let reviewIndex, footerIndex == nil || reviewIndex > footerIndex! {
            return parseReview(lines, startingAt: reviewIndex)
        }

        guard let footer = lines.lastIndex(where: {
            $0.contains("Enter to select") && $0.contains("Arrow keys to navigate")
        }),
        let closingRule = lines[..<footer].lastIndex(where: { $0.contains("────") }),
        let openingRule = lines[..<closingRule].lastIndex(where: { $0.contains("────") }) else {
            return parsePermission(lines) ?? parseAnyScreen(lines)
        }
        let formRange = lines.index(after: openingRule)..<closingRule
        guard let firstOption = lines[formRange].firstIndex(where: { optionLine($0) != nil }) else {
            return nil
        }

        let questionLines = lines[lines.index(after: openingRule)..<firstOption].compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,

                  !(trimmed.contains("☐") || trimmed.contains("☒") || trimmed.contains("✔")) else {
                return nil
            }
            let text = trimmed.hasPrefix("│")
                ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                : trimmed
            return text.isEmpty ? nil : text
        }
        let question = questionLines.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return nil }

        var options: [Option] = []
        var current: Option?
        var selectedIndex: Int?
        var customIndex: Int?

        func finish(_ option: Option?) {
            guard let option else { return }
            options.append(option)
        }

        for line in lines[firstOption..<closingRule] {
            if let parsed = optionLine(line) {
                finish(current)
                current = nil
                if parsed.selected { selectedIndex = parsed.index }
                let lower = parsed.label.lowercased()
                if lower == "type something." || lower == "type something" {
                    customIndex = parsed.index
                } else if !lower.contains("chat about this") {
                    current = Option(index: parsed.index, label: parsed.label, description: [])
                }
                continue
            }
            let detail = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty, current != nil { current!.description.append(detail) }
        }
        finish(current)

        let labels = options.map(\.label)
        let descriptions = Dictionary(uniqueKeysWithValues: options.compactMap { option in
            let text = option.description.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (option.label, text)
        })
        let indices = Dictionary(uniqueKeysWithValues: options.map { ($0.label, $0.index) })
        let item = PendingUserQuestion.Item(
            question: question, header: nil, options: labels, multiSelect: false,
            optionDescriptions: descriptions.isEmpty ? nil : descriptions)
        return PendingUserQuestion(
            questions: [item], askedAt: nil, reasonCode: nil, summary: question,
            recommendation: nil, defaultAction: nil, unblockAction: nil, toolUseID: nil,
            source: .terminal, terminalSelectedIndex: selectedIndex,
            terminalOptionIndices: indices, terminalCustomOptionIndex: customIndex)
    }

    private static func parseReview(_ lines: [String], startingAt reviewIndex: Int)
        -> PendingUserQuestion? {
        guard let readyIndex = lines[reviewIndex...].firstIndex(where: {
            $0.contains("Ready to submit your answers?")
        }) else { return nil }

        let parsedOptions = lines[lines.index(after: readyIndex)...].compactMap(optionLine)
        guard let submit = parsedOptions.first(where: { $0.label == "Submit answers" }),
              let cancel = parsedOptions.first(where: { $0.label == "Cancel" }),
              let selected = parsedOptions.first(where: \.selected)?.index else { return nil }

        let answers = lines[reviewIndex..<readyIndex].compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("→") else { return nil }
            return String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let summary = answers.isEmpty ? nil : answers.joined(separator: " • ")
        let descriptions = summary.map { [reviewSubmitLabel: $0] }
        let item = PendingUserQuestion.Item(
            question: "Підтвердити вибрані відповіді?", header: nil,
            options: [reviewSubmitLabel, reviewCancelLabel], multiSelect: false,
            optionDescriptions: descriptions)
        return PendingUserQuestion(
            questions: [item], askedAt: nil, reasonCode: nil,
            summary: "Підтвердити вибрані відповіді?", recommendation: nil,
            defaultAction: nil, unblockAction: nil, toolUseID: nil, source: .terminal,
            terminalSelectedIndex: selected,
            terminalOptionIndices: [reviewSubmitLabel: submit.index,
                                    reviewCancelLabel: cancel.index],
            terminalCustomOptionIndex: nil, terminalReview: true)
    }

    /// Claude Code's own permission dialog, as 2.1.289 draws it:
    ///
    ///     ──────────────────────────
    ///      Bash command
    ///      Create a test file at the specified path
    ///     ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
    ///      touch /tmp/permtest.txt
    ///     ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
    ///      Do you want to proceed?
    ///      ❯ 1. Yes
    ///        2. Yes, and always allow access to /tmp from this project
    ///        3. No
    ///      Esc to cancel · Tab to amend
    ///
    /// It waited in a pane nobody could see; read as a question, it is answered from the Mac or the
    /// phone the way any of Claude's forms is, by moving the selection and pressing Enter.
    private static func parsePermission(_ lines: [String]) -> PendingUserQuestion? {
        guard let footer = lines.lastIndex(where: { $0.contains("Esc to cancel") }),
              let ask = lines[..<footer].lastIndex(where: {
                  let t = $0.trimmingCharacters(in: .whitespaces)
                  return t.hasPrefix("Do you want") && t.hasSuffix("?")
              }) else { return nil }
        let parsed = lines[lines.index(after: ask)..<footer].compactMap(optionLine)
        guard parsed.count >= 2, parsed.first?.index == 1,
              let selected = parsed.first(where: \.selected)?.index else { return nil }

        let rule = lines[..<ask].lastIndex(where: { $0.contains("────") }) ?? lines.startIndex
        let body = lines[lines.index(after: rule)..<ask]
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // The title is the first line under the rule ("Bash command", "Edit file", a tool's name);
        // what it is about is set between the dashed rules when there is one.
        let title = body.first(where: { !$0.isEmpty && !$0.contains("╌") }) ?? ""
        var subject: [String] = []
        var inside = false
        for line in body {
            if line.contains("╌") { if inside { break }; inside = true; continue }
            if inside, !line.isEmpty { subject.append(line) }
        }
        let what = subject.joined(separator: " ")
        let summary = [title, what].filter { !$0.isEmpty }.joined(separator: " — ")
        let question = lines[ask].trimmingCharacters(in: .whitespaces)
        let labels = parsed.map(\.label)
        let item = PendingUserQuestion.Item(question: summary.isEmpty ? question : "\(summary)\n\(question)",
                                            header: nil, options: labels, multiSelect: false,
                                            optionDescriptions: nil)
        return PendingUserQuestion(
            questions: [item], askedAt: nil, reasonCode: nil, summary: summary.isEmpty ? question : summary,
            recommendation: nil, defaultAction: nil, unblockAction: nil, toolUseID: nil,
            source: .terminal, terminalSelectedIndex: selected,
            terminalOptionIndices: Dictionary(parsed.map { ($0.label, $0.index) }, uniquingKeysWith: { first, _ in first }),
            terminalCustomOptionIndex: nil)
    }

    // MARK: - Any other screen that waits on a key

    /// Every screen Claude Code stops on that is not one of the forms above.
    ///
    /// The forms above are read by their exact shape, and Claude Code grows new screens faster than
    /// shapes can be added: on 5 Oct a start sat on "Allow external CLAUDE.md file imports?" — two
    /// unnumbered choices, "Enter to confirm · Esc to cancel" — that nothing here knew, and the run
    /// was rolled back with the question on it. So this reads what every such screen has, not what
    /// one of them says: the key hints printed under it (the engine's `handshake_screen_asks` reads
    /// the same list), and above them either a list with a cursor on one line — numbered or not,
    /// `❯` or `›` or `>` — or nothing to choose from, in which case the answers are the keys the
    /// hints name. The text above becomes the question, word for word.
    static func parseAnyScreen(_ lines: [String]) -> PendingUserQuestion? {
        let inner = lines.map(inside)
        let filled = inner.indices.filter { !isBlankOrRule(inner[$0]) }
        guard let footer = filled.suffix(6).last(where: { hints(inner[$0]) }) else { return nil }
        if let list = optionList(inner, above: footer) {
            return question(text: questionText(inner, above: list.firstLine), options: list.options,
                            selected: list.selected)
        }
        return keysQuestion(inner, footer: footer)
    }

    /// The words a screen prints under itself when it waits on a key. "esc to interrupt" is a turn
    /// running, not a question, and is not among them.
    private static let hint = try! NSRegularExpression(
        pattern: #"(enter|return) to (confirm|select|continue|submit|accept|approve|choose|proceed)|esc to (cancel|exit|go back|close|dismiss|skip|reject|deny|decline)|press (enter|return)|arrow keys to|↑/↓ to|\((y/n|yes/no)\)|\[(y/n|y/N|Y/n)\]"#,
        options: [.caseInsensitive])
    private static let yesNo = try! NSRegularExpression(pattern: #"\((y/n|yes/no)\)|\[(y/n|y/N|Y/n)\]"#,
                                                        options: [.caseInsensitive])
    private static let enterTo = try! NSRegularExpression(
        pattern: #"\b(?:press\s+)?(?:enter|return)\b(?:\s+to\s+([a-z][a-z ]*?))?(?=\s*(?:[·•,;.…)]|$|\s{2,}))"#,
        options: [.caseInsensitive])
    private static let escTo = try! NSRegularExpression(
        pattern: #"\besc\s+to\s+([a-z][a-z ]*?)(?=\s*(?:[·•,;.…)]|$|\s{2,}))"#, options: [.caseInsensitive])
    private static let cursors: Set<Character> = ["❯", "›", "▶", "►", "→", ">"]
    private static let borders: Set<Character> = ["│", "┃", "║"]
    private static let ruleScalars = CharacterSet(charactersIn: "─━═╌┄┈╭╮╰╯├┤┌┐└┘│┃║ ")

    private static func hints(_ text: String) -> Bool {
        hint.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A line as the dialog draws it, without the box: the borders are not text, but the
    /// indentation inside them says which lines are the choices.
    static func inside(_ line: String) -> String {
        var text = line
        while text.last == " " { text.removeLast() }
        if let last = text.last, borders.contains(last) { text.removeLast() }
        while text.last == " " { text.removeLast() }
        if let first = text.firstIndex(where: { $0 != " " }), borders.contains(text[first]) {
            text = String(text[text.index(after: first)...])
        }
        return text
    }

    private static func isBlankOrRule(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { ruleScalars.contains($0) }
    }

    private static func isRule(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && isBlankOrRule(text)
    }

    private static func column(_ text: String) -> Int {
        text.prefix(while: { $0 == " " }).count
    }

    /// Where the cursor is drawn and where the words after it begin, if this line has the cursor.
    private static func cursorColumns(_ text: String) -> (glyph: Int, label: Int)? {
        let glyph = column(text)
        let chars = Array(text)
        guard glyph + 2 < chars.count, cursors.contains(chars[glyph]), chars[glyph + 1] == " " else {
            return nil
        }
        let label = glyph + 1 + chars[(glyph + 1)...].prefix(while: { $0 == " " }).count
        return label < chars.count ? (glyph, label) : nil
    }

    private static func numbered(_ text: String) -> (index: Int, label: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let stop = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }),
              let index = Int(trimmed[..<stop]) else { return nil }
        let label = trimmed[trimmed.index(after: stop)...].trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : (index, label)
    }

    private struct Listed { var index: Int; var label: String; var detail: [String] }

    /// The list the cursor is in: its lines are the ones lined up with the cursor's own words; a
    /// line indented further belongs to the choice above it.
    private static func optionList(_ inner: [String], above footer: Int)
        -> (options: [Listed], selected: Int, firstLine: Int)? {
        let floor = max(0, footer - 40)
        guard footer > floor,
              let cursorLine = stride(from: footer - 1, through: floor, by: -1)
                .first(where: { cursorColumns(inner[$0]) != nil }),
              let columns = cursorColumns(inner[cursorLine]) else { return nil }
        func belongs(_ text: String) -> Bool {
            guard !isBlankOrRule(text) else { return false }
            if cursorColumns(text)?.glyph == columns.glyph { return true }
            return column(text) >= columns.label
        }
        var first = cursorLine
        while first - 1 >= floor, belongs(inner[first - 1]) { first -= 1 }
        var last = cursorLine
        while last + 1 < footer, belongs(inner[last + 1]) { last += 1 }
        // Lines above the first choice that are indented like a description belong to nothing.
        while first < cursorLine, cursorColumns(inner[first]) == nil, column(inner[first]) != columns.label {
            first += 1
        }

        var options: [Listed] = []
        var selected = 1
        for row in first...last {
            let text = inner[row]
            let cursor = cursorColumns(text)
            let isChoice = cursor?.glyph == columns.glyph || column(text) == columns.label
            if isChoice {
                let start = text.index(text.startIndex, offsetBy: cursor?.label ?? columns.label)
                var label = String(text[start...]).trimmingCharacters(in: .whitespaces)
                var index = options.count + 1
                if let n = numbered(label) { index = n.index; label = n.label }
                // A checkbox drawn before the words is not part of them.
                label = label.trimmingCharacters(in: CharacterSet(charactersIn: "☐☒✔◯◉○● "))
                guard !label.isEmpty else { continue }
                if options.contains(where: { $0.label == label }) { label += " (\(index))" }
                if cursor != nil { selected = index }
                options.append(Listed(index: index, label: label, detail: []))
            } else if !options.isEmpty {
                options[options.count - 1].detail.append(text.trimmingCharacters(in: .whitespaces))
            }
        }
        guard options.count >= 2 else { return nil }
        return (options, selected, first)
    }

    /// What the screen says above its choices, as it says it: up to the box's top or a gap.
    private static func questionText(_ inner: [String], above row: Int) -> String {
        questionText(inner, above: row, fallback: String(localized: "Claude Code is asking on its own screen."))
            ?? ""
    }

    private static func questionText(_ inner: [String], above row: Int, fallback: String?) -> String? {
        var collected: [String] = []
        var cursor = row - 1
        while cursor >= 0, inner[cursor].trimmingCharacters(in: .whitespaces).isEmpty { cursor -= 1 }
        var gaps = 0
        while cursor >= 0, collected.count < 14 {
            let text = inner[cursor]
            if isRule(text) { break }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                gaps += 1
                if gaps >= 2 { break }
            } else {
                gaps = 0
                collected.append(trimmed)
            }
            cursor -= 1
        }
        let text = collected.reversed().joined(separator: "\n")
        return text.isEmpty ? fallback : text
    }

    private static func question(text: String, options: [Listed], selected: Int?,
                                 keys: [String: [String]] = [:]) -> PendingUserQuestion {
        let labels = options.map(\.label)
        let details = Dictionary(options.compactMap { option -> (String, String)? in
            let joined = option.detail.joined(separator: " ")
            return joined.isEmpty ? nil : (option.label, joined)
        }, uniquingKeysWith: { first, _ in first })
        let summary = text.components(separatedBy: "\n").first ?? text
        let item = PendingUserQuestion.Item(question: text, header: nil, options: labels,
                                            multiSelect: false,
                                            optionDescriptions: details.isEmpty ? nil : details)
        return PendingUserQuestion(
            questions: [item], askedAt: nil, reasonCode: nil, summary: summary,
            recommendation: nil, defaultAction: nil, unblockAction: nil, toolUseID: nil,
            source: .terminal, terminalSelectedIndex: selected,
            terminalOptionIndices: Dictionary(options.map { ($0.label, $0.index) },
                                              uniquingKeysWith: { first, _ in first }),
            terminalCustomOptionIndex: nil, terminalKeys: keys)
    }

    /// A screen with nothing to choose from: its answers are the keys its hints name — "Press Enter
    /// to continue", "Esc to cancel", "(y/n)". A yes or a no is typed; Enter follows only if the
    /// screen is still asking afterwards (`SupervisorClient.answerTerminalQuestion`), because a
    /// screen that takes the single key would hand that Enter to whatever comes next.
    private static func keysQuestion(_ inner: [String], footer: Int) -> PendingUserQuestion? {
        let text = inner[footer]
        let range = NSRange(text.startIndex..., in: text)
        var options: [Listed] = []
        var keys: [String: [String]] = [:]
        func add(_ label: String, _ sequence: [String]) {
            guard keys[label] == nil else { return }
            options.append(Listed(index: options.count + 1, label: label, detail: []))
            keys[label] = sequence
        }
        func words(_ match: NSTextCheckingResult, _ group: Int, otherwise: String) -> String {
            guard let r = Range(match.range(at: group), in: text) else { return otherwise }
            let said = text[r].trimmingCharacters(in: .whitespaces)
            return said.isEmpty ? otherwise : said.prefix(1).uppercased() + said.dropFirst()
        }
        if yesNo.firstMatch(in: text, range: range) != nil {
            add(String(localized: "Yes"), ["y", "Enter?"])
            add(String(localized: "No"), ["n", "Enter?"])
        }
        for match in enterTo.matches(in: text, range: range) {
            add("\(words(match, 1, otherwise: String(localized: "Continue"))) (Enter)", ["Enter"])
        }
        for match in escTo.matches(in: text, range: range) {
            add("\(words(match, 1, otherwise: String(localized: "Cancel"))) (Esc)", ["Escape"])
        }
        guard !options.isEmpty else { return nil }
        // A yes/no is usually its own question ("Overwrite the hooks? (y/n)"), and then the line
        // itself is what is being asked.
        var asked = questionText(inner, above: footer, fallback: nil)
        if yesNo.firstMatch(in: text, range: range) != nil {
            let line = text.trimmingCharacters(in: .whitespaces)
            asked = [asked, line].compactMap { $0 }.joined(separator: "\n")
        }
        return question(text: asked ?? String(localized: "Claude Code is asking on its own screen."),
                        options: options, selected: nil, keys: keys)
    }

    private static func optionLine(_ line: String) -> (index: Int, label: String, selected: Bool)? {
        var text = line.trimmingCharacters(in: .whitespaces)
        let selected = text.hasPrefix("❯")
        if selected { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard let dot = text.firstIndex(of: "."),
              let index = Int(text[..<dot]) else { return nil }
        let label = String(text[text.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (index, label, selected)
    }
}
