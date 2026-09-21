import Foundation

nonisolated enum ClaudeSlashCommandSource: Int, Sendable, Equatable {
    case project = 0
    case addedFolder = 1
    case personal = 2
    case plugin = 3
}

nonisolated struct ClaudeSlashCommand: Identifiable, Sendable, Equatable {
    let name: String
    let description: String
    let argumentHint: String
    let source: ClaudeSlashCommandSource

    var id: String { name.lowercased() }
    var invocation: String { "/" + name }
}

nonisolated struct SlashCommandQuery: Sendable, Equatable {
    let fragment: String

    init?(_ text: String) {
        guard text.first == "/" else { return nil }
        let remainder = text.dropFirst()
        guard !remainder.contains(where: \.isWhitespace) else { return nil }
        fragment = String(remainder).lowercased()
    }

    func matches(in commands: [ClaudeSlashCommand]) -> [ClaudeSlashCommand] {
        commands
            .filter { fragment.isEmpty || $0.name.lowercased().contains(fragment) }
            .sorted { lhs, rhs in
                let left = lhs.name.lowercased()
                let right = rhs.name.lowercased()
                let leftPrefix = fragment.isEmpty || left.hasPrefix(fragment)
                let rightPrefix = fragment.isEmpty || right.hasPrefix(fragment)
                if leftPrefix != rightPrefix { return leftPrefix }
                if lhs.source.rawValue != rhs.source.rawValue {
                    return lhs.source.rawValue < rhs.source.rawValue
                }
                return left.localizedStandardCompare(right) == .orderedAscending
            }
    }
}

