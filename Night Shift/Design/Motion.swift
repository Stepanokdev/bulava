import SwiftUI

nonisolated enum Motion {

    static let standard = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.25)

    static let hover    = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.15)

    static let snappy   = Animation.spring(response: 0.28, dampingFraction: 0.9)

    static let expand   = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.28)

    static let surface  = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.34)

    static let arrive   = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.26)

    static let breathe  = Animation.timingCurve(0.45, 0, 0.55, 1, duration: 1.0)
}

// MARK: - Reduce Motion

private struct MotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {

    var motionEnabled: Bool {
        get { self[MotionEnabledKey.self] }
        set { self[MotionEnabledKey.self] = newValue }
    }
}

extension View {

    func resolveMotionPreference() -> some View {
        modifier(ResolveMotion())
    }
}

private struct ResolveMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.environment(\.motionEnabled, !reduceMotion)
    }
}
