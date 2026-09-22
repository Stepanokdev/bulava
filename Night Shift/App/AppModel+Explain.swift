import Foundation

// MARK: - When the action is offered at all

/// Whether a record has come to rest. Pure, so it can be pinned down without a client, a chat or
/// a running engine — the same seam `PreflightRunner.paidProbesAreDue` uses.
nonisolated enum ExplainAvailability {

    /// A turn in a conversation.
    ///
    /// `turnFinished` is the feed's own answer, written while it still had the reducer in hand.
    /// Nothing else in the app is a sound reading of it: `isDirectChatBusy` is true while a
    /// review, an audit or a preparation holds a chat whose last answer finished minutes ago, and
    /// false for a worker that is only holding a question or waiting out a usage window; and "the
    /// newest entry of a busy chat" takes the button off a finished answer the moment the next
    /// message is sent, which is exactly when somebody reaches for it.
    static func isExplainable(turn entry: ConversationEntry) -> Bool {
        entry.kind == .foreman && entry.hiddenNotice != true && entry.turnFinished == true
    }

    /// A night-shift task.
    ///
    /// Only the states that are an outcome. A run that is still going has nothing to explain yet,
    /// and one waiting on a decision already has its own question on screen — explaining it would
    /// answer something it has not done.
    static func isExplainable(state: WorkState) -> Bool {
        switch state {
        case .reportReady, .partial, .stopped, .failed, .done: true
        case .planned, .running, .paused, .needsAnswer:        false
        }
    }
}

// MARK: - What the screen needs to know

/// Everything one explain affordance shows, worked out in one pass.
///
/// One value rather than six accessors, because every one of them needs the same assembled
/// material and building it six times per render would be the expensive way to ask the same
/// question.
struct ExplainState {

    /// The button may be pressed: the mode is on, the record has come to rest, and there is
    /// something in it worth explaining.
    var available: Bool

    var brief: Explanation?
    var stepByStep: Explanation?

    var briefRunning: Bool
    var stepByStepRunning: Bool

    /// An explanation exists, and the record — or the profile it was written for — has changed
    /// since. Shown as out of date rather than quietly presented as current.
    var stale: Bool

    var failure: String?

    /// There is something on screen even with the mode switched off. Turning the switch off is
    /// permission withdrawn, not an explanation deleted.
    var hasAnything: Bool { brief != nil || stepByStep != nil }

    var isRunning: Bool { briefRunning || stepByStepRunning }
}

// MARK: - The action

extension AppModel {

    /// Long enough for a walk-through of a long night turn. `askClaude` defaults to sixty seconds,
    /// which is not enough for seven hundred words about fifty steps.
    static let explainTimeout: TimeInterval = 150

    var explainOffered: Bool { settings.devLearningEnabled }

    /// The language an explanation is written in: the one the app is displayed in, resolved to a
    /// real language even when that setting says System.
    var explainLanguageName: String {
        ExplainPrompt.languageName(interface: settings.interfaceLanguage,
                                   displayedCode: LanguageBundle.currentCode)
    }

    // MARK: A turn in a conversation

    func explainState(turn entry: ConversationEntry) -> ExplainState {
        state(.turn(entry.id),
              settled: ExplainAvailability.isExplainable(turn: entry),
              context: ExplainContext.forTurn(entry))
    }

    func explain(turn entry: ConversationEntry, depth: ExplainDepth) {
        start(.turn(entry.id), depth: depth, context: ExplainContext.forTurn(entry))
    }

    // MARK: A night-shift task

    /// The manifest is passed in rather than read here: the cards already load it for their own
    /// title and subtitle, and the material this is fingerprinted against has to be the same
    /// material the prompt is built from.
    func explainState(task: BacklogTask, manifest: ReportManifest?) -> ExplainState {
        state(.task(task.id),
              settled: ExplainAvailability.isExplainable(state: workState(of: task)),
              context: taskContext(task, manifest: manifest))
    }

    func explain(task: BacklogTask, manifest: ReportManifest?, depth: ExplainDepth) {
        start(.task(task.id), depth: depth, context: taskContext(task, manifest: manifest))
    }

