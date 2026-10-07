import Foundation

/// A chat report's name in a list.
///
/// Reports are written as `…/artifacts/<yyyy-MM-dd-HHmm>-<slug>/index.html`, so every one of them is
/// called `index.html` and a list of file names says nothing. The folder says what and when.
nonisolated enum ReportName {

    /// "Нічна зміна 3-4 вересня чат диктовка моделі скіл", or the file's own name for a report
    /// that was not written that way.
    static func title(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let file = url.lastPathComponent
        let folder = url.deletingLastPathComponent().lastPathComponent
        guard file.lowercased() == "index.html" || file.lowercased().hasSuffix(".html"), !folder.isEmpty else { return file }
        let named = folder.lowercased() == "artifacts" ? (file as NSString).deletingPathExtension : folder
        let slug = parts(named)?.slug ?? named
        let words = slug.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return file }
        return first.uppercased() + words.dropFirst()
    }

    /// When it was made, read from the folder's name; nil when it carries none.
    static func date(_ path: String) -> Date? {
        parts(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent)?.date
    }

    private static func parts(_ name: String) -> (date: Date, slug: String)? {
        let pieces = name.split(separator: "-", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 5, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces[3].count == 4, pieces[3].allSatisfy(\.isNumber),
              let y = Int(pieces[0]), let m = Int(pieces[1]), let d = Int(pieces[2]),
              let h = Int(pieces[3].prefix(2)), let min = Int(pieces[3].suffix(2)) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        guard let date = Calendar.current.date(from: c) else { return nil }
        return (date, pieces[4])
    }
}
