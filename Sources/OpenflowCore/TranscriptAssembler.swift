import Foundation

/// Folds the STT event stream into "current utterance" text.
///
/// Observed on grok-voice-transcribe-2.0: inside one utterance the server locks ~3 s chunks
/// (`is_final`), and later interims only carry the text after the last locked chunk.
/// The `speech_final` event then carries the whole stitched utterance.
public struct TranscriptAssembler: Sendable {
    public private(set) var lockedChunks: [String] = []
    /// Session audio time (s) where each locked chunk ends. The server locks chunks at silence
    /// boundaries (and every ~3 s of continuous speech).
    public private(set) var chunkEnds: [Double] = []
    public private(set) var interim: String = ""
    /// Chunks of the utterance that just completed (read right after `apply` returns it).
    public private(set) var lastUtteranceChunks: [(text: String, end: Double)] = []

    public init() {}

    /// Text heard in the current (not yet finalized) utterance.
    public var current: String {
        Self.join(lockedChunks + [interim])
    }

    public var isEmpty: Bool { current.isEmpty }

    /// Returns the completed utterance when `speechFinal` arrives, else nil.
    public mutating func apply(text: String, isFinal: Bool, speechFinal: Bool, end: Double = 0) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if speechFinal {
            // Prefer the server's stitched text; fall back to what we assembled.
            let utterance = t.isEmpty ? current : t
            var chunks = Array(zip(lockedChunks, chunkEnds)).map { (text: $0.0, end: $0.1) }
            // Text the server finalized without a separate chunk event.
            let covered = Self.join(lockedChunks)
            if chunks.isEmpty || utterance.count > covered.count + 2 {
                let rest = chunks.isEmpty ? utterance : String(utterance.dropFirst(min(covered.count, utterance.count)))
                if !rest.trimmingCharacters(in: .whitespaces).isEmpty { chunks.append((text: rest, end: end)) }
            }
            reset()
            lastUtteranceChunks = chunks
            return utterance
        }
        if isFinal {
            if !t.isEmpty { lockedChunks.append(t); chunkEnds.append(end) }
            interim = ""
        } else {
            interim = t
        }
        return nil
    }

    /// Ends the utterance with whatever has been heard (used if `speech_final` never arrives).
    public mutating func flush() -> String {
        let u = current
        var chunks = Array(zip(lockedChunks, chunkEnds)).map { (text: $0.0, end: $0.1) }
        if !interim.isEmpty { chunks.append((text: interim, end: chunkEnds.last ?? 0)) }
        reset()
        lastUtteranceChunks = chunks
        return u
    }

    public mutating func reset() {
        lockedChunks = []
        chunkEnds = []
        interim = ""
    }

    /// Groups chunks into the parts the speaker separated with real pauses.
    /// A chunk boundary counts as a pause only if local VAD saw ≥ `minPause` of silence near it.
    public static func spokenParts(chunks: [(text: String, end: Double)], pauses: [(from: Double, to: Double)],
                                   minPause: Double = 0.45) -> [String] {
        var parts: [String] = []
        var current: [String] = []
        for (i, c) in chunks.enumerated() {
            current.append(c.text)
            let isLast = i == chunks.count - 1
            // Server chunk ends land inside or just after the silence that caused them.
            let paused = pauses.contains { p in
                p.to - p.from >= minPause && p.from <= c.end + 0.3 && p.to >= c.end - 0.9
            }
            if isLast || paused {
                parts.append(join(current))
                current = []
            }
        }
        return parts.filter { !$0.isEmpty }
    }

    public static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Energy-based voice activity detector with an adaptive noise floor.
/// Feed 16 kHz PCM16 mono; it evaluates 20 ms frames.
public struct VoiceActivityDetector: Sendable {
    public private(set) var noiseFloor: Float = 0.002
    public private(set) var lastVoiceAt: TimeInterval = 0
    public private(set) var voicedRun: Int = 0
    /// RMS (0–1 scale) a frame must exceed regardless of noise floor.
    public var absoluteMin: Float = 0.006
    /// Frame must exceed `noiseFloor * ratio`.
    public var ratio: Float = 3.0
    private var carry: [Int16] = []

    public init() {}

    public struct Result: Sendable {
        /// 0–1 loudness for the waveform UI.
        public var level: Float
        /// At least one voiced frame in this buffer.
        public var voiced: Bool
        /// Consecutive voiced frames reached `onsetFrames` (sustained speech, not a click).
        public var onset: Bool
        /// Number of voiced 20 ms frames in this buffer.
        public var voicedFrames: Int
    }

