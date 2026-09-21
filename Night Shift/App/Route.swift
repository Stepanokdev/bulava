import Foundation

enum Route: Hashable {

    case product(UUID)

    case products

    /// Which skills this machine carries, and which of them each product actually uses. A screen
    /// rather than a summoned window: a skill decided for one product is a fact about that
    /// product, and a window that has to be summoned is not where anyone looks.
    case skills

    case preflight
}

extension Route {
    var productID: UUID? {
        if case .product(let id) = self { return id }
        return nil
    }
}
