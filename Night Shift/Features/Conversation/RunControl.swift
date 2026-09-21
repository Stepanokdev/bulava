import SwiftUI

/// What the next message runs on — the mode, each engine's model, and how deep it thinks.
///
/// All of it used to live in one menu of four inline pickers, twenty-odd rows deep, and the
/// composer said only "Claude + Codex": to learn which model was about to answer he had to open
/// the menu and read down it. Now the row itself carries the answer, and the panel behind it is
/// one page per engine — a model, and a slider for depth.
struct RunControl: View {

    @Environment(AppModel.self) private var model

    /// Whether this chat already has a Claude session running. A session keeps the model and depth
    /// it was started with, so a change made now reaches the next one, and the panel says so
    /// rather than letting the pill quietly become untrue.
    let hasLiveClaudeSession: Bool

    @State private var open = false
    @State private var hovering = false

    private var mode: ChatEngineMode { model.settings.chatMode }

    var body: some View {
        Button { open = true } label: { pill }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .overlay(alignment: .topLeading) {
                // WHERE THE TAIL COMES OUT. An invisible strip pinned to the pill's leading edge,
                // as wide as the pill but never wider than this: the popover anchors to its
                // bounds, so the tail sits at half of that — in under the words rather than out
                // at the edge, and in the same place whichever model or depth is named. A short
                // pill (one engine) is narrower than the cap, so there the strip is the pill and
                // the tail is its true centre; it can never land past the end.
                //
                // It has to be the FRAME, not `.offset`: an offset moves what is drawn and not
                // what is laid out, and a popover anchors to the layout. Offsetting a point by 96
                // left the tail exactly where it was, on the pill's left edge.
                Color.clear
                    .frame(maxWidth: 192, maxHeight: 1)
                    .popover(isPresented: $open, arrowEdge: .bottom) {
                        RunControlPanel(hasLiveClaudeSession: hasLiveClaudeSession)
                    }
                    .accessibilityHidden(true)
            }
            .help(Text(LocalizedStringKey(mode.help)))
            .accessibilityLabel(Text("What this message runs on"))
            .accessibilityValue(Text(verbatim: spoken))
    }

    // MARK: The pill

    private var pill: some View {
        HStack(spacing: 5) {
            ForEach(Array(mode.engines.enumerated()), id: \.element) { index, engine in
                if index > 0 {
                    // Claude works, Codex reviews — the arrow is the order, not decoration.
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Palette.textFaint.opacity(0.7))
                }
                HStack(spacing: 4) {
                    EngineGlyph(engine: engine, size: 10.5, tint: Palette.textSecondary)
                    Text(verbatim: RunChoice.modelName(engine, model))
                        .foregroundStyle(Palette.textSecondary)
                    // A model with no depth names none, and an empty label would still take its
                    // spacing — a gap in the pill where a word used to be.
                    let depth = RunChoice.depthName(engine, model)
                    if !depth.isEmpty {
                        Text(verbatim: depth)
                            .foregroundStyle(Palette.textFaint)
                    }
                }
            }
        }
        .font(Typo.meta)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .frame(height: 23)
        .background(
            Capsule(style: .continuous)
                .fill(hovering || open ? Palette.hover : .clear)
        )
    }

    private var spoken: String {
        mode.engines
            .map { engine in
                [engine.name, RunChoice.modelName(engine, model), RunChoice.depthName(engine, model)]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: ", ")
    }
}

// MARK: - What is chosen, as words

/// The current choice, worded once and read by both the pill and the panel.
nonisolated enum RunChoice {

    @MainActor static func modelName(_ engine: Engine, _ model: AppModel) -> String {
        switch engine {
        case .claude:
            // With no model chosen, the engine's name is the honest label: it says which side is
            // answering without claiming to know which Claude the subscription will hand over.
            // With one chosen, the version is what the pill says — a family resolved through the
            // catalogue, so "Opus" reads as the Opus it is actually about to run.
            guard !model.settings.claudeModel.isAutomatic else { return Engine.claude.name }
            return model.claudeModels.resolved(model.settings.claudeModel)?.name
                ?? String(localized: model.settings.claudeModel.label)
        case .codex:
            return model.codexModels.model(slug: model.settings.codexModel)?.shortLabel
                ?? Engine.codex.name
        }
    }

    @MainActor static func depthName(_ engine: Engine, _ model: AppModel) -> String {
        switch engine {
        case .claude:
            // A model with no reasoning levels has no depth to name, and the pill says nothing
            // rather than naming one it does not send.
            guard model.claudeModels.thinks(model.settings.claudeModel) else { return "" }
            let depth = model.claudeModels.effort(model.settings.claudeEffort,
                                                  for: model.settings.claudeModel)
            return String(localized: depth.label)
        case .codex:
            let resolved = model.codexModels.effort(model.settings.codexEffort,
                                                    forSlug: model.settings.codexModel)
            return String(localized: resolved.label)
        }
    }
}

