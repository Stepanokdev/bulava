import SwiftUI
import WidgetKit

/// Where the Mac's widgets find the week: the file Bulava writes into the App Group both are
/// entitled to (`WeekStore`). The widget only reads.
enum WeekSource {
    static let place: WeekPlace = .mac
    static func read() -> WeekSnapshot? { WeekStore.read() }
}

@main
struct BulavaMacWidgets: WidgetBundle {
    var body: some Widget {
        AutonomyWidget()
        OutcomesWidget()
        ReceiptWidget()
        RhythmWidget()
        VolumeWidget()
        LimitsWidget()
        NowWidget()
        WeekAtAGlanceWidget()
    }
}
