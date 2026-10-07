import ActivityKit

/// The Live Activity, as both sides of it know it: the app starts, updates and ends it, and the
/// widget extension draws it.
///
/// Three counts — runs working by themselves, things waiting for the director, reports ready — and,
/// from a Mac that sends them, the work by name (`LiveBox`). When the app is closed all of it comes
/// through Bulava's push relay, so `ContentState`'s keys are part of the relay's contract
/// (`activityPayload` in `push-relay/relay.go`); the names travel there only sealed with this
/// phone's own key, and the attributes are empty on purpose: the relay starts an activity with
/// `"attributes": {}` and learns no name of any Mac or project.
struct ShiftAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var working: Int
        var waiting: Int
        var ready: Int
        /// From the Mac through the relay: the names, sealed with this phone's key. Absent from an
        /// older Mac, or for a phone that has not handed its key over yet.
        var sealed: String? = nil
        /// From the app itself, with the link open: the same story in the clear. It is handed to
        /// ActivityKit on this phone and goes nowhere else.
        var box: LiveBox? = nil
    }
}
