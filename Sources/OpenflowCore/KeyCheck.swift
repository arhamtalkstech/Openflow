import Foundation

/// End-to-end check that an API key can do everything Openflow needs.
/// A key can be valid yet restricted to some models or endpoints, so each capability is tried for real.
public struct KeyCheckReport: Sendable {
    public enum Status: Sendable, Equatable { case ok(String), failed(String) }
    public var key: Status
    public var speechToText: Status
    public var cleanup: Status
    public var allOK: Bool {
        [key, speechToText, cleanup].allSatisfy { if case .ok = $0 { return true } else { return false } }
    }
}

public enum KeyCheck {
    /// Runs: key validity (`/v1/api-key`), STT WebSocket handshake (`transcript.created`),
    /// and a one-word grok-4.3 cleanup. Costs a fraction of a cent.
    public static func run(apiKey: String, sttModel: String = "grok-voice-transcribe-2.0",
                           formatterModel: String = "grok-4.3") async -> KeyCheckReport {
        let key: KeyCheckReport.Status
        switch await APIKeyStore.validate(apiKey) {
        case .success(let name): key = .ok("Key “\(name)” is active")
        case .failure(let e): key = .failed(e.localizedDescription)
        }
        guard case .ok = key else {
            return KeyCheckReport(key: key, speechToText: .failed("Skipped"), cleanup: .failed("Skipped"))
        }
        async let stt = checkSTT(apiKey: apiKey, model: sttModel)
        async let llm = checkCleanup(apiKey: apiKey, model: formatterModel)
        return await KeyCheckReport(key: key, speechToText: stt, cleanup: llm)
    }

    static func checkSTT(apiKey: String, model: String) async -> KeyCheckReport.Status {
        await withCheckedContinuation { (cont: CheckedContinuation<KeyCheckReport.Status, Never>) in
            let box = OnceBox(cont)
            var cfg = STTConfig(apiKey: apiKey, model: model)
            cfg.sampleRate = 16_000
            var stream: STTStream?
            let t0 = Date()
            stream = STTStream(config: cfg) { event in
                switch event {
                case .ready:
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    box.resume(.ok("\(model) connected in \(ms) ms"))
                    stream?.cancel()
                case .error(let m):
                    box.resume(.failed(m))
                    stream?.cancel()
                case .closed:
                    box.resume(.failed("Connection closed before the transcription service was ready"))
                default: break
                }
            }
            stream?.connect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                box.resume(.failed("Timed out connecting to speech-to-text"))
                stream?.cancel()
            }
        }
    }

    static func checkCleanup(apiKey: String, model: String) async -> KeyCheckReport.Status {
        let f = GrokFormatter(apiKey: apiKey, model: model, reasoningEffort: "none", timeout: 20)
        let t0 = Date()
        do {
            let r = try await f.format("um so this is uh a quick test", context: FormatContext())
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            return r.text.isEmpty ? .failed("\(model) returned no text") : .ok("\(model) answered in \(ms) ms")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Resumes a continuation at most once (first result wins).
private final class OnceBox<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func resume(_ v: T) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: v)
    }
}
