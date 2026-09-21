import SwiftUI
import AppKit
import AVFoundation
import UserNotifications
import CoreGraphics
import ApplicationServices

// MARK: - Model

nonisolated struct PreflightCheck: Identifiable, Sendable {
    enum Status: Sendable, Equatable {
        case ready
        case missing

        case unknown
        case checking
    }

    enum Gate: String, Sendable, Equatable, Codable {

        case allWork

        case pullRequests

        case appDriving

        case affectedWork

        case convenience
    }

    var id: String
    var titleKey: String
    var detailKey: String
    var status: Status

    var evidence: String?
    /// A sentence worked out when the screen is drawn rather than written in advance — what is
    /// holding the engine right now, say. Shown as it is, not looked up as a key.
    var note: String?
    var gate: Gate = .allWork

    var settingsURL: String?

    enum Fix: Sendable, Equatable {

        case trustFolders([String])

        /// Copy the engine out of the app and let it install itself.
        case installEngine

        /// Install missing command-line tools with Homebrew, visibly.
        case brew([String])

        /// Install something Homebrew ships as a cask — the agent CLIs are distributed that way,
        /// as a binary their vendor signed and Apple notarised.
        case brewCask([String])

        /// Run a sign-in command in Terminal. A login cannot be automated, and pretending
        /// otherwise would leave someone staring at a spinner.
        case signIn(command: String)

        /// Show a file in Finder. Moving an application someone installed is their decision, not
        /// the application's — this puts it under their cursor and stops there.
        case revealInFinder(String)

        /// Ask macOS for Screen Recording, rather than pointing at the list and hoping.
        ///
        /// Pointing was all this screen could do, and it was not enough: the switch for Bulava can
        /// be ON while the grant on file belongs to a differently-signed build of the same bundle,
        /// after which every capture is refused and the list says everything is fine. Somebody
        /// following the link finds nothing to change. `CGRequestScreenCaptureAccess` makes macOS
        /// re-decide and, when it has nothing valid on file, show its own dialog.
        case askForScreenRecording
    }
    var fix: Fix?

    var required: Bool { gate == .allWork }

    var unmet: Bool { status == .missing || status == .unknown }
}

@MainActor
@Observable
final class PreflightRunner {
    private(set) var checks: [PreflightCheck] = []
    private(set) var running = false
    private(set) var lastRun: Date?

    var blocking: [PreflightCheck] { checks.filter { $0.required && $0.status == .missing } }

    var unresolved: [PreflightCheck] { checks.filter { $0.required && $0.status == .unknown } }

    var optional: [PreflightCheck] { checks.filter { !$0.required && $0.status != .ready } }

    var isReady: Bool { !checks.isEmpty && blocking.isEmpty && unresolved.isEmpty }

    nonisolated struct Summary: Sendable, Equatable {
        var allWork: [String] = []
        var pullRequests: [String] = []
        var appDriving: [String] = []

        var affectedWork: [String] = []
        var isEmpty: Bool {
            allWork.isEmpty && pullRequests.isEmpty && appDriving.isEmpty && affectedWork.isEmpty
        }
    }

    var summary: Summary {
        var out = Summary()
        for check in checks where check.unmet {
            let label = String(localized: check.titleKey)
            switch check.gate {
            case .allWork:      out.allWork.append(label)
            case .pullRequests: out.pullRequests.append(label)
            case .appDriving:   out.appDriving.append(label)
            case .affectedWork: out.affectedWork.append(label)
            case .convenience:  break
            }
        }
        return out
    }

    nonisolated static func reasonsBlockingDispatch(summary: Summary,
                                                    deliversPullRequest: Bool,
                                                    needsAppDriving: Bool) -> [String] {
        var reasons = summary.allWork
        if deliversPullRequest { reasons += summary.pullRequests }
        if needsAppDriving { reasons += summary.appDriving }
        return reasons
    }

    func overrideChecksForTesting(_ checks: [PreflightCheck]) { self.checks = checks }

    /// How much of the readiness check to actually run.
    ///
    /// Two of these checks are not reads — they are paid calls to Claude and to Codex, and the
    /// Codex one costs about sixteen thousand input tokens. They used to run on the periodic
    /// refresh, every twenty minutes, forever: forty-five Codex sessions on an ordinary day, none
    /// of them asked for, all of them out of the same weekly quota as the real work.
    ///
    /// A subscription that answered does not stop answering on a twenty-minute timescale, so the
    /// answer is cached and the background refresh reuses it. It is re-proven when someone opens
    /// the readiness screen, when work is about to start, and once the cache is a day old.
    nonisolated enum Depth: Sendable {
        /// Everything, including the two paid probes.
        case full
        /// Only the free checks; the last proven verdict for the paid ones is carried forward.
        case free
    }

    nonisolated static let paidProbeTTL: TimeInterval = 24 * 60 * 60

    /// The last verdicts from the paid probes, and when they were proven.
    private var provenAnswers: [String: PreflightCheck] = [:]
    private var provenAt: Date?

