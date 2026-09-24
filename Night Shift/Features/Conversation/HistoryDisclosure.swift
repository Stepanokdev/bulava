import SwiftUI

struct HistoryDisclosure: View {
    @Environment(AppModel.self) private var model
    let items: [HistoryItem]
    @Binding var expanded: Bool

    private static let visibleLimit = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggle
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items.prefix(Self.visibleLimit)) { item in
                        HistoryRow(item: item)
                        if item.id != items.prefix(Self.visibleLimit).last?.id { Hairline() }
                    }
                    if items.count > Self.visibleLimit {
                        Button { model.searchPresented = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass").font(.system(size: 10))
                                Text("\(items.count - Self.visibleLimit) more — search to find them")
                            }
                            .font(Typo.meta)
                            .foregroundStyle(Palette.textFaint)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 6)
                .overlay(alignment: .leading) {

                    Rectangle().fill(Palette.line).frame(width: 1)
                }
                .padding(.leading, 17)
                .transition(.opacity)
            }
        }
    }

    private var toggle: some View {
        Button {
            withAnimation(Motion.expand) { expanded.toggle() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("Previous work")
                    .font(Typo.control)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 8)
                Text("\(items.count)")
                    .font(Typo.meta)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            )
        }
        .buttonStyle(.row(radius: 9))
    }
}

// MARK: - Row

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chatReadOnly) private var readOnly
    let item: HistoryItem

    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.expand) { open.toggle() }
            } label: {
                HStack(spacing: 8) {

                    Image(systemName: item.closedByYou ? "minus" : "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(item.closedByYou ? Palette.textFaint : Palette.green)
                        .frame(width: 16)
                        .help(item.closedByYou ? Text("You closed this") : Text("Reviewed and accepted"))
                    Text(item.title)
                        .font(Typo.step)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(item.dayLabel)
                        .font(Typo.meta)
                        .foregroundStyle(Palette.textFaint)
                        .fixedSize()
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 10)
            }
            .buttonStyle(.row(radius: 6))

            if open {
                VStack(alignment: .leading, spacing: 10) {
                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .font(Typo.caption)
                            .lineSpacing(3)
                            .foregroundStyle(Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 7) {
                        if let task = model.backlog.task(id: item.id) {
                            if item.hasReport {
                                Button { model.openReport(task) } label: { Text("Open the report") }
                                    .buttonStyle(.bulava(.quiet))
                            }
                            Button { model.beginFollowUp(task) } label: { Text("Continue from this") }
                                .buttonStyle(.bulava(.quiet))
                                .disabled(readOnly)
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.trailing, 5)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
    }
}
