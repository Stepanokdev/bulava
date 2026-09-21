import Foundation

nonisolated enum CaptureKind: String, Codable, Sendable {
    case note, voice, image, link, file

    var icon: String {
        switch self {
        case .note: "text.alignleft"
        case .voice: "waveform"
        case .image: "photo"
        case .link: "link"
        case .file: "doc"
        }
    }
}

nonisolated enum AttachmentKind: String, Codable, Sendable { case image, audio, file, link }

nonisolated struct Attachment: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: AttachmentKind
    var filename: String
    var relativePath: String?
    var urlString: String?
    var durationSeconds: Double?

    init(id: UUID = UUID(), kind: AttachmentKind, filename: String,
         relativePath: String? = nil, urlString: String? = nil, durationSeconds: Double? = nil) {
        self.id = id; self.kind = kind; self.filename = filename
        self.relativePath = relativePath; self.urlString = urlString; self.durationSeconds = durationSeconds
    }
}

nonisolated enum CaptureStatus: String, Codable, Sendable { case inbox, compiled, dismissed }

nonisolated struct CaptureItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var text: String
    var kind: CaptureKind
    var attachments: [Attachment]
    var suggestedProjectID: UUID?
    var suggestedType: TaskType?
    var suggestedPriority: Priority
    var status: CaptureStatus
    var linkedTaskID: UUID?

    init(id: UUID = UUID(), createdAt: Date = Date(), text: String = "", kind: CaptureKind = .note,
         attachments: [Attachment] = [], suggestedProjectID: UUID? = nil,
         suggestedType: TaskType? = nil, suggestedPriority: Priority = .p2,
         status: CaptureStatus = .inbox, linkedTaskID: UUID? = nil) {
        self.id = id; self.createdAt = createdAt; self.text = text; self.kind = kind
        self.attachments = attachments; self.suggestedProjectID = suggestedProjectID
        self.suggestedType = suggestedType; self.suggestedPriority = suggestedPriority
        self.status = status; self.linkedTaskID = linkedTaskID
    }

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch kind {
        case .voice: return "Voice note"
        case .image: return "\(attachments.count) image\(attachments.count == 1 ? "" : "s")"
        case .link: return attachments.first?.urlString ?? "Link"
        case .file: return attachments.first?.filename ?? "File"
        case .note: return "Empty note"
        }
    }
}
