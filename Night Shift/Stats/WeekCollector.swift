import Foundation

/// The numbers of one calendar week, read from what Bulava and its engines leave on this Mac.
///
/// Everything is counted per day of the week, Monday first. Days still ahead hold zeros here and
/// are told apart by `today`; the presenter turns them into "nothing yet", never "zero".
nonisolated struct WeekRaw: Equatable, Sendable {
    /// The week's eight boundaries: Monday 00:00 … next Monday 00:00, in the Mac's time zone. Seven
    /// days, but not always 168 hours — a day that changes the clock is 23 or 25 hours long.
    var bounds: [Date]
    var today: Int
    var isoWeek: String

    var agentSec = Array(repeating: 0.0, count: 7)
    var wallSec = Array(repeating: 0.0, count: 7)
    var heatSec = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
    var prompts = Array(repeating: 0, count: 7)
    var passed = Array(repeating: 0, count: 7)
    var debt = Array(repeating: 0, count: 7)
    var waiting = Array(repeating: 0, count: 7)
    var added = Array(repeating: 0, count: 7)
    var removed = Array(repeating: 0, count: 7)
    var costPerDay = Array(repeating: 0.0, count: 7)

    var files = 0
    var tokensIn = 0
    var tokensOut = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Models seen this week that no Claude Code summary priced: their tokens are not in the cost.
    var unpriced: [String] = []
    var codexTokens = 0
    var commits = 0
    var tasksGiven = 0
    var codexConsults = 0
    var questions = 0
    var longestSec = 0.0
    var longestProject: String?
    var longestEnd: Date?
    var peakParallel = 0
    var sessions = 0

    var weekStart: Date { bounds[0] }

    /// A week with nothing in it: what the widgets show while statistics are off.
    static func empty(now: Date, calendar: Calendar = .bulavaWeek) -> WeekRaw {
        let bounds = WeekCollector.weekBounds(containing: now, calendar: calendar)
        return WeekRaw(bounds: bounds, today: WeekRaw.dayIndex(of: now, bounds: bounds),
                       isoWeek: WeekCollector.isoWeek(of: now, calendar: calendar))
    }

    /// Which of the week's days a moment falls on, held to the week.
    static func dayIndex(of date: Date, bounds: [Date]) -> Int {
        max(0, min(6, bounds.prefix(7).lastIndex(where: { $0 <= date }) ?? 0))
    }
}

extension Calendar {
    /// Monday-first weeks in the Mac's own time zone, numbered the ISO way.
    nonisolated static var bulavaWeek: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        return c
    }
}

