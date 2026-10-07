import Foundation

/// The way a run in one of his chats sees and makes the product's automations (`$IDIR/automation`)
/// — through Bulava, which alone writes them, the way a run asks him to decide (`DecisionCenter`).
///
/// A run used to know nothing of automations: one that had Bulava's source on hand once quit the
/// app and wrote `automations.json` by hand, and in any other chat "make this run every week" had
/// no way to happen. Now the run asks: the request is a file in the engine's state folder, Bulava
/// reads it, and answers in the file beside it.
///
/// What is made is his at once — on, in his list, said in the chat it was asked in and in a card
/// with "Turn off" — because it is made only when he asked for it there. A run without him (an
/// automation's own run, a night run with no chat) makes none: nothing makes automations behind
/// his back, and no automation multiplies itself.
@MainActor
final class AutomationDoor {
    weak var model: AppModel?
    private var requests: URL?
    private var timer: Task<Void, Never>?
    private var inFlight: Set<String> = []
    /// The Codex turns going on now, by the word each was given (`BULAVA_CHAT_TURN`). A Codex chat
    /// has no run folder to say which chat it is, so its turn carries a word of its own, and a
    /// request with that word is from that chat for as long as the turn lasts — and from no one after.
    private var codexTurns: [String: UUID] = [:]

    static let maxBrief = 20_000
    static let maxName = 80
    /// The command gives up after 20 seconds and takes its request away; one left this long belongs
    /// to a command that died, and answering it now would act on words nobody is waiting for.
    static let staleAfter: TimeInterval = 120

