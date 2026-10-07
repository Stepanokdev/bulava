import Foundation

/// Why a chat stopped, as far as repairing and reporting it goes.
enum ChatFailure: Sendable, Equatable {
    /// Something only the person can do — choose a folder, sign in, wait for another run. Nothing
    /// is broken, so nothing is repaired or reported.
    case needsYou
    /// Something went wrong before the message reached the agent — proven, not assumed. The code
    /// says where, in our own words, and stays the same across languages and machines: it is what
    /// reports are grouped by. Such a message may be repaired and sent again by itself.
    case unexpected(String)
    /// Something went wrong and the message MAY have reached the agent: cut off by a timeout,
    /// killed, broken halfway through typing, or a Codex turn that failed after it began. Sending
    /// it again by itself could run the same work twice, so a repair here waits for a press and
    /// never resends — the person decides.
    case uncertain(String)

    var code: String? {
        switch self {
        case .needsYou: return nil
        case .unexpected(let code), .uncertain(let code): return code
        }
    }

    /// The message is known never to have arrived, so sending it again cannot do anything twice.
    var resendable: Bool {
        if case .unexpected = self { return true }
        return false
    }
}

/// A failure that stopped a chat, and what Bulava is doing about it.
struct ChatRepair: Equatable {
    enum Phase: Equatable {
        /// Found, not started — the setting is off, or the automatic attempt already ran once.
        case offered
        /// Codex (or Claude) is looking into it.
        case running
        /// It changed something; the message is being sent again to see whether that was enough.
        case verifying(summary: String)
        /// The cause is gone and the engine confirmed the message was delivered.
        case fixed(summary: String)
        /// The cause is gone, but delivery is not confirmed — and the row says which way.
        case unconfirmed(summary: String, why: Unconfirmed)
        case notFixed(summary: String)
        /// It is something the person has to do, and the repair says what.
        case needsYou(summary: String)
        /// Neither agent could be asked.
        case unavailable(reason: String)
    }

    enum Unconfirmed: Equatable {
        /// The engine took the message and it waits in line — a turn still running, a usage window.
        case queued
        /// Still being handed over when Bulava stopped watching, or it ended without saying.
        case stillSending
        /// Never sent again: the first attempt may have arrived, and twice is worse than once.
        case notResent
    }

    var incidentID = UUID()
    var chatID: UUID
    /// The message that did not go — it is what gets sent again once the cause is gone.
    var entryID: UUID
    var code: String
    var error: String
    var fingerprint: String
    /// The message is known never to have reached the agent (`ChatFailure.resendable`).
    var resendable = true
    var phase: Phase = .offered
    var startedAt: Date?
    var agent: RepairSession.Agent?
    var finding: RepairSession.Finding?
    /// Shown under "Details": what the agent said beyond the summary, or why it could not run.
    var detail: String?

    var isBusy: Bool {
        switch phase {
        case .running, .verifying: return true
        default: return false
        }
    }
}

extension AppModel {

    /// How long after one attempt the same failure in the same chat is attempted again by itself.
    static let repairCooldown: TimeInterval = 30 * 60

    // MARK: - Noticing

