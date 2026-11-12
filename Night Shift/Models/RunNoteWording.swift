import Foundation

/// The engine writes the notes of `run-events.jsonl` in Ukrainian, for its log. The run view is the
/// interface, and the interface speaks the person's language: a step skipped because the message
/// continues an open task reads «Continuing an open task» in English, not «Продовження відкритої
/// задачі».
///
/// The journal keeps the engine's words — the event log shows them as they were written — and old
/// runs on disk have no other wording, so this reads the note itself: every sentence the engine
/// writes from a fixed template is recognised here and said again in the interface language. What
/// was put INTO a template — a model's reason, a reviewer's sentence, a tool's error, a step's
/// name — is carried over exactly as written. A note that matches no template is shown as it is:
/// it is somebody's own text (the worker's summary, a reason passed through), never guessed at.
nonisolated enum RunNoteWording {

    /// `note` in the interface language when it is one of the engine's own sentences; the note
    /// unchanged otherwise. `bundle` is the localisation to speak; tests pass `uk`/`ru` ones.
    static func interfaceText(_ note: String, bundle: Bundle = .main) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return note }
        if let said = sentence(trimmed, bundle) { return said }
        // A verdict with Codex's participation after it: «<why> — <participation>».
        for prefix in Participation.openings.map(\.engine) {
            if let r = trimmed.range(of: " — " + prefix, options: .backwards) {
                let head = String(trimmed[..<r.lowerBound])
                let tail = String(trimmed[trimmed.index(r.lowerBound, offsetBy: 3)...])
                return interfaceText(head, bundle: bundle) + " — " + interfaceText(tail, bundle: bundle)
            }
        }
        return note
    }

    // MARK: - Templates

    /// Built once and only read after: a compiled pattern and a pure function of its groups.
    private struct Template: @unchecked Sendable {
        let regex: NSRegularExpression
        /// The captured groups in order; a group that did not take part is nil.
        let say: @Sendable ([String?], Bundle) -> String

        init(_ pattern: String, _ say: @escaping @Sendable ([String?], Bundle) -> String) {
            regex = try! NSRegularExpression(pattern: "^" + pattern + "$", options: [.dotMatchesLineSeparators])
            self.say = say
        }
    }

    private static func sentence(_ note: String, _ bundle: Bundle) -> String? {
        let whole = NSRange(note.startIndex..., in: note)
        for t in templates {
            guard let m = t.regex.firstMatch(in: note, range: whole) else { continue }
            let groups: [String?] = (1..<max(1, m.numberOfRanges)).map { i in
                Range(m.range(at: i), in: note).map { String(note[$0]) }
            }
            return t.say(groups, bundle)
        }
        return nil
    }

    /// Something the engine put into a sentence: itself one of its sentences sometimes
    /// («потрібне твоє рішення», a participation note), the person's or a model's words otherwise.
    private static func inner(_ s: String?, _ b: Bundle) -> String {
        guard let s else { return "" }
        return interfaceText(s, bundle: b)
    }

    /// «A», «B» → the same names, quoted the way the interface quotes.
    private static func names(_ s: String?, _ b: Bundle) -> String {
        let raw = (s ?? "").trimmingCharacters(in: .whitespaces)
        let quoted = raw.components(separatedBy: "»").compactMap { part -> String? in
            guard let open = part.range(of: "«") else { return nil }
            return String(part[open.upperBound...])
        }
        guard !quoted.isEmpty else { return raw }
        return quoted.map { String(localized: "“\($0)”", bundle: b) }.joined(separator: ", ")
    }

    /// Every sentence of the engine's that reaches a run's notes, most specific first. The pattern
    /// is the engine's own wording, so `RunNoteWordingTests` can hold the two together.
    private static let templates: [Template] = [
        // pipeline.sh
        Template("Пайплайн «(.+)» не знайдено") { g, b in String(localized: "Pipeline “\(g[0] ?? "")” not found", bundle: b) },
        Template("Опис пайплайна «(.+)» не проходить перевірку") { g, b in
            String(localized: "The description of pipeline “\(g[0] ?? "")” is not valid", bundle: b)
        },
        Template("Тріаж: не потрібен для цієї задачі — (.+)") { g, b in
            String(localized: "Triage: not needed for this task — \(g[0] ?? "")", bundle: b)
        },
        Template("Тріаж: не потрібен для цієї задачі") { _, b in String(localized: "Triage: not needed for this task", bundle: b) },
        Template("Повідомлення забрано") { _, b in String(localized: "Message withdrawn", bundle: b) },
        Template("Продовження відкритої задачі") { _, b in String(localized: "Continuing an open task", bundle: b) },
        Template("Обов'язковий крок (.+?) не вдався — повідомлення затримано, виконавець його не отримав") { g, b in
            String(localized: "Required step \(names(g[0], b)) failed — the message is held; the worker did not get it", bundle: b)
        },
        Template("Обов'язковий крок\\s*(.+?) не вдався") { g, b in
            String(localized: "Required step \(names(g[0], b)) failed", bundle: b)
        },
        Template("Підготовку завершено") { _, b in String(localized: "Preparation finished", bundle: b) },

        // pipeline-deliver.sh
        Template("Сесія підтвердила, що отримала бриф") { _, b in
            String(localized: "The session confirmed it received the brief", bundle: b)
        },
        Template("Бриф не дійшов — він у черзі повторної доставки") { _, b in
            String(localized: "The brief did not arrive — it is queued for redelivery", bundle: b)
        },

        // review-gate.sh: the gates
        Template("Виконавець зупинився — ворота перевіряють") { _, b in
            String(localized: "The worker stopped — the checks are running", bundle: b)
        },
        Template("Шматок (\\S+) «(.+?)» прийнято\\. Ти надіслав нову задачу — беруся за неї замість «(.+)»") { g, b in
            String(localized: "Piece \(g[0] ?? "") “\(g[1] ?? "")” accepted. You sent a new task — taking it on instead of “\(g[2] ?? "")”", bundle: b)
        },
        Template("Шматок (\\S+) «(.+?)» прийнято — далі «(.+)»") { g, b in
            String(localized: "Piece \(g[0] ?? "") “\(g[1] ?? "")” accepted — next: “\(g[2] ?? "")”", bundle: b)
        },
        Template("Прийнято") { _, b in String(localized: "Accepted", bundle: b) },
        Template("Прийнято із зауваженнями") { _, b in String(localized: "Accepted with notes", bundle: b) },
        Template("Прийнято рецензентом, але не все закомічено: (.+)") { g, b in
            String(localized: "Accepted by the reviewer, but not everything is committed: \(g[0] ?? "")", bundle: b)
        },
        Template("Рев'ю зупинилось — потрібне твоє рішення") { _, b in
            String(localized: "The review stopped — your decision is needed", bundle: b)
        },
        Template("потрібне твоє рішення") { _, b in String(localized: "your decision is needed", bundle: b) },
        Template("Передав агентові твоє уточнення — рев'ю після того, як він його врахує") { _, b in
            String(localized: "Passed your clarification to the agent — the review comes once it has taken it in", bundle: b)
        },
        Template("Агент чекає на своїх фонових помічників — перевірки почнуться після них") { _, b in
            String(localized: "The agent is waiting for its background helpers — the checks start after them", bundle: b)
        },
        Template("Нема ні змін, ні заявленого результату — попросив заявити") { _, b in
            String(localized: "No changes and no declared result — asked the agent to declare one", bundle: b)
        },
        Template("Вікно Claude вичерпано — продовжить, коли повернеться") { _, b in
            String(localized: "Claude's usage window is used up — work continues when it is back", bundle: b)
        },
        Template("Чекає на Codex — без нього роботу не прийнято") { _, b in
            String(localized: "Waiting for Codex — work is not accepted without it", bundle: b)
        },
        Template("Codex недоступний понад (.+?) год \\((.*)\\) — задачу зупинено без його ревʼю; робота лишилась у гілці\\.") { g, b in
            String(localized: "Codex has been unavailable for over \(g[0] ?? "") h (\(g[1] ?? "")) — the task was stopped without its review; the work stays on its branch.", bundle: b)
        },
        Template("Не можу перевірити: транскрипт сесії недоступний") { _, b in
            String(localized: "Cannot check: the session transcript is unavailable", bundle: b)
        },
        Template("Немає виклику: (.+) — потрібне твоє рішення") { g, b in
            String(localized: "Skill not called: \(g[0] ?? "") — your decision is needed", bundle: b)
        },
        Template("Немає виклику: (.+) — роботу повернуто") { g, b in
            String(localized: "Skill not called: \(g[0] ?? "") — work sent back", bundle: b)
        },
        Template("Скіл викликано: (.+)") { g, b in String(localized: "Skill called: \(g[0] ?? "")", bundle: b) },

        // review-gate.sh: the report review
        Template("Звіту не знайдено") { _, b in String(localized: "No report found", bundle: b) },
        Template("Звіту не знайдено — попросив назвати шлях") { _, b in
            String(localized: "No report found — asked for its path", bundle: b)
        },
        Template("Рецензент звіту недоступний — чекаю \\((.+)\\)") { g, b in
            String(localized: "The report reviewer is unavailable — waiting (\(g[0] ?? ""))", bundle: b)
        },
        Template("Рецензент звіту недоступний — чекаю") { _, b in
            String(localized: "The report reviewer is unavailable — waiting", bundle: b)
        },
        Template("Звіт повернуто · зауважень: (.+)") { g, b in
            String(localized: "Report sent back · findings: \(g[0] ?? "")", bundle: b)
        },
        Template("Агент зупинився, але роботу не здав \\((.+)\\) — повернув без перевірок") { g, b in
            String(localized: "The agent stopped without handing the work in (\(g[0] ?? "")) — sent back without checks", bundle: b)
        },

        // review-gate.sh: the build and the independent checks
        Template("Збірка й перевірки пройшли") { _, b in String(localized: "Build and checks passed", bundle: b) },
        Template("Збірка або перевірки не пройшли — рецензент це побачить") { _, b in
            String(localized: "Build or checks failed — the reviewer will see it", bundle: b)
        },
        Template("Перевірку збіркою вимкнено") { _, b in String(localized: "Build check is turned off", bundle: b) },
        Template("Нічого зібрати чи протестувати \\((.*)\\)") { g, b in
            String(localized: "Nothing to build or test (\(g[0] ?? ""))", bundle: b)
        },
        Template("Незалежні перевірки пропущено: збірка червона") { _, b in
            String(localized: "Independent checks skipped: the build is red", bundle: b)
        },
        Template("Незалежні перевірки вже були — їхні знахідки йдуть Codex") { _, b in
            String(localized: "Independent checks already ran — their findings go to Codex", bundle: b)
        },
        Template("Незалежні перевірки Claude: код і безпека") { _, b in
            String(localized: "Claude's independent checks: code and security", bundle: b)
        },
        Template("Незалежна перевірка не відпрацювала: (.+) — далі Codex") { g, b in
            String(localized: "An independent check did not finish: \(g[0] ?? "") — Codex is next", bundle: b)
        },
        Template("Незалежна перевірка не відпрацювала: (.+)") { g, b in
            String(localized: "An independent check did not finish: \(g[0] ?? "")", bundle: b)
        },
        Template("Незалежні перевірки знайшли (.+) — повернуто виконавцю") { g, b in
            String(localized: "Independent checks found \(g[0] ?? "") — sent back to the worker", bundle: b)
        },
        Template("Незалежним перевіркам нічого перевіряти: diff порожній") { _, b in
            String(localized: "Nothing for the independent checks to check: the diff is empty", bundle: b)
        },
        Template("Незалежні перевірки: нічого, що треба повертати") { _, b in
            String(localized: "Independent checks: nothing that needs sending back", bundle: b)
        },

        // review-gate.sh: the review
        Template("Рецензент недоступний — (.+)") { g, b in
            String(localized: "The reviewer is unavailable — \(g[0] ?? "")", bundle: b)
        },
        Template("Віддав хід — попросив працювати далі") { _, b in
            String(localized: "The agent handed the turn back — asked it to keep working", bundle: b)
        },
        Template("Повернуто на виправлення") { _, b in String(localized: "Sent back for fixes", bundle: b) },
        Template("Повернуто на доопрацювання · зауважень: (.+)") { g, b in
            String(localized: "Sent back for more work · findings: \(g[0] ?? "")", bundle: b)
        },
        Template("Без git і без коду — перевіряти нічого, лишається те, що прогін заявив") { _, b in
            String(localized: "No git and no code — nothing to check; what the run declared stands", bundle: b)
        },
        Template("Codex зупинив рев'ю: (.+)") { g, b in
            String(localized: "Codex stopped the review: \(inner(g[0], b))", bundle: b)
        },
        Template("Виконавець кілька разів поспіль віддав хід — потрібне твоє рішення") { _, b in
            String(localized: "The worker handed the turn back several times in a row — your decision is needed", bundle: b)
        },
        Template("Робота прийнята із зауваженням: перевірку зупинив сам інструмент перевірки, а не робота — (.*)") { g, b in
            String(localized: "Work accepted with a note: the checking tool itself stopped the check, not the work — \(g[0] ?? "")", bundle: b)
        },
        Template("Перевірка (\\S+) рази поспіль упиралась у сам інструмент перевірки, а не в роботу: (.*)") { g, b in
            String(localized: "The check ran into the checking tool itself, not the work, \(g[0] ?? "") times in a row: \(g[1] ?? "")", bundle: b)
        },
        // The reviewer's CLI refusing the call: who, the code, then the CLI's cause and the log when
        // there were any.
        Template("(.+?) не запустився: CLI відхилив сам виклик \\(код (.+?)\\)(?: — (.+?))?\\. Це не недоступність рецензента, очікування цього не виправить — потрібне оновлення CLI або рушія\\.(?: Повний лог: (.+))?") { g, b in
            var s = String(localized: "\(g[0] ?? "") did not start: the CLI refused the call itself (code \(g[1] ?? ""))", bundle: b)
            if let cause = g[2] { s += " — " + cause }
            s += ". " + String(localized: "The reviewer is not away, and waiting will not fix this — the CLI or the engine needs an update.", bundle: b)
            if let log = g[3] { s += " " + String(localized: "Full log: \(log)", bundle: b) }
            return s
        },

        // supervisor-lib.sh: which steps went without Codex
        Template("(Фінальне ревʼю не проводилось\\. |Фінальне ревʼю виконав Claude замість Codex\\. |Codex брав участь не в усьому\\. )Без Codex: (.+)") { g, b in
            Participation.say(opening: g[0] ?? "", gaps: g[1] ?? "", b)
        },
    ]

    // MARK: - Codex's participation

    /// `codex_participation_note`: an opening sentence, then «Без Codex: » and the steps it missed,
    /// each «stage[ ×n][ — reason]», joined by «; », with «; і ще N» past the fourth.
    private enum Participation {
        static let openings: [(engine: String, say: @Sendable (Bundle) -> String)] = [
            ("Фінальне ревʼю не проводилось. ", { String(localized: "The final review did not take place.", bundle: $0) }),
            ("Фінальне ревʼю виконав Claude замість Codex. ", { String(localized: "Claude did the final review instead of Codex.", bundle: $0) }),
            ("Codex брав участь не в усьому. ", { String(localized: "Codex did not take part in everything.", bundle: $0) }),
        ]

        static let stages: [(engine: String, say: @Sendable (Bundle) -> String)] = [
            ("підготовка", { String(localized: "preparation", bundle: $0) }),
            ("звірка позицій", { String(localized: "aligning the positions", bundle: $0) }),
            ("консультація", { String(localized: "consultation", bundle: $0) }),
            ("частина Codex", { String(localized: "Codex's part", bundle: $0) }),
            ("питання воркера", { String(localized: "the worker's question", bundle: $0) }),
            ("фінальне ревʼю", { String(localized: "final review", bundle: $0) }),
        ]

        static func say(opening: String, gaps: String, _ b: Bundle) -> String {
            let first = openings.first { $0.engine == opening }.map { $0.say(b) } ?? opening
            let items = gaps.components(separatedBy: "; ").map { item -> String in
                if item.hasPrefix("і ще "), let n = Int(item.dropFirst("і ще ".count)) {
                    return String(localized: "and \(n) more", bundle: b)
                }
                // The stage's name is the engine's; what follows it — a count, a reason — is not.
                for stage in stages where item == stage.engine || item.hasPrefix(stage.engine + " ") {
                    return stage.say(b) + item.dropFirst(stage.engine.count)
                }
                return item
            }
            return first + " " + String(localized: "Without Codex: \(items.joined(separator: "; "))", bundle: b)
        }
    }
}
