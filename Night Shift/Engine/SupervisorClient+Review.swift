import Foundation

extension SupervisorClient {

    func loadReview(projectPath: String, branchHint: String? = nil, baseHint: String? = nil,
                    baseBranchHint: String? = nil, sessionID: String? = nil,
                    runID: String? = nil) async -> ReviewPackage {
        var pkg = ReviewPackage.empty(projectPath: projectPath)
        let projURL = URL(fileURLWithPath: projectPath)
        guard FileManager.default.fileExists(atPath: projectPath) else { return pkg }

        let script = """
        branch="$1"
        if [ -z "$branch" ]; then branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"; fi
        case "$branch" in
          night/*) : ;;
          *) nb="$(git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads/night/ 2>/dev/null | head -1)"; [ -n "$nb" ] && branch="$nb" ;;
        esac
        # Reject a bound branch that no longer exists — surface a clear mismatch
        # instead of silently diffing something unrelated.
        if [ -n "$1" ] && ! git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
          printf '@@MISSING@@\\n%s\\n' "$branch"; exit 0
        fi
        base="$2"; basebr="$3"
        if [ -z "$basebr" ]; then
          for c in main master develop; do
            if git show-ref --verify --quiet "refs/heads/$c"; then basebr="$c"; break; fi
          done
        fi
        if [ -z "$base" ] && [ -n "$basebr" ]; then base="$(git merge-base "$basebr" "$branch" 2>/dev/null)"; fi
        [ -z "$base" ] && base="$(git rev-parse "${branch}^" 2>/dev/null)"
        [ -z "$base" ] && base="$branch"
        # The MERGE destination is always a default branch that is NOT the reviewed
        # branch — merging a branch into itself is a no-op and must be disallowed.
        mergedest=""
        for c in main master develop; do
          if git show-ref --verify --quiet "refs/heads/$c" && [ "$c" != "$branch" ]; then mergedest="$c"; break; fi
        done
        printf '@@BRANCH@@\\n%s\\n' "$branch"
        printf '@@BASEBR@@\\n%s\\n' "$basebr"
        printf '@@DEFAULT@@\\n%s\\n' "$mergedest"
        printf '@@BASE@@\\n%s\\n' "$base"
        printf '@@HEAD@@\\n%s\\n' "$(git rev-parse "$branch" 2>/dev/null)"
        printf '@@NUMSTAT@@\\n'; git diff "$base".."$branch" --numstat 2>/dev/null
        printf '@@COMMITS@@\\n'; git log "$base".."$branch" --oneline 2>/dev/null | head -50
        printf '@@DIFF@@\\n'; git diff "$base".."$branch" 2>/dev/null | head -c 80000
        """
        let r = await Shell.run(script, args: [branchHint ?? "", baseHint ?? "", baseBranchHint ?? ""],
                                cwd: projURL, timeout: 40)
        if let missing = missingBranch(r.stdout) {
            pkg.branch = missing
            pkg.mismatch = "The bound branch ‘\(missing)’ no longer exists in the repo."
            pkg.loadedAt = Date()
            return pkg
        }
        parseGit(r.stdout, into: &pkg)

        if let base = paths.artifactBase(runID: runID, projectPath: projectPath) {

            pkg.evidence = boundEvidence(base: base, sessionID: sessionID,
                                         projectPath: projectPath, baseSHA: pkg.baseRef)
            readRunNotes(base: base, projURL: projURL, into: &pkg)

            pkg.scopeViolationCount = scopeViolationCount(base: base)

            (pkg.reportManifest, pkg.reportDirectory) = loadReportManifest(base: base, sessionID: sessionID)
        }
        pkg.loadedAt = Date()
        return pkg
    }

    private func loadReportManifest(base: URL, sessionID: String?) -> (ReportManifest?, URL?) {
        var dirs = [base.appendingPathComponent("report")]
        if let sid = sessionID { dirs.append(base.appendingPathComponent("evidence/\(sid)/report")) }
        for dir in dirs {
            let json = dir.appendingPathComponent("report.json")
            guard let data = try? Data(contentsOf: json),
                  let m = try? JSONDecoder().decode(ReportManifest.self, from: data) else { continue }
            return (m, dir)
        }
        return (nil, nil)
    }

