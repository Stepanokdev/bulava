import Foundation

nonisolated enum RelayTier: String, Sendable {
    case live
    case resumed
    /// Accepted, and being prepared: Claude and Codex are forming independent positions before the
    /// worker is given anything. Nothing has been typed at the session yet, and saying "working"
    /// here would be the app's own version of the bug this exists to fix.
    case preparing
    case queued
    case conflict
    case none
    case error
}

nonisolated struct RelayResult: Sendable {
    var tier: RelayTier
    var confirmed: Bool
    var uncertain: Bool
    var message: String
    /// For an `.error`: proven that the message never reached the worker — the engine refused it
    /// before trying, or there was no engine to ask. Only such a message may be sent again by
    /// itself. Everything else that ends in `.error` (cut off by the timeout, killed, a crash
    /// halfway through typing) may have landed, and sending it again could run the work twice.
    var undelivered = false

    /// What `worker-send.sh` said, read into a result.
    ///
    /// The script prints a `TIER=` line only once it has tried — a refusal before that (no such
    /// folder, an empty message, a pipeline that does not exist) exits 1 with no tier and says so
    /// on a line of its own starting with ❌. That shape, on a process that ended by itself, is the
    /// one proof of non-delivery an `.error` can carry. A shell error halfway through typing also
    /// exits 1 with no tier, but it does not speak in ❌ — so it stays "may have landed".
    static func read(output out: String, exitCode: Int32, launched: Bool,
                     endedBy: CommandEnd) -> RelayResult {
        let marker: RelayTier =
            out.contains("TIER=live")      ? .live :
            out.contains("TIER=resumed")   ? .resumed :
            out.contains("TIER=preparing") ? .preparing :
            out.contains("TIER=queued")    ? .queued :
            out.contains("TIER=conflict")  ? .conflict :
            out.contains("TIER=none")      ? .none : .error
        var tier = marker
        var confirmed = false, uncertain = false

        switch (marker, exitCode) {
        case (.live, 0), (.resumed, 0):        confirmed = true
        case (.preparing, 5):                  tier = .preparing
        case (.queued, 2):                     tier = .queued
        case (.live, 2), (.resumed, 2):        uncertain = true
        case (.conflict, 4):                   tier = .conflict
        case (.none, 3):                       tier = .none
        default:                               tier = .error
        }
        let humanLine = out.split(separator: "\n").map(String.init)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("TIER=") } ?? out
        var result = RelayResult(tier: tier, confirmed: confirmed, uncertain: uncertain, message: humanLine)
        if tier == .error {
            result.undelivered = !launched || endedBy == .neverStarted
                || (endedBy == .exited && marker == .error && exitCode == 1
                    && humanLine.trimmingCharacters(in: .whitespaces).hasPrefix("❌"))
        }
        return result
    }
}

extension SupervisorClient {

    enum RelayIntent: String { case conversation, continueWork = "continue" }

