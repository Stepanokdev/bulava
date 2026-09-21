import SwiftUI
import Observation

@MainActor
@Observable
final class EventLog {

    private(set) var events: [AppEvent] = []
    private let file: JSONFile<[AppEvent]>

    private static let cap = 1000

    init(fileURL: URL = AppSupport.file("events.json")) {
        file = JSONFile(url: fileURL)
        events = file.load() ?? []
        if events.count > Self.cap { events.removeFirst(events.count - Self.cap); file.save(events) }
    }

    @discardableResult
    func record(_ event: AppEvent) -> AppEvent {
        events.append(event)
        if events.count > Self.cap { events.removeFirst(events.count - Self.cap) }
        file.save(events)
        return event
    }

    var reversed: [AppEvent] { events.reversed() }

    func recent(_ n: Int) -> [AppEvent] { Array(events.suffix(n).reversed()) }

    func clear() { events.removeAll(); file.save(events) }
}
