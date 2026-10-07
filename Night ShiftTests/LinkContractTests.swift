import XCTest
@testable import Bulava

/// The wire contract with the phone, pinned to files both sides read.
///
/// Every file in `link-protocol/fixtures/v1/` is what the Mac's DTOs encode to, byte for byte. The
/// phone's own tests decode the same files, so a change to what the Mac sends that is not also
/// made on the phone fails on the phone's side, before any release.
///
/// When a change here is intended — a field ADDED under the rules in `link-protocol/README.md` —
/// regenerate with `BULAVA_UPDATE_FIXTURES=1` and commit the files together with the phone's
/// change. Renaming or removing a field is never such a change within one protocol version.
nonisolated final class LinkContractTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("link-protocol")

    private static var fixtures: URL { root.appendingPathComponent("fixtures/v1") }

    private func check<T: Encodable>(_ value: T, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value) + Data("\n".utf8)
        let url = Self.fixtures.appendingPathComponent(name + ".json")
        if ProcessInfo.processInfo.environment["BULAVA_UPDATE_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
            try data.write(to: url)
            return
        }
        let stored = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), String(decoding: stored, as: UTF8.self),
                       "\(name).json no longer matches what the Mac sends. If the change is additive and intended, regenerate the fixtures and update the phone in the same change.",
                       file: file, line: line)
    }

    // MARK: - The version and what is offered

    func testTheContractFileMatchesTheCode() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("contract.json"))
        let contract = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(contract["protocolVersion"] as? Int, LinkProtocol.version)
        XCTAssertEqual(contract["minimumVersion"] as? Int, LinkProtocol.minimumVersion)
        XCTAssertEqual(Set(contract["capabilities"] as? [String] ?? []), Set(LinkProtocol.capabilities),
                       "a capability offered or withdrawn must be written into contract.json, where the phone's tests read it")
    }

    // MARK: - Samples

    func testHandshake() throws {
        try check(LinkHello(protocolVersion: 1, minimumVersion: 1,
                            app: LinkClientApp(platform: "android", version: "1.0", deviceName: "Pixel 9", osVersion: "Android 17"),
                            pairing: .init(token: "pairing-token"), credential: nil), "hello-pairing")
        try check(LinkHello(protocolVersion: 1, minimumVersion: 1,
                            app: LinkClientApp(platform: "ios", version: "1.0", deviceName: "iPhone", osVersion: "iOS 26.0"),
                            pairing: nil, credential: LinkCredential(deviceID: "D1", secret: "S1")), "hello-credential")
        try check(LinkWelcome(protocolVersion: 1, desktop: Self.desktop, capabilities: LinkProtocol.capabilities.sorted(),
                              deviceID: "D1", credential: LinkCredential(deviceID: "D1", secret: "S1")), "welcome")
        try check(LinkRefusal(code: LinkErrorCode.protocolTooOld, message: "Update the app.",
                              desktopVersion: "1.9", protocolVersion: 1, phoneApps: Self.phoneApps), "refused")
    }

    func testHome() throws {
        try check(LinkEvent(event: "home", data: HomeDTO(
            desktop: Self.desktop,
            products: [ProductDTO(
                id: "P1", name: "Narada", initials: "N", pinned: true, brief: "Meeting recorder",
                icon: FileDTO(ref: "icon:P1", name: "icon.png", kind: "image", size: 2048, url: nil),
                status: StatusDTO(code: "running", label: "Running", tone: "active", active: true),
                lastWorkedAtMs: 1_790_000_000_000,
                chats: [Self.chatSummary],
                archivedChats: [])],
            attention: [AttentionDTO(id: "ask:trust:C1:E1", productID: "P1", chatID: "C1", kind: "ask",
                                     title: "Export fix", body: "Claude Code asks before working in a folder for the first time.",
                                     tone: "attention", atMs: 1_790_000_000_000,
                                     actions: [Self.invoke, Self.onMac]),
                        AttentionDTO(id: "task.dirty:A1", productID: "P1", chatID: nil, kind: "ask",
                                     title: "Export fix", body: "“Export fix” did not start: the folder has uncommitted changes.",
                                     tone: "attention", atMs: 1_789_999_000_000,
                                     actions: [ActionDTO(id: "task.dirty.commit:A1", label: "Commit as me…", style: "secondary",
                                                         kind: "invoke", confirm: nil,
                                                         input: ActionInputDTO(placeholder: "Commit message", required: true,
                                                                               value: "WIP: App.swift", title: "A commit in your name",
                                                                               above: [InputNoteDTO(text: "Author: Ivan <ivan@example.com>")],
                                                                               below: [InputNoteDTO(text: "Everything below goes into one commit on “main”.", tone: "faint"),
                                                                                       InputNoteDTO(text: "M  App.swift", mono: true)],
                                                                               submit: "Commit and start", blocked: nil),
                                                         target: nil, disabledReason: nil)],
                                     code: "M  App.swift")],
            composer: ComposerOptionsDTO(
                groups: [
                    OptionGroupDTO(id: "claudeModel", title: "Claude",
                                   options: [OptionDTO(id: "auto", label: "Automatic", detail: nil),
                                             OptionDTO(id: "opus", label: "Opus · Opus 5.5", detail: "The newest Opus.",
                                                       section: "Newest of each"),
                                             OptionDTO(id: "claude-opus-4-7", label: "Opus 4.7", detail: nil,
                                                       section: "A fixed version")],
                                   selected: "opus", engine: "claude", kind: "model"),
                    OptionGroupDTO(id: "claudeEffort", title: "Claude thinks",
                                   options: [OptionDTO(id: "auto", label: "Automatic · High", detail: nil),
                                             OptionDTO(id: "max", label: "Max", detail: nil)],
                                   selected: "max", engine: "claude", kind: "depth"),
                ],
                summary: [RunPartDTO(engine: "claude", name: "Claude", model: "Opus 5.5", depth: "Max"),
                          RunPartDTO(engine: "codex", name: "Codex", model: "GPT-5.5", depth: "High")]),
            readiness: [ReadinessDTO(id: "engine", title: "The work engine is installed", detail: "",
                                     state: "problem", actions: [Self.invoke])],
            finished: [FinishedDTO(id: "done:T1", productID: "P1", chatID: "C1", title: "Export fix",
                                   body: "Report ready", atMs: 1_790_000_000_000,
                                   report: ActionDTO(id: "done.report:T1", label: "Open the report", style: "primary",
                                                     kind: "report", target: "done.report:T1"))],
            summary: SummaryDTO(working: 2, waiting: 1, ready: 1),
            live: LiveDTO(
                running: [LiveLineDTO(id: "chat:C1", productID: "P1", chatID: "C1", title: "Export fix",
                                      product: "Narada", sinceMs: 1_790_000_000_000, outcome: nil)],
                ended: [LiveLineDTO(id: "task:T1", productID: "P1", chatID: nil, title: "Import speed",
                                    product: "Narada", sinceMs: 1_789_990_000_000, outcome: "done",
                                    label: "Report ready")],
                over: false),
            limits: LimitsDTO(title: "Limits", engines: [
                EngineLimitsDTO(name: "Claude", used: 81, pressure: "tight", windows: [
                    LimitWindowDTO(label: "Session", used: 34, usedLabel: "34% used", pressure: "comfortable", resets: "2h 5m"),
                    LimitWindowDTO(label: "Weekly", used: 81, usedLabel: "81% used", pressure: "tight", resets: "3d 4h"),
                ], note: nil, stale: false, readAgo: nil),
                EngineLimitsDTO(name: "Codex", used: nil, pressure: "comfortable", windows: [],
                                note: "Not known yet — it fills in when something runs", stale: true, readAgo: "2 hours ago"),
            ]),
            phoneApps: Self.phoneApps)), "home")
    }

    func testChat() throws {
        try check(LinkEvent(event: "chat", data: ChatDTO(
            id: "C1", productID: "P1", title: "Export fix", archived: false,
            status: StatusDTO(code: "working", label: "Night Shift is working", tone: "active", active: true),
            activity: "Reading ExportController.swift", degradation: nil, queueCount: 1, busy: true,
            entries: Self.entries, hasEarlier: true,
            actions: [ActionDTO(id: "stop:C1", label: "Stop", style: "secondary", kind: "invoke")],
            composer: Self.chatComposer)), "chat")
        try check(LinkEvent(event: "chat.delta", data: ChatDeltaDTO(
            id: "C1",
            header: ChatHeaderDTO(title: "Export fix", archived: false,
                                  status: StatusDTO(code: "ready", label: "Night Shift replied", tone: "good", active: false),
                                  activity: nil, degradation: nil, queueCount: 0, busy: false, hasEarlier: true, actions: [],
                                  composer: Self.chatComposer),
            upserts: [Self.entries[1]], removed: ["E0"], order: ["E1", "E2"])), "chat-delta")
    }

    func testResults() throws {
        try check(LinkResponse(id: "R1", ok: true, result: SentDTO(entryID: "E9", duplicate: false), error: nil), "response-sent")
        try check(LinkResponse<LinkEmpty>(id: "R2", ok: false, result: nil,
                                          error: LinkError(code: LinkErrorCode.stale, message: "This was already handled on your Mac.")),
                  "response-stale")
        try check(LinkResponse(id: "R3", ok: true,
                               result: FileChunkDTO(ref: "att:A1", offset: 0, total: 3, data: "AAEC", mime: "image/png", name: "shot.png"),
                               error: nil), "response-file")
        try check(LinkResponse(id: "R4", ok: true,
                               result: ReportDTO(title: "Export fix", html: "<p>Done</p>", root: "rep:abc",
                                                 actions: [ActionDTO(id: "report.merge:T1", label: "Merge it in", style: "primary",
                                                                     kind: "invoke", confirm: "Merge it in")]),
                               error: nil), "response-report")
        try check(LinkResponse(id: "R11", ok: true,
                               result: ReportDTO(title: "What to build next", html: "<p>Plan</p>", root: "rep:def",
                                                 decisions: DecisionsDTO(
                                                    ref: "dec:0123456789abcdef01234567", title: "What to build next",
                                                    revision: "a1b2c3d4e5f6a1b2c3d4e5f6",
                                                    items: [DecisionItemDTO(id: "leak", title: "Close the password leak",
                                                                            detail: "Workers inherit the browser.",
                                                                            options: ["Take it", "Later", "No"],
                                                                            recommended: "Take it", comment: true),
                                                            DecisionItemDTO(id: "keychain", title: "Keep logins in the Keychain",
                                                                            detail: nil, options: ["Now", "Never"],
                                                                            recommended: nil, comment: false)],
                                                    latest: DecisionSentDTO(id: "9F2C1D8E-6B1A-4C1E-9E61-0A4B2C3D4E5F",
                                                                            sentAt: 1_791_000_000_000, device: "mac",
                                                                            choices: ["leak": "Take it"],
                                                                            comments: ["leak": "first thing tomorrow"],
                                                                            general: ""))),
                               error: nil), "response-report-decisions")
        try check(LinkResponse<LinkEmpty>(id: "R12", ok: false, result: nil,
                                          error: LinkError(code: LinkErrorCode.decisionsConflict,
                                                           message: "Decisions for this report were sent from another device meanwhile. Look at them before sending yours.")),
                  "response-decisions-conflict")
        try check(LinkResponse(id: "R5", ok: true,
                               result: [OptionDTO(id: "/review", label: "/review", detail: "[file] — Review the changes")],
                               error: nil), "response-commands")
        try check(LinkResponse(id: "R10", ok: true,
                               result: FileOpenDTO(url: "http://192.168.1.20:47292/s/p7ubM5qb0saPxViWboo6Ag/index.html",
                                                   title: "index.html", scope: "site"),
                               error: nil), "response-open")
        try check(LinkResponse(id: "R9", ok: true,
                               result: TranscriptDTO(requestID: "V1", chatID: "C1", text: "Зроби експорт сірим, поки немає транскрипту"),
                               error: nil), "response-transcript")
    }

    func testContextAndSkills() throws {
        let report = ActionDTO(id: "productReport:P1", label: "Everything done so far", style: "secondary",
                               kind: "report", target: "productReport:P1")
        try check(LinkResponse(id: "R6", ok: true, result: ContextDTO(
            productID: "P1",
            resources: [ResourceDTO(id: "R1", name: "Narada", kind: "repository", kindLabel: "Repository",
                                    access: "workspace", accessLabel: "Night Shift works here",
                                    path: "~/Developer/Narada", url: nil, branch: "main", primary: true, live: true,
                                    actions: [ActionDTO(id: "resource.primary:R1", label: "Make primary",
                                                        style: "secondary", kind: "invoke")])],
            changes: [ChangeDTO(ref: "chg:R1:Sources/Export.swift", project: "Narada", path: "Sources/Export.swift",
                                kindLabel: "Modified", added: 12, removed: 3)],
            checks: ChecksDTO(status: "pass", items: [CheckDTO(criterion: "Export enables after the transcript",
                                                                status: "pass", note: "UI test")]),
            instructions: InstructionsDTO(summary: "Meeting recorder for macOS", brief: "Keep the UI native."),
            nowAndNext: [CardDTO(id: "T1", title: "Export fix", subtitle: "Working",
                                 status: StatusDTO(code: "running", label: "Running", tone: "active", active: true),
                                 actions: [])],
            work: [WorkDTO(id: "W1", title: "Onboarding", kind: "variants",
                           status: StatusDTO(code: "reportReady", label: "Report ready", tone: "good", active: false),
                           parts: [CardDTO(id: "T2", title: "Variant A", subtitle: "Reviewed",
                                           status: StatusDTO(code: "reportReady", label: "Report ready", tone: "good", active: false),
                                           actions: [])],
                           missing: 1,
                           report: ActionDTO(id: "workReport:W1", label: "Open the report", style: "primary",
                                             kind: "report", target: "workReport:W1"))],
            report: report,
            chatReports: ChatReportsDTO(
                items: [ChatReportDTO(title: "Latest report", detail: "27.09 12:10 · Export fix on the phone",
                                      open: ActionDTO(id: "chatReport:C1:0", label: "Open the report", style: "secondary",
                                                      kind: "report", target: "chatReport:C1:0"))],
                generating: false,
                create: ActionDTO(id: "chatReport.make:C1", label: "Create report", style: "secondary", kind: "invoke"),
                note: "It will be saved in the project’s artifacts folder and ignored by Git.")), error: nil), "response-context")
        try check(LinkResponse(id: "R7", ok: true, result: DiffDTO(text: "@@ -1 +1 @@\n-old\n+new\n"), error: nil),
                  "response-diff")
        try check(LinkResponse(id: "R8", ok: true, result: SkillsDTO(
            skills: [SkillDTO(id: "S1", name: "minimalist-ui", scope: "global", description: "Clean editorial UI",
                              uses: 14, usesHere: 3, lastUsed: "2 days ago", source: "~/.claude/skills/minimalist-ui",
                              actions: [])],
            servers: [ServerDTO(name: "github", target: "npx @github/mcp", health: "connected", transport: "stdio",
                                scope: "user", description: "GitHub", uses: 5, lastUsed: "today")],
            counted: true, transcripts: 120), error: nil), "response-skills")
    }

    // MARK: - Building blocks

    private static let desktop = LinkDesktop(id: "k3Y", name: "Ivan's MacBook Pro", version: "1.9", language: "uk")

    private static let phoneApps = PhoneAppsDTO(
        android: PhoneAppDTO(version: "1.1", build: 9, url: "https://bulava.app/Bulava-android.apk"),
        ios: PhoneAppDTO(version: "1.1", build: 9, url: "https://testflight.apple.com/join/wtWcPjb1"))

    /// A chat whose own run control differs from the Mac's default: Codex thinks harder here.
    private static let chatComposer = ComposerOptionsDTO(
        groups: [OptionGroupDTO(id: "codexEffort", title: "Codex thinks",
                                options: [OptionDTO(id: "auto", label: "Automatic · Medium", detail: nil),
                                          OptionDTO(id: "high", label: "High", detail: nil)],
                                selected: "high", engine: "codex", kind: "depth")],
        summary: [RunPartDTO(engine: "claude", name: "Claude", model: "Opus 5.5", depth: "Max"),
                  RunPartDTO(engine: "codex", name: "Codex", model: "GPT-5.5", depth: "High")])

    private static let chatSummary = ChatSummaryDTO(
        id: "C1", productID: "P1", title: "Export fix", pinned: false, archived: false,
        createdAtMs: 1_790_000_000_000, updatedAtMs: 1_790_000_060_000,
        status: StatusDTO(code: "needsAttention", label: "Needs your answer", tone: "attention", active: false))

    private static let invoke = ActionDTO(id: "trust:C1:E1", label: "Trust and send", style: "primary", kind: "invoke")
    private static let onMac = ActionDTO(id: "mac", label: "Sign in on your Mac", style: "secondary", kind: "mac")

    private static let entries: [EntryDTO] = [
        EntryDTO(id: "E1", kind: "user", atMs: 1_790_000_000_000, author: "You", text: "Why is export grey?",
                 blocks: [], attachments: [FileDTO(ref: "att:A1", name: "shot.png", kind: "image", size: 3, url: nil)],
                 tone: "neutral", delivery: DeliveryDTO(code: "failed", label: "Not delivered"),
                 asks: [AskDTO(id: "trust:C1:E1", kind: "folderTrust", tone: "attention",
                               title: "Claude Code asks before working in a folder for the first time.",
                               detail: nil, code: "/Users/you/Narada",
                               actions: [invoke])],
                 actions: [ActionDTO(id: "takeBack:E1", label: "Edit", style: "secondary", kind: "takeBack", target: "E1"),
                           ActionDTO(id: "commit:E1", label: "Commit as me…", style: "secondary", kind: "invoke",
                                     input: ActionInputDTO(placeholder: "Commit message", required: true, value: "WIP"))],
                 question: nil, card: nil, finished: nil),
        EntryDTO(id: "E2", kind: "agent", atMs: 1_790_000_030_000, author: "Night Shift", text: "It waits for the transcript.",
                 blocks: [BlockDTO(id: "t1", kind: "activity", text: "",
                                   activity: ActivityDTO(sentence: "Reading ExportController.swift", status: "done", detail: nil),
                                   files: []),
                          BlockDTO(id: "m1", kind: "markdown", text: "It waits for the **transcript**. The page: `artifacts/review/index.html`.",
                                   activity: nil, files: [],
                                   links: [FileDTO(ref: "lnk:C1:0a1b2c3d4e5f60718293", name: "index.html", kind: "document",
                                                   size: 2048, url: nil)]),
                          BlockDTO(id: "g1", kind: "gallery", text: "Before and after", activity: nil,
                                   files: [FileDTO(ref: "art:run/after.png", name: "after.png", kind: "image", size: 10, url: nil)])],
                 attachments: [], tone: "neutral", delivery: nil, asks: [], actions: [], question: nil, card: nil, finished: true,
                 explanation: ExplanationDTO(brief: "It waits for the transcript, so the button stays grey.",
                                             stepByStep: nil, running: false, stale: false, failure: nil,
                                             actions: [ActionDTO(id: "explain.steps:E2", label: "Go through it step by step",
                                                                 style: "secondary", kind: "invoke")])),
        EntryDTO(id: "E3", kind: "question", atMs: 1_790_000_040_000, author: "Night Shift", text: "Which build number?",
                 blocks: [], attachments: [], tone: "neutral", delivery: nil, asks: [], actions: [],
                 question: QuestionDTO(eyebrow: "Needs your answer", headline: "Which build number?", situation: "41 is taken.",
                                       recommendation: "42", ifUnanswered: nil, unblocks: "The upload",
                                       items: [QuestionItemDTO(question: "Build number", header: nil,
                                                               options: [OptionDTO(id: "42", label: "42", detail: "The next one")],
                                                               multiSelect: false)],
                                       answerable: true),
                 card: nil, finished: nil),
        EntryDTO(id: "E4", kind: "report", atMs: 1_790_000_050_000, author: "", text: "",
                 blocks: [], attachments: [], tone: "neutral", delivery: nil, asks: [], actions: [], question: nil,
                 card: CardDTO(id: "T1", title: "Export fix", subtitle: "Reviewed and ready for you",
                               status: StatusDTO(code: "reportReady", label: "Report ready", tone: "good", active: false),
                               actions: [ActionDTO(id: "card.report:T1", label: "Open the report", style: "primary",
                                                   kind: "report", target: "card.report:T1"),
                                         ActionDTO(id: "card.changes:T1", label: "Ask for changes", style: "secondary",
                                                   kind: "compose", input: ActionInputDTO(placeholder: "Ask for changes", required: true))]),
                 finished: nil),
    ]
}
