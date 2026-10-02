import Combine
import Foundation
import OpenflowCore

// openflow-cli — drives the real DictationEngine with SpaceXAI TTS audio streamed in real time.
//
//   XAI_API_KEY=… swift run openflow-cli suite [--only name,name] [--pause 1.0] [--effort none]
//   XAI_API_KEY=… swift run openflow-cli say "text to speak" [--voice eve] [--lang en] [--ptt]
//   XAI_API_KEY=… swift run openflow-cli format "raw transcript text"
//   XAI_API_KEY=… swift run openflow-cli check-key [key]   (what onboarding verifies)

// MARK: - Simulated text field

@MainActor
final class FieldInserter: TextInserting {
    /// Simulated text field: `field` with an optional selected range.
    var field: String
    var selection: Range<String.Index>?
    var inserts: [String] = []
    var actions: [InsertAction] = []
    let appName: String
    let bundleID: String
    var info: FieldInfo?
    init(initialText: String = "", selectAll: Bool = false, appName: String = "Notes", bundleID: String = "com.apple.Notes",
         info: FieldInfo? = nil) {
        field = initialText; self.appName = appName; self.bundleID = bundleID; self.info = info
        if selectAll && !initialText.isEmpty { selection = field.startIndex..<field.endIndex }
    }
    func captureContext(includeFieldText: Bool) -> InsertionContext {
        let before = selection.map { String(field[..<$0.lowerBound]) } ?? field
        return InsertionContext(appName: appName, bundleID: bundleID, textBeforeCursor: includeFieldText ? before : nil,
                                field: info)
    }
    func captureSelection() -> String? { selection.map { String(field[$0]) } }
    /// Simulate pastes that don't land (the app ignores ⌘V) for the first N attempts.
    var failPastes = 0
    func insert(_ text: String, action: InsertAction, pastedEarlierInSession: Bool,
                completion: ((InsertOutcome) -> Void)?) -> String {
        if failPastes > 0 {
            failPastes -= 1
            DispatchQueue.main.async { completion?(.failed) }
            return text
        }
        defer { DispatchQueue.main.async { completion?(.inserted) } }
        inserts.append(text); actions.append(action)
        if let sel = selection {
            selection = nil
            if action == .replaceSelection {
                field.replaceSubrange(sel, with: text)
                return text
            }
            // Collapse to the end of the selection, then insert there.
            let before = String(field[..<sel.upperBound])
            let s = SmartSpacing.prefix(before: before, insertion: text, pastedEarlierInSession: true) + text
            field.insert(contentsOf: s, at: sel.upperBound)
            return s
        }
        let s = SmartSpacing.prefix(before: field, insertion: text, pastedEarlierInSession: pastedEarlierInSession) + text
        field += s
        return s
    }
}

// MARK: - Scenarios

enum Seg {
    case speech(String, voice: String, lang: String)
    case silence(Int)
}

struct Scenario {
    var name: String
    var about: String
    var segments: [Seg]
    var mode: DictationEngine.Mode = .handsFree
    var expectPastes: Int? = nil
    var mustContain: [String] = []
    var mustNotContain: [String] = []
    var expectListLines: Int = 0
    var maxLatencyMs: Int = 3500
    var configure: ((inout OpenflowSettings) -> Void)? = nil
    var app: (String, String) = ("Notes", "com.apple.Notes")
    /// Pre-existing field text, fully selected when dictation starts.
    var selectedField: String? = nil
    /// Pre-existing field text with the cursor at its end (no selection).
    var initialField: String? = nil
    var expectAction: InsertAction? = nil
    /// Checks against the final field contents (after insertion).
    var fieldMustContain: [String] = []
    var fieldMustNotContain: [String] = []
    /// Case-sensitive regexes over the final field contents.
    var fieldMustMatch: [String] = []
    /// Field type, label, and window title the "app" reports.
    var fieldInfo: FieldInfo? = nil
    var expectNoList = false
    var expectSingleLine = false
    /// Regexes (dot matches newlines off; ^/$ anchor the whole output).
    var mustMatch: [String] = []
    var mustNotMatch: [String] = []
    // Failure simulation
    var sttEndpoint: URL? = nil
    var restEndpoint: URL? = nil
    var failPastes = 0
    /// Expected issue after the session ("pasteFailed" / "transcriptionFailed"); then the bubble button is pressed.
    var expectIssue: String? = nil
    var expectNoAudioFlag = false
    var expectOfflineFlag = false
}

func sp(_ t: String, _ voice: String = "eve", _ lang: String = "en") -> Seg { .speech(t, voice: voice, lang: lang) }

