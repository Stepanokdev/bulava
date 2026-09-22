import SwiftUI

/// Find in this conversation, the way a browser does it: a small bar over the thread, a count
/// that keeps up with the typing, and two arrows that walk the results.
///
/// It sits in the thread's top safe area rather than floating over it, so that a result scrolled
/// to lands BELOW the bar instead of behind it.
struct FindBar: View {
    @Binding var session: FindSession
    var focused: FocusState<Bool>.Binding

    let onStep: (Int) -> Void
    let onClose: () -> Void

    private var hasResults: Bool { !session.isEmpty }
    private var searching: Bool { !session.query.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textFaint)

            TextField("Find in this chat…", text: $session.query)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.text)
                .focused(focused)
                .frame(width: 190)
                .onKeyPress(phases: .down) { press in
                    switch press.key {
                    case .return:
                        onStep(press.modifiers.contains(.shift) ? -1 : 1)
                        return .handled
                    case .escape:
                        onClose()
                        return .handled
                    default:
                        return .ignored
                    }
                }

            count

            HStack(spacing: 1) {
                Button { onStep(-1) } label: { Image(systemName: "chevron.up") }
                    .help(Text("Previous result (⇧⌘G)"))
                Button { onStep(1) } label: { Image(systemName: "chevron.down") }
                    .help(Text("Next result (⌘G)"))
            }
            .buttonStyle(.icon(size: 22, glyph: 10))
            .disabled(!hasResults)
            .opacity(hasResults ? 1 : 0.4)

            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.icon(size: 22, glyph: 10))
                .help(Text("Close the search (esc)"))
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Palette.panel)
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                        .strokeBorder(Palette.lineStrong, lineWidth: 1)
                }
        }
        .floatingShadow()
        .fixedSize()
        // Esc again at the bar's own level: the handler on the field only fires while the field
        // holds focus, and a click on one of the arrows moves it. Esc has to close the search
        // from wherever inside the bar the reader happens to be.
        .onKeyPress(.escape) { onClose(); return .handled }
        // Focus is taken here rather than where the bar is put up: at that moment the field does
        // not exist yet, and focus asked of a view that is not there is simply dropped — the bar
        // appears and the first thing typed goes nowhere.
        .onAppear { focused.wrappedValue = true }
    }

    /// Where the reader is among the results — and, when a markdown answer holds the phrase more
    /// than once, how many mentions those results add up to. One number alone would be a lie
    /// either about the walk or about the thread.
    @ViewBuilder private var count: some View {
        if searching, !hasResults {
            Text("Not found")
                .font(Typo.meta)
                .foregroundStyle(Palette.textFaint)
        } else if hasResults {
            HStack(spacing: 5) {
                Text(verbatim: "\((session.activeIndex ?? 0) + 1)/\(session.places.count)")
                    .font(Typo.meta)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                if session.mentions > session.places.count {
                    Text(Fmt.count("%lld mentions", session.mentions))
                        .font(Typo.meta)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textFaint)
                }
            }
            .help(Text("Places this phrase appears in, in the order they were said"))
        }
    }
}
