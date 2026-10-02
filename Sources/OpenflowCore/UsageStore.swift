import Foundation

/// Streaming STT list price: $0.20 per hour of audio streamed.
public let sttStreamingUSDPerHour = 0.20
/// SpaceXAI cost ticks per US dollar (`usage.cost_in_usd_ticks`).
public let ticksPerUSD = 10_000_000_000.0
/// Typing speed used for "time saved" (characters per minute ≈ 40 WPM).
public let typingCharsPerMinute = 200.0

/// One pasted dictation. Used in memory (stats, the setup assistant's practice check, "Paste last
/// dictation"); only its numbers are persisted — the text never is.
public struct DictationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var appName: String?
    public var bundleID: String?
    public var raw: String
    public var text: String
    /// Seconds of detected speech that produced this paste.
    public var spokenSeconds: Double
    /// End of speech (or stop) → text inserted, milliseconds.
    public var latencyMs: Int
    /// Formatter round trip, milliseconds (0 in raw mode).
    public var formatterMs: Int
    public var llmCostTicks: Int64
    public var cleaned: Bool

    public var words: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
    public var characters: Int { text.count }

    public init(appName: String?, bundleID: String?, raw: String, text: String, spokenSeconds: Double,
                latencyMs: Int, formatterMs: Int, llmCostTicks: Int64, cleaned: Bool) {
        self.appName = appName; self.bundleID = bundleID; self.raw = raw; self.text = text
        self.spokenSeconds = spokenSeconds; self.latencyMs = latencyMs; self.formatterMs = formatterMs
        self.llmCostTicks = llmCostTicks; self.cleaned = cleaned
    }
}

public struct DayStats: Codable, Equatable, Sendable {
    public var spokenSeconds: Double = 0
    public var streamedSeconds: Double = 0
    public var words: Int = 0
    public var characters: Int = 0
    public var dictations: Int = 0
    public var llmCostTicks: Int64 = 0
    public init() {}

    public var sttCostUSD: Double { streamedSeconds / 3600 * sttStreamingUSDPerHour }
    public var llmCostUSD: Double { Double(llmCostTicks) / ticksPerUSD }
}

public struct UsageTotals: Codable, Equatable, Sendable {
    public var sessions: Int = 0
    public var spokenSeconds: Double = 0
    /// Seconds of audio sent to the streaming STT endpoint (what SpaceXAI bills).
    public var streamedSeconds: Double = 0
    public var words: Int = 0
    /// Characters inserted = keystrokes you did not type.
    public var characters: Int = 0
    public var dictations: Int = 0
    public var llmCostTicks: Int64 = 0
    public var latencyMsSum: Int = 0
    public var appCounts: [String: Int] = [:]
    public var appWords: [String: Int] = [:]
    /// Key: yyyy-MM-dd (local time).
    public var days: [String: DayStats] = [:]
    public init() {}

    public var sttCostUSD: Double { streamedSeconds / 3600 * sttStreamingUSDPerHour }
    public var llmCostUSD: Double { Double(llmCostTicks) / ticksPerUSD }
    public var totalCostUSD: Double { sttCostUSD + llmCostUSD }

    enum CodingKeys: String, CodingKey {
        case sessions, spokenSeconds, streamedSeconds, words, characters, dictations, llmCostTicks, latencyMsSum, appCounts, appWords, days
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = (try? c.decode(Int.self, forKey: .sessions)) ?? 0
        spokenSeconds = (try? c.decode(Double.self, forKey: .spokenSeconds)) ?? 0
        streamedSeconds = (try? c.decode(Double.self, forKey: .streamedSeconds)) ?? 0
        words = (try? c.decode(Int.self, forKey: .words)) ?? 0
        characters = (try? c.decode(Int.self, forKey: .characters)) ?? 0
        dictations = (try? c.decode(Int.self, forKey: .dictations)) ?? 0
        llmCostTicks = (try? c.decode(Int64.self, forKey: .llmCostTicks)) ?? 0
        latencyMsSum = (try? c.decode(Int.self, forKey: .latencyMsSum)) ?? 0
        appCounts = (try? c.decode([String: Int].self, forKey: .appCounts)) ?? [:]
        appWords = (try? c.decode([String: Int].self, forKey: .appWords)) ?? [:]
        days = (try? c.decode([String: DayStats].self, forKey: .days)) ?? [:]
    }
    public var averageLatencyMs: Int { dictations == 0 ? 0 : latencyMsSum / dictations }
    /// Typing time for the inserted characters minus the time spent speaking them.
    public var timeSavedSeconds: Double { max(0, Double(characters) / typingCharsPerMinute * 60 - spokenSeconds) }
    public var wordsPerMinute: Double { spokenSeconds < 1 ? 0 : Double(words) / (spokenSeconds / 60) }
}

/// Persists usage totals (numbers only) to `~/Library/Application Support/Openflow/usage.json`.
/// No dictation text is ever written to disk.
@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var totals = UsageTotals()
    public let fileURL: URL
    private var saveWork: DispatchWorkItem?

    private struct Snapshot: Codable { var totals: UsageTotals }

    nonisolated public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Openflow", isDirectory: true).appendingPathComponent("usage.json")
    }

    public init(fileURL: URL = UsageStore.defaultURL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let snap = try? JSONDecoder.iso.decode(Snapshot.self, from: data) { totals = snap.totals }
        // Earlier builds also stored dictation history (with text): rewrite the file without it.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["history"] != nil { saveNow() }
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    public func record(_ r: DictationRecord) {
        totals.dictations += 1
        totals.words += r.words
        totals.characters += r.characters
        totals.spokenSeconds += r.spokenSeconds
        totals.llmCostTicks += r.llmCostTicks
        totals.latencyMsSum += r.latencyMs
        if let app = r.appName {
            totals.appCounts[app, default: 0] += 1
            totals.appWords[app, default: 0] += r.words
        }
        let k = Self.dayKey(r.date)
        var day = totals.days[k] ?? DayStats()
        day.dictations += 1
        day.words += r.words
        day.characters += r.characters
        day.spokenSeconds += r.spokenSeconds
        day.llmCostTicks += r.llmCostTicks
        totals.days[k] = day
        scheduleSave()
    }

    public func recordSession(streamedSeconds: Double, date: Date = Date()) {
        totals.sessions += 1
        totals.streamedSeconds += streamedSeconds
        let k = Self.dayKey(date)
        var day = totals.days[k] ?? DayStats()
        day.streamedSeconds += streamedSeconds
        totals.days[k] = day
        scheduleSave()
    }

    public func resetAll() {
        totals = UsageTotals()
        scheduleSave()
    }

    /// Last `n` days (oldest first), filling gaps with zeros.
    public func recentDays(_ n: Int, now: Date = Date()) -> [(date: Date, stats: DayStats)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<n).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (d, totals.days[Self.dayKey(d)] ?? DayStats())
        }
    }

    public func saveNow() {
        saveWork?.cancel()
        let snap = Snapshot(totals: totals)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso.encode(snap).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Openflow: failed to save usage: \(error)")
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
