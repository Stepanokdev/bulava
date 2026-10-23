import SwiftUI

/// Jev in Settings: one switch, the key that makes it work, and a check that it answers.
///
/// What it changes is narrow on purpose. After a run was stopped or sat idle, or after hours of
/// silence, the engine used to take the next message for a new task and prepare it from scratch.
/// With Jev on the task is kept, and Jev decides whether the message continues it. Off, without a
/// key, unsure or unreachable, the engine decides exactly as it did before.
struct JevSettingsSection: View {
    @State private var status: JevStatus?
    @State private var loaded = false
    /// Switched on before a key was stored: the key field is what the switch is waiting for.
    @State private var waitingForKey = false
    @State private var replacingKey = false
    @State private var keyDraft = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var check: JevTestResult?
    @State private var checking = false
    /// Shown as given and never read from the engine — for previews and the rendering test.
    private let fixed: Bool

    init() { fixed = false }

    init(showing status: JevStatus?, waitingForKey: Bool = false, check: JevTestResult? = nil) {
        _status = State(initialValue: status)
        _loaded = State(initialValue: true)
        _waitingForKey = State(initialValue: waitingForKey)
        _check = State(initialValue: check)
        fixed = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Decide with Jev whether a message continues the task")
                        .font(Typo.panelRow)
                        .foregroundStyle(Palette.text)
                    Text("After a run was stopped or sat idle, its next message used to be prepared as a new task: two positions, an alignment, research. With Jev on, the task is kept and Jev decides in under a second whether the message continues it. When Jev is unsure or cannot be reached, the engine decides as before.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Toggle("", isOn: Binding(get: { isOn }, set: { flip($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Palette.accent)
                    .disabled(status == nil || busy)
                    .accessibilityIdentifier("jev.switch")
            }

            statusRow

            if showsKeyField { keyField }

            if let check { checkLine(check) }

            if let problem {
                Text(problem)
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("The message, the task's goal and Claude's last reply go to TypeSafe in the US, on your own TypeSafe account: well under a cent a decision. A key is made at console.typesafe.ai.")
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { if !fixed { await refresh() } }
    }

    // MARK: Parts

    private var isOn: Bool { (status?.isOn ?? false) || waitingForKey }

    private var showsKeyField: Bool {
        guard let status else { return false }
        return (isOn && !status.key) || replacingKey
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let status, status.key {
                Button { Task { await runCheck() } } label: { Text(checking ? "Checking…" : "Check") }
                    .buttonStyle(.bulava(.quiet))
                    .disabled(checking || busy)
                if !replacingKey {
                    Button { replacingKey = true; problem = nil } label: { Text("Replace key") }
                        .buttonStyle(.bulava(.quiet))
                        .disabled(busy)
                }
                Button { Task { await removeKey() } } label: { Text("Remove key") }
                    .buttonStyle(.bulava(.quiet))
                    .disabled(busy)
            }
        }
    }

    private var statusText: String {
        guard loaded else { return String(localized: "Reading the engine's setting…") }
        guard let status else {
            return String(localized: "This engine has no Jev yet. It comes with the next engine update.")
        }
        if waitingForKey && !status.key {
            return String(localized: "Waiting for a key. Nothing is sent until one is stored.")
        }
        switch status.mode {
        case "on" where status.key:
            return status.decisions > 0
                ? String(format: String(localized: "On. %lld decisions so far."), status.decisions)
                : String(localized: "On. The first decision comes with the next message after a restart or a long pause.")
        case "on":
            return String(localized: "On, but there is no key: nothing is sent, and the engine decides as before.")
        case "shadow":
            return String(localized: "Watching only: Jev is asked and its answer written down, the engine decides as before.")
        default:
            return String(localized: "Off. The engine decides as it always has.")
        }
    }

    private var statusColor: Color {
        guard let status, loaded else { return Palette.textFaint }
        if waitingForKey && !status.key { return Palette.orange }
        switch status.mode {
        case "on": return status.key ? Palette.green : Palette.orange
        case "shadow": return Palette.accent
        default: return Palette.textFaint
        }
    }

    private var keyField: some View {
        HStack(spacing: 8) {
            SecureField(String(localized: "TypeSafe API key"), text: $keyDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await saveKey() } }
                .accessibilityIdentifier("jev.key")
            Button { Task { await saveKey() } } label: { Text(busy ? "Saving…" : "Save key") }
                .buttonStyle(.bulava(.primary))
                .disabled(busy || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if replacingKey {
                Button { replacingKey = false; keyDraft = "" } label: { Text("Cancel") }
                    .buttonStyle(.bulava(.quiet))
            }
        }
    }

    private func checkLine(_ result: JevTestResult) -> some View {
        let text: String
        if result.ok {
            let reads = result.verdict == "continue"
                ? String(localized: "«the ticket was updated, check it» reads as the same task")
                : String(localized: "«the ticket was updated, check it» does not read as the same task")
            text = String(format: String(localized: "Jev answered in %1$@ s (input tokens: %2$@): %3$@."),
                          String(format: "%.2f", result.seconds ?? 0), String(result.inputTokens ?? 0), reads)
        } else {
            text = String(format: String(localized: "The check failed: %@."), result.error ?? "?")
        }
        return Text(text)
            .font(Typo.panelMeta)
            .foregroundStyle(result.ok ? Palette.textSecondary : Palette.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private func refresh() async {
        status = await JevClient.status()
        loaded = true
    }

    private func flip(_ on: Bool) {
        problem = nil
        check = nil
        guard let status else { return }
        if on && !status.key {
            // The switch waits for the key; the engine is switched on once one is stored.
            waitingForKey = true
            return
        }
        waitingForKey = false
        replacingKey = false
        Task {
            busy = true
            await JevClient.setEnabled(on)
            await refresh()
            busy = false
        }
    }

    private func saveKey() async {
        busy = true
        problem = await JevClient.storeKey(keyDraft)
        if problem == nil {
            keyDraft = ""
            replacingKey = false
            if waitingForKey || status?.isOn == true { await JevClient.setEnabled(true) }
            waitingForKey = false
            await refresh()
            busy = false
            await runCheck()
        } else {
            // A refusal can still have left a key behind (stored, then not read back): show what
            // the engine actually has, not what the attempt hoped for.
            await refresh()
            busy = false
        }
    }

    private func removeKey() async {
        busy = true
        await JevClient.removeKey()
        await JevClient.setEnabled(false)
        waitingForKey = false
        replacingKey = false
        check = nil
        await refresh()
        busy = false
    }

    private func runCheck() async {
        checking = true
        check = await JevClient.test()
        if check == nil { check = JevTestResult(ok: false, error: String(localized: "no answer from the engine")) }
        checking = false
    }
}

#Preview("Off") {
    JevSettingsSection(showing: JevStatus(mode: "off", key: false, model: "jev-1.13.0", decisions: 0))
        .padding(18).frame(width: 620)
}

#Preview("Waiting for a key") {
    JevSettingsSection(showing: JevStatus(mode: "off", key: false, model: "jev-1.13.0", decisions: 0), waitingForKey: true)
        .padding(18).frame(width: 620)
}

#Preview("On") {
    JevSettingsSection(showing: JevStatus(mode: "on", key: true, model: "jev-1.13.0", decisions: 12),
                       check: JevTestResult(ok: true, model: "jev-1.13.0", seconds: 0.21, inputTokens: 352, verdict: "continue"))
        .padding(18).frame(width: 620)
}
