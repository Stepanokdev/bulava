import CryptoKit
import Foundation

/// The product's context and the machine's skills, for the phone — the Mac's inspector pane and
/// Skills screen, read through the same `AppModel` calls those use.
extension MobileLink {

    func context(productID: UUID, chatID: UUID?, session: LinkSession, model: AppModel) async -> Outcome {
        guard let product = model.products.product(id: productID) else {
            return .failure(LinkError(code: LinkErrorCode.notFound, message: "product"))
        }
        // A chat of another product is not this product's chat: its panel would be someone else's.
        let chat = chatID.flatMap { model.conversations.chat(id: $0) }.flatMap { $0.productID == productID ? $0 : nil }
        let primaryID = chat.flatMap { model.chatPrimary(for: product, chatID: $0.id)?.id } ?? product.defaultProjectID

        var resources: [ResourceDTO] = []
        for item in model.resources(for: product) {
            let resource = item.resource
            var buttons: [ActionDTO] = []
            if item.project != nil {
                // The same switch as the lock in the Mac's inspector.
                let next: ResourceAccess = resource.access == .workspace ? .source : .workspace
                let id = "access:\(resource.id.uuidString):\(next.rawValue)"
                let resourceID = resource.id
                session.extraActions[id] = { [weak model] _ in
                    guard let model, model.products.product(id: productID)?.resources.contains(where: { $0.id == resourceID }) == true else {
                        return LinkProjection.staleError
                    }
                    model.products.setAccess(next, resourceID: resourceID, productID: productID)
                    return nil
                }
                buttons.append(ActionDTO(id: id,
                                         label: next == .source ? String(localized: "Ask before editing") : String(localized: "Can edit"),
                                         style: "secondary", kind: "invoke"))
            }
            resources.append(ResourceDTO(
                id: resource.id.uuidString, name: resource.name, kind: resource.kind.rawValue,
                kindLabel: LinkProjection.localized(resource.kind.labelKey), access: resource.access.rawValue,
                accessLabel: resource.access == .workspace ? String(localized: "Can edit") : String(localized: "Ask before editing"),
                path: item.project?.path, url: resource.urlString,
                branch: model.branch(forProjectID: item.project?.id),
                primary: item.project?.id != nil && item.project?.id == primaryID,
                live: item.isLive, actions: buttons))
        }

        let snapshot = await model.chatInspectorSnapshot(productID: productID, chatID: chat?.id)
        var changes: [ChangeDTO] = []
        for inspection in snapshot.projects {
            for change in inspection.changes {
                // The same file is the same ref: a phone that re-reads the panel every few seconds
                // replaces its entries instead of piling up new ones for the whole session.
                let ref = Self.diffRef(project: inspection.project.path, file: change.path)
                session.diffTargets[ref] = (inspection.project.path, change.path)
                changes.append(ChangeDTO(ref: ref, project: inspection.project.name, path: change.path,
                                         kindLabel: LinkProjection.localized(change.kind.labelKey),
                                         added: change.added, removed: change.removed))
            }
        }
        let checks = snapshot.evidence.map { evidence in
            ChecksDTO(status: evidence.overallStatus.rawValue,
                      items: evidence.criteria.map { CheckDTO(criterion: $0.criterion, status: $0.status.rawValue, note: $0.note) })
        }
        let instructions: InstructionsDTO? = product.summary.isEmpty && product.brief.isEmpty
            ? nil : InstructionsDTO(summary: product.summary, brief: product.brief)

        let nowAndNext = session.cards(model.nowAndNext(for: productID), model: model)

        var work: [WorkDTO] = []
        let items = model.workItems.items(forProductID: productID).sorted { $0.createdAt > $1.createdAt }.prefix(20)
        for item in items {
            let parts = session.cards(model.streamTasks(of: item), model: model)
            var report: ActionDTO?
            if item.isMultiStream, !model.streamTasks(of: item).isEmpty {
                let target = "item:\(item.id.uuidString)"
                session.addReport(target, LinkProjection.ReportTarget(task: nil, chatReportPath: nil,
                                                                      title: item.title, workItemID: item.id))
                report = ActionDTO(id: target, label: String(localized: "Open the report"), style: "primary",
                                   kind: "report", target: target)
            }
            work.append(WorkDTO(id: item.id.uuidString, title: item.title, kind: item.kind.rawValue,
                                status: LinkProjection.status(model.state(of: item)), parts: parts,
                                missing: item.missingVariants, report: report))
        }

        var productReport: ActionDTO?
        if model.hasFinishedWork(productID) {
            let target = "product:\(productID.uuidString)"
            session.addReport(target, LinkProjection.ReportTarget(task: nil, chatReportPath: nil,
                                                                  title: product.name, productID: productID))
            productReport = ActionDTO(id: target, label: String(localized: "Everything done so far"),
                                      style: "secondary", kind: "report", target: target)
        }

        return .success(ContextDTO(productID: productID.uuidString, resources: resources, changes: changes,
                                   checks: checks, instructions: instructions, nowAndNext: nowAndNext,
                                   work: work, report: productReport,
                                   chatReports: chat.flatMap { chatReports($0, productID: productID, session: session, model: model) }))
    }

