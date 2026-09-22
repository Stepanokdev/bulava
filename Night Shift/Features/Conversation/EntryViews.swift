import SwiftUI

struct EntryView: View {
    let entry: ConversationEntry
    let productID: UUID

    var body: some View {
        switch entry.kind {
        case .user:     MessageEntry(entry: entry, isUser: true)
        case .foreman:  MessageEntry(entry: entry, isUser: false)
        case .codex:    CodexMessageEntry(entry: entry)
        case .event:    EventEntry(entry: entry)
        case .question: QuestionEntry(entry: entry)
        case .decision: DecisionEntry(entry: entry)
        case .report:   ReportEntry(entry: entry)
        case .task:     EmptyView()
        }
    }
}

// MARK: - Spoken turn

private struct MessageEntry: View {
    @Environment(AppModel.self) private var model
    @Environment(\.findMark) private var findMark
    let entry: ConversationEntry
    let isUser: Bool
    @State private var copied = false
    @State private var hovering = false

    private var replaced: Bool { entry.delivery == .replaced }

    /// Stop whatever this message started and hand it back to be finished properly.
    private var takeBackButton: some View {
        Button { model.takeBackMessage(entryID: entry.id) } label: {
            Label(isChatBusy ? "Stop and edit" : "Edit", systemImage: "pencil")
        }
        .buttonStyle(DeliveryActionStyle())
        .help(Text(isChatBusy
                   ? "Stop the answer and put this message back to edit"
                   : "Put this message back to edit"))
        .transition(.opacity)
    }

