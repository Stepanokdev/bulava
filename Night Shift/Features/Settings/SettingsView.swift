import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var draft = AppSettings.fallback
    @State private var tools: [ToolStatus] = []
    @State private var testOutput = ""
    @State private var checking = false
    @State private var testing = false
    @State private var advancedOpen = false
    @State private var usagePreviewOpen = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    appearanceSection
                    learningSection
                    engineSection
                    diagnosticsSection
                    weekSection
                    advancedSection
                    about
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if dirty {
                Hairline()
                saveBar
            }
        }
        .background(Palette.content)
        .animation(Motion.standard, value: dirty)
        .onAppear { draft = model.settings }
    }

    // MARK: - Appearance & language

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(get: { model.settings.appearance }, set: { model.settings.appearance = $0 })
    }

    private func languageBinding(_ keyPath: WritableKeyPath<AppSettings, AppLanguage>) -> Binding<AppLanguage> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { model.settings[keyPath: keyPath] = $0 })
    }

    private var appearanceSection: some View {
        SettingsSection("Appearance") {
            VStack(spacing: 0) {
                SettingRow("Theme", help: "System follows macOS. Light and dark are designed separately.") {
                    Picker("", selection: appearanceBinding) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(LocalizedStringKey(appearance.label)).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .settingsRow()

                Hairline()

                SettingRow("Interface language", help: "The app's own text.") {
                    languagePicker(languageBinding(\.interfaceLanguage))
                }
                .settingsRow()

                Hairline()

                SettingRow("Report language", help: "What Bulava writes its reports in.") {
                    languagePicker(languageBinding(\.reportLanguage))
                }
                .settingsRow()

                Hairline()

                SettingRow("Dictation language",
                           help: "What you SPEAK. Its own setting: an app displayed in English is not a claim about the language you dictate in, and a wrong guess does not fail — it returns fluent nonsense.") {
                    Picker("", selection: liveBinding(\.dictationLanguage)) {
                        ForEach(DictationLanguage.allCases) { choice in
                            Text(LocalizedStringKey(choice.label)).tag(choice)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 190)
                }
                .settingsRow()

                Hairline()

                SettingRow("Report written by",
                           help: "Who composes the final report. Codex read the work independently; Claude did it.") {
                    Picker("", selection: liveBinding(\.reportWriter)) {
                        ForEach(ReportWriter.allCases) { w in
                            Text(w.label).tag(w)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 260)
                }
                .settingsRow()
            }
        }
    }

    private func languagePicker(_ selection: Binding<AppLanguage>) -> some View {
        Picker("", selection: selection) {
            ForEach(AppLanguage.allCases) { language in
                Text(LocalizedStringKey(language.label)).tag(language)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 152)
    }

    // MARK: - Learning about the work

    private var learningSection: some View {
        SettingsSection("Learning about the work") {
            VStack(spacing: 0) {
                toggleRow("Dev Learning Mode",
                          help: "Puts an “Explain what happened” button on a finished result. One read-only request per press — it changes nothing, does not take the worker’s session, and never runs on its own.",
                          isOn: liveBinding(\.devLearningEnabled))
                    .settingsRow()
                    .accessibilityIdentifier("learning.mode")

                // Only once the mode is on. The switch answers one question — are explanations
                // offered — and a field for the audience underneath an off switch would make its
                // position unreadable.
                if model.settings.devLearningEnabled {
                    Hairline()
                    profileField
                        .settingsRow()
                }
            }
            .animation(Motion.expand, value: model.settings.devLearningEnabled)
        }
    }

    /// Free text, not a list of roles. The one thing worth knowing about the reader is the thing
    /// a list of presets leaves out.
    private var profileField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Who you are")
                .font(Typo.panelRow)
                .foregroundStyle(Palette.text)
            TextField("iOS developer, Swift. Not much backend.", text: boundedProfile)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: Metrics.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                        .fill(Palette.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                        .strokeBorder(Palette.lineStrong, lineWidth: Metrics.hairline)
                )
                .accessibilityIdentifier("learning.profile")
            Text("Optional. Empty, and an explanation is written in plain words. Filled in, it is written through what you already know — a Python backend put in terms of iOS, say. Bulava never guesses this, and the worker doing the work never sees it.")
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Cut to the length the prompt will actually use, as it is typed — so what is on screen is
    /// what an explanation is written for.
    private var boundedProfile: Binding<String> {
        Binding(get: { draft.learningProfile },
                set: { draft.learningProfile = String($0.prefix(LearningProfile.limit)) })
    }

    // MARK: - What the work runs on

    private var engineSection: some View {
        SettingsSection("What the work runs on") {
            VStack(spacing: 0) {
                SettingRow("Worker model",
                           help: "Read from the Claude CLI's own catalogue. A family follows the newest release of itself; a fixed version stays where it is.") {
                    ClaudeModelMenu(width: 190)
                }
                .settingsRow()

                Hairline()

                SettingRow("How deeply the worker thinks",
                           help: LocalizedStringKey(model.settings.claudeEffort.help)) {
                    Picker("", selection: liveBinding(\.claudeEffort)) {
                        // Only the depths this model takes. Haiku has none at all, and the older
                        // versions differ from each other.
                        ForEach(model.claudeModels.levels(for: model.settings.claudeModel)) { choice in
                            Text(verbatim: model.claudeModels.workerDepthLabel(choice,
                                                                               for: model.settings.claudeModel))
                                .tag(choice)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 190)
                    .disabled(!model.claudeModels.thinks(model.settings.claudeModel))
                    .accessibilityIdentifier("claude.depth")
                }
                .settingsRow()

                Hairline()

                SettingRow("Reviewer model",
                           help: "Read from the Codex CLI's own catalogue, so a new model appears here on its own. Automatic = the CLI's default.") {
                    Picker("", selection: Binding(get: { model.settings.codexModel },
                                                  set: { model.chooseCodexModel($0) })) {
                        Text("Automatic").tag("")
                        ForEach(model.codexModels.models) { candidate in
                            Text(verbatim: candidate.shortLabel).tag(candidate.slug)
                        }
                        // A model chosen on an older build, or on a machine whose catalogue has
                        // not been written yet, still has to be shown as the current value —
                        // otherwise the picker silently reads "Automatic" while sending it.
                        if !model.settings.codexModel.isEmpty,
                           model.codexModels.model(slug: model.settings.codexModel) == nil {
                            Text(verbatim: model.settings.codexModel).tag(model.settings.codexModel)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 190)
                }
                .settingsRow()

                Hairline()

                SettingRow("How deeply the reviewer thinks",
                           help: "The reviewer is what refuses work that is not right. Lower settings save quota and refuse less.") {
                    Picker("", selection: liveBinding(\.codexEffort)) {
                        // Only the depths the chosen model accepts: the CLI rejects its config for
                        // one that does not take them, and the run dies on it.
                        ForEach(model.codexModels.levels(forSlug: model.settings.codexModel)) { choice in
                            Text(verbatim: choice.menuLabel).tag(choice)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 190)
                }
                .settingsRow()

                Hairline()

                toggleRow("Workers may drive apps through Bulava",
                          help: "A worker holds no macOS permission of its own, so Bulava clicks and types on its behalf — one Accessibility grant, given to Bulava once, instead of one per project. Every action is written to ui-actions.log beside the state directory. System Settings, Keychain and terminals are refused whatever it asks.",
                          isOn: liveBinding(\.workersMayDriveApps))
                    .settingsRow()

                Hairline()

                // OUT with the mode switch. Claude stood in for Codex on the one path where
                // Codex answers a message by itself, and that mode is not offered at the moment —
                // so the switch would promise something nothing can do. It comes back together
                // with "Codex only"; the setting itself is untouched and still saved.
                //
                // toggleRow("Claude stands in when Codex runs out",
                //           help: "Codex's weekly window is the one that actually runs out. When it has, the message is answered by Claude and the thread says so — instead of coming back as an error.",
                //           isOn: liveBinding(\.claudeStandsInForCodex))
                //     .settingsRow()
                //
                // Hairline()

                SettingRow("Next run", help: nil) {
                    Text(nextRunSummary)
                        .font(Typo.mono(10.5))
                        .foregroundStyle(Palette.textFaint)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 268, alignment: .trailing)
                        .accessibilityIdentifier("next.run")
                }
                .settingsRow()
            }
        }
    }

    private var nextRunSummary: String {
        let s = RunStrategy.standing.overridden(by: model.settings, claudeModels: model.claudeModels)
        let noDepth = s.claudeEffort.isEmpty || s.claudeEffort == ClaudeModelCatalog.noDepth
        var parts: [String] = [noDepth ? "claude" : "claude --effort \(s.claudeEffort)"]
        if !s.claudeModel.isEmpty { parts[0] += " --model \(s.claudeModel)" }
        var codex = "codex -c model_reasoning_effort=\(s.codexEffort)"
        if !s.codexModel.isEmpty { codex += " -m \(s.codexModel)" }
        parts.append(codex)
        if model.settings.claudeEffort == .auto, !noDepth {
            parts[0] += " · " + String(localized: "(per task)")
        }
        return parts.joined(separator: "\n")
    }

    private func liveBinding<V>(_ keyPath: WritableKeyPath<AppSettings, V>) -> Binding<V> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { model.settings[keyPath: keyPath] = $0 })
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        SettingsSection("Diagnostics", trailing: {
            Button { checkTools() } label: { Text(checking ? "Checking…" : "Check again") }
                .buttonStyle(.bulava(.quiet))
                .disabled(checking)
        }) {
            VStack(alignment: .leading, spacing: 13) {
                toolDoctor
                Hairline()
                connectionTest
                Hairline()
                toggleRow("Fix what stops a message by itself",
                          help: "When a message cannot go because something broke, Codex looks for the cause in that project's folder, fixes it there and Bulava sends the message again. It can change files only in that folder and in Bulava's notes about it, never the app or its engine. Off, the same repair waits for a button.",
                          isOn: liveBinding(\.autoRepair))
                Hairline()
                toggleRow("Send anonymous error reports",
                          help: "What broke and how the repair went: Bulava's own error code, the message with every name, path, address and key taken out, and the app, engine and macOS versions. No project, file, chat or account. Turning it off drops reports that have not gone yet.",
                          isOn: Binding(get: { model.settings.shareErrorReports },
                                        set: { on in
                                            model.settings.shareErrorReports = on
                                            model.flushIncidentReports()
                                        }))
            }
            .padding(Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if tools.isEmpty { checkTools() } }
    }

    private var toolDoctor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tools.isEmpty {
                Text("Run a check to confirm night-shift, night-queue, tmux, git, codex and claude are on PATH.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 8)],
                          alignment: .leading, spacing: 7) {
                    ForEach(tools) { tool in
                        HStack(spacing: 6) {
                            Image(systemName: tool.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(tool.ok ? Palette.green : Palette.red)
                            Text(verbatim: tool.name)
                                .font(Typo.mono(11))
                                .foregroundStyle(tool.ok ? Palette.textSecondary : Palette.text)
                        }
                    }
                }
                if tools.contains(where: { !$0.ok }) {
                    Text("A missing tool means PATH is not finding it — often because a broken install shadows the real binary.")
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var connectionTest: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button { runTest() } label: {
                    Label {
                        Text(testing ? "Testing…" : "Test connection")
                    } icon: {
                        Image(systemName: "bolt.horizontal")
                    }
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bulava())
                .disabled(testing)

                Text("Runs night-shift status and shows exactly what it printed.")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !testOutput.isEmpty {
                Text(verbatim: testOutput)
                    .font(Typo.mono(10.5))
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                            .fill(Palette.field)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                            .strokeBorder(Palette.line, lineWidth: Metrics.hairline)
                    )
            }
        }
    }

    // MARK: - The week and its widgets

    private var weekSection: some View {
        SettingsSection("The week and its widgets") {
            VStack(alignment: .leading, spacing: 13) {
                toggleRow("Count the week for the widgets",
                          help: "Hours without you, how runs ended, the receipt, the rhythm and code changes, counted on this Mac from Claude Code's, Codex's and Bulava's own files for the widgets. Off, nothing is counted and the widgets say so; the limits still show.",
                          isOn: Binding(get: { model.settings.weeklyStats },
                                        set: { on in
                                            model.settings.weeklyStats = on
                                            model.weeklyStatsChanged()
                                        }))
                Hairline()
                toggleRow("Send Bulava's author a weekly summary",
                          help: "Once a week, ranges rather than numbers: how many runs and agent-hours, the share review accepted, on how many days agents worked, whether the night shift, Codex, a phone, automations and which widgets were used, with the app's version, macOS and the interface language. No code, names, folders, paths, prompts, chat text, times or anything that identifies you or this Mac. It helps decide what to build next.",
                          isOn: liveBinding(\.shareUsage))
                usagePreview
            }
            .padding(Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var usagePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.standard) { usagePreviewOpen.toggle() }
            } label: {
                Label(usagePreviewOpen ? "Hide" : "What this week's summary holds",
                      systemImage: usagePreviewOpen ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.bulava(.quiet))
            if usagePreviewOpen {
                if let report = model.usageReportPreview(),
                   let data = try? { () -> Data in
                       let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(report)
                   }(), let text = String(data: data, encoding: .utf8) {
                    Text(verbatim: text)
                        .font(Typo.mono(10.5))
                        .foregroundStyle(Palette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous).fill(Palette.field))
                    Text("This is the week so far; the one that is sent describes a whole week, after it ends. Which widgets are on the desktop is filled in when it is sent.")
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The week has not been counted yet.")
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textFaint)
                }
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        PanelCard {
            DisclosureGroup(isExpanded: $advancedOpen) {
                advancedBody
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced")
                        .font(Typo.panelRow)
                        .foregroundStyle(Palette.text)
                    Text("Bulava normally decides all of this itself. Open it only when something is broken.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .padding(Metrics.cardPadding)
            .animation(Motion.expand, value: advancedOpen)
        }
    }

    private var advancedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            pathField("State directory",
                      help: "Where the engine writes usage, instances and the queue.",
                      placeholder: "~/.claude/supervisor",
                      text: $draft.stateDirPath) { pickDirectory { draft.stateDirPath = $0 } }

            pathField("Engine home",
                      help: "The orchestration checkout — read for lessons and standards. Optional.",
                      placeholder: "Detected automatically",
                      text: Binding(get: { draft.orchestratorHomePath ?? "" },
                                    set: { draft.orchestratorHomePath = $0.isEmpty ? nil : $0 })) {
                pickDirectory { draft.orchestratorHomePath = $0 }
            }

            Hairline()

            SettingRow("Refresh interval", help: "How often live state is polled.") {
                Stepper(value: $draft.pollSeconds, in: 2...30, step: 1) {
                    Text("\(Int(draft.pollSeconds))s")
                        .font(Typo.mono(11.5))
                        .foregroundStyle(Palette.textSecondary)
                }
                .fixedSize()
            }

            Hairline()

            toggleRow("Answer workers' questions myself",
                      help: "Codex reads a worker's question first and answers what it can. What only you can decide waits for you. When this is off, the worker takes the safe default right away.",
                      isOn: $draft.askUserEnabled)

            if draft.askUserEnabled {
                SettingRow("Wait for my answer",
                           help: "How long such a question waits for you. Then the worker takes the safe default; what only you may decide is left undone, and the run says what would unblock it.") {
                    Stepper(value: $draft.askUserWaitMinutes, in: 5...240, step: 5) {
                        Text("\(draft.askUserWaitMinutes) min")
                            .font(Typo.mono(11.5))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .fixedSize()
                }
            }

            Hairline()

            toggleRow("Keep the Mac awake while work runs",
                      help: "While work can go on without you, the Mac does not fall asleep on its own. It is let go the moment everything waits for you or is done. A closed lid or a flat battery still stops it.",
                      isOn: $draft.keepAwakeWhileWorking)

            Hairline()

            toggleRow("Links to the phone",
                      help: "Sites, pages, notes and files an agent shares, or that you open from a chat, open on your phone over this Wi-Fi only. A link opens only what it was made for. Off, nothing answers.",
                      isOn: $draft.shareLinksEnabled)
            if !model.shares.store.links.isEmpty {
                SharedLinksList(shares: model.shares)
            }

            Hairline()

            toggleRow("Bulava's browser",
                      help: "Runs work in a Chrome of Bulava's own: you sign in to sites there once, and runs use them without asking you, one run at a time. Runs that need no sign-in get a throwaway browser. Off, runs use the browser your own Claude setup gives them.",
                      isOn: $draft.accountBrowserEnabled)
            if draft.accountBrowserEnabled {
                AccountBrowserSection(browser: model.browser)
            }
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pathField(_ title: LocalizedStringKey,
                           help: LocalizedStringKey,
                           placeholder: LocalizedStringKey,
                           text: Binding<String>,
                           choose: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Typo.panelRow)
                .foregroundStyle(Palette.text)
            HStack(spacing: 8) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(Typo.mono(11))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: Metrics.controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                            .fill(Palette.field)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                            .strokeBorder(Palette.lineStrong, lineWidth: Metrics.hairline)
                    )
                Button { choose() } label: { Text("Choose…") }
                    .buttonStyle(.bulava())
            }
            Text(help)
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleRow(_ title: LocalizedStringKey,
                           help: LocalizedStringKey,
                           isOn: Binding<Bool>) -> some View {
        SettingRow(title, help: help) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Palette.accent)
        }
    }

    // MARK: - Save bar

    private var merged: AppSettings {
        var settings = draft
        settings.appearance = model.settings.appearance
        settings.interfaceLanguage = model.settings.interfaceLanguage
        settings.reportLanguage = model.settings.reportLanguage
        settings.dictationLanguage = model.settings.dictationLanguage
        settings.reportWriter = model.settings.reportWriter

        settings.claudeModel = model.settings.claudeModel
        settings.claudeEffort = model.settings.claudeEffort
        settings.codexModel = model.settings.codexModel
        settings.codexEffort = model.settings.codexEffort
        settings.claudeStandsInForCodex = model.settings.claudeStandsInForCodex
        settings.workersMayDriveApps = model.settings.workersMayDriveApps
        settings.autoRepair = model.settings.autoRepair
        settings.shareErrorReports = model.settings.shareErrorReports
        settings.weeklyStats = model.settings.weeklyStats
        settings.shareUsage = model.settings.shareUsage
        settings.usageSince = model.settings.usageSince
        settings.usageReportedWeek = model.settings.usageReportedWeek
        // The switch is live, like every other switch here. The profile is NOT: it is typed, and
        // a live binding on a text field would write the whole settings file — and re-publish the
        // engine's configuration — once per keystroke. It goes through draft and Save.
        settings.devLearningEnabled = model.settings.devLearningEnabled
        return settings
    }

    private var dirty: Bool { merged != model.settings }

    private var saveBar: some View {
        HStack(spacing: 8) {
            Text("Unsaved advanced changes")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 8)
            Button { draft = model.settings } label: { Text("Revert") }
                .buttonStyle(.bulava(.quiet))
            Button { save() } label: { Text("Save") }
                .buttonStyle(.bulava(.primary))
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Palette.chrome)
    }

    // MARK: - About

    private var about: some View {
        HStack(spacing: 5) {
            Text(verbatim: "bulava")
                .font(Typo.meta)
                .foregroundStyle(Palette.textTertiary)
            Text(verbatim: "·")
                .font(Typo.meta)
                .foregroundStyle(Palette.textFaint)
            Text("Version \(appVersion)")
                .font(Typo.meta)
                .foregroundStyle(Palette.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // MARK: - Actions

    private func save() {
        model.settings = merged
        draft = model.settings
        model.toast = ToastMessage(text: String(localized: "Settings saved"), kind: .success)
    }

    private func pickDirectory(_ completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
    }

    private func runTest() {
        testing = true
        testOutput = String(localized: "Running night-shift status…")
        _Concurrency.Task {
            let result = await Shell.run("night-shift status 2>&1", timeout: 25)
            testOutput = result.combined.isEmpty
                ? String(localized: "No output (is the engine installed?)")
                : result.combined
            testing = false
        }
    }

    private func checkTools() {
        checking = true
        _Concurrency.Task {
            let names = ["night-shift", "night-queue", "tmux", "git", "codex", "claude"]
            let script = "for t in \"$@\"; do command -v \"$t\" >/dev/null 2>&1 && echo \"$t=1\" || echo \"$t=0\"; done"
            let result = await Shell.run(script, args: names, timeout: 20)
            var found: [ToolStatus] = []
            for line in result.stdout.split(separator: "\n") {
                let parts = line.split(separator: "=")
                if parts.count == 2 {
                    found.append(ToolStatus(name: String(parts[0]), ok: parts[1] == "1"))
                }
            }
            tools = found.isEmpty ? names.map { ToolStatus(name: $0, ok: false) } : found
            checking = false
        }
    }
}

// MARK: - Tool status

private struct ToolStatus: Identifiable, Equatable {
    var name: String
    var ok: Bool
    var id: String { name }
}

// MARK: - Section

private struct SettingsSection<Trailing: View, Content: View>: View {
    private let title: LocalizedStringKey
    private let trailing: Trailing
    private let content: Content

    init(_ title: LocalizedStringKey,
         @ViewBuilder content: () -> Content) where Trailing == EmptyView {
        self.title = title
        self.trailing = EmptyView()
        self.content = content()
    }

    init(_ title: LocalizedStringKey,
         @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Eyebrow(title)
                    Spacer(minLength: 6)
                    trailing
                }
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.top, 10)
                .padding(.bottom, 9)

                Hairline()
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Row

private struct SettingRow<Trailing: View>: View {
    private let title: LocalizedStringKey
    private let help: LocalizedStringKey?
    private let trailing: Trailing

    init(_ title: LocalizedStringKey,
         help: LocalizedStringKey? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.help = help
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.text)
                if let help {
                    Text(help)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {

    func settingsRow() -> some View {
        padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 11)
    }
}