    nonisolated static func diffRef(project: String, file: String) -> String {
        let digest = SHA256.hash(data: Data((project + "\n" + file).utf8))
        return "diff:" + digest.prefix(9).map { String(format: "%02x", $0) }.joined()
    }

    /// The Mac panel's Reports: "Create report", then every report of the chat, newest first. Shown,
    /// as there, once the chat has a session to make one in.
    private func chatReports(_ chat: Chat, productID: UUID, session: LinkSession, model: AppModel) -> ChatReportsDTO? {
        guard chat.session?.claudeSessionID != nil else { return nil }
        let paths = chat.session?.reportPaths ?? []
        let chatID = chat.id
        var items: [ChatReportDTO] = []
        for (index, path) in paths.enumerated().reversed() {
            let target = "chatReport:\(chatID.uuidString):\(index)"
            session.addReport(target, LinkProjection.ReportTarget(task: nil, chatReportPath: path, title: chat.title))
            let detail = ([ReportName.date(path).map(Fmt.stamp)].compactMap { $0 } + [ReportName.title(path)])
                .joined(separator: " · ")
            items.append(ChatReportDTO(
                title: items.isEmpty ? String(localized: "Latest report") : String(localized: "Report"),
                detail: detail,
                open: ActionDTO(id: target, label: String(localized: "Open the report"), style: "secondary",
                                kind: "report", target: target)))
        }
        var create: ActionDTO?
        if !chat.archived {
            let id = "chatReport.make:\(chatID.uuidString)"
            session.extraActions[id] = { [weak model] _ in
                guard let model, let live = model.conversations.chat(id: chatID), live.productID == productID,
                      !live.archived else { return LinkProjection.staleError }
                // Pressed twice while it is being made: the one that is being made is the answer.
                guard !model.generatingChatReportIDs.contains(chatID) else { return nil }
                model.generateChatReport(chatID: chatID)
                return nil
            }
            create = ActionDTO(id: id, label: String(localized: "Create report"), style: "secondary", kind: "invoke")
        }
        return ChatReportsDTO(items: items, generating: model.generatingChatReportIDs.contains(chatID), create: create,
                              note: String(localized: "It will be saved in the project’s artifacts folder and ignored by Git."))
    }

    func diff(ref: String, session: LinkSession, model: AppModel) async -> Outcome {
        guard let (project, file) = session.diffTargets[ref] else { return .failure(LinkProjection.staleError) }
        let text = await model.chatInspectorDiff(projectPath: project, filePath: file)
        return .success(DiffDTO(text: String(text.prefix(200_000))))
    }

    func skills(productID: UUID?, full: Bool, session: LinkSession, model: AppModel) async -> Outcome {
        var inventory = await model.skillInventory(fast: !full)
        if let productID { inventory = inventory.belongingTo(projects: model.skillProjectPaths(productID)) }
        let servers = await model.mcpInventory(fast: !full)

        let skills = inventory.skills.map { skill -> SkillDTO in
            var buttons: [ActionDTO] = []
            let key = LinkIdentity.base64url(Data(skill.id.utf8)).prefix(40)
            if skill.canUpdate {
                let id = "skill.update:\(key)"
                session.extraActions[id] = { [weak model] _ in
                    guard let model else { return LinkProjection.staleError }
                    let r = await model.updateSkill(skill, productID: productID)
                    return r.ok ? nil : LinkError(code: LinkErrorCode.failed, message: r.message)
                }
                buttons.append(ActionDTO(id: id, label: String(localized: "Update"), style: "secondary", kind: "invoke"))
            }
            if skill.canRemove {
                let id = "skill.remove:\(key)"
                session.extraActions[id] = { [weak model] _ in
                    guard let model else { return LinkProjection.staleError }
                    let r = await model.removeSkill(skill, productID: productID)
                    return r.ok ? nil : LinkError(code: LinkErrorCode.failed, message: r.message)
                }
                buttons.append(ActionDTO(id: id, label: String(localized: "Delete"), style: "destructive", kind: "invoke",
                                         confirm: String(localized: "It is deleted from disk. Installing it again goes through the audit like any new skill.")))
            }
            return SkillDTO(id: skill.id, name: skill.name, scope: skill.scope.rawValue, description: skill.description,
                            uses: skill.uses, usesHere: skill.usesHere, lastUsed: skill.lastUsed, source: skill.source,
                            actions: buttons)
        }
        let serverRows = servers.servers.map { server -> ServerDTO in
            let scope: String
            switch server.scope {
            case .account: scope = "account"
            case .user: scope = "user"
            case .project(let path): scope = "project:" + (path as NSString).lastPathComponent
            case .unknown: scope = "unknown"
            }
            return ServerDTO(name: server.name, target: server.target, health: server.health.rawValue,
                             transport: server.transport, scope: scope, description: server.description,
                             uses: server.uses, lastUsed: server.lastUsed)
        }
        return .success(SkillsDTO(skills: skills, servers: serverRows, counted: inventory.counted,
                                  transcripts: inventory.transcriptsScanned))
    }
}
