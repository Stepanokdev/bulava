import Foundation

nonisolated struct ForemanIntent: Sendable {
    enum Action: String, Sendable {
        case answer, status, done, blocked, review, capacity, activity
        case runQueue = "run_queue", stopAll = "stop_all", dispatchReady = "dispatch_ready"
        case createTask = "create_task", look
        case watch
        case approve, relay, clarify, unknown
    }
    var action: Action
    var target: String?
    var reply: String
    var taskTitle: String? = nil
    var visual: Bool = false
}

nonisolated struct ForemanProposal: Sendable, Equatable {
    var id = UUID()
    var action: ForemanIntent.Action
    var taskID: UUID?
    var label: String
    var draftTask: BacklogTask? = nil
    var draftSubtasks: [SubtaskDraft] = []

    var sourceMessage: String = ""

    var attachments: [Attachment] = []
}

nonisolated struct SubtaskDraft: Sendable, Equatable {
    var title: String
    var detail: String
    var acceptance: [String]
    var projectID: UUID?
    var projectPath: String?
    var projectName: String
    var dependsOn: [Int]
    var visual: Bool

    var behavior: Bool = false
    var userFacingCopy: Bool = false

    var holds: [TaskHold] = []

    var preparation: Bool = false

    var readsOnly: Bool = false
}

nonisolated enum ForemanConfirm {
    static let affirm: Set<String> = ["так", "yes", "y", "ага", "угу", "давай", "го", "ок", "окей", "ok", "+",
                                      "ага давай", "так давай", "давай так", "так, давай", "підтверджую",
                                      "підтверджу", "confirm", "approve", "поїхали", "погнали", "жени", "мерджь", "мерджи"]
    static let deny: Set<String> = ["ні", "нє", "no", "nope", "не треба", "не тре", "не варто", "не зараз",
                                    "та ні", "та нє", "скасуй", "скасувати", "відміна", "відмінити",
                                    "стоп", "stop", "cancel", "почекай", "wait", "поки не"]
    static func normalized(_ s: String) -> String {
        var n = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = n.last, "!.,;:? ".contains(last) { n.removeLast() }
        return n
    }
    static func isAffirmative(_ s: String) -> Bool { affirm.contains(normalized(s)) }
    static func isNegative(_ s: String) -> Bool { deny.contains(normalized(s)) }
}

@MainActor
enum ForemanRouter {

    static func decide(message: String, model: AppModel) async -> ForemanIntent {
        let prompt = buildPrompt(message: message, model: model)
        guard let raw = await model.client.askClaude(prompt: prompt, timeout: 90),
              let intent = parse(raw) else {

            return ForemanIntent(action: .clarify, target: nil,
                reply: "Не впевнений, що вловив — напиши коротко, що зробити і в якому проєкті, і я візьму в роботу.")
        }
        return intent
    }

    // MARK: Prompt

