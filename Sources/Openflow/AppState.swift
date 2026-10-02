import AppKit
import AVFoundation
import Combine
import OpenflowCore
import ServiceManagement

/// Shared state for the menu bar, dashboard window, and dictation pipeline.
@MainActor
final class AppState: ObservableObject {
    @Published var settings: OpenflowSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            engine.settings = settings
            hotkeys.hotkey = settings.hotkey
            overlay.placement = settings.bubblePlacement
            overlay.model.showLiveText = settings.liveTranscript
            onSettingsChanged?()
        }
    }
    @Published private(set) var apiKeyMasked: String = ""
    @Published private(set) var hasAPIKey = false
    @Published private(set) var micStatus: AVAuthorizationStatus = AudioCapture.permission
    @Published private(set) var accessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published private(set) var hotkeyActive = false
    @Published private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchAtLoginNeedsApproval: Bool = SMAppService.mainApp.status == .requiresApproval
    @Published var recordingShortcut = false
    /// Setup assistant's shortcut test: presses are reported, dictation does not start.
    @Published var hotkeyTestMode = false
    @Published private(set) var lastHotkeyDetected: Date?
    /// Most recent paste (the setup assistant's practice step watches this).
    @Published private(set) var lastPasted: DictationRecord?

    let usage: UsageStore = {
        // `--usage-file <path>` points the app at another stats file (used for screenshots of test runs).
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--usage-file"), i + 1 < args.count {
            return UsageStore(fileURL: URL(fileURLWithPath: args[i + 1]))
        }
        #endif
        return UsageStore()
    }()
    let engine: DictationEngine
    let hotkeys = HotkeyMonitor()
    let overlay = OverlayController()
    let inserter = SystemInserter()
    let audio = AudioCapture()
    let clicks = ClickTracker()
    let updates = UpdateController()
    var onSettingsChanged: (() -> Void)?

    private var cachedKey: String?
    private var pressAt: TimeInterval = 0
    private var pressStartedSession = false
    private var ignoreNextRelease = false
    private var upgradeWork: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    /// A hold longer than this is push-to-talk; shorter is a tap (hands-free).
    private let holdThreshold: TimeInterval = 0.32

    init() {
        let s = OpenflowSettings.load()
        settings = s
        engine = DictationEngine(settings: s, apiKeyProvider: { nil })
        engine.apiKeyProvider = { [weak self] in self?.cachedKey }
        engine.inserter = inserter
        engine.usage = usage
        engine.onCaptureShouldStop = { [weak self] in self?.audio.stop() }
        engine.onPasted = { [weak self] rec in
            self?.lastPasted = rec
            self?.play("Pop", volume: 0.25)
        }
        engine.onSessionEnded = { [weak self] in self?.audio.stop() }
        audio.onSamples = { [weak self] samples in self?.engine.feed(samples) }
        overlay.placement = s.bubblePlacement
        overlay.model.showLiveText = s.liveTranscript
        overlay.bind(engine)
        overlay.onClose = { [weak self] in self?.engine.stop() }
        overlay.onAction = { [weak self] in self?.engine.resolveIssue() }
        overlay.onDismiss = { [weak self] in self?.engine.dismissIssue() }
        overlay.clicks = clicks
        inserter.onPasted = { [weak self] text in self?.clicks.notePaste(text) }
        inserter.inputCount = { [weak self] in self?.clicks.inputCount ?? 0 }
        hotkeys.hotkey = s.hotkey
        hotkeys.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeys.onOtherKeyWhileHeld = { [weak self] in self?.otherKeyWhileHeld() }
        hotkeys.onEscape = { [weak self] in
            guard let self else { return false }
            if self.engine.isActive { self.engine.cancel(); return true }
            if self.engine.issue != nil { self.engine.dismissIssue(); return true }
            return false
        }
        engine.$phase.sink { [weak self] p in
            if case .error = p { self?.play("Basso", volume: 0.2) }
        }.store(in: &cancellables)
        reloadKey()
    }

    func startup() {
        // Key migration may read the Keychain (one possible prompt): never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let changed = APIKeyStore.migrateIfNeeded()
            DispatchQueue.main.async { MainActor.assumeIsolated { if changed { self.reloadKey() } } }
        }
        refreshPermissions()
        installHotkeyIfPossible()
        // Accessibility can be granted at any time in System Settings; pick it up without a relaunch.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissions()
                self?.installHotkeyIfPossible()
            }
        }
    }

    // MARK: - Hotkey behaviour

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func hotkeyPressed() {
        if hotkeyTestMode {
            lastHotkeyDetected = Date()
            return
        }
        if engine.isActive {
            // Second press ends a hands-free session (or a toggle session).
            if settings.activation != .holdOnly {
                ignoreNextRelease = true
                engine.stop()
            }
            return
        }
        pressAt = now
        let mode: DictationEngine.Mode = settings.activation == .holdOnly ? .pushToTalk : .handsFree
        // A lone modifier might be the start of ⌃C etc.: start listening now (no clipped words),
        // but only show the bubble / play the sound if no other key follows within 200 ms.
        let deferUI = settings.hotkey.kind != .combo
        pressStartedSession = startDictation(mode: mode, deferUI: deferUI ? 0.2 : 0)
        if pressStartedSession && settings.activation == .holdOrTap {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.engine.setMode(.pushToTalk) }  // still held → push-to-talk
            }
            upgradeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
        }
    }

    private func hotkeyReleased() {
        if hotkeyTestMode { return }
        upgradeWork?.cancel()
        if ignoreNextRelease { ignoreNextRelease = false; return }
        guard pressStartedSession, engine.isActive else { return }
        pressStartedSession = false
        let heldFor = now - pressAt
        switch settings.activation {
        case .holdOnly:
            stopWithTail()
        case .holdOrTap:
            if heldFor >= holdThreshold { stopWithTail() }   // released after holding → paste
            // quick tap → stays in hands-free mode
        case .toggle:
            break
        }
    }

    private func otherKeyWhileHeld() {
        // e.g. ⌃C with a Control hotkey: that was a shortcut, not dictation.
        guard pressStartedSession, engine.isActive, now - pressAt < 1.5 else { return }
        upgradeWork?.cancel()
        pressStartedSession = false
        engine.cancel()
    }

    /// Keep the mic open a moment after release so the last syllable is not clipped.
    private func stopWithTail() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.engine.stop() }
    }

    // MARK: - Dictation

    @discardableResult
    func startDictation(mode: DictationEngine.Mode, deferUI: TimeInterval = 0) -> Bool {
        guard !engine.isActive else { return false }
        guard cachedKey != nil else {
            flashError("Add your SpaceXAI API key in Openflow")
            NotificationCenter.default.post(name: .openDashboard, object: DashboardSection.account)
            return false
        }
        switch AudioCapture.permission {
        case .notDetermined:
            AudioCapture.requestPermission { [weak self] _ in self?.refreshPermissions() }
            return false
        case .denied, .restricted:
            flashError("Allow microphone access for Openflow")
            NotificationCenter.default.post(name: .openDashboard, object: DashboardSection.setup)
            return false
        default: break
        }
        inserter.rememberTarget()
        // Chosen microphone if it's connected; otherwise the system default.
        audio.deviceID = AudioDevices.device(uid: settings.inputDeviceUID)?.id
        if deferUI > 0 { overlay.suppressBriefly(deferUI) }
        guard engine.start(mode: mode) else { return false }
        do {
            try audio.start()
        } catch {
            engine.cancel()
            flashError("Microphone unavailable")
            return false
        }
        if deferUI > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + deferUI) { [weak self] in
                guard let self, self.engine.isActive else { return }
                self.play("Tink", volume: 0.18)
            }
        } else {
            play("Tink", volume: 0.18)
        }
        return true
    }

    func toggleHandsFree() {
        if engine.isActive { engine.stop() } else { startDictation(mode: .handsFree) }
    }

    func pasteLast() {
        guard let last = lastPasted?.text else { return }  // in memory only; gone when Openflow quits
        inserter.pasteRaw(last)
    }

    private func flashError(_ msg: String) {
        overlay.flash(error: msg)
    }

    private func play(_ name: String, volume: Float) {
        guard settings.playSounds, let s = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        s.volume = volume
        s.play()
    }

    // MARK: - Microphone

    /// The saved microphone isn't connected right now (dictation uses the system default meanwhile).
    var selectedInputMissing: Bool {
        !settings.inputDeviceUID.isEmpty && AudioDevices.device(uid: settings.inputDeviceUID) == nil
    }

    func selectInput(uid: String) {
        settings.inputDeviceUID = uid
    }

    // MARK: - API key

    func setAPIKey(_ key: String) {
        APIKeyStore.save(key)
        reloadKey()
    }

    func removeAPIKey() {
        APIKeyStore.delete()
        reloadKey()
    }

    func reloadKey() {
        cachedKey = APIKeyStore.load()
        apiKeyMasked = APIKeyStore.masked(cachedKey)
        hasAPIKey = cachedKey != nil
    }

    // MARK: - Permissions & login item

    func refreshPermissions() {
        micStatus = AudioCapture.permission
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        let st = SMAppService.mainApp.status
        launchAtLogin = st == .enabled
        launchAtLoginNeedsApproval = st == .requiresApproval
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openPrivacyPane("Privacy_Accessibility")
    }

    func requestMicrophone() {
        if AudioCapture.permission == .notDetermined {
            AudioCapture.requestPermission { [weak self] _ in self?.refreshPermissions() }
        } else {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func installHotkeyIfPossible() {
        guard !hotkeys.isInstalled, AXIsProcessTrusted() else {
            hotkeyActive = hotkeys.isInstalled
            return
        }
        hotkeyActive = hotkeys.install()
        if hotkeyActive {
            clicks.start()
            if let front = NSWorkspace.shared.frontmostApplication { SystemInserter.prepareAccessibility(for: front) }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                              object: nil, queue: .main) { n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { SystemInserter.prepareAccessibility(for: app) }
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Openflow: login item change failed: \(error)")
        }
        refreshPermissions()
        if launchAtLoginNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func beginShortcutRecording() {
        guard hotkeys.isInstalled else { return }
        recordingShortcut = true
        hotkeys.beginRecording { [weak self] hk in
            guard let self else { return }
            self.recordingShortcut = false
            if let hk { self.settings.hotkey = hk }
        }
    }

    func cancelShortcutRecording() {
        hotkeys.cancelRecording()
        recordingShortcut = false
    }
}

extension Notification.Name {
    static let openDashboard = Notification.Name("openflow.openDashboard")
    static let openOnboarding = Notification.Name("openflow.openOnboarding")
}
