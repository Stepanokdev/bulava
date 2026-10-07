import Foundation

/// The git side of a run's own copy: making one, telling whether it is still ours, reading what is
/// in it, handing its work to his branch, and taking it away.
///
/// Everything here fails closed. A copy that cannot be made stops the run — the old task path fell
/// back to his folder when `createWorktree` came back empty, which is exactly the folder a copy
/// exists to protect. A folder that is not provably ours is never adopted and never deleted.
enum WorkCopies {

    enum Failure: Error, Equatable, Sendable {
        case notARepository
        case noBase(String)
        case lowDisk(freeGB: Int)
        case createFailed(String)
        case notOurs
        case conflict([String])
        case targetDirty(String)
        case targetElsewhere(String)
        case targetMoved
        case nothingToMerge
        case gitFailed(String)
    }

    /// Below this much free space a copy is not made. A build of one of his apps writes gigabytes,
    /// and a disk that fills at 3 a.m. breaks more than the run.
    static let minimumFreeBytes: Int64 = 6 * 1_073_741_824

    /// Ignored files copied in may not add up to more than this — `.worktreeinclude` is for env
    /// files and keys, and a pattern that catches `node_modules` should not quietly copy it.
    static let includeBudgetBytes: Int64 = 64 * 1_048_576

    // MARK: Where

    nonisolated static var root: URL { base.appendingPathComponent("copies", isDirectory: true) }

    /// Build output belongs here, outside the copy, so removing a copy is never a question of
    /// gigabytes. The copy that sat on disk for six weeks held 6.6 GB of `build_dd`.
    static func buildCache(for copy: WorkCopy) -> URL {
        buildCache(named: copy.name)
    }

    static func buildCache(named folderName: String) -> URL {
        base.appendingPathComponent("build-cache", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Reports a run wrote into the copy's ignored `artifacts/` outlive the copy here.
    static func keptArtifacts(for copy: WorkCopy) -> URL {
        AppSupport.root.appendingPathComponent("copies-kept/\(copy.id.uuidString)/artifacts",
                                               isDirectory: true)
    }

    /// No spaces anywhere in it: a project whose own scripts never had to cope with a space in its
    /// path must not meet one for the first time inside a copy.
    nonisolated private static var base: URL {
        if let override = ProcessInfo.processInfo.environment["BULAVA_COPIES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // Per channel: each Bulava sweeps the copies it has no record of, and the other one's
        // copies are exactly that.
        return AppChannel.current.developerFolder()
    }

    // MARK: Git

    static func git(_ args: [String], in dir: String, timeout: TimeInterval = 60) async -> CommandResult {
        await Shell.run("git \"$@\"", args: args, cwd: URL(fileURLWithPath: dir),
                        extraEnv: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C",
                                   "GIT_OPTIONAL_LOCKS": "0"],
                        timeout: timeout)
    }

    private static func out(_ r: CommandResult) -> String {
        r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func detail(_ r: CommandResult) -> String {
        let text = r.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.suffix(600))
    }

    /// The branch a run starts from when none was named: the one the remote calls its default, then
    /// the usual names, then whatever is checked out.
    static func defaultBranch(of repo: String) async -> String? {
        let remoteHead = out(await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
                                       in: repo))
        if remoteHead.hasPrefix("origin/") {
            let name = String(remoteHead.dropFirst("origin/".count))
            if await refExists("refs/heads/\(name)", in: repo) { return name }
        }
        for name in ["main", "master", "develop"] where await refExists("refs/heads/\(name)", in: repo) {
            return name
        }
        let current = out(await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repo))
        return current.isEmpty ? nil : current
    }

    static func refExists(_ ref: String, in repo: String) async -> Bool {
        await git(["show-ref", "--verify", "--quiet", ref], in: repo).ok
    }

