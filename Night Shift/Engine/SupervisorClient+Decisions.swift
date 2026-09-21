import Foundation

extension SupervisorClient {

    func parkedMessageIDs(projectPath: String) -> (queued: Set<UUID>, failed: Set<UUID>) {
        let dir = paths.undeliveredDir(slug: Slug.forPath(projectPath))
        func ids(_ name: String) -> Set<UUID> {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name),
                                        encoding: .utf8) else { return [] }
            return Set(text.split(separator: "\n").compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = object["id"] as? String else { return nil }
                return UUID(uuidString: raw)
            })
        }
        return (ids("undelivered.jsonl"), ids("undelivered-stuck.jsonl"))
    }

    func repoNote(projectPath: String, filename: String, chars: Int = 1600) -> String? {
        let url = URL(fileURLWithPath: projectPath).appendingPathComponent(filename)
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.count > chars ? "…" + String(trimmed.suffix(chars)) : trimmed
    }

    func clearParked(dirName: String) {
        let url = paths.queueNeedsUser.appendingPathComponent(dirName)
        try? FileManager.default.removeItem(at: url)
    }

    func checkPRMerged(number: String, repo: String, cwd: String?) async -> Bool? {
        guard !repo.isEmpty, !number.isEmpty else { return nil }
        let r = await Shell.run("gh pr view \"$1\" --repo \"$2\" --json state --jq .state 2>/dev/null || true",
                                args: [number, repo], cwd: cwd.map { URL(fileURLWithPath: $0) }, timeout: 25)
        let state = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return state.isEmpty ? nil : (state == "MERGED")
    }

    func createWorktree(projectPath: String, taskID: String) async -> String? {
        let script = """
        proj="$1"; tid="$2"
        ( cd "$proj" && git rev-parse --git-dir >/dev/null 2>&1 ) || { echo ""; exit 0; }
        root="$(dirname "$proj")/.nightshift-worktrees"; mkdir -p "$root"
        wt="$root/$(basename "$proj")-$tid"
        if [ -d "$wt" ]; then echo "$wt"; exit 0; fi
        br="night/task-$tid"
        ( cd "$proj" && git worktree add -b "$br" "$wt" >/dev/null 2>&1 ) && echo "$wt" || echo ""
        """
        let r = await Shell.run(script, args: [projectPath, taskID], timeout: 60)
        let wt = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return wt.isEmpty ? nil : wt
    }

    func projectGitInfo(_ path: String) async -> (remote: String?, defaultBranch: String?) {
        let script = """
        r="$(git remote get-url origin 2>/dev/null)"
        d="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
        if [ -z "$d" ]; then for b in main master develop; do git show-ref --verify --quiet "refs/heads/$b" && d="$b" && break; done; fi
        printf '%s\\n%s\\n' "$r" "$d"
        """
        let res = await Shell.run(script, cwd: URL(fileURLWithPath: path), timeout: 15)
        let lines = res.stdout.components(separatedBy: "\n")
        let remote = lines.indices.contains(0) && !lines[0].isEmpty ? lines[0] : nil
        let branch = lines.indices.contains(1) && !lines[1].isEmpty ? lines[1] : nil
        return (remote, branch)
    }

    func askCodex(prompt: String, cwd: String? = nil) async -> String? {
        let dir = cwd.map { URL(fileURLWithPath: $0) }
        let r = await Shell.run("codex exec --sandbox read-only --skip-git-repo-check \"$1\" 2>/dev/null",
                                args: [prompt], cwd: dir, timeout: 150)
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    func describeAttachments(fileNames: [String], directory: URL, message: String,
                             timeout: TimeInterval = 180) async -> String? {
        let names = fileNames.filter { !$0.contains("/") && !$0.hasPrefix(".") }
        guard !names.isEmpty else { return nil }
        let list = names.map { "- \($0)" }.joined(separator: "\n")
        let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        Прочитай ці файли з поточної теки (це вкладення, які користувач щойно надіслав у чат):
        \(list)

        \(said.isEmpty ? "Він не написав нічого — вкладення і є повідомлення."
                       : "Він написав: «\(said)»")

        Перекажи ДОСЛІВНО і по суті, що в них — так, щоб за твоїм переказом можна було зробити
        роботу, не відкриваючи файл. Якщо це список вимог — випиши всі пункти. Якщо це скріншот
        екрана з дефектом — опиши, що на екрані й що саме не так. Якщо це листування — передай,
        хто що просить.

        Тільки те, що справді видно. Нічого не додумуй, не давай порад і не пропонуй рішень.
        Якщо файл не читається — скажи це одним рядком.
        """
        let r = await Shell.run(
            "printf '%s' \"$1\" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude -p --tools 'Read' --strict-mcp-config 2>/dev/null",
            args: [prompt], cwd: directory, timeout: timeout)
        guard r.launched, r.exitCode == 0 else { return nil }
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    func askClaude(prompt: String, timeout: TimeInterval = 60) async -> String? {
        let neutral = URL(fileURLWithPath: NSTemporaryDirectory())

        let r = await Shell.run(
            "printf '%s' \"$1\" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude -p --tools '' --strict-mcp-config 2>/dev/null",
            args: [prompt], cwd: neutral, timeout: timeout)

        guard r.launched, r.exitCode == 0 else { return nil }
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    enum LookResult: Sendable {
        case answer(String)

        case wentQuiet(minutes: Int, partial: String?)

        case failed(reason: String)

        case unavailable(reason: String)
    }

    func lookAtProject(question: String, projectPath: String?,
                       quietFor: TimeInterval = 150,
                       ceiling: TimeInterval = 2400) async -> LookResult {
        guard let projectPath, !projectPath.isEmpty else {
            return .unavailable(reason: "no project to look at")
        }
        guard FileManager.default.fileExists(atPath: projectPath) else {
            return .unavailable(reason: "the folder is not there: \(projectPath)")
        }

        let r = await Shell.run(
            "printf '%s' \"$1\" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude -p"
            + " --tools 'Read,Grep,Glob' --strict-mcp-config --permission-mode plan"
            + " --output-format stream-json --verbose",
            args: [question], cwd: URL(fileURLWithPath: projectPath),
            timeout: ceiling, idle: quietFor)
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stream = LookStream(ndjson: r.stdout)

        if !r.launched {
            return .unavailable(reason: err.isEmpty ? "could not start claude" : firstLine(err))
        }
        switch r.endedBy {
        case .wentQuiet(let idle):
            return .wentQuiet(minutes: max(1, Int(idle / 60)), partial: stream.partial)
        case .hitCeiling:
            return .wentQuiet(minutes: max(1, Int(ceiling / 60)), partial: stream.partial)
        case .neverStarted:
            return .unavailable(reason: err.isEmpty ? "could not start claude" : firstLine(err))
        case .exited:
            if let answer = stream.answer { return .answer(answer) }
            if let partial = stream.partial { return .answer(partial) }
            if let refusal = stream.error { return .failed(reason: refusal) }
            return .failed(reason: err.isEmpty ? "it answered with nothing" : firstLine(err))
        }
    }

    struct LookStream {
        var answer: String?
        var partial: String?
        var error: String?

        init(ndjson: String) {
            var text: [String] = []
            for line in ndjson.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                switch type {
                case "result":

                    let payload = (event["result"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if (event["is_error"] as? Bool) == true {
                        error = payload
                    } else if let payload, !payload.isEmpty {
                        answer = payload
                    }
                case "assistant":
                    guard let message = event["message"] as? [String: Any],
                          let content = message["content"] as? [[String: Any]] else { continue }
                    for block in content where block["type"] as? String == "text" {
                        if let t = (block["text"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                            text.append(t)
                        }
                    }
                default: continue
                }
            }
            partial = text.isEmpty ? nil : text.joined(separator: "\n\n")
        }
    }

    private func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}
