import Foundation

nonisolated struct InstalledSkill: Sendable, Equatable, Identifiable {
    enum Scope: String, Sendable {
        case project, global, plugin
    }

    var id: String { path.isEmpty ? "\(scope.rawValue):\(name)" : path }
    var name: String
    var scope: Scope

    var path: String = ""

    var projectPath: String = ""

    var uses: Int

    var lastUsed: String?

    var frontmatterSize: Int

    var description: String = ""

    var source: String?

    /// Uses inside ONE project, when that has been counted, and when it was last used there.
    ///
    /// Optional because zero and "not looked" are different answers, and because the engine's own
    /// count is a machine-wide total: 17 uses of `minimalist-ui` says nothing about whether THIS
    /// product has ever wanted it, which is why the numbers on the panel meant nothing.
    var usesHere: Int?
    var lastUsedHere: String?

    var canUpdate: Bool { scope == .project && !(source ?? "").isEmpty }

    var canRemove: Bool { scope != .plugin }
}

nonisolated struct MissingSkill: Sendable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var uses: Int
    var lastUsed: String?
}

nonisolated struct SkillInventory: Sendable, Equatable {
    var skills: [InstalledSkill] = []
    var missing: [MissingSkill] = []

    var transcriptsScanned: Int = 0

    /// Transcripts read for the one project, so the panel can say what its numbers rest on.
    var transcriptsHere: Int = 0

    var counted: Bool = false
    var loaded: Bool = false

    var unused: [InstalledSkill] { counted ? skills.filter { $0.uses == 0 } : [] }

    var unusedFrontmatter: Int { unused.reduce(0) { $0 + $1.frontmatterSize } }

    /// The same inventory with each skill's use count for one project filled in.
    func attributed(to use: SkillUseInProject) -> SkillInventory {
        guard use.counted else { return self }
        var out = self
        out.skills = skills.map { skill in
            var row = skill
            row.usesHere = use.uses[skill.name] ?? 0
            row.lastUsedHere = use.lastUsed[skill.name]
            return row
        }
        out.transcriptsHere = use.transcripts
        return out
    }

    /// Skills this project has actually used, most-used first — whatever scope they live in.
    var usedHere: [InstalledSkill] {
        skills.filter { ($0.usesHere ?? 0) > 0 }
            .sorted {
                if ($0.usesHere ?? 0) != ($1.usesHere ?? 0) {
                    return ($0.usesHere ?? 0) > ($1.usesHere ?? 0)
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// The inventory as it applies to ONE project.
    ///
    /// Every project on the machine is scanned, because the global list is the same everywhere and
    /// pruning it is a machine-wide decision. But a project-scoped skill installed in some other
    /// repository is not this project's, and counting it here produced a headline — "77 installed"
    /// — that was true of the machine and false of the product named directly above it.
    func visible(forProjectPath path: String?) -> SkillInventory {
        guard let path, !path.isEmpty else { return self }
        let wanted = Slug.canonicalPath(path)
        var out = self
        out.skills = skills.filter { skill in
            guard skill.scope == .project else { return true }
            return Slug.canonicalPath(skill.projectPath) == wanted
        }
        return out
    }

    func belongingTo(projects paths: [String]) -> SkillInventory {
        let wanted = Set(paths.filter { !$0.isEmpty })

        return SkillInventory(skills: skills.filter { $0.scope == .project && wanted.contains($0.projectPath) },
                              transcriptsScanned: transcriptsScanned, counted: counted, loaded: loaded)
    }

    static let empty = SkillInventory()
}

extension SupervisorClient {

    func skillInventory(projectPaths: [String], fast: Bool = false) async -> SkillInventory {
        guard let home = OrchestratorHome.detect()?.path else { return .empty }
        let script = "\(home)/bin/skill-resolver.sh"
        guard FileManager.default.fileExists(atPath: script) else { return .empty }

        var seen = Set<String>()
        let projects = projectPaths.filter { !$0.isEmpty && seen.insert($0).inserted }

        let script_args = projects.isEmpty ? ""
            : (2...(projects.count + 1)).map { "\"$\($0)\"" }.joined(separator: " ")

        let r = await Shell.run("bash \"$1\" usage \(script_args) --json\(fast ? " --fast" : "") 2>/dev/null",
                                args: [script] + projects, timeout: fast ? 30 : 180)
        guard let data = r.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["installed"] as? [[String: Any]] else { return .empty }

        let sources = lockedSources()
        var out: [InstalledSkill] = []
        for row in rows {
            guard let name = row["name"] as? String, !name.isEmpty else { continue }

            guard let scope = InstalledSkill.Scope(rawValue: (row["scope"] as? String) ?? "") else { continue }
            let last = (row["last"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.append(InstalledSkill(name: name, scope: scope,
                                      path: (row["path"] as? String) ?? "",
                                      projectPath: (row["project"] as? String) ?? "",
                                      uses: (row["uses"] as? NSNumber)?.intValue ?? 0,
                                      lastUsed: last,
                                      frontmatterSize: (row["frontmatter"] as? NSNumber)?.intValue ?? 0,
                                      description: (row["description"] as? String) ?? "",
                                      source: sources["\(scope.rawValue):\(name)"]))
        }
        out.sort {
            if $0.uses != $1.uses { return $0.uses > $1.uses }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var missing: [MissingSkill] = []
        for row in (root["used_but_not_installed"] as? [[String: Any]]) ?? [] {
            guard let name = row["name"] as? String, !name.isEmpty else { continue }
            let last = (row["last"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            missing.append(MissingSkill(name: name,
                                        uses: (row["uses"] as? NSNumber)?.intValue ?? 0,
                                        lastUsed: last))
        }
        missing.sort { $0.uses > $1.uses }
        return SkillInventory(skills: out, missing: missing,
                              transcriptsScanned: (root["transcripts"] as? NSNumber)?.intValue ?? 0,
                              counted: (root["counted"] as? Bool) ?? !fast,
                              loaded: true)
    }

    func removeSkill(_ skill: InstalledSkill, projectPath: String) async -> (ok: Bool, message: String) {
        await runResolver(["remove", skill.projectPath.isEmpty ? projectPath : skill.projectPath,
                           skill.name, skill.scope.rawValue])
    }

    func updateSkill(_ skill: InstalledSkill, projectPath: String) async -> (ok: Bool, message: String) {

        await runResolver(["update", skill.projectPath.isEmpty ? projectPath : skill.projectPath,
                           skill.name, skill.scope.rawValue], timeout: 420)
    }

    private func runResolver(_ argv: [String], timeout: TimeInterval = 60) async -> (ok: Bool, message: String) {
        guard let home = OrchestratorHome.detect()?.path else { return (false, "engine not found") }
        let script = "\(home)/bin/skill-resolver.sh"
        guard FileManager.default.fileExists(atPath: script) else { return (false, "skill-resolver.sh missing") }
        let r = await Shell.run("bash \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" 2>&1",
                                args: [script] + argv, timeout: timeout)
        let out = (r.stdout.isEmpty ? r.stderr : r.stdout).trimmedTail
        return (r.exitCode == 0, out.isEmpty ? "no output" : out)
    }

    private func lockedSources() -> [String: String] {
        let lock = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".orchestrator/skills.lock")
        guard let d = try? Data(contentsOf: lock),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rows = o["skills"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for row in rows {
            guard let n = row["name"] as? String,
                  let s = row["source_url"] as? String, !s.isEmpty else { continue }
            let scope = (row["scope"] as? String) ?? "project"
            out["\(scope):\(n)"] = s
        }
        return out
    }
}
