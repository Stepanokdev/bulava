import Foundation
import WidgetKit

/// The week's widgets: what the app keeps for them and when it asks them to redraw.
extension BulavaHost {
    /// The week for the Home Screen and Lock Screen widgets, kept where they read it. They are asked
    /// to redraw at once when what they show changes in kind — someone started or stopped working,
    /// statistics went on or off — and otherwise at most every ten minutes, which iOS can afford.
    func showWeek(json: String?) {
        // One at a time, on the main queue: the redraw bookkeeping below is not shared across threads.
        DispatchQueue.main.async { Self.keep(json) }
    }

    private static func keep(_ json: String?) {
        guard let json else {
            WeekKey.remove()
            WeekRedraw.shape = nil
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        let data = Data(json.utf8)
        guard WeekKey.write(data) else { return }
        let shape = weekShape(data)
        let due = WeekRedraw.at.map { Date().timeIntervalSince($0) > 600 } ?? true
        if due || shape != WeekRedraw.shape {
            WeekRedraw.at = Date()
            WeekRedraw.shape = shape
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// What decides an immediate redraw: whether statistics are off, and who is working or waiting.
    private static func weekShape(_ data: Data) -> String {
        guard let week = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let now = week["now"] as? [String: Any]
        let runs = (now?["runs"] as? [[String: Any]] ?? []).map { "\($0["name"] ?? "")|\($0["waiting"] ?? "")" }
        return "\(week["off"] ?? false)#\(week["week"] ?? "")#" + runs.joined(separator: ",")
    }
}

/// When the widgets were last asked to redraw, and what they showed then.
private enum WeekRedraw {
    nonisolated(unsafe) static var at: Date?
    nonisolated(unsafe) static var shape: String?
}
