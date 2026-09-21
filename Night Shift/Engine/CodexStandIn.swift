import Foundation

/// When Codex has no quota left, Claude takes its place.
///
/// The weekly window is the one that actually runs out — as this was written it stood at 91% used
/// with four days to go, and the five-hour window at 3%. A conversation that reaches that wall
/// does not fail loudly: `codex exec` comes back having said nothing useful, and the reply is an
/// error where an answer should be. Nothing about that is worth a person's evening.
///
/// So the app watches for both shapes of "out": the quota reported before a turn is sent, and the
/// refusal that comes back from a turn that was sent anyway. Either way the message is answered by
/// Claude, and the thread says which one answered — a substitution nobody was told about is worse
/// than the wall.
nonisolated enum CodexStandIn: Equatable, Sendable {

    /// The share of the weekly window above which Claude answers instead.
    ///
    /// It was 97, on the reasoning that the last few per cent should be saved for a review at the
    /// end of a night. Holding a reserve turned out to cost more than it saved — quota that was
    /// paid for went unused while a capability was switched off — so it is the full window now, and
    /// what stands Codex down is Codex refusing a turn rather than this number predicting it.
    static let weeklyCeiling: Double = 100

    /// Why Claude answered instead.
    enum Reason: Equatable, Sendable {
        /// The quota said so before anything was sent.
        case weeklyQuotaSpent(percent: Double, resetsAt: Date?)
        /// A turn was sent and Codex refused it.
        case refusedMidTurn(String)

        var sentence: String {
            switch self {
            case .weeklyQuotaSpent(let percent, let resetsAt):
                let used = String(format: "%.0f", min(max(percent, 0), 100))
                if let resetsAt {
                    let clock = DateFormatter()
                    clock.dateFormat = "d MMM, HH:mm"
                    return String(format: String(localized: "Codex has used %@%% of its week and resets %@ — Claude answered this one."),
                                  used, clock.string(from: resetsAt))
                }
                return String(format: String(localized: "Codex has used %@%% of its week — Claude answered this one."),
                              used)
            case .refusedMidTurn:
                return String(localized: "Codex refused the turn — out of quota. Claude answered this one.")
            }
        }

        /// The wall on its own, with nothing claimed about what happened next.
        ///
        /// `sentence` ends in "Claude answered this one", which was true while the app answered by
        /// itself and is a lie now that it asks first. The two readings need different words: one
        /// reports a substitution that happened, this one reports a question still open.
        var wall: String {
            switch self {
            case .weeklyQuotaSpent(let percent, let resetsAt):
                let used = String(format: "%.0f", min(max(percent, 0), 100))
                if let resetsAt {
                    return String(format: String(localized: "Codex has used %@%% of its week and comes back %@."),
                                  used, Fmt.stamp(resetsAt))
                }
                return String(format: String(localized: "Codex has used %@%% of its week."), used)
            case .refusedMidTurn:
                return String(localized: "Codex refused the turn — it has no quota left.")
            }
        }
    }

    /// Whether to send this message to Claude instead of Codex, and why.
    ///
    /// - Parameter usage: what the engine last read from the Codex CLI. Absent usage is NOT
    ///   treated as exhausted: an unread quota is not a spent one, and refusing to use Codex
    ///   because a JSON file is missing would be its own bug.
    static func insteadOfCodex(usage: UsageSnapshot, enabled: Bool) -> Reason? {
        guard enabled, usage.present, let week = usage.sevenDay else { return nil }
        guard week.clampedPercent >= weeklyCeiling else { return nil }
        return .weeklyQuotaSpent(percent: week.clampedPercent, resetsAt: week.resetsAt)
    }

    /// Whether a finished Codex turn failed because there was no quota left.
    ///
    /// Matched on the wording both the CLI and the service use. A wrong match here costs one
    /// duplicated answer from Claude, so it stays narrow: only messages that actually name a
    /// limit, never a generic failure.
    static func refusal(in failure: String?) -> Reason? {
        guard let failure, !failure.isEmpty else { return nil }
        let text = failure.lowercased()
        let phrases = [
            "usage limit",
            "rate limit",
            "quota",
            "you've hit your",
            "youve hit your",
            "too many requests",
            "insufficient_quota",
        ]
        guard phrases.contains(where: text.contains) else { return nil }
        return .refusedMidTurn(failure)
    }
}
