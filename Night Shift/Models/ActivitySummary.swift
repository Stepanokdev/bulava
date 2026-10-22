import Foundation

/// A run of steps said in one line, by kind: "Read 3 files, edited 2, ran 4 commands".
///
/// What used to stand there was "17 steps" over a list of raw commands. He asked for the way
/// ChatGPT shows an agent at work (22.10): what was done, grouped, in words — the individual
/// steps stay one click away for whoever wants them.
nonisolated enum ActivitySummary {

    enum Kind: String, CaseIterable, Sendable {
        case read, edit, search, run, browser, device, tool, deploy, agent, web, other
    }

    /// What kind of step a verb key names. The keys are the ones `WorkerActivity.describe` and the
    /// Codex stream produce; anything new falls under `other` rather than being miscounted.
    static func kind(of verbKey: String) -> Kind {
        switch verbKey {
        case "reads %@", "Reading %@": .read
        case "edits %@", "Editing %@": .edit
        case "searches the code", "Searching for %@": .search
        case "runs %@", "described %@", "Running %@": .run
        case "drives the browser": .browser
        case "drives the app on a device": .device
        case "works with %@", "applies %@", "generates an image": .tool
        case "deploys": .deploy
        case "started a sub-agent", "asks %@": .agent
        case "reads documentation": .web
        default: .other
        }
    }

    /// The format key for `n` steps of a kind, with the plural forms in the string catalog.
    static func key(for kind: Kind) -> String {
        switch kind {
        case .read: "read %lld files"
        case .edit: "edited %lld files"
        case .search: "searched the code %lld times"
        case .run: "ran %lld commands"
        case .browser: "worked in the browser %lld times"
        case .device: "worked on the device %lld times"
        case .tool: "used tools %lld times"
        case .deploy: "deployed %lld times"
        case .agent: "started %lld helpers"
        case .web: "read %lld pages"
        case .other: "%lld other steps"
        }
    }

    /// The finished steps, counted by kind in a fixed order and said in one line, the first word
    /// capitalised. Empty when nothing has finished yet.
    static func line(_ activities: [BlockActivity],
                     count: (String, Int) -> String = { Fmt.count($0, $1) }) -> String {
        var tally: [Kind: Int] = [:]
        for activity in activities where activity.status != .running {
            tally[kind(of: activity.verbKey), default: 0] += 1
        }
        let parts = Kind.allCases.compactMap { kind -> String? in
            guard let n = tally[kind], n > 0 else { return nil }
            return count(key(for: kind), n)
        }
        guard let first = parts.first else { return "" }
        let joined = ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst())
            .joined(separator: ", ")
        return joined
    }
}