let scenarios: [Scenario] = [
    Scenario(name: "self-correction",
             about: "Speaker changes their mind mid-sentence; only the final intent should be pasted.",
             segments: [.silence(400), sp("Hey Sarah, um, I wanted to follow up on the contract. Can we meet on Thursday at three, no wait, actually let's do Friday at four PM. Thanks!", "ara"), .silence(2500)],
             expectPastes: 1, mustContain: ["Friday", "4"], mustNotContain: ["Thursday", "no wait"],
             app: ("Mail", "com.apple.mail")),
    Scenario(name: "spoken-list",
             about: "Enumerated items become a list.",
             segments: [.silence(400), sp("Okay so here's what we need to do for the launch. First, finish the pricing page. Second, update the docs. And third, send the announcement email to all customers.", "rex"), .silence(2500)],
             expectPastes: 1, mustContain: ["pricing page", "docs", "announcement email"], expectListLines: 3,
             app: ("Notion", "notion.id")),
    Scenario(name: "scratch-that",
             about: "\"Scratch that\" removes the previous sentence.",
             segments: [.silence(400), sp("Let's ship it tonight. Actually, scratch that. Let's ship it tomorrow morning after the QA pass.", "sal"), .silence(2500)],
             expectPastes: 1, mustContain: ["tomorrow morning"], mustNotContain: ["tonight", "scratch"],
             app: ("Slack", "com.tinyspeck.slackmacgap")),
    Scenario(name: "resume-before-paste",
             about: "Speaker pauses long enough that cleanup has already started (speculatively), then keeps talking before the paste: the paste must be cancelled and both halves pasted together once.",
             segments: [.silence(400), sp("So the plan for next week is pretty simple.", "leo"), .silence(850),
                        sp("We focus on onboarding and nothing else.", "leo"), .silence(2500)],
             expectPastes: 1, mustContain: ["plan for next week", "onboarding"]),
    Scenario(name: "append-after-paste",
             about: "Hands-free keeps listening: a long pause pastes, the next sentence is pasted after it, the first paste is untouched.",
             segments: [.silence(400), sp("The build is green on main.", "eve"), .silence(3000),
                        sp("Deploying to staging now, I'll ping you when it's live.", "eve"), .silence(2500)],
             expectPastes: 2, mustContain: ["build is green", "staging"],
             app: ("Slack", "com.tinyspeck.slackmacgap")),
    Scenario(name: "question-not-answered",
             about: "Dictated questions are cleaned up, not answered.",
             segments: [.silence(400), sp("What's the best way to reverse a linked list in Python? I need to explain it to the new intern tomorrow.", "ara"), .silence(2500)],
             expectPastes: 1, mustContain: ["linked list", "?", "intern"], mustNotContain: ["def ", "prev", "None"],
             app: ("Messages", "com.apple.MobileSMS")),
    Scenario(name: "push-to-talk",
             about: "Hold-to-talk: a mid-sentence pause must not paste; one paste on release.",
             segments: [.silence(300), sp("I think we should move the offsite to October.", "rex"), .silence(1600),
                        sp("Mostly because half the team is traveling in September.", "rex"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["October", "September"]),
    Scenario(name: "about-me-context",
             about: "Free-text \"about me\" + dictionary steer names and product spellings.",
             segments: [.silence(400), sp("Tell Priya that the Openflow demo for the Atlas team is ready, and loop in Joaquín.", "eve"), .silence(2500)],
             expectPastes: 1, mustContain: ["Priya", "Openflow", "Atlas", "Joaquín"],
             configure: { s in
                 s.aboutMe = "I'm Sam Lee, a product manager at Northwind. Teammates: Priya Raman (design), Joaquín Ortega (engineering). We build Openflow and Atlas."
                 s.dictionary = ["Openflow", "Atlas", "Priya Raman", "Joaquín Ortega"]
             },
             app: ("Slack", "com.tinyspeck.slackmacgap")),
    Scenario(name: "spanish-correction",
             about: "Spanish, auto-detected, with a self-correction.",
             segments: [.silence(400), sp("Hola equipo, la reunión es el martes, no, perdón, el miércoles a las diez de la mañana.", "ara", "es-MX"), .silence(2500)],
             expectPastes: 1, mustContain: ["miércoles"], mustNotContain: ["martes", "perdón"]),
    Scenario(name: "german-list",
             about: "German enumeration becomes a list; no translation.",
             segments: [.silence(400), sp("Hallo zusammen, wir brauchen drei Dinge: erstens die neue Preisliste, zweitens die Dokumentation, und drittens die E-Mail an die Kunden.", "rex", "de"), .silence(2500)],
             expectPastes: 1, mustContain: ["Preisliste", "Dokumentation", "Kunden"], expectListLines: 3),
    Scenario(name: "hindi-correction",
             about: "Hindi in Devanagari with a correction (3 o'clock → 4 o'clock).",
             segments: [.silence(400), sp("नमस्ते टीम, कल की मीटिंग दोपहर तीन बजे है, नहीं रुको, चार बजे है।", "ara", "hi"), .silence(2500)],
             expectPastes: 1, mustContain: ["बजे"], mustNotContain: ["तीन", "3 बजे", "Meeting"]),
    Scenario(name: "japanese-correction",
             about: "Japanese with a correction (10 → 11 o'clock).",
             segments: [.silence(400), sp("明日の会議は十時からです。いや、やっぱり十一時からにしましょう。", "eve", "ja"), .silence(2500)],
             expectPastes: 1, mustContain: ["会議"], mustNotContain: ["十時から", "10時から", "いや"]),
    Scenario(name: "hinglish-code-switch",
             about: "Mixed Hindi/English stays mixed; nothing gets translated.",
             segments: [.silence(400), sp("Yaar, kal ka demo bahut accha gaya, client ne bola they want the pilot by next Friday.", "eve", "auto"), .silence(2500)],
             expectPastes: 1, mustContain: ["pilot", "Friday"], mustNotContain: ["yesterday", "said"],
             app: ("WhatsApp", "net.whatsapp.WhatsApp")),
    Scenario(name: "custom-instructions-hinglish",
             about: "Custom instruction: write Hindi in Latin script (how people actually type Hinglish).",
             segments: [.silence(400), sp("Yaar, kal ka demo bahut accha gaya, client ne bola they want the pilot by next Friday.", "eve", "auto"), .silence(2500)],
             expectPastes: 1, mustContain: ["demo", "kal", "pilot", "Friday"],
             configure: { s in s.customInstructions = "When I speak Hindi, write it in romanized Latin script (Hinglish), the way I type on WhatsApp. Never use Devanagari." },
             app: ("WhatsApp", "net.whatsapp.WhatsApp")),
    Scenario(name: "spoken-formatting-commands",
             about: "\"New line\" / \"new paragraph\" are applied, not typed.",
             segments: [.silence(400), sp("Grocery list. New line. Milk. New line. Eggs. New line. Sourdough bread.", "sal"), .silence(2500)],
             expectPastes: 1, mustContain: ["Milk", "Eggs", "Sourdough"], mustNotContain: ["New line", "new line"]),
    Scenario(name: "selection-edit",
             about: "Select text, speak an instruction: the selection is rewritten in place.",
             segments: [.silence(400), sp("Make this a bulleted list and fix the typo.", "ara"), .silence(2500)],
             expectPastes: 1, expectListLines: 3,
             app: ("Notes", "com.apple.Notes"),
             selectedField: "Q3 roadmap: ship the pricing page, update the docs, emaill the customers",
             expectAction: .replaceSelection,
             fieldMustContain: ["Q3 roadmap", "pricing page", "docs", "email"], fieldMustNotContain: ["emaill", "bulleted"]),
    Scenario(name: "selection-add",
             about: "Select text, dictate an addition: the selection stays, new text goes right after it.",
             segments: [.silence(400), sp("By the way, I also fixed the login bug this morning, so we're unblocked.", "eve"), .silence(2500)],
             expectPastes: 1,
             app: ("Slack", "com.tinyspeck.slackmacgap"),
             selectedField: "We shipped the new onboarding flow yesterday.",
             expectAction: .insertAfterSelection,
             fieldMustContain: ["We shipped the new onboarding flow yesterday.", "login bug"]),
    Scenario(name: "ai-chat-paused-list",
             about: "Repro of a real dictation: a prompt to an AI chat in Chrome, items said with pauses → bullets, not answered.",
             segments: [.silence(300), sp("Can you help me build like a bullet list, so just in general? Talk to me about the shopping grocery list. Help me buy", "eve"),
                        .silence(850), sp("eggs", "eve"), .silence(850), sp("banana", "eve"), .silence(850), sp("milk", "eve"),
                        .silence(750), sp("and so on.", "eve"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["eggs", "banana", "milk", "list"], mustNotContain: ["Here's", "Sure"],
             expectListLines: 3, app: ("Google Chrome", "com.google.Chrome"),
             fieldInfo: FieldInfo(kind: .multiLine, label: "Ask anything", windowTitle: "Grok")),
    Scenario(name: "paused-items-become-list",
             about: "No \"list\" word: short items said one by one with pauses become a list.",
             segments: [.silence(300), sp("Things to pack for Lisbon", "ara"), .silence(850), sp("passport", "ara"), .silence(850),
                        sp("phone charger", "ara"), .silence(850), sp("sunscreen", "ara"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["passport", "charger", "sunscreen"], expectListLines: 3,
             fieldInfo: FieldInfo(kind: .multiLine, label: nil, windowTitle: "Packing")),
    Scenario(name: "inline-items-stay-inline",
             about: "Items mentioned in passing in one flowing sentence are not turned into a list.",
             segments: [.silence(300), sp("I grabbed eggs, milk and bread on the way home, so we're good for breakfast tomorrow.", "sal"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["eggs", "milk", "bread"], app: ("Slack", "com.tinyspeck.slackmacgap"),
             fieldInfo: FieldInfo(kind: .multiLine, label: "Message #general", windowTitle: "general - Slack"), expectNoList: true),
    Scenario(name: "single-line-field-no-breaks",
             about: "Paused items in a single-line search box stay on one line.",
             segments: [.silence(300), sp("flights to", "rex"), .silence(800), sp("Lisbon", "rex"), .silence(800), sp("Porto", "rex"),
                        .silence(800), sp("and Madrid in May", "rex"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["Lisbon", "Porto", "Madrid"], app: ("Google Chrome", "com.google.Chrome"),
             fieldInfo: FieldInfo(kind: .singleLine, label: "Search flights", windowTitle: "Google Flights"), expectSingleLine: true),
    Scenario(name: "correction-15th-to-16th",
             about: "A date changed mid-sentence: only the final value survives.",
             segments: [.silence(300), sp("Hey, by the way, can you move the launch review to the 15th? No, actually, do it the 16th.", "rex"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["16th", "launch review"], mustNotContain: ["15th", "No, actually"],
             app: ("Slack", "com.tinyspeck.slackmacgap")),
    Scenario(name: "correction-several-values",
             about: "Place and time each corrected, the time twice: last values win.",
             segments: [.silence(300), sp("Let's meet at Starbucks, sorry, Blue Bottle, at three, no, four, actually five.", "ara"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["Blue Bottle", "5"], mustNotContain: ["Starbucks", "at 3", "at 4", "three", "four"],
             app: ("Messages", "com.apple.MobileSMS")),
    Scenario(name: "style-email",
             about: "Rambling speech into Mail reads like a written email: greeting line, paragraphs, sign-off.",
             segments: [.silence(300), sp("hi Priya, so um I wanted to give you a quick update on the pilot. basically the team finished the integration yesterday and we're now testing it with real traffic, and I think we'll have results by Friday. let me know if you want to join the review call. thanks, Sam", "eve"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["integration", "Friday", "review call", "Sam"],
             mustNotContain: ["basically", " um", "so um", "Sam."],
             configure: { s in s.aboutMe = "I'm Sam Lee, a product manager at Northwind. I work with Priya Raman on customer pilots." },
             app: ("Mail", "com.apple.mail"),
             fieldInfo: FieldInfo(kind: .multiLine, label: "Message Body", windowTitle: "Pilot update"),
             mustMatch: ["^Hi Priya,\\n\\n", "\\n\\n.+", "\\n(Thanks|Thank you)[,!]?\\n+Sam( Lee)?\\s*$"]),
    Scenario(name: "style-slack",
             about: "The same speech into Slack reads like a chat message: inline greeting, no email layout.",
             segments: [.silence(300), sp("hi Priya, so um I wanted to give you a quick update on the pilot. basically the team finished the integration yesterday and we're now testing it with real traffic, and I think we'll have results by Friday. let me know if you want to join the review call. thanks, Sam", "eve"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["integration", "Friday", "review call"],
             mustNotContain: ["basically", " um", "Dear"], app: ("Slack", "com.tinyspeck.slackmacgap"),
             fieldInfo: FieldInfo(kind: .multiLine, label: "Message Priya Raman", windowTitle: "Priya Raman (DM) - Slack"),
             mustNotMatch: ["^(Hi|Hey) Priya,\\n", "\\n\\n(Thanks|Best)"]),
    Scenario(name: "style-ai-prompt-in-terminal",
             about: "Talking to a coding agent in Terminal: a clean first-person prompt, tics removed, not answered.",
             segments: [.silence(300), sp("okay so basically I want you to refactor the caret resolver so it always trusts the accessibility caret, and like, add tests for the terminal case, you know?", "rex"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["refactor", "caret", "tests", "terminal"],
             mustNotContain: ["basically", "you know", "like,", "okay so", "Here"], app: ("Terminal", "com.apple.Terminal"),
             fieldInfo: FieldInfo(kind: .multiLine, label: nil, windowTitle: "Openflow — grok — 160×48")),
    Scenario(name: "style-notes-prose",
             about: "A rambling thought in Notes becomes clean written prose with nothing dropped.",
             segments: [.silence(300), sp("so I've been thinking about the onboarding, and basically the main problem is people don't get the API key step, like they paste the wrong thing, so we should probably validate it right there and show a really clear error.", "sal"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["onboarding", "API key", "validate", "error"],
             mustNotContain: ["basically", "like they", "So I've"], app: ("Notes", "com.apple.Notes"),
             fieldInfo: FieldInfo(kind: .multiLine, label: nil, windowTitle: "Notes"), mustMatch: ["[Pp]robably"]),
    Scenario(name: "continue-after-full-stop",
             about: "Reported bug: a second dictation after \"…3 PM.\" must start with a space and a capital.",
             segments: [.silence(300), sp("Actually, beyond that, you should also try considering the latest product, which is the Voice AI product.", "rex"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, app: ("Terminal", "com.apple.Terminal"),
             initialField: "Hey, I think I'll meet you tomorrow at 3 PM.",
             fieldMustContain: ["Voice AI product"], fieldMustNotContain: [". Which is", ". which is"],
             fieldMustMatch: ["^Hey, I think I'll meet you tomorrow at 3 PM\\. Actually, beyond that", "^(?!.*Hey, I think.*Hey, I think)"],
             fieldInfo: FieldInfo(kind: .multiLine, label: nil, windowTitle: "Openflow — grok — 160×48")),
    Scenario(name: "continue-mid-sentence",
             about: "Previous text ends mid-sentence: continue in lowercase with one space.",
             segments: [.silence(300), sp("and the demo laptop.", "ara"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, app: ("Notes", "com.apple.Notes"),
             initialField: "For tomorrow I'll bring the slides",
             fieldMustMatch: ["^For tomorrow I'll bring the slides and the demo laptop"],
             fieldInfo: FieldInfo(kind: .multiLine, label: nil, windowTitle: "Notes")),
    Scenario(name: "new-sentence-after-unpunctuated",
             about: "Previous chat line has no full stop and the new dictation is a new sentence: the join gets punctuation.",
             segments: [.silence(300), sp("Also, can you bring the deck?", "eve"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, app: ("Slack", "com.tinyspeck.slackmacgap"),
             initialField: "See you at 3",
             fieldMustMatch: ["^See you at 3(\\. Also|! Also|, also)"],
             fieldInfo: FieldInfo(kind: .multiLine, label: "Message Priya Raman", windowTitle: "Priya Raman (DM) - Slack"),
             mustMatch: []),
    Scenario(name: "no-audio-then-speech",
             about: "2.6 s of silence shows \"No audio detected\"; it clears as soon as the speaker talks, and the paste is normal.",
             segments: [.silence(2600), sp("Okay, now I'm talking. Please confirm the booking for Friday.", "eve"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["booking", "Friday"], expectNoAudioFlag: true),
    Scenario(name: "offline-recovers-from-audio",
             about: "Streaming connection unreachable: keeps recording, then transcribes the kept audio at stop and pastes it.",
             segments: [.silence(300), sp("The quarterly numbers look strong, let's share them with the board on Monday.", "rex"), .silence(300)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["quarterly", "board", "Monday"],
             sttEndpoint: URL(string: "wss://127.0.0.1:9/v1/stt"), expectOfflineFlag: true),
    Scenario(name: "offline-retry-later",
             about: "Fully offline: the bubble offers Retry with the audio kept in memory; Retry (network back) pastes it.",
             segments: [.silence(300), sp("Remind me to renew the domain before it expires next week.", "ara"), .silence(300)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["renew", "domain", "next week"],
             sttEndpoint: URL(string: "wss://127.0.0.1:9/v1/stt"), restEndpoint: URL(string: "https://127.0.0.1:9/v1/stt"), expectIssue: "transcriptionFailed", expectOfflineFlag: true),
    Scenario(name: "paste-did-not-land",
             about: "The app ignored the paste: no fake success; the bubble offers Paste, which lands the text.",
             segments: [.silence(300), sp("Ship it after lunch.", "sal"), .silence(250)],
             mode: .pushToTalk, expectPastes: 1, mustContain: ["Ship it after lunch"],
             failPastes: 1, expectIssue: "pasteFailed"),
    Scenario(name: "numbers-and-email",
             about: "Numbers, money, and spoken email addresses in written form.",
             segments: [.silence(400), sp("The invoice is two thousand four hundred and fifty dollars, please send it to billing at acme dot com by the fifteenth.", "rex"), .silence(2500)],
             expectPastes: 1, mustContain: ["$2,450", "billing@acme.com", "15"], mustNotContain: ["dot com"],
             app: ("Mail", "com.apple.mail")),
]

// MARK: - Runner

struct Outcome {
    var name: String
    var pass: Bool
    var notes: [String]
    var pastes: [String]
    var field: String
    var latencies: [Int]
    var formatterMs: [Int]
    var costTicks: Int64
    var audioSeconds: Double
}

func noise(_ n: Int, amplitude: Double = 90) -> [Int16] {
    (0..<n).map { _ in Int16(max(-32767, min(32767, Double.random(in: -1...1) * amplitude))) }
}

@MainActor
func run(_ sc: Scenario, key: String, pause: Double, effort: String, cacheDir: URL, verbose: Bool,
         sharedUsage: UsageStore? = nil) async throws -> Outcome {
    // 1. Synthesize audio for every speech segment (SpaceXAI TTS, 16 kHz PCM).
    var audio: [Int16] = []
    for seg in sc.segments {
        switch seg {
        case let .speech(text, voice, lang):
            let pcm = try await XAITTS.synthesize(text, voice: voice, language: lang, apiKey: key, cacheDir: cacheDir)
            audio += pcm.map { s in Int16(clamping: Int(s) + Int.random(in: -90...90)) }
        case let .silence(ms):
            audio += noise(16 * ms)
        }
    }

    // 2. Engine wired exactly like the app, but pasting into a simulated text field.
    var settings = OpenflowSettings()
    settings.pauseSeconds = pause
    settings.reasoningEffort = effort
    sc.configure?(&settings)
    let engine = DictationEngine(settings: settings, apiKeyProvider: { key })
    let field = FieldInserter(initialText: sc.selectedField ?? sc.initialField ?? "", selectAll: sc.selectedField != nil,
                              appName: sc.app.0, bundleID: sc.app.1, info: sc.fieldInfo)
    engine.inserter = field
    let usageURL = FileManager.default.temporaryDirectory.appendingPathComponent("openflow-cli-usage-\(UUID().uuidString).json")
    let usage = sharedUsage ?? UsageStore(fileURL: usageURL)
    engine.usage = usage
    var records: [DictationRecord] = []
    engine.onPasted = { records.append($0) }
    engine.sttEndpoint = sc.sttEndpoint
    engine.restEndpoint = sc.restEndpoint
    field.failPastes = sc.failPastes
    var sawNoAudio = false, sawOffline = false, noAudioClearedWhileListening = false
    var bag: Set<AnyCancellable> = []
    engine.$noAudio.sink { v in
        if v { sawNoAudio = true } else if sawNoAudio && engine.isActive { noAudioClearedWhileListening = true }
    }.store(in: &bag)
    engine.$offline.sink { if $0 { sawOffline = true } }.store(in: &bag)
    var ended = false
    engine.onSessionEnded = { ended = true }
    var captureStopped = false
    engine.onCaptureShouldStop = { captureStopped = true }
    let t0 = ProcessInfo.processInfo.systemUptime
    engine.trace = { msg in
        if verbose { print(String(format: "    [%6.2fs] %@", ProcessInfo.processInfo.systemUptime - t0, msg)) }
    }

    guard engine.start(mode: sc.mode) else { throw NSError(domain: "cli", code: 1) }

    // 3. Stream in real time, 100 ms frames, like the microphone.
    let frame = 1600
    var i = 0
    while i < audio.count {
        let end = min(i + frame, audio.count)
        engine.feed(Array(audio[i..<end]))
        i = end
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    // 4. User ends the session (tap hotkey / release key). Keep the mic running briefly, like the app.
    engine.stop()
    var tail = 0
    while !captureStopped && tail < 3 { engine.feed(noise(frame)); tail += 1; try await Task.sleep(nanoseconds: 100_000_000) }
    let deadline = ProcessInfo.processInfo.systemUptime + 40
    while !ended && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    try? FileManager.default.removeItem(at: usageURL)

    // Failure flow: the bubble shows the issue; press its button (with the network back) and wait for the paste.
    var issueNote: String?
    if let want = sc.expectIssue {
        try await Task.sleep(nanoseconds: 1_500_000_000)  // paste checks report a moment after the paste
        let got: String
        switch engine.issue {
        case .pasteFailed?: got = "pasteFailed"
        case .transcriptionFailed?: got = "transcriptionFailed"
        case nil: got = "none"
        }
        if got != want { issueNote = "expected issue \(want), got \(got)" }
        if verbose { print("    issue: \(engine.issue.map { "\($0.message) [\($0.actionTitle)]" } ?? "none")") }
        engine.restEndpoint = nil
        let before = field.inserts.count
        engine.resolveIssue()
        let d2 = ProcessInfo.processInfo.systemUptime + 40
        while field.inserts.count == before && ProcessInfo.processInfo.systemUptime < d2 { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    // 5. Checks.
    var notes: [String] = []
    if let n = issueNote { notes.append(n) }
    if sc.expectNoAudioFlag && !sawNoAudio { notes.append("\"no audio\" was never shown") }
    if sc.expectNoAudioFlag && !noAudioClearedWhileListening { notes.append("\"no audio\" did not clear when speech started") }
    if sc.expectOfflineFlag && !sawOffline { notes.append("offline state was never shown") }
    if sc.expectIssue == nil && engine.issue != nil { notes.append("unexpected issue: \(engine.issue!.message)") }
    let all = field.inserts.joined(separator: "\n")
    if !ended { notes.append("session did not end") }
    if let n = sc.expectPastes, field.inserts.count != n { notes.append("expected \(n) paste(s), got \(field.inserts.count)") }
    for s in sc.mustContain where !all.localizedCaseInsensitiveContains(s) { notes.append("missing “\(s)”") }
    for s in sc.mustNotContain where all.localizedCaseInsensitiveContains(s) { notes.append("should not contain “\(s)”") }
    if sc.expectListLines > 0 {
        let lines = all.split(separator: "\n").filter { SmartSpacing.isListLine(String($0)) }.count
        if lines < sc.expectListLines { notes.append("expected ≥\(sc.expectListLines) list lines, got \(lines)") }
    }
    func matches(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: all, range: NSRange(all.startIndex..., in: all)) != nil
    }
    for p in sc.mustMatch where !matches(p) { notes.append("should match /\(p)/") }
    for p in sc.mustNotMatch where matches(p) { notes.append("should not match /\(p)/") }
    let listLines = all.split(separator: "\n").filter { SmartSpacing.isListLine(String($0)) }.count
    if sc.expectNoList && listLines > 0 { notes.append("expected no list, got \(listLines) list lines") }
    if sc.expectSingleLine && all.contains("\n") { notes.append("single-line field got a line break") }
    if let a = sc.expectAction, field.actions.first != a {
        notes.append("expected action \(a.rawValue), got \(field.actions.first?.rawValue ?? "none")")
    }
    for s in sc.fieldMustContain where !field.field.localizedCaseInsensitiveContains(s) { notes.append("field missing “\(s)”") }
    for s in sc.fieldMustNotContain where field.field.localizedCaseInsensitiveContains(s) { notes.append("field should not contain “\(s)”") }
    for p in sc.fieldMustMatch where (try? NSRegularExpression(pattern: p))?.firstMatch(in: field.field, range: NSRange(field.field.startIndex..., in: field.field)) == nil {
        notes.append("field should match /\(p)/")
    }
    let lats = records.map(\.latencyMs)
    if sc.mode == .handsFree, let worst = lats.max(), worst > sc.maxLatencyMs + Int(pause * 1000) {
        notes.append("slow: \(worst) ms speech-end → paste")
    }
    return Outcome(name: sc.name, pass: notes.isEmpty, notes: notes, pastes: field.inserts, field: field.field,
                   latencies: lats, formatterMs: records.map(\.formatterMs),
                   costTicks: records.reduce(0) { $0 + $1.llmCostTicks }, audioSeconds: Double(audio.count) / 16000)
}

// MARK: - Entry

func arg(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

@main
struct CLI {
    @MainActor
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "caret-selftest" { exit(caretSelfTest() ? 0 : 1) }
        if args.first == "hedge-selftest" { exit(await hedgeSelfTest() ? 0 : 1) }
        if args.first == "spacing-selftest" { exit(spacingSelfTest() ? 0 : 1) }
        guard let key = ProcessInfo.processInfo.environment["XAI_API_KEY"], !key.isEmpty else {
            FileHandle.standardError.write("Set XAI_API_KEY\n".data(using: .utf8)!)
            exit(2)
        }
        let cacheDir = URL(fileURLWithPath: arg("--cache", args) ?? ".cache/tts")
        let pause = Double(arg("--pause", args) ?? "") ?? 1.0
        let effort = arg("--effort", args) ?? "none"
        let verbose = args.contains("-v")
        let cmd = args.first ?? "suite"

        switch cmd {
        case "caret-selftest":
            exit(caretSelfTest() ? 0 : 1)

        case "check-key":
            // Same check the onboarding runs: key valid, STT reachable, grok-4.3 reachable.
            let k = args.dropFirst().first { !$0.hasPrefix("-") } ?? key
            let r = await KeyCheck.run(apiKey: k)
            for (label, st) in [("API key", r.key), ("Speech to text", r.speechToText), ("Grok cleanup", r.cleanup)] {
                switch st {
                case .ok(let m): print("✅ \(label): \(m)")
                case .failed(let m): print("❌ \(label): \(m)")
                }
            }
            exit(r.allOK ? 0 : 1)

        case "join-probe":
            // Repeats one cleanup with text already before the cursor; prints model output vs. final text.
            let n = Int(arg("--n", args) ?? "") ?? 20
            let raw = "Deploying to staging now, I'll ping you when it's live."
            let ctx = FormatContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                    textBeforeCursor: "The build is green on main.",
                                    pastedThisSession: ["The build is green on main."],
                                    spokenParts: args.contains("--parts") ? ["Deploying to staging now,", "I'll ping you when it's live."] : [])
            let f = GrokFormatter(apiKey: key)
            var bad = 0
            await withTaskGroup(of: FormatResult?.self) { g in
                for _ in 0..<n { g.addTask { try? await f.format(raw, context: ctx) } }
                for await r in g {
                    guard let r else { print("error"); continue }
                    let lost = !r.text.localizedCaseInsensitiveContains("staging")
                    if lost { bad += 1 }
                    print("\(lost ? "❌" : "✅") model=\(String(reflecting: r.modelText))\n   final=\(String(reflecting: r.text))")
                }
            }
            print("lost clause in \(bad)/\(n)")

        case "format":
            let raw = args.dropFirst().first { !$0.hasPrefix("-") } ?? ""
            let f = GrokFormatter(apiKey: key, reasoningEffort: effort)
            let t0 = Date()
            do {
                let r = try await f.format(raw, context: FormatContext(appName: "Notes"))
                print(r.text)
                print(String(format: "\n(%.0f ms, $%.6f)", Date().timeIntervalSince(t0) * 1000, Double(r.costTicks) / ticksPerUSD))
            } catch { print("error: \(error)"); exit(1) }

        case "say":
            let text = args.dropFirst().first { !$0.hasPrefix("-") } ?? "Hello from Openflow."
            let sc = Scenario(name: "say", about: "ad hoc",
                              segments: [.silence(400), sp(text, arg("--voice", args) ?? "eve", arg("--lang", args) ?? "en"), .silence(2500)],
                              mode: args.contains("--ptt") ? .pushToTalk : .handsFree)
            do {
                let o = try await run(sc, key: key, pause: pause, effort: effort, cacheDir: cacheDir, verbose: true)
                print("\nField now contains:\n\(o.field)")
            } catch { print("error: \(error)"); exit(1) }

        case "suite":
            let only = arg("--only", args).map { Set($0.split(separator: ",").map(String.init)) }
            let chosen = scenarios.filter { only == nil || only!.contains($0.name) }
            var outcomes: [Outcome] = []
            // `--usage-out path`: keep the real stats of this run (the app can display them via --usage-file).
            let sharedUsage = arg("--usage-out", args).map { UsageStore(fileURL: URL(fileURLWithPath: $0)) }
            print("Openflow suite — \(chosen.count) scenarios, pause=\(pause)s, cleanup=grok-4.3 effort=\(effort)\n")
            for sc in chosen {
                print("▶ \(sc.name): \(sc.about)")
                do {
                    let o = try await run(sc, key: key, pause: pause, effort: effort, cacheDir: cacheDir, verbose: verbose,
                                         sharedUsage: sharedUsage)
                    outcomes.append(o)
                    for (n, p) in o.pastes.enumerated() {
                        print("  paste \(n + 1) (\(o.latencies[safe: n].map { "\($0) ms" } ?? "?"), cleanup \(o.formatterMs[safe: n].map { "\($0) ms" } ?? "?")):")
                        print(p.split(separator: "\n", omittingEmptySubsequences: false).map { "    │ \($0)" }.joined(separator: "\n"))
                    }
                    if sc.selectedField != nil || sc.initialField != nil {
                        print("  field after:")
                        print(o.field.split(separator: "\n", omittingEmptySubsequences: false).map { "    ┃ \($0)" }.joined(separator: "\n"))
                    }
                    print(o.pass ? "  ✅ pass" : "  ❌ \(o.notes.joined(separator: "; "))")
                } catch {
                    print("  ❌ error: \(error.localizedDescription)")
                    outcomes.append(Outcome(name: sc.name, pass: false, notes: ["\(error)"], pastes: [], field: "",
                                            latencies: [], formatterMs: [], costTicks: 0, audioSeconds: 0))
                }
                print("")
            }
            sharedUsage?.saveNow()
            let lats = outcomes.flatMap(\.latencies).sorted()
            let fmts = outcomes.flatMap(\.formatterMs).sorted()
            let llm = Double(outcomes.reduce(0) { $0 + $1.costTicks }) / ticksPerUSD
            let audio = outcomes.reduce(0) { $0 + $1.audioSeconds }
            func pct(_ a: [Int], _ p: Double) -> Int { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * p))] }
            print("──────── summary ────────")
            print("passed \(outcomes.filter(\.pass).count)/\(outcomes.count)")
            for o in outcomes where !o.pass { print("  ❌ \(o.name): \(o.notes.joined(separator: "; "))") }
            print("speech end → paste: p50 \(pct(lats, 0.5)) ms, p90 \(pct(lats, 0.9)) ms, max \(lats.last ?? 0) ms  (includes the \(Int(pause * 1000)) ms pause)")
            print("grok-4.3 cleanup:   p50 \(pct(fmts, 0.5)) ms, p90 \(pct(fmts, 0.9)) ms")
            print(String(format: "spend: cleanup $%.5f + STT $%.5f (%.0fs audio @ $0.20/h)", llm, audio / 3600 * sttStreamingUSDPerHour, audio))
            exit(outcomes.allSatisfy(\.pass) ? 0 : 1)

        default:
            print("usage: openflow-cli suite|say|format …")
            exit(2)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Bubble placement logic tests (no API key needed)

func caretSelfTest() -> Bool {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let window = CGRect(x: 100, y: 100, width: 1400, height: 900)
    let now: TimeInterval = 10_000
    let pid: Int32 = 42
    func click(_ x: CGFloat, _ y: CGFloat, age: TimeInterval = 5, typed: Int = 0, stale: Bool = false, pid p: Int32 = 42) -> ClickAnchor {
        var a = ClickAnchor(point: CGPoint(x: x, y: y), time: now - age, pid: p)
        a.typedSince = typed; a.invalidated = stale
        return a
    }
    func inputs(marker: CGRect? = nil, range: CGRect? = nil, field: CGRect? = nil, click: ClickAnchor? = nil,
                preferClick: Bool = false) -> CaretInputs {
        CaretInputs(markerCaret: marker, rangeCaret: range, elementFrame: field, windowFrame: window, screens: [screen],
                    frontPID: pid, click: click, mouse: CGPoint(x: 1600, y: 50), now: now, preferClick: preferClick)
    }
    let goodCaret = CGRect(x: 640, y: 520, width: 1, height: 17)
    let hiddenDocsInput = CGRect(x: 104, y: 980, width: 1, height: 14)   // top-left of the page, not the caret

    var cases: [(String, CaretResult, CaretResult.Source, CGPoint?)] = []
    func check(_ name: String, _ i: CaretInputs, _ expect: CaretResult.Source, near: CGPoint? = nil) {
        cases.append((name, CaretResolver.resolve(i), expect, near))
    }
    check("native app: accessibility caret is used", inputs(range: goodCaret), .textRange, near: CGPoint(x: 640, y: 528))
    check("browser: text-marker caret wins over range", inputs(marker: goodCaret, range: CGRect(x: 300, y: 300, width: 1, height: 17)), .textMarker)
    check("Google Docs: click beats the hidden input", inputs(marker: hiddenDocsInput, click: click(820, 610), preferClick: true), .click, near: CGPoint(x: 820, y: 610))
    check("Google Docs: typing after the click moves the anchor right", inputs(marker: hiddenDocsInput, click: click(820, 610, typed: 10), preferClick: true), .click, near: CGPoint(x: 885, y: 610))
    check("Google Docs: typed anchor stays inside the window", inputs(click: click(1450, 610, typed: 80), preferClick: true), .click, near: CGPoint(x: 1488, y: 610))
    check("Google Docs: scrolled since click → click not trusted", inputs(marker: goodCaret, click: click(820, 610, stale: true), preferClick: true), .textMarker)
    check("click past the end of a line: caret (line end) beats click", inputs(range: CGRect(x: 300, y: 602, width: 1, height: 17), click: click(820, 610)), .textRange, near: CGPoint(x: 300, y: 610))
    check("click below the text: caret (last line) beats click", inputs(range: goodCaret, click: click(700, 300)), .textRange, near: CGPoint(x: 640, y: 528))
    check("any app: typed since click → trust AX", inputs(range: goodCaret, click: click(820, 900, typed: 3)), .textRange)
    check("AX returns the whole text area frame → rejected", inputs(range: CGRect(x: 200, y: 200, width: 900, height: 600), field: CGRect(x: 200, y: 200, width: 900, height: 600), click: click(700, 500)), .click)
    check("AX rect outside the focused window → rejected", inputs(marker: CGRect(x: 1600, y: 1000, width: 1, height: 17), field: CGRect(x: 300, y: 400, width: 400, height: 24)), .field)
    check("AX rect off every screen → rejected", inputs(range: CGRect(x: -30_000, y: 10, width: 1, height: 17)), .window)
    check("click in another app is ignored", inputs(click: click(820, 610, pid: 7)), .window)
    check("click older than 15 min is ignored", inputs(click: click(820, 610, age: 3_600)), .window)
    check("no window, no field, nothing → mouse (last resort)", { var i = inputs(); i.windowFrame = nil; return i }(), .mouse)
    check("click outside the current window is ignored", inputs(click: click(1600, 1050)), .window)
    check("single-line field without caret info → field", inputs(field: CGRect(x: 300, y: 400, width: 400, height: 24)), .field)
    check("big field without caret info → its first line, not the mouse", inputs(field: CGRect(x: 300, y: 200, width: 800, height: 600)), .field, near: CGPoint(x: 316, y: 783))
    check("nothing but the window → inside the window, not the mouse", inputs(), .window, near: CGPoint(x: 800, y: 179))
    // Real cases from ~/Library/Logs/Openflow/caret.log (the bubble went to the click):
    var term = CaretInputs(rangeCaret: CGRect(x: 64, y: 92, width: 1, height: 19), elementFrame: CGRect(x: 0, y: 0, width: 3008, height: 3284),
                           windowFrame: CGRect(x: 0, y: 0, width: 3008, height: 1656), screens: [CGRect(x: 0, y: 0, width: 3008, height: 1692)],
                           frontPID: pid, click: click(632, 114), mouse: CGPoint(x: 632, y: 114), now: now, clickMovesCaret: false)
    check("logged: Terminal (CLI coding agent) — terminal cursor, not the click", term, .textRange, near: CGPoint(x: 64, y: 101))
    term.clickMovesCaret = true
    term.rangeCaret = nil
    check("terminal without AX caret: scrollback-sized field is skipped, never the click", { var t = term; t.clickMovesCaret = false; return t }(), .window, near: CGPoint(x: 1504, y: 79))
    let practice = CaretInputs(rangeCaret: CGRect(x: 1209, y: 1179, width: 0, height: 16), elementFrame: CGRect(x: 1204, y: 1029, width: 600, height: 150),
                               windowFrame: CGRect(x: 1164, y: 791, width: 680, height: 628), screens: [CGRect(x: 0, y: 0, width: 3008, height: 1692)],
                               frontPID: pid, click: click(1561, 1053), mouse: CGPoint(x: 1561, y: 1053), now: now)
    check("logged: empty practice box — caret at its start, not the click", practice, .textRange, near: CGPoint(x: 1209, y: 1187))
    // Real Google Docs reads (docs-probe.log / caret.log): hidden input at the top-left, visible caret element in the page.
    let docsScreen = CGRect(x: 0, y: 0, width: 3008, height: 1692), docsWindow = CGRect(x: 0, y: 65, width: 3008, height: 1597)
    var docs = CaretInputs(markerCaret: CGRect(x: 0, y: 16540, width: 0, height: 27), elementFrame: CGRect(x: 0, y: 1540, width: 938, height: 1),
                           windowFrame: docsWindow, screens: [docsScreen], frontPID: pid, click: click(1438, 617, age: 35, stale: true),
                           mouse: CGPoint(x: 1438, y: 617), now: now, preferClick: true)
    docs.domCaret = CGRect(x: 1389, y: 1190, width: 3, height: 25)
    check("logged: Google Docs — the visible kix caret, not the hidden input", docs, .domCaret, near: CGPoint(x: 1390, y: 1202))
    docs.domCaret = nil
    check("logged: Google Docs without caret element — never the 938×1 hidden input at the top-left", docs, .window)

    var ok = true
    for (name, r, expect, near) in cases {
        var pass = r.source == expect
        if let n = near, pass { pass = abs(r.rect.midX - n.x) < 2 && abs(r.rect.midY - n.y) < 10 }
        if !pass { ok = false }
        print("\(pass ? "✅" : "❌") \(name) → \(r.source.rawValue) @ \(Int(r.rect.midX)),\(Int(r.rect.midY))")
    }
    let detect: [(String?, String?, Bool)] = [
        ("com.google.Chrome", "Q3 plan - Google Docs", true), ("com.google.Chrome", "Budget - Google Sheets", true),
        ("com.apple.Safari", "Deck - Google Slides", true), ("company.thebrowser.Browser", "Notes - Google Docs", true),
        ("com.google.Chrome", "Inbox (3) - Gmail", false), ("com.apple.Notes", "Google Docs ideas", false), (nil, nil, false),
    ]
    for (b, t, expect) in detect {
        let got = CaretResolver.prefersClick(bundleID: b, windowTitle: t)
        if got != expect { ok = false }
        print("\(got == expect ? "✅" : "❌") prefersClick(\(b ?? "nil"), \(t ?? "nil")) = \(got)")
    }
    print(ok ? "all caret cases pass" : "caret cases FAILED")
    return ok
}

// MARK: - Hedged cleanup test (no API key needed)

/// First call is slow (server spike), later calls are fast.
final class SpikyFormatter: TextFormatting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let firstDelay: Double, laterDelay: Double, failFirst: Bool
    init(firstDelay: Double, laterDelay: Double, failFirst: Bool = false) {
        self.firstDelay = firstDelay; self.laterDelay = laterDelay; self.failFirst = failFirst
    }
    var callCount: Int { lock.withLock { calls } }
    func format(_ raw: String, context: FormatContext) async throws -> FormatResult {
        let n = lock.withLock { calls += 1; return calls }
        try await Task.sleep(nanoseconds: UInt64((n == 1 ? firstDelay : laterDelay) * 1e9))
        if n == 1 && failFirst { throw NSError(domain: "spike", code: 500) }
        return FormatResult(text: "call \(n)")
    }
}

final class Tally { var failed = 0 }

func hedgeSelfTest() async -> Bool {
    let tally = Tally()
    func run(_ name: String, _ f: SpikyFormatter, expect: String, maxSeconds: Double, calls: Int) async {
        let t0 = Date()
        let r = try? await HedgedFormatter(f, hedgeAfter: 0.5).format("x", context: FormatContext())
        let dt = Date().timeIntervalSince(t0)
        let pass = r?.text == expect && dt < maxSeconds && f.callCount == calls
        if !pass { tally.failed += 1 }
        print("\(pass ? "✅" : "❌") \(name): got \(r?.text ?? "error") in \(String(format: "%.2f", dt)) s, \(f.callCount) call(s)")
    }
    await run("fast answer: no second request", SpikyFormatter(firstDelay: 0.1, laterDelay: 0.1), expect: "call 1", maxSeconds: 0.4, calls: 1)
    await run("7 s spike: hedge answers at ~0.6 s", SpikyFormatter(firstDelay: 7, laterDelay: 0.1), expect: "call 2", maxSeconds: 1.0, calls: 2)
    await run("first call errors after hedge started: second still wins", SpikyFormatter(firstDelay: 0.7, laterDelay: 0.4, failFirst: true), expect: "call 2", maxSeconds: 1.2, calls: 2)
    // Content guard: a model that drops a clause on the first try is retried.
    final class DroppingFormatter: TextFormatting, @unchecked Sendable {
        private let lock = NSLock(); private var calls = 0; let firstOut: String, laterOut: String
        init(_ a: String, _ b: String) { firstOut = a; laterOut = b }
        var callCount: Int { lock.withLock { calls } }
        func format(_ raw: String, context: FormatContext) async throws -> FormatResult {
            let n = lock.withLock { calls += 1; return calls }
            return FormatResult(text: n == 1 ? firstOut : laterOut)
        }
    }
    func guardCase(_ name: String, raw: String, first: String, later: String, expect: String, calls: Int, ctx: FormatContext = FormatContext()) async {
        let f = DroppingFormatter(first, later)
        let r = try? await ContentGuardFormatter(f).format(raw, context: ctx)
        let pass = r?.text == expect && f.callCount == calls
        if !pass { tally.failed += 1 }
        print("\(pass ? "✅" : "❌") \(name): \(String(reflecting: r?.text ?? "error")), \(f.callCount) call(s)")
    }
    let raw = "Deploying to staging now, I'll ping you when it's live."
    await guardCase("dropped clause → retried, complete answer kept", raw: raw, first: "I'll ping you when it's live.",
                    later: "Deploying to staging now, I'll ping you when it's live.", expect: "Deploying to staging now, I'll ping you when it's live.", calls: 2)
    await guardCase("complete answer → no retry", raw: raw, first: raw, later: "x", expect: raw, calls: 1)
    await guardCase("fillers and numbers removed → no retry", raw: "so um basically the invoice is two thousand four hundred and fifty dollars okay",
                    first: "The invoice is $2,450.", later: "x", expect: "The invoice is $2,450.", calls: 1)
    await guardCase("spoken correction → no retry", raw: "Send it Monday, no wait, actually Tuesday", first: "Send it Tuesday.", later: "x",
                    expect: "Send it Tuesday.", calls: 1)
    await guardCase("ordinal list → no retry", raw: "Here is the plan. First, finish pricing. Second, update docs. Third, email customers.",
                    first: "Here is the plan:\n1. Finish pricing.\n2. Update docs.\n3. Email customers.", later: "x",
                    expect: "Here is the plan:\n1. Finish pricing.\n2. Update docs.\n3. Email customers.", calls: 1)
    await guardCase("selection edit → never checked", raw: "make this shorter", first: "Short.", later: "x", expect: "Short.", calls: 1,
                    ctx: FormatContext(selectedText: "A long paragraph"))
    print(tally.failed == 0 ? "all hedge cases pass" : "hedge cases FAILED")
    return tally.failed == 0
}

// MARK: - Spacing / joining tests (no API key needed)

func spacingSelfTest() -> Bool {
    var ok = true
    func expect(_ name: String, _ got: String, _ want: String) {
        let pass = got == want
        if !pass { ok = false }
        print("\(pass ? "✅" : "❌") \(name): \(String(reflecting: got))\(pass ? "" : " (want \(String(reflecting: want)))")")
    }
    let p = SmartSpacing.prefix
    expect("after a full stop", p("…tomorrow at 3 PM.", "Actually, beyond that", false), " ")
    expect("after ? ! : ;", [p("ok?", "Yes", false), p("ok!", "Yes", false), p("note:", "buy", false), p("a;", "b", false)].joined(), "    ")
    expect("mid-sentence", p("I'll bring the slides", "and the laptop", false), " ")
    expect("model added joining punctuation", p("See you at 3", ". Also bring the deck", false), "")
    expect("model added joining comma", p("See you at 3", ", and bring the deck", false), "")
    expect("already a space", p("PM. ", "Actually", false), "")
    expect("start of a line", p("Title\n", "Body", false), "")
    expect("empty field", p("", "Hello", false), "")
    expect("after an opening quote", p("He said \"", "hi", false), "")
    expect("CLI agent prompt (ends with a space)", p("│ ❯ ", "Hey", false), "")
    expect("unknown, first paste", p(nil, "Hey", false), "")
    expect("unknown, later paste in session", p(nil, "Next", true), " ")
    expect("list after text", p("Groceries:", "- Eggs", false), "\n")

    let m = RecentInsert(pid: 7, text: "Hey, I think I'll meet you tomorrow at 3 PM.", time: 100, inputCount: 5)
    expect("memory valid: same app, no input since", "\(m.isValid(pid: 7, inputCount: 5, now: 160))", "true")
    expect("memory invalid: user clicked or typed", "\(m.isValid(pid: 7, inputCount: 6, now: 160))", "false")
    expect("memory invalid: other app", "\(m.isValid(pid: 8, inputCount: 5, now: 160))", "false")
    expect("memory invalid: 20 min later", "\(m.isValid(pid: 7, inputCount: 5, now: 1_300))", "false")

    expect("recent words: CLI chrome stripped", TextContext.recentWords("──────╮  \n  │ ❯ Hey, I think I'll meet you tomorrow at 3 PM.") ?? "nil",
           "Hey, I think I'll meet you tomorrow at 3 PM.")
    expect("recent words: only the last 12", TextContext.recentWords("one two three four five six seven eight nine ten eleven twelve thirteen fourteen") ?? "nil",
           "three four five six seven eight nine ten eleven twelve thirteen fourteen")
    expect("recent words: empty prompt → none", TextContext.recentWords("│ ❯ ") ?? "nil", "nil")
    let j = { (t: String, b: String?, prose: Bool) in GrokFormatter.joinWithBefore(t, before: b, prose: prose) }
    expect("join: echo of previous text dropped", j("Hey, I think I'll meet you tomorrow at 3 PM. Actually, beyond that.", "Hey, I think I'll meet you tomorrow at 3 PM.", true), "Actually, beyond that.")
    expect("join: 'And' continues mid-sentence", j("And the demo laptop.", "I'll bring the slides", true), "and the demo laptop.")
    expect("join: new sentence after unpunctuated text", j("Also, can you bring the deck?", "See you at 3", true), ". Also, can you bring the deck?")
    expect("join: 'I' is never preceded by a period", j("I'll be late.", "Hey Priya", true), "I'll be late.")
    expect("join: terminal command untouched", j("Git status", "ls -la", false), "Git status")
    expect("join: after a full stop nothing changes", j("Actually, yes.", "…3 PM.", true), "Actually, yes.")
    expect("join: model already joined", j(". Also bring the deck.", "See you at 3", true), ". Also bring the deck.")
    // Defaults a brand-new install gets (empty settings store) and older saved settings without the keys.
    let suite = "openflow-defaults-selftest-\(UUID().uuidString)"
    let fresh = OpenflowSettings.load(from: UserDefaults(suiteName: suite)!)
    UserDefaults().removePersistentDomain(forName: suite)
    expect("default activation: hold to talk only", fresh.activation.rawValue, "holdOnly")
    expect("default: Grok cleanup on", "\(fresh.cleanupEnabled)", "true")
    expect("default cleanup model", fresh.formatterModel, "grok-4.3")
    let legacy = (try? JSONDecoder().decode(OpenflowSettings.self, from: Data(#"{"pauseSeconds": 1.4}"#.utf8)))
    expect("saved settings without the keys get the defaults", "\(legacy?.activation.rawValue ?? "nil") \(legacy?.cleanupEnabled ?? false)", "holdOnly true")
    print(ok ? "all spacing cases pass" : "spacing cases FAILED")
    return ok
}
