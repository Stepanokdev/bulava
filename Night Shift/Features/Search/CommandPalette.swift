import SwiftUI

struct CommandPalette: View {
    @Environment(AppModel.self) private var model

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {

            Rectangle()
                .fill(Color.black.opacity(0.28))
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                field
                if !results.isEmpty {
                    Hairline()
                    resultList
                } else if !query.isEmpty {
                    Hairline()
                    Text("Nothing matches")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textFaint)
                        .padding(.vertical, 22)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 560)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                    .fill(Palette.panel)
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: Metrics.radiusModal,
                                                     style: .continuous))
            )

            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                    .strokeBorder(Palette.lineStrong, lineWidth: 1)
            )
            .modalShadow()
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 120)
        }
        .onAppear { focused = true }
        .transition(.opacity)
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Palette.textFaint)
            TextField("Product, chat or report…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onChange(of: query) { _, _ in selection = 0 }
                .onSubmit { activate() }
                .onKeyPress(.downArrow) {
                    selection = min(selection + 1, max(0, results.count - 1)); return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(selection - 1, 0); return .handled
                }
                .onKeyPress(.escape) { close(); return .handled }
            KeyHint(keys: "esc")
        }
        .padding(.horizontal, 15)
        .frame(height: 50)
    }

    // MARK: - Results

    private var resultList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    Button { activate(result) } label: {
                        HStack(spacing: 10) {
                            icon(for: result)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(Typo.panelRow)
                                    .foregroundStyle(Palette.text)
                                    .lineLimit(1)
                                Text(result.subtitle)
                                    .font(Typo.panelMeta)
                                    .foregroundStyle(Palette.textFaint)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(LocalizedStringKey(result.kind.labelKey))
                                .font(Typo.tag)
                                .foregroundStyle(Palette.textFaint)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.row(selected: index == selection, radius: 8))
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 340)
    }

    @ViewBuilder private func icon(for result: SearchResult) -> some View {
        switch result.kind {
        case .product:
            ProductMonogram(initials: result.initials, selected: false)
        case .chat, .task, .report, .decision, .automation:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.panelRaised)
                .frame(width: 21, height: 21)
                .overlay(
                    Image(systemName: result.kind.symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                )
        }
    }

    // MARK: - Searching

    private var results: [SearchResult] { model.search(query) }

    private func activate() {
        guard selection < results.count else { return }
        activate(results[selection])
    }

    private func activate(_ result: SearchResult) {
        close()
        if let id = result.automationID {
            model.navigate(to: .automation(id))
            return
        }
        if let path = result.reportPath {
            model.open(product: result.productID)
            model.openChatReport(path: path, title: result.title)
            return
        }
        if let chatID = result.chatID, let chat = model.conversations.chat(id: chatID) {
            if chat.archived { model.viewArchivedChat(chat) } else { model.openChat(chat) }
            return
        }
        model.open(product: result.productID)
        if let taskID = result.taskID, let task = model.backlog.task(id: taskID) {

            if result.kind == .report { model.openReport(task) }
        }
    }

    private func close() {
        query = ""
        model.searchPresented = false
    }
}

// MARK: - Result model

struct SearchResult: Identifiable {
    enum Kind {
        case product, chat, task, report, decision, automation

        var labelKey: String {
            switch self {
            case .product:  "Product"
            case .chat:     "Chat"
            case .task:     "Task"
            case .report:   "Report"
            case .decision: "Decision"
            case .automation: "Automation"
            }
        }

        var symbol: String {
            switch self {
            case .product:  "square.grid.2x2"
            case .chat:     "bubble.left.and.bubble.right"
            case .task:     "circle.dotted"
            case .report:   "doc.text"
            case .decision: "flag"
            case .automation: "clock.arrow.2.circlepath"
            }
        }
    }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var productID: UUID
    var taskID: UUID?
    var chatID: UUID? = nil
    var reportPath: String? = nil
    var initials: String = ""
    var automationID: UUID? = nil
}

extension AppModel {

    func search(_ raw: String) -> [SearchResult] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if query.isEmpty {
            return products.sorted.prefix(8).map { product in
                SearchResult(id: "p-\(product.id)", kind: .product,
                             title: product.name,
                             subtitle: product.summary.isEmpty
                                ? String(format: String(localized: "%lld resources"), product.resources.count)
                                : product.summary,
                             productID: product.id,
                             initials: product.initials)
            }
        }

        var out: [SearchResult] = []

        for product in products.sorted {
            if product.name.lowercased().contains(query)
                || product.summary.lowercased().contains(query)
                || product.brief.lowercased().contains(query) {
                out.append(SearchResult(id: "p-\(product.id)", kind: .product,
                                        title: product.name,
                                        subtitle: product.summary,
                                        productID: product.id,
                                        initials: product.initials))
            }

            // An automation by its name or what it does, and by what its runs said about
            // themselves — the run summaries, not the transcripts of a year of runs.
            for automation in automations.automations(for: product.id) {
                let said = automations.runs(for: automation.id).compactMap(\.summary).joined(separator: " ")
                guard (automation.name + " " + automation.brief + " " + said).lowercased().contains(query) else { continue }
                out.append(SearchResult(id: "a-\(automation.id)", kind: .automation, title: automation.name,
                                        subtitle: "\(product.name) · \(AutomationPresentation.triggerLine(automation.trigger))",
                                        productID: product.id, automationID: automation.id))
            }

            for chat in conversations.chats where chat.productID == product.id && !chat.isAutomationRun {
                let spoken = conversations.entries(inChat: chat.id).map(\.text).joined(separator: " ")
                let matches = (chat.title + " " + chat.firstMessage + " " + spoken)
                    .lowercased().contains(query)
                if matches {
                    let archived = chat.archived ? " · \(String(localized: "Archived"))" : ""
                    out.append(SearchResult(id: "c-\(chat.id)", kind: .chat,
                                            title: chat.title,
                                            subtitle: "\(product.name) · \(Fmt.dayLabel(chat.updatedAt))\(archived)",
                                            productID: product.id,
                                            taskID: nil,
                                            chatID: chat.id))
                }
                for path in chat.session?.reportPaths ?? [] where matches || path.lowercased().contains(query) {
                    out.append(SearchResult(id: "r-\(chat.id)-\(path)", kind: .report,
                                            title: chat.title,
                                            subtitle: "\(product.name) · \(String(localized: "Report"))",
                                            productID: product.id,
                                            taskID: nil,
                                            chatID: chat.id,
                                            reportPath: path))
                }
            }
        }

        return Array(out.sorted { a, b in
            if (a.kind == .product) != (b.kind == .product) { return a.kind == .product }
            return a.title.count < b.title.count
        }.prefix(20))
    }
}
