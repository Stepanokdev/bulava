import AppKit
import SwiftUI

enum AutomationEditorRequest: Identifiable {
    case new(productID: UUID?, template: AutomationTemplate?)
    case edit(UUID)
    /// A conversation he wants to happen again by itself: its first request becomes the brief.
    case fromChat(UUID)

    var id: String {
        switch self {
        case .new(let p, let t): "new-\(p?.uuidString ?? "-")-\(t?.id ?? "blank")"
        case .edit(let id): "edit-\(id.uuidString)"
        case .fromChat(let id): "chat-\(id.uuidString)"
        }
    }
}

/// The form an automation is made in — When, then What — and the gallery that fills it.
///
/// Trigger first, the way Shortcuts and Zapier put it: "When this happens, do that." The next three
/// runs are shown under a schedule as it is being set, so a wrong time is seen before the night.
struct AutomationEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AutomationEditorRequest

    @State private var draft = AutomationDraft()
    @State private var choosingTemplate = false
    /// The gallery was opened from a form already under way: leaving it goes back to that form.
    @State private var galleryOverForm = false
    @State private var loaded = false
    @FocusState private var focus: Field?
    /// Where the cursor goes when the form shows: the field a chosen template still needs.
    @State private var focusWhenShown: Field = .name
    /// Access the trigger needs and has not been given yet (`AutomationNeedsSection`).
    @State private var needsBlocking = false

    enum Field: Hashable { case name, repoPath, feedURL, hfAuthor, pageURL, mailFrom, watchFolder }

    private var isNew: Bool { if case .edit = request { return false }; return true }

    /// Addresses, not words: shown as they are in every language.
    private static let feedPrompt: String = "https://github.com/owner/repo/releases.atom"
    private static let pagePrompt: String = "https://"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New automation" : "Edit automation")
                    .cardTitleStyle()
                    .foregroundStyle(Palette.text)
                Spacer()
                if isNew, !choosingTemplate {
                    Button("Templates") {
                        galleryOverForm = true
                        withAnimation(Motion.standard) { choosingTemplate = true }
                    }
                        .buttonStyle(.bulava(.quiet))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Hairline()
            if choosingTemplate {
                ScrollView {
                    AutomationTemplateGrid { template in
                        draft.apply(template)
                        focusWhenShown = draft.missingSetupField ?? .name
                        withAnimation(Motion.standard) { choosingTemplate = false }
                    }
                    .padding(18)
                }
                Hairline()
                HStack(spacing: 10) {
                    Text("Every template can be changed once it is chosen.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textFaint)
                    Spacer(minLength: 8)
                    if galleryOverForm {
                        // Escape here puts the gallery away; it does not throw the form away with it.
                        Button("Back to the form") { withAnimation(Motion.standard) { choosingTemplate = false } }
                            .buttonStyle(.bulava(.quiet))
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button("Cancel") { dismiss() }
                            .buttonStyle(.bulava(.quiet))
                            .keyboardShortcut(.cancelAction)
                    }
                    Button("Start from scratch") {
                        draft.clear()
                        focusWhenShown = .name
                        withAnimation(Motion.standard) { choosingTemplate = false }
                    }
                    .buttonStyle(.bulava(.secondary))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            } else {
                // The form is laid out INSIDE the sheet's width. A row wider than the sheet used to
                // centre the whole form and cut it off on both sides — the work-mode switch alone is
                // wider than the sheet in Ukrainian.
                ScrollView { form.padding(18).frame(maxWidth: .infinity, alignment: .leading) }
                    .task {
                        // After the sheet or the gallery has finished arriving; set at once, the
                        // first text field takes the cursor back.
                        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                        focus = focusWhenShown
                    }
                Hairline()
                footer
            }
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560, idealHeight: 700)
        .background(Palette.content)
        .onAppear(perform: load)
        .task(id: draft.projectID) {
            draft.folderIsRepository = nil
            draft.localFiles = []
            draft.knownTools = AutomationTools.known(projectPaths: folders.map(\.path))
            draft.suggestTools()
            guard let id = draft.projectID, let project = model.projects.project(id: id) else { return }
            let isRepository = await WorkCopies.topLevel(of: project.path) != nil
            let local = await WorkCopies.localConfigFiles(in: project.path)
            // An answer about a folder he has since moved away from is not an answer.
            guard !Task.isCancelled, draft.projectID == id else { return }
            draft.folderIsRepository = isRepository
            draft.found(localFiles: local, isNew: isNew)
        }
        .task(id: draft.repoPath) {
            draft.watchedIsRepository = nil
            let path = draft.repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let isRepository = await WorkCopies.topLevel(of: path) != nil
            guard !Task.isCancelled, draft.repoPath.trimmingCharacters(in: .whitespacesAndNewlines) == path else { return }
            draft.watchedIsRepository = isRepository
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch request {
        case .new(let productID, let template):
            draft.productID = productID ?? model.products.sorted.first?.id
            draft.projectID = draft.productID.flatMap { model.products.product(id: $0)?.defaultProjectID }
            if let template {
                draft.apply(template)
                focusWhenShown = draft.missingSetupField ?? .name
            } else {
                choosingTemplate = true
            }
        case .edit(let id):
            if let automation = model.automations.automation(id: id) { draft = AutomationDraft(automation) }
        case .fromChat(let chatID):
            guard let chat = model.conversations.chat(id: chatID) else { return }
            draft.productID = chat.productID
            draft.projectID = chat.session?.primaryProjectID
                ?? model.products.product(id: chat.productID)?.defaultProjectID
            draft.name = chat.title
            let asked = model.conversations.entries(inChat: chatID).first(where: { $0.kind == .user })?.text
            draft.brief = (asked ?? chat.firstMessage).trimmingCharacters(in: .whitespacesAndNewlines)
            draft.when = .schedule
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Name") {
                TextField("What to call it", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name)
            }
            section("Where") {
                // A product and its folder are often called the same, so each says which it is.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { productPicker; folderPicker }
                    VStack(alignment: .leading, spacing: 8) { productPicker; folderPicker }
                }
                // A job has no branch: it does not start from the code.
                if draft.workMode != .job {
                    HStack(spacing: 8) {
                        Text("Start each run from branch").font(Typo.caption).foregroundStyle(Palette.textTertiary)
                        TextField("default branch", text: $draft.baseBranch)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                }
            }
            AutomationWorkSection(draft: $draft)
            AutomationPipelineSection(pipelineID: $draft.pipelineID)
            section("When") {
                FittingPicker(selection: $draft.when) {
                    Text("On a schedule").tag(AutomationDraft.When.schedule)
                    Text("Something changes").tag(AutomationDraft.When.watch)
                    Text("On this Mac").tag(AutomationDraft.When.event)
                    Text("By hand").tag(AutomationDraft.When.manual)
                }
                switch draft.when {
                case .schedule: scheduleFields
                case .watch: watchFields
                case .event: eventFields
                case .manual:
                    hint("It runs only when you press Run now.")
                }
            }
            section("What to do") {
                TextEditor(text: $draft.brief)
                    .font(Typo.message)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 130)
                    .background(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).strokeBorder(Palette.lineStrong, lineWidth: 1))
                hint("Written the way you would ask in a chat. Each run gets this, what started it, and what earlier runs found — never the conversation of an earlier run.")
            }
            .onChange(of: draft.brief) { _, _ in draft.suggestTools() }
            AutomationNeedsSection(trigger: draft.trigger, brief: draft.brief,
                                   readFolders: draft.workMode == .job ? draft.readFolders : [],
                                   blocking: $needsBlocking)
            Toggle("Ask me before each run", isOn: $draft.confirmFirst)
                .toggleStyle(.checkbox)
                .font(Typo.body)
        }
    }

    private var productPicker: some View {
        HStack(spacing: 6) {
            Text("Product").font(Typo.caption).foregroundStyle(Palette.textTertiary)
            Picker("Product", selection: $draft.productID) {
                ForEach(model.products.sorted) { p in Text(verbatim: p.name).tag(UUID?.some(p.id)) }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: draft.productID) { _, id in
                draft.projectID = id.flatMap { model.products.product(id: $0)?.defaultProjectID }
            }
        }
    }

    private var folderPicker: some View {
        HStack(spacing: 6) {
            Text("Folder").font(Typo.caption).foregroundStyle(Palette.textTertiary)
            Picker("Folder", selection: $draft.projectID) {
                ForEach(folders, id: \.id) { project in
                    Text(verbatim: project.name).tag(UUID?.some(project.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var folders: [Project] {
        guard let product = draft.productID.flatMap({ model.products.product(id: $0) }) else { return [] }
        return product.allProjectIDs.compactMap { model.projects.project(id: $0) }
    }

    // MARK: When — a schedule

    private var scheduleFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $draft.cadence) {
                    Text("Every day").tag(AutomationDraft.Cadence.daily)
                    Text("Weekdays").tag(AutomationDraft.Cadence.weekdays)
                    Text("Every week").tag(AutomationDraft.Cadence.weekly)
                    Text("Every two weeks").tag(AutomationDraft.Cadence.biweekly)
                    Text("Every month").tag(AutomationDraft.Cadence.monthly)
                    Text("Every few hours").tag(AutomationDraft.Cadence.hourly)
                }
                .labelsHidden()
                .frame(width: 180, alignment: .leading)
                if draft.cadence == .hourly {
                    Stepper(value: $draft.everyHours, in: 1...12) {
                        Text(verbatim: Fmt.count("every %lld h", draft.everyHours))
                            .font(Typo.body).monospacedDigit()
                    }
                } else {
                    Text("at").font(Typo.body).foregroundStyle(Palette.textTertiary)
                    DatePicker("", selection: $draft.time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                if draft.cadence == .monthly {
                    Text("on day").font(Typo.body).foregroundStyle(Palette.textTertiary)
                    Stepper(value: $draft.monthDay, in: 1...31) {
                        Text(verbatim: "\(draft.monthDay)").font(Typo.body).monospacedDigit()
                    }
                }
            }
            if draft.cadence == .weekly || draft.cadence == .biweekly {
                HStack(spacing: 4) {
                    ForEach(AutomationPresentation.weekOrder, id: \.self) { day in
                        let on = draft.cadence == .weekly ? draft.weekdays.contains(day) : draft.biweeklyDay == day
                        Button(AutomationPresentation.shortDayName(day)) {
                            if draft.cadence == .weekly {
                                if on, draft.weekdays.count > 1 { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                            } else {
                                draft.biweeklyDay = day
                            }
                        }
                        .buttonStyle(DayChipStyle(on: on))
                        .accessibilityLabel(Text(verbatim: AutomationPresentation.dayName(day)))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            Toggle("Wait until I step away from the Mac", isOn: $draft.waitUntilAway)
                .toggleStyle(.checkbox)
                .font(Typo.body)
            if let schedule = draft.schedule {
                let next = AutomationClock.next(schedule, after: Date(), count: 3)
                if !next.isEmpty {
                    plainHint(String(format: String(localized: "Next: %@"), next.map { Fmt.stamp($0) }.joined(separator: " · ")))
                }
            }
        }
    }

    // MARK: When — something changes

    private var watchFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $draft.watchKind) {
                Text("New commits in a repository").tag(AutomationDraft.WatchKind.commits)
                Text("New entries in a feed (RSS, Atom, GitHub releases)").tag(AutomationDraft.WatchKind.feed)
                Text("New models on Hugging Face").tag(AutomationDraft.WatchKind.huggingFace)
                Text("A web page changes").tag(AutomationDraft.WatchKind.webPage)
            }
            .labelsHidden()
            switch draft.watchKind {
            case .commits:
                folderField("Repository", path: $draft.repoPath, focusedAs: .repoPath)
                TextField("Branch — empty for its default", text: $draft.watchBranch).textFieldStyle(.roundedBorder)
                hint("Fetched from its remote each time. The first look only learns where the branch is; the commits after that are what a run is given.")
            case .feed:
                TextField(Self.feedPrompt, text: $draft.feedURL).textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .feedURL)
            case .huggingFace:
                HStack(spacing: 8) {
                    TextField("Author, e.g. mlx-community", text: $draft.hfAuthor).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .hfAuthor)
                    TextField("Search — optional", text: $draft.hfSearch).textFieldStyle(.roundedBorder)
                }
            case .webPage:
                TextField(Self.pagePrompt, text: $draft.pageURL).textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .pageURL)
                hint("Only the words on the page count; markup that changes on every load does not.")
            }
            HStack(spacing: 8) {
                Text("Look").font(Typo.body).foregroundStyle(Palette.textTertiary)
                Picker("", selection: $draft.everyMinutes) {
                    ForEach(AutomationWatch.intervals, id: \.self) { minutes in
                        Text(verbatim: AutomationPresentation.intervalWord(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .frame(width: 160, alignment: .leading)
            }
        }
    }

    // MARK: When — on this Mac

    private var eventFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $draft.eventKind) {
                Text("A new letter in Mail").tag(AutomationDraft.EventKind.mail)
                Text("A new file in a folder").tag(AutomationDraft.EventKind.folder)
                Text("A meeting in the calendar ends").tag(AutomationDraft.EventKind.meeting)
            }
            .labelsHidden()
            switch draft.eventKind {
            case .mail:
                HStack(spacing: 8) {
                    TextField("From contains", text: $draft.mailFrom).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .mailFrom)
                    TextField("Subject contains", text: $draft.mailSubject).textFieldStyle(.roundedBorder)
                }
                hint("Read from Mail on this Mac — any account you have there. Mail has to be open. The text of a letter is given to the run as data, never as instructions.")
            case .folder:
                folderField("Folder", path: $draft.watchFolder, focusedAs: .watchFolder)
                hint("Files that arrive close together become one run.")
            case .meeting:
                TextField("Title contains — empty for every meeting", text: $draft.meetingTitle).textFieldStyle(.roundedBorder)
                hint("Two minutes after the meeting's scheduled end. Bulava knows its title and time, not what was said in it — say in the brief where its notes or recording are. Bulava asks for the calendar the first time.")
            }
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title)
            content()
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Typo.caption)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Words already put together at run time — the next three runs — shown as they are.
    private func plainHint(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Typo.caption)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func folderField(_ label: LocalizedStringKey, path: Binding<String>, focusedAs field: Field) -> some View {
        HStack(spacing: 8) {
            TextField(label, text: path).textFieldStyle(.roundedBorder)
                .focused($focus, equals: field)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
            .buttonStyle(.bulava(.secondary))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let problem = problem {
                Text(verbatim: problem)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.orange)
                    .lineLimit(2)
            } else if draft.workMode == .checkOnly {
                Text("A check never changes your folder or your branches.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textFaint)
            } else if draft.workMode == .job {
                Text("Your folders are only read. Nothing is left to merge.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textFaint)
            } else {
                Text("Nothing reaches your branch until you merge it.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textFaint)
            }
            Spacer(minLength: 8)
            Button("Cancel") { dismiss() }
                .buttonStyle(.bulava(.quiet))
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Create" : "Save") { save() }
                .buttonStyle(.bulava(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// What stops it from being saved: the form's own problem, or access its trigger still needs.
    private var problem: String? {
        draft.problem ?? (needsBlocking
            ? String(localized: "Allow what is marked above first: without it this automation cannot start.")
            : nil)
    }

    private func save() {
        guard problem == nil, let built = draft.automation() else { return }
        switch request {
        case .new, .fromChat:
            model.createAutomation(built)
        case .edit(let id):
            model.editAutomation(id, to: built)
        }
        dismiss()
    }
}

/// What a run may do with the code, and the files from his folder it brings along — or, for a job
/// that is not about code, what it reads and which services it may use.
struct AutomationWorkSection: View {
    @Binding var draft: AutomationDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("What a run may do")
            FittingPicker(selection: $draft.workMode) {
                Text("Change code on a branch").tag(AutomationWorkMode.branch)
                Text("Only check and report").tag(AutomationWorkMode.checkOnly)
                Text("Do a job outside the code").tag(AutomationWorkMode.job)
            }
            switch draft.workMode {
            case .branch:
                hint("Each run works in this automation's own folder, on a new branch from the start branch. What it changes waits for you to merge or throw away.")
            case .checkOnly:
                hint("Each run reads, builds and tests the code in this automation's own folder and writes a report. Nothing is left to merge; whatever it changes is thrown away.")
            case .job:
                hint("For work that is not about code, like turning meeting notes into tasks. Each run works in a folder of its own, without git: there is nothing to review or merge, and your folders are only read.")
            }
            if draft.workMode == .job {
                jobFields
            } else {
                codeFields
            }
            reportToggle
        }
        .animation(Motion.standard, value: draft.workMode)
    }

    @ViewBuilder private var codeFields: some View {
        hint("The folder stays between runs, so the next build is quick. Your own folder is never touched.")
        // Files git ignores in his folder that a build tends to need. Brought fresh into every
        // run, or not at all — his choice, offered once they are found.
        if !draft.localFiles.isEmpty {
            Toggle(isOn: $draft.bringLocalFiles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bring my local files into each run").font(Typo.body)
                    Text(verbatim: draft.localFiles.joined(separator: ", "))
                        .font(Typo.mono(11))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.top, 4)
            hint("git ignores them, so a run has none of them unless they are brought in. They are copied fresh from your folder when each run starts.")
                .padding(.leading, 20)
        }
    }

    // MARK: A job

    @ViewBuilder private var jobFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Folders it reads").font(Typo.rowLabel).foregroundStyle(Palette.text)
            ForEach(draft.readFolders, id: \.self) { path in
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
                    Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                        .font(Typo.mono(11))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Button { draft.readFolders.removeAll { $0 == path } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.icon(size: 18, glyph: 8))
                        .help(Text("Remove this folder"))
                        .accessibilityLabel(Text("Remove"))
                }
            }
            Button("Add a folder…") { addFolder() }
                .buttonStyle(.bulava(.secondary))
            hint("It can always read the product's own folders. Add any others it needs, like the folder your meeting notes land in.")
        }
        .padding(.top, 4)
        VStack(alignment: .leading, spacing: 6) {
            Text("Services it may use without asking").font(Typo.rowLabel).foregroundStyle(Palette.text)
            if draft.knownTools.isEmpty {
                hint("No MCP servers are set up in Claude Code on this Mac. A run can still read and write files, but it cannot reach any service.")
            } else {
                WrappingHStack(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(draft.knownTools) { tool in
                        let on = draft.allowedTools.contains(tool.rule)
                        Button { draft.toggleTool(tool.rule) } label: {
                            Text(verbatim: tool.name).padding(.horizontal, 9)
                        }
                        .buttonStyle(DayChipStyle(on: on))
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                hint("A run uses these without asking anyone, so pick only what the job needs. Any other tool that would need your approval is declined.")
            }
        }
        .padding(.top, 4)
    }

    private var reportToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Write a report after a run that did something", isOn: Binding(
                get: { draft.reportsAfterRun },
                set: { draft.writesReport = $0 }))
                .toggleStyle(.checkbox)
                .font(Typo.body)
            hint(draft.reportsAfterRun
                 ? "After such a run Bulava asks it for a written report and lets you know it finished."
                 : "A run that went well stays quiet: what it did is one line in its chat. Failures and questions always reach you.")
                .padding(.leading, 20)
        }
        .padding(.top, 4)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !draft.readFolders.contains(url.path) { draft.readFolders.append(url.path) }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Typo.caption)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DayChipStyle: ButtonStyle {
    var on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.control)
            .foregroundStyle(on ? Palette.onAccent : Palette.textSecondary)
            .frame(minWidth: 34, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .fill(on ? Palette.accent : Palette.panelMuted))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .strokeBorder(on ? .clear : Palette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Motion.hover, value: on)
    }
}

