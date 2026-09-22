import SwiftUI
import Observation

@MainActor
@Observable
final class ConversationStore {
    private(set) var entries: [ConversationEntry] = []
    private(set) var chats: [Chat] = []

    private let file: JSONFile<[ConversationEntry]>
    private let chatFile: JSONFile<[Chat]>

    init(fileURL: URL = AppSupport.file("conversations.json"),
         chatsURL: URL = AppSupport.file("chats.json")) {
        file = JSONFile<[ConversationEntry]>(url: fileURL)
        chatFile = JSONFile<[Chat]>(url: chatsURL)
        entries = file.load() ?? []
        chats = chatFile.load() ?? []
        adoptFinishedTurns()
        heal()
    }

    private func persist() { file.save(entries) }

    private func persistChats() {
        chats = Self.merge(memory: chats, stored: chatFile.load() ?? [])
        chatFile.save(chats)
    }

    nonisolated static func merge(memory: [Chat], stored: [Chat],
                                  removing doomed: Set<UUID> = []) -> [Chat] {
        var merged: [UUID: Chat] = [:]
        for chat in stored { merged[chat.id] = chat }
        for chat in memory {
            if let existing = merged[chat.id], existing.updatedAt > chat.updatedAt { continue }
            var chat = chat
            if chat.session == nil, let keep = merged[chat.id]?.session { chat.session = keep }
            merged[chat.id] = chat
        }
        for id in doomed { merged.removeValue(forKey: id) }
        return merged.values.sorted { $0.createdAt < $1.createdAt }
    }

    private func heal() {
        let known = Set(chats.map(\.id))
        let loose = entries.filter { $0.chatID == nil || !known.contains($0.chatID!) }
        defer { pruneEmptyChats() }
        guard !loose.isEmpty else { return }
        var made = 0
        for productID in Set(loose.map(\.productID)) {
            let mine = loose.filter { $0.productID == productID }.sorted { $0.at < $1.at }
            let seed = mine.first { $0.kind == .user }?.text ?? mine.first?.text ?? ""
            let chat = Chat(productID: productID,
                            title: seed.isEmpty ? String(localized: "Earlier") : Chat.title(from: seed),
                            createdAt: mine.first?.at ?? Date(),
                            updatedAt: mine.last?.at ?? Date(),
                            firstMessage: seed)
            chats.append(chat)
            let ids = Set(mine.map(\.id))
            for i in entries.indices where ids.contains(entries[i].id) { entries[i].chatID = chat.id }
            made += 1
        }
        if made > 0 { persist(); persistChats() }
    }

    private func pruneEmptyChats() {
        let used = Set(entries.compactMap(\.chatID))
        let empty = chats.filter { !used.contains($0.id) }
        guard !empty.isEmpty else { return }

        chats = Self.merge(memory: chats, stored: chatFile.load() ?? [],
                           removing: Set(empty.map(\.id)))
        chatFile.save(chats)
    }

    // MARK: - Chats

