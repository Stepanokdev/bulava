import Foundation

nonisolated struct ForemanRounds: Sendable {
    private var current: [UUID: Int] = [:]

    init() {}

    @discardableResult
    mutating func bump(_ productID: UUID) -> Int {
        let next = (current[productID] ?? 0) + 1
        current[productID] = next
        return next
    }

    func isCurrent(_ round: Int, _ productID: UUID) -> Bool { current[productID] == round }

    func current(_ productID: UUID) -> Int { current[productID] ?? 0 }
}
