import Foundation

// MARK: - Which folder a chat works in

/// One of the product's folders, as the chat's folder menu offers it.
struct ChatFolderChoice: Identifiable, Equatable {
    var id: UUID { project.id }
    var project: Project
    /// What the product calls it — the name he gave the folder when he connected it.
    var name: String
    /// "Ask before editing": the agent may work there, and asks before changing anything.
    var asksBeforeEditing: Bool
}

/// Moving a conversation to another of its product's folders, decided apart from the app so it can
/// be tested without one.
///
/// A big product is several folders, and the one Bulava picks as the default is simply the first
/// writable repository — often the heaviest, the one whose root `npm test` the check after every
/// answer then runs. The folder a chat works in decides where its agent starts, which folder is
/// "main" in its context, and where that check runs, so he can choose it: before the first message,
/// at no cost, and later too, at the cost of a new session.
nonisolated enum ChatFolderMove {

    /// Why the folder cannot be changed right now.
    enum Lock: Equatable {
        /// A turn, a check or a review is under way, or a message is waiting to be delivered. The
        /// session would be stopped under it — and a check of another folder started from the chat
        /// writes into the run folder a move removes.
        case working
        /// The chat works in a separate copy of a folder, and the copy is that folder's.
        case inCopy
        /// An automation's run: its folder is the automation's.
        case automationRun
    }

    enum Step: Equatable {
        /// Already there.
        case nothing
        /// Nothing has been said in this chat yet: remember the choice, start nothing.
        case choose
        /// A conversation is under way: its session belongs to the folder it was started in, so
        /// it ends, and the next message starts a new one in the chosen folder.
        case move
    }

    static func step(current: UUID?, target: UUID, hasConversation: Bool) -> Step {
        if current == target { return .nothing }
        return hasConversation ? .move : .choose
    }

    // MARK: What the new session is told

    /// How much of the conversation the new session gets. Enough to know what was being worked on,
    /// not a transcript: the visible history stays in the chat, and a long one sent on every move
    /// would cost more than it tells.
    static let carriedMessages = 12
    static let carriedCharactersPerMessage = 800
    static let carriedCharacters = 8000

    struct Line: Equatable {
        var mine: Bool
        var text: String
    }

    /// The conversation's last exchanges, oldest first, each cut to a readable length.
    static func excerpt(_ entries: [ConversationEntry]) -> [Line] {
        var lines: [Line] = []
        for entry in entries where entry.hiddenNotice != true {
            let mine: Bool
            switch entry.kind {
            case .user: mine = true
            case .foreman, .codex: mine = false
            default: continue
            }
            var text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, !mine {
                text = entry.blocks.filter { $0.kind == .markdown }.map(\.text)
                    .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else { continue }
            if text.count > carriedCharactersPerMessage {
                text = String(text.prefix(carriedCharactersPerMessage)) + "…"
            }
            lines.append(Line(mine: mine, text: text))
        }
        var kept = Array(lines.suffix(carriedMessages))
        while kept.count > 1, kept.reduce(0, { $0 + $1.text.count }) > carriedCharacters {
            kept.removeFirst()
        }
        return kept
    }

    /// What goes in front of the first message after a move.
    static func preamble(from oldPath: String, to newPath: String, lines: [Line]) -> String {
        var parts = [String(format: String(localized: "This chat was moved from the folder %@ to %@, so you are starting a new session here."),
                            "`\(oldPath)`", "`\(newPath)`")]
        if !lines.isEmpty {
            parts.append(String(localized: "The last messages of this chat, so you know what we were working on:"))
            parts.append(lines.map { line in
                let who = line.mine ? String(localized: "Me") : String(localized: "You")
                let quoted = line.text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> " + $0 }.joined(separator: "\n")
                return "**\(who):**\n\(quoted)"
            }.joined(separator: "\n\n"))
        }
        parts.append(String(localized: "My new message:"))
        return parts.joined(separator: "\n\n")
    }
}

extension AppModel {

    /// The folder this chat works in, as the screen should name it. Read only — unlike
    /// `chatPrimary(for:chatID:)`, which repairs a binding to a folder the product no longer has
    /// and so must not be called while a view is being drawn. Both answer the same: the chat's own
    /// folder while it is one of the product's, otherwise the product's default.
    func chatFolder(productID: UUID, chatID: UUID?) -> Project? {
        guard let product = products.product(id: productID) else { return nil }
        if let chatID, let saved = conversations.chat(id: chatID)?.session?.primaryProjectID,
           product.allProjectIDs.contains(saved), let project = projects.project(id: saved) {
            return project
        }
        return product.defaultProjectID.flatMap { projects.project(id: $0) }
    }

    /// The product's folders a chat can work in, in the order the product lists them.
    func chatFolderChoices(productID: UUID) -> [ChatFolderChoice] {
        guard let product = products.product(id: productID) else { return [] }
        var seen = Set<UUID>()
        return product.resources.compactMap { resource in
            guard let id = resource.projectID, seen.insert(id).inserted,
                  let project = projects.project(id: id), !project.path.isEmpty else { return nil }
            let name = resource.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatFolderChoice(project: project, name: name.isEmpty ? project.name : name,
                                    asksBeforeEditing: resource.access.isReadOnly)
        }
    }

    /// Why this chat's folder cannot be changed now, or nil when it can.
    func chatFolderLock(chatID: UUID?) -> ChatFolderMove.Lock? {
        guard let chatID, let chat = conversations.chat(id: chatID) else { return nil }
        if chat.isAutomationRun { return .automationRun }
        if chat.workCopyID != nil { return .inCopy }
        if movingChatFolders.contains(chatID) || sendingChatIDs.contains(chatID)
            || chatCopyMaking[chatID] != nil || isDirectChatBusy(chatID)
            || checkingElsewhere[chatID]?.isEmpty == false {
            return .working
        }
        if let binding = chat.session, let instance = matchingInstance(for: binding),
           instance.turnRunning || instance.queuedMessageCount > 0 {
            return .working
        }
        if conversations.entries(inChat: chatID).contains(where: { $0.kind == .user && $0.delivery == .queued }) {
            return .working
        }
        return nil
    }

    /// Whether anything has been said in this chat — what makes a change of folder a move.
    func chatHasConversation(_ chatID: UUID?) -> Bool {
        guard let chatID else { return false }
        return conversations.entries(inChat: chatID).contains { $0.kind == .user }
    }

    /// Make `projectID` the folder this chat works in. Returns why it could not be done, or nil.
    ///
    /// Before the first message this is only a choice: it is written down and the first message
    /// starts there. After it, the chat MOVES: the session in the old folder is stopped, the
    /// conversation stays where it is on screen, and the next message starts a new session in the
    /// new folder, carrying the end of the conversation with it. A Claude session and a Codex thread
    /// belong to the directory they were started in — resuming either somewhere else would continue
    /// a conversation about somebody else's files — so neither is carried over.
    ///
    /// Choosing a folder gives no permission the product does not: a folder marked "ask before
    /// editing" stays that way in the context the agent reads.
    @discardableResult
    func chooseChatFolder(_ projectID: UUID, productID: UUID, chatID: UUID?) async -> String? {
        guard let product = products.product(id: productID),
              product.allProjectIDs.contains(projectID),
              let target = projects.project(id: projectID) else {
            return String(localized: "That folder is no longer part of this product.")
        }
        // The control can be shown before a chat exists; choosing is what makes one.
        let chatID = chatID ?? conversations.currentChat(for: productID).id
        if let refusal = Self.folderLockProblem(chatFolderLock(chatID: chatID)) { return refusal }

        let current = chatFolder(productID: productID, chatID: chatID)
        switch ChatFolderMove.step(current: current?.id, target: target.id,
                                   hasConversation: chatHasConversation(chatID)) {
        case .nothing:
            return nil
        case .choose:
            conversations.bindSession(ChatSessionBinding(primaryProjectID: target.id, projectPath: target.path),
                                      to: chatID)
            return nil
        case .move:
            break
        }

        movingChatFolders.insert(chatID)
        defer { movingChatFolders.remove(chatID) }

        let old = conversations.chat(id: chatID)?.session
        // The old folder's session is this chat's to end, and ending it is what keeps it from being
        // adopted: an instance no chat claims is taken over by the next chat that sends in that
        // folder, which would resume THIS conversation in somebody else's chat.
        if let old, let instance = matchingInstance(for: old) {
            if let failure = await releaseProject(path: instance.projectPath, session: instance.session) {
                return Self.releaseProblem(failure)
            }
        }
        // Asked again: the release took a moment, and the folder could have left the product in it.
        guard let product = products.product(id: productID), product.allProjectIDs.contains(target.id) else {
            return String(localized: "That folder is no longer part of this product.")
        }
        let from = old?.projectPath.isEmpty == false ? old!.projectPath : (current?.path ?? "")
        conversations.bindSession(
            ChatSessionBinding(primaryProjectID: target.id, projectPath: target.path,
                               reportPaths: old?.reportPaths ?? [],
                               // Kept from an earlier move whose hand-over no session or thread has
                               // received yet: the conversation is still the one that left that
                               // folder. Once one has, `movedFrom` is cleared and the folder it is
                               // leaving now is where it comes from.
                               movedFrom: old?.movedFrom ?? (from.isEmpty ? nil : from)),
            to: chatID)
        // What was blocking the old folder — a trust prompt, a holder, git consent — is not the new
        // folder's, and an error naming the old one would be read as being about the new one.
        chatErrors[chatID] = nil
        trustBlocked[chatID] = nil
        handoffBlocked[chatID] = nil
        gitConsentBlocked[chatID] = nil
        dirtyTreeBlocked[chatID] = nil
        let name = chatFolderChoices(productID: productID).first { $0.id == target.id }?.name ?? target.name
        conversations.postNotice(
            String(format: String(localized: "Now working in %@. The next message starts a new session there and passes it the last messages of this chat."), name),
            productID: productID, chatID: chatID, tone: .neutral, once: false)
        return nil
    }

    /// The conversation so far, for message `entryID` to carry because this chat was just moved —
    /// or nil when it has nothing to carry.
    ///
    /// One message carries it at a time: the first sent after the move, and every retry of that one
    /// until it is delivered (`folderMoveHandoffDelivered`). A second message sent while the first is
    /// still on its way carries nothing — the new session is about to be told. A carrier that failed
    /// gives the hand-over up, so a new message sent instead of a retry carries it in its place.
    /// Everything said before `entryID` goes in, never the message itself.
    func folderMoveHandoff(chatID: UUID, for entryID: UUID) -> String? {
        guard let binding = conversations.chat(id: chatID)?.session,
              let from = binding.movedFrom, !from.isEmpty else { return nil }
        if let carrier = binding.handoffEntryID, carrier != entryID,
           let carrying = conversations.entry(id: carrier), carrying.delivery != .failed {
            return nil
        }
        if binding.handoffEntryID != entryID {
            conversations.updateSession(for: chatID) { $0.handoffEntryID = entryID }
        }
        var history = conversations.entries(inChat: chatID)
        if let cut = history.firstIndex(where: { $0.id == entryID }) {
            history = Array(history[..<cut])
        }
        return ChatFolderMove.preamble(from: from, to: binding.projectPath,
                                       lines: ChatFolderMove.excerpt(history))
    }

    /// Message `entryID` was answered with an error, and nobody knows whether the session or thread
    /// kept what it carried. It stops carrying the hand-over, so the next message sent carries it.
    /// A message marked failed needs no call: a failed carrier gives the hand-over up by itself.
    func folderMoveHandoffReleased(chatID: UUID, entryID: UUID) {
        guard conversations.chat(id: chatID)?.session?.handoffEntryID == entryID else { return }
        conversations.updateSession(for: chatID) { $0.handoffEntryID = nil }
    }

    /// Message `entryID` reached the new folder's session or thread. If it carried the hand-over,
    /// that conversation now remembers what was said and nothing after it carries it again.
    ///
    /// Not when a session merely started: the start writes its id before the message is sent, and a
    /// send that fails after that left a session that was never told.
    func folderMoveHandoffDelivered(chatID: UUID, entryID: UUID) {
        guard let binding = conversations.chat(id: chatID)?.session,
              binding.movedFrom != nil, binding.handoffEntryID == entryID else { return }
        conversations.updateSession(for: chatID) {
            $0.movedFrom = nil
            $0.handoffEntryID = nil
        }
    }

    nonisolated static func folderLockProblem(_ lock: ChatFolderMove.Lock?) -> String? {
        switch lock {
        case nil: return nil
        case .working?: return String(localized: "The agent is still working in this chat. Change the folder once it has finished.")
        case .inCopy?: return String(localized: "This chat works in a separate copy of its folder, so its folder cannot be changed.")
        case .automationRun?: return String(localized: "An automation's run works in the automation's folder.")
        }
    }
}