    private static func buildPrompt(message: String, model: AppModel) -> String {
        """
        Ти — бригадир нічної зміни (застосунок Night Shift). Зрозумій, ЩО користувач хоче ЗАРАЗ — з контексту розмови та реального стану зміни — і поверни РІВНО ОДИН JSON-обʼєкт (без пояснень, без code fences, без тексту навколо).

        Дозволені "action":
        - "answer" — просто відповісти/побалакати, без дій над зміною.
        - "status" | "done" | "blocked" | "review" | "capacity" | "activity" — показати відповідний зріз стану (числа підставить застосунок; НЕ вигадуй їх).
        - "create_task" — користувач просить ЗРОБИТИ нову роботу (фікс/фічу/лендінг/дослідження). Перепиши прохання в чіткий однорядковий заголовок місії у полі "task_title"; у "target" вкажи проєкт — ДОГАДАЙСЯ з контексту/стану, не питай, якщо очевидно (спитай лише коли реально неоднозначно). Постав "visual":true, якщо це зміна ВИГЛЯДУ/UI (тема, колір, кнопка, екран, верстка) — тоді приймання вимагатиме before/after кадр. Застосунок покаже підтвердження перед запуском.
        - "look" — користувач ПИТАЄ про конкретний проєкт (як влаштовано, чи лишиться X, де живе Y). У "target" — проєкт. Застосунок подивиться проєкт (лише читання) і відповість з фактами.
        - "watch" — користувач питає, ЩО РОБЛЯТЬ воркери ЗАРАЗ у живих сесіях: на якому етапі, чи адекватно, чи в межах задачі, чи не зациклились/понесло, чи не застрягли. Це про ЖИВУ РОБОТУ, не про файли. У "target" — конкретний проєкт/воркер, або null = всі живі. Застосунок сам зазирне в сесії та оцінить.
        - "run_queue" — запустити чергу.
        - "stop_all" — зупинити всіх воркерів.
        - "dispatch_ready" — розподілити всі готові задачі за пріоритетом.
        - "approve" — прийняти роботу з ревʼю (merge/PR виконає застосунок). Обовʼязково "target" — назва задачі або проєкту.
        - "relay" — переслати слова користувача у сесію конкретного воркера (правки, фідбек, «переробіть X»). Обовʼязково "target".
        - "clarify" — перепитати, коли незрозуміло або бракує підтвердження.

        ПРАВИЛА:
        - Консеквентні дії (run_queue, stop_all, dispatch_ready, approve) обирай ЛИШЕ якщо користувач ЯВНО і однозначно цього просить у цьому повідомленні (або щойно підтвердив у розмові вище). За найменшого сумніву — "clarify" з коротким уточненням.
        - "relay" — коли повідомлення явно адресоване РОБОТІ воркера (правка/фідбек/дороблення), а не тобі. У "target" вкажи проєкт/задачу.
        - Якщо повідомлення просить ЩОСЬ ЗРОБИТИ (виправити, додати, реалізувати, померджити, зробити фічу) — це "create_task", НАВІТЬ якщо воно починається з «глянь»/«подивись» або містить довгий опис чи вставлений лист. "look" — лише коли користувач нічого не просить зробити, а тільки питає про проєкт.
        - Розрізняй "watch" / "look" / status: «що зараз роблять воркери / на якому етапі / чи не понесло / глянь що там у canvas зараз» → "watch" (жива робота); «як влаштований проєкт / де код X» → "look" (файли); «що зроблено / що на ревʼю / скільки в черзі» → відповідний status-зріз.
        - Якщо користувач просить кілька справ за раз — це все одно "create_task": застосунок САМ складе план і покаже його на підтвердження. Кілька справ в ОДНОМУ ресурсі стають ОДНОЮ роботою з кроками по черзі й ОДНИМ звітом — не обіцяй «окремі задачі», «кілька задач» чи «список задач». У "reply" одним реченням підтверди, що берешся; план покаже застосунок.
        - Ніколи не вигадуй стан і не приписуй користувачу того, чого він не казав.
        - "reply" — коротко, по-людськи, мовою користувача (як він пише — укр/рос).
        - Якщо це запитання чи балачка — "answer" (або відповідний status-зріз, якщо він питає про стан).

        Формат (рівно один рядок):
        {"action":"<action>","target":"<назва задачі/проєкту або null>","task_title":"<для create_task: однорядкова місія, інакше null>","visual":<true|false — лише для create_task зі зміною вигляду>,"reply":"<коротка відповідь>"}

        === СТАН ЗМІНИ (реальний) ===
        \(stateBlock(model))

        === ПАМʼЯТЬ ПРО ПРОДУКТ (реальна, довготривала) ===
        \(productBlock(model))

        === ОСТАННІ РЕПЛІКИ ЦЬОГО ПРОДУКТУ (найновіші внизу) ===
        \(transcript(model, last: 10))

        === НОВЕ ПОВІДОМЛЕННЯ ДИРЕКТОРА ===
        \(message)
        """
    }

