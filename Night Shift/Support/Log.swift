import Foundation
import OSLog

nonisolated enum Log {
    private static let subsystem = "app.bulava"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")

    static let dispatch = Logger(subsystem: subsystem, category: "dispatch")

    static let engine = Logger(subsystem: subsystem, category: "engine")

    static let state = Logger(subsystem: subsystem, category: "state")

    static func failure(_ logger: Logger, _ what: String, exit: Int32, output: String) {
        let first = output.split(separator: "\n").first.map(String.init) ?? ""
        logger.error("\(what, privacy: .public) failed (exit \(exit, privacy: .public)): \(String(first.prefix(300)), privacy: .public)")
    }
}
