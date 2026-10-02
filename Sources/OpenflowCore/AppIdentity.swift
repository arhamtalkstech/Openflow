import Foundation

/// The one name macOS shows for Openflow everywhere: permission prompts, System Settings lists,
/// Keychain prompts, Login Items. Keep in sync with `Resources/Info.plist` (scripts/build-app.sh checks it).
public enum AppIdentity {
    public static let name = "Openflow"
    public static let bundleID = "com.openflow.Openflow"
    /// Keychain item "Where" field, shown in Keychain prompts and Keychain Access.
    public static let keychainService = "Openflow"
    public static let keychainAccount = "SpaceXAI API key"

}
