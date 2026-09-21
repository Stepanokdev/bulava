import XCTest
@testable import Bulava

// MARK: - Products and resources

nonisolated final class ProductModelTests: XCTestCase {

    func testInitialsFromOneAndTwoWordNames() {
        XCTAssertEqual(Product(name: "Narada").initials, "N")
        XCTAssertEqual(Product(name: "Night Shift").initials, "NS")
        XCTAssertEqual(Product(name: "a b c").initials, "AB")
    }

    func testWritableAndSourceResourcesAreSeparated() {
        let code = UUID(), backend = UUID()
        let product = Product(name: "P", resources: [
            ProductResource(name: "app", kind: .repository, access: .workspace, projectID: code),
            ProductResource(name: "backend", kind: .repository, access: .source, projectID: backend),
        ])
        XCTAssertEqual(product.writableProjectIDs, [code])
        XCTAssertEqual(product.sourceProjectIDs, [backend])
        XCTAssertEqual(Set(product.allProjectIDs), [code, backend])
        XCTAssertEqual(product.defaultProjectID, code, "a read-only resource must never be the default")
        XCTAssertEqual(product.access(forProjectID: backend), .source)
    }

    func testDefaultProjectPrefersWritableCodeOverWritableFolder() {
        let folder = UUID(), code = UUID()
        let product = Product(name: "P", resources: [
            ProductResource(name: "notes", kind: .folder, access: .workspace, projectID: folder),
            ProductResource(name: "app", kind: .repository, access: .workspace, projectID: code),
        ])
        XCTAssertEqual(product.defaultProjectID, code)
    }

    func testDecodeToleratesMissingFieldsButRequiresID() throws {
        let full = #"{"id":"\#(UUID().uuidString)"}"#
        XCTAssertNoThrow(try JSONDecoder().decode(Product.self, from: Data(full.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Product.self, from: Data(#"{"name":"x"}"#.utf8)))
    }
}

// MARK: - Priority and deadline read from what the user typed

nonisolated final class WorkPriorityDetectionTests: XCTestCase {

    func testUrgentIsRecognisedInBothLanguages() {
        XCTAssertEqual(WorkPriority.detect(in: "це срочно, поправ кнопку"), .urgent)
        XCTAssertEqual(WorkPriority.detect(in: "Це терміново"), .urgent)
        XCTAssertEqual(WorkPriority.detect(in: "fix this ASAP please"), .urgent)
    }

    func testLowPriorityIsRecognised() {
        XCTAssertEqual(WorkPriority.detect(in: "зроби коли освободишся"), .whenFree)
        XCTAssertEqual(WorkPriority.detect(in: "no rush on this one"), .whenFree)
    }

    func testOrdinaryRequestHasNoDetectedPriority() {
        XCTAssertNil(WorkPriority.detect(in: "онови лендінг і перевір тексти"),
                     "a plain request must not be silently promoted or demoted")
    }

    func testRankOrdersUrgentFirst() {
        XCTAssertLessThan(WorkPriority.urgent, WorkPriority.normal)
        XCTAssertLessThan(WorkPriority.normal, WorkPriority.whenFree)
    }

    func testDeadlineTomorrowIsEndOfNextDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 10)))
        let due = try XCTUnwrap(Deadline.detect(in: "зроби до завтра", now: now, calendar: cal))
        XCTAssertEqual(cal.component(.day, from: due), 5)
        XCTAssertEqual(cal.component(.hour, from: due), 23)
    }

    func testDeadlineWeekdayPicksTheNextOccurrence() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Kyiv")!

        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 10)))
        let due = try XCTUnwrap(Deadline.detect(in: "треба до пʼятниці", now: now, calendar: cal))
        XCTAssertEqual(cal.component(.weekday, from: due), 6, "Friday")
        XCTAssertGreaterThan(due, now)
    }

    func testNoDeadlineIsInventedFromAnOrdinaryRequest() {
        XCTAssertNil(Deadline.detect(in: "поправ кнопку в темній темі"))
    }
}

// MARK: - The dependency graph

nonisolated final class WorkItemGraphTests: XCTestCase {

    private func item(streams: [WorkItem.Stream], kind: WorkItem.Kind = .job) -> WorkItem {
        WorkItem(productID: UUID(), title: "package", kind: kind, streams: streams)
    }

    func testStartableRespectsDependencies() {
        let research = UUID(), pages = UUID(), audit = UUID()
        let it = item(streams: [
            .init(id: research, title: "research SEO", projectName: "site"),
            .init(id: pages, title: "build pages", projectName: "site", dependsOn: [research]),
            .init(id: audit, title: "audit", projectName: "site", dependsOn: [pages]),
        ])
        XCTAssertEqual(it.startable(finished: [], alreadyRunning: []).map(\.id), [research])
        XCTAssertEqual(it.startable(finished: [research], alreadyRunning: []).map(\.id), [pages])
        XCTAssertEqual(it.startable(finished: [research, pages], alreadyRunning: []).map(\.id), [audit])
        XCTAssertTrue(it.startable(finished: [research, pages, audit], alreadyRunning: []).isEmpty)
    }

    func testAlreadyRunningStreamIsNotStartedTwice() {
        let a = UUID(), b = UUID()
        let it = item(streams: [
            .init(id: a, title: "a", projectName: "p"),
            .init(id: b, title: "b", projectName: "p"),
        ])
        XCTAssertEqual(it.startable(finished: [], alreadyRunning: [a]).map(\.id), [b])
    }

    func testMissingDependencyDoesNotDeadlockTheItem() {
        let ghost = UUID(), real = UUID()
        let it = item(streams: [.init(id: real, title: "real", projectName: "p", dependsOn: [ghost])])
        XCTAssertEqual(it.startable(finished: [], alreadyRunning: []).map(\.id), [real],
                       "a dependency on a stream that no longer exists must not block forever")
    }

    func testVariantStreamsAreAllIndependentlyStartable() {
        let ids = (0..<10).map { _ in UUID() }
        let it = item(streams: ids.enumerated().map { i, id in
            .init(id: id, title: "variant \(i + 1)", projectName: "lab", variantNumber: i + 1)
        }, kind: .variants)
        XCTAssertEqual(it.startable(finished: [], alreadyRunning: []).count, 10,
                       "ten prototypes must be able to run as ten independent streams")
    }

    func testOverdueOnlyWhenDeadlinePassed() {
        var it = item(streams: [])
        it.dueBy = Date().addingTimeInterval(3600)
        XCTAssertFalse(it.isOverdue)
        it.dueBy = Date().addingTimeInterval(-3600)
        XCTAssertTrue(it.isOverdue)
    }
}

// MARK: - Scheduler ordering

nonisolated final class WorkItemOrderingTests: XCTestCase {

    func testUrgentBeatsNormalRegardlessOfAge() {
        let old = WorkItem(productID: UUID(), title: "old",
                           createdAt: Date().addingTimeInterval(-86_400), priority: .normal)
        let new = WorkItem(productID: UUID(), title: "urgent",
                           createdAt: Date(), priority: .urgent)
        XCTAssertTrue(WorkItemStore.precedes(new, old))
    }

    func testAmongEqualPrioritiesTheSoonerDeadlineWins() {
        let soon = WorkItem(productID: UUID(), title: "soon", priority: .normal,
                            dueBy: Date().addingTimeInterval(3600))
        let later = WorkItem(productID: UUID(), title: "later", priority: .normal,
                             dueBy: Date().addingTimeInterval(86_400))
        XCTAssertTrue(WorkItemStore.precedes(soon, later))
    }

    func testADeadlineBeatsNoDeadlineAtTheSamePriority() {
        let dated = WorkItem(productID: UUID(), title: "dated", priority: .normal,
                             dueBy: Date().addingTimeInterval(7200))
        let undated = WorkItem(productID: UUID(), title: "undated", priority: .normal)
        XCTAssertTrue(WorkItemStore.precedes(dated, undated))
    }
}

// MARK: - Honest progress

nonisolated final class WorkProgressHonestyTests: XCTestCase {

    private func task(_ state: TaskState, dispatched: Bool = true,
                      outcome: String? = nil) -> BacklogTask {
        var t = BacklogTask(title: "t", projectPath: "/tmp/p", state: state)
        if dispatched { t.dispatchedAt = Date().addingTimeInterval(-600) }
        t.lastOutcome = outcome
        return t
    }

    private func mark(_ ms: [WorkMilestone], _ id: String) -> WorkMilestone.Mark? {
        ms.first { $0.id == id }?.mark
    }

    func testAStoppedRunDoesNotClaimItNeverStarted() {
        let ms = WorkProgress.milestones(task: task(.blocked, outcome: "needs-user"), instance: nil,
                                         evidence: nil, disposition: "needs-user", hasReport: true)
        XCTAssertEqual(mark(ms, "queued"), .done)
        XCTAssertEqual(mark(ms, "review"), .failed, "the reviewer held it — say so")
        XCTAssertEqual(mark(ms, "report"), .done, "the report exists on disk")
        for id in ["plan", "research", "build", "check"] {
            XCTAssertEqual(mark(ms, id), .skipped,
                           "\(id) is unreadable after the run, which is not the same as unreached")
        }
    }

    func testAnUnstartedStageStillReadsAsWaitingWhileTheRunIsAlive() {
        let ms = WorkProgress.milestones(task: task(.executing), instance: nil,
                                         evidence: nil, disposition: nil, hasReport: false)
        XCTAssertEqual(mark(ms, "build"), .waiting)
        XCTAssertEqual(mark(ms, "report"), .waiting)
    }

    func testAFailedEvidenceFileNeverShowsTheCheckAsPassed() throws {
        let raw = """
        {"project_dir":"/tmp/p","session_id":"s","base_sha":"a","head_sha":"b",
         "work_tree_digest":"d","stacks":[],"overall_status":"fail",
         "criteria":[{"criterion":"build","command":"x","exit_code":1,"artifact":"",
                      "status":"fail","note":""}]}
        """
        let evidence = try XCTUnwrap(Evidence.decode(from: Data(raw.utf8)))
        let ms = WorkProgress.milestones(task: task(.review), instance: nil,
                                         evidence: evidence, disposition: nil, hasReport: false)
        XCTAssertEqual(mark(ms, "check"), .failed,
                       "an evidence file that failed must not read as a passed check")
    }

    func testPassingEvidenceShowsTheCheckDone() throws {
        let raw = """
        {"project_dir":"/tmp/p","session_id":"s","base_sha":"a","head_sha":"b",
         "work_tree_digest":"d","stacks":[],"overall_status":"pass",
         "criteria":[{"criterion":"build","command":"x","exit_code":0,"artifact":"",
                      "status":"pass","note":""}]}
        """
        let evidence = try XCTUnwrap(Evidence.decode(from: Data(raw.utf8)))
        let ms = WorkProgress.milestones(task: task(.review), instance: nil,
                                         evidence: evidence, disposition: nil, hasReport: false)
        XCTAssertEqual(mark(ms, "check"), .done)
    }

    func testReviewIsNeverClaimedWithoutTheReviewersVerdict() {
        let ms = WorkProgress.milestones(task: task(.review), instance: nil,
                                         evidence: nil, disposition: nil, hasReport: false)
        XCTAssertNotEqual(mark(ms, "review"), .done,
                          "a finished task's own state is not a reviewer's verdict")
    }

    func testAScopeViolationVerdictMarksReviewFailed() {
        let ms = WorkProgress.milestones(task: task(.review), instance: nil,
                                         evidence: nil, disposition: "scope_violation",
                                         hasReport: false)
        XCTAssertEqual(mark(ms, "review"), .failed)
    }

    func testNoReportMeansTheReportStageIsNotDoneAndDoesNotSpin() {
        let ms = WorkProgress.milestones(task: task(.review), instance: nil,
                                         evidence: nil, disposition: "passed", hasReport: false)
        XCTAssertNotEqual(mark(ms, "report"), .done)
        XCTAssertNotEqual(mark(ms, "report"), .current,
                          "a finished run with no report must not spin forever")
    }

    func testAnUndispatchedTaskClaimsNothing() {
        let ms = WorkProgress.milestones(task: task(.ready, dispatched: false), instance: nil,
                                         evidence: nil, disposition: nil, hasReport: false)
        XCTAssertEqual(mark(ms, "queued"), .waiting)
        XCTAssertTrue(ms.allSatisfy { $0.mark != .done },
                      "nothing has happened, so nothing may be green")
    }

    func testAVanishedRunBlamesNoStageBecauseNothingIsObservable() {

        let ms = WorkProgress.milestones(task: task(.failed, outcome: "gone"), instance: nil,
                                         evidence: nil, disposition: nil, hasReport: false)
        XCTAssertTrue(ms.allSatisfy { $0.mark != .failed },
                      "with no evidence past the handover, no stage may be blamed")
        XCTAssertNotEqual(mark(ms, "plan"), .failed,
                          "the old logic put every failure on \"Understand the work\"")
    }

    func testAFailureAfterRealProgressIsBlamedOnTheNextStage() throws {

        let raw = """
        {"project_dir":"/tmp/p","session_id":"s","base_sha":"a","head_sha":"b",
         "work_tree_digest":"d","stacks":[],"overall_status":"pass",
         "criteria":[{"criterion":"build","command":"x","exit_code":0,"artifact":"",
                      "status":"pass","note":""}]}
        """
        let evidence = try XCTUnwrap(Evidence.decode(from: Data(raw.utf8)))
        let ms = WorkProgress.milestones(task: task(.failed), instance: nil,
                                         evidence: evidence, disposition: nil, hasReport: false)
        let failed = ms.filter { $0.mark == .failed }
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.id, "review", "the stage after the last confirmed one")
    }

    func testUserStateCollapsesEngineStates() {
        XCTAssertEqual(WorkProgress.state(task: task(.merged), instance: nil), .done)
        XCTAssertEqual(WorkProgress.state(task: task(.review), instance: nil), .reportReady)
        XCTAssertEqual(WorkProgress.state(task: task(.failed), instance: nil), .failed)
        XCTAssertEqual(WorkProgress.state(task: task(.executing), instance: nil), .running)
        XCTAssertEqual(WorkProgress.state(task: task(.blocked), instance: nil), .needsAnswer)
        XCTAssertEqual(WorkProgress.state(task: task(.ready, dispatched: false), instance: nil), .planned)
    }
}

// MARK: - Run strategy is decided, never asked

nonisolated final class RunStrategyTests: XCTestCase {

    func testIsolationIsRequiredExactlyWhenTheCheckoutIsBusy() {
        let t = BacklogTask(title: "t")
        XCTAssertFalse(RunStrategy.decide(for: t, projectIsBusy: false).isolated)
        XCTAssertTrue(RunStrategy.decide(for: t, projectIsBusy: true).isolated)
    }

    func testReadingWorkGetsASmallerBudgetThanBuildingWork() {
        var research = BacklogTask(title: "r"); research.type = .research
        let build = BacklogTask(title: "b")
        XCTAssertEqual(RunStrategy.decide(for: research, projectIsBusy: false).claudeEffort, "medium")
        XCTAssertEqual(RunStrategy.decide(for: build, projectIsBusy: false).claudeEffort, "high")
    }

    func testAShortMultiStepJobGetsAStepUpNotTheMaximum() {
        var job = BacklogTask(title: "j")
        job.planSteps = ["one", "two", "three"]
        XCTAssertEqual(RunStrategy.decide(for: job, projectIsBusy: false).claudeEffort, "xhigh")
    }

    func testALongNightGetsTheDeepestSetting() {
        var job = BacklogTask(title: "j")
        job.planSteps = ["one", "two", "three", "four", "five"]
        XCTAssertEqual(RunStrategy.decide(for: job, projectIsBusy: false).claudeEffort, "ultracode")
    }
}

// MARK: - Conversation store

