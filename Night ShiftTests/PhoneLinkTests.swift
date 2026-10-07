import XCTest
import Network
import CryptoKit
import Security
@testable import Bulava

/// The phone link, end to end: a real TLS listener in this process and a client that behaves the
/// way the phone does — it trusts nothing but the key fingerprint the QR code carried.
///
/// These are the promises the mobile app is built on. The phone's messages land in the chat the
/// PHONE addressed, whatever the Mac has open; a message sent twice is one message; a code works
/// once; a removed phone is cut off; and adding folders is refused by the Mac itself, not merely
/// hidden on the phone.
nonisolated final class PhoneLinkTests: XCTestCase {

    nonisolated(unsafe) private var dir: URL!
    nonisolated(unsafe) private var model: AppModel!
    nonisolated(unsafe) private var link: MobileLink!

    @MainActor
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bulava-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("BULAVA_STATE_DIR", dir.path, 1)
        model = AppModel()
        link = MobileLink(root: dir.appendingPathComponent("mobile-link"))
        link.preferredPort = 0
        link.attach(model, allowInTests: true)
    }

    @MainActor
    override func tearDown() async throws {
        link.shutdown()
        link = nil
        model = nil
        try? FileManager.default.removeItem(at: dir)
        unsetenv("BULAVA_STATE_DIR")
    }

    // MARK: - Helpers

    @MainActor
    private func pairingCode() async throws -> (payload: [String: Any], port: Int) {
        let first = try XCTUnwrap(link.beginPairing())
        for _ in 0..<100 {
            if case .listening = link.serverState { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .listening(let port) = link.serverState else {
            XCTFail("the listener never came up: \(link.serverState)"); throw CancellationError()
        }
        // The port settles after the first code is drawn; the code is redrawn for it.
        let url = link.pairingPayload?.url ?? first.url
        let fragment = try XCTUnwrap(url.split(separator: "#").last).description
        let json = try XCTUnwrap(Data(base64URL: fragment))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        return (payload, Int(port))
    }

    /// The usual port taken by something that bound it first — a second Bulava on the same Mac did
    /// exactly that — and the link still comes up, on a free port, with the code naming that port.
    /// It used to die instead: a listener on a named port only learns it is busy once it starts,
    /// so the fallback never ran and the code went on pointing at a port nobody was listening on.
    @MainActor
    func testABusyUsualPortIsTradedForAFreeOne() async throws {
        let blocker = try NWListener(using: .tcp)
        blocker.newConnectionHandler = { $0.cancel() }
        blocker.start(queue: .main)
        defer { blocker.cancel() }
        for _ in 0..<100 where blocker.port == nil || blocker.state != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        let busy = try XCTUnwrap(blocker.port?.rawValue, "the blocker never got a port")

        link.preferredPort = busy
        let (payload, port) = try await pairingCode()
        XCTAssertNotEqual(port, Int(busy), "the link claims the port another listener holds")
        XCTAssertEqual(payload["p"] as? Int, port, "and the code names the port it really listens on")
    }

    @MainActor
    private func pairedPhone() async throws -> (TestPhone, LinkCredentialJSON, [String: Any]) {
        let (payload, port) = try await pairingCode()
        let phone = TestPhone(port: port, pin: payload["k"] as! String)
        try await phone.connect()
        let welcome = try await phone.hello(pairing: payload["t"] as? String)
        XCTAssertEqual(welcome["type"] as? String, "welcome")
        let cred = try XCTUnwrap(welcome["credential"] as? [String: Any])
        return (phone, LinkCredentialJSON(deviceID: cred["deviceID"] as! String, secret: cred["secret"] as! String), payload)
    }

    // MARK: - Identity

    @MainActor
    func testTheCertificateIsRealAndNeedsNoKeychain() throws {
        let identity = try XCTUnwrap(LinkIdentity.loadOrCreate(at: dir.appendingPathComponent("id.json"),
                                                              commonName: "Bulava Test"))
        XCTAssertNotNil(SecCertificateCreateWithData(nil, identity.certificateDER as CFData),
                        "the hand-written DER has to parse as a certificate")
        XCTAssertNotNil(identity.secIdentity(), "and become a TLS identity without touching a keychain")
        let again = try XCTUnwrap(LinkIdentity.loadOrCreate(at: dir.appendingPathComponent("id.json"),
                                                           commonName: "Bulava Test"))
        XCTAssertEqual(identity.pin, again.pin, "the same key after a restart, or every phone would have to pair again")
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("id.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testOnlyTheLocalNetworkMayKnock() {
        for local in ["192.168.1.20", "10.0.0.4", "172.20.3.1", "169.254.10.1", "127.0.0.1", "::1",
                      "fe80::1%en0", "fd12:3456::1", "::ffff:192.168.0.7"] {
            XCTAssertTrue(LinkServer.isLocal(local), local)
        }
        for outside in ["8.8.8.8", "100.64.1.1", "100.100.100.100", "172.32.0.1", "2001:4860::8888",
                        "::ffff:8.8.8.8", "example.com"] {
            XCTAssertFalse(LinkServer.isLocal(outside), outside)
        }
    }

    // MARK: - Pairing

    @MainActor
    func testACodeWorksOnceAndTheCredentialKeepsWorking() async throws {
        let (payload, port) = try await pairingCode()
        let pin = payload["k"] as! String
        let token = payload["t"] as! String

        let first = TestPhone(port: port, pin: pin)
        try await first.connect()
        let welcome = try await first.hello(pairing: token)
        let cred = try XCTUnwrap(welcome["credential"] as? [String: Any])
        XCTAssertEqual(link.devices.devices.count, 1)
        first.close()

        let thief = TestPhone(port: port, pin: pin)
        try await thief.connect()
        let refused = try await thief.hello(pairing: token)
        XCTAssertEqual(refused["type"] as? String, "refused")
        XCTAssertEqual(refused["code"] as? String, LinkErrorCode.pairingUsed)
        XCTAssertEqual(link.devices.devices.count, 1, "a spent code registers nobody")

        let back = TestPhone(port: port, pin: pin)
        try await back.connect()
        let again = try await back.hello(credential: LinkCredentialJSON(deviceID: cred["deviceID"] as! String,
                                                                       secret: cred["secret"] as! String))
        XCTAssertEqual(again["type"] as? String, "welcome")
        XCTAssertNil(again["credential"], "the secret is handed over once, at pairing")
        back.close()
    }

    @MainActor
    func testAWrongFingerprintNeverGetsToSayHello() async throws {
        let (_, port) = try await pairingCode()
        let impostor = TestPhone(port: port, pin: LinkIdentity.base64url(Data(repeating: 7, count: 32)))
        do {
            try await impostor.connect()
            _ = try await impostor.hello(pairing: "anything")
            XCTFail("a Mac whose key does not match the QR code must not be talked to")
        } catch {
            XCTAssertTrue(link.devices.devices.isEmpty)
        }
    }

    @MainActor
    func testAWrongSecretIsRefused() async throws {
        let (phone, cred, payload) = try await pairedPhone()
        phone.close()
        let liar = TestPhone(port: Int(payload["p"] as! Int), pin: payload["k"] as! String)
        try await liar.connect()
        let answer = try await liar.hello(credential: LinkCredentialJSON(deviceID: cred.deviceID, secret: "nope"))
        XCTAssertEqual(answer["code"] as? String, LinkErrorCode.unauthorized)
    }

    @MainActor
    func testARemovedPhoneIsCutOffAndStaysOut() async throws {
        let (phone, cred, payload) = try await pairedPhone()
        link.revoke(cred.deviceID)
        let event = try await phone.next { $0["type"] as? String == "event" && $0["event"] as? String == "revoked" }
        XCTAssertNotNil(event)
        try await phone.waitClosed()

        let retry = TestPhone(port: payload["p"] as! Int, pin: payload["k"] as! String)
        try await retry.connect()
        let answer = try await retry.hello(credential: cred)
        XCTAssertEqual(answer["code"] as? String, LinkErrorCode.revoked)
    }

    // MARK: - Working through it

    @MainActor
    func testThePhonesMessageLandsInThePhonesChatAndOnlyOnce() async throws {
        let product = model.products.add(name: "Narada")
        let desk = model.conversations.newChat(for: product.id)
        model.conversations.appendUser("from the desk", productID: product.id, chatID: desk.id)
        let (phone, _, _) = try await pairedPhone()

        let phoneChat = UUID(), entry = UUID()
        let created = try await phone.request("chat.create", ["productID": product.id.uuidString,
                                                              "chatID": phoneChat.uuidString])
        XCTAssertEqual(created["ok"] as? Bool, true)
        XCTAssertEqual(model.conversations.currentChatID(for: product.id), desk.id,
                       "a chat started on the phone must not move the chat open on the Mac")

        let args: [String: Any] = ["productID": product.id.uuidString, "chatID": phoneChat.uuidString,
                                   "entryID": entry.uuidString, "text": "from the phone"]
        let sent = try await phone.request("chat.send", args)
        XCTAssertEqual((sent["result"] as? [String: Any])?["duplicate"] as? Bool, false)
        let again = try await phone.request("chat.send", args)
        XCTAssertEqual((again["result"] as? [String: Any])?["duplicate"] as? Bool, true,
                       "a retry after a lost reply finds the first message")

        let inPhoneChat = model.conversations.entries(inChat: phoneChat).filter { $0.kind == .user }
        XCTAssertEqual(inPhoneChat.map(\.text), ["from the phone"])
        XCTAssertEqual(inPhoneChat.first?.id, entry)
        XCTAssertEqual(model.conversations.entries(inChat: desk.id).filter { $0.kind == .user }.map(\.text),
                       ["from the desk"])
        XCTAssertEqual(model.conversations.currentChatID(for: product.id), desk.id)
        phone.close()
    }

    @MainActor
    func testAnOpenChatFollowsWhatHappensOnTheMac() async throws {
        let product = model.products.add(name: "Narada")
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.appendUser("first", productID: product.id, chatID: chat.id)
        let (phone, _, _) = try await pairedPhone()

        _ = try await phone.request("home.subscribe", [:])
        let home = try await phone.next { $0["event"] as? String == "home" }
        let products = (home?["data"] as? [String: Any])?["products"] as? [[String: Any]]
        XCTAssertEqual(products?.first?["name"] as? String, "Narada")

        _ = try await phone.request("chat.open", ["chatID": chat.id.uuidString])
        let full = try await phone.next { $0["event"] as? String == "chat" }
        let entries = (full?["data"] as? [String: Any])?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.compactMap { $0["text"] as? String }, ["first"])

        model.conversations.appendForeman("an answer", productID: product.id, chatID: chat.id)
        let delta = try await phone.next { $0["event"] as? String == "chat.delta" }
        let upserts = (delta?["data"] as? [String: Any])?["upserts"] as? [[String: Any]]
        XCTAssertEqual(upserts?.first?["text"] as? String, "an answer",
                       "the phone hears about a new line without asking")
        XCTAssertEqual(upserts?.first?["kind"] as? String, "agent")
        phone.close()
    }

    /// A site an answer names opens on the phone as a site: the phone is handed a ref (never the
    /// path), asks to open it, and gets an address on this Mac it can load — the page and the
    /// styles beside it. Nothing hidden and nothing outside the product's folders is offered.
    @MainActor
    func testAFileAnAnswerNamesOpensOnThePhoneWithItsSite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("link-open-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let site = folder.appendingPathComponent("artifacts/site")
        try FileManager.default.createDirectory(at: site.appendingPathComponent("assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "<!doctype html><link rel=stylesheet href=\"assets/app.css\"><h1>Звіт</h1>".write(
            to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "h1{color:red}".write(to: site.appendingPathComponent("assets/app.css"), atomically: true, encoding: .utf8)
        try "SECRET=1".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let product = model.products.add(name: "Narada")
        let project = model.projects.add(path: folder.path)
        model.products.addResource(ProductResource(name: "project", kind: .folder, access: .workspace,
                                                   projectID: project.id), to: product.id)
        let chat = model.conversations.newChat(for: product.id)
        var answer = ConversationEntry(productID: product.id, kind: .foreman, text: "")
        answer.chatID = chat.id
        answer.blocks = [.markdown(id: "b1", "Готово: `artifacts/site/index.html`. Ключі в `.env`, хости в `/etc/hosts`.")]
        model.conversations.append(answer)
        model.shares.server.preferredPort = 0
        defer { model.shares.server.stop() }

        let (phone, _, _) = try await pairedPhone()
        _ = try await phone.request("chat.open", ["chatID": chat.id.uuidString])
        let full = try await phone.next { $0["event"] as? String == "chat" }
        let entries = try XCTUnwrap((full?["data"] as? [String: Any])?["entries"] as? [[String: Any]])
        let blocks = try XCTUnwrap(entries.last?["blocks"] as? [[String: Any]])
        let links = try XCTUnwrap(blocks.first?["links"] as? [[String: Any]], "the answer's file is offered under it")
        XCTAssertEqual(links.count, 1, "nothing hidden, nothing outside the product's folders: \(links)")
        XCTAssertEqual(links.first?["name"] as? String, "index.html")
        let ref = try XCTUnwrap(links.first?["ref"] as? String)
        XCTAssertFalse(ref.contains("artifacts") || ref.contains(folder.path), "the phone never learns the path: \(ref)")

        let opened = try await phone.request("file.open", ["ref": ref])
        let result = try XCTUnwrap(opened["result"] as? [String: Any], "\(opened)")
        XCTAssertEqual(result["scope"] as? String, "site")
        let url = try XCTUnwrap(URL(string: result["url"] as? String ?? ""))
        XCTAssertEqual(url.host, "127.0.0.1", "the address the phone reached this Mac at")
        let session = URLSession(configuration: .ephemeral)
        let (page, pageResponse) = try await session.data(from: url)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("<h1>Звіт</h1>"))
        let (style, styleResponse) = try await session.data(from: url.deletingLastPathComponent().appendingPathComponent("assets/app.css"))
        XCTAssertEqual((styleResponse as? HTTPURLResponse)?.statusCode, 200, "and the site's own files beside it")
        XCTAssertEqual(String(decoding: style, as: UTF8.self), "h1{color:red}")

        let forged = try await phone.request("file.open", ["ref": "lnk:\(chat.id.uuidString):0000000000"])
        XCTAssertEqual((forged["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.stale,
                       "a ref the phone was never handed opens nothing")
        phone.close()
    }

    /// A report that asks him to decide, answered from the phone: the questions come with the
    /// report, the answer becomes his message in the report's chat, the same answer sent again
    /// after a lost reply is one message, and questions that changed meanwhile refuse an answer
    /// to the old ones.
    @MainActor
    func testAReportsQuestionsAreAnsweredFromThePhoneOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("link-decide-\(UUID().uuidString)")
        let plan = folder.appendingPathComponent("artifacts/plan")
        try FileManager.default.createDirectory(at: plan, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = plan.appendingPathComponent("index.html")
        try "<h1>План</h1>".write(to: report, atomically: true, encoding: .utf8)
        let questions = plan.appendingPathComponent("decisions.json")
        try #"{"title":"Що далі","items":[{"id":"leak","title":"Закрити витік","recommended":"Take it"},{"id":"browser","title":"Свій браузер","options":["Зараз","Потім"]}]}"#
            .write(to: questions, atomically: true, encoding: .utf8)

        let product = model.products.add(name: "Narada")
        let chat = model.conversations.newChat(for: product.id)
        // The chat of a run: it has a session, which is where a chat's reports are kept.
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: folder.path,
                                                           activeRunID: "RUN-DECIDE"), to: chat.id)
        model.decisions.model = model
        model.decisions.publish(report, to: chat.id)

        let (phone, _, _) = try await pairedPhone()
        _ = try await phone.request("home.subscribe", [:])
        let home = try await phone.next { $0["event"] as? String == "home" }
        let waiting = ((home?["data"] as? [String: Any])?["attention"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "decide" }
        XCTAssertEqual(waiting.count, 1, "a report waiting for his decisions is among what waits for him")
        let target = try XCTUnwrap((waiting.first?["actions"] as? [[String: Any]])?.first?["target"] as? String)

        let opened = try await phone.request("report.open", ["target": target])
        let decisions = try XCTUnwrap((opened["result"] as? [String: Any])?["decisions"] as? [String: Any], "\(opened)")
        let items = try XCTUnwrap(decisions["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["id"] as? String }, ["leak", "browser"])
        XCTAssertEqual(items.first?["recommended"] as? String, "Take it")
        let ref = try XCTUnwrap(decisions["ref"] as? String)
        let revision = try XCTUnwrap(decisions["revision"] as? String)
        XCTAssertFalse(ref.contains("artifacts"), "the phone never learns the path: \(ref)")

        let submission = UUID().uuidString
        let args: [String: Any] = ["ref": ref, "revision": revision, "submissionID": submission,
                                   "choices": ["leak": "Take it", "browser": "Потім"], "comments": ["browser": "після релізу"],
                                   "general": ""]
        let sent = try await phone.request("report.decide", args)
        XCTAssertEqual((sent["result"] as? [String: Any])?["id"] as? String, submission, "\(sent)")
        let again = try await phone.request("report.decide", args)
        XCTAssertEqual((again["result"] as? [String: Any])?["id"] as? String, submission, "the lost reply's answer, again")
        let messages = model.conversations.entries(inChat: chat.id).filter { $0.kind == .user }
        XCTAssertEqual(messages.count, 1, "one message for one answer")
        XCTAssertTrue(messages.first?.text.contains("Свій браузер — Потім") == true, messages.first?.text ?? "")
        XCTAssertTrue(messages.first?.text.contains("після релізу") == true)

        let reopened = try await phone.request("report.open", ["target": target])
        let latest = ((reopened["result"] as? [String: Any])?["decisions"] as? [String: Any])?["latest"] as? [String: Any]
        XCTAssertEqual(latest?["id"] as? String, submission, "the report says what was answered, from anywhere")

        // Another device's answer in between: the phone's is not silently written over it.
        var behind = args
        behind["submissionID"] = UUID().uuidString
        let conflict = try await phone.request("report.decide", behind)
        XCTAssertEqual((conflict["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.decisionsConflict)

        try #"{"title":"Що далі","items":[{"id":"leak","title":"Закрити витік і змінити ключі"}]}"#
            .write(to: questions, atomically: true, encoding: .utf8)
        behind["basedOn"] = submission
        let changed = try await phone.request("report.decide", behind)
        XCTAssertEqual((changed["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.decisionsChanged,
                       "an answer to questions that are no longer the questions")
        XCTAssertEqual(model.conversations.entries(inChat: chat.id).filter { $0.kind == .user }.count, 1)
        phone.close()
    }

    @MainActor
    func testFoldersAreAddedOnTheMacOnly() async throws {
        let (phone, _, _) = try await pairedPhone()
        for op in ["product.add", "folder.connect", "resource.add"] {
            let answer = try await phone.request(op, ["path": "/Users"])
            XCTAssertEqual((answer["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.notOnPhone, op)
        }
        let unknown = try await phone.request("anything.else", [:])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.unknownOperation)
        XCTAssertTrue(model.products.products.isEmpty)
        phone.close()
    }

    @MainActor
    func testAButtonAnsweredOnTheMacIsNotAnsweredAgain() async throws {
        let (phone, _, _) = try await pairedPhone()
        let answer = try await phone.request("action.invoke", ["id": "trust:nothing"])
        XCTAssertEqual((answer["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.stale)
        phone.close()
    }

    @MainActor
    func testAFileOnlyReadsWhatThePhoneWasShown() async throws {
        let (phone, _, _) = try await pairedPhone()
        let answer = try await phone.request("file.read", ["ref": "art:../../etc/passwd"])
        XCTAssertEqual((answer["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.notFound)
        let report = try await phone.request("file.read", ["ref": "rep:x/../../etc/passwd"])
        XCTAssertEqual((report["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.notFound)
        phone.close()
    }

    @MainActor
    func testAPhotoFromThePhoneGoesOutWithTheMessage() async throws {
        let product = model.products.add(name: "Narada")
        let (phone, _, _) = try await pairedPhone()
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        let begun = try await phone.request("upload.begin", ["name": "shot.png", "kind": "image", "size": bytes.count])
        let uploadID = try XCTUnwrap((begun["result"] as? [String: Any])?["uploadID"] as? String)
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(bytes.count, offset + 100_000)]
            let r = try await phone.request("upload.chunk", ["uploadID": uploadID, "offset": offset,
                                                             "data": Data(chunk).base64EncodedString()])
            XCTAssertEqual(r["ok"] as? Bool, true)
            offset += chunk.count
        }
        let done = try await phone.request("upload.finish", ["uploadID": uploadID])
        let ref = try XCTUnwrap((done["result"] as? [String: Any])?["ref"] as? String)

        let chatID = UUID()
        let sent = try await phone.request("chat.send", [
            "productID": product.id.uuidString, "chatID": chatID.uuidString, "entryID": UUID().uuidString,
            "text": "", "attachments": [ref]])
        XCTAssertEqual(sent["ok"] as? Bool, true)
        let attachment = try XCTUnwrap(model.conversations.entries(inChat: chatID).first?.attachments.first)
        XCTAssertEqual(attachment.filename, "shot.png")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(model.capture.url(for: attachment))), bytes)

        let read = try await phone.request("file.read", ["ref": ref, "offset": 0, "length": 10])
        XCTAssertEqual((read["result"] as? [String: Any])?["total"] as? Int, bytes.count)
        phone.close()
    }

    /// Dictation from the phone: the recording goes up like a photo, the words come back for the
    /// phone's composer, and nothing is sent. Asked twice — a phone that lost the answer — it is
    /// the same words, heard once; and the recording is gone from the Mac once heard.
    @MainActor
    func testARecordingFromThePhoneComesBackAsWordsHeardOnce() async throws {
        let ears = Ears(.text("Зроби експорт сірим"))
        link.transcriber = ears.engine
        let product = model.products.add(name: "Narada")
        let (phone, _, _) = try await pairedPhone()
        let ref = try await upload(Data(repeating: 7, count: 40_000), name: "dictation.m4a", kind: "audio", phone: phone)
        let chatID = UUID().uuidString

        let first = try await phone.request("audio.transcribe", ["requestID": "V1", "ref": ref, "chatID": chatID])
        XCTAssertEqual(first["ok"] as? Bool, true, "\(first)")
        let result = try XCTUnwrap(first["result"] as? [String: Any])
        XCTAssertEqual(result["text"] as? String, "Зроби експорт сірим")
        XCTAssertEqual(result["chatID"] as? String, chatID, "the words go back to the chat they were spoken in")
        XCTAssertEqual(ears.language, model.settings.dictationLanguage.code(interface: model.settings.interfaceLanguage),
                       "decoded in the Mac’s own dictation language")
        XCTAssertTrue(model.conversations.entries(inChat: UUID(uuidString: chatID)!).isEmpty, "words, not a message")
        XCTAssertTrue(model.conversations.chats.filter { $0.productID == product.id }.isEmpty)
        let heard = try XCTUnwrap(ears.heard.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heard.path), "the recording does not stay on the Mac")

        let again = try await phone.request("audio.transcribe", ["requestID": "V1", "chatID": chatID])
        XCTAssertEqual((again["result"] as? [String: Any])?["text"] as? String, "Зроби експорт сірим")
        XCTAssertEqual(ears.heard.count, 1, "a repeated request is answered from memory, not heard again")

        let unknown = try await phone.request("audio.transcribe", ["requestID": "V2", "ref": ref])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.notFound,
                       "a recording already heard cannot be named again: the phone sends it once more")
        phone.close()
    }

    /// A Mac with no Whisper model says so with its own code — the phone keeps the recording and
    /// offers to try again — and a recording with no words is told apart from that.
    @MainActor
    func testARecordingTheMacCannotHearIsToldApart() async throws {
        let (phone, _, _) = try await pairedPhone()
        link.transcriber = Ears(.unavailable("Your Mac is fetching its dictation model, once only. Try again in a few minutes.")).engine
        let ref = try await upload(Data(repeating: 1, count: 1_000), name: "dictation.m4a", kind: "audio", phone: phone)
        let none = try await phone.request("audio.transcribe", ["requestID": "V3", "ref": ref])
        XCTAssertEqual((none["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.dictationUnavailable)

        link.transcriber = Ears(.notTranscribed).engine
        let quiet = try await upload(Data(repeating: 0, count: 1_000), name: "dictation.m4a", kind: "audio", phone: phone)
        let silence = try await phone.request("audio.transcribe", ["requestID": "V3", "ref": quiet])
        XCTAssertEqual((silence["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.notTranscribed,
                       "a failure is not remembered: the same request may be tried again")
        phone.close()
    }

    /// The same request asked while it is still being heard waits for that hearing rather than
    /// starting another, and an answer is kept only as long as it is useful.
    @MainActor
    func testTheTranscriptionLedgerHearsEachRequestOnce() async throws {
        let ledger = LinkTranscriptions()
        let ears = Ears(.text("words"), delay: .milliseconds(200))
        let first = dir.appendingPathComponent("a.m4a"), second = dir.appendingPathComponent("b.m4a")
        for f in [first, second] { FileManager.default.createFile(atPath: f.path, contents: Data([1])) }
        async let one = ledger.transcribe("R", audio: first, language: "uk", engine: ears.engine)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(ledger.knows("R"))
        async let two = ledger.transcribe("R", audio: second, language: "uk", engine: ears.engine)
        let (a, b) = await (one, two)
        XCTAssertEqual(a, .text("words"))
        XCTAssertEqual(b, .text("words"))
        XCTAssertEqual(ears.heard.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path), "a second copy is deleted unheard")
        let none = await ledger.transcribe("unknown", audio: nil, language: "uk", engine: ears.engine)
        XCTAssertNil(none, "nothing to hear and nothing remembered")

        ledger.keep = 0
        XCTAssertFalse(ledger.knows("R"), "an answer past its keeping is forgotten")
    }

    /// What bulava.app says about the phone apps reaches every phone in its `home` and a phone
    /// turned away as too old in the refusal — and a manifest with nothing usable in it, nothing.
    @MainActor
    func testTheNewestPhoneAppIsPassedOnAsBulavaAppSaysIt() async throws {
        let manifest = Data("""
        {"android": {"version": "1.1", "build": 9, "url": "https://bulava.app/Bulava-android.apk"},
         "ios": {"version": "", "build": 9, "url": "https://testflight.apple.com/join/x"},
         "watch": {"version": "1.0"}}
        """.utf8)
        let apps = try XCTUnwrap(MobileLink.decodePhoneApps(manifest))
        XCTAssertEqual(apps.android, PhoneAppDTO(version: "1.1", build: 9, url: "https://bulava.app/Bulava-android.apk"))
        XCTAssertNil(apps.ios, "an entry with no version is not passed on")
        XCTAssertNil(MobileLink.decodePhoneApps(Data(#"{"android": {"version": "1.1", "build": 0, "url": "http://x"}}"#.utf8)))
        XCTAssertNil(MobileLink.decodePhoneApps(Data("not json".utf8)))

        link.adoptPhoneApps(apps, save: true)
        let (phone, _, _) = try await pairedPhone()
        _ = try await phone.request("home.subscribe", [:])
        let frame = try await phone.next { $0["event"] as? String == "home" }
        let home = try XCTUnwrap(frame)
        let sent = try XCTUnwrap((home["data"] as? [String: Any])?["phoneApps"] as? [String: Any])
        XCTAssertEqual((sent["android"] as? [String: Any])?["build"] as? Int, 9)
        phone.close()

        let (payload, port) = try await pairingCode()
        let old = TestPhone(port: port, pin: payload["k"] as! String)
        try await old.connect()
        let refused = try await old.hello(pairing: nil, version: 0, minimum: 0)
        XCTAssertEqual(refused["code"] as? String, LinkErrorCode.protocolTooOld)
        XCTAssertEqual(((refused["phoneApps"] as? [String: Any])?["android"] as? [String: Any])?["version"] as? String, "1.1",
                       "a phone too old is told which version to get")

        let reread = MobileLink(root: dir.appendingPathComponent("mobile-link"))
        reread.loadPhoneApps()
        XCTAssertEqual(reread.phoneApps, apps, "kept on disk for a Mac that wakes up offline")
    }

    @MainActor
    private func upload(_ bytes: Data, name: String, kind: String, phone: TestPhone) async throws -> String {
        let begun = try await phone.request("upload.begin", ["name": name, "kind": kind, "size": bytes.count])
        let uploadID = try XCTUnwrap((begun["result"] as? [String: Any])?["uploadID"] as? String)
        let r = try await phone.request("upload.chunk", ["uploadID": uploadID, "offset": 0, "data": bytes.base64EncodedString()])
        XCTAssertEqual(r["ok"] as? Bool, true)
        let done = try await phone.request("upload.finish", ["uploadID": uploadID])
        return try XCTUnwrap((done["result"] as? [String: Any])?["ref"] as? String)
    }

    @MainActor
    func testAnOldPhoneAndANewPhoneAreBothToldWhatToUpdate() async throws {
        let (payload, port) = try await pairingCode()
        let old = TestPhone(port: port, pin: payload["k"] as! String)
        try await old.connect()
        let tooOld = try await old.hello(pairing: nil, version: 0, minimum: 0)
        XCTAssertEqual(tooOld["code"] as? String, LinkErrorCode.protocolTooOld)

        let future = TestPhone(port: port, pin: payload["k"] as! String)
        try await future.connect()
        let tooNew = try await future.hello(pairing: nil, version: 9, minimum: 9)
        XCTAssertEqual(tooNew["code"] as? String, LinkErrorCode.protocolTooNew)
        XCTAssertNotNil(tooNew["desktopVersion"], "the phone says WHICH Bulava is too old")
    }

    // MARK: - Pure pieces

    @MainActor
    func testAnAnswerIsWrittenTheWayTheMacsCardWritesIt() {
        XCTAssertEqual(MobileLink.composeAnswer(selections: [["42"]], typed: ""), "42")
        XCTAssertEqual(MobileLink.composeAnswer(selections: [["a", "b"]], typed: ""), "a, b")
        XCTAssertEqual(MobileLink.composeAnswer(selections: [["yes"], [], ["later"]], typed: ""), "1: yes\n3: later")
        XCTAssertEqual(MobileLink.composeAnswer(selections: [["42"]], typed: "and bump the notes"), "42\nand bump the notes")
        XCTAssertEqual(MobileLink.composeAnswer(selections: [], typed: "my own words"), "my own words")
    }

    @MainActor
    func testADeltaKeepsWhatMerelyScrolledOutOfTheWindow() {
        func entry(_ id: String, _ text: String) -> EntryDTO {
            EntryDTO(id: id, kind: "agent", atMs: 0, author: "", text: text, blocks: [], attachments: [], tone: "neutral",
                     delivery: nil, asks: [], actions: [], question: nil, card: nil, finished: nil)
        }
        func chat(_ entries: [EntryDTO]) -> ChatDTO {
            ChatDTO(id: "C", productID: "P", title: "t", archived: false,
                    status: StatusDTO(code: "ready", label: "", tone: "good", active: false), activity: nil,
                    degradation: nil, queueCount: 0, busy: false, entries: entries, hasEarlier: false, actions: [])
        }
        let old = chat([entry("a", "1"), entry("b", "2")])
        let new = chat([entry("b", "2 and more"), entry("c", "3")])
        let delta = try! XCTUnwrap(LinkSession.delta(from: old, to: new, visible: ["a", "b", "c"]))
        XCTAssertEqual(delta.upserts.map(\.id), ["b", "c"])
        XCTAssertEqual(delta.removed, [], "a slid out of the window; it is still in the chat")
        XCTAssertEqual(delta.order, ["b", "c"])
        let gone = try! XCTUnwrap(LinkSession.delta(from: old, to: new, visible: ["b", "c"]))
        XCTAssertEqual(gone.removed, ["a"])
        XCTAssertNil(LinkSession.delta(from: new, to: new, visible: ["b", "c"]), "nothing changed, nothing sent")
    }

    // MARK: - Projects from the phone

    @MainActor
    func testAProjectCanBeRenamedPinnedAndRemovedButNeverAdded() async throws {
        let product = model.products.add(name: "Narada")
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.appendUser("hello", productID: product.id, chatID: chat.id)
        let (phone, _, _) = try await pairedPhone()

        _ = try await phone.request("product.rename", ["productID": product.id.uuidString, "name": "  Narada 2  "])
        XCTAssertEqual(model.products.product(id: product.id)?.name, "Narada 2")
        _ = try await phone.request("product.pin", ["productID": product.id.uuidString, "pinned": true])
        XCTAssertEqual(model.products.product(id: product.id)?.pinned, true)
        _ = try await phone.request("product.remove", ["productID": product.id.uuidString])
        XCTAssertNil(model.products.product(id: product.id))
        XCTAssertTrue(model.conversations.entries(inChat: chat.id).isEmpty)
        phone.close()
    }

    @MainActor
    func testAQuestionAnsweredOnThePhoneIsAnsweredInItsOwnChat() async throws {
        let product = model.products.add(name: "Narada")
        let desk = model.conversations.newChat(for: product.id)
        model.conversations.appendUser("at the desk", productID: product.id, chatID: desk.id)
        let asked = model.conversations.adoptChat(id: UUID(), for: product.id)
        var question = ConversationEntry(productID: product.id, kind: .question, text: "Which one?")
        question.chatID = asked.id
        model.conversations.append(question)
        model.conversations.open(desk.id, for: product.id)
        let (phone, _, _) = try await pairedPhone()

        let answer = try await phone.request("question.answer", ["entryID": question.id.uuidString,
                                                                 "selections": [["the second"]], "text": ""])
        XCTAssertEqual(answer["ok"] as? Bool, true)
        let thread = model.conversations.entries(inChat: asked.id)
        XCTAssertEqual(thread.last { $0.kind == .user }?.text, "the second")
        XCTAssertFalse(thread.contains { $0.kind == .question }, "nobody was waiting, so the card goes")
        XCTAssertEqual(model.conversations.entries(inChat: desk.id).map(\.text), ["at the desk"],
                       "nothing about the phone's answer lands in the chat the Mac has open")
        let again = try await phone.request("question.answer", ["entryID": question.id.uuidString,
                                                                "selections": [["the second"]], "text": ""])
        XCTAssertEqual((again["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.stale)
        phone.close()
    }

    // MARK: - The inspector and the skills, on the phone

    @MainActor
    func testTheProductsContextIsTheInspectorsAndItsLockWorks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("link-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = model.projects.add(path: folder.path)
        let product = model.products.add(name: "Narada", resources: [
            ProductResource(name: "Narada", kind: .folder, access: .workspace, projectID: project.id),
            ProductResource(name: "Site", kind: .website, access: .source, urlString: "https://narada.app"),
        ], brief: "Keep the UI native.")
        let (phone, _, _) = try await pairedPhone()

        let answer = try await phone.request("context.get", ["productID": product.id.uuidString])
        let context = try XCTUnwrap(answer["result"] as? [String: Any], "\(answer)")
        XCTAssertEqual(context["productID"] as? String, product.id.uuidString)
        let resources = try XCTUnwrap(context["resources"] as? [[String: Any]])
        XCTAssertEqual(resources.map { $0["name"] as? String }, ["Narada", "Site"])
        XCTAssertEqual(resources[1]["url"] as? String, "https://narada.app")
        XCTAssertEqual((context["instructions"] as? [String: Any])?["brief"] as? String, "Keep the UI native.")
        XCTAssertNil(context["report"], "no finished work yet, so no \"everything done so far\"")

        // The folder's lock is a button the Mac sent, and pressing it changes what the Mac holds.
        let lock = try XCTUnwrap((resources[0]["actions"] as? [[String: Any]])?.first?["id"] as? String)
        _ = try await phone.request("action.invoke", ["id": lock])
        XCTAssertEqual(model.products.product(id: product.id)?.resources.first?.access, .source)
        // The website has no lock: it is not a folder Night Shift could write to.
        XCTAssertEqual((resources[1]["actions"] as? [[String: Any]])?.count, 0)

        let unknownDiff = try await phone.request("context.diff", ["ref": "diff:made-up"])
        XCTAssertEqual((unknownDiff["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.stale,
                       "only a change the phone was shown can be read")
        phone.close()
    }

    @MainActor
    func testAReportTargetThePhoneWasNotGivenIsNotOpened() async throws {
        let product = model.products.add(name: "Narada")
        let (phone, _, _) = try await pairedPhone()
        let answer = try await phone.request("report.open", ["target": "product:\(product.id.uuidString)"])
        XCTAssertEqual((answer["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.stale,
                       "a product report is opened only through the button context.get handed out")
        phone.close()
    }

    // MARK: - Waking an iPhone

    @MainActor
    func testAnIPhoneThatIsNotListeningIsWokenWithNothingButItsToken() async throws {
        StubRelay.reset(status: 202)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubRelay.self]
        link.pushSession = URLSession(configuration: config)
        link.relayOverride = URL(string: "https://relay.test")
        link.relayFeatures = .legacy
        link.relayFeaturesCheckedAt = Date()

        let product = model.products.add(name: "Narada")
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.appendUser("first", productID: product.id, chatID: chat.id)
        let (phone, _, _) = try await pairedPhone()
        let token = String(repeating: "ab", count: 32)
        _ = try await phone.request("push.register", ["token": token, "environment": "development"])
        XCTAssertEqual(link.devices.devices.first?.pushToken, token)

        // On screen: the phone hears it over the link, and nothing is pushed.
        let asked = model.conversations.appendUser("needs trust", productID: product.id, chatID: chat.id)
        model.conversations.updateDelivery(entryID: asked.id, .failed)
        model.trustBlocked[chat.id] = "/nowhere"
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(StubRelay.bodies.isEmpty, "an app on screen is not woken")

        // In the background: the next request wakes it.
        _ = try await phone.request("presence.set", ["foreground": false])
        let question = model.conversations.adoptChat(id: UUID(), for: product.id)
        var entry = ConversationEntry(productID: product.id, kind: .question, text: "Which one?")
        entry.chatID = question.id
        model.conversations.append(entry)
        for _ in 0..<40 where StubRelay.bodies.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let body = try XCTUnwrap(StubRelay.bodies.first)
        XCTAssertEqual(Set(body.keys), ["token", "environment"], "the relay is told which phone, and nothing about the work")
        XCTAssertEqual(body["token"] as? String, token)
        XCTAssertEqual(body["environment"] as? String, "development")
        XCTAssertEqual(StubRelay.paths.first, "/v1/notify")

        // A phone that no longer has the app: the relay says so, and the token is forgotten.
        StubRelay.reset(status: 410)
        phone.close()
        try await Task.sleep(for: .milliseconds(400))
        let third = model.conversations.adoptChat(id: UUID(), for: product.id)
        var again = ConversationEntry(productID: product.id, kind: .question, text: "And this?")
        again.chatID = third.id
        model.conversations.append(again)
        for _ in 0..<40 where link.devices.devices.first?.pushToken != nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(link.devices.devices.first?.pushToken)
    }

    /// A question in its own chat, the way the engine's card arrives.
    @MainActor
    private func question(_ text: String, product: UUID) -> UUID {
        let chat = model.conversations.adoptChat(id: UUID(), for: product)
        var entry = ConversationEntry(productID: product, kind: .question, text: text)
        entry.chatID = chat.id
        model.conversations.append(entry)
        return chat.id
    }

    /// What went to /v1/notify: a wake-up names its phone and never an `event` (a Live Activity does).
    @MainActor
    private func notifyBodies() -> [[String: Any]] {
        StubRelay.bodies.filter { $0["token"] != nil && $0["event"] == nil }
    }

    /// 6 Oct: two questions half a minute apart, and the second never reached the phone. The relay
    /// answered "too soon" (429), nothing tried again, and it was already counted as seen.
    @MainActor
    func testASecondQuestionInsideTheRelaysGapIsPushedWhenTheGapIsOverAndOpensItsChat() async throws {
        useStubRelay(features: .current)
        StubRelay.reset(status: 202, answers: [202, 429])
        link.wakeRetryAfter = .milliseconds(500)
        let key = SymmetricKey(size: .bits256)
        let seal = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        let product = model.products.add(name: "Narada")
        let (phone, _, _) = try await pairedPhone()
        _ = try await phone.request("presence.set", ["foreground": false])
        _ = try await phone.request("push.register", ["token": String(repeating: "ab", count: 32), "environment": "development",
                                                      "seal": seal, "kinds": ["attention", "finished", "done"]])
        try await Task.sleep(for: .milliseconds(300))

        let first = question("Which one?", product: product.id)
        for _ in 0..<40 where notifyBodies().count < 1 { try await Task.sleep(for: .milliseconds(50)) }
        let second = question("And which here?", product: product.id)
        for _ in 0..<40 where notifyBodies().count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(notifyBodies().count, 2, "the second went to the relay and was refused as too soon")
        for _ in 0..<60 where notifyBodies().count < 3 { try await Task.sleep(for: .milliseconds(50)) }
        let bodies = notifyBodies()
        XCTAssertEqual(bodies.count, 3, "and was sent again once the gap was over")
        let route = { (body: [String: Any]) in
            (body["sealed"] as? String).flatMap { LiveSeal.open($0, as: LiveSeal.Route.self, key: key) }
        }
        XCTAssertEqual(route(bodies[0]), LiveSeal.Route(productID: product.id.uuidString, chatID: first.uuidString),
                       "a tap opens the chat that asked")
        XCTAssertEqual(route(bodies[2]), LiveSeal.Route(productID: product.id.uuidString, chatID: second.uuidString),
                       "and the late one opens the second question's chat")
        XCTAssertFalse((bodies[2]["sealed"] as? String ?? "").contains("which"), "nothing of the question in the clear")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(notifyBodies().count, 3, "one late push, not a stream of them")
        phone.close()
    }

    /// A question that came while Bulava was not running — quit, crashed, rebuilt in the night —
    /// used to be taken for the starting line of the next start, and never pushed.
    @MainActor
    func testWhatCameWhileBulavaWasNotRunningIsPushedOnTheNextStart() async throws {
        useStubRelay()
        try FileManager.default.createDirectory(at: link.attentionSeenFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(["something-from-yesterday"]).write(to: link.attentionSeenFile)
        let product = model.products.add(name: "Narada")
        _ = question("Which one?", product: product.id)

        let (phone, _, _) = try await pairedPhone()
        _ = try await phone.request("presence.set", ["foreground": false])
        _ = try await phone.request("push.register", ["token": String(repeating: "ab", count: 32), "environment": "development"])
        for _ in 0..<40 where notifyBodies().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(notifyBodies().count, 1, "the question that waited through the restart is news")
        let kept = try JSONDecoder().decode([String].self, from: Data(contentsOf: link.attentionSeenFile))
        XCTAssertFalse(kept.contains("something-from-yesterday"), "and what is waiting now is what is kept")
        XCTAssertEqual(kept.count, 1)
        phone.close()
    }

    /// The control: a Mac that has never pushed has no record, and its first reading is still only
    /// the starting line — a phone paired for the first time is not woken for the whole backlog.
    @MainActor
    func testAMacThatNeverPushedStartsFromWhatIsThere() async throws {
        useStubRelay()
        let product = model.products.add(name: "Narada")
        _ = question("Which one?", product: product.id)
        let (phone, _, _) = try await pairedPhone()
        _ = try await phone.request("presence.set", ["foreground": false])
        _ = try await phone.request("push.register", ["token": String(repeating: "ab", count: 32), "environment": "development"])
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(notifyBodies().isEmpty, "the first reading ever is the starting line")
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.attentionSeenFile.path), "and from now on it is kept")
        _ = question("A new one", product: product.id)
        for _ in 0..<40 where notifyBodies().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(notifyBodies().count, 1, "what comes after it is news, as before")
        phone.close()
    }

    // MARK: - Finished work and the Live Activity

    /// `features`: what the relay says it takes — known up front, so no question to it is in the way.
    @MainActor
    private func useStubRelay(status: Int = 202, features: RelayFeatures = .legacy) {
        StubRelay.reset(status: status)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubRelay.self]
        link.pushSession = URLSession(configuration: config)
        link.relayOverride = URL(string: "https://relay.test")
        link.relayFeatures = features
        link.relayFeaturesCheckedAt = Date()
    }

    /// The counts as the Mac reads them, as a stretch of work: going on while anything works.
    @MainActor
    private func counts(_ working: Int, _ waiting: Int, _ ready: Int) {
        link.summaryChanged(SummaryDTO(working: working, waiting: waiting, ready: ready),
                            live: LiveDTO(running: [], ended: [], over: working == 0))
    }

    @MainActor
    private func reviewTask(_ title: String, product: UUID) -> BacklogTask {
        var task = BacklogTask(title: title, type: .feature, priority: .p2, state: .review)
        task.productID = product
        task.dispatchedAt = Date()
        return model.backlog.add(task)
    }

    @MainActor
    func testFinishedWorkIsInTheHomeWithItsReportAndCounted() async throws {
        let product = model.products.add(name: "Narada")
        let task = reviewTask("Export fix", product: product.id)
        let (phone, _, _) = try await pairedPhone()

        _ = try await phone.request("home.subscribe", [:])
        let homeFrame = try await phone.next { $0["event"] as? String == "home" }
        let home = try XCTUnwrap(homeFrame?["data"] as? [String: Any])
        let finished = try XCTUnwrap(home["finished"] as? [[String: Any]])
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?["id"] as? String, "done:\(task.id.uuidString)")
        XCTAssertEqual(finished.first?["title"] as? String, "Export fix")
        let report = try XCTUnwrap(finished.first?["report"] as? [String: Any])
        XCTAssertEqual(report["kind"] as? String, "report")
        let summary = try XCTUnwrap(home["summary"] as? [String: Any])
        XCTAssertEqual(summary["ready"] as? Int, 1)
        XCTAssertEqual(summary["working"] as? Int, 0)
        XCTAssertEqual(summary["waiting"] as? Int, (home["attention"] as? [Any])?.count)

        // The button is one the phone was handed, so the Mac opens it rather than calling it stale.
        let opened = try await phone.request("report.open", ["target": report["target"] as! String])
        XCTAssertNotEqual((opened["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.stale)

        // Read and approved on the Mac: it is no longer waiting.
        model.backlog.setState(task.id, .approved)
        let nextFrame = try await phone.next {
            $0["event"] as? String == "home" && (($0["data"] as? [String: Any])?["finished"] as? [Any])?.isEmpty == true
        }
        let next = try XCTUnwrap(nextFrame)
        XCTAssertEqual(((next["data"] as? [String: Any])?["summary"] as? [String: Any])?["ready"] as? Int, 0)
        phone.close()
    }

    @MainActor
    func testAReportThatCameInWakesAClosedIPhone() async throws {
        useStubRelay()
        let product = model.products.add(name: "Narada")
        let (phone, _, _) = try await pairedPhone()
        let token = String(repeating: "cd", count: 32)
        _ = try await phone.request("push.register", ["token": token, "environment": "production"])
        _ = try await phone.request("presence.set", ["foreground": false])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(StubRelay.bodies.isEmpty, "what was already there when the Mac started is not news")

        _ = reviewTask("Export fix", product: product.id)
        for _ in 0..<40 where StubRelay.bodies.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let body = try XCTUnwrap(StubRelay.bodies.first)
        XCTAssertEqual(StubRelay.paths.first, "/v1/notify")
        XCTAssertEqual(Set(body.keys), ["token", "environment", "kind"],
                       "which phone and which of the relay's sentences — nothing about the work")
        XCTAssertEqual(body["kind"] as? String, "finished")
        XCTAssertEqual(body["token"] as? String, token)
        phone.close()
    }

    @MainActor
    func testTheLiveActivityStartsFollowsTheCountsAndEnds() async throws {
        useStubRelay()
        link.activityGap = .milliseconds(300)
        let (phone, _, _) = try await pairedPhone()
        let start = String(repeating: "5a", count: 40)
        let running = String(repeating: "7b", count: 40)
        _ = try await phone.request("push.register", ["token": String(repeating: "ab", count: 32), "environment": "development"])
        let bad = try await phone.request("activity.register", ["kind": "start", "token": "not hex"])
        XCTAssertEqual((bad["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.badRequest)
        _ = try await phone.request("activity.register", ["kind": "start", "token": start])
        XCTAssertEqual(link.devices.devices.first?.activityStartToken, start)

        // On screen, the phone runs its own activity: nothing is pushed.
        counts(1, 0, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(StubRelay.paths.filter { $0 == "/v1/activity" }.isEmpty)
        counts(0, 0, 0)

        // Closed: work beginning starts one with a push, and the counts are all it carries.
        _ = try await phone.request("presence.set", ["foreground": false])
        counts(2, 0, 0)
        let started = try await activityPush()
        XCTAssertEqual(Set(started.keys), ["token", "environment", "event", "state"])
        XCTAssertEqual(started["event"] as? String, "start")
        XCTAssertEqual(started["token"] as? String, start)
        XCTAssertEqual(started["environment"] as? String, "development")
        XCTAssertEqual(started["state"] as? [String: Int], ["working": 2, "waiting": 0, "ready": 0])

        // The phone hands over the running activity's token; changes go to it, folded when close together.
        _ = try await phone.request("activity.register", ["kind": "update", "token": running])
        try await Task.sleep(for: .milliseconds(400))
        counts(1, 1, 0)
        counts(1, 1, 1)
        let updated = try await activityPush()
        XCTAssertEqual(updated["event"] as? String, "update")
        XCTAssertEqual(updated["token"] as? String, running)
        XCTAssertEqual(updated["state"] as? [String: Int], ["working": 1, "waiting": 1, "ready": 0])
        let folded = try await activityPush()
        XCTAssertEqual(folded["state"] as? [String: Int], ["working": 1, "waiting": 1, "ready": 1],
                       "the change that came too soon arrives once the gap is over")
        counts(1, 1, 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(StubRelay.bodies.filter { $0["event"] != nil }.isEmpty, "the same counts are not sent twice")

        // Nothing working, nothing waiting: the activity ends, and its token goes with it.
        counts(0, 0, 1)
        let ended = try await activityPush()
        XCTAssertEqual(ended["event"] as? String, "end")
        XCTAssertEqual(ended["state"] as? [String: Int], ["working": 0, "waiting": 0, "ready": 1])
        for _ in 0..<40 where link.devices.devices.first?.activityToken != nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(link.devices.devices.first?.activityToken, "the relay took the end, so the token is spent")

        // The next stretch of work starts a new one.
        counts(1, 0, 1)
        let restarted = try await activityPush()
        XCTAssertEqual(restarted["event"] as? String, "start")

        // An activity token Apple no longer knows is forgotten.
        _ = try await phone.request("activity.register", ["kind": "update", "token": running])
        StubRelay.reset(status: 410)
        counts(3, 0, 1)
        for _ in 0..<40 where link.devices.devices.first?.activityToken != nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(link.devices.devices.first?.activityToken)
        phone.close()
    }

    // MARK: - The run control and a finished chat

    @MainActor
    func testThePhoneIsOfferedTheMacsRunControlAndNoModeSwitch() async throws {
        let projection = LinkProjection.build(model, desktop: link.desktop, openChats: [])
        let composer = projection.home.composer
        XCTAssertFalse(composer.groups.contains { $0.id == "mode" },
                       "Claude alone and Codex alone are not a choice the Mac offers, so the phone is not offered them")
        XCTAssertEqual(composer.groups.first?.id, "claudeModel", "Claude first: it writes, Codex reviews")
        XCTAssertTrue(composer.groups.contains { $0.id == "codexModel" })
        for group in composer.groups {
            XCTAssertNotNil(group.engine, "\(group.id) says which engine it is for")
            XCTAssertTrue(["model", "depth"].contains(group.kind ?? ""), "\(group.id) says what it chooses")
        }
        let claude = try XCTUnwrap(composer.groups.first { $0.id == "claudeModel" })
        XCTAssertEqual(claude.options.first?.id, "auto")
        XCTAssertEqual(claude.options.filter { $0.section != nil }.map(\.id).prefix(4),
                       ClaudeModelChoice.families.map(\.rawValue).prefix(4))
        let summary = try XCTUnwrap(composer.summary)
        XCTAssertEqual(summary.map(\.engine), ["claude", "codex"])
        XCTAssertEqual(summary.map(\.model), [RunChoice.modelName(.claude, model), RunChoice.modelName(.codex, model)],
                       "the phone's chip says what the Mac's pill says")

        // An older phone still showing "Who answers" is told its menu is out of date.
        let (phone, _, _) = try await pairedPhone()
        let answer = try await phone.request("settings.set", ["group": "mode", "value": "claude"])
        XCTAssertEqual((answer["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.stale)
        XCTAssertEqual(model.settings.chatMode, .claudeAndCodex, "and the Mac stays on the pair")
        phone.close()
    }

    @MainActor
    func testAChatWhoseAnswerIsInWakesAPhoneThatCanSaySoAndNamesTheWorkOnlySealed() async throws {
        useStubRelay(features: .current)
        link.live.settle = 0.3
        link.activityGap = .milliseconds(50)
        let key = SymmetricKey(size: .bits256)
        let seal = key.withUnsafeBytes { Data($0) }.base64EncodedString()

        let product = model.products.add(name: "Narada")
        let chat = model.conversations.newChat(for: product.id)
        model.conversations.rename(chat.id, to: "Export fix")

        // Two iPhones with the app closed: a new one with a key that knows "done", an old one.
        let (fresh, _, _) = try await pairedPhone()
        _ = try await fresh.request("push.register", ["token": String(repeating: "ab", count: 32), "environment": "development",
                                                      "seal": seal, "kinds": ["attention", "finished", "done", "shout"]])
        _ = try await fresh.request("activity.register", ["kind": "start", "token": String(repeating: "5a", count: 40)])
        _ = try await fresh.request("presence.set", ["foreground": false])
        let (old, _, _) = try await pairedPhone()
        _ = try await old.request("push.register", ["token": String(repeating: "cd", count: 32), "environment": "production"])
        _ = try await old.request("presence.set", ["foreground": false])
        let freshID = try XCTUnwrap(link.devices.devices.first { $0.pushToken == String(repeating: "ab", count: 32) })
        XCTAssertEqual(freshID.pushKinds, ["attention", "finished", "done"], "a kind the Mac does not send is not kept")
        XCTAssertEqual(freshID.sealKey, seal)

        // The director asks; the chat works.
        model.sendingChatIDs.insert(chat.id)
        let started = try await activityPush()
        XCTAssertEqual(started["event"] as? String, "start")
        let state = try XCTUnwrap(started["state"] as? [String: Any])
        let sealed = try XCTUnwrap(state["sealed"] as? String, "the phone with a key is sent the names, sealed")
        XCTAssertFalse(sealed.contains("Export"), "and nothing of them in the clear")
        let box = try XCTUnwrap(LiveSeal.open(sealed, as: LiveSeal.Box.self, key: key))
        XCTAssertEqual(box.running.map(\.title), ["Export fix"])
        XCTAssertEqual(box.running.first?.product, "Narada")
        XCTAssertEqual(box.chatID, chat.id.uuidString)
        XCTAssertFalse(box.over)

        // The answer is in, and stays in: once it has settled, the phone that can say so is told.
        model.sendingChatIDs.remove(chat.id)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: "/tmp/narada",
                                                           outcomeAt: Date()), to: chat.id)
        XCTAssertEqual(model.directPhase(for: chat.id), .ready)
        for _ in 0..<60 where !StubRelay.bodies.contains(where: { $0["kind"] as? String == "done" }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let done = StubRelay.bodies.filter { $0["kind"] as? String == "done" }
        XCTAssertEqual(done.count, 1, "one push for one answer, and none to the phone that has no words for it")
        XCTAssertEqual(done.first?["token"] as? String, String(repeating: "ab", count: 32))
        let route = try XCTUnwrap((done.first?["sealed"] as? String).flatMap { LiveSeal.open($0, as: LiveSeal.Route.self, key: key) })
        XCTAssertEqual(route, LiveSeal.Route(productID: product.id.uuidString, chatID: chat.id.uuidString),
                       "a tap opens the chat that answered")
        XCTAssertEqual(link.live.detail.ended.first?.outcome, "done")
        fresh.close()
        old.close()
    }

    @MainActor
    func testAnOlderRelayIsSentOnlyWhatItTakes() async throws {
        // Asked first: a relay that does not know the question is an older one.
        StubRelay.reset(status: 404)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubRelay.self]
        link.pushSession = URLSession(configuration: config)
        link.relayOverride = URL(string: "https://relay.test")
        link.checkRelayFeatures()
        for _ in 0..<40 where link.relayFeatures == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(StubRelay.paths, ["/v1/features"])
        XCTAssertEqual(link.relayFeatures, .legacy)

        StubRelay.reset(status: 202)
        link.live.settle = 0.3
        let key = SymmetricKey(size: .bits256)
        let product = model.products.add(name: "Narada")
        let chat = model.conversations.newChat(for: product.id)
        let (phone, _, _) = try await pairedPhone()
        _ = try await phone.request("push.register", ["token": String(repeating: "ab", count: 32), "environment": "development",
                                                      "seal": key.withUnsafeBytes { Data($0) }.base64EncodedString(),
                                                      "kinds": ["attention", "finished", "done"]])
        _ = try await phone.request("activity.register", ["kind": "start", "token": String(repeating: "5a", count: 40)])
        _ = try await phone.request("presence.set", ["foreground": false])
        model.sendingChatIDs.insert(chat.id)
        let started = try await activityPush()
        XCTAssertNil((started["state"] as? [String: Any])?["sealed"], "an older relay would refuse the box, so none goes")
        model.sendingChatIDs.remove(chat.id)
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: "/tmp/narada",
                                                           outcomeAt: Date()), to: chat.id)
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertFalse(StubRelay.bodies.contains { $0["kind"] as? String == "done" }, "nor a kind it does not know")
        phone.close()
    }

    // MARK: - The Mac's dialogs, on the phone

    private func tree(author: String?) -> DirtyTree {
        DirtyTree(dirty: true, unborn: false, head: "abc123", branch: "bulava-mobile-assistant", digest: "d1",
                  author: author, keepPossible: true, total: 3,
                  files: [.init(xy: " M", path: "Night Shift/App/AppModel.swift"),
                          .init(xy: "M ", path: "Night Shift/App/AppSettings.swift")])
    }

    /// A task that met a question on its way to starting is a dialog on the Mac. On the phone it is
    /// an item that needs the director, with the dialog's own buttons — and answered there, it is
    /// gone from the Mac too.
    @MainActor
    func testATaskThatStoppedOnAQuestionAsksThePhoneWithTheMacsOwnButtons() async throws {
        let product = model.products.add(name: "Narada")
        var task = BacklogTask(title: "Export fix", type: .feature, priority: .p2, state: .ready)
        task.productID = product.id
        task = model.backlog.add(task)
        let dirty = tree(author: "IvanStepanok <ivan@example.com>")
        model.dirtyTreeAsk = AppModel.DirtyTreeAsk(task: task, folder: "/tmp/narada", tree: dirty)
        model.mcpAsk = AppModel.McpAsk(task: task, folder: "/tmp/narada", servers: ["github", "xcode"])
        model.gitConsentAsk = AppModel.GitConsentAsk(task: task, folder: "/tmp/narada")

        let (phone, _, _) = try await pairedPhone()
        _ = try await phone.request("home.subscribe", [:])
        let frame = try await phone.next { $0["event"] as? String == "home" }
        let attention = try XCTUnwrap((frame?["data"] as? [String: Any])?["attention"] as? [[String: Any]])
        let item = try XCTUnwrap(attention.first { ($0["id"] as? String)?.hasPrefix("task.dirty:") == true },
                                 "uncommitted work a task met reaches the phone")
        XCTAssertEqual(item["title"] as? String, "Export fix")
        XCTAssertEqual(item["productID"] as? String, product.id.uuidString)
        XCTAssertTrue((item["code"] as? String)?.contains("AppModel.swift") == true, "with the files the dialog lists")
        let buttons = try XCTUnwrap(item["actions"] as? [[String: Any]])
        XCTAssertEqual(buttons.count, 4, "leave, commit, sort it out, not now — the dialog's four")
        let sheet = try XCTUnwrap(buttons[1]["input"] as? [String: Any], "«Commit as me…» carries the Mac's sheet")
        XCTAssertEqual(sheet["value"] as? String, dirty.suggestedMessage)
        XCTAssertTrue(((sheet["above"] as? [[String: Any]])?.first?["text"] as? String)?.contains("IvanStepanok") == true,
                      "the author is on the screen before anything is pressed")
        let below = try XCTUnwrap(sheet["below"] as? [[String: Any]])
        XCTAssertTrue(below.contains { ($0["text"] as? String)?.contains("bulava-mobile-assistant") == true }, "which branch")
        XCTAssertTrue(below.contains { $0["mono"] as? Bool == true && ($0["text"] as? String)?.contains("AppSettings.swift") == true },
                      "every file it takes")
        XCTAssertTrue(below.contains { $0["tone"] as? String == "attention" }, "staged and not staged: the sheet says so")
        XCTAssertNil(sheet["blocked"])
        XCTAssertNotNil(attention.first { ($0["id"] as? String)?.hasPrefix("task.mcp:") == true }, "MCP servers a task met")
        XCTAssertNotNil(attention.first { ($0["id"] as? String)?.hasPrefix("task.git:") == true }, "a folder with no git")

        let notNow = try XCTUnwrap(buttons[3]["id"] as? String)
        let answered = try await phone.request("action.invoke", ["id": notNow])
        XCTAssertEqual(answered["ok"] as? Bool, true)
        XCTAssertNil(model.dirtyTreeAsk, "the Mac's dialog goes with it")
        let twice = try await phone.request("action.invoke", ["id": notNow])
        XCTAssertEqual((twice["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.stale)

        let git = try XCTUnwrap(attention.first { ($0["id"] as? String)?.hasPrefix("task.git:") == true })
        let gitNo = try XCTUnwrap((git["actions"] as? [[String: Any]])?.last?["id"] as? String)
        _ = try await phone.request("action.invoke", ["id": gitNo])
        XCTAssertNil(model.gitConsentAsk)
        phone.close()
    }

    /// The Mac's sheet will not commit when git does not know the author, and neither will the phone.
    @MainActor
    func testACommitGitHasNoAuthorForIsRefusedOnThePhoneToo() async throws {
        let product = model.products.add(name: "Narada")
        let chat = model.conversations.newChat(for: product.id)
        let asked = model.conversations.appendUser("Start on the release notes", productID: product.id, chatID: chat.id)
        model.conversations.updateDelivery(entryID: asked.id, .failed)
        model.dirtyTreeBlocked[chat.id] = AppModel.DirtyTreeBlock(entryID: asked.id, folder: "/tmp/narada", tree: tree(author: nil))

        let (phone, _, _) = try await pairedPhone()
        _ = try await phone.request("chat.open", ["chatID": chat.id.uuidString])
        let full = try await phone.next { $0["event"] as? String == "chat" }
        let entries = try XCTUnwrap((full?["data"] as? [String: Any])?["entries"] as? [[String: Any]])
        let ask = try XCTUnwrap(entries.compactMap { ($0["asks"] as? [[String: Any]])?.first }.first { $0["kind"] as? String == "uncommittedWork" })
        let commit = try XCTUnwrap((ask["actions"] as? [[String: Any]])?.first { ($0["id"] as? String)?.hasPrefix("dirty.commit:") == true })
        let sheet = try XCTUnwrap(commit["input"] as? [String: Any])
        XCTAssertNotNil(sheet["blocked"], "the sheet says why, and its button stays off")
        XCTAssertNotNil(sheet["submit"])
        let tried = try await phone.request("action.invoke", ["id": commit["id"] as! String, "input": ["text": "Release notes"]])
        XCTAssertEqual((tried["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.failed)
        XCTAssertNil(model.dirtyTreeAnswer[chat.id], "nothing was committed")
        phone.close()
    }

    /// Files too big for the checkpoint reach the phone as the Mac's row: the headline, the files with
    /// their sizes and the «in git» mark, and the same three answers. «Not now» works once.
    @MainActor
    func testFilesTooBigForTheCheckpointAreACardOnThePhone() async throws {
        let product = model.products.add(name: "Narada")
        let chat = model.conversations.newChat(for: product.id)
        let asked = model.conversations.appendUser("Cut the trailer", productID: product.id, chatID: chat.id)
        model.conversations.updateDelivery(entryID: asked.id, .failed)
        let files = try XCTUnwrap(HeavyFiles.parse(#"{"fits_after":false,"file_limit_bytes":268435456,"files":[{"path":"Movies/Screen Recording.mov","rule":"/Movies/Screen Recording.mov","size":4013948928,"tracked":false},{"path":"model.bin","rule":null,"size":300000000,"tracked":true}],"limit_bytes":1073741824,"remaining_bytes":300001204,"total_bytes":4313950132}"#))
        model.heavyFilesBlocked[chat.id] = AppModel.HeavyFilesBlock(entryID: asked.id, folder: "/tmp/narada", files: files)

        let (phone, _, _) = try await pairedPhone()
        _ = try await phone.request("chat.open", ["chatID": chat.id.uuidString])
        let full = try await phone.next { $0["event"] as? String == "chat" }
        let entries = try XCTUnwrap((full?["data"] as? [String: Any])?["entries"] as? [[String: Any]])
        let ask = try XCTUnwrap(entries.compactMap { ($0["asks"] as? [[String: Any]])?.first }.first { $0["kind"] as? String == "largeFiles" })
        XCTAssertFalse((ask["title"] as? String ?? "").isEmpty)
        let code = try XCTUnwrap(ask["code"] as? String)
        XCTAssertTrue(code.contains("Movies/Screen Recording.mov"), code)
        XCTAssertTrue(code.contains("model.bin"), code)
        XCTAssertNotNil(ask["detail"], "why the tracked file cannot be left out")
        let ids = try XCTUnwrap((ask["actions"] as? [[String: Any]])?.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids[0].hasPrefix("heavy.local:"))
        XCTAssertTrue(ids[1].hasPrefix("heavy.gitignore:"))
        let notNow = ids[2]
        let answered = try await phone.request("action.invoke", ["id": notNow])
        XCTAssertEqual(answered["ok"] as? Bool, true)
        XCTAssertNil(model.heavyFilesBlocked[chat.id], "the Mac's row goes with it")
        let twice = try await phone.request("action.invoke", ["id": notNow])
        XCTAssertEqual((twice["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.stale)
        phone.close()
    }

    // MARK: - The chat's details

    /// The Mac's right-hand pane on the phone: this chat's reports, newest first, named by when and
    /// what — not "index.html" each — with "Create report"; nothing of the kind for a chat of
    /// another product, and no "Create report" for an archived chat.
    @MainActor
    func testTheDetailsCarryThisChatsReportsLikeTheMacsPane() async throws {
        let product = model.products.add(name: "Narada")
        let other = model.products.add(name: "Harbor")
        let chat = model.conversations.newChat(for: product.id)
        let paths = ["/p/artifacts/2026-09-26-0910-перший-звіт/index.html", "/p/artifacts/2026-09-27-1210-export-fix-on-the-phone/index.html"]
        model.conversations.bindSession(ChatSessionBinding(primaryProjectID: nil, projectPath: "/tmp/narada", claudeSessionID: "S1",
                                                           reportPaths: paths), to: chat.id)
        let (phone, _, _) = try await pairedPhone()

        let answer = try await phone.request("context.get", ["productID": product.id.uuidString, "chatID": chat.id.uuidString])
        let result = try XCTUnwrap(answer["result"] as? [String: Any])
        let reports = try XCTUnwrap(result["chatReports"] as? [String: Any], "the chat's reports reach the phone")
        let items = try XCTUnwrap(reports["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?["title"] as? String, String(localized: "Latest report"))
        XCTAssertTrue((items.first?["detail"] as? String)?.contains("Export fix on the phone") == true, "named by its folder, newest first")
        XCTAssertFalse((items.first?["detail"] as? String)?.contains("index.html") == true)
        let open = try XCTUnwrap((items.first?["open"] as? [String: Any])?["target"] as? String)
        let opened = try await phone.request("report.open", ["target": open])
        XCTAssertNotEqual((opened["error"] as? [String: Any])?["code"] as? String, LinkErrorCode.stale, "the phone was handed it")
        XCTAssertNotNil(reports["create"], "“Create report”, as on the Mac")

        let elsewhere = try await phone.request("context.get", ["productID": other.id.uuidString, "chatID": chat.id.uuidString])
        XCTAssertNil((elsewhere["result"] as? [String: Any])?["chatReports"], "another product's details never carry this chat")

        model.conversations.setArchived(chat.id, true)
        let archived = try await phone.request("context.get", ["productID": product.id.uuidString, "chatID": chat.id.uuidString])
        XCTAssertNil(((archived["result"] as? [String: Any])?["chatReports"] as? [String: Any])?["create"],
                     "an archived chat is read only")
        phone.close()
    }

    /// Re-reading the details every few seconds names the same file the same way, so a session's
    /// diff entries do not pile up.
    func testADiffRefIsTheSameForTheSameFile() {
        let a = MobileLink.diffRef(project: "/p/narada", file: "Sources/Export.swift")
        XCTAssertEqual(a, MobileLink.diffRef(project: "/p/narada", file: "Sources/Export.swift"))
        XCTAssertNotEqual(a, MobileLink.diffRef(project: "/p/narada", file: "Sources/Import.swift"))
        XCTAssertNotEqual(a, MobileLink.diffRef(project: "/p/harbor", file: "Sources/Export.swift"))
        XCTAssertTrue(a.hasPrefix("diff:"))
    }

    /// The phone is sent the foot of the sidebar by the sidebar's own rules.
    @MainActor
    func testThePhoneIsSentTheLimitsAsTheSidebarShowsThem() throws {
        let now = Date()
        XCTAssertNil(LinkProjection.limits(CapacitySnapshot(), now: now), "nothing heard from either engine")

        var claude = UsageSnapshot.empty
        claude.present = true
        claude.updatedAt = now.addingTimeInterval(-60)
        claude.fiveHour = UsageWindow(usedPercent: 33.6, resetsAt: now.addingTimeInterval(2 * 3600 + 5 * 60))
        claude.sevenDay = UsageWindow(usedPercent: 91, resetsAt: now.addingTimeInterval(3 * 86400))
        var codex = UsageSnapshot.empty
        codex.present = true
        codex.updatedAt = now.addingTimeInterval(-2 * 3600)
        // Its reset has passed: it starts over, and the sidebar stops showing the old share.
        codex.fiveHour = UsageWindow(usedPercent: 70, resetsAt: now.addingTimeInterval(-60))

        let limits = try XCTUnwrap(LinkProjection.limits(CapacitySnapshot(claude: claude, codex: codex), now: now))
        XCTAssertEqual(limits.engines.map(\.name), ["Claude", "Codex"])

        let c = limits.engines[0]
        XCTAssertEqual(c.windows.map(\.used), [34, 91])
        XCTAssertEqual(c.windows.map(\.pressure), ["comfortable", "nearlyOut"])
        XCTAssertEqual(c.used, claude.tightestShown(now: now), "the folded line gives the tightest, as the sidebar's")
        XCTAssertEqual(c.pressure, "nearlyOut")
        XCTAssertNotNil(c.windows[0].resets)
        XCTAssertTrue(c.windows[0].usedLabel.contains("34"))
        XCTAssertFalse(c.stale)
        XCTAssertNil(c.readAgo)
        XCTAssertNil(c.note)

        let x = limits.engines[1]
        XCTAssertTrue(x.windows.isEmpty)
        XCTAssertNil(x.used)
        XCTAssertNotNil(x.note, "said in place of the meters")
        XCTAssertTrue(x.stale, "read two hours ago")
        XCTAssertNotNil(x.readAgo)
    }

    func testAReportIsNamedByItsFolderNotItsFile() {
        let path = "/Users/me/p/artifacts/2026-09-04-1212-нічна-зміна-3-4-вересня/index.html"
        XCTAssertEqual(ReportName.title(path), "Нічна зміна 3 4 вересня")
        let date = try? XCTUnwrap(ReportName.date(path))
        XCTAssertEqual(date.map { Calendar.current.component(.hour, from: $0) }, 12)
        XCTAssertEqual(ReportName.title("/p/notes/summary.pdf"), "summary.pdf", "anything else keeps its own name")
        XCTAssertNil(ReportName.date("/p/notes/index.html"))
    }

    /// A phone with the app closed and the relay set up, ready for Live Activity pushes.
    @MainActor
    private func closedIPhoneForActivities(start: String, running: String?) async throws -> TestPhone {
        link.activityGap = .milliseconds(100)
        link.activityRetryBase = .milliseconds(60)
        link.activityRetryCap = .milliseconds(240)
        let (phone, _, _) = try await pairedPhone()
        _ = try await phone.request("push.register", ["token": String(repeating: "ab", count: 32), "environment": "development"])
        _ = try await phone.request("activity.register", ["kind": "start", "token": start])
        if let running { _ = try await phone.request("activity.register", ["kind": "update", "token": running]) }
        _ = try await phone.request("presence.set", ["foreground": false])
        return phone
    }

    @MainActor
    private func activityEvents() -> [String] {
        StubRelay.bodies.compactMap { $0["event"] as? String }
    }

    @MainActor
    func testAStartThatDidNotGetThroughIsTriedAgainUntilTheRelayTakesIt() async throws {
        useStubRelay()
        let start = String(repeating: "5a", count: 40)
        let phone = try await closedIPhoneForActivities(start: start, running: nil)
        counts(0, 0, 0)

        // No network, then the relay's limit, then a server error, then it goes through.
        StubRelay.reset(status: 202, answers: [0, 429, 503])
        counts(1, 0, 0)
        // The relay records a body before its answer is back at the link, so the count of pushes
        // taken is waited for as well — a busy machine runs the suite slower than the backoff.
        for _ in 0..<120 where activityEvents().count < 4 || link.activityPushesSent < 1 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(activityEvents(), ["start", "start", "start", "start"], "tried again after each failure")
        XCTAssertEqual(Set(StubRelay.bodies.compactMap { $0["token"] as? String }), [start])
        XCTAssertEqual(link.activityPushesSent, 1, "one of them was taken")

        // Taken: not started again in this stretch of work.
        counts(2, 0, 0)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(activityEvents().count, 4)
        phone.close()
    }

    @MainActor
    func testAnEndThatDidNotGetThroughKeepsItsTokenAndIsTriedAgain() async throws {
        useStubRelay()
        let running = String(repeating: "7b", count: 40)
        let phone = try await closedIPhoneForActivities(start: String(repeating: "5a", count: 40), running: running)
        counts(1, 0, 0)
        for _ in 0..<40 where activityEvents().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(activityEvents(), ["update"])

        StubRelay.reset(status: 202, answers: [500, 0])
        counts(0, 0, 2)
        for _ in 0..<40 where activityEvents().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(link.devices.devices.first?.activityToken, running, "a failed end leaves the token, or nothing could end it")
        for _ in 0..<60 where activityEvents().count < 3 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(activityEvents(), ["end", "end", "end"])
        XCTAssertEqual(Set(StubRelay.bodies.compactMap { $0["token"] as? String }), [running])
        for _ in 0..<40 where link.devices.devices.first?.activityToken != nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(link.devices.devices.first?.activityToken, "once taken, the token is spent")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(activityEvents().count, 3, "and nothing more is sent")
        phone.close()
    }

    @MainActor
    func testAnUpdateThatDidNotGetThroughArrivesWithTheLatestCounts() async throws {
        useStubRelay()
        let running = String(repeating: "7b", count: 40)
        let phone = try await closedIPhoneForActivities(start: String(repeating: "5a", count: 40), running: running)
        StubRelay.reset(status: 202, answers: [429])
        counts(1, 0, 0)
        for _ in 0..<40 where activityEvents().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        // While it waits to be tried again, the counts move on.
        counts(1, 2, 0)
        for _ in 0..<60 where activityEvents().count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(activityEvents(), ["update", "update"])
        XCTAssertEqual(StubRelay.bodies.last?["state"] as? [String: Int], ["working": 1, "waiting": 2, "ready": 0])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(activityEvents().count, 2, "taken, and not sent again")
        phone.close()
    }

    @MainActor
    func testRetriesAreBoundedAndBackOff() async throws {
        XCTAssertEqual(link.activityBackoff(1), .seconds(2))
        XCTAssertEqual(link.activityBackoff(2), .seconds(4))
        XCTAssertEqual(link.activityBackoff(5), .seconds(32))
        XCTAssertEqual(link.activityBackoff(6), .seconds(60), "never more than a minute")
        XCTAssertEqual(link.activityBackoff(40), .seconds(60))

        useStubRelay()
        let phone = try await closedIPhoneForActivities(start: String(repeating: "5a", count: 40), running: nil)
        link.maxActivityRetries = 3
        StubRelay.reset(status: 503)
        counts(1, 0, 0)
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(activityEvents().count, 4, "the first try and three more, then it stops")
        XCTAssertNotNil(link.devices.devices.first?.activityStartToken, "a server error is not a reason to forget the token")

        // The next change tries again.
        StubRelay.reset(status: 202)
        counts(2, 0, 0)
        for _ in 0..<40 where activityEvents().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(activityEvents(), ["start"])
        phone.close()
    }

    @MainActor
    func testAStartGivenUpOnIsStartedOnTheBeatWithTheSameCounts() async throws {
        useStubRelay()
        let start = String(repeating: "5a", count: 40)
        let phone = try await closedIPhoneForActivities(start: start, running: nil)
        link.maxActivityRetries = 2
        StubRelay.reset(status: 503)
        counts(1, 0, 0)
        for _ in 0..<60 where activityEvents().count < 3 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(activityEvents(), ["start", "start", "start"], "the first try and two more, then it stops")

        // The same counts again — the Mac re-reads them at every change of anything — send nothing.
        counts(1, 0, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(activityEvents().count, 3, "no tight loop on a start that was given up on")

        // The relay is back; nothing changed in the work; the ten-minute beat comes.
        StubRelay.reset(status: 202)
        link.refreshActivities()
        for _ in 0..<40 where activityEvents().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(activityEvents(), ["start"])
        XCTAssertEqual(StubRelay.bodies.first?["token"] as? String, start)
        XCTAssertEqual(link.activityPushesSent, 1)

        // Taken: the next beat does not start a second one.
        StubRelay.reset(status: 202)
        link.refreshActivities()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(activityEvents().isEmpty, "an accepted start is not repeated")
        phone.close()
    }

    @MainActor
    func testARefusedPushChangesNothingAndIsTriedAgainOnTheBeat() async throws {
        useStubRelay()
        let running = String(repeating: "7b", count: 40)
        let phone = try await closedIPhoneForActivities(start: String(repeating: "5a", count: 40), running: nil)

        // A refused start: not counted as started, not sent again in a loop, started on the beat.
        StubRelay.reset(status: 202, answers: [400])
        counts(1, 0, 0)
        for _ in 0..<40 where activityEvents().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        counts(1, 0, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(activityEvents(), ["start"], "refused once, and not sent again until something changes")
        XCTAssertEqual(link.activityPushesSent, 0)
        XCTAssertNil(link.activityStartedAt[link.devices.devices[0].id], "a refused start did not start anything")
        link.refreshActivities()
        for _ in 0..<40 where activityEvents().count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(activityEvents(), ["start", "start"])
        XCTAssertEqual(link.activityPushesSent, 1)

        // A refused update: the counts are still due, and go on the beat.
        _ = try await phone.request("activity.register", ["kind": "update", "token": running])
        StubRelay.reset(status: 202, answers: [400])
        counts(1, 1, 0)
        for _ in 0..<40 where activityEvents().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(activityEvents(), ["update"])
        link.refreshActivities()
        for _ in 0..<40 where activityEvents().count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(activityEvents(), ["update", "update"])
        XCTAssertEqual(StubRelay.bodies.last?["state"] as? [String: Int], ["working": 1, "waiting": 1, "ready": 0])
        XCTAssertEqual(link.activityPushesSent, 2)

        // A refused end keeps the token, so the activity can still be ended; the beat ends it.
        StubRelay.reset(status: 202, answers: [400])
        counts(0, 0, 1)
        for _ in 0..<40 where activityEvents().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(activityEvents(), ["end"])
        XCTAssertEqual(link.devices.devices.first?.activityToken, running, "a refused end leaves the token")
        link.refreshActivities()
        for _ in 0..<40 where link.devices.devices.first?.activityToken != nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(activityEvents(), ["end", "end"])
        XCTAssertNil(link.devices.devices.first?.activityToken, "taken, so the token is spent")
        phone.close()
    }

    @MainActor
    func testAStartTokenAppleNoLongerKnowsIsForgottenAndNotRetried() async throws {
        useStubRelay()
        let phone = try await closedIPhoneForActivities(start: String(repeating: "5a", count: 40), running: nil)
        StubRelay.reset(status: 410)
        counts(1, 0, 0)
        for _ in 0..<40 where link.devices.devices.first?.activityStartToken != nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(link.devices.devices.first?.activityStartToken)
        try await Task.sleep(for: .milliseconds(400))
        link.refreshActivities()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(activityEvents(), ["start"], "nothing left to send it to")
        phone.close()
    }

    /// The next Live Activity push the relay was sent, taken off the list.
    @MainActor
    private func activityPush() async throws -> [String: Any] {
        for _ in 0..<40 where !StubRelay.bodies.contains(where: { $0["event"] != nil }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let i = try XCTUnwrap(StubRelay.bodies.firstIndex { $0["event"] != nil }, "no Live Activity push arrived")
        XCTAssertEqual(StubRelay.paths[i], "/v1/activity")
        StubRelay.paths.remove(at: i)
        return StubRelay.bodies.remove(at: i)
    }
}

/// The push relay, as far as the Mac can tell: records what it was sent and answers `status` —
/// or, first, each of `answers` in turn, where 0 is a network that is not there.
nonisolated final class StubRelay: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var status = 202
    nonisolated(unsafe) static var answers: [Int] = []
    private static let lock = NSLock()
    static func reset(status: Int, answers: [Int] = []) {
        lock.lock(); defer { lock.unlock() }
        bodies = []; paths = []; self.status = status; self.answers = answers
    }
    private static func record(_ body: [String: Any]?, path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let body { bodies.append(body) }
        paths.append(path)
        return answers.isEmpty ? status : answers.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "relay.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var out = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                out.append(buffer, count: n)
            }
            stream.close()
            data = out
        }
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let status = Self.record(json, path: request.url?.path ?? "")
        if status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - A phone, for tests

/// A stand-in for Whisper: says what it was told to, and keeps what it was asked to hear.
nonisolated final class Ears: @unchecked Sendable {
    private let answer: LinkTranscriptions.Outcome
    private let delay: Duration
    private let lock = NSLock()
    private var _heard: [URL] = []
    private var _language: String?

    init(_ answer: LinkTranscriptions.Outcome, delay: Duration = .zero) {
        self.answer = answer
        self.delay = delay
    }

    var heard: [URL] { lock.withLock { _heard } }
    var language: String? { lock.withLock { _language } }

    var engine: LinkTranscriptions.Engine {
        { [self] url, language in
            self.lock.withLock {
                self._heard.append(url)
                self._language = language
            }
            if self.delay > .zero { try? await Task.sleep(for: self.delay) }
            return self.answer
        }
    }
}

nonisolated struct LinkCredentialJSON: Sendable {
    var deviceID: String
    var secret: String
}

/// The phone's side of the link, reduced to what the tests need: pinned TLS, JSON frames, requests
/// with ids and the events in between.
nonisolated final class TestPhone: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let port: Int
    let pin: String
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var inbox: [[String: Any]] = []
    private var opened: CheckedContinuation<Void, Error>?
    private var closed = false

    init(port: Int, pin: String) {
        self.port = port
        self.pin = pin
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    func connect() async throws {
        task = session.webSocketTask(with: URL(string: "wss://127.0.0.1:\(port)/link")!)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            opened = c
            task.resume()
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        opened?.resume(); opened = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        closed = true
        opened?.resume(throwing: error ?? URLError(.cancelled)); opened = nil
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, let key = SecCertificateCopyKey(leaf),
              let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let spki = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                         0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]) + x963
        let got = LinkIdentity.base64url(Data(SHA256.hash(data: spki)))
        if got == pin {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveOne() async throws -> [String: Any] {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await self.task.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw URLError(.timedOut)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: data = Data()
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func next(_ matching: ([String: Any]) -> Bool) async throws -> [String: Any]? {
        if let i = inbox.firstIndex(where: matching) { return inbox.remove(at: i) }
        while true {
            let frame = try await receiveOne()
            if matching(frame) { return frame }
            inbox.append(frame)
        }
    }

    func waitClosed() async throws {
        for _ in 0..<60 {
            if closed { return }
            do { _ = try await receiveOne() } catch { return }
        }
    }

    func hello(pairing: String? = nil, credential: LinkCredentialJSON? = nil,
               version: Int = LinkProtocol.version, minimum: Int = LinkProtocol.minimumVersion) async throws -> [String: Any] {
        var hello: [String: Any] = [
            "type": "hello", "protocolVersion": version, "minimumVersion": minimum,
            "app": ["platform": "android", "version": "1.0", "deviceName": "Test phone"],
        ]
        if let pairing { hello["pairing"] = ["token": pairing] }
        if let credential { hello["credential"] = ["deviceID": credential.deviceID, "secret": credential.secret] }
        try await send(hello)
        return try await next { ["welcome", "refused"].contains($0["type"] as? String ?? "") } ?? [:]
    }

    func request(_ op: String, _ args: [String: Any]) async throws -> [String: Any] {
        let id = UUID().uuidString
        try await send(["type": "request", "id": id, "op": op, "args": args])
        return try await next { $0["type"] as? String == "response" && $0["id"] as? String == id } ?? [:]
    }
}

extension Data {
    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