    nonisolated static func paidProbesAreDue(provenAt: Date?, now: Date = Date(),
                                             depth: Depth) -> Bool {
        if depth == .full { return true }
        guard let provenAt else { return true }
        return now.timeIntervalSince(provenAt) >= paidProbeTTL
    }

    func run(model: AppModel, depth: Depth = .full) async {
        guard !running else { return }
        running = true
        defer { running = false; lastRun = Date() }

        let probe = Self.paidProbesAreDue(provenAt: provenAt, depth: depth)

        var out: [PreflightCheck] = []
        out.append(engineCheck(model: model))

        out.append(await agentCheck(
            id: "claude-auth", foundAt: await onPath("claude"), cask: "claude-code", probe: probe,
            missingTitleKey: "Claude is not installed",
            missingDetailKey: "Bulava runs work through the Claude CLI on your subscription, and cannot start any work without it. Homebrew has the signed build.",
            run: claudeAnswersCheck))
        out.append(await agentCheck(
            id: "codex-auth", foundAt: await onPath("codex"), cask: "codex", probe: probe,
            missingTitleKey: "Codex is not installed",
            missingDetailKey: "Codex independently reviews finished work before you see it. Homebrew has the build OpenAI signed and Apple notarised.",
            run: codexAnswersCheck))
        out.append(await toolCheck(name: "jq", titleKey: "jq is installed",
                                   detailKey: "The engine reads and writes its own state through it. Without jq a run cannot start.",
                                   brewFormula: "jq"))
        out.append(await toolCheck(name: "python3", titleKey: "python3 is available",
                                   detailKey: "Most of the engine's own tooling is written in it.",
                                   brewFormula: "python"))
        out.append(await toolCheck(name: "tmux", titleKey: "tmux is installed",
                                   detailKey: "Each worker runs in its own session so a run survives the app closing.",
                                   brewFormula: "tmux"))
        out.append(await toolCheck(name: "git", titleKey: "git is available",
                                   detailKey: "Needed to branch, diff and merge work."))
        out.append(await githubCheck())
        out.append(folderCheck(model: model))
        out.append(trustCheck(model: model))
        out.append(accessibilityCheck())
        out.append(screenRecordingCheck())
        out.append(oldCopyCheck())
        out.append(await browserCheck())
        out.append(await notificationCheck())
        out.append(microphoneCheck())
        checks = out
    }

    // MARK: The paid probes, and remembering their answer

    /// Run a paid probe, or hand back the last verdict it gave.
    ///
    /// A remembered verdict is only ever a `ready` one. A failure is not cached: if Codex did not
    /// answer, the next refresh has to ask again — that is the case where the reader is waiting
    /// for the state to change.
    private func answersCheck(id: String, probe: Bool,
                              run: () async -> PreflightCheck) async -> PreflightCheck {
        if !probe, let remembered = provenAnswers[id] {
            return remembered
        }
        let fresh = await run()
        if fresh.status == .ready {
            provenAnswers[id] = fresh
            // Both probes stamp the same clock, so one of them failing keeps the other honest
            // about its age too.
            provenAt = Date()
        } else {
            provenAnswers[id] = nil
            provenAt = nil
        }
        return fresh
    }

    // MARK: Individual checks

    private func trustCheck(model: AppModel) -> PreflightCheck {

        let paths = Set(model.products.products
            .flatMap(\.resources)
            .compactMap(\.projectID)
            .compactMap { model.projects.project(id: $0)?.path })

        let untrustedFolders = Set(paths.compactMap { ClaudeFolderTrust.folderNeedingTrust(forProjectPath: $0) })
            .sorted()
        let untrusted = untrustedFolders.map { ($0 as NSString).lastPathComponent }
        guard !untrusted.isEmpty else {
            return PreflightCheck(id: "folder-trust", titleKey: "Folders are trusted",
                                  detailKey: "Claude Code can start work in every connected folder without asking first.",
                                  status: .ready, gate: .affectedWork)
        }
        return PreflightCheck(id: "folder-trust",
                              titleKey: "Claude Code will ask about a folder",
                              detailKey: "A worker cannot answer that dialog, so work in these folders would stop on it. Answering it here is the same yes.",
                              status: .missing,
                              evidence: untrusted.joined(separator: ", "),
                              gate: .affectedWork,
                              fix: .trustFolders(untrustedFolders))
    }

    /// Said before the button is pressed rather than after it refuses.
    private func engineHeldNote(model: AppModel) -> String? {
        guard let blocker = model.engineBlocker else { return nil }
        return String(format: String(localized: "Cannot be replaced while %@."), blocker.text)
    }

