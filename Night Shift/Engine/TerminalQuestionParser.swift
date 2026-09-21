import Foundation

nonisolated enum TerminalQuestionParser {
    static let reviewSubmitLabel = "Надіслати відповіді"
    static let reviewCancelLabel = "Повернутися до питань"

    private struct Option {
        var index: Int
        var label: String
        var description: [String]
    }

    static func parse(_ pane: String) -> PendingUserQuestion? {
        let lines = pane.components(separatedBy: .newlines)
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
            return nil
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
