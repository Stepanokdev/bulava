import SwiftUI
import AppKit

/// The agent's prose: one answer, drawn so that it can be selected and copied as one.
///
/// The answer is parsed once (see `ProseDocument`) into one run of text — paragraphs, headings,
/// lists, quotes, code, tables and pictures all in one `NSTextView`. A drag therefore runs from
/// the first line of an answer to the last, and ⌘C copies it in order with its line breaks,
/// bullets, numbers and table rows.
struct MarkdownProse: View {

    static let proseWidth: CGFloat = 680

    let text: String

    var fileRoots: [URL] = []

    var openWeb: ((URL) -> Void)? = nil

    /// Where Find stands inside this prose, when a search is running. Nil the rest of the time,
    /// and then nothing here behaves differently from before the feature existed.
    var find: ProseFind? = nil

    var body: some View {
        let document = Self.document(text, roots: fileRoots)
        let found = Self.matches(in: document, find: find)
        let anchor = find.map { (entry: $0.entryID, block: $0.blockID) }

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(document.parts.enumerated()), id: \.offset) { index, part in
                switch part.segment {
                case .text(let segment):
                    ProseTextPart(segment: segment, matches: found[index],
                                  anchorPrefix: anchor,
                                  onLink: { url in Self.follow(url, roots: fileRoots, openWeb: openWeb) })
                        .padding(.top, part.spacingBefore)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            switch Self.route(url, roots: fileRoots, openWeb: openWeb) {
            case .handled:   .handled
            case .discarded: .discarded
            case .system:    .systemAction
            }
        })
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: Self.proseWidth, alignment: .leading)
    }

    // MARK: The document, remembered

    /// The parsed answer. File paths are turned into links first, the way the reader is shown
    /// them; that pass looks at the disk, so it is remembered for a few seconds rather than
    /// redone on every redraw of every message in the thread.
    static func document(_ text: String, roots: [URL]) -> ProseDocument {
        guard !roots.isEmpty else { return ProseDocument.make(text) }
        return ProseDocument.make(LinkedSource.shared.rewrite(text, roots: roots), roots: roots)
    }

    /// Where the phrase stands in each part, numbered the way Find numbers the answer's results.
    nonisolated static func matches(in document: ProseDocument, find: ProseFind?) -> [[ProseMatch]] {
        guard let find, !find.query.isEmpty else {
            return Array(repeating: [], count: document.parts.count)
        }
        var next = 0
        return document.parts.map { part in
            let ranges: [NSRange]
            switch part.segment {
            case .text(let segment):
                ranges = segment.matches(of: find.query)
            }
            defer { next += ranges.count }
            return ranges.enumerated().map { offset, range in
                ProseMatch(range: range, occurrence: next + offset,
                           isActive: find.activeOccurrence == next + offset)
            }
        }
    }

    // MARK: Links

    /// What a click on a link does: a file in scope opens in Quick Look (a folder in Finder), a
    /// web page goes to the in-app preview, and anything else is left alone.
    enum Routed { case handled, discarded, system }

    static func route(_ url: URL, roots: [URL], openWeb: ((URL) -> Void)?) -> Routed {
        if let target = FilePathLinks.target(of: url, roots: roots) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
                return .handled
            }
            if isDirectory.boolValue {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } else if DecisionCenter.current?.open(target) == true {
                // A report that asks him to decide opens in the report window, with its choices beside it.
            } else if let openWeb, let shares = ShareCenter.current, shares.enabled,
                      ["html", "htm", "md", "markdown"].contains(target.pathExtension.lowercased()) {
                // A page or a note opens as itself — a site with its styles and scripts, a note as a
                // page — through the share server, and from there one button puts it on the phone.
                Task { @MainActor in
                    if case .success(let link) = await shares.share(target, within: roots),
                       let local = shares.localURL(for: link) {
                        openWeb(local)
                    } else {
                        QuickLookPresenter.shared.show([target], startingAt: 0)
                    }
                }
            } else {
                QuickLookPresenter.shared.show([target], startingAt: 0)
            }
            return .handled
        }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return .discarded }

        guard let openWeb else { return .system }
        openWeb(url)
        return .handled
    }

    /// The same, for a click inside the text view, which has no SwiftUI `openURL` to hand it to.
    static func follow(_ url: URL, roots: [URL], openWeb: ((URL) -> Void)?) {
        if route(url, roots: roots, openWeb: openWeb) == .system {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - File paths as links, remembered briefly

/// `FilePathLinks.rewrite` asks the disk whether every path in an answer exists. Remembered for
/// a few seconds: long enough that a redraw of the whole thread does not stat every path in it,
/// short enough that a file the agent has just created becomes a link.
nonisolated private final class LinkedSource: @unchecked Sendable {
    static let shared = LinkedSource()
    private static let lifetime: TimeInterval = 10
    private static let capacity = 600

    private struct Key: Hashable { var text: String; var roots: [String] }

    private let lock = NSLock()
    private var memo: [Key: (value: String, at: Date)] = [:]

    func rewrite(_ text: String, roots: [URL]) -> String {
        let key = Key(text: text, roots: roots.map(\.path))
        let now = Date()
        lock.lock()
        if let hit = memo[key], now.timeIntervalSince(hit.at) < Self.lifetime {
            lock.unlock()
            return hit.value
        }
        lock.unlock()

        let value = FilePathLinks.rewrite(text, roots: roots)

        lock.lock(); defer { lock.unlock() }
        if memo.count >= Self.capacity {
            memo = memo.filter { now.timeIntervalSince($0.value.at) < Self.lifetime }
            if memo.count >= Self.capacity { memo.removeAll(keepingCapacity: true) }
        }
        memo[key] = (value, now)
        return value
    }
}