    /// Called with every chat failure. A failure that only the person can resolve is left to the
    /// rows that already ask them; anything else gets a repair — started by itself when the
    /// setting allows and this kind of failure has not just been tried, offered otherwise.
    func noticeChatFailure(_ chatID: UUID, message: String, kind: ChatFailure) {
        guard let code = kind.code else { return }
        // A retry made by a repair failed: that repair's verification reads it, not a new one.
        if repairs[chatID]?.isBusy == true { return }
        guard let entry = lastFailedMessage(in: chatID) else {
            // No message to send again, so no way to tell whether a repair worked. Reported, so
            // it still reaches us.
            reportIncident(code: code, message: message, chatID: chatID, outcome: "not_attempted")
            return
        }
        let scrubbed = ReportScrubber.scrub(message, known: knownPrivateStrings(chatID: chatID))
        let fingerprint = ReportScrubber.fingerprint(code: code, scrubbed: scrubbed)
        repairs[chatID] = ChatRepair(chatID: chatID, entryID: entry.id, code: code,
                                     error: message, fingerprint: fingerprint,
                                     resendable: kind.resendable)

        let attemptKey = "\(chatID.uuidString)|\(fingerprint)"
        let recently = repairAttempts[attemptKey].map { Date().timeIntervalSince($0) < Self.repairCooldown } ?? false
        // Never by itself when the message may already be running: the person decides.
        guard settings.autoRepair, kind.resendable, !recently else {
            if !settings.autoRepair || !kind.resendable {
                reportIncident(code: code, message: message, chatID: chatID, outcome: "not_attempted",
                               incidentID: repairs[chatID]?.incidentID)
            }
            return
        }
        // A beat first. A failure is often followed at once by the row that explains it — a
        // folder to trust, a login, uncommitted changes — and those are the person's to answer,
        // not a repair's.
        let incident = repairs[chatID]?.incidentID
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, self.repairs[chatID]?.incidentID == incident,
                  self.chatErrors[chatID] != nil, !self.chatHasAQuestionForYou(chatID) else { return }
            self.startRepair(chatID: chatID)
        }
    }

    /// The newest message of the chat that never reached the agent.
    func lastFailedMessage(in chatID: UUID) -> ConversationEntry? {
        conversations.entries(inChat: chatID).last { $0.kind == .user && $0.delivery == .failed }
    }

    /// A row under the message is already asking the person something only they can answer.
    func chatHasAQuestionForYou(_ chatID: UUID) -> Bool {
        trustBlocked[chatID] != nil || setupBlocked.contains(chatID) || gitConsentBlocked[chatID] != nil
            || mcpBlocked[chatID] != nil || dirtyTreeBlocked[chatID] != nil
            || heavyFilesBlocked[chatID] != nil || handoffBlocked[chatID] != nil
            || signInBlocked[chatID] != nil
            || (lastFailedMessage(in: chatID)?.codexWall != nil)
    }

    // MARK: - Repairing

    func startRepair(chatID: UUID) {
        guard var repair = repairs[chatID], !repair.isBusy,
              let chat = conversations.chat(id: chatID),
              let product = products.product(id: chat.productID),
              let project = chatPrimary(for: product, chatID: chatID) else { return }
        repair.phase = .running
        repair.startedAt = Date()
        repair.detail = nil
        repairs[chatID] = repair
        repairAttempts["\(chatID.uuidString)|\(repair.fingerprint)"] = Date()

        toast = ToastMessage(title: String(localized: "Bulava is fixing what stopped the message"),
                             text: repair.resendable
                                ? String(format: String(localized: "Codex is looking for the cause in “%@”. Once it is fixed, the message goes again."), project.name)
                                : String(format: String(localized: "Codex is looking for the cause in “%@”. The message may already have arrived, so it will not be sent again by itself."), project.name),
                             kind: .info, key: repairToastKey(chatID),
                             actions: [ToastAction(title: String(localized: "Stop"), primary: false) { [weak self] in
                                 self?.cancelRepair(chatID: chatID)
                             }],
                             inProgress: true)

        let slug = Slug.forPath(project.path)
        let instance = settings.paths.instanceDir(slug: slug)
        let state = FileManager.default.fileExists(atPath: instance.path) ? instance : nil
        let readOnly = [OrchestratorHome.detect(), Optional(settings.paths.undeliveredDir(slug: slug))]
            .compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let request = RepairSession.Request(
            errorText: repair.error,
            // For the agent, not the person: it stays in English, like the rest of the prompt.
            operation: "sending a message to the project's chat. Bulava starts the Night Shift engine in this folder and hands the message to Claude Code.",
            folder: URL(fileURLWithPath: project.path),
            stateFolder: state, readOnly: readOnly,
            languageName: explainLanguageName,
            preferClaude: lastFailedMessage(in: chatID)?.codexWall != nil)
        let pidFile = repairPIDFile(repair.incidentID)
        let incident = repair.incidentID

        Task { [weak self] in
            let outcome = await RepairSession.run(request, pidFile: pidFile)
            try? FileManager.default.removeItem(at: pidFile)
            try? FileManager.default.removeItem(atPath: pidFile.path + ".cancelled")
            await self?.concludeRepair(chatID: chatID, incident: incident, outcome: outcome)
        }
    }

    /// The app is quitting: a repair does not go on changing somebody's folder with nobody left to
    /// read what it did.
    func stopRepairs() {
        for repair in repairs.values where repair.phase == .running {
            RepairSession.cancel(pidFile: repairPIDFile(repair.incidentID))
        }
    }

    /// A repair the app was running when it crashed or was killed. Its pid file is still there, and
    /// so — if nothing stopped it — is the agent, still in the folder. Only a process that is
    /// still Codex or Claude is stopped: the number may have been handed to something else since.
    func sweepOrphanedRepairs() {
        let dir = AppSupport.root.appendingPathComponent("repairs", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "pid" {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
               let argv = ProcessTable.arguments(of: pid),
               argv.contains(where: { ["codex", "claude"].contains(($0 as NSString).lastPathComponent)
                                      || $0.contains("/codex") || $0.hasSuffix("/claude") }) {
                kill(-pid, SIGTERM)
                kill(pid, SIGTERM)
            }
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(atPath: file.path + ".cancelled")
        }
    }

    func cancelRepair(chatID: UUID) {
        guard let repair = repairs[chatID], repair.phase == .running else { return }
        RepairSession.cancel(pidFile: repairPIDFile(repair.incidentID))
    }

    func dismissRepair(chatID: UUID) {
        if let repair = repairs[chatID], repair.phase == .running { cancelRepair(chatID: chatID) }
        repairs[chatID] = nil
        resolveToast(key: repairToastKey(chatID))
    }

    /// What a finished repair means, decided here and nowhere else.
    ///
    /// `resend` is how the stopped message is sent again — the real retry in the app, a stand-in
    /// in tests, which is how "a message that may have arrived is never sent twice" is proved
    /// rather than read off the code.
    func concludeRepair(chatID: UUID, incident: UUID, outcome: RepairSession.Outcome,
                        verifyFor deadline: TimeInterval = 300,
                        resend: (@MainActor (UUID) -> Void)? = nil) async {
        guard var repair = repairs[chatID], repair.incidentID == incident else { return }
        let took = Date().timeIntervalSince(repair.startedAt ?? Date())
        switch outcome {
        case .cancelled:
            repair.phase = .offered
            repairs[chatID] = repair
            resolveToast(key: repairToastKey(chatID))

        case .unavailable(let why):
            repair.phase = .unavailable(reason: String(localized: "Neither Codex nor Claude answered. The readiness screen shows whether they are signed in."))
            repair.detail = why
            repairs[chatID] = repair
            postRepairCard(repair)
            reportIncident(code: repair.code, message: repair.error, chatID: chatID,
                           outcome: "repair_unavailable", incidentID: incident, duration: took)

        case .failed(let why, let agent):
            repair.agent = agent
            repair.phase = .notFixed(summary: String(localized: "The repair did not finish, so nothing was sent again."))
            repair.detail = why
            repairs[chatID] = repair
            postRepairCard(repair)
            reportIncident(code: repair.code, message: repair.error, chatID: chatID,
                           outcome: "not_fixed", incidentID: incident, agent: agent.rawValue, duration: took)

        case .answered(let finding, let agent):
            repair.agent = agent
            repair.finding = finding
            repair.detail = finding.changed.isEmpty ? nil
                : String(localized: "Changed:") + "\n" + finding.changed.joined(separator: "\n")
            let summary = finding.summary.isEmpty
                ? String(localized: "The repair found nothing to change.") : finding.summary
            func finish(_ phase: ChatRepair.Phase, _ reported: String) {
                guard var now = repairs[chatID], now.incidentID == incident else { return }
                now.phase = phase
                now.agent = agent
                now.finding = finding
                if now.detail == nil { now.detail = repair.detail }
                repairs[chatID] = now
                postRepairCard(now)
                reportIncident(code: repair.code, message: repair.error, chatID: chatID,
                               outcome: reported, incidentID: incident, finding: finding,
                               agent: agent.rawValue,
                               duration: Date().timeIntervalSince(repair.startedAt ?? Date()))
            }
            if finding.cause == "needs_user" || !finding.fixed {
                repairs[chatID] = repair
                finish(finding.cause == "needs_user" ? .needsYou(summary: summary) : .notFixed(summary: summary),
                       finding.cause == "needs_user" ? "needs_user" : "not_fixed")
                return
            }
            // The message may already have reached the agent: it is not sent again by anyone but
            // the person. What the repair did is reported, with its result unverified.
            guard repair.resendable else {
                repairs[chatID] = repair
                finish(.unconfirmed(summary: summary, why: .notResent), "unverified")
                return
            }
            // Its word is not the verdict. The message goes again, and only the engine saying it
            // was delivered makes this "fixed".
            repair.phase = .verifying(summary: summary)
            repairs[chatID] = repair
            let verdict = await sendAgainToVerify(chatID: chatID, entryID: repair.entryID,
                                                  deadline: deadline, resend: resend)
            switch verdict {
            case .delivered:
                finish(.fixed(summary: summary), "fixed")
            case .accepted:
                finish(.unconfirmed(summary: summary, why: .queued), "unverified")
            case .pending:
                finish(.unconfirmed(summary: summary, why: .stillSending), "unverified")
            case .questionForYou:
                finish(.needsYou(summary: String(localized: "Fixed. The message now waits for your answer under it.")),
                       "needs_user")
            case .failedAgain(let error):
                if var now = repairs[chatID], now.incidentID == incident {
                    now.detail = [repair.detail, error].compactMap { $0 }.joined(separator: "\n\n")
                    repairs[chatID] = now
                }
                finish(.notFixed(summary: String(format: String(localized: "%@\nThe message still did not go through."), summary)),
                       "not_fixed")
            }
        }
    }

    enum VerifyResult: Equatable {
        /// The engine confirmed the turn is running, or Codex answered.
        case delivered
        /// The engine took it and it waits in line.
        case accepted
        /// Still being handed over when the watch ended, or ended without saying either way.
        case pending
        /// It stopped at one of the questions only the person answers.
        case questionForYou
        case failedAgain(String)
    }

    /// What the chat's state says about a message sent again — or nil while there is nothing to
    /// say yet. Kept apart so every state can be checked on its own.
    nonisolated static func judge(error: String?, delivery: ConversationEntry.Delivery?,
                                  confirmed: Bool, sending: Bool,
                                  questionForYou: Bool) -> VerifyResult? {
        if let error { return .failedAgain(error) }
        if confirmed { return .delivered }
        if sending { return nil }
        switch delivery {
        case .queued: return .accepted
        case .failed:
            return questionForYou ? .questionForYou
                : .failedAgain(String(localized: "The message was not delivered."))
        case .replaced: return .delivered
        case nil: return .pending
        }
    }

    /// Sends the stopped message again and watches what the engine says about it.
    func sendAgainToVerify(chatID: UUID, entryID: UUID, deadline: TimeInterval = 300,
                           resend: (@MainActor (UUID) -> Void)? = nil) async -> VerifyResult {
        // Another send of this chat still starting would make the retry a no-op — and its absence
        // would read as a failure that never happened.
        for _ in 0..<120 where sendingChatIDs.contains(chatID) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        confirmedDeliveries.remove(entryID)
        if let resend { resend(entryID) } else { retryDirectMessage(entryID: entryID) }
        let until = Date().addingTimeInterval(deadline)
        repeat {
            try? await Task.sleep(for: .milliseconds(400))
            if let verdict = Self.judge(error: chatErrors[chatID],
                                        delivery: conversations.entry(id: entryID)?.delivery,
                                        confirmed: confirmedDeliveries.contains(entryID),
                                        sending: sendingChatIDs.contains(chatID),
                                        questionForYou: chatHasAQuestionForYou(chatID)) {
                return verdict
            }
        } while Date() < until
        // Out of time with the send still going: not a failure, not a success — and said as such.
        return .pending
    }

    private func postRepairCard(_ repair: ChatRepair) {
        let key = repairToastKey(repair.chatID)
        switch repair.phase {
        case .fixed(let summary):
            toast = ToastMessage(title: String(localized: "Fixed, and the message went"), text: summary,
                                 kind: .success, key: key, detail: repair.detail)
        case .notFixed(let summary):
            toast = ToastMessage(title: String(localized: "Bulava could not fix it"), text: summary,
                                 kind: .error, key: key, detail: repair.detail,
                                 actions: [ToastAction(title: String(localized: "Open the chat")) { [weak self] in
                                     guard let self, let chat = self.conversations.chat(id: repair.chatID) else { return }
                                     self.openChat(chat)
                                 }])
        case .unconfirmed(let summary, let why):
            let title: String
            switch why {
            case .queued: title = String(localized: "Fixed, and the message is in line")
            case .stillSending: title = String(localized: "Fixed, and the message is on its way")
            case .notResent: title = String(localized: "Fixed, not sent again")
            }
            toast = ToastMessage(title: title, text: summary, kind: .info, key: key, detail: repair.detail,
                                 actions: why == .notResent
                                    ? [ToastAction(title: String(localized: "Send again")) { [weak self] in
                                           self?.sendAgainByHand(chatID: repair.chatID)
                                       }]
                                    : [])
        case .needsYou(let summary):
            toast = ToastMessage(title: String(localized: "This one is yours to do"), text: summary,
                                 kind: .info, key: key, detail: repair.detail,
                                 actions: [ToastAction(title: String(localized: "Open the chat")) { [weak self] in
                                     guard let self, let chat = self.conversations.chat(id: repair.chatID) else { return }
                                     self.openChat(chat)
                                 }])
        case .unavailable(let reason):
            toast = ToastMessage(title: String(localized: "Bulava could not fix it"), text: reason,
                                 kind: .error, key: key, detail: repair.detail,
                                 actions: [ToastAction(title: String(localized: "Check readiness")) { [weak self] in
                                     self?.openPreflight()
                                 }])
        case .offered, .running, .verifying:
            break
        }
    }

    func repairToastKey(_ chatID: UUID) -> String { "repair.\(chatID.uuidString)" }

    /// The person decided the message did not arrive and sends it again — their call, which is
    /// the only way a message that may have arrived ever goes twice.
    func sendAgainByHand(chatID: UUID) {
        guard let repair = repairs[chatID] else { return }
        repairs[chatID] = nil
        resolveToast(key: repairToastKey(chatID))
        retryDirectMessage(entryID: repair.entryID)
    }

    private func repairPIDFile(_ incident: UUID) -> URL {
        let dir = AppSupport.root.appendingPathComponent("repairs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(incident.uuidString).pid")
    }

    // MARK: - Reporting

    /// The specifics of this person's setup that a pattern could not know are private: the names
    /// and folders of their products.
    func knownPrivateStrings(chatID: UUID? = nil) -> [String] {
        var known: [String] = []
        for product in products.products {
            known.append(product.name)
            for id in product.allProjectIDs {
                if let p = projects.project(id: id) { known.append(p.path); known.append(p.name) }
            }
        }
        if let chatID, let chat = conversations.chat(id: chatID) {
            known.append(chat.title)
            if let path = chat.session?.projectPath { known.append(path) }
        }
        return known
    }

    func reportIncident(code: String, message: String, chatID: UUID? = nil, outcome: String,
                        incidentID: UUID? = nil, finding: RepairSession.Finding? = nil,
                        agent: String = "none", duration: TimeInterval = 0) {
        guard settings.shareErrorReports else { return }
        let report = IncidentReport.make(id: incidentID ?? UUID(), code: code, rawMessage: message,
                                         known: knownPrivateStrings(chatID: chatID),
                                         outcome: outcome, cause: finding?.cause ?? "unknown",
                                         productBug: finding?.productBug ?? "",
                                         agent: agent, duration: duration)
        Task {
            await ReportOutbox.shared.enqueue(report)
            await ReportOutbox.shared.flush()
        }
    }

    func flushIncidentReports() {
        guard settings.shareErrorReports else {
            Task { await ReportOutbox.shared.purge() }
            return
        }
        Task { await ReportOutbox.shared.flush() }
    }
}
