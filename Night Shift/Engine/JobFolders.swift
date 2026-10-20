import Foundation

/// The plain folder a job's runs work in (`AutomationWorkMode.job`): one per automation, kept
/// between its runs, never a repository.
///
/// Not a copy of anything. Nothing in it is reset, merged or swept: what a run leaves there — a
/// note for the next run, a report it was asked to write — is there for the next one, and goes when
/// the automation does. His own folders are given to a run to read; this is the only place it writes.
nonisolated enum JobFolders {

    static var root: URL { WorkCopies.jobsRoot }

    /// The automation's folder, if it has been made. Found by the automation's id, so renaming the
    /// automation keeps its folder and what is in it.
    static func existing(for automationID: UUID) -> URL? {
        let suffix = "-" + short(automationID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().first { $0.hasSuffix(suffix) }
            .map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// The automation's folder, made the first time a run needs it. Nil when it cannot be made.
    ///
    /// Named after the automation as well as its id, so the folder a run is told it works in reads
    /// as what it is. No spaces, as for the copies: a script that never met one in a path must not
    /// meet one here.
    static func prepare(for automationID: UUID, name: String) -> URL? {
        if let folder = existing(for: automationID) { return folder }
        let folder = root.appendingPathComponent(WorkCopies.sanitized(WorkCopies.branchSlug(name)) + "-"
                                                 + short(automationID), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    /// What its runs wrote for him in `artifacts/`, once the automation has gone: carried out of the
    /// folder before it is removed, so a report a run's chat points at still opens.
    static func kept(for automationID: UUID) -> URL {
        AppSupport.root.appendingPathComponent("copies-kept/job-\(automationID.uuidString)/artifacts",
                                               isDirectory: true)
    }

    /// The folder goes with its automation. Its `artifacts/`, when a run wrote anything there, is
    /// carried to `kept(for:)` first; returns where, or nil when there was nothing to carry.
    @discardableResult
    static func remove(for automationID: UUID) -> URL? {
        guard let folder = existing(for: automationID) else { return nil }
        let fm = FileManager.default
        let artifacts = folder.appendingPathComponent("artifacts", isDirectory: true)
        var carried: URL?
        let names = ((try? fm.contentsOfDirectory(atPath: artifacts.path)) ?? []).filter { !$0.hasPrefix(".") }
        if !names.isEmpty {
            let kept = kept(for: automationID)
            try? fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: kept.path), (try? fm.moveItem(at: artifacts, to: kept)) != nil {
                carried = kept
            }
        }
        // Left in place when what it held for him could not be carried: a folder too many is
        // better than a report gone.
        if names.isEmpty || carried != nil { try? fm.removeItem(at: folder) }
        return carried
    }

    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }
}
