import SwiftUI

struct RenameChatSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chat: Chat

    @State private var title: String
    @FocusState private var focused: Bool

    init(chat: Chat) {
        self.chat = chat
        _title = State(initialValue: chat.title)
    }

    private var generated: String? {
        let auto = Chat.title(from: chat.firstMessage)
        return (chat.firstMessage.isEmpty || auto == title) ? nil : auto
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat name").font(Typo.cardTitle).foregroundStyle(Palette.text)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.icon)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Palette.chrome)

            Hairline()

            VStack(alignment: .leading, spacing: 10) {
                TextField("What this conversation is about", text: $title)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .focused($focused)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1))
                    .onSubmit(save)

                if let generated {
                    Button {
                        title = generated
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 9))
                            Text(String(format: String(localized: "Use “%@”"), generated)).font(Typo.panelMeta)
                        }
                        .foregroundStyle(Palette.accentEmphasis)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            Hairline()

            HStack(spacing: 8) {
                Spacer()
                Button { dismiss() } label: { Text("Cancel") }
                    .buttonStyle(.bulava(.quiet))
                Button { save() } label: { Text("Save") }
                    .buttonStyle(.bulava(.primary))
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.chrome)
        }
        .frame(width: 420)
        .background(Palette.content)
        .onAppear { focused = true }
    }

    private func save() {
        model.conversations.rename(chat.id, to: title)
        dismiss()
    }
}
