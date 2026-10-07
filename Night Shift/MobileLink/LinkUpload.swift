import Foundation

/// A file on its way from the phone — a photo, a document, a voice note — arriving in chunks.
///
/// Written straight into the attachment store under the name it will keep, so finishing is a
/// rename of nothing: the bytes are already where a message's attachments live. A phone that
/// disconnects halfway leaves nothing behind (`discard`).
@MainActor
final class LinkUpload {
    let id = UUID()
    let filename: String
    let kind: AttachmentKind
    let expected: Int64
    private(set) var received: Int64 = 0
    private let url: URL
    private let relativePath: String
    private var handle: FileHandle?

    static let maximumSize: Int64 = 50 * 1024 * 1024

    init?(filename: String, kind: AttachmentKind, size: Int64, directory: URL = AppSupport.attachments) {
        guard size > 0, size <= Self.maximumSize else { return nil }
        let clean = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.filename = clean.isEmpty ? "Attachment" : String(clean.prefix(120))
        self.kind = kind
        self.expected = size
        let ext = (self.filename as NSString).pathExtension
        relativePath = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        url = directory.appendingPathComponent(relativePath)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
    }

    /// Chunks must arrive in order. One out of place means something was lost, and a file with a
    /// hole in it is worse than no file.
    func append(offset: Int64, _ data: Data) -> LinkError? {
        guard let handle else { return LinkError(code: LinkErrorCode.failed, message: "Upload closed.") }
        guard offset == received else {
            return LinkError(code: LinkErrorCode.badRequest, message: "Expected offset \(received).")
        }
        guard received + Int64(data.count) <= expected else {
            return LinkError(code: LinkErrorCode.tooLarge, message: "More bytes than announced.")
        }
        do { try handle.write(contentsOf: data) } catch {
            return LinkError(code: LinkErrorCode.failed, message: error.localizedDescription)
        }
        received += Int64(data.count)
        return nil
    }

    func finish() -> Attachment? {
        try? handle?.close()
        handle = nil
        guard received == expected else { discard(); return nil }
        return Attachment(id: id, kind: kind, filename: filename, relativePath: relativePath)
    }

    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}
