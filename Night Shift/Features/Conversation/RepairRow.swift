import SwiftUI
import AppKit

/// Under a message that did not go because something broke: what Bulava is doing about it.
///
/// The corner card says it in passing; this stays with the message it is about, so whoever comes
/// back to the chat later finds out what happened without having caught the card.
struct RepairRow: View {
    @Environment(AppModel.self) private var model
    let repair: ChatRepair

    @State private var showsDetail = false
    @State private var copied = false

    private var tint: Color {
        switch repair.phase {
        case .notFixed, .unavailable: Palette.red
        case .needsYou: Palette.orange
        case .fixed: Palette.green
        case .unconfirmed: Palette.blue
        case .offered, .running, .verifying: Palette.accentEmphasis
        }
    }

    private var fill: Color {
        switch repair.phase {
        case .notFixed, .unavailable: Palette.redSoft
        case .needsYou: Palette.orangeSoft
        case .fixed: Palette.greenSoft
        case .unconfirmed: Palette.blueSoft
        case .offered, .running, .verifying: Palette.accentSoft
        }
    }

    private var headline: String {
        switch repair.phase {
        case .offered:
            repair.resendable
                ? String(localized: "Bulava can find what broke, fix it in this folder and send the message again.")
                : String(localized: "Bulava can find what broke and fix it in this folder. The message may already have reached the agent, so it will not be sent again by itself.")
        case .running:
            repair.agent == .claude
                ? String(localized: "Claude is looking for the cause in this folder…")
                : String(localized: "Codex is looking for the cause in this folder…")
        case .verifying:
            String(localized: "Fixed something. Sending the message again…")
        case .fixed(let summary), .notFixed(let summary), .needsYou(let summary):
            summary
        case .unconfirmed(let summary, _):
            summary
        case .unavailable(let reason):
            reason
        }
    }

    private var symbol: String {
        switch repair.phase {
        case .offered: "wrench.and.screwdriver"
        case .running, .verifying: ""
        case .fixed: "checkmark.circle"
        case .unconfirmed: "clock.arrow.circlepath"
        case .notFixed, .unavailable: "exclamationmark.triangle"
        case .needsYou: "hand.raised"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if repair.isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: symbol).font(.system(size: 12))
                    }
                }
                .foregroundStyle(tint)
                .frame(width: 14)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: headline)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if case .unconfirmed(_, let why) = repair.phase {
                        Text(Self.unconfirmedNote(why))
                            .font(Typo.meta)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .notFixed = repair.phase, model.settings.shareErrorReports {
                        Text("An anonymous report went to Bulava's makers, so this gets fixed in an update.")
                            .font(Typo.meta)
                            .foregroundStyle(Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if repair.phase == .running, let started = repair.startedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(Fmt.elapsed(context.date.timeIntervalSince(started)))
                                .font(Typo.meta)
                                .monospacedDigit()
                                .foregroundStyle(Palette.textFaint)
                        }
                    }
                }
            }

            if showsDetail {
                ScrollView {
                    Text(verbatim: detailText)
                        .font(Typo.mono(9.5))
                        .foregroundStyle(Palette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .fill(Palette.panel.opacity(0.6)))
                .padding(.leading, 24)
            }

            HStack(spacing: 8) {
                switch repair.phase {
                case .offered:
                    Button { model.startRepair(chatID: repair.chatID) } label: { Text("Fix it") }
                        .buttonStyle(.bulava(.primary))
                    Button { model.dismissRepair(chatID: repair.chatID) } label: { Text("Not now") }
                        .buttonStyle(.bulava(.quiet))
                case .running:
                    Button { model.cancelRepair(chatID: repair.chatID) } label: { Text("Stop") }
                        .buttonStyle(.bulava(.secondary))
                case .verifying, .fixed:
                    EmptyView()
                case .unconfirmed(_, let why):
                    if why == .notResent {
                        Button { model.sendAgainByHand(chatID: repair.chatID) } label: { Text("Send again") }
                            .buttonStyle(.bulava(.primary))
                    }
                    Button { model.dismissRepair(chatID: repair.chatID) } label: { Text("Got it") }
                        .buttonStyle(.bulava(.quiet))
                case .notFixed:
                    Button { model.startRepair(chatID: repair.chatID) } label: { Text("Try again") }
                        .buttonStyle(.bulava(.secondary))
                case .needsYou:
                    Button { model.dismissRepair(chatID: repair.chatID) } label: { Text("Got it") }
                        .buttonStyle(.bulava(.quiet))
                case .unavailable:
                    Button { model.openPreflight() } label: { Text("Check readiness") }
                        .buttonStyle(.bulava(.secondary))
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(Motion.expand) { showsDetail.toggle() }
                } label: { Text(showsDetail ? LocalizedStringKey("Hide details") : LocalizedStringKey("Details")) }
                    .buttonStyle(.bulava(.quiet))
                Button { copy() } label: {
                    Label(copied ? String(localized: "Copied") : String(localized: "Copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bulava(.quiet))
                .help(Text("Copy the error and what the repair found"))
            }
            .padding(.leading, 24)
        }
        .padding(11)
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).fill(fill))
        .animation(Motion.snappy, value: repair.phase)
        .accessibilityElement(children: .contain)
    }

    /// What "fixed" does not yet mean, said plainly — the delivery is not confirmed.
    static func unconfirmedNote(_ why: ChatRepair.Unconfirmed) -> String {
        switch why {
        case .queued:
            String(localized: "The message is in line and goes as soon as the session is free.")
        case .stillSending:
            String(localized: "The message is still on its way; its answer will appear in the chat.")
        case .notResent:
            String(localized: "The message may already have reached the agent, so Bulava did not send it again. If no answer comes, send it yourself.")
        }
    }

    private var detailText: String {
        var parts = [repair.error]
        if let f = repair.finding, !f.productBug.isEmpty { parts.append(f.productBug) }
        if let d = repair.detail, !d.isEmpty { parts.append(d) }
        return parts.joined(separator: "\n\n")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString([headline, detailText].joined(separator: "\n\n"), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