nonisolated enum SlashCommandCatalog {
    struct Roots: Sendable, Equatable {
        var primaryProject: URL?
        var addedProjects: [URL]
        var homeDirectory: URL

        init(primaryProject: URL?, addedProjects: [URL],
             homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
            self.primaryProject = primaryProject
            self.addedProjects = addedProjects
            self.homeDirectory = homeDirectory
        }
    }

    private struct Candidate {
        var command: ClaudeSlashCommand
        var priority: Int
    }

    static func discover(_ roots: Roots) -> [ClaudeSlashCommand] {
        let fm = FileManager.default
        let settings = effectiveSettings(roots: roots, fileManager: fm)
        var resolved: [String: Candidate] = [:]

        func offer(_ command: ClaudeSlashCommand, priority: Int) {
            let key = normalized(command.name)
            guard !key.isEmpty else { return }

            guard command.source == .plugin || settings.skillOverrides[key] != "off" else { return }
            if let existing = resolved[key], existing.priority >= priority { return }
            resolved[key] = Candidate(command: command, priority: priority)
        }

        let personal = roots.homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        scanCommands(at: personal.appendingPathComponent("commands", isDirectory: true),
                     source: .personal, priority: 410, namespace: nil,
                     fileManager: fm, offer: offer)
        scanSkills(at: personal.appendingPathComponent("skills", isDirectory: true),
                   source: .personal, priority: 420, namespace: nil,
                   fileManager: fm, offer: offer)

        if let primary = roots.primaryProject {

            for (distance, projectRoot) in configurationRoots(startingAt: primary,
                                                               fileManager: fm).enumerated() {
                let claude = projectRoot.appendingPathComponent(".claude", isDirectory: true)
                let base = 310 - distance * 2
                scanCommands(at: claude.appendingPathComponent("commands", isDirectory: true),
                             source: .project, priority: base, namespace: nil,
                             fileManager: fm, offer: offer)
                scanSkills(at: claude.appendingPathComponent("skills", isDirectory: true),
                           source: .project, priority: base + 1, namespace: nil,
                           fileManager: fm, offer: offer)
            }
        }

        for added in roots.addedProjects {
            scanSkills(at: added.appendingPathComponent(".claude/skills", isDirectory: true),
                       source: .addedFolder, priority: 210, namespace: nil,
                       fileManager: fm, offer: offer)
        }

        scanEnabledPlugins(settings.enabledPlugins, homeDirectory: roots.homeDirectory,
                           fileManager: fm, offer: offer)

        return resolved.values.map(\.command).sorted {
            if $0.source.rawValue != $1.source.rawValue {
                return $0.source.rawValue < $1.source.rawValue
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Skills and commands

    private static func scanSkills(at root: URL, source: ClaudeSlashCommandSource, priority: Int,
                                   namespace: String?, fileManager fm: FileManager,
                                   offer: (ClaudeSlashCommand, Int) -> Void) {
        guard let children = try? fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return }
        for directory in children where isDirectory(directory, fileManager: fm) {
            if directory.lastPathComponent.lowercased() == "synced", namespace == nil {
                scanSkills(at: directory, source: source, priority: priority,
                           namespace: namespace, fileManager: fm, offer: offer)
                continue
            }
            let file = directory.appendingPathComponent("SKILL.md")
            guard let document = SkillDocument(file: file), document.userInvocable else { continue }
            let localName = namespace == nil
                ? directory.lastPathComponent
                : (document.name?.isEmpty == false ? document.name! : directory.lastPathComponent)
            let commandName = namespace.map { "\($0):\(localName)" } ?? localName
            offer(ClaudeSlashCommand(name: commandName,
                                     description: document.description,
                                     argumentHint: document.argumentHint,
                                     source: source), priority)
        }
    }

    private static func scanCommands(at root: URL, source: ClaudeSlashCommandSource, priority: Int,
                                     namespace: String?, fileManager fm: FileManager,
                                     offer: (ClaudeSlashCommand, Int) -> Void) {
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "md",
                  let document = SkillDocument(file: file), document.userInvocable else { continue }
            let localName = file.deletingPathExtension().lastPathComponent
            let commandName = namespace.map { "\($0):\(localName)" } ?? localName
            offer(ClaudeSlashCommand(name: commandName,
                                     description: document.description,
                                     argumentHint: document.argumentHint,
                                     source: source), priority)
        }
    }

    private static func isDirectory(_ url: URL, fileManager fm: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: - Plugins

    private struct InstalledPlugins: Decodable {
        struct Install: Decodable { var installPath: String }
        var plugins: [String: [Install]]
    }

    private static func scanEnabledPlugins(_ enabled: [String: Bool], homeDirectory: URL,
                                           fileManager fm: FileManager,
                                           offer: (ClaudeSlashCommand, Int) -> Void) {
        let file = homeDirectory.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: file),
              let installed = try? JSONDecoder().decode(InstalledPlugins.self, from: data) else { return }

        for (identifier, isEnabled) in enabled where isEnabled {
            guard let installs = installed.plugins[identifier],
                  let install = installs.last(where: { fm.fileExists(atPath: $0.installPath) }) else { continue }
            let pluginName = String(identifier.split(separator: "@", maxSplits: 1).first ?? "")
            guard !pluginName.isEmpty else { continue }
            let root = URL(fileURLWithPath: install.installPath, isDirectory: true)
            scanCommands(at: root.appendingPathComponent("commands", isDirectory: true),
                         source: .plugin, priority: 110, namespace: pluginName,
                         fileManager: fm, offer: offer)
            scanSkills(at: root.appendingPathComponent("skills", isDirectory: true),
                       source: .plugin, priority: 111, namespace: pluginName,
                       fileManager: fm, offer: offer)

            let skills = root.appendingPathComponent("skills", isDirectory: true)
            if !fm.fileExists(atPath: skills.path) {
                let file = root.appendingPathComponent("SKILL.md")
                if let document = SkillDocument(file: file), document.userInvocable {
                    let localName = document.name?.isEmpty == false
                        ? document.name!
                        : root.lastPathComponent
                    offer(ClaudeSlashCommand(name: "\(pluginName):\(localName)",
                                             description: document.description,
                                             argumentHint: document.argumentHint,
                                             source: .plugin), 111)
                }
            }
        }
    }

    // MARK: - Settings

    private struct SettingsFile: Decodable {
        var skillOverrides: [String: String]?
        var enabledPlugins: [String: Bool]?
    }

    private struct EffectiveSettings {
        var skillOverrides: [String: String] = [:]
        var enabledPlugins: [String: Bool] = [:]

        mutating func merge(_ file: URL, includeSkillOverrides: Bool = true) {
            guard let data = try? Data(contentsOf: file),
                  let settings = try? JSONDecoder().decode(SettingsFile.self, from: data) else { return }
            if includeSkillOverrides {
                for (name, value) in settings.skillOverrides ?? [:] {
                    skillOverrides[SlashCommandCatalog.normalized(name)] = value.lowercased()
                }
            }
            for (name, value) in settings.enabledPlugins ?? [:] { enabledPlugins[name] = value }
        }
    }

    private static func effectiveSettings(roots: Roots, fileManager fm: FileManager) -> EffectiveSettings {
        var settings = EffectiveSettings()
        let personal = roots.homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        settings.merge(personal.appendingPathComponent("settings.json"))
        settings.merge(personal.appendingPathComponent("settings.local.json"))

        for added in roots.addedProjects {
            let claude = added.appendingPathComponent(".claude", isDirectory: true)
            settings.merge(claude.appendingPathComponent("settings.json"),
                           includeSkillOverrides: false)
            settings.merge(claude.appendingPathComponent("settings.local.json"),
                           includeSkillOverrides: false)
        }
        if let primary = roots.primaryProject {
            for root in configurationRoots(startingAt: primary, fileManager: fm).reversed() {
                let claude = root.appendingPathComponent(".claude", isDirectory: true)
                settings.merge(claude.appendingPathComponent("settings.json"))
                settings.merge(claude.appendingPathComponent("settings.local.json"))
            }
        }
        return settings
    }

    private static func configurationRoots(startingAt start: URL,
                                           fileManager fm: FileManager) -> [URL] {
        var roots: [URL] = []
        var current = start.standardizedFileURL
        while true {
            roots.append(current)
            let git = current.appendingPathComponent(".git")
            if fm.fileExists(atPath: git.path) { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return roots
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Frontmatter

private nonisolated struct SkillDocument {
    var name: String?
    var description: String
    var argumentHint: String
    var userInvocable: Bool

    init?(file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let parsed = Self.parse(text)
        name = parsed.fields["name"]
        description = parsed.fields["description"] ?? Self.firstParagraph(parsed.body)
        argumentHint = parsed.fields["argument-hint"] ?? ""
        userInvocable = !Self.falseValues.contains(
            parsed.fields["user-invocable"]?.lowercased() ?? ""
        )
    }

    private static let falseValues: Set<String> = ["false", "no", "off", "0"]

    private static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else { return ([:], text) }

        var fields: [String: String] = [:]
        var index = 1
        while index < closing {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, line.first?.isWhitespace != true,
                  let colon = trimmed.firstIndex(of: ":") else {
                index += 1
                continue
            }
            let key = String(trimmed[..<colon]).lowercased()
            var value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value == "|" || value == ">" {
                let folded = value == ">"
                index += 1
                var block: [String] = []
                while index < closing {
                    let blockLine = lines[index]
                    guard blockLine.first.map({ $0.isWhitespace }) == true || blockLine.isEmpty else { break }
                    block.append(blockLine.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = block.joined(separator: folded ? " " : "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                fields[key] = value
                continue
            }
            fields[key] = unquoted(value)
            index += 1
        }

        let bodyStart = lines.index(after: closing)
        let body = bodyStart < lines.endIndex ? lines[bodyStart...].joined(separator: "\n") : ""
        return (fields, body)
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func firstParagraph(_ body: String) -> String {
        var paragraph: [String] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            if paragraph.isEmpty, line.hasPrefix("#") { continue }
            paragraph.append(line)
        }
        return paragraph.joined(separator: " ")
    }
}
