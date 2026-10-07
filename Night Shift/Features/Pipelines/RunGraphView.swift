import SwiftUI

// MARK: - Words and colours for a state

extension RunNodeState {

    var label: String {
        switch self {
        case .queued:      String(localized: "Not yet")
        case .running:     String(localized: "Working")
        case .delivered:   String(localized: "Received")
        case .done:        String(localized: "Done")
        case .verified:    String(localized: "Approved")
        case .failed:      String(localized: "Failed")
        case .retrying:    String(localized: "Sent back")
        case .waiting:     String(localized: "Waiting")
        case .skipped:     String(localized: "Skipped")
        case .unavailable: String(localized: "Unavailable")
        case .cancelled:   String(localized: "Cancelled")
        case .parked:      String(localized: "Not delivered")
        }
    }

    var tint: Color {
        switch self {
        case .queued, .skipped, .cancelled: Palette.textFaint
        case .running, .delivered:          Palette.accent
        case .done, .verified:              Palette.green
        case .failed:                       Palette.red
        case .retrying, .waiting, .parked:  Palette.orange
        case .unavailable:                  Palette.textTertiary
        }
    }

    /// A row of several steps shows the state that matters most among them.
    static func combined(_ states: [RunNodeState]) -> RunNodeState {
        let order: [RunNodeState] = [.failed, .retrying, .waiting, .parked, .running, .delivered]
        if let worst = order.first(where: states.contains) { return worst }
        if states.allSatisfy({ $0 == .queued }) { return .queued }
        if states.allSatisfy({ $0 == .cancelled }) { return .cancelled }
        if states.contains(.queued) { return .running }
        return states.contains(.verified) ? .verified : (states.contains(.done) ? .done : .skipped)
    }
}

extension RunOverall {

    var sentence: String {
        switch self {
        case .notStarted:               String(localized: "Not started")
        case .preparing:                String(localized: "Preparing the task")
        case .working:                  String(localized: "The worker is on it")
        case .checking:                 String(localized: "Checking the result")
        case .returned(let r, let m):
            m > 0 ? String(localized: "Sent back · round \(r) of \(m)") : String(localized: "Sent back for another round")
        case .waitingForYou:            String(localized: "Waiting for you")
        case .waitingForCodex:          String(localized: "Waiting for Codex")
        case .waitingForLimit:          String(localized: "Waiting for the usage limit")
        case .finished(let d):          d == "debt" ? String(localized: "Accepted with notes") : String(localized: "Work accepted")
        case .cancelled:                String(localized: "Cancelled")
        case .failed:                   String(localized: "Stopped")
        }
    }

    var tint: Color {
        switch self {
        case .finished:                                   Palette.green
        case .failed:                                     Palette.red
        case .waitingForYou, .waitingForCodex,
             .waitingForLimit, .returned:                 Palette.orange
        case .cancelled, .notStarted:                     Palette.textFaint
        case .preparing, .working, .checking:             Palette.accent
        }
    }

    var detail: String? {
        switch self {
        case .waitingForYou(let note), .failed(let note): note
        default: nil
        }
    }
}

// MARK: - Names of the steps

nonisolated enum RunNodeNaming {

    /// A step's name in the interface language. A built-in pipeline carries English names next to
    /// its Ukrainian ones; a pipeline somebody made keeps the names they gave it.
    static func title(_ node: PipelineNode, in doc: PipelineDocument?, registry: PipelineRegistry?) -> String {
        if !PipelineText.prefersUkrainian, let en = doc?.i18n?["en"]?["node." + node.id], !en.isEmpty { return en }
        if let t = node.title, !t.isEmpty { return t }
        return registry?.modules[node.key]?.t.local ?? node.id
    }
}

// MARK: - The glyph on the rail

struct RunGlyph: View {
    var state: RunNodeState
    var size: CGFloat = 13
    /// False for a run nothing is driving any more: it stands still where it stopped.
    var live: Bool = true
    @Environment(\.motionEnabled) private var motionEnabled

