import Foundation

/// How the hotkey starts and stops dictation.
public enum ActivationStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Hold the key to talk (release pastes). A quick tap locks hands-free mode instead.
    case holdOrTap
    /// Every press toggles hands-free mode on/off.
    case toggle
    /// Only push-to-talk: hold to talk, release to paste.
    case holdOnly

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .holdOrTap: return "Hold to talk, tap for hands-free"
        case .toggle: return "Tap to start / stop (hands-free)"
        case .holdOnly: return "Hold to talk only"
        }
    }
}

public enum BubblePlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case nearCaret
    case bottomCenter
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .nearCaret: return "Next to the text cursor"
        case .bottomCenter: return "Bottom center of the screen"
        }
    }
}

/// A global shortcut.
/// - `.modifierOnly`: one modifier key on its own (Right ⌥, fn, either ⌃ …).
/// - `.modifierChord`: two or more modifiers held together (⌃⌥, ⌘⇧ …).
/// - `.combo`: a regular key plus modifiers (⌥Space, ⌃⇧D, F5 …).
public struct Hotkey: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case modifierOnly, modifierChord, combo }
    public var kind: Kind
    /// `.modifierOnly`: the modifier's key code (59 L⌃, 62 R⌃, 58 L⌥, 61 R⌥, 55 L⌘, 54 R⌘, 56 L⇧, 60 R⇧, 63 fn),
    /// or `-1` for "either Control". `.combo`: the key's virtual key code. `.modifierChord`: unused.
    public var keyCode: Int
    /// Device-independent `CGEventFlags` modifier mask (chords and combos).
    public var modifiers: UInt64
    public var display: String

    public init(kind: Kind, keyCode: Int, modifiers: UInt64, display: String) {
        self.kind = kind; self.keyCode = keyCode; self.modifiers = modifiers; self.display = display
    }

    // CGEventFlags raw values (device independent).
    public static let maskShift: UInt64 = 0x20000
    public static let maskControl: UInt64 = 0x40000
    public static let maskOption: UInt64 = 0x80000
    public static let maskCommand: UInt64 = 0x100000
    public static let maskFn: UInt64 = 0x800000
    public static let allModifiers: UInt64 = maskShift | maskControl | maskOption | maskCommand | maskFn

    public static let eitherControl = Hotkey(kind: .modifierOnly, keyCode: -1, modifiers: maskControl, display: "⌃ Control")
    public static let fn = Hotkey(kind: .modifierOnly, keyCode: 63, modifiers: maskFn, display: "fn 🌐")
    public static let rightOption = Hotkey(kind: .modifierOnly, keyCode: 61, modifiers: maskOption, display: "Right ⌥ Option")
    public static let rightCommand = Hotkey(kind: .modifierOnly, keyCode: 54, modifiers: maskCommand, display: "Right ⌘ Command")
    public static let controlOption = Hotkey(kind: .modifierChord, keyCode: 0, modifiers: maskControl | maskOption, display: "⌃⌥")
    public static let optionSpace = Hotkey(kind: .combo, keyCode: 49, modifiers: maskOption, display: "⌥ Space")
    public static let presets: [Hotkey] = [.eitherControl, .fn, .rightOption, .rightCommand, .controlOption, .optionSpace]

    /// "⌃⌥⇧⌘" style prefix for a modifier mask.
    public static func symbols(for mask: UInt64) -> String {
        var s = ""
        if mask & maskFn != 0 { s += "fn " }
        if mask & maskControl != 0 { s += "⌃" }
        if mask & maskOption != 0 { s += "⌥" }
        if mask & maskShift != 0 { s += "⇧" }
        if mask & maskCommand != 0 { s += "⌘" }
        return s
    }

    /// The modifier mask for a modifier key code.
    public static func mask(forModifierKeyCode code: Int) -> UInt64? {
        switch code {
        case 59, 62, -1: return maskControl
        case 58, 61: return maskOption
        case 55, 54: return maskCommand
        case 56, 60: return maskShift
        case 63: return maskFn
        default: return nil
        }
    }

    public static func modifierKeyName(_ code: Int) -> String {
        switch code {
        case 59: return "Left ⌃ Control"
        case 62: return "Right ⌃ Control"
        case -1: return "⌃ Control"
        case 58: return "Left ⌥ Option"
        case 61: return "Right ⌥ Option"
        case 55: return "Left ⌘ Command"
        case 54: return "Right ⌘ Command"
        case 56: return "Left ⇧ Shift"
        case 60: return "Right ⇧ Shift"
        case 63: return "fn 🌐"
        default: return "Key \(code)"
        }
    }

    /// Names for common key codes (US layout positions).
    public static func keyName(_ code: Int) -> String {
        let names: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
            13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
            35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
            107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up",
            117: "Fwd Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        return names[code] ?? "Key \(code)"
    }

    public static func isFunctionKey(_ code: Int) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90].contains(code)
    }
}

