import SwiftUI
import AppKit
import OSLog

struct Composer: View {
    @Environment(AppModel.self) private var model
    let productID: UUID

    @State private var text = ""
    @State private var voice = VoiceRecorder()
    @State private var editorHeight: CGFloat = GrowingMessageEditor.minimumHeight
    @State private var focused = false
    @State private var slashCommands: [ClaudeSlashCommand] = []
    @State private var commandSelection = 0
    @State private var autocompleteDismissed = false

    private var product: Product? { model.products.product(id: productID) }
    private var chatID: UUID? { model.conversations.currentChatID(for: productID) }
    private var attachments: [Attachment] { model.draftAttachments(for: productID) }
    private var isSending: Bool { chatID.map { model.sendingChatIDs.contains($0) } ?? false }
    private var isWorking: Bool { model.isDirectChatBusy(chatID) }
    private var isStopping: Bool { chatID.map { model.stoppingChatIDs.contains($0) } ?? false }
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
    private var commandQuery: SlashCommandQuery? { SlashCommandQuery(text) }
    private var matchingCommands: [ClaudeSlashCommand] {
        commandQuery?.matches(in: slashCommands) ?? []
    }
    private var autocompleteVisible: Bool {
        focused && !autocompleteDismissed && !matchingCommands.isEmpty
    }
    private var commandMenuHeight: CGFloat {
        let rows = min(matchingCommands.count, SlashCommandMenu.maximumVisibleRows)
        let spacing = max(0, rows - 1)
        return CGFloat(rows) * SlashCommandMenu.rowHeight + CGFloat(spacing) * 2 + 12
    }