/// Reads one calendar week from local files and keeps what it read, so the next reading only
/// looks at what changed.
///
/// - Claude Code transcripts (`~/.claude/projects`): how long each agent turn took
///   (`turn_duration`), the tokens of every answer (each `message.id` once), the lines every file
///   edit added and removed (`structuredPatch`), and the per-model prices Claude Code writes into
///   its own `cost-state` summaries.
/// - The engine's journal (`decisions.jsonl`): how review ended each dispatch, its last word only.
/// - Bulava's conversations: the messages the person wrote.
/// - Codex rollouts: the week's growth of each session's cumulative token counter.
/// - git: the person's commits in the repositories the agents worked in.
///
/// Bulava's own service calls (capability probes, end-to-end tests, temporary folders) are not
/// work and are left out. Nothing here leaves the Mac.
actor WeekCollector {
    nonisolated struct Sources: Sendable {
        var claudeProjects: URL
        var codexSessions: URL
        var decisions: URL
        var conversations: URL
        /// false in tests that have no repositories to read.
        var readGit = true

        static var standard: Sources {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Sources(
                claudeProjects: home.appendingPathComponent(".claude/projects"),
                codexSessions: home.appendingPathComponent(".codex/sessions"),
                decisions: home.appendingPathComponent(".claude/supervisor/decisions.jsonl"),
                conversations: home.appendingPathComponent("Library/Application Support/NightShift/conversations.json"))
        }
    }

    // MARK: What one transcript contributed

    nonisolated struct Turn: Sendable { var uuid: String; var start: Date; var end: Date }
    nonisolated struct Answer: Sendable {
        var id: String; var at: Date; var model: String
        var input: Int; var output: Int; var cacheRead: Int; var cacheWrite: Int
    }
    nonisolated struct Edit: Sendable { var uuid: String; var at: Date; var path: String; var added: Int; var removed: Int }

    private struct Transcript {
        var size: UInt64 = 0
        var offset: UInt64 = 0
        var modified = Date.distantPast
        var cwd: String?
        var project: String?
        var isService = false
        var isSubagent = false
        var session: String?
        var turns: [Turn] = []
        var answers: [Answer] = []
        var edits: [Edit] = []
        var prices: [String: [Double]] = [:]
    }

    private struct CodexRollout {
        var size: UInt64 = 0
        var modified = Date.distantPast
        var growth = 0
    }

    let sources: Sources
    private var transcripts: [String: Transcript] = [:]
    private var rollouts: [String: CodexRollout] = [:]
    private var tops: [String: String] = [:]
    private var cachedWeek: String?

    init(sources: Sources = .standard) { self.sources = sources }

    // MARK: Reading

    func collect(now: Date = Date(), calendar: Calendar = .bulavaWeek) async -> WeekRaw {
        let bounds = Self.weekBounds(containing: now, calendar: calendar)
        let iso = Self.isoWeek(of: now, calendar: calendar)
        if cachedWeek != iso {
            // A new week: everything kept belongs to the last one.
            transcripts = [:]; rollouts = [:]; cachedWeek = iso
        }
        let today = WeekRaw.dayIndex(of: now, bounds: bounds)
        var raw = WeekRaw(bounds: bounds, today: today, isoWeek: iso)
        let start = bounds[0], end = min(bounds[7], now)

        refreshTranscripts(from: start)
        await resolveRepositories()
        tally(into: &raw, from: start, to: end, calendar: calendar)
        await tallyGit(into: &raw, from: start, to: end)
        tallyJournal(into: &raw, from: start, to: end)
        tallyConversations(into: &raw, from: start, to: end)
        tallyCodex(into: &raw, from: start, to: end)
        return raw
    }

    nonisolated static func weekBounds(containing date: Date, calendar: Calendar) -> [Date] {
        let monday = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return (0...7).map { calendar.date(byAdding: .day, value: $0, to: monday) ?? monday }
    }

    nonisolated static func isoWeek(of date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    // MARK: Transcripts

    private func refreshTranscripts(from start: Date) {
        let fm = FileManager.default
        var seen = Set<String>()
        guard let projects = try? fm.contentsOfDirectory(at: sources.claudeProjects, includingPropertiesForKeys: nil) else { return }
        for dir in projects {
            let service = Self.isServiceFolder(dir.lastPathComponent)
            var files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            // A session's subagents live beside it: <session>/subagents/agent-*.jsonl.
            for sub in files where sub.pathExtension.isEmpty {
                files += (try? fm.contentsOfDirectory(at: sub.appendingPathComponent("subagents"), includingPropertiesForKeys: nil)) ?? []
            }
            for file in files where file.pathExtension == "jsonl" {
                guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let modified = attrs[.modificationDate] as? Date,
                      let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
                // Untouched since the week began: nothing in it can be this week's.
                if modified < start { continue }
                seen.insert(file.path)
                var t = transcripts[file.path] ?? Transcript()
                if t.size == size && t.modified == modified { continue }
                if size < t.offset {
                    // Replaced or cut short: start over.
                    t = Transcript()
                }
                t.isSubagent = file.path.contains("/subagents/")
                if service { t.isService = true }
                read(file, into: &t, from: start)
                t.size = size; t.modified = modified
                transcripts[file.path] = t
            }
        }
        for gone in transcripts.keys where !seen.contains(gone) { transcripts[gone] = nil }
    }

    nonisolated static func isServiceFolder(_ name: String) -> Bool {
        name.contains("bulava-cap") || name.contains("bulava-phone-e2e") || name.contains("e2e-copies")
            || name.hasPrefix("-private-var-folders") || name.hasPrefix("-var-folders")
            || name.hasPrefix("-private-tmp") || name.hasPrefix("-tmp-")
    }

    nonisolated static func isServicePath(_ cwd: String) -> Bool {
        cwd.hasPrefix("/private/var/") || cwd.hasPrefix("/var/folders/") || cwd.hasPrefix("/private/tmp/") || cwd.hasPrefix("/tmp/")
    }

    /// Reads what was appended since the last reading, whole lines only: a line still being written
    /// is read next time.
    private func read(_ file: URL, into t: inout Transcript, from start: Date) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: t.offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let whole = data[data.startIndex...lastNewline]
        t.offset += UInt64(whole.count)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        for line in whole.split(separator: 0x0A, omittingEmptySubsequences: true) {
            Self.parse(Data(line), into: &t, from: start, iso: iso, isoPlain: isoPlain)
        }
    }

    nonisolated private static func parse(_ line: Data, into t: inout Transcript, from start: Date,
                              iso: ISO8601DateFormatter, isoPlain: ISO8601DateFormatter) {
        guard let r = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let type = r["type"] as? String
        if t.cwd == nil, let cwd = r["cwd"] as? String {
            t.cwd = cwd
            if isServicePath(cwd) { t.isService = true }
        }
        if t.session == nil { t.session = r["sessionId"] as? String }
        if type == "cost-state" {
            for (model, any) in (r["modelUsage"] as? [String: Any]) ?? [:] {
                guard let u = any as? [String: Any], let cost = (u["costUSD"] as? NSNumber)?.doubleValue, cost > 0 else { continue }
                let w = num(u["inputTokens"]) + 5 * num(u["outputTokens"])
                    + 0.1 * num(u["cacheReadInputTokens"]) + 1.25 * num(u["cacheCreationInputTokens"])
                if w > 1_000_000 { t.prices[baseModel(model), default: []].append(cost / w) }
            }
            return
        }
        guard let stamp = r["timestamp"] as? String,
              let at = iso.date(from: stamp) ?? isoPlain.date(from: stamp), at >= start else { return }
        let uuid = r["uuid"] as? String ?? UUID().uuidString
        switch type {
        case "system":
            guard r["subtype"] as? String == "turn_duration", !t.isSubagent,
                  (r["isSidechain"] as? Bool) != true else { return }
            let ms = num(r["durationMs"])
            guard ms > 0 else { return }
            t.turns.append(Turn(uuid: uuid, start: max(start, at.addingTimeInterval(-ms / 1000)), end: at))
        case "assistant":
            guard let message = r["message"] as? [String: Any], let id = message["id"] as? String else { return }
            let model = baseModel(message["model"] as? String ?? "")
            guard !model.isEmpty, model != "<synthetic>" else { return }
            let u = message["usage"] as? [String: Any] ?? [:]
            t.answers.append(Answer(id: id, at: at, model: model,
                                    input: Int(num(u["input_tokens"])), output: Int(num(u["output_tokens"])),
                                    cacheRead: Int(num(u["cache_read_input_tokens"])),
                                    cacheWrite: Int(num(u["cache_creation_input_tokens"]))))
        case "user":
            guard let result = r["toolUseResult"] as? [String: Any], let path = result["filePath"] as? String else { return }
            var added = 0, removed = 0
            if result["type"] as? String == "create", let content = result["content"] as? String {
                added = content.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } + (content.isEmpty || content.hasSuffix("\n") ? 0 : 1)
            }
            for hunk in (result["structuredPatch"] as? [[String: Any]]) ?? [] {
                for l in (hunk["lines"] as? [String]) ?? [] {
                    if l.hasPrefix("+") { added += 1 } else if l.hasPrefix("-") { removed += 1 }
                }
            }
            if added + removed > 0 { t.edits.append(Edit(uuid: uuid, at: at, path: path, added: added, removed: removed)) }
        default:
            return
        }
    }

    nonisolated private static func num(_ any: Any?) -> Double { (any as? NSNumber)?.doubleValue ?? 0 }
    nonisolated static func baseModel(_ m: String) -> String { m.split(separator: "[").first.map(String.init) ?? m }

    // MARK: Adding it up

    nonisolated static let generatedExtensions: Set<String> = ["xcstrings", "lock", "resolved", "pbxproj", "svg", "map", "snap"]
    nonisolated static let generatedNames: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Podfile.lock", "Cargo.lock"]

    /// A path whose lines say nothing about the code written: a temporary folder, Claude's own
    /// state, a report, a generated or lock file.
    nonisolated static func isCountedEdit(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if isServicePath(path + "/") || path.hasPrefix(home + "/.claude/") || path.contains("/artifacts/") { return false }
        let url = URL(fileURLWithPath: path)
        return !generatedExtensions.contains(url.pathExtension) && !generatedNames.contains(url.lastPathComponent)
    }

    private func tally(into raw: inout WeekRaw, from start: Date, to end: Date, calendar: Calendar) {
        var turnSeen = Set<String>(), answerSeen = Set<String>(), editSeen = Set<String>()
        var prices: [String: [Double]] = [:]
        var weighted = Array(repeating: [String: Double](), count: 7)
        var intervals: [(start: Date, end: Date, project: String?)] = []
        var files = Set<String>()
        var sessions = Set<String>()
        for t in transcripts.values {
            for (m, p) in t.prices { prices[m, default: []] += p }
            guard !t.isService else { continue }
            let project = t.cwd.map { project(of: $0) }
            for turn in t.turns where turnSeen.insert(turn.uuid).inserted && turn.end <= end {
                intervals.append((turn.start, turn.end, project))
                if let s = t.session { sessions.insert(s) }
            }
            for a in t.answers where answerSeen.insert(a.id).inserted && a.at < end {
                guard let d = Self.day(of: a.at, in: raw.bounds) else { continue }
                raw.tokensIn += a.input; raw.tokensOut += a.output
                raw.cacheRead += a.cacheRead; raw.cacheWrite += a.cacheWrite
                weighted[d][a.model, default: 0] += Double(a.input) + 5 * Double(a.output)
                    + 0.1 * Double(a.cacheRead) + 1.25 * Double(a.cacheWrite)
            }
            for e in t.edits where editSeen.insert(e.uuid).inserted && e.at < end && Self.isCountedEdit(e.path) {
                guard let d = Self.day(of: e.at, in: raw.bounds) else { continue }
                raw.added[d] += e.added; raw.removed[d] += e.removed
                files.insert(e.path)
            }
        }
        // The median of what Claude Code itself charged per weighted token, model by model.
        let price = prices.mapValues { $0.sorted()[$0.count / 2] }
        var unpricedWeight: [String: Double] = [:]
        var totalWeight = 0.0
        for d in 0..<7 {
            for (model, w) in weighted[d] {
                totalWeight += w
                if let p = price[model] { raw.costPerDay[d] += w * p } else { unpricedWeight[model, default: 0] += w }
            }
        }
        // A model nobody priced is named only when it did a noticeable share of the work; a few
        // calls to a small model do not make the receipt say it is incomplete.
        raw.unpriced = unpricedWeight.filter { totalWeight > 0 && $0.value / totalWeight > 0.01 }.keys.sorted()
        raw.files = files.count
        raw.sessions = sessions.count

        for iv in intervals {
            let length = iv.end.timeIntervalSince(iv.start)
            if length > raw.longestSec { raw.longestSec = length; raw.longestProject = iv.project; raw.longestEnd = iv.end }
            Self.spread(iv.start, iv.end, bounds: raw.bounds, calendar: calendar) { d, h, secs in
                raw.agentSec[d] += secs
                raw.heatSec[d][h] += secs
            }
        }
        for d in 0..<7 {
            let dayStart = raw.bounds[d], dayEnd = raw.bounds[d + 1]
            let clipped = intervals.compactMap { iv -> (Date, Date)? in
                let s = max(iv.start, dayStart), e = min(iv.end, dayEnd)
                return s < e ? (s, e) : nil
            }
            raw.wallSec[d] = Self.unionSeconds(clipped)
        }
        raw.peakParallel = Self.peak(intervals.map { ($0.start, $0.end) })
    }

    nonisolated static func day(of date: Date, in bounds: [Date]) -> Int? {
        guard date >= bounds[0], date < bounds[7] else { return nil }
        return (0..<7).first { date >= bounds[$0] && date < bounds[$0 + 1] }
    }

    /// Cuts an interval at every day and hour boundary (in the calendar's time zone) and hands each
    /// piece to `add` with its day, hour and length.
    nonisolated static func spread(_ start: Date, _ end: Date, bounds: [Date], calendar: Calendar = .bulavaWeek,
                                   add: (Int, Int, Double) -> Void) {
        var cursor = max(start, bounds[0])
        let stop = min(end, bounds[7])
        while cursor < stop {
            guard let d = day(of: cursor, in: bounds) else { break }
            let hour = calendar.component(.hour, from: cursor)
            let nextHour = calendar.nextDate(after: cursor, matching: DateComponents(minute: 0, second: 0),
                                             matchingPolicy: .nextTime) ?? stop
            let pieceEnd = min(nextHour, stop, bounds[d + 1])
            add(d, hour, pieceEnd.timeIntervalSince(cursor))
            cursor = pieceEnd
        }
    }

    nonisolated static func unionSeconds(_ intervals: [(Date, Date)]) -> Double {
        var total = 0.0
        var current: (Date, Date)?
        for iv in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let c = current, iv.0 <= c.1 {
                current = (c.0, max(c.1, iv.1))
            } else {
                if let c = current { total += c.1.timeIntervalSince(c.0) }
                current = iv
            }
        }
        if let c = current { total += c.1.timeIntervalSince(c.0) }
        return total
    }

    nonisolated static func peak(_ intervals: [(Date, Date)]) -> Int {
        var points: [(at: Date, step: Int)] = []
        for iv in intervals {
            points.append((iv.0, 1))
            points.append((iv.1, -1))
        }
        // An end and a start at the same instant do not overlap: the end goes first.
        points.sort { a, b in a.at == b.at ? a.step < b.step : a.at < b.at }
        var best = 0, current = 0
        for p in points { current += p.step; best = max(best, current) }
        return best
    }

    private func project(of cwd: String) -> String {
        let top = tops[cwd] ?? cwd
        var name = URL(fileURLWithPath: top).lastPathComponent
        // A Bulava work copy, "phone-app-a04f122d", is the same project as "phone-app".
        if let r = name.range(of: #"-[0-9a-f]{8}$"#, options: .regularExpression) { name.removeSubrange(r) }
        return name
    }

    // MARK: git

    private var workFolders: Set<String> {
        Set(transcripts.values.filter { !$0.isService && !$0.turns.isEmpty }.compactMap(\.cwd))
    }

    /// The repository each working folder belongs to, asked of git once per folder.
    private func resolveRepositories() async {
        for cwd in workFolders where tops[cwd] == nil {
            guard sources.readGit, FileManager.default.fileExists(atPath: cwd) else { tops[cwd] = cwd; continue }
            let r = await Shell.run(#"git -C "$1" rev-parse --show-toplevel"#, args: [cwd], timeout: 10)
            tops[cwd] = r.launched && r.exitCode == 0 ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : cwd
        }
    }

    private func tallyGit(into raw: inout WeekRaw, from start: Date, to end: Date) async {
        guard sources.readGit else { return }
        let cwds = workFolders
        let iso = ISO8601DateFormatter()
        var hashes = Set<String>()
        for top in Set(cwds.compactMap { tops[$0] }) where FileManager.default.fileExists(atPath: top + "/.git") {
            // Only the person's own commits: a client repository carries the whole team's. The same
            // person signs with more than one address, so the name counts as much as the email.
            var authors: [String] = []
            for key in ["user.email", "user.name"] {
                let r = await Shell.run(#"git -C "$1" config "$2""#, args: [top, key], timeout: 10)
                let value = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if r.launched, r.exitCode == 0, !value.isEmpty { authors.append(value) }
            }
            for author in authors {
                let log = await Shell.run(#"git -C "$1" log --branches --no-merges --format=%H --fixed-strings --author="$2" --since="$3" --until="$4""#,
                                          args: [top, author, iso.string(from: start), iso.string(from: end)], timeout: 30)
                for h in log.stdout.split(separator: "\n") { hashes.insert(String(h)) }
            }
        }
        raw.commits = hashes.count
    }

    // MARK: The engine's journal

    private func tallyJournal(into raw: inout WeekRaw, from start: Date, to end: Date) {
        guard let text = try? String(contentsOf: sources.decisions, encoding: .utf8) else { return }
        let iso = ISO8601DateFormatter()
        // A dispatch can end more than once (a review round, then the last word): keep the last.
        var lastEnd: [String: (Date, String)] = [:]
        for line in text.split(separator: "\n") {
            guard line.contains("\"ts\""),
                  let r = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let ts = r["ts"] as? String, let at = iso.date(from: ts), at >= start, at < end else { continue }
            switch r["kind"] as? String {
            case "terminal":
                let key = (r["dispatch_id"] as? String) ?? (r["event_id"] as? String) ?? UUID().uuidString
                lastEnd[key] = (at, (r["disposition"] as? String) ?? "")
            case "dispatch-delivered": raw.tasksGiven += 1
            case "peer-consultation": raw.codexConsults += 1
            case "question", "codex-decision-asked": raw.questions += 1
            default: break
            }
        }
        for (at, disposition) in lastEnd.values {
            guard let d = Self.day(of: at, in: raw.bounds) else { continue }
            switch disposition {
            case "passed": raw.passed[d] += 1
            case "debt": raw.debt[d] += 1
            case "needs-user", "scope_violation": raw.waiting[d] += 1
            default: break
            }
        }
    }

    // MARK: The person's messages

    private func tallyConversations(into raw: inout WeekRaw, from start: Date, to end: Date) {
        guard let data = try? Data(contentsOf: sources.conversations),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let iso = ISO8601DateFormatter()
        for m in list where m["kind"] as? String == "user" {
            guard let s = m["at"] as? String, let at = iso.date(from: s), at < end,
                  let d = Self.day(of: at, in: raw.bounds) else { continue }
            raw.prompts[d] += 1
        }
    }

    // MARK: Codex

    private func tallyCodex(into raw: inout WeekRaw, from start: Date, to end: Date) {
        let fm = FileManager.default
        var seen = Set<String>()
        guard let walker = fm.enumerator(at: sources.codexSessions, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, modified >= start else { continue }
            let size = UInt64(values.fileSize ?? 0)
            seen.insert(file.path)
            if let r = rollouts[file.path], r.size == size, r.modified == modified { continue }
            rollouts[file.path] = CodexRollout(size: size, modified: modified, growth: Self.codexGrowth(file, from: start, to: end))
        }
        for gone in rollouts.keys where !seen.contains(gone) { rollouts[gone] = nil }
        raw.codexTokens = rollouts.values.reduce(0) { $0 + $1.growth }
    }

    /// A rollout's `token_count` is cumulative for the session. What the week used is the last count
    /// inside it minus the last count before it — a session begun on Sunday does not bring Sunday in.
    nonisolated static func codexGrowth(_ file: URL, from start: Date, to end: Date) -> Int {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var before = 0, inside: Int?
        for line in text.split(separator: "\n") where line.contains("\"token_count\"") {
            guard let r = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let ts = r["timestamp"] as? String, let at = iso.date(from: ts),
                  let info = (r["payload"] as? [String: Any])?["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { continue }
            let count = Int(num(total["input_tokens"]) + num(total["output_tokens"]))
            if at < start { before = count } else if at < end { inside = count }
        }
        guard let inside else { return 0 }
        return max(0, inside - before)
    }
}
