import Foundation

nonisolated enum Trace {

    nonisolated(unsafe) static var destination: URL?

    static var url: URL {

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("bulava-trace-tests.jsonl")
        }
        let dir = destination ?? SupervisorPaths.default.stateDir
        return dir.appendingPathComponent("app-trace.jsonl")
    }

    static let sizeLimit: UInt64 = 4 << 20

    static func note(_ kind: String,
                     task: UUID? = nil,
                     dispatch: String? = nil,
                     report: String? = nil,
                     chat: UUID? = nil,
                     project: String? = nil,
                     file: URL? = nil,
                     detail: String? = nil) {
        var row: [String: String] = ["ts": stamp(Date()), "kind": kind]
        if let task { row["task"] = short(task) }
        if let dispatch, !dispatch.isEmpty { row["dispatch"] = String(dispatch.prefix(8)).uppercased() }
        if let report, !report.isEmpty { row["report"] = report }
        if let chat { row["chat"] = short(chat) }
        if let project, !project.isEmpty { row["project"] = (project as NSString).lastPathComponent }
        if let file { row["file"] = file.lastPathComponent }
        if let detail, !detail.isEmpty {
            row["detail"] = String(detail.replacingOccurrences(of: "\n", with: " ").prefix(400))
        }
        append(row)
    }

    // MARK: - Writing

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func stamp(_ date: Date) -> String { clock.string(from: date) }

    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    private static let queue = DispatchQueue(label: "app.bulava.trace")

    private static func append(_ row: [String: String]) {

        let order = ["ts", "kind", "task", "dispatch", "report", "chat", "project", "file", "detail"]
        let fields = order.compactMap { key -> String? in
            guard let value = row[key] else { return nil }
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(key)\":\"\(escaped)\""
        }
        let line = "{" + fields.joined(separator: ",") + "}\n"
        queue.async {
            let url = Self.url
            guard let data = line.data(using: .utf8) else { return }
            rotateIfNeeded(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64,
              size > sizeLimit else { return }
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }
}