    private var isChatBusy: Bool { model.isDirectChatBusy(entry.chatID) }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        withAnimation(Motion.snappy) { copied = true }
        Task { @MainActor in
            try? await _Concurrency.Task.sleep(for: .seconds(2))
            withAnimation(Motion.standard) { copied = false }
        }
    }

    private var pending: ForemanProposal? {
        guard let id = entry.proposalID,
              let productID = model.route.productID ?? model.selectedProductID,
              let proposal = model.pendingProposals[productID], proposal.id == id else { return nil }
        return proposal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                SpeakerAvatar(initial: isUser ? "I" : "N", isForeman: !isUser)
                Text(isUser ? "You" : "Night Shift")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                Text(Fmt.clock(entry.at))
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
            }

            if !entry.blocks.renderable.isEmpty {
                BlockStack(blocks: entry.blocks, artifactBase: model.artifactBase,
                               entryID: entry.id,
                               productID: entry.productID, chatID: entry.chatID)
            } else if !entry.text.isEmpty {
                if isUser {

                    // His own message is text the app builds itself, so Find marks the phrase
                    // exactly where it stands rather than colouring the whole bubble.
                    findMark.text(entry.text, entry: entry.id)
                        .messageStyle()
                        .foregroundStyle(replaced ? Palette.textFaint : Palette.text)
                        .strikethrough(replaced, color: Palette.textFaint)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                                .fill(Palette.panel)
                                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusCard,
                                                          style: .continuous)
                                    .strokeBorder(Palette.line, lineWidth: 1))
                        }
                        .padding(.leading, 25)
                        // Revealed on hover, on his own last message only: an "edit" button
                        // beside an older one would promise a rewind the agent's session cannot
                        // do.
                        .overlay(alignment: .topTrailing) {
                            if hovering, !replaced, model.canTakeBack(entryID: entry.id) {
                                takeBackButton
                                    .padding(.top, 4)
                                    .padding(.trailing, 4)
                            }
                        }
                        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
                } else {

                    MarkdownProse(text: entry.text,
                                  fileRoots: model.fileRoots(forProductID: entry.productID, chatID: entry.chatID),
                                  openWeb: { model.webPreview = $0 },
                                  find: findMark.prose(entry: entry.id, markdown: entry.text))
                }
            }

            if !entry.attachments.isEmpty {
                AttachmentStrip(attachments: entry.attachments)
                    .padding(.leading, isUser ? 25 : 0)
            }

            if isUser, let delivery = entry.delivery {
                HStack(spacing: 5) {
                    Image(systemName: delivery == .queued ? "clock.arrow.circlepath"
                          : delivery == .replaced ? "arrow.uturn.backward"
                          : "exclamationmark.circle")
                    Text(delivery == .queued
                         ? String(localized: "Queued up")
                         : delivery == .replaced
                         ? String(localized: "Replaced — it had already been read")
                         : String(localized: "Not delivered"))
                    if delivery == .queued {
                        Text("·")
                        Text(isChatBusy
                             ? model.directWaitReason(for: entry.chatID)
                             : String(localized: "Not delivered to the worker yet"))
                    }

                    if delivery == .failed {
                        Button { model.retryDirectMessage(entryID: entry.id) } label: {
                            Label("Send again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(DeliveryActionStyle())
                        .help(Text("Send again"))
                        Button { copyText() } label: {
                            Label(copied ? "Copied" : "Copy",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(DeliveryActionStyle())
                        .help(Text("Copy the text"))
                    }
                }
                .font(Typo.meta)
                .foregroundStyle(delivery == .failed ? Palette.red : Palette.textFaint)
                .padding(.leading, 37)
            }

            if isUser, entry.delivery == .failed,
               let chatID = entry.chatID, let folder = model.trustBlocked[chatID] {
                trustRow(folder: folder, chatID: chatID)
                    .padding(.leading, 37)
                    .padding(.top, 4)
            }

            if isUser, entry.delivery == .failed,
               let chatID = entry.chatID, let folder = model.gitConsentBlocked[chatID] {
                gitConsentRow(folder: folder, chatID: chatID)
                    .padding(.leading, 37)
                    .padding(.top, 4)
            }

            if isUser, entry.delivery == .failed,
               let chatID = entry.chatID, let plan = model.handoffBlocked[chatID] {
                handoffRow(plan: plan, chatID: chatID)
                    .padding(.leading, 37)
                    .padding(.top, 4)
            }

            if isUser, entry.delivery == .failed,
               let chatID = entry.chatID, let wall = entry.codexWall {
                codexOutRow(wall: wall, chatID: chatID)
                    .padding(.leading, 37)
                    .padding(.top, 4)
            }

            // Beside the one message the notice failed to answer. Keyed by chat it appeared under
            // every message in the thread that had ever failed, which is how a week-old failure
            // ended up offering to fix today's login.
            if isUser, model.signInPromptEntryID(inChat: entry.chatID) == entry.id {
                signInRow()
                    .padding(.leading, 37)
                    .padding(.top, 4)
            }

            if let proposal = pending {
                confirmRow(proposal)
                    .padding(.top, 2)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// This folder has no git, and the engine stopped to ask.
    ///
    /// Connecting a folder is not the same as allowing it to be changed: a folder of videos or
    /// documents needs no repository. But without a baseline the night shift has nowhere to roll
    /// back to, so the choice stays with the director — and it is made here, by a button, not by a
    @ViewBuilder private func gitConsentRow(folder: String, chatID: UUID) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 12))
                .foregroundStyle(Palette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("There is no git here, so a run would have no way back and nothing to show a review.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: folder)
                    .font(Typo.mono(9.5))
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                model.allowGitIn(folder, thenRetry: entry.id, in: chatID)
            } label: {
                Label { Text("Create git and send") } icon: { Image(systemName: "checkmark") }
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bulava(.primary))
        }
        .padding(11)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
            .fill(Palette.orangeSoft))
    }

    /// Another chat is running in this project. Nothing was stopped, and the button says exactly
    /// what pressing it does — because the run being stopped may be waiting on an answer rather
    /// than finished, and that is a judgement only the reader can make.
    @ViewBuilder private func handoffRow(plan: AppModel.PendingHandoff, chatID: UUID) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundStyle(Palette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("One project, one run at a time. Stopping it ends whatever it is doing now.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: plan.projectPath)
                    .font(Typo.mono(9.5))
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Button {
                model.stopHolderAndRetry(entryID: entry.id, in: chatID)
            } label: {
                Text(String(format: String(localized: "Stop “%@” and send"), plan.holderTitle))
            }
            .buttonStyle(.bulava(.primary))
        }
        .padding(10)
        .background(Palette.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Metrics.radiusControl))
    }

    /// Claude's own answer was "run /login", which is a command in a terminal the reader of this
    /// window does not have. The button opens one with the login already typed in; sending again is
    /// a separate press, because nothing here can tell when the sign-in finished.
    @ViewBuilder private func signInRow() -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 12))
                .foregroundStyle(Palette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude asked to be signed in again. It happens in a terminal — a login cannot be done for you.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "claude auth login")
                    .font(Typo.mono(9.5))
                    .foregroundStyle(Palette.textFaint)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                model.signIn(command: "claude auth login")
            } label: {
                Text("Sign in…")
            }
            .buttonStyle(.bulava(.primary))
        }
        .padding(11)
        .background(Palette.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Metrics.radiusControl))
    }

    /// Codex has no window left, and the message is still unanswered.
    ///
    /// This used to be no row at all: Claude took the message the moment Codex refused it, and the
    /// thread mentioned the swap underneath the answer it had already given. The substitution is
    /// the same one; what changed is that it now waits for a press. An answer from the other
    /// engineer is worth having when it was asked for and worth nothing when it merely appeared.
    @ViewBuilder private func codexOutRow(wall: String, chatID: UUID) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "pause.circle")
                .font(.system(size: 12))
                .foregroundStyle(Palette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: wall)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing was sent to anybody else. Claude can take this one if you want it now.")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                model.answerWithClaudeInstead(entryID: entry.id, in: chatID)
            } label: {
                Text("Answer with Claude")
            }
            .buttonStyle(.bulava(.primary))
        }
        .padding(11)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
            .fill(Palette.orangeSoft))
    }

    @ViewBuilder private func trustRow(folder: String, chatID: UUID) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12))
                .foregroundStyle(Palette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code asks before working in a folder for the first time.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                Text(verbatim: folder)
                    .font(Typo.mono(9.5))
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                model.trustFolder(folder, thenRetry: entry.id, in: chatID)
            } label: {
                Label { Text("Trust and send") } icon: { Image(systemName: "checkmark") }
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bulava(.primary))
        }
        .padding(11)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
            .fill(Palette.orangeSoft))
    }

    @ViewBuilder private func confirmRow(_ proposal: ForemanProposal) -> some View {
        HStack(spacing: 8) {
            Button {
                model.pendingProposal = nil
                model.executeProposal(proposal)
            } label: {
                Label { Text("Yes, do it") } icon: { Image(systemName: "checkmark") }
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bulava(.primary))

            Button {
                model.pendingProposal = nil
                model.postForemanText("Гаразд, скасував — нічого не роблю.")
            } label: { Text("Not now") }
                .buttonStyle(.bulava(.quiet))

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

}

private struct DeliveryActionStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(Typo.meta)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovering || configuration.isPressed ? Palette.panelMuted : .clear)
            )
            .foregroundStyle(Palette.textSecondary)
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onHover { h in withAnimation(Motion.hover) { hovering = h } }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct CodexMessageEntry: View {
    @Environment(AppModel.self) private var model
    @Environment(\.findMark) private var findMark
    let entry: ConversationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                SpeakerAvatar(initial: "C", isForeman: true)
                Text(verbatim: "Codex")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                Text(Fmt.clock(entry.at))
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
            }

            Group {
                if !entry.blocks.renderable.isEmpty {
                    BlockStack(blocks: entry.blocks, artifactBase: model.artifactBase,
                               entryID: entry.id,
                               productID: entry.productID, chatID: entry.chatID)
                } else {
                    MarkdownProse(text: entry.text,
                                  fileRoots: model.fileRoots(forProductID: entry.productID, chatID: entry.chatID),
                                  openWeb: { model.webPreview = $0 },
                                  find: findMark.prose(entry: entry.id, markdown: entry.text))
                }
            }
            .padding(.leading, 25)
            .overlay(alignment: .leading) {
                Capsule().fill(Palette.accent.opacity(0.35)).frame(width: 2)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Shift event

private struct EventEntry: View {
    let entry: ConversationEntry

    private var tint: Color {
        switch entry.tone {
        case .good: Palette.green
        case .attention: Palette.orange
        case .problem: Palette.red
        case .neutral: Palette.textFaint
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(tint).frame(width: 5, height: 5).padding(.top, 6)
            Text(entry.text)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(Fmt.clock(entry.at))
                .font(Typo.meta)
                .foregroundStyle(Palette.textFaint)
                .monospacedDigit()
        }
        .padding(.leading, 6)
    }
}

// MARK: - Decision

private struct DecisionEntry: View {
    let entry: ConversationEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flag")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.accentEmphasis)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow("Decision", color: Palette.accentEmphasis)
                Text(entry.text)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Palette.accentSoft)
        )
        .padding(.leading, 25)
    }
}

