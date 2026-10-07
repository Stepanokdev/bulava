import Foundation

enum Route: Hashable {

    case product(UUID)

    case products

    /// Which skills this machine carries, and which of them each product actually uses. A screen
    /// rather than a summoned window: a skill decided for one product is a fact about that
    /// product, and a window that has to be summoned is not where anyone looks.
    case skills

    /// Every automation, and what each of them has been doing.
    case automations

    case automation(UUID)

    /// The pipelines a message can go through: the built-in ones and his own.
    case pipelines

    /// One pipeline open for reading or editing.
    case pipeline(String)

    case preflight
}

extension Route {
    var productID: UUID? {
        if case .product(let id) = self { return id }
        return nil
    }
}
