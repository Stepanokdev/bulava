import Foundation

/// A job he describes once and Bulava runs by itself — on a clock, when something it watches
/// changes, or when something happens on the Mac.
///
/// What it is (the brief, the trigger, where it works) is kept apart from what it did (its runs):
/// every run is a fresh conversation in the automation's own folder, reset to a fresh start commit,
/// and the only thing carried from one run to the next is what the runs themselves recorded as
/// facts — and, in that folder, what git ignores: build output and local files. A run never
/// inherits a conversation, and the brief changes only when he edits it.
nonisolated struct Automation: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var productID: UUID
    /// The product folder it works in. A run never works in it directly: it gets its own copy.
    var projectID: UUID
    var name: String
    /// What to do, in his words. The one instruction every run is given.
    var brief: String
    /// Bumped on every edit of the brief, so a run says which version it worked from.
    var briefRevision: Int
    var trigger: AutomationTrigger
    /// The branch a run starts from. Nil means the repository's default branch, resolved to a
    /// commit at the start of every run — never whatever happens to be checked out that night.
    var baseBranch: String?
    /// Ask before each run instead of starting it. The run waits with a button.
    var confirmFirst: Bool
    var enabled: Bool
    /// Why it switched itself off, in words, when it did. Nil when he paused it himself.
    var pausedReason: String?
    var templateID: String?
    var createdAt: Date
    var updatedAt: Date
    /// Scheduled times up to here have been decided — run, caught up, or recorded as skipped.
    var evaluatedThrough: Date?
    /// What a watch or event trigger has already seen. Nil for a schedule.
    var watch: WatchState?
    /// What a run may do with the code. Nil on automations made before there was a choice: they
    /// change code on a branch, as every run did then.
    var workMode: AutomationWorkMode?
    /// Files from his folder that git ignores and every run is given a fresh copy of — the
    /// `local.properties` or `.env` a build needs. Paths from the top of the repository.
    var carryFiles: [String]?
    /// The pipeline every run goes through. Nil is the one chats use by default.
    var pipelineID: String?

    var checksOnly: Bool { workMode == .checkOnly }

    init(id: UUID = UUID(), productID: UUID, projectID: UUID, name: String, brief: String,
         trigger: AutomationTrigger, baseBranch: String? = nil, confirmFirst: Bool = false,
         enabled: Bool = true, templateID: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.productID = productID
        self.projectID = projectID
        self.name = name
        self.brief = brief
        self.briefRevision = 1
        self.trigger = trigger
        self.baseBranch = baseBranch
        self.confirmFirst = confirmFirst
        self.enabled = enabled
        self.pausedReason = nil
        self.templateID = templateID
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.evaluatedThrough = createdAt
        self.watch = trigger.watchesSomething ? WatchState() : nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        productID = try c.decode(UUID.self, forKey: .productID)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        brief = (try? c.decode(String.self, forKey: .brief)) ?? ""
        briefRevision = (try? c.decode(Int.self, forKey: .briefRevision)) ?? 1
        trigger = (try? c.decode(AutomationTrigger.self, forKey: .trigger)) ?? .manual
        baseBranch = try? c.decodeIfPresent(String.self, forKey: .baseBranch)
        confirmFirst = (try? c.decode(Bool.self, forKey: .confirmFirst)) ?? false
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        pausedReason = try? c.decodeIfPresent(String.self, forKey: .pausedReason)
        templateID = try? c.decodeIfPresent(String.self, forKey: .templateID)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
        evaluatedThrough = try? c.decodeIfPresent(Date.self, forKey: .evaluatedThrough)
        watch = try? c.decodeIfPresent(WatchState.self, forKey: .watch)
        workMode = try? c.decodeIfPresent(AutomationWorkMode.self, forKey: .workMode)
        carryFiles = try? c.decodeIfPresent([String].self, forKey: .carryFiles)
        pipelineID = try? c.decodeIfPresent(String.self, forKey: .pipelineID)
    }
}