    func attach(_ model: AppModel, stateDir: URL?) {
        self.model = model
        requests = stateDir?.appendingPathComponent("automation-requests", isDirectory: true)
        guard let requests else { return }
        try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        announce()
        timer = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                // Detached while asleep: no last drain, and no word that Bulava is still here.
                if Task.isCancelled { break }
                self?.drain()
                ticks += 1
                if ticks % 12 == 0 { self?.announce() }
            }
        }
    }

    /// Where requests are left: a Codex turn is let write here from inside its sandbox.
    var requestsDirectory: URL? { requests }

    func openCodexTurn(chatID: UUID) -> String {
        let word = UUID().uuidString.lowercased()
        codexTurns[word] = chatID
        return word
    }

    func closeCodexTurn(_ word: String) {
        codexTurns[word] = nil
    }

    func detach() {
        timer?.cancel()
        timer = nil
        if let requests { try? FileManager.default.removeItem(at: requests.appendingPathComponent("service.json")) }
    }

    private func announce() {
        guard let requests else { return }
        let payload: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "since": Int(Date().timeIntervalSince1970)]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: requests.appendingPathComponent("service.json"), options: .atomic)
        }
    }

    private func drain() {
        guard let requests, let names = try? FileManager.default.contentsOfDirectory(atPath: requests.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") && name != "service.json" {
            let id = String(name.dropLast(5))
            let done = requests.appendingPathComponent("\(id).done")
            guard !inFlight.contains(id), !FileManager.default.fileExists(atPath: done.path) else { continue }
            let request = requests.appendingPathComponent(name)
            if let made = (try? FileManager.default.attributesOfItem(atPath: request.path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(made) > Self.staleAfter {
                try? FileManager.default.removeItem(at: request)
                continue
            }
            inFlight.insert(id)
            let answer = serve(requests.appendingPathComponent(name))
            if let data = try? JSONSerialization.data(withJSONObject: answer) { try? data.write(to: done, options: .atomic) }
            inFlight.remove(id)
        }
    }

    // MARK: Answering

    /// `{"op": "list" | "create", "project", …}` from a run: `name`, `when`, `brief`, `mode`
    /// ("branch" | "check") and `confirmFirst` for a new one. `turn` when it is from a Codex chat.
    func serve(_ request: URL) -> [String: Any] {
        guard let model, let data = try? Data(contentsOf: request),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let op = object["op"] as? String, let project = object["project"] as? String else {
            return refusal(String(localized: "The request is not readable."))
        }
        let asking: Chat?
        if let word = object["turn"] as? String, !word.isEmpty {
            // From a Codex chat: the chat its turn was given the word for, while that turn lasts.
            guard let chatID = codexTurns[word] else {
                return refusal(String(localized: "This chat's turn is over. Ask again in the chat."))
            }
            asking = model.conversations.chat(id: chatID)
        } else {
            asking = Self.chat(workingIn: project, run: object["run"] as? String, model: model)
        }
        guard let chat = asking, let product = model.products.product(id: chat.productID) else {
            return refusal(String(localized: "No chat is working in that project now."))
        }
        switch op {
        case "list":
            return ["ok": true, "product": product.name, "automations": list(product)]
        case "create":
            return create(object, chat: chat, product: product, model: model)
        default:
            return refusal("unknown op \(op)")
        }
    }

    private func refusal(_ message: String) -> [String: Any] { ["ok": false, "error": message] }

    private func list(_ product: Product) -> [[String: Any]] {
        guard let model else { return [] }
        return model.automations.automations.filter { $0.productID == product.id }.map { a in
            var line: [String: Any] = [
                "name": a.name,
                "when": AutomationPresentation.triggerLine(a.trigger),
                "on": a.enabled,
                "mode": a.checksOnly ? "check" : "branch",
            ]
            if let why = a.pausedReason { line["paused"] = why }
            if let last = model.automations.runs.filter({ $0.automationID == a.id }).map(\.createdAt).max() {
                line["lastRun"] = Int(last.timeIntervalSince1970)
            }
            return line
        }
    }

    private func create(_ object: [String: Any], chat: Chat, product: Product, model: AppModel) -> [String: Any] {
        // Made only where he asked for it: an automation's own run, or a run in no chat of his,
        // makes none.
        guard !chat.isAutomationRun else {
            return refusal(String(localized: "An automation's own run does not make automations. Ask him in one of his chats."))
        }
        let name = (object["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = (object["brief"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.maxName else {
            return refusal("--name: 1–\(Self.maxName) characters")
        }
        guard !brief.isEmpty, brief.count <= Self.maxBrief else {
            return refusal("--brief-file: the brief is empty or longer than \(Self.maxBrief) characters")
        }
        guard let trigger = AutomationWhen.parse(object["when"] as? String ?? "") else {
            return refusal("--when: manual | hourly N | daily HH:MM | weekdays HH:MM | weekly mon,thu HH:MM | monthly D HH:MM, optionally ending in “away”")
        }
        guard !model.automations.automations.contains(where: {
            $0.productID == product.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            return refusal(String(format: String(localized: "“%@” already has an automation called “%@”."), product.name, name))
        }
        guard let folder = model.chatPrimary(for: product, chatID: chat.id) else {
            return refusal(String(localized: "The product has no folder for an automation to work in."))
        }
        var automation = Automation(productID: product.id, projectID: folder.id, name: name, brief: brief,
                                    trigger: trigger, confirmFirst: object["confirmFirst"] as? Bool ?? false)
        automation.workMode = (object["mode"] as? String) == "check" ? .checkOnly : .branch
        model.automations.add(automation)

        let when = AutomationPresentation.triggerLine(trigger)
        let said = String(format: String(localized: "Automation “%@” made: %@."), name, when)
        model.conversations.postEventOnce(said, productID: product.id, chatID: chat.id)
        let id = automation.id
        model.toast = ToastMessage(
            title: said,
            text: String(localized: "Made at your request in this chat. It runs by itself from now on; each run is a new chat in a copy of the folder."),
            kind: .success, key: "automation-made-\(id.uuidString)",
            actions: [
                ToastAction(title: String(localized: "Open")) { [weak model] in model?.navigate(to: .automation(id)) },
                ToastAction(title: String(localized: "Turn off"), primary: false) { [weak model] in
                    model?.setAutomationEnabled(id, false)
                },
            ])
        return ["ok": true, "id": id.uuidString, "name": name, "when": when, "folder": folder.name]
    }

    /// The chat whose run is working in this project: the one that asked. With the run's id (from
    /// its folder), only the chat bound to that very run: a run with no chat of its own is answered
    /// by none, even when an older chat once had the same Claude session — it does not get to make
    /// automations in that chat's name.
    static func chat(workingIn project: String, run: String? = nil, model: AppModel) -> Chat? {
        let path = Slug.canonicalPath(URL(fileURLWithPath: project).resolvingSymlinksInPath().standardizedFileURL.path)
        let run = run.flatMap { $0.isEmpty ? nil : $0 }
        let running = model.snapshot.instances.filter {
            Slug.canonicalPath($0.projectPath) == path && (run == nil || $0.runID == run)
        }
        let asking = model.conversations.chats.filter { chat in
            guard let binding = chat.session, let instance = model.matchingInstance(for: binding) else { return false }
            return running.contains { $0.slug == instance.slug }
        }
        if let run { return asking.first { $0.session?.activeRunID == run } }
        return asking.first
    }
}
