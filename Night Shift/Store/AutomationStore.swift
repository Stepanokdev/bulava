import Foundation
import Observation

/// His automations, every run they made, and the copies those runs worked in.
///
/// Three small files beside the chat history rather than inside it: a year of weekly runs is a few
/// hundred records, and none of them belongs in `conversations.json`, which is read whole and
/// searched whole.
@MainActor
@Observable
final class AutomationStore {
    private(set) var automations: [Automation] = []
    private(set) var runs: [AutomationRun] = []
    private(set) var copies: [WorkCopy] = []

    private let automationFile: JSONFile<[Lossy<Automation>]>
    private let runFile: JSONFile<[Lossy<AutomationRun>]>
    private let copyFile: JSONFile<[Lossy<WorkCopy>]>

    /// Runs kept per automation. The quiet ones go first; anything waiting for him is never cut.
    static let runHistoryLimit = 400

    init(directory: URL = AppSupport.root) {
        automationFile = JSONFile(url: directory.appendingPathComponent("automations.json"))
        runFile = JSONFile(url: directory.appendingPathComponent("automation-runs.json"))
        copyFile = JSONFile(url: directory.appendingPathComponent("work-copies.json"))
        automations = (automationFile.load() ?? []).compactMap(\.value)
        runs = (runFile.load() ?? []).compactMap(\.value)
        copies = (copyFile.load() ?? []).compactMap(\.value)
    }

    private func saveAutomations() { automationFile.save(automations.map(Lossy.init)) }
    private func saveRuns() { runFile.save(runs.map(Lossy.init)) }
    private func saveCopies() { copyFile.save(copies.map(Lossy.init)) }

    // MARK: Automations

    func automation(id: UUID) -> Automation? { automations.first { $0.id == id } }

    func automations(for productID: UUID) -> [Automation] {
        automations.filter { $0.productID == productID }.sorted { $0.createdAt < $1.createdAt }
    }

    func add(_ automation: Automation) {
        automations.append(automation)
        saveAutomations()
    }

    func update(_ id: UUID, _ change: (inout Automation) -> Void) {
        guard let i = automations.firstIndex(where: { $0.id == id }) else { return }
        var a = automations[i]
        change(&a)
        guard a != automations[i] else { return }
        a.updatedAt = Date()
        automations[i] = a
        saveAutomations()
    }

    /// The automation goes; its history stays readable from the runs' own conversations.
    func remove(_ id: UUID) {
        automations.removeAll { $0.id == id }
        saveAutomations()
    }

    // MARK: Runs

    func run(id: UUID) -> AutomationRun? { runs.first { $0.id == id } }

    func run(forChat chatID: UUID) -> AutomationRun? { runs.first { $0.chatID == chatID } }

    func runs(for automationID: UUID) -> [AutomationRun] {
        runs.filter { $0.automationID == automationID }.sorted { $0.createdAt > $1.createdAt }
    }

    func hasRun(occurrence: String, for automationID: UUID) -> Bool {
        runs.contains { $0.automationID == automationID && $0.occurrence == occurrence }
    }

    /// Recorded before anything is started for it, so a second ask for the same occurrence — a
    /// restart in the same minute, a timer and a button together — finds it and does nothing.
    @discardableResult
    func record(_ run: AutomationRun) -> Bool {
        guard !hasRun(occurrence: run.occurrence, for: run.automationID) else { return false }
        runs.append(run)
        trim(run.automationID)
        saveRuns()
        return true
    }

    func updateRun(_ id: UUID, _ change: (inout AutomationRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        var r = runs[i]
        change(&r)
        guard r != runs[i] else { return }
        runs[i] = r
        saveRuns()
    }

    private func trim(_ automationID: UUID) {
        let mine = runs.filter { $0.automationID == automationID }
        guard mine.count > Self.runHistoryLimit else { return }
        let removable = mine.filter { $0.state.isTerminal && !$0.wantsHim }
            .sorted { a, b in
                if a.isQuiet != b.isQuiet { return a.isQuiet }
                return a.createdAt < b.createdAt
            }
            .prefix(mine.count - Self.runHistoryLimit)
        let doomed = Set(removable.map(\.id))
        runs.removeAll { doomed.contains($0.id) }
    }

    // MARK: Copies

    func copy(id: UUID) -> WorkCopy? { copies.first { $0.id == id } }

    func addCopy(_ copy: WorkCopy) {
        copies.removeAll { $0.id == copy.id }
        copies.append(copy)
        saveCopies()
    }

    func updateCopy(_ id: UUID, _ change: (inout WorkCopy) -> Void) {
        guard let i = copies.firstIndex(where: { $0.id == id }) else { return }
        var c = copies[i]
        change(&c)
        guard c != copies[i] else { return }
        copies[i] = c
        saveCopies()
    }

    var liveCopies: [WorkCopy] { copies.filter(\.isLive) }
}

/// One record that will not decode — a field from a newer build — is dropped on its own instead
/// of taking every other record in the file down with it.
nonisolated struct Lossy<Value: Codable & Sendable>: Codable, Sendable {
    var value: Value?

    init(_ value: Value) { self.value = value }

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value?.encode(to: encoder)
    }
}
