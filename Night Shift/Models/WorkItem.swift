import Foundation

// MARK: - Priority

nonisolated enum WorkPriority: String, Codable, Sendable, CaseIterable, Comparable {

    case urgent

    case normal

    case whenFree

    var rank: Int {
        switch self { case .urgent: 0; case .normal: 1; case .whenFree: 2 }
    }
    static func < (a: WorkPriority, b: WorkPriority) -> Bool { a.rank < b.rank }

    var labelKey: String {
        switch self {
        case .urgent:   "Urgent"
        case .normal:   "Normal"
        case .whenFree: "When there is room"
        }
    }

    var taskPriority: Priority {
        switch self { case .urgent: .p0; case .normal: .p2; case .whenFree: .p3 }
    }

    static func detect(in text: String) -> WorkPriority? {
        let t = text.lowercased()
        let urgent = ["срочно", "срочна", "термінов", "терминов", "asap", "urgent",
                      "негайно", "зараз же", "перш за все", "важніше за все",
                      "важнее всего", "в першу чергу", "в первую очередь", "critical"]
        let later = ["коли освободишся", "коли буде час", "когда освободишься",
                     "когда будет время", "не спіши", "не спеши", "не терміново",
                     "не срочно", "колись", "when you have time", "no rush", "low priority"]
        if urgent.contains(where: { t.contains($0) }) { return .urgent }
        if later.contains(where: { t.contains($0) }) { return .whenFree }
        return nil
    }
}

// MARK: - Deadline

nonisolated enum Deadline {

    static func detect(in text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let t = text.lowercased()

        func endOf(_ date: Date) -> Date? {
            calendar.date(bySettingHour: 23, minute: 59, second: 0, of: date)
        }
        if t.contains("сьогодні") || t.contains("сегодня") || t.contains("today") {
            return endOf(now)
        }
        if t.contains("завтра") || t.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: now).flatMap(endOf)
        }

        let weekdays: [(names: [String], weekday: Int)] = [
            (["понеділ", "понедельник", "monday"], 2),
            (["вівтор", "вторник", "tuesday"], 3),
            (["серед", "среду", "среда", "wednesday"], 4),
            (["четвер", "четверг", "thursday"], 5),
            (["пʼятниц", "п'ятниц", "пятниц", "friday"], 6),
            (["субот", "суббот", "saturday"], 7),
            (["неділ", "воскресен", "sunday"], 1),
        ]
        for (names, weekday) in weekdays where names.contains(where: { t.contains($0) }) {
            var comps = DateComponents()
            comps.weekday = weekday
            guard let next = calendar.nextDate(after: now, matching: comps,
                                               matchingPolicy: .nextTime) else { continue }
            return endOf(next)
        }
        return nil
    }
}

// MARK: - Variant count

nonisolated enum VariantCount {
    private static let words: [String: Int] = [
        "два": 2, "двi": 2, "дві": 2, "две": 2, "три": 3, "чотири": 4, "четыре": 4,
        "пʼять": 5, "п'ять": 5, "пять": 5, "шість": 6, "шесть": 6, "сім": 7, "семь": 7,
        "вісім": 8, "восемь": 8, "девʼять": 9, "девять": 9, "десять": 10,
        "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10,
    ]
    private static let nouns = ["варіант", "вариант", "variant", "прототип", "prototype",
                               "версі", "версия", "напрям", "направлен", "option", "concept",
                               "ідей", "идей", "idea"]

    static func detect(in text: String) -> Int? {
        let t = text.lowercased()
        guard nouns.contains(where: { t.contains($0) }) else { return nil }

        let scanner = t.components(separatedBy: CharacterSet.decimalDigits.inverted)
        for chunk in scanner where !chunk.isEmpty {
            if let n = Int(chunk), (2...24).contains(n) { return n }
        }
        for (word, n) in words where t.contains(word) { return n }
        return nil
    }
}

// MARK: - Work item

nonisolated struct WorkItem: Identifiable, Codable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable {

        case job

        case variants
    }

    nonisolated struct Stream: Identifiable, Codable, Equatable, Sendable {

        var id: UUID
        var title: String
        var projectName: String

        var dependsOn: [UUID]

        var variantNumber: Int?

        init(id: UUID, title: String, projectName: String,
             dependsOn: [UUID] = [], variantNumber: Int? = nil) {
            self.id = id
            self.title = title
            self.projectName = projectName
            self.dependsOn = dependsOn
            self.variantNumber = variantNumber
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            projectName = (try? c.decode(String.self, forKey: .projectName)) ?? ""
            dependsOn = (try? c.decode([UUID].self, forKey: .dependsOn)) ?? []
            variantNumber = try? c.decodeIfPresent(Int.self, forKey: .variantNumber)
        }
    }

    var id: UUID
    var productID: UUID

    var chatID: UUID?
    var title: String
    var createdAt: Date
    var kind: Kind
    var priority: WorkPriority
    var dueBy: Date?
    var streams: [Stream]

    var preemptedStreamIDs: [UUID]

    var requestedVariants: Int?

    var reportAnnouncedAt: Date?

    init(id: UUID = UUID(), productID: UUID, chatID: UUID? = nil, title: String, createdAt: Date = Date(),
         kind: Kind = .job, priority: WorkPriority = .normal, dueBy: Date? = nil,
         streams: [Stream] = [], preemptedStreamIDs: [UUID] = [],
         requestedVariants: Int? = nil, reportAnnouncedAt: Date? = nil) {
        self.id = id
        self.productID = productID
        self.chatID = chatID
        self.title = title
        self.createdAt = createdAt
        self.kind = kind
        self.priority = priority
        self.dueBy = dueBy
        self.streams = streams
        self.preemptedStreamIDs = preemptedStreamIDs
        self.requestedVariants = requestedVariants
        self.reportAnnouncedAt = reportAnnouncedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        productID = try c.decode(UUID.self, forKey: .productID)
        chatID = try? c.decodeIfPresent(UUID.self, forKey: .chatID)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .job
        priority = (try? c.decode(WorkPriority.self, forKey: .priority)) ?? .normal
        dueBy = try? c.decodeIfPresent(Date.self, forKey: .dueBy)
        streams = (try? c.decode([Stream].self, forKey: .streams)) ?? []
        preemptedStreamIDs = (try? c.decode([UUID].self, forKey: .preemptedStreamIDs)) ?? []
        requestedVariants = try? c.decodeIfPresent(Int.self, forKey: .requestedVariants)
        reportAnnouncedAt = try? c.decodeIfPresent(Date.self, forKey: .reportAnnouncedAt)
    }

    // MARK: Derived

    var streamIDs: [UUID] { streams.map(\.id) }
    var isMultiStream: Bool { streams.count > 1 }

    func stream(id: UUID) -> Stream? { streams.first { $0.id == id } }

    func dependenciesSatisfied(for streamID: UUID, finished: Set<UUID>) -> Bool {
        guard let stream = stream(id: streamID) else { return false }

        return stream.dependsOn.allSatisfy { finished.contains($0) || self.stream(id: $0) == nil }
    }

    func startable(finished: Set<UUID>, alreadyRunning: Set<UUID>) -> [Stream] {
        streams.filter { stream in
            !finished.contains(stream.id)
                && !alreadyRunning.contains(stream.id)
                && dependenciesSatisfied(for: stream.id, finished: finished)
        }
    }

    var missingVariants: Int {
        guard kind == .variants, let requested = requestedVariants else { return 0 }
        return max(0, requested - streams.count)
    }

    var isOverdue: Bool {
        guard let dueBy else { return false }
        return dueBy < Date()
    }
}
