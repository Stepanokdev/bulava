import AppKit
import CoreGraphics
import Foundation
import UserNotifications

/// Automations: deciding when one runs, giving the run a copy and a fresh conversation, reading
/// how it ended, and handing its work over.
///
/// A run is an ordinary chat underneath — the same engine start, the same review, the same
/// outcome, the same questions on the phone — whose folder is its own copy. Everything the app
/// already does for a conversation it does for a run; what is added here is the clock, the copy,
/// and the record of what each run did.
extension AppModel {

    // MARK: - The clock

    /// Called on every poll. Cheap unless something is due: the schedules are arithmetic, and each
    /// check that goes out to git, the network or Mail runs at most once at a time per automation.
    func automationsTick(now: Date = Date()) {
        // First, so nothing below reads a run's conversation as an ordinary one.
        relinkCopyChats()
        // Before anything is handed over, and for automations switched off too, so what they show
        // as gathered is true.
        for automation in automations.automations { reconcileWatchItems(automation.id) }
        for automation in automations.automations where automation.enabled {
            switch automation.trigger {
            case .manual:
                break
            case .schedule(let schedule):
                settleSchedule(automation, schedule, now: now)
            case .watch, .event:
                pollWatch(automation, now: now)
            }
        }
        advanceRuns(now: now)
        followHandedMerges(now: now)
        if lastCopySweep.map({ now.timeIntervalSince($0) > 600 }) ?? true {
            lastCopySweep = now
            Task { await sweepCopies() }
        }
        syncFolderWatchers()
    }

    private func settleSchedule(_ automation: Automation, _ schedule: AutomationSchedule, now: Date) {
        let owed = AutomationClock.owed(schedule, evaluatedThrough: automation.evaluatedThrough ?? automation.createdAt,
                                        now: now)
        guard owed.through != automation.evaluatedThrough else { return }
        for time in owed.skipped {
            var run = AutomationRun(automationID: automation.id,
                                    occurrence: AutomationClock.occurrenceKey(time, schedule),
                                    reason: .scheduled(time), state: .skipped,
                                    briefRevision: automation.briefRevision, createdAt: time)
            run.note = String(localized: "The Mac was asleep or Bulava was closed at that time.")
            run.finishedAt = time
            run.seen = true
            automations.record(run)
        }
        // The night is recorded first and the watermark moved second. A crash in between replays
        // the same occurrence, which is refused as a duplicate — never a night that was neither
        // run nor written down.
        if let due = owed.due {
            let late = now.timeIntervalSince(due) > AutomationClock.lateAfter
            beginRun(automation, occurrence: AutomationClock.occurrenceKey(due, schedule),
                     reason: late ? .caughtUp(due) : .scheduled(due), items: [], now: now)
        }
        automations.update(automation.id) { $0.evaluatedThrough = owed.through }
    }

    // MARK: - Making and changing them

    func createAutomation(_ automation: Automation) {
        automations.add(automation)
        navigate(to: .automation(automation.id))
    }

    /// Apply an edit. A new brief is a new version; a new trigger starts its watch from what is
    /// there now and its schedule from now, so an edit never runs the nights before it.
    func editAutomation(_ id: UUID, to edited: Automation) {
        automations.update(id) { a in
            if a.brief != edited.brief { a.briefRevision += 1 }
            if a.trigger != edited.trigger {
                a.watch = edited.trigger.watchesSomething ? WatchState() : nil
                a.evaluatedThrough = Date()
            }
            a.name = edited.name
            a.brief = edited.brief
            a.trigger = edited.trigger
            a.projectID = edited.projectID
            a.productID = edited.productID
            a.baseBranch = edited.baseBranch
            a.confirmFirst = edited.confirmFirst
            a.workMode = edited.workMode
            a.carryFiles = edited.carryFiles
            a.pipelineID = edited.pipelineID
        }
    }

    /// On or off. Switched back on, it starts from now: the nights it was off were not missed.
    func setAutomationEnabled(_ id: UUID, _ on: Bool) {
        automations.update(id) { a in
            guard a.enabled != on else { return }
            a.enabled = on
            if on {
                a.pausedReason = nil
                a.evaluatedThrough = Date()
            }
        }
    }

    /// The automation goes. Its runs' conversations stay, as ordinary archived chats, so what it
    /// did can still be read and searched.
    func deleteAutomation(_ id: UUID) -> String? {
        let runs = automations.runs(for: id)
        if runs.contains(where: { !$0.state.isTerminal }) {
            return String(localized: "A run is still going. Stop it first.")
        }
        if runs.contains(where: { $0.state == .finished && $0.result == .changes && $0.handoff == .waiting }) {
            return String(localized: "A run's changes are still waiting. Merge or discard them first.")
        }
        for run in runs { if let chatID = run.chatID { conversations.releaseAutomationChat(chatID) } }
        automations.remove(id)
        if route == .automation(id) { navigate(to: .automations) }
        return nil
    }

    // MARK: - Starting a run

    /// Start the automation once, now, by his hand.
    func runAutomationNow(_ id: UUID) {
        guard let automation = automations.automation(id: id) else { return }
        // Asked before anything is taken off the watch: a refused start keeps what was gathered.
        if let why = reasonNotToStart(automation, now: Date()) {
            toast = ToastMessage(text: why, kind: .info)
            return
        }
        // What a watch has gathered goes with a run he starts himself — that is what "now" means —
        // and leaves the watch only once that run is on the record. What an earlier run already
        // owns is not handed to this one.
        reconcileWatchItems(id)
        let items = Array((automations.automation(id: id)?.watch?.pending ?? []).prefix(AutomationBrief.batchLimit))
        if case .recorded = beginRun(automation, occurrence: "manual:\(UUID().uuidString)", reason: .manual,
                                     items: items, now: Date(), byHand: true), !items.isEmpty {
            releasePending(items, from: id)
        }
    }

    /// Take items off a watch's gathered list once a run owns them. Matched by what they are owned
    /// under, so letting go of an item a run holds does not take its retry with it.
    func releasePending(_ items: [WatchItem], from automationID: UUID) {
        let taken = Set(items.map(Self.ownershipKey))
        automations.update(automationID) { a in
            a.watch?.pending.removeAll { taken.contains(Self.ownershipKey($0)) }
            if a.watch?.pending.isEmpty == true { a.watch?.pendingSince = nil }
        }
    }

    /// Why a run cannot start right now, or nil. Each reason is something he can act on or wait out.
    func reasonNotToStart(_ automation: Automation, now: Date) -> String? {
        let mine = automations.runs(for: automation.id)
        // A question waits until it is answered, looked at or not — the same rule as the badge.
        if mine.contains(where: { !$0.state.isTerminal || ($0.state == .finished && $0.result == .needsYou) }) {
            return String(localized: "The previous run has not finished yet.")
        }
        if mine.contains(where: { $0.state == .finished && $0.result == .changes && $0.handoff == .waiting }) {
            return String(localized: "The previous run's changes are still waiting for you — merge or discard them first, so the next run does not pile work on top of work nobody has looked at.")
        }
        guard let project = projects.project(id: automation.projectID),
              products.product(id: automation.productID)?.allProjectIDs.contains(project.id) == true else {
            return String(localized: "Its folder is no longer connected to the product.")
        }
        guard FileManager.default.fileExists(atPath: project.path) else {
            return String(format: String(localized: "The folder %@ is not there any more."), project.displayPath)
        }
        let week = capacity.claude.sevenDay
        if let week, week.usedPercent >= 97, let reset = week.resetsAt, reset > now,
           !capacity.claude.isStale(now: now) {
            return String(format: String(localized: "Claude's weekly limit is used up until %@."), Fmt.stamp(reset))
        }
        return nil
    }

    /// What became of an occurrence handed to `beginRun`.
    enum BeginOutcome: Equatable {
        /// A run is on the record and owns the items it was given.
        case recorded(UUID)
        /// Already on the record from an earlier ask: the items belong to that run.
        case duplicate
        /// Could not start now. Items stay where they were; a scheduled time is recorded as skipped.
        case refused
    }

