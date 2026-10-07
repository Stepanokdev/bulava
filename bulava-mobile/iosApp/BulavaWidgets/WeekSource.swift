import Foundation

/// Where the iPhone's week widgets find the week: what the app kept in the Keychain group it shares
/// with this extension (`WeekKey`), as the Mac sent it. The widget only reads.
enum WeekSource {
    static let place: WeekPlace = .phone
    static func read() -> WeekSnapshot? { WeekKey.read().flatMap(WeekSnapshot.decode) }
}
