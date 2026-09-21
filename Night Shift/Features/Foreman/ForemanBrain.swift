import Foundation

@MainActor
enum ForemanBrain {

    struct Reply { var text: String; var ranAction: Bool; var silent: Bool = false; var link: AppLink? = nil }

    static func respond(to raw: String, model: AppModel) -> Reply? {
        let t = raw.lowercased()

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 60 || trimmed.contains("\n") { return nil }

        if (t.contains("воркер") || t.contains("сесі") || t.contains("наглян"))
            && match(t, ["роблять", "робить", "роблят", "етап", "застрягл", "зацикл", "наглян", "як там", "чим займа"]) {
            return nil
        }

        if match(t, ["what got done", "whats done", "what's done", "що зроблено", "что сделано", "за ніч", "за ночь", "результат"]) {
            return Reply(text: doneSummary(model), ranAction: false)
        }
        if match(t, ["blocked", "blocker", "заблок", "чому сто", "почему сто", "застряг", "проблем"]) {
            return Reply(text: blockedSummary(model), ranAction: false)
        }
        if match(t, ["review", "ревʼю", "ревью", "на рев", "що прийма", "что принима"]) {
            return Reply(text: reviewSummary(model), ranAction: false)
        }
        if match(t, ["capacity", "limit", "usage", "ліміт", "лимит", "квота"]) {
            return Reply(text: capacitySummary(model), ranAction: false)
        }
        if match(t, ["status", "what's happening", "whats happening", "що зараз", "что сейчас", "стан", "як справи", "как дела"]) {
            return Reply(text: statusSummary(model), ranAction: false)
        }
        if match(t, ["що нового", "что нового", "що сталося", "что случилось", "історія", "history",
                     "активність", "журнал", "timeline", "останні події", "recent"]) {
            return Reply(text: activitySummary(model), ranAction: false)
        }

        if asksForProductReport(raw), let productID = model.conversationTarget {
            model.openProductReport(productID: productID)
            return Reply(text: String(localized: "Collecting everything this product has been through — opening it now."),
                         ranAction: true)
        }
        if match(t, ["help", "команди", "что умеешь", "що вмієш", "хелп"]) {
            return Reply(text: helpText, ranAction: false)
        }
        return nil
    }