    func chats(for productID: UUID) -> [Chat] {
        chats.filter { $0.productID == productID && !$0.archived }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                return a.createdAt > b.createdAt
            }
    }

    func archivedChats(for productID: UUID) -> [Chat] {
        chats.filter { $0.productID == productID && $0.archived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func chat(id: UUID) -> Chat? { chats.first { $0.id == id } }

    private(set) var openChatID: [UUID: UUID] = [:]

    func open(_ chatID: UUID, for productID: UUID) { openChatID[productID] = chatID }

    func currentChatID(for productID: UUID) -> UUID? {
        if let id = openChatID[productID], let chat = chat(id: id), !chat.archived { return id }
        return chats(for: productID).first?.id
    }

    @discardableResult
    func currentChat(for productID: UUID) -> Chat {
        if let id = openChatID[productID], let chat = chat(id: id), !chat.archived { return chat }
        if let existing = chats(for: productID).first { openChatID[productID] = existing.id; return existing }
        let fresh = newChat(for: productID)
        openChatID[productID] = fresh.id
        return fresh
    }

    @discardableResult

    func newChat(for productID: UUID) -> Chat {
        let chat = Chat(productID: productID, title: String(localized: "New chat"))
        chats.append(chat)
        openChatID[productID] = chat.id
        return chat
    }

    private func titleIfNeeded(_ chatID: UUID, from text: String) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }), chats[i].firstMessage.isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chats[i].firstMessage = text
        chats[i].title = Chat.title(from: text)
    }

    func rename(_ chatID: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[i].title = String(clean.prefix(80))
        persistChats()
    }

    func setArchived(_ chatID: UUID, _ archived: Bool) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[i].archived = archived
        persistChats()
    }

    func togglePinned(_ chatID: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[i].pinned.toggle()
        persistChats()
    }

    func bindSession(_ binding: ChatSessionBinding, to chatID: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[i].session = binding
        chats[i].updatedAt = max(chats[i].updatedAt, Date())
        persistChats()
    }

    func updateSession(for chatID: UUID, _ mutate: (inout ChatSessionBinding) -> Void) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }), chats[i].session != nil else { return }
        mutate(&chats[i].session!)
        chats[i].updatedAt = max(chats[i].updatedAt, Date())
        persistChats()
    }

    func addReport(_ path: String, to chatID: UUID) {
        updateSession(for: chatID) { session in
            if !session.reportPaths.contains(path) { session.reportPaths.append(path) }
            session.lastReportedTurnKey = session.lastCompletedTurnKey
            session.outcomeAt = nil
        }
    }

    func completeTurn(_ turnKey: String, at: Date, in chatID: UUID) {
        guard let i = chats.firstIndex(where: { $0.id == chatID }),
              var session = chats[i].session,
              session.lastCompletedTurnKey != turnKey else { return }
        let reported = session.hasReported(turnKey: turnKey)
        session.lastCompletedTurnKey = turnKey
        if reported { session.lastReportedTurnKey = turnKey }
        session.outcomeAt = reported ? nil : at
        chats[i].session = session
        chats[i].updatedAt = max(chats[i].updatedAt, max(at, Date()))
        persistChats()
    }

    private func touch(_ chatID: UUID?) {
        guard let chatID, let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[i].updatedAt = max(chats[i].updatedAt, Date())
        persistChats()
    }

    // MARK: - Reads

    func all(for productID: UUID) -> [ConversationEntry] {
        entries.filter { $0.productID == productID }
    }

    func live(inChat chatID: UUID, isFinished: (UUID) -> Bool) -> [ConversationEntry] {
        entries(inChat: chatID).filter { entry in
            guard let taskID = entry.taskID else { return true }
            return !isFinished(taskID)
        }
    }

    func live(for productID: UUID, isFinished: (UUID) -> Bool) -> [ConversationEntry] {
        all(for: productID).filter { entry in
            guard let taskID = entry.taskID else { return true }
            return !isFinished(taskID)
        }
    }

    func entry(id: UUID) -> ConversationEntry? { entries.first { $0.id == id } }

    func closingLine(taskID: UUID) -> String? {
        entries.last { $0.taskID == taskID && $0.kind == .foreman && !$0.text.isEmpty }?.text
    }

    func openQuestion(for productID: UUID, isFinished: (UUID) -> Bool) -> ConversationEntry? {
        live(for: productID, isFinished: isFinished).last { $0.kind == .question }
    }

    func entries(inChat chatID: UUID) -> [ConversationEntry] {
        entries.enumerated()
            .filter { $0.element.chatID == chatID }
            .sorted { $0.element.at == $1.element.at ? $0.offset < $1.offset
                                                     : $0.element.at < $1.element.at }
            .map(\.element)
    }

    // MARK: - Writes

    func append(_ entry: ConversationEntry) {
        var entry = entry
        if entry.chatID == nil { entry.chatID = currentChat(for: entry.productID).id }
        entries.append(entry)
        if entry.kind == .user { titleIfNeeded(entry.chatID!, from: entry.text) }
        touch(entry.chatID)
        persist()
    }

    @discardableResult
    func appendUser(_ text: String, productID: UUID, chatID: UUID? = nil,
                    attachments: [Attachment] = [], taskID: UUID? = nil) -> ConversationEntry {
        var e = ConversationEntry(productID: productID, kind: .user, text: text,
                                  taskID: taskID, attachments: attachments)
        e.chatID = chatID
        append(e)
        return e
    }

    @discardableResult
    func appendForeman(_ text: String, productID: UUID, chatID: UUID? = nil,
                       taskID: UUID? = nil, proposalID: UUID? = nil) -> ConversationEntry {
        var e = ConversationEntry(productID: productID, kind: .foreman, text: text,
                                  taskID: taskID, proposalID: proposalID)
        e.chatID = chatID
        append(e)
        return e
    }

    @discardableResult
    func beginForemanTurn(productID: UUID, at: Date = Date(), taskID: UUID? = nil,
                          chatID: UUID? = nil, kind: ConversationEntry.Kind = .foreman) -> UUID {
        var e = ConversationEntry(productID: productID, kind: kind, at: at, taskID: taskID)

        e.chatID = chatID
        append(e)
        return e.id
    }

    func updateBlocks(entryID: UUID, blocks: [ConversationBlock], text: String? = nil,
                      persist shouldPersist: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == entryID }) else { return }
        guard entries[i].blocks != blocks || (text != nil && entries[i].text != text) else { return }
        entries[i].blocks = blocks

        if let text { entries[i].text = text }
        if shouldPersist { persist() }
    }

    @discardableResult
    func failOrphanedQueued(inChat chatID: UUID, olderThan seconds: TimeInterval,
                            stillParked: Set<UUID> = [], now: Date = Date()) -> [ConversationEntry] {
        var lost: [ConversationEntry] = []
        for i in entries.indices where entries[i].chatID == chatID
            && entries[i].kind == .user && entries[i].delivery == .queued
            && !stillParked.contains(entries[i].id)
            && now.timeIntervalSince(entries[i].at) >= seconds {
            entries[i].delivery = .failed
            lost.append(entries[i])
        }
        if !lost.isEmpty { persist() }
        return lost
    }

    @discardableResult
    func withdrawLostNotice(for entry: ConversationEntry) -> Bool {
        guard let chatID = entry.chatID else { return false }
        let excerpt = String(entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ").prefix(60))
        guard !excerpt.isEmpty else { return false }
        let before = entries.count
        entries.removeAll { candidate in
            candidate.kind == .event && candidate.chatID == chatID
                && candidate.text.contains(excerpt)
                && candidate.text.contains(String(localized: "never reached the worker"))
        }
        guard entries.count != before else { return false }
        persist()
        return true
    }

    func withdrawStaleLostNotices(inChat chatID: UUID) {
        let marker = String(localized: "never reached the worker")
        guard entries.contains(where: {
            $0.chatID == chatID && $0.kind == .event && $0.text.contains(marker)
        }) else { return }
        let delivered = entries.filter {
            $0.chatID == chatID && $0.kind == .user && $0.delivery == nil
        }.map { entry -> String in
            String(entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ").prefix(60))
        }.filter { !$0.isEmpty }
        guard !delivered.isEmpty else { return }
        let before = entries.count
        entries.removeAll { candidate in
            candidate.kind == .event && candidate.chatID == chatID
                && candidate.text.contains(marker)
                && delivered.contains(where: { candidate.text.contains($0) })
        }
        if entries.count != before { persist() }
    }

    func updateDelivery(entryID: UUID, _ delivery: ConversationEntry.Delivery?) {
        guard let i = entries.firstIndex(where: { $0.id == entryID }),
              entries[i].delivery != delivery else { return }
        entries[i].delivery = delivery
        persist()
    }

    /// Offer, on this message, to let Claude answer the one Codex refused.
    ///
    /// Stored on the entry so it is still there after a relaunch and so a second refused message
    /// gets its own offer rather than the first one's.
    func setCodexWall(entryID: UUID, _ wall: String?) {
        guard let i = entries.firstIndex(where: { $0.id == entryID }),
              entries[i].codexWall != wall else { return }
        entries[i].codexWall = wall
        persist()
    }

    /// Use it, once. Returns the wall it held, or nil when there was nothing open on this entry —
    /// which is how a second press, or a callback from before a relaunch, comes to nothing.
    func consumeCodexWall(entryID: UUID) -> String? {
        guard let i = entries.firstIndex(where: { $0.id == entryID }),
              let wall = entries[i].codexWall else { return nil }
        entries[i].codexWall = nil
        persist()
        return wall
    }

    /// Take the CLI's sign-in notice out of the conversation for good.
    ///
    /// Marked rather than deleted: the chat feed re-reads the session transcript every second and
    /// would write it straight back. Marked on the entry rather than remembered in the app, so it
    /// is still gone tomorrow morning.
    func hideNotice(entryID: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == entryID }),
              entries[i].hiddenNotice != true else { return }
        entries[i].hiddenNotice = true
        persist()
    }

    /// Record whether the turn behind an entry has ended.
    ///
    /// Called by `ChatTranscriptFeed.publish` on every drain with the reducer's own answer, so it
    /// corrects itself as well as sets: a segment the fold decides to keep writing goes back to
    /// unfinished, and the action that reads this disappears while it does. Persisted only on a
    /// change, because the drain runs once a second.
    func setTurnFinished(entryID: UUID, _ finished: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == entryID }),
              entries[i].turnFinished != finished else { return }
        entries[i].turnFinished = finished
        persist()
    }

    /// Settle the entries written before anything recorded this, once.
    ///
    /// Launch is the one moment when the answer is knowable without the fold: no feed has started,
    /// so nothing in the file is being written to. An answer that was cut off by a crash is
    /// finished in the only sense that matters here — it is not streaming — and if its session is
    /// resumed the fold says so again on its first drain.
    private func adoptFinishedTurns() {
        var touched = false
        for i in entries.indices where entries[i].kind == .foreman && entries[i].turnFinished == nil {
            entries[i].turnFinished = true
            touched = true
        }
        if touched { persist() }
    }

    func dropIfEmpty(entryID: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == entryID }),
              entries[i].blocks.renderable.isEmpty,
              entries[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.remove(at: i)
        persist()
    }

    func anchorTask(_ taskID: UUID, productID: UUID, title: String) {
        guard !entries.contains(where: { $0.kind == .task && $0.taskID == taskID }) else { return }
        append(ConversationEntry(productID: productID, kind: .task, text: title, taskID: taskID))
    }

    @discardableResult
    func dropDeadAnchors(known: Set<UUID>) -> Int {
        let before = entries.count
        entries.removeAll { $0.kind == .task && ($0.taskID.map { !known.contains($0) } ?? true) }
        let removed = before - entries.count
        if removed > 0 { persist() }
        return removed
    }

    func repairEnglishOutcomeLeaks() {
        var touched = 0
        for i in entries.indices {
            let text = entries[i].text
            guard text.contains("Needs you") || text.contains("Review debt") else { continue }
            var fixed = text
                .replacingOccurrences(of: ": Needs you. Треба твоє рішення.",
                                      with: " і чекає на твоє рішення.")
                .replacingOccurrences(of: ": Needs you.", with: " і чекає на твоє рішення.")
                .replacingOccurrences(of: "Review debt", with: String(localized: "Review debt"))
            if fixed.contains("Needs you") {
                fixed = fixed.replacingOccurrences(of: "Needs you", with: String(localized: "Needs you"))
            }
            if fixed != text { entries[i].text = fixed; touched += 1 }
        }
        if touched > 0 { persist() }
    }

    func postQuestion(_ text: String, productID: UUID, taskID: UUID?,
                      decision: DecisionRecord? = nil) {
        if let taskID {
            let existing = entries.filter { $0.kind == .question && $0.taskID == taskID }

            if let i = entries.firstIndex(where: { $0.kind == .question && $0.taskID == taskID
                                                  && $0.text == text }),
               let decision, entries[i].decision != decision {
                entries[i].decision = decision
                persist()
            }
            if existing.contains(where: { $0.text == text }) {
                if existing.count > 1 {

                    let keep = existing.first!.id
                    entries.removeAll { $0.kind == .question && $0.taskID == taskID && $0.id != keep }
                    persist()
                }
                return
            }
            entries.removeAll { $0.kind == .question && $0.taskID == taskID }
        }
        append(ConversationEntry(productID: productID, kind: .question, text: text,
                                 taskID: taskID, decision: decision))
    }

    func syncDirectQuestion(_ question: ConversationEntry?, in chatID: UUID) {
        var changed = false
        if let question {
            if let i = entries.firstIndex(where: { $0.id == question.id }) {
                if entries[i] != question { entries[i] = question; changed = true }
            } else {
                entries.append(question)
                changed = true
            }
            let before = entries.count
            entries.removeAll { $0.kind == .question && $0.taskID == nil && $0.chatID == chatID
                                && $0.id != question.id }
            changed = changed || entries.count != before
        } else {
            let before = entries.count
            entries.removeAll { $0.kind == .question && $0.taskID == nil && $0.chatID == chatID }
            changed = entries.count != before
        }
        if changed { persist() }
    }

    func remove(entryID: UUID) {
        let before = entries.count
        entries.removeAll { $0.id == entryID }
        if entries.count != before { persist() }
    }

    @discardableResult
    func resolveQuestion(taskID: UUID, answered: Int? = nil) -> Bool {
        guard let answered,
              let i = entries.firstIndex(where: { $0.kind == .question && $0.taskID == taskID }),
              var record = entries[i].decision, record.items.count > 1,
              answered >= 1, answered <= record.items.count else {
            let before = entries.count
            entries.removeAll { $0.kind == .question && $0.taskID == taskID }
            if entries.count != before { persist() }
            return false
        }
        record.items.remove(at: answered - 1)
        entries[i].decision = record

        if record.items.count == 1 { entries[i].text = record.items[0].question }
        persist()
        return true
    }

    func answers(taskID: UUID, since: Date) -> [String] {
        entries.filter { $0.kind == .user && $0.taskID == taskID && $0.at >= since }
            .map(\.text).filter { !$0.isEmpty }
    }

    func postReport(_ title: String, productID: UUID, taskID: UUID) {
        guard lastReportAt(taskID: taskID) == nil else { return }
        append(ConversationEntry(productID: productID, kind: .report, text: title, taskID: taskID))
    }

    func lastReportAt(taskID: UUID) -> Date? {
        entries.last { $0.kind == .report && $0.taskID == taskID }?.at
    }

    func postUpdatedReport(_ title: String, productID: UUID, taskID: UUID) {
        append(ConversationEntry(productID: productID, kind: .report, text: title, taskID: taskID))
    }

    func postEvent(_ text: String, productID: UUID,
                   tone: ConversationEntry.Tone = .neutral, taskID: UUID? = nil) {
        append(ConversationEntry(productID: productID, kind: .event, text: text,
                                 tone: tone, taskID: taskID))
    }

    func postEventOnce(_ text: String, productID: UUID,
                       tone: ConversationEntry.Tone = .neutral, taskID: UUID? = nil) {
        guard !entries.contains(where: {
            $0.productID == productID && $0.kind == .event && $0.text == text
        }) else { return }
        postEvent(text, productID: productID, tone: tone, taskID: taskID)
    }

    func postEventOnce(_ text: String, productID: UUID, chatID: UUID,
                       tone: ConversationEntry.Tone = .neutral) {
        guard !entries.contains(where: {
            $0.chatID == chatID && $0.kind == .event && $0.text == text
        }) else { return }
        var entry = ConversationEntry(productID: productID, kind: .event, text: text, tone: tone)
        entry.chatID = chatID
        append(entry)
    }

    func hasOpenQuestion(taskID: UUID) -> Bool {
        entries.contains { $0.kind == .question && $0.taskID == taskID }
    }

    func postDecision(_ text: String, productID: UUID, taskID: UUID? = nil) {
        append(ConversationEntry(productID: productID, kind: .decision, text: text, taskID: taskID))
    }

    func detach(taskID: UUID, keepingIn productID: UUID) {
        var changed = false
        entries.removeAll { entry in
            let structural = entry.kind == .task || entry.kind == .question || entry.kind == .report
            let match = entry.taskID == taskID && structural
            if match { changed = true }
            return match
        }
        for i in entries.indices where entries[i].taskID == taskID {
            entries[i].taskID = nil
            entries[i].productID = productID
            changed = true
        }
        if changed { persist() }
    }

    func removeAll(for productID: UUID) {
        entries.removeAll { $0.productID == productID }
        persist()
    }

    func move(taskID: UUID, to productID: UUID) {
        var changed = false
        for i in entries.indices where entries[i].taskID == taskID && entries[i].productID != productID {
            entries[i].productID = productID
            changed = true
        }
        if changed { persist() }
    }
}