// MARK: - The form's state

struct AutomationDraft {
    enum When: Hashable { case schedule, watch, event, manual }
    enum Cadence: Hashable { case hourly, daily, weekdays, weekly, biweekly, monthly }
    enum WatchKind: Hashable { case commits, feed, huggingFace, webPage }
    enum EventKind: Hashable { case mail, folder, meeting }

    var name = ""
    var productID: UUID?
    var projectID: UUID?
    var brief = ""
    var baseBranch = ""
    var confirmFirst = false
    var workMode: AutomationWorkMode = .branch
    /// The pipeline its runs go through; nil is the one chats use by default.
    var pipelineID: String?
    /// A job's: folders it reads beyond the product's own.
    var readFolders: [String] = []
    /// A job's: the MCP servers it may use without asking, by their rule names.
    var allowedTools: Set<String> = []
    /// The servers set up in Claude Code that could be chosen (`AutomationTools.known`).
    var knownTools: [AutomationTools.Server] = []
    /// He has chosen the servers himself: the brief's words no longer pick any.
    var toolsTouched = false
    /// Nil follows the mode: a report for work on code, none for a job.
    var writesReport: Bool?
    /// Ignored files found in the chosen folder (`WorkCopies.localConfigFiles`), with any the
    /// automation already brings that are not there now.
    var localFiles: [String] = []
    var bringLocalFiles = false
    /// What the automation brought before this edit, kept when the folder is looked at again.
    var carriedBefore: [String] = []
    var templateID: String?
    /// What the last template filled in, to tell its text from his.
    var appliedName: String?
    var appliedBrief: String?

