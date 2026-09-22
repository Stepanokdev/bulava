import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let productID: UUID

    @State private var scroll = ScrollPosition(edge: .bottom)
    @State private var dropTargeted = false

    /// Whether the thread is still following its own tail.
    ///
    /// Following must not fight someone who scrolled up to read. While they are back in the
    /// history nothing moves under them; the moment they return to the bottom, the thread starts
    /// following again — and their own message always brings them back. See `TailFollow` for why
    /// this tracks "did they scroll away" rather than "are they at the bottom".
    @State private var follow = TailFollow()

    /// Find in this conversation. It belongs to the view and not to the model on purpose: it owns
    /// scrolling and focus, and it has to die with the thread it was searching.
    @State private var find = FindSession()
    @State private var findShown = false
    @FocusState private var findFocused: Bool

    private var product: Product? { model.products.product(id: productID) }

    private var chatID: UUID? { model.conversations.currentChatID(for: productID) }
    private var entries: [ConversationEntry] {
        guard let chatID else { return [] }
        return model.visibleEntries(inChat: chatID)
    }
    private var phase: DirectChatPhase { model.directPhase(for: chatID) }
    private var activity: NowLine? { model.directActivity(for: chatID) }
    private var queueCount: Int { model.directQueueCount(for: chatID) }
    private var isFresh: Bool { entries.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if isFresh {
                            invitation
                        } else {
                            feed
                        }

                        if !entries.contains(where: { $0.kind == .question }) {
                            SessionStatusRow(phase: phase, activity: activity, queueCount: queueCount,
                                             degradation: model.directDegradation(for: chatID))
                                .padding(.top, 12)
                        }

                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 30)
                    .padding(.top, 26)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.automatic)
                .scrollPosition($scroll, anchor: .bottom)
                .onScrollGeometryChange(for: TailFollow.Frame.self) { geometry in
                    TailFollow.Frame(offsetY: geometry.contentOffset.y,
                                     contentHeight: geometry.contentSize.height,
                                     viewportHeight: geometry.containerSize.height)
                } action: { old, new in
                    // A growing answer is not the reader leaving. Both readings go in, and
                    // TailFollow tells the two apart; if it decides to keep following it also
                    // catches the thread up, because the height changed under this very callback
                    // and `tailSignature` will not fire for a chunk that carried no new text.
                    // Not animated: this fires on every chunk of a streaming answer, and an
                    // animation started ten times a second fights itself. Pinned text should look
                    // like it is simply standing still while more of it arrives.
                    if follow.advance(from: old, to: new), new.distanceFromBottom > 0.5 {
                        scrollToBottom(proxy, animated: false)
                    }
                }
                // A hand on the trackpad is the one thing that takes the thread back from a find
                // jump. A programmatic scroll reports `.animating`, so this cannot mistake Find's
                // own jump for the reader changing their mind.
                .onScrollPhaseChange { _, phase in
                    guard follow.pinned else { return }
                    if phase == .interacting || phase == .tracking { follow.unpin() }
                }

                .safeAreaInset(edge: .top, spacing: 0) { findLayer(proxy) }

                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Composer(productID: productID)
                }

                if dropTargeted { fileDropOverlay }
            }
            // Not `dropDestination(for: URL.self)`: a dragged screenshot thumbnail carries no file
            // URL at all — the shot is still a promise on its way to the desktop — so that reading
            // saw an empty drop and refused it. Taking the item providers instead lets the PNG the
            // thumbnail really is carrying through.
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                model.importDrop(providers, into: productID)
            }
            .animation(Motion.hover, value: dropTargeted)
            .environment(\.findMark, findMark)
            .task(id: chatID) {
                closeFind(focusComposer: false)
                follow.rejoin()
                model.syncDirectChats()
                scrollToBottom(proxy, animated: false)
                try? await _Concurrency.Task.sleep(for: .milliseconds(350))
                // The catch-up scroll belongs to the chat that asked for it. Without this guard
                // it fires for a chat already left behind — and lands on a find jump the reader
                // has just made in the new one.
                guard !_Concurrency.Task.isCancelled else { return }
                scrollToBottom(proxy, animated: false)
            }

            // ⌘F, ⌘G and ⇧⌘G come from the menu bar, which cannot see this view's state.
            .onChange(of: model.findOpenRequest) { _, _ in openFind() }
            .onChange(of: model.findNextRequest) { _, _ in step(1, proxy) }
            .onChange(of: model.findPreviousRequest) { _, _ in step(-1, proxy) }

            .onChange(of: find.query) { _, _ in
                refreshFind()
                if let place = find.active { go(to: place, proxy) }
            }
            // An answer still being written grows the results under the reader. The cursor is
            // held by identity, so it stays on the very result they are standing on.
            .onChange(of: tailSignature) { _, _ in refreshFind() }
            // An explanation finishing adds words to a turn that is otherwise standing still,
            // so the counter has to be told about it the same way. Watching the assembled prose
            // rather than the store's count also catches "Explain again", which replaces one in
            // place; while nobody is searching it is empty and this costs nothing.
            .onChange(of: explainedProse) { _, _ in refreshFind() }

            .onChange(of: findShown) { _, shown in model.findBarOpen = shown }
            .onDisappear { model.findBarOpen = false }

            // A working agent does not add entries — it grows the last one, and the status line
            // under it changes as it goes. Watching only the COUNT meant the thread sat still
            // while text streamed in below the fold, and every answer had to be scrolled to by
            // hand.
            .onChange(of: tailSignature) { _, _ in
                if entries.last?.kind == .user { follow.rejoin() }
                guard follow.following else { return }
                scrollToBottom(proxy, animated: true)
            }
        }
    }

    /// Everything that can change the height of the thread without adding an entry: the last
    /// entry's own growth, the activity line, the queue, the phase.
    private var tailSignature: String {
        var parts = ["\(entries.count)"]
        if let last = entries.last {
            parts.append("\(last.id):\(last.text.count):\(last.blocks.count):\(last.attachments.count)")
        }
        parts.append(activity?.key ?? "")
        parts.append(activity?.object ?? "")
        parts.append(activity?.detail ?? "")
        parts.append("\(phase)")
        parts.append("\(queueCount)")
        return parts.joined(separator: "|")
    }

    private var fileDropOverlay: some View {
        ZStack {
            Palette.content.opacity(0.72)
                .background(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(18)
            VStack(spacing: 9) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Palette.accentEmphasis)
                Text("Drop files to attach them")
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.text)
                Text("They will be added to this message")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: - Find in this conversation

    /// The bar sits in the thread's top safe area, so a result scrolled to lands below it instead
    /// of behind it. The gradient is the same trick the composer plays at the other end: the
    /// inset reserves the room, and the thread still passes under it as it scrolls.
    @ViewBuilder private func findLayer(_ proxy: ScrollViewProxy) -> some View {
        if findShown {
            FindBar(session: $find,
                    focused: $findFocused,
                    onStep: { delta in step(delta, proxy) },
                    onClose: { closeFind(focusComposer: true) })
                // Right-hand end of the reading column — the same edge the composer ends on, and
                // out of the way of the prose, which is set left.
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 30)
                .padding(.top, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: Metrics.readingWidth + 60)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(colors: [Palette.content, Palette.content.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                )
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var findMark: FindMark {
        guard findShown, let active = find.active else { return FindMark() }
        var mark = FindMark(query: find.query,
                            activeEntryID: active.entryID,
                            activeBlockID: active.blockID)
        if case .range(let occurrence) = active.mark { mark.activeOccurrence = occurrence }
        return mark
    }

    private func openFind() {
        withAnimation(Motion.arrive) { findShown = true }
        refreshFind()
        // ⌘F pressed a second time, with the bar already up and the caret back in the composer:
        // setting a focus flag that is already true changes nothing, so it is put down and taken
        // up again on the next turn of the loop.
        findFocused = false
        _Concurrency.Task { @MainActor in findFocused = true }
    }

    private func closeFind(focusComposer: Bool) {
        guard findShown || !find.query.isEmpty else { return }
        withAnimation(Motion.arrive) { findShown = false }
        find.clear()
        findFocused = false
        follow.unpin()
        if focusComposer { model.composerFocusRequest = UUID() }
    }

    private func refreshFind() {
        guard findShown, !find.query.isEmpty else {
            if !find.isEmpty { find.refresh([]) }
            // Nothing to stand on any more, so the thread goes back to following its own tail.
            // Without this, deleting the phrase left a live answer pinned and apparently frozen.
            if find.query.isEmpty { follow.unpin() }
            return
        }
        find.refresh(ConversationFind.places(in: entries, query: find.query,
                                             explained: explainedProse))
    }

    /// What each turn's explanation panel is showing, for the index to walk with everything else
    /// on the page. Empty while nobody is searching — rendering every stored explanation to plain
    /// text costs more than the thread itself, and nothing needs it until a phrase is typed.
    private var explainedProse: [UUID: String] {
        guard findShown, !find.query.isEmpty else { return [:] }
        var out: [UUID: String] = [:]
        for entry in entries where entry.kind == .foreman {
            let state = model.explainState(turn: entry)
            guard state.hasAnything else { continue }
            let text = ConversationFind.explainedText(brief: state.brief?.text,
                                                      stepByStep: state.stepByStep?.text)
            if !text.isEmpty { out[entry.id] = text }
        }
        return out
    }

    private func go(to place: FindPlace, _ proxy: ScrollViewProxy) {
        // Pinned BEFORE the scroll: a result within the last forty points of the thread is inside
        // the tail-follow slack, and without the pin the next chunk of a streaming answer would
        // drag the reader straight back down off it.
        follow.pin()
        withAnimation(Motion.arrive) {
            proxy.scrollTo(place.scrollID, anchor: .top)
        }
    }

    private func step(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard findShown else { return }
        if let place = find.step(delta) { go(to: place, proxy) }
    }

    private static let bottomAnchor = "conversation.bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let go = {
            scroll.scrollTo(edge: .bottom)
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
        if animated { withAnimation(Motion.arrive) { go() } } else { go() }
    }

    // MARK: - Invitation

    private var invitation: some View {
        InviteState(
            systemImage: "moon.stars",
            title: Text("Start a Night Shift conversation"),
            message: "Write exactly as you would in the terminal. Follow-up messages stay in this chat, and you can resume it later.")
        .padding(.vertical, 60)
    }

    // MARK: - Feed

    private var feed: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                EntryView(entry: entry, productID: productID)
                    .padding(.bottom, 22)
                    // Where a find jump lands when the whole entry is the result: his own
                    // message, or an answer that carries no blocks of its own.
                    .findAnchor(entry: entry.id)
            }
        }
    }

}

