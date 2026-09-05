import Foundation
import Observation
import Sparkle

/// Wraps Sparkle so the rest of the app can ask "is there an update?" without
/// knowing anything about appcasts.
///
/// Sparkle is deliberately left in charge of the dangerous part — verifying the
/// EdDSA signature, unpacking, swapping the bundle and relaunching. Nothing here
/// downloads or installs anything itself.
@MainActor
@Observable
final class UpdateController: NSObject {
    /// Set once Sparkle has found a version newer than this one.
    private(set) var availableVersion: String?

    /// This build, for the settings panel.
    let currentVersion: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // startingUpdater: true begins the scheduled check loop immediately.
        // The standard user driver supplies Sparkle's own confirmation UI, which
        // is the flow macOS users already recognise and trust.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        // Never install without asking: an update must not restart the app
        // while it is mid-task.
        controller.updater.automaticallyDownloadsUpdates = false
    }

    /// Opens Sparkle's update dialog. Safe to call at any time.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            availableVersion = item.displayVersionString
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            availableVersion = nil
        }
    }
}
