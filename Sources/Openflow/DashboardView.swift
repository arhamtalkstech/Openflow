import AppKit
import Charts
import OpenflowCore
import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case home, personalize, shortcut, dictation, account, setup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .personalize: return "Personalize"
        case .shortcut: return "Shortcut"
        case .dictation: return "Dictation"
        case .account: return "API key & spend"
        case .setup: return "Setup"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .personalize: return "person.text.rectangle"
        case .shortcut: return "keyboard"
        case .dictation: return "waveform"
        case .account: return "key"
        case .setup: return "checkmark.shield"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var state: AppState
    @ObservedObject var usage: UsageStore
    @Binding var section: DashboardSection

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) { s in
                Label(s.title, systemImage: s.icon)
                    .badge(s == .setup && setupIssues > 0 ? Text("\(setupIssues)") : nil)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                }
                .padding(12)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case .home: HomeSection(state: state, usage: usage)
                    case .personalize: PersonalizeSection(state: state)
                    case .shortcut: ShortcutSection(state: state)
                    case .dictation: DictationSection(state: state)
                    case .account: AccountSection(state: state, usage: usage)
                    case .setup: SetupSection(state: state)
                    }
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(section.title)
        }
        .frame(minWidth: 860, minHeight: 600)
    }

    private var setupIssues: Int {
        [state.hasAPIKey, state.micStatus == .authorized, state.accessibilityTrusted].filter { !$0 }.count
    }
    private var statusColor: Color { setupIssues == 0 ? .green : .orange }
    private var statusText: String {
        setupIssues == 0 ? "Ready · \(state.settings.hotkey.display)" : "\(setupIssues) setup step\(setupIssues == 1 ? "" : "s") left"
    }
}

// MARK: - Shared bits

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct StatTile: View {
    var label: String
    var value: String
    var detail: String?
    var icon: String
    var tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint).font(.system(size: 12, weight: .semibold))
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

enum Fmt {
    static func duration(_ s: Double) -> String {
        if s < 60 { return String(format: "%.0fs", s) }
        let m = Int(s / 60)
        if m < 60 { return "\(m)m \(Int(s) % 60)s" }
        return "\(m / 60)h \(m % 60)m"
    }
    static func hours(_ s: Double) -> String { s < 3600 ? duration(s) : String(format: "%.1f h", s / 3600) }
    static func int(_ n: Int) -> String { n.formatted(.number) }
    static func usd(_ v: Double) -> String { v < 0.01 && v > 0 ? String(format: "$%.4f", v) : String(format: "$%.2f", v) }
}

// MARK: - Home

