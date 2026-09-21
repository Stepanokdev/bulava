import Foundation

/// Which of the skills he already owns this project has any business using.
///
/// The engine's own picker never produced anything. It detects seven signals in a repository, maps
/// five of them to five skill names, and those names — `storekit-subscriptions`,
/// `push-notifications`, `auth-flows` — exist in no catalogue it can reach, so `suggest` prints
/// "not in the index" and `resolve` has nothing to fetch. pocket-ledger has been through that path
/// many times and no skill was ever installed.
///
/// This answers a different and more useful question, and answers it from what is already here.
/// His skills are hand-picked and global, so they are ALREADY loaded in every project — nothing
/// needs installing. What was missing is which of them applies where, and in one case, which of
/// several mutually exclusive ones he has chosen.
///
/// Nothing here picks an aesthetic. Three of these skills each set a whole look, applying two at
/// once is a defect, and which one a product wears is a brand decision — so an unmade choice is
/// reported as unmade rather than guessed at.
nonisolated struct SkillFit: Identifiable, Equatable, Sendable {

    /// The skill's name, matching an installed skill.
    var skill: String

    /// Why it applies here, in one clause, grounded in what was actually found in the repository.
    var because: String

    /// True when this is one of several mutually exclusive choices and none has been made.
    var needsHisChoice: Bool = false

    var id: String { skill }

    // MARK: What the repository is

    /// The evidence, read off the file tree — never inferred from the project's name.
    nonisolated struct Shape: Equatable, Sendable {
        var hasAppleUI = false
        var hasMacTarget = false
        var hasWebUI = false
        var hasUserFacingProse = false

        var showsAnUI: Bool { hasAppleUI || hasWebUI }
    }

    /// Aesthetic skills, which are mutually exclusive: each sets a whole look.
    static let aesthetics = ["high-end-visual-design", "minimalist-ui", "industrial-brutalist-ui"]

    static func shape(ofProjectAt path: String,
                      fileNames: [String]? = nil) -> Shape {
        let names = fileNames ?? scanNames(path)
        var shape = Shape()
        for name in names {
            let lower = name.lowercased()
            if lower.hasSuffix(".swift") || lower.hasSuffix(".storyboard")
                || lower.hasSuffix(".xib") { shape.hasAppleUI = true }
            if lower.hasSuffix(".xcodeproj") || lower.hasSuffix(".xcworkspace") {
                shape.hasAppleUI = true
            }
            if lower.hasSuffix(".tsx") || lower.hasSuffix(".jsx") || lower.hasSuffix(".vue")
                || lower.hasSuffix(".svelte") || lower.hasSuffix(".html")
                || lower.hasSuffix(".css") || lower.hasSuffix(".scss") { shape.hasWebUI = true }
            if lower.hasSuffix(".md") || lower.hasSuffix(".xcstrings")
                || lower.hasSuffix(".strings") { shape.hasUserFacingProse = true }
        }
        // A Mac app or an iOS one: the native patterns are different sets and the skill for one is
        // wrong for the other. The Xcode project says which, so it is read rather than guessed
        // from the folder's name.
        if shape.hasAppleUI, fileNames == nil {
            shape.hasMacTarget = mentionsMacPlatform(projectAt: path)
        }
        return shape
    }

    /// Whether an Xcode project in this folder builds for macOS.
    static func mentionsMacPlatform(projectAt path: String) -> Bool {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }
        for name in names where name.hasSuffix(".xcodeproj") {
            let file = root.appendingPathComponent(name)
                .appendingPathComponent("project.pbxproj")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if text.contains("SDKROOT = macosx") { return true }
            if text.contains("SUPPORTED_PLATFORMS = \"macosx") { return true }
        }
        return false
    }

    /// File and directory names in the repository, one level of interest deep.
    ///
    /// Deliberately shallow and capped. This is a hint for a panel, not an audit: walking a
    /// hundred thousand files to decide whether to suggest a design skill would be worse than
    /// suggesting nothing.
    private static func scanNames(_ path: String, limit: Int = 4000) -> [String] {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let skip: Set<String> = ["node_modules", "Pods", "build", "DerivedData", "vendor", "dist",
                                 "target", ".git", "venv", "Carthage", "__pycache__", ".build"]
        var names: [String] = []
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        while let url = walker.nextObject() as? URL {
            let name = url.lastPathComponent
            if skip.contains(name) {
                walker.skipDescendants()
                continue
            }
            names.append(name)
            if names.count >= limit { break }
        }
        return names
    }

    // MARK: The suggestion

    /// - Parameters:
    ///   - installed: names of skills that are available in this project (global ones included —
    ///     they already are).
    ///   - usedHere: names this project has actually used, which is how a chosen aesthetic is
    ///     recognised without asking him to record it twice.
    static func suggest(shape: Shape, installed: Set<String>,
                        usedHere: Set<String> = []) -> [SkillFit] {
        var out: [SkillFit] = []

        func offer(_ skill: String, _ because: String, needsHisChoice: Bool = false) {
            guard installed.contains(skill) else { return }
            out.append(SkillFit(skill: skill, because: because, needsHisChoice: needsHisChoice))
        }

        if shape.hasMacTarget && shape.hasAppleUI {
            offer("macos-design", String(localized: "a Mac app — the native patterns are a different set from iOS"))
        }
        if shape.hasWebUI {
            offer("design-taste-frontend", String(localized: "web UI in the repository"))
            offer("frontend-ui-engineering", String(localized: "web UI in the repository"))
        }
        if shape.showsAnUI {
            offer("impeccable", String(localized: "there is an interface to audit and polish"))
        }
        if shape.hasUserFacingProse {
            offer("humanizer", String(localized: "there is prose a person reads"))
        }

        // The aesthetic. Exactly one, and only he can say which — so if the project has already
        // used one, that IS the answer; if it has used none, the choice is named as his to make.
        if shape.showsAnUI {
            let available = aesthetics.filter { installed.contains($0) }
            let chosen = available.filter { usedHere.contains($0) }
            if chosen.count == 1 {
                out.append(SkillFit(skill: chosen[0],
                                    because: String(localized: "the look this product already wears")))
            } else if chosen.count > 1 {
                for skill in chosen {
                    out.append(SkillFit(skill: skill,
                                        because: String(localized: "two looks have been applied here — only one can be right"),
                                        needsHisChoice: true))
                }
            } else {
                for skill in available {
                    out.append(SkillFit(skill: skill,
                                        because: String(localized: "one of these, and only one — a brand decision, so yours"),
                                        needsHisChoice: true))
                }
            }
        }
        return out
    }
}
