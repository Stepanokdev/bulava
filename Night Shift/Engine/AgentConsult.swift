import Foundation

/// When the worker asks another agent something, and what it asked.
///
/// Claude consults Codex by running it: a `Bash` call whose command is `codex exec …`. Both halves
/// of that conversation used to disappear. The tool call collapsed into "runs codex exec …" in the
/// step trace, and the tool RESULT — Codex's actual answer — was thrown away outright, because the
/// stream only kept a tool result's content when it was an error. So the thread showed Claude's
/// summary of a review and never the review, and there was no way to tell whether the summary was
/// fair.
///
/// This recognises the call. The reducer keeps the answer for the calls it recognises and for no
/// others: an ordinary `ls` still costs nothing, because nobody wants its output in the thread.
nonisolated struct AgentConsult: Equatable, Sendable {

    /// Who was asked, as a person would say it.
    var agent: String

    /// The question, when the command carries one plainly enough to show.
    var ask: String

    /// The most an answer is kept at. A review runs to a couple of pages; a command that dumps a
    /// log is not a consultation and would not get here, but a cap keeps one pathological answer
    /// from being written into the conversation store forever.
    static let answerLimit = 24_000

    /// Recognise a consultation in a tool call, or return nil.
    ///
    /// Deliberately narrow, in both directions. `codex` has to be the command being RUN — the
    /// first word of a command, not an argument to `grep`, not a path being `cat`-ed, not the name
    /// of a script — because a false positive pastes somebody's shell output into the middle of
    /// the conversation as if an agent had said it. A missed consultation only costs a card.
    static func recognise(tool: String, input: [String: Any]) -> AgentConsult? {
        guard tool == "Bash" || tool == "BashOutput" else { return nil }
        let command = (input["command"] as? String) ?? ""
        guard !command.isEmpty, let ask = codexInvocation(in: command) else { return nil }
        return AgentConsult(agent: "Codex", ask: ask)
    }

    /// The question `codex` was called with, `""` when it was invoked but the question cannot be
    /// read off the command line, and nil when it was not invoked at all.
    ///
    /// A question is never guessed: a wrong question above a right answer is worse than no
    /// question, so only a token that actually reads as prose — one with a space in it — is shown.
    /// That is also what keeps `-c model_reasoning_effort="low"` and a redirected
    /// `< /tmp/prompt.txt` from being mistaken for one.
    static func codexInvocation(in command: String) -> String? {
        var atCommandPosition = true
        var inWrapperPrefix = false
        var skipWrapperArgument = false
        var sawCodex = false
        // Asking it something is `codex exec …` (or `exec resume` / `review`). `codex --help` and
        // `codex --version` run the same binary and answer nobody: their output is the CLI's own
        // usage text, and it used to be shown in the thread as Codex's reply to a question that
        // was never asked.
        var sawSubcommand = false
        var sawSelfDescribingFlag = false
        var ask: String?

        for token in tokens(of: command) {
            if token == .separator {
                if sawCodex { break }   // the pipeline moved on; whatever follows is not the ask
                atCommandPosition = true
                inWrapperPrefix = false
                skipWrapperArgument = false
                continue
            }
            guard case .word(let word, let quoted) = token else { continue }

            if !sawCodex {
                guard atCommandPosition else { continue }
                // Wrappers stand in front of the command they run, and bring their own
                // arguments with them: `timeout 180 codex`, `env -u OPENAI_API_KEY codex`.
                if Self.wrappers.contains(word) { inWrapperPrefix = true; continue }
                if word.contains("=") && !word.hasPrefix("-") { continue }
                if inWrapperPrefix, skipWrapperArgument { skipWrapperArgument = false; continue }
                if inWrapperPrefix, word.hasPrefix("-") {
                    // A wrapper's flag may take a value: `env -u OPENAI_API_KEY`, `timeout -k 5`.
                    skipWrapperArgument = true
                    continue
                }
                if inWrapperPrefix, word.allSatisfy(\.isNumber) { continue }

                if (word as NSString).lastPathComponent == "codex" {
                    sawCodex = true
                } else {
                    // Some other command runs here. `codex` further along this command is an
                    // argument to it, not an invocation.
                    atCommandPosition = false
                    inWrapperPrefix = false
                }
                continue
            }

            if word == "exec" || word == "resume" || word == "review" { sawSubcommand = true; continue }
            if word == "--help" || word == "-h" || word == "--version" || word == "-V" {
                sawSelfDescribingFlag = true
                continue
            }
            if word.hasPrefix("-") { continue }
            // Prose, not a flag value, a thread id or a path.
            guard word.contains(" "), quoted || word.count > 12 else { continue }
            // Remembered, not returned. `codex exec 'review this' --help` prints the manual, and
            // returning here on the prose would never have reached the flag that says so.
            if ask == nil { ask = String(word.prefix(280)) }
        }
        guard sawCodex, sawSubcommand, !sawSelfDescribingFlag else { return nil }
        return ask ?? ""
    }

    /// Words that stand in front of the command they run.
    private static let wrappers: Set<String> = [
        "env", "nohup", "command", "timeout", "gtimeout", "time", "exec", "sudo", "nice",
    ]

    private enum Token: Equatable {
        case word(String, quoted: Bool)
        case separator
    }

    /// Shell-ish tokenisation: enough to see quoting and where one command ends, not a shell.
    private static func tokens(of command: String) -> [Token] {
        var out: [Token] = []
        var current = ""
        var quotedCurrent = false
        var quote: Character?

        func flush() {
            if !current.isEmpty { out.append(.word(current, quoted: quotedCurrent)) }
            current = ""
            quotedCurrent = false
        }
        func separate() {
            flush()
            if out.last != .separator { out.append(.separator) }
        }

        for character in command {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                quotedCurrent = true
            case " ", "\t":
                flush()
            case "\n", "|", ";", "&", "(", ")", "<", ">", "`":
                separate()
            default:
                current.append(character)
            }
        }
        flush()
        return out
    }
}

