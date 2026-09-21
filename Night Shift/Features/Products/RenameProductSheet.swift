import SwiftUI

struct RenameProductSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let product: Product

    @State private var name: String
    @State private var summary: String
    @State private var brief: String
    @FocusState private var nameFocused: Bool

    init(product: Product) {
        self.product = product
        _name = State(initialValue: product.name)
        _summary = State(initialValue: product.summary)
        _brief = State(initialValue: product.brief)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Product details")
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.text)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.icon)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Palette.chrome)

            Hairline()

            VStack(alignment: .leading, spacing: 16) {
                field("Name", text: $name, placeholder: "Narada", focused: true)
                field("One line", text: $summary, placeholder: "AI meeting recorder for macOS")
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("What Bulava should know")
                    TextField("Goals, audience, constraints — anything that stays true",
                              text: $brief, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Typo.body)
                        .lineLimit(3...8)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.field))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Palette.lineStrong, lineWidth: 1))
                    Text("The Foreman reads this before starting a task.")
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textFaint)
                }
            }
            .padding(18)

            Spacer(minLength: 0)
            Hairline()

            HStack(spacing: 8) {
                Spacer()
                Button { dismiss() } label: { Text("Cancel") }
                    .buttonStyle(.bulava(.quiet))
                Button { save() } label: { Text("Save") }
                    .buttonStyle(.bulava(.primary))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 430)
        .background(Palette.content)
        .onAppear { nameFocused = true }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>,
                       placeholder: LocalizedStringKey, focused: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .focused($nameFocused, equals: focused ? true : false)
                .padding(.horizontal, 10)
                .frame(height: Metrics.fieldHeight)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.field))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Palette.lineStrong, lineWidth: 1))
        }
    }

    private func save() {
        model.products.rename(product.id, to: name)
        model.products.setSummary(summary, for: product.id)
        model.products.setBrief(brief, for: product.id)
        dismiss()
    }
}
