import Foundation
import Sparkle
import Observation

/// Keeping Bulava current, without interrupting it.
///
/// Sparkle's own default is to put an update window in front of whoever is at the keyboard the
/// moment it finds one. For this product that is the wrong moment by definition: a night run may
/// be mid-review, and the person may not even be here. So a found update becomes a quiet line in
/// the sidebar, and the window only opens when someone asks for it.
@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    /// The version waiting, once one is known. Nil the rest of the time — which is most of the
    /// time, and why there is no permanent "Update" button anywhere.
    var availableVersion: String?

    /// True while a check the user asked for is in flight, so the menu can say so.
    var checking = false

    private var controller: SPUStandardUpdaterController?

    /// Set by the app so the updater can tell whether interrupting would land on live work.
    var isWorkInFlight: () -> Bool = { false }

    var updater: SPUUpdater? { controller?.updater }

    func start() {
        guard controller == nil else { return }
        // startingUpdater: true — the schedule begins now; the first run asks permission itself.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    /// What the menu item and the sidebar line both call.
    func checkForUpdates() {
        checking = true
        controller?.updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.availableVersion = item.displayVersionString
            self.checking = false
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Task { @MainActor in
            self.availableVersion = nil
            self.checking = false
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Task { @MainActor in self.checking = false }
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Sparkle asks before showing an update it found on its own schedule. While a run is in
    /// flight the answer is no: the sidebar will carry it instead, and the person decides when.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        MainActor.assumeIsolated { !isWorkInFlight() }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in self.availableVersion = update.displayVersionString }
    }
}
