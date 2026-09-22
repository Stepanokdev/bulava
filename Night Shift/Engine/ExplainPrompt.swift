import Foundation
import CryptoKit

// MARK: - The material

/// Everything an explanation is allowed to be written from, and nothing else.
///
/// Assembled from what the app already has on screen, because the point of the action is to
/// explain THIS result — not to send a fresh agent to go and look. The prose alone is not enough:
/// it is the text he has already read and did not understand. What was missing from it is the
/// work — which files were edited, which commands were run, what came back — and that is what
/// `steps` carries.
nonisolated struct ExplainContext: Equatable, Sendable {

    /// One line naming what kind of result this is. Never localised: it goes into a prompt, not
    /// onto the screen, and a prompt that changes with the interface language cannot be tested.
    var headline: String

    /// The prose the reader has already seen.
    var prose: String

    /// What the worker actually did, in order — "edits AppSettings.swift", "runs ./night-verify.sh".
    var steps: [String]

    /// Another engine's answer inside this turn, when there was one.
    var consults: [String]

    /// What went wrong, in the material's own words.
    var problems: [String]

    /// Steps the budget dropped. Said out loud in the prompt, so the explanation can never claim
    /// the list it was given is the whole of the work.
    var omittedSteps: Int = 0

    /// The prose was longer than the budget and has a hole in the middle.
    var elidedProse: Bool = false

    /// Whether there is anything here worth paying for. An entry with a heading and no work
    /// behind it would produce "some changes were made", which is worse than no button.
    var hasMaterial: Bool {
        !prose.isEmpty || !steps.isEmpty || !problems.isEmpty || !consults.isEmpty
    }

    // MARK: Budget

    /// Characters of prose. A long night turn runs to tens of thousands and would neither fit nor
    /// finish inside the timeout.
    static let proseBudget = 6_000
    static let stepLimit = 60
    static let stepWidth = 140
    static let consultLimit = 3
    static let consultWidth = 600
    static let problemLimit = 6
    static let problemWidth = 400

    /// The digest of this material. Used to notice that the record changed under a cached
    /// explanation; see `Explanation.fingerprint`.
    var digest: String {
        var hasher = SHA256()
        for part in [headline, prose, steps.joined(separator: "\n"),
                     consults.joined(separator: "\n"), problems.joined(separator: "\n"),
                     "\(omittedSteps)", "\(elidedProse)"] {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0x1e]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Assembling it

nonisolated extension ExplainContext {

    /// A finished turn in a conversation.
    static func forTurn(_ entry: ConversationEntry, headline: String = "One answer in a conversation with Bulava.") -> ExplainContext {
        var prose = entry.blocks
            .filter { $0.kind == .markdown }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        if prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { prose = entry.text }

        let (clipped, elided) = fit(prose: prose)
        let (steps, dropped) = fit(steps: entry.blocks
            .filter { $0.kind == .activity }
            .compactMap { $0.activity }
            .map(line(for:)))

        let consults = entry.blocks.filter { $0.kind == .consult }.prefix(consultLimit).map { block in
            let agent = block.activity?.object ?? "another engine"
            let ask = clamp(block.activity?.detail ?? "", to: 200)
            let answer = clamp(block.text, to: consultWidth)
            return "\(agent) was asked: \(ask.isEmpty ? "—" : ask)\n\(agent) answered: \(answer.isEmpty ? "—" : answer)"
        }

        let problems = entry.blocks.filter { $0.kind == .error }
            .map { clamp($0.text, to: problemWidth) }
            .filter { !$0.isEmpty }
            .prefix(problemLimit)

        return ExplainContext(headline: headline, prose: clipped, steps: steps,
                              consults: Array(consults), problems: Array(problems),
                              omittedSteps: dropped, elidedProse: elided)
    }

    /// A night-shift task: its own state, what it said when it stopped, its report, and the trail
    /// of turns that produced it.
    ///
    /// `stateLabel` is `WorkState.labelKey` — the English source string, deliberately, for the
    /// same reason `headline` is.
    static func forTask(title: String, stateLabel: String, outcome: String?,
                        manifest: ReportManifest?, turns: [ConversationEntry]) -> ExplainContext {
        // The title and the state are IDENTITY, and they belong in the headline rather than in
        // the material. A task always has both, so counting them as material would make every
        // run explainable — including one that produced nothing readable, where the only possible
        // answer is "some work was done", which is worse than no button at all.
        let headline = "A night-shift task Bulava ran on its own: «\(clamp(title, to: 200))»."
            + " Where it ended up: \(stateLabel)."
        var lines: [String] = []
        if let outcome = outcome.map({ clamp($0, to: 600) }), !outcome.isEmpty {
            lines.append("What it said when it finished: \(outcome)")
        }
        if let manifest {
            if let summary = manifest.summary.map({ clamp($0, to: 800) }), !summary.isEmpty {
                lines.append("Report summary: \(summary)")
            }
            for section in (manifest.sections ?? []).prefix(12) {
                let name = clamp(section.title ?? section.ref ?? "—", to: 160)
                lines.append("Report section «\(name)» — \(englishStatus(section.status))")
                if let body = section.body.map({ clamp($0, to: 700) }), !body.isEmpty {
                    lines.append(body)
                }
            }
            for item in (manifest.attention ?? []).prefix(6) {
                let text = clamp(item, to: 300)
                if !text.isEmpty { lines.append("Flagged for attention: \(text)") }
            }
            if let body = manifest.body.map({ clamp($0, to: 1_500) }), !body.isEmpty {
                lines.append(body)
            }
        }

        let (prose, elided) = fit(prose: lines.joined(separator: "\n"))
        let (steps, dropped) = fit(steps: turns
            .flatMap(\.blocks)
            .filter { $0.kind == .activity }
            .compactMap { $0.activity }
            .map(line(for:)))
        let problems = turns.flatMap(\.blocks).filter { $0.kind == .error }
            .map { clamp($0.text, to: problemWidth) }
            .filter { !$0.isEmpty }
            .prefix(problemLimit)

        return ExplainContext(headline: headline,
                              prose: prose, steps: steps, consults: [],
                              problems: Array(problems),
                              omittedSteps: dropped, elidedProse: elided)
    }

    // MARK: Pieces

    /// One step, as a sentence.
    ///
    /// `verbKey` is an English format string — "reads %@", "edits %@", "working" — and it is used
    /// here unlocalised on purpose: this is prompt material, and the same result must produce the
    /// same prompt whatever the app is displayed in.
    static func line(for activity: BlockActivity) -> String {
        let object = clamp(activity.object ?? "", to: stepWidth)
        var text: String
        if activity.verbKey.contains("%@") {
            text = activity.verbKey.replacingOccurrences(of: "%@", with: object.isEmpty ? "—" : object)
        } else if object.isEmpty {
            text = activity.verbKey
        } else {
            text = activity.verbKey + " — " + object
        }
        if activity.status == .failed { text += " (it failed)" }
        return text
    }

    /// Identical lines collapse — twenty "reads Theme.swift" in a row tell the reader nothing
    /// the first one did not — and then the list is cut to the budget, in order.
    static func fit(steps raw: [String]) -> (kept: [String], dropped: Int) {
        var seen = Set<String>()
        var unique: [String] = []
        for step in raw where !step.isEmpty && seen.insert(step).inserted { unique.append(step) }
        guard unique.count > stepLimit else { return (unique, 0) }
        return (Array(unique.prefix(stepLimit)), unique.count - stepLimit)
    }

    /// Over budget, the middle goes. The head says what the turn set out to do and the tail says
    /// how it ended; the part that can be spared is between them. Deterministic, so the same turn
    /// always produces the same prompt.
    static func fit(prose raw: String) -> (text: String, elided: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > proseBudget else { return (text, false) }
        let head = proseBudget * 2 / 5
        let tail = proseBudget - head
        return (String(text.prefix(head))
                + "\n\n[…the middle of this answer was left out to keep the request small…]\n\n"
                + String(text.suffix(tail)), true)
    }

    static func clamp(_ raw: String, to limit: Int) -> String {
        let flat = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    private static func englishStatus(_ status: ReportManifest.Section.Status) -> String {
        switch status {
        case .closed:         "closed"
        case .partial:        "only partly done"
        case .notClosed:      "not done"
        case .blocked:        "blocked"
        case .notApplicable:  "not applicable"
        case .unknown:        "no verdict"
        }
    }
}

// MARK: - The request

nonisolated enum ExplainPrompt {

    /// Bumped whenever the wording below changes in a way that would produce a different answer.
    /// It is part of the fingerprint, so an explanation written by an older prompt is shown as out
    /// of date rather than silently kept forever.
    static let version = 1

    /// The whole request, including the material. One string, handed to `claude -p --tools ''`.
    static func build(context: ExplainContext, profile rawProfile: String,
                      languageName: String, depth: ExplainDepth) -> String {
        let profile = LearningProfile.normalized(rawProfile)

        var sections: [String] = []
        sections.append("""
        Somebody has just had a piece of work done for them by Bulava, and wants to understand \
        what happened. You are writing that explanation. You are not doing any work, not \
        reviewing it, and not suggesting improvements.

        \(context.headline)
        """)

        sections.append(profile.isEmpty
            ? """
              About the reader: nothing is known. Write for somebody who is not a specialist in \
              this technology — plain words, no unexplained jargon, and spell out any term you \
              cannot avoid. Do not assume they can read code.
              """
            : """
              About the reader, in their own words: «\(profile)»

              Explain it THROUGH that. Where something here is unfamiliar to them, say what it \
              corresponds to in what they already know, and name the correspondence out loud. \
              Never assume they know the technology in front of them just because they know \
              another one.
              """)

        sections.append("Write the answer in \(languageName).")
        sections.append(instructions(for: depth))
        sections.append(material(context))
        sections.append("""
        Rules:
        - Use only the material above. It is everything that is known. Where something is not \
        there, say that it is not visible rather than filling the gap.
        - Name the real files, commands and tools from the step list. That is precisely what the \
        reader could not read for themselves.
        - Do not call the work finished unless the material says so. If it stopped, was only \
        partly done, or failed, say which and say why.
        - No preamble, no compliments on the question, no sign-off. Begin with the first heading.
        - Plain markdown: short headings, short paragraphs, no code fences unless you are quoting \
        something from above.
        """)

        return sections.joined(separator: "\n\n")
    }

    private static func instructions(for depth: ExplainDepth) -> String {
        switch depth {
        case .brief:
            return """
            Answer in exactly three sections, in this order, each under its own heading:
            1. What was done — two to four sentences.
            2. Why it was done this way — two to four sentences.
            3. What to check — two to four bullets the reader can actually act on.
            Under 250 words in total. This is the first thing they read, so it has to answer \
            "what happened" before it teaches anything.
            """
        case .stepByStep:
            return """
            Go through it in order. For each meaningful step: what was changed, what it was for, \
            and what the technology involved actually is. Group the steps that belong together \
            rather than restating the list line by line. Finish with one short section, "Worth \
            knowing next time", of two or three bullets. Under 700 words.
            """
        }
    }

    private static func material(_ context: ExplainContext) -> String {
        var out = ["Here is the result, exactly as the app holds it.", "", "## What it said", "",
                   context.prose.isEmpty ? "(it wrote nothing — the work is all in the steps below)"
                                         : context.prose]
        if !context.steps.isEmpty {
            out += ["", "## What it actually did", ""]
            out += context.steps.map { "- " + $0 }
            if context.omittedSteps > 0 {
                out.append("- (and \(context.omittedSteps) further steps, not listed here — do not "
                           + "claim this list is the whole of the work)")
            }
        }
        if !context.consults.isEmpty {
            out += ["", "## What another engine was asked", ""]
            out += context.consults
        }
        if !context.problems.isEmpty {
            out += ["", "## What went wrong", ""]
            out += context.problems.map { "- " + $0 }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Fingerprint

    /// What produced an explanation: the material, plus every part of the request that changes the
    /// answer. The profile is in here, so the generic explanation is not handed back to somebody
    /// who has since written down who they are.
    static func fingerprint(context: ExplainContext, profile: String,
                            languageName: String, depth: ExplainDepth) -> String {
        var hasher = SHA256()
        for part in [context.digest, LearningProfile.normalized(profile), languageName,
                     depth.rawValue, "v\(version)"] {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0x1e]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Language

    /// The language the explanation is written in: the one the app is displayed in.
    ///
    /// `AppLanguage.reportLanguageName` answers "English" for `.system`, which is right for a
    /// report and wrong here — a Ukrainian Mac running Bulava on System shows a Ukrainian
    /// interface and would have got an English explanation inside it. `displayedCode` is
    /// `LanguageBundle.currentCode`: the localisation that actually loaded.
    static func languageName(interface: AppLanguage, displayedCode: String) -> String {
        guard interface == .system else { return interface.reportLanguageName }
        let base = String(displayedCode.prefix(2)).lowercased()
        return AppLanguage(rawValue: base)?.reportLanguageName ?? "English"
    }
}