    /// `now` is the media time at the *end* of `samples`.
    public mutating func process(_ samples: [Int16], now: TimeInterval, onsetFrames: Int = 6) -> Result {
        carry.append(contentsOf: samples)
        let frame = 320  // 20 ms at 16 kHz
        var peakRMS: Float = 0
        var anyVoiced = false
        var onset = false
        var voicedFrames = 0
        var idx = 0
        let frames = carry.count / frame
        for f in 0..<frames {
            var sum: Float = 0
            for i in 0..<frame {
                let v = Float(carry[idx + i]) / 32768
                sum += v * v
            }
            idx += frame
            let rms = (sum / Float(frame)).squareRoot()
            peakRMS = max(peakRMS, rms)
            let threshold = max(absoluteMin, noiseFloor * ratio)
            if rms > threshold {
                voicedRun += 1
                voicedFrames += 1
                anyVoiced = true
                let frameEnd = now - Double(frames - f - 1) * 0.02
                lastVoiceAt = max(lastVoiceAt, frameEnd)
                if voicedRun >= onsetFrames { onset = true }
            } else {
                voicedRun = 0
                // Track the floor quickly downward, slowly upward.
                if rms < noiseFloor { noiseFloor = max(0.0005, noiseFloor * 0.9 + rms * 0.1) }
                else { noiseFloor += (rms - noiseFloor) * 0.01 }
            }
        }
        carry.removeFirst(frames * frame)
        // Map RMS to a perceptual 0–1 level (-55 dB … -10 dB).
        let db = 20 * log10(max(peakRMS, 1e-6))
        let level = min(1, max(0, (db + 55) / 45))
        return Result(level: level, voiced: anyVoiced, onset: onset, voicedFrames: voicedFrames)
    }

    public mutating func markVoice(at t: TimeInterval) { lastVoiceAt = max(lastVoiceAt, t) }
}

/// Decides what goes between existing text and newly inserted text.
public enum SmartSpacing {
    /// - Parameters:
    ///   - before: text immediately before the cursor, if known.
    ///   - insertion: the formatted text about to be inserted.
    ///   - pastedEarlierInSession: whether this dictation session already pasted something.
    public static func prefix(before: String?, insertion: String, pastedEarlierInSession: Bool) -> String {
        guard let first = insertion.first else { return "" }
        let startsBlock = isListLine(insertion)
        if let before {
            guard let last = before.last else { return "" }   // empty field / start of text
            if last.isNewline { return "" }
            if startsBlock { return "\n" }
            if last.isWhitespace { return "" }
            if first.isWhitespace || first.isNewline { return "" }
            if ",.;:!?)]}".contains(first) { return "" }
            if "([{\"'“‘".contains(last) { return "" }
            return " "
        }
        // No field context: separate from the previous paste of this session.
        guard pastedEarlierInSession else { return "" }
        if first.isWhitespace || first.isNewline { return "" }
        return startsBlock ? "\n" : " "
    }

    public static func isListLine(_ s: String) -> Bool {
        let t = s.drop(while: { $0 == " " })
        if t.hasPrefix("- ") || t.hasPrefix("• ") || t.hasPrefix("* ") { return true }
        let digits = t.prefix(while: { $0.isNumber })
        return !digits.isEmpty && (t.dropFirst(digits.count).hasPrefix(". ") || t.dropFirst(digits.count).hasPrefix(") "))
    }
}

/// What Openflow itself last inserted, per app. If the user hasn't clicked or typed in that app since,
/// the text before the cursor is exactly this — even in apps that don't expose their text (Google Docs).
public struct RecentInsert: Sendable, Equatable {
    public var pid: Int32
    public var text: String
    public var time: TimeInterval
    /// The user-input counter (clicks + keys) at the moment of the paste.
    public var inputCount: Int

    public init(pid: Int32, text: String, time: TimeInterval, inputCount: Int) {
        self.pid = pid; self.text = text; self.time = time; self.inputCount = inputCount
    }

    /// Still describes the text before the cursor?
    public func isValid(pid: Int32, inputCount: Int, now: TimeInterval) -> Bool {
        pid == self.pid && inputCount == self.inputCount && now - time < 15 * 60
    }
}

public enum TextContext {
    /// The last few words before the cursor, for the cleanup prompt (never the whole field).
    /// Drops terminal UI chrome (box-drawing characters, prompt arrows).
    public static func recentWords(_ before: String?, maxWords: Int = 12, maxChars: Int = 100) -> String? {
        guard let before else { return nil }
        let cleaned = String(before.unicodeScalars.filter { s in
            !(0x2500...0x259F).contains(s.value) && !"❯›»▌▍▎█".unicodeScalars.contains(s)
        })
        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        let tail = words.suffix(maxWords).joined(separator: " ")
        return String(tail.suffix(maxChars))
    }
}