/// All user-tunable settings. Persisted as JSON in UserDefaults. The API key lives in the Keychain.
public struct OpenflowSettings: Codable, Equatable, Sendable {
    public var hotkey: Hotkey = .eitherControl
    public var activation: ActivationStyle = .holdOrTap
    /// Silence (seconds) that counts as "I stopped speaking" in hands-free mode.
    public var pauseSeconds: Double = 1.0
    /// Hands-free mode closes the mic after this much continuous silence (seconds).
    public var handsFreeIdleTimeout: Double = 120
    /// BCP-47-ish code passed to the STT model, or "" for auto-detect.
    public var language: String = ""
    /// Run the Grok 4.3 cleanup pass. Off = paste raw transcript.
    public var cleanupEnabled: Bool = true
    public var formatterModel: String = "grok-4.3"
    /// "none" or "low". Cleanup is latency-bound, so "none" is the default.
    public var reasoningEffort: String = "none"
    /// Free text about the user and their role. Sent to the formatter as context.
    public var aboutMe: String = ""
    public var customInstructions: String = ""
    /// Names, jargon, product terms. Sent to STT as `keyterm` and to the formatter as spellings.
    public var dictionary: [String] = []
    /// Send the last few words before the cursor (≤ 12 words) to Grok so a new dictation continues the
    /// previous text correctly (capitalization, joining punctuation). Never the whole field.
    public var sendRecentWords: Bool = true
    public var bubblePlacement: BubblePlacement = .nearCaret
    /// Show the words being heard, live, above the bubble. (Replaces the old `showLiveTranscript`,
    /// which defaulted to off, so existing installs get it on.)
    public var liveTranscript: Bool = true
    public var playSounds: Bool = true
    public var sttModel: String = "grok-voice-transcribe-2.0"
    /// Core Audio UID of the chosen microphone; "" = the system default input.
    public var inputDeviceUID: String = ""
    /// The setup assistant has been completed once.
    public var onboardingCompleted: Bool = false

    public init() {}

    // Tolerate older/newer JSON: missing keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        let d = OpenflowSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = (try? c.decode(Hotkey.self, forKey: .hotkey)) ?? d.hotkey
        activation = (try? c.decode(ActivationStyle.self, forKey: .activation)) ?? d.activation
        pauseSeconds = (try? c.decode(Double.self, forKey: .pauseSeconds)) ?? d.pauseSeconds
        handsFreeIdleTimeout = (try? c.decode(Double.self, forKey: .handsFreeIdleTimeout)) ?? d.handsFreeIdleTimeout
        language = (try? c.decode(String.self, forKey: .language)) ?? d.language
        cleanupEnabled = (try? c.decode(Bool.self, forKey: .cleanupEnabled)) ?? d.cleanupEnabled
        formatterModel = (try? c.decode(String.self, forKey: .formatterModel)) ?? d.formatterModel
        reasoningEffort = (try? c.decode(String.self, forKey: .reasoningEffort)) ?? d.reasoningEffort
        aboutMe = (try? c.decode(String.self, forKey: .aboutMe)) ?? d.aboutMe
        customInstructions = (try? c.decode(String.self, forKey: .customInstructions)) ?? d.customInstructions
        dictionary = (try? c.decode([String].self, forKey: .dictionary)) ?? d.dictionary
        sendRecentWords = (try? c.decode(Bool.self, forKey: .sendRecentWords)) ?? d.sendRecentWords
        bubblePlacement = (try? c.decode(BubblePlacement.self, forKey: .bubblePlacement)) ?? d.bubblePlacement
        liveTranscript = (try? c.decode(Bool.self, forKey: .liveTranscript)) ?? d.liveTranscript
        playSounds = (try? c.decode(Bool.self, forKey: .playSounds)) ?? d.playSounds
        sttModel = (try? c.decode(String.self, forKey: .sttModel)) ?? d.sttModel
        onboardingCompleted = (try? c.decode(Bool.self, forKey: .onboardingCompleted)) ?? d.onboardingCompleted
        inputDeviceUID = (try? c.decode(String.self, forKey: .inputDeviceUID)) ?? d.inputDeviceUID
    }

    private static let defaultsKey = "openflow.settings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> OpenflowSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(OpenflowSettings.self, from: data) else { return OpenflowSettings() }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Languages Grok Voice Transcribe 2.0 formats natively. Speech in other languages is still transcribed
/// with auto-detect; the code only enables number/currency formatting.
public let supportedLanguages: [(code: String, name: String)] = [
    ("", "Auto-detect (any language)"),
    ("en", "English"), ("ar", "Arabic"), ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"),
    ("fil", "Filipino"), ("fr", "French"), ("de", "German"), ("hi", "Hindi"), ("id", "Indonesian"),
    ("it", "Italian"), ("ja", "Japanese"), ("ko", "Korean"), ("mk", "Macedonian"), ("ms", "Malay"),
    ("fa", "Persian"), ("pl", "Polish"), ("pt", "Portuguese"), ("ro", "Romanian"), ("ru", "Russian"),
    ("es", "Spanish"), ("sv", "Swedish"), ("th", "Thai"), ("tr", "Turkish"), ("vi", "Vietnamese"),
]
