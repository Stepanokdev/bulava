import Foundation
import OSLog

extension AppModel {

    // MARK: - Speaking

    func foremanSpeak(_ message: String, productID: UUID, chatID: UUID? = nil,
                      asked: Date = Date()) {
        guard foremanLiveEnabled else {

            postForemanText(ForemanBrain.statusSummary(self))
            return
        }

        let thread = chatID ?? conversations.currentChat(for: productID).id
        let key = ForemanSession.Key(productID: productID, chatID: thread)

        let entryID = conversations.beginForemanTurn(productID: productID, at: asked.addingTimeInterval(0.001))
        foremanTurnEntries[key, default: []].append(entryID)
        thinkingProductIDs.insert(productID)

        let cwd = foremanScope(productID)
        let onUpdate: @Sendable (ForemanSession.Update) -> Void = {
            [weak self] update in

            Task { @MainActor in
                guard let self else { return }
                let previous = self.foremanApplyChain[key]
                self.foremanApplyChain[key] = Task { @MainActor in
                    await previous?.value
                    self.apply(update, key: key)
                }
            }
        }

        let envelope = foremanEnvelope(message, productID: productID, key: key)
        let previous = foremanSendChain[key]
        let sessions = foremanSessions
        foremanSendChain[key] = Task {
            await previous?.value
            let session = await sessions.acquire(for: key, cwd: cwd, onUpdate: onUpdate)
            await session.send(envelope)
        }
    }

    private func apply(_ update: ForemanSession.Update, key: ForemanSession.Key) {
        let productID = key.productID
        guard let entryID = foremanTurnEntries[key]?.first else { return }
        switch update {

        case .turn(let blocks):

            thinkingProductIDs.remove(productID)
            let due = Date().timeIntervalSince(foremanCheckpoint[key] ?? .distantPast) > 5
            conversations.updateBlocks(entryID: entryID, blocks: blocks,
                                       text: due ? Self.plainText(of: blocks) : nil,
                                       persist: due)
            if due {
                foremanCheckpoint[key] = Date()
                rememberResume(for: key)
            }

        case .finished(let blocks, let plainText, let failed):
            thinkingProductIDs.remove(productID)

            conversations.updateBlocks(entryID: entryID, blocks: blocks,
                                       text: plainText, persist: true)
            conversations.dropIfEmpty(entryID: entryID)
            foremanTurnEntries[key]?.removeFirst()
            foremanCheckpoint[key] = nil
            rememberResume(for: key)
            if failed {

                foremanBriefed.remove(key)
                note(.taskStateChanged, .attention, "Розмова з бригадиром обірвалась.", taskID: nil)
            }

        case .scopeViolation(let observed, let mcpServers):

            thinkingProductIDs.remove(productID)

            for queued in foremanTurnEntries[key] ?? [] { conversations.dropIfEmpty(entryID: queued) }
            foremanTurnEntries[key] = nil
            foremanCheckpoint[key] = nil
            foremanBriefed.remove(key)

            foremanSessions.discard(key)
            let extra = (Set(observed).subtracting(ForemanSession.readOnlyTools).sorted()
                         + mcpServers).joined(separator: ", ")
            postForemanText(String(format: String(localized:
                "I stopped my own session: it came up with access it was not given (%@). Say it again and I will answer from what I already know."),
                extra.isEmpty ? "—" : extra))
            note(.taskStateChanged, .problem,
                 "Сесія бригадира піднялась із зайвими інструментами: \(extra)", taskID: nil)

        case .unavailable(let reason):
            thinkingProductIDs.remove(productID)
            conversations.dropIfEmpty(entryID: entryID)
            foremanTurnEntries[key]?.removeFirst()

            foremanBriefed.remove(key)
            postForemanText(reason)
        }
    }

    private func rememberResume(for key: ForemanSession.Key) {
        guard let session = foremanSessions.existing(key) else { return }
        Task { [weak self] in
            let id = await session.resumeID
            await MainActor.run { self?.foremanSessions.rememberResume(id, for: key) }
        }
    }

