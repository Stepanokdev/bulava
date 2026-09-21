import Foundation

/// Taking a message back before the agent has read it.
///
/// He sends something, notices he left half of it out, and wants it back to edit — the way Escape
/// works in Claude Code and in Codex. Whether that is possible at all depends on where the message
/// currently is, and this type exists so the app never blurs the two:
///
///   * still in the undelivered queue → it genuinely can be un-sent. Its line comes out of
///     `undelivered.jsonl` and nothing the agent ever sees will contain it.
///   * already handed to the agent    → it cannot. The session has read it. Deleting it from the
///     app would only make the app lie about what the conversation contains, and the next answer
///     would be an answer to a message that is no longer on screen.
///
/// The second case is not a failure — it is the normal one, and it has its own honest handling:
/// stop the turn, hand the text back for editing, and let the new message say plainly that it
/// replaces the last one.
nonisolated enum MessageWithdrawal {

    enum Outcome: Equatable, Sendable {
        /// Removed from the queue. The agent never saw it.
        case withdrawn
        /// The agent already has it. Nothing was changed on disk.
        case alreadyRead
        /// The queue could not be read or written, so nothing is known and nothing was touched.
        case unknown(String)
    }

    /// Remove one message from a queue file, leaving everything else — including lines that are
    /// not JSON — exactly as it was.
    ///
    /// Returns nil when the file does not name this message at all, so a caller can tell "took it
    /// out" from "it was never here" without comparing counts itself.
    static func removing(_ id: UUID, from text: String) -> String? {
        let wanted = id.uuidString.lowercased()
        var kept: [String] = []
        var removed = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if !removed,
               let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let carried = object["id"] as? String,
               carried.lowercased() == wanted {
                // Only the first match: the same id twice would be a bug elsewhere, and removing
                // both would hide it.
                removed = true
                continue
            }
            kept.append(raw)
        }
        guard removed else { return nil }
        return kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
    }

    /// What a new message says when it replaces one the agent has already read.
    ///
    /// The agent cannot un-read the first message, so the replacement has to be explicit rather
    /// than hopeful. Both CLIs document handling exactly this: a new message that supersedes the
    /// request they are working on.
    static func supersedingPreamble() -> String {
        String(localized: "Ignore my previous message — I sent it before I had finished. This replaces it:")
    }
}

extension SupervisorClient {

    /// Try to take a queued message back out of the engine's undelivered queue.
    ///
    /// The app already reads this file to show "Queued up" against a message, so it is not
    /// reaching into somebody else's state — it is the same file, one write instead of one read.
    func withdrawQueuedMessage(id: UUID, projectPath: String) async -> MessageWithdrawal.Outcome {
        // The engine answers first, because only it can see all three places a message can be:
        // waiting to be prepared, being prepared this second, or composed and parked for a retry.
        // Rewriting the retry queue from here could only ever see the third, so a message caught
        // mid-preparation came back as "already read" — the one answer that was certainly false.
        if let home = OrchestratorHome.detect()?.path {
            let script = "\(home)/bin/worker-withdraw.sh"
            if FileManager.default.fileExists(atPath: script) {
                let r = await Shell.run("bash \"$1\" \"$2\" \"$3\" 2>/dev/null",
                                        args: [script, projectPath, id.uuidString], timeout: 20)
                if r.exitCode == 0 {
                    return r.stdout.contains("withdrawn") ? .withdrawn : .alreadyRead
                }
            }
        }

        let slug = Slug.forPath(projectPath)
        let candidates = [
            paths.undeliveredDir(slug: slug).appendingPathComponent("undelivered.jsonl"),
            paths.stateDir.appendingPathComponent("instances/\(slug)/undelivered.jsonl"),
        ]

        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let rewritten = MessageWithdrawal.removing(id, from: text) else { continue }
            do {
                if rewritten.isEmpty {
                    try FileManager.default.removeItem(at: url)
                } else {
                    try rewritten.write(to: url, atomically: true, encoding: .utf8)
                }
                return .withdrawn
            } catch {
                return .unknown(error.localizedDescription)
            }
        }
        // No file, or no file naming this message: either way the agent has it, and there is
        // nothing to take back.
        return .alreadyRead
    }
}
