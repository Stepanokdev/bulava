import XCTest
@testable import Bulava

/// The collapsed line over a run of steps says what was done, by kind, instead of "17 steps" over
/// raw commands (22.10, "like ChatGPT").
nonisolated final class ActivitySummaryTests: XCTestCase {

    private func step(_ key: String, _ status: BlockActivity.Status = .done) -> BlockActivity {
        BlockActivity(toolCallID: UUID().uuidString, verbKey: key, object: "x", status: status)
    }

    private let english: (String, Int) -> String = { key, n in key.replacingOccurrences(of: "%lld", with: "\(n)") }

    func testStepsAreCountedByKindInAFixedOrder() {
        let steps = [step("runs %@"), step("reads %@"), step("described %@"), step("reads %@"),
                     step("edits %@"), step("searches the code")]
        XCTAssertEqual(ActivitySummary.line(steps, count: english),
                       "Read 2 files, edited 1 files, searched the code 1 times, ran 2 commands")
    }

    func testARunningStepIsNotCountedAsDone() {
        XCTAssertEqual(ActivitySummary.line([step("reads %@", .running)], count: english), "")
    }

    func testABashStepWithADescriptionShowsTheDescriptionNotTheCommand() {
        let described = WorkerActivity.describe(tool: "Bash", input: [
            "command": "D=/Users/me/.claude/supervisor/instances/x; ls $D", "description": "Lists the run folder"])
        XCTAssertEqual(described?.key, "described %@")
        XCTAssertEqual(described?.object, "Lists the run folder")
        XCTAssertEqual(ActivitySummary.kind(of: described?.key ?? ""), .run)
    }
}
