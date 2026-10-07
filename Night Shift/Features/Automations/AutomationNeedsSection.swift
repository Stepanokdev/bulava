import AppKit
import SwiftUI

/// "What it will need": every access the automation is going to touch, where each stands, and the
/// one button that settles it — pressed while he is here, so nothing waits for him at night.
///
/// Access the trigger itself needs (the calendar for a meeting, Mail for a letter, a guarded folder)
/// keeps the form from saving until it is settled: an automation that cannot start is worse than
/// one not made yet. What the brief's words suggest (a browser, screenshots) is offered, not required.
struct AutomationNeedsSection: View {
    let trigger: AutomationTrigger
    let brief: String
    /// Something the trigger needs is still unsettled.
    @Binding var blocking: Bool

    @State private var states: [String: NeedState]
    @State private var asking: String?

    /// `known`: states already found, shown before the first check comes back.
    init(trigger: AutomationTrigger, brief: String, blocking: Binding<Bool>, known: [String: NeedState] = [:]) {
        self.trigger = trigger
        self.brief = brief
        self._blocking = blocking
        self._states = State(initialValue: known)
    }

    private var needs: [AutomationNeed] { AutomationNeeds.needs(trigger: trigger, brief: brief) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("What it will need")
            VStack(spacing: 0) {
                ForEach(needs) { need in
                    row(need)
                    Hairline()
                }
                nightRow
            }
            .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).fill(Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1))
            .animation(Motion.standard, value: needs.map(\.id))
        }
        .task(id: needs.map(\.id)) { await refresh() }
        // Back from System Settings: what he changed there is read again, never assumed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    // MARK: Rows

    private func row(_ need: AutomationNeed) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol(need))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(need)).font(Typo.rowLabel).foregroundStyle(Palette.text)
                detail(need)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing(need)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var nightRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "moon.stars")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nobody approves anything while it runs").font(Typo.rowLabel).foregroundStyle(Palette.text)
                Text("Claude's own permission questions are answered for it: its browser is allowed, anything else is declined and listed in the run's report.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func trailing(_ need: AutomationNeed) -> some View {
        if asking == need.id {
            ProgressView().controlSize(.small)
        } else {
            switch states[need.id] {
            case nil:
                ProgressView().controlSize(.small)
            case .ready?:
                StatePill(text: need == .browser ? "Ready" : "Allowed", systemImage: "checkmark",
                          tint: Palette.green, wash: Palette.greenSoft)
            case .askNow?:
                Button("Allow now") { ask(need) }.buttonStyle(.bulava(.primary))
            case .checkNow?:
                Button("Check access") { ask(need) }.buttonStyle(.bulava(.secondary))
            case .blocked?:
                HStack(spacing: 6) {
                    StatePill(text: "Refused", systemImage: "xmark", tint: Palette.orange, wash: Palette.orangeSoft)
                    Button("Open Settings") { open(need) }.buttonStyle(.bulava(.secondary))
                }
            case .missing?:
                Button("Install Chrome") { open(need) }.buttonStyle(.bulava(.secondary))
            case .atRunTime?:
                Button("Open Mail") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app")) }
                    .buttonStyle(.bulava(.secondary))
                    .help(Text("Mail is closed, so it cannot be asked now. Open it and the question appears here."))
            }
        }
    }

    // MARK: Words

    private func title(_ need: AutomationNeed) -> LocalizedStringKey {
        switch need {
        case .calendar: "Calendar"
        case .mail: "Letters in Mail"
        case .folder: "The watched folder"
        case .browser: "Its own browser"
        case .screen: "Screen recording"
        }
    }

    @ViewBuilder private func detail(_ need: AutomationNeed) -> some View {
        switch need {
        case .calendar: Text("To know when a meeting ends.")
        case .mail: Text("To read new letters. Mail has to be open while it watches.")
        case .folder(let path): Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
        case .browser: Text("Chrome with no window and a profile of its own. It needs no permission and touches nothing of yours.")
        case .screen: Text("For screenshots of apps on this Mac, taken by Bulava.")
        }
    }

    private func symbol(_ need: AutomationNeed) -> String {
        switch need {
        case .calendar: "calendar"
        case .mail: "envelope"
        case .folder: "folder"
        case .browser: "globe"
        case .screen: "rectangle.dashed.badge.record"
        }
    }

    // MARK: Acting

    private func ask(_ need: AutomationNeed) {
        asking = need.id
        Task {
            let state = await AutomationNeeds.ask(need)
            states[need.id] = state
            asking = nil
            updateBlocking()
        }
    }

    private func open(_ need: AutomationNeed) {
        if let url = AutomationNeeds.fixURL(need) { NSWorkspace.shared.open(url) }
    }

    private func refresh() async {
        // A folder path being typed out is not checked one letter at a time.
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        for need in needs {
            if case .folder = need {
                // Known only by reading it. He is here, in the form: if macOS asks, now is the time.
                if states[need.id] != .ready { states[need.id] = await AutomationNeeds.ask(need) }
                continue
            }
            states[need.id] = await AutomationNeeds.state(of: need)
        }
        updateBlocking()
    }

    private func updateBlocking() {
        blocking = needs.filter(\.comesFromTrigger).contains { states[$0.id]?.stopsTheTrigger ?? false }
    }
}
