# Using Openflow

## Everyday dictation
- **Quick message**: hold the shortcut, talk, and release. The text is pasted where your cursor is.
- **Long-form or walking around**: tap the shortcut once for hands-free mode. Every pause pastes; keep talking and it keeps appending. Tap again, click ✕ on the bubble, or stay silent for the idle timeout (default 2 min) to stop.
- **Changed your mind**: just say it ("at three, no wait, four", "scratch that"). Only the final version is pasted.
- **Lists**: "Three things: first…, second…, third…" gives a numbered list. Saying items one at a time with a short pause between them ("Help me buy… eggs… bananas… milk") gives "- " bullets, as does asking for a list. Items mentioned in passing in one sentence stay inline, and single-line boxes (search, subject) always stay on one line. "New line" and "new paragraph" work too.
- **Mistake before it pastes**: Esc discards whatever hasn't been pasted yet.
- **Paste the last dictation again**: menu bar icon → Paste last dictation. Only the latest one is kept, in memory, until Openflow quits. Openflow keeps no dictation history.

## Editing with your voice
1. Select text (double-click or drag).
2. Press the shortcut and speak.
   - An instruction ("make this more formal", "turn this into bullets", "translate to Spanish", "fix the typos") rewrites the selection in place.
   - New content ("by the way, I also shipped the fix") is added right after the selection, which stays untouched.
   - A reply request ("reply saying I'll join at 5") writes the reply after the selection.

## Languages
Auto-detect (the default) handles any language and switching mid-sentence. Picking a language under **Dictation** also writes that language's numbers and currencies as digits at the transcription step. Openflow never translates unless you ask it to with a selection.

## Writing style per app
Openflow recognizes where you're typing and writes like a person would there:
- **Email** (Mail, Outlook, Gmail): greeting on its own line, paragraphs, and a sign-off.
- **Chat** (Slack, Teams, WhatsApp, iMessage, Meet): one casual message.
- **AI prompt** (ChatGPT, Grok, Claude, a coding agent in your terminal): a clean prompt. It is never answered.
- **Documents** (Notes, Docs, Notion, Word): polished prose.
- **Code and terminal**: exact commands and identifiers.

Corrections always resolve to the last thing you said ("the 15th, no, actually the 16th" gives "the 16th").

## Personalize
- **About you**: your name, role, team, the people you mention, and products and jargon. It improves spelling and tone and is never typed out.
- **Custom instructions**: these override the defaults. Examples: "British spelling", "In Slack keep it casual and lowercase", "Write Hindi in Latin script (Hinglish)".
- **Dictionary**: terms are sent to Grok Voice Transcribe as `keyterm` (better recognition) and to the cleanup step as preferred spellings.

## Settings worth knowing
| Setting | Where | Default |
|---|---|---|
| Shortcut (record any combo, chord, or single modifier) | Shortcut | ⌃ Control |
| Activation style | Shortcut | Hold to talk, tap for hands-free |
| Pause before paste | Dictation | 1.0 s |
| Cleanup with Grok (off = raw transcript) | Dictation / menu bar | On |
| Reasoning effort | Dictation | None (fastest) |
| Bubble position (next to the text cursor or bottom center) | Dictation | Next to the text cursor |
| Show the words being heard in the bubble | Dictation | On |
| Microphone (menu bar → Microphone, or Dictation → Microphone) | both | System default |
| Send the last few words before the cursor (≤ 12 words; the rest of the field is never sent) | Dictation | On |
| Live transcript above the bubble | Dictation | Off |
| Open at login | Setup / menu bar | Off |

If you use **fn** as the shortcut, set System Settings → Keyboard → "Press 🌐 key to" → Do Nothing.

## Updates
Open Openflow → **Updates**:
- **Check for Updates** checks right on the page and shows the result: "You're up to date", "Openflow x.y.z is available", or why the check failed, with **Try Again**.
- **Update to x.y.z…** shows the release notes and **Install & Relaunch**.
- The page also has the daily automatic check toggle, the last check time, and a link to the release notes.

When an update is waiting:
- the sidebar shows a badge;
- Home shows a banner;
- the menu bar shows **Update to Openflow x.y.z…**.

**Check for Updates…** is also always in the menu bar.

## Choosing a microphone
Menu bar icon → **Microphone** lists every connected input (AirPods, USB webcams, the built-in mic) plus **System default**; the checked one is used from the next dictation. The same picker is under **Dictation → Microphone** and on the setup assistant's microphone step. If the chosen mic is unplugged, Openflow uses the system default until it's back. A MacBook's built-in mic is marked "(lid closed)" when the lid is shut, because macOS switches it off then.

## When something goes wrong
- **"No audio detected"**: Openflow hasn't heard you for 2 s. Check the mic (System Settings → Sound → Input) or just start talking; it clears instantly.
- **Tiny words inside the bubble**: the last 2–3 words Openflow heard, live (older words trail off with "…"). If none appear while you talk, it isn't being transcribed.
- **"Offline · still recording"**: keep talking. When you stop, Openflow transcribes what it recorded. If it still can't reach SpaceXAI, click **Retry** once you're back online. The audio is kept in memory only and discarded when you dismiss.
- **"Didn't paste · copied"**: the app didn't accept the paste. Click **Paste**, or press ⌘V yourself; the text is on your clipboard.

## Troubleshooting
- **Nothing happens on the hotkey**: Setup must show Accessibility ✓. In System Settings → Privacy & Security → Accessibility the entry is called **Openflow** (bundle ID `com.openflow.Openflow`, at `/Applications/Openflow.app`; Setup → This app shows both). If an old entry is there, remove it with − and add Openflow again with +. Setup → "Show Openflow in Finder" lets you drag it in.
- **Keychain prompt about "Openflow"**: the key is stored as the Keychain item "Openflow" / "SpaceXAI API key". Saving it from the app makes Openflow the owner, so normal launches read it silently.
- **Bubble not above the cursor in some app**: click where you want to type before pressing the shortcut. Openflow anchors to that click when the app (Google Docs, canvas editors) doesn't report its caret. If it's still off, the last lines of `~/Library/Logs/Openflow/caret.log` show which source was used and what the app reported. Send them with the app name.
- **"Cleanup failed, pasted raw text"**: the Grok call failed (network or key). The raw transcript was pasted so nothing was lost.