    private static func stateBlock(_ model: AppModel) -> String {
        var lines: [String] = []
        let active = model.activeInstances
        lines.append("Активні воркери (\(active.count)): " +
            (active.isEmpty ? "нема" : active.map { "\($0.projectName) [\($0.phase.label)]" }.joined(separator: ", ")))
        lines.append("Черга: \(model.queue.pendingCount) в очікуванні, \(model.queue.runnerAlive ? "запущена" : "не запущена")")
        let rr = model.backlog.reviewReady
        lines.append("На ревʼю (\(rr.count)): " + (rr.isEmpty ? "нема" : rr.prefix(8).map { $0.title }.joined(separator: " | ")))
        lines.append("Потребують рішення: \(model.queue.needsUser.count)")
        let ready = model.backlog.readyToDispatch
        lines.append("Готові до запуску (\(ready.count)): " + (ready.isEmpty ? "нема" : ready.prefix(8).map { $0.title }.joined(separator: " | ")))
        return lines.joined(separator: "\n")
    }

    private static func transcript(_ model: AppModel, last: Int) -> String {
        guard let productID = model.conversationTarget ?? model.selectedProductID else {
            return "(порожньо)"
        }
        let spoken = model.conversations.all(for: productID).filter(\.isSpoken).suffix(last)
        guard !spoken.isEmpty else { return "(порожньо)" }
        return spoken
            .map { ($0.kind == .user ? "Користувач" : "Бригадир") + ": " + $0.text }
            .joined(separator: "\n")
    }

    private static func productBlock(_ model: AppModel) -> String {
        guard let product = model.products.product(id: model.conversationTarget)
                ?? model.selectedProduct else { return "" }

        var lines: [String] = ["ПРОДУКТ: \(product.name)"]
        if !product.summary.isEmpty { lines.append("Коротко: \(product.summary)") }
        if !product.brief.isEmpty { lines.append("Про продукт: \(product.brief)") }

        let resources = model.resources(for: product)
        if !resources.isEmpty {
            lines.append("Ресурси:")
            for item in resources {
                let access = item.resource.access == .source
                    ? "ТІЛЬКИ ЧИТАННЯ — не змінювати, про потрібну зміну повідомити"
                    : "можна змінювати"
                let path = item.project?.displayPath ?? item.resource.urlString ?? "—"
                lines.append("  • \(item.resource.name) [\(access)] \(path)")
            }
        }

        let open = model.openTasks(for: product.id)
        if !open.isEmpty {
            lines.append("Задачі в роботі по цьому продукту:")
            for task in open.prefix(6) {
                let state = WorkProgress.state(task: task, instance: model.liveInstance(for: task))
                lines.append("  • \(task.title) — \(state.rawValue)")
            }
        }

        let finished = model.history(for: product.id)
        if !finished.isEmpty {
            lines.append("Нещодавно завершено:")
            for item in finished.prefix(5) {
                lines.append("  • \(item.title) (\(item.dayLabel))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Parse

    nonisolated static func parse(_ raw: String) -> ForemanIntent? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        let json = String(s[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let actionRaw = (obj["action"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let action = ForemanIntent.Action(rawValue: actionRaw) ?? .unknown
        guard action != .unknown else { return nil }
        let target = (obj["target"] as? String).flatMap {
            let v = $0.trimmingCharacters(in: .whitespaces)
            return (v.isEmpty || v.lowercased() == "null") ? nil : v
        }
        let reply = (obj["reply"] as? String) ?? ""
        let taskTitle = (obj["task_title"] as? String).flatMap {
            let v = $0.trimmingCharacters(in: .whitespaces); return v.isEmpty || v.lowercased() == "null" ? nil : v
        }
        let visual = (obj["visual"] as? Bool) ?? false
        return ForemanIntent(action: action, target: target, reply: reply, taskTitle: taskTitle, visual: visual)
    }
}
