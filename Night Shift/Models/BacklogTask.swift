import Foundation

nonisolated enum RunMode: String, Codable, Sendable, CaseIterable {
    case patch, remediation, audit, broad
    var label: String {
        switch self {
        case .patch: "Patch"
        case .remediation: "Remediation"
        case .audit: "Audit"
        case .broad: "Broad"
        }
    }
}

nonisolated enum VerificationProfile: String, Codable, Sendable, CaseIterable {
    case standard, localVisual = "local_visual", buildOnly = "build_only", full
    var label: String {
        switch self {
        case .standard: "Standard"
        case .localVisual: "Local visual"
        case .buildOnly: "Build only"
        case .full: "Full"
        }
    }
}

nonisolated struct BacklogTask: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var detail: String
    var projectID: UUID?
    var projectPath: String?
    var type: TaskType
    var priority: Priority
    var state: TaskState
    var createdAt: Date
    var updatedAt: Date

    var queueDirName: String?
    var dispatchedAt: Date?
    var lastOutcome: String?
    var reviewFeedback: [String]
    var fromCaptureID: UUID?
    var attachments: [Attachment]

    var boundBranch: String?
    var boundBaseSHA: String?
    var boundBaseBranch: String?
    var boundSessionID: String?

    var boundDispatchID: String?

    var boundReportKey: String?
    var boundRunID: String?
    var finalizingSince: Date?

    var dependsOn: [UUID]
    var externalBlocker: String?
    var autoResume: Bool

    var requestedBranch: String?

    var askedVerbatim: String?

    var holds: [TaskHold] = []
    var worktree: String?
    var wantsReport: Bool

    var runMode: RunMode?
    var writePaths: [String]
    var nonGoals: [String]
    var acceptance: [String]
    var surfaceUserFacingCopy: Bool
    var surfaceVisual: Bool
    var surfaceBehavior: Bool
    var verificationProfile: VerificationProfile?

    var planSteps: [String]

    var productID: UUID?

    var chatID: UUID?

    init(id: UUID = UUID(), title: String, detail: String = "", projectID: UUID? = nil,
         projectPath: String? = nil, type: TaskType = .feature, priority: Priority = .p2,
         state: TaskState = .ready, createdAt: Date = Date(), updatedAt: Date = Date(),
         queueDirName: String? = nil, dispatchedAt: Date? = nil, lastOutcome: String? = nil,
         reviewFeedback: [String] = [], fromCaptureID: UUID? = nil, attachments: [Attachment] = [],
         boundBranch: String? = nil, boundBaseSHA: String? = nil, boundBaseBranch: String? = nil,
         boundSessionID: String? = nil, boundRunID: String? = nil, finalizingSince: Date? = nil,
         dependsOn: [UUID] = [], externalBlocker: String? = nil,
         autoResume: Bool = false, holds: [TaskHold] = [], requestedBranch: String? = nil,
         worktree: String? = nil, wantsReport: Bool = true,
         runMode: RunMode? = nil, writePaths: [String] = [], nonGoals: [String] = [], acceptance: [String] = [],
         surfaceUserFacingCopy: Bool = false, surfaceVisual: Bool = false,
         surfaceBehavior: Bool = false, verificationProfile: VerificationProfile? = nil,
         planSteps: [String] = [], productID: UUID? = nil, chatID: UUID? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.projectID = projectID
        self.projectPath = projectPath; self.type = type; self.priority = priority; self.state = state
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.queueDirName = queueDirName
        self.dispatchedAt = dispatchedAt; self.lastOutcome = lastOutcome
        self.reviewFeedback = reviewFeedback; self.fromCaptureID = fromCaptureID
        self.attachments = attachments
        self.boundBranch = boundBranch; self.boundBaseSHA = boundBaseSHA
        self.boundBaseBranch = boundBaseBranch; self.boundSessionID = boundSessionID
        self.boundRunID = boundRunID; self.finalizingSince = finalizingSince
        self.dependsOn = dependsOn; self.externalBlocker = externalBlocker
        self.autoResume = autoResume; self.holds = holds
        self.requestedBranch = requestedBranch; self.worktree = worktree
        self.wantsReport = wantsReport
        self.runMode = runMode; self.writePaths = writePaths; self.nonGoals = nonGoals; self.acceptance = acceptance
        self.surfaceUserFacingCopy = surfaceUserFacingCopy; self.surfaceVisual = surfaceVisual
        self.surfaceBehavior = surfaceBehavior; self.verificationProfile = verificationProfile
        self.planSteps = planSteps; self.productID = productID; self.chatID = chatID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        type = try c.decodeIfPresent(TaskType.self, forKey: .type) ?? .feature
        priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .p2
        state = try c.decodeIfPresent(TaskState.self, forKey: .state) ?? .ready
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        queueDirName = try c.decodeIfPresent(String.self, forKey: .queueDirName)
        dispatchedAt = try c.decodeIfPresent(Date.self, forKey: .dispatchedAt)
        lastOutcome = try c.decodeIfPresent(String.self, forKey: .lastOutcome)
        reviewFeedback = try c.decodeIfPresent([String].self, forKey: .reviewFeedback) ?? []
        fromCaptureID = try c.decodeIfPresent(UUID.self, forKey: .fromCaptureID)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        boundBranch = try c.decodeIfPresent(String.self, forKey: .boundBranch)
        boundBaseSHA = try c.decodeIfPresent(String.self, forKey: .boundBaseSHA)
        boundBaseBranch = try c.decodeIfPresent(String.self, forKey: .boundBaseBranch)
        boundSessionID = try c.decodeIfPresent(String.self, forKey: .boundSessionID)
        boundDispatchID = try c.decodeIfPresent(String.self, forKey: .boundDispatchID)
        boundReportKey = try c.decodeIfPresent(String.self, forKey: .boundReportKey)
        boundRunID = try c.decodeIfPresent(String.self, forKey: .boundRunID)
        finalizingSince = try c.decodeIfPresent(Date.self, forKey: .finalizingSince)
        dependsOn = try c.decodeIfPresent([UUID].self, forKey: .dependsOn) ?? []
        externalBlocker = try c.decodeIfPresent(String.self, forKey: .externalBlocker)
        autoResume = try c.decodeIfPresent(Bool.self, forKey: .autoResume) ?? false
        holds = (try? c.decodeIfPresent([TaskHold].self, forKey: .holds)) ?? []
        requestedBranch = try? c.decodeIfPresent(String.self, forKey: .requestedBranch)
        worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
        wantsReport = try c.decodeIfPresent(Bool.self, forKey: .wantsReport) ?? true
        runMode = try c.decodeIfPresent(RunMode.self, forKey: .runMode)
        writePaths = try c.decodeIfPresent([String].self, forKey: .writePaths) ?? []
        nonGoals = try c.decodeIfPresent([String].self, forKey: .nonGoals) ?? []
        acceptance = try c.decodeIfPresent([String].self, forKey: .acceptance) ?? []
        surfaceUserFacingCopy = try c.decodeIfPresent(Bool.self, forKey: .surfaceUserFacingCopy) ?? false
        surfaceVisual = try c.decodeIfPresent(Bool.self, forKey: .surfaceVisual) ?? false
        surfaceBehavior = try c.decodeIfPresent(Bool.self, forKey: .surfaceBehavior) ?? false
        verificationProfile = try c.decodeIfPresent(VerificationProfile.self, forKey: .verificationProfile)
        planSteps = try c.decodeIfPresent([String].self, forKey: .planSteps) ?? []
        productID = try c.decodeIfPresent(UUID.self, forKey: .productID)
        chatID = try? c.decodeIfPresent(UUID.self, forKey: .chatID)
        askedVerbatim = try? c.decodeIfPresent(String.self, forKey: .askedVerbatim)
    }

    var dispatchText: String {
        var parts = [title]
        let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { parts.append(d) }

        if let asked = askedVerbatim?.trimmingCharacters(in: .whitespacesAndNewlines), !asked.isEmpty {
            parts.append("""

            --- ЩО ПРОСИВ ДИРЕКТОР, ЙОГО СЛОВАМИ І ЙОГО НУМЕРАЦІЄЮ ---
            Це першоджерело. План вище — наш спосіб це зробити, але звітуй саме за цими пунктами і
            саме цими номерами: по кожному скажи, закрито / частково / не закрито / заблоковано, і
            дай доказ саме там. Нічого з цього списку не має зникнути у звіті.
            \(asked)
            --- кінець списку користувача ---
            """)
        }
        let paths = attachmentPaths
        if !paths.isEmpty {
            parts.append("\nВкладення (відкрий за абсолютними шляхами — це контекст задачі):")
            for (name, path) in paths { parts.append("- \(name): \(path)") }
        }
        if !reviewFeedback.isEmpty {
            parts.append("\nЗауваження від рев'ю (виправ повністю):")
            for (i, f) in reviewFeedback.enumerated() { parts.append("\(i + 1). \(f)") }
        }
        return parts.joined(separator: "\n")
    }

    var attachmentPaths: [(String, String)] {
        attachments.compactMap { a in
            guard let rel = a.relativePath else {
                if let url = a.urlString { return (a.filename, url) }
                return nil
            }
            return (a.filename, AppSupport.attachments.appendingPathComponent(rel).path)
        }
    }

    var reportKey: String { boundReportKey ?? String(id.uuidString.prefix(8)).lowercased() }

    func runSpec(projectPath: String) -> RunSpec { RunSpec.infer(from: self, projectPath: projectPath) }

    var isDispatchable: Bool {

        guard type != .idea else { return false }
        return projectPath != nil && externalBlocker == nil
            && (state == .ready || state == .needsClarification || state == .blocked || state == .failed)
    }

    var isNote: Bool { type == .idea }

    var isInformationalReview: Bool {
        lastOutcome == "succeeded_research" || lastOutcome == "succeeded_no_change"
    }

    enum ReviewClass: Sendable { case visual, code, informational }
    var reviewClass: ReviewClass {

        if surfaceVisual || verificationProfile == .localVisual || type == .design { return .visual }
        if isInformationalReview { return .informational }
        return .code
    }
}
