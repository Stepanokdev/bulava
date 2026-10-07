import SwiftUI
import UniformTypeIdentifiers
import os

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
    /// Whether the scroll under way is his own — see `TailFollow.advance(from:to:byHand:)`.
    @State private var scrollingByHand = false
    /// Which messages the lazy thread has built right now. Find walks toward a result from the
    /// nearest of these; a reference, so rows coming and going do not redraw the thread.
    @State private var built = BuiltRows()
    /// Bumped to build the thread afresh — see `checkStillDrawn(_:)`.
    @State private var threadGeneration = 0

    /// Find in this conversation. It belongs to the view and not to the model on purpose: it owns
    /// scrolling and focus, and it has to die with the thread it was searching.
    @State private var find = FindSession()
    @State private var findShown = false
    @FocusState private var findFocused: Bool

    private var product: Product? { model.products.product(id: productID) }

    private var chatID: UUID? { model.conversations.displayedChatID(for: productID) }
    /// An archived chat opened from Archives or search: shown for reading, never written to.
    private var archived: Chat? { model.conversations.viewedArchivedChat(for: productID) }
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
                    // Lazy, and the messages are its direct rows. A plain stack built every message
                    // of a long chat — every answer's Markdown, every card — on each change, and a
                    // streaming answer changes ten times a second: scrolling a long thread crawled.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isFresh {
                            invitation
                        } else {
                            feed
                        }

                        if !entries.contains(where: { $0.kind == .question }) {
                            SessionStatusRow(phase: phase, activity: activity, queueCount: queueCount,
                                             degradation: model.directDegradation(for: chatID),
                                             run: chatID.flatMap { model.chatRuns[$0] })
                                .padding(.top, 12)
                        }

                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    // Every message is a target the scroll position can go to by its id, built
                    // or not — which is what lets Find reach one far up a lazy thread.
                    .scrollTargetLayout()
                    .id(threadGeneration)
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
                                     viewportHeight: geometry.containerSize.height,
                                     viewportWidth: geometry.containerSize.width)
                } action: { old, new in
                    // A growing answer is not the reader leaving. Both readings go in, and
                    // TailFollow tells the two apart; if it decides to keep following it also
                    // catches the thread up, because the height changed under this very callback
                    // and `tailSignature` will not fire for a chunk that carried no new text.
                    // Not animated: this fires on every chunk of a streaming answer, and an
                    // animation started ten times a second fights itself. Pinned text should look
                    // like it is simply standing still while more of it arrives.
                    //
                    // Worked out on a copy and written back only when it changed: this runs on every
                    // frame of a scroll, and writing the state each time rebuilt the whole thread
                    // each frame.
                    built.offset = new.offsetY
                    built.height = new.contentHeight
                    var next = follow
                    let keepUp = next.advance(from: old, to: new, byHand: scrollingByHand)
                    if next != follow { follow = next }
                    if keepUp, new.distanceFromBottom > 0.5 {
                        scrollToBottom(proxy, animated: false)
                    }
                    checkStillDrawn(proxy)
                }
                // A hand on the trackpad is the one thing that takes the thread back from a find
                // jump. A programmatic scroll reports `.animating`, so this cannot mistake Find's
                // own jump for the reader changing their mind.
                .onScrollPhaseChange { _, phase in
                    // A fling keeps moving after the fingers lift, and it is still his.
                    let byHand = phase == .interacting || phase == .tracking || phase == .decelerating
                    if byHand != scrollingByHand { scrollingByHand = byHand }
                    guard follow.pinned else { return }
                    if phase == .interacting || phase == .tracking { follow.unpin() }
                }

                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        WorkCopyBar(chatID: chatID)
                        findLayer(proxy)
                    }
                }

                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let archived {
                        ArchivedChatBar(chat: archived)
                    } else {
                        Composer(productID: productID)
                    }
                }

                if dropTargeted { fileDropOverlay }
            }
            // Not `dropDestination(for: URL.self)`: a dragged screenshot thumbnail carries no file
            // URL at all — the shot is still a promise on its way to the desktop — so that reading
            // saw an empty drop and refused it. Taking the item providers instead lets the PNG the
            // thumbnail really is carrying through.
            .onDrop(of: [.fileURL, .image], isTargeted: Binding(
                get: { dropTargeted },
                // An archived chat takes nothing: the files would wait in the live chat's draft,
                // out of sight, and the overlay would promise a message that cannot be sent.
                set: { dropTargeted = $0 && archived == nil })) { providers in
                guard archived == nil else { return false }
                return model.importDrop(providers, into: productID)
            }
            .animation(Motion.hover, value: dropTargeted)
            .environment(\.findMark, findMark)
            .environment(\.chatReadOnly, archived != nil)
            .task(id: chatID) {
                built.reset()
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

            // The run's steps, from the engine's journal, for the line under the chat.
            .task(id: chatID) { await model.watchChatRun(chatID: chatID) }

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
            .onDisappear {
                model.findBarOpen = false
                built.reset()
            }

            // A working agent does not add entries — it grows the last one, and the status line
            // under it changes as it goes. Watching only the COUNT meant the thread sat still
            // while text streamed in below the fold, and every answer had to be scrolled to by
            // hand.
            .onChange(of: tailSignature) { _, _ in
                if entries.last?.kind == .user { follow.rejoin() }
                checkStillDrawn(proxy)
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
        // Straight from the store: Find needs the words of the explanations there are, and the
        // full state — which fingerprints each turn's whole content to tell whether it went stale
        // — asked for every answer of a long thread on every streamed chunk held the window still.
        for entry in entries where entry.kind == .foreman {
            let brief = model.explanations.explanation(.turn(entry.id), .brief)?.text
            let steps = model.explanations.explanation(.turn(entry.id), .stepByStep)?.text
            guard brief != nil || steps != nil else { continue }
            let text = ConversationFind.explainedText(brief: brief, stepByStep: steps)
            if !text.isEmpty { out[entry.id] = text }
        }
        return out
    }

    private func go(to place: FindPlace, _ proxy: ScrollViewProxy) {
        // Pinned BEFORE the scroll: a result within the last forty points of the thread is inside
        // the tail-follow slack, and without the pin the next chunk of a streaming answer would
        // drag the reader straight back down off it.
        follow.pin()
        // The thread is lazy, and a jump far up it is a guess: rows that were never built are
        // placed by an estimate, and with long answers near the end the estimate can be off by
        // thousands of points — the jump lands on the wrong message, and asking again lands on the
        // same wrong one. So the result's row is approached in short hops from the nearest row
        // that IS built, where the estimate is good, and the exact place inside it is aimed at once
        // the row exists. Only while the reader is still on this result.
        //
        // The bound position still says "the bottom edge" from the last time the thread followed
        // its tail, and a lazy thread that changes height re-applies it; Find holds its own.
        scroll = ScrollPosition(idType: UUID.self)
        let target = place.scrollID
        let wanted = place.entryID
        proxy.scrollTo(wanted, anchor: .top)
        _Concurrency.Task { @MainActor in
            for _ in 0..<60 {
                try? await _Concurrency.Task.sleep(for: .milliseconds(40))
                guard follow.pinned, find.active?.scrollID == target else { return }
                if built.ids.contains(wanted) { break }
                let order = entries.map(\.id)
                guard let goal = order.firstIndex(of: wanted) else { return }
                let near = order.indices.filter { built.ids.contains(order[$0]) }
                    .min { abs($0 - goal) < abs($1 - goal) }
                guard let near else { proxy.scrollTo(wanted, anchor: .top); continue }
                let hop = min(abs(goal - near), 12)
                proxy.scrollTo(order[near + (goal > near ? hop : -hop)], anchor: .top)
            }
            // The row is there; its own height is now known. Aim at it, then at the place inside it,
            // and again as whatever was built on the way settles.
            // Then the place inside it, again and again until the thread stops moving: rows built
            // on the way are measured after the aim and push the place down under it.
            proxy.scrollTo(wanted, anchor: .top)
            var still = 0
            var last = built.offset
            for _ in 0..<40 {
                try? await _Concurrency.Task.sleep(for: .milliseconds(50))
                guard follow.pinned, find.active?.scrollID == target else { return }
                proxy.scrollTo(target, anchor: .top)
                try? await _Concurrency.Task.sleep(for: .milliseconds(30))
                still = abs(built.offset - last) < 1 && abs(built.height - built.lastHeight) < 1 ? still + 1 : 0
                last = built.offset
                built.lastHeight = built.height
                if still >= 3 { return }
            }
        }
    }

    private func step(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard findShown else { return }
        if let place = find.step(delta) { go(to: place, proxy) }
    }

    private static let bottomAnchor = "conversation.bottom"
    private static let log = Logger(subsystem: "app.bulava", category: "thread")

    // MARK: - A thread that stopped drawing

    /// Puts the thread back on screen when the lazy stack has left it standing on a stretch with
    /// no message built in it.
    ///
    /// 5 Oct: "while Bulava works and the chat changes, all the text sometimes disappears, and I
    /// have to scroll down and up by hand for it to render again." Whenever the thread is measured
    /// again — the window narrower, the side panel opening, a long answer arriving — the stack
    /// estimates the rows it has not built, and in a long chat the estimate is off by tens of
    /// thousands of points. Now and then, depending on timing, the scroll position is restored or
    /// followed to a place where, by those estimates, there are rows, and in fact there are none:
    /// nothing is built, nothing is drawn, and nothing changes until a hand moves the thread.
    /// It is a race inside the stack (`scripts/tests/test-thread-stays-drawn.sh` reproduces it on a
    /// long chat); no arrangement of the scroll modifiers avoided it every time.
    ///
    /// So the thread watches for the state itself. A moment after any change of its geometry or its
    /// tail, if there are messages and not one of them is built, the stack is built afresh — from
    /// measurements, not estimates — and taken back to where the reader was: the end while it is
    /// following, the Find result it is pinned to, or else the messages last on screen.
    private func checkStillDrawn(_ proxy: ScrollViewProxy) {
        // One pending look, not one per change: an answer streaming ten times a second would
        // otherwise push the look back forever and the thread would stay blank while it streams.
        guard built.drawnCheck == nil, let chat = chatID else { return }
        built.drawnToken += 1
        let token = built.drawnToken
        built.drawnCheck = _Concurrency.Task { @MainActor in
            defer { if built.drawnToken == token { built.drawnCheck = nil } }
            try? await _Concurrency.Task.sleep(for: .milliseconds(300))
            guard !_Concurrency.Task.isCancelled, chatID == chat,
                  !entries.isEmpty, built.ids.isEmpty else { return }
            // Three times in ten seconds at most: a stack that keeps going blank must not be rebuilt
            // in a loop that holds the window still. When the budget is spent, one more look is
            // booked for the moment it renews, so a thread that went blank and then stood still
            // is not left that way.
            let now = Date()
            built.rebuilds = built.rebuilds.filter { now.timeIntervalSince($0) < 10 }
            if built.rebuilds.count >= 3, let oldest = built.rebuilds.min() {
                let wait = max(0.3, 10.05 - now.timeIntervalSince(oldest))
                try? await _Concurrency.Task.sleep(for: .seconds(wait))
                guard !_Concurrency.Task.isCancelled, chatID == chat,
                      !entries.isEmpty, built.ids.isEmpty else { return }
                built.rebuilds = built.rebuilds.filter { Date().timeIntervalSince($0) < 10 }
            }
            built.rebuilds.append(Date())

            // Where the reader was, decided BEFORE the rebuild: the geometry of a fresh stack
            // passes through a short "bottom" on its way to the real one, and reading the follow
            // state after it would send somebody reading history to the end.
            enum Place { case end, find(FindPlace), seen(UUID) }
            let lastSeen = entries.map(\.id).filter { built.lastSeen.contains($0) }
            let place: Place
            if follow.pinned, let result = find.active {
                place = .find(result)
            } else if follow.following || lastSeen.isEmpty {
                place = .end
            } else {
                place = .seen(lastSeen[lastSeen.count / 2])
            }

            threadGeneration += 1
            try? await _Concurrency.Task.sleep(for: .milliseconds(60))
            // His hand on the trackpad, or another chat, wins over putting the thread back.
            guard !_Concurrency.Task.isCancelled, chatID == chat, !scrollingByHand else { return }
            let described: String
            switch place {
            case .find(let result):
                described = "the Find result"
                // The way Find itself gets there: the row first, then the place inside it.
                go(to: result, proxy)
            case .end:
                described = "the end"
                scrollToBottom(proxy, animated: false)
            case .seen(let id):
                described = "the messages last on screen"
                proxy.scrollTo(id, anchor: .center)
            }
            Self.log.notice("thread had no message built in view (content \(built.height, privacy: .public) pt, at \(built.offset, privacy: .public)); built it afresh at \(described, privacy: .public)")
        }
    }

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

    @ViewBuilder private var feed: some View {
        ForEach(entries) { entry in
            EntryView(entry: entry, productID: productID)
                .padding(.bottom, 22)
                // Where a find jump lands when the whole entry is the result: his own
                // message, or an answer that carries no blocks of its own. Inside the row, not
                // on it: an `.id` on the row would replace the identity the lazy stack knows
                // rows by before they are built, and a jump to one not built yet went nowhere.
                .background(alignment: .top) {
                    Color.clear.frame(height: 1).findAnchor(entry: entry.id)
                        .onAppear { built.appeared(entry.id) }
                        .onDisappear { built.disappeared(entry.id) }
                }
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
    /// The latest run of this chat, step by step, when the engine has journalled one.
    var run: ChatRun?

    /// "Work stopped" says THAT it stopped. When the engine said why — a review that needs a
    /// decision, a permission it was refused — the line says that instead of sending the reader
    /// up the thread to guess.
    private var label: String {
        if phase == .needsReview, case .waitingForYou(let why)? = run?.graph.overall,
           let why, !why.isEmpty {
            return String(format: String(localized: "Work stopped: %@"), why)
        }
        return phase.label
    }

    private var showsRun: Bool {
        guard let run, run.document != nil else { return false }
        if phase.isActive { return true }
        switch run.graph.overall {
        case .waitingForYou, .waitingForCodex, .waitingForLimit: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if phase.isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: phase.symbol)
                }
                Text(label)
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
            if showsRun, let run {
                RunStrip(run: run)
                    .padding(.leading, 23)
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

// MARK: - An archived chat, read only

/// Takes the composer's place while an archived chat is open. The thread above stays readable;
/// the one way to write in it again is to bring it back first.
private struct ArchivedChatBar: View {
    @Environment(AppModel.self) private var model
    let chat: Chat

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("This chat is archived")
                    .font(Typo.body.weight(.semibold))
                    .foregroundStyle(Palette.text)
                Text("You can read it. Unarchive it to write here again.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { model.unarchiveChat(chat) } label: {
                Label { Text("Unarchive") } icon: { Image(systemName: "arrow.uturn.backward") }
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bulava(.primary))
            .help(Text("Return this chat to the list and write in it again"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                .fill(Palette.panel.opacity(0.92))
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                .strokeBorder(Palette.lineStrong, lineWidth: 1)
        )
        .floatingShadow()
        // The composer's own frame, so the thread above ends where it always does.
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
    }
}

private struct ChatReadOnlyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside an archived chat opened for reading. Controls that would write to the chat,
    /// answer for it or act on its work read this and stand down.
    var chatReadOnly: Bool {
        get { self[ChatReadOnlyKey.self] }
        set { self[ChatReadOnlyKey.self] = newValue }
    }
}

/// The rows a lazy thread has built — see `ConversationView.go(to:_:)`.
@MainActor
private final class BuiltRows {
    /// Counted, not a set: when the thread is built afresh the new row can appear before the old
    /// one with the same id has gone, and a set would then drop a row that is on screen.
    private var counts: [UUID: Int] = [:]
    var ids: Set<UUID> { Set(counts.keys) }
    /// The rows built just before the last of them went: where the reader was when the thread
    /// went blank.
    private(set) var lastSeen: Set<UUID> = []
    var drawnCheck: _Concurrency.Task<Void, Never>?
    /// Which booked look is the current one, so a look that was called off cannot clear the next.
    var drawnToken = 0
    var rebuilds: [Date] = []

    func appeared(_ id: UUID) {
        counts[id, default: 0] += 1
        lastSeen = Set(counts.keys)
    }

    func disappeared(_ id: UUID) {
        guard let count = counts[id] else { return }
        if count > 1 { counts[id] = count - 1; return }
        if counts.count == 1 { lastSeen = Set(counts.keys) }
        counts[id] = nil
    }

    /// Another chat: nothing it built and no look booked for it carries over.
    func reset() {
        drawnCheck?.cancel()
        drawnCheck = nil
        rebuilds = []
        lastSeen = []
    }
    /// The last scroll reading, kept here rather than in state for the same reason.
    var offset: CGFloat = 0
    var height: CGFloat = 0
    var lastHeight: CGFloat = 0
}