    var body: some View {
        field
            .padding(.horizontal, 30)
            .padding(.top, 34)
            .padding(.bottom, 18)
            .frame(maxWidth: Metrics.readingWidth + 60)
            .frame(maxWidth: .infinity)

            .background(
                LinearGradient(colors: [Palette.content.opacity(0), Palette.content],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            )
            .onChange(of: model.composerFocusRequest) { _, _ in focused = true }
            .onChange(of: text) { previous, next in
                model.setDraftText(next, for: productID)
                commandSelection = 0
                autocompleteDismissed = false
                if SlashCommandQuery(previous) == nil, SlashCommandQuery(next) != nil {
                    _Concurrency.Task { await reloadSlashCommands() }
                }
            }
            .onChange(of: focused) { _, isFocused in
                guard isFocused else { return }
                _Concurrency.Task { await reloadSlashCommands() }
            }
            .task(id: commandRootsKey) { await reloadSlashCommands() }

            .onAppear { text = model.draftText(for: productID) }
            .onChange(of: productID) { _, id in text = model.draftText(for: id) }
    }

    // MARK: - Field

    private var field: some View {
        composerSurface
            .overlay(alignment: .top) {
                if autocompleteVisible {
                    SlashCommandMenu(commands: matchingCommands,
                                     selection: commandSelection,
                                     onHighlight: { commandSelection = $0 },
                                     onChoose: completeCommand)
                        .frame(height: commandMenuHeight)
                        .offset(y: -commandMenuHeight - 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.98,
                                                                  anchor: .bottom)))
                }
            }
            .zIndex(10)
            .animation(Motion.hover, value: autocompleteVisible)
    }

    private var composerSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty { attachmentChips }

            ZStack(alignment: .topLeading) {
                GrowingMessageEditor(text: $text,
                                     height: $editorHeight,
                                     focused: $focused,
                                     onSend: send,
                                     onAutocompleteKey: handleAutocompleteKey,
                                     onPaste: paste)
                    .frame(height: editorHeight)

                if text.isEmpty {
                    Text(placeholder)
                        .font(Typo.message)
                        .foregroundStyle(Palette.textFaint)
                        .padding(.top, 3)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            controls
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                .fill(Palette.panel.opacity(0.92))
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                .strokeBorder(focused ? Palette.selectedBorder : Palette.lineStrong, lineWidth: 1)
        )
        .floatingShadow()
        .animation(Motion.hover, value: focused)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 5) {
            Button { attachFiles() } label: { Image(systemName: "plus") }
                .buttonStyle(.icon(size: 28, glyph: 13))
                .help(Text("Attach files"))

            RunControl(hasLiveClaudeSession: hasLiveClaudeSession)

            sessionLabel
                .layoutPriority(-1)

            Spacer(minLength: 8)

            if voice.isRecording { recordingMeter }
            if voice.phase.isTranscribing { transcribingRow }

            Button { voice.isRecording ? stopVoice() : startVoice() } label: {
                Image(systemName: voice.isRecording ? "stop.fill" : "mic")
            }
            .buttonStyle(.icon(size: 28, glyph: 13,
                               tint: voice.isRecording ? Palette.red : Palette.textSecondary))
            .disabled(voice.phase.isTranscribing)
            .help(Text(voice.isRecording ? "Stop recording" : "Say it instead"))

            Button { isWorking ? model.stopDirectChat(chatID) : send() } label: {

                Image(systemName: isWorking ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isWorking || canSend ? Palette.content : Palette.textFaint)
                    .frame(width: 28, height: 28)
                    .background {
                        if isWorking || canSend {
                            Circle().fill(Palette.text)
                        } else {
                            Circle().strokeBorder(Palette.lineStrong, lineWidth: 1)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(isWorking ? isStopping : (!canSend || isSending))
            .help(Text(isWorking ? "Stop the answer" : "Send (↵) · New line (⇧↵ or ⌥↵)"))
        }
    }

    // MARK: - What this message runs on

    /// Whether this chat has a live Claude session, which keeps the model it was started with.
    private var hasLiveClaudeSession: Bool {
        guard model.settings.chatMode.usesClaude, let chatID else { return false }
        return model.conversations.chat(id: chatID)?.session?.claudeSessionID != nil
    }

    private var sessionLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 9, weight: .medium))
            Text(primaryProjectName)
            if isWorking {
                Text("·")
                Text(model.directWaitReason(for: chatID))
                    .lineLimit(1)
            }
        }
        .font(Typo.meta)
        .foregroundStyle(Palette.textFaint)
        .padding(.leading, 2)
        .lineLimit(1)
    }

    private var primaryProjectName: String {
        guard let project = primaryProject else {
            return String(localized: "Choose a project folder")
        }
        return project.name
    }

    private var primaryProject: Project? {
        guard let id = product?.defaultProjectID else { return nil }
        return model.projects.project(id: id)
    }

    private var commandRoots: SlashCommandCatalog.Roots {
        let primaryPath = primaryProject.map { Slug.canonicalPath($0.path) }
        var seen = Set<String>()
        let added = (product?.resources ?? []).compactMap { resource -> URL? in
            guard let projectID = resource.projectID,
                  let project = model.projects.project(id: projectID) else { return nil }
            let path = Slug.canonicalPath(project.path)
            guard path != primaryPath, seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return SlashCommandCatalog.Roots(
            primaryProject: primaryPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
            addedProjects: added.sorted { $0.path < $1.path }
        )
    }

    private var commandRootsKey: String {
        ([commandRoots.primaryProject?.path ?? "-"] + commandRoots.addedProjects.map(\.path))
            .joined(separator: "\n")
    }

    private var placeholder: LocalizedStringKey {
        "Message Night Shift…"
    }

    // MARK: - Attachments

    /// The draft's attachments, as the pictures they are.
    ///
    /// A row of grey chips with a generic glyph told him nothing about what he had just attached
    /// — which of four screenshots, whether the PDF was the right one. Same card as inside a
    /// message, one size smaller, with the remove button on top of it.
    private var attachmentChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    AttachmentThumb(attachment: attachment, compact: true)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                model.removeDraftAttachment(attachment.id, from: productID)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.textSecondary)
                                    .background(Circle().fill(Palette.panel))
                            }
                            .buttonStyle(.plain)
                            .help(Text("Remove this attachment"))
                            .offset(x: 5, y: -5)
                        }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 5)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 62)
    }

    private func symbol(for kind: AttachmentKind) -> String {
        switch kind {
        case .image: "photo"
        case .audio: "waveform"
        case .file:  "doc"
        case .link:  "link"
        }
    }

    // MARK: - Voice meter

    /// Reading the words takes a moment, and a first-ever dictation has a model to fetch. Both
    /// used to be a completely still window, which reads as a hang rather than as work.
    private var transcribingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(voice.phase.note ?? String(localized: "Reading what you said…"))
                .font(Typo.meta)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
        .transition(.opacity)
    }

    private var recordingMeter: some View {
        HStack(spacing: 6) {
            Text(Fmt.elapsed(voice.elapsed))
                .font(Typo.panelMeta)
                .monospacedDigit()
                .foregroundStyle(Palette.red)
            Capsule()
                .fill(Palette.red.opacity(0.25))
                .frame(width: 44, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Palette.red)
                        .frame(width: max(2, 44 * min(max(voice.level, 0), 1)))
                }
        }
    }

    // MARK: - Actions

    private func send() {
        guard canSend, !isSending else { return }
        let body = text
        let files = model.takeDraftAttachments(for: productID)
        text = ""
        model.setDraftText("", for: productID)

        editorHeight = GrowingMessageEditor.minimumHeight
        model.send(body, attachments: files)
    }

    private func paste(_ pasteboard: NSPasteboard) -> Bool {
        model.importPasteboard(pasteboard, into: productID)
    }

    private func handleAutocompleteKey(_ key: ComposerAutocompleteKey) -> Bool {
        guard autocompleteVisible else { return false }
        switch key {
        case .previous:
            commandSelection = max(0, commandSelection - 1)
        case .next:
            commandSelection = min(matchingCommands.count - 1, commandSelection + 1)
        case .complete:
            completeCommand(commandSelection)
        case .dismiss:
            autocompleteDismissed = true
        }
        return true
    }

    private func completeCommand(_ index: Int) {
        guard matchingCommands.indices.contains(index) else { return }
        text = matchingCommands[index].invocation + " "
        focused = true
    }

    private func reloadSlashCommands() async {
        let roots = commandRoots
        let discovered = await _Concurrency.Task.detached(priority: .utility) {
            SlashCommandCatalog.discover(roots)
        }.value
        slashCommands = discovered
        commandSelection = min(commandSelection, max(0, matchingCommands.count - 1))
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            model.importDroppedFile(url, into: productID)
        }
    }

    private func startVoice() {
        _Concurrency.Task {
            guard let failure = await voice.start() else { return }
            switch failure {
            case .alreadyRecording:
                break
            case .permissionDenied:
                model.toast = ToastMessage(text: String(localized: "Bulava needs microphone access to take dictation"),
                                           kind: .error)
            case .recorderFailed(let why):

                model.toast = ToastMessage(text: String(format: String(localized: "Could not start recording: %@"), why),
                                           kind: .error)
                Log.lifecycle.error("voice recorder failed: \(why, privacy: .public)")
            }
        }
    }

    private func stopVoice() {
        guard let result = voice.stop() else { return }
        _Concurrency.Task {
            let transcript = await voice.transcribe(url: result.url, language: dictationLanguage)
            if let transcript, !transcript.isEmpty {
                // Dictation is typing with your voice. Attaching the recording as well — which
                // it used to do every time — sends the agent an audio file nobody asked for
                // beside the words it already has.
                text = text.isEmpty ? transcript : text + "\n" + transcript
            } else if var attachment = model.capture.importFile(from: result.url) {
                // Only when the words could not be read: the recording is then the only thing
                // that survived, and throwing it away would lose what he said.
                attachment.durationSeconds = result.duration
                attachment.kind = .audio
                model.addDraftAttachment(attachment, to: productID)
                model.toast = ToastMessage(text: String(localized: "Kept the recording — could not transcribe it"),
                                           kind: .info)
            } else {
                model.toast = ToastMessage(text: String(localized: "Could not make out the dictation"),
                                           kind: .error)
            }
            try? FileManager.default.removeItem(at: result.url)
        }
    }

    /// The language dictation is decoded in — his own setting, never the machine's locale.
    private var dictationLanguage: String {
        model.settings.dictationLanguage.code(interface: model.settings.interfaceLanguage)
    }
}

