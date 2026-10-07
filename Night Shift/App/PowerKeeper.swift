import Foundation
import Observation
import IOKit.pwr_mgt
import IOKit.ps

/// Keeps the Mac from going to sleep on its own while work goes on without the director.
///
/// A night shift is only as long as the Mac stays up. The engine survives a sleep — it resumes by
/// the clock when the Mac wakes — but nothing happens while it sleeps, and an idle Mac falls
/// asleep by itself. So while a run is working, reviewing, or waiting out a limit it will
/// get past by itself, Bulava holds the system's "no idle sleep" assertion, and lets it go the
/// moment everything is waiting for the director or finished: a question nobody answers overnight
/// must not keep a laptop awake until morning.
///
/// What it cannot do is hold the Mac awake through a closed lid, or on a battery that runs out.
/// `onBattery` is for saying so before the night starts.
@Observable @MainActor
final class PowerKeeper {
    @ObservationIgnored private var assertion = IOPMAssertionID(0)
    private(set) var holding = false

    /// Holds or releases the assertion. Repeating the same answer does nothing.
    func hold(_ want: Bool) {
        guard want != holding else { return }
        if want {
            let reason = String(localized: "Bulava is working") as CFString
            let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion)
            holding = result == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            assertion = IOPMAssertionID(0)
            holding = false
        }
    }

    /// Whether this run goes on by itself while the Mac is awake.
    nonisolated static func keepsAwake(_ instance: SupervisorInstance) -> Bool {
        guard instance.active, !instance.looksStuck else { return false }
        return keepsAwake(phase: instance.phase, waitingFor: instance.awaitingWait?.kind)
    }

    nonisolated static func keepsAwake(phase: WorkerPhase, waitingFor wait: AwaitingWait.Kind?) -> Bool {
        switch phase {
        case .starting, .working, .reviewing, .pausedForLimit, .offline:
            return true
        case .awaitingDecision:
            // A Codex window reopens by itself; the director's answer does not.
            return wait == .codexWindow
        case .done, .blocked, .stalled, .idle:
            return false
        }
    }

    /// Whether the Mac is running on its battery right now.
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMBatteryPowerKey
    }
}

extension AppModel {

    /// Whether some work will go on without the director if the Mac stays awake: a run working,
    /// reviewing or preparing, one paused on a limit or a Codex window it will resume after by
    /// itself, one waiting for the network, a Codex answer being written, or a queue with a
    /// project still to start. A run that looks stuck does not count — it would hold the Mac for
    /// nothing — and neither does one waiting for the director's answer.
    var workContinuesUnattended: Bool {
        if !codexTurns.isEmpty { return true }
        // A scheduled automation due within hours, on mains power: held now, while the Mac is still
        // awake to hold it. On a battery the run waits for the Mac to wake instead.
        if automationDueSoon && !PowerKeeper.onBattery { return true }
        if queue.runnerAlive && queue.pendingCount > 0 { return true }
        return instances.contains { PowerKeeper.keepsAwake($0) }
    }

    /// Brings the assertion in line with the work, and notes whether the Mac is on battery.
    func updatePower() {
        power.hold(settings.keepAwakeWhileWorking && workContinuesUnattended)
        let battery = PowerKeeper.onBattery
        if battery != runningOnBattery { runningOnBattery = battery }
    }
}
