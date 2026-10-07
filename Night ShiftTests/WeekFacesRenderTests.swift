import AppKit
import SwiftUI
import XCTest
@testable import Bulava

/// Draws every widget face at the sizes macOS and iOS give widgets, in both appearances, and checks
/// that each one is drawn — not an empty frame. With `BULAVA_WEEK_RENDER_DIR` set, the pictures are
/// written there to be looked at.
nonisolated final class WeekFacesRenderTests: XCTestCase {

    private struct Slot { let kind: WeekFaceKind; let size: WeekFaceSize; let w: CGFloat; let h: CGFloat }

    private static let mac: [(WeekFaceSize, CGFloat, CGFloat)] = [(.small, 170, 170), (.medium, 364, 170), (.large, 364, 382)]
    private static let phone: [(WeekFaceSize, CGFloat, CGFloat)] = [(.small, 158, 158), (.medium, 338, 158), (.large, 338, 354)]

    private static func sizes(for kind: WeekFaceKind) -> Set<WeekFaceSize> {
        switch kind {
        case .autonomy, .outcomes, .receipt: [.small, .medium, .large]
        case .rhythm, .volume, .limits: [.small, .medium]
        case .now: [.small, .medium, .large]
        case .week: [.large]
        }
    }

    @MainActor
    private func render(_ view: some View, w: CGFloat, h: CGFloat, dark: Bool) -> NSImage? {
        let framed = view
            .padding(15)
            .frame(width: w, height: h)
            .background(WeekPalette.field)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        var image: NSImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        return image
    }

    @MainActor
    private func write(_ image: NSImage, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["BULAVA_WEEK_RENDER_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }

    /// The share of pixels that differ from the face's background: a face with nothing drawn on it
    /// has none.
    @MainActor
    private func inkShare(_ image: NSImage) -> Double {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bg = (pixels[(h / 2 * w + 4) * 4], pixels[(h / 2 * w + 4) * 4 + 1], pixels[(h / 2 * w + 4) * 4 + 2])
        var ink = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let d = abs(Int(pixels[i]) - Int(bg.0)) + abs(Int(pixels[i + 1]) - Int(bg.1)) + abs(Int(pixels[i + 2]) - Int(bg.2))
            if d > 60 { ink += 1 }
        }
        return Double(ink) / Double(w * h)
    }

    @MainActor
    private func drawAll(_ snapshot: WeekSnapshot?, label: String, stale: Bool = false) throws {
        let now = stale ? (snapshot?.generatedAt ?? .now).addingTimeInterval(2 * 86400) : (snapshot?.generatedAt ?? .now)
        for kind in WeekFaceKind.allCases {
            for (place, table) in [("mac", Self.mac), ("phone", Self.phone)] {
                for (size, w, h) in table where Self.sizes(for: kind).contains(size) {
                    for dark in [false, true] {
                        let face = WeekFaceView(kind: kind, size: size, snapshot: snapshot,
                                                place: place == "mac" ? .mac : .phone, now: now)
                        let image = try XCTUnwrap(render(face, w: w, h: h, dark: dark))
                        let ink = inkShare(image)
                        XCTAssertGreaterThan(ink, 0.004, "\(label) \(kind) \(size) \(place) dark=\(dark) is blank")
                        try write(image, "\(label)/\(place)-\(kind.rawValue)-\(size)-\(dark ? "dark" : "light")")
                    }
                }
            }
        }
    }

    @MainActor
    func testEveryFaceIsDrawnFromTheSampleWeek() throws {
        try drawAll(LinkContractTests.week, label: "sample")
    }

    @MainActor
    func testAStaleWeekSaysHowOldItIs() throws {
        try drawAll(LinkContractTests.week, label: "stale", stale: true)
    }

    @MainActor
    func testStatisticsOffSaysSoInsteadOfZero() throws {
        var off = LinkContractTests.week
        off.off = true
        try drawAll(off, label: "off")
    }

    @MainActor
    func testNoWeekYetSaysWhatToDo() throws {
        try drawAll(nil, label: "none")
    }

    /// The real week of this Mac, when asked for (`TEST_RUNNER_BULAVA_REAL_WEEK=1`).
    /// The same week said in Ukrainian: the longest of the three languages, the one that overflows first.
    @MainActor
    func testTheWeekInUkrainianFits() throws {
        LanguageBundle.adopt(.uk)
        defer { LanguageBundle.adopt(.en) }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        let en = LinkContractTests.week
        let now = en.generatedAt
        var raw = WeekRaw.empty(now: now, calendar: calendar)
        raw.agentSec = [60_900, 35_340, 20_340, 0, 0, 0, 0]; raw.wallSec = [46_380, 29_280, 19_560, 0, 0, 0, 0]
        raw.heatSec[0][21] = 5_400; raw.heatSec[1][10] = 3_600; raw.heatSec[2][1] = 1_800
        raw.prompts = [15, 28, 6, 0, 0, 0, 0]; raw.passed = [4, 4, 3, 0, 0, 0, 0]; raw.debt = [3, 6, 1, 0, 0, 0, 0]
        raw.waiting = [4, 3, 0, 0, 0, 0, 0]; raw.added = [7_382, 4_045, 7_698, 0, 0, 0, 0]; raw.removed = [56, 88, 95, 0, 0, 0, 0]
        raw.costPerDay = [275, 199, 181, 0, 0, 0, 0]; raw.files = 108; raw.tokensOut = 4_720_931; raw.cacheRead = 2_014_752_352
        raw.codexTokens = 17_799_694; raw.commits = 15; raw.longestSec = 14_280; raw.peakParallel = 2
        let claude = UsageSnapshot(fiveHour: UsageWindow(usedPercent: 17, resetsAt: now.addingTimeInterval(3 * 3600)),
                                   sevenDay: UsageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(141 * 3600)),
                                   plan: "team", updatedAt: now, present: true)
        let codex = UsageSnapshot(fiveHour: UsageWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(1 * 3600)),
                                  sevenDay: UsageWindow(usedPercent: 38, resetsAt: now.addingTimeInterval(78 * 3600)),
                                  plan: "plus", updatedAt: now, present: true)
        let running = [WeekNowLine(name: "Віджети на тиждень", since: now.addingTimeInterval(-47 * 60), waiting: false),
                       WeekNowLine(name: "Експорт звітів", since: now.addingTimeInterval(-12 * 60), waiting: false),
                       WeekNowLine(name: "Шрифти в PDF", since: nil, waiting: true)]
        let uk = WeekPresenter(raw: raw, capacity: CapacitySnapshot(claude: claude, codex: codex), running: running,
                               off: false, now: now, locale: Locale(identifier: "uk"), calendar: calendar).snapshot()
        XCTAssertEqual(uk.days.first, "Пн")
        XCTAssertEqual(uk.autonomy.title, "Без тебе")
        XCTAssertEqual(uk.now.unit, "агенти", "two agents: the plural for two")
        if let dir = ProcessInfo.processInfo.environment["BULAVA_WEEK_RENDER_DIR"], let data = uk.encoded() {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("week-uk.json"))
        }
        try drawAll(uk, label: "uk")
    }

    @MainActor
    func testTheRealWeek() async throws {
        guard ProcessInfo.processInfo.environment["BULAVA_REAL_WEEK"] == "1" else { throw XCTSkip("real data not requested") }
        let raw = await WeekCollector().collect()
        let supervisor = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/supervisor")
        func usage(_ name: String) -> UsageSnapshot {
            (try? Data(contentsOf: supervisor.appendingPathComponent(name))).flatMap(UsageSnapshot.decode(from:)) ?? .empty
        }
        let capacity = CapacitySnapshot(claude: usage("usage.json"), codex: usage("codex-usage.json"))
        let snapshot = WeekPresenter(raw: raw, capacity: capacity, running: [], off: false, now: Date()).snapshot()
        try drawAll(snapshot, label: "real")
    }
}
