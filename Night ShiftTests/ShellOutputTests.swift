import XCTest
@testable import Bulava

/// What a command printed is what `Shell.run` returns — under load too.
///
/// 5 Oct: `git rev-list --count` printed "1" and the app read nothing, so a merge reported "nothing
/// to merge" for a copy holding work. The last bytes arrived through the pipe's reader at the
/// moment the process ended, after the ending had already collected the output.
nonisolated final class ShellOutputTests: XCTestCase {

    @MainActor
    func testShortOutputIsNeverLostWhileManyCommandsEnd() async {
        let rounds = 6, width = 64
        var lost: [String] = []
        for round in 0..<rounds {
            await withTaskGroup(of: (Int, CommandResult).self) { group in
                for n in 0..<width {
                    group.addTask { (n, await Shell.run("printf '%s' \"$1\"", args: ["\(n)"])) }
                }
                for await (n, result) in group where !result.ok || result.stdout != "\(n)" {
                    lost.append("round \(round), #\(n): ok=\(result.ok) stdout=\(result.stdout.debugDescription)")
                }
            }
        }
        XCTAssertTrue(lost.isEmpty, "\(lost.count) of \(rounds * width) lost their output:\n" + lost.prefix(10).joined(separator: "\n"))
    }

    @MainActor
    func testStandardErrorIsKeptToo() async {
        let r = await Shell.run("printf 'out'; printf 'err' >&2; exit 3")
        XCTAssertEqual(r.stdout, "out")
        XCTAssertEqual(r.stderr, "err")
        XCTAssertEqual(r.exitCode, 3)
        XCTAssertFalse(r.ok)
    }
}
