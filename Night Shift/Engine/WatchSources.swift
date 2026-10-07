import AppKit
import CryptoKit
import EventKit
import Foundation

/// One look at whatever an automation watches. No model is involved: a watch costs a git fetch,
/// an HTTP request or a question to Mail, and a run is only started when it finds something.
///
/// Every source answers in the same shape — what is new, where it got to, what went wrong — and an
/// empty answer and a failed one are never the same thing.
nonisolated struct WatchCheck: Sendable, Equatable {
    var items: [WatchItem]
    /// The source's new position, when it has one. Nil leaves the old one.
    var cursor: String?
    /// Why the look failed, in words. A failure is never read as "nothing new".
    var error: String?
    /// The one thing that takes the failure down, when there is one he can press.
    var fix: WatchFix? = nil
    /// Something worth saying about a look that still went through — a fetch that failed while
    /// the local branch was read anyway.
    var warning: String? = nil

    init(items: [WatchItem], cursor: String?, error: String? = nil, fix: WatchFix? = nil, warning: String? = nil) {
        self.items = items
        self.cursor = cursor
        self.error = error
        self.fix = fix
        self.warning = warning
    }

    static func failed(_ why: String, fix: WatchFix? = nil) -> WatchCheck {
        WatchCheck(items: [], cursor: nil, error: why, fix: fix)
    }
}

enum WatchSources {

    static func check(_ trigger: AutomationTrigger, state: WatchState, now: Date) async -> WatchCheck {
        // Whether a question from macOS may appear now: only while Bulava is in front of him. A
        // first look at the calendar or at Mail used to ask whenever it happened — at three in the
        // morning, too, to nobody. Those are asked when the automation is made (`AutomationNeeds`).
        let mayAsk = await MainActor.run { NSApplication.shared.isActive }
        switch trigger {
        case .watch(let watch):
            switch watch.source {
            case .commits(let repo, let branch): return await commits(repo: repo, branch: branch, cursor: state.cursor)
            case .feed(let url): return await feed(url, cursor: state.cursor)
            case .huggingFace(let author, let search): return await huggingFace(author: author, search: search)
            case .webPage(let url): return await webPage(url, cursor: state.cursor)
            }
        case .event(let event):
            switch event.kind {
            case .mail(let from, let subject):
                return await mail(from: from, subject: subject, since: state.lastSucceededAt ?? state.lastCheckedAt, now: now,
                                  mayAsk: mayAsk)
            case .folder(let path): return folder(path)
            case .meetingEnded(let title):
                return await meetingsEnded(titleContains: title, since: state.lastSucceededAt ?? state.lastCheckedAt, now: now,
                                           mayAsk: mayAsk)
            }
        case .manual, .schedule:
            return WatchCheck(items: [], cursor: nil, error: nil)
        }
    }

    /// How often a trigger is looked at.
    static func interval(_ trigger: AutomationTrigger) -> TimeInterval {
        switch trigger {
        case .watch(let w): return TimeInterval(max(5, w.everyMinutes) * 60)
        case .event(let e):
            switch e.kind {
            case .mail: return 5 * 60
            case .folder: return 10 * 60
            case .meetingEnded: return 60
            }
        case .manual, .schedule: return .infinity
        }
    }

    /// How long a burst is gathered before one run takes all of it: a quiet spell, and a cap on how
    /// long a steady trickle can keep it waiting. Twenty letters make one run, not twenty.
    static func gathering(_ trigger: AutomationTrigger) -> (quiet: TimeInterval, longest: TimeInterval) {
        switch trigger {
        case .event(let e):
            switch e.kind {
            case .mail: return (120, 15 * 60)
            case .folder: return (120, 30 * 60)
            case .meetingEnded: return (0, 0)
            }
        default: return (0, 0)
        }
    }

    // MARK: Commits

