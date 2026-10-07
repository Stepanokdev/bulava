import XCTest
import SwiftUI
@testable import Bulava

/// Pictures of the corner cards and the repair row, for a person to look at — light and dark, a
/// long Ukrainian refusal included. Written only when asked: `BULAVA_SNAPSHOT_DIR=/some/dir`.
nonisolated final class ErrorSurfacesSnapshotTests: XCTestCase {

    @MainActor
    func testRenderTheCardsAndTheRepairRow() throws {
        guard let out = ProcessInfo.processInfo.environment["BULAVA_SNAPSHOT_DIR"], !out.isEmpty else {
            throw XCTSkip("set BULAVA_SNAPSHOT_DIR to write the pictures")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = AppModel()
        m.toast = ToastMessage(title: "Движок не оновлено",
                               text: "Движок не можна оновити, поки ще працює watchdog.sh з попереднього запуску. Спробуйте, коли роботу буде завершено.",
                               kind: .error, key: "engine.install",
                               actions: [ToastAction(title: "Показати, що його тримає") {}])
        m.toast = ToastMessage(text: "Налаштування збережено", kind: .success)
        for _ in 0..<3 { m.toast = ToastMessage(text: "Не вдалося зберегти PDF", kind: .error, detail: "CGPDFContextCreate: /Users/x/report.pdf — Permission denied") }
        m.toast = ToastMessage(title: "Bulava виправляє те, що зупинило повідомлення",
                               text: "Codex шукає причину в «pocket-ledger». Щойно виправить, повідомлення піде знову.",
                               kind: .info, key: "repair.x", actions: [ToastAction(title: "Зупинити", primary: false) {}],
                               inProgress: true)

        let chat = UUID()
        var repair = ChatRepair(chatID: chat, entryID: UUID(), code: "chat.start_failed",
                                error: "Night Shift did not start.\nsupervisor-lib.sh: line 1271: watchdog.pid: Permission denied",
                                fingerprint: "6e4c198cc48c6598")
        let phases: [(String, ChatRepair.Phase)] = [
            ("offered", .offered), ("running", .running),
            ("notfixed", .notFixed(summary: "Тека стану цього проєкту належала іншому користувачу, тож Night Shift не міг записати watchdog.pid. Змінити власника можна лише з правами адміністратора.")),
            ("needsyou", .needsYou(summary: "Потрібно увійти в Claude Code: у терміналі виконай claude auth login, а тоді надішли повідомлення ще раз.")),
        ]

        for scheme in [ColorScheme.light, .dark] {
            let stack = VStack(alignment: .trailing, spacing: 8) {
                ForEach(m.toasts.reversed()) { ToastCard(toast: $0) }
            }
            .padding(24)
            .background(Palette.content)
            .environment(m)
            .environment(\.colorScheme, scheme)
            try write(stack, to: "\(out)/cards-\(scheme == .dark ? "dark" : "light").png")

            for (name, phase) in phases {
                repair.phase = phase
                repair.startedAt = Date().addingTimeInterval(-47)
                let row = RepairRow(repair: repair)
                    .frame(width: 640)
                    .padding(20)
                    .background(Palette.content)
                    .environment(m)
                    .environment(\.colorScheme, scheme)
                try write(row, to: "\(out)/repair-\(name)-\(scheme == .dark ? "dark" : "light").png")
            }
        }
    }

    @MainActor
    private func write(_ view: some View, to path: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("could not render \(path)")
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
