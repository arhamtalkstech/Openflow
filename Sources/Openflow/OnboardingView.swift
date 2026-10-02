import AppKit
import AVFoundation
import Combine
import OpenflowCore
import SwiftUI

/// Step-by-step setup assistant. Every step verifies itself on this Mac before moving on:
/// key → real STT + Grok calls, mic → live level, Accessibility → granted, shortcut → detected,
/// practice → a real dictation pasted into the practice box.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, apiKey, microphone, accessibility, shortcut, practice, personalize, done
        var title: String {
            switch self {
            case .welcome: return "Welcome to Openflow"
            case .apiKey: return "Connect your SpaceXAI API key"
            case .microphone: return "Let Openflow hear you"
            case .accessibility: return "Let Openflow type for you"
            case .shortcut: return "Pick your shortcut"
            case .practice: return "Try it"
            case .personalize: return "Tell Openflow about you"
            case .done: return "You're all set"
            }
        }
    }

    @Published var step: Step = .welcome
    // API key
    @Published var keyInput = ""
    @Published var checkingKey = false
    @Published var keyReport: KeyCheckReport?
    // Microphone
    @Published var micLevel: Float = 0
    @Published var heardVoice = false
    // Practice
    @Published var practiceText = ""
    @Published var practiceResult: DictationRecord?

    let state: AppState
    var onFinish: (() -> Void)?
    private let meter = AudioCapture()
    private var vad = VoiceActivityDetector()
    private var voicedRun = 0
    private var poll: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(state: AppState) {
        self.state = state
        state.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if state.hasAPIKey { checkExistingKey() }
    }

    func close() {
        poll?.invalidate()
        meter.stop()
        state.hotkeyTestMode = false
    }

    private func tick() {
        state.refreshPermissions()
        state.installHotkeyIfPossible()
    }

    // MARK: navigation

    var canContinue: Bool {
        switch step {
        case .apiKey: return keyReport?.allOK == true
        case .microphone: return state.micStatus == .authorized
        case .accessibility: return state.accessibilityTrusted && state.hotkeyActive
        default: return true
        }
    }

    func next() {
        guard let n = Step(rawValue: step.rawValue + 1) else { finish(); return }
        go(n)
    }

    func jump(to s: Step) { go(s) }

    func back() {
        if let p = Step(rawValue: step.rawValue - 1) { go(p) }
    }

    private func go(_ s: Step) {
        leave(step)
        step = s
        enter(s)
    }

    private func enter(_ s: Step) {
        switch s {
        case .microphone: startMeterIfAllowed()
        case .shortcut: state.hotkeyTestMode = true
        case .practice:
            practiceResult = nil
            let since = state.lastPasted?.id
            state.$lastPasted.dropFirst().sink { [weak self] rec in
                guard let self, self.step == .practice, let rec, rec.id != since else { return }
                self.practiceResult = rec
            }.store(in: &cancellables)
        default: break
        }
    }

    private func leave(_ s: Step) {
        switch s {
        case .microphone: meter.stop()
        case .shortcut: state.hotkeyTestMode = false
        default: break
        }
    }

    func finish() {
        leave(step)
        state.settings.onboardingCompleted = true
        onFinish?()
    }

    // MARK: API key

    func checkKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        runCheck(key: key, saveOnSuccess: true)
    }

    private func checkExistingKey() {
        guard let key = APIKeyStore.load() else { return }
        runCheck(key: key, saveOnSuccess: false)
    }

    private func runCheck(key: String, saveOnSuccess: Bool) {
        checkingKey = true
        keyReport = nil
        Task { @MainActor in
            let r = await KeyCheck.run(apiKey: key, sttModel: state.settings.sttModel,
                                       formatterModel: state.settings.formatterModel)
            checkingKey = false
            keyReport = r
            if r.allOK && saveOnSuccess {
                state.setAPIKey(key)
                keyInput = ""
            }
        }
    }

    // MARK: Microphone

    func requestMic() {
        if state.micStatus == .notDetermined {
            AudioCapture.requestPermission { [weak self] _ in
                self?.state.refreshPermissions()
                self?.startMeterIfAllowed()
            }
        } else {
            state.openPrivacyPane("Privacy_Microphone")
        }
    }

    func restartMeter() {
        meter.stop()
        heardVoice = false
        micLevel = 0
        startMeterIfAllowed()
    }

    private func startMeterIfAllowed() {
        guard AudioCapture.permission == .authorized, !meter.isRunning else { return }
        meter.deviceID = AudioDevices.device(uid: state.settings.inputDeviceUID)?.id
        vad = VoiceActivityDetector()
        meter.onSamples = { [weak self] samples in
            guard let self else { return }
            let r = self.vad.process(samples, now: ProcessInfo.processInfo.systemUptime)
            self.micLevel = self.micLevel * 0.6 + r.level * 0.4
            self.voicedRun = r.voiced ? self.voicedRun + samples.count : 0
            if self.voicedRun > 16_000 / 3 { self.heardVoice = true }  // ~0.33 s of speech
        }
        try? meter.start()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    private var state: AppState { model.state }

    var body: some View {
        VStack(spacing: 0) {
            // Progress
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= model.step.rawValue ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 32).padding(.top, 22)

            VStack(alignment: .leading, spacing: 16) {
                Text(model.step.title).font(.system(size: 26, weight: .bold))
                content
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            HStack {
                if model.step != .welcome && model.step != .done {
                    Button("Back") { model.back() }
                }
                Spacer()
                Text("Step \(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if [.shortcut, .practice, .personalize].contains(model.step) {
                    Button("Skip") { model.next() }
                }
                Button(primaryLabel) { model.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canContinue)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 680, height: 600)
    }

    private func setting<T>(_ kp: WritableKeyPath<OpenflowSettings, T>) -> Binding<T> {
        let state = model.state
        return Binding(get: { state.settings[keyPath: kp] }, set: { state.settings[keyPath: kp] = $0 })
    }

    private var primaryLabel: String {
        switch model.step {
        case .welcome: return "Get started"
        case .done: return "Start using Openflow"
        default: return "Continue"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .apiKey: apiKey
        case .microphone: microphone
        case .accessibility: accessibility
        case .shortcut: shortcut
        case .practice: practice
        case .personalize: personalize
        case .done: done
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
                Text("Speak anywhere on your Mac and Openflow types clean, formatted text where your cursor is. Powered by Grok Voice Transcribe 2.0 and Grok 4.3.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            Bullet(icon: "keyboard", text: "Hold your shortcut and talk. Let go and the text appears.")
            Bullet(icon: "wand.and.stars", text: "Filler words disappear, “no wait, Tuesday” gets applied, lists get formatted.")
            Bullet(icon: "globe", text: "Any language, even mixed mid-sentence.")
            Bullet(icon: "text.cursor", text: "Select text and say “make this shorter” to edit it by voice.")
            Text("Setup takes about two minutes. You'll need an SpaceXAI API key from console.x.ai.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var apiKey: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Openflow sends your audio and text straight to the SpaceXAI API with your own key. The key is stored in your Mac's Keychain.")
                .foregroundStyle(.secondary)
            if state.hasAPIKey {
                Label("Saved key \(state.apiKeyMasked)", systemImage: "key.fill").font(.callout)
            }
            HStack {
                SecureField(state.hasAPIKey ? "Paste a different key (optional)" : "Paste your key: xai-…", text: $model.keyInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.checkKey() }
                Button(model.checkingKey ? "Checking…" : "Check & save") { model.checkKey() }
                    .disabled(model.keyInput.trimmingCharacters(in: .whitespaces).isEmpty || model.checkingKey)
            }
            Link("Get a key at console.x.ai →", destination: URL(string: "https://console.x.ai/team/default/api-keys")!)
                .font(.callout)
            if model.checkingKey {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Testing speech-to-text and Grok with this key…").foregroundStyle(.secondary) }
            }
            if let r = model.keyReport {
                VStack(alignment: .leading, spacing: 8) {
                    CheckRow(label: "API key", status: r.key)
                    CheckRow(label: "Speech to text (Grok Voice Transcribe 2.0)", status: r.speechToText)
                    CheckRow(label: "Text cleanup (Grok 4.3)", status: r.cleanup)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                if !r.allOK, case .ok = r.key {
                    Text("This key works but can't reach every model Openflow needs. Ask your admin to allow grok-voice-transcribe-2.0 and grok-4.3 for it, or use another key.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Openflow only listens while you hold or tap your shortcut. The bubble on screen tells you when it's listening.")
                .foregroundStyle(.secondary)
            switch state.micStatus {
            case .authorized:
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.heardVoice ? "We hear you." : "Say something. The bar should move.")
                        .font(.headline)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(8, g.size.width * CGFloat(min(1, model.micLevel * 1.2))))
                                .animation(.easeOut(duration: 0.08), value: model.micLevel)
                        }
                    }
                    .frame(height: 12)
                    Label(model.heardVoice ? "Microphone works" : "Microphone access granted",
                          systemImage: model.heardVoice ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(.green)
                    MicrophonePicker(state: state)
                        .onChange(of: state.settings.inputDeviceUID) { _, _ in model.restartMeter() }
                    if !model.heardVoice {
                        Text("Bar not moving? Pick the microphone you use above.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .denied, .restricted:
                Text("Microphone access is off for Openflow.").foregroundStyle(.orange)
                Button("Open Microphone settings") { model.requestMic() }.buttonStyle(.borderedProminent)
                Text("Switch on Openflow in the list, then come back here.").font(.callout).foregroundStyle(.secondary)
            default:
                Button("Allow microphone") { model.requestMic() }.buttonStyle(.borderedProminent).controlSize(.large)
                Text("macOS will ask: “Openflow” would like to access the microphone. Click Allow.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("To use a shortcut from any app, see where your cursor is, and paste text for you, Openflow needs Accessibility access. It never reads password fields.")
                .foregroundStyle(.secondary)
            if state.accessibilityTrusted && state.hotkeyActive {
                Label("Accessibility is on. Your shortcut works in every app.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    NumberedLine(n: 1, text: "Click **Open System Settings**.")
                    NumberedLine(n: 2, text: "In Privacy & Security → Accessibility, switch on **Openflow**.")
                    NumberedLine(n: 3, text: "Come back. This page continues on its own.")
                }
                HStack {
                    Button("Open System Settings") { state.requestAccessibility() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Show Openflow in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Accessibility access…").foregroundStyle(.secondary)
                }
                Text("Not in the list? Click + and pick Openflow from Applications, or drag it in from Finder. Already on but still waiting? Remove it with −, add it again, then quit and reopen Openflow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(state.recordingShortcut ? "Press your shortcut…" : state.settings.hotkey.display)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
                if state.recordingShortcut {
                    Button("Cancel") { state.cancelShortcutRecording() }
                } else {
                    Button("Record a different shortcut") { state.beginShortcutRecording() }
                }
            }
            HStack {
                ForEach(Hotkey.presets, id: \.display) { p in
                    if state.settings.hotkey == p {
                        Button(p.display) {}.buttonStyle(.borderedProminent)
                    } else {
                        Button(p.display) { state.settings.hotkey = p }.buttonStyle(.bordered)
                    }
                }
            }
            Picker("How it works", selection: setting(\.activation)) {
                ForEach(ActivationStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Divider()
            if let t = state.lastHotkeyDetected, Date().timeIntervalSince(t) < 30 {
                Label("Got it: \(state.settings.hotkey.display) works.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
            } else {
                Label("Press \(state.settings.hotkey.display) now to test it.", systemImage: "hand.tap")
                    .font(.headline)
            }
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Click in the box, then **hold \(state.settings.hotkey.display)** and say:")
            Text("“Hey team, the launch moves to Monday, no wait, Tuesday. Three things: first, update the docs, second, ping sales, third, ship it.”")
                .italic().foregroundStyle(.secondary)
            Text("Let go when you're done.").foregroundStyle(.secondary)
            TextEditor(text: $model.practiceText)
                .font(.body)
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.4)))
            if let r = model.practiceResult {
                Label("It works: pasted \(r.words) words \(r.latencyMs) ms after you stopped talking.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
            } else {
                Text("Tip: tap the shortcut instead of holding it for hands-free mode. It pastes every time you pause.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var personalize: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional. Your name, role, team, and the names and products you often mention. Grok uses this to spell things right. It's never typed into your text.")
                .foregroundStyle(.secondary)
            TextEditor(text: setting(\.aboutMe))
                .frame(height: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            Picker("I mostly speak", selection: setting(\.language)) {
                ForEach(supportedLanguages, id: \.code) { Text($0.name).tag($0.code) }
            }
            .frame(maxWidth: 360)
            Text("You can change all of this later in Openflow → Personalize.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Bullet(icon: "keyboard", text: "**Hold \(state.settings.hotkey.display)** to talk, let go to paste.")
            Bullet(icon: "hand.tap", text: "**Tap** it for hands-free. Tap again or click ✕ on the bubble to stop.")
            Bullet(icon: "escape", text: "**Esc** throws away what hasn't been pasted yet.")
            Bullet(icon: "text.cursor", text: "**Select text** first to edit it by voice.")
            Bullet(icon: "menubar.arrow.up.rectangle", text: "Openflow lives in the menu bar (the waveform icon).")
            Toggle("Open Openflow when I log in", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                .padding(.top, 6)
        }
    }
}

private struct Bullet: View {
    var icon: String
    var text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(Color.accentColor)
            Text(text)
        }
    }
}

private struct NumberedLine: View {
    var n: Int
    var text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            Text(text)
        }
    }
}

private struct CheckRow: View {
    var label: String
    var status: KeyCheckReport.Status
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch status {
            case .ok(let m):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading) { Text(label); Text(m).font(.caption).foregroundStyle(.secondary) }
            case .failed(let m):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                VStack(alignment: .leading) { Text(label); Text(m).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