/// What came back from a consultation, which is not always an answer.
///
/// The thread showed four things as "Codex answered" that Codex never said: its own `--help` text,
/// a CLI error about an unknown flag, and twice the harness's note that a command had been put in
/// the background. Every one of them was simply the tool result of a command with `codex` in it,
/// pasted under Codex's name — so a reader saw a page of usage text where a review should have
/// been, and had no way to tell the difference.
nonisolated enum AgentAnswer: Equatable, Sendable {
    /// Codex spoke, and this is what it said.
    case answered(String)
    /// The call did not reach Codex. The text is short and says why, in the reader's terms.
    case failed(String)
    /// The command was backgrounded: the answer is not in this result and will not arrive here.
    case startedInBackground

    static func classify(output: String?, isError: Bool) -> AgentAnswer {
        let text = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let head = String(text.prefix(400)).lowercased()

        if head.hasPrefix("command running in background with id") {
            return .startedInBackground
        }
        // The CLI failing to parse its own command line — its SHAPE, not its words. A review is
        // perfectly entitled to discuss an unexpected argument, and one that did would have been
        // thrown away as a failure by a rule that only looked for the phrase.
        if head.hasPrefix("error:")
            || head.contains("usage: codex")
            || (head.contains("unexpected argument") && head.contains("for more information, try")) {
            return .failed(firstMeaningfulLine(text))
        }
        // Its manual. `codex --help` no longer reaches here, but a wrapper script can still print
        // this on a bad invocation.
        if head.contains("run codex non-interactively") || head.contains("commands:") && head.contains("options:") {
            return .failed(String(localized: "Codex printed its usage instead of an answer."))
        }
        if isError { return .failed(firstMeaningfulLine(text)) }
        if text.isEmpty { return .failed(String(localized: "It answered with nothing.")) }
        return .answered(text)
    }

    private static func firstMeaningfulLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let trimmed = (line.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return String(localized: "The call to Codex failed.") }
        return String(trimmed.prefix(200))
    }
}
