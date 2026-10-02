import Foundation

/// SpaceXAI text-to-speech, used by the test harness to produce realistic dictation audio.
public enum XAITTS {
    /// Returns 16 kHz mono PCM16 samples. Cached on disk by (voice, language, text).
    public static func synthesize(_ text: String, voice: String = "eve", language: String = "en",
                                  apiKey: String, cacheDir: URL? = nil) async throws -> [Int16] {
        let cacheURL = cacheDir.map { dir -> URL in
            let name = "\(voice)-\(language)-\(stableHash(text)).pcm"
            return dir.appendingPathComponent(name)
        }
        if let u = cacheURL, let data = try? Data(contentsOf: u), !data.isEmpty {
            return samples(from: data)
        }
        var req = URLRequest(url: URL(string: "https://api.x.ai/v1/tts")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "voice_id": voice,
            "language": language,
            "output_format": ["codec": "pcm", "sample_rate": 16000],
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw NSError(domain: "XAITTS", code: code, userInfo: [NSLocalizedDescriptionKey:
                "TTS HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")"])
        }
        if let u = cacheURL {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: u)
        }
        return samples(from: data)
    }

    public static func samples(from data: Data) -> [Int16] {
        let n = data.count / 2
        var out = [Int16](repeating: 0, count: n)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0, count: n * 2) }
        return out.map { Int16(littleEndian: $0) }
    }

    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