/// What a run may do with the code it works on.
nonisolated enum AutomationWorkMode: String, Codable, Sendable {
    /// Change it, on a branch of its own, and leave the change for him to merge or throw away.
    case branch
    /// Read it, build it, check it, and write a report. Nothing is left to merge: whatever a run
    /// changed is thrown away with it.
    case checkOnly
}

// MARK: - Triggers

nonisolated enum AutomationTrigger: Codable, Equatable, Sendable {
    /// Only when he presses Run now.
    case manual
    case schedule(AutomationSchedule)
    /// Something outside changed: commits, a feed, models, a page. Checked by polling.
    case watch(AutomationWatch)
    /// Something happened on this Mac: a letter, a file, the end of a meeting.
    case event(AutomationEvent)

    var watchesSomething: Bool {
        switch self {
        case .watch, .event: true
        case .manual, .schedule: false
        }
    }

    var schedule: AutomationSchedule? {
        if case .schedule(let s) = self { return s }
        return nil
    }
}

nonisolated struct AutomationSchedule: Codable, Equatable, Sendable {
    nonisolated enum Cadence: Codable, Equatable, Sendable {
        case hourly(every: Int)
        case daily
        case weekdays
        /// Weekdays in `Calendar` numbering: 1 is Sunday, 7 is Saturday.
        case weekly(days: [Int])
        /// Every other week on one weekday, counted from the week it was set up in.
        case biweekly(day: Int, anchor: Date)
        case monthly(day: Int)
    }

    var cadence: Cadence
    var hour: Int
    var minute: Int
    var timeZoneID: String
    /// Start only once nobody has touched the Mac for a while — "when I have gone to bed" rather
    /// than a fixed minute. It waits up to `awayWindowHours` after the scheduled time.
    var waitUntilAway: Bool

    static let awayMinutes = 15
    static let awayWindowHours = 6

    init(cadence: Cadence, hour: Int, minute: Int,
         timeZoneID: String = TimeZone.current.identifier, waitUntilAway: Bool = false) {
        self.cadence = cadence
        self.hour = hour
        self.minute = minute
        self.timeZoneID = timeZoneID
        self.waitUntilAway = waitUntilAway
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
}

nonisolated struct AutomationWatch: Codable, Equatable, Sendable {
    nonisolated enum Source: Codable, Equatable, Sendable {
        /// New commits on a branch of a repository on this Mac (fetched from its remote first).
        case commits(repoPath: String, branch: String?)
        /// New entries in an RSS or Atom feed — GitHub releases have one.
        case feed(url: String)
        /// New models on Hugging Face from one author, optionally narrowed by a search.
        case huggingFace(author: String, search: String?)
        /// A web page whose text changed.
        case webPage(url: String)
    }

    var source: Source
    var everyMinutes: Int

    static let intervals = [15, 60, 360, 1440]
}

nonisolated struct AutomationEvent: Codable, Equatable, Sendable {
    nonisolated enum Kind: Codable, Equatable, Sendable {
        /// A new letter in Mail's inbox. Empty filters match anything.
        case mail(from: String, subject: String)
        /// A new or changed file in a folder (not in its subfolders).
        case folder(path: String)
        /// A calendar event ended. Empty matches every event with other people or a title.
        case meetingEnded(titleContains: String)
    }

    var kind: Kind
}

// MARK: - What a watch has seen

/// One thing a watch or event found: a commit, an entry, a model, a letter, a file.
nonisolated struct WatchItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var detail: String?
    var link: String?
    var at: Date?
    /// Handed back after a run that failed on it. A second failure drops it, visibly.
    var retried: Bool = false

    init(id: String, title: String, detail: String? = nil, link: String? = nil, at: Date? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.link = link
        self.at = at
    }
}