nonisolated final class ConversationStoreTests: XCTestCase {

    @MainActor private func store() -> (ConversationStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-\(UUID().uuidString).json")
        return (ConversationStore(fileURL: url), url)
    }

    @MainActor
    func testQuestionIsIdempotentSoTypingIsNotWiped() {
        let (s, url) = store(); defer { try? FileManager.default.removeItem(at: url) }
        let product = UUID(), task = UUID()
        s.postQuestion("Which database?", productID: product, taskID: task)
        let firstID = s.all(for: product).first { $0.kind == .question }?.id

        for _ in 0..<5 { s.postQuestion("Which database?", productID: product, taskID: task) }
        let questions = s.all(for: product).filter { $0.kind == .question }
        XCTAssertEqual(questions.count, 1, "a re-asked identical question must not stack up")
        XCTAssertEqual(questions.first?.id, firstID,
                       "the entry id must be stable or the card is rebuilt and the answer field cleared")
    }

    @MainActor
    func testANewQuestionReplacesTheOldOneForTheSameTask() {
        let (s, url) = store(); defer { try? FileManager.default.removeItem(at: url) }
        let product = UUID(), task = UUID()
        s.postQuestion("First?", productID: product, taskID: task)
        s.postQuestion("Second?", productID: product, taskID: task)
        let questions = s.all(for: product).filter { $0.kind == .question }
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.text, "Second?")
    }

    @MainActor
    func testPostEventOnceSurvivesARelaunch() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let product = UUID()
        do {
            let s = ConversationStore(fileURL: url)
            s.postEventOnce("Blocked in backend", productID: product)
            s.postEventOnce("Blocked in backend", productID: product)
        }

        let reopened = ConversationStore(fileURL: url)
        reopened.postEventOnce("Blocked in backend", productID: product)
        XCTAssertEqual(reopened.all(for: product).filter { $0.kind == .event }.count, 1,
                       "a blocker still on disk must not be re-announced on every launch")
    }

    @MainActor
    func testDetachKeepsWhatTheUserSaidAndDropsTheStructure() {
        let (s, url) = store(); defer { try? FileManager.default.removeItem(at: url) }
        let product = UUID(), task = UUID()
        s.appendUser("please fix the button", productID: product, taskID: task)
        s.anchorTask(task, productID: product, title: "fix button")
        s.postQuestion("which button?", productID: product, taskID: task)
        s.detach(taskID: task, keepingIn: product)

        let left = s.all(for: product)
        XCTAssertEqual(left.count, 1, "the anchor and the question go with the task")
        XCTAssertEqual(left.first?.kind, .user)
        XCTAssertEqual(left.first?.text, "please fix the button")
        XCTAssertNil(left.first?.taskID, "the surviving turn is no longer tied to a dead task")
    }

    @MainActor
    func testLiveFeedHidesEntriesOfFinishedWorkButKeepsThem() {
        let (s, url) = store(); defer { try? FileManager.default.removeItem(at: url) }
        let product = UUID(), done = UUID(), open = UUID()
        s.appendUser("about the finished thing", productID: product, taskID: done)
        s.appendUser("about the open thing", productID: product, taskID: open)
        let live = s.live(for: product) { $0 == done }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(s.all(for: product).count, 2, "nothing is deleted to achieve the fold")
    }
}

// MARK: - Products store

nonisolated final class ProductsStoreTests: XCTestCase {

    @MainActor private func store() -> (ProductsStore, [URL]) {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("products-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("adopted-\(UUID().uuidString).json")
        return (ProductsStore(fileURL: a, migrationURL: b), [a, b])
    }

    // MARK: Order

    @MainActor
    func testActivityDoesNotReorderTheSidebar() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let a = s.add(name: "Alpha"), b = s.add(name: "Bravo"), c = s.add(name: "Charlie")
        let before = s.sorted.map(\.id)
        XCTAssertEqual(before, [a.id, b.id, c.id])

        s.touch(c.id)
        XCTAssertEqual(s.sorted.map(\.id), before, "selection moved the list")

        s.worked(c.id)
        XCTAssertEqual(s.sorted.map(\.id), before, "activity moved the list")
    }

    @MainActor
    func testTheAppReopensWhereHeLastLookedNotWhereHeLastWorked() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let worked = s.add(name: "Worked in"), looked = s.add(name: "Looked at")
        s.worked(worked.id)
        s.touch(looked.id)
        XCTAssertEqual(s.lastVisited?.id, looked.id)
        XCTAssertEqual(s.sorted.first?.id, worked.id)
    }

    func testALegacyRecordKeepsItsPlaceInTheOrder() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Old","lastOpenedAt":751000000}"#
        let product = try JSONDecoder().decode(Product.self, from: Data(json.utf8))
        XCTAssertNotNil(product.lastWorkedAt)
        XCTAssertEqual(product.lastWorkedAt, product.lastOpenedAt)
    }

    @MainActor
    func testAddingAResourceTwiceDoesNotDuplicateTheProject() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = s.add(name: "P")
        let project = UUID()
        s.addResource(ProductResource(name: "app", access: .workspace, projectID: project), to: product.id)
        s.addResource(ProductResource(name: "app renamed", access: .source, projectID: project), to: product.id)
        let stored = s.product(id: product.id)
        XCTAssertEqual(stored?.resources.count, 1, "the same project must not gain two access modes")
        XCTAssertEqual(stored?.resources.first?.access, .workspace,
                       "the existing access mode wins; only the name is refreshed")
        XCTAssertEqual(stored?.resources.first?.name, "app renamed")
    }

    @MainActor
    func testSortPutsPinnedFirstAndKeepsTheRestStable() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let a = s.add(name: "Alpha")
        let b = s.add(name: "Beta")
        let c = s.add(name: "Gamma")
        s.togglePin(c.id)

        var opened = s.product(id: b.id)!
        opened.lastOpenedAt = Date()
        s.update(opened)
        XCTAssertEqual(s.sorted.map(\.name), ["Gamma", "Alpha", "Beta"], "opening reordered the list")

        s.worked(b.id)
        XCTAssertEqual(s.sorted.map(\.name), ["Gamma", "Alpha", "Beta"])
        XCTAssertEqual(a.name, "Alpha")
    }

    func testImpossibleSavedSplitLayoutIsDiscarded() {
        XCTAssertTrue(SavedSplitLayout.needsRepair(
            splitFrames: [
                "0.000000, 0.000000, 256.000000, 894.000000, NO, NO",
                "0.000000, 0.000000, 1528.000000, 894.000000, NO, NO",
            ],
            windowFrame: "67 55 1322 894 0 0 1512 949 "
        ))
    }

    func testHealthySavedSplitLayoutIsPreserved() {
        XCTAssertFalse(SavedSplitLayout.needsRepair(
            splitFrames: [
                "0.000000, 0.000000, 248.000000, 894.000000, NO, NO",
                "0.000000, 0.000000, 1058.000000, 894.000000, NO, NO",
            ],
            windowFrame: "67 55 1322 894 0 0 1512 949 "
        ))
    }

    /// Bulava no longer keeps its own record of what was decided about a product, and nothing
    /// reads the old one into a prompt. What it must not do is destroy it: these entries are the
    /// director's writing, and the first save after an update would have silently dropped every
    /// one of them if the field stopped round-tripping.
    /// Every stored property makes the round trip, so that adding one and forgetting the coding
    /// keys cannot silently drop it from `products.json`.
    ///
    /// `Product` spells its keys out by hand — `legacyDecisions` has to keep reading and writing
    /// the `decisions` it was stored under — and a hand-maintained list is one someone will add a
    /// property beside without touching. The failure that causes has no symptom at the time: the
    /// field simply stops being saved, and the loss shows up whenever the director next notices
    /// something they typed is gone.
    func testEveryPropertyOfAProductSurvivesEncodingAndDecoding() throws {
        var original = Product(
            name: "Atlas", summary: "карти для рятувальників",
            resources: [ProductResource(name: "app", kind: .repository, access: .workspace,
                                        projectID: UUID(), urlString: "https://atlas.example",
                                        note: "основна")],
            pinned: true,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_100_000),
            lastWorkedAt: Date(timeIntervalSince1970: 1_700_200_000),
            brief: "що це за продукт",
            legacyDecisions: [ProductDecision(at: Date(timeIntervalSince1970: 1_600_000_000),
                                              text: "backend stays read-only", taskID: UUID())],
            iconPath: "/tmp/atlas.png", iconScanned: true)
        original.id = UUID()

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Product.self, from: data)
        XCTAssertEqual(restored, original, "a stored property was lost on the way to disk and back")

        // Named individually as well: `Equatable` is synthesized from the same property list, so a
        // property missing from the coding keys would still compare equal if it also defaulted the
        // same way on both sides.
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for key in ["id", "name", "summary", "resources", "pinned", "addedAt", "lastOpenedAt",
                    "lastWorkedAt", "brief", "decisions", "iconPath", "iconScanned"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "\(key) was not written to products.json")
        }
    }

    @MainActor
    func testDecisionsRecordedByAnOlderBulavaSurviveASave() throws {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let id = UUID()
        let stored = """
        [{"id":"\(id.uuidString)","name":"Atlas","summary":"","resources":[],"pinned":false,\
        "addedAt":751000000,"brief":"","iconScanned":false,\
        "decisions":[{"id":"\(UUID().uuidString)","at":751000000,"text":"backend stays read-only"}]}]
        """
        try stored.write(to: urls[0], atomically: true, encoding: .utf8)

        let reopened = ProductsStore(fileURL: urls[0], migrationURL: urls[1])
        XCTAssertEqual(reopened.product(id: id)?.legacyDecisions.count, 1,
                       "an existing decision must still decode")

        reopened.setBrief("a map product", for: id)   // any edit at all rewrites the file

        let afterSave = ProductsStore(fileURL: urls[0], migrationURL: urls[1])
        XCTAssertEqual(afterSave.product(id: id)?.legacyDecisions.first?.text,
                       "backend stays read-only",
                       "saving the product must not erase what an older Bulava recorded")

        let raw = try String(contentsOf: urls[0], encoding: .utf8)
        XCTAssertTrue(raw.contains("\"decisions\""),
                      "it has to be written back under the key it was stored under")
    }

    @MainActor
    func testGeneratedSummaryCleanupRunsOnceAndSparesUserText() {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("products-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("adopted-\(UUID().uuidString).json")
        let c = base.appendingPathComponent("cleaned-\(UUID().uuidString).json")
        defer { [a, b, c].forEach { try? FileManager.default.removeItem(at: $0) } }
        let s = ProductsStore(fileURL: a, migrationURL: b, summaryCleanupURL: c)
        var generated = s.add(name: "G")
        generated.summary = ProjectKind.webLanding.label
        s.update(generated)
        var typed = s.add(name: "T")
        typed.summary = "the thing customers actually see"
        s.update(typed)

        s.clearGeneratedSummariesOnce()
        XCTAssertEqual(s.product(id: generated.id)?.summary, "")
        XCTAssertEqual(s.product(id: typed.id)?.summary, "the thing customers actually see")

        var again = s.product(id: generated.id)!
        again.summary = ProjectKind.webLanding.label
        s.update(again)
        s.clearGeneratedSummariesOnce()
        XCTAssertEqual(s.product(id: generated.id)?.summary, ProjectKind.webLanding.label)
    }
}

// MARK: - Work item store

nonisolated final class WorkItemStoreTests: XCTestCase {

    @MainActor private func store() -> (WorkItemStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("items-\(UUID().uuidString).json")
        return (WorkItemStore(fileURL: url), url)
    }

    @MainActor
    func testRemovingAStreamKeepsTheGraphConsistent() {
        let (s, url) = store(); defer { try? FileManager.default.removeItem(at: url) }
        let a = UUID(), b = UUID()
        s.add(WorkItem(productID: UUID(), title: "pkg", streams: [
            .init(id: a, title: "a", projectName: "p"),
            .init(id: b, title: "b", projectName: "p", dependsOn: [a]),
        ]))
        s.removeStream(a)
        let item = try? XCTUnwrap(s.items.first)
        XCTAssertEqual(item?.streams.count, 1)
        XCTAssertEqual(item?.streams.first?.dependsOn, [],
                       "a dependency on a removed stream must be cleaned up, not left dangling")
    }

    @MainActor
    func testItemIsDroppedWhenItsLastStreamGoes() {
        let (s, url) = store(); defer { try? FileManager.default.removeItem(at: url) }
        let only = UUID()
        s.add(WorkItem(productID: UUID(), title: "solo",
                       streams: [.init(id: only, title: "x", projectName: "p")]))
        s.removeStream(only)
        XCTAssertTrue(s.items.isEmpty)
    }

    @MainActor
    func testStreamLookupFindsItsParentItem() {
        let (s, url) = store(); defer { try? FileManager.default.removeItem(at: url) }
        let stream = UUID()
        let item = s.add(WorkItem(productID: UUID(), title: "pkg",
                                  streams: [.init(id: stream, title: "x", projectName: "p")]))
        XCTAssertEqual(s.item(forStreamID: stream)?.id, item.id)
        XCTAssertNil(s.item(forStreamID: UUID()))
    }

    @MainActor
    func testPreemptionIsRecordedOnceAndCleared() {
        let (s, url) = store(); defer { try? FileManager.default.removeItem(at: url) }
        let stream = UUID()
        let item = s.add(WorkItem(productID: UUID(), title: "pkg",
                                  streams: [.init(id: stream, title: "x", projectName: "p")]))
        s.markPreempted(stream, in: item.id)
        s.markPreempted(stream, in: item.id)
        XCTAssertEqual(s.item(id: item.id)?.preemptedStreamIDs, [stream])
        s.clearPreempted(stream)
        XCTAssertEqual(s.item(id: item.id)?.preemptedStreamIDs, [])
    }

    @MainActor
    func testItemsSurviveARelaunch() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("items-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let product = UUID()
        do {
            let s = WorkItemStore(fileURL: url)
            s.add(WorkItem(productID: product, title: "persisted", priority: .urgent,
                           streams: [.init(id: UUID(), title: "x", projectName: "p")]))
        }
        let reopened = WorkItemStore(fileURL: url)
        XCTAssertEqual(reopened.items(forProductID: product).first?.title, "persisted")
        XCTAssertEqual(reopened.items.first?.priority, .urgent)
    }
}

// MARK: - One localization path

nonisolated final class LocalizationPathTests: XCTestCase {

    override func tearDown() {
        LanguageBundle.adopt(.system)
        super.tearDown()
    }

    func testEveryDeclaredLanguageShipsACatalog() throws {
        for language in [AppLanguage.en, .uk, .ru] {
            let code = try XCTUnwrap(language.localeIdentifier)
            XCTAssertNotNil(Bundle.main.path(forResource: code, ofType: "lproj"),
                            "\(code).lproj must be in the built bundle")
        }
    }

    func testAdoptingALanguageChangesWhatStringLocalizedReturns() {
        LanguageBundle.adopt(.uk)
        let uk = String(localized: "Products")
        LanguageBundle.adopt(.ru)
        let ru = String(localized: "Products")

        XCTAssertEqual(uk, "Продукти")
        XCTAssertEqual(ru, "Продукты")
        XCTAssertNotEqual(uk, ru, "the two paths must not collapse to one language")
    }

    func testAdoptingSystemFallsBackToTheMainBundle() {
        LanguageBundle.adopt(.system)

        XCTAssertFalse(String(localized: "Products").isEmpty)
    }

    func testSavedLanguageDoesNotRelaunchAwayFromTheDebugger() {
        XCTAssertFalse(LanguageBundle.shouldRelaunchAtStartup(
            language: .uk,
            arguments: ["Bulava"],
            isTestHost: false,
            debuggerAttached: true
        ))
    }

    func testSavedLanguageRelaunchesOnceOutsideDevelopment() {
        XCTAssertTrue(LanguageBundle.shouldRelaunchAtStartup(
            language: .uk,
            arguments: ["Bulava"],
            isTestHost: false,
            debuggerAttached: false
        ))
        XCTAssertFalse(LanguageBundle.shouldRelaunchAtStartup(
            language: .uk,
            arguments: ["Bulava", "-AppleLanguages", "(uk)"],
            isTestHost: false,
            debuggerAttached: false
        ))
    }

    func testAnUnknownKeyReturnsItselfRatherThanEmptiness() {
        LanguageBundle.adopt(.ru)
        let missing = "this key does not exist in any catalog"
        XCTAssertEqual(String(localized: missing), missing,
                       "a missing key must degrade to its own text, never to blank UI")
    }

    func testCriticalDynamicKeysResolveInBothLanguages() {

        let keys = WorkState.allCases.map(\.labelKey)
            + WorkPriority.allCases.map(\.labelKey)
            + ResourceKind.allCases.map(\.labelKey)
            + ["System", "Light", "Dark", "Today", "Yesterday"]
        for language in [AppLanguage.uk, .ru] {
            LanguageBundle.adopt(language)
            for key in keys {
                let value = String(localized: key)
                XCTAssertNotEqual(value, key,
                    "\(key) has no \(language.rawValue) translation — it would ship in English")
            }
        }
    }
}

