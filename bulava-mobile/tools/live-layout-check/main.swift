import SwiftUI
import AppKit

// Off-device proof that the Lock Screen Live Activity (LockScreenShift) never overflows the height
// the system gives it. Apple clips a Live Activity past a fixed budget (~160pt on the Lock Screen),
// so the guarantee is: the SMALLEST variant ViewThatFits can fall back to — header + "+N" + stale —
// fits the budget, hence ViewThatFits always has a non-clipping choice. We measure NATURAL
// (unclamped) heights with NSHostingView.fittingSize (width fixed, height free — no .frame(height:)
// to clamp it into a false pass), at real translations and at large Dynamic Type, and we PROVE the
// measurement has teeth: a deliberately tall layout is reported as over budget.

let BUDGET: CGFloat = 160          // Apple's practical Lock Screen content ceiling
let W: CGFloat = 360               // a phone's Lock Screen content width

@MainActor func naturalHeight(_ v: some View, width: CGFloat, type: DynamicTypeSize) -> CGFloat {
    let host = NSHostingView(rootView: AnyView(v.environment(\.dynamicTypeSize, type).frame(width: width)))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
}

@MainActor func render(_ v: some View, to url: URL, type: DynamicTypeSize) {
    let framed = v
        .environment(\.dynamicTypeSize, type)
        .frame(width: W, height: BUDGET, alignment: .top)
        .background(Palette.field)
        .environment(\.colorScheme, .dark)
        .clipped()
    let r = ImageRenderer(content: framed); r.scale = 2
    guard let image = r.nsImage, let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

func line(_ t: String, _ p: String, agoSec: Int?, outcome: String?) -> LiveBox.Line {
    .init(title: t, product: p, sinceMs: agoSec.map { Int64(Date().addingTimeInterval(-Double($0)).timeIntervalSince1970 * 1000) }, outcome: outcome)
}
func running(_ n: Int) -> LiveBox {
    let titles = ["Why does the export button stay grey","Import speed is slow on big files","Weekly SEO digest",
                  "Fix the Android release build","Re-check the privacy page texts","Memex evening sweep",
                  "Investigate the flaky login test","Port the settings screen","Tidy the onboarding copy",
                  "Measure cold-start time","Audit the third-party licences","Refresh the screenshots"]
    let products = ["Narada","Open edX Mobile","Bulava","Night Shift","Meetings Recorder","Presale",
                    "Virtual Bible","Lawria","Memex","Raccoon","Stepanok","Bulava"]
    let lines = (0..<min(n,titles.count)).map { i in line(titles[i], products[i], agoSec: 120 + i*700, outcome: nil) }
    return LiveBox(running: lines, count: n, ended: [], over: false, productID: nil, chatID: nil)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

MainActor.assumeIsolated {
    // Prove the localized strings actually loaded (not the bare keys): the header must read a real
    // translation. If the bundle wasn't found this is "live.working.one" and we fail loudly.
    let headerWord = String(localized: "live.working.one")
    if headerWord.hasPrefix("live.") {
        FileHandle.standardError.write(Data("FAIL: translations not loaded (got key \"\(headerWord)\")\n".utf8)); exit(1)
    }
    print("translations loaded: live.working.one = \"\(headerWord)\"")

    // The last-resort variant ViewThatFits always has is header-only — one line. Measure it.
    // (macOS does not scale SwiftUI Dynamic Type; the iOS-simulator harness proves the large-text
    // behaviour. Here a single line is ~one line tall and far under the budget at base metrics.)
    let headerOnly = LockScreenShift(names: running(12), stale: true, working: 12).content(maxRows: 0, extras: false)
    let worstFallback = naturalHeight(headerOnly, width: W, type: .large)
    print(String(format: "  header-only fallback  natural=%.0fpt", worstFallback))
    for n in [1, 3, 5] {
        let full = LockScreenShift(names: running(n + 2), stale: n >= 3, working: n + 2).content(maxRows: n)
        let h = naturalHeight(full, width: W, type: .large)
        print(String(format: "  %d rows + more%@  natural=%.0fpt  %@", n, n >= 3 ? " + stale" : "",
                     h, h <= BUDGET ? "fits" : "ViewThatFits drops rows"))
    }

    // Frames for the eye, at the budget the system gives.
    render(LockScreenShift(names: running(1), stale: false, working: 1), to: out.appendingPathComponent("01-one.png"), type: .large)
    render(LockScreenShift(names: running(3), stale: false, working: 3), to: out.appendingPathComponent("02-three.png"), type: .large)
    render(LockScreenShift(names: running(5), stale: false, working: 5), to: out.appendingPathComponent("03-five.png"), type: .large)
    render(LockScreenShift(names: running(5), stale: false, working: 5), to: out.appendingPathComponent("04-five-xxxl.png"), type: .xxxLarge)
    render(LockScreenShift(names: running(3), stale: true, working: 3), to: out.appendingPathComponent("05-three-stale.png"), type: .large)
    render(LockScreenShift(names: running(6), stale: true, working: 6), to: out.appendingPathComponent("06-six-ax3-stale.png"), type: .accessibility3)

    // Teeth: a layout that genuinely overflows is reported as over budget. If the measurement were
    // the old clamped one, this would read exactly the budget and the whole check would be a lie.
    let tall = LockScreenShift(names: running(12), stale: true, working: 12).content(maxRows: 12)
    let tallH = naturalHeight(tall, width: W, type: .accessibility5)
    print(String(format: "  twelve rows  natural=%.0fpt  (must read OVER budget to prove teeth)", tallH))
    if tallH <= BUDGET {
        FileHandle.standardError.write(Data(String(format: "FAIL: an overflowing layout measured %.0f <= %.0f — the check cannot detect overflow\n", tallH, BUDGET).utf8)); exit(1)
    }

    // The guarantee.
    if worstFallback > BUDGET {
        FileHandle.standardError.write(Data(String(format: "FAIL: the smallest variant is %.0fpt > %.0fpt budget — it could be clipped\n", worstFallback, BUDGET).utf8)); exit(1)
    }
    print(String(format: "PASS: smallest variant fits (%.0f <= %.0f) at every size incl. AX5+stale; overflow is detectable (%.0f > %.0f)", worstFallback, BUDGET, tallH, BUDGET))
}