    /// Hand a message to the engine.
    ///
    /// `pipeline` says what has to happen before the worker reads it: `plain` is what the engine
    /// has always done — compose the standing sections and type it in — and it stays the default
    /// because this call also carries the foreman's relays and the report runs, none of which
    /// should start paying for two research calls because a chat setting changed.
    ///
    /// `runEnv` is the composer's own choices. Without them a preflight, a consultation or the
    /// review gate runs on the engine's defaults while the composer names something else.
    func workerSend(projectPath: String, sessionID: String?, branch: String?, runID: String?,
                    message: String, messageID: UUID? = nil,
                    intent: RelayIntent = .conversation,
                    pipeline: String = "plain",
                    runEnv: [String: String] = [:],
                    contextFile: String? = nil, extraDirsFile: String? = nil) async -> RelayResult {
        guard let home = OrchestratorHome.detect()?.path else {
            var r = RelayResult(tier: .error, confirmed: false, uncertain: false, message: "engine not found")
            r.undelivered = true
            return r
        }
        let script = "\(home)/bin/worker-send.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            var r = RelayResult(tier: .error, confirmed: false, uncertain: false, message: "worker-send.sh missing")
            r.undelivered = true
            return r
        }
        var env = ["SUPERVISOR_ENABLE_RESUME": "1"]
        env.merge(Self.screenAnswerEnv) { _, new in new }
        env.merge(runEnv) { _, new in new }
        if let contextFile { env["SUPERVISOR_CHAT_CONTEXT_FILE"] = contextFile }
        if let extraDirsFile { env["SUPERVISOR_EXTRA_DIRS_FILE"] = extraDirsFile }
        let call = Self.workerSendInvocation(script: script, projectPath: projectPath, sessionID: sessionID,
                                             branch: branch, runID: runID, message: message, messageID: messageID,
                                             intent: intent, pipeline: pipeline)
        // Longer than the slowest path the engine can take on its defaults: a resume waits up to a
        // minute for a long transcript to load (SUPERVISOR_RESUME_HANDSHAKE_WAIT), then typing waits
        // up to two minutes for a quiet prompt and a few seconds per try to type and submit. Cut
        // short, the shell is killed while the message may still land, and the chat says «not
        // delivered» about something that was.
        // …and on top of that, as long as a resume may wait for him to answer a screen of Claude's.
        let r = await Shell.run(call.command, args: call.args, extraEnv: env,
                                timeout: 240 + Self.screenAnswerWait)

