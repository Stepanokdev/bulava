import Foundation

/// Starting points for an automation.
///
/// Chosen from what several vendors ship or document independently for scheduled coding agents —
/// Cursor, OpenAI Codex, Claude Code routines, GitHub's agentic-workflow samples, Devin, Factory —
/// checked against their own pages in October 2026. That is evidence the archetype is common, not
/// a measured ranking, so nothing here is called popular. Archetypes that need a service a Mac app
/// does not have — issue trackers, Slack, error monitoring, pull-request webhooks — are left out:
/// a starter must work with a git repository and this Mac alone, or say exactly what it needs.
///
/// Each one fills the form and is the user's to change from then on. The run's own rules — work in a
/// copy, say "nothing to do" plainly, put a report in `artifacts/` — come from `AutomationBrief`,
/// so the briefs here only say what to do.
nonisolated struct AutomationTemplate: Identifiable, Sendable {

    nonisolated enum Group: Sendable, CaseIterable {
        /// Works on any repository as it is.
        case anyRepository
        /// Works once something is filled in or allowed.
        case needsSetup
    }

    /// What a run leaves behind, said before it is switched on.
    nonisolated enum Output: Sendable {
        /// A written report. Nothing in the repository changes.
        case report
        /// Changes on its own branch, for him to review and merge.
        case changes
        /// A report, and a small change when one is clearly right.
        case reportAndSmallFixes
    }

    var id: String
    var name: String
    var summary: String
    var symbol: String
    var brief: String
    var trigger: AutomationTrigger
    var group: Group
    var output: Output
    /// What it needs that the form cannot see, or nil.
    var needs: String?

    static func all() -> [AutomationTemplate] {
        let zone = TimeZone.current.identifier
        func weekly(_ day: Int, _ hour: Int, _ minute: Int = 0, away: Bool = false) -> AutomationTrigger {
            .schedule(AutomationSchedule(cadence: .weekly(days: [day]), hour: hour, minute: minute,
                                         timeZoneID: zone, waitUntilAway: away))
        }
        return [
            // MARK: Any repository
            AutomationTemplate(
                id: "digest", name: String(localized: "Summary of what changed"),
                summary: String(localized: "Each weekday morning: what moved in the repository, and what looks risky or unfinished."),
                symbol: "text.line.first.and.arrowtriangle.forward",
                brief: String(localized: "Summarise what changed in this repository since the previous run, or in the last day if there was none: the commits, the areas that changed most, new TODOs. Point out anything that looks risky or unfinished. Change no files."),
                trigger: .schedule(AutomationSchedule(cadence: .weekdays, hour: 8, minute: 30, timeZoneID: zone)),
                group: .anyRepository, output: .report),
            AutomationTemplate(
                id: "bugs", name: String(localized: "Find bugs in recent commits"),
                summary: String(localized: "Each night: reads the day's commits for real defects and reports them with file and line."),
                symbol: "ladybug",
                brief: String(localized: "Review the commits made since the previous run. Look for real defects: wrong logic, crashes, missed edge cases, unsafe concurrency, leaked resources. Report each one with its file, line and why it is wrong. Fix one only when the fix is small and you can show it with a test; otherwise leave the code as it is."),
                trigger: .schedule(AutomationSchedule(cadence: .daily, hour: 3, minute: 0, timeZoneID: zone, waitUntilAway: true)),
                group: .anyRepository, output: .reportAndSmallFixes),
            AutomationTemplate(
                id: "tests", name: String(localized: "Fix a failing build or tests"),
                summary: String(localized: "Each night: builds and runs the tests, and fixes what is clearly broken."),
                symbol: "wrench.and.screwdriver",
                brief: String(localized: "Build the project and run its tests. If something fails, find the cause and fix it when the fix is clear. Never weaken or delete a test to make it pass. If everything passes, say so and change nothing. If the build or the tests cannot run on this Mac, say exactly what is missing."),
                trigger: .schedule(AutomationSchedule(cadence: .daily, hour: 2, minute: 30, timeZoneID: zone, waitUntilAway: true)),
                group: .anyRepository, output: .changes),
            AutomationTemplate(
                id: "coverage", name: String(localized: "Add missing tests"),
                summary: String(localized: "Weekly: adds focused tests to important code that has none, without touching that code."),
                symbol: "checklist",
                brief: String(localized: "Find code that matters and has no tests, starting with recently changed logic. Add focused tests that check real behaviour, then run the whole test suite. Do not change the code under test. If the coverage is already sound, say so."),
                trigger: weekly(4, 3, away: true),
                group: .anyRepository, output: .changes),
            AutomationTemplate(
                id: "security", name: String(localized: "Security review"),
                summary: String(localized: "Weekly: committed secrets and vulnerable dependencies, reported without the secret values."),
                symbol: "lock.shield",
                brief: String(localized: "Look for committed secrets, keys and tokens, and for dependencies with known vulnerabilities. Report each finding with its file and line, never the secret itself. Say that a leaked key has to be revoked or rotated — removing it from the code does not undo the leak — and do not rewrite git history. Fix only what can be fixed without changing behaviour, and name the checks you could not run."),
                trigger: weekly(5, 3, 30),
                group: .anyRepository, output: .reportAndSmallFixes),
            AutomationTemplate(
                id: "docs", name: String(localized: "Docs that match the code"),
                summary: String(localized: "Weekly: corrects what the README and docs say that is no longer true."),
                symbol: "text.book.closed",
                brief: String(localized: "Compare the README and the docs with what the code actually does. Correct statements that are no longer true — facts only, not the style. If everything still holds, say so."),
                trigger: weekly(1, 4),
                group: .anyRepository, output: .changes),
            AutomationTemplate(
                id: "deps", name: String(localized: "Dependency updates"),
                summary: String(localized: "Weekly: applies patch and minor updates, runs the tests, and lists the major ones."),
                symbol: "shippingbox",
                brief: String(localized: "Check the project's dependencies for newer versions. Apply patch and minor updates, then build and run the tests. List major updates without applying them. Leave anything that breaks the build as it was and say why. If this project's package manager is not available here, say so instead of guessing."),
                trigger: weekly(7, 3, away: true),
                group: .anyRepository, output: .changes,
                needs: String(localized: "The project's package manager on this Mac.")),
            AutomationTemplate(
                id: "release-notes", name: String(localized: "Release notes draft"),
                summary: String(localized: "Every Friday: what is new and fixed since the last tag, as a draft to edit."),
                symbol: "doc.richtext",
                brief: String(localized: "Write release notes for the changes since the last tag, or since the previous run if there are no tags: what is new, what is fixed, what changes for the people who use it. Save them as artifacts/release-notes.md. Do not tag, push or edit the changelog."),
                trigger: weekly(6, 16),
                group: .anyRepository, output: .report),

            // MARK: Needs setup
            AutomationTemplate(
                id: "releases", name: String(localized: "A library you use released"),
                summary: String(localized: "When a dependency publishes a release: whether it matters here, and how to upgrade."),
                symbol: "sparkles.rectangle.stack",
                brief: String(localized: "A library or tool this project uses published a release — it is listed below. Read its release notes and say whether it matters here: fixes we need, breaking changes, security notes. Change nothing; if it is worth upgrading, say how."),
                trigger: .watch(AutomationWatch(source: .feed(url: ""), everyMinutes: 360)),
                group: .needsSetup, output: .report,
                needs: String(localized: "The release feed's address — on GitHub it ends in /releases.atom.")),
            AutomationTemplate(
                id: "parity", name: String(localized: "Keep up with another repository"),
                summary: String(localized: "When another repository gets commits: makes the matching changes here."),
                symbol: "arrow.triangle.2.circlepath",
                brief: String(localized: "New commits landed in the repository this one follows — they are listed below. Find the ones that need a matching change here: API, data models, features. Make those changes, then build and test. List what you did not bring over and why."),
                trigger: .watch(AutomationWatch(source: .commits(repoPath: "", branch: nil), everyMinutes: 60)),
                group: .needsSetup, output: .changes,
                needs: String(localized: "The repository to follow, on this Mac.")),
            AutomationTemplate(
                id: "mail", name: String(localized: "Letters that need an answer"),
                summary: String(localized: "When letters you choose arrive in Mail: what each asks, and a draft reply. Sends nothing."),
                symbol: "envelope.badge",
                brief: String(localized: "New letters arrived — they are below. Sum each one up in a line or two, say what it asks of me, and draft a reply where one is needed, in your answer rather than as files. Send nothing."),
                trigger: .event(AutomationEvent(kind: .mail(from: "", subject: ""))),
                group: .needsSetup, output: .report,
                needs: String(localized: "Mail open on this Mac, Bulava allowed to read it, and a sender or subject to listen for.")),
        ]
    }
}
