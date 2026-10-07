import SwiftUI

/// The pipeline as boxes and wires, drawn natively: steps are views, wires are paths. A box is
/// moved by dragging it; a wire is pulled from an output dot to an input dot, and only to one
/// whose type it can feed. The engine's validator still has the last word on every change.
///
/// Zoom is laid out, not painted: every position and size is multiplied by it, and a press is
/// matched to a box or a dot by arithmetic on those same numbers. A canvas scaled as a picture
/// draws in one place and answers the mouse in another.
struct PipelineCanvas: View {
    @Bindable var state: PipelineEditorState
    let registry: PipelineRegistry?
    @State private var zoom: CGFloat = 1
    @State private var pending: PendingWire?
    @State private var press: Press?
    @State private var addingStep = false

    private struct PendingWire: Equatable {
        var fromNode: String
        var fromPort: String
        var type: String
        var start: CGPoint
        var end: CGPoint
    }

    /// What the press that is under way is doing: moving a box, or pulling a wire out of a dot.
    private enum Press: Equatable {
        case move(String)
        case wire(String, String)
    }

    private var doc: PipelineDocument? { state.doc }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                ScrollView([.horizontal, .vertical]) {
                    content
                }
                .background(Palette.content)
                .background(GridBackdrop())

                toolbar(fitting: geo.size).padding(10)
            }
            .onAppear { fit(geo.size) }
        }
        .onDeleteCommand { deleteSelection() }
    }

    /// The whole pipeline in view when it opens: zoomed out as far as it takes, never in.
    private func fit(_ size: CGSize) {
        let content = contentBounds
        guard content.width > 0, size.width > 0 else { return }
        let wide = (size.width - 20) / content.width
        let tall = (size.height - 70) / content.height
        zoom = max(0.5, min(1, min(wide, tall))).rounded(toStep: 0.05)
    }

    // MARK: Layers

    private var content: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: canvasSize.width * zoom, height: canvasSize.height * zoom)
                .contentShape(Rectangle())
                .onTapGesture { state.selection = nil; state.selectedEdge = nil }
            if let doc {
                ForEach(Array(doc.edges.enumerated()), id: \.element.id) { _, edge in
                    wire(edge, in: doc)
                }
                if let pending {
                    WireShape(from: pending.start, to: pending.end, loop: false)
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 3]))
                        .allowsHitTesting(false)
                }
                ForEach(doc.nodes) { node in
                    let w = PipelineCanvasMetrics.nodeWidth, h = height(of: node)
                    nodeView(node)
                        .frame(width: w, height: h, alignment: .topLeading)
                        .scaleEffect(zoom, anchor: .topLeading)
                        .frame(width: w * zoom, height: h * zoom, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .gesture(nodeGesture(node))
                        .position(x: (Self.inset.width + CGFloat(node.x ?? 0)) * zoom + w * zoom / 2,
                                  y: (Self.inset.height + CGFloat(node.y ?? 0)) * zoom + h * zoom / 2)
                }
            }
        }
        .frame(width: canvasSize.width * zoom, height: canvasSize.height * zoom, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
    }

    private static let space = "pipeline-canvas"

    /// Room around the boxes for wires that bend outside them and for the tools along the bottom.
    private static let inset = CGSize(width: 64, height: 32)

    /// Where the boxes and their wires reach, before any spare room, at 100%.
    private var contentBounds: CGSize {
        guard let doc, !doc.nodes.isEmpty else { return CGSize(width: 600, height: 300) }
        let maxX = doc.nodes.map { CGFloat($0.x ?? 0) + PipelineCanvasMetrics.nodeWidth }.max() ?? 0
        let maxY = doc.nodes.map { CGFloat($0.y ?? 0) + height(of: $0) }.max() ?? 0
        let loops: CGFloat = doc.edges.contains { $0.loop != nil } ? 90 : 0
        return CGSize(width: maxX + Self.inset.width * 2, height: maxY + Self.inset.height * 2 + loops + 40)
    }

    private var canvasSize: CGSize {
        let b = contentBounds
        return CGSize(width: max(700, b.width + 240), height: max(460, b.height + 160))
    }

    // MARK: Geometry — in canvas points, zoom applied

    private func spec(_ node: PipelineNode) -> PipelineModuleSpec? { registry?.modules[node.key] }

    private func height(of node: PipelineNode) -> CGFloat {
        let s = spec(node)
        return PipelineCanvasMetrics.height(inputs: s?.inPorts.count ?? 1, outputs: s?.outPorts.count ?? 1)
    }

    private func portY(_ node: PipelineNode, _ index: Int) -> CGFloat {
        CGFloat(node.y ?? 0) + Self.inset.height + PipelineCanvasMetrics.headerHeight
            + CGFloat(index) * PipelineCanvasMetrics.portRow + PipelineCanvasMetrics.portRow / 2
    }

    private func inPoint(_ node: PipelineNode, _ port: String) -> CGPoint {
        let idx = spec(node)?.inPorts.firstIndex { $0.id == port } ?? 0
        return CGPoint(x: (Self.inset.width + CGFloat(node.x ?? 0)) * zoom, y: portY(node, idx) * zoom)
    }

    private func outPoint(_ node: PipelineNode, _ port: String) -> CGPoint {
        let idx = spec(node)?.outPorts.firstIndex { $0.id == port } ?? 0
        return CGPoint(x: (Self.inset.width + CGFloat(node.x ?? 0) + PipelineCanvasMetrics.nodeWidth) * zoom,
                       y: portY(node, idx) * zoom)
    }

    /// The output dot of this box under a point, if the point is close enough to one.
    private func outputPort(of node: PipelineNode, near point: CGPoint) -> PipelinePortSpec? {
        let reach = max(10, 12 * zoom)
        return spec(node)?.outPorts.first { port in
            let q = outPoint(node, port.id)
            return hypot(q.x - point.x, q.y - point.y) <= reach
        }
    }

    // MARK: Wires

    @ViewBuilder
    private func wire(_ edge: PipelineEdge, in doc: PipelineDocument) -> some View {
        if let a = doc.node(edge.fromNode), let b = doc.node(edge.toNode) {
            let from = outPoint(a, edge.fromPort)
            let to = inPoint(b, edge.toPort)
            let selected = state.selectedEdge == edge.id
            let loop = edge.loop != nil
            let shape = WireShape(from: from, to: to, loop: loop, drop: 70 * zoom)
            ZStack {
                shape
                    .stroke(selected ? Palette.accent : (loop ? Palette.orange : Palette.textFaint.opacity(0.7)),
                            style: StrokeStyle(lineWidth: selected ? 2 : 1.4, lineCap: .round, dash: loop ? [5, 4] : []))
                if let max = edge.loop?.max {
                    Text(String(localized: "back · at most \(max)"))
                        .font(Typo.panelMeta)
                        .foregroundStyle(Palette.orange)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(Capsule(style: .continuous).fill(Palette.panel))
                        .overlay(Capsule(style: .continuous).strokeBorder(Palette.orange.opacity(0.4), lineWidth: 1))
                        .position(shape.labelPoint)
                }
            }
            .contentShape(shape.stroke(lineWidth: 12))
            .onTapGesture {
                state.selectedEdge = edge.id
                state.selection = nil
            }
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: "\(edge.from) → \(edge.to)"))
            .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: Boxes

    @ViewBuilder
    private func nodeView(_ node: PipelineNode) -> some View {
        let s = spec(node)
        let selected = state.selection == node.id
        let problems = state.issues(for: node.id)
        let hasError = problems.contains(where: \.isError)
        let runnable = s?.exec ?? false
        VStack(alignment: .leading, spacing: 0) {
            header(node, spec: s)
            ports(node, spec: s)
        }
        .frame(width: PipelineCanvasMetrics.nodeWidth, height: height(of: node), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(hasError ? Palette.red : (selected ? Palette.accent : Palette.lineStrong),
                              style: StrokeStyle(lineWidth: selected || hasError ? 1.5 : 1, dash: runnable ? [] : [4, 3]))
        )
        .shadow(color: Palette.shadow(selected ? 0.10 : 0.04), radius: selected ? 8 : 3, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: RunNodeNaming.title(node, in: state.doc, registry: registry)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select(node.id) }
    }

    private func header(_ node: PipelineNode, spec s: PipelineModuleSpec?) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: PipelineGlyphs.category(s?.cat ?? ""))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                let title = RunNodeNaming.title(node, in: state.doc, registry: registry)
                Text(verbatim: title)
                    .font(Typo.panelRow)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                let kind = s?.exec == false ? String(localized: "Not in the engine yet") : (s?.t.local ?? node.key)
                if kind != title {
                    Text(verbatim: kind)
                        .font(Typo.panelMeta)
                        .foregroundStyle(s?.exec == false ? Palette.orange : Palette.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            let problems = state.issues(for: node.id)
            if !problems.isEmpty {
                Image(systemName: problems.contains(where: \.isError) ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(problems.contains(where: \.isError) ? Palette.red : Palette.orange)
                    .help(Text(verbatim: problems.map(\.msg.local).joined(separator: "\n")))
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 7)
        .frame(height: PipelineCanvasMetrics.headerHeight, alignment: .top)
    }

    private func ports(_ node: PipelineNode, spec s: PipelineModuleSpec?) -> some View {
        let ins = s?.inPorts ?? []
        let outs = s?.outPorts ?? []
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ins, id: \.id) { port in
                    HStack(spacing: 5) {
                        PortDot(highlighted: pendingAccepts(node, port))
                            .offset(x: -4)
                        Text(verbatim: port.label?.local ?? inLabel(port))
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                    .frame(height: PipelineCanvasMetrics.portRow)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(outs, id: \.id) { port in
                    HStack(spacing: 5) {
                        Text(verbatim: port.label?.local ?? outLabel(port))
                            .font(Typo.panelMeta)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                        PortDot(highlighted: pending?.fromNode == node.id && pending?.fromPort == port.id)
                            .offset(x: 4)
                            .help(Text("Drag to an input to connect"))
                    }
                    .frame(height: PipelineCanvasMetrics.portRow)
                }
            }
        }
    }

    /// An input that takes several kinds says so: "report / code changes", not only the first.
    private func inLabel(_ port: PipelinePortSpec) -> String {
        let names = port.accepted.filter { $0 != "any" }.map { registry?.typeName($0) ?? $0 }
        if names.isEmpty { return registry?.typeName("any") ?? port.id }
        return names.count > 2 ? (names.prefix(2).joined(separator: " / ") + " …") : names.joined(separator: " / ")
    }

    private func outLabel(_ port: PipelinePortSpec) -> String {
        switch port.id {
        case "pass": String(localized: "if passed")
        case "fail": String(localized: "if sent back")
        case "yes": String(localized: "yes")
        case "no": String(localized: "no")
        default: registry?.typeName(port.type ?? port.id) ?? port.id
        }
    }

    // MARK: The one gesture a box has

    private func select(_ id: String) {
        state.selection = id
        state.selectedEdge = nil
    }

    /// A press on a box selects it. Started on an output dot it pulls a wire; started anywhere else
    /// and moved, it moves the box.
    private func nodeGesture(_ node: PipelineNode) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if press == nil {
                    select(node.id)
                    if !state.readOnly, let port = outputPort(of: node, near: value.startLocation) {
                        press = .wire(node.id, port.id)
                    } else {
                        press = .move(node.id)
                    }
                }
                switch press {
                case .wire(_, let portID):
                    let port = spec(node)?.outPorts.first { $0.id == portID }
                    pending = PendingWire(fromNode: node.id, fromPort: portID, type: port?.type ?? "any",
                                          start: outPoint(node, portID), end: value.location)
                case .move:
                    guard !state.readOnly, hypot(value.translation.width, value.translation.height) > 3 else { return }
                    state.beginGesture()
                    let origin = state.gestureOrigin(of: node.id) ?? .zero
                    let nx = max(0, (origin.x + value.translation.width / zoom).rounded(toStep: 4))
                    let ny = max(0, (origin.y + value.translation.height / zoom).rounded(toStep: 4))
                    state.editDuringGesture { d in
                        if let i = d.nodes.firstIndex(where: { $0.id == node.id }) {
                            d.nodes[i].x = Double(nx); d.nodes[i].y = Double(ny)
                        }
                    }
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer { press = nil; pending = nil }
                switch press {
                case .wire(_, let portID):
                    guard let port = spec(node)?.outPorts.first(where: { $0.id == portID }),
                          let target = nearestInput(to: value.location, excluding: node.id, type: port.type ?? "any") else { return }
                    connect(from: node.id, port: port, to: target.node, port: target.port)
                case .move:
                    state.endGesture()
                case nil:
                    break
                }
            }
    }

    private func pendingAccepts(_ node: PipelineNode, _ port: PipelinePortSpec) -> Bool {
        guard let pending, pending.fromNode != node.id else { return false }
        return PipelineRegistry.compatible(pending.type, port.accepted)
    }

    private func nearestInput(to point: CGPoint, excluding: String, type: String) -> (node: String, port: String)? {
        guard let doc else { return nil }
        var best: (node: String, port: String, d: CGFloat)?
        let reach = max(18, 26 * zoom)
        for n in doc.nodes where n.id != excluding {
            for p in spec(n)?.inPorts ?? [] where PipelineRegistry.compatible(type, p.accepted) {
                let q = inPoint(n, p.id)
                let d = hypot(q.x - point.x, q.y - point.y)
                if d < reach, d < (best?.d ?? .infinity) { best = (n.id, p.id, d) }
            }
        }
        return best.map { ($0.node, $0.port) }
    }

    private func connect(from: String, port: PipelinePortSpec, to: String, port inPort: String) {
        let edge = PipelineEdge(from: "\(from).\(port.id)", to: "\(to).\(inPort)",
                                loop: port.id == "fail" && inPort == "feedback"
                                    ? PipelineLoop(max: registry?.reviewDefault ?? 3) : nil)
        state.edit { d in
            guard !d.edges.contains(where: { $0.from == edge.from && $0.to == edge.to }) else { return }
            d.edges.append(edge)
        }
        state.selectedEdge = edge.id
        state.selection = nil
    }

    private func deleteSelection() {
        if let id = state.selection {
            state.edit { $0.removeNode(id) }
        } else if let e = state.selectedEdge {
            state.edit { $0.edges.removeAll { $0.id == e } }
        }
    }

    // MARK: Tools over the canvas

    private func toolbar(fitting size: CGSize) -> some View {
        HStack(spacing: 6) {
            if !state.readOnly {
                Button { addingStep = true } label: { Label("Add step", systemImage: "plus") }
                    .buttonStyle(.bulava(.secondary))
                    .popover(isPresented: $addingStep, arrowEdge: .bottom) {
                        ModulePalette(registry: registry) { key in
                            addingStep = false
                            add(key)
                        }
                    }
            }
            Spacer()
            HStack(spacing: 0) {
                Button { zoom = max(0.5, zoom - 0.1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.icon(size: 26, glyph: 11))
                    .help(Text("Zoom out"))
                Text(verbatim: "\(Int((zoom * 100).rounded()))%")
                    .font(Typo.panelMeta)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 38)
                Button { zoom = min(1.6, zoom + 0.1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.icon(size: 26, glyph: 11))
                    .help(Text("Zoom in"))
                Button { fit(size) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.icon(size: 26, glyph: 10))
                    .help(Text("Show the whole pipeline"))
            }
            .background(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).fill(Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
        }
    }

    private func add(_ key: String) {
        guard let doc, let spec = registry?.modules[key] else { return }
        let id = doc.freeNodeID(for: key)
        var params: [String: JSONValue] = [:]
        for p in spec.p ?? [] { if let d = p.default { params[p.k] = d } }
        let anchor = state.selection.flatMap(doc.node)
        let x = (anchor?.x).map { $0 + PipelineCanvasMetrics.columnStep } ?? (doc.nodes.map { $0.x ?? 0 }.max() ?? 0) + PipelineCanvasMetrics.columnStep
        let y = anchor?.y ?? 24
        let node = PipelineNode(id: id, module: "bulava/\(key)@1", params: params.isEmpty ? nil : params, x: x, y: y)
        state.edit { $0.nodes.append(node) }
        state.selection = id
    }
}

// MARK: - Pieces

private struct PortDot: View {
    var highlighted: Bool
    var body: some View {
        Circle()
            .fill(highlighted ? Palette.accent : Palette.panel)
            .overlay(Circle().strokeBorder(highlighted ? Palette.accent : Palette.textFaint, lineWidth: 1.2))
            .frame(width: 9, height: 9)
            .contentShape(Circle().inset(by: -6))
    }
}

nonisolated struct WireShape: Shape {
    var from: CGPoint
    var to: CGPoint
    var loop: Bool
    /// How far a wire that goes back dips below the boxes.
    var drop: CGFloat = 70

    /// A forward wire bends like any node editor's; a wire that goes back runs under both boxes,
    /// so the loop reads as a loop and never crosses the steps in between.
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        if !loop, to.x < from.x, abs(to.y - from.y) > 40 {
            // A wire that wraps to the next row runs back along the gap between the rows.
            let mid = (from.y + to.y) / 2
            p.addCurve(to: CGPoint(x: from.x + 24, y: mid),
                       control1: CGPoint(x: from.x + 34, y: from.y),
                       control2: CGPoint(x: from.x + 34, y: mid))
            p.addLine(to: CGPoint(x: to.x - 24, y: mid))
            p.addCurve(to: to,
                       control1: CGPoint(x: to.x - 34, y: mid),
                       control2: CGPoint(x: to.x - 34, y: to.y))
        } else if loop || to.x < from.x {
            let drop = max(from.y, to.y) + self.drop
            p.addCurve(to: CGPoint(x: (from.x + to.x) / 2, y: drop),
                       control1: CGPoint(x: from.x + 60, y: from.y),
                       control2: CGPoint(x: from.x + 40, y: drop))
            p.addCurve(to: to,
                       control1: CGPoint(x: to.x - 40, y: drop),
                       control2: CGPoint(x: to.x - 60, y: to.y))
        } else {
            let dx = max(40, abs(to.x - from.x) / 2)
            p.addCurve(to: to, control1: CGPoint(x: from.x + dx, y: from.y), control2: CGPoint(x: to.x - dx, y: to.y))
        }
        return p
    }

    var labelPoint: CGPoint {
        if !loop, to.x < from.x, abs(to.y - from.y) > 40 { return CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2) }
        if loop || to.x < from.x { return CGPoint(x: (from.x + to.x) / 2, y: max(from.y, to.y) + drop) }
        return CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
    }
}