        let out = r.stderr.isEmpty ? r.stdout : (r.stdout.isEmpty ? r.stderr : r.stdout + "\n" + r.stderr)
        return RelayResult.read(output: out, exitCode: r.exitCode, launched: r.launched, endedBy: r.endedBy)
    }

    func interruptChat(projectPath: String, runID: String?) async -> CommandResult {
        guard let home = OrchestratorHome.detect()?.path else {
            return CommandResult(stdout: "", stderr: "engine not found", exitCode: -1,
                                 launched: false, endedBy: .neverStarted)
        }
        let script = "\(home)/bin/worker-interrupt.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            return CommandResult(stdout: "", stderr: "worker-interrupt.sh missing", exitCode: -1,
                                 launched: false, endedBy: .neverStarted)
        }
        let rid = (runID?.isEmpty == false) ? runID! : "-"
        return await Shell.run("bash \"$1\" \"$2\" \"$3\" 2>&1",
                               args: [script, projectPath, rid], timeout: 20)
    }

    func answerTerminalQuestion(session: String, expected: PendingUserQuestion,
                                answer: String) async -> CommandResult {
        let pane = await capturePane(session: session, lines: 160)
        guard let current = TerminalQuestionParser.parse(pane),
              current.source == .terminal,
              current.questions.first?.question == expected.questions.first?.question else {
            return CommandResult(stdout: "", stderr: "Claude вже показує інше питання.", exitCode: 2,
                                 launched: false, endedBy: .neverStarted)
        }

        let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // A screen answered by keys rather than by moving through a list: it has no cursor to start from.
        if let keys = current.terminalKeys[clean] {
            return await pressKeys(keys, session: session, stillAsking: current)
        }
        guard let selected = current.terminalSelectedIndex else {
            return CommandResult(stdout: "", stderr: "Claude вже показує інше питання.", exitCode: 2,
                                 launched: false, endedBy: .neverStarted)
        }
        let target: Int
        let custom: Bool
        if let exact = current.terminalOptionIndices[clean] {
            target = exact
            custom = false
        } else if let customIndex = current.terminalCustomOptionIndex {
            target = customIndex
            custom = true
        } else {
            return CommandResult(stdout: "", stderr: "У формі Claude немає поля для власної відповіді.",
                                 exitCode: 2, launched: false, endedBy: .neverStarted)
        }

        let direction = target >= selected ? "Down" : "Up"
        let steps = abs(target - selected)
        let mode = custom ? "custom" : "option"
        let sent = await Shell.run(
            """
            set -e
            i=0
            while [ "$i" -lt "$2" ]; do
              tmux send-keys -t "$1" "$3"
              i=$((i + 1))
            done
            tmux send-keys -t "$1" Enter
            if [ "$4" = custom ]; then
              sleep 0.2
              tmux send-keys -t "$1" -l -- "$5"
              tmux send-keys -t "$1" Enter
            fi
            """,
            args: [session, String(steps), direction, mode, clean], timeout: 10)
        guard sent.launched, sent.exitCode == 0, !current.terminalReview else { return sent }

        return await submitTerminalReviewIfPresented(
            session: session, previousQuestion: current.questions.first?.question) ?? sent
    }

    /// The keys a screen named for an answer, in order. "Enter?" is an Enter sent only if the screen
    /// still asks the same thing after the keys before it: a "(y/n)" that takes the single key has
    /// already moved on, and an Enter sent regardless would answer whatever came next.
    private func pressKeys(_ keys: [String], session: String, stillAsking asked: PendingUserQuestion) async
        -> CommandResult {
        var last = CommandResult(stdout: "", stderr: "", exitCode: 0, launched: true, endedBy: .exited)
        for key in keys {
            if key == "Enter?" {
                try? await Task.sleep(for: .milliseconds(300))
                let pane = await capturePane(session: session, lines: 160)
                guard let now = TerminalQuestionParser.parse(pane),
                      now.questions.first?.question == asked.questions.first?.question else { continue }
                last = await Shell.run(#"tmux send-keys -t "$1" Enter"#, args: [session], timeout: 10)
            } else {
                last = await Shell.run(#"tmux send-keys -t "$1" "$2""#, args: [session, key], timeout: 10)
            }
            guard last.launched, last.exitCode == 0 else { return last }
        }
        return last
    }

    private func submitTerminalReviewIfPresented(session: String, previousQuestion: String?) async
        -> CommandResult? {
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(80))
            let pane = await capturePane(session: session, lines: 160)
            guard let prompt = TerminalQuestionParser.parse(pane) else { continue }
            if !prompt.terminalReview {
                if prompt.questions.first?.question != previousQuestion { return nil }
                continue
            }
            guard let selected = prompt.terminalSelectedIndex,
                  let submit = prompt.terminalOptionIndices[TerminalQuestionParser.reviewSubmitLabel]
            else { return nil }
            let direction = submit >= selected ? "Down" : "Up"
            return await Shell.run(
                """
                set -e
                i=0
                while [ "$i" -lt "$2" ]; do
                  tmux send-keys -t "$1" "$3"
                  i=$((i + 1))
                done
                tmux send-keys -t "$1" Enter
                """,
                args: [session, String(abs(submit - selected)), direction], timeout: 10)
        }
        return nil
    }

    /// Start the Claude session a chat talks to.
    ///
    /// The model and the depth are handed over here, and they used to not be: night runs got them
    /// through `launchEnv`, a chat got nothing, and the engine's own default (`high`, no model)
    /// answered instead. So the composer could say "Opus · Maximum" while the session it started
    /// was running whatever the engine felt like — the one thing a control that names the model
    /// must never do.
    func startChat(projectPath: String, contextFile: String, extraDirsFile: String,
                   claudeEffort: String = "", claudeModel: String = "",
                   codexEffort: String = "", codexModel: String = "",
                   collaboration: String = "", language: String = "",
                   dirty: DirtyTreeChoice? = nil, unattended: Bool = false) async -> CommandResult {
        guard let home = OrchestratorHome.detect()?.path else {
            return CommandResult(stdout: "", stderr: "engine not found", exitCode: -1, launched: false,
                                 endedBy: .neverStarted)
        }
        var env = Self.chatEnv(contextFile: contextFile, extraDirsFile: extraDirsFile,
                               claudeEffort: claudeEffort, claudeModel: claudeModel,
                               codexEffort: codexEffort, codexModel: codexModel,
                               collaboration: collaboration, language: language)
        // The director's answer about uncommitted work already in the folder, for this one start.
        if let dirty { env.merge(dirty.env) { _, new in new } }
        // An automation's run: nobody answers a dialog while it works (`hooks/permission-gate.sh`),
        // and it gets a browser of its own.
        if unattended { env["SUPERVISOR_UNATTENDED"] = "1" }
        env.merge(Self.screenAnswerEnv) { _, new in new }
        return await Shell.run("bash \"$1/bin/night-shift.sh\" start \"$2\" --no-attach 2>&1",
                               args: [home, projectPath], extraEnv: env,
                               timeout: 150 + Self.screenAnswerWait)
    }

    /// A run whose watchdog died with its session while it still owed work, brought back in place:
    /// the same instance, run id and Claude conversation (`night-shift.sh revive`). Exit 0 is whole
    /// again; 4 is refused for good — stopped or replaced; 5 is not now — its Claude is still running.
    func revive(projectPath: String) async -> CommandResult {
        guard let home = OrchestratorHome.detect()?.path else {
            return CommandResult(stdout: "", stderr: "engine not found", exitCode: -1, launched: false,
                                 endedBy: .neverStarted)
        }
        return await Shell.run("bash \"$1/bin/night-shift.sh\" revive \"$2\" 2>&1",
                               args: [home, projectPath], extraEnv: Self.screenAnswerEnv,
                               timeout: 150 + Self.screenAnswerWait)
    }

    /// How long a start, a resume or a revival waits for him to answer a screen Claude asks on
    /// (`await_handshake`), in seconds. Handed to the engine explicitly and added to the time the
    /// app gives the call: a process cut off by the app in the middle of that wait is never rolled
    /// back, and leaves a run half started.
    static let screenAnswerWait: TimeInterval = 420
    static var screenAnswerEnv: [String: String] {
        ["SUPERVISOR_SCREEN_ANSWER_WAIT": String(Int(screenAnswerWait))]
    }

    /// The environment a chat's session is started with.
    static func chatEnv(contextFile: String, extraDirsFile: String,
                        claudeEffort: String, claudeModel: String,
                        codexEffort: String = "", codexModel: String = "",
                        collaboration: String = "", language: String = "") -> [String: String] {
        var env = [
            "SUPERVISOR_CHAT_CONTEXT_FILE": contextFile,
            "SUPERVISOR_EXTRA_DIRS_FILE": extraDirsFile,
            "SUPERVISOR_HANDSHAKE_WAIT": "12",
        ]
        env.merge(runEnv(claudeEffort: claudeEffort, claudeModel: claudeModel,
                         codexEffort: codexEffort, codexModel: codexModel,
                         collaboration: collaboration, language: language)) { _, new in new }
        return env
    }

    /// Every choice the composer is showing, in the form the engine reads.
    ///
    /// Both halves used to be handed over separately and incompletely: `startChat` carried Claude's
    /// model and depth and nothing else, `workerSend` carried neither. So a preflight, a peer
    /// consultation and the final review all ran on `supervisor/config.sh`'s defaults — `high`, no
    /// model — while the composer said "Opus · Maximum". `SUPERVISOR_RUN_ENV_FROM_APP` is what
    /// tells the engine these are the director's choices and worth writing down for the run.
    static func runEnv(claudeEffort: String, claudeModel: String,
                       codexEffort: String, codexModel: String,
                       collaboration: String, language: String = "") -> [String: String] {
        var env = ["SUPERVISOR_RUN_ENV_FROM_APP": "1",
                   "SUPERVISOR_APP_ANSWERS": SupervisorClient.questionsAnswered]
        if !claudeEffort.isEmpty { env["SUPERVISOR_CLAUDE_EFFORT"] = claudeEffort }
        if !codexEffort.isEmpty { env["SUPERVISOR_CODEX_EFFORT"] = codexEffort }
        // A model id goes onto a command line, so it is filtered the same way everywhere else.
        if let model = ClaudeModelCatalog.safeID(claudeModel) { env["SUPERVISOR_CLAUDE_MODEL"] = model }
        if let model = CodexModelCatalog.safeSlug(codexModel) { env["SUPERVISOR_CODEX_MODEL"] = model }
        if !collaboration.isEmpty { env["SUPERVISOR_COLLABORATION_MODE"] = collaboration }
        // Where the worker's language starts. A chat never sent it, and the engine's default — Ukrainian
        // — answered people who wrote in English or Russian.
        if !language.isEmpty { env["SUPERVISOR_REPORT_LANGUAGE"] = language }
        return env
    }

    /// A pipeline name reaches a shell and then a file path, so it is lowercase letters, digits and
    /// hyphens or it is nothing.
    /// The command line `workerSend` runs, kept apart so what reaches `worker-send.sh` — the
    /// pipeline above all — can be checked without an engine.
    nonisolated static func workerSendInvocation(script: String, projectPath: String, sessionID: String?,
                                                 branch: String?, runID: String?, message: String,
                                                 messageID: UUID?, intent: RelayIntent,
                                                 pipeline: String) -> (command: String, args: [String]) {
        let sid = (sessionID?.isEmpty == false) ? sessionID! : "-"
        let br = (branch?.isEmpty == false) ? branch! : "-"
        let rid = (runID?.isEmpty == false) ? runID! : "-"
        let mid = messageID?.uuidString ?? "-"
        return ("bash \"$1\" --mode \"$7\" --message-id \"$8\" --pipeline \"$9\" \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" 2>&1",
                [script, projectPath, sid, br, rid, message, intent.rawValue, mid, safePipelineName(pipeline)])
    }

    static func safePipelineName(_ raw: String) -> String {
        let cleaned = raw.filter { $0.isLowercase && $0.isASCII || $0.isNumber || $0 == "-" }
        return cleaned.isEmpty || cleaned != raw ? "plain" : cleaned
    }

    func awaitChatInstance(projectPath: String, timeout: TimeInterval = 20) async -> SupervisorInstance? {
        let wanted = Slug.canonicalPath(projectPath)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let instance = readInstances().first(where: {
                Slug.canonicalPath($0.projectPath) == wanted && $0.runID != nil
            }) { return instance }
            try? await Task.sleep(for: .milliseconds(300))
        } while Date() < deadline
        return nil
    }
}