    var when: When = .schedule
    var cadence: Cadence = .weekly
    var everyHours = 6
    var weekdays: Set<Int> = [1]
    var biweeklyDay = 1
    var monthDay = 1
    var time: Date = Calendar.current.date(from: DateComponents(hour: 3, minute: 0)) ?? Date()
    var waitUntilAway = false
    var timeZoneID = TimeZone.current.identifier
    var biweeklyAnchor = Date()

    var watchKind: WatchKind = .commits
    var repoPath = ""
    var watchBranch = ""
    var feedURL = ""
    var hfAuthor = ""
    var hfSearch = ""
    var pageURL = ""
    var everyMinutes = 60

    var eventKind: EventKind = .mail
    var mailFrom = ""
    var mailSubject = ""
    var watchFolder = ""
    var meetingTitle = ""

    init() {}

    init(_ a: Automation) {
        name = a.name
        productID = a.productID
        projectID = a.projectID
        brief = a.brief
        baseBranch = a.baseBranch ?? ""
        confirmFirst = a.confirmFirst
        workMode = a.workMode ?? .branch
        pipelineID = a.pipelineID
        readFolders = a.readFolders ?? []
        allowedTools = Set(a.allowedTools ?? [])
        toolsTouched = true
        writesReport = a.writesReport
        carriedBefore = a.carryFiles ?? []
        localFiles = carriedBefore
        bringLocalFiles = !carriedBefore.isEmpty
        templateID = a.templateID
        load(a.trigger)
    }

