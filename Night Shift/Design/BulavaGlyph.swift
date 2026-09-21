import CoreGraphics
import Foundation

nonisolated enum BulavaGlyph {

    static let inkBounds = CGRect(x: 324, y: 216, width: 401.5, height: 591)

    static let svgPath: String =
        "M550.1 216 L567.9 216 L576.9 217.6 L586.7 220.9 L596.3 225.7 L603.7 230.6 L613.4 239.5 L622.2"
        + " 251.6 L627.1 261.3 L632 279.2 L632 300.3 L628.7 313.4 L621.5 328.7 L619.2 330.6 L615 337.6"
        + " L602.8 349 L588.6 357.2 L580.4 366.2 L577.2 375.2 L577.2 407.6 L581.3 416.6 L588.6 423.1 L610"
        + " 430.5 L626.2 438.6 L652 455.5 L673 474.1 L673.2 475.5 L680.3 482.2 L691.6 496.7 L700.5 510.5"
        + " L710.2 529.8 L719.1 554.9 L723.1 572.6 L725.5 592.1 L725.5 621.2 L722.3 645.5 L715.8 669.7"
        + " L709.4 686.7 L700.5 704.4 L683.5 730.3 L674.8 739.4 L674.7 740.8 L652.8 761.8 L642.4 769.8"
        + " L622.1 782.8 L603.6 791.6 L588.2 797.3 L570.5 802.1 L543 806.2 L529.1 806.2 L528.4 807 L505"
        + " 806.2 L479.1 802.1 L447.5 792.4 L424.2 781.2 L408.8 771.4 L395.1 761 L373.3 740 L353.9 714.2"
        + " L341.8 691.5 L331.3 663.2 L326.4 642.3 L324 621.2 L324 234.9 L327.3 226.6 L332.2 221.7 L341.3"
        + " 218.4 L436.5 218.4 L444.8 221.7 L449.7 226.6 L452.2 231.5 L453 235.7 L453 620.4 L453.8 626.1"
        + " L457.9 639.9 L465.2 653.7 L470 660.1 L481.3 670.7 L496.7 679.6 L506.5 682.8 L514.6 684.4 L534.9"
        + " 684.4 L553.6 679.6 L563.3 674.7 L574.6 666.6 L581.1 660.1 L590 648 L594.9 638.3 L598.9 625.3"
        + " L600.6 614.8 L599.7 594.4 L594.9 577.4 L584.4 559.6 L570.6 545.8 L559.2 538.5 L557.2 538.5 L552"
        + " 535.3 L536.5 531.3 L521.1 530.4 L508.1 532.1 L498.7 535.3 L491.2 535.3 L483.7 530.3 L481.2 525.3"
        + " L481.2 436.5 L482.9 431.5 L489.4 424.1 L495.2 421.6 L500.3 421.6 L516.2 418.4 L525.2 418.4 L531"
        + " 416.7 L536.8 411.8 L540.1 404.3 L540.1 375.2 L536.8 366.2 L528.7 357.2 L516.8 350.6 L504.7 340"
        + " L496.6 329.6 L490.1 316.6 L485.3 296.3 L485.3 284.1 L486.9 273.5 L490.1 263 L495.8 251.7 L508"
        + " 236.2 L521.7 225.8 L529.8 221.7 Z"

    // MARK: - CoreGraphics

    static func cgPath(in rect: CGRect) -> CGPath {
        let scale = min(rect.width / inkBounds.width, rect.height / inkBounds.height)
        var t = CGAffineTransform(
            translationX: rect.midX - inkBounds.width * scale / 2 - inkBounds.minX * scale,
            y: rect.midY - inkBounds.height * scale / 2 - inkBounds.minY * scale)
            .scaledBy(x: scale, y: scale)
        return unitPath().copy(using: &t) ?? unitPath()
    }

    private static func unitPath() -> CGPath {
        let p = CGMutablePath()
        var pendingX: CGFloat?
        var started = false
        for token in svgPath.split(separator: " ") {

            let text = (token.first?.isLetter ?? false) ? token.dropFirst() : token[...]
            guard let value = Double(text) else { continue }
            guard let x = pendingX else { pendingX = CGFloat(value); continue }
            let point = CGPoint(x: x, y: CGFloat(value))
            if started { p.addLine(to: point) } else { p.move(to: point); started = true }
            pendingX = nil
        }
        p.closeSubpath()
        return p
    }

    // MARK: - SVG

    static func svg(size: CGFloat, color: String = "currentColor") -> String {
        let b = inkBounds
        return "<svg width=\"\(Int((size * b.width / b.height).rounded()))\" height=\"\(Int(size))\" "
            + "viewBox=\"\(Int(b.minX)) \(Int(b.minY)) \(Int(b.width.rounded())) \(Int(b.height))\" "
            + "fill=\"\(color)\" xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\">"
            + "<path d=\"\(svgPath)\"/></svg>"
    }
}

nonisolated extension CGPath {

    var points: [CGPoint] {
        var out: [CGPoint] = []
        applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: out.append(element.pointee.points[0])
            default: break
            }
        }
        return out
    }
}
