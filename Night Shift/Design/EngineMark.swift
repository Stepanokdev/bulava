import SwiftUI

/// The two engines, drawn rather than spelled.
///
/// The composer used to say "Claude + Codex" in words, and the words were what made that row long
/// enough that the model and its depth had nowhere to sit — they went behind a menu, and he could
/// not tell what a message was about to run on without opening it. A mark reads at a glance and
/// gives the horizontal space back to what actually changes: the model's name, and how deep it
/// thinks.
nonisolated enum Engine: String, Identifiable, CaseIterable, Sendable {

    case claude, codex

    var id: String { rawValue }

    /// The vendor's own name for it. Never translated.
    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex:  "Codex"
        }
    }
}

/// Claude's burst: petals radiating from the middle, widest halfway out.
nonisolated struct ClaudeMark: Shape {

    var petals = 11

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.09
        let waist = outer * 0.40
        let step = CGFloat.pi * 2 / CGFloat(petals)
        let spread = step * 0.34

        func point(_ angle: CGFloat, _ radius: CGFloat) -> CGPoint {
            CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
        }

        var path = Path()
        for i in 0..<petals {
            let angle = step * CGFloat(i) - .pi / 2
            let root = point(angle, inner)
            path.move(to: root)
            path.addQuadCurve(to: point(angle, outer), control: point(angle + spread, waist))
            path.addQuadCurve(to: root, control: point(angle - spread, waist))
            path.closeSubpath()
        }
        path.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner,
                                   width: inner * 2, height: inner * 2))
        return path
    }
}

/// Codex's knot: three crossed loops, the way the hexagonal mark is built.
nonisolated struct CodexMark: Shape {

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let loop = CGRect(x: c.x - side / 2, y: c.y - side * 0.235,
                          width: side, height: side * 0.47)

        var path = Path()
        for turn in 0..<3 {
            let spin = CGAffineTransform(translationX: c.x, y: c.y)
                .rotated(by: .pi / 3 * CGFloat(turn))
                .translatedBy(x: -c.x, y: -c.y)
            path.addPath(Path(ellipseIn: loop), transform: spin)
        }
        return path
    }
}

/// One engine's mark, at the size an inline label wants.
nonisolated struct EngineGlyph: View {

    let engine: Engine
    var size: CGFloat = 11
    var tint: Color = Palette.textSecondary

    var body: some View {
        Group {
            switch engine {
            case .claude:
                ClaudeMark().fill(tint)
            case .codex:
                // Stroked, not filled: the knot is a line drawing, and filling it would close
                // the lobes into a blob at eleven points across.
                CodexMark().stroke(tint, style: StrokeStyle(lineWidth: max(1, size * 0.105),
                                                            lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Both marks side by side, for the mode where Claude works and Codex reviews.
nonisolated struct EnginePairGlyph: View {

    var size: CGFloat = 11
    var tint: Color = Palette.textSecondary

    var body: some View {
        HStack(spacing: 2) {
            EngineGlyph(engine: .claude, size: size, tint: tint)
            EngineGlyph(engine: .codex, size: size, tint: tint)
        }
    }
}

nonisolated extension ChatEngineMode {

    /// The engines this mode actually runs, in the order they run in.
    var engines: [Engine] {
        switch self {
        case .claude:         [.claude]
        case .codex:          [.codex]
        case .claudeAndCodex: [.claude, .codex]
        }
    }

    /// The short name for a segmented control, where the marks already say which engine it is.
    var shortLabel: String {
        switch self {
        case .claude:         "Claude"
        case .codex:          "Codex"
        case .claudeAndCodex: "Both"
        }
    }
}