    func taskContext(_ task: BacklogTask, manifest: ReportManifest?) -> ExplainContext {
        let outcome = liveInstance(for: task)?.outcomeSummary ?? task.externalBlocker
        let turns = conversations.entries
            .filter { $0.taskID == task.id && $0.kind == .foreman }
            .sorted { $0.at < $1.at }
        return ExplainContext.forTask(title: task.title,
                                      stateLabel: workState(of: task).labelKey,
                                      outcome: outcome, manifest: manifest, turns: turns)
    }

    // MARK: Shared

    private func state(_ anchor: ExplainAnchor, settled: Bool,
                       context: ExplainContext) -> ExplainState {
        let brief = explanations.explanation(anchor, .brief)
        let steps = explanations.explanation(anchor, .stepByStep)
        let profile = settings.learningProfileForPrompt
        let language = explainLanguageName
        // Out of date if ANY explanation held for this record no longer matches what the record
        // and the profile would produce now. Each depth is compared against its own request.
        let stale = ExplainDepth.allCases.contains { depth in
            guard let held = explanations.explanation(anchor, depth) else { return false }
            return held.fingerprint != ExplainPrompt.fingerprint(context: context, profile: profile,
                                                                 languageName: language,
                                                                 depth: depth)
        }
        return ExplainState(
            available: explainOffered && settled && context.hasMaterial,
            brief: brief,
            stepByStep: steps,
            briefRunning: explainInFlight.contains(ExplanationStore.key(anchor, .brief)),
            stepByStepRunning: explainInFlight.contains(ExplanationStore.key(anchor, .stepByStep)),
            stale: stale,
            failure: ExplainDepth.allCases
                .compactMap { explainErrors[ExplanationStore.key(anchor, $0)] }.first)
    }

    /// One read-only request, paid for by this press and nothing else.
    ///
    /// Deliberately NOT a message in the chat. Every message goes out through `worker-send.sh` on
    /// the `adaptive-peer` pipeline — `chatMode` is pinned to `.claudeAndCodex` — which pays for
    /// two independent positions in preflight and then runs a worker that may write to the
    /// repository. Asking for an explanation needs none of that: it changes nothing, it must not
    /// occupy the live session, and it must not appear in the thread as something he said.
    /// `askClaude` runs `claude -p --tools ''` in a neutral directory with no tools at all.
    private func start(_ anchor: ExplainAnchor, depth: ExplainDepth, context: ExplainContext) {
        let key = ExplanationStore.key(anchor, depth)
        // A second press while the first is out does nothing. Two different records, or the two
        // depths of one, run side by side.
        guard !explainInFlight.contains(key) else { return }
        guard context.hasMaterial else {
            failExplaining(key, String(localized: "There is nothing readable in this result yet."))
            return
        }

        let profile = settings.learningProfileForPrompt
        let language = explainLanguageName
        // Taken BEFORE the call, and stored with the answer. A record that changes while the
        // explanation is being written is then out of date the moment it lands, which is the
        // truth, rather than being labelled current because it just arrived.
        let fingerprint = ExplainPrompt.fingerprint(context: context, profile: profile,
                                                    languageName: language, depth: depth)
        let prompt = ExplainPrompt.build(context: context, profile: profile,
                                         languageName: language, depth: depth)

        beginExplaining(key)
        Task { [weak self] in
            guard let self else { return }
            defer { self.endExplaining(key) }
            let answer = await self.client.askClaude(prompt: prompt, timeout: Self.explainTimeout)
            guard let text = answer?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                self.failExplaining(key, String(localized: "Claude did not answer. It is either signed out or out of quota — Settings → Diagnostics says which."))
                return
            }
            // The CLI answers "Login expired · Please run /login" with a zero exit code, and that
            // is not an explanation. `noticeExpiredLogin` does the same for the conversation.
            guard !PreflightRunner.isSignInNotice(text) else {
                self.failExplaining(key, String(localized: "Claude asked to be signed in again, so there is nothing to explain yet. A login happens in a terminal: claude auth login"))
                return
            }
            self.explanations.put(Explanation(text: text, profile: profile,
                                              languageName: language, fingerprint: fingerprint),
                                  for: anchor, depth: depth)
        }
    }
}
