import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ComposerIntent: Equatable {

    case newTask

    case instruct(taskID: UUID)

    case changes(taskID: UUID)

    case answer(taskID: UUID)

    case followUp(taskID: UUID)

    var taskID: UUID? {
        switch self {
        case .newTask: nil
        case .instruct(let id), .changes(let id), .answer(let id), .followUp(let id): id
        }
    }
}

extension AppModel {

    // MARK: - Priming the composer

    func beginInstructing(_ task: BacklogTask) { primeComposer(.instruct(taskID: task.id)) }
    func beginAskingChanges(_ task: BacklogTask) { primeComposer(.changes(taskID: task.id)) }
    func beginAnswering(_ task: BacklogTask) { primeComposer(.answer(taskID: task.id)) }
    func beginFollowUp(_ task: BacklogTask) { primeComposer(.followUp(taskID: task.id)) }
    func resetComposerIntent() { composerIntent = .newTask }

    func focusComposer() { primeComposer(.newTask) }

    private func primeComposer(_ intent: ComposerIntent) {
        composerIntent = intent
        composerFocusRequest = UUID()
    }

    // MARK: - Text drafts

    func draftText(for productID: UUID) -> String { composerDrafts[productID] ?? "" }

    func setDraftText(_ text: String, for productID: UUID) {
        if text.isEmpty { composerDrafts[productID] = nil } else { composerDrafts[productID] = text }
    }

    func takeDraftText(for productID: UUID) -> String {
        defer { composerDrafts[productID] = nil }
        return composerDrafts[productID] ?? ""
    }

    // MARK: - Attachment drafts

    func draftAttachments(for productID: UUID) -> [Attachment] {
        composerAttachments[productID] ?? []
    }

    func addDraftAttachment(_ attachment: Attachment, to productID: UUID) {
        composerAttachments[productID, default: []].append(attachment)
        composerFocusRequest = UUID()
    }

    func removeDraftAttachment(_ attachmentID: UUID, from productID: UUID) {
        composerAttachments[productID]?.removeAll { $0.id == attachmentID }
        if composerAttachments[productID]?.isEmpty == true { composerAttachments[productID] = nil }
    }

    func takeDraftAttachments(for productID: UUID) -> [Attachment] {
        defer { composerAttachments[productID] = nil }
        return composerAttachments[productID] ?? []
    }

    func importDroppedFile(_ url: URL, into productID: UUID) {
        guard url.isFileURL else { return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              !directory.boolValue else {
            toast = ToastMessage(text: String(localized: "Drop files here; add folders as product resources."),
                                 kind: .info)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let attachment = capture.importFile(from: url) else {
            toast = ToastMessage(text: String(format: String(localized: "Could not attach %@"),
                                               url.lastPathComponent), kind: .error)
            return
        }
        addDraftAttachment(attachment, to: productID)
    }

    /// Attaches whatever a pasteboard is actually carrying — the clipboard on ⌘V, or the drag
    /// pasteboard on a drop.
    ///
    /// Answers `false` when there is nothing to attach, and that answer matters: ⌘V in the
    /// composer has to fall through to an ordinary text paste unless this took the contents.
    /// Files win over pixels, because a copied image FILE carries both a file URL and a preview
    /// image, and the file is the thing he meant to send.
    @discardableResult
    func importPasteboard(_ pasteboard: NSPasteboard, into productID: UUID) -> Bool {
        if pasteboard.availableType(from: [.fileURL]) != nil,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            for url in urls { importDroppedFile(url, into: productID) }
            return true
        }
        if let png = Self.pngData(from: pasteboard) {
            return importImageData(png, named: Self.pasteboardName(from: pasteboard), into: productID)
        }
        return false
    }

    /// A name the clipboard is carrying for the pixels it hands over, if it is carrying one.
    ///
    /// A screenshot taken with ⌃⌘⇧4 has none — there is no file yet, and the generated name is the
    /// only honest answer. An image copied from a web page or a document usually does, and the
    /// name is often the only place the sender put a word about what the picture IS.
    nonisolated static func pasteboardName(from pasteboard: NSPasteboard) -> String? {
        guard let item = pasteboard.pasteboardItems?.first else { return nil }
        if let name = item.string(forType: .init("public.url-name"))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let string = item.string(forType: .init("public.url")),
           let url = URL(string: string) {
            let last = url.lastPathComponent
            if !last.isEmpty, last != "/" { return last }
        }
        return nil
    }

    /// Files a loose image — pasted pixels, or a screenshot handed over as raw data — as an
    /// attachment of its own.
    ///
    /// macOS hands a dragged screenshot thumbnail over as BYTES, not as a file: the shot is still
    /// only a promise on its way to the desktop, so the drag carries `public.png` and a suggested
    /// name and no file URL anyone can open. Everything downstream wants a file, so the bytes get
    /// written into the attachment store here.
    @discardableResult
    func importImageData(_ data: Data, type: UTType = .png, named name: String? = nil,
                         into productID: UUID) -> Bool {
        // A provider that would only promise "some image" gets re-encoded rather than saved under
        // a guessed extension.
        var data = data
        var type = type
        if type == .image {
            guard let rep = NSBitmapImageRep(data: data),
                  let png = rep.representation(using: .png, properties: [:]) else {
                toast = ToastMessage(text: String(localized: "Could not attach the image"), kind: .error)
                return false
            }
            data = png
            type = .png
        }
        let filename = Self.uniqueFilename(Self.imageFilename(named: name, type: type),
                                           taken: draftAttachments(for: productID).map(\.filename))
        guard let attachment = capture.writeData(data, filename: filename, kind: .image) else {
            toast = ToastMessage(text: String(localized: "Could not attach the image"), kind: .error)
            return false
        }
        addDraftAttachment(attachment, to: productID)
        return true
    }

    /// A name the attachment chip can show and a file the agent can open.
    ///
    /// The screenshot's own suggested name is kept — it is what he will recognise — but it arrives
    /// without a guarantee of an extension, and an image saved without one is a file nothing knows
    /// how to open.
    nonisolated static func imageFilename(named name: String?, type: UTType,
                                          at date: Date = Date()) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let base = (trimmed?.isEmpty == false ? trimmed : nil)
            ?? "\(String(localized: "Pasted image")) \(Self.stamp(date))"
        // Only a suffix that actually names an image counts as one. A screenshot is called
        // "Screenshot 2026-09-11 at 4.04.47 PM", so the text after the last dot is "47 PM" —
        // treating that as the extension writes a file nothing can open.
        let suffix = (base as NSString).pathExtension
        if !suffix.isEmpty, let known = UTType(filenameExtension: suffix), known.conforms(to: .image) {
            return base
        }
        return "\(base).\(type.preferredFilenameExtension ?? "png")"
    }