    var reportsAfterRun: Bool { writesReport ?? (workMode != .job) }

    mutating func toggleTool(_ rule: String) {
        toolsTouched = true
        if allowedTools.contains(rule) { allowedTools.remove(rule) } else { allowedTools.insert(rule) }
    }

    /// A service the brief names — "add them to memex" — is offered ticked, until he picks for
    /// himself. Only for a job, and only what is set up on this Mac.
    mutating func suggestTools() {
        guard workMode == .job, !toolsTouched else { return }
        allowedTools = Set(AutomationTools.mentioned(in: brief, among: knownTools).map(\.rule))
    }

    /// What looking at the folder found. A new automation is offered them ticked; an existing one
    /// keeps the choice it was saved with.
    mutating func found(localFiles found: [String], isNew: Bool) {
        localFiles = Array(Set(found).union(carriedBefore)).sorted()
        if isNew, carriedBefore.isEmpty { bringLocalFiles = !localFiles.isEmpty }
    }

    /// Fill the form from a template. A name or a brief he has written himself is kept: a template
    /// replaces only what is empty or what the previous template put there.
    mutating func apply(_ template: AutomationTemplate) {
        if name.trimmed.isEmpty || name == appliedName { name = template.name }
        if brief.trimmed.isEmpty || brief == appliedBrief { brief = template.brief }
        appliedName = template.name
        appliedBrief = template.brief
        templateID = template.id
        load(template.trigger)
    }