private struct GridBackdrop: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 24
            var x: CGFloat = 0
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(Palette.lineStrong))
                    y += step
                }
                x += step
            }
        }
        .allowsHitTesting(false)
    }
}

nonisolated enum PipelineGlyphs {
    static func category(_ cat: String) -> String {
        switch cat {
        case "trigger": "bolt"
        case "prep":    "doc.text.magnifyingglass"
        case "agent":   "person.crop.square"
        case "skill":   "wand.and.stars"
        case "gate":    "checkmark.shield"
        case "flow":    "arrow.triangle.branch"
        case "out":     "tray.and.arrow.up"
        default:        "clock"
        }
    }

    static func categoryName(_ cat: String) -> String {
        switch cat {
        case "trigger": String(localized: "Triggers")
        case "prep":    String(localized: "Preparation")
        case "agent":   String(localized: "Who does the work")
        case "skill":   String(localized: "Skills and tools")
        case "gate":    String(localized: "Checks")
        case "flow":    String(localized: "Flow")
        case "out":     String(localized: "Results")
        default:        String(localized: "Later")
        }
    }
}

/// Every module the engine knows, by what it is for. The ones it cannot run yet are shown, so the
/// whole map is visible, but cannot be added.
struct ModulePalette: View {
    let registry: PipelineRegistry?
    let pick: (String) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Find a step", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(PipelineRegistry.categoryOrder, id: \.self) { cat in
                        let items = (registry?.ordered(category: cat) ?? []).filter(matches)
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Eyebrow(LocalizedStringKey(PipelineGlyphs.categoryName(cat)))
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 2)
                                ForEach(items, id: \.key) { item in
                                    Button { pick(item.key) } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: PipelineGlyphs.category(cat))
                                                .font(.system(size: 11))
                                                .foregroundStyle(Palette.textSecondary)
                                                .frame(width: 16)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(verbatim: item.spec.t.local)
                                                    .font(Typo.panelRow)
                                                    .foregroundStyle(item.spec.exec ? Palette.text : Palette.textFaint)
                                                Text(verbatim: item.spec.exec ? item.spec.d.local : String(localized: "Not in the engine yet"))
                                                    .font(Typo.meta)
                                                    .foregroundStyle(Palette.textTertiary)
                                                    .lineLimit(2)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                    }
                                    .buttonStyle(.row())
                                    .disabled(!item.spec.exec)
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 320, height: 420)
    }

    private func matches(_ item: (key: String, spec: PipelineModuleSpec)) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return item.spec.t.uk.lowercased().contains(q) || item.spec.t.en.lowercased().contains(q)
            || item.spec.d.local.lowercased().contains(q) || item.key.contains(q)
    }
}

private extension CGFloat {
    func rounded(toStep step: CGFloat) -> CGFloat { (self / step).rounded() * step }
}
