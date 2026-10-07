import Foundation

nonisolated enum UsagePressure: Sendable, Equatable {

    case comfortable

    case tight

    case nearlyOut

    init(usedPercent: Double) {
        switch usedPercent {
        case ..<75:  self = .comfortable
        case ..<90:  self = .tight
        default:     self = .nearlyOut
        }
    }
}

nonisolated struct UsageWindow: Sendable, Equatable {
    var usedPercent: Double
    var resetsAt: Date?

    var clampedPercent: Double { min(max(usedPercent, 0), 100) }
    var pressure: UsagePressure { UsagePressure(usedPercent: clampedPercent) }

    var resetsInText: String? {
        guard let resetsAt else { return nil }
        let secs = Int(resetsAt.timeIntervalSinceNow)
        if secs <= 0 { return "resetting…" }
        let h = secs / 3600, m = (secs % 3600) / 60
        if h > 0 { return "resets in \(h)h \(m)m" }
        return "resets in \(m)m"
    }

    var resetsAtClock: String? {
        guard let resetsAt else { return nil }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: resetsAt)
    }

    /// The share used as the sidebar shows it, 0…100 — or nil while there is nothing to show:
    /// nothing used and no reset known, or a reset already passed, after which it starts over.
    /// The phone is sent the same (`LinkProjection.limits`).
    func shownPercent(now: Date = Date()) -> Int? {
        guard usedPercent > 0 || resetsAt != nil else { return nil }
        if let resetsAt, resetsAt <= now { return nil }
        return min(100, max(0, Int(usedPercent.rounded())))
    }
}

nonisolated struct UsageSnapshot: Sendable, Equatable {
    var fiveHour: UsageWindow
    var sevenDay: UsageWindow?
    var plan: String?
    var updatedAt: Date?
    var present: Bool

    static let empty = UsageSnapshot(fiveHour: UsageWindow(usedPercent: 0, resetsAt: nil),
                                     sevenDay: nil, plan: nil, updatedAt: nil, present: false)

    /// The tightest of the windows shown — what the folded line in the sidebar gives.
    func tightestShown(now: Date = Date()) -> Int? {
        [fiveHour.shownPercent(now: now), sevenDay?.shownPercent(now: now)].compactMap { $0 }.max()
    }

    /// Read so long ago — over half an hour, or never — that the meters are dimmed.
    func isStale(now: Date = Date()) -> Bool {
        updatedAt.map { now.timeIntervalSince($0) > 1800 } ?? true
    }

    // MARK: Decoding from the engine's JSON

    private struct Raw: Decodable {
        struct Win: Decodable { var used_percentage: Double?; var resets_at: Double? }
        var ts: Double?
        var plan: String?
        var five_hour: Win?
        var seven_day: Win?
    }

    static func decode(from data: Data) -> UsageSnapshot? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        func win(_ w: Raw.Win?) -> UsageWindow? {
            guard let w else { return nil }
            let reset = (w.resets_at ?? 0) > 0 ? Date(timeIntervalSince1970: w.resets_at ?? 0) : nil
            return UsageWindow(usedPercent: w.used_percentage ?? 0, resetsAt: reset)
        }
        let five = win(raw.five_hour) ?? UsageWindow(usedPercent: 0, resetsAt: nil)
        return UsageSnapshot(
            fiveHour: five,
            sevenDay: win(raw.seven_day),
            plan: raw.plan,
            updatedAt: (raw.ts ?? 0) > 0 ? Date(timeIntervalSince1970: raw.ts ?? 0) : nil,
            present: true)
    }
}

nonisolated struct CapacitySnapshot: Sendable, Equatable {
    var claude: UsageSnapshot = .empty
    var codex: UsageSnapshot = .empty
}
