import Foundation
import Security

/// Where the SpaceXAI API key lives.
///
/// - Signed with an Apple Team ID (Developer ID): the login Keychain, item "Openflow" / "SpaceXAI API key".
///   macOS ties access to the Team ID, so updates keep access without prompts.
/// - Self-signed (no Team ID): a private file, `~/Library/Application Support/Openflow/api-key`
///   (mode 600 in a 700 folder, encrypted at rest by FileVault). Without a Team ID, macOS ties Keychain
///   access to each binary's hash, which would prompt "Openflow wants to access the Keychain" after every
///   update.
public enum APIKeyStore {
    static let service = AppIdentity.keychainService
    static let account = AppIdentity.keychainAccount

    /// The running app is signed with an Apple Team ID.
    public static let usesKeychain: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return !((dict[kSecCodeInfoTeamIdentifier as String] as? String) ?? "").isEmpty
    }()

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Openflow", isDirectory: true).appendingPathComponent("api-key")
    }

    /// The saved key; `XAI_API_KEY` from the environment as a fallback (handy for `swift run`).
    public static func load() -> String? {
        let env = ProcessInfo.processInfo.environment
        if env["OPENFLOW_ENV_KEY_ONLY"] == "1" { return env["XAI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } }
        if let key = usesKeychain ? read(service: service, account: account) : readFile() { return key }
        if let e = env["XAI_API_KEY"], !e.isEmpty { return e }
        return nil
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        delete()
        guard !trimmed.isEmpty else { return true }
        return usesKeychain ? saveKeychain(trimmed) : writeFile(trimmed)
    }

    public static func delete() {
        if usesKeychain { delete(service: service, account: account) }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// One-time moves, run off the main thread at launch (a Keychain read may show a single prompt):
    /// a Keychain item from an earlier self-signed build → the private file; or adopt `XAI_API_KEY` if the
    /// app was launched with it. Returns true if the stored key changed.
    @discardableResult
    public static func migrateIfNeeded() -> Bool {
        // Headless/debug runs must never touch the Keychain (an unsigned binary would trigger a prompt).
        if ProcessInfo.processInfo.environment["OPENFLOW_ENV_KEY_ONLY"] == "1" { return false }
        if usesKeychain {
            guard read(service: service, account: account) == nil else { return false }
        } else {
            guard readFile() == nil else { return false }
            if let k = read(service: service, account: account) {   // Keychain → private file
                if writeFile(k) { delete(service: service, account: account) }
                return true
            }
        }
        if let env = ProcessInfo.processInfo.environment["XAI_API_KEY"], env.hasPrefix("xai-") {
            return save(env)
        }
        return false
    }

    // MARK: File store (self-signed builds)

    private static func readFile() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    private static func writeFile(_ key: String) -> Bool {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            // Create with 600 before writing the secret, so it is never readable by others, even briefly.
            let tmp = dir.appendingPathComponent(".api-key.\(UUID().uuidString)")
            guard fm.createFile(atPath: tmp.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else { return false }
            _ = try fm.replaceItemAt(fileURL, withItemAt: tmp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    // MARK: Keychain (Developer ID builds, and migration)

    private static func saveKeychain(_ key: String) -> Bool {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Openflow",
            kSecAttrDescription as String: "SpaceXAI API key used by Openflow",
            kSecValueData as String: Data(key.utf8),
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    private static func read(service: String, account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    private static func delete(service: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }

    /// "xai-…abcd" for display.
    public static func masked(_ key: String?) -> String {
        guard let key, key.count > 8 else { return "Not set" }
        return "\(key.prefix(4))…\(key.suffix(4))"
    }

    /// Checks the key against `GET /v1/api-key`.
    public static func validate(_ key: String) async -> Result<String, Error> {
        var req = URLRequest(url: URL(string: "https://api.x.ai/v1/api-key")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let msg = [400, 401, 403].contains(code)
                    ? "SpaceXAI didn't accept this key. Check that you copied the whole key (it starts with “xai-”)."
                    : "SpaceXAI returned HTTP \(code). Try again in a moment."
                return .failure(NSError(domain: "Openflow", code: code, userInfo: [NSLocalizedDescriptionKey: msg]))
            }
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let name = obj["name"] as? String ?? "valid key"
            let blocked = (obj["api_key_blocked"] as? Bool ?? false) || (obj["api_key_disabled"] as? Bool ?? false)
            if blocked {
                return .failure(NSError(domain: "Openflow", code: 403,
                                        userInfo: [NSLocalizedDescriptionKey: "This key is blocked or disabled"]))
            }
            return .success(name)
        } catch {
            return .failure(error)
        }
    }
}