    private mutating func load(_ trigger: AutomationTrigger) {
        switch trigger {
        case .manual:
            when = .manual
        case .schedule(let s):
            when = .schedule
            time = Calendar.current.date(from: DateComponents(hour: s.hour, minute: s.minute)) ?? time
            waitUntilAway = s.waitUntilAway
            timeZoneID = s.timeZoneID
            switch s.cadence {
            case .hourly(let n): cadence = .hourly; everyHours = n
            case .daily: cadence = .daily
            case .weekdays: cadence = .weekdays
            case .weekly(let days): cadence = .weekly; weekdays = Set(days)
            case .biweekly(let day, let anchor): cadence = .biweekly; biweeklyDay = day; biweeklyAnchor = anchor
            case .monthly(let day): cadence = .monthly; monthDay = day
            }
        case .watch(let w):
            when = .watch
            everyMinutes = w.everyMinutes
            switch w.source {
            case .commits(let repo, let branch): watchKind = .commits; repoPath = repo; watchBranch = branch ?? ""
            case .feed(let url): watchKind = .feed; feedURL = url
            case .huggingFace(let author, let search): watchKind = .huggingFace; hfAuthor = author; hfSearch = search ?? ""
            case .webPage(let url): watchKind = .webPage; pageURL = url
            }
        case .event(let e):
            when = .event
            switch e.kind {
            case .mail(let from, let subject): eventKind = .mail; mailFrom = from; mailSubject = subject
            case .folder(let path): eventKind = .folder; watchFolder = path
            case .meetingEnded(let title): eventKind = .meeting; meetingTitle = title
            }
        }
    }