    static func currentBranch(of repo: String) async -> String? {
        let name = out(await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repo))
        return name.isEmpty ? nil : name
    }

    static func topLevel(of path: String) async -> String? {
        let r = await git(["rev-parse", "--show-toplevel"], in: path)
        guard r.ok else { return nil }
        let top = out(r)
        return top.isEmpty ? nil : Slug.canonicalPath(top)
    }

    // MARK: Make

    /// Where the copy with this id will be made. Known before anything is created, so the record
    /// of a copy can be written first and a sweep never meets a copy nobody wrote down.
    nonisolated static func plannedCheckoutRoot(sourceRoot: String, id: UUID) -> String {
        let short = String(id.uuidString.prefix(8)).lowercased()
        let folderName = sanitized((sourceRoot as NSString).lastPathComponent) + "-" + short
        return root.appendingPathComponent(folderName, isDirectory: true).path
    }

    /// A new copy of `sourcePath`'s repository on a branch of its own, started from `baseRef`
    /// (his default branch when nil) as it is at this moment. Made at `at` when given — an
    /// automation's own folder (`homeRoot`) — and otherwise in a folder named after `id`.
    static func make(sourcePath: String, projectID: UUID, baseRef: String?, branch wanted: String,
                     owner: WorkCopy.Owner, id: UUID = UUID(), at folder: String? = nil,
                     carry: [String] = []) async -> Result<WorkCopy, Failure> {
        let source = Slug.canonicalPath(sourcePath)
        guard let sourceRoot = await topLevel(of: source) else { return .failure(.notARepository) }

        let start: (ref: String, sha: String, branch: String)
        switch await startingPoint(baseRef, branch: wanted, in: sourceRoot) {
        case .success(let found): start = found
        case .failure(let f): return .failure(f)
        }
        let sha = start.sha, branch = start.branch

        let checkoutRoot = folder ?? plannedCheckoutRoot(sourceRoot: sourceRoot, id: id)
        guard !FileManager.default.fileExists(atPath: checkoutRoot) else {
            return .failure(.createFailed("\(checkoutRoot) already exists"))
        }
        if folder != nil {
            // An automation's folder deleted by hand leaves git's record of it behind, locked, and
            // git refuses to make a checkout where it thinks one still is.
            _ = await git(["worktree", "unlock", checkoutRoot], in: sourceRoot)
            _ = await git(["worktree", "prune"], in: sourceRoot)
        }

        let add = await git(["worktree", "add", "-b", branch, checkoutRoot, sha], in: sourceRoot, timeout: 600)
        guard add.ok, FileManager.default.fileExists(atPath: checkoutRoot) else {
            // Half a checkout is not left behind: git may have registered it before failing.
            _ = await git(["worktree", "remove", "--force", checkoutRoot], in: sourceRoot)
            _ = await git(["worktree", "prune"], in: sourceRoot)
            if await refExists("refs/heads/\(branch)", in: sourceRoot) {
                _ = await git(["branch", "-D", branch], in: sourceRoot)
            }
            return .failure(.createFailed(detail(add)))
        }
        _ = await git(["worktree", "lock", "--reason", "Bulava \(id.uuidString)", checkoutRoot], in: sourceRoot)
        await writeMarker(id: id, in: checkoutRoot)

        let relative = relativePath(of: source, under: sourceRoot)
        let path = relative.isEmpty ? checkoutRoot : (checkoutRoot as NSString).appendingPathComponent(relative)
        let copied = await copyIncludes(from: sourceRoot, to: checkoutRoot, carry: carry)
        await recordCarried(copied, in: checkoutRoot)

        return .success(WorkCopy(id: id, path: path, checkoutRoot: checkoutRoot, sourcePath: source,
                                 sourceRoot: sourceRoot, projectID: projectID, branch: branch,
                                 baseRef: start.ref, baseSHA: sha, owner: owner, state: .active,
                                 copiedFiles: copied))
    }

    /// The commit a run starts from, the name it was asked by, and a branch name nobody has yet —
    /// with the disk checked for room, as a new copy would be.
    private static func startingPoint(_ baseRef: String?, branch wanted: String,
                                      in sourceRoot: String) async -> Result<(ref: String, sha: String, branch: String), Failure> {
        guard let ref = await resolveBaseRef(baseRef, in: sourceRoot) else {
            return .failure(.noBase(baseRef ?? ""))
        }
        let shaResult = await git(["rev-parse", "--verify", "--quiet", "\(ref.full)^{commit}"], in: sourceRoot)
        let sha = out(shaResult)
        guard shaResult.ok, !sha.isEmpty else { return .failure(.noBase(ref.name)) }

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let free = freeBytes(at: root), free < minimumFreeBytes {
            return .failure(.lowDisk(freeGB: Int(free / 1_073_741_824)))
        }

        var branch = wanted
        var attempt = 2
        while await refExists("refs/heads/\(branch)", in: sourceRoot) {
            branch = "\(wanted)-\(attempt)"; attempt += 1
        }
        return .success((ref.name, sha, branch))
    }

    // MARK: An automation's own folder

    /// The one folder all of an automation's runs work in, one after another.
    ///
    /// A new copy for every run started every build from nothing — an Android app's weekly run spent
    /// its first hour on what the week before had already built — and lost what a run had set up for
    /// itself, like the `local.properties` its worker wrote. Between runs the folder is parked: on no
    /// branch, nothing git tracks left changed, its reports carried out. What git ignores — build
    /// output, local files — stays, and that is what it is kept for.
    nonisolated static func homeRoot(sourceRoot: String, automationID: UUID) -> String {
        let short = String(automationID.uuidString.prefix(8)).lowercased()
        let folderName = sanitized((sourceRoot as NSString).lastPathComponent) + "-auto-" + short
        return root.appendingPathComponent(folderName, isDirectory: true).path
    }

    /// What a parked folder's marker says. Not a copy's id, so nothing treats it as a copy — an
    /// older build's sweep included — and only this automation's next run takes it up.
    nonisolated static func parkedMarker(_ automationID: UUID) -> String { "parked:" + automationID.uuidString }

    /// The automation whose parked folder this is, read off its marker; nil for anything else.
    static func parkedOwner(of folder: String) async -> UUID? {
        guard let dir = await gitDir(of: folder),
              let marker = try? String(contentsOfFile: (dir as NSString).appendingPathComponent(markerName), encoding: .utf8)
        else { return nil }
        let text = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("parked:") else { return nil }
        return UUID(uuidString: String(text.dropFirst("parked:".count)))
    }

    /// The top of the repository a checkout belongs to — his folder, for one of his copies.
    static func repositoryRoot(ofCheckout folder: String) async -> String? {
        let common = out(await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: folder))
        guard common.hasSuffix("/.git") else { return nil }
        return Slug.canonicalPath((common as NSString).deletingLastPathComponent)
    }

    /// Whether `folder` is `automationID`'s parked folder: its marker, a checkout of its own, and a
    /// linked checkout of `sourceRoot`'s repository rather than the repository itself.
    static func isParked(_ folder: String, automationID: UUID, sourceRoot: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: folder),
              await parkedOwner(of: folder) == automationID,
              let top = await topLevel(of: folder), top == Slug.canonicalPath(folder) else { return false }
        return await isLinkedCheckout(folder, of: sourceRoot)
    }

    /// The automation's parked folder, taken up by its next run: exactly the start commit, on a
    /// branch of its own, with what git ignores left as the last run left it.
    static func adoptHome(_ home: String, automationID: UUID, sourcePath: String, projectID: UUID,
                          baseRef: String?, branch wanted: String, owner: WorkCopy.Owner, id: UUID,
                          carry: [String] = []) async -> Result<WorkCopy, Failure> {
        let source = Slug.canonicalPath(sourcePath)
        guard let sourceRoot = await topLevel(of: source) else { return .failure(.notARepository) }
        guard await isParked(home, automationID: automationID, sourceRoot: sourceRoot) else { return .failure(.notOurs) }

        let start: (ref: String, sha: String, branch: String)
        switch await startingPoint(baseRef, branch: wanted, in: sourceRoot) {
        case .success(let found): start = found
        case .failure(let f): return .failure(f)
        }
        // Whatever git tracks, or could, goes back; what it ignores stays. A run that was stopped
        // half way, or a park that did not finish, leaves nothing for this one to start on top of.
        let reset = await git(["reset", "--hard", "--quiet"], in: home, timeout: 300)
        guard reset.ok else { return .failure(.createFailed(detail(reset))) }
        let clean = await git(["clean", "-fd", "--quiet"], in: home, timeout: 300)
        guard clean.ok else { return .failure(.createFailed(detail(clean))) }
        let switched = await git(["switch", "--quiet", "--discard-changes", "-c", start.branch, start.sha],
                                 in: home, timeout: 600)
        guard switched.ok else { return .failure(.createFailed(detail(switched))) }
        await writeMarker(id: id, in: home)

        let relative = relativePath(of: source, under: sourceRoot)
        let path = relative.isEmpty ? home : (home as NSString).appendingPathComponent(relative)
        // What the last run was given from his folder goes first: switched off since, or gone from
        // his folder, it must not reach this run as a stale copy — git ignores these files, so
        // nothing above has touched them. What a run made for itself, and the build, stay.
        await dropCarried(in: home)
        let copied = await copyIncludes(from: sourceRoot, to: home, carry: carry)
        await recordCarried(copied, in: home)
        return .success(WorkCopy(id: id, path: path, checkoutRoot: home, sourcePath: source,
                                 sourceRoot: sourceRoot, projectID: projectID, branch: start.branch,
                                 baseRef: start.ref, baseSHA: start.sha, owner: owner, state: .active,
                                 copiedFiles: copied))
    }

    /// The run in the automation's folder is over, and the folder stays for the next one.
    ///
    /// The same guards as `remove`: only a folder provably ours, reports carried out first, and
    /// without `force` nothing uncommitted is thrown away. Then it goes back to no branch, and the
    /// run's branch is dealt with exactly as a removal would. A folder already parked for this
    /// automation is parked: asked twice — a quit between the two steps — it does nothing twice.
    static func park(_ copy: WorkCopy, automationID: UUID, force: Bool, branch fate: BranchFate) async -> Result<Void, Failure> {
        let folder = copy.checkoutRoot
        let exists = FileManager.default.fileExists(atPath: folder)
        if exists, !(await isParked(folder, automationID: automationID, sourceRoot: copy.sourceRoot)) {
            guard await isOurs(copy) else { return .failure(.notOurs) }
            guard preserveArtifacts(of: copy) else {
                return .failure(.gitFailed(String(localized: "Could not keep the run's reports, so its copy was left in place.")))
            }
            let status = await status(of: copy)
            guard status.inspected else {
                return .failure(.gitFailed(String(localized: "git did not say what is in the copy, so nothing was changed in it.")))
            }
            guard force || status.uncommitted.isEmpty else {
                return .failure(.gitFailed(String(localized: "The copy has changes nobody has decided about, so it was left as it is.")))
            }
            if force {
                let reset = await git(["reset", "--hard", "--quiet"], in: folder, timeout: 300)
                let clean = await git(["clean", "-fd", "--quiet"], in: folder, timeout: 300)
                guard reset.ok, clean.ok else { return .failure(.gitFailed(detail(reset.ok ? clean : reset))) }
            }
            // Marked before it leaves the branch: a quit in between leaves a folder that says whose
            // it is and is finished on the next ask, not one nothing recognises any more.
            await writeMarker(parkedMarker(automationID), in: folder)
            guard await parkedOwner(of: folder) == automationID else {
                return .failure(.gitFailed(String(localized: "Could not mark the automation's folder as free.")))
            }
        }
        // Off the branch, so the branch can go and the next run can start one of its own. Work
        // being thrown away goes from the folder too: back to where the run started.
        if exists, await currentBranch(of: folder) != nil {
            let at = force && !copy.baseSHA.isEmpty ? ["--discard-changes", copy.baseSHA] : []
            let detached = await git(["switch", "--quiet", "--detach"] + at, in: folder, timeout: 300)
            guard detached.ok else { return .failure(.gitFailed(detail(detached))) }
        }
        _ = await git(["worktree", "prune"], in: copy.sourceRoot)
        await dealWith(branch: copy.branch, of: copy, fate)
        return .success(())
    }

    /// An automation that is gone, or now works in another repository, keeps no folder. Only a
    /// folder parked for it — never one a run is in.
    @discardableResult
    static func removeHome(_ folder: String, automationID: UUID, sourceRoot: String) async -> Bool {
        guard await isParked(folder, automationID: automationID, sourceRoot: sourceRoot) else { return false }
        _ = await git(["worktree", "unlock", folder], in: sourceRoot)
        let removed = await git(["worktree", "remove", "--force", "--force", folder], in: sourceRoot, timeout: 300)
        guard removed.ok else {
            _ = await git(["worktree", "lock", "--reason", "Bulava \(parkedMarker(automationID))", folder], in: sourceRoot)
            return false
        }
        _ = await git(["worktree", "prune"], in: sourceRoot)
        try? FileManager.default.removeItem(at: buildCache(named: (folder as NSString).lastPathComponent))
        return true
    }

    private static func resolveBaseRef(_ wanted: String?, in repo: String) async -> (name: String, full: String)? {
        var name = wanted?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { name = await defaultBranch(of: repo) ?? "" }
        guard !name.isEmpty else { return nil }
        if await refExists("refs/heads/\(name)", in: repo) { return (name, "refs/heads/\(name)") }
        if await refExists("refs/remotes/origin/\(name)", in: repo) { return (name, "refs/remotes/origin/\(name)") }
        return nil
    }

    // MARK: Ours?

    private static let markerName = "bulava-copy"
    /// Which files in a checkout were copied in from his folder, so they can be taken out again.
    private static let carriedName = "bulava-carried"

    private static func recordCarried(_ files: [String], in checkout: String) async {
        guard let dir = await gitDir(of: checkout) else { return }
        let list = (dir as NSString).appendingPathComponent(carriedName)
        if files.isEmpty {
            try? FileManager.default.removeItem(atPath: list)
        } else {
            try? files.joined(separator: "\0").write(toFile: list, atomically: true, encoding: .utf8)
        }
    }

    /// Takes out every file the list says was copied in, and the list with them. Only plain files
    /// inside the checkout: a path that now leads out through a link is left alone.
    static func dropCarried(in checkout: String) async {
        guard let dir = await gitDir(of: checkout) else { return }
        let list = (dir as NSString).appendingPathComponent(carriedName)
        let fm = FileManager.default
        let names = ((try? String(contentsOfFile: list, encoding: .utf8)) ?? "")
            .split(separator: "\0").map(String.init)
        for relative in names where !relative.isEmpty && !relative.contains("..") && !relative.hasPrefix("/") {
            let path = (checkout as NSString).appendingPathComponent(relative)
            guard staysInside(path, root: checkout),
                  let attrs = try? fm.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            try? fm.removeItem(atPath: path)
        }
        try? fm.removeItem(atPath: list)
    }

    private static func gitDir(of checkout: String) async -> String? {
        let r = await git(["rev-parse", "--absolute-git-dir"], in: checkout)
        let dir = out(r)
        return r.ok && !dir.isEmpty ? dir : nil
    }

    private static func writeMarker(id: UUID, in checkout: String) async {
        await writeMarker(id.uuidString, in: checkout)
    }

    private static func writeMarker(_ text: String, in checkout: String) async {
        guard let dir = await gitDir(of: checkout) else { return }
        try? (text + "\n").write(toFile: (dir as NSString).appendingPathComponent(markerName),
                                atomically: true, encoding: .utf8)
    }

    /// Whether the folder on disk is the copy this record describes: our marker in its git
    /// metadata, a checkout of his repository and not his repository itself, on its own branch.
    /// Anything else — a folder someone put there, a copy re-pointed at another repository — is not
    /// adopted and not deleted.
    static func isOurs(_ copy: WorkCopy) async -> Bool {
        guard FileManager.default.fileExists(atPath: copy.checkoutRoot) else { return false }
        guard let dir = await gitDir(of: copy.checkoutRoot) else { return false }
        let marker = (try? String(contentsOfFile: (dir as NSString).appendingPathComponent(markerName),
                                  encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard marker == copy.id.uuidString else { return false }
        guard let top = await topLevel(of: copy.checkoutRoot),
              top == Slug.canonicalPath(copy.checkoutRoot),
              top != Slug.canonicalPath(copy.sourceRoot) else { return false }
        let common = out(await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: copy.checkoutRoot))
        let sourceCommon = out(await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: copy.sourceRoot))
        guard !common.isEmpty, Slug.canonicalPath(common) == Slug.canonicalPath(sourceCommon) else { return false }
        return await currentBranch(of: copy.checkoutRoot) == copy.branch
    }

    /// Whether `folder` is a separate checkout of `project`'s repository — a linked worktree that
    /// shares its git metadata — and not the repository itself.
    static func isLinkedCheckout(_ folder: String, of project: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: folder),
              let top = await topLevel(of: folder), let projectTop = await topLevel(of: project),
              top != projectTop else { return false }
        let mine = out(await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: folder))
        let theirs = out(await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: project))
        return !mine.isEmpty && Slug.canonicalPath(mine) == Slug.canonicalPath(theirs)
    }

    // MARK: Read

    static func status(of copy: WorkCopy) async -> WorkCopyStatus {
        guard await isOurs(copy) else { return .missing }
        let countResult = await git(["rev-list", "--count", "\(copy.baseSHA)..HEAD"], in: copy.checkoutRoot)
        let count = Int(out(countResult))
        let porcelain = await git(["status", "--porcelain=v1", "--untracked-files=all", "-z"], in: copy.checkoutRoot)
        let ignored = await git(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
                                in: copy.checkoutRoot)
        // A question git did not answer is not "nothing there": a failed count read as zero is how a
        // branch with commits of its own would be deleted as empty.
        guard countResult.ok, let count, porcelain.ok, ignored.ok else {
            return WorkCopyStatus(commitsAhead: 0, uncommitted: [], keepsakes: [], exists: true, inspected: false)
        }
        let keepsakes = ignored.stdout.split(separator: "\0").map(String.init).filter {
            !isDisposable($0, copied: copy.copiedFiles)
        }
        return WorkCopyStatus(commitsAhead: count, uncommitted: Self.porcelainPaths(porcelain.stdout),
                              keepsakes: keepsakes, exists: true, inspected: true)
    }

    /// Paths out of `git status --porcelain=v1 -z`. A rename or copy is followed by its old path as
    /// an entry of its own, with no status in front of it — read as a path, it would be cut short.
    nonisolated static func porcelainPaths(_ text: String) -> [String] {
        var out: [String] = []
        var skipNext = false
        for entry in text.split(separator: "\0", omittingEmptySubsequences: true) {
            if skipNext { skipNext = false; continue }
            let s = String(entry)
            guard s.count > 3 else { continue }
            let code = s.prefix(2)
            if code.contains("R") || code.contains("C") { skipNext = true }
            out.append(String(s.dropFirst(3)))
        }
        return out
    }

    /// The whole change a copy holds, against where it started: commits and what is not committed.
    static func diff(of copy: WorkCopy) async -> String {
        guard await isOurs(copy) else { return "" }
        _ = await git(["add", "--intent-to-add", "--all"], in: copy.checkoutRoot)
        let r = await git(["diff", "--no-color", "--stat", "--patch", copy.baseSHA], in: copy.checkoutRoot, timeout: 120)
        return r.stdout
    }

    /// Build output and the files copied in are not work; anything else ignored might be.
    /// `artifacts/` is carried out of the copy before it goes, so it does not hold the copy either.
    nonisolated static func isDisposable(_ path: String, copied: [String]) -> Bool {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if copied.contains(trimmed) { return true }
        let first = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        let last = (trimmed as NSString).lastPathComponent
        let dirs: Set<String> = ["build", "DerivedData", ".build", "node_modules", "Pods", ".gradle",
                                 "dist", "out", "target", ".next", ".turbo", "__pycache__", ".swiftpm",
                                 "xcuserdata", ".venv", "venv", ".pytest_cache", ".mypy_cache",
                                 "coverage", ".parcel-cache", ".cache", "artifacts", ".kotlin",
                                 ".idea", ".dart_tool"]
        if dirs.contains(first) || dirs.contains(last) { return true }
        if first.hasPrefix("build") || last.hasPrefix("build_") { return true }
        if last == ".DS_Store" || last.hasSuffix(".log") || last.hasSuffix(".xcuserstate") { return true }
        if trimmed.contains("/xcuserdata/") || trimmed.contains("/build/") || trimmed.contains("/.gradle/") {
            return true
        }
        return false
    }

    // MARK: Hand over

    /// Commit whatever the run left uncommitted, so its work is one branch and nothing else.
    static func commitPending(_ copy: WorkCopy, message: String) async -> Result<Void, Failure> {
        guard await isOurs(copy) else { return .failure(.notOurs) }
        let st = await status(of: copy)
        // Unanswered is not "nothing uncommitted": the work would be left out of the commit and the
        // merge after it would find nothing to hand over.
        guard st.inspected else {
            return .failure(.gitFailed(String(localized: "git did not say what is in the copy, so nothing was changed in it.")))
        }
        guard !st.uncommitted.isEmpty else { return .success(()) }
        _ = await git(["add", "--all"], in: copy.checkoutRoot)
        let commit = await git(["commit", "--quiet", "-m", message], in: copy.checkoutRoot, timeout: 120)
        guard commit.ok else { return .failure(.gitFailed(detail(commit))) }
        return .success(())
    }

    /// Move `copy.baseRef` forward to the copy's work, without switching anything he has open.
    ///
    /// The copy is first brought up to date with the branch, inside the copy, so a conflict stays
    /// there and his folder never sees a half-merged file. Then the branch moves forward only:
    /// fast-forward in his folder when it is the branch he has checked out and nothing tracked is
    /// changed there; a compare-and-swap of the ref when nobody has it checked out; and a refusal
    /// when it is open in some other checkout, where moving the ref under it would leave that
    /// checkout's files describing a different commit.
    static func merge(_ copy: WorkCopy, message: String) async -> Result<String, Failure> {
        guard await isOurs(copy) else { return .failure(.notOurs) }
        if case .failure(let f) = await commitPending(copy, message: message) { return .failure(f) }

        // A count git did not give is not zero: read as zero, the run was marked merged and its copy
        // taken for empty while the work in it had reached nobody.
        let counted = await git(["rev-list", "--count", "\(copy.baseSHA)..HEAD"], in: copy.checkoutRoot)
        guard counted.ok, let ahead = Int(out(counted)) else { return .failure(.gitFailed(detail(counted))) }
        guard ahead > 0 else { return .failure(.nothingToMerge) }

        let targetRef = "refs/heads/\(copy.baseRef)"
        let targetExists = await refExists(targetRef, in: copy.sourceRoot)
        let oldTip = targetExists ? out(await git(["rev-parse", targetRef], in: copy.sourceRoot)) : ""

        if !oldTip.isEmpty, !(await git(["merge-base", "--is-ancestor", oldTip, "HEAD"], in: copy.checkoutRoot).ok) {
            let rebase = await git(["rebase", "--quiet", oldTip], in: copy.checkoutRoot, timeout: 300)
            if !rebase.ok {
                let files = out(await git(["diff", "--name-only", "--diff-filter=U"], in: copy.checkoutRoot))
                    .split(separator: "\n").map(String.init)
                _ = await git(["rebase", "--abort"], in: copy.checkoutRoot)
                return .failure(.conflict(files))
            }
        }
        let newTip = out(await git(["rev-parse", "HEAD"], in: copy.checkoutRoot))
        guard !newTip.isEmpty else { return .failure(.gitFailed("no HEAD in the copy")) }

        let holder = await checkoutHolding(branch: copy.baseRef, in: copy.sourceRoot)
        if let holder {
            guard Slug.canonicalPath(holder) == Slug.canonicalPath(copy.sourceRoot) else {
                return .failure(.targetElsewhere(holder))
            }
            let dirty = out(await git(["status", "--porcelain", "--untracked-files=no"], in: copy.sourceRoot))
            guard dirty.isEmpty else { return .failure(.targetDirty(copy.baseRef)) }
            // `merge --ff-only` moves whatever branch is checked out. Asked again at the last
            // moment: if he switched branches since, the merge would land on the wrong one.
            guard await currentBranch(of: copy.sourceRoot) == copy.baseRef else { return .failure(.targetMoved) }
            let ff = await git(["merge", "--ff-only", "--quiet", newTip], in: copy.sourceRoot, timeout: 300)
            guard ff.ok else { return .failure(.gitFailed(detail(ff))) }
        } else {
            let update = await git(["update-ref", "-m", "Bulava: \(message)", targetRef, newTip,
                                    targetExists ? oldTip : String(repeating: "0", count: 40)],
                                   in: copy.sourceRoot)
            guard update.ok else { return .failure(.targetMoved) }
        }
        // Said only once it is true of the branch itself.
        let landed = out(await git(["rev-parse", targetRef], in: copy.sourceRoot))
        guard landed == newTip else { return .failure(.targetMoved) }
        return .success(newTip)
    }

    /// Which checkout has `branch` open, if any — his folder, another worktree, or nobody.
    static func checkoutHolding(branch: String, in repo: String) async -> String? {
        let list = await git(["worktree", "list", "--porcelain"], in: repo)
        var current: String?
        for line in list.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { current = String(line.dropFirst("worktree ".count)) }
            if line == "branch refs/heads/\(branch)" { return current }
        }
        return nil
    }

    /// The commit the copy stands on.
    static func tip(of copy: WorkCopy) async -> String? {
        let r = await git(["rev-parse", "HEAD"], in: copy.checkoutRoot)
        let sha = out(r)
        return r.ok && !sha.isEmpty ? sha : nil
    }

    /// Whether every commit in the copy is already on its base branch.
    static func isIntegrated(_ copy: WorkCopy) async -> Bool {
        guard await isOurs(copy) else { return false }
        return await git(["merge-base", "--is-ancestor", "HEAD", "refs/heads/\(copy.baseRef)"],
                         in: copy.checkoutRoot).ok
    }

    // MARK: Take away

    enum BranchFate: Sendable { case deleteIfIntegrated, delete, keep }

    /// Remove the copy's folder and, if told to, its branch.
    ///
    /// Only a copy that is provably ours. `artifacts/` is carried out first. Without `force`, git
    /// itself refuses a copy with uncommitted work, which is the last guard behind the caller's
    /// own checks.
    static func remove(_ copy: WorkCopy, force: Bool, branch fate: BranchFate) async -> Result<Void, Failure> {
        if FileManager.default.fileExists(atPath: copy.checkoutRoot) {
            guard await isOurs(copy) else { return .failure(.notOurs) }
            // A report that could not be carried out keeps its copy: the folder is the only place
            // it is.
            guard preserveArtifacts(of: copy) else {
                return .failure(.gitFailed(String(localized: "Could not keep the run's reports, so its copy was left in place.")))
            }
            _ = await git(["worktree", "unlock", copy.checkoutRoot], in: copy.sourceRoot)
            var args = ["worktree", "remove"]
            if force { args += ["--force", "--force"] }
            args.append(copy.checkoutRoot)
            let removed = await git(args, in: copy.sourceRoot, timeout: 300)
            guard removed.ok else {
                _ = await git(["worktree", "lock", "--reason", "Bulava \(copy.id.uuidString)", copy.checkoutRoot],
                              in: copy.sourceRoot)
                return .failure(.gitFailed(detail(removed)))
            }
        }
        _ = await git(["worktree", "prune"], in: copy.sourceRoot)
        await dealWith(branch: copy.branch, of: copy, fate)
        try? FileManager.default.removeItem(at: buildCache(for: copy))
        return .success(())
    }

    private static func dealWith(branch: String, of copy: WorkCopy, _ fate: BranchFate) async {
        guard !branch.isEmpty, await refExists("refs/heads/\(branch)", in: copy.sourceRoot) else { return }
        switch fate {
        case .keep:
            break
        case .delete:
            _ = await git(["branch", "-D", branch], in: copy.sourceRoot)
        case .deleteIfIntegrated:
            if await git(["merge-base", "--is-ancestor", "refs/heads/\(branch)",
                          "refs/heads/\(copy.baseRef)"], in: copy.sourceRoot).ok {
                _ = await git(["branch", "-D", branch], in: copy.sourceRoot)
            }
        }
    }

    /// Every `artifacts/` the status treats as disposable — the project's own, and the
    /// repository's when the project is a subfolder of it — moved out next to the others. Returns
    /// false when one could not be kept.
    private static func preserveArtifacts(of copy: WorkCopy) -> Bool {
        let fm = FileManager.default
        var folders = [URL(fileURLWithPath: copy.path).appendingPathComponent("artifacts", isDirectory: true)]
        if Slug.canonicalPath(copy.path) != Slug.canonicalPath(copy.checkoutRoot) {
            folders.append(URL(fileURLWithPath: copy.checkoutRoot).appendingPathComponent("artifacts", isDirectory: true))
        }
        let keep = keptArtifacts(for: copy)
        for (index, folder) in folders.enumerated() {
            guard fm.fileExists(atPath: folder.path) else { continue }
            // There but unreadable is not empty: the copy stays rather than take a report with it.
            guard let items = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
            guard !items.isEmpty else { continue }
            // A name not taken yet: an earlier preservation is never overwritten.
            var target = index == 0 ? keep : keep.deletingLastPathComponent().appendingPathComponent("artifacts-root")
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = keep.deletingLastPathComponent().appendingPathComponent("artifacts-\(n)"); n += 1
            }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fm.moveItem(at: folder, to: target)) == nil {
                    try fm.copyItem(at: folder, to: target)
                }
            } catch {
                return false
            }
        }
        return true
    }

    /// A copy recorded before its branch was known — Bulava quit while making it. Taken away when
    /// its folder carries our marker for this id, whatever its record lacks. True when nothing of it
    /// is left on disk.
    static func takeAwayHalfMade(_ placeholder: WorkCopy) async -> Bool {
        guard FileManager.default.fileExists(atPath: placeholder.checkoutRoot) else {
            _ = await git(["worktree", "prune"], in: placeholder.sourceRoot)
            return true
        }
        guard let dir = await gitDir(of: placeholder.checkoutRoot),
              (try? String(contentsOfFile: (dir as NSString).appendingPathComponent(markerName), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == placeholder.id.uuidString else { return false }
        var found = placeholder
        found.branch = await currentBranch(of: placeholder.checkoutRoot) ?? ""
        found.baseSHA = out(await git(["rev-parse", "HEAD"], in: placeholder.checkoutRoot))
        found.baseRef = found.branch
        guard !found.branch.isEmpty else { return false }
        if case .failure = await remove(found, force: true, branch: .delete) { return false }
        return !FileManager.default.fileExists(atPath: placeholder.checkoutRoot)
    }

    // MARK: Ignored files he wants in every copy

    /// Claude Code's `.worktreeinclude`, read the same way: a file is copied when it matches a line
    /// AND git ignores it, so nothing tracked is ever duplicated. `carry` adds files an automation
    /// was set to bring along — the same rule: only what git ignores. Symlinks are not followed, the
    /// total is capped, and a file already in the copy (the automation's folder, from its last run)
    /// is replaced with his current one.
    static func copyIncludes(from sourceRoot: String, to checkoutRoot: String, carry: [String] = []) async -> [String] {
        var candidates: [String] = []
        let list = (sourceRoot as NSString).appendingPathComponent(".worktreeinclude")
        if FileManager.default.fileExists(atPath: list) {
            let matching = await git(["ls-files", "--others", "--ignored", "--exclude-from=.worktreeinclude", "-z"],
                                     in: sourceRoot)
            candidates = matching.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        }
        for path in carry where !path.isEmpty && !candidates.contains(path) { candidates.append(path) }
        guard !candidates.isEmpty else { return [] }
        let ignoredCheck = await Shell.run("printf '%s\\0' \"$@\" | git check-ignore -z --stdin",
                                           args: candidates, cwd: URL(fileURLWithPath: sourceRoot),
                                           extraEnv: ["GIT_TERMINAL_PROMPT": "0"])
        let ignored = Set(ignoredCheck.stdout.split(separator: "\0").map(String.init))

        let fm = FileManager.default
        var copied: [String] = []
        var spent: Int64 = 0
        for relative in candidates where ignored.contains(relative) {
            guard !relative.contains(".."), !relative.hasPrefix("/") else { continue }
            let from = (sourceRoot as NSString).appendingPathComponent(relative)
            guard let attrs = try? fm.attributesOfItem(atPath: from),
                  attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard spent + size <= includeBudgetBytes else { continue }
            let to = (checkoutRoot as NSString).appendingPathComponent(relative)
            // A run can leave an ignored link in the automation's folder that leads back into his:
            // replacing a file through it would delete his own.
            guard staysInside(to, root: checkoutRoot) else { continue }
            try? fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            if let existing = try? fm.attributesOfItem(atPath: to) {
                guard existing[.type] as? FileAttributeType == .typeRegular else { continue }
                try? fm.removeItem(atPath: to)
            }
            if (try? fm.copyItem(atPath: from, toPath: to)) != nil {
                copied.append(relative); spent += size
            }
        }
        return copied
    }

    /// Whether writing `path` stays inside `root`: nothing of it that exists already leads out
    /// through a link, and the file itself is not one.
    nonisolated static func staysInside(_ path: String, root: String) -> Bool {
        let fm = FileManager.default
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        var probe = (path as NSString).deletingLastPathComponent
        while !fm.fileExists(atPath: probe), probe != "/" { probe = (probe as NSString).deletingLastPathComponent }
        let real = URL(fileURLWithPath: probe).resolvingSymlinksInPath().path
        guard real == realRoot || real.hasPrefix(realRoot + "/") else { return false }
        if let attrs = try? fm.attributesOfItem(atPath: path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink { return false }
        return true
    }

    /// Files in his folder that git ignores and a build usually cannot do without — an SDK path,
    /// keys, an env file — and that `.worktreeinclude` does not already bring. A run has none of
    /// them unless they are brought in: an Android app's worker wrote its own `local.properties`
    /// because the copy had none.
    static func localConfigFiles(in sourcePath: String) async -> [String] {
        guard let sourceRoot = await topLevel(of: sourcePath) else { return [] }
        let ignored = await git(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
                                in: sourceRoot)
        guard ignored.ok else { return [] }
        let already = Set(await copyIncludesList(in: sourceRoot))
        let fm = FileManager.default
        return ignored.stdout.split(separator: "\0").map(String.init).filter { path in
            guard !path.hasSuffix("/"), path.split(separator: "/").count <= 3,
                  !already.contains(path), isLocalConfig(path),
                  !isDisposable(path, copied: []) else { return false }
            let full = (sourceRoot as NSString).appendingPathComponent(path)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  ((attrs[.size] as? NSNumber)?.int64Value ?? 0) <= 1_048_576 else { return false }
            return true
        }.sorted()
    }

    private static func copyIncludesList(in sourceRoot: String) async -> [String] {
        guard FileManager.default.fileExists(atPath: (sourceRoot as NSString).appendingPathComponent(".worktreeinclude"))
        else { return [] }
        let r = await git(["ls-files", "--others", "--ignored", "--exclude-from=.worktreeinclude", "-z"], in: sourceRoot)
        return r.stdout.split(separator: "\0").map(String.init)
    }

    /// A name that is a machine's or a person's settings rather than the project's.
    nonisolated static func isLocalConfig(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let exact: Set<String> = ["local.properties", "secrets.properties", "keystore.properties",
                                  "gradle.properties", ".env", ".npmrc", "GoogleService-Info.plist",
                                  "google-services.json", "Secrets.plist"]
        if exact.contains(name) { return true }
        if name.hasPrefix(".env."), !name.hasSuffix(".example"), !name.hasSuffix(".sample") { return true }
        return name.hasSuffix(".xcconfig")
    }

    // MARK: Helpers

    nonisolated static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    nonisolated static func sanitized(_ name: String) -> String {
        var out = ""
        var lastWasDash = false
        for ch in name {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == ".") {
                out.append(ch); lastWasDash = false
            } else if !lastWasDash {
                out.append("-"); lastWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "repo" : String(trimmed.prefix(40))
    }

    /// A branch name for a piece of text: lowercase ASCII words joined by dashes.
    nonisolated static func branchSlug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        var out = ""
        var lastWasDash = false
        for ch in Transliteration.latin(folded) {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch); lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-"); lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "run" : String(out.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    nonisolated static func relativePath(of path: String, under root: String) -> String {
        let p = Slug.canonicalPath(path), r = Slug.canonicalPath(root)
        guard p != r, p.hasPrefix(r + "/") else { return "" }
        return String(p.dropFirst(r.count + 1))
    }
}

/// Cyrillic to Latin, for branch names made from his Ukrainian titles. Git takes any bytes, but a
/// branch called `bulava/moдeli` is one nobody can type.
nonisolated enum Transliteration {
    static func latin(_ text: String) -> String {
        if let latin = text.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) {
            return latin
        }
        return text
    }
}