nonisolated struct WatchState: Codable, Equatable, Sendable {
    /// Source-specific position: a commit, a feed's validator, a page's digest, a time.
    var cursor: String?
    /// Ids already taken in, newest last, kept to a bounded tail so a restart neither replays
    /// what was handled nor loses what was not.
    var seen: [String] = []
    /// The first look only records what already exists. Nothing there yet is "new".
    var baselined = false
    /// When it last tried to look — what the polling interval counts from.
    var lastCheckedAt: Date?
    /// When a look last went through. Mail and the calendar read "since then", so a look that
    /// failed — Mail closed for a day — must not move it, or that day is never read.
    var lastSucceededAt: Date?
    var lastError: String?
    /// Found and not yet handed to a run — the burst being gathered into one run.
    var pending: [WatchItem] = []
    var pendingSince: Date?
    /// When the last new thing arrived — the clock a burst's quiet spell is measured on.
    var lastFoundAt: Date?
    /// The button that takes `lastError` down, when there is one.
    var lastErrorFix: WatchFix?

    static let seenLimit = 400

    mutating func remember(_ ids: [String]) {
        for id in ids where !seen.contains(id) { seen.append(id) }
        if seen.count > Self.seenLimit { seen.removeFirst(seen.count - Self.seenLimit) }
    }
}

/// What he can press to clear a watch that could not look.
nonisolated enum WatchFix: String, Codable, Sendable {
    /// Mail is closed.
    case openMail
    /// Bulava may not control Mail.
    case automationPrivacy
    /// Bulava may not read the calendar.
    case calendarPrivacy

    /// The address that opens the place where it is cleared.
    var url: URL? {
        switch self {
        case .openMail: URL(fileURLWithPath: "/System/Applications/Mail.app")
        case .automationPrivacy: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .calendarPrivacy: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        }
    }
}

// MARK: - Runs