    private func engineCheck(model: AppModel) -> PreflightCheck {
        switch EngineInstaller.state() {
        case .development(let url):
            return PreflightCheck(id: "engine", titleKey: "The work engine is installed",
                                  detailKey: "Running from your own checkout — your edits to it take effect directly.",
                                  status: .ready, evidence: url.path)
        case .ready(let url):
            return PreflightCheck(id: "engine", titleKey: "The work engine is installed",
                                  detailKey: "Bulava drives this to run and review work.",
                                  status: .ready, evidence: url.path)
        case .stale(let url):
            return PreflightCheck(id: "engine", titleKey: "The work engine is from an older version",
                                  detailKey: "Bulava calls it by name and reads its answers, so a mismatched copy misreports work. Install the one this version shipped with.",
                                  status: .missing, evidence: url.path,
                                  note: engineHeldNote(model: model), fix: .installEngine)
        case .notInstalled:
            return PreflightCheck(id: "engine", titleKey: "The work engine is not installed yet",
                                  detailKey: "It comes inside Bulava. Installing it also puts night-shift on your PATH for the terminal.",
                                  status: .missing, note: engineHeldNote(model: model),
                                  fix: .installEngine)
        case .unavailable:
            return PreflightCheck(id: "engine", titleKey: "The work engine is missing",
                                  detailKey: "Bulava cannot start any work without it.",
                                  status: .missing)
        }
    }

    private func onPath(_ name: String) async -> String {
        let result = await Shell.run("command -v \"$1\" 2>/dev/null || true", args: [name], timeout: 10)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toolCheck(name: String, titleKey: String, detailKey: String,
                           gate: PreflightCheck.Gate = .allWork,
                           brewFormula: String? = nil) async -> PreflightCheck {
        let path = await onPath(name)
        if path.isEmpty {
            return PreflightCheck(id: "tool-\(name)", titleKey: titleKey, detailKey: detailKey,
                                  status: .missing, evidence: String(localized: "not on PATH"),
                                  gate: gate,
                                  fix: brewFormula.map { .brew([$0]) })
        }
        return PreflightCheck(id: "tool-\(name)", titleKey: titleKey, detailKey: detailKey,
                              status: .ready, evidence: path, gate: gate)
    }

    /// One row, and one thing to do, for an agent CLI.
    ///
    /// It used to be two: "Codex is installed" and "Codex answers" were separate checks, so a Mac
    /// without Codex showed two red rows saying the same thing — and, once both learned to offer a
    /// button, two identical buttons. Worse, the second row got there by making the paid call
    /// anyway, against a command the first row had just established was not there.
    ///
    /// So the question is asked in order: is it here, and only then does it answer.
    func agentCheck(id: String, foundAt: String, cask: String, probe: Bool,
                    missingTitleKey: String, missingDetailKey: String,
                    run: () async -> PreflightCheck) async -> PreflightCheck {
        guard !foundAt.isEmpty else {
            return PreflightCheck(id: id, titleKey: missingTitleKey, detailKey: missingDetailKey,
                                  status: .missing, evidence: String(localized: "not on PATH"),
                                  fix: .brewCask([cask]))
        }
        return await answersCheck(id: id, probe: probe, run: run)
    }

    /// What a CLI's failure actually proves.
    ///
    /// Every case here is a phrase the failing program itself printed, and nothing is inferred
    /// from the absence of one. The first version of this guessed: anything mentioning a missing
    /// file was reported as "not installed", an unrecognised failure was reported as "installed
    /// and signed in, this is a rate limit", and every broken binary was blamed on XProtect by
    /// name. Three different walls wearing one label is what this screen exists to prevent, and a
    /// confident wrong label wastes an evening more thoroughly than an honest `unknown`.
    ///
    /// `launched` is no help in telling them apart — it is about `/bin/zsh`, which starts whether
    /// or not the thing it was asked to run exists. A missing command is a live shell reporting
    /// 127.
    nonisolated enum ProbeFailure: Equatable {
        /// The shell said so: exit 127, or "command not found".
        case notOnPath
        /// The launcher is there and the program it runs is not — node's `spawn … ENOENT`. What
        /// an npm-installed Codex looks like after macOS removes its Mach-O, and equally what a
        /// half-finished install looks like. Which of the two it is, this cannot tell.
        case executableMissing
        /// A binary built for a different processor.
        case wrongArchitecture
        /// macOS refused to run it and said why — malware signature, damaged, unverified
        /// developer. This is the only case that may name Gatekeeper or XProtect, because this is
        /// the only case where they named themselves.
        case blockedBySystem
        /// The program said the account is the problem.
        case notSignedIn
        /// It failed and did not say anything this knows how to read. Reported as exactly that.
        case unknown
    }

    nonisolated static func classify(exitCode: Int32, output: String) -> ProbeFailure {
        let text = output.lowercased()

        // The shell's own verdict. 127 is not ambiguous whatever the rest of the line says.
        if exitCode == 127 || text.contains("command not found") { return .notOnPath }

        // Apple's wording, when macOS is the one refusing. Checked before the missing-file signs:
        // a binary that XProtect has just moved to the Trash is missing BECAUSE of this, and the
        // reason is the useful half. Whole phrases, not "is damaged" on its own — a CLI says that
        // about its own cache.
        for sign in ["contains malware", "is damaged and can", "was not opened because",
                     "cannot be opened because", "developer cannot be verified"]
        where text.contains(sign) { return .blockedBySystem }

        if text.contains("bad cpu type") || text.contains("wrong architecture") {
            return .wrongArchitecture
        }

        // Node's report that the program this wrapper exists to launch is not there, which is a
        // FAILED SPAWN and nothing else. Bare "enoent" is not enough — a CLI raises it about its
        // own config file too — and neither is "no such file or directory", which it says about
        // working directories and arguments. Reading either as a missing install was a guess, and
        // it sent people to reinstall a CLI that was sitting right there.
        if text.contains("enoent"), text.contains("spawn") { return .executableMissing }

        // Phrases that assert an account problem, not merely mention a word that appears in one.
        // `please run /login` and `login expired` are Claude Code's own, and they are here because
        // of where they turn up: the CLI answers an expired login by REPLYING with that sentence,
        // so it arrives looking like the worker's answer to the question rather than like an
        // error. See `isSignInNotice`.
        // Bare "oauth" was here and had to go: "OAuth endpoint unavailable" is an outage, and it
        // was being offered a Sign in button.
        for sign in ["oauth token", "oauth session", "not logged in", "not logged into",
                     "failed to authenticate", "authentication failed", "not authenticated",
                     "unauthorized", "session expired", "login expired", "please run /login",
                     "invalid api key", "please log in", "please sign in",
                     "credentials are invalid", "401 "]
        where text.contains(sign) { return .notSignedIn }

        return .unknown
    }

    /// Is this the CLI telling the reader to sign in, dressed up as an answer?
    ///
    /// Claude Code does not fail when its login has run out. It replies — "Login expired · Please
    /// run /login" — and Bulava put that in the conversation as if the worker had said it. `/login`
    /// is a command inside the CLI's own terminal, which the reader of a chat window does not have,
    /// so the first person to meet this asked where he was supposed to type it and then deleted the
    /// conversation.
    ///
    /// Matched on the CLI's whole sentence — `<reason> · Please run /login` — and nothing looser.
    ///
    /// This takes a message off the screen, so it has to be the CLI and not a worker discussing it.
    /// Every broader rule tried here hid a real answer: matching the subject hid "The OAuth flow
    /// refreshes the token before it expires", and matching the tail alone hid "Please run /login,
    /// then retry". Requiring the separator AND the sentence ending there leaves only what Claude
    /// Code actually emits. A wording nobody has seen stays on screen, which is where it is today.
    nonisolated static func isSignInNotice(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120, !trimmed.contains("\n"),
              trimmed.contains("·") else { return false }
        let lower = trimmed.lowercased()
        return lower.hasSuffix("please run /login") || lower.hasSuffix("please run /login.")
    }

    private func claudeAnswersCheck() async -> PreflightCheck {
        let probe = await Shell.run(
            "printf '%s' \"$1\" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude -p --tools '' --strict-mcp-config 2>&1",
            args: ["reply with the single word: ok"],
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()), timeout: 45)
        let reply = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if probe.launched, probe.exitCode == 0, reply.lowercased().contains("ok") {
            return PreflightCheck(id: "claude-auth", titleKey: "Claude answers",
                                  detailKey: "A real one-shot call came back, so the subscription is live.",
                                  status: .ready, evidence: String(reply.prefix(120)))
        }
        let output = reply.isEmpty ? probe.combined : reply
        let evidence = String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard probe.launched else {
            return PreflightCheck(id: "claude-auth", titleKey: "Claude could not be asked",
                                  detailKey: "Bulava could not start a shell to reach the CLI.",
                                  status: .missing, evidence: probe.stderr.trimmedTail)
        }
        return claudeFailureRow(Self.classify(exitCode: probe.exitCode, output: output),
                               evidence: evidence)
    }