    static func commits(repo: String, branch: String?, cursor: String?) async -> WatchCheck {
        guard FileManager.default.fileExists(atPath: repo) else {
            return .failed(String(format: String(localized: "The folder %@ is not there."), repo))
        }
        guard await WorkCopies.topLevel(of: repo) != nil else {
            return .failed(String(localized: "The folder is not a git repository."))
        }
        let fetch = await WorkCopies.git(["fetch", "--quiet", "--prune", "origin"], in: repo, timeout: 180)
        let name: String
        if let branch, !branch.isEmpty { name = branch } else { name = await WorkCopies.defaultBranch(of: repo) ?? "" }
        guard !name.isEmpty else { return .failed(String(localized: "Could not tell which branch to watch.")) }
        let remote = "refs/remotes/origin/\(name)"
        let ref = await WorkCopies.refExists(remote, in: repo) ? remote : "refs/heads/\(name)"
        let tipResult = await WorkCopies.git(["rev-parse", "--verify", "--quiet", ref], in: repo)
        let tip = tipResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tipResult.ok, !tip.isEmpty else {
            return .failed(String(format: String(localized: "There is no branch “%@” to watch."), name))
        }
        // A fetch that did not work is said, but what is already here is still read: the local
        // branch can have moved by itself.
        let fetchNote: String? = fetch.ok ? nil : String(localized: "Could not fetch from the remote; read what is on this Mac.")
        guard let cursor, !cursor.isEmpty else {
            return WatchCheck(items: [], cursor: tip, warning: fetchNote)
        }
        guard cursor != tip else { return WatchCheck(items: [], cursor: tip, warning: fetchNote) }
        // Oldest first, in topological order, and a page at a time: the cursor moves to the last
        // commit actually read, so a range longer than a page is finished on the next look instead
        // of being skipped. A log that did not run moves nothing.
        let log = await WorkCopies.git(["log", "--topo-order", "--reverse", "--format=%H%x1f%an%x1f%aI%x1f%s",
                                        tip, "--not", cursor], in: repo, timeout: 120)
        guard log.ok else {
            return .failed(String(localized: "Could not read the new commits; the next look tries again from the same place."))
        }
        let iso = ISO8601DateFormatter()
        let all = log.stdout.split(separator: "\n").compactMap { line -> WatchItem? in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { return nil }
            return WatchItem(id: f[0], title: "\(f[0].prefix(8)) \(f[3])", detail: f[1], at: iso.date(from: f[2]))
        }
        let page = Array(all.prefix(Self.commitPage))
        let reached = all.count > page.count ? (page.last?.id ?? tip) : tip
        return WatchCheck(items: page, cursor: reached, warning: fetchNote)
    }

    /// Commits taken in one look. The rest are taken on the next one, from where this one stopped.
    static let commitPage = 200

    // MARK: Feeds

    private struct Validators: Codable { var etag: String?; var modified: String? }

