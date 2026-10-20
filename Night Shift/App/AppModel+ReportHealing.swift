import Foundation

/// A chat's report that is no longer where the chat remembers it.
///
/// The report contract tells the worker to build its page again after a correction, and building it
/// again made a new dated folder — while the folder the chat had recorded was the first one. When
/// that one was removed, "Open report" said the file was missing although the report was right there
/// under its new name (19 Oct). The engine now rebuilds the same request in place; this repairs what
/// was recorded before that, and whatever else moves a report away.
///
/// A replacement is taken only on proof that it belongs to this chat: Bulava copies the request it
/// wrote into the report's folder, and that request names the chat and quotes his first message. A
/// newer report of another chat — even one with the same title — is never taken for it.
extension AppModel {

    /// Puts the report this chat's missing one was rebuilt as in its place. True when it changed.
    @discardableResult
    func healReportPaths(in chatID: UUID) -> Bool {
        guard let chat = conversations.chat(id: chatID), let paths = chat.session?.reportPaths, !paths.isEmpty else { return false }
        let fm = FileManager.default
        let missing = paths.filter { !fm.fileExists(atPath: $0) }
        guard !missing.isEmpty else { return false }
        let marks = SupervisorClient.reportRequestMarks(title: chat.title, originalRequest: chat.firstMessage)
        var taken = Set(paths.filter { fm.fileExists(atPath: $0) }.map(Slug.canonicalPath))
        var replaced: [String: String] = [:]
        for path in missing {
            let root = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            guard let found = Self.reportBuiltFromTheSameChat(in: root, marks: marks, excluding: taken) else { continue }
            replaced[path] = found
            taken.insert(Slug.canonicalPath(found))
        }
        guard !replaced.isEmpty else { return false }
        conversations.updateSession(for: chatID) { session in
            var seen: Set<String> = []
            session.reportPaths = session.reportPaths
                .map { replaced[$0] ?? $0 }
                .filter { seen.insert(Slug.canonicalPath($0)).inserted }
        }
        return true
    }

    /// The newest report under `root` whose request names this chat and quotes his request.
    nonisolated static func reportBuiltFromTheSameChat(in root: URL, marks: [String], excluding taken: Set<String>) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        var best: (path: String, at: Date)?
        for name in names where !name.hasPrefix(".") {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            // `latest` and any other link: it points at whatever was built last, which tomorrow may be
            // another chat's report.
            if (try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil { continue }
            let page = folder.appendingPathComponent("index.html")
            guard fm.fileExists(atPath: page.path), !taken.contains(Slug.canonicalPath(page.path)),
                  let request = try? String(contentsOf: folder.appendingPathComponent("REPORT-REQUEST.md"), encoding: .utf8),
                  marks.allSatisfy({ request.contains($0) }) else { continue }
            let at = (try? fm.attributesOfItem(atPath: page.path)[.modificationDate] as? Date) ?? .distantPast
            if best == nil || at > best!.at { best = (page.path, at) }
        }
        return best?.path
    }

    /// "Open report": the report as it is now — repaired first when it moved.
    func openChatReport(chatID: UUID, path: String, title: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            // The button may have been drawn before the record was repaired: the record is the truth.
            healReportPaths(in: chatID)
            if let current = conversations.chat(id: chatID)?.session?.reportPaths.last, fm.fileExists(atPath: current) {
                return openChatReport(path: current, title: title)
            }
        }
        openChatReport(path: path, title: title)
    }
}