// MARK: - Question

struct QuestionEntry: View {
    @Environment(AppModel.self) private var model
    @Environment(\.findMark) private var findMark
    let entry: ConversationEntry

    @State private var answer = ""
    @State private var selectedOptions: [Int: [String]] = [:]
    @FocusState private var focused: Bool

    private var task: BacklogTask? { entry.taskID.flatMap { model.backlog.task(id: $0) } }
    private var instance: SupervisorInstance? { task.flatMap { model.questionInstance(for: $0) } }

    private var decision: DecisionRecord? { entry.decision ?? instance?.pendingQuestion?.record }
    private var items: [DecisionRecord.Item] { decision?.items ?? [] }
    private var options: [String] { decision?.options ?? [] }

    var body: some View {
        Card(border: Palette.orange.opacity(0.35)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.orange)
                    VStack(alignment: .leading, spacing: 5) {

                        if let gate = decision?.gateLabelKey {
                            Eyebrow(LocalizedStringKey(gate), color: Palette.orange)
                        } else {
                            Eyebrow("Needs your answer", color: Palette.orange)
                        }
                        Text(decision?.headline ?? entry.text)
                            .font(Typo.message)
                            .foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)

                        if let situation = decision?.situation, !situation.isEmpty {
                            Text(situation)
                                .font(Typo.step)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                                .textSelection(.enabled)
                        }

                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            if item.question != (decision?.headline ?? entry.text) || items.count > 1 {
                                Text(items.count > 1 ? "\(index + 1). \(item.question)" : item.question)
                                    .font(Typo.step)
                                    .foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.top, 14)
                .padding(.bottom, 12)

                decisionContext

                if items.contains(where: { !$0.options.isEmpty }) {

                    Hairline()
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            if !item.options.isEmpty {
                                if items.count > 1 {
                                    HStack {
                                        Text("\(index + 1). \(item.header ?? item.question)")
                                            .font(Typo.meta)
                                            .foregroundStyle(Palette.textFaint)
                                            .lineLimit(1)
                                        if item.multiSelect {
                                            Text("several allowed")
                                                .font(Typo.meta)
                                                .foregroundStyle(Palette.textFaint)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 15)
                                    .padding(.top, 8)
                                } else if item.multiSelect {
                                    HStack {
                                        Text("several allowed — list them, comma separated")
                                            .font(Typo.meta)
                                            .foregroundStyle(Palette.textFaint)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 15)
                                    .padding(.top, 8)
                                }
                                optionRows(item, number: items.count > 1 ? index + 1 : nil)
                            }
                        }
                    }
                }