    var schedule: AutomationSchedule? {
        guard when == .schedule else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let c: AutomationSchedule.Cadence
        switch cadence {
        case .hourly: c = .hourly(every: everyHours)
        case .daily: c = .daily
        case .weekdays: c = .weekdays
        case .weekly: c = .weekly(days: weekdays.sorted())
        case .biweekly: c = .biweekly(day: biweeklyDay, anchor: biweeklyAnchor)
        case .monthly: c = .monthly(day: monthDay)
        }
        return AutomationSchedule(cadence: c, hour: parts.hour ?? 3, minute: parts.minute ?? 0,
                                  timeZoneID: timeZoneID, waitUntilAway: waitUntilAway)
    }

    var trigger: AutomationTrigger {
        switch when {
        case .manual: return .manual
        case .schedule: return .schedule(schedule!)
        case .watch:
            let source: AutomationWatch.Source
            switch watchKind {
            case .commits: source = .commits(repoPath: repoPath.trimmed, branch: watchBranch.trimmed.isEmpty ? nil : watchBranch.trimmed)
            case .feed: source = .feed(url: feedURL.trimmed)
            case .huggingFace: source = .huggingFace(author: hfAuthor.trimmed, search: hfSearch.trimmed.isEmpty ? nil : hfSearch.trimmed)
            case .webPage: source = .webPage(url: pageURL.trimmed)
            }
            return .watch(AutomationWatch(source: source, everyMinutes: everyMinutes))
        case .event:
            switch eventKind {
            case .mail: return .event(AutomationEvent(kind: .mail(from: mailFrom.trimmed, subject: mailSubject.trimmed)))
            case .folder: return .event(AutomationEvent(kind: .folder(path: watchFolder.trimmed)))
            case .meeting: return .event(AutomationEvent(kind: .meetingEnded(titleContains: meetingTitle.trimmed)))
            }
        }
    }

