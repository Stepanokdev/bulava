import UIKit
import SwiftUI

// iOS-simulator measurement: unlike macOS, iOS scales SwiftUI Text with Dynamic Type, so this is
// where "large text" is really exercised. Measures the NATURAL (unclamped) height of each
// LockScreenShift variant at normal and at the largest accessibility text size, and checks:
//   * the smallest variant (header only) fits the Lock Screen budget even at AX5 (the guarantee);
//   * a full 3-row layout actually grows with text size (proves Dynamic Type is applied);
//   * a deliberately tall layout is measured OVER budget (teeth).
let W: CGFloat = 360, BUDGET: CGFloat = 160

func natural(_ view: some View, type: DynamicTypeSize) -> CGFloat {
    let host = UIHostingController(rootView: AnyView(view.environment(\.dynamicTypeSize, type)))
    host.view.backgroundColor = .clear
    let target = CGSize(width: W, height: UIView.layoutFittingCompressedSize.height)
    let size = host.view.systemLayoutSizeFitting(target,
                                                 withHorizontalFittingPriority: .required,
                                                 verticalFittingPriority: .fittingSizeLevel)
    return size.height
}

func line(_ t: String, _ p: String, agoSec: Int?) -> LiveBox.Line {
    .init(title: t, product: p, sinceMs: agoSec.map { Int64(Date().addingTimeInterval(-Double($0)).timeIntervalSince1970 * 1000) }, outcome: nil)
}
func running(_ n: Int) -> LiveBox {
    let t = ["Why does the export button stay grey","Import speed is slow","Weekly SEO digest","Android build","Privacy page","Memex sweep","Flaky login","Settings screen","Onboarding copy","Cold start","Licences","Screenshots"]
    let p = ["Narada","Open edX Mobile","Bulava","Night Shift","Meetings","Presale","VBS","Lawria","Memex","Raccoon","Stepanok","Bulava"]
    return LiveBox(running: (0..<min(n,t.count)).map { line(t[$0], p[$0], agoSec: 120+$0*600) }, count: n, ended: [], over: false, productID: nil, chatID: nil)
}

@main
enum IOSMeasure {
    @MainActor static func main() {
        var fail = false
        func require(_ cond: Bool, _ msg: String) { print((cond ? "  ok  " : "  FAIL ") + msg); if !cond { fail = true } }


        // Header-only fallback fits at any size, including AX5 + stale + many runs.
        for (label, size) in [("large", DynamicTypeSize.large), ("AX5", .accessibility5)] {
            let h = natural(LockScreenShift(names: running(12), stale: true, working: 12).content(maxRows: 0, extras: false), type: size)
            require(h <= BUDGET, String(format: "header-only fallback @ %@ = %.0fpt <= %.0f", label, h, BUDGET))
        }
        // Dynamic Type is really applied: the same content is taller at AX5 than at large.
        let full = LockScreenShift(names: running(3), stale: false, working: 3)
        let hL = natural(full.content(maxRows: 3), type: .large)
        let hA = natural(full.content(maxRows: 3), type: .accessibility5)
        print(String(format: "  three rows: large=%.0fpt  AX5=%.0fpt", hL, hA))
        require(hA > hL + 20, "large text grows the layout (AX5 noticeably taller than large)")
        // Teeth: a tall layout is over budget.
        let tall = natural(LockScreenShift(names: running(12), stale: true, working: 12).content(maxRows: 12), type: .accessibility5)
        require(tall > BUDGET, String(format: "twelve rows @ AX5 = %.0fpt > %.0f (overflow is detectable)", tall, BUDGET))

        print(fail ? "IOS-LAYOUT: FAIL" : "IOS-LAYOUT: PASS")
        exit(fail ? 1 : 0)
    }
}
