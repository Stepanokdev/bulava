import Foundation

extension SupervisorClient {
    func inspectChatProject(_ project: ChatInspectorProject) async -> ChatProjectInspection {
        let url = URL(fileURLWithPath: project.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: project.path) else {
            return ChatProjectInspection(project: project, isGitRepository: false,
                                         branch: nil, changes: [])
        }

        let script = """
        if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          printf '@@NOT_GIT@@\\n'
          exit 0
        fi
        printf '@@BRANCH@@\\n'
        git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null
        printf '@@STATUS@@\\n'
        git status --porcelain=v1 -z --untracked-files=all -- .
        printf '@@GITLINKS@@\\n'
        git ls-files --full-name --stage -- . 2>/dev/null | grep ^160000 || true
        printf '@@NUMSTAT@@\\n'
        git diff --numstat HEAD -- . 2>/dev/null
        """
        let result = await Shell.run(script, cwd: url, timeout: 12)
        return Self.parseChatInspection(result.stdout, project: project)
    }

    func chatFileDiff(projectPath: String, path: String) async -> String {
        let url = URL(fileURLWithPath: projectPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: projectPath) else { return "" }
        let script = """
        if git ls-files --error-unmatch -- "$1" >/dev/null 2>&1; then
          git diff --no-ext-diff --unified=3 HEAD -- "$1" 2>/dev/null
        elif [ -f "$1" ]; then
          git diff --no-index --no-ext-diff --unified=3 /dev/null "$1" 2>/dev/null || true
        fi
        """
        let result = await Shell.run(script, args: [path], cwd: url, timeout: 12)
        return String(result.stdout.prefix(40_000))
    }

    func chatEvidence(projectPath: String, runID: String?, sessionID: String?) -> Evidence? {
        guard let base = paths.artifactBase(runID: runID, projectPath: projectPath) else { return nil }
        if let sessionID, !sessionID.isEmpty {
            let file = base.appendingPathComponent("evidence/\(sessionID)/evidence.json")
            guard let data = try? Data(contentsOf: file), let evidence = Evidence.decode(from: data) else {
                return nil
            }
            return Self.matches(evidence, projectPath: projectPath) ? evidence : nil
        }
        guard let evidence = latestEvidence(in: base) else { return nil }
        return Self.matches(evidence, projectPath: projectPath) ? evidence : nil
    }

    nonisolated static func parseChatInspection(_ output: String,
                                                project: ChatInspectorProject) -> ChatProjectInspection {
        guard !output.contains("@@NOT_GIT@@") else {
            return ChatProjectInspection(project: project, isGitRepository: false,
                                         branch: nil, changes: [])
        }
        let branchMarker = "@@BRANCH@@\n"
        let statusMarker = "@@STATUS@@\n"
        let numstatMarker = "@@NUMSTAT@@\n"
        guard let branchRange = output.range(of: branchMarker),
              let statusRange = output.range(of: statusMarker),
              let numstatRange = output.range(of: numstatMarker),
              branchRange.upperBound <= statusRange.lowerBound,
              statusRange.upperBound <= numstatRange.lowerBound else {
            return ChatProjectInspection(project: project, isGitRepository: false,
                                         branch: nil, changes: [])
        }

        let branch = output[branchRange.upperBound..<statusRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let linkRange = output.range(of: "@@GITLINKS@@\n")
        let statusEnd = linkRange?.lowerBound ?? numstatRange.lowerBound
        let status = String(output[statusRange.upperBound..<statusEnd])

        var nested: Set<String> = []
        if let linkRange, linkRange.upperBound <= numstatRange.lowerBound {
            nested = Set(output[linkRange.upperBound..<numstatRange.lowerBound]
                .split(separator: "\n")
                .compactMap { line in
                    guard let tab = line.firstIndex(of: "\t") else { return nil }
                    let path = String(line[line.index(after: tab)...])
                    return path.isEmpty ? nil : path
                })
        }
        let counts = parseNumstat(String(output[numstatRange.upperBound...]))
        let changes = parsePorcelain(status, nested: nested).map { change in
            var copy = change
            if let count = counts[change.path] {
                copy.added = count.added
                copy.removed = count.removed
            }
            return copy
        }
        return ChatProjectInspection(project: project, isGitRepository: true,
                                     branch: branch.isEmpty ? nil : branch, changes: changes)
    }

    nonisolated static func isNoise(path: String, nested: Set<String>) -> Bool {
        if nested.contains(path) { return true }
        switch (path as NSString).lastPathComponent {
        case ".DS_Store", "Thumbs.db", "desktop.ini", ".localized": return true
        default: return false
        }
    }

    nonisolated static func parsePorcelain(_ raw: String, nested: Set<String> = []) -> [ChatFileChange] {
        let records = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [ChatFileChange] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 4 else { index += 1; continue }
            let x = record[record.startIndex]
            let yIndex = record.index(after: record.startIndex)
            let y = record[yIndex]
            let pathIndex = record.index(record.startIndex, offsetBy: 3)
            let path = String(record[pathIndex...])
            let renamed = x == "R" || y == "R" || x == "C" || y == "C"
            let previous = renamed && index + 1 < records.count ? records[index + 1] : nil
            guard !isNoise(path: path, nested: nested) else { index += renamed ? 2 : 1; continue }
            changes.append(ChatFileChange(path: path, previousPath: previous,
                                          kind: changeKind(index: x, worktree: y),
                                          staged: x != " " && x != "?",
                                          added: nil, removed: nil))
            index += renamed ? 2 : 1
        }
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated private static func parseNumstat(_ raw: String) -> [String: (added: Int, removed: Int)] {
        var result: [String: (added: Int, removed: Int)] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            result[String(fields[2])] = (Int(fields[0]) ?? 0, Int(fields[1]) ?? 0)
        }
        return result
    }

