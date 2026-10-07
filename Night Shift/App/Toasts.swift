import Foundation

/// Something the app says in passing — a result, a refusal, a problem — shown as a card in the
/// window's top-right corner.
///
/// It used to be one capsule at the bottom, two lines at most and 480 points wide, holding the
/// latest message only. A refusal that explained itself in a long sentence ended in "…" exactly
/// where it said what to do; "Settings saved" a second later replaced it altogether; and the whole
/// capsule dismissed on any click, so its text could not even be selected to be copied. These are
/// cards in a short stack instead: the whole text, an explicit close, the technical part folded
/// under "Details" with a Copy button, and the action that fixes the problem on the card itself.
struct ToastMessage: Identifiable, Equatable {
    enum Kind { case success, error, info }

    var id = UUID()
    /// A few words saying what happened, when the text alone does not start with that.
    var title: String?
    var text: String
    var kind: Kind
    /// What this message is ABOUT. A second message with the same key is the same story continued:
    /// it replaces the card rather than stacking beside it, so "not updated" is followed by
    /// "updated" in the same place — and the same error repeated is counted, not shown five times.
    var key: String?
    /// Command output, a log tail, a path — whatever a person might paste into a bug report. Shown
    /// folded, monospaced, selectable.
    var detail: String?
    var actions: [ToastAction] = []
    /// Something is still happening (a repair under way). The card shows it and does not time out.
    var inProgress = false
    /// How many times this exact message has been posted while its card was up.
    var count = 1
    var postedAt = Date()

    init(title: String? = nil, text: String, kind: Kind, key: String? = nil,
         detail: String? = nil, actions: [ToastAction] = [], inProgress: Bool = false) {
        self.title = title
        self.text = text
        self.kind = kind
        self.key = key
        self.detail = detail
        self.actions = actions
        self.inProgress = inProgress
    }

    /// Two messages are the same story when they say they are, or — for the many call sites that
    /// name no key — when they say the same thing.
    var identity: String { key ?? "\(kind)|\(title ?? "")|\(text)" }

    /// Errors wait to be read; good news and progress notes leave by themselves.
    var dismissesItself: Bool { kind != .error && !inProgress && actions.isEmpty }

    static func == (a: ToastMessage, b: ToastMessage) -> Bool {
        a.id == b.id && a.title == b.title && a.text == b.text && a.kind == b.kind
            && a.detail == b.detail && a.count == b.count && a.inProgress == b.inProgress
            && a.actions.map(\.id) == b.actions.map(\.id)
    }
}

/// A button on a card. Pressing it closes the card unless the action says otherwise — it usually
/// starts the thing the card was about, and the next card says how that went.
struct ToastAction: Identifiable {
    let id = UUID()
    var title: String
    var primary = true
    var keepsCard = false
    var perform: @MainActor () -> Void

    init(title: String, primary: Bool = true, keepsCard: Bool = false,
         perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.primary = primary
        self.keepsCard = keepsCard
        self.perform = perform
    }
}

/// The stack's rules, kept apart from the app so they can be checked on their own.
enum ToastStack {

    /// More than this and the corner becomes a wall. The oldest message that is not an error goes
    /// first; errors are only dropped when nothing else is left to drop.
    static let limit = 4

    static func post(_ message: ToastMessage, into stack: [ToastMessage]) -> [ToastMessage] {
        var stack = stack
        var incoming = message
        if let i = stack.firstIndex(where: { $0.identity == incoming.identity }) {
            let previous = stack.remove(at: i)
            // The same card, so nothing jumps: it keeps its place in the view's identity.
            incoming.id = previous.id
            let sameWords = previous.kind == incoming.kind && previous.text == incoming.text
                && previous.title == incoming.title
            incoming.count = sameWords ? previous.count + 1 : 1
        }
        stack.append(incoming)
        while stack.count > limit {
            if let j = stack.firstIndex(where: { $0.kind != .error }) {
                stack.remove(at: j)
            } else {
                stack.removeFirst()
            }
        }
        return stack
    }
}

extension AppModel {

    /// The newest card. Setting it posts a card — every place in the app that ever said
    /// `toast = ToastMessage(…)` keeps working and now adds to the stack instead of replacing it.
    var toast: ToastMessage? {
        get { toasts.last }
        set {
            if let newValue {
                toasts = ToastStack.post(newValue, into: toasts)
            } else if !toasts.isEmpty {
                toasts.removeLast()
            }
        }
    }

    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    /// The story a key names is over — fixed, or no longer true.
    func resolveToast(key: String) {
        toasts.removeAll { $0.key == key }
    }
}
