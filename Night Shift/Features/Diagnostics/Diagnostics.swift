import SwiftUI

// MARK: - Live worker output

struct LiveWorkerPane: View {
    @Environment(AppModel.self) private var model
    let session: String
    var height: CGFloat = 260
    var tailLines: Int = 200

    @State private var lines: [String] = []
    @State private var loading = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if lines.isEmpty {
                        Text(loading
                             ? "Attaching…"
                             : "No output. Grant Screen Recording to tmux, or open the session in Terminal.")
                            .font(Typo.mono())
                            .foregroundStyle(Palette.onTerminalDim)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(Typo.mono())
                                .foregroundStyle(Palette.onTerminal)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .fill(Palette.terminal)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            )
            .onChange(of: lines.count) { _, _ in
                guard let last = lines.indices.last else { return }
                withAnimation(Motion.hover) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .task(id: session) { await poll() }
    }

    private func poll() async {
        while !_Concurrency.Task.isCancelled {
            let text = await model.workerActivity(session: session, lines: tailLines)
            var out = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
            lines = Array(out.suffix(tailLines))
            loading = false
            try? await _Concurrency.Task.sleep(for: .seconds(2.5))
        }
    }
}

// MARK: - Diff

struct DiffView: View {
    let text: String
    var maxLines: Int = 400

    private var lines: [Substring] {
        Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines))
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(Typo.mono())
                        .foregroundStyle(color(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
            }
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Palette.terminal)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(Palette.line, lineWidth: 1)
        )
    }

    private func color(for line: Substring) -> Color {

        if line.hasPrefix("+++") || line.hasPrefix("---")
            || line.hasPrefix("diff --git") || line.hasPrefix("index ") { return Palette.onTerminalDim }
        if line.hasPrefix("@@") { return Color(hex: 0xA5A8FF) }
        if line.hasPrefix("+") { return Color(hex: 0x69C58C) }
        if line.hasPrefix("-") { return Color(hex: 0xEF7770) }
        return Palette.onTerminal
    }
}

// MARK: - Task diagnostics

struct TaskDiagnosticsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: BacklogTask

    @State private var package: ReviewPackage?
    @State private var loading = false

    private var instance: SupervisorInstance? { model.liveInstance(for: task) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    request
                    scope
                    if let instance { live(instance) }
                    if let package { changes(package) }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 720, height: 620)
        .background(Palette.content)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow("Diagnostics")
                Text(task.title)
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let instance {
                Button {
                    model.attachInTerminal(session: instance.session, projectPath: instance.projectPath)
                } label: { Text("Open in Terminal") }
                .buttonStyle(.bulava(.quiet))
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.icon)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.chrome)
    }

    private var request: some View {
        section("What was asked") {
            Text(task.detail.isEmpty ? task.title : task.detail)
                .font(Typo.step)
                .lineSpacing(3)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scope: some View {
        section("Scope the Foreman chose") {
            VStack(alignment: .leading, spacing: 6) {
                labelled("Mode", task.runMode?.label ?? "Broad")
                labelled("Verification", task.verificationProfile?.label ?? "Standard")
                if !task.writePaths.isEmpty {
                    labelled("May change", task.writePaths.joined(separator: ", "))
                }
                if !task.acceptance.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Must be true when done")
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textFaint)
                        ForEach(task.acceptance, id: \.self) { criterion in
                            Text("• \(criterion)")
                                .font(Typo.panelMeta)
                                .foregroundStyle(Palette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let branch = task.boundBranch {
                    labelled("Branch", branch)
                }
            }
        }
    }

    private func live(_ instance: SupervisorInstance) -> some View {
        section("Live output") {
            LiveWorkerPane(session: instance.session)
        }
    }

    private func changes(_ package: ReviewPackage) -> some View {
        section("Changes") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(package.changedFiles.count) files · +\(package.insertions) −\(package.deletions)")
                    .font(Typo.panelMeta)
                    .foregroundStyle(Palette.textFaint)
                if !package.diffText.isEmpty {
                    DiffView(text: package.diffText)
                        .frame(height: 300)
                }
            }
        }
    }

    private func section(_ title: LocalizedStringKey,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelled(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textFaint)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(Typo.panelMeta)
                .foregroundStyle(Palette.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        package = await model.loadReview(for: task)
        loading = false
    }
}
