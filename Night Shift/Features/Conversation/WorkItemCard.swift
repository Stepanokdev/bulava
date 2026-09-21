import SwiftUI

struct WorkItemCard: View {
    @Environment(AppModel.self) private var model
    let item: WorkItem

    private var state: WorkState { model.state(of: item) }
    private var tasks: [BacklogTask] { model.streamTasks(of: item) }

    var body: some View {
        if !item.isMultiStream, let only = tasks.first {

            TaskCard(task: only)
        } else {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    streamRows
                    if item.kind == .variants, model.allStreamsSettled(item) { galleryStrip }
                    actionRow
                }
            }
            .padding(.leading, 25)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Eyebrow(item.kind == .variants ? "Variants" : "One task, several streams",
                            color: Palette.accentEmphasis)
                    if item.priority == .urgent {
                        Text("Urgent")
                            .font(Typo.tag)
                            .textCase(.uppercase)
                            .foregroundStyle(Palette.red)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: Metrics.radiusBadge,
                                                         style: .continuous).fill(Palette.redSoft))
                    }
                }
                Text(item.title)
                    .cardTitleStyle()
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                subtitle
            }
            Spacer(minLength: 8)
            StatePill(text: LocalizedStringKey(state.labelKey),
                      systemImage: state.symbol, tint: tint, wash: wash)
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var subtitle: some View {
        HStack(spacing: 6) {
            Text(String(format: String(localized: "%lld of %lld done"), doneCount, item.streams.count))
                .font(Typo.caption)
                .foregroundStyle(Palette.textFaint)

            if failedCount > 0 {
                Text("·").font(Typo.caption).foregroundStyle(Palette.textFaint)
                Text(String(format: String(localized: "%lld failed"), failedCount))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.red)
            }
            if item.missingVariants > 0 {
                Text("·").font(Typo.caption).foregroundStyle(Palette.textFaint)
                Text(String(format: String(localized: "%lld never started"), item.missingVariants))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.orange)
            }
            if let dueBy = item.dueBy {
                Text("·").font(Typo.caption).foregroundStyle(Palette.textFaint)
                Text(dueLabel(dueBy))
                    .font(Typo.caption)
                    .foregroundStyle(item.isOverdue ? Palette.red : Palette.textFaint)
            }
        }
    }

    private func dueLabel(_ date: Date) -> String {
        item.isOverdue
            ? String(localized: "past its deadline")
            : String(format: String(localized: "due %@"), Fmt.dayLabel(date))
    }

    private var doneCount: Int { model.deliveredStreamCount(item) }
    private var failedCount: Int { model.failedStreamCount(item) }

    // MARK: - Streams

    private var streamRows: some View {
        VStack(spacing: 0) {
            Hairline()
            VStack(spacing: 0) {
                ForEach(Array(item.streams.enumerated()), id: \.element.id) { index, stream in
                    if index > 0 { Hairline() }
                    StreamRow(item: item, stream: stream)
                }
            }
        }
    }

    // MARK: - Variant gallery

    private var galleryStrip: some View {
        VStack(spacing: 0) {
            Hairline()
            Button { model.openVariantGallery(item) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.accentEmphasis)
                    Text(galleryLabel)
                        .font(Typo.control)
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textFaint)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(Palette.accentSoft)
            }
            .buttonStyle(.plain)
        }
    }

    private var galleryLabel: String {
        item.missingVariants > 0
            ? String(format: String(localized: "Open %lld variants — %lld of the %lld asked for"),
                     item.streams.count, item.streams.count, item.requestedVariants ?? item.streams.count)
            : String(format: String(localized: "Open all %lld variants"), item.streams.count)
    }

    // MARK: - Actions

    private var actionRow: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 7) {
                Menu {
                    Picker("Priority", selection: Binding(
                        get: { item.priority },
                        set: { model.workItems.setPriority($0, for: item.id) }
                    )) {
                        ForEach(WorkPriority.allCases, id: \.self) { p in
                            Text(LocalizedStringKey(p.labelKey)).tag(p)
                        }
                    }
                    if item.dueBy != nil {
                        Button("Clear the deadline") { model.workItems.setDeadline(nil, for: item.id) }
                    }
                } label: {
                    Text("Priority")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                CloseWorkButton(target: .item(item), running: state == .running || state == .paused)

                Spacer(minLength: 0)

                if doneCount > 0 {

                    let parts = model.deliveredParts(of: item)
                    if parts.count > 1 {
                        Menu {
                            ForEach(parts) { part in
                                Button(model.partName(part, in: item)) {
                                    model.beginAskingChangesOnItem(item, streamID: part.id)
                                }
                            }
                        } label: {
                            Text("Ask for changes")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    } else {
                        Button { model.beginAskingChangesOnItem(item) } label: { Text("Ask for changes") }
                            .buttonStyle(.bulava(.quiet))
                    }
                    Button { model.openItemReport(item) } label: {
                        Label {
                            Text(doneCount == item.streams.count
                                 ? String(localized: "Open the report")
                                 : String(format: String(localized: "Report on what is in (%lld of %lld)"),
                                          doneCount, item.streams.count))
                        } icon: { Image(systemName: "doc.text") }
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bulava(.primary))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
    }

    private var tint: Color {
        switch state {
        case .running, .reportReady, .done: Palette.green
        case .paused, .needsAnswer:         Palette.orange
        case .stopped:                      Palette.orange
        case .partial:                      Palette.orange
        case .failed:                       Palette.red
        case .planned:                      Palette.textTertiary
        }
    }

    private var wash: Color {
        switch state {
        case .running, .reportReady, .done: Palette.greenSoft
        case .paused, .needsAnswer:         Palette.orangeSoft
        case .stopped:                      Palette.orangeSoft
        case .partial:                      Palette.orangeSoft
        case .failed:                       Palette.redSoft
        case .planned:                      Palette.panelMuted
        }
    }
}

// MARK: - Stream row

private struct StreamRow: View {
    @Environment(AppModel.self) private var model
    let item: WorkItem
    let stream: WorkItem.Stream

    private var task: BacklogTask? { model.backlog.task(id: stream.id) }
    private var state: WorkState? {
        task.map { WorkProgress.state(task: $0, instance: model.liveInstance(for: $0)) }
    }
    private var isPreempted: Bool { item.preemptedStreamIDs.contains(stream.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            glyph.frame(width: 15).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let n = stream.variantNumber {
                        Text("\(n)")
                            .font(Typo.panelMeta)
                            .monospacedDigit()
                            .foregroundStyle(Palette.textFaint)
                    }
                    Text(stream.title)
                        .font(Typo.step)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = statusNote {
                    Text(note)
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if let task, let since = WorkProgress.startedAt(task: task, instance: model.liveInstance(for: task)),
               state == .running {
                ElapsedLabel(since: since, font: Typo.panelMeta)
            }
            if let task {
                Button { model.openTaskDetail(task) } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(.icon(size: 22, glyph: 10))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
    }

    private var statusNote: String? {
        if isPreempted { return String(localized: "paused for urgent work — goes back automatically") }

        if let blocker = task?.externalBlocker, !blocker.isEmpty { return blocker }
        if state == .planned {
            let unmet = stream.dependsOn.compactMap { depID -> String? in
                guard let dep = item.stream(id: depID),
                      let depTask = model.backlog.task(id: depID) else { return nil }
                let done = depTask.state == .review || depTask.state == .approved || depTask.state == .merged
                return done ? nil : dep.title
            }
            if !unmet.isEmpty {
                return String(format: String(localized: "waits for %@"),
                              unmet.joined(separator: ", "))
            }
            return String(localized: "next in this task")
        }
        if let task, let line = WorkProgress.nowLine(task: task, instance: model.liveInstance(for: task),
                                                    activity: task.projectPath.flatMap { model.workerActivity[$0] }) {
            return line.sentence
        }
        return stream.projectName
    }

    @ViewBuilder private var glyph: some View {
        switch state {
        case .done, .reportReady:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.green)
        case .running:
            PulseDot(color: Palette.green, size: 6)
        case .needsAnswer:
            Image(systemName: "questionmark").font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.orange)
        case .stopped:

            Image(systemName: "pause.circle").font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.orange)
        case .partial:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.orange)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.red)
        case .paused:
            Image(systemName: "pause.fill").font(.system(size: 9))
                .foregroundStyle(Palette.orange)
        case .planned, nil:
            Circle().strokeBorder(Palette.lineStrong, lineWidth: 1.2).frame(width: 9, height: 9)
        }
    }
}