// MARK: - The panel

private struct RunControlPanel: View {

    @Environment(AppModel.self) private var model
    let hasLiveClaudeSession: Bool

    private var mode: ChatEngineMode { model.settings.chatMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(mode.engines.enumerated()), id: \.element) { index, engine in
                if index > 0 { Hairline() }
                section(for: engine)
            }
        }
        .frame(width: 336)
        .animation(Motion.expand, value: mode)
    }

    // MARK: Mode — not offered for now
    //
    // Working with Claude alone, or Codex alone, is not a choice the app offers at the moment: he
    // asked for it to go, and said he may want it back. So it is commented out rather than
    // deleted, and `AppSettings.init(from:)` pins the mode to Claude + Codex to match. Bringing it
    // back is this section, the `Eyebrow("Mode")` and `modeSwitch` rows in `body` above, and
    // dropping that pin — the strings and the per-engine delivery paths never left.
    //
    // private static let modeOrder: [ChatEngineMode] = [.claude, .codex, .claudeAndCodex]
    //
    //          Eyebrow("Mode")
    //              .padding(.horizontal, 12)
    //              .padding(.top, 12)
    //              .padding(.bottom, 8)
    //
    //          modeSwitch
    //              .padding(.horizontal, 12)
    //              .padding(.bottom, 12)
    //
    // private var modeSwitch: some View {
    //     HStack(spacing: 4) {
    //         ForEach(Self.modeOrder) { candidate in
    //             let chosen = candidate == mode
    //             Button { model.settings.chatMode = candidate } label: {
    //                 VStack(spacing: 5) {
    //                     HStack(spacing: 2) {
    //                         ForEach(candidate.engines) { engine in
    //                             EngineGlyph(engine: engine, size: 12,
    //                                         tint: chosen ? Palette.accentEmphasis : Palette.textSecondary)
    //                         }
    //                     }
    //                     .frame(height: 13)
    //                     Text(LocalizedStringKey(candidate.shortLabel))
    //                         .font(Typo.meta)
    //                         .foregroundStyle(chosen ? Palette.accentEmphasis : Palette.textSecondary)
    //                 }
    //                 .frame(maxWidth: .infinity)
    //                 .frame(height: 44)
    //             }
    //             .buttonStyle(.row(selected: chosen))
    //             .help(Text(LocalizedStringKey(candidate.help)))
    //         }
    //     }
    // }

    // MARK: One engine

    @ViewBuilder private func section(for engine: Engine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                EngineGlyph(engine: engine, size: 12, tint: Palette.text)
                Text(verbatim: engine.name)
                    .font(Typo.rowLabel)
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                modelPicker(engine)
            }

            depthRow(engine)

            if engine == .claude, hasLiveClaudeSession {
                Text("This chat is already running — Claude picks the model up on its next session here.")
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: The models

    /// The system's own popup, with nothing in it but the names.
    ///
    /// It was a list drawn inside the panel, each row carrying the model's one-line description —
    /// which made the panel tall, pushed the depth slider around as it opened, and explained models
    /// to someone who already knows them. A menu is what macOS uses for a choice of one out of six.
    @ViewBuilder private func modelPicker(_ engine: Engine) -> some View {
        switch engine {
        case .claude:
            ClaudeModelMenu()

        case .codex:
            Picker("", selection: Binding(get: { model.settings.codexModel },
                                          set: { model.chooseCodexModel($0) })) {
                Text("Automatic").tag("")
                ForEach(model.codexModels.models) { candidate in
                    Text(verbatim: candidate.shortLabel).tag(candidate.slug)
                }
                // A model chosen on an older build, or on a machine whose catalogue has not been
                // written yet, is still the current value and has to be shown as one — otherwise
                // the popup reads "Automatic" while the app keeps sending the model.
                if !model.settings.codexModel.isEmpty,
                   model.codexModels.model(slug: model.settings.codexModel) == nil {
                    Text(verbatim: model.settings.codexModel).tag(model.settings.codexModel)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    // MARK: The depth

    @ViewBuilder private func depthRow(_ engine: Engine) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.textFaint)

            switch engine {
            case .claude:
                if model.claudeModels.thinks(model.settings.claudeModel) {
                    let steps = model.claudeModels.levels(for: model.settings.claudeModel)
                    EffortSlider(count: steps.count,
                                 index: steps.firstIndex(of: model.settings.claudeEffort) ?? 0,
                                 label: depthLabel(engine)) { i in
                        model.settings.claudeEffort = steps[i]
                    }
                    .animation(Motion.expand, value: steps.count)
                } else {
                    // Haiku has no reasoning levels. A slider with one stop is a control that does
                    // nothing, so the row says so and keeps its height.
                    Spacer(minLength: 0)
                }
            case .codex:
                let steps = model.codexModels.levels(forSlug: model.settings.codexModel)
                EffortSlider(count: steps.count,
                             index: steps.firstIndex(of: model.settings.codexEffort) ?? 0,
                             label: depthLabel(engine)) { i in
                    model.settings.codexEffort = steps[i]
                }
            }

            // Wide enough for the longest thing it says — "Automatic · Very high" — because a
            // depth label truncated to "Automatic · V…" answers nothing, and a label that resizes
            // itself would move the slider under his finger every time the depth changed.
            Text(verbatim: depthLabel(engine))
                .font(Typo.meta)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .frame(width: 128, alignment: .trailing)
        }
    }

    /// The depth as the panel words it: `Automatic` says which level it resolves to, because the
    /// difference between the lightest setting and the most expensive one is the whole question.
    private func depthLabel(_ engine: Engine) -> String {
        switch engine {
        case .claude:
            return model.claudeModels.depthLabel(model.settings.claudeEffort,
                                                 for: model.settings.claudeModel)
        case .codex:
            guard model.settings.codexEffort == .auto else {
                return String(localized: model.settings.codexEffort.label)
            }
            let resolved = model.codexModels.automaticLevel(forSlug: model.settings.codexModel)
            return String(format: String(localized: "Automatic · %@"),
                          String(localized: resolved.label))
        }
    }
}

// MARK: - The depth slider

/// A slider with a stop for each depth the engine takes, and nothing in between.
///
/// Depth is an ordered handful of named levels, which is what a slider is for — a menu made him
/// read six rows to learn where "high" sat between the others. Every stop is drawn, so the shape
/// of the choice is visible before he touches it.
private struct EffortSlider: View {

    let count: Int
    let index: Int
    let label: String
    let change: (Int) -> Void

    private let height: CGFloat = 22

    /// Light in both themes, on purpose. A knob the colour of the surrounding panel vanishes in
    /// the dark, where the leftmost stop leaves it sitting on the empty part of the track.
    private static let knob = Color.theme(light: 0xFFFFFF, dark: 0xF2F2F3)

    var body: some View {
        GeometryReader { geo in
            let knob = height - 6
            // The knob's travel stops short of both ends. Flush against the right edge it read as
            // stuck to the border of the filled part rather than sitting on a track.
            let inset: CGFloat = 6
            let usable = max(geo.size.width - knob - inset * 2, 1)
            let gap = count > 1 ? usable / CGFloat(count - 1) : 0
            let centre = inset + knob / 2 + gap * CGFloat(min(max(index, 0), count - 1))

            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Palette.track)

                Capsule(style: .continuous)
                    .fill(Palette.accent)
                    .frame(width: centre + knob / 2)

                ForEach(0..<count, id: \.self) { stop in
                    Circle()
                        .fill(stop <= index ? Palette.onAccent.opacity(0.55)
                                            : Palette.textFaint.opacity(0.45))
                        .frame(width: 3.5, height: 3.5)
                        .offset(x: inset + knob / 2 + gap * CGFloat(stop) - 1.75)
                }

                Circle()
                    .fill(Self.knob)
                    .overlay(Circle().strokeBorder(Palette.lineStrong, lineWidth: 0.5))
                    .shadow(color: Palette.shadow(0.16), radius: 2, x: 0, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: centre - knob / 2 - 1)
                    .padding(.leading, -4)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { touch in
                        guard gap > 0 else { return }
                        let raw = (touch.location.x - inset - knob / 2) / gap
                        let stop = min(max(Int(raw.rounded()), 0), count - 1)
                        if stop != index { change(stop) }
                    }
            )
            .animation(Motion.snappy, value: index)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text("Depth"))
        .accessibilityValue(Text(verbatim: label))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < count { change(index + 1) }
            case .decrement: if index > 0 { change(index - 1) }
            @unknown default: break
            }
        }
    }
}

#Preview {
    EffortSlider(count: 6, index: 2, label: "Label", change: { _ in })
}
