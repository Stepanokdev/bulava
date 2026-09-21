import Foundation

/// How often each skill was actually used IN one project.
///
/// The engine's count is a total across every project on the machine, which is why the numbers on
/// the skills panel meant nothing: 17 uses of `minimalist-ui` says nothing about whether THIS app
/// has ever wanted it. The evidence for the narrower question is already on disk — Claude Code
/// keeps one transcript directory per working folder, and a skill invocation is a `Skill` tool
/// call inside it — so this reads the directories belonging to one project instead of all 2,874
/// of them.
///
/// The honest limit travels with the numbers: transcripts hold what was kept. "No uses" means no
/// evidence of use, never "never useful".
nonisolated struct SkillUseInProject: Sendable, Equatable {

    /// uses, keyed by skill name.
    var uses: [String: Int] = [:]

    /// Last use, keyed by skill name, as the transcript's own `YYYY-MM-DD`.
    var lastUsed: [String: String] = [:]

    /// How many transcript files were read, so the panel can say what the number is based on.
    var transcripts = 0

    /// True once a scan actually ran — zero uses and "not looked yet" are different answers.
    var counted = false

    static let empty = SkillUseInProject()

    var total: Int { uses.values.reduce(0, +) }

    // MARK: Where a project's transcripts live

    /// Claude Code's directory name for a working folder: the absolute path with every `/`
    /// replaced by `-`.
    static func directoryName(forProjectPath path: String) -> String {
        Slug.canonicalPath(path).replacingOccurrences(of: "/", with: "-")
    }

    /// The transcript directories that belong to this project.
    ///
    /// Its own folder, plus the git worktrees Bulava makes for it when a second run needs the same
    /// repository — those are separate working folders with their own transcripts, and a night's
    /// work often happens entirely inside one. Counting only the main folder would report zero for
    /// a project that has been worked on seven times.
    static func directories(forProjectPath path: String,
                            root: URL? = nil) -> [URL] {
        let base = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let own = directoryName(forProjectPath: path)
        let folder = (Slug.canonicalPath(path) as NSString).lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
            return []
        }
        let worktreeMark = "nightshift-worktrees"
        return names.filter { name in
            if name == own { return true }
            // `…--nightshift-worktrees-pocket-ledger-3CC6DEF7`: a worktree of this repository.
            return name.contains(worktreeMark) && name.contains("-\(folder)-")
        }
        .sorted()
        .map { base.appendingPathComponent($0, isDirectory: true) }
    }

    // MARK: Reading them

    static func scan(projectPath: String, root: URL? = nil) -> SkillUseInProject {
        var out = SkillUseInProject()
        out.counted = true
        for directory in directories(forProjectPath: projectPath, root: root) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                out.transcripts += 1
                guard let text = try? String(contentsOf: directory.appendingPathComponent(name),
                                             encoding: .utf8) else { continue }
                out.absorb(transcript: text)
            }
        }
        return out
    }

    mutating func absorb(transcript: String) {
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap pre-filter: almost no line in a transcript is a skill call, and parsing every
            // one of them as JSON is the difference between a second and a minute.
            guard line.contains("\"Skill\"") else { continue }
            guard let data = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) else { continue }
            let day = Self.day(in: record)
            for skill in Self.skillNames(in: record) {
                uses[skill, default: 0] += 1
                if let day, day > (lastUsed[skill] ?? "") { lastUsed[skill] = day }
            }
        }
    }

    /// Every `Skill` tool call in one transcript record, however deeply it is nested.
    private static func skillNames(in record: Any) -> [String] {
        var found: [String] = []
        var stack: [Any] = [record]
        while let node = stack.popLast() {
            if let object = node as? [String: Any] {
                if object["name"] as? String == "Skill",
                   let input = object["input"] as? [String: Any],
                   let skill = input["skill"] as? String, !skill.isEmpty {
                    found.append(skill)
                }
                stack.append(contentsOf: object.values)
            } else if let array = node as? [Any] {
                stack.append(contentsOf: array)
            }
        }
        return found
    }

    private static func day(in record: Any) -> String? {
        guard let object = record as? [String: Any],
              let stamp = object["timestamp"] as? String, stamp.count >= 10 else { return nil }
        return String(stamp.prefix(10))
    }
}
