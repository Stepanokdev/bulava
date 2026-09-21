import XCTest
@testable import Bulava

/// Repairing a product whose folder turned out to be a workspace.
///
/// The folder is expanded into the repositories inside it — but a product is more than a list of
/// folders. A chat remembers where it was started, a resource carries the director's decision about
/// whether Bulava may write there, and both outlive the resource being replaced. Each of those was
/// wrong in the first version of this, in a way that left the repair looking like it had worked
/// while the next message still went to the folder the engine refuses.
nonisolated final class WorkspaceRepairTests: XCTestCase {

    private var root: URL!
    private var state: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repair-\(UUID().uuidString)", isDirectory: true)
        state = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repair-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", state.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("BULAVA_STATE_DIR")
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: state)
    }

    /// A REAL repository, not a `.git` directory with a plausible file in it.
    ///
    /// The fixtures used to be hand-built: `HEAD`, `refs/heads/main` with `abc123` inside. That was
    /// enough while the app decided for itself what a repository is. It no longer does — the engine
    /// answers, and the engine asks git. A shape git refuses is now classified as a damaged store,
    /// which is the right answer to the wrong fixture.
    private func makeRepo(_ relative: String) {
        let dir = root.appendingPathComponent(relative, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "x".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        run(["git", "init", "-q"], in: dir)
        run(["git", "config", "user.email", "t@t"], in: dir)
        run(["git", "config", "user.name", "t"], in: dir)
        run(["git", "add", "-A"], in: dir)
        run(["git", "commit", "-qm", "init"], in: dir)
    }

    private func run(_ argv: [String], in dir: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// A product connected the way they were connected before Bulava knew the difference: the
    /// workspace itself, as one folder.
    @MainActor
    private func productHoldingTheWorkspace(access: ResourceAccess) -> (AppModel, Product) {
        makeRepo("frontend-app-home")
        makeRepo("src/edx-platform")

        let model = AppModel()
        let container = model.projects.add(path: root.path)
        let resource = ProductResource(name: "abinito-verawood", kind: .folder,
                                       access: access, projectID: container.id)
        let product = model.products.add(name: "Verawood", resources: [resource])
        return (model, product)
    }

    // MARK: - Permissions

    @MainActor
    func testTheRepositoriesInheritWhatTheDirectorAllowedOnTheFolder() async {
        let (model, product) = productHoldingTheWorkspace(access: .source)
        await model.findWorkspaceResources(in: product)
        let resourceID = try! XCTUnwrap(product.resources.first?.id)

        model.connectRepositoriesInside(resourceID: resourceID, productID: product.id)

        let after = try! XCTUnwrap(model.products.product(id: product.id))
        XCTAssertEqual(after.resources.count, 2, "the workspace was not expanded")
        XCTAssertTrue(after.resources.allSatisfy { $0.access == .source },
                      "“ask before editing” became write access to every repository inside")
    }

    @MainActor
    func testAWritableFolderStaysWritable() async {
        let (model, product) = productHoldingTheWorkspace(access: .workspace)
        await model.findWorkspaceResources(in: product)
        let resourceID = try! XCTUnwrap(product.resources.first?.id)

        model.connectRepositoriesInside(resourceID: resourceID, productID: product.id)

        let after = try! XCTUnwrap(model.products.product(id: product.id))
        XCTAssertTrue(after.resources.allSatisfy { $0.access == .workspace })
        XCTAssertFalse(after.allProjectIDs.contains(where: {
            model.projects.project(id: $0)?.path == Slug.canonicalPath(self.root.path)
        }), "the workspace itself is still a run target")
    }

    // MARK: - Old chats

    @MainActor
    func testAnOldChatStopsAimingAtTheFolderTheEngineRefuses() async {
        let (model, product) = productHoldingTheWorkspace(access: .workspace)
        let container = try! XCTUnwrap(model.projects.project(path: root.path))

        let chat = model.conversations.newChat(for: product.id)
        model.conversations.bindSession(
            ChatSessionBinding(primaryProjectID: container.id, projectPath: container.path,
                               claudeSessionID: "SESSION-IN-THE-CONTAINER",
                               codexThreadID: "THREAD-IN-THE-CONTAINER"),
            to: chat.id)

        await model.findWorkspaceResources(in: product)
        let resourceID = try! XCTUnwrap(product.resources.first?.id)
        model.connectRepositoriesInside(resourceID: resourceID, productID: product.id)

        let session = try! XCTUnwrap(model.conversations.chat(id: chat.id)?.session)
        XCTAssertNotEqual(session.primaryProjectID, container.id,
                          "the next message would start a worker in the workspace again")
        XCTAssertNotEqual(Slug.canonicalPath(session.projectPath), Slug.canonicalPath(root.path))
        let after = try! XCTUnwrap(model.products.product(id: product.id))
        XCTAssertTrue(after.allProjectIDs.contains(where: { $0 == session.primaryProjectID }),
                      "the chat was moved to a folder that is not part of the product")
        XCTAssertNil(session.claudeSessionID,
                     "a Claude session belongs to the directory it was started in")
        XCTAssertNil(session.codexThreadID,
                     "a Codex thread belongs to the directory it was started in")
    }

    /// A rebound chat has a folder but no session in it, and a message needs somewhere to land.
    ///
    /// The first version of the repair left a binding that named no session and had no run behind
    /// it. The delivery path reads any binding as "already started", skipped the launch, and handed
    /// the engine a session id it did not have — `TIER=none`, nothing typed, nothing said. The chat
    /// was moved correctly and then sat mute.
    @MainActor
    func testARepairedChatHasNothingToSendToUntilASessionIsStarted() async {
        let (model, product) = productHoldingTheWorkspace(access: .workspace)
        let container = try! XCTUnwrap(model.projects.project(path: root.path))
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.bindSession(
            ChatSessionBinding(primaryProjectID: container.id, projectPath: container.path,
                               claudeSessionID: "SESSION-IN-THE-CONTAINER"),
            to: chat.id)

        await model.findWorkspaceResources(in: product)
        model.connectRepositoriesInside(resourceID: try! XCTUnwrap(product.resources.first?.id),
                                        productID: product.id)

        let session = try! XCTUnwrap(model.conversations.chat(id: chat.id)?.session)
        XCTAssertFalse(AppModel.bindingCanReceive(sessionID: session.claudeSessionID,
                                                  hasLiveInstance: false),
                       "the next message would be sent to a session that does not exist")
        XCTAssertTrue(AppModel.bindingCanReceive(sessionID: "S-1", hasLiveInstance: false),
                      "a resumable session is still something to send to")
        XCTAssertTrue(AppModel.bindingCanReceive(sessionID: nil, hasLiveInstance: true),
                      "a run of its own is still something to send to")
    }

    /// Both delivery paths ask the same question, so a chat bound to a folder the product no longer
    /// holds is corrected once, wherever the message came from.
    @MainActor
    func testASavedFolderThatIsNoLongerPartOfTheProductIsNotUsed() async {
        let (model, product) = productHoldingTheWorkspace(access: .workspace)
        let container = try! XCTUnwrap(model.projects.project(path: root.path))

        let chat = model.conversations.newChat(for: product.id)
        model.conversations.bindSession(
            ChatSessionBinding(primaryProjectID: container.id, projectPath: container.path),
            to: chat.id)

        await model.findWorkspaceResources(in: product)
        model.connectRepositoriesInside(resourceID: try! XCTUnwrap(product.resources.first?.id),
                                        productID: product.id)
        let repaired = try! XCTUnwrap(model.products.product(id: product.id))

        // Ask again with the stale id put back by hand: what matters is that the answer never is
        // the folder the product has let go of, whatever a chat remembers.
        model.conversations.updateSession(for: chat.id) { $0.primaryProjectID = container.id }
        let primary = model.chatPrimary(for: repaired, chatID: chat.id)

        XCTAssertNotNil(primary)
        XCTAssertNotEqual(primary?.id, container.id,
                          "the disconnected workspace came back as the folder to run in")
        XCTAssertTrue(repaired.allProjectIDs.contains(where: { $0 == primary?.id }))
        XCTAssertEqual(model.conversations.chat(id: chat.id)?.session?.primaryProjectID, primary?.id,
                       "the binding was left pointing somewhere else than the run")
    }
}

// MARK: - The call sites, in the source

/// Two view- and delivery-level rules that no unit can reach: which function each delivery path
/// asks for its folder, and that the add sheet will not be confirmed while it is still looking.
/// Read off the source, as the other call-site assertions in this suite are.
nonisolated final class WorkspaceCallSiteTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    func testBothDeliveryPathsAskForTheProductsOwnFolder() throws {
        let text = try source("Night Shift/App/AppModel+DirectChat.swift")
        let asks = text.components(separatedBy: "chatPrimary(for: product, chatID:").count - 1
        XCTAssertEqual(asks, 2,
                       "Claude and Codex must both resolve the folder through chatPrimary — "
                       + "found \(asks) call(s)")
        XCTAssertFalse(text.contains("?.session?.primaryProjectID\n                .flatMap({ projects.project(id: $0) }) ?? primaryProject"),
                       "a delivery path still trusts a saved id without checking the product")
    }

    func testASessionlessBindingFallsThroughToStartingOne() throws {
        let text = try source("Night Shift/App/AppModel+DirectChat.swift")
        XCTAssertTrue(text.contains("bindingCanReceive(sessionID: held.claudeSessionID"),
                      "the delivery path no longer checks whether the binding can receive anything")
        let check = try XCTUnwrap(text.range(of: "bindingCanReceive(sessionID: held.claudeSessionID")?.lowerBound)
        let launch = try XCTUnwrap(text.range(of: "if binding == nil {")?.lowerBound)
        XCTAssertTrue(check < launch,
                      "the check must run BEFORE the branch that starts a session, or it changes nothing")
    }

    func testTheAddSheetCannotBeConfirmedWhileItIsStillLooking() throws {
        let text = try source("Night Shift/Features/Products/AddProductSheet.swift")
        let canCommit = try XCTUnwrap(text.range(of: "private var canCommit: Bool {")
            .map { text[$0.upperBound...].prefix(400) })
        XCTAssertTrue(canCommit.contains("scanning == 0"),
                      "the form can be confirmed mid-scan, storing half of a workspace")
    }
}