    @discardableResult
    func beginRun(_ automation: Automation, occurrence: String, reason: AutomationRun.Reason,
                  items: [WatchItem], now: Date, byHand: Bool = false) -> BeginOutcome {
        guard !automations.hasRun(occurrence: occurrence, for: automation.id) else { return .duplicate }
        if let why = reasonNotToStart(automation, now: now) {
            if byHand { toast = ToastMessage(text: why, kind: .info); return .refused }
            // What a watch found stays gathered for the next chance instead of being lost to a skip.
            if !items.isEmpty { return .refused }
            var run = AutomationRun(automationID: automation.id, occurrence: occurrence, reason: reason,
                                    state: .skipped, briefRevision: automation.briefRevision, createdAt: now)
            run.note = why
            run.finishedAt = now
            run.seen = true
            automations.record(run)
            return .refused
        }
        let state: AutomationRun.State
        if automation.confirmFirst && !byHand {
            state = .awaitingApproval
        } else if automation.trigger.schedule?.waitUntilAway == true && !byHand {
            state = .awaitingAway
        } else {
            state = .preparing
        }
        var run = AutomationRun(automationID: automation.id, occurrence: occurrence, reason: reason,
                                state: state, briefRevision: automation.briefRevision, items: items,
                                createdAt: now)
        run.brief = automation.brief
        run.projectID = automation.projectID
        run.baseBranch = automation.baseBranch ?? ""
        run.checkOnly = automation.checksOnly ? true : nil
        guard automations.record(run) else { return .duplicate }
        switch state {
        case .awaitingApproval:
            notify(title: automation.name, body: String(localized: "Wants to run. Open Bulava to start it or skip it."))
        case .preparing:
            Task { await prepareAndStart(run.id) }
        default:
            break
        }
        return .recorded(run.id)
    }

    func approveRun(_ runID: UUID) {
        guard let run = automations.run(id: runID), run.state == .awaitingApproval else { return }
        automations.updateRun(runID) { $0.state = .preparing; $0.seen = true }
        Task { await prepareAndStart(runID) }
    }

    func skipRun(_ runID: UUID) {
        guard let run = automations.run(id: runID),
              run.state == .awaitingApproval || run.state == .awaitingAway else { return }
        automations.updateRun(runID) {
            $0.state = .skipped
            $0.note = String(localized: "You skipped this run.")
            $0.finishedAt = Date()
            $0.seen = true
        }
    }

    /// Give the run its copy and its conversation, then send it the brief.
    ///
    /// Every step that can fail stops the run with the reason, in words: no copy means no run — it
    /// never falls back to his folder. The copy's and the chat's ids are written down before either
    /// exists, so a run interrupted half way is resumed, not started a second time; and after every
    /// wait the run is asked again whether it is still wanted — he may have stopped it meanwhile.
    func prepareAndStart(_ runID: UUID) async {
        guard !automationPreparing.contains(runID) else { return }
        automationPreparing.insert(runID)
        defer { automationPreparing.remove(runID) }

        guard let run = automations.run(id: runID), run.state == .preparing,
              let automation = automations.automation(id: run.automationID) else { return }
        guard let product = products.product(id: automation.productID),
              let project = projects.project(id: run.projectID ?? automation.projectID),
              product.allProjectIDs.contains(project.id) else {
            failRun(runID, String(localized: "Its folder is no longer connected to the product."))
            return
        }
        let baseBranch: String? = run.baseBranch.map { $0.isEmpty ? nil : $0 } ?? automation.baseBranch
        let brief = run.brief ?? automation.brief

        let chatID = run.chatID ?? UUID()
        var copyID = run.workspaceID ?? UUID()
        if run.chatID == nil || run.workspaceID == nil {
            automations.updateRun(runID) { $0.chatID = chatID; $0.workspaceID = copyID }
        }

        var copy: WorkCopy
        if let existing = automations.copy(id: copyID), existing.state == .active,
           await WorkCopies.isOurs(existing) {
            copy = existing
        } else {
            guard let sourceRoot = await WorkCopies.topLevel(of: project.path) else {
                failRun(runID, Self.copyProblem(.notARepository))
                return
            }
            if let half = automations.copy(id: copyID), half.state != .removed {
                // Made half way before a quit: not trusted, taken away, and made again under a new
                // name so nothing of the first attempt is mistaken for the second. Its record may
                // predate its branch, so the folder's own marker says whether it is ours. The
                // automation's own folder, still parked because the quit came first, is simply free.
                let stillParked = await WorkCopies.isParked(half.checkoutRoot, automationID: automation.id,
                                                            sourceRoot: sourceRoot)
                if stillParked {
                    automations.updateCopy(copyID) { $0.state = .removed; $0.removedAt = Date() }
                } else if await WorkCopies.takeAwayHalfMade(half) {
                    automations.updateCopy(copyID) { $0.state = .removed; $0.removedAt = Date() }
                }
                copyID = UUID()
                automations.updateRun(runID) { $0.workspaceID = copyID }
            }
            let home = await freeHome(of: automation, sourceRoot: sourceRoot)
            let branch = "bulava/\(WorkCopies.branchSlug(automation.name))/\(Self.branchStamp(Date()))"
            let carry = automation.carryFiles ?? []
            func record(at folder: String) {
                // On the record before git is asked for anything, so a sweep can never meet this
                // copy as a stranger.
                automations.addCopy(WorkCopy(id: copyID, path: folder, checkoutRoot: folder,
                                             sourcePath: project.path, sourceRoot: sourceRoot,
                                             projectID: project.id, branch: "", baseRef: "", baseSHA: "",
                                             owner: .run(runID), state: .preparing))
            }
            var made: Result<WorkCopy, WorkCopies.Failure>
            if let home {
                record(at: home)
                made = FileManager.default.fileExists(atPath: home)
                    ? await WorkCopies.adoptHome(home, automationID: automation.id, sourcePath: project.path,
                                                 projectID: project.id, baseRef: baseBranch, branch: branch,
                                                 owner: .run(runID), id: copyID, carry: carry)
                    : await WorkCopies.make(sourcePath: project.path, projectID: project.id, baseRef: baseBranch,
                                            branch: branch, owner: .run(runID), id: copyID, at: home, carry: carry)
                // The folder could not be taken up — something there that is not provably its
                // parked folder, or git stopped half way. It is left as it is, and this run gets a
                // folder of its own, as every run did before.
                if case .failure(let f) = made, Self.homeCanFallBack(f) {
                    let own = WorkCopies.plannedCheckoutRoot(sourceRoot: sourceRoot, id: copyID)
                    record(at: own)
                    made = await WorkCopies.make(sourcePath: project.path, projectID: project.id, baseRef: baseBranch,
                                                 branch: branch, owner: .run(runID), id: copyID, carry: carry)
                }
            } else {
                record(at: WorkCopies.plannedCheckoutRoot(sourceRoot: sourceRoot, id: copyID))
                made = await WorkCopies.make(sourcePath: project.path, projectID: project.id, baseRef: baseBranch,
                                             branch: branch, owner: .run(runID), id: copyID, carry: carry)
            }
            switch made {
            case .success(let ready):
                copy = ready
                automations.addCopy(ready)
            case .failure(let f):
                automations.updateCopy(copyID) { $0.state = .removed; $0.removedAt = Date() }
                failRun(runID, Self.copyProblem(f))
                return
            }
        }
        guard automations.run(id: runID)?.state == .preparing else {
            _ = await removeCopy(copy.id, force: false, branch: .delete)
            return
        }
        await readyForUnattendedWork(copy)
        guard automations.run(id: runID)?.state == .preparing else {
            _ = await removeCopy(copy.id, force: false, branch: .delete)
            return
        }

        let title = "\(automation.name) · \(Fmt.dayLabel(Date()))"
        let chat = conversations.newAutomationChat(id: chatID, for: product.id, runID: runID,
                                                   copyID: copy.id, title: title)
        if let pipeline = automation.pipelineID, !pipeline.isEmpty {
            conversations.setPipeline(pipeline, for: chat.id)
        }
        automations.updateRun(runID) {
            $0.state = .running
            $0.startedAt = Date()
        }
        let message = AutomationBrief.message(brief: brief, reason: run.reason, items: run.items)
        if let send = sendAutomationBrief {
            send(message, product.id, chat.id, run.entryID)
        } else {
            sendDirectMessage(message, productID: product.id, chatID: chat.id, entryID: run.entryID)
        }
    }

