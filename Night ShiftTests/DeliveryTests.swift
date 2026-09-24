import XCTest
@testable import Bulava

nonisolated final class DeliveryTests: XCTestCase {

    private var reports: URL!
    private var run: URL!
    private let runID = "0dc87ef6"

    override func setUpWithError() throws {
        reports = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-delivery-\(UUID().uuidString)", isDirectory: true)
        run = reports.appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: reports)
    }

    private func write(_ name: String, _ bytes: Int = 8) throws {
        try Data(repeating: 0x41, count: bytes).write(to: run.appendingPathComponent(name))
    }

    private func blocks(manifest: ReportManifest? = nil) -> [ConversationBlock] {
        AppModel.deliveryBlocks(runID: runID, directory: run, manifest: manifest)
    }

    // MARK: - What comes out

    func testAnEmptyRunDeliversNothing() {
        XCTAssertTrue(blocks().isEmpty, "a run with no artifacts must not post an empty card")
    }

    func testFramesBecomeOneGalleryAndFilesBecomeTheirOwnCards() throws {
        for name in ["before-1.png", "after-1.png", "before-2.png", "after-2.png"] { try write(name) }
        try write("walkthrough.mp4", 1024)
        try write("lawria-applinks.zip", 2048)
        try write("build.log")

        let out = blocks()
        let galleries = out.filter { $0.kind == .gallery }
        let files = out.filter { $0.kind == .file }

        XCTAssertEqual(galleries.count, 1, "frames belong together, not four cards")
        XCTAssertEqual(galleries.first?.artifacts.count, 4)
        XCTAssertEqual(Set(files.map(\.artifacts.first!.displayName)),
                       ["walkthrough.mp4", "lawria-applinks.zip", "build.log"])
    }

    func testTheArchiveResolvesToARealFileAndCarriesItsSize() throws {
        try write("lawria-applinks.zip", 24_576)
        let ref = try XCTUnwrap(blocks().first { $0.kind == .file }?.artifacts.first)
        XCTAssertEqual(ref.kind, .archive)
        XCTAssertEqual(ref.byteSize, 24_576)
        let url = try XCTUnwrap(ref.resolve(base: reports), "a delivered file must actually open")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTheDocumentAndItsManifestAreNotDeliveredTwice() throws {
        try write("report.html", 4096)
        try write("report.json", 512)
        try write("notes.md")
        let names = blocks().filter { $0.kind == .file }.compactMap(\.artifacts.first?.displayName)
        XCTAssertEqual(names, ["notes.md"], "the rendered report has its own card and its own reader")
    }

    func testTheManifestsOrderIsKept() throws {
        for name in ["after-1.png", "before-1.png", "after-2.png", "before-2.png"] { try write(name) }
        let manifest = try JSONDecoder().decode(ReportManifest.self, from: Data(#"""
        {"format":"photos","items":[{"before":"before-1.png","after":"after-1.png"},
                                    {"before":"before-2.png","after":"after-2.png"}]}
        """#.utf8))
        let gallery = try XCTUnwrap(blocks(manifest: manifest).first { $0.kind == .gallery })
        XCTAssertEqual(gallery.artifacts.map(\.displayName),
                       ["before-1.png", "after-1.png", "before-2.png", "after-2.png"])
        XCTAssertEqual(gallery.text, String(localized: "Before and after"),
                       "the caption is localized; compare against the catalog, not the key")
    }

    func testFramesWithNoManifestStillDeliverInAStableOrder() throws {
        for name in ["num-3.png", "num-1.png", "num-2.png"] { try write(name) }
        let gallery = try XCTUnwrap(blocks().first { $0.kind == .gallery })
        XCTAssertEqual(gallery.artifacts.map(\.displayName), ["num-1.png", "num-2.png", "num-3.png"])
    }

    func testADeliveredNameCannotReachOutOfItsRun() throws {
        let sibling = reports.appendingPathComponent("other-run", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: sibling.appendingPathComponent("secret.txt"))

        let escape = ArtifactRef(runID: runID, relativePath: "../other-run/secret.txt")
        XCTAssertNil(escape.resolve(base: reports))
    }

    func testEveryDeliveredBlockIsRenderable() throws {
        try write("after-1.png"); try write("pack.zip", 64)
        for block in blocks() {
            XCTAssertTrue(block.isRenderable, "\(block.kind) would leave a blank gap in the feed")
        }
    }
}

// MARK: - Nested reports

nonisolated final class NestedDeliveryTests: XCTestCase {

    private var reports: URL!
    private var run: URL!
    private let runID = "0dc87ef6"

    override func setUpWithError() throws {
        reports = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bulava-nested-\(UUID().uuidString)", isDirectory: true)
        run = reports.appendingPathComponent(runID, isDirectory: true)
        let fm = FileManager.default
        for sub in ["", "verify", "evidence/2f9c", "build", "checks"] {
            try fm.createDirectory(at: run.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for path in ["num-1.png", "num-2.png", "report.json", "report.html", ".DS_Store",
                     "verify/verify.log", "verify/shot-1440.png",
                     "evidence/2f9c/build.log", "evidence/2f9c/syslog.txt",
                     "build/app-release.aab", "checks/gate.json"] {
            try Data(repeating: 0x41, count: 16).write(to: run.appendingPathComponent(path))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: reports)
    }

    private func blocks() -> [ConversationBlock] {
        AppModel.deliveryBlocks(runID: runID, directory: run,
                                manifest: AppModel.manifest(in: run))
    }

    func testNestedArtifactsAreDelivered() throws {
        let names = blocks().filter { $0.kind == .file }
            .compactMap(\.artifacts.first?.relativePath)
        XCTAssertTrue(names.contains("verify/verify.log"), "a run's own verification is the proof")
        XCTAssertTrue(names.contains("evidence/2f9c/build.log"))
        XCTAssertTrue(names.contains("evidence/2f9c/syslog.txt"))
        XCTAssertTrue(names.contains("build/app-release.aab"))
        XCTAssertTrue(names.contains("checks/gate.json"))
    }

    func testNestedFramesJoinTheGallery() throws {
        let gallery = try XCTUnwrap(blocks().first { $0.kind == .gallery })
        let paths = gallery.artifacts.map(\.relativePath)
        XCTAssertTrue(paths.contains("verify/shot-1440.png"), "a frame two levels down is a frame")
        XCTAssertTrue(paths.contains("num-1.png"))
    }

    func testTheDocumentAndTheNoiseStayOut() throws {
        let names = blocks().flatMap { $0.artifacts.map(\.relativePath) }
        XCTAssertFalse(names.contains("report.html"))
        XCTAssertFalse(names.contains("report.json"))
        XCTAssertFalse(names.contains(".DS_Store"))
    }

    func testEveryNestedReferenceStillResolves() throws {
        for block in blocks() {
            for ref in block.artifacts {
                XCTAssertNotNil(ref.resolve(base: reports),
                                "\(ref.relativePath) was delivered but cannot be opened")
            }
        }
    }

    func testAHugeDirectoryIsCappedRatherThanDumped() throws {
        for n in 0..<(AppModel.deliveryCeiling + 40) {
            try Data("x".utf8).write(to: run.appendingPathComponent("verify/extra-\(n).log"))
        }
        XCTAssertLessThanOrEqual(AppModel.relativeFiles(in: run).count, AppModel.deliveryCeiling)
    }

    func testARealReportOnThisMachineDelivers() throws {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/supervisor/reports")
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: real.path)) ?? []
        let withSubdir = dirs.first { name in
            let d = real.appendingPathComponent(name)
            return ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).contains {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: d.appendingPathComponent($0).path,
                                               isDirectory: &isDir)
                return isDir.boolValue
            }
        }
        let id = try XCTUnwrap(withSubdir, "no nested report on this machine to check against")
        let dir = real.appendingPathComponent(id)
        let out = AppModel.deliveryBlocks(runID: id, directory: dir,
                                          manifest: AppModel.manifest(in: dir))
        XCTAssertFalse(out.isEmpty, "a real report delivered nothing")
        for block in out {
            for ref in block.artifacts {
                XCTAssertNotNil(ref.resolve(base: real), "\(ref.relativePath) cannot be opened")
            }
        }
    }
}

// MARK: - The frames are real

nonisolated final class GalleryDecodeTests: XCTestCase {

    func testEveryFrameOfARealReportResolvesAndDecodes() async throws {
        let reports = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/supervisor/reports")
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: reports.path)) ?? []

        var checked = 0
        for id in dirs.sorted() {
            let dir = reports.appendingPathComponent(id)
            let blocks = AppModel.deliveryBlocks(runID: id, directory: dir,
                                                 manifest: AppModel.manifest(in: dir))
            guard let gallery = blocks.first(where: { $0.kind == .gallery }) else { continue }
            for ref in gallery.artifacts.prefix(6) {
                let url = try XCTUnwrap(ref.resolve(base: reports),
                                        "\(ref.relativePath) is in a gallery and cannot be opened")
                let image = await ThumbnailCache.shared.load(url)
                XCTAssertNotNil(image, "\(ref.relativePath) is delivered as a frame but does not decode")
                checked += 1
            }
            break
        }
        try XCTSkipIf(checked == 0, "no report with frames on this machine")
        XCTAssertGreaterThan(checked, 0)
    }
}

// MARK: - A message parked in a run that no longer exists

nonisolated final class LostQueuedMessageTests: XCTestCase {

    @MainActor private func store() -> (ConversationStore, [URL]) {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        return (ConversationStore(fileURL: a, chatsURL: b), [a, b])
    }

    @MainActor
    func testAMessageWhoseRunIsGoneIsMarkedUndelivered() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        let old = s.append(user: "Братику, є фідбек по додатку", productID: product,
                           at: Date().addingTimeInterval(-3600))
        s.updateDelivery(entryID: old, .queued)

        let lost = s.failOrphanedQueued(inChat: s.currentChat(for: product).id, olderThan: 90)

        XCTAssertEqual(lost.count, 1)
        XCTAssertEqual(s.entry(id: old)?.delivery, .failed,
                       "a queue that no longer exists is not a queue")
    }

    @MainActor
    func testAMessageSentSecondsAgoIsLeftAlone() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        let fresh = s.append(user: "Полагодь експорт", productID: product, at: Date())
        s.updateDelivery(entryID: fresh, .queued)

        s.failOrphanedQueued(inChat: s.currentChat(for: product).id, olderThan: 90)

        XCTAssertEqual(s.entry(id: fresh)?.delivery, .queued,
                       "its run may still be coming up — 90 seconds is the grace, not a guess")
    }

    @MainActor
    func testWhatReachedTheWorkerIsNotTouched() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        let delivered = s.append(user: "Це дійшло", productID: product,
                                 at: Date().addingTimeInterval(-3600))
        let chat = s.currentChat(for: product).id
        s.failOrphanedQueued(inChat: chat, olderThan: 90)
        XCTAssertNil(s.entry(id: delivered)?.delivery)
        XCTAssertTrue(s.failOrphanedQueued(inChat: chat, olderThan: 90).isEmpty,
                      "nothing to announce means nothing is said")
    }

    @MainActor
    func testTheWarningLandsInTheChatThatLostTheMessage() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()

        let lostIn = s.currentChat(for: product).id
        let old = s.append(user: "Братику, є фідбек по додатку", productID: product,
                           at: Date().addingTimeInterval(-3600))
        s.updateDelivery(entryID: old, .queued)

        let openNow = s.newChat(for: product)
        s.appendUser("Інша розмова", productID: product, chatID: openNow.id)
        XCTAssertEqual(s.currentChatID(for: product), openNow.id)

        XCTAssertEqual(s.failOrphanedQueued(inChat: lostIn, olderThan: 90).count, 1)
        s.postEventOnce("Не дійшло: фідбек", productID: product, chatID: lostIn, tone: .problem)

        XCTAssertEqual(s.entries(inChat: lostIn).filter { $0.kind == .event }.count, 1,
                       "the warning belongs beside the message it is about")
        XCTAssertTrue(s.entries(inChat: openNow.id).allSatisfy { $0.kind != .event },
                      "and not in whichever thread happens to be open")
    }

    @MainActor
    func testTheSameWarningIsSaidOncePerChatAndNotSilencedInTheSecond() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        let first = s.currentChat(for: product).id
        s.appendUser("Перша розмова", productID: product, chatID: first)
        let second = s.newChat(for: product)
        s.appendUser("Друга розмова", productID: product, chatID: second.id)

        for _ in 0..<3 {
            s.postEventOnce("Не дійшло", productID: product, chatID: first, tone: .problem)
            s.postEventOnce("Не дійшло", productID: product, chatID: second.id, tone: .problem)
        }

        XCTAssertEqual(s.entries(inChat: first).filter { $0.kind == .event }.count, 1)
        XCTAssertEqual(s.entries(inChat: second.id).filter { $0.kind == .event }.count, 1,
                       "two chats with the same problem are two things to say, not one")
    }
}

private extension ConversationStore {

    @MainActor func append(user text: String, productID: UUID, at: Date) -> UUID {
        var e = ConversationEntry(productID: productID, kind: .user, at: at, text: text)
        e.chatID = currentChat(for: productID).id
        append(e)
        return e.id
    }
}
// MARK: - A parked message is waiting, not lost

nonisolated final class ParkedNotLostTests: XCTestCase {

    @MainActor private func store() -> (ConversationStore, [URL]) {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        return (ConversationStore(fileURL: a, chatsURL: b), [a, b])
    }

    @MainActor
    func testAMessageTheEngineStillHoldsIsNotDeclaredLost() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        var e = ConversationEntry(productID: product, kind: .user,
                                  at: Date().addingTimeInterval(-3600), text: "продовжуй")
        e.chatID = s.currentChat(for: product).id
        s.append(e)
        s.updateDelivery(entryID: e.id, .queued)

        let lost = s.failOrphanedQueued(inChat: e.chatID!, olderThan: 90, stillParked: [e.id])

        XCTAssertTrue(lost.isEmpty, "it is parked in the durable queue — it will be delivered")
        XCTAssertEqual(s.entry(id: e.id)?.delivery, .queued)
    }

    @MainActor
    func testAMessageInNobodysQueueIsStillReportedLost() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        var e = ConversationEntry(productID: product, kind: .user,
                                  at: Date().addingTimeInterval(-3600), text: "фідбек")
        e.chatID = s.currentChat(for: product).id
        s.append(e)
        s.updateDelivery(entryID: e.id, .queued)

        let lost = s.failOrphanedQueued(inChat: e.chatID!, olderThan: 90,
                                        stillParked: [UUID()])

        XCTAssertEqual(lost.count, 1)
        XCTAssertEqual(s.entry(id: e.id)?.delivery, .failed)
    }
}

// MARK: - Taking back a false claim

nonisolated final class WithdrawLostNoticeTests: XCTestCase {

    @MainActor private func store() -> (ConversationStore, [URL]) {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        return (ConversationStore(fileURL: a, chatsURL: b), [a, b])
    }

    @MainActor
    private func lostNotice(for text: String) -> String {
        String(format: String(localized: "This message never reached the worker — the run it was queued in is gone. Send it again: “%@”"),
               String(text.prefix(60)))
    }

    @MainActor
    func testTheNoticeGoesWhenTheMessageTurnsOutDelivered() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        var e = ConversationEntry(productID: product, kind: .user, text: "продовжуй")
        e.chatID = s.currentChat(for: product).id
        s.append(e)
        s.postEventOnce(lostNotice(for: "продовжуй"), productID: product, chatID: e.chatID!,
                        tone: .problem)
        XCTAssertEqual(s.entries(inChat: e.chatID!).filter { $0.kind == .event }.count, 1)

        XCTAssertTrue(s.withdrawLostNotice(for: e))

        XCTAssertTrue(s.entries(inChat: e.chatID!).allSatisfy { $0.kind != .event },
                      "the app must not leave its own false sentence on his screen")
        XCTAssertEqual(s.entries(inChat: e.chatID!).count, 1, "and his words stay")
    }

    @MainActor
    func testItOnlyEverRemovesItsOwnSentence() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        var e = ConversationEntry(productID: product, kind: .user, text: "продовжуй")
        e.chatID = s.currentChat(for: product).id
        s.append(e)
        s.postEvent("«orbit-console» зупинився", productID: product, tone: .problem)
        s.postEventOnce(lostNotice(for: "інше повідомлення"), productID: product,
                        chatID: e.chatID!, tone: .problem)

        XCTAssertFalse(s.withdrawLostNotice(for: e), "no notice about THIS message")
        XCTAssertEqual(s.entries(inChat: e.chatID!).filter { $0.kind == .event }.count, 2,
                       "an unrelated event and a notice about another message both stay")
    }
}

// MARK: - Sweeping a notice written before the check existed

nonisolated final class StaleLostNoticeSweepTests: XCTestCase {

    @MainActor private func store() -> (ConversationStore, [URL]) {
        let base = FileManager.default.temporaryDirectory
        let a = base.appendingPathComponent("conv-\(UUID().uuidString).json")
        let b = base.appendingPathComponent("chats-\(UUID().uuidString).json")
        return (ConversationStore(fileURL: a, chatsURL: b), [a, b])
    }

    @MainActor
    private func notice(_ text: String) -> String {
        String(format: String(localized: "This message never reached the worker — the run it was queued in is gone. Send it again: “%@”"),
               String(text.prefix(60)))
    }

    @MainActor
    func testANoticeUnderADeliveredMessageIsSweptWhateverTheMoment() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        var e = ConversationEntry(productID: product, kind: .user, text: "продовжуй")
        e.chatID = s.currentChat(for: product).id
        s.append(e)
        s.postEventOnce(notice("продовжуй"), productID: product, chatID: e.chatID!, tone: .problem)

        s.withdrawStaleLostNotices(inChat: e.chatID!)

        XCTAssertTrue(s.entries(inChat: e.chatID!).allSatisfy { $0.kind != .event })
    }

    @MainActor
    func testANoticeAboutAMessageStillUndeliveredStays() {
        let (s, urls) = store(); defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let product = UUID()
        var e = ConversationEntry(productID: product, kind: .user, text: "фідбек по додатку")
        e.chatID = s.currentChat(for: product).id
        s.append(e)
        s.updateDelivery(entryID: e.id, .failed)
        s.postEventOnce(notice("фідбек по додатку"), productID: product, chatID: e.chatID!,
                        tone: .problem)

        s.withdrawStaleLostNotices(inChat: e.chatID!)

        XCTAssertEqual(s.entries(inChat: e.chatID!).filter { $0.kind == .event }.count, 1,
                       "this one really did not arrive — the line is true and stays")
    }
}