    static func feed(_ address: String, cursor: String?) async -> WatchCheck {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else {
            return .failed(String(localized: "That is not a web address."))
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bulava", forHTTPHeaderField: "User-Agent")
        let old = cursor.flatMap { try? JSONDecoder().decode(Validators.self, from: Data($0.utf8)) }
        if let etag = old?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = old?.modified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 304 { return WatchCheck(items: [], cursor: cursor, error: nil) }
            guard let http, (200..<300).contains(http.statusCode) else {
                return .failed(String(format: String(localized: "The feed answered %@."), String((response as? HTTPURLResponse)?.statusCode ?? 0)))
            }
            let items = FeedParser.items(in: data)
            let next = Validators(etag: http.value(forHTTPHeaderField: "ETag"),
                                  modified: http.value(forHTTPHeaderField: "Last-Modified"))
            let encoded = (try? JSONEncoder().encode(next)).flatMap { String(data: $0, encoding: .utf8) }
            return WatchCheck(items: items, cursor: encoded, error: items.isEmpty && data.count > 0
                              && !FeedParser.looksLikeFeed(data) ? String(localized: "That address is not an RSS or Atom feed.") : nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Hugging Face

    static func huggingFace(author: String, search: String?) async -> WatchCheck {
        var parts = URLComponents(string: "https://huggingface.co/api/models")!
        var query = [URLQueryItem(name: "author", value: author),
                     URLQueryItem(name: "sort", value: "createdAt"),
                     URLQueryItem(name: "direction", value: "-1"),
                     URLQueryItem(name: "limit", value: "50")]
        if let search, !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        parts.queryItems = query
        guard let url = parts.url else { return .failed(String(localized: "That author name cannot be looked up.")) }
        do {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("Bulava", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed(String(format: String(localized: "Hugging Face answered %@."),
                                      String((response as? HTTPURLResponse)?.statusCode ?? 0)))
            }
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .failed(String(localized: "Hugging Face sent something that is not a model list."))
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let items = rows.compactMap { row -> WatchItem? in
                guard let id = row["id"] as? String ?? row["modelId"] as? String else { return nil }
                let tag = row["pipeline_tag"] as? String
                return WatchItem(id: id, title: id, detail: tag, link: "https://huggingface.co/\(id)",
                                 at: (row["createdAt"] as? String).flatMap { iso.date(from: $0) })
            }
            return WatchCheck(items: items, cursor: nil, error: nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: A page

    static func webPage(_ address: String, cursor: String?) async -> WatchCheck {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else {
            return .failed(String(localized: "That is not a web address."))
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("Bulava", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed(String(format: String(localized: "The page answered %@."),
                                      String((response as? HTTPURLResponse)?.statusCode ?? 0)))
            }
            let text = PageText.visibleText(String(decoding: data, as: UTF8.self))
            let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            guard let cursor, !cursor.isEmpty else { return WatchCheck(items: [], cursor: digest, error: nil) }
            guard cursor != digest else { return WatchCheck(items: [], cursor: digest, error: nil) }
            let title = PageText.title(String(decoding: data, as: UTF8.self)) ?? url.host() ?? address
            let item = WatchItem(id: "page:\(digest)", title: String(format: String(localized: "Changed: %@"), title),
                                 detail: String(text.prefix(4_000)), link: address, at: Date())
            return WatchCheck(items: [item], cursor: digest, error: nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Mail

    /// New letters in Mail's inbox, asked of Mail itself — every account he has there, and no
    /// Google approval to apply for. Mail has to be open; Bulava does not open it for him.
    static func mail(from: String, subject: String, since: Date?, now: Date, mayAsk: Bool = true) async -> WatchCheck {
        if !mayAsk, await AutomationNeeds.mailState(asking: false) == .askNow {
            return .failed(String(localized: "Bulava has not been allowed to read Mail yet. Allow it in the automation's settings — a question shown at night would wait for nobody."),
                           fix: .automationPrivacy)
        }
        let window = Int(max(600, now.timeIntervalSince(since ?? now.addingTimeInterval(-3600)) + 600))
        let script = """
        if application "Mail" is not running then return "BULAVA_NOT_RUNNING"
        set us to character id 31
        set rs to character id 30
        tell application "Mail"
          set cutoff to (current date) - \(window)
          set found to (messages of inbox whose date received > cutoff and sender contains "\(escape(from))" and subject contains "\(escape(subject))")
          set out to ""
          repeat with m in found
            set letterText to ""
            try
              set letterText to content of m
              if (length of letterText) > 4000 then set letterText to text 1 thru 4000 of letterText
            end try
            set out to out & (message id of m) & us & (sender of m) & us & (subject of m) & us & ((date received of m) as «class isot» as string) & us & letterText & rs
          end repeat
          return out
        end tell
        """
        let r = await Shell.run("osascript -e \"$1\"", args: [script], timeout: 90)
        let text = r.stdout
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "BULAVA_NOT_RUNNING" {
            return .failed(String(localized: "Mail is not open, so no letters were read. They are picked up once it is."),
                           fix: .openMail)
        }
        guard r.ok else {
            if r.combined.contains("-1743") || r.combined.contains("Not authorized") {
                return .failed(String(localized: "Bulava is not allowed to read Mail. Allow it in System Settings → Privacy & Security → Automation."),
                               fix: .automationPrivacy)
            }
            return .failed(r.combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return WatchCheck(items: mailItems(text), cursor: nil, error: nil)
    }

    /// Mail's answer, one letter per record: id, sender, subject, time, text — fields split by the
    /// unit separator and records by the record separator, which no letter is going to contain.
    nonisolated static func mailItems(_ text: String) -> [WatchItem] {
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return text.split(separator: "\u{1e}").compactMap { record -> WatchItem? in
            let f = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { return nil }
            let id = f[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let sender = f[1].trimmingCharacters(in: .whitespacesAndNewlines)
            // The text of a letter can hold the separators' neighbours; everything after the fourth
            // field is the letter.
            let body = f[4...].joined(separator: "\u{1f}")
            return WatchItem(id: "mail:\(id)", title: "\(f[2]) — \(sender)", detail: body,
                             at: iso.date(from: f[3].trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: A folder

    /// The files directly in a folder, each named by its path, size and time: a file that is still
    /// being written shows up again with a new name, and only the last one of those is run on.
    static func folder(_ path: String) -> WatchCheck {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return .failed(String(format: String(localized: "The folder %@ is not there."), path))
        }
        guard let names = try? fm.contentsOfDirectory(atPath: path) else {
            return .failed(String(localized: "The folder cannot be read."))
        }
        var items: [WatchItem] = []
        for name in names where !name.hasPrefix(".") {
            let full = (path as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attrs[.modificationDate] as? Date
            let stamp = Int(modified?.timeIntervalSince1970 ?? 0)
            items.append(WatchItem(id: "file:\(full)|\(size)|\(stamp)", title: name,
                                   detail: full, link: full, at: modified))
        }
        return WatchCheck(items: items.sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) },
                          cursor: nil, error: nil)
    }

    // MARK: Meetings

    @MainActor static let calendarStore = EKEventStore()

    /// Calendar events that ended since the last look. "Ended" is the scheduled end — the calendar
    /// does not know when a call actually hung up — read two minutes late so a meeting that runs a
    /// little over is not interrupted.
    static func meetingsEnded(titleContains: String, since: Date?, now: Date, mayAsk: Bool = true) async -> WatchCheck {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined, !mayAsk {
            return .failed(String(localized: "Bulava has not been allowed to read the calendar yet. Allow it in the automation's settings — a question shown at night would wait for nobody."),
                           fix: .calendarPrivacy)
        }
        if status == .notDetermined {
            let granted = (try? await calendarStore.requestFullAccessToEvents()) ?? false
            if !granted { return .failed(String(localized: "Bulava is not allowed to read the calendar."), fix: .calendarPrivacy) }
        } else if status != .fullAccess {
            return .failed(String(localized: "Bulava is not allowed to read the calendar. Allow it in System Settings → Privacy & Security → Calendars."),
                           fix: .calendarPrivacy)
        }
        let until = now.addingTimeInterval(-120)
        let from = since?.addingTimeInterval(-120) ?? until
        guard until > from else { return WatchCheck(items: [], cursor: nil, error: nil) }
        let predicate = calendarStore.predicateForEvents(withStart: from.addingTimeInterval(-24 * 3600), end: until, calendars: nil)
        let wanted = titleContains.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let iso = ISO8601DateFormatter()
        let items = calendarStore.events(matching: predicate).compactMap { event -> WatchItem? in
            guard !event.isAllDay, let end = event.endDate, end > from, end <= until else { return nil }
            let title = event.title ?? ""
            if !wanted.isEmpty, !title.lowercased().contains(wanted) { return nil }
            let start = event.startDate.map { iso.string(from: $0) } ?? ""
            return WatchItem(id: "event:\(event.calendarItemIdentifier)|\(start)", title: title,
                             detail: event.calendar?.title, at: end)
        }
        return WatchCheck(items: items, cursor: nil, error: nil)
    }
}

// MARK: - Reading feeds and pages

nonisolated enum FeedParser {
    static func looksLikeFeed(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(2_000), as: UTF8.self).lowercased()
        return head.contains("<rss") || head.contains("<feed") || head.contains("<rdf")
    }

    /// RSS `<item>` and Atom `<entry>`, newest wherever the feed put them.
    static func items(in data: Data) -> [WatchItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [WatchItem] = []
        private var inEntry = false
        private var field = ""
        private var text = ""
        private var title = "", link = "", guid = "", date = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let n = name.lowercased()
            if n == "item" || n == "entry" {
                inEntry = true; title = ""; link = ""; guid = ""; date = ""
            }
            if inEntry, n == "link", let href = attributes["href"], link.isEmpty { link = href }
            field = n; text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let n = name.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard inEntry else { return }
            switch n {
            case "title": if title.isEmpty { title = value }
            case "link": if link.isEmpty { link = value }
            case "guid", "id": if guid.isEmpty { guid = value }
            case "pubdate", "updated", "published": if date.isEmpty { date = value }
            case "item", "entry":
                inEntry = false
                let id = !guid.isEmpty ? guid : (!link.isEmpty ? link : title)
                if !id.isEmpty {
                    items.append(WatchItem(id: "feed:\(id)", title: title.isEmpty ? id : title,
                                           link: link.isEmpty ? nil : link))
                }
            default: break
            }
            text = ""
        }
    }
}

nonisolated enum PageText {
    static func title(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let close = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: close.upperBound..<html.endIndex)
        else { return nil }
        let t = html[close.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(120))
    }

    /// The words a person would see: scripts, styles and tags out, whitespace folded. A page whose
    /// markup changes every load but whose text does not is not "changed".
    static func visibleText(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg"] {
            while let open = s.range(of: "<\(tag)", options: .caseInsensitive),
                  let close = s.range(of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; out.append(" "); continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