    var body: some View {
        ZStack {
            switch state {
            case .queued:
                Circle().strokeBorder(Palette.lineStrong, lineWidth: 1.2)
            case .skipped, .unavailable, .cancelled:
                Circle().strokeBorder(Palette.lineStrong, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
            case .running, .delivered:
                if motionEnabled && live {
                    PulseDot(color: state.tint, size: size * 0.55)
                } else {
                    Circle().fill(state.tint).frame(width: size * 0.55, height: size * 0.55)
                }
            case .done, .verified:
                Circle().fill(state.tint)
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(Palette.panel)
            case .failed:
                Circle().fill(state.tint)
                Image(systemName: "xmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(Palette.panel)
            case .retrying:
                Circle().fill(Palette.orangeSoft)
                Image(systemName: "arrow.uturn.backward").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(state.tint)
            case .waiting, .parked:
                Circle().strokeBorder(state.tint, lineWidth: 1.4)
                Image(systemName: "pause.fill").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(state.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - The graph, top to bottom

/// The run drawn as the steps it goes through, one rail top to bottom. Steps of one depth sit on
/// the same stop of the rail, indented under it. Only what the journal said moves here.
struct RunGraphView: View {
    let run: ChatRun
    var registry: PipelineRegistry?
    /// Whether something is still driving the run. A journal that says "working" about a run
    /// whose engine is gone is drawn standing still.
    var live: Bool = true
    @Environment(\.motionEnabled) private var motionEnabled

    private var rows: [[PipelineNode]] {
        guard let doc = run.document else { return [] }
        return doc.rows().map { $0.compactMap(doc.node) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let rows = rows
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                stop(row, isLast: index == rows.count - 1, next: index + 1 < rows.count ? rows[index + 1] : nil)
            }
        }
    }

    private func state(_ row: [PipelineNode]) -> RunNodeState {
        RunNodeState.combined(row.map { run.graph.status($0.id).state })
    }

    @ViewBuilder
    private func stop(_ row: [PipelineNode], isLast: Bool, next: [PipelineNode]?) -> some View {
        let rowState = state(row)
        HStack(alignment: .top, spacing: 9) {
            VStack(spacing: 0) {
                RunGlyph(state: rowState, live: live)
                    .padding(.top, 2)
                if !isLast {
                    RailSegment(finished: rowState.isFinished || rowState == .skipped || rowState == .unavailable,
                                flowing: motionEnabled && live && run.graph.isLive && rowState.isActive)
                }
            }
            .frame(width: 13)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(row) { node in
                    nodeLine(node, nested: row.count > 1)
                }
            }
            .padding(.bottom, isLast ? 0 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func nodeLine(_ node: PipelineNode, nested: Bool) -> some View {
        let status = run.graph.status(node.id)
        let title = RunNodeNaming.title(node, in: run.document, registry: registry)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if nested {
                    Circle().fill(status.state.tint.opacity(status.state == .queued ? 0.35 : 1))
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
                Text(verbatim: title)
                    .font(Typo.panelRow)
                    .foregroundStyle(status.state == .queued || status.state == .skipped
                                     ? Palette.textTertiary : Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let round = status.round, let max = status.max, max > 0 {
                    Text(String(localized: "round \(round) of \(max)"))
                        .font(Typo.panelMeta)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textFaint)
                }
                if status.state != .queued {
                    Text(verbatim: status.state.label)
                        .font(Typo.panelMeta)
                        .foregroundStyle(status.state.tint)
                }
            }
            if let note = noteText(status), !note.isEmpty, status.state != .queued, status.state != .done {
                Text(verbatim: note)
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, nested ? 11 : 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(title), \(status.state.label)"))
    }
}

extension RunGraphView {
    /// The engine writes its notes for the log; a few say something the interface can put in its
    /// own words, in its own language.
    fileprivate func noteText(_ status: RunNodeStatus) -> String? {
        if status.state == .retrying, let n = status.findings, n > 0 {
            return String(localized: "Sent back with \(n) findings")
        }
        return status.note
    }
}

/// The piece of rail between two stops. While the stop above it is working, a mark runs down it;
/// the moment the run stands still, so does the mark.
private struct RailSegment: View {
    var finished: Bool
    var flowing: Bool

    var body: some View {
        Rectangle()
            .fill(finished ? Palette.green.opacity(0.45) : Palette.lineStrong)
            .frame(width: 1.2)
            .frame(maxHeight: .infinity, alignment: .top)
            .frame(minHeight: 12)
            .overlay(alignment: .top) {
                if flowing {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        GeometryReader { geo in
                            let t = context.date.timeIntervalSinceReferenceDate
                            let phase = CGFloat(t.truncatingRemainder(dividingBy: 1.4) / 1.4)
                            Capsule()
                                .fill(Palette.accent)
                                .frame(width: 3, height: 7)
                                .offset(x: -0.9, y: phase * max(geo.size.height - 7, 0))
                                .opacity(Double(1 - phase * 0.6))
                        }
                    }
                }
            }
            .padding(.vertical, 3)
    }
}

// MARK: - In the right panel

struct RunInspectorSection: View {
    @Environment(AppModel.self) private var model
    let chatID: UUID
    @State private var expanded = true
    @State private var showingLog = false

    private var run: ChatRun? { model.chatRuns[chatID] }

    /// The journal says the run is going, but nothing is driving it now.
    private var stalled: Bool {
        guard let run else { return false }
        return run.graph.isLive && !model.directPhase(for: chatID).isActive
    }

    var body: some View {
        if let run, run.document != nil {
            VStack(alignment: .leading, spacing: 0) {
                PanelTitle("Run") {
                    if let id = run.graph.pipeline {
                        Button { model.openPipeline(id) } label: {
                            Text(verbatim: model.pipelineName(id))
                                .font(Typo.panelMeta)
                                .foregroundStyle(Palette.textFaint)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help(Text("Open this pipeline"))
                    }
                    Button { withAnimation(Motion.standard) { expanded.toggle() } } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.icon(size: 20, glyph: 9))
                    .help(Text(expanded ? "Hide the steps" : "Show the steps"))
                }
                PanelCard {
                    VStack(alignment: .leading, spacing: 10) {
                        header(run)
                        if expanded {
                            Hairline()
                            RunGraphView(run: run, registry: model.pipelineRegistry, live: !stalled)
                            Hairline()
                            footer(run)
                        }
                    }
                    .padding(12)
                }
            }
            .sheet(isPresented: $showingLog) {
                RunEventLog(run: run, registry: model.pipelineRegistry) { showingLog = false }
            }
        }
    }

    private func header(_ run: ChatRun) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(stalled ? Palette.textFaint : run.graph.overall.tint).frame(width: 7, height: 7)
                Text(verbatim: stalled ? String(localized: "Not running now") : run.graph.overall.sentence)
                    .font(Typo.rowLabel)
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 0)
            }
            if stalled {
                Text("It stopped at the step below. Send a message to carry on.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            } else if let detail = run.graph.overall.detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            }
        }
    }

    private func footer(_ run: ChatRun) -> some View {
        HStack(spacing: 6) {
            if let start = run.graph.startedAt {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let end = run.graph.isLive && !stalled ? Date() : (run.graph.lastEventAt ?? Date())
                    Text(String(localized: "Started \(start.formatted(date: .omitted, time: .shortened)) · \(Fmt.elapsed(end.timeIntervalSince(start)))"))
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textFaint)
                }
            }
            Spacer(minLength: 4)
            Button { showingLog = true } label: { Text("Event log") }
                .buttonStyle(.bulava(.quiet))
                .controlSize(.small)
        }
    }
}

// MARK: - Under the chat

/// One line under the conversation while a run is going: how far along it is, as many marks as
/// it has stops, and a way to the full view in the right panel.
struct RunStrip: View {
    @Environment(AppModel.self) private var model
    let run: ChatRun
    @Environment(\.motionEnabled) private var motionEnabled

    private var rows: [[String]] { run.document?.rows() ?? [] }

    private var current: (title: String, state: RunNodeState)? {
        guard let doc = run.document else { return nil }
        for row in rows {
            for id in row {
                let s = run.graph.status(id).state
                if s.isActive || s == .waiting || s == .failed || s == .parked, let node = doc.node(id) {
                    return (RunNodeNaming.title(node, in: doc, registry: model.pipelineRegistry), s)
                }
            }
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let s = RunNodeState.combined(row.map { run.graph.status($0).state })
                    Capsule()
                        .fill(s == .queued ? Palette.track : s.tint.opacity(s.isFinished ? 0.75 : 1))
                        .frame(width: 10, height: 3)
                        .modifier(Breathing(active: motionEnabled && s.isActive && run.graph.isLive))
                }
            }
            .accessibilityHidden(true)
            if let current {
                Text(verbatim: current.title)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Button {
                withAnimation(Motion.surface) { model.inspectorShown = true }
            } label: {
                Text("Show the run")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .help(Text("Every step of this run, in the right panel"))
        }
        .font(Typo.meta)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: run.graph.overall.sentence))
    }
}

private struct Breathing: ViewModifier {
    var active: Bool
    @State private var low = false

    func body(content: Content) -> some View {
        content
            .opacity(active && low ? 0.35 : 1)
            .onChange(of: active, initial: true) { _, on in
                if on {
                    withAnimation(Motion.breathe.repeatForever(autoreverses: true)) { low = true }
                } else {
                    withAnimation(nil) { low = false }
                }
            }
    }
}

// MARK: - Everything that happened

struct RunEventLog: View {
    let run: ChatRun
    var registry: PipelineRegistry?
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Event log").font(Typo.cardTitle).foregroundStyle(Palette.text)
                    Text("What the engine wrote down for this run, in order.")
                        .font(Typo.caption).foregroundStyle(Palette.textTertiary)
                }
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(.bulava(.secondary))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(run.graph.events.enumerated()), id: \.offset) { index, event in
                        if index > 0 { Hairline() }
                        row(event)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 560, height: 460)
        .background(Palette.panel)
    }

    private func where_(_ e: RunEvent) -> String {
        if let doc = run.document {
            let id = e.node ?? e.stage
            if let node = doc.node(id) { return RunNodeNaming.title(node, in: doc, registry: registry) }
            let byKey = doc.nodes.first { $0.key == e.stage }
            if let byKey { return RunNodeNaming.title(byKey, in: doc, registry: registry) }
        }
        switch e.stage {
        case "pipeline": return String(localized: "Preparation")
        case "gate":     return String(localized: "Checks")
        case "outcome":  return String(localized: "Result declared")
        case "agent":    return String(localized: "Worker")
        case "run":      return String(localized: "Verdict")
        default:         return e.stage
        }
    }

    private func row(_ e: RunEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: e.date.map { $0.formatted(.dateTime.hour().minute().second()) } ?? "—")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.textFaint)
                .frame(width: 64, alignment: .leading)
            Text(verbatim: where_(e))
                .font(Typo.panelRow)
                .foregroundStyle(Palette.text)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: e.state + (e.round.map { " · \($0)\(e.max.map { "/\($0)" } ?? "")" } ?? ""))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                if let note = e.note, !note.isEmpty {
                    Text(verbatim: note)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