// MARK: - Slash command completion

private struct SlashCommandMenu: View {
    static let maximumVisibleRows = 7
    static let rowHeight: CGFloat = 46

    let commands: [ClaudeSlashCommand]
    let selection: Int
    let onHighlight: (Int) -> Void
    let onChoose: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        Button { onChoose(index) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text(command.invocation)
                                        .font(Typo.mono(11.5).weight(.semibold))
                                        .foregroundStyle(Palette.text)
                                    if !command.argumentHint.isEmpty {
                                        Text(command.argumentHint)
                                            .font(Typo.mono(9.5))
                                            .foregroundStyle(Palette.textFaint)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                }
                                if !command.description.isEmpty {
                                    Text(command.description)
                                        .font(Typo.caption)
                                        .foregroundStyle(Palette.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: Self.rowHeight)
                        }
                        .buttonStyle(.row(selected: index == selection,
                                          radius: Metrics.radiusControl))
                        .onHover { hovering in
                            if hovering { onHighlight(index) }
                        }
                        .id(command.id)
                        .accessibilityIdentifier("slash-command-\(command.id)")
                        .accessibilityLabel(command.invocation)
                        .accessibilityValue(command.description)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.automatic)
            .onChange(of: selection) { _, next in
                guard commands.indices.contains(next) else { return }
                withAnimation(Motion.hover) {
                    proxy.scrollTo(commands[next].id, anchor: .center)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Palette.panel.opacity(0.96))
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: Metrics.radiusPanel,
                                                style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(Palette.lineStrong, lineWidth: Metrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous))
        .floatingShadow()
    }
}

// MARK: - Growing native editor

nonisolated enum ComposerReturnAction: Equatable {
    case send
    case newline
    case system
}