    /// Found out by looking at the disk, not typed: whether the chosen folder is under git, and
    /// whether the repository a commit watch names is one.
    var folderIsRepository: Bool?
    var watchedIsRepository: Bool?

    /// What stops it from being saved, in words; nil when it can be.
    var problem: String? {
        if name.trimmed.isEmpty { return String(localized: "Give it a name.") }
        if productID == nil || projectID == nil { return String(localized: "Choose the product and the folder it works in.") }
        if brief.trimmed.isEmpty { return String(localized: "Say what it should do.") }
        // Every run on code works in a separate git copy of the folder, so a folder without git
        // would fail at its first run — said here, before anything is switched on. A job works in
        // a folder of its own and needs none.
        if folderIsRepository == false, workMode != .job {
            return String(localized: "This folder is not a git repository. Every run works in a separate git copy, so choose a folder under git.")
        }
        switch when {
        case .watch:
            switch watchKind {
            case .commits where repoPath.trimmed.isEmpty: return String(localized: "Choose the repository to watch.")
            case .commits where watchedIsRepository == false: return String(localized: "The folder to watch is not a git repository.")
            case .feed where !Self.isWebAddress(feedURL): return String(localized: "Give the feed's web address.")
            case .huggingFace where hfAuthor.trimmed.isEmpty: return String(localized: "Name the Hugging Face author to watch.")
            case .webPage where !Self.isWebAddress(pageURL): return String(localized: "Give the page's web address.")
            default: return nil
            }
        case .event where eventKind == .folder && watchFolder.trimmed.isEmpty:
            return String(localized: "Choose the folder to watch.")
        case .event where eventKind == .mail && mailFrom.trimmed.isEmpty && mailSubject.trimmed.isEmpty:
            // Every newsletter would otherwise start a run, each with its own copy of the repository.
            return String(localized: "Say whose letters, or which subject, should start it.")
        default:
            return nil
        }
    }

