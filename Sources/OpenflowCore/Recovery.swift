import Foundation

/// One-shot transcription of recorded audio (`POST /v1/stt`). Used to recover a dictation when the
/// streaming connection failed: the engine keeps the session's audio in memory, never on disk.
public enum STTREST {
    public static let endpoint = URL(string: "https://api.x.ai/v1/stt")!

    public static func transcribe(_ pcm: [Int16], apiKey: String, model: String = "grok-voice-transcribe-2.0",
                                  language: String = "", endpoint: URL? = nil, timeout: TimeInterval = 45) async throws -> String {
        let boundary = "openflow-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        if !language.isEmpty { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav(pcm))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: endpoint ?? Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw NSError(domain: "Openflow", code: code, userInfo: [NSLocalizedDescriptionKey: "Transcription failed (HTTP \(code))"])
        }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 16 kHz mono PCM16 → WAV.
    public static func wav(_ pcm: [Int16]) -> Data {
        let dataBytes = UInt32(pcm.count * 2)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); u32(36 + dataBytes); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(dataBytes)
        // Apple Silicon and Intel are little-endian, matching WAV: copy the samples as-is.
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// Human-readable reason for a failed request.
    public static func reason(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
                return "No internet"
            case NSURLErrorTimedOut: return "SpaceXAI timed out"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return "SpaceXAI unreachable"
            default: break
            }
        }
        return ns.code >= 400 && ns.code < 600 ? "SpaceXAI error \(ns.code)" : "Transcription failed"
    }
}

/// Something went wrong after you spoke; the bubble offers a one-click fix.
public enum DictationIssue: Equatable, Sendable {
    /// The text was ready but the paste didn't land. It stays on the clipboard.
    case pasteFailed(text: String)
    /// Speech couldn't be transcribed (offline, server error). The audio is kept in memory for a retry.
    case transcriptionFailed(reason: String)

    public var message: String {
        switch self {
        case .pasteFailed: return "Didn't paste · copied"
        case .transcriptionFailed(let r): return r
        }
    }

    public var actionTitle: String {
        switch self {
        case .pasteFailed: return "Paste"
        case .transcriptionFailed: return "Retry"
        }
    }
}

/// Result of an insertion attempt, checked against the field afterwards where the app exposes its text.
public enum InsertOutcome: Sendable, Equatable {
    /// The field changed after the paste.
    case inserted
    /// The app doesn't expose its text (e.g. Google Docs); assume it landed.
    case unverified
    /// The field didn't change, even after a second paste. The text is left on the clipboard.
    case failed
}