// MARK: - Date rule

struct DateRule: View {
    let text: Text

    var body: some View {
        HStack(spacing: 12) {
            Hairline()
            text.font(Typo.meta).foregroundStyle(Palette.textFaint).fixedSize()
            Hairline()
        }
    }
}

private struct SessionStatusRow: View {
    let phase: DirectChatPhase
    let activity: NowLine?
    let queueCount: Int
    /// Working a hand short. The engine has always recorded this; until now nothing showed it, so
    /// a run continuing without Codex looked exactly like one that had both engineers on it.
    var degradation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if phase.isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: phase.symbol)
                }
                Text(phase.label)
                    .foregroundStyle(phase.isFailure ? Palette.red
                                     : phase.wantsAttention ? Palette.orange
                                     : Palette.textSecondary)
                if phase == .auditing {
                    Text(verbatim: "AUDIT")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.accentEmphasis)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Palette.accentSoft))
                }
                Spacer(minLength: 0)
                if queueCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(String(localized: "Queued up"))
                        Text(verbatim: "\(queueCount)")
                    }
                    .foregroundStyle(Palette.textSecondary)
                }
            }
            if let activity, phase == .working {
                Text(activity.sentence)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(2)
                    .padding(.leading, 23)
            }
            if let degradation, phase.isActive {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "person.fill.questionmark")
                    Text(degradation)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.textFaint)
                .padding(.leading, 23)
            }
        }
        .font(Typo.meta)
        .padding(.horizontal, phase.isActive || queueCount > 0 ? 10 : 0)
        .padding(.vertical, phase.isActive || queueCount > 0 ? 8 : 4)
        .background {
            if phase.isActive || queueCount > 0 {
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .fill(Palette.panel.opacity(0.75))
            }
        }
    }
}
