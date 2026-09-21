import Foundation

nonisolated struct ChatReportRequest: Sendable {
    let id: UUID
    let directory: URL
    let instructionFile: URL
    let artifactPointer: URL
    let artifactsRoot: URL
    let relayMessage: String
}

extension SupervisorClient {
    // MARK: - Per-task result reports (worker-produced manifest + assets)

    func reportManifest(task8: String) -> ReportManifest? {
        let url = paths.reportDir(task8: task8).appendingPathComponent("report.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let m = try? JSONDecoder().decode(ReportManifest.self, from: data)
        return (m?.hasContent == true) ? m : nil
    }

    func artifactPage(task8: String) -> URL? {
        let pointer = paths.reportDir(task8: task8).appendingPathComponent("artifact-path")
        guard let raw = try? String(contentsOf: pointer, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func renderReport(task8: String, fallbackTitle: String) -> URL? {
        if let artefact = artifactPage(task8: task8) { return artefact }
        guard let m = reportManifest(task8: task8) else { return nil }
        let dir = paths.reportDir(task8: task8)
        let html = ReportHTML.page(m, fallbackTitle: fallbackTitle)
        let url = dir.appendingPathComponent("report.html")
        guard (try? html.data(using: .utf8)?.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    func renderItemReport(itemKey: String, title: String, productName: String,
                          sections: [ReportHTML.ItemSection],
                          delivered: Int, failed: Int, unfinished: Int, missing: Int,
                          generatedAt: String) -> URL? {
        let root = paths.reportsDir
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let html = ReportHTML.itemPage(title: title, productName: productName, sections: sections,
                                       deliveredCount: delivered, failedCount: failed,
                                       unfinishedCount: unfinished, missingCount: missing,
                                       generatedAt: generatedAt)
        let url = root.appendingPathComponent("task-\(itemKey).html")
        guard let data = html.data(using: .utf8), (try? data.write(to: url, options: .atomic)) != nil else {
            return nil
        }
        return url
    }

    func reportHTMLPath(projectPath: String, sessionID: String) -> String? {
        let slug = Slug.forPath(projectPath)
        let candidates = [
            paths.instanceDir(slug: slug).appendingPathComponent("evidence/\(sessionID)/report/report.html"),
            paths.evidenceDir.appendingPathComponent("\(sessionID)/report/report.html"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    func generateReport(projectPath: String, orchestratorHome: String,
                        sessionID: String, language: String) async -> String? {
        guard FileManager.default.fileExists(atPath: "\(orchestratorHome)/bin/report.sh") else { return nil }

        _ = await runVerify(projectPath: projectPath, orchestratorHome: orchestratorHome, sessionID: sessionID)
        let r = await Shell.run("bash \"$1/bin/report.sh\" \"$2\" \"$3\" \"$4\"",
                                args: [orchestratorHome, projectPath, sessionID, language],
                                timeout: 1200)
        let out = r.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        if let out, out.hasSuffix(".html"), FileManager.default.fileExists(atPath: out) { return out }
        return reportHTMLPath(projectPath: projectPath, sessionID: sessionID)
    }

    func publishChatReport(htmlPath: String, projectPath: String, title: String) -> String? {
        let fileManager = FileManager.default
        let source = URL(fileURLWithPath: htmlPath)
        guard fileManager.fileExists(atPath: source.path) else { return nil }

        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let slug = title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9а-яіїєґ]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let folder = "\(date)-\(slug.isEmpty ? "chat-report" : String(slug.prefix(42)))-\(suffix)"
        let artifacts = URL(fileURLWithPath: projectPath).appendingPathComponent("artifacts", isDirectory: true)
        let destinationDir = artifacts.appendingPathComponent(folder, isDirectory: true)
        let destination = destinationDir.appendingPathComponent("index.html")
        do {
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)

            let ignore = URL(fileURLWithPath: projectPath).appendingPathComponent(".gitignore")
            let old = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
            let lines = old.split(whereSeparator: \.isNewline).map(String.init)
            if !lines.contains("artifacts/") {
                let separator = old.isEmpty || old.hasSuffix("\n") ? "" : "\n"
                try (old + separator + "artifacts/\n").write(to: ignore, atomically: true, encoding: .utf8)
            }
            return destination.path
        } catch {
            try? fileManager.removeItem(at: destinationDir)
            return nil
        }
    }

    // MARK: - Direct-chat reports (the same Claude session, the worker's rich artefact)

    func generateRichChatReport(projectPath: String, orchestratorHome: String,
                                sessionID: String, branch: String?, runID: String?,
                                language: String, title: String, originalRequest: String,
                                timeout: Duration = .seconds(1_200)) async -> String? {
        guard let request = prepareChatReportRequest(projectPath: projectPath,
                                                     orchestratorHome: orchestratorHome,
                                                     language: language, title: title,
                                                     originalRequest: originalRequest) else { return nil }
        let relay = await workerSend(projectPath: projectPath, sessionID: sessionID,
                                     branch: branch, runID: runID,
                                     message: request.relayMessage, messageID: request.id,
                                     intent: .conversation)
        guard relay.tier == .live || relay.tier == .resumed || relay.tier == .queued else { return nil }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if let page = completedChatReport(request) {

                try? FileManager.default.removeItem(at: request.directory)
                return page
            }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .seconds(1))
        } while ContinuousClock.now < deadline
        return nil
    }

    func prepareChatReportRequest(projectPath: String, orchestratorHome: String,
                                  language: String, title: String,
                                  originalRequest: String, id: UUID = UUID()) -> ChatReportRequest? {
        let project = URL(fileURLWithPath: projectPath).standardizedFileURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: project.path) else { return nil }
        let artifactsRoot = project.appendingPathComponent("artifacts", isDirectory: true)
        let directory = artifactsRoot
            .appendingPathComponent(".requests", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        let instructionFile = directory.appendingPathComponent("REPORT-REQUEST.md")
        let artifactPointer = directory.appendingPathComponent("artifact-path")
        let template = URL(fileURLWithPath: orchestratorHome)
            .appendingPathComponent("supervisor/REPORT-DIRECTIVE.md")
        guard let shared = try? String(contentsOf: template, encoding: .utf8),
              shared.contains("{{DIR}}") else { return nil }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRequest = originalRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitCommand = "$IDIR/artifact \"\(directory.path)\" \"\(project.path)\""
        let directive = shared
            .replacingOccurrences(of: "{{DIR}}", with: directory.path)
            .replacingOccurrences(of: "{{LANG}}", with: language)
            .replacingOccurrences(of: "{{CONTINUING}}", with: "")
        let instructions = """
        # ОКРЕМИЙ ХІД: ЛИШЕ ЗВІТ

        Це не нова задача, не продовження розробки й не аудит усього продукту. Код, гілку, коміти та
        робочі файли НЕ змінюй. Зроби зрозумілий команді звіт лише про вже виконану роботу в поточному
        діалозі: простими словами, що зроблено, як це працює і як перевірено.

        Ти залишаєшся в тій самій Claude-сесії, тому використовуй її повний контекст і свій фінальний
        підсумок. Насамперед знайди й повторно використай реальні кадри/відео, які вже були зроблені для
        цієї роботи у `\(artifactsRoot.path)`; скопіюй потрібні файли до теки маніфесту й прив'яжи їх до
        конкретних пунктів. Не замінюй наявні кадри фразою про те, що схему збірки не знайдено.

        Назва діалогу: \(cleanTitle.isEmpty ? "Звіт про результат" : cleanTitle)

        Початковий запит користувача (це межі звіту, а не привід перевіряти весь продукт):
        <director-request>
        \(cleanRequest)
        </director-request>

        \(directive)

        ВАЖЛИВО ДЛЯ ЦЬОГО DIRECT CHAT: останню команду без аргументів із контракту не використовуй,
        бо тут немає dispatch-запису. Коли маніфест і кадри повністю готові, виклич рівно:

            \(explicitCommand)

        Не завершуй відповідь, доки команда не надрукує шлях до готового `index.html`.
        """
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try instructions.write(to: instructionFile, atomically: true, encoding: .utf8)
        } catch {
            try? fileManager.removeItem(at: directory)
            return nil
        }

        let relayMessage = """
        Згенеруй тепер лише звіт про вже виконану роботу. Не змінюй продукт і не запускай новий аудит.
        Повний обов'язковий контракт лежить у файлі:
        \(instructionFile.path)
        Прочитай його повністю, виконай і поверни шлях до готового index.html.
        """
        return ChatReportRequest(id: id, directory: directory, instructionFile: instructionFile,
                                 artifactPointer: artifactPointer, artifactsRoot: artifactsRoot,
                                 relayMessage: relayMessage)
    }

    func completedChatReport(_ request: ChatReportRequest) -> String? {
        guard let raw = try? String(contentsOf: request.artifactPointer, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let page = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root = request.artifactsRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard page.path.hasPrefix(root.path + "/"), page.lastPathComponent == "index.html",
              FileManager.default.fileExists(atPath: page.path),
              ((try? page.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else { return nil }
        return page.path
    }
}