    nonisolated static func plainText(of blocks: [ConversationBlock]) -> String {
        blocks.filter { $0.kind == .markdown }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    func foremanStopSpeaking(productID: UUID) {
        guard let chatID = conversations.currentChatID(for: productID) else { return }
        let key = ForemanSession.Key(productID: productID, chatID: chatID)
        guard let session = foremanSessions.existing(key) else { return }
        Task { await session.cancelTurn() }
    }

    // MARK: - Where he stands

    func foremanCanSpeak(about project: Project, productID: UUID) -> Bool {
        guard foremanLiveEnabled, let cwd = foremanProjectDirectory(productID) else { return false }
        return Slug.canonicalPath(cwd.path) == Slug.canonicalPath(project.path)
    }

    func foremanScope(_ productID: UUID) -> URL {
        foremanProjectDirectory(productID) ?? Self.emptyScope
    }

    private func foremanProjectDirectory(_ productID: UUID) -> URL? {
        guard let product = products.product(id: productID) else { return nil }
        let writable = product.writableProjectIDs.compactMap { projects.project(id: $0) }
        let chosen = product.defaultProjectID.flatMap { id in writable.first { $0.id == id } }
            ?? writable.first
            ?? product.resources.compactMap { $0.projectID }.compactMap { projects.project(id: $0) }.first
        guard let path = chosen?.path,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static let emptyScope: URL = {
        let dir = AppSupport.root.appendingPathComponent("foreman-scope", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - What he is told

    private func foremanEnvelope(_ message: String, productID: UUID,
                                 key: ForemanSession.Key) -> String {
        let product = products.product(id: productID)
        var lines: [String] = []

        if !foremanBriefed.contains(key) {
            foremanBriefed.insert(key)
            lines.append(Self.foremanIdentity)
            if let product {
                lines.append("")
                lines.append("ПРОДУКТ: \(product.name)")
                if !product.summary.isEmpty { lines.append("Коротко: \(product.summary)") }
                if !product.brief.isEmpty { lines.append("Про продукт: \(product.brief)") }
                let resources = self.resources(for: product)
                if !resources.isEmpty {
                    lines.append("Ресурси:")
                    for item in resources {
                        let access = item.resource.access == .source
                            ? "ТІЛЬКИ ЧИТАННЯ" : "можна змінювати"
                        lines.append("  • \(item.resource.name) [\(access)] "
                                     + (item.project?.displayPath ?? item.resource.urlString ?? "—"))
                    }
                }
            }
            lines.append("")
        }

        lines.append("<стан зміни>")
        lines.append(ForemanBrain.stateContext(self))
        lines.append("</стан зміни>")
        lines.append("")
        lines.append(message)
        return lines.joined(separator: "\n")
    }

    private static let foremanIdentity = """
    Ти — бригадир нічної зміни в застосунку Bulava. Ти керуєш агентами, які працюють у проєктах \
    людини, з якою ти зараз розмовляєш.

    Як відповідати:
    • Звертайся на «ти», прямо до неї — не в третій особі й не по імені.
    • ЇЇ мовою, з першого слова (визнач мову з її повідомлень). Не перемикайся на англійську, \
    навіть у короткій репліці перед тим, як щось подивитись.
    • У тебе є Read/Grep/Glob у теці цього продукту — якщо питання про код, ПОДИВИСЬ і відповідай \
    фактами з файлів, а не здогадами. Не питай дозволу подивитись, просто дивись.
    • Числа про стан зміни бери ТІЛЬКИ з блоку <стан зміни>. Ніколи не вигадуй їх.
    • Ти НЕ запускаєш роботу і нічого не змінюєш — у тебе тільки читання. Якщо тебе просять щось \
    зробити, скажи одним реченням, що береш, і застосунок покаже план на підтвердження.
    • Не переказуй, що ти зараз зробиш. Роби і відповідай результатом. Без преамбул на кшталт \
    «зараз подивлюсь» — і так видно, що ти дивишся.
    • Оформлення: звичайний текст, **жирний**, `код`, списки через «•» або «-». Таблиць НЕ роби — \
    стрічка розмови їх не малює, вони перетворяться на сирі палки. Те, що просилось у таблицю, \
    давай списком.
    """
}