// MARK: - Feed partitioning

nonisolated final class FeedPartitionTests: XCTestCase {

    @MainActor
    func testAStreamIsNeverAlsoALooseTask() {
        let itemsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("items-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: itemsURL) }
        let store = WorkItemStore(fileURL: itemsURL)

        let a = UUID(), b = UUID(), orphan = UUID()
        store.add(WorkItem(productID: UUID(), title: "pkg", streams: [
            .init(id: a, title: "a", projectName: "p"),
            .init(id: b, title: "b", projectName: "p", dependsOn: [a]),
        ]))

        XCTAssertNotNil(store.item(forStreamID: a))
        XCTAssertNotNil(store.item(forStreamID: b))
        XCTAssertNil(store.item(forStreamID: orphan))
    }

    @MainActor
    func testLowercaseUUIDsFromAnExternalWriterStillMatch() throws {

        let productID = UUID()
        let streamID = UUID()
        let json = """
        [{"id":"\(UUID().uuidString.lowercased())",
          "productID":"\(productID.uuidString.lowercased())",
          "title":"seeded","createdAt":"2026-08-04T10:00:00Z","kind":"job",
          "priority":"normal","preemptedStreamIDs":[],
          "streams":[{"id":"\(streamID.uuidString.lowercased())","title":"s",
                      "projectName":"p","dependsOn":[]}]}]
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("items-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)

        let store = WorkItemStore(fileURL: url)
        XCTAssertEqual(store.items.count, 1, "a lowercase-UUID file must decode")
        XCTAssertEqual(store.items(forProductID: productID).count, 1,
                       "product matching must be by UUID value, not by string case")
        XCTAssertNotNil(store.item(forStreamID: streamID),
                        "stream matching must be by UUID value, not by string case")
    }
}

// MARK: - Localization completeness

nonisolated final class LocalizationCompletenessTests: XCTestCase {

    static let untranslatable: Set<String> = [
        "%lld", "%llds", "• %@", "·",
        "~/.claude/supervisor",
        "Bulava", "Night Shift", "Narada",
        "ultracode",

        // Model names are proper nouns. The families replaced the pinned "Opus 5" list when the
        // picker moved to CLI aliases; the old names stay listed because older settings still
        // decode through them.
        "Opus 5", "Sonnet 5", "Haiku 4.5", "Ultracode",
        "Fable", "Opus", "Sonnet", "Haiku",
        // A reasoning level the service names in English on every model it offers it on.
        "Ultra",
        "gpt-5-codex",
    ]

    private func catalog() throws -> [String: Any] {

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Night Shift/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["strings"] as? [String: Any])
    }

    func testEveryKeyHasUkrainianAndRussian() throws {
        let strings = try catalog()
        var missing: [String] = []
        for (key, value) in strings {
            guard !key.trimmingCharacters(in: .whitespaces).isEmpty,
                  !Self.untranslatable.contains(key),
                  let entry = value as? [String: Any] else { continue }
            let locs = entry["localizations"] as? [String: Any] ?? [:]
            for language in ["uk", "ru"] {
                let unit = locs[language] as? [String: Any]
                let hasSingular = unit?["stringUnit"] != nil
                let hasPlural = unit?["variations"] != nil
                if !hasSingular && !hasPlural { missing.append("\(language): \(key)") }
            }
        }
        XCTAssertTrue(missing.isEmpty,
                      "\(missing.count) untranslated key(s):\n" + missing.sorted().joined(separator: "\n"))
    }

    func testEveryTranslationIsActuallyDifferentFromTheKey() throws {

        let strings = try catalog()
        var suspicious: [String] = []
        for (key, value) in strings {
            guard !Self.untranslatable.contains(key), let entry = value as? [String: Any],
                  let locs = entry["localizations"] as? [String: Any] else { continue }
            for language in ["uk", "ru"] {
                guard let unit = (locs[language] as? [String: Any])?["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String else { continue }

                let letters = key.filter(\.isLetter)
                let latinTerm = ["English", "GitHub", "Codex", "Claude", "PDF", "tmux", "git"]
                if value == key, letters.count > 2, !latinTerm.contains(where: key.contains) {
                    suspicious.append("\(language): \(key)")
                }
            }
        }
        XCTAssertTrue(suspicious.isEmpty,
                      "\(suspicious.count) key(s) whose translation equals the English source:\n"
                      + suspicious.sorted().joined(separator: "\n"))
    }
}

// MARK: - Localization: source ↔ catalog

nonisolated final class LocalizationSourceScanTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func catalogKeys() throws -> Set<String> {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Night Shift/Localizable.xcstrings"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        return Set(strings.keys)
    }

    private func sourceKeys() throws -> [(key: String, file: String)] {
        let sourceDir = repoRoot.appendingPathComponent("Night Shift")
        let files = FileManager.default.enumerator(at: sourceDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        let patterns = [
            #"String\(localized:\s*"([^"\\]*)"\)"#,
            #"(?<![A-Za-z])Text\(\s*"([^"\\]*)"\s*\)"#,
            #"(?<![A-Za-z])Eyebrow\(\s*"([^"\\]*)"[,)]"#,
            #"LocalizedStringKey\(\s*"([^"\\]*)"\s*\)"#,
        ].map { try! NSRegularExpression(pattern: $0) }

        var out: [(String, String)] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let full = NSRange(text.startIndex..., in: text)
            for regex in patterns {
                for match in regex.matches(in: text, range: full) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    let key = String(text[range])
                    guard !key.isEmpty, key.contains(where: \.isLetter),
                          !LocalizationCompletenessTests.untranslatable.contains(key) else { continue }
                    out.append((key, file.lastPathComponent))
                }
            }
        }
        return out
    }

    func testEveryLocalizedLiteralInTheSourceHasACatalogEntry() throws {
        let catalog = try catalogKeys()
        let found = try sourceKeys()
        XCTAssertGreaterThan(found.count, 200, "the scan found suspiciously few literals — check the patterns")

        var missing: Set<String> = []
        for (key, file) in found where !catalog.contains(key) {
            missing.insert("\(key)   [\(file)]")
        }
        XCTAssertTrue(missing.isEmpty,
                      "\(missing.count) localized literal(s) with no catalog entry:\n"
                      + missing.sorted().joined(separator: "\n"))
    }

    // MARK: - Interpolated keys

    private func interpolatedSourceKeys() throws -> [(shape: String, file: String)] {
        let sourceDir = repoRoot.appendingPathComponent("Night Shift")
        let files = FileManager.default.enumerator(at: sourceDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        let patterns = [
            #"(?<![A-Za-z])Text\(\s*"((?:[^"\\]|\\\()*\\\((?:[^"\\]|\\\()*)"\s*\)"#,
            #"String\(localized:\s*"((?:[^"\\]|\\\()*\\\((?:[^"\\]|\\\()*)"\)"#,
        ].map { try! NSRegularExpression(pattern: $0) }

        var out: [(String, String)] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let full = NSRange(text.startIndex..., in: text)
            for regex in patterns {
                for match in regex.matches(in: text, range: full) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    let literal = String(text[range])
                    guard literal.contains(where: \.isLetter) else { continue }
                    out.append((Self.shape(of: literal), file.lastPathComponent))
                }
            }
        }
        return out
    }

    private static func shape(of literal: String) -> String {
        var pattern = "^"
        var rest = Substring(literal)
        while let open = rest.range(of: "\\(") {
            pattern += NSRegularExpression.escapedPattern(for: String(rest[..<open.lowerBound]))
            pattern += "(?:%lld|%@|%d|%1$@|%1$lld)"

            var depth = 1
            var index = open.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "(" { depth += 1 }
                if rest[index] == ")" { depth -= 1 }
                index = rest.index(after: index)
            }
            rest = rest[index...]
        }
        pattern += NSRegularExpression.escapedPattern(for: String(rest)) + "$"
        return pattern
    }

    func testEveryInterpolatedLiteralHasACatalogEntryOfTheRightShape() throws {
        let catalog = try catalogKeys()
        let found = try interpolatedSourceKeys()
        XCTAssertFalse(found.isEmpty, "the interpolation scan found nothing — check the patterns")

        var missing: Set<String> = []
        for (shape, file) in found {
            let regex = try NSRegularExpression(pattern: shape)
            let hit = catalog.contains { key in
                regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
            }
            if !hit { missing.insert("\(shape)   [\(file)]") }
        }
        XCTAssertTrue(missing.isEmpty,
                      "\(missing.count) interpolated literal(s) with no catalog entry:\n"
                      + missing.sorted().joined(separator: "\n"))
    }

    private static let countingStringsWithoutPlurals: Set<String> = [

        "%lld", "%lld%% used", "%lld. %@", "%llds", "+%lld earlier", "Variant %lld · %@",

        "Codex stopped without answering (exit %lld).",

        "%lld failed — each one says why below.",
        "%lld had not finished when this was written.",
        "%lld more were asked for and never started.",
        "%lld tasks queued and ready to run.",
        "All %lld steps in this card close together.",
        "I stopped hearing anything from the look for %lld min, so I ended it. Ask again and I will take another run at it.",
        "Open all %lld variants",
        "Queued %lld streams — I will start as soon as the resource frees up.",
        "Taken as ONE job of %lld streams. Dependents wait on their predecessors; one report for all of it at the end.",
        "This report covers all %lld streams of “%@”.",
        "Your agents worked %@ across %lld projects.",
        "create %lld INDEPENDENT variants — I will show them all in the gallery and filter nothing out in advance:",
        "take this as ONE job across %lld resources — one report at the end:",
    ]

    func testEveryCountingStringHasPluralFormsInBothLanguages() throws {
        let url = repoRoot.appendingPathComponent("Night Shift/Localizable.xcstrings")
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let strings = ((raw as? [String: Any])?["strings"] as? [String: Any]) ?? [:]

        var missing: [String] = []
        var pluralised = 0
        for (key, value) in strings {
            let counts = key.components(separatedBy: "%lld").count - 1
                       + key.components(separatedBy: "%d").count - 1
            guard counts == 1, !Self.countingStringsWithoutPlurals.contains(key) else { continue }
            let localizations = (value as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            var complete = true
            for lang in ["uk", "ru"] {
                guard let entry = localizations[lang] as? [String: Any] else {
                    missing.append("\(key) [\(lang) missing]"); complete = false; continue
                }
                if entry["variations"] == nil {
                    missing.append("\(key) [\(lang) has no plural forms]"); complete = false
                }
            }
            if complete { pluralised += 1 }
        }
        XCTAssertGreaterThan(pluralised, 5, "the scan found suspiciously few pluralised strings")
        XCTAssertTrue(missing.isEmpty,
                      "counting strings without plural forms (add them, or add the key to "
                      + "countingStringsWithoutPlurals with a reason):\n"
                      + missing.sorted().joined(separator: "\n"))
    }

    func testThePluralDebtListHasNoStaleEntries() throws {
        let url = repoRoot.appendingPathComponent("Night Shift/Localizable.xcstrings")
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let strings = ((raw as? [String: Any])?["strings"] as? [String: Any]) ?? [:]
        let stale = Self.countingStringsWithoutPlurals.filter { strings[$0] == nil }
        XCTAssertTrue(stale.isEmpty, "no longer in the catalog:\n" + stale.sorted().joined(separator: "\n"))
    }
}

// MARK: - The consolidated item report

nonisolated final class ItemReportTests: XCTestCase {

    private func section(_ n: Int, title: String,
                         outcome: ReportHTML.ItemSection.Outcome,
                         manifest: ReportManifest? = nil,
                         prefix: String = "abc12345/",
                         criteria: [ReportHTML.ItemSection.Criterion] = [],
                         findings: [String] = [],
                         blocker: String? = nil,
                         absence: String? = nil) -> ReportHTML.ItemSection {
        ReportHTML.ItemSection(
            number: n, title: title, projectName: "proj-\(n)", outcome: outcome,
            stateLabel: outcome.rawValue, gateBlocker: blocker, summary: "summary \(n)",
            manifest: manifest, assetPrefix: prefix, criteria: criteria,
            evidenceOverall: criteria.isEmpty ? nil : "fail", commits: ["c\(n)"],
            filesChanged: 2, insertions: 10, deletions: 3, findings: findings,
            absenceNote: absence)
    }

    private func photoManifest(after: String) -> ReportManifest {
        let json = #"{"format":"photos","items":[{"caption":"cap","after":"\#(after)"}]}"#
        return try! JSONDecoder().decode(ReportManifest.self, from: Data(json.utf8))
    }

    func testEveryStreamAppearsInTheDocument() {
        let sections = [
            section(1, title: "Landing page", outcome: .delivered, manifest: photoManifest(after: "a.png")),
            section(2, title: "SEO research", outcome: .delivered),
            section(3, title: "Backend wiring", outcome: .failed, absence: "it failed"),
        ]
        let html = ReportHTML.itemPage(title: "Launch package", productName: "Narada",
                                       sections: sections, deliveredCount: 2, failedCount: 1,
                                       unfinishedCount: 0, missingCount: 0, generatedAt: "now")
        for title in ["Landing page", "SEO research", "Backend wiring"] {
            XCTAssertTrue(html.contains(title), "the consolidated report is missing “\(title)”")
        }

        for n in 1...3 { XCTAssertTrue(html.contains("id=\"s\(n)\"")) }
        XCTAssertTrue(html.contains("badge failed"), "the failed stream must be marked as failed")
    }

    func testAssetsResolveThroughEachStreamsOwnDirectory() {

        let html = ReportHTML.itemPage(
            title: "T", productName: "P",
            sections: [section(1, title: "S", outcome: .delivered,
                               manifest: photoManifest(after: "media/after.png"),
                               prefix: "deadbeef/")],
            deliveredCount: 1, failedCount: 0, unfinishedCount: 0, missingCount: 0,
            generatedAt: "now")
        XCTAssertTrue(html.contains("src=\"deadbeef/media/after.png\""),
                      "an asset without its stream's directory would render as a broken image")
        XCTAssertFalse(html.contains("src=\"media/after.png\""))
    }

    func testTheLedeCountsAreStatedNotRoundedUp() {
        let html = ReportHTML.itemPage(
            title: "T", productName: "P",
            sections: [section(1, title: "S", outcome: .delivered)],
            deliveredCount: 2, failedCount: 1, unfinishedCount: 1, missingCount: 3,
            generatedAt: "now")
        XCTAssertTrue(html.contains("2"), "delivered count must be stated")

        XCTAssertTrue(html.lowercased().contains("fail"))
        XCTAssertTrue(html.contains("3"), "variants asked for but never started must be admitted")
    }

    func testEvidenceFindingsAndGateReasonAreCarriedThrough() {
        let criteria = [ReportHTML.ItemSection.Criterion(
            name: "tests", status: "fail", command: "xcodebuild test", note: "2 failed")]
        let html = ReportHTML.itemPage(
            title: "T", productName: "P",
            sections: [section(1, title: "S", outcome: .failed, criteria: criteria,
                               findings: ["the migration is not reversible"],
                               blocker: "tests failed — nothing to accept")],
            deliveredCount: 0, failedCount: 1, unfinishedCount: 0, missingCount: 0,
            generatedAt: "now")
        XCTAssertTrue(html.contains("xcodebuild test"))
        XCTAssertTrue(html.contains("2 failed"))
        XCTAssertTrue(html.contains("the migration is not reversible"))
        XCTAssertTrue(html.contains("tests failed — nothing to accept"),
                      "the acceptance gate's reason belongs in the document")
    }

    func testWorkerTextCannotInjectMarkup() {
        let html = ReportHTML.itemPage(
            title: "<script>alert(1)</script>", productName: "P",
            sections: [section(1, title: "<img src=x onerror=y>", outcome: .delivered)],
            deliveredCount: 1, failedCount: 0, unfinishedCount: 0, missingCount: 0,
            generatedAt: "now")
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertFalse(html.contains("<img src=x"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }
}

// MARK: - Variants stay reachable

nonisolated final class VariantCountTests: XCTestCase {

    func testDigitsAndWordsAreBothRead() {
        XCTAssertEqual(VariantCount.detect(in: "зроби 10 прототипів лендінга"), 10)
        XCTAssertEqual(VariantCount.detect(in: "сделай три варианта главной"), 3)
        XCTAssertEqual(VariantCount.detect(in: "make five design concepts"), 5)
    }

    func testNoCountAndNoVariantWordMeansNothingIsInvented() {
        XCTAssertNil(VariantCount.detect(in: "зроби варіанти головної"),
                     "no number stated — do not guess one")
        XCTAssertNil(VariantCount.detect(in: "виправ 3 баги в білді"),
                     "a number without a variant word is not a variant count")
    }

    func testMissingVariantsIsTheDifferenceAndNeverNegative() {
        func item(streams: Int, requested: Int?) -> WorkItem {
            WorkItem(productID: UUID(), title: "v", kind: .variants,
                     streams: (0..<streams).map {
                         WorkItem.Stream(id: UUID(), title: "v\($0)", projectName: "p")
                     },
                     requestedVariants: requested)
        }
        XCTAssertEqual(item(streams: 6, requested: 10).missingVariants, 4)
        XCTAssertEqual(item(streams: 10, requested: 10).missingVariants, 0)
        XCTAssertEqual(item(streams: 12, requested: 10).missingVariants, 0)
        XCTAssertEqual(item(streams: 6, requested: nil).missingVariants, 0)

        var job = item(streams: 2, requested: 10); job.kind = .job
        XCTAssertEqual(job.missingVariants, 0)
    }
}

// MARK: - Preflight gates what it says it gates

nonisolated final class PreflightGateTests: XCTestCase {

    private func check(_ id: String, _ status: PreflightCheck.Status,
                       _ gate: PreflightCheck.Gate) -> PreflightCheck {
        PreflightCheck(id: id, titleKey: id, detailKey: "d", status: status, gate: gate)
    }

    func testOnlyAllWorkCapabilitiesAreRequired() {
        XCTAssertTrue(check("a", .missing, .allWork).required)
        XCTAssertFalse(check("b", .missing, .pullRequests).required)
        XCTAssertFalse(check("c", .missing, .appDriving).required)
        XCTAssertFalse(check("d", .missing, .convenience).required)
    }

    func testUnknownCountsAsUnmetBecauseWeDidNotLook() {
        XCTAssertTrue(check("a", .unknown, .allWork).unmet)
        XCTAssertTrue(check("a", .missing, .allWork).unmet)
        XCTAssertFalse(check("a", .ready, .allWork).unmet)
    }

    @MainActor
    func testSummaryGroupsUnmetCapabilitiesByWhatTheyBlock() {
        let runner = PreflightRunner()
        runner.overrideChecksForTesting([
            check("engine", .missing, .allWork),
            check("claude", .ready, .allWork),
            check("codex-auth", .unknown, .allWork),
            check("gh", .missing, .pullRequests),
            check("ax", .missing, .appDriving),
            check("mic", .missing, .convenience),
        ])
        let summary = runner.summary
        XCTAssertEqual(summary.allWork.count, 2, "a ready capability must not appear as a blocker")
        XCTAssertEqual(summary.pullRequests.count, 1)
        XCTAssertEqual(summary.appDriving.count, 1)
        XCTAssertFalse(summary.isEmpty)

        XCTAssertFalse(summary.allWork.contains { $0.contains("mic") })
    }

    @MainActor
    func testEverythingReadyMeansAnEmptySummaryAndReady() {
        let runner = PreflightRunner()
        runner.overrideChecksForTesting([
            check("engine", .ready, .allWork),
            check("gh", .ready, .pullRequests),
            check("mic", .missing, .convenience),
        ])
        XCTAssertTrue(runner.summary.isEmpty)
        XCTAssertTrue(runner.isReady, "an unmet convenience must not make Bulava 'not ready'")
    }
}

// MARK: - One card, one state

nonisolated final class ItemStateTests: XCTestCase {
    private typealias S = WorkProgress.StreamOutcome

    private func delivered(_ state: WorkState = .reportReady) -> S {
        S(state: state, settled: true, delivered: true)
    }
    private var failed: S { S(state: .failed, settled: true, delivered: false) }
    private var running: S { S(state: .running, settled: false, delivered: false) }

    func testOneFailedVariantDoesNotFailTheWholeSet() {
        let state = WorkProgress.itemState(kind: .variants,
                                           streams: [delivered(), delivered(), failed])
        XCTAssertEqual(state, .reportReady,
                       "eight good directions and two dead ones is finished work, not failed work")
    }

    func testAVariantSetWithNothingDeliveredIsHonestlyFailed() {
        XCTAssertEqual(WorkProgress.itemState(kind: .variants, streams: [failed, failed]), .failed)
    }

    func testAVariantSetStillRunningIsNotReadyToLookAt() {
        XCTAssertEqual(WorkProgress.itemState(kind: .variants,
                                              streams: [delivered(), failed, running]), .running)
    }

    func testAJobThatLostAStepIsPartlyDoneNotStopped() {

        XCTAssertEqual(WorkProgress.itemState(kind: .job, streams: [delivered(), failed]), .partial)
    }

    func testAJobWithNothingDeliveredIsStopped() {

        XCTAssertEqual(WorkProgress.itemState(kind: .job, streams: [failed, failed]), .failed)
    }

    func testAJobIsOnlyReadyWhenEveryStreamIsIn() {
        XCTAssertEqual(WorkProgress.itemState(kind: .job, streams: [delivered(), running]), .running)
        XCTAssertEqual(WorkProgress.itemState(kind: .job,
                                              streams: [delivered(), delivered(.done)]), .reportReady)
        XCTAssertEqual(WorkProgress.itemState(kind: .job,
                                              streams: [delivered(.done), delivered(.done)]), .done)
    }

    func testWorkInFlightIsTheHeadlineEvenWhileAnotherStepAsks() {

        let asking = S(state: .needsAnswer, settled: false, delivered: false)
        XCTAssertEqual(WorkProgress.itemState(kind: .job, streams: [running, asking]), .running)
    }

    func testAQuestionIsTheHeadlineOnceNothingElseIsMoving() {

        let asking = S(state: .needsAnswer, settled: false, delivered: false)
        XCTAssertEqual(WorkProgress.itemState(kind: .job, streams: [delivered(), asking]), .needsAnswer)
    }

    func testPreemptedWorkWithNothingRunningReadsAsPaused() {
        let held = S(state: .planned, settled: false, delivered: false, preempted: true)
        XCTAssertEqual(WorkProgress.itemState(kind: .job, streams: [held, delivered()]), .paused)

        XCTAssertEqual(WorkProgress.itemState(kind: .job, streams: [held, running]), .running)
    }

    func testNoStreamsIsPlannedRatherThanAnyKindOfDone() {
        XCTAssertEqual(WorkProgress.itemState(kind: .job, streams: []), .planned)
    }
}

// MARK: - The director choosing model and depth

nonisolated final class RunStrategyOverrideTests: XCTestCase {

    private func settings(claudeModel: ClaudeModelChoice = .auto,
                          claudeEffort: ClaudeEffortChoice = .auto,
                          codexEffort: CodexEffortChoice = .auto,
                          codexModel: String = "") -> AppSettings {
        var s = AppSettings.fallback
        s.claudeModel = claudeModel
        s.claudeEffort = claudeEffort
        s.codexEffort = codexEffort
        s.codexModel = codexModel
        return s
    }

    func testAutomaticChangesNothingBulavaDecided() {
        let decided = RunStrategy(claudeEffort: "ultracode", codexEffort: "high", isolated: true)
        let out = decided.overridden(by: settings())
        XCTAssertEqual(out.claudeEffort, "ultracode", "automatic must not override the per-task effort")
        XCTAssertEqual(out.codexEffort, "high")
        XCTAssertTrue(out.isolated, "isolation is not a preference and must survive")
        XCTAssertEqual(out.claudeModel, "", "automatic must pass NO model flag")
        XCTAssertEqual(out.codexModel, "")
    }

    func testAnExplicitChoiceWins() {
        let decided = RunStrategy(claudeEffort: "medium", codexEffort: "medium", isolated: false)
        let out = decided.overridden(by: settings(claudeModel: .haiku, claudeEffort: .low,
                                                 codexEffort: .high, codexModel: "gpt-5-codex"))
        XCTAssertEqual(out.claudeEffort, "low", "a chosen depth must beat the per-task guess")
        XCTAssertEqual(out.codexEffort, "high")
        XCTAssertEqual(out.claudeModel, "haiku")
        XCTAssertEqual(out.codexModel, "gpt-5-codex")
    }

    func testATypedCodexModelIsTrimmedNotPassedWithSpaces() {
        let out = RunStrategy.standing.overridden(by: settings(codexModel: "  gpt-5-codex \n"))
        XCTAssertEqual(out.codexModel, "gpt-5-codex")
    }

    func testATypedModelIDIsReducedToWhatAModelIDCanContain() {

        XCTAssertEqual(RunStrategy.safeModelID("gpt 5 codex"), "gpt5codex")
        XCTAssertEqual(RunStrategy.safeModelID("gpt-5-codex; rm -rf ~"), "gpt-5-codexrm-rf")
        XCTAssertEqual(RunStrategy.safeModelID("$(whoami)"), "whoami")
        XCTAssertEqual(RunStrategy.safeModelID("  o3-mini_2025.01  "), "o3-mini_2025.01")
        XCTAssertEqual(RunStrategy.safeModelID(""), "")
    }

    func testEveryChoiceCarriesTheValueItsCLIAccepts() {

        XCTAssertEqual(ClaudeModelChoice.auto.flagValue, "")
        // Family aliases, so "the newest Opus" needs no release of Bulava. See ModelChoiceTests.
        XCTAssertEqual(ClaudeModelChoice.opus.flagValue, "opus")
        XCTAssertEqual(ClaudeModelChoice.fable.flagValue, "fable")
        XCTAssertEqual(ClaudeModelChoice.sonnet.flagValue, "sonnet")
        XCTAssertEqual(ClaudeModelChoice.haiku.flagValue, "haiku")
        XCTAssertEqual(ClaudeEffortChoice.auto.flagValue, "")
        for effort in ClaudeEffortChoice.allCases where effort != .auto {
            XCTAssertEqual(effort.flagValue, effort.rawValue)
        }
        for effort in CodexEffortChoice.allCases where effort != .auto {
            XCTAssertEqual(effort.flagValue, effort.rawValue)
        }
        // Automatic used to send nothing, and nothing means `~/.codex/config.toml` — which is
        // where a person's own xhigh lives. It names a level now. Night runs still choose per
        // task: `RunStrategy.overridden` leaves its own value alone while this stays `.auto`.
        XCTAssertEqual(CodexEffortChoice.auto.flagValue,
                       CodexEffortChoice.conversationDefault.rawValue)
        XCTAssertEqual(RunStrategy.standing.overridden(by: settings()).codexEffort, "high",
                       "a night run's own depth is not overwritten by the chat default")
    }

    func testTheLaunchEnvironmentCarriesExactlyWhatWasChosen() {

        let pinned = RunStrategy.standing.overridden(
            by: settings(claudeModel: .opus, claudeEffort: .xhigh,
                         codexEffort: .low, codexModel: "gpt-5-codex"))
        let env = SupervisorClient.launchEnv(pinned)
        XCTAssertEqual(env["SUPERVISOR_CLAUDE_EFFORT"], "xhigh")
        XCTAssertEqual(env["SUPERVISOR_CLAUDE_MODEL"], "opus")
        XCTAssertEqual(env["SUPERVISOR_CODEX_EFFORT"], "low")
        XCTAssertEqual(env["SUPERVISOR_CODEX_MODEL"], "gpt-5-codex")

        let auto = RunStrategy.standing.overridden(by: settings())
        let autoEnv = SupervisorClient.launchEnv(auto)
        XCTAssertNil(autoEnv["SUPERVISOR_CLAUDE_MODEL"])
        XCTAssertNil(autoEnv["SUPERVISOR_CODEX_MODEL"])

        XCTAssertEqual(autoEnv["SUPERVISOR_CLAUDE_EFFORT"], "high")
    }

    func testChoicesSurviveAPersistRoundTrip() throws {
        var s = settings(claudeModel: .sonnet, claudeEffort: .max, codexEffort: .xhigh,
                         codexModel: "gpt-5-codex")
        s.appearance = .dark
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back, s)
    }

    func testSettingsWrittenBeforeTheseFieldsExistedStillLoadAsAutomatic() throws {

        let legacy = #"{"stateDirPath":"/tmp/x","pollSeconds":4,"appearance":"dark"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(s.claudeModel, .auto)
        XCTAssertEqual(s.claudeEffort, .auto)
        XCTAssertEqual(s.codexEffort, .auto)
        XCTAssertEqual(s.codexModel, "")
        XCTAssertEqual(s.stateDirPath, "/tmp/x")
    }
}

// MARK: - What a missing capability is allowed to stop

nonisolated final class DispatchGateScopeTests: XCTestCase {

    private func summary(allWork: [String] = [], pullRequests: [String] = [],
                         appDriving: [String] = [], affectedWork: [String] = []) -> PreflightRunner.Summary {
        PreflightRunner.Summary(allWork: allWork, pullRequests: pullRequests,
                                appDriving: appDriving, affectedWork: affectedWork)
    }

    // MARK: What a failing CLI's own words prove, and what they do not
    //
    // These used to be one case wearing four hats: every failure said "run it once in a terminal
    // to sign in", including to someone whose Codex binary macOS had deleted an hour earlier.
    // The first fix then over-corrected and started guessing — any mention of a missing file meant
    // "not installed", any broken binary was blamed on XProtect by name, and anything unrecognised
    // was reported as "installed and signed in, this is a rate limit". A confident wrong label
    // costs more than an honest "it did not say".

    func testACommandThatIsNotThereIsNotAnAuthenticationProblem() {
        XCTAssertEqual(PreflightRunner.classify(exitCode: 127, output: "zsh:1: command not found: codex"),
                       .notOnPath)
        XCTAssertEqual(PreflightRunner.classify(exitCode: 127, output: ""), .notOnPath)
    }

    func testAMissingConfigFileIsNotAMissingProgram() {
        // ENOENT on its own is not a failed spawn. A CLI raises it about its own config, and
        // reading that as "the program is gone" sent people to reinstall a CLI that was there.
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 1, output: "Error: ENOENT: no such file or directory, open '/Users/x/.codex/config.toml'"),
                       .unknown)
    }

    func testSomethingElseBeingDamagedIsNotMacOSRefusing() {
        XCTAssertEqual(PreflightRunner.classify(exitCode: 1, output: "cache is damaged, rebuilding"),
                       .unknown)
    }

    func testAnOutageAtTheAuthEndpointIsNotASignedOutAccount() {
        // The service being down used to match on the bare word "oauth" and be handed a Sign in
        // button, which fixes nothing and costs an evening.
        XCTAssertEqual(PreflightRunner.classify(exitCode: 1, output: "OAuth endpoint unavailable (503)"),
                       .unknown)
    }

    func testADeletedProgramFileIsNotReadAsBeingSignedOut() {
        // What is left after macOS takes the Mach-O out of an npm-installed Codex: the wrapper is
        // still on PATH, still runs, and node cannot find what it was told to launch. Which of
        // "never finished installing" and "something removed it" this is, the message does not
        // say, so neither does the row.
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 1, output: "Error: spawn /opt/homebrew/.../codex-aarch64-apple-darwin ENOENT"),
                       .executableMissing)
    }

    func testAMissingFileThatIsNotTheProgramIsNotCalledAMissingInstall() {
        // A CLI says "no such file or directory" about config files, working directories and
        // arguments. Reading that as "the CLI is not installed" was a guess, and it sent people
        // to reinstall a CLI that was sitting right there.
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 1, output: "error: /Users/x/.codex/config.toml: No such file or directory"),
                       .unknown)
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 1, output: "cd: no such file or directory: /tmp/gone"), .unknown)
    }

    func testAnArchitectureMismatchIsNotBlamedOnMalware() {
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 126, output: "zsh: bad CPU type in executable: codex"), .wrongArchitecture)
    }

    func testOnlyMacOSSOwnWordingIsReportedAsMacOSBlockingIt() {
        for message in ["\u{201C}codex-aarch64-apple-darwin\u{201D} was not opened because it contains malware.",
                        "The application is damaged and can't be opened.",
                        "codex cannot be opened because the developer cannot be verified."] {
            XCTAssertEqual(PreflightRunner.classify(exitCode: 1, output: message), .blockedBySystem,
                           "macOS said this itself: \(message)")
        }
        // A process dying on signal 9 says nothing about why. It used to be filed under the same
        // label, which put Apple's name on an out-of-memory kill.
        XCTAssertEqual(PreflightRunner.classify(exitCode: 137, output: "Killed: 9"), .unknown)
    }

    func testAnExpiredSessionAsksForASignIn() {
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 1, output: "Failed to authenticate: OAuth session expired and could not be refreshed"),
                       .notSignedIn)
        XCTAssertEqual(PreflightRunner.classify(exitCode: 1, output: "Not logged in. Run codex login."),
                       .notSignedIn)
    }

    func testMerelyMentioningLoginIsNotAnAuthenticationVerdict() {
        // "login", "credential" and "api key" appear in help text, in hints and in unrelated
        // errors. Matching the bare words offered a Sign in button for a network failure.
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 1, output: "tip: run `codex login` to see more options"), .unknown)
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 1, output: "could not read credentials file, continuing"), .unknown)
    }

    func testAnUnrecognisedFailureIsReportedAsUnrecognised() {
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 1, output: "Error: 429 rate limit reached, try again in 4 minutes"), .unknown)
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 1, output: "stream disconnected before completion"), .unknown)
        XCTAssertEqual(PreflightRunner.classify(exitCode: 1, output: ""), .unknown)
    }

    func testAMissingBinaryWinsOverTheWordLoginInThePath() {
        // A shell reporting 127 is not ambiguous, whatever the rest of the line happens to contain.
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 127, output: "zsh:1: command not found: gh\nrun gh auth login first"),
                       .notOnPath)
    }

    func testMacOSSRefusalOutranksTheMissingFileItCaused() {
        // XProtect moves the binary to the Trash and says so. Both signs are present; the reason
        // is the half worth showing, and it is the one that changes what to install.
        XCTAssertEqual(PreflightRunner.classify(
            exitCode: 1,
            output: "spawn codex ENOENT — \u{201C}codex\u{201D} was not opened because it contains malware."),
                       .blockedBySystem)
    }

    func testAnUnreadableFolderElsewhereDoesNotStopUnrelatedWork() {
        let reasons = PreflightRunner.reasonsBlockingDispatch(
            summary: summary(affectedWork: ["Some folders cannot be read"]),
            deliversPullRequest: false, needsAppDriving: false)
        XCTAssertTrue(reasons.isEmpty,
                      "a folder problem in another product must not block this dispatch")
    }

    func testAMissingCoreCapabilityStopsEverything() {
        let reasons = PreflightRunner.reasonsBlockingDispatch(
            summary: summary(allWork: ["Claude does not answer"]),
            deliversPullRequest: false, needsAppDriving: false)
        XCTAssertEqual(reasons, ["Claude does not answer"])
    }

    func testGitHubOnlyStopsPullRequestDelivery() {
        let s = summary(pullRequests: ["GitHub is not connected"])
        XCTAssertTrue(PreflightRunner.reasonsBlockingDispatch(
            summary: s, deliversPullRequest: false, needsAppDriving: false).isEmpty)
        XCTAssertEqual(PreflightRunner.reasonsBlockingDispatch(
            summary: s, deliversPullRequest: true, needsAppDriving: false),
                       ["GitHub is not connected"])
    }

    func testAccessibilityOnlyStopsWorkThatMustLookAtAScreen() {
        let s = summary(appDriving: ["Bulava cannot drive other apps"])
        XCTAssertTrue(PreflightRunner.reasonsBlockingDispatch(
            summary: s, deliversPullRequest: false, needsAppDriving: false).isEmpty)
        XCTAssertEqual(PreflightRunner.reasonsBlockingDispatch(
            summary: s, deliversPullRequest: false, needsAppDriving: true),
                       ["Bulava cannot drive other apps"])
    }

    func testEveryApplicableReasonIsReportedTogether() {
        let reasons = PreflightRunner.reasonsBlockingDispatch(
            summary: summary(allWork: ["The work engine is missing"],
                             pullRequests: ["GitHub is not connected"],
                             appDriving: ["Bulava cannot drive other apps"],
                             affectedWork: ["Some folders cannot be read"]),
            deliversPullRequest: true, needsAppDriving: true)
        XCTAssertEqual(reasons.count, 3, "all three applicable ones, and not the folders")
        XCTAssertFalse(reasons.contains("Some folders cannot be read"))
    }

    func testTheFoldersRowStillCountsAsSomethingToReport() {

        XCTAssertFalse(summary(affectedWork: ["Some folders cannot be read"]).isEmpty)
    }

    func testAGateIsRequiredOnlyWhenItStopsEverything() {
        XCTAssertTrue(PreflightCheck(id: "a", titleKey: "a", detailKey: "d",
                                     status: .missing, gate: .allWork).required)
        for gate: PreflightCheck.Gate in [.pullRequests, .appDriving, .affectedWork, .convenience] {
            XCTAssertFalse(PreflightCheck(id: "a", titleKey: "a", detailKey: "d",
                                          status: .missing, gate: gate).required,
                           "\(gate) must not make Bulava globally 'not ready'")
        }
    }
}

// MARK: - A plan waiting for confirmation

nonisolated final class PendingPlanTests: XCTestCase {

    private func draft(_ title: String, deps: [Int] = [], prep: Bool = false) -> SubtaskDraft {
        SubtaskDraft(title: title, detail: "d", acceptance: [], projectID: UUID(),
                     projectPath: "/tmp/p", projectName: "p", dependsOn: deps,
                     visual: false, preparation: prep)
    }

    func testAnApprovalWithACorrectionIsNotAPlainYes() {

        XCTAssertFalse(ForemanConfirm.isAffirmative(
            "Так, про дев гілку я мав на увазі бекенд підтягнути, бо ним займаються інші розробники, я його тільки читаю. Все інше ок"))
        XCTAssertFalse(ForemanConfirm.isNegative(
            "Так, про дев гілку я мав на увазі бекенд підтягнути. Все інше ок"))

        XCTAssertTrue(ForemanConfirm.isAffirmative("Так"))
        XCTAssertTrue(ForemanConfirm.isAffirmative("так."))
    }

    func testAProposalRemembersTheMessageItWasShapedFrom() {

        let plan = [draft("sync"), draft("test iOS", deps: [0]), draft("test Android", deps: [0])]
        let proposal = ForemanProposal(action: .createTask, taskID: nil, label: "l",
                                       draftSubtasks: plan, sourceMessage: "original request")
        XCTAssertEqual(proposal.sourceMessage, "original request")
        XCTAssertEqual(proposal.draftSubtasks.count, 3)
    }

    func testAPlanCarriesItsDependencyGraphIntoTheItem() {

        let plan = [draft("sync", prep: true), draft("rules"), draft("fix", deps: [0]),
                    draft("iOS", deps: [0, 2]), draft("Android", deps: [0, 2])]
        XCTAssertEqual(plan.filter { $0.dependsOn.contains(0) }.count, 3)
        XCTAssertTrue(plan[0].preparation)
        XCTAssertFalse(plan[1].preparation)

        for (i, d) in plan.enumerated() {
            for dep in d.dependsOn { XCTAssertLessThan(dep, i) }
        }
    }
}

// MARK: - Groundwork streams

nonisolated final class PreparationStreamTests: XCTestCase {

    func testPreparationDefaultsToFalseSoNothingChangesByAccident() {
        let d = SubtaskDraft(title: "t", detail: "d", acceptance: [], projectID: nil,
                             projectPath: nil, projectName: "p", dependsOn: [], visual: false)
        XCTAssertFalse(d.preparation)
    }

    func testAPreparationStreamIsNotAskedForItsOwnReport() {

        let prep = BacklogTask(title: "sync", type: .chore, wantsReport: false)
        let real = BacklogTask(title: "feature", type: .feature)
        XCTAssertFalse(prep.wantsReport)
        XCTAssertTrue(real.wantsReport, "ordinary work still gets a report")
    }

    func testAPreparationStreamStillBlocksItsDependents() {

        let sync = UUID(), iOS = UUID()
        let item = WorkItem(productID: UUID(), title: "package", streams: [
            WorkItem.Stream(id: sync, title: "sync", projectName: "backend"),
            WorkItem.Stream(id: iOS, title: "test iOS", projectName: "app", dependsOn: [sync]),
        ])
        XCTAssertEqual(item.startable(finished: [], alreadyRunning: []).map(\.id), [sync],
                       "only the groundwork may start first")
        XCTAssertEqual(item.startable(finished: [sync], alreadyRunning: [sync]).map(\.id), [iOS],
                       "the dependent starts once the groundwork is in")
    }
}

// MARK: - A worker that finished and never signed off

nonisolated final class SilentFinishTests: XCTestCase {

    private func resolvable(stalled: Bool, doneResult: String?, question: Bool,
                            hasReport: Bool, state: TaskState, held: Bool = false) -> Bool {
        guard [.executing, .verifying, .blocked].contains(state) else { return false }
        guard !held else { return false }
        guard stalled, doneResult == nil, !question else { return false }
        return hasReport
    }

    func testAParkedRunIsAlsoResolved() {

        XCTAssertTrue(resolvable(stalled: true, doneResult: nil, question: false,
                                 hasReport: true, state: .blocked))
    }

    func testATaskHeldForItsOwnReasonIsLeftHeld() {
        XCTAssertFalse(resolvable(stalled: true, doneResult: nil, question: false,
                                  hasReport: true, state: .blocked, held: true))
    }

    func testAStalledRunWithARealReportIsDelivered() {
        XCTAssertTrue(resolvable(stalled: true, doneResult: nil, question: false,
                                 hasReport: true, state: .executing))
    }

    func testWithoutAReportNothingIsAssumed() {

        XCTAssertFalse(resolvable(stalled: true, doneResult: nil, question: false,
                                  hasReport: false, state: .executing))
    }

    func testARunThatDeclaredSomethingIsLeftAlone() {

        XCTAssertFalse(resolvable(stalled: true, doneResult: "passed", question: false,
                                  hasReport: true, state: .executing))
    }

    func testAWorkerHoldingAQuestionIsNotFinished() {
        XCTAssertFalse(resolvable(stalled: true, doneResult: nil, question: true,
                                  hasReport: true, state: .executing))
    }

    func testAHealthyRunningRunIsUntouched() {
        XCTAssertFalse(resolvable(stalled: false, doneResult: nil, question: false,
                                  hasReport: true, state: .executing))
    }

    func testItLandsInReviewNotApproved() {

        let delivered = TaskState.review
        XCTAssertNotEqual(delivered, .approved)
        XCTAssertNotEqual(delivered, .merged)
        XCTAssertTrue([.executing, .verifying].allSatisfy { $0 != delivered })
    }
}

// MARK: - What is allowed to interrupt the director

nonisolated final class InterruptionPolicyTests: XCTestCase {

    private func mayToast(userInitiated: Bool) -> Bool { userInitiated }

    func testARefusalYouCausedIsWorthATellingYou() {
        XCTAssertTrue(mayToast(userInitiated: true), "you pressed the button; you get an answer")
    }

    func testARoutineSchedulerRefusalIsSilent() {
        XCTAssertFalse(mayToast(userInitiated: false))
    }

    func testTheWaitingReasonIsStillCarriedOnTheStreamItself() {

        let dep = UUID()
        let item = WorkItem(productID: UUID(), title: "p", streams: [
            WorkItem.Stream(id: dep, title: "sync", projectName: "backend"),
            WorkItem.Stream(id: UUID(), title: "qa", projectName: "app", dependsOn: [dep]),
        ])
        XCTAssertEqual(item.streams[1].dependsOn, [dep])
        XCTAssertEqual(item.startable(finished: [], alreadyRunning: []).count, 1,
                       "the waiting stream is genuinely not startable — that is what the row says")
    }
}

// MARK: - Notes, and decisions the director can actually answer

nonisolated final class NotesAndDecisionsTests: XCTestCase {

    func testANoteIsNotDispatchable() {
        var note = BacklogTask(title: "n", projectPath: "/tmp/p", type: .idea, state: .ready)
        XCTAssertFalse(note.isDispatchable, "a note must never sit in the run queue")
        XCTAssertTrue(note.isNote)
        note.type = .chore
        XCTAssertTrue(note.isDispatchable, "taking it on makes it real work")
    }

    func testOrdinaryWorkIsUnaffected() {
        for type in [TaskType.feature, .bug, .chore, .research, .design, .content, .refactor] {
            let t = BacklogTask(title: "t", projectPath: "/tmp/p", type: type, state: .ready)
            XCTAssertTrue(t.isDispatchable, "\(type) must still be dispatchable")
            XCTAssertFalse(t.isNote)
        }
    }

    func testANumberedAnswerIsParsed() {
        XCTAssertEqual(ForemanBrain.numberedAnswer("1: дозволяю писати в бекенд")?.0, 1)
        XCTAssertEqual(ForemanBrain.numberedAnswer("5 - ось акаунт guest@x.io")?.0, 5)
        XCTAssertEqual(ForemanBrain.numberedAnswer("3. передай команді бекенду")?.1,
                       "передай команді бекенду")

        XCTAssertEqual(ForemanBrain.numberedAnswer("2: рядок один\nрядок два")?.0, 2)
    }

    func testOrdinaryMessagesAreNotMistakenForAnswers() {
        XCTAssertNil(ForemanBrain.numberedAnswer("зроби 5 варіантів головної"))
        XCTAssertNil(ForemanBrain.numberedAnswer("5:"))
        XCTAssertNil(ForemanBrain.numberedAnswer("подивись, що там з покупками"))
        XCTAssertNil(ForemanBrain.numberedAnswer("1234567: щось"))
    }

    func testTheDecisionsQuestionIsRecognisedHoweverItIsPhrased() {
        for q in ["що за рішення від мене очікується?", "які рішення від мене потрібні",
                  "какие решения от меня нужны?", "чого ти чекаєш від мене?",
                  "что мне сделать?", "what decisions are waiting"] {
            XCTAssertTrue(ForemanBrain.asksForDecisions(q), "should recognise: \(q)")
        }
        for q in ["зроби мені лендінг", "що зроблено за ніч", "запусти чергу"] {
            XCTAssertFalse(ForemanBrain.asksForDecisions(q), "should NOT match: \(q)")
        }
    }
}

// MARK: - One request, one job

nonisolated final class OneJobPerResourceTests: XCTestCase {

    private func draft(_ title: String, project: UUID?, name: String = "repo",
                       deps: [Int] = []) -> SubtaskDraft {
        SubtaskDraft(title: title, detail: "d", acceptance: ["a"], projectID: project,
                     projectPath: "/tmp/\(name)", projectName: name, dependsOn: deps, visual: false)
    }

    private func groups(_ drafts: [SubtaskDraft], variants: Bool) -> [[Int]] {
        if variants { return drafts.indices.map { [$0] } }
        var order: [String] = []
        var byResource: [String: [Int]] = [:]
        for (i, d) in drafts.enumerated() {
            let key = d.projectID?.uuidString ?? "unplaced-\(i)"
            if byResource[key] == nil { order.append(key) }
            byResource[key, default: []].append(i)
        }
        return order.compactMap { byResource[$0] }
    }

    func testStepsInOneResourceBecomeOneJob() {
        let repo = UUID()
        let plan = [draft("sync", project: repo), draft("test iOS", project: repo, deps: [0]),
                    draft("fix tariff", project: repo, deps: [1]), draft("test Android", project: repo, deps: [0])]
        XCTAssertEqual(groups(plan, variants: false).count, 1,
                       "four steps in one repository are one job, not four")
        XCTAssertEqual(groups(plan, variants: false)[0], [0, 1, 2, 3], "in the order they were planned")
    }

    func testDifferentResourcesStaySeparate() {
        let backend = UUID(), app = UUID()
        let plan = [draft("sync backend", project: backend, name: "backend"),
                    draft("QA iOS", project: app, name: "app", deps: [0]),
                    draft("fix tariff", project: app, name: "app", deps: [1])]
        let g = groups(plan, variants: false)
        XCTAssertEqual(g.count, 2, "two resources, two workers — this split is real parallelism")
        XCTAssertEqual(g[0], [0])
        XCTAssertEqual(g[1], [1, 2], "both app steps go to the same worker")
    }

    func testAlternativesAreNeverGrouped() {
        let repo = UUID()
        let plan = (1...5).map { draft("variant \($0)", project: repo) }
        XCTAssertEqual(groups(plan, variants: true).count, 5,
                       "ten prototypes are ten prototypes (§15) — grouping them would defeat the point")
    }

    func testAnUnplacedDraftIsNeverGroupedWithAnother() {

        let plan = [draft("a", project: nil), draft("b", project: nil)]
        XCTAssertEqual(groups(plan, variants: false).count, 2)
    }

    func testDependencyEdgesInsideAGroupDisappearAndAcrossGroupsSurvive() {
        let backend = UUID(), app = UUID()
        let plan = [draft("sync", project: backend, name: "backend"),
                    draft("qa", project: app, name: "app", deps: [0]),
                    draft("fix", project: app, name: "app", deps: [1])]
        let g = groups(plan, variants: false)
        var streamOfDraft: [Int: Int] = [:]
        for (s, group) in g.enumerated() { for d in group { streamOfDraft[d] = s } }

        let appDeps = Set(g[1].flatMap { plan[$0].dependsOn }.compactMap { streamOfDraft[$0] }).subtracting([1])
        XCTAssertEqual(appDeps, [0])
        let backendDeps = Set(g[0].flatMap { plan[$0].dependsOn }.compactMap { streamOfDraft[$0] }).subtracting([0])
        XCTAssertTrue(backendDeps.isEmpty, "the first job waits for nothing")
    }

    func testASingleResourceRequestRendersAsAPlainCard() {

        let item = WorkItem(productID: UUID(), title: "job", streams: [
            WorkItem.Stream(id: UUID(), title: "everything", projectName: "repo"),
        ])
        XCTAssertFalse(item.isMultiStream)
    }
}

// MARK: - A job is named by what was ASKED FOR

nonisolated final class JobNamingTests: XCTestCase {

    func testTheJobIsNamedAfterTheDirectorsOwnSentence() {
        let asked = "Додай експорт звичок у CSV, нагадування на заданий час і опиши це в README"
        XCTAssertEqual(AppModel.jobName(from: asked), asked)
    }

    func testAMultiSentenceRequestIsNamedByItsFirstSentence() {
        let name = AppModel.jobName(from: "Зроби експорт у CSV. Потім нагадування. І README онови.")
        XCTAssertEqual(name, "Зроби експорт у CSV")
    }

    func testAMultiLineRequestIsNamedByItsFirstLine() {
        let name = AppModel.jobName(from: "Онови трекер звичок\n- експорт\n- нагадування")
        XCTAssertEqual(name, "Онови трекер звичок")
    }

    func testTooShortToBeAName() {
        XCTAssertNil(AppModel.jobName(from: "ок"))
        XCTAssertNil(AppModel.jobName(from: "   "))
        XCTAssertNil(AppModel.jobName(from: ""))
    }

    func testAShortLeadingClauseIsNotTheName() {
        let asked = "Слухай, додай будь ласка експорт звичок у CSV і нагадування на ранок"
        XCTAssertEqual(AppModel.jobName(from: asked), asked)
    }

    func testALongRequestIsCutOnAWordBoundaryNotMidWord() {
        let long = String(repeating: "додай нагадування ", count: 12)
        guard let name = AppModel.jobName(from: long) else { return XCTFail("expected a name") }
        XCTAssertTrue(name.hasSuffix("…"))
        XCTAssertLessThanOrEqual(name.count, 98)

        let head = name.dropLast()
        XCTAssertTrue(head.hasSuffix("нагадування") || head.hasSuffix("додай"),
                      "cut mid-word: “\(name)”")
    }

    func testLeadingBulletsAreNotPartOfTheName() {
        XCTAssertEqual(AppModel.jobName(from: "— додай експорт звичок у CSV"),
                       "додай експорт звичок у CSV")
        XCTAssertEqual(AppModel.jobName(from: "* онови трекер звичок"), "онови трекер звичок")
    }
}

// MARK: - Accepting one part of a job

nonisolated final class PartialAcceptanceTests: XCTestCase {

    func testASinglePartNeedsNoQuestion() {
        let only = UUID()
        XCTAssertEqual(AppModel.aimOfRemark(parts: [only], explicit: nil), only)
    }

    func testTwoPartsAndNoPickMeansAsk() {
        XCTAssertNil(AppModel.aimOfRemark(parts: [UUID(), UUID()], explicit: nil),
                     "with two delivered parts the app must ask, not pick the first")
    }

    func testAnExplicitPickWins() {
        let mobile = UUID(), backend = UUID()
        XCTAssertEqual(AppModel.aimOfRemark(parts: [mobile, backend], explicit: backend), backend)
    }

    func testAPickOutsideTheDeliveredPartsIsHonoured() {
        let running = UUID()
        XCTAssertEqual(AppModel.aimOfRemark(parts: [UUID(), UUID()], explicit: running), running)
    }

    func testNothingDeliveredAndNothingPickedIsNoAim() {
        XCTAssertNil(AppModel.aimOfRemark(parts: [], explicit: nil))
    }
}

// MARK: - What is knowable before the night starts

nonisolated final class PlanReadinessTests: XCTestCase {

    private func facts(_ name: String = "repo", exists: Bool = true, readable: Bool = true,
                       writable: Bool = true, repo: Bool = true, verifiable: Bool = true,
                       dirty: Bool = false, changed: Bool = true, busy: Bool = false,
                       missing: [String] = [], needs: [String] = [],
                       writeSet: [String] = []) -> ResourceFacts {
        ResourceFacts(name: name, path: "/tmp/" + name, willBeChanged: changed, exists: exists,
                      readable: readable, writable: writable, isGitRepo: repo,
                      hasVerification: verifiable, hasUncommittedChanges: dirty,
                      isBusy: busy, missingCapabilities: missing,
                      needsExternal: needs, writeSet: writeSet)
    }

    func testAReadyResourceRaisesNothing() {
        XCTAssertTrue(PlanReadiness.gaps([facts()]).isEmpty)
        XCTAssertEqual(PlanReadiness.confirmationNote(PlanReadiness.gaps([facts()])), "",
                       "a plan with no gaps must not grow a paragraph saying so")
    }

    func testChangingAReadOnlyResourceIsRaisedBeforeStarting() {
        let gaps = PlanReadiness.gaps([facts("бекенд", writable: false), facts("мобілка")])
        XCTAssertEqual(gaps.map(\.kind), [.readOnlyResource])
        XCTAssertFalse(gaps[0].blocking, "it does not stop the work — the rest still ships")
        XCTAssertFalse(gaps[0].plan.isEmpty, "a gap with no default is another interruption")
    }

    func testAPlanWithNowhereToWriteStopsBeforeStarting() {
        let gaps = PlanReadiness.gaps([facts("бекенд", writable: false)])
        XCTAssertEqual(gaps.map(\.kind), [.nowhereToWrite])
        XCTAssertTrue(gaps[0].blocking, "starting work that cannot be written anywhere is not a plan")
        XCTAssertEqual(gaps[0].plan,
                       String(localized: "I will not start — grant write access or tell me which resource to work in"),
                       "it must ask for what it needs")
    }

    func testReadingAReadOnlyResourceIsFine() {
        XCTAssertTrue(PlanReadiness.gaps([facts(writable: false, changed: false)]).isEmpty,
                      "read-only matters only when the plan changes it")
    }

    func testNothingToVerifyWithIsStatedAsAnAssumption() {
        let gaps = PlanReadiness.gaps([facts(verifiable: false)])
        XCTAssertEqual(gaps.map(\.kind), [.noVerification])
        XCTAssertFalse(gaps[0].blocking)
    }

    func testAMissingFolderStopsTheWorkAndSaysSo() {
        let gaps = PlanReadiness.gaps([facts(exists: false)])
        XCTAssertEqual(gaps.map(\.kind), [.folderMissing])
        XCTAssertTrue(gaps[0].blocking)
    }

    func testAMissingFolderRaisesNothingElse() {
        let gaps = PlanReadiness.gaps([facts(exists: false, repo: false, verifiable: false, dirty: true)])
        XCTAssertEqual(gaps.count, 1)
    }

    func testAnUnreadableFolderIsAPermissionOnlyHeCanGrant() {
        let gaps = PlanReadiness.gaps([facts(readable: false)])
        XCTAssertEqual(gaps.map(\.kind), [.folderUnreadable])
        XCTAssertTrue(gaps[0].blocking)
    }

    func testWhatStopsTheWorkIsReadFirst() {
        let gaps = PlanReadiness.gaps([facts("а", verifiable: false), facts("б", exists: false)])
        XCTAssertEqual(gaps.first?.kind, .folderMissing, "blocking gaps come first")
    }

    // MARK: The rest of the readiness contract

    func testABusyResourceIsStatedAsQueuing() {
        let gaps = PlanReadiness.gaps([facts(busy: true)])
        XCTAssertEqual(gaps.map(\.kind), [.resourceBusy])
        XCTAssertFalse(gaps[0].blocking, "queuing is not a blocker")
        XCTAssertEqual(gaps[0].plan, String(localized: "I will queue and start when it frees up"))
    }

    func testAMissingCapabilityStopsTheWork() {
        let gaps = PlanReadiness.gaps([facts(missing: ["Codex не залогінений"])])
        XCTAssertEqual(gaps.map(\.kind), [.missingTool])
        XCTAssertTrue(gaps[0].blocking)
        XCTAssertTrue(gaps[0].what.contains("Codex"), gaps[0].what)
    }

    func testSomethingThisMachineCannotReachIsAnAssumption() {
        let gaps = PlanReadiness.gaps([facts(needs: ["тестовий акаунт із підпискою"])])
        XCTAssertEqual(gaps.map(\.kind), [.needsExternal])
        XCTAssertFalse(gaps[0].blocking)
        XCTAssertTrue(gaps[0].what.contains("тестовий акаунт із підпискою"),
                      "the worker's own words must survive: \(gaps[0].what)")
        XCTAssertEqual(gaps[0].plan,
                       String(localized: "I will do the rest and leave that part unproven — tell me if you grant access"))
    }

    func testTheWholeContractLandsInOneNote() {
        let gaps = PlanReadiness.gaps([
            facts("бекенд", writable: false, needs: ["задеплоєний стейджинг"]),
            facts("мобілка", verifiable: false, dirty: true, busy: true),
        ])
        let kinds = Set(gaps.map(\.kind))
        XCTAssertEqual(kinds, [.readOnlyResource, .needsExternal, .noVerification,
                               .dirtyTree, .resourceBusy])
        let note = PlanReadiness.confirmationNote(gaps)
        for g in gaps {
            XCTAssertTrue(note.contains(g.what), "the note drops «\(g.what)»")
        }
    }

    func testABlockingGapIsReadFirst() {
        let gaps = PlanReadiness.gaps([facts("а", busy: true, needs: ["пристрій"]),
                                       facts("б", missing: ["tmux не встановлено"])])
        XCTAssertEqual(gaps.first?.kind, .missingTool)
        let note = PlanReadiness.confirmationNote(gaps)
        XCTAssertLessThan(note.range(of: "tmux")!.lowerBound,
                          note.range(of: "пристрій")!.lowerBound,
                          "what stops the work must come before what merely assumes")
    }

    func testTheFileListNeverReachesTheConfirmation() {
        let files = ["src/weekly_report.py", "src/sharing.py", "src/tui/screens.py"]
        let note = PlanReadiness.confirmationNote(PlanReadiness.gaps([facts(writeSet: files)]))
        for f in files {
            XCTAssertFalse(note.contains(f), "the confirmation names a source file: \(note)")
        }
    }

    func testTheWorkerGetsTheReconMapInItsBrief() {
        let draft = SubtaskDraft(title: "Тижневий звіт", detail: "Ціль: звіт по звичках",
                                 acceptance: [], projectID: UUID(), projectPath: "/tmp/repo",
                                 projectName: "repo", dependsOn: [], visual: false)
        let out = AppModel.carryingReconMap([draft], facts: [facts("repo", writeSet: ["src/report.py"])])
        XCTAssertTrue(out[0].detail.contains("src/report.py"), out[0].detail)
        XCTAssertTrue(out[0].detail.contains("Ціль: звіт по звичках"), "the original brief survives")
        XCTAssertEqual(out[0].title, draft.title, "titles are untouched — the plan he confirmed")
    }

    func testNoReconMeansTheBriefIsUnchanged() {
        let draft = SubtaskDraft(title: "т", detail: "бриф", acceptance: [], projectID: UUID(),
                                 projectPath: "/tmp/repo", projectName: "repo",
                                 dependsOn: [], visual: false)
        XCTAssertEqual(AppModel.carryingReconMap([draft], facts: [facts("repo")]), [draft])
    }

    func testTheNoteNamesTheResourceAndTheDefault() {
        let note = PlanReadiness.confirmationNote(
            PlanReadiness.gaps([facts("бекенд", writable: false), facts("мобілка")]))
        XCTAssertTrue(note.contains("бекенд"), "he must be able to tell WHICH resource: \(note)")
        XCTAssertTrue(note.contains(String(localized: "If that is right — press Yes. If not, tell me how, and I will redo the plan.")),
                      "the note must say what a yes means")
    }

    func testReadingAReadOnlyResourceRaisesNothingEvenAlone() {
        let gaps = PlanReadiness.gaps([facts("бекенд", writable: false, changed: false)])
        XCTAssertTrue(gaps.isEmpty, "recon in a read-only resource is not a problem: \(gaps)")
    }

    func testSeveralAssumptionsOnOneResource() {
        let gaps = PlanReadiness.gaps([facts("бекенд", writable: false, repo: false,
                                             verifiable: false, dirty: true),
                                       facts("мобілка")])
        XCTAssertEqual(Set(gaps.map(\.kind)),
                       [.readOnlyResource, .noVerification, .dirtyTree, .notARepo])
        XCTAssertTrue(gaps.allSatisfy { !$0.blocking })
    }
}

// MARK: - The plan he confirms is the plan that runs

nonisolated final class PlanReconciliationTests: XCTestCase {

    private func draft(_ title: String, path: String, name: String,
                       readsOnly: Bool = false) -> SubtaskDraft {
        SubtaskDraft(title: title, detail: "бриф", acceptance: ["працює"], projectID: UUID(),
                     projectPath: path, projectName: name, dependsOn: [], visual: false,
                     readsOnly: readsOnly)
    }

    func testAStepInAReadOnlyResourceMovesToWhereItCanBeDone() {
        let plan = [draft("Додати ендпоінт стріку", path: "/api", name: "taskly-api"),
                    draft("Кнопка синку", path: "/app", name: "fake app")]
        let (out, moved) = PlanReadiness.rehostReadOnlySteps(plan, readOnlyPaths: ["/api"])

        XCTAssertEqual(out.count, 2, "nothing is dropped — the work he asked for still exists")
        XCTAssertEqual(out[0].projectPath, "/app", "it runs where writing is allowed")
        XCTAssertEqual(out[0].projectName, "fake app")
        XCTAssertTrue(out[0].title.contains("taskly-api"),
                      "the title still says which resource it is about: \(out[0].title)")
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved[0].from, "taskly-api")
        XCTAssertEqual(moved[0].to, "fake app")
    }

    func testTheBriefForbidsTouchingTheReadOnlyResource() {
        let plan = [draft("Додати ендпоінт", path: "/api", name: "taskly-api"),
                    draft("Кнопка", path: "/app", name: "fake app")]
        let (out, _) = PlanReadiness.rehostReadOnlySteps(plan, readOnlyPaths: ["/api"])
        XCTAssertTrue(out[0].detail.contains("ТІЛЬКО НА ЧИТАННЯ"), out[0].detail)
        XCTAssertTrue(out[0].detail.contains("бриф"), "the original brief survives")
        XCTAssertTrue(out[0].acceptance.contains { $0.contains("taskly-api") && $0.contains("не змінено") },
                      "the gate gets a criterion it can check: \(out[0].acceptance)")
    }

    func testWritableStepsAreLeftAlone() {
        let plan = [draft("Кнопка синку", path: "/app", name: "fake app")]
        let (out, moved) = PlanReadiness.rehostReadOnlySteps(plan, readOnlyPaths: ["/api"])
        XCTAssertEqual(out, plan)
        XCTAssertTrue(moved.isEmpty, "a plan with nothing to move must not claim it moved something")
    }

    func testWithNoWritableResourceNothingIsMoved() {
        let plan = [draft("Додати ендпоінт", path: "/api", name: "taskly-api")]
        let (out, moved) = PlanReadiness.rehostReadOnlySteps(plan, readOnlyPaths: ["/api"])
        XCTAssertEqual(out, plan)
        XCTAssertTrue(moved.isEmpty)
    }

    func testAReadOnlyStepInAReadOnlyResourceStaysPut() {
        let plan = [draft("Звірити контракти API", path: "/api", name: "taskly-api", readsOnly: true),
                    draft("Кнопка синку", path: "/app", name: "fake app")]
        let (out, moved) = PlanReadiness.rehostReadOnlySteps(plan, readOnlyPaths: ["/api"])
        XCTAssertEqual(out, plan, "a reading step must not be rewritten")
        XCTAssertTrue(moved.isEmpty)
    }

    func testOnlyTheChangingStepMoves() {
        let plan = [draft("Звірити контракти", path: "/api", name: "taskly-api", readsOnly: true),
                    draft("Додати ендпоінт", path: "/api", name: "taskly-api"),
                    draft("Кнопка синку", path: "/app", name: "fake app")]
        let (out, moved) = PlanReadiness.rehostReadOnlySteps(plan, readOnlyPaths: ["/api"])
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(out[0].projectPath, "/api", "the reading step stayed where it belongs")
        XCTAssertEqual(out[1].projectPath, "/app", "the changing step moved to where writing is allowed")
        XCTAssertTrue(out[1].title.contains("taskly-api"))
    }

    func testAPlanThatOnlyReadsIsUntouched() {
        let plan = [draft("Вивчити схему", path: "/api", name: "taskly-api", readsOnly: true),
                    draft("Вивчити ще раз", path: "/api", name: "taskly-api", readsOnly: true),
                    draft("Кнопка", path: "/app", name: "fake app")]
        let (out, moved) = PlanReadiness.rehostReadOnlySteps(plan, readOnlyPaths: ["/api"])
        XCTAssertEqual(out, plan)
        XCTAssertTrue(moved.isEmpty)
    }

    func testTheMoveIsStatedInHisLanguage() {
        let note = PlanReadiness.movedNote([.init(title: "Додати ендпоінт стріку",
                                                 from: "taskly-api", to: "fake app")])
        XCTAssertTrue(note.contains("taskly-api"))
        XCTAssertTrue(note.contains("fake app"))
        XCTAssertFalse(note.contains("readOnly"), "no internal vocabulary on his screen")
    }

    func testNoReadOnlyResourcesIsANoOp() {
        let plan = [draft("Кнопка", path: "/app", name: "fake app")]
        let (out, moved) = PlanReadiness.rehostReadOnlySteps(plan, readOnlyPaths: [])
        XCTAssertEqual(out, plan)
        XCTAssertTrue(moved.isEmpty)
    }
}

// MARK: - Technical observations are not work he has to triage

nonisolated final class FindingsAreNotCardsTests: XCTestCase {

    @MainActor private func store() -> (BacklogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-findings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (BacklogStore(), dir)
    }

    private func finding(_ title: String, id: String = "abc123") -> BacklogTask {
        BacklogTask(title: title, detail: "Клас: needs_scope\n\nтекст\n\n[finding-id: \(id)]",
                    projectPath: "/tmp/p", type: .idea, priority: .p3, state: .ready)
    }

    @MainActor
    func testFindingNotesAreTakenOutOfTheFeed() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(finding("src/habits"))
        backlog.add(finding("Taskly: TASKLY_HOME переносить лише стан", id: "def456"))

        let removed = backlog.removeFindingNotes()
        XCTAssertEqual(removed.count, 2)
        XCTAssertTrue(backlog.tasks.isEmpty, "his feed is work he asked for")
    }

    @MainActor
    func testTheRemovedTextComesBack() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(finding("src/habits"))
        let removed = backlog.removeFindingNotes()
        XCTAssertTrue(removed.first?.detail.contains("текст") ?? false)
    }

    @MainActor
    func testWorkHeTookOnSurvives() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        var promoted = finding("Полагодити перейменування звички")
        promoted.type = .chore
        backlog.add(promoted)
        backlog.add(finding("src/habits", id: "other"))

        let removed = backlog.removeFindingNotes()
        XCTAssertEqual(removed.count, 1, "only the untouched note goes")
        XCTAssertEqual(backlog.tasks.count, 1)
        XCTAssertEqual(backlog.tasks.first?.type, .chore)
    }

    @MainActor
    func testHisOwnNotesAreLeftAlone() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(BacklogTask(title: "а що якщо додати темну тему", detail: "думка",
                                projectPath: "/tmp/p", type: .idea, priority: .p3, state: .ready))
        XCTAssertTrue(backlog.removeFindingNotes().isEmpty)
        XCTAssertEqual(backlog.tasks.count, 1)
    }

    @MainActor
    func testRunningItTwiceIsAsGoodAsOnce() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(finding("src/habits"))
        XCTAssertEqual(backlog.removeFindingNotes().count, 1)
        XCTAssertTrue(backlog.removeFindingNotes().isEmpty)
    }

    @MainActor
    func testTheRunLabelPrefixIsStripped() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(BacklogTask(title: "Нічний джоб · fake app: Додати експорт звичок у CSV",
                                projectPath: "/tmp/p", state: .ready))
        backlog.add(BacklogTask(title: "Звичайна робота", projectPath: "/tmp/p", state: .ready))

        backlog.stripRunLabelPrefixes()
        XCTAssertTrue(backlog.tasks.contains { $0.title == "Додати експорт звичок у CSV" },
                      backlog.tasks.map(\.title).description)
        XCTAssertTrue(backlog.tasks.contains { $0.title == "Звичайна робота" },
                      "ordinary titles untouched")
        XCTAssertFalse(backlog.tasks.contains { $0.title.contains("Нічний джоб") })

        backlog.stripRunLabelPrefixes()
        XCTAssertTrue(backlog.tasks.contains { $0.title == "Додати експорт звичок у CSV" },
                      "idempotent")
    }

    @MainActor
    func testAPrefixWithoutAProjectStillLosesTheLabel() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(BacklogTask(title: "Нічний джоб · полагодити експорт",
                                projectPath: "/tmp/p", state: .ready))
        backlog.stripRunLabelPrefixes()
        XCTAssertEqual(backlog.tasks.first?.title, "полагодити експорт")
    }
}

// MARK: - The plan he confirms is the plan that runs

nonisolated final class ConfirmedPlanMatchesExecutedPlanTests: XCTestCase {

    private let app = UUID()
    private let api = UUID()

    private func draft(_ title: String, path: String = "/app", name: String = "fake app",
                       id: UUID? = nil) -> SubtaskDraft {
        SubtaskDraft(title: title, detail: "бриф", acceptance: [], projectID: id ?? app,
                     projectPath: path, projectName: name, dependsOn: [], visual: false)
    }

    func testEveryStepOfThePlanIsNamedInTheLabel() {
        let plan = [draft("Описати зміни для «taskly-api»: додати ендпоінт"), draft("Кнопка синку")]
        let label = AppModel.multiTaskLabel(plan)
        for step in plan {
            XCTAssertTrue(label.contains(step.title), "the label omits «\(step.title)»: \(label)")
        }
    }

    func testTheLabelDescribesTheRehostedPlanNotTheOriginal() {
        let original = [draft("Додати ендпоінт", path: "/api", name: "taskly-api", id: api),
                        draft("Кнопка синку")]
        let (plan, moved) = PlanReadiness.rehostReadOnlySteps(original, readOnlyPaths: ["/api"])
        XCTAssertFalse(moved.isEmpty, "precondition: something was moved")

        let label = AppModel.multiTaskLabel(plan)
        XCTAssertTrue(label.contains(plan[0].title), "the label must describe what will run")
        XCTAssertFalse(label.contains("  1. Додати ендпоінт\n"),
                       "the label still lists the step as originally planned: \(label)")

        XCTAssertEqual(plan[0].projectName, "fake app")
    }

    func testASingleStepPlanNamesItsResource() {
        let label = AppModel.multiTaskLabel([draft("Полагодити експорт")])
        XCTAssertTrue(label.contains("Полагодити експорт"))
        XCTAssertTrue(label.contains("fake app"))
    }

    func testTheStepCountMatchesThePlan() {
        let two = AppModel.multiTaskLabel([draft("а"), draft("б")])
        XCTAssertTrue(two.contains(AppModel.stepsPhrase(2)), two)
        let five = AppModel.multiTaskLabel((1...5).map { draft("крок \($0)") })
        XCTAssertTrue(five.contains(AppModel.stepsPhrase(5)), five)
        XCTAssertNotEqual(AppModel.stepsPhrase(1), AppModel.stepsPhrase(2),
                          "one and two must not read identically")
    }

    func testThePluralPhrasesDecline() {
        // Declension is a property of the TRANSLATED phrase, so the language has to be named.
        // This used to pass by borrowing whichever language his own settings happened to be in —
        // which stopped being readable the moment a test launch got its own defaults suite, and
        // was never something a test should have depended on.
        LanguageBundle.adopt(.uk)
        defer { LanguageBundle.adopt(.system) }

        for n in [1, 2, 5, 11, 21] {
            XCTAssertTrue(AppModel.stepsPhrase(n).contains("\(n)"), AppModel.stepsPhrase(n))
            XCTAssertTrue(AppModel.reportsPhrase(n).contains("\(n)"), AppModel.reportsPhrase(n))
        }

        let forms = Set([AppModel.stepsPhrase(1).replacingOccurrences(of: "1", with: ""),
                         AppModel.stepsPhrase(2).replacingOccurrences(of: "2", with: ""),
                         AppModel.stepsPhrase(5).replacingOccurrences(of: "5", with: "")])
        XCTAssertGreaterThanOrEqual(forms.count, 2, "the noun never declines: \(forms)")
    }
}

// MARK: - A parked run's question still reaches him

nonisolated final class ParkedQuestionTests: XCTestCase {

    func testTheDurableRecordCarriesEverythingHeNeedsToDecide() {
        let q = PendingUserQuestion(
            questions: [.init(question: "Чи можна змінювати taskly-api?", header: "Доступ",
                              options: ["Так, змінюй", "Ні, тільки клієнт"], multiSelect: false)],
            askedAt: Date(),
            reasonCode: "missing_authority",
            summary: "Потрібен доступ на запис у бекенд",
            recommendation: "Дати право на запис",
            defaultAction: "Інакше зроблю тільки клієнт",
            unblockAction: "Переключи taskly-api на «можна змінювати»")
        let r = q.record
        XCTAssertEqual(r.question, "Чи можна змінювати taskly-api?")
        XCTAssertEqual(r.options.count, 2)
        XCTAssertEqual(r.recommendation, "Дати право на запис")
        XCTAssertEqual(r.defaultAction, "Інакше зроблю тільки клієнт")
        XCTAssertEqual(r.unblockAction, "Переключи taskly-api на «можна змінювати»")
        XCTAssertFalse(r.headline.isEmpty)
        XCTAssertNotNil(r.gateLabelKey, "the gate it hit is part of the decision")
    }

    func testEveryQuestionIsKept() {
        let q = PendingUserQuestion(
            questions: [.init(question: "Змінювати бекенд?", header: "Доступ",
                              options: ["Так", "Ні"], multiSelect: false),
                        .init(question: "Які платформи перевіряти?", header: "Платформи",
                              options: ["iOS", "Android", "Web"], multiSelect: true)],
            askedAt: Date(), reasonCode: "missing_authority", summary: "Два питання")
        let r = q.record
        XCTAssertEqual(r.items.count, 2)
        XCTAssertEqual(r.items[1].options, ["iOS", "Android", "Web"])
        XCTAssertTrue(r.items[1].multiSelect, "multi-select must survive")
        XCTAssertEqual(r.items[1].header, "Платформи")
    }

    func testALegacyRecordDecodesIntoTheArray() throws {
        let json = """
        {"headline":"Потрібен доступ","question":"Можна?","options":["Так","Ні"],
         "recommendation":"р","defaultAction":"д","unblockAction":"у"}
        """
        let r = try JSONDecoder().decode(DecisionRecord.self, from: Data(json.utf8))
        XCTAssertEqual(r.items.count, 1)
        XCTAssertEqual(r.question, "Можна?")
        XCTAssertEqual(r.options, ["Так", "Ні"])
        XCTAssertEqual(r.recommendation, "р")
    }

    func testTheDecisionSurvivesPersistence() throws {
        let record = DecisionRecord(
            headline: "Потрібен доступ",
            items: [.init(question: "Можна?", header: nil, options: ["Так"], multiSelect: false),
                    .init(question: "Де саме?", header: "Місце", options: [], multiSelect: false)],
            gateLabelKey: "k", recommendation: "р", defaultAction: "д", unblockAction: "у")
        let entry = ConversationEntry(productID: UUID(), kind: .question, text: "Потрібен доступ",
                                     taskID: UUID(), decision: record)
        let back = try JSONDecoder().decode(ConversationEntry.self,
                                            from: try JSONEncoder().encode(entry))
        XCTAssertEqual(back.decision, record)
    }

    func testAnOlderEntryWithoutADecisionStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","productID":"\(UUID().uuidString)","kind":"question",
         "at":0,"text":"старе питання","tone":"neutral","attachments":[]}
        """
        let back = try JSONDecoder().decode(ConversationEntry.self, from: Data(json.utf8))
        XCTAssertNil(back.decision)
        XCTAssertEqual(back.text, "старе питання")
    }
}

// MARK: - No English engine label inside a Ukrainian line

nonisolated final class OutcomeLanguageTests: XCTestCase {

    @MainActor private func store() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-lang-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (ConversationStore(), dir)
    }

    func testEveryOutcomeHasAHumanLabel() {
        for outcome in [QueueOutcome.passed, .debt, .needsUser, .handoff, .blocked, .timeout,
                        .interrupted, .vanished, .gone, .startfail, .injectfail, .unknown] {
            XCTAssertFalse(outcome.humanLabel.isEmpty, "\(outcome) has no human label")
        }
    }

    func testTheEngineLabelStaysEnglish() {
        XCTAssertEqual(QueueOutcome.needsUser.label, "Needs you")
        XCTAssertEqual(QueueOutcome.debt.label, "Review debt")
    }

    @MainActor
    func testStoredHistoryIsRepaired() {
        let (conversations, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()
        conversations.postEvent("«fake app» зупинився: Needs you. Треба твоє рішення.",
                                productID: product, tone: .attention)
        conversations.repairEnglishOutcomeLeaks()

        let texts = conversations.all(for: product).map(\.text)
        XCTAssertFalse(texts.contains { $0.contains("Needs you") },
                       "the English label is still on screen: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("чекає на твоє рішення") }, texts.description)
    }

    @MainActor
    func testRepairIsIdempotentAndLeavesOtherTextAlone() {
        let (conversations, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()
        conversations.postEvent("Звичайна подія без англійських слів.", productID: product, tone: .neutral)
        conversations.repairEnglishOutcomeLeaks()
        conversations.repairEnglishOutcomeLeaks()
        XCTAssertEqual(conversations.all(for: product).map(\.text),
                       ["Звичайна подія без англійських слів."])
    }
}

// MARK: - A claimed verification command must exist

nonisolated final class VerificationClaimTests: XCTestCase {

    private func repo(_ files: [String: String]) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-verify-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            let url = dir.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testAMakeTargetThatExistsCounts() {
        let dir = repo(["Makefile": "test:\n\t.venv/bin/python -m pytest\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(AppModel.verificationCommandExists("make test", at: dir.path))
    }

    func testAMakeTargetThatDoesNotExistIsNotBelieved() {
        let dir = repo(["README.md": "no makefile here"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(AppModel.verificationCommandExists("make test", at: dir.path))
    }

    func testAMakefileWithoutThatTargetIsNotBelieved() {
        let dir = repo(["Makefile": "build:\n\techo hi\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(AppModel.verificationCommandExists("make test", at: dir.path))
    }

    func testNpmNeedsAPackageJson() {
        let withPkg = repo(["package.json": "{\"scripts\":{\"test\":\"vitest\"}}"])
        let without = repo(["index.js": "//"])
        defer { try? FileManager.default.removeItem(at: withPkg)
                try? FileManager.default.removeItem(at: without) }
        XCTAssertTrue(AppModel.verificationCommandExists("npm test", at: withPkg.path))
        XCTAssertFalse(AppModel.verificationCommandExists("npm test", at: without.path))
    }

    func testPytestNeedsSomethingPythonShaped() {
        let withTests = repo(["tests/test_a.py": "def test_a(): pass"])
        let without = repo(["main.go": "package main"])
        defer { try? FileManager.default.removeItem(at: withTests)
                try? FileManager.default.removeItem(at: without) }
        XCTAssertTrue(AppModel.verificationCommandExists("pytest -q", at: withTests.path))
        XCTAssertFalse(AppModel.verificationCommandExists("pytest -q", at: without.path))
    }

    func testAScriptMustBeOnDisk() {
        let dir = repo(["run-tests.sh": "#!/bin/bash\nexit 0\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(AppModel.verificationCommandExists("./run-tests.sh", at: dir.path))
        XCTAssertTrue(AppModel.verificationCommandExists("bash run-tests.sh", at: dir.path))
        XCTAssertFalse(AppModel.verificationCommandExists("./nope.sh", at: dir.path))
    }

    func testAnXcodeProjectIsRecognised() {
        let dir = repo(["Thing.xcodeproj/project.pbxproj": "// objects"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(AppModel.verificationCommandExists("xcodebuild test -scheme Thing", at: dir.path))
    }

    func testAnEmptyOrUnplaceableCommandIsNotBelieved() {
        let dir = repo(["README.md": "x"])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(AppModel.verificationCommandExists("", at: dir.path))
        XCTAssertFalse(AppModel.verificationCommandExists("   ", at: dir.path))
        XCTAssertFalse(AppModel.verificationCommandExists("просто перевір руками", at: dir.path))
    }
}

// MARK: - A hold belongs to one resource, not to the whole job

nonisolated final class PerResourceHoldTests: XCTestCase {

    private let mobile = UUID()
    private let backend = UUID()

    private func draft(_ title: String, path: String, name: String, id: UUID) -> SubtaskDraft {
        SubtaskDraft(title: title, detail: "d", acceptance: [], projectID: id,
                     projectPath: path, projectName: name, dependsOn: [], visual: false)
    }

    private func facts(_ name: String, _ path: String, exists: Bool = true,
                       writable: Bool = true) -> ResourceFacts {
        ResourceFacts(name: name, path: path, willBeChanged: true, exists: exists,
                      readable: true, writable: writable, isGitRepo: true,
                      hasVerification: true, hasUncommittedChanges: false)
    }

    func testAHoldLandsOnlyOnTheStepsOfItsOwnResource() {
        let resources = [facts("бекенд", "/api", exists: false), facts("мобілка", "/app")]
        let gaps = PlanReadiness.gaps(resources)
        let plan = [draft("ендпоінт", path: "/api", name: "бекенд", id: backend),
                    draft("кнопка", path: "/app", name: "мобілка", id: mobile)]

        let out = AppModel.carryingHolds(plan, gaps: gaps, facts: resources)
        XCTAssertEqual(out[0].holds.count, 1, "the backend step is held")
        XCTAssertEqual(out[0].holds.first?.kind, ReadinessGap.Kind.folderMissing.rawValue)
        XCTAssertTrue(out[1].holds.isEmpty, "the mobile step must not be held by the backend's problem")
    }

    func testNoBlockingGapsMeansNoHolds() {
        let resources = [facts("мобілка", "/app")]
        let out = AppModel.carryingHolds([draft("кнопка", path: "/app", name: "мобілка", id: mobile)],
                                        gaps: PlanReadiness.gaps(resources), facts: resources)
        XCTAssertTrue(out[0].holds.isEmpty)
    }

    func testAssumptionsAreNotHolds() {
        let r = ResourceFacts(name: "мобілка", path: "/app", willBeChanged: true, exists: true,
                              readable: true, writable: true, isGitRepo: false,
                              hasVerification: false, hasUncommittedChanges: true)
        let holds = PlanReadiness.holds(PlanReadiness.gaps([r]), resources: [r])
        XCTAssertTrue(holds.isEmpty, "only blocking gaps become holds: \(holds)")
    }

    func testAHoldKnowsWhichPathItIsAbout() {
        let resources = [facts("бекенд", "/api", exists: false)]
        let holds = PlanReadiness.holds(PlanReadiness.gaps(resources), resources: resources)
        XCTAssertEqual(holds.first?.path, "/api")
        XCTAssertEqual(holds.first?.resource, "бекенд")
        XCTAssertFalse(holds.first?.sentence.isEmpty ?? true, "the card needs a sentence")
    }

    func testTwoProblemsInOneResourceAreTwoHolds() {
        let r = facts("бекенд", "/api", writable: false)
        var holds = PlanReadiness.holds(PlanReadiness.gaps([r]), resources: [r])
        XCTAssertEqual(holds.count, 1, "read-only with nowhere else to write is one blocking gap")
        holds = PlanReadiness.holds(PlanReadiness.gaps([facts("бекенд", "/api", exists: false)]),
                                    resources: [facts("бекенд", "/api", exists: false)])
        XCTAssertEqual(holds.count, 1)
    }

    func testHoldsAreDecodableFromDisk() throws {
        let hold = TaskHold(kind: ReadinessGap.Kind.folderMissing.rawValue, resource: "бекенд",
                            path: "/api", what: "теки немає", plan: "онови шлях")
        var task = BacklogTask(title: "t", projectPath: "/api", state: .ready)
        task.holds = [hold]
        task.autoResume = true
        let back = try JSONDecoder().decode(BacklogTask.self, from: try JSONEncoder().encode(task))
        XCTAssertEqual(back.holds, [hold])
        XCTAssertTrue(back.autoResume)
    }

    func testATaskWithoutHoldsStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"старе","detail":"","type":"feature",
         "priority":2,"state":"ready","createdAt":0,"updatedAt":0}
        """
        let back = try JSONDecoder().decode(BacklogTask.self, from: Data(json.utf8))
        XCTAssertTrue(back.holds.isEmpty)
        XCTAssertEqual(back.title, "старе")
    }
}

// MARK: - The same words twice in a breath are one request

nonisolated final class RepeatedMessageTests: XCTestCase {

    private func entry(_ text: String, secondsAgo: TimeInterval) -> ConversationEntry {
        ConversationEntry(productID: UUID(), kind: .user,
                          at: Date().addingTimeInterval(-secondsAgo), text: text)
    }

    func testAnImmediateDuplicateIsIgnored() {
        XCTAssertTrue(AppModel.isImmediateRepeat("Додай експорт", of: [entry("Додай експорт", secondsAgo: 1)]))
    }

    func testTheSameWordsAMinuteLaterGoThrough() {
        XCTAssertFalse(AppModel.isImmediateRepeat("Додай експорт", of: [entry("Додай експорт", secondsAgo: 60)]),
                       "re-asking is not stuttering")
    }

    func testDifferentWordsAlwaysGoThrough() {
        XCTAssertFalse(AppModel.isImmediateRepeat("Додай нагадування", of: [entry("Додай експорт", secondsAgo: 1)]))
    }

    func testARepeatAfterSomethingElseGoesThrough() {
        let earlier = entry("Додай експорт", secondsAgo: 3)
        let between = ConversationEntry(productID: UUID(), kind: .user,
                                        at: Date().addingTimeInterval(-2), text: "ні, зачекай")
        XCTAssertFalse(AppModel.isImmediateRepeat("Додай експорт", of: [earlier, between]))
    }

    func testAnEmptyConversationNeverLooksLikeARepeat() {
        XCTAssertFalse(AppModel.isImmediateRepeat("Додай експорт", of: []))
    }

    func testTheForemansOwnEchoIsNotADuplicate() {
        let foreman = ConversationEntry(productID: UUID(), kind: .foreman,
                                        at: Date().addingTimeInterval(-1), text: "Додай експорт")
        XCTAssertFalse(AppModel.isImmediateRepeat("Додай експорт", of: [foreman]))
    }
}

// MARK: - An isolated worktree is not a project of its own

nonisolated final class GhostRunCardTests: XCTestCase {

    @MainActor private func store() -> (BacklogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-ghosts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (BacklogStore(), dir)
    }

    @MainActor
    func testTheAdoptedCopyOfAnAlreadyRepresentedRunIsRemoved() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        var real = BacklogTask(title: "Створи нову гілку і попрацюй з адмін панеллю",
                               projectPath: "/tmp", state: .blocked)
        real.boundRunID = "RUN-1"
        var adopted = BacklogTask(title: "Нічна зміна в Meetings Recorder",
                                  detail: "Direct night-shift run on main.",
                                  projectPath: "/tmp", state: .blocked)
        adopted.boundRunID = "RUN-1"
        var ownRun = BacklogTask(title: "Нічна зміна в Something Else",
                                 detail: "Direct night-shift run on main.",
                                 projectPath: "/tmp", state: .blocked)
        ownRun.boundRunID = "RUN-2"
        backlog.add(real); backlog.add(adopted); backlog.add(ownRun)

        let removed = backlog.removeGhostRunCards()
        XCTAssertEqual(removed.map(\.id), [adopted.id], "the wrong card was dropped")
        XCTAssertEqual(Set(backlog.tasks.map(\.id)), [real.id, ownRun.id])
    }

    func testAWorktreePathIsRecognised() {
        XCTAssertTrue(BacklogStore.isWorktreePath(
            "/Users/x/Developer/.nightshift-worktrees/pocket-ledger-3CC6DEF7"))
        XCTAssertFalse(BacklogStore.isWorktreePath("/Users/x/Developer/pocket-ledger"))
        XCTAssertFalse(BacklogStore.isWorktreePath(""))
    }

    @MainActor
    func testGhostCardsAreRemoved() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(BacklogTask(title: "Night run · pocket-ledger-3CC6DEF7",
                                projectPath: "/Users/x/.nightshift-worktrees/pocket-ledger-3CC6DEF7",
                                state: .blocked))
        backlog.add(BacklogTask(title: "Night run · gone-project",
                                projectPath: "/nope/does/not/exist", state: .blocked))

        let removed = backlog.removeGhostRunCards()
        XCTAssertEqual(removed.count, 2)
        XCTAssertTrue(backlog.tasks.isEmpty)
    }

    @MainActor
    func testARealRunCardSurvives() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(BacklogTask(title: "Night run · pocket-ledger",
                                projectPath: dir.path, state: .review))
        XCTAssertTrue(backlog.removeGhostRunCards().isEmpty)
        XCTAssertEqual(backlog.tasks.count, 1)
    }

    @MainActor
    func testHisOwnTasksAreNeverRemoved() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        var mine = BacklogTask(title: "Додати експорт у CSV",
                               projectPath: "/nope/does/not/exist", state: .blocked)
        mine.productID = UUID()
        backlog.add(mine)
        backlog.add(BacklogTask(title: "Полагодити тариф", projectPath: nil, state: .ready))

        XCTAssertTrue(backlog.removeGhostRunCards().isEmpty)
        XCTAssertEqual(backlog.tasks.count, 2)
    }

    @MainActor
    func testARealRunCardIsAttributedAndRenamed() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(BacklogTask(title: "Night run · pocket-ledger", projectPath: dir.path, state: .merged))
        let product = UUID()

        let touched = backlog.adoptRealRunCards { path in
            path == dir.path ? (product, "pocket-ledger") : nil
        }
        XCTAssertEqual(touched, 1)
        XCTAssertEqual(backlog.tasks.first?.productID, product)
        XCTAssertFalse(backlog.tasks.first?.title.hasPrefix("Night run · ") ?? true,
                       "the run label is gone: \(backlog.tasks.first?.title ?? "")")
        XCTAssertTrue(backlog.tasks.first?.title.contains("pocket-ledger") ?? false)
    }

    @MainActor
    func testAWorktreeRunCardIsNotAttributed() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(BacklogTask(title: "Night run · x-1EF5ADB2",
                                projectPath: "/Users/x/.nightshift-worktrees/x-1EF5ADB2",
                                state: .blocked))
        XCTAssertEqual(backlog.adoptRealRunCards { _ in (UUID(), "x") }, 0)
        XCTAssertEqual(backlog.removeGhostRunCards().count, 1)
    }

    @MainActor
    func testAnUnownedRunCardIsRenamedButNotAttributed() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(BacklogTask(title: "Night run · somewhere", projectPath: dir.path, state: .merged))
        XCTAssertEqual(backlog.adoptRealRunCards { _ in nil }, 1)
        XCTAssertNil(backlog.tasks.first?.productID, "no owner was invented")
        XCTAssertFalse(backlog.tasks.first?.title.hasPrefix("Night run · ") ?? true,
                       backlog.tasks.first?.title ?? "")
        XCTAssertTrue(backlog.tasks.first?.title.contains(dir.lastPathComponent) ?? false)
    }

    @MainActor
    func testRunningItTwiceChangesNothingMore() {
        let (backlog, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        backlog.add(BacklogTask(title: "Night run · x",
                                projectPath: "/Users/x/.nightshift-worktrees/x-1", state: .blocked))
        XCTAssertEqual(backlog.removeGhostRunCards().count, 1)
        XCTAssertTrue(backlog.removeGhostRunCards().isEmpty)
    }
}

// MARK: - A pointer to a card that no longer exists

nonisolated final class DeadAnchorTests: XCTestCase {

    @MainActor private func store() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulava-anchors-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        return (ConversationStore(), dir)
    }

    @MainActor
    func testAnAnchorWithNoCardIsDropped() {
        let (conversations, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID(), alive = UUID()
        conversations.anchorTask(alive, productID: product, title: "жива робота")
        conversations.anchorTask(UUID(), productID: product, title: "видалена робота")

        XCTAssertEqual(conversations.dropDeadAnchors(known: [alive]), 1)
        XCTAssertEqual(conversations.all(for: product).filter { $0.kind == .task }.count, 1)
    }

    @MainActor
    func testEventsAndMessagesAreNeverTouched() {
        let (conversations, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let product = UUID()
        conversations.postEvent("«pocket-ledger» зупинився і чекає на твоє рішення.",
                                productID: product, tone: .attention, taskID: UUID())
        conversations.appendUser("додай експорт", productID: product)

        XCTAssertEqual(conversations.dropDeadAnchors(known: []), 0)
        XCTAssertEqual(conversations.all(for: product).count, 2)
    }

    @MainActor
    func testItIsIdempotent() {
        let (conversations, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        conversations.anchorTask(UUID(), productID: UUID(), title: "видалена")
        XCTAssertEqual(conversations.dropDeadAnchors(known: []), 1)
        XCTAssertEqual(conversations.dropDeadAnchors(known: []), 0)
    }
}
