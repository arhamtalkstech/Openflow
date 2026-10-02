import Foundation

/// Where text goes. The app pastes at the system cursor; the CLI prints.
@MainActor
public protocol TextInserting: AnyObject {
    /// App name, bundle id, field type/label/window title, and — only if `includeFieldText` — the last
    /// few words before the cursor (never the whole field). Read at commit time.
    func captureContext(includeFieldText: Bool) -> InsertionContext
    /// The currently selected text in the focused field, if any (read when dictation starts).
    func captureSelection() -> String?
    /// Insert `text` (replacing the selection, after it, or at the cursor).
    /// Returns the exact string inserted, including any spacing prefix. `completion` reports whether the
    /// field actually changed (checked a moment later where the app exposes its text).
    @discardableResult
    func insert(_ text: String, action: InsertAction, pastedEarlierInSession: Bool,
                completion: ((InsertOutcome) -> Void)?) -> String
}

public struct InsertionContext: Sendable {
    public var appName: String?
    public var bundleID: String?
    public var textBeforeCursor: String?
    public var field: FieldInfo?
    public init(appName: String? = nil, bundleID: String? = nil, textBeforeCursor: String? = nil, field: FieldInfo? = nil) {
        self.appName = appName; self.bundleID = bundleID; self.textBeforeCursor = textBeforeCursor; self.field = field
    }
}

/// What kind of text box the cursor is in (from Accessibility).
public struct FieldInfo: Sendable, Equatable {
    public enum Kind: String, Sendable { case singleLine = "single-line", multiLine = "multi-line", unknown }
    public var kind: Kind
    /// Placeholder or accessible label, e.g. "Ask anything", "Message #general", "Search".
    public var label: String?
    /// Window or tab title, e.g. "Grok", "Inbox – Gmail".
    public var windowTitle: String?
    public init(kind: Kind, label: String? = nil, windowTitle: String? = nil) {
        self.kind = kind; self.label = label; self.windowTitle = windowTitle
    }
}