    /// A name no other attachment already waiting in this message carries.
    ///
    /// The generated name is stamped to the second, so several images arriving in one gesture all
    /// got the SAME one: four screenshots went out as four copies of "Pasted image
    /// 2026-09-15 at 11.56.32.png". The director had written what each bug was in those file
    /// names, and by the time the agent read the message there was no way to tell which was
    /// which — or that there had been four different descriptions at all. Finder's own answer to
    /// a collision: number them.
    nonisolated static func uniqueFilename(_ name: String, taken: [String]) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    nonisolated static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    /// PNG bytes out of a pasteboard, whatever form the image arrived in. Screenshots reach the
    /// clipboard as TIFF; everything downstream expects a normal image file, so TIFF is re-encoded
    /// rather than attached under a name nothing opens.
    nonisolated static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Takes everything a drop is carrying, in the order that keeps the most: a real file beats
    /// the preview image of that same file, because the file is what he meant to send.
    @discardableResult
    func importDrop(_ providers: [NSItemProvider], into productID: UUID) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    _Concurrency.Task { @MainActor in self.importDroppedFile(url, into: productID) }
                }
            } else if let type = Self.imageType(of: provider) {
                accepted = true
                let name = provider.suggestedName
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data, !data.isEmpty else { return }
                    _Concurrency.Task { @MainActor in
                        self.importImageData(data, type: type, named: name, into: productID)
                    }
                }
            }
        }
        return accepted
    }

    /// The image flavour a provider can actually hand over, preferring the lossless one.
    nonisolated static func imageType(of provider: NSItemProvider) -> UTType? {
        for candidate in [UTType.png, .tiff, .jpeg, .heic, .gif] where
            provider.hasItemConformingToTypeIdentifier(candidate.identifier) {
            return candidate
        }
        return provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? .image : nil
    }


    // MARK: - Sending

    nonisolated static func answeredNumber(in text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":"),
              trimmed.distance(from: trimmed.startIndex, to: colon) <= 2,
              let n = Int(trimmed[trimmed.startIndex..<colon]), n >= 1 else { return nil }
        return n
    }

    func send(_ raw: String, attachments: [Attachment] = []) {
        composerIntent = .newTask
        sendDirectMessage(raw, attachments: attachments)
    }

    // MARK: - Pause / resume

    func pause(task: BacklogTask) {
        guard let path = task.projectPath else { return }
        note(.workersStopped, .info, "Ставлю на паузу «\(task.title)».", projectPath: path, taskID: task.id)
        if let productID = productID(for: task) {
            conversations.postEvent("Задачу поставлено на паузу — зупиниться після поточного кроку.",
                                    productID: productID, tone: .neutral, taskID: task.id)
        }
        perform(String(localized: "Pausing after the current step")) {
            await self.client.stopNightShift(project: path)
        }
    }

    func resume(task: BacklogTask) {
        dispatch(task: task, continuing: true)
    }

    // MARK: - Project lookups for a task

    func project(for task: BacklogTask) -> Project? {
        if let id = task.projectID, let p = projects.project(id: id) { return p }
        if let path = task.projectPath { return projects.project(path: path) }
        return nil
    }

    func projectRemote(for task: BacklogTask) -> String? {
        project(for: task)?.gitRemote
    }
}

extension AppModel {

    func answerUnboundQuestion(entry: ConversationEntry, text: String) {
        conversations.appendUser(text, productID: entry.productID, chatID: entry.chatID)

        let holding = entry.chatID
            .flatMap { conversations.chat(id: $0)?.session }
            .flatMap { matchingInstance(for: $0) }
            // Written as a `map` over the question rather than a comparison against `nil`: Swift
            // 6.4 calls that comparison ambiguous here, and the whole target stopped compiling.
            .flatMap { instance -> SupervisorInstance? in instance.pendingQuestion.map { _ in instance } }
        guard let holding else {
            postForemanText("Той воркер уже не чекає на відповідь — прибрав питання.",
                            productID: entry.productID)
            conversations.remove(entryID: entry.id)
            return
        }
        answerQuestion(holding, text)

    }
}
