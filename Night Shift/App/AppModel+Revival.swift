import Foundation
import OSLog

/// How bringing one dead run back is going.
nonisolated struct RevivalAttempt: Equatable, Sendable {
    var tries = 0
    var last: Date?
    var inFlight = false
    /// Refused by the engine for good (stopped, replaced): not tried again.
    var refused = false
}

extension AppModel {

    /// Tries before the chat says it could not be brought back, and the gap between them.
    static let revivalTries = 3
    static let revivalGap: TimeInterval = 180

    /// A run whose watchdog died with its session while it still owed work is brought back in place.
    ///
    /// Nothing else would. A chat parked on Codex's usage window, owing its review, lost its tmux
    /// session and its watchdog a few minutes before Codex came back — and stayed parked, under
    /// "Waiting for Codex", long after: a dead watchdog cannot notice anything, and a message to it
    /// used to replace the run and lose the review. The engine now brings such a run back as it was
    /// (`night-shift.sh revive`); this is what asks it to when the watchdog is not there to. One try at
    /// a time per run, a few minutes apart, a few in all — each start of Claude costs — and then the
    /// chat says so; a message there tries again (`worker-send.sh`).
    func reviveDeadRuns(now: Date = Date()) {
        let dead = snapshot.instances.filter { $0.needsRevival && !$0.inStartupGrace }
        for slug in revivals.keys where !dead.contains(where: { $0.slug == slug }) && revivals[slug]?.inFlight != true {
            revivals[slug] = nil
        }
        for inst in dead {
            var attempt = revivals[inst.slug] ?? RevivalAttempt()
            guard !attempt.inFlight, !attempt.refused, attempt.tries < Self.revivalTries,
                  now.timeIntervalSince(attempt.last ?? .distantPast) >= Self.revivalGap else { continue }
            attempt.inFlight = true
            attempt.tries += 1
            attempt.last = now
            revivals[inst.slug] = attempt
            let slug = inst.slug, project = inst.projectPath, name = name(of: project) ?? project
            Log.lifecycle.notice("reviving \(slug, privacy: .public): its watchdog is gone and it still owes work (try \(attempt.tries))")
            Task { [weak self] in
                guard let self else { return }
                let result = await client.revive(projectPath: project)
                revivals[slug]?.inFlight = false
                switch result.exitCode {
                case 0:
                    note(.taskDispatched, .info,
                         String(format: String(localized: "Night Shift for «%@» stopped unexpectedly and was brought back"), name),
                         projectPath: project)
                case 4:
                    revivals[slug]?.refused = true
                    Log.lifecycle.notice("revival of \(slug, privacy: .public) refused: \(result.stdout.suffix(200), privacy: .public)")
                default:
                    Log.lifecycle.error("revival of \(slug, privacy: .public) failed (\(result.exitCode)): \(result.stdout.suffix(300), privacy: .public)")
                }
                await refresh()
            }
        }
    }

    /// Whether bringing this run back has been given up on: refused, or out of tries.
    func revivalGaveUp(_ slug: String) -> Bool {
        guard let attempt = revivals[slug], !attempt.inFlight else { return false }
        return attempt.refused || attempt.tries >= Self.revivalTries
    }
}