nonisolated enum ComposerKeyPolicy {

    /// Which modifiers turn Return into a line break instead of a send.
    ///
    /// Shift is the one people arrive with — every chat window they have ever used breaks a line
    /// that way, and reaching for it here sent the message half-written. Option was here first and
    /// stays, because fingers that learned it should not have to unlearn it.
    static func wantsNewline(shift: Bool, option: Bool) -> Bool { shift || option }

    static func returnAction(newline: Bool, hasMarkedText: Bool) -> ComposerReturnAction {
        if hasMarkedText { return .system }
        return newline ? .newline : .send
    }

    static func autocompleteAction(keyCode: UInt16, newline: Bool,
                                   hasMarkedText: Bool) -> ComposerAutocompleteKey? {
        guard !hasMarkedText else { return nil }
        switch keyCode {
        case 126: return .previous
        case 125: return .next
        case 48: return .complete
        case 53: return .dismiss
        // Return picks the highlighted completion — unless it is being used to break a line, in
        // which case it is not a choice about the list at all.
        case 36, 76: return newline ? nil : .complete
        default: return nil
        }
    }
}

nonisolated enum ComposerAutocompleteKey: Equatable {
    case previous
    case next
    case complete
    case dismiss
}

private final class MessageTextView: NSTextView {
    var onSend: @MainActor () -> Void = {}
    var onAutocompleteKey: @MainActor (ComposerAutocompleteKey) -> Bool = { _ in false }
    var onPaste: @MainActor (NSPasteboard) -> Bool = { _ in false }

    // ⌘V of a screenshot or a file used to land on a text view that takes neither — it is plain
    // text only, by design — and so did nothing at all. The composer takes the contents as an
    // attachment instead; anything it does not claim is still an ordinary text paste.
    override func paste(_ sender: Any?) {
        if onPaste(.general) { return }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let newline = ComposerKeyPolicy.wantsNewline(
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option))
        let autocompleteKey = ComposerKeyPolicy.autocompleteAction(
            keyCode: event.keyCode,
            newline: newline,
            hasMarkedText: hasMarkedText()
        )
        if let autocompleteKey, onAutocompleteKey(autocompleteKey) { return }
        guard isReturn else {
            super.keyDown(with: event)
            return
        }

        switch ComposerKeyPolicy.returnAction(
            newline: newline,
            hasMarkedText: hasMarkedText()
        ) {
        case .send:
            onSend()
        case .newline:
            insertNewline(nil)
        case .system:
            super.keyDown(with: event)
        }
    }
}

private struct GrowingMessageEditor: NSViewRepresentable {

    static let minimumHeight: CGFloat = Metrics.composerRestingHeight
    static let maximumHeight: CGFloat = 164

    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    let onSend: @MainActor () -> Void
    let onAutocompleteKey: @MainActor (ComposerAutocompleteKey) -> Bool
    let onPaste: @MainActor (NSPasteboard) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = MessageTextView(frame: NSRect(x: 0, y: 0, width: 100,
                                                     height: Self.minimumHeight))
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: Self.minimumHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 100,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.font = .systemFont(ofSize: 13.5)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.string = text
        textView.onSend = onSend
        textView.onAutocompleteKey = onAutocompleteKey
        textView.onPaste = onPaste
        textView.setAccessibilityLabel(String(localized: "Message Night Shift…"))
        scrollView.documentView = textView

        DispatchQueue.main.async { context.coordinator.updateHeight(of: textView, in: scrollView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MessageTextView else { return }
        context.coordinator.parent = self
        textView.onSend = onSend
        textView.onAutocompleteKey = onAutocompleteKey
        textView.onPaste = onPaste
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.updateHeight(of: textView, in: scrollView)
        }
        if focused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingMessageEditor

        init(parent: GrowingMessageEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MessageTextView,
                  let scrollView = textView.enclosingScrollView else { return }
            parent.text = textView.string
            updateHeight(of: textView, in: scrollView)
        }

        func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused = false }

        func updateHeight(of textView: NSTextView, in scrollView: NSScrollView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = ceil(layoutManager.usedRect(for: textContainer).height
                                     + textView.textContainerInset.height * 2)
            let nextHeight = min(max(contentHeight, GrowingMessageEditor.minimumHeight),
                                 GrowingMessageEditor.maximumHeight)
            scrollView.hasVerticalScroller = contentHeight > GrowingMessageEditor.maximumHeight
            if abs(parent.height - nextHeight) > 0.5 { parent.height = nextHeight }
        }
    }
}

// MARK: - Attachment strip

struct AttachmentStrip: View {
    let attachments: [Attachment]

    var body: some View {
        WrappingHStack(horizontalSpacing: 7, verticalSpacing: 7) {
            ForEach(attachments) { attachment in
                AttachmentThumb(attachment: attachment)
            }
        }
    }
}