    nonisolated private static func changeKind(index: Character, worktree: Character) -> ChatFileChangeKind {
        let pair = String([index, worktree])
        if pair == "??" { return .untracked }
        if pair.contains("U") || pair == "AA" || pair == "DD" { return .conflicted }
        if index == "R" || worktree == "R" { return .renamed }
        if index == "C" || worktree == "C" { return .copied }
        let meaningful = worktree == " " ? index : worktree
        switch meaningful {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        default: return .unknown
        }
    }

    // MARK: The folders the check after an answer did not look at

    /// A check's evidence, the folder it was found in, and when it was written.
    struct DatedEvidence: Sendable {
        var evidence: Evidence
        var at: Date
        /// The run folder holding `evidence/` — where the checks of its other repositories live too.
        var base: URL
    }

    /// The chat's newest evidence as `chatEvidence` finds it, with the time it was written: what
    /// tells a check made for the answer on screen from one made for an earlier message.
    func chatEvidenceDated(projectPath: String, runID: String?, sessionID: String?) -> DatedEvidence? {
        guard let base = paths.artifactBase(runID: runID, projectPath: projectPath) else { return nil }
        let file: URL
        if let sessionID, !sessionID.isEmpty {
            file = base.appendingPathComponent("evidence/\(sessionID)/evidence.json")
        } else {
            let dirs = (try? FileManager.default.contentsOfDirectory(
                at: base.appendingPathComponent("evidence"), includingPropertiesForKeys: nil)) ?? []
            guard let newest = dirs.map({ $0.appendingPathComponent("evidence.json") })
                .compactMap({ url in Self.writtenAt(url).map { (url, $0) } })
                .max(by: { $0.1 < $1.1 })?.0 else { return nil }
            file = newest
        }
        guard let data = try? Data(contentsOf: file), let evidence = Evidence.decode(from: data),
              Self.matches(evidence, projectPath: projectPath), let at = Self.writtenAt(file) else { return nil }
        return DatedEvidence(evidence: evidence, at: at, base: base)
    }

    /// The newest check of one of the run's other repositories, made from the chat
    /// (`night-shift verify-elsewhere`), found by what it says it checked rather than by a folder
    /// name worked out here — the engine names that folder, and only the engine spells its slugs.
    func elsewhereEvidence(in base: URL, repoPath: String) -> DatedEvidence? {
        let root = base.appendingPathComponent("elsewhere")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let want = Slug.canonicalPath(repoPath)
        return dirs.compactMap { dir -> DatedEvidence? in
            let file = dir.appendingPathComponent("evidence/check/evidence.json")
            guard let data = try? Data(contentsOf: file), let evidence = Evidence.decode(from: data),
                  Slug.canonicalPath(evidence.projectDir) == want, let at = Self.writtenAt(file) else { return nil }
            return DatedEvidence(evidence: evidence, at: at, base: base)
        }.max { $0.at < $1.at }
    }

    nonisolated private static func writtenAt(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    nonisolated private static func matches(_ evidence: Evidence, projectPath: String) -> Bool {
        evidence.projectDir.isEmpty
            || Slug.canonicalPath(evidence.projectDir) == Slug.canonicalPath(projectPath)
    }
}