    /// An http or https address with a host — "https:" alone, or "httpfoo://x", is not one.
    static func isWebAddress(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty else { return false }
        return true
    }

    /// The field the trigger still needs filled in, if any — where the cursor goes after a template.
    var missingSetupField: AutomationEditor.Field? {
        switch when {
        case .watch:
            switch watchKind {
            case .commits where repoPath.trimmed.isEmpty: return .repoPath
            case .feed where !Self.isWebAddress(feedURL): return .feedURL
            case .huggingFace where hfAuthor.trimmed.isEmpty: return .hfAuthor
            case .webPage where !Self.isWebAddress(pageURL): return .pageURL
            default: return nil
            }
        case .event where eventKind == .mail && mailFrom.trimmed.isEmpty && mailSubject.trimmed.isEmpty:
            return .mailFrom
        case .event where eventKind == .folder && watchFolder.trimmed.isEmpty:
            return .watchFolder
        default:
            return nil
        }
    }

    /// Back to an empty form, still aimed at the same product and folder.
    mutating func clear() {
        var fresh = AutomationDraft()
        fresh.productID = productID
        fresh.projectID = projectID
        fresh.folderIsRepository = folderIsRepository
        fresh.localFiles = localFiles
        fresh.bringLocalFiles = !localFiles.isEmpty
        fresh.knownTools = knownTools
        self = fresh
    }

    func automation() -> Automation? {
        guard problem == nil, let productID, let projectID else { return nil }
        var a = Automation(productID: productID, projectID: projectID, name: name.trimmed, brief: brief.trimmed,
                           trigger: trigger, baseBranch: baseBranch.trimmed.isEmpty ? nil : baseBranch.trimmed,
                           confirmFirst: confirmFirst, templateID: templateID)
        a.evaluatedThrough = Date()
        a.workMode = workMode
        a.pipelineID = pipelineID
        let job = workMode == .job
        a.carryFiles = !job && bringLocalFiles && !localFiles.isEmpty ? localFiles : nil
        a.baseBranch = job ? nil : a.baseBranch
        a.readFolders = job && !readFolders.isEmpty ? readFolders : nil
        a.allowedTools = job && !allowedTools.isEmpty ? allowedTools.sorted() : nil
        a.writesReport = writesReport
        return a
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A segmented switch while its labels fit across the form, a pop-up menu when they do not.
///
/// A segmented control is as wide as its labels and will not shrink. In Ukrainian the work-mode
/// switch alone is wider than the automation sheet, and a row wider than the sheet pushed the whole
/// form off both its edges.
struct FittingPicker<Value: Hashable, Content: View>: View {
    @Binding var selection: Value
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Picker("", selection: $selection, content: content)
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            Picker("", selection: $selection, content: content)
                .labelsHidden()
                .fixedSize()
        }
    }
}
