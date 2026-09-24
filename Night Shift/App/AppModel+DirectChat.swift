import AppKit
import Foundation

/// Who is reading the message, and since when.
///
/// One sentence stood here for the whole of preparation — "Claude and Codex are reading this
/// first" — and it said exactly as much after two minutes as after two seconds. A user watching a
/// simple question sit under it wrote in to ask whether it had hung. It had not; the screen simply
/// had nothing else to say. Now it counts, and names whoever is still going.
nonisolated struct PeerReading: Equatable, Sendable {
    var claudeSince: Date?
    var codexSince: Date?
    var codexOut: Bool = false
    var claudeOut: Bool = false

    var withCodex: Bool { !codexOut }

    var label: String {
        switch (claudeSince, codexSince) {
        case (.some(let c), .some(let x)):
            return String(format: String(localized: "Claude and Codex are reading this · %@"),
                          Self.elapsed(since: min(c, x)))
        case (.some(let c), .none):
            return codexOut
                ? String(format: String(localized: "Claude is reading this · %@ — Codex is not taking part"),
                         Self.elapsed(since: c))
                : String(format: String(localized: "Claude is still reading · %@"), Self.elapsed(since: c))
        case (.none, .some(let x)):
            return String(format: String(localized: "Codex is still reading · %@"), Self.elapsed(since: x))
        case (.none, .none):
            // Preparation has started but neither position has begun: the message is still being
            // put together for them to read.
            return codexOut
                ? String(localized: "Claude is reading this — Codex is not taking part")
                : String(localized: "Claude and Codex are reading this first")
        }
    }

    /// Minutes and seconds, the way a person times something that is taking a while.
    static func elapsed(since: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(since)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

nonisolated enum DirectChatPhase: Equatable, Sendable {
    case new
    case starting
    /// The message has been accepted but the worker has not been given it. Claude and Codex are
    /// forming independent positions first, which takes minutes — and calling that "working" was
    /// the app's half of the same lie the engine used to tell.
    case preparing(PeerReading)
    /// Accepted, in line, and nothing has started on it: the worker is finishing something else.
    /// Not the same as `preparing`, and saying it was is how a message parked behind a usage
    /// window displayed as "Claude and Codex are reading this first" for an hour while neither
    /// engine had seen it.
    case queued
    /// Parked on a usage window, with the time it is expected back.
    case waitingForLimit(Date?)
    /// Parked on CODEX, which is not the same thing and never was.
    ///
    /// Claude is perfectly free here; what is waiting is the review. The app used to hide this
    /// state on exactly that reasoning, and it was right while a spent Codex window stopped
    /// nothing. Now that nothing finishes without Codex, hiding it would leave a run standing
    /// still under a label that says it is in line — the failure this whole change is against.
    case waitingForCodex(Date?)
    /// The Stop hook wired into the worker is older than the engine that would rely on it, so the
    /// promise that nothing finishes without Codex is not in the file that has to keep it. Nothing
    /// is prepared against that: it is a reinstall, not a wait.
    case engineMismatch
    /// The worker froze on the turn it was given — no answer, no error, a screen that stopped
    /// drawing — and the engine is restarting it on the same conversation.
    case restartingFrozen
    /// Restarted and still silent. The next message gets one more restart.
    case frozen
    case working
    case verifying
    case reviewing
    case auditing
    case needsAttention
    case needsReview
    case ready
    case resumable
    case failed(String)

    var label: String {
        switch self {
        case .new: String(localized: "New conversation")
        case .starting: String(localized: "Connecting to Night Shift…")
        case .preparing(let peers): peers.label
        case .queued: String(localized: "In line — the current answer has to finish first")
        case .waitingForLimit(let until):
            if let until {
                String(format: String(localized: "Waiting for the usage window · back around %@"),
                       Fmt.clock(until))
            } else {
                String(localized: "Waiting for the usage window")
            }
        case .waitingForCodex(let until):
            // The day as well as the clock: a weekly window five days out shown as a bare time
            // reads as minutes away, and a reader acted on exactly that once already.
            if let until {
                String(format: String(localized: "Waiting for Codex · back around %@"),
                       Fmt.stamp(until))
            } else {
                String(localized: "Waiting for Codex")
            }
        case .engineMismatch:
            String(localized: "The installed engine is older than this app — reinstall it in Settings")
        case .restartingFrozen: String(localized: "Claude froze — Bulava is restarting it")
        case .frozen: String(localized: "Claude froze and restarting did not help — send a message to try again")
        case .working: String(localized: "Night Shift is working")
        case .verifying: String(localized: "Checking…")
        case .reviewing: String(localized: "Codex is reviewing the result.")
        case .auditing: String(localized: "Codex is reviewing the result.")
        case .needsAttention: String(localized: "Needs your answer")
        case .needsReview: String(localized: "Work stopped — review the result above")
        case .ready: String(localized: "Night Shift replied")
        case .resumable: String(localized: "Ready to resume")
        case .failed(let message): message
        }
    }

    var symbol: String {
        switch self {
        case .new: "moon.stars"
        case .starting: "ellipsis"
        case .preparing(let peers): peers.withCodex ? "person.2.wave.2" : "person.wave.2"
        case .queued: "tray.full"
        case .waitingForLimit: "hourglass"
        case .waitingForCodex: "pause.circle"
        case .engineMismatch: "exclamationmark.arrow.triangle.2.circlepath"
        case .restartingFrozen: "arrow.clockwise.circle"
        case .frozen: "exclamationmark.arrow.circlepath"
        case .working: "circle.dotted"
        case .verifying: "checkmark.circle.dotted"
        case .reviewing: "sparkles"
        case .auditing: "magnifyingglass"
        case .needsAttention: "questionmark.circle"
        case .needsReview: "exclamationmark.bubble"
        case .ready: "checkmark.circle"
        case .resumable: "clock.arrow.circlepath"
        case .failed: "exclamationmark.triangle"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var wantsAttention: Bool {
        self == .needsAttention || self == .needsReview || self == .engineMismatch || self == .frozen
            || isFailure
    }

    var isActive: Bool {
        switch self {
        case .starting, .preparing, .queued, .waitingForLimit, .waitingForCodex, .restartingFrozen,
             .working, .verifying, .reviewing, .auditing: true
        default: false
        }
    }

    static func resolve(instance: SupervisorInstance, bindingHasOutcome: Bool) -> DirectChatPhase {
        if instance.pendingQuestion != nil { return .needsAttention }

        if instance.auditState == "audit_running" || instance.reviewStage == "auditing" {
            return .auditing
        }
        if instance.reviewActive {
            return instance.reviewStage == "verifying" ? .verifying : .reviewing
        }
        // A running turn first: a message queued behind it is waiting, not being prepared, and the
        // header must describe what the worker is doing rather than what is next in line. Only
        // when the pane is genuinely idle does preparation explain the silence — nothing has been
        // typed at the worker, so every other signal here says nothing is going on.
        // Before "busy": a frozen Claude's status can say busy for hours, and that is exactly the
        // state the header must not call working.
        switch instance.frozenRecovery {
        case .restarting?: return .restartingFrozen
        case .gaveUp?: return .frozen
        case nil: break
        }
        if instance.workerStatus == "busy" { return .working }
        // Actually running, not merely next in line. These were one case until a message sat
        // behind a Codex usage window for an hour under a header that said both engines were
        // reading it.
        if instance.preparing {
            // Named, not assumed. A message read by Claude alone because Codex had no window left
            // is a different thing from one both engineers read, and the header said the second
            // either way.
            return .preparing(PeerReading(claudeSince: instance.peerClaude?.startedAt,
                                          codexSince: instance.peerCodex?.startedAt,
                                          codexOut: instance.codexUnavailable != nil,
                                          claudeOut: instance.claudeUnavailable != nil))
        }
        if instance.queuedNotStarted {
            // Only when the queue is genuinely held by a limit. A Codex pause sitting in the run
            // while the real reason is "the previous message is still being prepared" would put
            // the wrong engine's window on screen — the same misattribution in a new place.
            if instance.queueWaitReason == "limit"
                || (instance.queueWaitReason == nil && instance.pausedResumeAt != nil
                    && !instance.pausedOnCodex) {
                return .waitingForLimit(instance.pausedResumeAt)
            }
            // The message is being held BEFORE preparation rather than parked after it: there is
            // no pause marker to read a time off, because nothing has started. Saying "in line"
            // here would be the same silence this change exists to remove.
            if instance.queueWaitReason == "codex" { return .waitingForCodex(nil) }
            if instance.queueWaitReason == "engine-mismatch" { return .engineMismatch }
            // Only when the pause is what the queue is actually waiting on. A run parked on Codex
            // whose queue is really held by the message in front of it is a queue, and saying
            // "waiting for Codex" there would be the same misattribution the line above avoids.
            if instance.queueWaitReason == nil, instance.pausedOnCodex {
                return .waitingForCodex(instance.pausedResumeAt)
            }
            return .queued
        }
        if instance.pausedResumeAt != nil, instance.doneResult == nil {
            // Nothing queued, and the run itself is parked. Whose window it is decides what the
            // screen says: Claude's stops the conversation, Codex's stops the review — and saying
            // nothing at all, which is what this did, is what left a parked run looking idle.
            return instance.pausedOnCodex
                ? .waitingForCodex(instance.pausedResumeAt)
                : .waitingForLimit(instance.pausedResumeAt)
        }
        if instance.doneResult == "needs-user" { return .needsReview }
        if bindingHasOutcome || instance.outcome != nil || instance.doneResult != nil { return .ready }
        if instance.active || instance.watchdogAlive { return .working }
        return .resumable
    }
}

extension AppModel {
    // MARK: Sending

    func sendDirectMessage(_ raw: String, attachments: [Attachment] = []) {
        guard let productID = selectedProductID,
              let product = products.product(id: productID) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }

        let chat = conversations.currentChat(for: productID)
        let superseding = supersededChatIDs.remove(chat.id) != nil
        let message = directMessage(text, attachments: attachments, superseding: superseding)
        let userEntry = conversations.appendUser(text, productID: productID, chatID: chat.id,
                                                 attachments: attachments)
        if isDirectChatBusy(chat.id) {
            conversations.updateDelivery(entryID: userEntry.id, .queued)
        }
        products.worked(productID)
        chatErrors[chat.id] = nil
        deliver(message: message, entryID: userEntry.id, chat: chat, product: product)
    }

    // MARK: Codex-only

    private func deliverViaCodex(message: String, entryID: UUID, chat: Chat, product: Product) {
        guard let primary = chatPrimary(for: product, chatID: chat.id) else {
            conversations.updateDelivery(entryID: entryID, .failed)
            failChat(chat.id, String(localized: "Choose a primary project folder before sending."))
            return
        }
        sendingChatIDs.insert(chat.id)
        chatErrors[chat.id] = nil

        if conversations.chat(id: chat.id)?.session == nil {
            conversations.bindSession(ChatSessionBinding(primaryProjectID: primary.id,
                                                         projectPath: primary.path),
                                      to: chat.id)
        }

        let thread = conversations.chat(id: chat.id)?.session?.codexThreadID
        // `Automatic` means the chosen model's own default depth, which the catalogue knows and
        // differs per model — not one fixed level for all of them.
        let effort = codexModels.effort(settings.codexEffort, forSlug: settings.codexModel).rawValue
        let codexModel = settings.codexModel
        let cwd = URL(fileURLWithPath: primary.path)

        let answerID = conversations.beginForemanTurn(productID: product.id, chatID: chat.id,
                                                     kind: .codex)

        conversations.updateDelivery(entryID: entryID, nil)

        Task {
            defer {
                sendingChatIDs.remove(chat.id)
                codexTurns[chat.id] = nil
            }
            let path = await ShellEnvironment.shared.path()
            let outcome = await CodexChatRunner.send(
                prompt: message, threadID: thread, cwd: cwd, effort: effort,
                model: codexModel, path: path,
                register: { [weak self] runner in
                    Task { @MainActor in self?.codexTurns[chat.id] = runner }
                },
                onProgress: { [weak self] blocks in
                    Task { @MainActor in

                        self?.conversations.updateBlocks(entryID: answerID, blocks: blocks,
                                                         persist: false)
                    }
                })

            conversations.updateBlocks(entryID: answerID, blocks: outcome.blocks,
                                       text: Self.proseOf(outcome.blocks), persist: true)

            if let id = outcome.threadID, !id.isEmpty {
                conversations.updateSession(for: chat.id) { $0.codexThreadID = id }
            }
            if let reason = CodexStandIn.refusal(in: outcome.failure) {
                // Sent, refused for want of quota, and there is still a question waiting for an
                // answer. Which engine gives it is his call now: with the substitution switched on
                // Claude takes it straight away, and with it off — the default — the thread says
                // what happened and offers the same thing as a button. What it never does again is
                // quietly answer as somebody else and mention it afterwards.
                sendingChatIDs.remove(chat.id)
                codexTurns[chat.id] = nil
                if settings.claudeStandsInForCodex {
                    noteCodexStandIn(reason, in: chat, product: product)
                    deliverViaClaude(message: message, entryID: entryID, chat: chat, product: product)
                } else {
                    conversations.updateDelivery(entryID: entryID, .failed)
                    conversations.setCodexWall(entryID: entryID, reason.wall)
                }
                return
            }
            if let failure = outcome.failure {
                failChat(chat.id, failure)
            }
            products.worked(product.id)
        }
    }

    /// Say in the thread that Claude answered in Codex's place.
    ///
    /// Spoken by Night Shift rather than filed as an event, because the chat shows what was said
    /// and this is something he has to be able to read afterwards — not only while a toast is up.
    /// Not repeated: once the thread carries the sentence, saying it again on every message would
    /// bury the conversation in its own footnotes.
    private func noteCodexStandIn(_ reason: CodexStandIn.Reason, in chat: Chat, product: Product) {
        let sentence = reason.sentence
        let alreadySaid = conversations.entries(inChat: chat.id)
            .contains { $0.kind == .foreman && $0.text == sentence }
        if !alreadySaid {
            conversations.appendForeman(sentence, productID: product.id, chatID: chat.id)
        }
        toast = ToastMessage(text: sentence, kind: .info)
    }

    private static func proseOf(_ blocks: [ConversationBlock]) -> String {
        blocks.filter { $0.kind == .markdown }
            .map(\.text)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Taking a message back to edit it

    /// Whether this message can be pulled back into the composer.
    ///
    /// Only the last thing he said. Editing something from the middle of a thread would leave the
    /// app showing a conversation the agent's own session does not have, and every answer after it
    /// would be answering text that is no longer on screen.
    func canTakeBack(entryID: UUID) -> Bool {
        guard let entry = conversations.entry(id: entryID), entry.kind == .user,
              let chatID = entry.chatID else { return false }
        let lastSpoken = conversations.entries(inChat: chatID)
            .last { $0.kind == .user }
        return lastSpoken?.id == entryID
    }

    /// Stop what is running, take the message back, and put it in the composer to edit.
    ///
    /// The two outcomes are told apart rather than blurred. A message still sitting in the
    /// undelivered queue is genuinely un-sent and disappears from the thread. One the agent has
    /// already read stays on screen, marked as replaced — because it WAS read, and hiding it would
    /// make the next answer look like a reply to nothing.
    func takeBackMessage(entryID: UUID) {
        guard let entry = conversations.entry(id: entryID), entry.kind == .user,
              let chatID = entry.chatID, canTakeBack(entryID: entryID) else { return }
        let productID = entry.productID

        // A Codex-only chat has no queue: the prompt goes straight to a process, and cancelling
        // that process IS the withdrawal.
        if codexTurns[chatID] != nil { stopDirectChat(chatID) }

        let projectPath = conversations.chat(id: chatID)?.session?.projectPath

        Task {
            // Ask the engine FIRST, and only once.
            //
            // Stopping what is running used to come first — and once preparation counted as
            // running, that call and this one were two withdrawals of the same message racing each
            // other. The first took it back; the second found nothing left and reported it as
            // read, so the app marked a message the worker had never seen as read and hid it. The
            // engine's answer is the decision, and whatever it says is running afterwards is
            // stopped on the strength of that answer.
            let outcome: MessageWithdrawal.Outcome
            if let projectPath, !projectPath.isEmpty, settings.chatMode != .codex {
                outcome = await client.withdrawQueuedMessage(id: entryID, projectPath: projectPath)
                // Read means a turn may be running on it. That turn is what Stop is for.
                if outcome != .withdrawn, isDirectChatBusy(chatID) { stopDirectChat(chatID) }
            } else {
                outcome = .alreadyRead
            }

            handBackToComposer(entry, in: productID)
            chatErrors[chatID] = nil

            switch outcome {
            case .withdrawn:
                conversations.remove(entryID: entryID)
                toast = ToastMessage(text: String(localized: "Taken back — it never reached the agent."),
                                     kind: .success)
            case .alreadyRead, .unknown:
                conversations.updateDelivery(entryID: entryID, .replaced)
                supersededChatIDs.insert(chatID)
                toast = ToastMessage(text: String(localized: "It had already been read. Your next message will say it replaces this one."),
                                     kind: .info)
            }
        }
    }

    private func handBackToComposer(_ entry: ConversationEntry, in productID: UUID) {
        var draft = draftText(for: productID)
        // Anything already half-typed is kept: losing it to a button labelled "edit" would be
        // its own small betrayal.
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        setDraftText(draft.isEmpty ? entry.text : entry.text + "\n" + draft, for: productID)
        for attachment in entry.attachments { addDraftAttachment(attachment, to: productID) }
        composerFocusRequest = UUID()
    }

    func retryDirectMessage(entryID: UUID) {
        guard let entry = conversations.entry(id: entryID), entry.kind == .user,
              let product = products.product(id: entry.productID),
              let chatID = entry.chatID, let chat = conversations.chat(id: chatID),
              !sendingChatIDs.contains(chatID) else { return }
        conversations.updateDelivery(entryID: entryID, nil)
        chatErrors[chatID] = nil
        trustBlocked[chatID] = nil
        gitConsentBlocked[chatID] = nil
        handoffBlocked[chatID] = nil
        signInBlocked[chatID] = nil
        conversations.setCodexWall(entryID: entryID, nil)
        deliver(message: directMessage(entry.text, attachments: entry.attachments),
                entryID: entryID, chat: chat, product: product)
    }

    /// Send the message Codex refused to Claude instead — because he pressed the button.
    ///
    /// The same delivery Codex's refusal used to trigger by itself. What changed is only who
    /// decided, and that is the whole feature: an answer from the wrong engineer is worth having
    /// when it was asked for, and worth nothing when it merely appeared.
    ///
    /// The offer is CONSUMED before anything is sent. Two presses on the same row, or a button
    /// still on screen in a window that has not refreshed, would otherwise each send the message
    /// again — and the offer is read from the entry, so there is exactly one of it per refused
    /// message rather than one per chat.
    func answerWithClaudeInstead(entryID: UUID, in chatID: UUID) {
        guard let entry = conversations.entry(id: entryID), entry.kind == .user,
              let product = products.product(id: entry.productID),
              let chat = conversations.chat(id: chatID),
              !sendingChatIDs.contains(chatID) else { return }
        guard conversations.consumeCodexWall(entryID: entryID) != nil else { return }
        chatErrors[chatID] = nil
        conversations.updateDelivery(entryID: entryID, nil)
        conversations.appendForeman(String(localized: "Claude answered this one — you asked it to, because Codex had no window left."),
                                    productID: product.id, chatID: chatID)
        deliverViaClaude(message: directMessage(entry.text, attachments: entry.attachments),
                         entryID: entryID, chat: chat, product: product)
    }

    /// Stop the run that holds this project, then send the message that was refused.
    ///
    /// Uses the same checked release the automatic hand-over uses: the instance and the session
    /// both have to be gone before anything is sent, or the next send is made against stale state.
    func stopHolderAndRetry(entryID: UUID, in chatID: UUID) {
        guard let plan = handoffBlocked[chatID] else { return }
        handoffBlocked[chatID] = nil
        chatErrors[chatID] = nil
        conversations.updateDelivery(entryID: entryID, nil)

        Task {
            let failure = await releaseProject(.init(projectPath: plan.projectPath,
                                                     session: plan.session,
                                                     resumesOwnSession: plan.resumesOwnSession))
            if let failure {
                conversations.updateDelivery(entryID: entryID, .failed)
                failChat(chatID, Self.releaseProblem(failure))
                return
            }
            if plan.resumesOwnSession {
                conversations.updateSession(for: chatID) { $0.activeRunID = nil }
            }
            note(.taskEdited, .info, "Зупинив «\(plan.holderTitle)» на твоє прохання",
                 detail: plan.projectPath, projectPath: plan.projectPath)
            retryDirectMessage(entryID: entryID)
        }
    }

    func trustFolders(_ folders: [String]) {
        let granted = folders.filter { ClaudeFolderTrust.grant(forProjectPath: $0) }
        if granted.isEmpty {
            toast = ToastMessage(text: String(localized: "Could not write the trust setting. Open a terminal in the folder and run `claude` once."),
                                 kind: .error)
        } else {
            toast = ToastMessage(text: granted.count == 1
                                 ? String(format: String(localized: "Claude Code can now work in “%@”."),
                                          (granted[0] as NSString).lastPathComponent)
                                 : String(localized: "Claude Code can now work in the folders it asked about."),
                                 kind: .success)
        }
        // Free checks: trusting a folder cannot change whether Claude or Codex answers, and
        // re-proving that costs a paid turn for nothing.
        Task { await refreshReadiness(force: true, depth: .free) }
    }

    /// The director allowed git in this folder — record it and retry what did not go through.
    ///
    /// The consent goes to the engine, not to the folder: `.git` appears when work starts there,
    /// and only if the folder is fit for it. The engine checks that again itself, so the button
    /// cannot allow git where it is forbidden — in a store, in someone else's repository, in a
    func allowGitIn(_ folder: String, thenRetry entryID: UUID?, in chatID: UUID?) {
        Task {
            let r = await client.allowGit(projectPath: folder)
            guard r.ok else {
                let why = r.combined.split(whereSeparator: \.isNewline).first.map(String.init)
                toast = ToastMessage(text: why ?? String(localized: "Could not record the answer."),
                                     kind: .error)
                return
            }
            if let chatID {
                gitConsentBlocked[chatID] = nil
                chatErrors[chatID] = nil
            }
            toast = ToastMessage(text: String(format: String(localized: "Git will be created in “%@” when work starts there."),
                                              (folder as NSString).lastPathComponent),
                                 kind: .success)
            if let entryID { retryDirectMessage(entryID: entryID) }
        }
    }

    func trustFolder(_ folder: String, thenRetry entryID: UUID?, in chatID: UUID?) {
        guard ClaudeFolderTrust.grant(forProjectPath: folder) else {
            toast = ToastMessage(text: String(localized: "Could not write the trust setting. Open a terminal in the folder and run `claude` once."),
                                 kind: .error)
            return
        }
        if let chatID {
            trustBlocked[chatID] = nil
        gitConsentBlocked[chatID] = nil
            handoffBlocked[chatID] = nil
            chatErrors[chatID] = nil
        }
        toast = ToastMessage(text: String(format: String(localized: "Claude Code can now work in “%@”."),
                                          (folder as NSString).lastPathComponent),
                             kind: .success)

        // Free checks: trusting a folder cannot change whether Claude or Codex answers, and
        // re-proving that costs a paid turn for nothing.
        Task { await refreshReadiness(force: true, depth: .free) }
        if let entryID { retryDirectMessage(entryID: entryID) }
    }

    private func deliver(message: String, entryID: UUID, chat: Chat, product: Product) {
        // Codex out of weekly quota is a wall, not a failure worth an evening. Claude takes the
        // message instead — and the thread is told, because a substitution nobody mentioned is
        // worse than the wall.
        switch ChatRoute.decide(mode: settings.chatMode,
                                standIn: CodexStandIn.insteadOfCodex(
                                    usage: capacity.codex,
                                    enabled: settings.claudeStandsInForCodex)) {
        case .codex:
            deliverViaCodex(message: message, entryID: entryID, chat: chat, product: product)
        case .claude(let standIn):
            if let standIn { noteCodexStandIn(standIn, in: chat, product: product) }
            deliverViaClaude(message: message, entryID: entryID, chat: chat, product: product)
        }
    }

    private func deliverViaClaude(message: String, entryID: UUID, chat: Chat, product: Product) {
        if isDirectChatBusy(chat.id) {
            conversations.updateDelivery(entryID: entryID, .queued)
        }
        sendingChatIDs.insert(chat.id)

        Task {
            defer { sendingChatIDs.remove(chat.id) }
            guard let primary = chatPrimary(for: product, chatID: chat.id) else {
                conversations.updateDelivery(entryID: entryID, .failed)
                failChat(chat.id, String(localized: "Choose a primary project folder before sending."))
                return
            }
            guard let files = writeSessionContext(chatID: chat.id, product: product,
                                                  primary: primary) else {
                conversations.updateDelivery(entryID: entryID, .failed)
                failChat(chat.id, String(localized: "Could not prepare the project context."))
                return
            }

            var binding = conversations.chat(id: chat.id)?.session

            if let stale = binding, matchingInstance(for: stale) == nil,
               let live = instanceForAdoption(projectPath: stale.projectPath, chatID: chat.id) {
                let rebound = makeBinding(for: primary, instance: live, keeping: stale)
                conversations.bindSession(rebound, to: chat.id)
                binding = rebound
            }
            // A binding that names no session and has no run behind it is a note of where this
            // conversation lives, not something to send a message to. Treating it as one skipped
            // the launch below and handed the engine a session id it does not have, which comes
            // back `TIER=none` — nothing typed, nothing said. A chat moved to another folder (its
            // workspace expanded into the repositories inside it) is exactly that shape, and it
            // would have been left mute.
            if let held = binding,
               !Self.bindingCanReceive(sessionID: held.claudeSessionID,
                                       hasLiveInstance: matchingInstance(for: held) != nil) {
                binding = nil
            }
            // WHO HOLDS THE PROJECT — asked on every send, not only when this chat has no
            // binding. The first version asked only in the no-binding branch, which made the
            // handover one-way: a new chat could take an idle project, and the chat it took it
            // from could never take it back, because it still had a binding and skipped this
            // entirely. Its next message then met a live run belonging to someone else and came
            // back as a conflict.
            let held = holderOfProject(primary.path, excluding: chat.id)
            switch ProjectHandoff.decide(holderTitle: held?.chat.title,
                                         holderProjectPath: held?.instance.projectPath ?? primary.path,
                                         holderSession: held?.instance.session ?? "",
                                         holderIsTakeable: held?.instance.isTakeable ?? false,
                                         callerHasSessionID: binding?.claudeSessionID != nil) {
            case .proceed:
                break
            case .refuse(let holder):
                conversations.updateDelivery(entryID: entryID, .failed)
                // Named, with the offer attached: the decision is the director's, but it is
                // takeable here rather than in a terminal.
                handoffBlocked[chat.id] = PendingHandoff(
                    holderTitle: holder,
                    projectPath: held?.instance.projectPath ?? primary.path,
                    session: held?.instance.session ?? "",
                    resumesOwnSession: binding?.claudeSessionID != nil)
                failChat(chat.id, String(format: String(localized:
                    "“%@” is still working in this project. It may be waiting on you rather than finished, so nothing was stopped."),
                    holder))
                return
            case .takeOver(let plan):
                // Whether this was a run that ended properly or one nobody was coming back to —
                // worth knowing afterwards, because the second kind is cleared without being asked
                // about and a run should not simply vanish from under somebody.
                let abandoned = held?.instance.isFinished == false
                if let failure = await releaseProject(plan) {
                    conversations.updateDelivery(entryID: entryID, .failed)
                    failChat(chat.id, Self.releaseProblem(failure))
                    return
                }
                if abandoned, let title = held?.chat.title {
                    note(.taskEdited, .info, "Прибрав зупинену роботу «\(title)» — вона нічого не робила",
                         detail: held?.instance.projectPath, projectPath: held?.instance.projectPath)
                }
                if plan.resumesOwnSession {
                    // Keep the id that resumes this conversation; drop the run that no longer
                    // exists, or the engine refuses the send on a run-id mismatch.
                    conversations.updateSession(for: chat.id) { $0.activeRunID = nil }
                    binding = conversations.chat(id: chat.id)?.session
                }
            }

            if binding == nil {
                if let existing = instanceForAdoption(projectPath: primary.path, chatID: chat.id) {
                    binding = makeBinding(for: primary, instance: existing)
                    conversations.bindSession(binding!, to: chat.id)
                } else if let folder = ClaudeFolderTrust.folderNeedingTrust(forProjectPath: primary.path) {

                    conversations.updateDelivery(entryID: entryID, .failed)
                    trustBlocked[chat.id] = folder
                    failChat(chat.id, ClaudeFolderTrust.problem(forProjectPath: primary.path)
                             ?? String(localized: "Claude Code has not been trusted with this folder."))
                    return
                } else {
                    let launch = await client.startChat(
                        projectPath: primary.path,
                        contextFile: files.context.path,
                        extraDirsFile: files.directories.path,
                        claudeEffort: claudeModels.effortFlag(settings.claudeEffort,
                                                              for: settings.claudeModel),
                        claudeModel: settings.claudeModel.flagValue,
                        codexEffort: codexModels.effort(settings.codexEffort,
                                                        forSlug: settings.codexModel).rawValue,
                        codexModel: settings.codexModel,
                        collaboration: settings.chatMode.collaborationMode)
                    guard launch.ok,
                          let instance = await client.awaitChatInstance(projectPath: primary.path)
                    else {
                        conversations.updateDelivery(entryID: entryID, .failed)

                        let detail = launch.stderr.isEmpty ? launch.stdout : launch.stderr
                        // 76 — the engine did not refuse to work, it asked. This folder has no git, and
                        // without a baseline the night shift has nowhere to roll back to. The answer is a button.
                        if launch.exitCode == 76 {
                            gitConsentBlocked[chat.id] = primary.path
                            failChat(chat.id, detail)
                            return
                        }
                        if let trust = ClaudeFolderTrust.problem(forProjectPath: primary.path) {
                            trustBlocked[chat.id] = ClaudeFolderTrust
                                .folderNeedingTrust(forProjectPath: primary.path) ?? primary.path
                            failChat(chat.id, trust)
                        } else {
                            failChat(chat.id, detail.isEmpty ? "Night Shift did not start." : detail)
                        }
                        return
                    }
                    binding = self.makeBinding(for: primary, instance: instance)
                    conversations.bindSession(binding!, to: chat.id)
                }
            }

            guard let bound = binding else {
                conversations.updateDelivery(entryID: entryID, .failed)
                return
            }

            conversations.updateSession(for: chat.id) { $0.outcomeAt = nil }

            do {
                try await client.setReviewGate(enabled: settings.chatMode.reviewsWork,
                                               projectPath: bound.projectPath)
            } catch {
                conversations.updateDelivery(entryID: entryID, .failed)
                failChat(chat.id, String(localized: "Could not set the mode for this run, so nothing was sent. Check that the run folder is writable."))
                return
            }
            let result = await client.workerSend(projectPath: bound.projectPath,
                                                 sessionID: bound.claudeSessionID,
                                                 // The branch this conversation recorded. Passing
                                                 // nil made an older chat with no run id read as
                                                 // somebody else's run and come back a conflict.
                                                 branch: bound.branch,
                                                 runID: bound.activeRunID,
                                                 message: message,
                                                 messageID: entryID,
                                                 intent: .conversation,
                                                 pipeline: settings.chatMode.messagePipeline,
                                                 runEnv: self.engineChoices(),
                                                 contextFile: files.context.path,
                                                 extraDirsFile: files.directories.path)
            switch result.tier {
            case .live, .resumed:
                conversations.updateDelivery(entryID: entryID,
                                             result.uncertain ? .queued : nil)
                if let instance = await client.awaitChatInstance(projectPath: bound.projectPath,
                                                                 timeout: 8) {
                    conversations.bindSession(self.makeBinding(for: primary, instance: instance,
                                                                keeping: bound), to: chat.id)
                }
                await refresh(codex: false)
            case .preparing:
                // Accepted, and genuinely not delivered: the two positions are being formed. The
                // row says queued because that is what it is, and the header says who is reading.
                conversations.updateDelivery(entryID: entryID, .queued)
                chatErrors[chat.id] = nil
                if let instance = await client.awaitChatInstance(projectPath: bound.projectPath,
                                                                 timeout: 8) {
                    conversations.bindSession(self.makeBinding(for: primary, instance: instance,
                                                                keeping: bound), to: chat.id)
                }
                await refresh(codex: false)
            case .queued:
                conversations.updateDelivery(entryID: entryID, .queued)
                chatErrors[chat.id] = nil
                await refresh(codex: false)
            case .conflict:
                conversations.updateDelivery(entryID: entryID, .failed)

                failChat(chat.id, String(localized: "Another Night Shift run is working in this project. Wait for it to finish, or stop it, and send again."))
            case .none:
                conversations.updateDelivery(entryID: entryID, .failed)
                failChat(chat.id, bound.claudeSessionID == nil
                         ? String(localized: "This older chat has no resume id. Start a new chat to continue.")
                         : String(localized: "Night Shift could not resume this conversation. Your history is intact."))
            case .error:
                conversations.updateDelivery(entryID: entryID, .failed)
                failChat(chat.id, result.message.isEmpty ? String(localized: "The message was not delivered.") : result.message)
            }
        }
    }

    /// The models and depths the composer is showing, handed to the engine on every send.
    ///
    /// Every send, not only at session start: the preflight, the consultations and the review gate
    /// are separate processes started later, and the only thing that reaches them is what the
    /// engine wrote down for the run.
    func engineChoices() -> [String: String] {
        SupervisorClient.runEnv(
            claudeEffort: claudeModels.effortFlag(settings.claudeEffort,
                                                   for: settings.claudeModel),
            claudeModel: settings.claudeModel.flagValue,
            codexEffort: codexModels.effort(settings.codexEffort, forSlug: settings.codexModel).rawValue,
            codexModel: settings.codexModel,
            collaboration: settings.chatMode.collaborationMode)
    }

    private func directMessage(_ text: String, attachments: [Attachment],
                               superseding: Bool = false) -> String {
        var parts: [String] = []
        // A message he took back after the agent had read it cannot be un-read, so the
        // replacement says so out loud rather than hoping the agent works it out.
        if superseding { parts.append(MessageWithdrawal.supersedingPreamble()) }
        if !text.isEmpty { parts.append(text) }
        let paths = attachments.compactMap { attachment -> String? in
            if let url = capture.url(for: attachment) { return "- \(attachment.filename): \(url.path)" }
            if let link = attachment.urlString { return "- \(attachment.filename): \(link)" }
            return nil
        }
        if !paths.isEmpty {
            parts.append("Attached files are available at these paths:\n" + paths.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private func primaryProject(for product: Product) -> Project? {
        product.defaultProjectID.flatMap { projects.project(id: $0) }
    }

    /// Whether there is anything on the other end of a chat's binding.
    ///
    /// Either a session id this conversation can be resumed into, or a run of its own still alive.
    /// With neither, a message has nowhere to go and a session has to be started first.
    nonisolated static func bindingCanReceive(sessionID: String?, hasLiveInstance: Bool) -> Bool {
        (sessionID.map { !$0.isEmpty } ?? false) || hasLiveInstance
    }

    /// The folder this conversation should actually run in.
    ///
    /// A chat remembers the folder it started in, and that memory outlives the product's resources:
    /// disconnect a folder — or expand a workspace into the repositories inside it — and the saved
    /// id still points at something the product no longer has. Sending in that chat then started a
    /// worker in the old folder and wrote it into the context as writable, so the repair looked
    /// like it had changed nothing.
    ///
    /// A saved primary counts only while it is still one of the product's folders. When it is not,
    /// the product's own default takes over and the binding is rewritten, so the cwd, the context
    /// and the additional directories all move together.
    func chatPrimary(for product: Product, chatID: UUID) -> Project? {
        let saved = conversations.chat(id: chatID)?.session?.primaryProjectID
        if let saved, product.allProjectIDs.contains(saved), let project = projects.project(id: saved) {
            return project
        }
        guard let fallback = primaryProject(for: product) else { return nil }
        if saved != nil, conversations.chat(id: chatID)?.session != nil {
            conversations.bindSession(ChatSessionBinding(primaryProjectID: fallback.id,
                                                         projectPath: fallback.path),
                                      to: chatID)
        }
        return fallback
    }

    func makeBinding(for project: Project, instance: SupervisorInstance,
                             keeping old: ChatSessionBinding? = nil) -> ChatSessionBinding {
        ChatSessionBinding(primaryProjectID: project.id,
                           projectPath: project.path,
                           claudeSessionID: instance.sessionID ?? old?.claudeSessionID,

                           codexThreadID: old?.codexThreadID,
                           activeRunID: instance.runID,
                           branch: instance.branch,
                           startedAt: instance.startedAt ?? old?.startedAt ?? Date(),
                           outcomeAt: old?.outcomeAt,
                           lastCompletedTurnKey: old?.lastCompletedTurnKey,
                           lastReportedTurnKey: old?.lastReportedTurnKey,
                           reportPaths: old?.reportPaths ?? [])
    }

    /// The chat that currently holds this project's session, and whether it is actually working.
    ///
    /// One project has one tmux session and one Claude context, so two chats cannot speak into it
    /// at once — that constraint is real. What was wrong was WHO the constraint asked about: it
    /// asked whether another chat was BOUND, never whether that chat was doing anything. A
    /// conversation the director had finished held the project for ever, and the only way out was
    /// to stop the night shift by hand.
    ///
    /// Being bound is not being busy. `turnRunning` is.
    private func holderOfProject(_ projectPath: String, excluding chatID: UUID)
        -> (chat: Chat, instance: SupervisorInstance)? {
        let path = Slug.canonicalPath(projectPath)
        guard let instance = snapshot.instances.first(where: {
            Slug.canonicalPath($0.projectPath) == path
        }) else { return nil }
        let holder = conversations.chats.first { chat in
            guard chat.id != chatID, let session = chat.session else { return false }
            return (instance.runID != nil && session.activeRunID == instance.runID)
                || (instance.sessionID != nil && session.claudeSessionID == instance.sessionID)
        }
        return holder.map { ($0, instance) }
    }

    /// Take an IDLE project over for this chat.
    ///
    /// Nothing is lost by doing so, which is what makes it safe: the chat that had it keeps its
    /// `claudeSessionID`, and `worker-send.sh` resumes that session on its next message — the same
    /// path a chat already takes after the app is quit and reopened. So the session is a runtime
    /// the two chats take turns holding, not the identity of either.
    ///
    /// The tmux session is killed as well as the instance. Stopping the instance deliberately
    /// leaves the session alive, and a fresh chat starting into a live session would inherit the
    /// previous conversation's context — which is the one thing a new chat exists to avoid.
    /// Free a FINISHED project so this chat can use it. Returns the reason it could not be freed.
    ///
    /// Confirmed on both halves, not assumed on one. Stopping an instance deliberately leaves its
    /// tmux session alive, so the session is killed too — a new chat starting into a live session
    /// would inherit the previous conversation's context, the one thing a new chat exists to
    /// avoid. And an instance record left behind means the app still sees a run that is not there,
    /// so the next send would be made against stale state.
    ///
    /// Nothing is lost by this. The chat that had the project keeps its `claudeSessionID`, and
    /// `worker-send.sh` resumes that session on its next message — the same path a chat already
    /// takes after the app is quit and reopened.
    private func releaseProject(_ plan: ProjectHandoff.TakeOver) async -> ProjectRelease.Failure? {
        await releaseProject(path: plan.projectPath, session: plan.session)
    }

    /// The same sequence, for a project named rather than handed over: stop it, close its session,
    /// and confirm both are really gone before telling anybody it worked.
    func releaseProject(path: String, session: String) async -> ProjectRelease.Failure? {
        let release = ProjectRelease(
            stop: { [client] in
                let r = await client.stopNightShift(project: path)
                let detail = r.stderr.isEmpty ? r.stdout : r.stderr
                return (r.exitCode == 0, detail.trimmingCharacters(in: .whitespacesAndNewlines))
            },
            killSession: { [client] in
                guard !session.isEmpty else { return }
                _ = await client.killSession(session)
            },
            instanceGone: { [client] in
                let live = await client.readInstances()
                return !live.contains { Slug.canonicalPath($0.projectPath) == Slug.canonicalPath(path) }
            },
            sessionGone: { [client] in
                guard !session.isEmpty else { return true }
                return await client.sessionExists(session) == false
            },
            wait: { try? await Task.sleep(for: .milliseconds(250)) })
        let failure = await release.run()
        await refresh(codex: false)
        return failure
    }

    /// A live instance for this project that no other chat has claimed — this chat may simply
    /// take it, without stopping anything.
    private func instanceForAdoption(projectPath: String, chatID: UUID) -> SupervisorInstance? {
        let path = Slug.canonicalPath(projectPath)
        return snapshot.instances.first { instance in
            guard Slug.canonicalPath(instance.projectPath) == path else { return false }
            return !conversations.chats.contains { other in
                guard other.id != chatID, let session = other.session else { return false }
                return (instance.runID != nil && session.activeRunID == instance.runID)
                    || (instance.sessionID != nil && session.claudeSessionID == instance.sessionID)
            }
        }
    }

    /// Why it could not be freed, in the words that tell him what to do about it.
    nonisolated static func releaseProblem(_ failure: ProjectRelease.Failure) -> String {
        switch failure {
        case .stopRefused(let detail):
            return detail.isEmpty
                ? String(localized: "Could not stop the other chat's run in this project.")
                : String(format: String(localized: "Could not stop the other chat's run: %@"), detail)
        case .instanceRemains:
            return String(localized: "The other chat's run is still registered. Stop it there and send again.")
        case .sessionRemains:
            return String(localized: "The other chat's session is still open. Stop it there and send again.")
        }
    }

    /// The engine writes a refusal over several lines: the reason, what it found, what to do.
    ///
    /// Only the first line used to arrive here — and the user saw «the folder is deeper than 4
    /// levels» with none of the repository list and no advice. Now the whole text is in the chat;
    /// the notification, which has no room, gets the first line, because the rest is visible next
    private func failChat(_ chatID: UUID, _ message: String) {
        let full = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = full.split(whereSeparator: \.isNewline).first.map(String.init) ?? full
        chatErrors[chatID] = full
        toast = ToastMessage(text: headline, kind: .error)
    }

    // MARK: Project context

    private func writeSessionContext(chatID: UUID, product: Product,
                                     primary: Project) -> (context: URL, directories: URL)? {
        let folder = AppSupport.root.appendingPathComponent("chats/\(chatID.uuidString)", isDirectory: true)
        let context = folder.appendingPathComponent("context.md")
        let directories = folder.appendingPathComponent("additional-directories.txt")

        var resourceLines: [String] = []
        var extraPaths: [String] = []
        for resource in product.resources {
            if let projectID = resource.projectID, let project = projects.project(id: projectID) {
                let policy = resource.access == .workspace ? "можно изменять" : "сначала спросить перед изменением"
                let role = project.id == primary.id ? "основная папка" : "дополнительная папка"
                resourceLines.append("- \(resource.name) — \(role), \(policy): `\(project.path)`"
                                      + (resource.note.isEmpty ? "" : " — \(resource.note)"))
                if project.id != primary.id { extraPaths.append(project.path) }
            } else if let url = resource.urlString, !url.isEmpty {
                resourceLines.append("- \(resource.name) — ссылка: \(url)"
                                      + (resource.note.isEmpty ? "" : " — \(resource.note)"))
            }
        }
        // Only for a product that has no folders at all. A primary that is not among the resources
        // used to be written in here as writable, which is how a disconnected folder came back into
        // the context with permission to edit it; `chatPrimary(for:chatID:)` now settles that
        // before we get here.
        if !product.resources.contains(where: { $0.projectID == primary.id }) {
            resourceLines.insert("- \(primary.name) — основная папка, можно изменять: `\(primary.path)`",
                                 at: 0)
        }
        extraPaths = Array(Set(extraPaths.map(Slug.canonicalPath))).sorted()

        let contextText = """
        Ты работаешь в обычном долгоживущем диалоге Night Shift, который показан через приложение Bulava.
        Это не задача бригадира: не классифицируй сообщения, не создавай внутренние карточки и не считай
        уточнение новой задачей. Продолжай тот же разговор ровно как в интерактивном терминале.

        ## Продукт
        - Название: \(product.name)
        - Кратко: \(product.summary.isEmpty ? "не указано" : product.summary)
        - Что владелец написал о продукте: \(product.brief.isEmpty ? "ничего" : product.brief)

        ## Папки и политика
        \(resourceLines.isEmpty ? "- \(primary.name) — основная папка, можно изменять: `\(primary.path)`" : resourceLines.joined(separator: "\n"))

        Политика «сначала спросить» — договорённость, а не физическое ограничение. Читай такую папку
        свободно. До первого изменения объясни, что именно нужно поменять, и попроси разрешение. Если
        пользователь явно разрешил изменение в этом диалоге, продолжай без изменения настроек продукта.

        Отчёт не создавай автоматически. В конце кратко подведи итог обычным сообщением; приложение само
        предложит подготовить отдельный отчёт в правой панели. Если отчёт запрошен, он должен лежать в `artifacts/` основной
        папки, а `artifacts/` должен быть в `.gitignore`.

        Обычная проверка Codex оценивает только текущую просьбу пользователя. Полный аудит всего продукта
        никогда не запускается автоматически. Если пользователь прямо попросил полный аудит — словами на любом
        языке или через `/deep-audit` — запусти `deep-audit "$PWD" "<контекст запроса>"`, дождись отчёта и покажи
        выводы. Не начинай исправлять найденный общепродуктовый backlog без отдельного согласия пользователя.
        """

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try contextText.write(to: context, atomically: true, encoding: .utf8)
            try (extraPaths.joined(separator: "\n") + (extraPaths.isEmpty ? "" : "\n"))
                .write(to: directories, atomically: true, encoding: .utf8)
            return (context, directories)
        } catch {
            return nil
        }
    }

    // MARK: Transcript reconciliation

    func syncDirectChats() {
        var desired: Set<UUID> = []
        // What the screen shows, not where the app writes: an archived chat opened to read is the
        // visible one, and its transcript must catch up like any other on screen.
        let visibleChatID = selectedProductID.flatMap { conversations.displayedChatID(for: $0) }

        for chat in conversations.chats {
            guard let binding = chat.session else { continue }
            let instance = matchingInstance(for: binding)
            if let instance {
                var updated = binding
                updated.activeRunID = instance.runID
                updated.claudeSessionID = instance.sessionID ?? updated.claudeSessionID
                updated.branch = instance.branch
                if (instance.outcome != nil || instance.doneResult != nil), updated.outcomeAt == nil {
                    updated.outcomeAt = instance.finishedAt ?? Date()
                }
                if updated != binding { conversations.bindSession(updated, to: chat.id) }
                reconcileDelivery(in: chat.id, with: instance)
                syncCodexArtifacts(in: chat, from: instance)
                syncPendingQuestion(in: chat, from: instance)
                adoptRunReport(in: chat, from: instance)
            } else {
                resolveLostMessages(in: chat)
            }
            noticeExpiredLogin(in: chat)

            let sessionID = instance?.sessionID ?? binding.claudeSessionID
            let isLive = instance?.active == true || instance?.watchdogAlive == true
            guard let sessionID, chat.id == visibleChatID || isLive else { continue }
            let transcript = WorkerTrail.directory(for: binding.projectPath)
                .appendingPathComponent("\(sessionID).jsonl")
            guard FileManager.default.fileExists(atPath: transcript.path) else { continue }
            desired.insert(chat.id)
            if let feed = chatFeeds[chat.id], feed.sessionID == sessionID { continue }
            chatFeeds[chat.id]?.stop()
            let feed = ChatTranscriptFeed(chatID: chat.id, productID: chat.productID,
                                          sessionID: sessionID, transcript: transcript,
                                          store: conversations)
            chatFeeds[chat.id] = feed
            feed.start()
        }

        for (chatID, feed) in chatFeeds where !desired.contains(chatID) {
            feed.stop()
            chatFeeds[chatID] = nil
        }
    }

    /// What the conversation actually shows, with the CLI's sign-in notice taken out of it.
    ///
    /// The notice is hidden rather than annotated. Leaving it up is the whole defect: it reads as
    /// the worker's answer, and the answer it gives is to type `/login` into a terminal this window
    /// does not have. What happened is said once, in the app's own words, next to the message that
    /// went unanswered.
    func visibleEntries(inChat chatID: UUID) -> [ConversationEntry] {
        conversations.entries(inChat: chatID).filter { entry in
            guard entry.kind == .user || entry.kind == .foreman
                    || entry.kind == .codex || entry.kind == .question else { return false }
            return entry.hiddenNotice != true
        }
    }

    /// Where the sign-in panel belongs in this chat: beside the message the notice failed to
    /// answer, and nowhere else.
    func signInPromptEntryID(inChat chatID: UUID?) -> UUID? {
        chatID.flatMap { signInBlocked[$0]?.askedEntryID }
    }

    /// Catch the CLI answering "sign in" and stop presenting it as an answer.
    ///
    /// The worker is not broken and the run did not fail, so nothing else in this file notices:
    /// Claude Code simply replies with "Login expired · Please run /login" and everything
    /// downstream treats that as what the worker said.
    ///
    /// Armed against the notice ENTRY, not against the chat. A second expired answer after a
    /// retry is a new turn with a new entry, and it has to raise the wall again — keyed by chat,
    /// the second one was swallowed and the reader was left watching a message go nowhere.
    func noticeExpiredLogin(in chat: Chat) {
        let entries = conversations.entries(inChat: chat.id)
        guard let notice = entries.last(where: { $0.kind == .foreman && !$0.text.isEmpty }),
              PreflightRunner.isSignInNotice(notice.text) else {
            // A real answer arrived. The offer goes; what was hidden stays hidden, because the
            // notice is no more an answer now than it was then.
            if signInBlocked.removeValue(forKey: chat.id) != nil { chatErrors[chat.id] = nil }
            return
        }
        // Recognised once and hidden for good — including on the refresh right after Send again,
        // and including tomorrow morning, when this same old notice is still the last thing in the
        // thread and must not raise the wall again over a message long since re-sent.
        guard notice.hiddenNotice != true else { return }
        conversations.hideNotice(entryID: notice.id)

        // The message it was answering is the last one sent before it — not simply the last one in
        // the chat, which after a queued send is a message that has not been tried yet.
        let asked = entries.prefix(while: { $0.id != notice.id })
            .last(where: { $0.kind == .user })
        signInBlocked[chat.id] = SignInBlock(noticeEntryID: notice.id, askedEntryID: asked?.id)
        if let asked { conversations.updateDelivery(entryID: asked.id, .failed) }
        failChat(chat.id, String(localized: "Claude's login has run out, so this was never answered. Sign in and send it again."))
    }

    func matchingInstance(for binding: ChatSessionBinding) -> SupervisorInstance? {
        snapshot.instances.first { instance in
            guard Slug.canonicalPath(instance.projectPath) == Slug.canonicalPath(binding.projectPath) else {
                return false
            }
            if let run = binding.activeRunID, instance.runID == run { return true }
            if let session = binding.claudeSessionID, instance.sessionID == session { return true }
            return false
        }
    }

    private func resolveLostMessages(in chat: Chat) {
        guard !sendingChatIDs.contains(chat.id) else { return }
        guard let projectPath = chat.session?.projectPath else { return }
        guard conversations.entries(inChat: chat.id)
            .contains(where: { $0.kind == .user && $0.delivery == .queued }) else { return }

        Task {

            let parked = await client.parkedMessageIDs(projectPath: projectPath)
            let lost = conversations.failOrphanedQueued(inChat: chat.id, olderThan: 90,
                                                        stillParked: parked.queued)
            for message in lost {
                let excerpt = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                conversations.postEventOnce(
                    String(format: String(localized: "This message never reached the worker — the run it was queued in is gone. Send it again: “%@”"),
                           String(excerpt.prefix(60))),
                    productID: chat.productID, chatID: chat.id, tone: .problem)
            }
        }
    }

    private func adoptRunReport(in chat: Chat, from instance: SupervisorInstance) {
        let known = Set(chat.session?.reportPaths ?? [])
        let keys = instance.finishedDispatches.compactMap(\.reportKey).filter { !$0.isEmpty }
        guard !keys.isEmpty else { return }
        Task {
            for key in keys {
                guard let page = await client.artifactPage(task8: key),
                      !known.contains(page.path) else { continue }
                conversations.addReport(page.path, to: chat.id)
            }
        }
    }

    private func reconcileDelivery(in chatID: UUID, with instance: SupervisorInstance) {
        let queued = Set(instance.queuedMessageIDs)
        let failed = Set(instance.failedMessageIDs)
        for entry in conversations.entries(inChat: chatID)
            where entry.kind == .user && entry.delivery != nil {
            // `.replaced` is not a delivery state the engine knows about — it is his own decision
            // to take a message back, and reconciling against the queue must not erase it.
            guard entry.delivery != .replaced else { continue }
            let next: ConversationEntry.Delivery? = failed.contains(entry.id) ? .failed
                : queued.contains(entry.id) ? .queued : nil
            conversations.updateDelivery(entryID: entry.id, next)
        }

        conversations.withdrawStaleLostNotices(inChat: chatID)
    }

    private func syncCodexArtifacts(in chat: Chat, from instance: SupervisorInstance) {
        for artifact in instance.codexArtifacts {
            let id = ChatTranscriptFeed.entryID(chatID: chat.id, sessionID: "codex-review",
                                                turnKey: artifact.key)
            guard conversations.entry(id: id) == nil else { continue }
            conversations.append(ConversationEntry(
                id: id, productID: chat.productID, chatID: chat.id, kind: .codex,
                at: artifact.at.addingTimeInterval(0.002), text: artifact.text,
                tone: artifact.text.contains("VERDICT: FAIL") ? .problem : .neutral))
        }
    }

    private func syncPendingQuestion(in chat: Chat, from instance: SupervisorInstance) {
        guard let pending = instance.pendingQuestion else {
            conversations.syncDirectQuestion(nil, in: chat.id)
            return
        }
        let askedAt = pending.askedAt ?? instance.lastActivity ?? instance.startedAt
            ?? Date(timeIntervalSince1970: 0)
        let source = instance.runID ?? instance.sessionID ?? instance.slug
        let turnKey = pending.toolUseID ?? "\(source):\(Int(askedAt.timeIntervalSince1970)):\(pending.headline)"
        let id = ChatTranscriptFeed.entryID(chatID: chat.id, sessionID: "question", turnKey: turnKey)
        let entry = ConversationEntry(
            id: id, productID: chat.productID, chatID: chat.id, kind: .question,
            at: askedAt, text: pending.headline, tone: .attention, decision: pending.record)
        conversations.syncDirectQuestion(entry, in: chat.id)
    }

    func stopChatFeeds() {
        for (_, feed) in chatFeeds { feed.stop() }
        chatFeeds.removeAll()
    }

    func directPhase(for chatID: UUID?) -> DirectChatPhase {
        guard let chatID else { return .new }
        if let error = chatErrors[chatID] { return .failed(error) }
        if sendingChatIDs.contains(chatID) { return .starting }
        guard let chat = conversations.chat(id: chatID), let binding = chat.session else { return .new }
        if let instance = matchingInstance(for: binding) {
            return DirectChatPhase.resolve(instance: instance, bindingHasOutcome: binding.outcomeAt != nil)
        }
        if binding.outcomeAt != nil { return .ready }
        return binding.claudeSessionID == nil ? .new : .resumable
    }

    /// What a message is actually waiting for.
    ///
    /// "Waiting for the current answer to finish" is true while a turn is running and a lie while a
    /// message is being prepared — there is no current answer, and the thing it waits for is the
    /// two positions being formed for IT. The screen that says a message is queued has to say which.
    func directWaitReason(for chatID: UUID?) -> String {
        switch directPhase(for: chatID) {
        case .preparing(let peers): return peers.label
        case .waitingForLimit(let until):
            if let until {
                return String(format: String(localized: "Waiting for the usage window · back around %@"),
                              Fmt.clock(until))
            }
            return String(localized: "Waiting for the usage window")
        case .waitingForCodex(let until):
            if let until {
                return String(format: String(localized: "Waiting for Codex · back around %@"),
                              Fmt.stamp(until))
            }
            return String(localized: "Waiting for Codex")
        case .engineMismatch:
            return String(localized: "The installed engine is older than this app — reinstall it in Settings")
        case .reviewing, .verifying, .auditing:
            return String(localized: "Waiting for the review to finish")
        default:
            return String(localized: "Waiting for the current answer to finish")
        }
    }

    func isDirectChatBusy(_ chatID: UUID?) -> Bool {

        if let chatID, codexTurns[chatID] != nil { return true }
        guard let chatID, let binding = conversations.chat(id: chatID)?.session,
              let instance = matchingInstance(for: binding) else { return false }
        return instance.turnRunning
    }

    /// Working a hand short, in one line the director can read. Nil when both engineers are in.
    ///
    /// The engine has always written this down; nothing displayed it, so a run that quietly
    /// continued without Codex looked exactly like one that had both.
    func directDegradation(for chatID: UUID?) -> String? {
        guard let chatID, let binding = conversations.chat(id: chatID)?.session,
              let instance = matchingInstance(for: binding) else { return nil }
        guard let note = instance.degradation?
            .trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
        return note
    }

    func directQueueCount(for chatID: UUID?) -> Int {
        guard let chatID, let binding = conversations.chat(id: chatID)?.session else { return 0 }
        return matchingInstance(for: binding)?.queuedMessageCount ?? 0
    }

    func directActivity(for chatID: UUID?) -> NowLine? {
        guard let chatID, let binding = conversations.chat(id: chatID)?.session,
              let instance = matchingInstance(for: binding), instance.workerStatus == "busy",
              let activity = workerActivity[instance.projectPath] else { return nil }
        return NowLine(key: activity.key, object: activity.object)
    }

    func stopDirectChat(_ chatID: UUID?) {
        guard let chatID, !stoppingChatIDs.contains(chatID) else { return }

        if let runner = codexTurns[chatID] {
            runner.cancel()
            return
        }
        guard let binding = conversations.chat(id: chatID)?.session else { return }
        stoppingChatIDs.insert(chatID)
        Task {
            defer { stoppingChatIDs.remove(chatID) }
            let result = await client.interruptChat(projectPath: binding.projectPath,
                                                    runID: binding.activeRunID)
            if !result.ok && result.exitCode != 2 {
                let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                failChat(chatID, detail.isEmpty ? String(localized: "Could not stop the current answer.") : detail)
            }
            await refresh(codex: false)
        }
    }

    // MARK: Context inspector

    func chatInspectorSnapshot(productID: UUID, chatID: UUID?) async -> ChatInspectorSnapshot {
        guard let product = products.product(id: productID) else { return .empty }
        let chat = chatID.flatMap { conversations.chat(id: $0) }
        let binding = chat?.session
        let primaryID = binding?.primaryProjectID ?? product.defaultProjectID

        var inputs: [ChatInspectorProject] = resources(for: product).compactMap { item in
            guard let project = item.project else { return nil }
            return ChatInspectorProject(id: project.id, name: item.resource.name, path: project.path,
                                        access: item.resource.access, isPrimary: project.id == primaryID)
        }

        if let binding,
           !inputs.contains(where: { Slug.canonicalPath($0.path) == Slug.canonicalPath(binding.projectPath) }) {
            inputs.append(ChatInspectorProject(id: binding.primaryProjectID,
                                               name: (binding.projectPath as NSString).lastPathComponent,
                                               path: binding.projectPath, access: .workspace,
                                               isPrimary: true))
        }
        inputs.sort {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        var inspected: [ChatProjectInspection] = []
        for input in inputs { inspected.append(await client.inspectChatProject(input)) }

        let evidence: Evidence?
        if let binding {
            evidence = await client.chatEvidence(projectPath: binding.projectPath,
                                                 runID: binding.activeRunID,
                                                 sessionID: binding.claudeSessionID)
        } else {
            evidence = nil
        }
        return ChatInspectorSnapshot(projects: inspected, evidence: evidence, loadedAt: Date())
    }

    func chatInspectorDiff(projectPath: String, filePath: String) async -> String {
        await client.chatFileDiff(projectPath: projectPath, path: filePath)
    }

    // MARK: Reports

    func shouldOfferReport(for chatID: UUID?) -> Bool {
        guard let chatID, let session = conversations.chat(id: chatID)?.session else { return false }
        guard session.outcomeAt != nil, let completed = session.lastCompletedTurnKey else { return false }
        return completed != session.lastReportedTurnKey
    }

    func generateChatReport(chatID: UUID) {
        guard !generatingChatReportIDs.contains(chatID),
              let chat = conversations.chat(id: chatID),
              let binding = chat.session,
              let sessionID = binding.claudeSessionID,
              let home = OrchestratorHome.detect()?.path else {
            failChat(chatID, String(localized: "This chat does not have a resumable Night Shift session yet."))
            return
        }
        generatingChatReportIDs.insert(chatID)
        Task {
            defer { generatingChatReportIDs.remove(chatID) }
            guard let published = await client.generateRichChatReport(
                projectPath: binding.projectPath, orchestratorHome: home,
                sessionID: sessionID, branch: binding.branch, runID: binding.activeRunID,
                language: settings.reportLanguage.reportLanguageName,
                title: chat.title, originalRequest: chat.firstMessage) else {
                failChat(chatID, String(localized: "Could not generate the report."))
                return
            }
            conversations.addReport(published, to: chatID)
            openChatReport(path: published, title: chat.title)
        }
    }

    func openChatReport(path: String, title: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            toast = ToastMessage(text: "The report file is missing.", kind: .error)
            return
        }
        reportViewer = ReportViewer(taskID: nil, title: title, htmlURL: url, isVideo: false)
    }
}
