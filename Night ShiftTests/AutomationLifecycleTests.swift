import XCTest
import SwiftUI
import AppKit
@testable import Bulava

/// An automation from the app's side: when a run is recorded, where it works, what it is told,
/// and what becomes of its copy. The engine is not started — the brief is caught where it would
/// have been sent — but the copies are real.
nonisolated final class AutomationLifecycleTests: XCTestCase {

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-auto-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", scratch.appendingPathComponent("state").path, 1)
        setenv("BULAVA_COPIES_DIR", scratch.appendingPathComponent("copies").path, 1)
        setenv("GIT_AUTHOR_NAME", "Test", 1); setenv("GIT_AUTHOR_EMAIL", "t@example.com", 1)
        setenv("GIT_COMMITTER_NAME", "Test", 1); setenv("GIT_COMMITTER_EMAIL", "t@example.com", 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        unsetenv("BULAVA_COPIES_DIR")
        super.tearDown()
    }

    struct Sent { var message: String; var chatID: UUID; var entryID: UUID }

    @MainActor private final class Box { var sent: [Sent] = []; var readied: [WorkCopy] = [] }

    @MainActor private func world(projectPath: String? = nil) async -> (AppModel, Box, Project, Product) {
        let m = AppModel()
        let box = Box()
        m.sendAutomationBrief = { message, _, chatID, entryID in
            box.sent.append(Sent(message: message, chatID: chatID, entryID: entryID))
        }
        m.readyCopyOverride = { copy in box.readied.append(copy) }
        let path: String
        if let projectPath { path = projectPath } else { path = await repo() }
        let project = m.projects.add(path: path)
        let product = m.products.add(name: "Narada", resources: [ProductResource(name: "App", projectID: project.id)])
        return (m, box, project, product)
    }

    @MainActor private func repo() async -> String {
        let dir = scratch.appendingPathComponent("Narada App", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = await Shell.run("git init -q -b main . && printf 'one\\n' > a.txt && git add a.txt && git commit -qm init",
                                cwd: dir)
        XCTAssertTrue(r.ok, r.combined)
        return dir.path
    }

    @MainActor private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    // MARK: When

    @MainActor
    func testMissedNightsAreRecordedAndTheSameNightIsNeverTakenTwice() async {
        let (m, box, _, product) = await world(projectPath: scratch.appendingPathComponent("gone").path)
        let project = m.projects.projects.first!
        var a = Automation(productID: product.id, projectID: project.id, name: "Models",
                           brief: "Check for new models.",
                           trigger: .schedule(AutomationSchedule(cadence: .daily, hour: 3, minute: 0)))
        let now = Date()
        a.evaluatedThrough = now.addingTimeInterval(-3 * 86_400 - 60)
        m.automations.add(a)

        m.automationsTick(now: now)
        let runs = m.automations.runs(for: a.id)
        XCTAssertEqual(runs.count, 3, "two nights missed, one due")
        XCTAssertTrue(runs.allSatisfy { $0.state == .skipped })
        XCTAssertEqual(runs.filter { $0.note?.contains("not there") == true }.count, 1,
                       "the due night says why it could not start: the folder is gone")
        XCTAssertEqual(Set(runs.map(\.occurrence)).count, 3)

        m.automationsTick(now: now.addingTimeInterval(5))
        XCTAssertEqual(m.automations.runs(for: a.id).count, 3, "nothing is recorded twice")
        XCTAssertTrue(box.sent.isEmpty)
    }

    // MARK: Where, and what it is told

    @MainActor
    func testRunNowGivesTheRunItsOwnCopyAndAChatOutOfHisList() async {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Моделі для Наради",
                           brief: "Check whether a better local model came out.", trigger: .manual)
        m.automations.add(a)

        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }

        guard let run = m.automations.runs(for: a.id).first, let sent = box.sent.first else {
            return XCTFail("the brief was never sent")
        }
        XCTAssertEqual(run.state, .running)
        XCTAssertEqual(sent.chatID, run.chatID)
        XCTAssertEqual(sent.entryID, run.entryID, "sent under the id the run recorded, so a second send is the first")
        XCTAssertTrue(sent.message.contains("Check whether a better local model came out."))

        let copy = m.automations.copy(id: run.workspaceID!)!
        XCTAssertEqual(copy.state, .active)
        XCTAssertNotEqual(Slug.canonicalPath(copy.path), Slug.canonicalPath(project.path))
        XCTAssertEqual(copy.checkoutRoot, WorkCopies.homeRoot(sourceRoot: copy.sourceRoot, automationID: a.id),
                       "the automation's own folder, the same one every run")
        let ours = await WorkCopies.isOurs(copy)
        XCTAssertTrue(ours)
        XCTAssertTrue(copy.branch.hasPrefix("bulava/modeli-dla-naradi/"))
        XCTAssertEqual(box.readied.map(\.id), [copy.id], "trust and MCP answers are given to the copy before it runs")

        let chat = m.conversations.chat(id: run.chatID!)!
        XCTAssertTrue(chat.isAutomationRun)
        XCTAssertEqual(chat.workCopyID, copy.id)
        XCTAssertFalse(m.conversations.chats(for: product.id).contains { $0.id == chat.id },
                       "a run is not one of his conversations")
        XCTAssertTrue(m.conversations.chats(for: product.id, includingAutomationRuns: true).contains { $0.id == chat.id },
                      "but anything asking what is waiting still finds it")
        XCTAssertNotEqual(m.conversations.currentChatID(for: product.id), chat.id,
                          "a run starting does not take the place of the chat he has open")

        let execution = await m.executionProject(for: chat.id, primary: project)
        XCTAssertEqual(try? execution.get().path, copy.path, "the worker runs in the copy")

        let context = m.copyContext(chatID: chat.id, copy: copy)
        XCTAssertTrue(context.contains(copy.path))
        XCTAssertTrue(context.contains("НЕ изменяй"), "the run is told his folder is not to be touched")
    }

    @MainActor
    func testAStartRefusedBecauseTheLastResultIsWaitingKeepsWhatTheWatchFound() async {
        let (m, _, project, product) = await world()
        var a = Automation(productID: product.id, projectID: project.id, name: "Parity",
                           brief: "Bring the app up to date.",
                           trigger: .watch(AutomationWatch(source: .feed(url: "https://example.com/f"), everyMinutes: 60)))
        a.watch?.baselined = true
        a.watch?.pending = [WatchItem(id: "x", title: "new thing")]
        a.watch?.pendingSince = Date()
        m.automations.add(a)
        var waiting = AutomationRun(automationID: a.id, occurrence: "old", reason: .manual, state: .finished, briefRevision: 1)
        waiting.result = .changes
        waiting.handoff = .waiting
        m.automations.record(waiting)

        m.runAutomationNow(a.id)
        XCTAssertEqual(m.automations.automation(id: a.id)?.watch?.pending.map(\.id), ["x"],
                       "a refused start takes nothing off the watch")
        XCTAssertEqual(m.automations.runs(for: a.id).count, 1)
        XCTAssertNotNil(m.toast, "and says why")
    }

    @MainActor
    func testStoppingARunWhilePreparingMeansItNeverStarts() async {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Stop me",
                           brief: "Anything.", trigger: .manual)
        m.automations.add(a)
        m.readyCopyOverride = { copy in
            box.readied.append(copy)
            if case .run(let runID) = copy.owner { m.stopRun(runID) }
        }

        m.runAutomationNow(a.id)
        await waitUntil { m.automations.runs(for: a.id).first?.state.isTerminal == true && m.automationPreparing.isEmpty }

        let run = m.automations.runs(for: a.id).first!
        XCTAssertEqual(run.state, .failed)
        XCTAssertTrue(box.sent.isEmpty, "nothing was sent after he stopped it")
        let copy = m.automations.copy(id: run.workspaceID!)!
        XCTAssertEqual(copy.state, .removed, "and its unused copy is given back")
        let parked = await WorkCopies.isParked(copy.checkoutRoot, automationID: a.id, sourceRoot: copy.sourceRoot)
        XCTAssertTrue(parked, "parked for the next run, not left on its branch")
        let branch = await WorkCopies.refExists("refs/heads/\(copy.branch)", in: project.path)
        XCTAssertFalse(branch)
    }

    @MainActor
    func testAnInterruptedPreparationResumesTheSameCopyAndChat() async {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Resume",
                           brief: "Anything.", trigger: .manual)
        m.automations.add(a)
        // As a quit left it: the run named its copy and chat, the copy was made and written down.
        var run = AutomationRun(automationID: a.id, occurrence: "manual:1", reason: .manual,
                                state: .preparing, briefRevision: 1)
        let copyID = UUID(), chatID = UUID()
        run.workspaceID = copyID
        run.chatID = chatID
        m.automations.record(run)
        guard case .success(let made) = await WorkCopies.make(sourcePath: project.path, projectID: project.id,
                                                              baseRef: nil, branch: "bulava/resume/1",
                                                              owner: .run(run.id), id: copyID) else {
            return XCTFail("no copy")
        }
        m.automations.addCopy(made)

        await m.prepareAndStart(run.id)
        let after = m.automations.run(id: run.id)!
        XCTAssertEqual(after.workspaceID, copyID, "the copy it already had, not a second one")
        XCTAssertEqual(after.chatID, chatID)
        XCTAssertEqual(box.sent.map(\.chatID), [chatID])
        let copies = try? FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent("copies/copies").path)
        XCTAssertEqual(copies?.count, 1)
    }

    @MainActor
    func testAChatThatAskedForACopyGetsOneEvenWhenTwoMessagesRace() async {
        let (m, _, project, product) = await world()
        let chat = m.conversations.newChat(for: product.id)
        m.conversations.setWantsCopy(true, for: chat.id)

        async let first = m.executionProject(for: chat.id, primary: project)
        async let second = m.executionProject(for: chat.id, primary: project)
        let (a, b) = await (first, second)
        let pathA = try? a.get().path, pathB = try? b.get().path
        XCTAssertNotNil(pathA)
        XCTAssertEqual(pathA, pathB, "one copy for one chat")
        XCTAssertNotEqual(pathA.map(Slug.canonicalPath), Slug.canonicalPath(project.path), "never his folder")
        XCTAssertEqual(m.automations.copies.filter { $0.state == .active }.count, 1)
        XCTAssertEqual(m.conversations.chat(id: chat.id)?.session?.projectPath, pathA,
                       "its session starts in the copy, not in his folder")
    }

    @MainActor
    func testARunWhoseCopyIsGoneIsRefusedRatherThanSentHome() async {
        let (m, _, project, product) = await world()
        let gone = WorkCopy(path: "/nowhere", checkoutRoot: "/nowhere", sourcePath: project.path,
                            sourceRoot: project.path, projectID: project.id, branch: "b", baseRef: "main",
                            baseSHA: "x", owner: .run(UUID()), state: .removed)
        m.automations.addCopy(gone)
        let chat = m.conversations.newAutomationChat(id: UUID(), for: product.id, runID: UUID(), copyID: gone.id, title: "t")
        let result = await m.executionProject(for: chat.id, primary: project)
        guard case .failure = result else { return XCTFail("a run without its copy must not run in his folder") }
    }

    // MARK: Handing over, and cleaning up

    @MainActor
    func testMergingARunPutsItsWorkOnHisBranchAndTakesTheCopyAway() async {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Docs",
                           brief: "Fix the docs.", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let runID = m.automations.runs(for: a.id).first!.id
        let copy = m.automations.copy(id: m.automations.run(id: runID)!.workspaceID!)!
        try? "two\n".write(toFile: copy.path + "/a.txt", atomically: true, encoding: .utf8)
        m.automations.updateRun(runID) { $0.state = .finished; $0.result = .changes; $0.handoff = .waiting }

        let problem = await m.mergeRun(runID)
        XCTAssertNil(problem)
        XCTAssertEqual(try? String(contentsOfFile: project.path + "/a.txt", encoding: .utf8), "two\n")
        XCTAssertEqual(m.automations.run(id: runID)?.handoff, .merged)
        XCTAssertEqual(m.automations.copy(id: copy.id)?.state, .removed)
        let parked = await WorkCopies.isParked(copy.checkoutRoot, automationID: a.id, sourceRoot: copy.sourceRoot)
        XCTAssertTrue(parked, "the automation's folder stays for the next run, off any branch")
        let branch = await WorkCopies.refExists("refs/heads/\(copy.branch)", in: project.path)
        XCTAssertFalse(branch, "the merged branch is gone")
    }

    @MainActor
    func testTheSweepTakesEmptyFinishedCopiesAndKeepsWorkWaitingForHim() async {
        let (m, _, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Sweep",
                           brief: "x", trigger: .manual)
        m.automations.add(a)

        func copy(for run: AutomationRun, branch: String) async -> WorkCopy {
            guard case .success(let c) = await WorkCopies.make(sourcePath: project.path, projectID: project.id,
                                                               baseRef: nil, branch: branch, owner: .run(run.id)) else {
                fatalError("no copy")
            }
            m.automations.addCopy(c)
            m.automations.updateRun(run.id) { $0.workspaceID = c.id }
            return c
        }
        var quiet = AutomationRun(automationID: a.id, occurrence: "q", reason: .manual, state: .finished, briefRevision: 1)
        quiet.result = .noChange
        m.automations.record(quiet)
        let quietCopy = await copy(for: quiet, branch: "bulava/quiet")

        var busy = AutomationRun(automationID: a.id, occurrence: "w", reason: .manual, state: .finished, briefRevision: 1)
        busy.result = .changes
        busy.handoff = .waiting
        m.automations.record(busy)
        let waitingCopy = await copy(for: busy, branch: "bulava/waiting")
        try? "work\n".write(toFile: waitingCopy.path + "/b.txt", atomically: true, encoding: .utf8)

        await m.sweepCopies()
        XCTAssertFalse(FileManager.default.fileExists(atPath: quietCopy.checkoutRoot), "a quiet run's copy goes")
        XCTAssertEqual(m.automations.copy(id: quietCopy.id)?.state, .removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: waitingCopy.path + "/b.txt"), "work waiting for him stays")
    }

    // MARK: Attention

    @MainActor
    func testWhatWaitsForHimIsCountedAndAQuietRunIsNot() async {
        let (m, _, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "A", brief: "x", trigger: .manual)
        m.automations.add(a)
        var quiet = AutomationRun(automationID: a.id, occurrence: "1", reason: .manual, state: .finished, briefRevision: 1)
        quiet.result = .noChange
        m.automations.record(quiet)
        XCTAssertTrue(m.automationRunsWantingHim.isEmpty, "a quiet week makes no noise")
        XCTAssertNil(m.automationState(forProductID: product.id))

        var failed = AutomationRun(automationID: a.id, occurrence: "2", reason: .manual, state: .failed, briefRevision: 1)
        failed.note = "boom"
        m.automations.record(failed)
        XCTAssertEqual(m.automationRunsWantingHim.map(\.id), [failed.id], "a failure is never invisible")
        XCTAssertEqual(m.automationState(forProductID: product.id), .failed)
        m.markRunSeen(failed.id)
        XCTAssertTrue(m.automationRunsWantingHim.isEmpty)
    }

    @MainActor
    func testAQuestionStillWaitsAfterHeOpensItUntilHeAnswersOrStopsIt() async {
        let (m, _, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Q", brief: "x", trigger: .manual)
        m.automations.add(a)
        let chat = m.conversations.newAutomationChat(id: UUID(), for: product.id, runID: UUID(), copyID: UUID(), title: "q")
        var run = AutomationRun(automationID: a.id, occurrence: "q", reason: .manual, state: .finished, briefRevision: 1)
        run.result = .needsYou
        run.chatID = chat.id
        m.automations.record(run)
        m.openRunChat(m.automations.run(id: run.id)!)
        XCTAssertEqual(m.automationRunsWantingHim.map(\.id), [run.id], "opening it is not answering it")
        XCTAssertEqual(m.automationState(forProductID: product.id), .needsAnswer)
        m.stopRun(run.id)
        XCTAssertTrue(m.automationRunsWantingHim.isEmpty, "stopping it is")
    }

    @MainActor
    func testMergeAndDiscardRefuseWhileTheConversationIsWorkingAndARefusalChangesNothing() async {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Busy", brief: "x", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let runID = m.automations.runs(for: a.id).first!.id
        let copyID = m.automations.run(id: runID)!.workspaceID!
        let copy = m.automations.copy(id: copyID)!
        try? "two\n".write(toFile: copy.path + "/a.txt", atomically: true, encoding: .utf8)
        m.automations.updateRun(runID) { $0.state = .finished; $0.result = .changes; $0.handoff = .waiting }

        let chatID = m.automations.run(id: runID)!.chatID!
        m.sendingChatIDs.insert(chatID)
        let refusedMerge = await m.mergeRun(runID)
        XCTAssertNotNil(refusedMerge, "a follow-up on its way: nothing is merged under it")
        m.sendingChatIDs.remove(chatID)

        m.copyOperations.insert(copyID)
        let refusedDiscard = await m.discardRun(runID)
        XCTAssertNotNil(refusedDiscard)
        XCTAssertEqual(m.automations.run(id: runID)?.handoff, .waiting, "a refused discard leaves the run as it was")
        XCTAssertEqual(m.automations.copy(id: copyID)?.state, .active)
        m.copyOperations.remove(copyID)
        await m.sweepCopies()
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path + "/a.txt"), "and no sweep takes the work")
        XCTAssertEqual(try? String(contentsOfFile: project.path + "/a.txt", encoding: .utf8), "one\n")
    }

    @MainActor
    func testAChatSetToWorkInACopyIsStillSetAfterARelaunch() async {
        let dir = scratch.appendingPathComponent("store", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entries = dir.appendingPathComponent("conversations.json"), chats = dir.appendingPathComponent("chats.json")
        let first = ConversationStore(fileURL: entries, chatsURL: chats)
        let product = UUID()
        let chat = first.newChat(for: product)
        first.setWantsCopy(true, for: chat.id)
        CoalescedWrites.shared.flushAll()

        let relaunched = ConversationStore(fileURL: entries, chatsURL: chats)
        XCTAssertEqual(relaunched.chat(id: chat.id)?.wantsCopy, true, "his choice is not pruned as an empty chat")
    }

    @MainActor
    func testAnApprovedRunRunsWhatItWasRecordedWithNotALaterEdit() async {
        let (m, box, project, product) = await world()
        var a = Automation(productID: product.id, projectID: project.id, name: "Ask first",
                           brief: "The brief he approved.", trigger: .manual, confirmFirst: true)
        a.confirmFirst = true
        m.automations.add(a)
        m.beginRun(m.automations.automation(id: a.id)!, occurrence: "slot:1", reason: .scheduled(Date()),
                   items: [], now: Date())
        guard let waiting = m.automations.runs(for: a.id).first else { return XCTFail("not recorded") }
        XCTAssertEqual(waiting.state, .awaitingApproval)

        var edited = m.automations.automation(id: a.id)!
        edited.brief = "A brief written afterwards."
        edited.baseBranch = "release"
        m.editAutomation(a.id, to: edited)

        m.approveRun(waiting.id)
        await waitUntil { !box.sent.isEmpty }
        XCTAssertTrue(box.sent.first?.message.contains("The brief he approved.") == true,
                      "it runs the brief it was recorded with")
        XCTAssertFalse(box.sent.first?.message.contains("afterwards") == true)
        XCTAssertEqual(m.automations.run(id: waiting.id)?.briefRevision, 1, "and says which revision that was")
        let copy = m.automations.copy(id: m.automations.run(id: waiting.id)!.workspaceID!)!
        XCTAssertEqual(copy.baseRef, "main", "from the branch it was recorded with, not the edited one")
    }

    @MainActor
    func testAnOpenedQuestionStillHoldsTheNextRunBack() async {
        let (m, _, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Held", brief: "x", trigger: .manual)
        m.automations.add(a)
        var asked = AutomationRun(automationID: a.id, occurrence: "q", reason: .manual, state: .finished, briefRevision: 1)
        asked.result = .needsYou
        asked.seen = true
        m.automations.record(asked)
        XCTAssertNotNil(m.reasonNotToStart(m.automations.automation(id: a.id)!, now: Date()),
                        "a question he looked at but did not answer still waits")
    }

    @MainActor
    func testAStopAndOneFailureDoNotSwitchItOff() async {
        let (m, _, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Stop", brief: "x", trigger: .manual)
        m.automations.add(a)
        let first = AutomationRun(automationID: a.id, occurrence: "1", reason: .manual, state: .running, briefRevision: 1,
                                  createdAt: Date().addingTimeInterval(-60))
        m.automations.record(first)
        m.stopRun(first.id)
        XCTAssertEqual(AutomationPresentation.look(m.automations.run(id: first.id)!, phase: nil).word,
                       String(localized: "Stopped by you"))
        let second = AutomationRun(automationID: a.id, occurrence: "2", reason: .manual, state: .running, briefRevision: 1)
        m.automations.record(second)
        m.failRun(second.id, "boom")
        XCTAssertTrue(m.automations.automation(id: a.id)!.enabled, "one real failure is not two")
    }

    @MainActor
    func testAReportCanBeOpenedAfterItsCopyIsGone() async {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Report", brief: "x", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let runID = m.automations.runs(for: a.id).first!.id
        let copy = m.automations.copy(id: m.automations.run(id: runID)!.workspaceID!)!
        let shell = await Shell.run("printf 'artifacts/\\n' >> .git/info/exclude", cwd: URL(fileURLWithPath: project.path))
        XCTAssertTrue(shell.ok)
        try? FileManager.default.createDirectory(atPath: copy.path + "/artifacts", withIntermediateDirectories: true)
        try? "# Findings".write(toFile: copy.path + "/artifacts/report.md", atomically: true, encoding: .utf8)
        m.automations.updateRun(runID) { $0.state = .finished; $0.result = .report }
        XCTAssertNotNil(m.reportFolder(for: m.automations.run(id: runID)!), "while the copy is there")

        await m.sweepCopies()
        XCTAssertEqual(m.automations.copy(id: copy.id)?.state, .removed, "the quiet run let its folder go")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path + "/artifacts/report.md"),
                       "and its report left the folder with it, so the next run does not find it there")
        let folder = m.reportFolder(for: m.automations.run(id: runID)!)
        XCTAssertNotNil(folder, "and the report is still reachable from the run")
        let found = FileManager.default.enumerator(atPath: folder!.path)?.compactMap { $0 as? String } ?? []
        XCTAssertTrue(found.contains { $0.hasSuffix("report.md") })
        try? FileManager.default.removeItem(at: folder!)
    }

    @MainActor
    func testARunThatEndedFailedIsAFailureHeSees() async {
        let (m, _, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "F", brief: "x", trigger: .manual)
        m.automations.add(a)
        var run = AutomationRun(automationID: a.id, occurrence: "f", reason: .manual, state: .finished, briefRevision: 1)
        run.result = .failed
        m.automations.record(run)
        XCTAssertEqual(m.automationRunsWantingHim.map(\.id), [run.id])
        XCTAssertEqual(m.automationState(forProductID: product.id), .failed)
    }

    @MainActor
    func testNothingIsSentIntoACopyWhileItIsBeingMergedOrRemoved() async {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Locked", brief: "x", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let run = m.automations.runs(for: a.id).first!
        m.copyOperations.insert(run.workspaceID!)
        let result = await m.executionProject(for: run.chatID!, primary: project)
        guard case .failure = result else { return XCTFail("a send must not start in a copy being taken away") }
        m.copyOperations.remove(run.workspaceID!)
    }

    @MainActor
    func testAHalfMadeCopyFromBeforeAQuitIsTakenAwayByItsMarker() async {
        let (m, _, project, _) = await world()
        let id = UUID()
        let root = WorkCopies.plannedCheckoutRoot(sourceRoot: project.path, id: id)
        let made = await Shell.run("git worktree add -q -b bulava/half/1 \"$1\" && printf '%s\\n' \"$2\" > \"$(git -C \"$1\" rev-parse --absolute-git-dir)/bulava-copy\"",
                                   args: [root, id.uuidString], cwd: URL(fileURLWithPath: project.path))
        XCTAssertTrue(made.ok, made.combined)
        let placeholder = WorkCopy(id: id, path: root, checkoutRoot: root, sourcePath: project.path,
                                   sourceRoot: project.path, projectID: project.id, branch: "", baseRef: "",
                                   baseSHA: "", owner: .run(UUID()), state: .preparing)
        _ = m
        let gone = await WorkCopies.takeAwayHalfMade(placeholder)
        XCTAssertTrue(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root))
        let branch = await WorkCopies.refExists("refs/heads/bulava/half/1", in: project.path)
        XCTAssertFalse(branch)
    }

    @MainActor
    func testTwoFailuresInARowSwitchItOffWithTheReason() async {
        let (m, _, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Flaky", brief: "x", trigger: .manual)
        m.automations.add(a)
        for n in 1...2 {
            let run = AutomationRun(automationID: a.id, occurrence: "\(n)", reason: .manual, state: .running,
                                    briefRevision: 1, createdAt: Date().addingTimeInterval(Double(n)))
            m.automations.record(run)
            m.failRun(run.id, "failed \(n)")
        }
        let after = m.automations.automation(id: a.id)!
        XCTAssertFalse(after.enabled)
        XCTAssertNotNil(after.pausedReason)
    }

    // MARK: After an older build

    /// 4 Oct: an installed 1.10 took over from a Debug build mid-run and wrote `chats.json` back
    /// without the fields it did not know. The run's chat became an ordinary chat bound to his
    /// folder on his branch, and the next message he typed into it went there.
    @MainActor
    func testARunChatAnOlderBuildUnlinkedIsLinkedBackToItsRunAndCopy() async throws {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Синхронізація з вебом",
                           brief: "Port what production has.", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        let chatID = try XCTUnwrap(run.chatID)
        let copy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(run.workspaceID)))
        // The brief, as it stands in the real chat — caught above, so put there by hand.
        m.conversations.append(ConversationEntry(productID: product.id, chatID: chatID, kind: .user,
                                                 text: "Port what production has."))
        CoalescedWrites.shared.flushAll()

        // What the older build left: none of the three fields, and the session in his folder.
        let file = AppSupport.file("chats.json")
        var chats = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let i = try XCTUnwrap(chats.firstIndex { $0["id"] as? String == chatID.uuidString })
        chats[i]["automationRunID"] = nil
        chats[i]["workCopyID"] = nil
        chats[i]["wantsCopy"] = nil
        chats[i]["session"] = ["primaryProjectID": project.id.uuidString, "projectPath": project.path,
                               "claudeSessionID": "964e9367-e3c5-4ce6-aeda-b70a7614d342",
                               "activeRunID": "A8CBEE76-ECF7-4158-A6A6-CB3892E768B9",
                               "branch": "feat/firebase-analytics", "startedAt": "2026-10-04T12:05:34Z",
                               "outcomeAt": "2026-10-04T12:13:52Z", "reportPaths": [String]()]
        try JSONSerialization.data(withJSONObject: chats).write(to: file)

        let relaunched = AppModel()
        relaunched.sendAutomationBrief = { _, _, _, _ in }
        relaunched.readyCopyOverride = { _ in }
        let unlinked = try XCTUnwrap(relaunched.conversations.chat(id: chatID))
        XCTAssertFalse(unlinked.isAutomationRun, "the older build's file is what this launch reads")

        relaunched.automationsTick()
        let chat = try XCTUnwrap(relaunched.conversations.chat(id: chatID))
        XCTAssertEqual(chat.automationRunID, run.id)
        XCTAssertEqual(chat.workCopyID, copy.id)
        XCTAssertTrue(chat.wantsCopy)
        XCTAssertEqual(chat.session?.projectPath, copy.path, "its session lives in the copy again")
        XCTAssertEqual(chat.session?.branch, copy.branch, "on the copy's branch, not his")
        XCTAssertNil(chat.session?.activeRunID, "the run in his folder is not this conversation's")
        XCTAssertEqual(chat.session?.claudeSessionID, "964e9367-e3c5-4ce6-aeda-b70a7614d342",
                       "the conversation itself carries on")
        XCTAssertFalse(relaunched.conversations.chats(for: product.id).contains { $0.id == chatID },
                       "out of his list of conversations again")
        let execution = await relaunched.executionProject(for: chatID, primary: project)
        XCTAssertEqual(try? execution.get().path, copy.path, "the next message runs in the copy")

        relaunched.automationsTick()
        XCTAssertEqual(relaunched.conversations.chat(id: chatID), chat, "a chat that agrees is left alone")
        XCTAssertNil(relaunched.reboundToCopy(chat.session, copy: copy),
                     "a binding already in the copy is not moved again — the send goes through as it is")
        let stray = ChatSessionBinding(primaryProjectID: project.id, projectPath: project.path,
                                       claudeSessionID: "s", activeRunID: "elsewhere", branch: "main")
        XCTAssertEqual(relaunched.reboundToCopy(stray, copy: copy)?.projectPath, copy.path,
                       "one left in his folder, with nothing running there, is moved before anything is sent")
    }

    /// A deleted automation's chats are ordinary on purpose; nothing links them back.
    @MainActor
    func testADeletedAutomationsChatStaysOrdinary() async throws {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Gone", brief: "x", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        m.automations.updateRun(run.id) { $0.state = .finished; $0.result = .noChange }
        XCTAssertNil(m.deleteAutomation(a.id))

        m.automationsTick()
        let chat = try XCTUnwrap(m.conversations.chat(id: try XCTUnwrap(run.chatID)))
        XCTAssertNil(chat.automationRunID)
        XCTAssertTrue(chat.archived)
    }

    /// An Android app's automation, 4 Oct: the run left ten screenshots and no words, and "Open report" opened the
    /// folder. A written report is a page or a document; screenshots are evidence.
    func testScreenshotsAreEvidenceAndAPageOrDocumentIsAReport() throws {
        let fm = FileManager.default
        let artifacts = scratch.appendingPathComponent("artifacts-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: artifacts.appendingPathComponent("web-sync-2026-10-04"), withIntermediateDirectories: true)
        for n in 1...3 {
            fm.createFile(atPath: artifacts.appendingPathComponent("web-sync-2026-10-04/0\(n).png").path, contents: Data([0]))
        }
        XCTAssertNil(AppModel.newestWrittenReport(in: artifacts), "a folder of screenshots is not a report")

        fm.createFile(atPath: artifacts.appendingPathComponent("findings.md").path, contents: Data("# Findings".utf8))
        XCTAssertEqual(AppModel.newestWrittenReport(in: artifacts)?.lastPathComponent, "findings.md",
                       "a document written at the top is one")

        let page = artifacts.appendingPathComponent("2026-10-04-2140-sync/index.html")
        try fm.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: page.path, contents: Data("<html></html>".utf8))
        XCTAssertEqual(AppModel.newestWrittenReport(in: artifacts)?.path, page.path,
                       "the report page the artifact command builds is the report")
        try? fm.removeItem(at: artifacts)
    }

    /// A run that did work asks for its written report once, when the work ends — and a finished
    /// run is not asked again.
    @MainActor
    func testARunThatDidWorkAsksForItsReportOnce() async throws {
        let (m, _, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Sync", brief: "x", trigger: .manual)
        m.automations.add(a)
        let chat = m.conversations.newAutomationChat(id: UUID(), for: product.id, runID: UUID(), copyID: UUID(), title: "t")
        var run = AutomationRun(automationID: a.id, occurrence: "w", reason: .manual, state: .running, briefRevision: 1)
        run.chatID = chat.id
        m.automations.record(run)
        m.settle(m.automations.run(id: run.id)!, result: .changes, summary: "Перенесено дві функції.", now: Date())
        XCTAssertEqual(m.automations.run(id: run.id)?.reportAsked, true)

        var quiet = AutomationRun(automationID: a.id, occurrence: "q", reason: .manual, state: .running, briefRevision: 1)
        quiet.chatID = chat.id
        m.automations.record(quiet)
        m.settle(m.automations.run(id: quiet.id)!, result: .noChange, summary: "Нічого нового.", now: Date())
        XCTAssertNil(m.automations.run(id: quiet.id)?.reportAsked, "a quiet week needs no report")
        XCTAssertTrue(AppModel.wantsWrittenReport(.report) && AppModel.wantsWrittenReport(.unverified))
        XCTAssertFalse(AppModel.wantsWrittenReport(.needsYou) || AppModel.wantsWrittenReport(.failed))
    }

    /// The copy goes after a merge and its `artifacts/` is carried to `copies-kept`; the report the
    /// conversation recorded is found there, on the Mac and on the phone.
    @MainActor
    func testARecordedReportFollowsItsCopyWhenTheCopyGoes() async throws {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Carry", brief: "x", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        let copy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(run.workspaceID)))
        let shell = await Shell.run("printf 'artifacts/\\n' >> .git/info/exclude", cwd: URL(fileURLWithPath: project.path))
        XCTAssertTrue(shell.ok)
        let page = URL(fileURLWithPath: copy.path).appendingPathComponent("artifacts/2026-10-04-2140-sync/index.html")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<html>report</html>".write(to: page, atomically: true, encoding: .utf8)
        let chatID = try XCTUnwrap(run.chatID)
        m.conversations.bindSession(ChatSessionBinding(primaryProjectID: project.id, projectPath: copy.path), to: chatID)
        m.conversations.addReport(page.path, to: chatID)
        m.automations.updateRun(run.id) { $0.state = .finished; $0.result = .report }
        XCTAssertEqual(m.reportPage(for: m.automations.run(id: run.id)!)?.lastPathComponent, "index.html")

        await m.sweepCopies()
        XCTAssertEqual(m.automations.copy(id: copy.id)?.state, .removed, "the quiet run let its folder go")
        let after = try XCTUnwrap(m.reportPage(for: m.automations.run(id: run.id)!), "the report is still reachable")
        XCTAssertTrue(after.path.hasPrefix(WorkCopies.keptArtifacts(for: copy).path), after.path)
        XCTAssertEqual(try? String(contentsOf: after, encoding: .utf8), "<html>report</html>")
        XCTAssertEqual(m.conversations.chat(id: chatID)?.session?.reportPaths.last, after.path,
                       "the phone opens the recorded path, so it moved too")
        try? FileManager.default.removeItem(at: WorkCopies.keptArtifacts(for: copy).deletingLastPathComponent())
    }

    // MARK: The automation's own folder

    /// The second run works where the first did: from the start branch as it is now, with what the
    /// first one built still there and its report carried away.
    @MainActor
    func testTheNextRunTakesUpTheSameFolderFromAFreshStart() async throws {
        let (m, box, project, product) = await world()
        let excluded = await Shell.run("printf 'build/\\nartifacts/\\nlocal.properties\\n' >> .git/info/exclude",
                                       cwd: URL(fileURLWithPath: project.path))
        XCTAssertTrue(excluded.ok)
        let a = Automation(productID: product.id, projectID: project.id, name: "Weekly sync", brief: "x", trigger: .manual)
        m.automations.add(a)

        m.runAutomationNow(a.id)
        await waitUntil { box.sent.count == 1 }
        let first = try XCTUnwrap(m.automations.runs(for: a.id).first)
        let firstCopy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(first.workspaceID)))
        let fm = FileManager.default
        try fm.createDirectory(atPath: firstCopy.path + "/build", withIntermediateDirectories: true)
        try "binary".write(toFile: firstCopy.path + "/build/app.bin", atomically: true, encoding: .utf8)
        try "sdk.dir=/x".write(toFile: firstCopy.path + "/local.properties", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: firstCopy.path + "/artifacts", withIntermediateDirectories: true)
        try "# Week 1".write(toFile: firstCopy.path + "/artifacts/report.md", atomically: true, encoding: .utf8)
        m.automations.updateRun(first.id) { $0.state = .finished; $0.result = .noChange }
        await m.sweepCopies()
        XCTAssertEqual(m.automations.copy(id: firstCopy.id)?.state, .removed)

        let firstBranch = await WorkCopies.refExists("refs/heads/\(firstCopy.branch)", in: project.path)
        XCTAssertFalse(firstBranch, "a quiet run leaves no branch behind")

        // His branch moves on between the two runs.
        let moved = await Shell.run("printf 'two\\n' > a.txt && git commit -qam second", cwd: URL(fileURLWithPath: project.path))
        XCTAssertTrue(moved.ok, moved.combined)

        m.runAutomationNow(a.id)
        await waitUntil { box.sent.count == 2 }
        let second = try XCTUnwrap(m.automations.runs(for: a.id).first { $0.id != first.id })
        let copy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(second.workspaceID)))
        XCTAssertEqual(copy.checkoutRoot, firstCopy.checkoutRoot, "the same folder")
        XCTAssertNotEqual(copy.id, firstCopy.id, "under a record of its own")
        XCTAssertEqual(try? String(contentsOfFile: copy.path + "/a.txt", encoding: .utf8), "two\n",
                       "started from the branch as it is now, not as the last run left it")
        XCTAssertTrue(fm.fileExists(atPath: copy.path + "/build/app.bin"), "what was built is still there")
        XCTAssertEqual(try? String(contentsOfFile: copy.path + "/local.properties", encoding: .utf8), "sdk.dir=/x")
        XCTAssertFalse(fm.fileExists(atPath: copy.path + "/artifacts/report.md"), "last week's report is not this week's")
        let ours = await WorkCopies.isOurs(copy)
        XCTAssertTrue(ours, "on its own branch, marked as this run's")
        let kept = WorkCopies.keptArtifacts(for: firstCopy).appendingPathComponent("report.md").path
        XCTAssertTrue(fm.fileExists(atPath: kept), "the first run's report is kept with that run")
    }

    /// Throwing a run's changes away throws away the changes, not the folder and what it built.
    @MainActor
    func testDiscardingThrowsTheChangesAwayAndKeepsTheFolder() async throws {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Discard", brief: "x", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        let copy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(run.workspaceID)))
        try "changed\n".write(toFile: copy.path + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: copy.path + "/new.txt", atomically: true, encoding: .utf8)
        let committed = await Shell.run("git add -A && git commit -qm work", cwd: URL(fileURLWithPath: copy.path))
        XCTAssertTrue(committed.ok, committed.combined)
        try "loose\n".write(toFile: copy.path + "/loose.txt", atomically: true, encoding: .utf8)
        m.automations.updateRun(run.id) { $0.state = .finished; $0.result = .changes; $0.handoff = .waiting }

        let problem = await m.discardRun(run.id)
        XCTAssertNil(problem)
        XCTAssertEqual(m.automations.run(id: run.id)?.handoff, .discarded)
        XCTAssertEqual(try? String(contentsOfFile: copy.path + "/a.txt", encoding: .utf8), "one\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path + "/new.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path + "/loose.txt"))
        let parked = await WorkCopies.isParked(copy.checkoutRoot, automationID: a.id, sourceRoot: copy.sourceRoot)
        XCTAssertTrue(parked)
        let branch = await WorkCopies.refExists("refs/heads/\(copy.branch)", in: project.path)
        XCTAssertFalse(branch, "the thrown-away branch is gone")
        XCTAssertEqual(try? String(contentsOfFile: project.path + "/a.txt", encoding: .utf8), "one\n", "his folder never saw it")
    }

    /// A check is told it is one, never ends with changes to merge, and what it changed anyway is
    /// thrown away with its folder's reset.
    @MainActor
    func testACheckHandsNothingOver() async throws {
        let (m, box, project, product) = await world()
        var a = Automation(productID: product.id, projectID: project.id, name: "Check", brief: "Run the tests.", trigger: .manual)
        a.workMode = .checkOnly
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        XCTAssertEqual(run.checkOnly, true, "recorded as a check")
        let copy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(run.workspaceID)))
        let context = m.copyContext(chatID: try XCTUnwrap(run.chatID), copy: copy)
        XCTAssertTrue(context.contains("Это проверка, а не правка"), "the run is told it only checks")
        XCTAssertTrue(context.contains("постоянная папка"), "and that the folder is kept")

        XCTAssertEqual(AppModel.runResult(outcome: .succeededChanges, done: nil, copyHasWork: true, checkOnly: true), .noChange)
        XCTAssertEqual(AppModel.runResult(outcome: .succeededResearch, done: nil, copyHasWork: true, checkOnly: true), .report)
        XCTAssertEqual(AppModel.runResult(outcome: .succeededChanges, done: nil, copyHasWork: true, checkOnly: false), .changes)

        try "edited by a check\n".write(toFile: copy.path + "/a.txt", atomically: true, encoding: .utf8)
        m.automations.updateRun(run.id) { $0.state = .finished; $0.result = .report }
        await m.sweepCopies()
        XCTAssertEqual(m.automations.copy(id: copy.id)?.state, .removed, "nothing of a check waits for him")
        XCTAssertEqual(try? String(contentsOfFile: copy.path + "/a.txt", encoding: .utf8), "one\n")
        XCTAssertEqual(try? String(contentsOfFile: project.path + "/a.txt", encoding: .utf8), "one\n")
        XCTAssertTrue(m.automationRunsWantingHim.isEmpty)
    }

    /// Something at the folder's place that is not the automation's parked folder is not adopted,
    /// emptied or removed: the run is given a folder of its own, as before.
    @MainActor
    func testAFolderInTheWayIsLeftAloneAndTheRunGetsItsOwn() async throws {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "In the way", brief: "x", trigger: .manual)
        m.automations.add(a)
        guard let sourceRoot = await WorkCopies.topLevel(of: project.path) else { return XCTFail("no repository") }
        let home = WorkCopies.homeRoot(sourceRoot: sourceRoot, automationID: a.id)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try "someone's".write(toFile: home + "/note.txt", atomically: true, encoding: .utf8)

        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        XCTAssertEqual(run.state, .running)
        let copy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(run.workspaceID)))
        XCTAssertNotEqual(copy.checkoutRoot, home)
        XCTAssertEqual(try? String(contentsOfFile: home + "/note.txt", encoding: .utf8), "someone's")
    }

    /// An automation that is gone keeps no folder.
    @MainActor
    func testTheFolderOfADeletedAutomationIsRemoved() async throws {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Short-lived", brief: "x", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        let copy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(run.workspaceID)))
        m.automations.updateRun(run.id) { $0.state = .finished; $0.result = .noChange }
        await m.sweepCopies()
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.checkoutRoot), "kept while the automation is there")

        // A Bulava that never had this automation — a list that did not load, another model looking
        // at the same folders — has no say over its folder.
        setenv("BULAVA_STATE_DIR", scratch.appendingPathComponent("elsewhere-state").path, 1)
        let other = AppModel()
        setenv("BULAVA_STATE_DIR", scratch.appendingPathComponent("state").path, 1)
        XCTAssertNil(other.automations.automation(id: a.id))
        XCTAssertTrue(other.automations.runs.isEmpty)
        await other.sweepCopies()
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.checkoutRoot), "unknown is not deleted")

        XCTAssertNil(m.deleteAutomation(a.id))
        await m.sweepCopies()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.checkoutRoot))
        let listed = await Shell.run("git worktree list --porcelain", cwd: URL(fileURLWithPath: project.path))
        XCTAssertFalse(listed.stdout.contains((copy.checkoutRoot as NSString).lastPathComponent), "and git no longer counts it")
    }

    /// The files git ignores in his folder that a build needs are found, and brought into a run
    /// when the automation says so — only ignored ones, and fresh each time.
    @MainActor
    func testLocalFilesAreFoundAndBroughtIn() async throws {
        let path = await repo()
        let setup = await Shell.run("""
            printf 'local.properties\\n.env\\nbuild/\\n' >> .git/info/exclude && \
            printf 'sdk.dir=/sdk\\n' > local.properties && printf 'KEY=1\\n' > .env && \
            mkdir -p build && printf 'x' > build/out.txt
            """, cwd: URL(fileURLWithPath: path))
        XCTAssertTrue(setup.ok, setup.combined)
        let found = await WorkCopies.localConfigFiles(in: path)
        XCTAssertEqual(found, [".env", "local.properties"])
        XCTAssertTrue(WorkCopies.isLocalConfig("android/local.properties"))
        XCTAssertTrue(WorkCopies.isLocalConfig(".env.local"))
        XCTAssertFalse(WorkCopies.isLocalConfig(".env.example"))
        XCTAssertFalse(WorkCopies.isLocalConfig("README.md"))

        let made = await WorkCopies.make(sourcePath: path, projectID: UUID(), baseRef: nil, branch: "bulava/carry",
                                         owner: .run(UUID()), carry: ["local.properties", "a.txt"])
        guard case .success(let copy) = made else { return XCTFail("no copy") }
        XCTAssertEqual(try? String(contentsOfFile: copy.path + "/local.properties", encoding: .utf8), "sdk.dir=/sdk\n")
        XCTAssertEqual(copy.copiedFiles, ["local.properties"], "a tracked file is never copied over the checkout")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path + "/.env"), "only what was chosen")
    }

    /// Local files are his to give or withhold run by run. Switched off, or gone from his folder,
    /// they do not reach the next run as last week's copy — and what a run built stays.
    @MainActor
    func testLocalFilesSwitchedOffOrGoneDoNotReachTheNextRun() async throws {
        let (m, box, project, product) = await world()
        let setup = await Shell.run("""
            printf 'local.properties\\n.env\\nbuild/\\n' >> .git/info/exclude && \
            printf 'sdk.dir=/sdk\\n' > local.properties && printf 'KEY=secret\\n' > .env
            """, cwd: URL(fileURLWithPath: project.path))
        XCTAssertTrue(setup.ok, setup.combined)
        var a = Automation(productID: product.id, projectID: project.id, name: "Local files", brief: "x", trigger: .manual)
        a.carryFiles = [".env", "local.properties"]
        m.automations.add(a)
        let fm = FileManager.default

        func runOnce(_ n: Int) async throws -> WorkCopy {
            m.runAutomationNow(a.id)
            await waitUntil { box.sent.count == n }
            let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
            let copy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(run.workspaceID)))
            return copy
        }
        func finish(_ copy: WorkCopy) async {
            if case .run(let runID) = copy.owner {
                m.automations.updateRun(runID) { $0.state = .finished; $0.result = .noChange }
            }
            await m.sweepCopies()
        }

        let first = try await runOnce(1)
        XCTAssertEqual(try? String(contentsOfFile: first.path + "/.env", encoding: .utf8), "KEY=secret\n")
        XCTAssertEqual(try? String(contentsOfFile: first.path + "/local.properties", encoding: .utf8), "sdk.dir=/sdk\n")
        try fm.createDirectory(atPath: first.path + "/build", withIntermediateDirectories: true)
        try "binary".write(toFile: first.path + "/build/app.bin", atomically: true, encoding: .utf8)
        await finish(first)

        // He deletes .env in his folder.
        try fm.removeItem(atPath: project.path + "/.env")
        let second = try await runOnce(2)
        XCTAssertEqual(second.checkoutRoot, first.checkoutRoot)
        XCTAssertFalse(fm.fileExists(atPath: second.path + "/.env"), "gone from his folder, gone from the run")
        XCTAssertEqual(try? String(contentsOfFile: second.path + "/local.properties", encoding: .utf8), "sdk.dir=/sdk\n")
        await finish(second)

        // He switches bringing them off.
        var edited = try XCTUnwrap(m.automations.automation(id: a.id))
        edited.carryFiles = nil
        m.editAutomation(a.id, to: edited)
        let third = try await runOnce(3)
        XCTAssertEqual(third.checkoutRoot, first.checkoutRoot)
        XCTAssertFalse(fm.fileExists(atPath: third.path + "/local.properties"), "switched off: not given")
        XCTAssertFalse(fm.fileExists(atPath: third.path + "/.env"))
        XCTAssertEqual(third.copiedFiles, [])
        XCTAssertTrue(fm.fileExists(atPath: third.path + "/build/app.bin"), "what was built is not his file to withhold")
        XCTAssertEqual(try? String(contentsOfFile: project.path + "/local.properties", encoding: .utf8), "sdk.dir=/sdk\n",
                       "his own file is never touched")
    }

    /// A link a run left in its folder that leads back into his: bringing a file in through it
    /// would have replaced — deleted — his own.
    @MainActor
    func testALinkBackIntoHisFolderNeverCostsHimAFile() async throws {
        let path = await repo()
        let setup = await Shell.run("""
            printf 'cfg/\\n' >> .git/info/exclude && mkdir -p cfg && printf 'mine\\n' > cfg/local.properties
            """, cwd: URL(fileURLWithPath: path))
        XCTAssertTrue(setup.ok, setup.combined)
        let made = await WorkCopies.make(sourcePath: path, projectID: UUID(), baseRef: nil, branch: "bulava/link",
                                         owner: .run(UUID()))
        guard case .success(let copy) = made else { return XCTFail("no copy") }
        try FileManager.default.createSymbolicLink(atPath: copy.path + "/cfg", withDestinationPath: path + "/cfg")
        XCTAssertFalse(WorkCopies.staysInside(copy.path + "/cfg/local.properties", root: copy.checkoutRoot))
        XCTAssertTrue(WorkCopies.staysInside(copy.path + "/new/local.properties", root: copy.checkoutRoot))

        let copied = await WorkCopies.copyIncludes(from: path, to: copy.checkoutRoot, carry: ["cfg/local.properties"])
        XCTAssertEqual(copied, [])
        XCTAssertEqual(try? String(contentsOfFile: path + "/cfg/local.properties", encoding: .utf8), "mine\n")
    }

    /// Bulava quit after the folder was marked free and before it left the run's branch: the next
    /// look finishes the job, and the next run still gets the folder.
    @MainActor
    func testAParkInterruptedByAQuitIsFinishedAndTheFolderReused() async throws {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Interrupted", brief: "x", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { box.sent.count == 1 }
        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        let copy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(run.workspaceID)))
        let marked = await Shell.run("printf 'parked:%s\\n' \"$1\" > \"$(git rev-parse --absolute-git-dir)/bulava-copy\"",
                                     args: [a.id.uuidString], cwd: URL(fileURLWithPath: copy.path))
        XCTAssertTrue(marked.ok, marked.combined)
        m.automations.updateRun(run.id) { $0.state = .finished; $0.result = .noChange }

        await m.sweepCopies()
        XCTAssertEqual(m.automations.copy(id: copy.id)?.state, .removed)
        let onBranch = await WorkCopies.currentBranch(of: copy.path)
        XCTAssertNil(onBranch, "off the run's branch")
        let branch = await WorkCopies.refExists("refs/heads/\(copy.branch)", in: project.path)
        XCTAssertFalse(branch)

        m.runAutomationNow(a.id)
        await waitUntil { box.sent.count == 2 }
        let next = try XCTUnwrap(m.automations.runs(for: a.id).first { $0.id != run.id })
        XCTAssertEqual(m.automations.copy(id: try XCTUnwrap(next.workspaceID))?.checkoutRoot, copy.checkoutRoot)
    }

    /// Moved to another repository that happens to have the same name: the old folder is given up,
    /// not refused forever.
    @MainActor
    func testAnAutomationMovedToAnotherRepositoryOfTheSameNameGetsAFolderOfIt() async throws {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Moved", brief: "x", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { box.sent.count == 1 }
        let first = try XCTUnwrap(m.automations.runs(for: a.id).first)
        m.automations.updateRun(first.id) { $0.state = .finished; $0.result = .noChange }
        await m.sweepCopies()

        let other = scratch.appendingPathComponent("elsewhere/Narada App", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let made = await Shell.run("git init -q -b main . && printf 'other\\n' > b.txt && git add b.txt && git commit -qm init",
                                   cwd: other)
        XCTAssertTrue(made.ok, made.combined)
        let otherProject = m.projects.add(path: other.path)
        m.products.addResource(ProductResource(name: "Other", projectID: otherProject.id), to: product.id)
        var edited = try XCTUnwrap(m.automations.automation(id: a.id))
        edited.projectID = otherProject.id
        m.editAutomation(a.id, to: edited)

        m.runAutomationNow(a.id)
        await waitUntil { box.sent.count == 2 }
        let second = try XCTUnwrap(m.automations.runs(for: a.id).first { $0.id != first.id })
        let copy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(second.workspaceID)))
        let home = WorkCopies.homeRoot(sourceRoot: Slug.canonicalPath(other.path), automationID: a.id)
        XCTAssertEqual(Slug.canonicalPath(copy.checkoutRoot), Slug.canonicalPath(home))
        let linked = await WorkCopies.isLinkedCheckout(copy.checkoutRoot, of: other.path)
        XCTAssertTrue(linked, "a checkout of the repository it now works in")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path + "/b.txt"))
    }

    /// Moved to a repository under another name: its old folder does not stay behind for ever.
    @MainActor
    func testAnAutomationMovedToAnotherRepositoryLeavesNoOldFolder() async throws {
        let (m, box, project, product) = await world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Moved away", brief: "x", trigger: .manual)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { box.sent.count == 1 }
        let first = try XCTUnwrap(m.automations.runs(for: a.id).first)
        let old = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(first.workspaceID)))
        m.automations.updateRun(first.id) { $0.state = .finished; $0.result = .noChange }
        await m.sweepCopies()
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.checkoutRoot))

        let other = scratch.appendingPathComponent("Backend", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let made = await Shell.run("git init -q -b main . && printf 'b\\n' > b.txt && git add b.txt && git commit -qm init",
                                   cwd: other)
        XCTAssertTrue(made.ok, made.combined)
        let otherProject = m.projects.add(path: other.path)
        m.products.addResource(ProductResource(name: "Backend", projectID: otherProject.id), to: product.id)
        var edited = try XCTUnwrap(m.automations.automation(id: a.id))
        edited.projectID = otherProject.id
        m.editAutomation(a.id, to: edited)

        m.runAutomationNow(a.id)
        await waitUntil { box.sent.count == 2 }
        let second = try XCTUnwrap(m.automations.runs(for: a.id).first { $0.id != first.id })
        let copy = try XCTUnwrap(m.automations.copy(id: try XCTUnwrap(second.workspaceID)))
        XCTAssertNotEqual(copy.checkoutRoot, old.checkoutRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.checkoutRoot), "the old repository's folder is gone")
        let listed = await Shell.run("git worktree list --porcelain", cwd: URL(fileURLWithPath: project.path))
        XCTAssertFalse(listed.stdout.contains((old.checkoutRoot as NSString).lastPathComponent),
                       "and the old repository no longer counts it")
    }

    /// The form, laid out and drawn in both appearances, with a check chosen and local files brought.
    @MainActor
    func testTheEditorShowsWhatARunMayDoAndTheFilesItBrings() async throws {
        let (_, _, project, product) = await world()
        var a = Automation(productID: product.id, projectID: project.id, name: "Перевірка збірки",
                           brief: "Зберіть застосунок і проженіть тести.", trigger: .manual)
        a.workMode = .checkOnly
        a.carryFiles = ["local.properties", ".env"]
        for scheme in [ColorScheme.light, .dark] {
            let view = AutomationWorkSection(draft: .constant(AutomationDraft(a)))
                .frame(width: 604)
                .padding(18)
                .background(Palette.content)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "the section draws")
            XCTAssertGreaterThan(image.size.height, 140, "the choice, its words and the files, not an empty box")
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("bulava-editor-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        var draft = AutomationDraft(a)
        XCTAssertEqual(draft.workMode, .checkOnly)
        XCTAssertTrue(draft.bringLocalFiles)
        draft.found(localFiles: ["local.properties"], isNew: false)
        XCTAssertEqual(draft.localFiles, [".env", "local.properties"], "what it brings is shown even when not found now")
        XCTAssertEqual(draft.automation()?.carryFiles, [".env", "local.properties"])
        draft.bringLocalFiles = false
        XCTAssertNil(draft.automation()?.carryFiles)

        var fresh = AutomationDraft()
        fresh.found(localFiles: ["local.properties"], isNew: true)
        XCTAssertTrue(fresh.bringLocalFiles, "a new automation is offered them ticked")
        XCTAssertEqual(fresh.workMode, .branch)
    }

    /// «Noted, changed nothing» after the work is not what the run hands over.
    func testAReplyThatChangedNothingDoesNotReplaceTheSummaryOfTheWork() {
        let work = "Перенесено «Судова практика» і «Порівняти редакції»; коміти 64f4827, 8e6af02."
        let remark = "Уточнення прийнято, змін не робив."
        XCTAssertEqual(AppModel.runSummary(turn: remark, turnOutcome: .succeededNoChange, copyHasWork: true,
                                           earlier: work), work)
        XCTAssertEqual(AppModel.runSummary(turn: "Додав ще одну функцію.", turnOutcome: .succeededChanges,
                                           copyHasWork: true, earlier: work),
                       "Додав ще одну функцію.", "a turn that did work says what it did")
        XCTAssertEqual(AppModel.runSummary(turn: "Нового нічого.", turnOutcome: .succeededNoChange,
                                           copyHasWork: false, earlier: "Минулого разу теж нічого."),
                       "Нового нічого.", "with nothing in the copy, the latest answer is the answer")
        XCTAssertEqual(AppModel.runSummary(turn: remark, turnOutcome: .succeededNoChange, copyHasWork: true,
                                           earlier: nil), remark, "and with nothing earlier, it is all there is")
    }
}
