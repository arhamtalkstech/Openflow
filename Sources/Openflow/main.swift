import AppKit
import Combine
import OpenflowCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var state: AppState!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var onboardingWindow: NSWindow?
    private(set) var onboardingModel: OnboardingModel?
    private var section: DashboardSection = .home
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--caret-probe <seconds>`: headless diagnostic. Logs what Openflow reads for the caret in the
        // frontmost app to ~/Library/Logs/Openflow/caret.log once a second, then quits. No UI, no hotkey.
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        if let i = args.firstIndex(of: "--text-probe"), i + 1 < args.count {
            // Diagnostic: what the frontmost app reports around the cursor (escaped), for spacing bugs.
            let out = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                var lines: [String] = []
                if let el = SystemInserter.focusedElement() {
                    lines.append("role=\(CaretLocator.string(el, kAXRoleAttribute) ?? "-") range=\(SystemInserter.selectedRange(el).map { "\($0.location),\($0.length)" } ?? "-")")
                    lines.append("before40=\(String(reflecting: SystemInserter.textBeforeCursor(limit: 40)))")
                    var v: CFTypeRef?
                    if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let full = v as? String,
                       let r = SystemInserter.selectedRange(el) {
                        let ns = full as NSString
                        lines.append("valueLength=\(ns.length)")
                        let a = max(0, r.location - 40), b = min(ns.length, r.location + 20)
                        lines.append("around=\(String(reflecting: ns.substring(with: NSRange(location: a, length: r.location - a))))|CURSOR|\(String(reflecting: ns.substring(with: NSRange(location: r.location, length: max(0, b - r.location)))))")
                    }
                }
                try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        #if DEBUG
        if args.contains("--mic-test") {
            // Lists inputs, then records 1.5 s from each through AudioCapture and prints the peak level only.
            let devices = AudioDevices.inputs()
            for d in devices { print("input: \(d.name) uid=\(d.uid) id=\(d.id)\(d.isDefault ? " (default)" : "")") }
            var queue = devices
            func next() {
                guard !queue.isEmpty else { NSApp.terminate(nil); return }
                let d = queue.removeFirst()
                let cap = AudioCapture()
                cap.deviceID = d.id
                var peak: Int16 = 0, samples = 0
                cap.onSamples = { s in samples += s.count; peak = max(peak, s.map { $0 == Int16.min ? Int16.max : abs($0) }.max() ?? 0) }
                do { try cap.start() } catch { print("  \(d.name): start failed \(error)"); next(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MainActor.assumeIsolated {
                        cap.stop()
                        print("  \(d.name): active=\(cap.activeDeviceID.map(String.init) ?? "-") samples=\(samples) peak=\(peak)")
                        next()
                    }
                }
            }
            next()
            return
        }
        #endif
        if let i = args.firstIndex(of: "--docs-probe") {
            DocsProbe.run(seconds: Int(i + 1 < args.count ? args[i + 1] : "") ?? 300)
            return
        }
        if let i = args.firstIndex(of: "--caret-probe") {
            let secs = Int(i + 1 < args.count ? args[i + 1] : "") ?? 10
            let clicks = ClickTracker()
            clicks.start()
            NSLog("Openflow caret probe: trusted=%@ for %ds", AXIsProcessTrusted() ? "yes" : "no", secs)
            var left = secs
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                MainActor.assumeIsolated {
                    _ = CaretLocator.locate(clicks: clicks)
                    left -= 1
                    if left <= 0 { t.invalidate(); NSApp.terminate(nil) }
                }
            }
            return
        }
        state = AppState()
        state.startup()
        setUpStatusItem()

        NotificationCenter.default.publisher(for: .openDashboard).sink { [weak self] n in
            self?.openDashboard(n.object as? DashboardSection)
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .openOnboarding).sink { [weak self] _ in
            self?.openOnboarding()
        }.store(in: &cancellables)

        // Menu bar icon reflects recording state.
        state.engine.$phase.receive(on: RunLoop.main).sink { [weak self] p in self?.updateIcon(p) }.store(in: &cancellables)
        state.updates.$availableVersion.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.updateIcon(self.state.engine.phase)
        }.store(in: &cancellables)

        #if DEBUG  // developer tools: render UI to files, play the bubble demo
        if let i = args.firstIndex(of: "--snapshots"), i + 1 < args.count {
            Snapshots.run(state: state, delegate: self, dir: URL(fileURLWithPath: args[i + 1]))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-bubble") {
            state.overlay.runDemo { NSLog("Openflow demo: %@", $0) }
            return
        }
        #endif
        // First run: the setup assistant. Later, if something broke (e.g. a permission was revoked): Setup page.
        let ready = state.hasAPIKey && state.accessibilityTrusted && state.micStatus == .authorized
        if !state.settings.onboardingCompleted || ProcessInfo.processInfo.arguments.contains("--onboarding") {
            openOnboarding()
        } else if !ready || ProcessInfo.processInfo.arguments.contains("--open") {
            openDashboard(ready ? .home : .setup)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard(nil)
        return true
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(.idle)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateIcon(_ p: DictationEngine.Phase) {
        let name: String
        switch p {
        case .listening, .connecting: name = "waveform.circle.fill"
        case .thinking: name = "ellipsis.circle.fill"
        case .error: name = "exclamationmark.circle"
        default: name = state?.updates.availableVersion != nil ? "waveform.badge.exclamationmark" : "waveform"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Openflow")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = state.settings
        if let v = state.updates.availableVersion {
            let up = item("Update to Openflow \(v)…", #selector(checkUpdates))
            up.attributedTitle = NSAttributedString(string: up.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            up.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(up)
            menu.addItem(.separator())
        }
        let header = NSMenuItem(title: state.engine.isActive ? "Listening…" : "Hold \(s.hotkey.display) to dictate", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !state.hasAPIKey || !state.accessibilityTrusted || state.micStatus != .authorized {
            menu.addItem(item("Finish setup…", #selector(openOnboardingAction)))
        }
        menu.addItem(.separator())
        menu.addItem(item(state.engine.isActive ? "Stop dictation" : "Start hands-free dictation", #selector(toggleDictation)))
        if let issue = state.engine.issue {
            let fix = item(issue.actionTitle == "Retry" ? "Retry failed dictation" : "Paste last dictation again", #selector(resolveIssue))
            menu.addItem(fix)
        }
        let last = item("Paste last dictation", #selector(pasteLast))
        last.isEnabled = state.lastPasted != nil
        menu.addItem(last)
        menu.addItem(.separator())
        let cleanup = item("Clean up with Grok", #selector(toggleCleanup))
        cleanup.state = s.cleanupEnabled ? .on : .off
        menu.addItem(cleanup)
        let langMenu = NSMenu()
        for (code, name) in supportedLanguages {
            let li = NSMenuItem(title: name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            li.target = self
            li.representedObject = code
            li.state = s.language == code ? .on : .off
            langMenu.addItem(li)
        }
        let lang = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        lang.submenu = langMenu
        menu.addItem(lang)
        menu.addItem(microphoneMenuItem())
        let login = item("Open at login", #selector(toggleLogin))
        login.state = state.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let t = state.usage.totals
        let stats = NSMenuItem(title: "\(Fmt.int(t.words)) words · \(Fmt.duration(t.timeSavedSeconds)) saved · \(Fmt.usd(t.totalCostUSD))", action: nil, keyEquivalent: "")
        stats.isEnabled = false
        menu.addItem(stats)
        menu.addItem(item("Open Openflow…", #selector(openHome), key: ","))
        menu.addItem(item("Setup assistant…", #selector(openOnboardingAction)))
        if state.updates.isEnabled {
            menu.addItem(item("Check for Updates… (v\(state.updates.currentVersion))", #selector(checkUpdates)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Openflow", #selector(quit), key: "q"))
    }

    /// "Microphone ▸" with every input device; the chosen one is checked.
    private func microphoneMenuItem() -> NSMenuItem {
        let devices = AudioDevices.inputs()
        let chosen = state.settings.inputDeviceUID
        let sub = NSMenu()
        let defaultName = devices.first(where: \.isDefault)?.name
        let def = NSMenuItem(title: "System default" + (defaultName.map { " (\($0))" } ?? ""), action: #selector(pickInput(_:)), keyEquivalent: "")
        def.target = self
        def.representedObject = ""
        def.state = chosen.isEmpty ? .on : .off
        sub.addItem(def)
        sub.addItem(.separator())
        for d in devices {
            let i = NSMenuItem(title: AudioDevices.label(d), action: #selector(pickInput(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = d.uid
            i.state = d.uid == chosen ? .on : .off
            sub.addItem(i)
        }
        if state.selectedInputMissing {
            sub.addItem(.separator())
            let note = NSMenuItem(title: "Chosen microphone not connected, using the default", action: nil, keyEquivalent: "")
            note.isEnabled = false
            sub.addItem(note)
        }
        let current = chosen.isEmpty ? (defaultName ?? "Default") : (devices.first { $0.uid == chosen }?.name ?? "Default")
        let item = NSMenuItem(title: "Microphone: \(current)", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    @objc private func pickInput(_ sender: NSMenuItem) { state.selectInput(uid: sender.representedObject as? String ?? "") }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleDictation() { state.toggleHandsFree() }
    @objc private func pasteLast() { state.pasteLast() }
    @objc private func checkUpdates() { state.updates.checkForUpdates() }
    @objc private func resolveIssue() { state.engine.resolveIssue() }
    @objc private func toggleCleanup() { state.settings.cleanupEnabled.toggle() }
    @objc private func toggleLogin() { state.setLaunchAtLogin(!state.launchAtLogin) }
    @objc private func pickLanguage(_ sender: NSMenuItem) { state.settings.language = sender.representedObject as? String ?? "" }
    @objc private func openHome() { openDashboard(.home) }
    @objc private func openSetup() { openDashboard(.setup) }
    @objc private func openOnboardingAction() { openOnboarding() }

    // MARK: Setup assistant window

    func openOnboarding(at step: OnboardingModel.Step? = nil) {
        if onboardingWindow == nil {
            let model = OnboardingModel(state: state)
            model.onFinish = { [weak self] in self?.onboardingWindow?.close() }
            onboardingModel = model
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Set up Openflow"
            w.titlebarAppearsTransparent = true
            w.contentView = NSHostingView(rootView: OnboardingView(model: model))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            onboardingWindow = w
        }
        if let step { onboardingModel?.jump(to: step) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    var onboardingContentView: NSView? { onboardingWindow?.contentView }
    @objc private func quit() { state.usage.saveNow(); NSApp.terminate(nil) }

    // MARK: Dashboard window

    func openDashboard(_ s: DashboardSection?) {
        openDashboardWindow(s)
    }

    func openDashboardWindow(_ s: DashboardSection?) {
        if let s { section = s }
        if window == nil {
            let binding = Binding<DashboardSection>(get: { [weak self] in self?.section ?? .home },
                                                    set: { [weak self] in self?.section = $0; self?.refreshWindow() })
            let root = DashboardView(state: state, usage: state.usage, section: binding)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Openflow"
            w.contentView = NSHostingView(rootView: root)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("OpenflowDashboard")
            window = w
        } else {
            refreshWindow()
        }
        NSApp.setActivationPolicy(.regular)  // show in Dock + ⌘Tab while the window is open
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var dashboardWindow: NSWindow? { window }

    func refreshWindow() {
        guard let window else { return }
        let binding = Binding<DashboardSection>(get: { [weak self] in self?.section ?? .home },
                                                set: { [weak self] in self?.section = $0; self?.refreshWindow() })
        (window.contentView as? NSHostingView<DashboardView>)?.rootView = DashboardView(state: state, usage: state.usage, section: binding)
    }

    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow, w === onboardingWindow {
            onboardingModel?.close()
            onboardingModel = nil
            onboardingWindow = nil
        }
        // Back to menu-bar only once no Openflow window is open.
        let others = [window, onboardingWindow].compactMap { $0 }.filter { $0 !== notification.object as? NSWindow && $0.isVisible }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