struct HomeSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var usage: UsageStore

    var body: some View {
        let t = usage.totals
        VStack(alignment: .leading, spacing: 18) {
            UpdateBanner(updates: state.updates)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speak anywhere. Openflow types it.").font(.title2.weight(.semibold))
                    Text("Put your cursor in any text field and hold \(state.settings.hotkey.display) to talk, or tap it for hands-free.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.toggleHandsFree()
                } label: {
                    Label(state.engine.isActive ? "Stop" : "Try hands-free", systemImage: "mic.fill")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                StatTile(label: "Time spoken", value: Fmt.hours(t.spokenSeconds), detail: String(format: "%.2f hours of speech", t.spokenSeconds / 3600),
                         icon: "waveform", tint: .blue)
                StatTile(label: "Words dictated", value: Fmt.int(t.words), detail: String(format: "%.0f wpm speaking", t.wordsPerMinute),
                         icon: "text.word.spacing", tint: .purple)
                StatTile(label: "Keystrokes saved", value: Fmt.int(t.characters), detail: "characters you didn't type",
                         icon: "keyboard", tint: .orange)
                StatTile(label: "Time saved", value: Fmt.duration(t.timeSavedSeconds), detail: "vs. typing at 40 wpm",
                         icon: "hourglass", tint: .green)
                StatTile(label: "Dictations", value: Fmt.int(t.dictations), detail: "\(t.sessions) sessions",
                         icon: "text.bubble", tint: .teal)
                StatTile(label: "Avg. latency", value: t.dictations == 0 ? "–" : "\(t.averageLatencyMs) ms",
                         detail: "end of speech → pasted", icon: "bolt", tint: .yellow)
                StatTile(label: "API spend", value: Fmt.usd(t.totalCostUSD),
                         detail: "STT \(Fmt.usd(t.sttCostUSD)) · Grok \(Fmt.usd(t.llmCostUSD))", icon: "dollarsign.circle", tint: .pink)
                StatTile(label: "Audio streamed", value: Fmt.hours(t.streamedSeconds), detail: "billed at $0.20 / hour",
                         icon: "antenna.radiowaves.left.and.right", tint: .indigo)
            }

            Card(title: "Last 14 days") {
                let days = usage.recentDays(14)
                Chart(days, id: \.date) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Words", d.stats.words))
                        .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .bottom, endPoint: .top))
                        .cornerRadius(4)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .frame(height: 160)
                Text("Words dictated per day").font(.caption).foregroundStyle(.secondary)
            }

            Card(title: "Where you dictate") {
                let apps = t.appCounts.sorted { $0.value > $1.value }.prefix(8)
                if apps.isEmpty { Text("No dictations yet.").foregroundStyle(.secondary) }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    if !apps.isEmpty {
                        GridRow {
                            Text("App").foregroundStyle(.secondary)
                            Text("Dictations").foregroundStyle(.secondary)
                            Text("Words").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    ForEach(Array(apps), id: \.key) { app, n in
                        GridRow {
                            Text(app)
                            Text("\(n)").monospacedDigit()
                            Text(t.appWords[app].map(Fmt.int) ?? "–").monospacedDigit()
                        }
                    }
                }
                Text("Openflow keeps counts only. What you dictate is never stored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Personalize

struct PersonalizeSection: View {
    @ObservedObject var state: AppState
    @StateObject private var ui = TermUI()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "About you") {
                Text("Who you are, your role, team, the people and products you mention. Grok uses this to spell names right and match your tone. It is never typed into your text.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $state.settings.aboutMe)
                    .font(.body)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(alignment: .topLeading) {
                        if state.settings.aboutMe.isEmpty {
                            Text("e.g. I'm Sam, a product manager at Northwind. I work with Priya Raman (design) and Joaquín Ortega (engineering). I often mention Atlas, our analytics product, and customer pilots.")
                                .foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                        }
                    }
            }
            Card(title: "Custom instructions") {
                Text("How you want your text written. These override the defaults (tone, language, script, formatting).")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $state.settings.customInstructions)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(alignment: .topLeading) {
                        if state.settings.customInstructions.isEmpty {
                            Text("e.g. British spelling. In Slack keep it casual and lowercase. When I speak Hindi, write it in Latin script (Hinglish).")
                                .foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                        }
                    }
            }
            Card(title: "Dictionary") {
                Text("Names, jargon, and product terms. Sent to Grok Voice Transcribe as key terms (better recognition) and to the cleanup step as preferred spellings.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("Add a word or name", text: $ui.newTerm).textFieldStyle(.roundedBorder)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm).disabled(ui.newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                FlowLayout(spacing: 6) {
                    ForEach(state.settings.dictionary, id: \.self) { term in
                        HStack(spacing: 4) {
                            Text(term)
                            Button { state.settings.dictionary.removeAll { $0 == term } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
            }
        }
    }

    private func addTerm() {
        let t = ui.newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !state.settings.dictionary.contains(t) else { return }
        state.settings.dictionary.append(String(t.prefix(50)))
        ui.newTerm = ""
    }
}

/// Simple wrapping layout for dictionary chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Shortcut

struct ShortcutSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Dictation shortcut") {
                HStack(spacing: 12) {
                    Text(state.recordingShortcut ? "Press your shortcut…" : state.settings.hotkey.display)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(state.recordingShortcut ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(state.recordingShortcut ? Color.accentColor : .clear, lineWidth: 1.5))
                    if state.recordingShortcut {
                        Button("Cancel") { state.cancelShortcutRecording() }
                    } else {
                        Button("Record new shortcut") { state.beginShortcutRecording() }
                            .disabled(!state.hotkeyActive)
                    }
                }
                Text(state.hotkeyActive
                     ? "Press any key combination (⌥Space, ⌃⇧D), a two-key chord (⌃⌥), or a single modifier (Right ⌥, fn). Esc cancels."
                     : "Grant Accessibility access in Setup to enable global shortcuts.")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                Text("Presets").font(.subheadline.weight(.medium))
                HStack {
                    ForEach(Hotkey.presets, id: \.display) { p in
                        if state.settings.hotkey == p {
                            Button(p.display) {}.buttonStyle(.borderedProminent)
                        } else {
                            Button(p.display) { state.settings.hotkey = p }.buttonStyle(.bordered)
                        }
                    }
                }
                if state.settings.hotkey == .fn {
                    Text("Tip: set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, so fn doesn't open the emoji picker.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Card(title: "How the shortcut works") {
                Picker("Activation", selection: $state.settings.activation) {
                    ForEach(ActivationStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                VStack(alignment: .leading, spacing: 4) {
                    switch state.settings.activation {
                    case .holdOrTap:
                        Text("• Hold the shortcut while you talk; release to paste.")
                        Text("• Tap it once for hands-free: it pastes every time you pause and keeps listening. Tap again (or click ✕ on the bubble) to stop.")
                    case .toggle:
                        Text("• Tap to start hands-free. It pastes every time you pause. Tap again (or click ✕) to stop.")
                    case .holdOnly:
                        Text("• You must hold the shortcut while speaking. Releasing it stops listening and pastes.")
                    }
                    Text("• Esc discards what hasn't been pasted yet.")
                    Text("• Select text first to edit it by voice (“make this shorter”) or to add to it (“by the way…”).")
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Dictation

struct DictationSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Language") {
                Picker("Spoken language", selection: $state.settings.language) {
                    ForEach(supportedLanguages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .frame(maxWidth: 380)
                Text("Auto-detect handles any language and mid-sentence switches. Picking one also formats its numbers and currencies at the transcription step.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Card(title: "Microphone") {
                MicrophonePicker(state: state)
                Text("Openflow records from this input while you dictate. If it's unplugged, the system default is used until it's back.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Card(title: "Pauses") {
                HStack {
                    Text("Paste after a pause of")
                    Slider(value: Binding(get: { state.settings.pauseSeconds },
                                          set: { state.settings.pauseSeconds = ($0 * 10).rounded() / 10 }),
                           in: 0.5...3.0).frame(maxWidth: 260)
                    Text(String(format: "%.1f s", state.settings.pauseSeconds)).monospacedDigit().frame(width: 44)
                }
                Text("Hands-free mode pastes when you stop for this long. Start talking again before it pastes and Openflow keeps listening and merges everything into one paste.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text("Hands-free turns off after")
                    Picker("", selection: $state.settings.handsFreeIdleTimeout) {
                        Text("30 s").tag(30.0); Text("1 min").tag(60.0); Text("2 min").tag(120.0); Text("5 min").tag(300.0); Text("10 min").tag(600.0)
                    }.labelsHidden().frame(width: 100)
                    Text("of silence")
                }
            }
            Card(title: "Cleanup with Grok") {
                Toggle("Clean up and format with \(state.settings.formatterModel)", isOn: $state.settings.cleanupEnabled)
                Text("Removes filler, applies your corrections (“no wait, Tuesday”), formats lists, numbers, and emails, and matches the app you're typing in. Turn off to paste the raw transcript.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Reasoning", selection: $state.settings.reasoningEffort) {
                    Text("None (fastest)").tag("none"); Text("Low").tag("low")
                }
                .frame(maxWidth: 280)
                .disabled(!state.settings.cleanupEnabled)
                Toggle("Send the last few words before the cursor", isOn: $state.settings.sendRecentWords)
                Text("Up to 12 words, so a new dictation continues the previous text with the right spacing, capitalization, and punctuation. The rest of the field is never sent; text you select before dictating is. Password fields are never read.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "Bubble & sounds") {
                Picker("Bubble position", selection: $state.settings.bubblePlacement) {
                    ForEach(BubblePlacement.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 380)
                Toggle("Show the words being heard above the bubble", isOn: $state.settings.liveTranscript)
                Toggle("Play start and paste sounds", isOn: $state.settings.playSounds)
            }
        }
    }
}

/// "Openflow x.y.z is available — Update" (only when Sparkle found a newer version).
struct UpdateBanner: View {
    @ObservedObject var updates: UpdateController
    var body: some View {
        if let v = updates.availableVersion {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Openflow \(v) is available").fontWeight(.semibold)
                    Text("You have \(updates.currentVersion). Updating keeps your settings, key, and permissions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Update") { updates.checkForUpdates() }.buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
        }
    }
}

/// Picker over the connected inputs, plus "System default".
struct MicrophonePicker: View {
    @ObservedObject var state: AppState
    var body: some View {
        let devices = AudioDevices.inputs()
        let defaultName = devices.first(where: \.isDefault)?.name
        Picker("Microphone", selection: Binding(get: { state.settings.inputDeviceUID }, set: { state.selectInput(uid: $0) })) {
            Text("System default" + (defaultName.map { " (\($0))" } ?? "")).tag("")
            ForEach(devices) { d in Text(AudioDevices.label(d)).tag(d.uid) }
            if state.selectedInputMissing { Text("Saved microphone (not connected)").tag(state.settings.inputDeviceUID) }
        }
        .frame(maxWidth: 420)
    }
}

// MARK: - Account

struct AccountSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var usage: UsageStore
    @StateObject private var ui = KeyUI()

    var body: some View {
        let t = usage.totals
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "SpaceXAI API key") {
                HStack {
                    Image(systemName: state.hasAPIKey ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.hasAPIKey ? .green : .orange)
                    Text(state.hasAPIKey ? "Using key \(state.apiKeyMasked)" : "No key yet")
                    Spacer()
                    if state.hasAPIKey { Button("Remove", role: .destructive) { state.removeAPIKey(); ui.message = nil } }
                }
                HStack {
                    SecureField(state.hasAPIKey ? "Paste a new key to replace it" : "xai-…", text: $ui.newKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button(ui.checking ? "Checking…" : "Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(ui.newKey.trimmingCharacters(in: .whitespaces).isEmpty || ui.checking)
                }
                if let m = ui.message {
                    Text(m.text).font(.callout).foregroundStyle(m.ok ? .green : .red)
                }
                Text("\(APIKeyStore.usesKeychain ? "Stored in your macOS Keychain." : "Stored in a private file only your account can read (encrypted by FileVault).") Create keys at console.x.ai. Openflow calls grok-voice-transcribe-2.0 (speech to text) and \(state.settings.formatterModel) (cleanup) directly from this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "Spend") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text("Speech to text").foregroundStyle(.secondary)
                        Text(Fmt.usd(t.sttCostUSD)).monospacedDigit()
                        Text("\(Fmt.hours(t.streamedSeconds)) streamed × $0.20/h").font(.caption).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Grok cleanup").foregroundStyle(.secondary)
                        Text(Fmt.usd(t.llmCostUSD)).monospacedDigit()
                        Text("exact, from usage.cost_in_usd_ticks").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider().gridCellColumns(3)
                    GridRow {
                        Text("Total").fontWeight(.semibold)
                        Text(Fmt.usd(t.totalCostUSD)).fontWeight(.semibold).monospacedDigit()
                        Text(t.dictations > 0 ? "≈ \(Fmt.usd(t.totalCostUSD / Double(t.dictations))) per dictation" : "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Card {
                    let days = usage.recentDays(14)
                    Chart(days, id: \.date) { d in
                        BarMark(x: .value("Day", d.date, unit: .day), y: .value("USD", d.stats.sttCostUSD))
                            .foregroundStyle(by: .value("Kind", "Speech to text"))
                        BarMark(x: .value("Day", d.date, unit: .day), y: .value("USD", d.stats.llmCostUSD))
                            .foregroundStyle(by: .value("Kind", "Grok cleanup"))
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                    .frame(height: 140)
                }
                Button("Reset all stats", role: .destructive) { usage.resetAll() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private func save() {
        let key = ui.newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        ui.checking = true
        ui.message = nil
        let ui = self.ui, state = self.state
        Task { @MainActor in
            let r = await APIKeyStore.validate(key)
            ui.checking = false
            switch r {
            case .success(let name):
                state.setAPIKey(key)
                ui.newKey = ""
                ui.message = (true, "Saved. Key “\(name)” works.")
            case .failure(let e):
                ui.message = (false, "Not saved: \(e.localizedDescription)")
            }
        }
    }
}

// MARK: - Setup

struct SetupSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("The setup assistant walks through every step and tests each one.").foregroundStyle(.secondary)
                Spacer()
                Button("Run setup assistant") { NotificationCenter.default.post(name: .openOnboarding, object: nil) }
                    .buttonStyle(.borderedProminent)
            }
            Card(title: "Get ready") {
                SetupRow(done: state.hasAPIKey, title: "SpaceXAI API key", detail: "Used for transcription and cleanup.",
                         action: state.hasAPIKey ? nil : ("Add key", { NotificationCenter.default.post(name: .openDashboard, object: DashboardSection.account) }))
                Divider()
                SetupRow(done: state.micStatus == .authorized, title: "Microphone",
                         detail: state.micStatus == .denied ? "Denied: turn on Openflow in System Settings → Privacy → Microphone." : "To hear you while you dictate.",
                         action: state.micStatus == .authorized ? nil : ("Allow", { state.requestMicrophone() }))
                Divider()
                SetupRow(done: state.accessibilityTrusted, title: "Accessibility",
                         detail: "For the global shortcut, reading the cursor position and selection, and pasting into other apps.",
                         action: state.accessibilityTrusted ? nil : ("Open settings", { state.requestAccessibility() }))
                if !state.accessibilityTrusted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("In System Settings → Privacy & Security → Accessibility, switch on **\(AppIdentity.name)**. If it isn't in the list, click + and choose it from Applications, or drag it in from Finder. If an older “Openflow” entry is there, remove it with − first.")
                        Button("Show \(AppIdentity.name) in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        .buttonStyle(.link)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Card(title: "This app") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("Name").foregroundStyle(.secondary); Text(AppIdentity.name) }
                    GridRow { Text("Bundle ID").foregroundStyle(.secondary); Text(Bundle.main.bundleIdentifier ?? AppIdentity.bundleID).textSelection(.enabled) }
                    GridRow { Text("Location").foregroundStyle(.secondary); Text(Bundle.main.bundlePath).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                }
                .font(.callout)
                if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
                    Text("Run Openflow from /Applications so permissions attach to the copy you use every day.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Card(title: "Startup") {
                Toggle("Open Openflow when I log in", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                if state.launchAtLoginNeedsApproval {
                    Text("macOS needs your approval: System Settings → General → Login Items → allow Openflow.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Openflow lives in the menu bar (the waveform icon at the top of the screen).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct SetupRow: View {
    var done: Bool
    var title: String
    var detail: String
    var action: (String, () -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary).font(.system(size: 17))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let action { Button(action.0, action: action.1).buttonStyle(.borderedProminent) }
        }
    }
}

// View-local state lives in small observable objects: the SwiftUI `@State` macro plugin
// ships only with full Xcode, and this project builds with the Command Line Tools.
@MainActor final class TermUI: ObservableObject {
    @Published var newTerm = ""
}
@MainActor final class KeyUI: ObservableObject {
    @Published var newKey = ""
    @Published var checking = false
    @Published var message: (ok: Bool, text: String)?
}
