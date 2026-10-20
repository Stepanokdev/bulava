import Foundation

// A layout-only double of `LiveBox` — the real one is in
// bulava-mobile/iosApp/Shared/LiveNames.swift, but it extends an ActivityKit type that does not
// build off a device, so this mirrors only the fields the Lock Screen layout reads. Keep in step
// with LiveNames.swift if those fields change (the layout and this double change together).
struct LiveBox: Codable, Hashable {
    struct Line: Codable, Hashable {
        var title: String
        var product: String
        var sinceMs: Int64?
        var outcome: String?
        var since: Date? { sinceMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } }
    }
    var running: [Line]
    var count: Int
    var ended: [Line]
    var over: Bool
    var productID: String?
    var chatID: String?
    var link: URL? { nil }
}
