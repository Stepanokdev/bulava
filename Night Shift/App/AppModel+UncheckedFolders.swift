import Foundation
import AppKit

// MARK: - What the check after an answer did not look at

/// The check after an answer runs in the chat's folder only. When the work was done in another of
/// the product's repositories — the chat stayed in the default folder, the agent went next door —
/// that check either measured an untouched folder (and was skipped) or measured the wrong one, and
/// the changed repository was never checked at all. The review knew; nothing on screen said so.
///
/// This is what the chat shows under the answer about it: which folders changed unchecked, and for
/// each, a check run from the chat since — so the offer turns into its result instead of repeating.
nonisolated struct UncheckedFolders: Equatable, Sendable {

    struct Folder: Identifiable, Equatable, Sendable {
        var id: String { path }
        var path: String
        /// What the product calls it, or the folder's own name for a repository nested in the chat's.
        var name: String
        /// One of the product's folders, so the chat can move there; nil for a nested repository.
        var projectID: UUID?
        /// A check run from the chat after this answer's own check, if there was one.
        var result: ElsewhereResult?

        var isSettled: Bool { result?.verdict == .passed || result?.verdict == .nothingToRun }
    }

    var primaryName: String
    /// Nothing changed in the chat's own folder (or only prose), so nothing ran there either.
    var primaryUntouched: Bool
    var folders: [Folder]
    /// The run whose answer this is: a check from the chat is run in it and nowhere else.
    var runID: String?
    /// That run still holds its folder. Once it has stopped, its record of the other repositories is
    /// gone and nothing can be checked from it: the row still says what went unchecked, and offers
    /// only what can still be done.
    var canCheck: Bool

    /// A check of one folder made from the chat, and the digest of the tree it checked.
    struct Checked: Equatable, Sendable {
        var result: ElsewhereResult
        var at: Date
        var digest: String

        init(_ result: ElsewhereResult, at: Date, digest: String = "") {
            self.result = result
            self.at = at
            self.digest = digest
        }
    }

    /// Worth a row under the answer: a folder still unchecked, or a check that did not pass. A check
    /// that passed — or found nothing to run — has said so in the thread and needs nothing more.
    var needsAttention: Bool { folders.contains { !$0.isSettled } }

    /// Only for the answer on screen. Evidence written before his last message is the check of an
    /// earlier turn, and one turn's "unchecked" said under the next answer would be about other work.
    ///
    /// A check from the chat counts when it was made after this answer's own check — or earlier, of
    /// exactly the tree this answer's check found there. The engine names a repository after every
    /// answer while it differs from the start of the run, so without the second rule a check made a
    /// minute ago would be "not checked" again under an answer that never touched it.
    static func make(evidence: Evidence, writtenAt: Date, lastAskedAt: Date?, primaryName: String,
                     names: [String: (name: String, projectID: UUID?)],
                     results: [String: Checked], runID: String? = nil,
                     canCheck: Bool = true) -> UncheckedFolders? {
        guard !evidence.unverifiedElsewhere.isEmpty else { return nil }
        if let lastAskedAt, writtenAt < lastAskedAt { return nil }
        let folders = evidence.unverifiedElsewhere.map { path -> Folder in
            let key = Slug.canonicalPath(path)
            let known = names[key]
            let tree = evidence.unverifiedElsewhereDigests[path] ?? ""
            let checked = results[key].flatMap { check -> ElsewhereResult? in
                if check.at >= writtenAt { return check.result }
                if !tree.isEmpty, check.digest == tree { return check.result }
                return nil
            }
            return Folder(path: path, name: known?.name ?? (path as NSString).lastPathComponent,
                          projectID: known?.projectID, result: checked)
        }
        return UncheckedFolders(primaryName: primaryName, primaryUntouched: evidence.primaryUntouched,
                                folders: folders, runID: runID, canCheck: canCheck)
    }
}

/// How a check of another folder came out, read from its evidence.
nonisolated struct ElsewhereResult: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        case passed, failed
        /// Something could not run to the end — a timeout, a missing tool, no base to compare with.
        case unfinished
        case nothingToRun
    }

    var verdict: Verdict
    /// The checks that failed, or — when it passed — the ones that ran.
    var checks: [String]
    /// The first failing check's log, to open.
    var log: String?

    var passed: Bool { verdict == .passed }

    static func nothingToRun(_ criterion: EvidenceCriterion) -> Bool {
        criterion.command == "(none available)"
            || criterion.note.contains("no automated verification available")
    }

    init(verdict: Verdict, checks: [String], log: String? = nil) {
        self.verdict = verdict
        self.checks = checks
        self.log = log
    }

    init(_ evidence: Evidence) {
        let failed = evidence.criteria.filter { $0.status == .fail }
        // "No automated verification available for this stack" is the engine saying there is
        // nothing to run, not a check that stopped half way. Known by the placeholder it writes for
        // the command, which names no command; the sentence after it is prose and may be reworded.
        let unfinished = evidence.criteria.filter {
            $0.status == .inconclusive && !Self.nothingToRun($0)
        }
        let ran = evidence.criteria.filter { $0.status == .pass }
        if !failed.isEmpty {
            self.init(verdict: .failed, checks: failed.map(\.criterion),
                      log: failed.first { !$0.artifact.isEmpty }?.artifact)
        } else if !unfinished.isEmpty {
            self.init(verdict: .unfinished, checks: unfinished.map(\.criterion),
                      log: unfinished.first { !$0.artifact.isEmpty }?.artifact)
        } else if !ran.isEmpty {
            self.init(verdict: .passed, checks: ran.map(\.criterion))
        } else {
            self.init(verdict: .nothingToRun, checks: [])
        }
    }

    /// One line for the thread, so the result is part of the conversation — on the Mac and on the
    /// phone — and not only of a row that is gone after the next message.
    func sentence(folder: String) -> String {
        switch verdict {
        case .passed:
            return String(format: String(localized: "Checks in “%@” passed: %@."), folder,
                          checks.joined(separator: ", "))
        case .failed:
            return String(format: String(localized: "Checks in “%@” failed: %@."), folder,
                          checks.joined(separator: ", "))
        case .unfinished:
            return String(format: String(localized: "Checks in “%@” did not finish: %@."), folder,
                          checks.joined(separator: ", "))
        case .nothingToRun:
            return String(format: String(localized: "Nothing in “%@” could be checked automatically."), folder)
        }
    }
}

