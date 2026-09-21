import Foundation

nonisolated struct ForemanMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case director, foreman }
    var id: UUID
    var role: Role
    var text: String
    var createdAt: Date
    var grounded: Bool
    var link: AppLink?

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date(),
         grounded: Bool = true, link: AppLink? = nil) {
        self.id = id; self.role = role; self.text = text; self.createdAt = createdAt
        self.grounded = grounded; self.link = link
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        role = (try? c.decode(Role.self, forKey: .role)) ?? .foreman
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        grounded = (try? c.decode(Bool.self, forKey: .grounded)) ?? true
        link = (try? c.decodeIfPresent(AppLink.self, forKey: .link)) ?? nil
    }
}
