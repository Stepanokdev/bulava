import SwiftUI

struct CloseWorkButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chatReadOnly) private var readOnly

    enum Target {
        case task(BacklogTask)
        case item(WorkItem)
    }

    let target: Target

    let running: Bool

    @State private var asking = false

    private var title: String {
        let full = switch target {
        case .task(let t): t.title
        case .item(let i): i.title
        }
        guard full.count > 44 else { return full }
        let cut = String(full.prefix(44))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 18 {
            return String(cut[cut.startIndex..<space]) + "…"
        }
        return cut + "…"
    }

    private var stepCount: Int {
        switch target {
        case .task: 1
        case .item(let i): i.streams.count
        }
    }

    var body: some View {
        Button { asking = true } label: {
            Text("Close it")
        }
        .buttonStyle(.bulava(.quiet))
        .disabled(readOnly)
        .help(Text("Mark this finished and take it out of the conversation"))
        .confirmationDialog(Text(String(format: String(localized: "Close “%@”?"), title)),
                            isPresented: $asking, titleVisibility: .visible) {
            Button(role: .destructive) { close() } label: { Text("Close it") }
            Button(role: .cancel) { asking = false } label: { Text("Cancel") }
        } message: {
            Text(message)
        }
    }

    private var message: String {
        var parts: [String] = []
        if stepCount > 1 {
            parts.append(String(format: String(localized: "All %lld steps in this card close together."), stepCount))
        }
        if running { parts.append(String(localized: "The worker on it stops.")) }
        parts.append(String(localized: "The card leaves this chat. Nothing is merged and nothing is marked approved — it stays in Previous work as closed by you."))
        return parts.joined(separator: " ")
    }

    private func close() {
        switch target {
        case .task(let t): model.closeOut(task: t)
        case .item(let i): model.closeOut(item: i)
        }
    }
}