    static func activitySummary(_ model: AppModel) -> String {
        let recent = model.events.recent(10)
        guard !recent.isEmpty else { return "Журнал поки порожній — жодних подій за зміну." }
        var lines = ["Останнє в журналі зміни:"]
        for e in recent { lines.append("• \(Fmt.clock(e.at)) — \(e.title)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Summaries

    static func statusSummary(_ model: AppModel) -> String {
        let active = model.activeInstances
        let finalizing = model.backlog.tasks.filter { $0.state == .finalizing }
        var lines: [String] = []
        if !active.isEmpty {
            lines.append("Працює \(active.count):")
            for i in active.prefix(6) {
                let up = i.startedAt.map { Fmt.elapsed(Date().timeIntervalSince($0)) } ?? "—"
                lines.append("• \(i.projectName) — \(i.phase.humanLabel), \(up)")
            }
        }
        if !finalizing.isEmpty {
            lines.append("Фіналізується (мерджу): " + finalizing.prefix(4).map { $0.title }.joined(separator: ", "))
        }
        if active.isEmpty && finalizing.isEmpty {
            lines.append("Зараз ніхто не працює.")
        }
        if model.queue.runnerAlive {
            lines.append("Черга активна, ще \(model.queue.pendingCount) в очікуванні.")
        } else if model.queue.pendingCount > 0 {
            lines.append("У черзі \(model.queue.pendingCount), але вона не запущена — скажи «запусти чергу».")
        }
        if model.backlog.reviewReadyCount > 0 {
            lines.append("На ревʼю \(model.backlog.reviewReadyCount) — скажи «прийми <назва>», щоб змерджити.")
        }
        lines.append(capacityLine(model))
        return lines.joined(separator: "\n")
    }

    static func doneSummary(_ model: AppModel) -> String {
        let done = model.completions.filter { $0.outcome.isSuccess }
        if done.isEmpty && model.completedToday == 0 {
            return "За добу ще нічого не прийнято. \(model.activeInstances.isEmpty ? "І зараз ніхто не працює." : "Але \(model.activeInstances.count) в роботі.")"
        }
        var lines = ["За останню добу завершено \(model.completedToday):"]
        for d in done.prefix(8) { lines.append("• \(d.projectName) — \(firstLine(d.detail))") }
        if model.backlog.reviewReadyCount > 0 { lines.append("\(model.backlog.reviewReadyCount) чекає на твоє ревʼю.") }
        return lines.joined(separator: "\n")
    }

    nonisolated static func numberedAnswer(_ raw: String) -> (Int, String)? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = try? NSRegularExpression(pattern: #"^(\d{1,2})\s*[:.\)\-–]\s*(.+)$"#,
                                              options: [.dotMatchesLineSeparators]),
              let hit = m.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let numRange = Range(hit.range(at: 1), in: t),
              let bodyRange = Range(hit.range(at: 2), in: t),
              let n = Int(t[numRange]) else { return nil }
        let body = String(t[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : (n, body)
    }

    nonisolated static func asksForProductReport(_ raw: String) -> Bool {
        let t = raw.lowercased()
        guard t.contains("звіт") || t.contains("отчёт") || t.contains("отчет") || t.contains("report") else {
            return false
        }
        let whole = ["по всій", "по всьому", "по всей", "по всему", "усій робот", "всій робот",
                     "всю робот", "всієї робот", "всей работ", "всю работ", "по проєкт", "по проекту",
                     "по продукт", "загальний", "общий", "повний звіт", "полный отчёт", "полный отчет",
                     "everything", "whole", "overall", "all the work"]
        return whole.contains { t.contains($0) }
    }

    nonisolated static func asksForDecisions(_ raw: String) -> Bool {
        let t = raw.lowercased()
        let needles = ["яке рішення", "які рішення", "яких рішень", "рішення від мене", "рішення потрібн",
                       "какое решение", "какие решения", "решение от меня", "решения от меня",
                       "що від мене", "чого від мене", "что от меня", "чего от меня",
                       "чого ти чекаєш", "чого чекаєш", "чего ждёшь", "чего ждешь",
                       "що мені зробити", "что мне сделать", "потрібна моя відповідь",
                       "needs you", "what do you need from me", "what decisions"]
        return needles.contains { t.contains($0) }
    }

    static func decisionsSummary(_ model: AppModel, decisions: [AppModel.PendingDecision]) -> String {
        guard !decisions.isEmpty else {
            return "Наразі від тебе нічого не потрібно — усе або в роботі, або чекає твого ревʼю."
        }
        var lines = ["Від тебе чекають \(decisions.count) рішень:"]
        for (i, d) in decisions.enumerated() {
            lines.append("")
            lines.append("\(i + 1). «\(d.title)»" + (d.productName.isEmpty ? "" : " · \(d.productName)"))
            if d.needs.isEmpty {
                lines.append("   Воркер зупинився й не написав, чого потребує — це вже наш баг. Відкрий «Деталі», там лог сесії.")
            } else {
                for need in d.needs.prefix(2) {
                    lines.append("   • " + String(need.prefix(600)))
                }
            }
        }
        lines.append("")
        lines.append("Відповідай із номером — напр. «1: дозволяю писати в бекенд аналітики» — і я передам це саме в той потік і запущу його далі.")
        return lines.joined(separator: "\n")
    }

    static func blockedSummary(_ model: AppModel) -> String {
        let parked = model.queue.needsUser
        let heldTasks = model.backlog.blockedByDeps
        if parked.isEmpty && heldTasks.isEmpty && model.blockedCount == 0 {
            return "Нічого не заблоковано. Все або в роботі, або чекає ревʼю."
        }
        var lines: [String] = []
        if !parked.isEmpty {
            lines.append("Потребують тебе (\(parked.count)):")
            for p in parked.prefix(6) { lines.append("• \(p.projectName) — \(p.outcome.label): \(firstLine(p.task))") }
            lines.append("Відкрий Decisions, щоб повернути в роботу або розрулити.")
        }
        if !heldTasks.isEmpty {
            lines.append("Тримаю до розблокування (\(heldTasks.count)):")
            for t in heldTasks.prefix(6) {
                lines.append("• \(t.title) — \(model.backlog.blockReason(t) ?? "заблоковано")")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func reviewSummary(_ model: AppModel) -> String {
        let n = model.backlog.reviewReadyCount
        if n == 0 { return "На ревʼю нічого. Порожньо." }
        var lines = ["На ревʼю \(n):"]
        for t in model.backlog.reviewReady.prefix(8) { lines.append("• \(t.title)") }
        lines.append("Відкрий Review — там діф, тести й нотатки аудитора.")
        return lines.joined(separator: "\n")
    }

    static func capacitySummary(_ model: AppModel) -> String {
        capacityLine(model) + "\n" + (model.nightModeActive ? "Нічна зміна активна." : "Нічна зміна не запущена.")
    }

    private static func capacityLine(_ model: AppModel) -> String {
        let c = model.capacity
        func fmt(_ u: UsageSnapshot) -> String {
            guard u.present else { return "—" }
            let p = Int(u.fiveHour.usedPercent.rounded())
            return "\(p)%\(Fmt.resetsIn(u.fiveHour.resetsAt).map { " (\($0))" } ?? "")"
        }
        return "Ліміти: Claude \(fmt(c.claude)), Codex \(fmt(c.codex))."
    }

    static var helpText: String {
        """
        Питай як бригадира:
        • «що зараз?» — хто працює, стан черги, ліміти
        • «що зроблено?» — результати за добу
        • «що заблоковано?» — що потребує тебе
        • «що на ревʼю?» — готове до приймання
        • «що нового?» — останні події зі зміни
        • «запусти чергу» / «зупини всіх» — керування зміною
        """
    }

    static func stateContext(_ model: AppModel) -> String {
        """
        Поточний стан нічної зміни:
        - Активних воркерів: \(model.activeInstances.count) (\(model.activeInstances.map { $0.projectName }.joined(separator: ", ")))
        - У черзі: \(model.queue.pendingCount), черга \(model.queue.runnerAlive ? "запущена" : "не запущена")
        - На ревʼю: \(model.backlog.reviewReadyCount)
        - Потребують рішення: \(model.queue.needsUser.count)
        - \(capacityLine(model))
        """
    }

    private static func match(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
    private static func firstLine(_ s: String) -> String {
        let l = s.split(separator: "\n").first.map(String.init) ?? s
        return l.count > 70 ? String(l.prefix(70)) + "…" : l
    }
}
