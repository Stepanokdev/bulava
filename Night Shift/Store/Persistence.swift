import Foundation

nonisolated enum AppSupport {

    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["BULAVA_STATE_DIR"],
           !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("NightShift", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var attachments: URL {
        let d = root.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }
}

struct JSONFile<T: Codable> {
    let url: URL

    func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(T.self, from: data)
    }

    func save(_ value: T) {
        guard let data = try? JSONEncoder.iso.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    // `nonisolated(unsafe)`, as `Fmt.relative` already is: a coder configured once and only read
    // afterwards. Without it Swift 6.4 puts these on the main actor and nothing off it can decode.
    nonisolated(unsafe) static let iso: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
extension JSONEncoder {
    nonisolated(unsafe) static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