// MARK: - Review gate

extension SupervisorClient {

    enum ReviewGateError: Error {

        case couldNotApply
    }

    /// Turn the supervisor's review off for this project — and prove it was us.
    ///
    /// The marker used to be an empty file, and an empty file proves nothing: anything able to
    /// write one could finish a night unreviewed and have the journal record it as the director's
    /// own decision. It is signed now, over `review-off|<slug>`, with the same key that signs a
    /// decision about Codex; the engine deletes one it cannot verify rather than honouring it.
    func setReviewGate(enabled: Bool, projectPath: String) throws {
        let slug = Slug.forPath(projectPath)
        let dir = paths.instanceDir(slug: slug)
        let marker = dir.appendingPathComponent("review-off")
        let fm = FileManager.default
        do {
            if enabled {
                if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
            } else {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                DecisionSigner.publishPublicKey(stateDir: paths.stateDir)
                guard let signature = DecisionSigner.sign(payload: "review-off|\(slug)") else {
                    throw ReviewGateError.couldNotApply
                }
                let body: [String: Any] = ["signature": signature,
                                           "at": Date().timeIntervalSince1970]
                let data = try JSONSerialization.data(withJSONObject: body)
                try data.write(to: marker, options: .atomic)
            }
        } catch {
            throw ReviewGateError.couldNotApply
        }
    }
}