nonisolated struct AutomationRun: Identifiable, Codable, Equatable, Sendable {
    nonisolated enum Reason: Codable, Equatable, Sendable {
        case scheduled(Date)
        /// The scheduled time passed while the Mac was asleep or Bulava was closed.
        case caughtUp(Date)
        case manual
        case changed(count: Int)
        case event(count: Int)
    }

    nonisolated enum State: String, Codable, Sendable {
        /// Asked first, and waiting for his yes.
        case awaitingApproval
        /// Due, and waiting for him to step away from the Mac.
        case awaitingAway
        /// Getting its copy ready.
        case preparing
        /// Its conversation is going.
        case running
        case finished
        case skipped
        case failed

        var isTerminal: Bool { self == .finished || self == .skipped || self == .failed }
    }

    nonisolated enum Result: String, Codable, Sendable {
        /// Changed something, and the change waits in its copy for him.
        case changes
        case noChange
        /// A written answer — research, a report.
        case report
        /// Done, but the review could not be completed.
        case unverified
        /// Stopped on a question or a wall only he can take down.
        case needsYou
        case failed
    }

    /// What became of a run's changes.
    nonisolated enum Handoff: String, Codable, Sendable {
        case waiting
        case merged
        case discarded
    }

    var id: UUID
    var automationID: UUID
    /// One occurrence is one run, whatever asks for it twice.
    var occurrence: String
    var reason: Reason
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var state: State
    var result: Result?
    /// The worker's own last words about it.
    var summary: String?
    /// Why it was skipped or failed, said plainly.
    var note: String?
    var chatID: UUID?
    /// The id the brief is sent under, so a second send is recognised as the first.
    var entryID: UUID
    var briefRevision: Int
    var items: [WatchItem]
    var workspaceID: UUID?
    var handoff: Handoff?
    /// Where its changes went, when they were merged.
    var mergedInto: String?
    /// He has looked at it. A failure stays marked until he has.
    var seen: Bool = false
    /// He stopped it. Not a failure: it does not count toward switching the automation off.
    var stoppedByHand: Bool = false
    /// A failure owes what it was handed one more try. Written in the same record as the failure,
    /// so a quit before the items are back on the gathered list cannot lose the retry: it is handed
    /// back from here until a run holds it, then cleared. Nil when nothing is owed, and on runs
    /// recorded before this was kept.
    var retryOwed: Bool?

    /// What it was asked to do, where, and from which branch — as the automation said when this
    /// run was recorded. An edit made while it waits for approval, or for him to step away, is the
    /// next run's business; this one runs what it was recorded with, under its revision number.
    /// Nil on runs recorded before these were kept.
    var brief: String?
    var projectID: UUID?
    /// The branch to start from; empty means the repository's default.
    var baseBranch: String?
    /// Its written report has been asked for — once, the moment its work ended. Nil on runs
    /// recorded before reports were asked for by themselves.
    var reportAsked: Bool?
    /// Recorded to only check: what it changes is not work to hand over. Nil for a run that may
    /// change code, and on runs recorded before there was a choice.
    var checkOnly: Bool?

    init(id: UUID = UUID(), automationID: UUID, occurrence: String, reason: Reason,
         state: State, briefRevision: Int, items: [WatchItem] = [], createdAt: Date = Date()) {
        self.id = id
        self.automationID = automationID
        self.occurrence = occurrence
        self.reason = reason
        self.createdAt = createdAt
        self.state = state
        self.entryID = UUID()
        self.briefRevision = briefRevision
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        automationID = try c.decode(UUID.self, forKey: .automationID)
        occurrence = (try? c.decode(String.self, forKey: .occurrence)) ?? id.uuidString
        reason = (try? c.decode(Reason.self, forKey: .reason)) ?? .manual
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try? c.decodeIfPresent(Date.self, forKey: .finishedAt)
        state = (try? c.decode(State.self, forKey: .state)) ?? .failed
        result = try? c.decodeIfPresent(Result.self, forKey: .result)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        chatID = try? c.decodeIfPresent(UUID.self, forKey: .chatID)
        entryID = (try? c.decode(UUID.self, forKey: .entryID)) ?? UUID()
        briefRevision = (try? c.decode(Int.self, forKey: .briefRevision)) ?? 1
        items = (try? c.decode([WatchItem].self, forKey: .items)) ?? []
        workspaceID = try? c.decodeIfPresent(UUID.self, forKey: .workspaceID)
        handoff = try? c.decodeIfPresent(Handoff.self, forKey: .handoff)
        mergedInto = try? c.decodeIfPresent(String.self, forKey: .mergedInto)
        seen = (try? c.decode(Bool.self, forKey: .seen)) ?? false
        stoppedByHand = (try? c.decode(Bool.self, forKey: .stoppedByHand)) ?? false
        retryOwed = try? c.decodeIfPresent(Bool.self, forKey: .retryOwed)
        brief = try? c.decodeIfPresent(String.self, forKey: .brief)
        projectID = try? c.decodeIfPresent(UUID.self, forKey: .projectID)
        baseBranch = try? c.decodeIfPresent(String.self, forKey: .baseBranch)
        reportAsked = try? c.decodeIfPresent(Bool.self, forKey: .reportAsked)
        checkOnly = try? c.decodeIfPresent(Bool.self, forKey: .checkOnly)
    }

    /// Whether this run is still something to look at: changes waiting for him, a question, or a
    /// failure he has not seen through.
    var wantsHim: Bool {
        if state == .awaitingApproval { return true }
        if state == .finished, result == .changes, handoff == .waiting { return true }
        // A question is waiting until it is answered, looked at or not.
        if state == .finished, result == .needsYou { return true }
        if isRealFailure, !seen { return true }
        return false
    }

    /// Failed on its own, as opposed to being stopped by him or skipped.
    var isRealFailure: Bool {
        (state == .failed && !stoppedByHand) || (state == .finished && result == .failed)
    }

    var isQuiet: Bool {
        (state == .finished && result == .noChange) || state == .skipped
    }
}