/// The dictation state machine.
///
/// Audio streams to Grok Voice Transcribe. A local voice-activity detector decides when the speaker
/// paused; the engine then sends `finalize`, gets the utterance, runs the Grok cleanup pass, and pastes.
/// If the speaker resumes before the paste lands, the cleanup is cancelled and the unpasted text is kept,
/// so the next pause pastes old + new together. Pasted text is never touched again.
@MainActor
public final class DictationEngine: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case listening
        /// Cleanup + paste in flight (the bubble shows a loader).
        case thinking
        /// Brief confirmation after a paste.
        case pasted
        case error(String)
    }

    public enum Mode: Equatable, Sendable {
        /// Pastes on every pause and keeps listening until stopped.
        case handsFree
        /// Pastes once, when stopped (key released).
        case pushToTalk
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var mode: Mode = .handsFree
    /// Unpasted transcript (finalized utterances + current partial).
    @Published public private(set) var liveText: String = ""
    @Published public private(set) var level: Float = 0
    @Published public private(set) var lastError: String?
    /// Listening for ~2 s without hearing any voice (muted mic, wrong input device, not speaking).
    @Published public private(set) var noAudio = false
    /// The streaming connection failed; audio is still being recorded for a later transcription.
    @Published public private(set) var offline = false
    /// A problem after speaking that the bubble offers to fix (Paste again / Retry).
    @Published public private(set) var issue: DictationIssue?
    public private(set) var isActive = false
    /// Test hooks: point the streaming / one-shot transcription at other endpoints.
    public var sttEndpoint: URL?
    public var restEndpoint: URL?

    public var settings: OpenflowSettings
    public var apiKeyProvider: () -> String?
    public weak var inserter: TextInserting?
    public var usage: UsageStore?
    /// Makes the formatter for a session; override for tests.
    public var makeFormatter: (OpenflowSettings, String) -> TextFormatting = { s, key in
        s.cleanupEnabled
            ? ContentGuardFormatter(HedgedFormatter(GrokFormatter(apiKey: key, model: s.formatterModel, reasoningEffort: s.reasoningEffort)))
            : PassthroughFormatter()
    }
    /// Tells the host to stop the microphone.
    public var onCaptureShouldStop: (() -> Void)?
    /// Fires when a session ends (after the last paste).
    public var onSessionEnded: (() -> Void)?
    /// Fires after each paste.
    public var onPasted: ((DictationRecord) -> Void)?
    /// Debug trace (the CLI prints it).
    public var trace: ((String) -> Void)?

    // Session state
    private var stt: STTStream?
    private var formatter: TextFormatting = PassthroughFormatter()
    private var assembler = TranscriptAssembler()
    private var vad = VoiceActivityDetector()
    private var pending: [String] = []
    /// For each pending utterance: its text split where the speaker really paused.
    private var pendingParts: [[String]] = []
    /// Silences ≥ 0.45 s on the session audio timeline (seconds of audio streamed).
    private var pauses: [(from: Double, to: Double)] = []
    private var lastVoicedAudioTime: Double = 0
    private var pastedThisSession: [String] = []
    /// Selection captured at session start; consumed by the first paste.
    public private(set) var selection: String?
    private var awaitingFinal = false
    private var finalizeSentAt: TimeInterval = 0
    private var refinalized = false
    /// `audio.done` sent: the server flushes everything, then sends `transcript.done`.
    private var audioDoneSent = false
    private var voiceSinceFinalize = false
    private var resumedSinceFinalize = false
    private var stopRequested = false
    private var stopRequestedAt: TimeInterval = 0
    private var commitTask: Task<Void, Never>?
    private var generation = 0
    /// A cleanup is running or finished for the first `inFlightCount` pending utterances.
    private var inFlightCount = 0
    /// Cleanup finished early (speculatively); waits for the full pause before pasting.
    private var readyPaste: ReadyPaste?
    private var stopAfterInFlight = false
    private var sessionStart: TimeInterval = 0
    private var streamedSamples = 0
    private var spokenSecondsSincePaste: Double = 0
    private var reconnects = 0
    private var timer: DispatchSourceTimer?
    private var pastedFlashWork: DispatchWorkItem?
    private var endingSession = false
    /// The session's audio (memory only, ≤ 10 min) so a failed transcription can be retried.
    private var sessionAudio: [Int16] = []
    private var audioIndexAtLastPaste = 0
    private var heardVoice = false
    private var recovering = false
    /// Audio of a dictation that couldn't be transcribed (memory only; cleared on dismiss/next dictation).
    private var failedAudio: [Int16]?
    private static let maxAudioSamples = 16_000 * 600

    private struct ReadyPaste {
        var snapshotCount: Int
        var raw: String
        var result: FormatResult
        var ctx: InsertionContext
        var spoken: Double
        var formatterMs: Int
        var cleaned: Bool
    }

    /// Silence after which the engine finalizes and starts cleanup speculatively.
    /// The paste itself still waits for the full `pauseSeconds`.
    private var speculativeSilence: Double { max(0.4, settings.pauseSeconds * 0.6) }

    public init(settings: OpenflowSettings, apiKeyProvider: @escaping () -> String?) {
        self.settings = settings
        self.apiKeyProvider = apiKeyProvider
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Public control

    /// Opens the STT stream. Returns false if no API key is configured.
    @discardableResult
    public func start(mode: Mode) -> Bool {
        guard !isActive else { return true }
        guard let key = apiKeyProvider(), !key.isEmpty else {
            setPhase(.error("Add your SpaceXAI API key in Openflow settings"))
            return false
        }
        isActive = true
        endingSession = false
        issue = nil
        failedAudio = nil
        noAudio = false
        offline = false
        heardVoice = false
        recovering = false
        sessionAudio = []
        sessionAudio.reserveCapacity(16_000 * 30)
        audioIndexAtLastPaste = 0
        self.mode = mode
        formatter = makeFormatter(settings, key)
        assembler.reset()
        vad = VoiceActivityDetector()
        pending = []
        pendingParts = []
        pauses = []
        lastVoicedAudioTime = 0
        pastedThisSession = []
        let sel = inserter?.captureSelection()?.trimmingCharacters(in: .whitespacesAndNewlines)
        selection = (sel?.isEmpty ?? true) ? nil : sel
        awaitingFinal = false
        voiceSinceFinalize = false
        resumedSinceFinalize = false
        stopRequested = false
        stopAfterInFlight = false
        audioDoneSent = false
        refinalized = false
        inFlightCount = 0
        readyPaste = nil
        streamedSamples = 0
        spokenSecondsSincePaste = 0
        reconnects = 0
        lastError = nil
        liveText = ""
        sessionStart = now
        vad.markVoice(at: sessionStart)
        connect(key: key)
        setPhase(.connecting)
        startTimer()
        trace?("session start mode=\(mode)\(selection.map { " selection=\"\($0.prefix(60))\"" } ?? "")")
        return true
    }

    public func setMode(_ m: Mode) {
        guard isActive, m != mode else { return }
        mode = m
        trace?("mode → \(m)")
    }

    /// Feed 16 kHz mono PCM16 samples from the mic (or a file).
    public func feed(_ samples: [Int16]) {
        guard isActive, !endingSession else { return }
        let t = now
        if sessionAudio.count < Self.maxAudioSamples { sessionAudio.append(contentsOf: samples) }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        stt?.sendAudio(data)
        let bufferStart = Double(streamedSamples) / 16_000
        streamedSamples += samples.count
        let r = vad.process(samples, now: t)
        if r.voiced {
            // Record the silence that just ended (used to find list items the speaker paused between).
            if lastVoicedAudioTime > 0, bufferStart - lastVoicedAudioTime >= 0.45 {
                pauses.append((from: lastVoicedAudioTime, to: bufferStart))
                if pauses.count > 400 { pauses.removeFirst(pauses.count - 400) }
            }
            lastVoicedAudioTime = Double(streamedSamples) / 16_000
        }
        level = level * 0.5 + r.level * 0.5
        // Speaking time includes the short gaps between words (350 ms hangover after voice).
        if t - vad.lastVoiceAt < 0.35 { spokenSecondsSincePaste += Double(samples.count) / 16_000 }
        if r.voiced { voiceSinceFinalize = true }
        if r.onset { heardVoice = true; if noAudio { noAudio = false } }
        if r.onset && !stopRequested {
            if awaitingFinal { resumedSinceFinalize = true }
            if inFlightCount > 0 { resume(reason: "voice") }
        }
    }

    /// Stop listening, paste whatever is unpasted, end the session.
    public func stop() {
        guard isActive, !stopRequested else { return }
        stopRequested = true
        stopRequestedAt = now
        onCaptureShouldStop?()
        trace?("stop requested")
        if offline {
            recoverFromAudio()
            return
        }
        if awaitingFinal {
            // Make the server flush every remaining word, then handleUtterance commits.
            sendAudioDone()
            return
        }
        if let ready = readyPaste, assembler.isEmpty, !voiceSinceFinalize, ready.snapshotCount == pending.count {
            // Cleanup of everything already finished; paste it now.
            readyPaste = nil
            paste(ready, final: true)
            return
        }
        if inFlightCount > 0 && inFlightCount == pending.count && assembler.isEmpty && !voiceSinceFinalize {
            // The running cleanup already covers everything; let it finish as the final paste.
            stopAfterInFlight = true
            return
        }
        cancelInFlight()
        if !assembler.isEmpty || voiceSinceFinalize {
            sendFinalize()
            sendAudioDone()
        } else {
            commit(final: true)
        }
    }

    /// Discard everything not yet pasted and end the session.
    public func cancel() {
        guard isActive else { return }
        trace?("cancelled")
        cancelInFlight()
        onCaptureShouldStop?()
        recordSessionUsage()
        teardown()
        setPhase(.idle)
        onSessionEnded?()
    }

    // MARK: - STT

    private func connect(key: String) {
        var cfg = STTConfig(apiKey: key, model: settings.sttModel, language: settings.language,
                            keyterms: settings.dictionary)
        cfg.endpoint = sttEndpoint
        let stream = STTStream(config: cfg) { [weak self] event in self?.handle(event) }
        stt = stream
        stream.connect()
    }

    private func handle(_ event: STTEvent) {
        guard isActive else { return }
        switch event {
        case .ready:
            reconnects = 0
            trace?(String(format: "stt ready +%.0fms", (now - sessionStart) * 1000))
            if phase == .connecting { setPhase(.listening) }
        case let .partial(text, isFinal, speechFinal, start, duration):
            if let utterance = assembler.apply(text: text, isFinal: isFinal, speechFinal: speechFinal, end: start + duration) {
                trace?("utterance: \(utterance)")
                handleUtterance(utterance)
            } else if !text.isEmpty && !awaitingFinal && !isFinal {
                // Quiet speakers may stay under the VAD threshold; new interim text proves speech.
                voiceSinceFinalize = true
                if inFlightCount > 0 && !stopRequested { resume(reason: "text") }
            }
            refreshLiveText()
        case let .done(text):
            trace?("stt done")
            // `done` may repeat the whole session's text; only the unfinalized remainder is new.
            _ = text
            if awaitingFinal { handleUtterance(assembler.flush()) }
        case let .error(msg):
            trace?("stt error: \(msg)")
            lastError = msg
            if msg.contains("401") || msg.lowercased().contains("api key") {
                setPhase(.error("SpaceXAI rejected the API key"))
                cancelKeepingPhase()
            }
        case .closed:
            guard !endingSession else { return }
            // Expected close after audio.done while the final cleanup runs.
            if stopRequested && (inFlightCount > 0 || readyPaste != nil) { return }
            // Unexpected close mid-session: keep what we heard and reconnect.
            let carry = assembler.flush()
            if !carry.isEmpty { pending.append(carry); pendingParts.append(currentParts(for: carry)) }
            if awaitingFinal { awaitingFinal = false }
            if stopRequested { commit(final: true); return }
            if offline { return }
            if reconnects < 3, let key = apiKeyProvider() {
                reconnects += 1
                trace?("stt closed; reconnect #\(reconnects)")
                let delay = 0.3 * Double(reconnects)
                schedule(after: delay) { [weak self] in
                    guard let self, self.isActive, !self.offline, !self.endingSession else { return }
                    self.connect(key: key)
                }
            } else {
                goOffline()
            }
        }
    }

    private func sendAudioDone() {
        guard !audioDoneSent else { return }
        audioDoneSent = true
        stt?.finish()
        trace?("audio.done sent (flush)")
    }

    private func sendFinalize() {
        awaitingFinal = true
        refinalized = false
        finalizeSentAt = now
        voiceSinceFinalize = false
        resumedSinceFinalize = false
        stt?.finalizeUtterance()
        trace?(String(format: "pause → finalize (silence %.2fs)", now - vad.lastVoiceAt))
    }

    /// Parts of the utterance just completed, split at real pauses (chunk timing × local VAD).
    private func currentParts(for utterance: String) -> [String] {
        var open = pauses
        // Silence still running at the end of the utterance counts too.
        let audioNow = Double(streamedSamples) / 16_000
        if lastVoicedAudioTime > 0, audioNow - lastVoicedAudioTime >= 0.45 { open.append((from: lastVoicedAudioTime, to: audioNow)) }
        let parts = TranscriptAssembler.spokenParts(chunks: assembler.lastUtteranceChunks, pauses: open)
        return parts.isEmpty ? [utterance] : parts
    }

    private func handleUtterance(_ utterance: String) {
        awaitingFinal = false
        let u = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.isEmpty {
            pending.append(u)
            pendingParts.append(currentParts(for: u))
        }
        refreshLiveText()
        if stopRequested {
            commit(final: true)
        } else if mode == .handsFree && !resumedSinceFinalize && !pending.isEmpty && inFlightCount != pending.count {
            commit(final: false)
        }
    }

    // MARK: - Commit (cleanup + paste)

    private func commit(final: Bool) {
        cancelInFlight()
        generation += 1
        let gen = generation
        guard !pending.isEmpty else {
            if final {
                // Voice was heard but nothing came back: ask the one-shot endpoint with the recorded audio.
                if spokenSecondsSincePaste >= 0.6 && !recovering && sessionAudio.count > audioIndexAtLastPaste {
                    recoverFromAudio()
                } else {
                    endSession()
                }
            }
            return
        }
        let snapshotCount = pending.count
        let raw = TranscriptAssembler.join(pending)
        if pendingParts.flatMap({ $0 }).count > 1 { trace?("spoken parts: \(pendingParts.flatMap { $0 })") }
        let spoken = spokenSecondsSincePaste
        let ctx = inserter?.captureContext(includeFieldText: settings.sendRecentWords) ?? InsertionContext()
        let fctx = FormatContext(appName: ctx.appName, bundleID: ctx.bundleID, textBeforeCursor: ctx.textBeforeCursor,
                                 pastedThisSession: pastedThisSession, languageHint: languageName(settings.language),
                                 dictionary: settings.dictionary, aboutMe: settings.aboutMe,
                                 customInstructions: settings.customInstructions, selectedText: selection,
                                 spokenParts: pendingParts.flatMap { $0 },
                                 field: ctx.field)
        let formatter = self.formatter
        let cleaned = settings.cleanupEnabled
        inFlightCount = snapshotCount
        if final || now - vad.lastVoiceAt >= settings.pauseSeconds { setPhase(.thinking) }
        trace?("cleanup start (final=\(final)) raw: \(raw)")
        commitTask = Task { [weak self] in
            let t0 = ProcessInfo.processInfo.systemUptime
            var result: FormatResult
            var fellBack = false
            do {
                result = try await formatter.format(raw, context: fctx)
            } catch {
                if Task.isCancelled { return }
                result = FormatResult(text: raw)
                fellBack = true
                await MainActor.run { self?.lastError = "Cleanup failed, pasted raw text: \(error.localizedDescription)" }
            }
            let fmtMs = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            await MainActor.run {
                guard let self, gen == self.generation, !Task.isCancelled else { return }
                let ready = ReadyPaste(snapshotCount: snapshotCount, raw: raw, result: result, ctx: ctx, spoken: spoken,
                                       formatterMs: fmtMs, cleaned: cleaned && !fellBack)
                if final || self.stopAfterInFlight {
                    self.paste(ready, final: true)
                } else {
                    self.readyPaste = ready
                    self.trace?("cleanup ready in \(fmtMs) ms; waiting for full pause")
                    self.tick()
                }
            }
        }
    }

    private func paste(_ r: ReadyPaste, final: Bool) {
        inFlightCount = 0
        readyPaste = nil
        pending.removeFirst(min(r.snapshotCount, pending.count))
        pendingParts.removeFirst(min(r.snapshotCount, pendingParts.count))
        let text = r.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            inserter?.insert(text, action: r.result.action, pastedEarlierInSession: !pastedThisSession.isEmpty) { [weak self] outcome in
                guard let self, outcome == .failed else { return }
                self.trace?("paste did not land → offering Paste again")
                self.issue = .pasteFailed(text: text)
            }
            audioIndexAtLastPaste = sessionAudio.count
            if r.result.action != .insertAtCursor { trace?("selection action: \(r.result.action.rawValue)") }
            selection = nil
            pastedThisSession.append(text)
            spokenSecondsSincePaste = 0
            let speechEnd = stopRequested ? max(vad.lastVoiceAt, stopRequestedAt - 0.2) : vad.lastVoiceAt
            let latency = Int((now - speechEnd) * 1000)
            let rec = DictationRecord(appName: r.ctx.appName, bundleID: r.ctx.bundleID, raw: r.raw, text: text,
                                      spokenSeconds: r.spoken, latencyMs: latency, formatterMs: r.formatterMs,
                                      llmCostTicks: r.result.costTicks, cleaned: r.cleaned)
            usage?.record(rec)
            onPasted?(rec)
            trace?("PASTED (speech end → paste \(latency) ms, cleanup \(r.formatterMs) ms): \(text)")
        }
        refreshLiveText()
        if final {
            endSession(flash: !text.isEmpty)
        } else {
            flashPasted()
            // Speech that finalized while we were busy gets its own paste.
            if !pending.isEmpty && !awaitingFinal && mode == .handsFree { commit(final: false) }
        }
    }

    /// Speaker resumed before the paste landed: drop the cleanup, keep the text unpasted.
    private func resume(reason: String) {
        guard inFlightCount > 0 else { return }
        cancelInFlight()
        trace?("resumed speaking (\(reason)) → cancel paste, keep listening")
        if phase == .thinking { setPhase(.listening) }
    }

    private func cancelInFlight() {
        generation += 1
        commitTask?.cancel()
        commitTask = nil
        inFlightCount = 0
        readyPaste = nil
    }

    // MARK: - Timer: pause detection, timeouts

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume()
        timer = t
    }

    private func tick() {
        guard isActive, !endingSession else { return }
        let t = now
        if !heardVoice && !noAudio && !stopRequested && t - sessionStart >= 2.0 {
            noAudio = true
            trace?("no audio detected")
        }
        if phase == .connecting && !offline && t - sessionStart > 6 {
            trace?("stt connect timeout")
            goOffline()
        }
        if offline || recovering {
            if !stopRequested, mode == .handsFree, t - vad.lastVoiceAt >= settings.handsFreeIdleTimeout { stop() }
            return
        }
        if awaitingFinal {
            let waited = t - finalizeSentAt
            if waited > 2.5 && !refinalized && !audioDoneSent {
                refinalized = true
                stt?.finalizeUtterance()
                trace?("finalize slow; re-sent")
            }
            // Last resort only: assembled interim text can lag the audio by ~1 s.
            if waited > (stopRequested ? 8 : 6) {
                trace?("finalize timeout; using assembled text")
                handleUtterance(assembler.flush())
                return
            }
        }
        if stopRequested { return }
        let silence = t - vad.lastVoiceAt
        guard mode == .handsFree, phase != .connecting else { return }
        if !awaitingFinal && voiceSinceFinalize && silence >= speculativeSilence {
            sendFinalize()
        }
        if silence >= settings.pauseSeconds {
            if let ready = readyPaste {
                paste(ready, final: false)
            } else if inFlightCount > 0 && phase == .listening {
                setPhase(.thinking)
            }
        }
        if phase == .listening && pending.isEmpty && assembler.isEmpty && inFlightCount == 0
            && silence >= settings.handsFreeIdleTimeout {
            trace?("idle timeout")
            stop()
        }
    }

    // MARK: - Session end

    private func endSession(flash: Bool = false) {
        guard isActive else { return }
        endingSession = true
        onCaptureShouldStop?()
        sendAudioDone()
        let s = stt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { s?.cancel() }
        recordSessionUsage()
        teardown(keepSTT: true)
        trace?("session end")
        if flash {
            setPhase(.pasted)
            schedule(after: 0.7) { [weak self] in
                guard let self, !self.isActive, self.phase == .pasted else { return }
                self.setPhase(.idle)
            }
        } else if case .error = phase {
            schedule(after: 2.5) { [weak self] in
                guard let self, !self.isActive else { return }
                if case .error = self.phase { self.setPhase(.idle) }
            }
        } else {
            setPhase(.idle)
        }
        onSessionEnded?()
    }

    private func cancelKeepingPhase() {
        cancelInFlight()
        onCaptureShouldStop?()
        recordSessionUsage()
        teardown()
        let p = phase
        onSessionEnded?()
        schedule(after: 3) { [weak self] in
            guard let self, !self.isActive, self.phase == p else { return }
            self.setPhase(.idle)
        }
    }

    private func recordSessionUsage() {
        let secs = Double(streamedSamples) / 16_000
        if secs > 0 { usage?.recordSession(streamedSeconds: secs) }
        streamedSamples = 0
    }

    private func teardown(keepSTT: Bool = false) {
        timer?.cancel(); timer = nil
        if !keepSTT { stt?.cancel() }
        stt = nil
        isActive = false
        stopRequested = false
        stopAfterInFlight = false
        awaitingFinal = false
        inFlightCount = 0
        readyPaste = nil
        level = 0
        liveText = ""
        pending = []
        pendingParts = []
        assembler.reset()
        sessionAudio = []
        noAudio = false
        offline = false
        recovering = false
    }

    // MARK: - Offline recording and recovery

    /// The stream is gone: keep recording into memory; transcribe the audio when the speaker stops.
    private func goOffline() {
        guard !offline else { return }
        offline = true
        trace?("offline → still recording")
        stt?.cancel()
        stt = nil
        awaitingFinal = false
        cancelInFlight()
        // Text already transcribed is re-done from the full audio since the last paste.
        if phase == .connecting || phase == .thinking { setPhase(.listening) }
        if stopRequested { recoverFromAudio() }
    }

    /// Transcribe everything since the last paste with the one-shot endpoint, then clean up and paste.
    private func recoverFromAudio() {
        guard !recovering else { return }
        recovering = true
        let audio = Array(sessionAudio[min(audioIndexAtLastPaste, sessionAudio.count)...])
        guard audio.count > 16_000 / 2, heardVoice || !pending.isEmpty else {
            endSession()
            return
        }
        onCaptureShouldStop?()
        setPhase(.thinking)
        trace?(String(format: "recovering %.1f s of audio via /v1/stt", Double(audio.count) / 16_000))
        guard let key = apiKeyProvider() else { endSession(); return }
        let model = settings.sttModel, language = settings.language, endpoint = restEndpoint
        Task { [weak self] in
            do {
                let text = try await STTREST.transcribe(audio, apiKey: key, model: model, language: language, endpoint: endpoint)
                await MainActor.run {
                    guard let self, self.isActive else { return }
                    self.trace?("recovered transcript: \(text)")
                    self.pending = text.isEmpty ? [] : [text]
                    self.pendingParts = text.isEmpty ? [] : [[text]]
                    self.offline = false
                    self.stopRequested = true
                    self.commit(final: true)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    let reason = STTREST.reason(error)
                    self.trace?("recovery failed: \(reason)")
                    self.failedAudio = audio
                    self.issue = .transcriptionFailed(reason: "\(reason) · audio kept")
                    self.endSession()
                }
            }
        }
    }

    /// The bubble's action button: paste the text again, or retry the kept audio.
    public func resolveIssue() {
        guard !isActive, let current = issue else { return }
        switch current {
        case .pasteFailed(let text):
            issue = nil
            inserter?.insert(text, action: .insertAtCursor, pastedEarlierInSession: false) { [weak self] outcome in
                if outcome == .failed { self?.issue = .pasteFailed(text: text) }
            }
        case .transcriptionFailed:
            guard let audio = failedAudio, let key = apiKeyProvider() else { issue = nil; return }
            issue = nil
            setPhase(.thinking)
            let s = settings, endpoint = restEndpoint
            let formatter = makeFormatter(s, key)
            let ctx = inserter?.captureContext(includeFieldText: s.sendRecentWords) ?? InsertionContext()
            Task { [weak self] in
                do {
                    let raw = try await STTREST.transcribe(audio, apiKey: key, model: s.sttModel, language: s.language, endpoint: endpoint)
                    let fctx = FormatContext(appName: ctx.appName, bundleID: ctx.bundleID, textBeforeCursor: ctx.textBeforeCursor,
                                             languageHint: s.language, dictionary: s.dictionary, aboutMe: s.aboutMe,
                                             customInstructions: s.customInstructions, field: ctx.field)
                    let result = raw.isEmpty ? FormatResult(text: "") : ((try? await formatter.format(raw, context: fctx)) ?? FormatResult(text: raw))
                    await MainActor.run {
                        guard let self else { return }
                        self.failedAudio = nil
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { self.setPhase(.idle); return }
                        self.inserter?.insert(text, action: .insertAtCursor, pastedEarlierInSession: false) { outcome in
                            if outcome == .failed { self.issue = .pasteFailed(text: text) }
                        }
                        let rec = DictationRecord(appName: ctx.appName, bundleID: ctx.bundleID, raw: raw, text: text,
                                                  spokenSeconds: Double(audio.count) / 16_000, latencyMs: 0, formatterMs: 0,
                                                  llmCostTicks: result.costTicks, cleaned: s.cleanupEnabled)
                        self.usage?.record(rec)
                        self.usage?.recordSession(streamedSeconds: Double(audio.count) / 16_000)
                        self.onPasted?(rec)
                        self.trace?("RETRY PASTED: \(text)")
                        self.setPhase(.pasted)
                        self.schedule(after: 0.7) { [weak self] in
                            if self?.phase == .pasted, self?.isActive == false { self?.setPhase(.idle) }
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.issue = .transcriptionFailed(reason: "\(STTREST.reason(error)) · audio kept")
                        self.setPhase(.idle)
                    }
                }
            }
        }
    }

    public func dismissIssue() {
        issue = nil
        failedAudio = nil
    }

    /// Whether a failed dictation's audio is being kept for a retry.
    public var hasFailedAudio: Bool { failedAudio != nil }

    // MARK: - Helpers

    private func flashPasted() {
        setPhase(.pasted)
        pastedFlashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.phase == .pasted else { return }
                self.setPhase(.listening)
            }
        }
        pastedFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func schedule(after s: Double, _ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
    }

    private func refreshLiveText() {
        liveText = TranscriptAssembler.join(pending + [assembler.current])
    }

    private func setPhase(_ p: Phase) {
        if phase != p {
            phase = p
            trace?("phase → \(p)")
        }
    }

    private func languageName(_ code: String) -> String {
        guard !code.isEmpty else { return "" }
        return supportedLanguages.first { $0.code == code }?.name ?? code
    }
}
