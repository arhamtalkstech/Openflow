import Foundation

/// What kind of place the text is going, so the cleanup writes like a person would there.
public enum DestinationKind: String, Sendable {
    case email, chat, aiPrompt = "ai_prompt", document, code, terminal, general

    public static func classify(bundleID: String?, appName: String?, windowTitle: String?, fieldLabel: String?) -> DestinationKind {
        let b = bundleID ?? ""
        let title = (windowTitle ?? "").lowercased()
        let label = (fieldLabel ?? "").lowercased()
        let app = (appName ?? "").lowercased()
        func any(_ hay: String, _ needles: [String]) -> Bool { needles.contains { hay.contains($0) } }

        // AI assistants first: their prompt boxes often look like chat inputs.
        let aiApps: Set<String> = ["com.openai.chat", "com.anthropic.claudefordesktop", "ai.perplexity.mac", "com.google.GeminiMacOS"]
        let aiWords = ["chatgpt", "grok", "claude", "gemini", "perplexity", "copilot", "ask anything", "how can i help", "message chatgpt", "ask grok"]
        if aiApps.contains(b) || any(label, aiWords) || any(app, ["chatgpt", "grok", "claude", "perplexity"]) { return .aiPrompt }
        if CaretResolver.terminals.contains(b) {
            // A terminal running a coding agent is a prompt box, not a shell.
            return any(title, ["grok", "claude", "codex", "gemini", "aider", "cursor-agent", "opencode", "amp"]) ? .aiPrompt : .terminal
        }
        let isBrowser = CaretResolver.chromiumBrowsers.contains(b) || ["com.apple.Safari", "org.mozilla.firefox"].contains(b)
        if isBrowser && any(title, aiWords) { return .aiPrompt }

        let mailApps: Set<String> = ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
                                     "com.mimestream.Mimestream", "it.bloop.airmail2", "com.google.Chrome.app.fmgjjmmmlfnkbppncabfkddbjimcfncm"]
        if mailApps.contains(b) || (isBrowser && any(title, ["gmail", "outlook", "superhuman", "yahoo mail", "proton mail", "fastmail"]))
            || any(label, ["message body", "compose email"]) { return .email }

        let chatApps: Set<String> = ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord",
                                     "net.whatsapp.WhatsApp", "com.apple.MobileSMS", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop",
                                     "com.facebook.archon", "us.zoom.xos", "com.linear"]
        if chatApps.contains(b) || any(app, ["google meet", "google chat", "slack", "whatsapp", "messenger"])
            || (isBrowser && any(title, ["slack", "google chat", "whatsapp", "discord", "messenger", "microsoft teams", "meet -", "linkedin"]))
            || label.hasPrefix("message ") || any(label, ["send a message", "type a message", "write a message", "reply"]) { return .chat }

        let docApps: Set<String> = ["com.apple.Notes", "notion.id", "com.microsoft.Word", "com.apple.iWork.Pages", "md.obsidian",
                                    "com.apple.TextEdit", "net.shinyfrog.bear", "com.lukilabs.lukiapp", "com.microsoft.onenote.mac"]
        if docApps.contains(b) || (isBrowser && any(title, ["google docs", "notion", "confluence", "coda", "dropbox paper", "quip", "word"])) {
            return .document
        }

        let codeApps: Set<String> = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode",
                                     "com.sublimetext.4", "com.exafunction.windsurf"]
        if codeApps.contains(b) || b.hasPrefix("com.jetbrains.") { return .code }
        return .general
    }
}