extension AppModel {

    /// The folders this chat's last answer changed without a check, or nil when there are none.
    /// Reads the engine's files, so it is asked from a view's task, not from its body.
    func uncheckedFolders(chatID: UUID?) async -> UncheckedFolders? {
        guard let chatID, let chat = conversations.chat(id: chatID), !chat.archived,
              let binding = chat.session, !directPhase(for: chatID).isActive else { return nil }
        guard let dated = await client.chatEvidenceDated(projectPath: binding.projectPath,
                                                         runID: binding.activeRunID,
                                                         sessionID: binding.claudeSessionID),
              !dated.evidence.unverifiedElsewhere.isEmpty else { return nil }

        let choices = chatFolderChoices(productID: chat.productID)
        var names: [String: (name: String, projectID: UUID?)] = [:]
        for choice in choices {
            names[Slug.canonicalPath(choice.project.path)] = (choice.name, choice.id)
        }
        var results: [String: UncheckedFolders.Checked] = [:]
        for path in dated.evidence.unverifiedElsewhere {
            if let checked = await client.elsewhereEvidence(in: dated.checkRoots, repoPath: path) {
                results[Slug.canonicalPath(path)] = UncheckedFolders.Checked(
                    ElsewhereResult(checked.evidence), at: checked.at, digest: checked.evidence.treeDigest)
            }
        }
        let primary = chatFolder(productID: chat.productID, chatID: chatID)
        let primaryName = primary.flatMap { folder in choices.first { $0.id == folder.id }?.name }
            ?? primary?.name ?? (binding.projectPath as NSString).lastPathComponent
        let lastAsked = conversations.entries(inChat: chatID).last { $0.kind == .user }?.at
        return UncheckedFolders.make(evidence: dated.evidence, writtenAt: dated.at, lastAskedAt: lastAsked,
                                     primaryName: primaryName, names: names, results: results,
                                     runID: dated.runID, canCheck: dated.runIsLive)
    }

    /// Run the check after an answer in one of the run's other repositories, because he asked from
    /// the chat. The result goes into the thread as a line of its own.
    ///
    /// In `runID` — the run whose answer named the folder — or not at all: the engine refuses when
    /// another run holds the folder now. While it runs, the chat is not moved (`chatFolderLock`): a
    /// move stops the run and removes the folder this check writes into.
    func checkElsewhere(chatID: UUID, folder: UncheckedFolders.Folder, runID: String?) async {
        guard let chat = conversations.chat(id: chatID), let binding = chat.session,
              !movingChatFolders.contains(chatID),
              checkingElsewhere[chatID]?.contains(folder.path) != true else { return }
        checkingElsewhere[chatID, default: []].insert(folder.path)
        defer {
            checkingElsewhere[chatID]?.remove(folder.path)
            if checkingElsewhere[chatID]?.isEmpty == true { checkingElsewhere[chatID] = nil }
            elsewhereRevision &+= 1
        }
        switch await client.verifyElsewhere(primaryPath: binding.projectPath, repoPath: folder.path,
                                            runID: runID) {
        case .success(let evidence):
            let result = ElsewhereResult(evidence)
            let tone: ConversationEntry.Tone = switch result.verdict {
            case .passed: .good
            case .failed: .attention
            case .unfinished, .nothingToRun: .neutral
            }
            conversations.postNotice(result.sentence(folder: folder.name), productID: chat.productID,
                                     chatID: chatID, tone: tone, once: false)
        case .failure(let failure):
            let why: String
            switch failure {
            case .noRecord, .notInRun:
                why = String(localized: "this run no longer has a record of that folder")
            case .noResult:
                why = String(localized: "the check left no result")
            }
            let text = String(format: String(localized: "Could not check “%@”: %@."), folder.name, why)
            conversations.postNotice(text, productID: chat.productID, chatID: chatID, tone: .problem, once: false)
            toast = ToastMessage(text: text, kind: .error)
        }
    }

    func openCheckLog(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