    func runVerify(projectPath: String, orchestratorHome: String, sessionID: String) async -> Evidence? {
        guard FileManager.default.fileExists(atPath: "\(orchestratorHome)/bin/verify.sh") else { return nil }
        let r = await Shell.run("bash \"$1/bin/verify.sh\" \"$2\" \"$3\"",
                                args: [orchestratorHome, projectPath, sessionID],
                                extraEnv: ["SUPERVISOR_VERIFY_STEP_TIMEOUT": "900",
                                           "SUPERVISOR_VERIFY_TOTAL_TIMEOUT": "1500"],
                                timeout: 1000)
        let evPath = r.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        guard let evPath, !evPath.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: evPath)) else { return nil }
        return Evidence.decode(from: data)
    }

    private func missingBranch(_ output: String) -> String? {
        let lines = output.components(separatedBy: "\n")
        guard let i = lines.firstIndex(of: "@@MISSING@@"), i + 1 < lines.count else { return nil }
        let b = lines[i + 1].trimmingCharacters(in: .whitespaces)
        return b.isEmpty ? nil : b
    }

    private func boundEvidence(base: URL, sessionID: String?, projectPath: String, baseSHA: String?) -> Evidence? {
        if let sessionID {
            let f = base
                .appendingPathComponent("evidence").appendingPathComponent(sessionID).appendingPathComponent("evidence.json")
            guard let data = try? Data(contentsOf: f), let ev = Evidence.decode(from: data) else { return nil }
            return validated(ev, projectPath: projectPath, baseSHA: baseSHA)
        }
        guard let latest = latestEvidence(in: base) else { return nil }
        return validated(latest, projectPath: projectPath, baseSHA: baseSHA)
    }

    private func validated(_ ev: Evidence, projectPath: String, baseSHA: String?) -> Evidence? {
        if !ev.projectDir.isEmpty, Slug.canonicalPath(ev.projectDir) != Slug.canonicalPath(projectPath) { return nil }
        if let baseSHA, !baseSHA.isEmpty, !ev.baseSHA.isEmpty, ev.baseSHA != baseSHA { return nil }
        return ev
    }

    private func parseGit(_ output: String, into pkg: inout ReviewPackage) {
        enum Section { case none, branch, basebr, mergeDefault, base, head, numstat, commits, diff }
        var section: Section = .none
        var diffLines: [String] = []
        var numstatCount = 0
        for line in output.components(separatedBy: "\n") {
            switch line {
            case "@@BRANCH@@": section = .branch; continue
            case "@@BASEBR@@": section = .basebr; continue
            case "@@DEFAULT@@": section = .mergeDefault; continue
            case "@@BASE@@": section = .base; continue
            case "@@HEAD@@": section = .head; continue
            case "@@NUMSTAT@@": section = .numstat; continue
            case "@@COMMITS@@": section = .commits; continue
            case "@@DIFF@@": section = .diff; continue
            default: break
            }
            switch section {
            case .branch: if !line.isEmpty { pkg.branch = line }
            case .basebr: if !line.isEmpty { pkg.baseBranch = line }
            case .mergeDefault: if !line.isEmpty { pkg.mergeTarget = line }
            case .base: if !line.isEmpty { pkg.baseRef = line }
            case .head: if !line.isEmpty { pkg.headSHA = line }
            case .numstat:
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                if parts.count == 3 {
                    let added = Int(parts[0]) ?? 0
                    let removed = Int(parts[1]) ?? 0
                    pkg.changedFiles.append(DiffFile(path: String(parts[2]), added: added, removed: removed))
                    pkg.insertions += added; pkg.deletions += removed
                    numstatCount += 1
                }
            case .commits: if !line.isEmpty { pkg.commits.append(line) }
            case .diff: diffLines.append(line)
            case .none: break
            }
        }
        _ = numstatCount
        pkg.diffText = diffLines.joined(separator: "\n")
        pkg.truncatedDiff = pkg.diffText.utf8.count >= 80000
    }

    private func readRunNotes(base: URL, projURL: URL, into pkg: inout ReviewPackage) {
        let reports = base.appendingPathComponent("reports")
        if let d = try? Data(contentsOf: reports.appendingPathComponent("review.json")),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            pkg.reviewState = obj["state"] as? String
            pkg.reviewVerdict = obj["verdict"] as? String
            pkg.disposition = obj["disposition"] as? String
            if let f = obj["findings"] as? String, !f.isEmpty { pkg.findings = [f] }
        }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: reports.path),
           let newest = files.filter({ $0.hasPrefix("audit-") && $0.hasSuffix(".md") }).sorted().last,
           let text = try? String(contentsOf: reports.appendingPathComponent(newest), encoding: .utf8) {
            pkg.auditFile = newest; pkg.auditExcerpt = String(text.prefix(3000))
        }
        pkg.blockedExcerpt = tail(reports.appendingPathComponent("blocked.md"), chars: 1500)
        pkg.reviewDebtExcerpt = tail(reports.appendingPathComponent("review-debt.md"), chars: 1500)

        pkg.decisionsExcerpt = tail(projURL.appendingPathComponent("DECISIONS.md"), chars: 2000)

        if pkg.reviewState == nil && pkg.auditFile == nil
            && pkg.blockedExcerpt == nil && pkg.reviewDebtExcerpt == nil {
            readRepoNotes(projURL, into: &pkg)
        }
    }

    private func readRepoNotes(_ projURL: URL, into pkg: inout ReviewPackage) {

        if let files = try? FileManager.default.contentsOfDirectory(atPath: projURL.path) {
            let audits = files.filter { $0.hasPrefix("AUDIT-") && $0.hasSuffix(".md") }.sorted()
            if let newest = audits.last {
                let url = projURL.appendingPathComponent(newest)
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    pkg.auditFile = newest
                    pkg.auditExcerpt = String(text.prefix(3000))
                }
            }
        }
        pkg.decisionsExcerpt = tail(projURL.appendingPathComponent("DECISIONS.md"), chars: 2000)
        pkg.blockedExcerpt = tail(projURL.appendingPathComponent("BLOCKED.md"), chars: 1500)
        pkg.reviewDebtExcerpt = tail(projURL.appendingPathComponent("REVIEW-DEBT.md"), chars: 1500)
    }

    private func tail(_ url: URL, chars: Int) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.count > chars ? "…" + String(trimmed.suffix(chars)) : trimmed
    }

    private func scopeViolationCount(base: URL) -> Int {
        let url = base.appendingPathComponent("scope-violation.json")
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return 0 }
        if let n = obj["count"] as? Int { return n }
        if let n = obj["count"] as? Double { return Int(n) }
        return 0
    }

    // MARK: Merge

    func merge(projectPath: String, branch: String?, target: String?) async -> MergeResult {
        guard let branch, !branch.isEmpty else { return .noBranch }
        guard let target, !target.isEmpty else { return .sameBranch }
        guard branch != target else { return .sameBranch }
        let projURL = URL(fileURLWithPath: projectPath)
        let script = """
        if [ "$1" = "$2" ]; then echo SAME; exit 0; fi
        st="$(git status --porcelain 2>/dev/null)"
        if [ -n "$st" ]; then echo DIRTY; exit 0; fi
        git rev-parse --verify --quiet "refs/heads/$2" >/dev/null 2>&1 || { echo "FAIL:target $2 not found"; exit 0; }
        git checkout "$2" >/dev/null 2>&1 || { echo "FAIL:checkout $2 failed"; exit 0; }
        if git merge --no-ff -m "Merge $1 (approved via NightShift)" "$1" >/dev/null 2>&1; then
          if git merge-base --is-ancestor "$1" "$2"; then echo MERGED; else echo NOTREACHED; fi
        else
          git merge --abort >/dev/null 2>&1
          echo CONFLICT
        fi
        """
        let r = await Shell.run(script, args: [branch, target], cwd: projURL, timeout: 60)
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("MERGED") { return .merged }
        if out.hasPrefix("SAME") { return .sameBranch }
        if out.hasPrefix("NOTREACHED") { return .notReached }
        if out.hasPrefix("DIRTY") { return .dirty }
        if out.hasPrefix("CONFLICT") { return .conflict }
        if out.hasPrefix("FAIL:") { return .failed(String(out.dropFirst(5))) }
        return .failed(out.isEmpty ? "merge failed" : out)
    }

    func mergeToMainLocal(projectPath: String, branch: String?, target: String?, label: String) async -> MergeResult {
        guard let branch, !branch.isEmpty else { return .noBranch }
        guard let target, !target.isEmpty else { return .sameBranch }
        guard branch != target else { return .sameBranch }
        let script = """
        cur="$(git symbolic-ref --short HEAD 2>/dev/null)"
        [ -n "$cur" ] && [ "$cur" != "$1" ] && git checkout "$1" >/dev/null 2>&1
        # D-B (Codex #3): NEVER commit uncommitted work here — those bytes were not evidenced by the
        # gate. A dirty tree = un-gated changes; bail so the director sends it back to the worker to
        # commit (which re-triggers verification) rather than shipping unverified bytes.
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then echo DIRTY; exit 0; fi
        git rev-parse --verify --quiet "refs/heads/$2" >/dev/null 2>&1 || { echo "FAIL:target $2 not found"; exit 0; }
        git checkout "$2" >/dev/null 2>&1 || { echo "FAIL:checkout $2 failed"; exit 0; }
        if git merge --no-ff -m "Merge $1 (approved via NightShift)" "$1" >/dev/null 2>&1; then
          if git merge-base --is-ancestor "$1" "$2"; then echo MERGED; else echo NOTREACHED; fi
        else
          git merge --abort >/dev/null 2>&1
          echo CONFLICT
        fi
        """
        let r = await Shell.run(script, args: [branch, target, label], cwd: URL(fileURLWithPath: projectPath), timeout: 90)
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("MERGED") { return .merged }
        if out.hasPrefix("SAME") { return .sameBranch }
        if out.hasPrefix("NOTREACHED") { return .notReached }
        if out.hasPrefix("CONFLICT") { return .conflict }
        if out.hasPrefix("FAIL:") { return .failed(String(out.dropFirst(5))) }
        return .failed(out.isEmpty ? "merge failed" : out)
    }

    func isMerged(projectPath: String, branch: String, base: String) async -> Bool {
        guard !branch.isEmpty, !base.isEmpty, branch != base else { return false }
        let r = await Shell.run("git merge-base --is-ancestor \"$1\" \"$2\" && echo YES || echo NO",
                                args: [branch, base], cwd: URL(fileURLWithPath: projectPath), timeout: 20)
        return r.stdout.contains("YES")
    }

    func mergedTargetBranch(projectPath: String, branch: String, baseSHA: String?) async -> String? {
        guard !branch.isEmpty, let baseSHA, !baseSHA.isEmpty else { return nil }
        let script = """
        head="$(git rev-parse "$1" 2>/dev/null)"
        [ -z "$head" ] && exit 0
        [ "$head" = "$2" ] && exit 0   # no commits over base → work not done, not "merged"
        for b in main master develop; do
          [ "$b" = "$1" ] && continue
          git show-ref --verify --quiet "refs/heads/$b" || continue
          if git merge-base --is-ancestor "$1" "$b" 2>/dev/null; then echo "$b"; exit 0; fi
        done
        """
        let r = await Shell.run(script, args: [branch, baseSHA], cwd: URL(fileURLWithPath: projectPath), timeout: 20)
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    func openPR(projectPath: String, branch: String, target: String, title: String) async -> (ok: Bool, url: String?, message: String) {
        guard branch != target else { return (false, nil, "Reviewed branch is the target — nothing to PR") }
        let script = """
        proj="$1"; br="$2"; base="$3"; title="$4"
        command -v gh >/dev/null 2>&1 || { echo "ERR:gh CLI not installed (brew install gh)"; exit 0; }
        git -C "$proj" push -u origin "$br" >/dev/null 2>&1 || { echo "ERR:could not push $br to origin"; exit 0; }
        existing="$(gh -R "$proj" pr view "$br" --json url --jq .url 2>/dev/null)"
        if [ -n "$existing" ]; then echo "OK:$existing"; exit 0; fi
        url="$(cd "$proj" && gh pr create --base "$base" --head "$br" --title "$title" --body "Reviewed and approved via NightShift." 2>&1 | grep -Eo 'https://[^ ]+' | head -1)"
        if [ -n "$url" ]; then echo "OK:$url"; else echo "ERR:gh pr create failed (auth? remote?)"; fi
        """
        let r = await Shell.run(script, args: [projectPath, branch, target, title],
                                cwd: URL(fileURLWithPath: projectPath), timeout: 120)
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("OK:") { return (true, String(out.dropFirst(3)), "PR opened") }
        return (false, nil, out.hasPrefix("ERR:") ? String(out.dropFirst(4)) : (out.isEmpty ? "PR failed" : out))
    }
}
