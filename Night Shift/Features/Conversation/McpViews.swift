import SwiftUI

/// Under a message that stopped because the project brings MCP servers Claude has not been told
/// about (engine exit 78). The answer is given once per project and kept by the engine; nothing is
/// written into the project, and nothing is enabled until the director says so.
struct McpRow: View {
    @Environment(AppModel.self) private var model
    let block: AppModel.McpBlock
    let entryID: UUID
    let chatID: UUID

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 12))
                .foregroundStyle(Palette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This project brings its own MCP servers. Claude asks whether to enable them before it starts, and in the background nobody can answer. An MCP server can run code, so it is your call.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !block.servers.isEmpty {
                    Text(verbatim: AppModel.mcpServerList(block.servers))
                        .font(Typo.mono(9.5))
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button {
                model.answerMcp(enable: false, entryID: entryID, in: chatID)
            } label: { Text("Send without them") }
            .buttonStyle(.bulava(.secondary))
            Button {
                model.answerMcp(enable: true, entryID: entryID, in: chatID)
            } label: { Text("Enable and send") }
            .buttonStyle(.bulava(.primary))
        }
        .padding(11)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
            .fill(Palette.orangeSoft))
    }
}

/// The same question from a task card, which has no message to put a row under.
struct McpPrompts: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: presented, titleVisibility: .visible,
                                presenting: model.mcpAsk) { ask in
                Button { model.answerMcpAndDispatch(ask, enable: true) } label: { Text("Enable them and start") }
                Button { model.answerMcpAndDispatch(ask, enable: false) } label: { Text("Start without them") }
                Button(role: .cancel) { model.mcpAsk = nil } label: { Text("Not now") }
            } message: { ask in
                Text(verbatim: AppModel.mcpServerList(ask.servers, limit: 8))
            }
    }

    private var title: Text {
        Text(String(format: String(localized: "“%@” did not start: the project brings MCP servers Claude has to ask about, and an MCP server can run code."),
                    model.mcpAsk?.task.title ?? ""))
    }

    private var presented: Binding<Bool> {
        Binding(get: { model.mcpAsk != nil }, set: { if !$0 { model.mcpAsk = nil } })
    }
}