    /// The automation's own folder, when this run may have it: no other record holds it. One that
    /// still does — a finished run the sweep has not got to — is settled now, the way the sweep
    /// would; if it cannot be, nil, and the run is given a folder of its own instead.
    private func freeHome(of automation: Automation, sourceRoot: String) async -> String? {
        let home = WorkCopies.homeRoot(sourceRoot: sourceRoot, automationID: automation.id)
        func holders() -> [WorkCopy] {
            automations.copies.filter {
                $0.state != .removed && Slug.canonicalPath($0.checkoutRoot) == Slug.canonicalPath(home)
            }
        }
        for holder in holders() where !copyOperations.contains(holder.id) {
            if let fate = await copyFate(holder) {
                _ = await removeCopy(holder.id, force: fate.force, branch: fate.branch)
            }
        }
        guard holders().isEmpty else { return nil }
        // Its folders from before it was pointed at another repository. One under another name is
        // simply not this one; one under the same name — another repository called the same — has
        // the path but not the repository, and would refuse this run every time. Both are given
        // up here, by the run itself, so nothing else can be taking them up at the same moment.
        let mine = "-auto-" + String(automation.id.uuidString.prefix(8)).lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: WorkCopies.root.path)) ?? []
        for name in names where name.hasSuffix(mine) {
            let folder = WorkCopies.root.appendingPathComponent(name).path
            guard await WorkCopies.parkedOwner(of: folder) == automation.id,
                  let theirs = await WorkCopies.repositoryRoot(ofCheckout: folder) else { continue }
            let current = Slug.canonicalPath(folder) == Slug.canonicalPath(home)
                && theirs == Slug.canonicalPath(sourceRoot)
            if !current {
                await WorkCopies.removeHome(folder, automationID: automation.id, sourceRoot: theirs)
            }
        }
        return home
    }

    /// Whether a run that could not take up its automation's folder may still run in a new one.
    /// Not when a new one would fail the same way: no repository, no start branch, no disk.
    nonisolated static func homeCanFallBack(_ failure: WorkCopies.Failure) -> Bool {
        switch failure {
        case .notOurs, .createFailed, .gitFailed: true
        default: false
        }
    }

    /// The automation whose own folder this copy is, when it is one.
    func homeAutomation(of copy: WorkCopy) -> UUID? {
        guard case .run(let runID) = copy.owner, let run = automations.run(id: runID) else { return nil }
        let home = WorkCopies.homeRoot(sourceRoot: copy.sourceRoot, automationID: run.automationID)
        return Slug.canonicalPath(home) == Slug.canonicalPath(copy.checkoutRoot) ? run.automationID : nil
    }

    /// What a copy needs before anyone can work in it with nobody watching: Claude has to trust
    /// the folder, and his MCP answers for the original have to hold for the copy. Both are keyed by
    /// exact path, so a new copy starts with neither.
    func readyForUnattendedWork(_ copy: WorkCopy) async {
        if let override = readyCopyOverride { await override(copy); return }
        ClaudeFolderTrust.grant(forProjectPath: copy.path)
        _ = await client.carryMcpDecisions(from: copy.sourcePath, to: copy.path)
    }

    nonisolated static func branchStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: date)
    }

    nonisolated static func copyProblem(_ failure: WorkCopies.Failure) -> String {
        switch failure {
        case .notARepository:
            return String(localized: "The folder is not a git repository, so there is nothing to make a separate copy of.")
        case .noBase(let name):
            return name.isEmpty
                ? String(localized: "Could not tell which branch to start from.")
                : String(format: String(localized: "There is no branch “%@” to start from."), name)
        case .lowDisk(let gb):
            return Fmt.count("Only %lld GB left on the disk — not enough for a separate copy and a build.", gb)
        case .createFailed(let detail):
            return String(format: String(localized: "git could not make the copy: %@"), detail)
        case .notOurs:
            return String(localized: "The copy's folder is not the one Bulava made, so it was left alone.")
        case .conflict(let files):
            return files.isEmpty
                ? String(localized: "The changes conflict with the branch. They are still in the copy — open it to resolve them.")
                : String(format: String(localized: "The changes conflict with the branch in %@. They are still in the copy — open it to resolve them."),
                         files.prefix(5).joined(separator: ", "))
        case .targetDirty(let branch):
            return String(format: String(localized: "Your folder has uncommitted changes on %@. Commit or put them aside, then merge again."), branch)
        case .targetElsewhere(let path):
            return String(format: String(localized: "The branch is open in another checkout (%@), so it was not moved under it."), path)
        case .targetMoved:
            return String(localized: "The branch moved while merging. Nothing was changed — merge again.")
        case .nothingToMerge:
            return String(localized: "There is nothing in the copy to merge.")
        case .gitFailed(let detail):
            return detail
        }
    }

    // MARK: - Following a run

    private func advanceRuns(now: Date) {
        for run in automations.runs where !run.state.isTerminal || run.result == .needsYou
            || (run.result == .changes && run.handoff == .waiting) {
            switch run.state {
            case .awaitingAway:
                followAway(run, now: now)
            case .preparing:
                // A preparation that is not happening any more was interrupted by a quit or a crash.
                if !automationPreparing.contains(run.id), now.timeIntervalSince(run.createdAt) > 300 {
                    Task { await prepareAndStart(run.id) }
                }
            case .running, .finished:
                followConversation(run, now: now)
            default:
                break
            }
        }
    }

    private func followAway(_ run: AutomationRun, now: Date) {
        let away = Self.secondsSinceInput() >= Double(AutomationSchedule.awayMinutes * 60)
        let due: Date? = {
            if case .scheduled(let at) = run.reason { return at }
            if case .caughtUp(let at) = run.reason { return at }
            return nil
        }()
        let overdue = due.map { now.timeIntervalSince($0) > Double(AutomationSchedule.awayWindowHours * 3600) } ?? true
        guard away || overdue else { return }
        automations.updateRun(run.id) { $0.state = .preparing }
        Task { await prepareAndStart(run.id) }
    }

    nonisolated static func secondsSinceInput() -> Double {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// Read the run's conversation and decide whether it has ended, and how.
    private func followConversation(_ run: AutomationRun, now: Date) {
        guard let chatID = run.chatID, let chat = conversations.chat(id: chatID) else {
            if run.state == .running { failRun(run.id, String(localized: "Its conversation is gone.")) }
            return
        }
        let phase = directPhase(for: chatID)
        if run.state == .finished {
            // Its own report being written is not more work: the run stays what it ended as.
            if generatingChatReportIDs.contains(chatID) { return }
            // He answered the question it stopped on, or asked for more on top of its changes, and
            // it is working again: what it hands over is decided when it stops this time.
            if phase.isActive || sendingChatIDs.contains(chatID) {
                automations.updateRun(run.id) {
                    $0.state = .running; $0.result = nil; $0.finishedAt = nil; $0.handoff = nil
                }
                if let copyID = run.workspaceID { automations.updateCopy(copyID) { $0.state = .active } }
            }
            return
        }
        if phase.isActive || sendingChatIDs.contains(chatID) { return }

        let binding = chat.session
        let instance = binding.flatMap { matchingInstance(for: $0) }
        if let instance, instance.pendingQuestion != nil || instance.doneResult == "needs-user"
            || instance.outcome == .blocked || instance.outcome == .needsInput {
            settle(run, result: .needsYou, summary: instance.outcomeSummary, now: now)
            return
        }
        let ended = instance.map { $0.doneResult != nil || ($0.outcome != nil && !$0.turnRunning) } ?? false
            || binding?.outcomeAt != nil
        if ended {
            let outcome = instance?.outcome
            let done = instance?.doneResult
            let lastAsked = conversations.entries(inChat: chatID).last(where: { $0.kind == .user })?.id
            Task {
                await self.conclude(run.id, chatID: chatID, lastAsked: lastAsked, outcome: outcome,
                                    done: done, summary: instance?.outcomeSummary)
            }
            return
        }
        // Nothing running and nothing said: the start was refused, or the message never landed.
        if let problem = chatErrors[chatID] {
            failRun(run.id, problem)
            return
        }
        if instance == nil, let started = run.startedAt, now.timeIntervalSince(started) > 900,
           !(binding.map { matchingInstance(for: $0) != nil } ?? false) {
            failRun(run.id, String(localized: "The run stopped without saying how it ended."))
        }
    }

    private func conclude(_ runID: UUID, chatID: UUID, lastAsked: UUID?, outcome: WorkerOutcome?,
                          done: String?, summary: String?) async {
        guard let run = automations.run(id: runID), run.state == .running else { return }
        let status = await run.workspaceID.flatMap { automations.copy(id: $0) }.asyncMap { await WorkCopies.status(of: $0) }
        // Read before the wait; true after it only if nobody has asked anything since and nothing
        // started — a follow-up sent meanwhile is a new turn this outcome says nothing about.
        guard automations.run(id: runID)?.state == .running,
              conversations.entries(inChat: chatID).last(where: { $0.kind == .user })?.id == lastAsked,
              !directPhase(for: chatID).isActive, !sendingChatIDs.contains(chatID) else { return }
        guard status?.inspected != false else { return }
        // A check hands nothing over: what it changed goes with its folder's reset, and is said.
        let checkOnly = automations.run(id: runID)?.checkOnly == true
        let hasWork = !checkOnly && (status?.hasWork ?? false)
        if checkOnly, status?.hasWork == true {
            automations.updateRun(runID) {
                $0.note = String(localized: "It changed files although it was only to check. The changes were thrown away; nothing reached your folder.")
            }
        }
        let result = Self.runResult(outcome: outcome, done: done, copyHasWork: status?.hasWork ?? false,
                                    checkOnly: checkOnly)
        // A reply to a remark made after the work says nothing about the work: «noted, changed
        // nothing» must not stand as the summary of a copy that holds the run's changes.
        let kept = Self.runSummary(turn: summary, turnOutcome: outcome, copyHasWork: hasWork,
                                   earlier: automations.run(id: runID)?.summary)
        settle(run, result: result, summary: kept, now: Date())
    }

    /// How a run ended, from what its worker declared and what its copy holds. A check never ends
    /// with changes to hand over, whatever it left in the folder.
    nonisolated static func runResult(outcome: WorkerOutcome?, done: String?, copyHasWork: Bool,
                                      checkOnly: Bool) -> AutomationRun.Result {
        let hasWork = copyHasWork && !checkOnly
        if outcome == .failed && !hasWork { return .failed }
        if hasWork { return .changes }
        if outcome == .succeededResearch { return .report }
        if done == "debt" { return .unverified }
        return .noChange
    }

    nonisolated static func runSummary(turn: String?, turnOutcome: WorkerOutcome?, copyHasWork: Bool,
                                       earlier: String?) -> String? {
        guard turnOutcome == .succeededNoChange, copyHasWork,
              let earlier, !earlier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return turn }
        return earlier
    }

    func settle(_ run: AutomationRun, result: AutomationRun.Result, summary: String?, now: Date) {
        guard let fresh = automations.run(id: run.id), fresh.state == .running else { return }
        automations.updateRun(run.id) {
            $0.state = .finished
            $0.result = result
            $0.finishedAt = now
            $0.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            if result == .changes { $0.handoff = .waiting }
            if result == .failed, $0.items.contains(where: { !$0.retried }) { $0.retryOwed = true }
            $0.seen = false
        }
        if let copyID = run.workspaceID {
            automations.updateCopy(copyID) { $0.state = result == .changes ? .waiting : $0.state }
        }
        // A question is not an ending: what the run was handed is settled when it really ends.
        if result != .needsYou { settleWatchItems(run, succeeded: result != .failed) }
        if result == .failed { pauseAfterRepeatedFailures(run.automationID) }
        // A run that got through says the earlier failures of the same automation are history:
        // they no longer wait for him.
        if result != .failed && result != .needsYou {
            for older in automations.runs(for: run.automationID)
            where older.id != run.id && older.isRealFailure && !older.seen && older.createdAt < run.createdAt {
                automations.updateRun(older.id) { $0.seen = true }
            }
        }

        // A run that did something ends with a written report, asked for in the same conversation
        // the way the chat's "Make a report" does it. Before this a run that was never told to
        // write one left a folder of screenshots, and "Open report" opened that folder. Asked
        // before the sweep below, which keeps the copy while its report is being written.
        if Self.wantsWrittenReport(result), let chatID = run.chatID, fresh.reportAsked != true {
            automations.updateRun(run.id) { $0.reportAsked = true }
            generateChatReport(chatID: chatID, opensWhenDone: false)
        }

        let name = automations.automation(id: run.automationID)?.name ?? String(localized: "Automation")
        switch result {
        case .changes: notify(title: name, body: String(localized: "Finished with changes. They wait in their copy for you."))
        case .report: notify(title: name, body: String(localized: "Finished with a report."))
        case .needsYou: notify(title: name, body: String(localized: "Needs your answer."))
        case .failed: notify(title: name, body: String(localized: "The run failed."))
        case .unverified: notify(title: name, body: String(localized: "Finished, but the review could not be completed."))
        case .noChange: break
        }
        // Nothing to hand over: the copy has done its job.
        if result != .changes && result != .needsYou { Task { await sweepCopies() } }
    }

    func failRun(_ runID: UUID, _ why: String) {
        guard let run = automations.run(id: runID), !run.state.isTerminal || run.state == .finished else { return }
        automations.updateRun(runID) {
            $0.state = .failed
            $0.note = why
            $0.finishedAt = Date()
            $0.seen = false
            if $0.items.contains(where: { !$0.retried }) { $0.retryOwed = true }
        }
        settleWatchItems(run, succeeded: false)
        if let name = automations.automation(id: run.automationID)?.name {
            notify(title: name, body: why)
        }
        pauseAfterRepeatedFailures(run.automationID)
        Task { await sweepCopies() }
    }

    /// Two failures in a row switch it off, with the reason on it. A watch that fails every fifteen
    /// minutes would otherwise spend the night — and the week's limit — failing.
    private func pauseAfterRepeatedFailures(_ automationID: UUID) {
        // Runs that ran: a skip, or a run he stopped himself, says nothing about whether it works.
        let recent = automations.runs(for: automationID)
            .filter { $0.state != .skipped && !$0.stoppedByHand && $0.state.isTerminal }
            .prefix(2)
        guard recent.count == 2, recent.allSatisfy(\.isRealFailure) else { return }
        automations.update(automationID) {
            $0.enabled = false
            $0.pausedReason = String(localized: "Switched off after two failed runs in a row. Look at the last one, then switch it back on.")
        }
    }

    /// What a watch handed to a run is remembered once the run got through it, and handed back
    /// once when it did not.
    private func settleWatchItems(_ run: AutomationRun, succeeded: Bool) {
        guard !run.items.isEmpty else { return }
        // A run concluded a second time — its ending was not on disk yet when the app quit — hands
        // nothing back twice, and nothing a retry run already has.
        let owned = ownedKeys(run.automationID)
        automations.update(run.automationID) { a in
            guard a.watch != nil else { return }
            if succeeded {
                a.watch?.remember(run.items.map(\.id))
            } else {
                let waiting = Set((a.watch?.pending ?? []).map(Self.ownershipKey))
                let again = run.items.filter { !$0.retried }.map { item -> WatchItem in
                    var i = item; i.retried = true; return i
                }.filter { !waiting.contains(Self.ownershipKey($0)) && !owned.contains(Self.ownershipKey($0)) }
                a.watch?.pending.append(contentsOf: again)
                if !again.isEmpty, a.watch?.pendingSince == nil { a.watch?.pendingSince = Date() }
                a.watch?.remember(run.items.filter(\.retried).map(\.id))
            }
        }
    }

    func stopRun(_ runID: UUID) {
        guard let run = automations.run(id: runID) else { return }
        if let chatID = run.chatID, directPhase(for: chatID).isActive {
            stopDirectChat(chatID)
        }
        if !run.state.isTerminal || (run.state == .finished && run.result == .needsYou) {
            automations.updateRun(runID) {
                $0.state = .failed
                $0.stoppedByHand = true
                $0.note = String(localized: "You stopped this run.")
                $0.finishedAt = Date()
                $0.seen = true
            }
            // He stopped it on purpose: what it was handed is not tried again behind his back.
            if !run.items.isEmpty {
                automations.update(run.automationID) { $0.watch?.remember(run.items.map(\.id)) }
            }
            Task { await sweepCopies() }
        }
    }

    func markRunSeen(_ runID: UUID) {
        automations.updateRun(runID) { $0.seen = true }
    }

    /// The run's own conversation, in the product's conversation view — where its question is
    /// answered, its work followed, and its result read.
    func openRunChat(_ run: AutomationRun) {
        guard let chatID = run.chatID, let chat = conversations.chat(id: chatID) else { return }
        markRunSeen(run.id)
        if chat.archived {
            conversations.viewArchived(chatID, for: chat.productID)
        } else {
            conversations.open(chatID, for: chat.productID)
        }
        navigate(to: .product(chat.productID))
    }

    // MARK: - Handing the work over

    /// Merge a run's changes into the branch it started from. Returns why not, in words.
    func mergeRun(_ runID: UUID) async -> String? {
        guard let run = automations.run(id: runID), let copyID = run.workspaceID,
              let copy = automations.copy(id: copyID), copy.isLive else {
            return String(localized: "This run has no copy to merge.")
        }
        if let busy = runIsWorking(run) { return busy }
        return await mergeCopy(copy, message: mergeMessage(for: run)) { [weak self] in
            self?.automations.updateRun(runID) {
                $0.handoff = .merged
                $0.mergedInto = copy.baseRef
                $0.seen = true
            }
        }
    }

    func mergeMessage(for run: AutomationRun) -> String {
        let name = automations.automation(id: run.automationID)?.name ?? "Bulava"
        let line = run.summary?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? name : "\(name): \(line.prefix(120))"
    }

    func mergeCopy(_ copy: WorkCopy, message: String, onMerged: @escaping () -> Void) async -> String? {
        let merged: String? = await withCopy(copy.id, busy: String(localized: "Something else is being done with this copy right now.")) {
            if let problem = await releaseCopySession(copy) { return problem }
            switch await WorkCopies.merge(copy, message: message) {
            case .success(let sha):
                automations.updateCopy(copy.id) { $0.state = .merged; $0.mergedSHA = sha }
                onMerged()
                return nil
            case .failure(.nothingToMerge):
                automations.updateCopy(copy.id) { $0.state = .merged }
                onMerged()
                return nil
            case .failure(let f) where Self.chatCanMerge(f):
                return handMergeToChat(copy) ?? Self.handedOver
            case .failure(let f):
                return Self.copyProblem(f)
            }
        }
        if merged == Self.handedOver { return nil }
        guard merged == nil else { return merged }
        // Taken away after the merge, as its own step: a removal that does not go through leaves a
        // merged copy the sweep finishes later, never a merge reported as failed.
        _ = await removeCopy(copy.id, force: false, branch: .deleteIfIntegrated)
        await refreshCurrentBranches()
        return nil
    }

    // MARK: - A merge the chat finishes

    /// What stops the app from merging alone, but not an agent that can put his changes aside and
    /// resolve a conflict. He pressed «Merge»: being told to commit first is not an answer to that.
    nonisolated static func chatCanMerge(_ failure: WorkCopies.Failure) -> Bool {
        switch failure {
        case .targetDirty, .conflict, .targetMoved: return true
        default: return false
        }
    }

    /// A marker `mergeCopy` returns from inside the copy's lock, never shown.
    nonisolated static let handedOver = "\u{0}handed-over"

    /// The chat a copy belongs to, if it has one to ask.
    func chatID(ofCopy copy: WorkCopy) -> UUID? {
        switch copy.owner {
        case .chat(let id): return id
        case .run(let runID): return automations.run(id: runID)?.chatID
        case .task: return nil
        }
    }

    /// Ask the copy's own chat to merge it. Returns why not, in words; nil once the message went.
    func handMergeToChat(_ copy: WorkCopy) -> String? {
        guard let chatID = chatID(ofCopy: copy), let chat = conversations.chat(id: chatID) else {
            return String(localized: "This copy has no chat to finish the merge.")
        }
        automations.updateCopy(copy.id) { $0.integrating = Date() }
        let text = String(format: String(localized: "Merge this copy into %@. Bulava could not do it by itself: your folder has uncommitted changes, or the branches have diverged. Keep my uncommitted changes, do not commit them."), copy.baseRef)
        switch sendDirectMessage(text, productID: chat.productID, chatID: chatID) {
        case .sent, .alreadySent:
            return nil
        case .noSuchProduct, .empty:
            automations.updateCopy(copy.id) { $0.integrating = nil }
            return String(localized: "This copy has no chat to finish the merge.")
        }
    }

    /// A handed-over merge is over when its chat stops. Git decides how it went: an answer of
    /// «done» proves nothing. Merged — the copy goes as after any merge; not merged — the button
    /// comes back and the chat's answer says what stopped it.
    func followHandedMerges(now: Date) {
        for copy in automations.copies where copy.isLive {
            guard let since = copy.integrating, now.timeIntervalSince(since) > 15,
                  !mergingHandedCopies.contains(copy.id) else { continue }
            if let chatID = chatID(ofCopy: copy),
               directPhase(for: chatID).isActive || sendingChatIDs.contains(chatID) { continue }
            mergingHandedCopies.insert(copy.id)
            Task { [weak self] in
                await self?.settleHandedMerge(copy.id)
                self?.mergingHandedCopies.remove(copy.id)
            }
        }
    }

    func settleHandedMerge(_ copyID: UUID) async {
        guard let copy = automations.copy(id: copyID), copy.isLive, copy.integrating != nil else { return }
        guard await WorkCopies.isIntegrated(copy) else {
            automations.updateCopy(copyID) { $0.integrating = nil }
            return
        }
        let sha = await WorkCopies.tip(of: copy)
        automations.updateCopy(copyID) { $0.state = .merged; $0.mergedSHA = sha; $0.integrating = nil }
        switch copy.owner {
        case .run(let runID):
            automations.updateRun(runID) { $0.handoff = .merged; $0.mergedInto = copy.baseRef; $0.seen = true }
        case .chat(let chatID):
            conversations.setWorkCopy(nil, for: chatID)
            conversations.setWantsCopy(false, for: chatID)
        case .task:
            break
        }
        _ = await removeCopy(copyID, force: false, branch: .deleteIfIntegrated)
        await refreshCurrentBranches()
    }

    /// Why a run's copy must not be merged or thrown away right now: its conversation is working.
    func runIsWorking(_ run: AutomationRun) -> String? {
        guard let chatID = run.chatID else { return nil }
        if directPhase(for: chatID).isActive || sendingChatIDs.contains(chatID) || run.state == .running {
            return String(localized: "It is still working. Wait for it to finish.")
        }
        return nil
    }

    /// Throw a run's changes away, with the copy and its branch. Nothing about the run or the copy
    /// changes unless the removal itself goes through.
    func discardRun(_ runID: UUID) async -> String? {
        guard let run = automations.run(id: runID), let copyID = run.workspaceID,
              automations.copy(id: copyID)?.isLive == true else { return nil }
        if let busy = runIsWorking(run) { return busy }
        let problem = await withCopy(copyID, busy: String(localized: "Something else is being done with this copy right now.")) {
            await removeCopyLocked(copyID, force: true, branch: .delete)
        }
        if problem == nil {
            automations.updateRun(runID) { $0.handoff = .discarded; $0.seen = true }
        }
        return problem
    }

    /// Nothing may still be running in a folder that is about to move or go. Asked of the engine
    /// now, not of the last snapshot; a stop that did not take stops whatever was to follow.
    func releaseCopySession(_ copy: WorkCopy) async -> String? {
        let path = Slug.canonicalPath(copy.path)
        let live = await client.readInstances()
        guard let instance = live.first(where: { Slug.canonicalPath($0.projectPath) == path }) else { return nil }
        if let failure = await releaseProject(path: copy.path, session: instance.session) {
            return Self.releaseProblem(failure)
        }
        return nil
    }

    /// One operation on a copy at a time: a merge, a removal and a sweep must never interleave on
    /// the same folder.
    private func withCopy<T>(_ id: UUID, busy: T, _ body: () async -> T) async -> T {
        guard !copyOperations.contains(id) else { return busy }
        copyOperations.insert(id)
        defer { copyOperations.remove(id) }
        return await body()
    }

    @discardableResult
    func removeCopy(_ copyID: UUID, force: Bool, branch: WorkCopies.BranchFate) async -> String? {
        await withCopy(copyID, busy: String(localized: "Something else is being done with this copy right now.")) {
            await removeCopyLocked(copyID, force: force, branch: branch)
        }
    }

    /// The removal itself, for a caller already holding the copy.
    private func removeCopyLocked(_ copyID: UUID, force: Bool, branch: WorkCopies.BranchFate) async -> String? {
        guard let copy = automations.copy(id: copyID) else { return nil }
        if let problem = await releaseCopySession(copy) { return problem }
        // An automation's own folder is not removed when its run is done with it: it is parked for
        // the next run, its build and local files kept. Everything else about the ending is the same.
        let home = homeAutomation(of: copy)
        let done = if let home {
            await WorkCopies.park(copy, automationID: home, force: force, branch: branch)
        } else {
            await WorkCopies.remove(copy, force: force, branch: branch)
        }
        switch done {
        case .success:
            automations.updateCopy(copyID) { $0.state = .removed; $0.removedAt = Date() }
            followCarriedReports(of: copy)
            if home == nil, readyCopyOverride == nil { ClaudeFolderTrust.forget(forProjectPath: copy.checkoutRoot) }
            return nil
        case .failure(let f):
            return Self.copyProblem(f)
        }
    }

    /// What a run left in `artifacts/`: the copy's folder while the copy is there, the folder it was
    /// carried to once the copy is gone. Nil when it left nothing.
    func reportFolder(for run: AutomationRun) -> URL? {
        guard let copyID = run.workspaceID, let copy = automations.copy(id: copyID) else { return nil }
        if copy.isLive {
            let live = URL(fileURLWithPath: copy.path).appendingPathComponent("artifacts", isDirectory: true)
            if Self.hasVisibleFiles(live) { return live }
        }
        let kept = WorkCopies.keptArtifacts(for: copy)
        return Self.hasVisibleFiles(kept) ? kept : nil
    }

    /// The run's written report, when it has one: the page its report turn recorded, wherever the
    /// copy has gone since; otherwise the newest report in what it left. Screenshots and a video
    /// are not one — they are evidence, and say nothing about what was done or how it was checked.
    func reportPage(for run: AutomationRun) -> URL? {
        if let chatID = run.chatID, let paths = conversations.chat(id: chatID)?.session?.reportPaths {
            for path in paths.reversed() where FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return reportFolder(for: run).flatMap(Self.newestWrittenReport(in:))
    }

    /// Files a run left with no written report beside them. Shown as what they are.
    func evidenceOnlyFolder(for run: AutomationRun) -> URL? {
        guard reportPage(for: run) == nil else { return nil }
        return reportFolder(for: run)
    }

    nonisolated static func wantsWrittenReport(_ result: AutomationRun.Result) -> Bool {
        result == .changes || result == .report || result == .unverified
    }

    /// The newest written report in an `artifacts/` folder: a dated report page as `artifact`
    /// builds it (`<date-title>/index.html`), else a document at the top — `.md`, `.html`, `.pdf`.
    nonisolated static func newestWrittenReport(in artifacts: URL) -> URL? {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: artifacts.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "latest" }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let pages = names.map { artifacts.appendingPathComponent($0).appendingPathComponent("index.html") }
            .filter { fm.fileExists(atPath: $0.path) }
        if let page = pages.max(by: { modified($0) < modified($1) }) { return page }
        let documents = names.map { artifacts.appendingPathComponent($0) }
            .filter { ["md", "html", "pdf"].contains($0.pathExtension.lowercased()) }
        return documents.max(by: { modified($0) < modified($1) })
    }

    nonisolated static func hasVisibleFiles(_ url: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).contains { !$0.hasPrefix(".") }
    }

    /// Open a run's written report: a page in Bulava's report viewer, any other document as itself.
    func openReport(of run: AutomationRun) {
        guard let page = reportPage(for: run) else { return }
        markRunSeen(run.id)
        if page.pathExtension.lowercased() == "html" {
            let title = run.chatID.flatMap { conversations.chat(id: $0)?.title }
                ?? automations.automation(id: run.automationID)?.name ?? ""
            openChatReport(path: page.path, title: title)
        } else {
            NSWorkspace.shared.open(page)
        }
    }

    /// A removed copy's `artifacts/` was carried to `copies-kept`; the reports its conversations
    /// recorded follow it there, so "Open the report" — on the Mac and on the phone — still opens.
    func followCarriedReports(of copy: WorkCopy) {
        let from = Slug.canonicalPath(URL(fileURLWithPath: copy.path).appendingPathComponent("artifacts").path) + "/"
        let to = WorkCopies.keptArtifacts(for: copy).path + "/"
        for chat in conversations.chats {
            guard let paths = chat.session?.reportPaths,
                  paths.contains(where: { Slug.canonicalPath($0).hasPrefix(from) }) else { continue }
            conversations.updateSession(for: chat.id) { session in
                session.reportPaths = session.reportPaths.map { path in
                    let canonical = Slug.canonicalPath(path)
                    return canonical.hasPrefix(from) ? to + canonical.dropFirst(from.count) : path
                }
            }
        }
    }

    func openEvidence(of run: AutomationRun) {
        guard let folder = evidenceOnlyFolder(for: run) else { return }
        markRunSeen(run.id)
        NSWorkspace.shared.open(folder)
    }

    func openCopy(_ copyID: UUID) {
        guard let copy = automations.copy(id: copyID), FileManager.default.fileExists(atPath: copy.path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: copy.path, isDirectory: true))
    }

    func copyDiff(_ copyID: UUID) async -> String {
        guard let copy = automations.copy(id: copyID) else { return "" }
        return await WorkCopies.diff(of: copy)
    }

    func copyStatus(_ copyID: UUID) async -> WorkCopyStatus {
        guard let copy = automations.copy(id: copyID) else { return .missing }
        return await WorkCopies.status(of: copy)
    }

    // MARK: - A copy for an ordinary chat

    /// The folder this conversation's worker actually runs in: its copy when it has one, his
    /// folder otherwise. A run whose copy is gone is refused rather than sent home.
    func executionProject(for chatID: UUID, primary: Project) async -> Result<Project, ChatCopyRefusal> {
        guard let chat = conversations.chat(id: chatID) else { return .success(primary) }
        if let copyID = chat.workCopyID, let copy = automations.copy(id: copyID) {
            if copyOperations.contains(copyID) {
                return .failure(ChatCopyRefusal(message: String(localized: "Its copy is being merged or cleaned up right now. Send again in a moment.")))
            }
            // Asked again after the wait: a merge or a removal may have taken it meanwhile.
            if copy.isLive, await WorkCopies.isOurs(copy), !copyOperations.contains(copyID),
               automations.copy(id: copyID)?.isLive == true {
                var inCopy = primary
                inCopy.path = copy.path
                return .success(inCopy)
            }
            if chat.isAutomationRun {
                return .failure(ChatCopyRefusal(message: String(localized: "This run's copy has already been cleaned up, so there is nowhere to continue it. Start the automation again for a fresh run.")))
            }
        } else if chat.isAutomationRun {
            return .failure(ChatCopyRefusal(message: String(localized: "This run has no copy to work in.")))
        }
        guard chat.wantsCopy else { return .success(primary) }

        // Two first messages sent close together wait on the same copy instead of making two.
        if let making = chatCopyMaking[chatID] {
            return await making.value.map { copy in var p = primary; p.path = copy.path; return p }
        }
        let making = Task { () -> Result<WorkCopy, ChatCopyRefusal> in
            await self.makeChatCopy(chatID: chatID, primary: primary)
        }
        chatCopyMaking[chatID] = making
        let result = await making.value
        chatCopyMaking[chatID] = nil
        return result.map { copy in var p = primary; p.path = copy.path; return p }
    }

    /// An ordinary chat that asked for a copy: made with its first message, from the branch his
    /// folder is on now — the work he is in the middle of is what he asked about.
    private func makeChatCopy(chatID: UUID, primary: Project) async -> Result<WorkCopy, ChatCopyRefusal> {
        let base = await WorkCopies.currentBranch(of: primary.path)
        let id = UUID()
        if let sourceRoot = await WorkCopies.topLevel(of: primary.path) {
            let planned = WorkCopies.plannedCheckoutRoot(sourceRoot: sourceRoot, id: id)
            automations.addCopy(WorkCopy(id: id, path: planned, checkoutRoot: planned, sourcePath: primary.path,
                                         sourceRoot: sourceRoot, projectID: primary.id, branch: "", baseRef: "",
                                         baseSHA: "", owner: .chat(chatID), state: .preparing))
        }
        let made = await WorkCopies.make(sourcePath: primary.path, projectID: primary.id, baseRef: base,
                                         branch: "bulava/chat-\(chatID.uuidString.prefix(8).lowercased())",
                                         owner: .chat(chatID), id: id)
        switch made {
        case .success(let copy):
            automations.addCopy(copy)
            await readyForUnattendedWork(copy)
            conversations.setWorkCopy(copy.id, for: chatID)
            // A session belongs to the folder it was started in: the copy starts its own.
            conversations.clearSession(for: chatID, primaryProjectID: primary.id, projectPath: copy.path)
            return .success(copy)
        case .failure(let f):
            automations.updateCopy(id) { $0.state = .removed; $0.removedAt = Date() }
            return .failure(ChatCopyRefusal(message: Self.copyProblem(f)))
        }
    }

    /// The live copy a chat works in, if it has one.
    func liveCopy(forChat chatID: UUID?) -> WorkCopy? {
        guard let chatID, let id = conversations.chat(id: chatID)?.workCopyID,
              let copy = automations.copy(id: id), copy.isLive else { return nil }
        return copy
    }

    /// Merge an ordinary chat's copy into the branch it was made from.
    func mergeChatCopy(_ chatID: UUID) async -> String? {
        guard let copy = liveCopy(forChat: chatID) else { return nil }
        if directPhase(for: chatID).isActive || sendingChatIDs.contains(chatID) {
            return String(localized: "It is still working. Wait for it to finish.")
        }
        let title = conversations.chat(id: chatID)?.title ?? "Bulava"
        return await mergeCopy(copy, message: title) { [weak self] in
            self?.conversations.setWorkCopy(nil, for: chatID)
            self?.conversations.setWantsCopy(false, for: chatID)
        }
    }

    func discardChatCopy(_ chatID: UUID) async -> String? {
        guard let copy = liveCopy(forChat: chatID) else { return nil }
        if directPhase(for: chatID).isActive || sendingChatIDs.contains(chatID) {
            return String(localized: "It is still working. Wait for it to finish.")
        }
        let problem = await removeCopy(copy.id, force: true, branch: .delete)
        if problem == nil {
            conversations.setWorkCopy(nil, for: chatID)
            conversations.setWantsCopy(false, for: chatID)
        }
        return problem
    }

    // MARK: - Conversations an older build unlinked

    /// Put back what tells a conversation it is a run, or that it works in a copy, from the records
    /// that own the copy.
    ///
    /// An older Bulava reads `chats.json` without these fields and writes it back without them.
    /// 4 Oct: an installed 1.10 took over from a Debug build in the middle of an automation's run, and
    /// the run's chat became an ordinary one bound to his folder — the next thing he typed into it
    /// resumed the run's conversation there, on his branch, while the run was alive in its copy. The
    /// runs and the copies live in files an older build never opens, so they still know which chat
    /// is whose. A chat that already agrees is left as it is; on every tick this costs a comparison.
    func relinkCopyChats() {
        for run in automations.runs {
            guard let chatID = run.chatID, let copyID = run.workspaceID,
                  // A deleted automation's chats are ordinary on purpose (`releaseAutomationChat`).
                  automations.automation(id: run.automationID) != nil,
                  let copy = automations.copy(id: copyID) else { continue }
            relinkCopyChat(chatID, runID: run.id, copy: copy)
        }
        for copy in automations.copies where copy.isLive {
            guard case .chat(let chatID) = copy.owner else { continue }
            relinkCopyChat(chatID, runID: nil, copy: copy)
        }
    }

    private func relinkCopyChat(_ chatID: UUID, runID: UUID?, copy: WorkCopy) {
        guard let chat = conversations.chat(id: chatID), !sendingChatIDs.contains(chatID),
              chat.workCopyID == nil || chat.workCopyID == copy.id else { return }
        let session = copy.isLive ? reboundToCopy(chat.session, copy: copy) : nil
        let unlinked = (runID != nil && chat.automationRunID == nil) || chat.workCopyID == nil
            || (copy.isLive && !chat.wantsCopy) || session != nil
        guard unlinked else { return }
        conversations.relinkCopy(chatID, runID: runID,
                                 copyID: copy.id, session: session)
    }

    /// The binding moved into the copy, or nil when it is already there or must not be moved yet. A
    /// turn running where the binding points is left to end: the next tick moves it.
    func reboundToCopy(_ old: ChatSessionBinding?, copy: WorkCopy) -> ChatSessionBinding? {
        guard let old, Slug.canonicalPath(old.projectPath) != Slug.canonicalPath(copy.path) else { return nil }
        if let there = matchingInstance(for: old), there.active || there.turnRunning || there.waitingToContinue {
            return nil
        }
        let inCopy = snapshot.instances.first { Slug.canonicalPath($0.projectPath) == Slug.canonicalPath(copy.path) }
        return ChatSessionBinding(primaryProjectID: old.primaryProjectID ?? copy.projectID,
                                  projectPath: copy.path,
                                  claudeSessionID: inCopy?.sessionID ?? old.claudeSessionID,
                                  codexThreadID: old.codexThreadID,
                                  activeRunID: inCopy?.runID,
                                  branch: copy.branch.isEmpty ? inCopy?.branch : copy.branch,
                                  startedAt: inCopy?.startedAt ?? old.startedAt,
                                  outcomeAt: old.outcomeAt,
                                  lastCompletedTurnKey: old.lastCompletedTurnKey,
                                  lastReportedTurnKey: old.lastReportedTurnKey,
                                  reportPaths: old.reportPaths)
    }

    // MARK: - Cleaning up

    /// Take away every copy whose work is over: merged, thrown away, or never holding any. A copy
    /// with work nobody has decided about, with ignored files that are somebody's, or with
    /// anything still running in it stays.
    func sweepCopies() async {
        guard !sweepingCopies else { return }
        sweepingCopies = true
        defer { sweepingCopies = false }

        for copy in automations.copies where copy.needsReconciling {
            guard !copyOperations.contains(copy.id) else { continue }
            // A message on its way into it: it is in use, whatever its owner says.
            if conversations.chats.contains(where: { $0.workCopyID == copy.id && sendingChatIDs.contains($0.id) }) {
                continue
            }
            if case .run(let runID) = copy.owner, automationPreparing.contains(runID) { continue }
            if case .chat(let chatID) = copy.owner, chatCopyMaking[chatID] != nil { continue }
            guard let decision = await copyFate(copy) else { continue }
            _ = await removeCopy(copy.id, force: decision.force, branch: decision.branch)
        }
        // Strangers are looked at only when nothing is being made: a copy half way through being
        // made has its marker before it has a finished record.
        if automationPreparing.isEmpty, chatCopyMaking.isEmpty, copyOperations.isEmpty {
            await sweepOrphanCopies()
            await sweepAbandonedHomes()
        }
    }

    /// The parked folder of an automation he deleted. Only that: an automation that is still there
    /// gives up a folder it has outgrown — another repository — when its next run starts
    /// (`freeHome`), so a removal here can never meet a run taking the same folder up.
    ///
    /// Deleted, not merely unknown. A deleted automation's runs stay on the record; an automation
    /// this Bulava never had has none. Taking "not in the list" for "deleted" would let a list that
    /// failed to load — or another Bulava's model looking at the same folders, as the test host's
    /// does — wipe every automation's folder.
    private func sweepAbandonedHomes() async {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: WorkCopies.root.path) else { return }
        for name in names {
            let folder = WorkCopies.root.appendingPathComponent(name).path
            guard let automationID = await WorkCopies.parkedOwner(of: folder),
                  automations.automation(id: automationID) == nil,
                  automations.runs.contains(where: { $0.automationID == automationID }),
                  let sourceRoot = await WorkCopies.repositoryRoot(ofCheckout: folder) else { continue }
            await WorkCopies.removeHome(folder, automationID: automationID, sourceRoot: sourceRoot)
        }
    }

    private func copyFate(_ copy: WorkCopy) async -> (force: Bool, branch: WorkCopies.BranchFate)? {
        // Something is working in it right now.
        let path = Slug.canonicalPath(copy.path)
        if let instance = snapshot.instances.first(where: { Slug.canonicalPath($0.projectPath) == path }),
           instance.active || instance.turnRunning || instance.waitingToContinue {
            return nil
        }
        // Its run's report is being written in it: the report reads the work, and the screenshots
        // it reuses are in this copy's `artifacts/`.
        if case .run(let runID) = copy.owner, let chatID = automations.run(id: runID)?.chatID,
           generatingChatReportIDs.contains(chatID) {
            return nil
        }
        // Its folder was given back to the automation and a quit came before this record said so.
        // Finishing the park again only deals with the branch, as it was meant to.
        if copy.state != .removed, let automationID = homeAutomation(of: copy),
           await WorkCopies.isParked(copy.checkoutRoot, automationID: automationID, sourceRoot: copy.sourceRoot) {
            let thrownAway = copy.state == .discarded
            return (thrownAway, thrownAway ? .delete : .deleteIfIntegrated)
        }
        switch copy.state {
        case .merged:
            return (false, .deleteIfIntegrated)
        case .discarded:
            return (true, .delete)
        case .removed:
            return nil
        case .preparing:
            // Interrupted while being made. Its owner either resumes it or has given up on it.
            if case .run(let runID) = copy.owner, let run = automations.run(id: runID), !run.state.isTerminal {
                return nil
            }
        case .active, .waiting:
            break
        }
        guard FileManager.default.fileExists(atPath: copy.checkoutRoot) else {
            // Removed by hand. The record follows what is on disk.
            automations.updateCopy(copy.id) { $0.state = .removed; $0.removedAt = Date() }
            return nil
        }
        let ownerDone: Bool
        switch copy.owner {
        case .run(let runID):
            guard let run = automations.run(id: runID) else { ownerDone = true; break }
            if run.state == .finished, run.result == .changes, run.handoff == .waiting { return nil }
            if run.state == .finished, run.result == .needsYou { return nil }
            ownerDone = run.state.isTerminal
        case .chat(let chatID):
            guard let chat = conversations.chat(id: chatID) else { ownerDone = true; break }
            ownerDone = chat.archived || Date().timeIntervalSince(chat.updatedAt) > 24 * 3600
        case .task(let taskID):
            // A card's copy stays while the card is open and still points at it.
            guard let task = backlog.task(id: taskID) else { ownerDone = true; break }
            let stillItsFolder = task.worktree.map { Slug.canonicalPath($0) == Slug.canonicalPath(copy.path) } ?? false
            ownerDone = isFinished(task) || !stillItsFolder
        }
        guard ownerDone else { return nil }
        let status = await WorkCopies.status(of: copy)
        guard status.exists, status.inspected else { return nil }
        if case .task = copy.owner {
            // The card's commits live on in its branch, which the card's review and merge read; the
            // folder can go once nothing uncommitted or ignored-and-his is left in it.
            guard status.uncommitted.isEmpty, status.keepsakes.isEmpty else { return nil }
            return (false, status.commitsAhead > 0 ? .keep : .deleteIfIntegrated)
        }
        // A check leaves nothing to decide about: whatever it changed goes, its reports carried out.
        if case .run(let runID) = copy.owner, automations.run(id: runID)?.checkOnly == true {
            return (true, .delete)
        }
        // The automation's own folder keeps what git ignores, so those files hold nothing back.
        let parks = homeAutomation(of: copy) != nil
        if status.hasWork {
            // Work nobody has decided about is never removed by a sweep.
            if case .run = copy.owner {
                automations.updateCopy(copy.id) { $0.state = .waiting }
            }
            return nil
        }
        guard parks || status.keepsakes.isEmpty else { return nil }
        return (false, .delete)
    }

    /// A copy git knows about and our records do not — Bulava quit between making it and writing
    /// it down. Removed only when it is provably ours and holds no commit of its own.
    private func sweepOrphanCopies() async {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: WorkCopies.root.path) else { return }
        let known = Set(automations.copies.map { Slug.canonicalPath($0.checkoutRoot) })
        for name in names {
            let folder = WorkCopies.root.appendingPathComponent(name).path
            guard !known.contains(Slug.canonicalPath(folder)) else { continue }
            let common = await WorkCopies.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: folder)
            let commonDir = common.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard common.ok, commonDir.hasSuffix("/.git") else { continue }
            let sourceRoot = (commonDir as NSString).deletingLastPathComponent
            let gitDir = await WorkCopies.git(["rev-parse", "--absolute-git-dir"], in: folder)
            let marker = (gitDir.stdout.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                .appendingPathComponent("bulava-copy")
            guard let id = (try? String(contentsOfFile: marker, encoding: .utf8))
                .flatMap({ UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { continue }
            let branch = await WorkCopies.currentBranch(of: folder) ?? ""
            let probe = WorkCopy(id: id, path: folder, checkoutRoot: folder, sourcePath: sourceRoot,
                                 sourceRoot: sourceRoot, projectID: UUID(), branch: branch,
                                 baseRef: branch, baseSHA: "HEAD", owner: .run(UUID()))
            let status = await WorkCopies.status(of: probe)
            guard status.exists, status.inspected, status.uncommitted.isEmpty, status.keepsakes.isEmpty else { continue }
            // Commits nothing else in the repository has: those would be lost with the branch.
            let ahead = await WorkCopies.git(["log", "--oneline", "HEAD", "--not", "--exclude=\(branch)",
                                              "--branches", "--remotes"], in: folder)
            guard ahead.ok, ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // Asked again after every wait above: it may have been written down, or started, since.
            guard automationPreparing.isEmpty, chatCopyMaking.isEmpty,
                  !automations.copies.contains(where: { $0.id == id || Slug.canonicalPath($0.checkoutRoot) == Slug.canonicalPath(folder) })
            else { continue }
            _ = await WorkCopies.remove(probe, force: false, branch: .delete)
        }
    }

    // MARK: - What wants him

    /// Runs waiting for him across every automation: changes to merge, a question, a failure, a
    /// run asking to start.
    var automationRunsWantingHim: [AutomationRun] {
        automations.runs.filter(runWantsHim)
    }

    /// Whether a run is waiting for him right now. A question counts until it is answered — opening
    /// its conversation and leaving it unanswered does not make it go away.
    func runWantsHim(_ run: AutomationRun) -> Bool {
        let live = run.chatID.map { directPhase(for: $0).wantsAttention } ?? false
        switch run.state {
        case .running: return live
        case .finished where run.result == .needsYou: return true
        default: return run.wantsHim
        }
    }

    /// Open whatever is waiting in a product: its own conversation when one of those is, and
    /// otherwise the automation run that is — a product whose only question sits in a run must
    /// not open onto an empty chat.
    func openWhatWaits(inProduct id: UUID) {
        let chatWaits = conversations.chats(for: id).contains { directPhase(for: $0.id).wantsAttention }
        if !chatWaits, let run = automationRunsWantingHim(inProduct: id).first {
            if run.chatID != nil, run.state == .running || run.result == .needsYou {
                openRunChat(run)
            } else {
                navigate(to: .automation(run.automationID))
            }
            return
        }
        open(product: id)
    }

    func automationRunsWantingHim(inProduct productID: UUID) -> [AutomationRun] {
        let mine = Set(automations.automations(for: productID).map(\.id))
        return automationRunsWantingHim.filter { mine.contains($0.automationID) }
    }

    /// What the product row and the menu bar show for its automations.
    func automationState(forProductID id: UUID) -> WorkState? {
        let mine = Set(automations.automations(for: id).map(\.id))
        let runs = automations.runs.filter { mine.contains($0.automationID) }
        var states: [WorkState] = []
        for run in runs {
            if run.state == .awaitingApproval { states.append(.needsAnswer) }
            if run.state == .running, let chatID = run.chatID {
                states.append(directPhase(for: chatID).wantsAttention ? .needsAnswer : .running)
            }
            if run.state == .finished, run.result == .needsYou, runWantsHim(run) { states.append(.needsAnswer) }
            if run.state == .finished, run.result == .changes, run.handoff == .waiting { states.append(.reportReady) }
            if run.isRealFailure, !run.seen { states.append(.failed) }
        }
        guard !states.isEmpty else { return nil }
        let order: [WorkState] = [.needsAnswer, .failed, .reportReady, .running]
        return order.first { states.contains($0) }
    }

    /// The runs a product's automations have made, newest first.
    func lastRun(of automationID: UUID) -> AutomationRun? {
        automations.runs(for: automationID).first
    }

    func nextRuns(of automation: Automation, count: Int = 3, now: Date = Date()) -> [Date] {
        guard automation.enabled, let schedule = automation.trigger.schedule else { return [] }
        return AutomationClock.next(schedule, after: max(now, automation.evaluatedThrough ?? now), count: count)
    }

    // MARK: - Keeping the Mac up for it

    /// A scheduled run due in the next twelve hours keeps an idle Mac on mains power from falling
    /// asleep before it. Taken while the Mac is still awake — an assertion taken at the due time
    /// could not stop the sleep that came first.
    var automationDueSoon: Bool {
        let horizon = Date().addingTimeInterval(12 * 3600)
        if automations.runs.contains(where: { $0.state == .awaitingAway || $0.state == .preparing || $0.state == .running }) {
            return true
        }
        return automations.automations.contains { automation in
            guard automation.enabled, automation.trigger.schedule != nil else { return false }
            return nextRuns(of: automation, count: 1).first.map { $0 <= horizon } ?? false
        }
    }

    // MARK: - What the run is told

    /// The part of a conversation's context that a copy adds: the rules of working in one, and for
    /// an automation run, the run's own section — why it started, what earlier runs found, and
    /// whatever the event carried, fenced off as data.
    func copyContext(chatID: UUID, copy: WorkCopy?) -> String {
        guard let copy else { return "" }
        let cache = WorkCopies.buildCache(for: copy).path
        guard let runID = conversations.chat(id: chatID)?.automationRunID,
              let run = automations.run(id: runID),
              let automation = automations.automation(id: run.automationID) else {
            return "\n\n" + AutomationBrief.copyRules(copy, buildCache: cache, automation: false)
        }
        let past = automations.runs(for: automation.id).filter { $0.id != run.id && $0.state.isTerminal }
        let section = AutomationBrief.contextSection(AutomationBrief.Context(
            automationName: automation.name, briefRevision: run.briefRevision,
            reasonText: AutomationBrief.reasonLine(run.reason, when: run.createdAt), copy: copy,
            buildCache: cache, pastRuns: past, items: run.items, untrustedPayload: true,
            checkOnly: run.checkOnly == true, keptFolder: homeAutomation(of: copy) != nil))
        return "\n\n" + section
    }

    // MARK: - Telling him

    func notify(title: String, body: String) {
        // The test host is the real app with nobody in front of it.
        guard NSClassFromString("XCTestCase") == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

/// Why a conversation that should work in a copy was not sent anywhere.
nonisolated struct ChatCopyRefusal: Error, Equatable, Sendable {
    var message: String
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
