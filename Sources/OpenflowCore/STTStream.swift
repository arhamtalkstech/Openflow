import Foundation

/// Events from `wss://api.x.ai/v1/stt` (Grok Voice Transcribe).
public enum STTEvent: Sendable, Equatable {
    case ready
    /// `isFinal=false`: interim, may change. `isFinal && !speechFinal`: chunk locked.
    /// `isFinal && speechFinal`: utterance complete; `text` is the stitched utterance.
    /// `start + duration` is the session audio time where the chunk ends (seconds).
    case partial(text: String, isFinal: Bool, speechFinal: Bool, start: Double = 0, duration: Double = 0)
    case done(text: String)
    case error(String)
    case closed
}

public struct STTConfig: Sendable {
    public var apiKey: String
    public var model: String = "grok-voice-transcribe-2.0"
    public var language: String = ""
    public var keyterms: [String] = []
    public var sampleRate: Int = 16_000
    /// Override for tests (default `wss://api.x.ai/v1/stt`).
    public var endpoint: URL?

    public init(apiKey: String, model: String = "grok-voice-transcribe-2.0", language: String = "", keyterms: [String] = []) {
        self.apiKey = apiKey; self.model = model; self.language = language; self.keyterms = keyterms
    }

    public var url: URL {
        var c = URLComponents(url: endpoint ?? URL(string: "wss://api.x.ai/v1/stt")!, resolvingAgainstBaseURL: false)!
        var q: [URLQueryItem] = [
            .init(name: "model", value: model),
            .init(name: "sample_rate", value: String(sampleRate)),
            .init(name: "encoding", value: "pcm"),
            .init(name: "interim_results", value: "true"),
            // Pauses are detected client-side and closed with `finalize`, so keep the server's own
            // endpointing long enough that it rarely ends an utterance on its own.
            .init(name: "endpointing", value: "5000"),
        ]
        if !language.isEmpty { q.append(.init(name: "language", value: language)) }
        for term in keyterms.prefix(100) where !term.trimmingCharacters(in: .whitespaces).isEmpty {
            q.append(.init(name: "keyterm", value: String(term.prefix(50))))
        }
        c.queryItems = q
        return c.url!
    }
}

/// One streaming transcription session. Audio sent before the server's `transcript.created`
/// is buffered and flushed once the server is ready.
public final class STTStream: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    private let config: STTConfig
    private let onEvent: @MainActor (STTEvent) -> Void
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var ready = false
    private var preReadyAudio: [Data] = []
    private var preReadyControl: [String] = []
    private var closed = false

    public init(config: STTConfig, onEvent: @escaping @MainActor (STTEvent) -> Void) {
        self.config = config
        self.onEvent = onEvent
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    public func connect() {
        var req = URLRequest(url: config.url)
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
    }

    /// 16 kHz mono PCM16 little-endian.
    public func sendAudio(_ pcm: Data) {
        lock.lock(); defer { lock.unlock() }
        if closed { return }
        if !ready { preReadyAudio.append(pcm); return }
        task?.send(.data(pcm)) { _ in }
    }

    /// Force the current utterance to end now (`speech_final`); the session stays open.
    public func finalizeUtterance() { sendControl(#"{"type":"finalize"}"#) }

    /// No more audio: the server flushes, sends `transcript.done`, and closes.
    public func finish() { sendControl(#"{"type":"audio.done"}"#) }

    public func cancel() {
        lock.lock(); closed = true; lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func sendControl(_ json: String) {
        lock.lock(); defer { lock.unlock() }
        if closed { return }
        if !ready { preReadyControl.append(json); return }
        task?.send(.string(json)) { _ in }
    }

    private func becameReady() {
        // Flush under the lock so live audio cannot overtake buffered audio.
        lock.lock(); defer { lock.unlock() }
        var merged = Data()
        for chunk in preReadyAudio { merged.append(chunk) }
        var offset = 0
        while offset < merged.count {  // ~100 ms frames, as the docs recommend
            let end = min(offset + 3200, merged.count)
            task?.send(.data(merged.subdata(in: offset..<end))) { _ in }
            offset = end
        }
        for c in preReadyControl { task?.send(.string(c)) { _ in } }
        preReadyAudio = []; preReadyControl = []
        ready = true
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.lock.lock(); let wasClosed = self.closed; self.closed = true; self.lock.unlock()
                if !wasClosed { self.emit(.error(err.localizedDescription)) }
                self.emit(.closed)
            case .success(let msg):
                var text: String?
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: break
                }
                if let text { self.handle(text) }
                self.receive()
            }
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "transcript.created":
            becameReady()
            emit(.ready)
        case "transcript.partial":
            emit(.partial(text: obj["text"] as? String ?? "",
                          isFinal: obj["is_final"] as? Bool ?? false,
                          speechFinal: obj["speech_final"] as? Bool ?? false,
                          start: (obj["start"] as? NSNumber)?.doubleValue ?? 0,
                          duration: (obj["duration"] as? NSNumber)?.doubleValue ?? 0))
        case "transcript.done":
            emit(.done(text: obj["text"] as? String ?? ""))
        case "error":
            emit(.error(obj["message"] as? String ?? "Unknown STT error"))
        default:
            break
        }
    }

    private func emit(_ e: STTEvent) {
        let cb = onEvent
        // The main queue is FIFO; unstructured Tasks are not guaranteed to keep event order.
        DispatchQueue.main.async { MainActor.assumeIsolated { cb(e) } }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock(); closed = true; lock.unlock()
        emit(.closed)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let http = task.response as? HTTPURLResponse, http.statusCode == 401 {
            emit(.error("SpaceXAI rejected the API key (401)."))
        }
    }
}