    private func codexAnswersCheck() async -> PreflightCheck {
        // There is no file to look for first. Checking ~/.codex/auth.json used to gate this, and
        // it marked a perfectly working machine as broken: Codex also keeps its credentials in the
        // Keychain, and CODEX_HOME moves the whole directory. The call itself is the only honest
        // test of whether reviews can run.
        //
        // `low` and `--ephemeral`, explicitly. Without an effort the CLI takes the one in
        // ~/.codex/config.toml — `xhigh` on this machine — so the cheapest question the app ever
        // asks was being asked at the most expensive setting. Ephemeral also stops a liveness
        // check from filing a session on disk beside the real conversations.
        let probe = await Shell.run(
            "codex exec --sandbox read-only --skip-git-repo-check --ephemeral"
            + " -c model_reasoning_effort=\"low\" \"$1\" 2>&1",
            args: ["reply with the single word: ok"],
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()), timeout: 90)
        let reply = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if probe.launched, probe.exitCode == 0, !reply.isEmpty {
            return PreflightCheck(id: "codex-auth", titleKey: "Codex answers",
                                  detailKey: "A real read-only call came back, so reviews can run.",
                                  status: .ready, evidence: String(reply.suffix(120)))
        }
        let output = reply.isEmpty ? probe.combined : reply
        let evidence = String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard probe.launched else {
            return PreflightCheck(id: "codex-auth", titleKey: "Codex could not be asked",
                                  detailKey: "Bulava could not start a shell to reach the CLI.",
                                  status: .missing, evidence: probe.stderr.trimmedTail)
        }
        return codexFailureRow(Self.classify(exitCode: probe.exitCode, output: output),
                               evidence: evidence)
    }

    /// The row for every way Claude can fail once it IS on PATH. Lifted out of the probe so
    /// each state can be asked for by name — one row, one thing to do, and nothing claimed that
    /// the output did not say.
    func claudeFailureRow(_ failure: ProbeFailure, evidence: String) -> PreflightCheck {
        switch failure {
        case .notOnPath, .executableMissing:
            return PreflightCheck(id: "claude-auth", titleKey: "Claude will not run",
                                  detailKey: "The launcher is on PATH and the program it starts is not there — an install that did not finish, or a file removed since. Installing it again puts the missing file back.",
                                  status: .missing, evidence: evidence,
                                  fix: .brewCask(["claude-code"]))
        case .blockedBySystem:
            return PreflightCheck(id: "claude-auth", titleKey: "macOS blocked Claude",
                                  detailKey: "macOS refused to run it and gave its reason below: a malware signature, a damaged file, or a developer it cannot verify. The Homebrew build is signed by its vendor and notarised by Apple, which is what that check looks for.",
                                  status: .missing, evidence: evidence,
                                  fix: .brewCask(["claude-code"]))
        case .wrongArchitecture:
            return PreflightCheck(id: "claude-auth", titleKey: "Claude is built for a different Mac",
                                  detailKey: "The installed binary was made for another processor. Installing it again through Homebrew fetches the one this Mac runs.",
                                  status: .missing, evidence: evidence,
                                  fix: .brewCask(["claude-code"]))
        case .notSignedIn:
            return PreflightCheck(id: "claude-auth", titleKey: "Claude is not signed in",
                                  detailKey: "It says the account is the problem. Signing in happens in a terminal — a login cannot be done for you.",
                                  status: .missing, evidence: evidence,
                                  fix: .signIn(command: "claude auth login"))
        case .unknown:
            return PreflightCheck(id: "claude-auth", titleKey: "Claude does not answer",
                                  detailKey: "The call failed and the output does not say why, so Bulava will not guess. What it printed is below.",
                                  status: .missing, evidence: evidence)
        }
    }

    /// The row for every way Codex can fail once it IS on PATH. Lifted out of the probe so
    /// each state can be asked for by name — one row, one thing to do, and nothing claimed that
    /// the output did not say.
    func codexFailureRow(_ failure: ProbeFailure, evidence: String) -> PreflightCheck {
        switch failure {
        case .notOnPath, .executableMissing:
            return PreflightCheck(id: "codex-auth", titleKey: "Codex will not run",
                                  detailKey: "The launcher is on PATH and the program it starts is not there — an install that did not finish, or a file removed since. Installing it again puts the missing file back.",
                                  status: .missing, evidence: evidence,
                                  fix: .brewCask(["codex"]))
        case .blockedBySystem:
            return PreflightCheck(id: "codex-auth", titleKey: "macOS blocked Codex",
                                  detailKey: "macOS refused to run it and gave its reason below: a malware signature, a damaged file, or a developer it cannot verify. The Homebrew build is signed by its vendor and notarised by Apple, which is what that check looks for.",
                                  status: .missing, evidence: evidence,
                                  fix: .brewCask(["codex"]))
        case .wrongArchitecture:
            return PreflightCheck(id: "codex-auth", titleKey: "Codex is built for a different Mac",
                                  detailKey: "The installed binary was made for another processor. Installing it again through Homebrew fetches the one this Mac runs.",
                                  status: .missing, evidence: evidence,
                                  fix: .brewCask(["codex"]))
        case .notSignedIn:
            return PreflightCheck(id: "codex-auth", titleKey: "Codex is not signed in",
                                  detailKey: "It says the account is the problem. Signing in happens in a terminal — a login cannot be done for you.",
                                  status: .missing, evidence: evidence,
                                  fix: .signIn(command: "codex login"))
        case .unknown:
            return PreflightCheck(id: "codex-auth", titleKey: "Codex does not answer",
                                  detailKey: "The call failed and the output does not say why, so Bulava will not guess. What it printed is below.",
                                  status: .missing, evidence: evidence)
        }
    }

    private func githubCheck() async -> PreflightCheck {
        let probe = await Shell.run("gh auth status 2>&1 || true", timeout: 25)
        let out = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.contains("Logged in") {
            let account = out.split(separator: "\n")
                .first { $0.contains("Logged in") }
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return PreflightCheck(id: "gh", titleKey: "GitHub is connected",
                                  detailKey: "Needed only for products that receive a pull request instead of a merge.",
                                  status: .ready, evidence: account, gate: .pullRequests)
        }
        // Not installed and not signed in are different walls, and the button is different too.
        // `gh auth status` exits non-zero for both, so the shell's own 127 is what separates them.
        if Self.classify(exitCode: probe.exitCode, output: out) == .notOnPath {
            return PreflightCheck(id: "gh", titleKey: "GitHub is not connected",
                                  detailKey: "Needed only for products that receive a pull request instead of a merge. The command-line tool is not installed.",
                                  status: .missing, evidence: String(out.prefix(160)),
                                  gate: .pullRequests, fix: .brew(["gh"]))
        }
        return PreflightCheck(id: "gh", titleKey: "GitHub is not connected",
                              detailKey: "Needed only for products that receive a pull request instead of a merge. The tool is installed but no account is signed in.",
                              status: .missing, evidence: String(out.prefix(160)),
                              gate: .pullRequests, fix: .signIn(command: "gh auth login"))
    }

    /// The one grant that lets a worker drive an interface at all.
    ///
    /// The old wording told him to grant this "to the terminal Bulava launches", which was the
    /// honest description of a broken arrangement: a terminal's identity changes with every
    /// rebuild, so the grant had to be given again and again, and giving it hands the same rights
    /// to everything else that runs through that binary. Workers now ask Bulava to click for them,
    /// so this is the whole of it — one grant, to one signed app, once.
    private func accessibilityCheck() -> PreflightCheck {
        let trusted = AXIsProcessTrusted()
        return PreflightCheck(id: "ax",
                              titleKey: trusted
                                ? "Workers can drive apps through Bulava"
                                : "Workers cannot drive apps yet",
                              detailKey: "A worker holds no permission of its own, so Bulava clicks and types on its behalf. Granting this once to Bulava covers every project and survives rebuilds, because Bulava is signed. Every action is written to ui-actions.log.",
                              status: trusted ? .ready : .missing,
                              gate: .appDriving,
                              settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Two copies of Bulava in /Applications, which is what the rename left behind.
    ///
    /// The application used to be called Night Shift, and the image on the site handed people
    /// "Night Shift.app". It hands them "Bulava.app" now — but an installed copy keeps the name it
    /// was installed under: Sparkle replaces the bundle in place and only renames it when the
    /// framework was COMPILED to, which this vendored build was not, and renaming a running
    /// application from inside itself is not something worth doing to someone's Mac at launch.
    ///
    /// So the one case that actually bites is said out loud: both files present, the same
    /// application twice, and whichever one is opened is a coin toss.
    private func oldCopyCheck() -> PreflightCheck {
        let fm = FileManager.default
        let old = "/Applications/Night Shift.app"
        let new = "/Applications/Bulava.app"
        let running = Bundle.main.bundleURL.path
        guard fm.fileExists(atPath: old) else {
            return PreflightCheck(id: "old-copy", titleKey: "One copy of Bulava is installed",
                                  detailKey: "Nothing left over from the name it used to have.",
                                  status: .ready, gate: .convenience)
        }
        if fm.fileExists(atPath: new) {
            return PreflightCheck(id: "old-copy", titleKey: "Bulava is installed twice",
                                  detailKey: "The application used to be called Night Shift, and both files are still here. They are the same application, so which one opens — and which one keeps your permissions — is a coin toss. Move the older one to the Trash.",
                                  status: .missing,
                                  // The arrow marks the one that is open right now, which is the
                                  // only thing that tells them apart on disk.
                                  evidence: [old, new]
                                      .map { $0 == running ? "\($0)  ←" : $0 }
                                      .joined(separator: "\n"),
                                  gate: .convenience,
                                  fix: .revealInFinder(old))
        }
        return PreflightCheck(id: "old-copy", titleKey: "Bulava still has its old name on disk",
                              detailKey: "It was called Night Shift when you installed it, and an update keeps the file name it found. Everything works; only the icon in Applications says otherwise. Renaming it to Bulava.app is safe while the app is closed.",
                              status: .missing, evidence: old,
                              gate: .convenience,
                              fix: .revealInFinder(old))
    }

    private func browserCheck() async -> PreflightCheck {
        let browsers = ["/Applications/Google Chrome.app", "/Applications/Chromium.app",
                        "/Applications/Microsoft Edge.app", "/Applications/Brave Browser.app"]
        let browser = browsers.first { FileManager.default.fileExists(atPath: $0) }
        let mcp = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/mcp.json")
        let configured: Bool = {
            guard let data = try? Data(contentsOf: mcp),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("chrome-devtools")
        }()
        guard let browser else {
            return PreflightCheck(id: "browser", titleKey: "No browser for web work",
                                  detailKey: "Browser work — checking a site, filling a console — needs a Chrome-family browser.",
                                  status: .missing, evidence: "none of Chrome / Chromium / Edge / Brave",
                                  gate: .convenience)
        }
        if configured {
            return PreflightCheck(id: "browser", titleKey: "Browser work is possible",
                                  detailKey: "Bulava can open a real page, read it, and act on it.",
                                  status: .ready,
                                  evidence: (browser as NSString).lastPathComponent + " · chrome-devtools",
                                  gate: .convenience)
        }
        return PreflightCheck(id: "browser", titleKey: "Browser control is not wired up",
                              detailKey: "A browser is installed but the chrome-devtools bridge is not configured, so Bulava cannot drive it.",
                              status: .missing, evidence: (browser as NSString).lastPathComponent,
                              gate: .convenience)
    }

    private func folderCheck(model: AppModel) -> PreflightCheck {
        let paths = model.products.products
            .flatMap(\.resources)
            .compactMap(\.projectID)
            .compactMap { model.projects.project(id: $0)?.path }
        guard !paths.isEmpty else {
            return PreflightCheck(id: "folders", titleKey: "Connected folders are readable",
                                  detailKey: "Nothing is connected yet.",
                                  status: .unknown, gate: .convenience)
        }
        let unreadable = paths.filter { !FileManager.default.isReadableFile(atPath: $0) }
        if unreadable.isEmpty {
            return PreflightCheck(id: "folders", titleKey: "Connected folders are readable",
                                  detailKey: "Bulava can reach everything your products point at.",
                                  status: .ready,
                                  evidence: String(format: String(localized: "%lld folders"), paths.count))
        }
        return PreflightCheck(id: "folders", titleKey: "Some folders cannot be read",
                              detailKey: "Only work in these folders is affected. Grant Bulava access, or disconnect what has moved.",
                              status: .missing,
                              evidence: unreadable.prefix(3).joined(separator: "\n"),
                              gate: .affectedWork,
                              settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    private func microphoneCheck() -> PreflightCheck {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let resolved: PreflightCheck.Status = switch status {
            case .authorized: .ready
            case .notDetermined: .unknown
            default: .missing
        }
        return PreflightCheck(id: "mic", titleKey: "Dictation works",
                              detailKey: "Only needed if you want to speak your requests instead of typing.",
                              status: resolved, gate: .convenience,
                              settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private func notificationCheck() async -> PreflightCheck {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let resolved: PreflightCheck.Status = switch settings.authorizationStatus {
            case .authorized, .provisional: .ready
            case .notDetermined: .unknown
            default: .missing
        }
        return PreflightCheck(id: "notify", titleKey: "Bulava can reach you",
                              detailKey: "How you hear about a finished report or a question while you are away.",
                              status: resolved, gate: .convenience,
                              settingsURL: "x-apple.systempreferences:com.apple.preference.notifications")
    }

    private func screenRecordingCheck() -> PreflightCheck {
        let granted = CGPreflightScreenCaptureAccess()
        var check = PreflightCheck(id: "screen", titleKey: "Bulava can watch its own workers",
                                   detailKey: "Screen Recording lets Bulava read a worker's output to tell you what it is doing.",
                                   status: granted ? .ready : .missing, gate: .convenience,
                                   settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        // Offered even when this reads as ready. The one failure that costs a night is the one
        // where the list says yes and the capture is refused anyway, and a row with nothing on it
        // but a tick leaves the only way out in a switch somebody has to know to toggle twice.
        check.fix = .askForScreenRecording
        return check
    }
}

// MARK: - View

struct PreflightView: View {
    @Environment(AppModel.self) private var model

    private var runner: PreflightRunner { model.readiness }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if runner.checks.isEmpty && runner.running {
                    ProgressView().controlSize(.small).padding(.vertical, 40)
                } else {
                    limits
                    list
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
            .padding(.top, 30)
            .padding(.bottom, 60)
        }
        .task { await model.refreshReadiness() }
    }

    @ViewBuilder private var limits: some View {
        let summary = runner.summary
        if !summary.pullRequests.isEmpty || !summary.appDriving.isEmpty || !summary.affectedWork.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !summary.affectedWork.isEmpty {
                    limitRow("Only work inside these folders is blocked. Everything else runs normally.",
                             summary.affectedWork)
                }
                if !summary.pullRequests.isEmpty {
                    limitRow("Work that must open a pull request will not start.",
                             summary.pullRequests)
                }
                if !summary.appDriving.isEmpty {
                    limitRow("Work that changes how something looks will not start — Bulava could not open the real screen to check it.",
                             summary.appDriving)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Palette.orangeSoft))
            .padding(.bottom, 14)
        }
    }

    private func limitRow(_ key: LocalizedStringKey, _ causes: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(key)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(causes.joined(separator: " · "))
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(runner.isReady ? "Bulava is ready to work unattended"
                                    : (runner.blocking.isEmpty ? "A few things could not be checked"
                                                               : "A few things are missing"))
                    .screenTitleStyle()
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Button { _Concurrency.Task { await model.refreshReadiness(force: true) } } label: {
                    Text(runner.running ? "Checking…" : "Check again")
                }
                .buttonStyle(.bulava())
                .disabled(runner.running)
            }
            Text(runner.isReady
                 ? "Everything an overnight run needs is in place. macOS will not interrupt work to ask for anything."
                 : "Clear these now rather than at two in the morning, when nothing is there to click the dialog. Bulava will not start work while a required one is unresolved.")
                .font(Typo.body)
                .lineSpacing(4)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }

    private var list: some View {
        VStack(spacing: 0) {

            let ordered = runner.blocking + runner.unresolved + runner.optional
                + runner.checks.filter { $0.status == .ready && $0.required }
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, check in
                if index > 0 { Hairline() }
                CheckRow(check: check)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous).fill(Palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1)
        )
        .restingShadow()
    }
}

private struct CheckRow: View {
    @Environment(AppModel.self) private var model
    let check: PreflightCheck
    @State private var confirmingStop = false

    /// "Ledger" and "Highline College" — named, because a button that stops two people's work
    /// without saying whose is not a button anybody should press.
    private func names(_ holders: [EngineBusy.Holder]) -> String {
        holders.map { "“\($0.name)”" }.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            glyph.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(check.titleKey))
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.text)
                Text(LocalizedStringKey(check.detailKey))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = check.note {
                    Text(note)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let evidence = check.evidence, !evidence.isEmpty {
                    Text(evidence)
                        .font(Typo.mono(9.5))
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if check.status != .ready, case .trustFolders(let folders)? = check.fix {
                Button { model.trustFolders(folders) } label: {
                    Text(folders.count == 1 ? "Trust the folder" : "Trust the folders")
                }
                .buttonStyle(.bulava(.primary))
            } else if check.status != .ready, case .installEngine? = check.fix {
                if let holders = model.engineBlocker?.holders, !holders.isEmpty {
                    // Plain "Install the engine" is known to refuse right now, and the run it
                    // refuses for cannot be stopped from here — nor, as it turns out, by stopping
                    // it elsewhere, since that leaves the session open and the session holds the
                    // engine too. So the button does the whole thing, and says whose work it ends.
                    Button { confirmingStop = true } label: {
                        Text(model.stoppingForEngine ? "Stopping…"
                             : model.installingEngine ? "Installing…"
                             : holders.count == 1 ? "Stop “\(holders[0].name)” and install"
                             : "Stop the running work and install")
                    }
                    .buttonStyle(.bulava(.primary))
                    .disabled(model.stoppingForEngine || model.installingEngine)
                    .confirmationDialog(
                        Text("Stop \(names(holders)) and install the engine?"),
                        isPresented: $confirmingStop, titleVisibility: .visible
                    ) {
                        Button("Stop and install", role: .destructive) {
                            Task { await model.stopHolderAndInstallEngine() }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        // Said plainly because it is true: stopping a run removes its instance
                        // directory, and a message accepted but not yet started lives in there.
                        Text("Whatever it is answering right now stops there, and anything still waiting in its queue is dropped. The conversation itself is kept — send the message again afterwards.")
                    }
                } else {
                    Button { Task { await model.installEngine() } } label: {
                        Text(model.installingEngine ? "Installing…" : "Install the engine")
                    }
                    .buttonStyle(.bulava(.primary))
                    .disabled(model.installingEngine)
                }
            } else if check.status != .ready, case .brew(let formulas)? = check.fix {
                Button { model.installWithHomebrew(formulas) } label: {
                    Text("Install with Homebrew")
                }
                .buttonStyle(.bulava(.primary))
            } else if check.status != .ready, case .brewCask(let casks)? = check.fix {
                Button { model.installWithHomebrew(casks, cask: true) } label: {
                    Text("Install with Homebrew")
                }
                .buttonStyle(.bulava(.primary))
            } else if check.status != .ready, case .signIn(let command)? = check.fix {
                Button { model.signIn(command: command) } label: { Text("Sign in…") }
                    .buttonStyle(.bulava(.primary))
            } else if case .askForScreenRecording? = check.fix {
                // Shown whatever the status says, for the reason above. The call returns at once
                // and macOS decides whether a dialog is warranted; re-reading readiness afterwards
                // is what turns the row green without anybody pressing Refresh.
                Button {
                    _ = CGRequestScreenCaptureAccess()
                    Task { await model.refreshReadiness() }
                } label: {
                    Text(check.status == .ready ? "Ask macOS again" : "Ask macOS")
                }
                .buttonStyle(.bulava(check.status == .ready ? .quiet : .primary))
            } else if check.status != .ready, case .revealInFinder(let path)? = check.fix {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Text("Show in Finder") }
                .buttonStyle(.bulava(.quiet))
            } else if check.status != .ready, let urlString = check.settingsURL,
                      let url = URL(string: urlString) {
                Button { NSWorkspace.shared.open(url) } label: { Text("Open Settings") }
                    .buttonStyle(.bulava(.quiet))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    @ViewBuilder private var glyph: some View {
        switch check.status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14)).foregroundStyle(Palette.green)
        case .missing:
            Image(systemName: check.required ? "exclamationmark.circle.fill" : "minus.circle")
                .font(.system(size: 14))
                .foregroundStyle(check.required ? Palette.red : Palette.textFaint)
        case .unknown:
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14)).foregroundStyle(Palette.orange)
        case .checking:
            ProgressView().controlSize(.mini)
        }
    }
}
