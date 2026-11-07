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

    /// A Mac without tmux (5 Nov, 1.17): the message that did not go, the row that installs tmux
    /// under it, and the corner card — reached through the same call a start makes with the
    /// engine's refusal (`engine/tests/test-missing-tool.sh` pins that output). Run once per app
    /// language: `xcodebuild … -testLanguage uk`.
    @MainActor
    func testRenderTheMissingToolRow() throws {
        guard let out = ProcessInfo.processInfo.environment["BULAVA_SNAPSHOT_DIR"], !out.isEmpty else {
            throw XCTSkip("set BULAVA_SNAPSHOT_DIR to write the pictures")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("BULAVA_STATE_DIR") }
        let m = AppModel()
        m.settings.shareErrorReports = false
        let product = m.products.add(name: "pocket-ledger")
        let chat = m.conversations.newChat(for: product.id)
        let sent = m.conversations.appendUser("Add a CSV export to the monthly report",
                                              productID: product.id, chatID: chat.id)
        m.conversations.updateDelivery(entryID: sent.id, .failed)
        XCTAssertTrue(m.stopOnStartTheyMustClear(
            chatID: chat.id, entryID: sent.id,
            output: "❌ tmux не встановлено (brew install tmux)\nstart-refused=tool:tmux"))
        XCTAssertNil(m.repairs[chat.id])
        let entry = try XCTUnwrap(m.conversations.entries(inChat: chat.id).first { $0.id == sent.id })
        let language = Bundle.main.preferredLocalizations.first ?? "en"

        for scheme in [ColorScheme.light, .dark] {
            let name = "\(language)-\(scheme == .dark ? "dark" : "light")"
            let thread = VStack(alignment: .trailing, spacing: 16) {
                EntryView(entry: entry, productID: product.id)
                ForEach(m.toasts.reversed()) { ToastCard(toast: $0) }
            }
            .frame(width: 760)
            .padding(24)
            .background(Palette.content)
            .environment(m)
            .environment(\.colorScheme, scheme)
            try write(thread, to: "\(out)/missing-tool-\(name).png")

            // A tool Bulava has no formula for: the row says what to do, and no button guesses.
            m.toolBlocked[chat.id] = "some-tool"
            let bare = EntryView(entry: entry, productID: product.id)
                .frame(width: 760).padding(24).background(Palette.content)
                .environment(m).environment(\.colorScheme, scheme)
            try write(bare, to: "\(out)/missing-tool-unknown-\(name).png")
            m.toolBlocked[chat.id] = "tmux"
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