                Hairline()
                HStack(spacing: 8) {
                    TextField("Answer in your own words…", text: $answer, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Typo.step)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit { send(answer) }
                    Button { send(answer) } label: { Text("Send") }
                        .buttonStyle(.bulava(.primary))
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
            }
        }
        // A question card is put together out of the decision it carries, not out of one string
        // the app draws, so Find marks it whole.
        .findHighlight(findMark.state(entry: entry.id,
                                      text: ConversationFind.questionText(entry)))
        .padding(.leading, 25)
    }

    @ViewBuilder private func optionRows(_ item: DecisionRecord.Item, number: Int?) -> some View {
        VStack(spacing: 0) {
            ForEach(item.options, id: \.self) { option in
                let reply = number.map { "\($0): \(option)" } ?? option
                let key = number ?? 1
                let selected = selectedOptions[key]?.contains(option) == true
                Button {
                    if item.multiSelect || items.count > 1 {
                        if item.multiSelect {
                            var values = selectedOptions[key] ?? []
                            if let i = values.firstIndex(of: option) { values.remove(at: i) }
                            else { values.append(option) }
                            selectedOptions[key] = values
                        } else {
                            selectedOptions[key] = [option]
                        }
                        rebuildAnswerFromSelections()
                    } else {
                        send(reply)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "checkmark.circle.fill"
                              : item.multiSelect ? "plus.circle" : "arrow.turn.down.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(selected ? Palette.accentEmphasis : Palette.textFaint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option)
                                .font(Typo.step)
                                .foregroundStyle(Palette.textSecondary)
                                .multilineTextAlignment(.leading)
                            if let description = item.optionDescriptions?[option], !description.isEmpty {
                                Text(description)
                                    .font(Typo.caption)
                                    .foregroundStyle(Palette.textFaint)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.row(radius: 0))
            }
        }
    }

    private func rebuildAnswerFromSelections() {
        if items.count == 1 {
            answer = (selectedOptions[1] ?? []).joined(separator: ", ")
            return
        }
        answer = selectedOptions.keys.sorted().compactMap { number in
            let values = selectedOptions[number] ?? []
            return values.isEmpty ? nil : "\(number): \(values.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    @ViewBuilder private var decisionContext: some View {
        let rec = decision?.recommendation
        let def = decision?.defaultAction
        let unblock = decision?.unblockAction
        if rec != nil || def != nil || unblock != nil {
            VStack(spacing: 0) {
                Hairline()
                VStack(alignment: .leading, spacing: 7) {
                    if let rec { contextRow("I would", rec, Palette.accentEmphasis) }
                    if let def { contextRow("If you never answer", def, Palette.textFaint) }
                    if let unblock { contextRow("Unblocks it", unblock, Palette.green) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(Palette.panelMuted)
            }
        }
    }

    private func contextRow(_ label: LocalizedStringKey, _ value: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(label)
                .font(Typo.tag)
                .textCase(.uppercase)
                .foregroundStyle(tint)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answer = ""
        if let task {
            model.beginAnswering(task)
            model.send(trimmed)
        } else {

            model.answerUnboundQuestion(entry: entry, text: trimmed)
        }
    }
}

// MARK: - Report

struct ReportEntry: View {
    @Environment(AppModel.self) private var model
    let entry: ConversationEntry

    private var task: BacklogTask? { entry.taskID.flatMap { model.backlog.task(id: $0) } }

    var body: some View {
        if let task {
            ReportCard(task: task)
        }
    }
}

struct ReportCard: View {
    @Environment(AppModel.self) private var model
    let task: BacklogTask

    @State private var hovering = false
    @State private var manifest: ReportManifest?

    var body: some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Palette.greenSoft)
                        .frame(width: 42, height: 42)
                        .overlay(
                            Image(systemName: task.isInformationalReview ? "text.magnifyingglass" : "checkmark")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Palette.green)
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(manifest?.title ?? task.title)
                            .cardTitleStyle()
                            .foregroundStyle(Palette.text)
                            .lineLimit(2)
                        Text(subtitle)
                            .font(Typo.meta)
                            .foregroundStyle(Palette.textFaint)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textFaint)
                        .offset(x: hovering ? 2 : 0)
                }
                .padding(15)

                Hairline()
                HStack(spacing: 0) {
                    ForEach(Array(TaskPresentation.cardActions(for: task, model: model).enumerated()),
                            id: \.element.id) { _, action in
                        Button { action.perform(model) } label: {
                            Label { Text(action.titleKey) } icon: { Image(systemName: action.symbol) }
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bulava(action.emphasis == .primary ? .primary : .quiet))
                        .padding(.vertical, 9)
                        .padding(.horizontal, 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
            }
        }
        .onHover { isHovering in withAnimation(Motion.hover) { hovering = isHovering } }
        .onTapGesture { model.openReport(task) }
        .task(id: task.id) { manifest = await model.reportManifest(for: task) }
        .padding(.leading, 25)
    }

    private var subtitle: String {
        if let summary = manifest?.summary, !summary.isEmpty { return summary }
        if task.isInformationalReview {
            return String(localized: "An answer, not a change")
        }
        switch manifest?.format {
        case .photos: return String(localized: "Before and after")
        case .video:  return String(localized: "Recorded walkthrough")
        case .notes:  return String(localized: "Written report")
        case nil:     return String(localized: "Reviewed and ready for you")
        }
    }
}
