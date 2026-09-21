import Foundation

nonisolated enum WorkerTrail {

    static let stepCeiling = 200

    enum Miss: Sendable { case noRecord, ambiguous }

    struct Trail: Sendable {
        var blocks: [ConversationBlock]

        var omitted: Int

        var lastSaid: String?

        var source: URL?

        var miss: Miss? = nil
        var isEmpty: Bool { blocks.isEmpty }
    }

    static func read(task: BacklogTask) -> Trail {
        let pick = pickTranscript(for: task)
        guard case .one(let url) = pick else {
            return Trail(blocks: [], omitted: 0, lastSaid: nil, source: nil,
                         miss: pick == .ambiguous ? .ambiguous : .noRecord)
        }

        return read(transcript: url, after: task.dispatchedAt)
    }

    static func read(transcript url: URL, after: Date? = nil) -> Trail {
        var activities: [String: BlockActivity] = [:]
        var order: [String] = []
        var said: [String] = []
        var seen = 0

        forEachLine(of: url) { line in

            if let after, let at = timestamp(of: line), at < after { return }
            for event in AgentEvent.decode(line: line) {
                switch event {
                case .toolUse(let id, _, let verbKey, let object):
                    if activities[id] == nil {
                        order.append(id)
                        seen += 1

                        if order.count > stepCeiling {
                            let dropped = order.removeFirst()
                            activities[dropped] = nil
                        }
                    }
                    let existing = activities[id]
                    activities[id] = BlockActivity(toolCallID: id, verbKey: verbKey, object: object,
                                                   status: existing?.status ?? .running,
                                                   detail: existing?.detail)
                case .toolResult(let id, let isError, let detail, _):
                    guard var activity = activities[id] else { continue }
                    activity.status = isError ? .failed : .done
                    activity.detail = detail
                    activities[id] = activity
                case .assistantText(_, let body):
                    let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { said.append(clean) }
                default:
                    continue
                }
            }
        }

        let blocks = order.compactMap { id -> ConversationBlock? in
            guard var activity = activities[id] else { return nil }

            if activity.status == .running { activity.status = .failed }
            return .activity(activity)
        }
        return Trail(blocks: blocks, omitted: max(0, seen - blocks.count),
                     lastSaid: said.last, source: url)
    }

    // MARK: - Which transcript

    enum Pick: Equatable, Sendable { case one(URL), none, ambiguous }

    static func transcript(for task: BacklogTask) -> URL? {
        guard case .one(let url) = pickTranscript(for: task) else { return nil }
        return url
    }

    static func pickTranscript(for task: BacklogTask) -> Pick {

        let roots = [task.worktree, task.projectPath].compactMap { $0 }
        guard !roots.isEmpty else { return .none }

        if let session = task.boundSessionID, !session.isEmpty {
            for root in roots {
                let candidate = directory(for: root).appendingPathComponent(session + ".jsonl")
                if FileManager.default.fileExists(atPath: candidate.path) { return .one(candidate) }
            }
        }

        guard let started = task.dispatchedAt else { return .none }
        var candidates: [URL] = []
        for root in roots {
            for (url, modified) in transcripts(in: directory(for: root)) where modified >= started {
                candidates.append(url)
            }
        }

        let distinct = Set(candidates.map { realPath($0) })
        if distinct.count > 1 { return .ambiguous }
        guard let only = candidates.first else { return .none }
        return .one(only)
    }

    private static func realPath(_ url: URL) -> String {
        url.path.withCString { c in
            guard let r = Foundation.realpath(c, nil) else { return url.path }
            defer { free(r) }
            return String(cString: r)
        }
    }

    static func directory(for path: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(WorkerActivity.transcriptDirName(for: path))
    }

    private static func transcripts(in dir: URL) -> [(URL, Date)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".jsonl") }.compactMap { name in
            let url = dir.appendingPathComponent(name)
            guard let modified = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date else { return nil }
            return (url, modified)
        }
    }

    // MARK: - Reading

    private static func forEachLine(of url: URL, _ body: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var framer = NDJSONFramer()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            for line in framer.feed(chunk) { body(line) }
        }
        for line in framer.flush() { body(line) }
    }

    private static func timestamp(of line: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["timestamp"] as? String else { return nil }
        return isoWithFraction.date(from: raw) ?? iso.date(from: raw)
    }

    private nonisolated(unsafe) static let iso = ISO8601DateFormatter()
    private nonisolated(unsafe) static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
