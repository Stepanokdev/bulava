import XCTest
import SwiftUI
import AppKit
@testable import Bulava

/// A job that is not about code (`AutomationWorkMode.job`): a plain folder of its own instead of a
/// git copy, what its run is told and allowed, how it ends, what it says about it and when, and
/// where its conversations are found — on the Mac and on the phone.
///
/// The engine is not started: the brief is caught where it would have been sent. What the engine
/// does with such a run is pinned in `engine/tests/test-plain-folder.sh`.
nonisolated final class AutomationJobTests: XCTestCase {

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-job-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", scratch.appendingPathComponent("state").path, 1)
        setenv("BULAVA_COPIES_DIR", scratch.appendingPathComponent("copies").path, 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        unsetenv("BULAVA_COPIES_DIR")
        super.tearDown()
    }

    struct Sent { var message: String; var chatID: UUID; var entryID: UUID }
    @MainActor private final class Box { var sent: [Sent] = []; var readied: [String] = []; var copies = 0 }

    /// A product whose folder is NOT a repository — a pile of documents — and a folder of notes.
    @MainActor private func world() -> (AppModel, Box, Project, Product, URL) {
        let m = AppModel()
        let box = Box()
        m.sendAutomationBrief = { message, _, chatID, entryID in
            box.sent.append(Sent(message: message, chatID: chatID, entryID: entryID))
        }
        m.readyCopyOverride = { _ in box.copies += 1 }
        m.readyJobOverride = { folder in box.readied.append(folder) }
        let docs = scratch.appendingPathComponent("Docs", isDirectory: true)
        let notes = scratch.appendingPathComponent("Meetings records", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let project = m.projects.add(path: docs.path)
        let product = m.products.add(name: "Мітинги", resources: [ProductResource(name: "Docs", projectID: project.id)])
        return (m, box, project, product, notes)
    }

    @MainActor private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @MainActor private func job(_ product: Product, _ project: Project, notes: URL) -> Automation {
        var a = Automation(productID: product.id, projectID: project.id, name: "Мітинги → memex",
                           brief: "Перегляньте нові мітинги й додайте задачі в memex.", trigger: .manual)
        a.workMode = .job
        a.readFolders = [notes.path]
        a.allowedTools = ["memex"]
        return a
    }

    // MARK: Where it works and what it is told

    @MainActor
    func testAJobRunsInAPlainFolderOfItsOwnWithNoCopyAndNoGit() async throws {
        let (m, box, project, product, notes) = world()
        let a = job(product, project, notes: notes)
        m.automations.add(a)

        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }

        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        XCTAssertEqual(run.state, .running, run.note ?? "")
        XCTAssertTrue(run.isJob, "recorded as a job, so an edit later does not change what this run was")
        XCTAssertNil(run.workspaceID, "no copy")
        XCTAssertTrue(m.automations.copies.isEmpty, "and none made")
        XCTAssertEqual(box.copies, 0)

        let folder = try XCTUnwrap(JobFolders.existing(for: a.id))
        XCTAssertTrue(folder.path.hasPrefix(scratch.appendingPathComponent("copies/jobs").path), folder.path)
        XCTAssertFalse(folder.path.contains(" "), "no space in a path a script may meet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path), "no git in it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path + "/.git"), "nor in his folder")
        XCTAssertEqual(box.readied, [folder.path], "the folder is trusted before the run starts")

        let chat = try XCTUnwrap(m.conversations.chat(id: run.chatID!))
        XCTAssertTrue(chat.isAutomationRun)
        XCTAssertNil(chat.workCopyID)
        XCTAssertFalse(chat.wantsCopy)
        XCTAssertFalse(m.conversations.chats(for: product.id).contains { $0.id == chat.id }, "not among his own chats")
        XCTAssertEqual(m.conversations.automationChats(for: product.id).map(\.id), [chat.id],
                       "but in the product's automation runs")

        let execution = await m.executionProject(for: chat.id, primary: project)
        XCTAssertEqual(try? execution.get().path, folder.path, "the worker runs in the job's folder, not his")

        XCTAssertEqual(m.jobEnv(forChat: chat.id),
                       ["SUPERVISOR_PLAIN_FOLDER": "1", "SUPERVISOR_ALLOW_TOOLS": "memex"],
                       "the engine is told: no git, and the one service it may use")
        XCTAssertEqual(m.jobEnv(forChat: m.conversations.newChat(for: product.id).id), [:], "and nothing for his own chats")

        let context = m.copyContext(chatID: chat.id, copy: nil)
        XCTAssertTrue(context.contains(folder.path), "told where it works")
        XCTAssertTrue(context.contains(notes.path) && context.contains(project.path), "and what it reads — his folders")
        XCTAssertTrue(context.contains("`memex`"), "and the service it may use")
        XCTAssertTrue(context.contains("succeeded_changes") && context.contains("failed"), "and how to end")
        XCTAssertTrue(context.contains("ДАННЫЕ"), "what the notes say is data, never instructions")
        XCTAssertFalse(context.contains("отдельной копии"), "not the copy's rules")

        // Nothing is waiting for a merge, so the next run is not held back by one.
        XCTAssertNil(m.reasonNotToStart(a, now: Date()).flatMap { $0.contains("merge") ? $0 : nil })
    }

    @MainActor
    func testTheFolderIsKeptBetweenRunsAndFoundAgainAfterARename() async throws {
        let (m, box, project, product, notes) = world()
        var a = job(product, project, notes: notes)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let first = try XCTUnwrap(JobFolders.existing(for: a.id))
        try "for the next run".write(to: first.appendingPathComponent("seen.txt"), atomically: true, encoding: .utf8)
        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        m.settle(run, result: .noChange, summary: "Нових мітингів немає.", now: Date())

        a.name = "Нотатки → задачі"
        m.editAutomation(a.id, to: a)
        m.runAutomationNow(a.id)
        await waitUntil { box.sent.count == 2 }
        XCTAssertEqual(JobFolders.existing(for: a.id), first, "the same folder, whatever it is called now")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("seen.txt").path),
                      "with what the last run left in it")
    }

    // MARK: How it ends, and what it says

    func testAJobsEndingIsWhatItDeclared() {
        XCTAssertEqual(AppModel.jobResult(outcome: .succeededChanges), .done)
        XCTAssertEqual(AppModel.jobResult(outcome: .succeededNoChange), .noChange)
        XCTAssertEqual(AppModel.jobResult(outcome: .succeededResearch), .report)
        XCTAssertEqual(AppModel.jobResult(outcome: .failed), .failed)
        XCTAssertEqual(AppModel.jobResult(outcome: nil), .failed, "saying nothing is a failure, not a quiet evening")
        XCTAssertEqual(AppModel.jobResult(outcome: .blocked), .needsYou)
        XCTAssertEqual(AppModel.jobResult(outcome: .needsInput), .needsYou)
    }

    /// A check that found nothing to do used to come back "done, not reviewed": the gate cannot prove
    /// "nothing to do" from a diff and writes debt, and that asked for a report and a look.
    func testNothingToDoWithNothingInTheCopyIsNothingNewWhateverTheGateWrote() {
        XCTAssertEqual(AppModel.runResult(outcome: .succeededNoChange, done: "debt", copyHasWork: false, checkOnly: true), .noChange)
        XCTAssertEqual(AppModel.runResult(outcome: .succeededNoChange, done: "debt", copyHasWork: false, checkOnly: false), .noChange)
        XCTAssertEqual(AppModel.runResult(outcome: nil, done: "debt", copyHasWork: false, checkOnly: false), .unverified,
                       "an ending nobody declared is still unreviewed")
        XCTAssertEqual(AppModel.runResult(outcome: .succeededChanges, done: "debt", copyHasWork: false, checkOnly: false), .unverified,
                       "a claim of changes with none in the copy is too")
        XCTAssertEqual(AppModel.runResult(outcome: .succeededNoChange, done: "passed", copyHasWork: true, checkOnly: false), .changes,
                       "and work in the copy is work, whatever was said")
    }

    func testOnlyWhatNeedsHimReachesHim() {
        XCTAssertNil(AppModel.notice(for: .done, writesReport: false))
        XCTAssertNotNil(AppModel.notice(for: .done, writesReport: true), "a report he asked for is news")
        XCTAssertNil(AppModel.notice(for: .noChange, writesReport: true))
        XCTAssertNil(AppModel.notice(for: .report, writesReport: false), "a report nobody asked for is not news")
        XCTAssertNotNil(AppModel.notice(for: .report, writesReport: true))
        XCTAssertNil(AppModel.notice(for: .unverified, writesReport: false))
        for loud in [AutomationRun.Result.failed, .needsYou, .changes] {
            XCTAssertNotNil(AppModel.notice(for: loud, writesReport: false), "\(loud) always reaches him")
        }
    }

    @MainActor
    func testAJobThatWentWellIsQuietAndAFailureIsNot() async throws {
        let (m, box, project, product, notes) = world()
        let a = job(product, project, notes: notes)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        XCTAssertEqual(run.writesReport, false, "a job writes no report unless its automation says so")

        m.settle(run, result: .done, summary: "Додав 2 задачі в memex.", now: Date())
        let done = try XCTUnwrap(m.automations.run(id: run.id))
        XCTAssertNil(done.reportAsked, "no report turn")
        XCTAssertFalse(m.runWantsHim(done), "nothing waits for him")
        XCTAssertNil(m.automationState(forProductID: product.id), "no mark on the product")
        XCTAssertEqual(AutomationPresentation.gist(done), "Додав 2 задачі в memex.", "its line is what it did")
        XCTAssertFalse(done.isQuiet, "a run that did something is shown, not folded away with the quiet ones")

        m.runAutomationNow(a.id)
        await waitUntil { box.sent.count == 2 }
        let second = try XCTUnwrap(m.automations.runs(for: a.id).first { $0.id != run.id })
        m.settle(second, result: .failed, summary: "memex не відповів: 401.", now: Date())
        let failed = try XCTUnwrap(m.automations.run(id: second.id))
        XCTAssertTrue(failed.isRealFailure)
        XCTAssertTrue(m.runWantsHim(failed), "a failure waits for him until he has seen it")
        XCTAssertEqual(m.automationState(forProductID: product.id), .failed)

        m.runAutomationNow(a.id)
        await waitUntil { box.sent.count == 3 }
        let third = try XCTUnwrap(m.automations.runs(for: a.id).first { $0.id != run.id && $0.id != second.id })
        m.settle(third, result: .failed, summary: nil, now: Date())
        XCTAssertEqual(m.automations.automation(id: a.id)?.enabled, false, "two failures in a row switch it off")
        XCTAssertNotNil(m.automations.automation(id: a.id)?.pausedReason)
    }

    @MainActor
    func testAReportIsAskedForOnlyWhenTheAutomationSaysSo() async throws {
        let (m, _, project, product, notes) = world()
        var a = job(product, project, notes: notes)
        a.writesReport = true
        m.automations.add(a)
        let runID = UUID()
        let chat = m.conversations.newAutomationChat(id: UUID(), for: product.id, runID: runID, copyID: nil, title: "t")
        var run = AutomationRun(id: runID, automationID: a.id, occurrence: "r", reason: .manual, state: .running, briefRevision: 1)
        run.chatID = chat.id
        run.job = true
        run.writesReport = true
        m.automations.record(run)
        m.settle(m.automations.run(id: run.id)!, result: .done, summary: "Додав задачу.", now: Date())
        XCTAssertEqual(m.automations.run(id: run.id)?.reportAsked, true, "asked for: written once it is done")

        // A run on code from before this was a choice asks for one, as it always did.
        var old = AutomationRun(automationID: a.id, occurrence: "o", reason: .manual, state: .running, briefRevision: 1)
        old.chatID = chat.id
        m.automations.record(old)
        m.settle(m.automations.run(id: old.id)!, result: .changes, summary: "x", now: Date())
        XCTAssertEqual(m.automations.run(id: old.id)?.reportAsked, true)
    }

    /// A report a run wrote into the job's folder belongs to that run alone — the folder is shared by
    /// every run of the job.
    @MainActor
    func testAReportInTheSharedFolderBelongsToTheRunThatWroteIt() async throws {
        let (m, _, project, product, notes) = world()
        let a = job(product, project, notes: notes)
        m.automations.add(a)
        let folder = try XCTUnwrap(JobFolders.prepare(for: a.id, name: a.name))
        let page = folder.appendingPathComponent("artifacts/2026-10-08-summary/index.html")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<h1>Summary</h1>".write(to: page, atomically: true, encoding: .utf8)

        var mine = AutomationRun(automationID: a.id, occurrence: "m", reason: .manual, state: .finished, briefRevision: 1)
        mine.job = true
        mine.result = .report
        mine.startedAt = Date().addingTimeInterval(-60)
        mine.finishedAt = Date()
        m.automations.record(mine)
        XCTAssertEqual(m.reportPage(for: mine)?.path, page.path)

        var earlier = mine
        earlier.id = UUID()
        earlier.occurrence = "e"
        earlier.startedAt = Date().addingTimeInterval(-7200)
        earlier.finishedAt = Date().addingTimeInterval(-7000)
        m.automations.record(earlier)
        XCTAssertNil(m.reportPage(for: earlier), "a page written after it ended is not its report")
        XCTAssertNil(m.evidenceOnlyFolder(for: earlier), "nor is the folder of everybody's files")
    }

    @MainActor
    func testDeletingAJobTakesItsFolderAndKeepsWhatItWroteForHim() async throws {
        let (m, _, project, product, notes) = world()
        let a = job(product, project, notes: notes)
        m.automations.add(a)
        let folder = try XCTUnwrap(JobFolders.prepare(for: a.id, name: a.name))
        let page = folder.appendingPathComponent("artifacts/week/index.html")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<h1>Week</h1>".write(to: page, atomically: true, encoding: .utf8)
        let runID = UUID()
        let chat = m.conversations.newAutomationChat(id: UUID(), for: product.id, runID: runID, copyID: nil, title: "Week")
        m.conversations.bindSession(ChatSessionBinding(primaryProjectID: project.id, projectPath: folder.path), to: chat.id)
        m.conversations.addReport(page.path, to: chat.id)
        var run = AutomationRun(id: runID, automationID: a.id, occurrence: "w", reason: .manual, state: .finished, briefRevision: 1)
        run.job = true
        run.result = .report
        run.chatID = chat.id
        m.automations.record(run)

        XCTAssertNil(m.deleteAutomation(a.id))
        XCTAssertNil(JobFolders.existing(for: a.id), "the folder went with it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let kept = try XCTUnwrap(m.conversations.chat(id: chat.id)?.session?.reportPaths.first)
        XCTAssertTrue(kept.hasPrefix(JobFolders.kept(for: a.id).path), "the chat's report points where it was carried: \(kept)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept), "and it is there")
        XCTAssertTrue(m.conversations.chat(id: chat.id)?.archived == true, "its run's chat is an ordinary archived one now")
    }

    @MainActor
    func testAStartThatStoppedOnAQuestionFailsTheRunAtOnce() async throws {
        let (m, _, project, product, notes) = world()
        let a = job(product, project, notes: notes)
        m.automations.add(a)
        let runID = UUID()
        let chat = m.conversations.newAutomationChat(id: UUID(), for: product.id, runID: runID, copyID: nil, title: "t")
        var run = AutomationRun(id: runID, automationID: a.id, occurrence: "s", reason: .manual, state: .running, briefRevision: 1)
        run.chatID = chat.id
        m.automations.record(run)
        m.failAutomationStart(chatID: chat.id, exitCode: 76, detail: "У цій теці немає git…")
        let failed = try XCTUnwrap(m.automations.run(id: run.id))
        XCTAssertEqual(failed.state, .failed, "not fifteen minutes of «running» first")
        XCTAssertTrue(failed.note?.contains("git") == true, failed.note ?? "")
    }

    /// The record that makes a folder a job's for the review gate is signed by the app and checked
    /// by the engine: the engine's own check believes the app's signature, for that folder only.
    @MainActor
    func testTheEngineBelievesTheAppsSignatureForAJobsFolderAndNoOther() async throws {
        let m = AppModel()
        let state = scratch.appendingPathComponent("supervisor", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        await m.client.updatePaths(SupervisorPaths(stateDir: state))
        let job = scratch.appendingPathComponent("jobs/meetings-1a2b3c4d", isDirectory: true)
        let other = scratch.appendingPathComponent("copies/App-5e6f7a8b", isDirectory: true)
        for folder in [job, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try await m.client.markPlainFolder(projectPath: job.path)

        let lib = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/bin/supervisor-lib.sh").path
        func engineSaysPlain(_ folder: URL) async -> Bool {
            // The run's own instance folder, as the engine makes it: named after the folder, which
            // it records.
            let dir = state.appendingPathComponent("instances/\(Slug.forEngine(folder.path))", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? (ClaudeFolderTrust.realPath(folder.path) + "\n").write(to: dir.appendingPathComponent("project"),
                                                                        atomically: true, encoding: .utf8)
            let instance = dir.path
            let r = await Shell.run("bash -c '. \"$1\" >/dev/null 2>&1; plain_folder_run \"$2\"' bash \"$1\" \"$2\"",
                                    args: [lib, instance], extraEnv: ["SUPERVISOR_STATE_DIR": state.path])
            return await MainActor.run { r.ok }
        }
        let jobIsPlain = await engineSaysPlain(job)
        XCTAssertTrue(jobIsPlain, "the engine verifies the app's signature for the job's folder")
        let otherIsPlain = await engineSaysPlain(other)
        XCTAssertFalse(otherIsPlain, "and for no other folder")

        await m.client.forgetPlainFolder(projectPath: job.path)
        let forgotten = await engineSaysPlain(job)
        XCTAssertFalse(forgotten, "a forgotten record is no record")
    }

    // MARK: How the app reads the engine's word on a job's run

    /// A job's run against an engine instance written the way the engine writes one: how it ended
    /// is read from `done`, `outcome.json` and `stalled.json` as they are on disk.
    @MainActor
    private func jobRunEnding(done: String?, outcome: (result: String, summary: String)?, stalled: Bool) async throws
    -> AutomationRun {
        let (m, box, project, product, notes) = world()
        let state = scratch.appendingPathComponent("supervisor", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        await m.client.updatePaths(SupervisorPaths(stateDir: state))
        let a = job(product, project, notes: notes)
        m.automations.add(a)
        m.runAutomationNow(a.id)
        await waitUntil { !box.sent.isEmpty }
        let run = try XCTUnwrap(m.automations.runs(for: a.id).first)
        let folder = try XCTUnwrap(JobFolders.existing(for: a.id))
        let instance = state.appendingPathComponent("instances/\(Slug.forPath(folder.path))", isDirectory: true)
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        var files = ["project": folder.path, "session": "ns-job-test", "run-id": "RUN-JOB", "started-at": ""]
        if let done { files["done"] = done }
        if let outcome {
            files["outcome.json"] = #"{"schema":1,"result":"\#(outcome.result)","summary":"\#(outcome.summary)","ts":"2026-10-08 20:00:00","run_id":"RUN-JOB"}"#
        }
        if stalled { files["stalled.json"] = #"{"reason":"the worker froze","recovery":"hung"}"# }
        for (name, text) in files {
            try text.write(to: instance.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        m.conversations.bindSession(ChatSessionBinding(primaryProjectID: project.id, projectPath: folder.path,
                                                       activeRunID: "RUN-JOB"), to: try XCTUnwrap(run.chatID))
        await m.refresh()
        await m.automationsTick()
        await waitUntil { m.automations.run(id: run.id)?.state != .running }
        return try XCTUnwrap(m.automations.run(id: run.id))
    }

    @MainActor
    func testAJobThatSaidItDidTheJobIsDoneWithItsLine() async throws {
        let run = try await jobRunEnding(done: "passed", outcome: ("succeeded_changes", "Додав 2 задачі в memex."), stalled: false)
        XCTAssertEqual(run.state, .finished)
        XCTAssertEqual(run.result, .done)
        XCTAssertEqual(run.summary, "Додав 2 задачі в memex.")
        XCTAssertNil(run.reportAsked, "and asks for no report")
    }

    @MainActor
    func testAJobParkedWithNothingDeclaredIsAFailureNotAQuestion() async throws {
        let run = try await jobRunEnding(done: "needs-user", outcome: nil, stalled: false)
        XCTAssertEqual(run.state, .finished)
        XCTAssertEqual(run.result, .failed, "nothing to answer: it broke, and says so")
        XCTAssertEqual(run.note, String(localized: "It stopped without saying how it ended."))
        XCTAssertTrue(run.isRealFailure)
    }

    @MainActor
    func testAJobThatAskedIsAQuestion() async throws {
        let run = try await jobRunEnding(done: "needs-user", outcome: ("blocked", "Потрібен доступ до memex."), stalled: false)
        XCTAssertEqual(run.result, .needsYou)
    }

    func testWhenTheEngineHasGivenUpOnARun() {
        XCTAssertTrue(AppModel.engineGaveUp(stalled: true, frozenGaveUp: true, done: nil, question: false,
                                            outcome: nil, turnRunning: true),
                      "frozen and given up on, even with a stale busy status")
        XCTAssertTrue(AppModel.engineGaveUp(stalled: true, frozenGaveUp: false, done: nil, question: false,
                                            outcome: nil, turnRunning: false), "parked silent")
        XCTAssertFalse(AppModel.engineGaveUp(stalled: true, frozenGaveUp: false, done: nil, question: false,
                                             outcome: nil, turnRunning: true), "a parked run that is working again is not")
        XCTAssertFalse(AppModel.engineGaveUp(stalled: true, frozenGaveUp: true, done: "needs-user", question: false,
                                             outcome: nil, turnRunning: false), "a verdict decides instead")
        XCTAssertFalse(AppModel.engineGaveUp(stalled: true, frozenGaveUp: false, done: nil, question: true,
                                             outcome: nil, turnRunning: false), "and so does a question")
        XCTAssertFalse(AppModel.engineGaveUp(stalled: false, frozenGaveUp: false, done: nil, question: false,
                                             outcome: nil, turnRunning: false), "nothing given up on")
    }

    @MainActor
    func testARunTheEngineGaveUpOnFailsInsteadOfRunningForever() async throws {
        let run = try await jobRunEnding(done: nil, outcome: nil, stalled: true)
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.note, String(localized: "It stopped responding, and the engine gave up on it."))
    }

    // MARK: The form

    @MainActor
    func testTheFormMakesAJobInAFolderWithNoGit() throws {
        var draft = AutomationDraft()
        draft.name = "Мітинги → memex"
        draft.productID = UUID()
        draft.projectID = UUID()
        draft.brief = "Щовечора переглянь нові мітинги й додай задачі в memex."
        draft.folderIsRepository = false
        XCTAssertNotNil(draft.problem, "work on code needs git")
        draft.workMode = .job
        XCTAssertNil(draft.problem, "a job does not")

        draft.knownTools = [AutomationTools.Server(name: "memex", rule: "memex"),
                            AutomationTools.Server(name: "stepanok-deploy", rule: "stepanok-deploy")]
        draft.suggestTools()
        XCTAssertEqual(draft.allowedTools, ["memex"], "the service the brief names is offered ticked")
        draft.toggleTool("stepanok-deploy")
        draft.brief = "Нічого не роби."
        draft.suggestTools()
        XCTAssertEqual(draft.allowedTools, ["memex", "stepanok-deploy"], "once he picks, the brief's words pick nothing")

        draft.readFolders = ["/Users/x/Documents/Meetings records"]
        draft.baseBranch = "develop"
        let built = try XCTUnwrap(draft.automation())
        XCTAssertEqual(built.workMode, .job)
        XCTAssertEqual(built.readFolders, ["/Users/x/Documents/Meetings records"])
        XCTAssertEqual(built.allowedTools, ["memex", "stepanok-deploy"])
        XCTAssertNil(built.baseBranch, "a job has no branch")
        XCTAssertNil(built.carryFiles)
        XCTAssertFalse(built.reportsAfterRun, "no report by default")
        XCTAssertFalse(draft.reportsAfterRun)
        draft.workMode = .branch
        XCTAssertTrue(draft.reportsAfterRun, "work on code is handed over with one")

        var reread = AutomationDraft(built)
        XCTAssertTrue(reread.toolsTouched, "an existing automation keeps what it was saved with")
        reread.suggestTools()
        XCTAssertEqual(reread.allowedTools, ["memex", "stepanok-deploy"])
    }

    @MainActor
    func testTheFormShowsAJobsFoldersServicesAndReportChoice() throws {
        var a = Automation(productID: UUID(), projectID: UUID(), name: "Мітинги → memex", brief: "x", trigger: .manual)
        a.workMode = .job
        a.readFolders = [NSHomeDirectory() + "/Documents/Meetings records"]
        a.allowedTools = ["memex"]
        var draft = AutomationDraft(a)
        draft.knownTools = [AutomationTools.Server(name: "memex", rule: "memex"),
                            AutomationTools.Server(name: "youtube-transcript", rule: "youtube-transcript")]
        for scheme in [ColorScheme.light, .dark] {
            let view = AutomationWorkSection(draft: .constant(draft))
                .frame(width: 604)
                .padding(18)
                .background(Palette.content)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "the section draws")
            XCTAssertGreaterThan(image.size.height, 220, "the choice, the folders, the services and the report, not an empty box")
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("bulava-job-editor-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    func testAGuardedFolderAJobReadsIsAskedAboutWhenItIsSaved() {
        let home = NSHomeDirectory()
        let notes = home + "/Documents/Meetings records"
        let needs = AutomationNeeds.needs(trigger: .schedule(AutomationSchedule(cadence: .daily, hour: 20, minute: 0)),
                                          brief: "", readFolders: [notes, "/tmp/plain"])
        XCTAssertEqual(needs, [.readFolder(notes)], "Documents is guarded and a schedule reads it at night just the same")
        XCTAssertTrue(AutomationNeed.readFolder(notes).comesFromTrigger, "so it keeps the form from saving until settled")
        let watched = AutomationNeeds.needs(trigger: .event(AutomationEvent(kind: .folder(path: notes))), brief: "",
                                            readFolders: [notes])
        XCTAssertEqual(watched, [.folder(notes)], "a folder it already watches is asked about once")
    }

    func testTheServicesOfferedAreWhatClaudeCodeHasExceptHisBrowsers() throws {
        let config = scratch.appendingPathComponent("claude.json")
        let project = scratch.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let root: [String: Any] = [
            "mcpServers": [
                "memex": ["type": "http", "url": "https://memex.example.com/mcp"],
                "chrome-devtools": ["command": "npx", "args": ["-y", "chrome-devtools-mcp@latest"]],
                "pw": ["command": "npx", "args": ["@playwright/mcp"]],
            ],
            "projects": [project.path: ["mcpServers": ["tracker": ["command": "node", "args": ["t.js"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: config)
        try #"{"mcpServers":{"local-notes":{"command":"python3","args":["n.py"]}}}"#
            .write(to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        let known = AutomationTools.known(projectPaths: [project.path], configURL: config)
        XCTAssertEqual(known.map(\.name), ["local-notes", "memex", "tracker"], "his, the project's and its .mcp.json — no browser")
        XCTAssertEqual(AutomationTools.rule(for: "claude.ai Atlassian"), "claude_ai_Atlassian")
        XCTAssertEqual(AutomationTools.rule(for: "-x"), "", "not a name a rule can start with")
        XCTAssertEqual(AutomationTools.mentioned(in: "Додай задачі в Memex, будь ласка.", among: known).map(\.name), ["memex"])
        XCTAssertTrue(AutomationTools.mentioned(in: "memexpro", among: known).isEmpty, "a whole word, not a piece of one")
    }

    // MARK: Lists

    @MainActor
    func testRunsAreFoldedNewestFirstAndProductsFollowWhereHeWorked() throws {
        let (m, _, _, product, _) = world()
        let older = m.conversations.newAutomationChat(id: UUID(), for: product.id, runID: UUID(), copyID: nil, title: "Older")
        Thread.sleep(forTimeInterval: 0.01)
        let newer = m.conversations.newAutomationChat(id: UUID(), for: product.id, runID: UUID(), copyID: UUID(), title: "Newer")
        XCTAssertEqual(m.conversations.automationChats(for: product.id).map(\.id), [newer.id, older.id])

        let quiet = m.products.add(name: "Quiet")
        let busy = m.products.add(name: "Busy")
        let pinned = m.products.add(name: "Pinned")
        m.products.togglePin(pinned.id)
        m.products.worked(busy.id)
        let order = m.products.byRecentWork.map(\.name)
        XCTAssertEqual(order.first, "Pinned", "pinned stay on top")
        XCTAssertEqual(order[1], "Busy", "then the one he worked in last")
        XCTAssertLessThan(order.firstIndex(of: "Мітинги")!, order.firstIndex(of: "Quiet")!,
                          "never-worked ones keep the order they were added in")
        _ = quiet
    }

    /// The runs under his chats, folded; the one on screen keeps the fold open and is marked; a run
    /// that failed carries its mark. Drawn to a file so it can be looked at.
    @MainActor
    func testTheSidebarFoldsTheRunsUnderHisChats() throws {
        let (m, _, project, product, _) = world()
        _ = m.conversations.newChat(for: product.id)
        m.conversations.appendUser("Підготуй план релізу", productID: product.id,
                                   chatID: m.conversations.currentChat(for: product.id).id)
        let a = Automation(productID: product.id, projectID: project.id, name: "Мітинги → memex", brief: "x", trigger: .manual)
        m.automations.add(a)
        var opened: UUID?
        for (i, result) in [AutomationRun.Result.done, .noChange, .failed].enumerated() {
            let runID = UUID()
            let chat = m.conversations.newAutomationChat(id: UUID(), for: product.id, runID: runID, copyID: nil,
                                                         title: "Мітинги → memex · \(6 + i) жовт.")
            var run = AutomationRun(id: runID, automationID: a.id, occurrence: "s\(i)", reason: .manual,
                                    state: .finished, briefRevision: 1)
            run.chatID = chat.id
            run.result = result
            run.job = true
            m.automations.record(run)
            if result == .done { opened = chat.id }
            Thread.sleep(forTimeInterval: 0.01)
        }
        m.conversations.open(try XCTUnwrap(opened), for: product.id)
        m.navigate(to: .product(product.id))
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(spacing: 0) { ProductGroup(product: product) }
                .padding(8)
                .frame(width: 280)
                .background(Palette.chrome)
                .environment(m)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "the sidebar draws")
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("bulava-sidebar-runs-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    // MARK: The phone

    @MainActor
    func testThePhoneIsSentTheRunsAndAnIconItCanDraw() throws {
        let (m, _, project, product, _) = world()
        let a = Automation(productID: product.id, projectID: project.id, name: "Мітинги → memex",
                           brief: "x", trigger: .manual)
        m.automations.add(a)
        let runID = UUID()
        let chat = m.conversations.newAutomationChat(id: UUID(), for: product.id, runID: runID, copyID: nil, title: "Мітинги · 8 жовт.")
        var run = AutomationRun(id: runID, automationID: a.id, occurrence: "p", reason: .manual, state: .finished, briefRevision: 1)
        run.chatID = chat.id
        run.result = .failed
        m.automations.record(run)

        // An icon the phone cannot decode as it is: drawn into a PNG for it.
        let icns = scratch.appendingPathComponent("AppIcon.icns")
        let picture = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSColor.systemOrange.setFill(); rect.fill(); return true
        }
        try XCTUnwrap(picture.tiffRepresentation).write(to: scratch.appendingPathComponent("tmp.tiff"))
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: scratch.appendingPathComponent("tmp.tiff"))))
        try XCTUnwrap(tiff.representation(using: .png, properties: [:])).write(to: icns)
        m.products.setIcon(icns.path, for: product.id)

        let desktop = LinkDesktop(id: "mac", name: "Mac", version: "1", language: "uk")
        let projection = LinkProjection.build(m, desktop: desktop, openChats: [])
        let dto = try XCTUnwrap(projection.home.products.first { $0.id == product.id.uuidString })
        XCTAssertEqual(dto.automationChats?.map(\.id), [chat.id.uuidString], "its runs travel with the product")
        XCTAssertEqual(dto.automationChats?.first?.automation, "Мітинги → memex", "named by their automation")
        XCTAssertFalse(dto.chats.contains { $0.id == chat.id.uuidString }, "and not among his own chats")

        let icon = try XCTUnwrap(dto.icon)
        let ref = try XCTUnwrap(icon.ref)
        XCTAssertTrue(ref.hasPrefix("icon:\(product.id.uuidString):"), "a reference with a revision in it: \(ref)")
        let png = try XCTUnwrap(projection.files[ref])
        let drawn = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: png)), "a picture the phone can decode")
        XCTAssertLessThanOrEqual(max(drawn.pixelsWide, drawn.pixelsHigh), LinkIcons.side, "small, not the 512-pixel original")

        // A new picture under the same file name: a new reference, so the phone fetches it again.
        Thread.sleep(forTimeInterval: 1.1)
        try XCTUnwrap(tiff.representation(using: .png, properties: [:])).write(to: icns)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: icns.path)
        let again = LinkProjection.build(m, desktop: desktop, openChats: [])
        let ref2 = try XCTUnwrap(again.home.products.first { $0.id == product.id.uuidString }?.icon?.ref)
        XCTAssertNotEqual(ref2, ref, "a changed icon is a new reference")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: LinkIcons.folder.path))?.count, 1,
                       "and the old drawing is gone")
    }
}
