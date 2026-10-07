import SwiftUI

/// The decisions a report asks for, beside the report, drawn by Bulava itself.
///
/// The report's page cannot reach these controls: they are not in it. What is ticked is kept as a
/// draft while he reads; "Send" shows exactly what will go into which chat, and only his press there
/// makes it his message (`DecisionCenter.submit`).
struct DecisionPanel: View {
    @Environment(AppModel.self) private var model
    let report: URL

    @State private var set: DecisionSet?
    @State private var answers = DecisionAnswers()
    @State private var openComments: Set<String> = []
    @State private var confirming = false
    @State private var problem: DecisionRefusal?
    @State private var loadedFor: String?
    /// Which answer he had in front of him: his own corrects that one, never one he has not seen.
    @State private var review = DecisionReview()

    private var record: DecisionAnswerLog { model.decisions.record(for: report) }

    var body: some View {
        VStack(spacing: 0) {
            if let set {
                header(set)
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let other = review.unseen(in: record) { arrived(other, set: set) }
                        ForEach(Array(set.items.enumerated()), id: \.element.id) { index, item in
                            card(item, number: index + 1)
                        }
                        generalField
                    }
                    .padding(14)
                }
                Hairline()
                footer(set)
            }
        }
        .frame(width: 380)
        .background(Palette.chrome)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: Metrics.hairline) }
        .task(id: report) { load() }
        // What he changes is his draft, an emptied one included; back to exactly what was sent, it
        // is no draft of his own any more, and the answer sent is what opens next time.
        .onChange(of: answers) { _, new in model.decisions.saveDraft(isAsSent ? nil : new, for: report) }
        .sheet(isPresented: $confirming) {
            if let set { confirmation(set) }
        }
    }

    private func load() {
        guard let state = model.decisions.state(for: report) else { set = nil; return }
        set = state.set
        if loadedFor != report.path {
            // What he has not sent yet — even if he emptied it — or else what he sent: an answered
            // report opens answered.
            answers = state.record.opening(for: state.set)
            openComments = Set(answers.comments.keys)
            loadedFor = report.path
            review = DecisionReview()
            review.open(state.record)
        }
    }

    // MARK: Parts

    private func header(_ set: DecisionSet) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow("Your decisions")
            Text(set.title)
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.text)
                .lineLimit(2)
            HStack(spacing: 10) {
                Text(progress(set))
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textSecondary)
                if set.items.contains(where: { $0.recommended != nil }) {
                    HStack(spacing: 4) {
                        Circle().fill(Palette.accent).frame(width: 5, height: 5)
                        Text("The agent's advice")
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textFaint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    /// The controls show exactly the answer already sent.
    private var isAsSent: Bool {
        guard let seen = review.corrected(in: record), let set else { return false }
        return answers == seen.answers.fitted(to: set)
    }

    private func progress(_ set: DecisionSet) -> String {
        let chosen = set.items.filter { answers.choices[$0.id] != nil }.count
        var text = String(format: String(localized: "Decided: %lld of %lld"), chosen, set.items.count)
        if let latest = record.latest {
            let time = DateFormatter.localizedString(from: latest.sentAt, dateStyle: .none, timeStyle: .short)
            text += " · " + String(format: String(localized: "sent at %@"), time)
        }
        return text
    }

    private func card(_ item: DecisionSet.Item, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(number)")
                    .font(Typo.mono(11))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 20, alignment: .leading)
                Text(item.title)
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = item.detail {
                Text(detail)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(item.options, id: \.self) { option in optionButton(option, item: item) }
                Spacer(minLength: 0)
                if item.comment {
                    Button {
                        if openComments.contains(item.id) { openComments.remove(item.id) } else { openComments.insert(item.id) }
                    } label: { Image(systemName: "text.bubble") }
                        .buttonStyle(.icon(size: 26, glyph: 12))
                        .help(Text("Comment"))
                }
            }
            if openComments.contains(item.id) {
                TextField(String(localized: "Comment"), text: Binding(
                    get: { answers.comments[item.id] ?? "" },
                    set: { answers.comments[item.id] = $0.isEmpty ? nil : $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous).fill(Palette.content))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
            .strokeBorder(answers.choices[item.id] != nil ? Palette.lineStrong : Palette.line, lineWidth: Metrics.hairline))
    }

    private func optionButton(_ option: String, item: DecisionSet.Item) -> some View {
        let chosen = answers.choices[item.id] == option
        return Button {
            answers.choices[item.id] = chosen ? nil : option
        } label: {
            HStack(spacing: 4) {
                Text(option)
                if item.recommended == option {
                    Circle().fill(Palette.accent).frame(width: 5, height: 5)
                        .accessibilityLabel(Text("The agent's advice"))
                }
            }
        }
        .buttonStyle(.bulava(chosen ? .primary : .quiet))
        .help(item.recommended == option ? Text("The agent's advice") : Text(option))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// An answer that came from another device while the panel was open: shown in full, and
    /// nothing goes until he has read it.
    private func arrived(_ other: DecisionSubmission, set: DecisionSet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: String(localized: "An answer came from another device at %@"),
                        DateFormatter.localizedString(from: other.sentAt, dateStyle: .none, timeStyle: .short)))
                .font(Typo.panelRow)
                .foregroundStyle(Palette.text)
            ForEach(Array(set.items.enumerated()), id: \.element.id) { index, item in
                Text("\(index + 1). \(item.title) — \(other.answers.choices[item.id] ?? String(localized: "not decided"))")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !other.answers.general.isEmpty {
                Text(other.answers.general)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("What you send now replaces it.")
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
            Button {
                // Nothing of his own changed since: the new answer is what the panel shows now.
                if answers == (review.corrected(in: record)?.answers.fitted(to: set) ?? DecisionAnswers()) {
                    answers = other.answers.fitted(to: set)
                    openComments = Set(answers.comments.keys)
                }
                review.acknowledge(record); problem = nil
            } label: { Text("Got it") }
                .buttonStyle(.bulava(.secondary))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous).fill(Palette.orangeSoft))
    }

    private var generalField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Overall comment")
                .font(Typo.panelRow)
                .foregroundStyle(Palette.text)
            TextField(String(localized: "What else to keep in mind, where to start"),
                      text: $answers.general, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...8)
        }
        .padding(.top, 4)
    }

    private func footer(_ set: DecisionSet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem {
                Text(problem.message)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(isAsSent ? "This is what you sent. Change anything to send a correction."
                              : "Undecided items stay undecided: nothing is started on them.")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { problem = nil; load(); confirming = true } label: {
                    Text(review.seen == nil ? "Send" : "Send a correction")
                }
                .buttonStyle(.bulava(.primary))
                .disabled(!review.canSend(answers, in: record, for: set))
            }
        }
        .padding(14)
    }

    // MARK: Confirmation

    private func confirmation(_ set: DecisionSet) -> some View {
        let chat = (record.chatID ?? model.conversations.chats.first { $0.session?.reportPaths.contains(report.path) == true }?.id)
            .flatMap { model.conversations.chat(id: $0) }
        return VStack(alignment: .leading, spacing: 12) {
            Text(chat.map { String(format: String(localized: "This goes to the chat “%@” as your message"), $0.title) }
                 ?? String(localized: "This goes to the report's chat as your message"))
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.text)
            ScrollView {
                Text(DecisionCenter.message(set: set, answers: answers, correcting: review.corrected(in: record)))
                    .font(Typo.body)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            HStack {
                Spacer()
                Button { confirming = false } label: { Text("Back") }
                    .buttonStyle(.bulava(.quiet))
                    .keyboardShortcut(.cancelAction)
                Button { send(set) } label: { Text("Send") }
                    .buttonStyle(.bulava(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!review.canSend(answers, in: record, for: set))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func send(_ set: DecisionSet) {
        confirming = false
        let result = model.decisions.send(from: &review, report: report, answers: answers, revision: set.revision)
        switch result {
        case .success(let submission):
            // What went stays on the controls, as it will when the report is opened again.
            answers = submission.answers.fitted(to: set)
            openComments = Set(answers.comments.keys)
            problem = nil
            model.toast = ToastMessage(text: String(localized: "Decisions sent to the chat."), kind: .success)
        case .failure(let refusal):
            // An answer from elsewhere is shown above the questions now (`arrived`), and nothing goes
            // until he has seen it; changed questions are read again, his choices kept where they fit.
            problem = refusal
            if refusal.code == .stale { load() }
        }
    }
}
