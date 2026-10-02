import AppKit
import Sparkle

/// Over-the-air updates via Sparkle.
///
/// Openflow checks the appcast daily. When a newer version exists it does not pop a window: the menu bar
/// shows "Update to x.y.z…" (and a badge on the icon) and the dashboard shows a banner. Clicking either opens
/// Sparkle's update window (release notes, Install & Relaunch). Updates must carry an EdDSA signature that
/// matches `SUPublicEDKey`, and be code-signed like the installed app, or Sparkle refuses them.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Version string of an update that is ready to install, if any.
    @Published private(set) var availableVersion: String?
    @Published private(set) var isEnabled = false
    private var controller: SPUStandardUpdaterController?

    /// Builds made with OPENFLOW_UPDATE_TEST=1 (local end-to-end test only) check right after launch and
    /// install as soon as an update is downloaded. Release builds never carry this key.
    private let testMode = Bundle.main.object(forInfoDictionaryKey: "OpenflowUpdateTest") as? Bool ?? false

    override init() {
        super.init()
        // Only a real app bundle with a feed and a public key can update itself.
        guard Bundle.main.bundleURL.pathExtension == "app",
              !((Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? "").isEmpty,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        isEnabled = true
        if testMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.log("test mode: background check")
                self?.controller?.updater.checkForUpdatesInBackground()
            }
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Menu / banner action: Sparkle's update window (or "You're up to date").
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        Task { @MainActor in
            self.availableVersion = v
            self.log("update available: \(v)")
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.availableVersion = nil
            self.log("up to date (\(self.currentVersion))")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let msg = (error as NSError).localizedDescription
        Task { @MainActor in self.log("update check ended: \(msg)") }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        Task { @MainActor in
            self.availableVersion = nil
            self.log("installing \(v)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let test = Bundle.main.object(forInfoDictionaryKey: "OpenflowUpdateTest") as? Bool ?? false
        guard test else { return false }
        let v = item.displayVersionString
        Task { @MainActor in self.log("test mode: installing \(v) now and relaunching") }
        immediateInstallHandler()
        return true
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders for a menu bar app)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled checks never pop a window; Openflow shows its own "Update…" button instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                         andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let v = update.displayVersionString
        Task { @MainActor in self.availableVersion = v }
    }

    // MARK: Log (~/Library/Logs/Openflow/updates.log: versions and outcomes only)

    private func log(_ message: String) {
        let url = CaretLog.url.deletingLastPathComponent().appendingPathComponent("updates.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) v\(currentVersion) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
