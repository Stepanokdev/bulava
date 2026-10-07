import Foundation
import CryptoKit

/// What Bulava tells us about a failure that stopped somebody's work — and nothing else.
///
/// The fields are a closed list, and every one of them is either something we chose (a code, a
/// category, a version) or text that went through `ReportScrubber` first. There is no install id,
/// no account, no project name, no path, no chat text. Two reports from the same Mac cannot be told
/// apart from two reports from two Macs, which is what makes them anonymous rather than merely
/// unsigned.
///
/// Every outcome is reported, not only repairs that worked: the failures nobody could fix are the
/// ones that most need to reach us.
nonisolated struct IncidentReport: Codable, Equatable, Sendable {
    /// The schema of this payload. The server rejects any other.
    var v = 1
    /// Random, made for this one incident. Lets the server drop a retried upload.
    var id: String
    /// Where in Bulava it happened, in our own words: `chat.start_failed`, `engine.install_failed`.
    var code: String
    /// The same failure on two machines, in two languages, groups under one value.
    var fingerprint: String
    /// The error with everything personal taken out — see `ReportScrubber`.
    var message: String
    /// fixed (the engine confirmed delivery after the repair) · unverified (repaired, delivery not
    /// confirmed or not attempted again) · not_fixed · needs_user · not_attempted · repair_unavailable
    var outcome: String
    /// The repair's category for the cause, or `unknown`.
    var cause: String
    /// The repair's description of a defect in Bulava or its engine, scrubbed. Empty when none.
    var productBug: String
    /// codex · claude · none
    var agent: String
    var durationSeconds: Int
    var app: String
    var engine: String
    var os: String
    var channel: String
    var language: String
    var arch: String

    enum CodingKeys: String, CodingKey {
        case v, id, code, fingerprint, message, outcome, cause, agent, app, engine, os, channel
        case language, arch
        case productBug = "product_bug"
        case durationSeconds = "duration_s"
    }

    static let outcomes: Set<String> = ["fixed", "unverified", "not_fixed", "needs_user",
                                        "not_attempted", "repair_unavailable"]
}

/// Takes the personal parts out of an error message.
///
/// Known things go first, by value — the home folder, the user's name, the project folders and
/// names in play — because a pattern cannot know that "pocket-ledger" is somebody's client. Then
/// patterns catch what is left: any absolute path, quoted names, addresses, links, things shaped
/// like keys or tokens, identifiers, long numbers. What survives is the sentence Bulava or the
/// engine wrote, with holes where the specifics were — which is exactly what a developer needs to
/// find the line that wrote it.
nonisolated enum ReportScrubber {

    static let limit = 400

    static func scrub(_ text: String, known: [String] = []) -> String {
        var s = text
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = NSUserName()
        let host = ProcessInfo.processInfo.hostName
        // Longest first, so a project path is not half-replaced by its own parent.
        let values = (known + [home, user, NSFullUserName(), host])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
        for value in values {
            s = s.replacingOccurrences(of: value, with: value.hasPrefix("/") ? "<path>" : "<name>",
                                       options: .caseInsensitive)
        }
        let rules: [(String, String)] = [
            // Secrets first: shaped like keys, wherever they sit.
            (#"(?i)\b(sk|pk|rk|ghp|gho|ghs|github_pat|xox[abprs]|glpat|AKIA|AIza)[-_A-Za-z0-9]{8,}"#, "<secret>"),
            (#"(?i)\b(bearer|token|password|passwd|secret|api[_-]?key)\s*[:=]\s*\S+"#, "$1=<secret>"),
            (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]+"#, "<secret>"),
            // A remote's address before an e-mail's: `git@host:owner/repo.git` is shaped like one,
            // and matching it as an address would leave the owner and the repository behind.
            (#"(?i)\b[a-z0-9._-]+@[^\s:@]+:[^\s]+"#, "<url>"),
            (#"(?i)\b[a-z][a-z0-9+.-]*://\S+"#, "<url>"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
            // A path is a slash followed by anything up to the end of the token — and a path with a
            // space in it is two tokens, so the rest of it goes too, as long as it still looks like
            // a path (has another slash).
            (#"(?:~|/)(?:[^\s/"'“”«»()<>]+/)+[^\s"'“”«»()<>,;]*"#, "<path>"),
            (#"<path>(?: [^\s/"'“”«»()<>]+/[^\s"'“”«»()<>,;]*)+"#, "<path>"),
            // Names the app quotes: “Ledger”, «Ledger», "Ledger", 'Ledger'.
            (#"“[^”\n]{1,120}”"#, "“…”"),
            (#"«[^»\n]{1,120}»"#, "«…»"),
            (#""[^"\n]{1,120}""#, "\"…\""),
            (#"(?<![A-Za-z])'[^'\n]{1,120}'"#, "'…'"),
            (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, "<id>"),
            (#"\b[0-9a-f]{12,}\b"#, "<hash>"),
            (#"\b[A-Za-z0-9+/_-]{32,}={0,2}"#, "<secret>"),
            (#"\b\d{3,}\b"#, "<n>"),
            (#"(?:<path>)+"#, "<path>"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > limit { s = String(s.prefix(limit)) + "…" }
        return s
    }

    /// One value per kind of failure: the code plus the scrubbed text with its specifics gone,
    /// lower-cased, digits and punctuation dropped. The same refusal about two different folders
    /// is one group.
    static func fingerprint(code: String, scrubbed: String) -> String {
        let shape = scrubbed.lowercased()
            .replacingOccurrences(of: #"<[a-z]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-zа-яіїєґ ]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let digest = SHA256.hash(data: Data((code + "|" + shape).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated extension IncidentReport {

    /// Versions and machine facts — the things that make a failure reproducible and say nothing
    /// about who had it.
    static func make(id: UUID = UUID(), code: String, rawMessage: String, known: [String],
                     outcome: String, cause: String = "unknown", productBug: String = "",
                     agent: String = "none", duration: TimeInterval = 0) -> IncidentReport {
        let message = ReportScrubber.scrub(rawMessage, known: known)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let engineVersion = OrchestratorHome.detect().flatMap { OrchestratorHome.version(of: $0) } ?? "dev"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return IncidentReport(
            id: id.uuidString.lowercased(), code: code,
            fingerprint: ReportScrubber.fingerprint(code: code, scrubbed: message),
            message: message,
            outcome: IncidentReport.outcomes.contains(outcome) ? outcome : "not_fixed",
            cause: RepairSession.Finding.causes.contains(cause) ? cause : "unknown",
            productBug: productBug.isEmpty ? "" : ReportScrubber.scrub(productBug, known: known),
            agent: agent, durationSeconds: max(0, Int(duration.rounded())),
            app: "\(version) (\(build))", engine: engineVersion,
            os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            channel: AppChannel.current.isDev ? "dev" : "production",
            language: Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en",
            arch: arch)
    }
}
