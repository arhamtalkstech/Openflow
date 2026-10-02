# How Openflow works

## Pipeline

```
hotkey (CGEvent tap) ─► mic (AVAudioEngine → 16 kHz PCM16, 20–100 ms chunks)
                          │
                          ├─► energy VAD (local) ── decides "you paused" / "you resumed"
                          │
                          └─► wss://api.x.ai/v1/stt  (grok-voice-transcribe-2.0, interim_results=true)
                                 │  transcript.partial (interim / chunk-final / utterance-final)
                                 ▼
                         unpasted utterances ──► grok-4.3 cleanup (Responses API, reasoning none)
                                                      │
                                                      ▼
                                   paste at cursor (⌘V, clipboard restored) + stats
```

## Why pauses are detected on the Mac

Measured against the live API: with `endpointing=800`, a 1.5 s pause produced only a chunk-final, and the utterance-final arrived seconds later with *both* utterances stitched together. Server endpointing is too unpredictable for "paste the moment I stop". Openflow therefore:

1. Opens the stream with `endpointing=5000`, so the server rarely ends an utterance on its own.
2. Runs an energy VAD on the mic with an adaptive noise floor (20 ms frames).
3. After **60%** of your pause setting (default 1.0 s → 0.6 s) of silence, it sends `{"type":"finalize"}`. The server answers with the utterance-final in about 130–250 ms, and the session stays open.
4. It starts the Grok cleanup right away (speculatively). The paste waits until the **full** pause has elapsed. Grok's ~0.6–1.2 s round trip mostly hides inside the pause.
5. If sustained voice (≥120 ms) comes back before the paste lands, the cleanup is cancelled and the text stays unpasted. The next pause cleans up old and new text together, so a correction can span the gap.
6. Once text is pasted it is locked. Later speech is pasted after it, and Grok sees the earlier text as context only ("do not repeat").

The bubble shows the spinner only after the full pause, so a short breath mid-sentence doesn't flash it.

## Failure handling

- **No audio.** If no voice is heard in the first 2 s, the bubble shows "No audio detected" (muted mic, wrong input, or simply not speaking yet). It clears the moment speech is detected.
- **Live words.** The last 2–3 words heard appear in tiny type (8.5 pt) inside the pill, above the waveform. The pill keeps its width and grows from 28 to 39 pt tall; older words trail off with "…".
- **Microphone choice.** `AudioDevices` lists Core Audio inputs by UID. The chosen device is set on a fresh `AVAudioEngine`'s input unit for each session (`kAudioOutputUnitProperty_CurrentDevice`), and the tap uses the input node's hardware `inputFormat`. The output format can still describe the previous device, which stalled capture from non-default mics until this fix.
- **Offline or dropped stream.** Every session's audio is kept in memory (≤ 10 min, never on disk). If the stream can't connect within 6 s or drops and 3 reconnects fail, the bubble shows "Offline · still recording" and the session keeps recording. At stop, the audio since the last paste is transcribed with the one-shot `POST /v1/stt` and goes through the normal cleanup and paste. If that fails too, the bubble shows "<reason> · audio kept" with **Retry**. The kept audio is discarded when you dismiss the bubble or start a new dictation.
- **Heard speech, empty transcript.** The recorded audio gets a second opinion from `POST /v1/stt` before giving up.
- **Paste check.** ⌘V is sent only once no modifier keys are physically held, so a lingering ⌃⌥ can't turn it into ⌃⌥⌘V. Where the app exposes its text, Openflow fingerprints the field (character count plus the text before the cursor) before pasting and compares at 0.6 s and 1.2 s. If nothing changed, it sends ⌘V once more and checks twice again. If the field is still unchanged, the bubble shows "Didn't paste · copied" with **Paste**, and the text stays on the clipboard; there's no ✓. Apps that hide their text, like Google Docs, can't be checked. Your previous clipboard is restored only after a confirmed paste.
- Esc dismisses an open issue. The menu bar also offers "Retry failed dictation" / "Paste last dictation again".

## Ending a session

- Hold-to-talk release, the second tap, or ✕ on the bubble all call `stop()`. The app keeps the mic open for 180 ms so the last syllable isn't clipped. The engine sends `finalize` and `audio.done`, which makes the server flush every remaining word before it closes, then pastes everything unpasted.
- Esc calls `cancel()`, which discards unpasted text.
- If the server is slow to answer `finalize`, the engine resends it at 2.5 s and waits up to 8 s when stopping (6 s in hands-free). Only then does it fall back to the locally assembled interim text, which can lag the audio by about a second.
- If the socket drops unexpectedly, the engine keeps what it heard and reconnects up to 3 times.

## Hotkey semantics

| Activation | Press | Release |
|---|---|---|
| Hold to talk, tap for hands-free (default) | starts listening | held ≥ 0.32 s → paste and stop; quick tap → hands-free stays on |
| Tap to start / stop | toggles hands-free | – |
| Hold to talk only | starts push-to-talk | stop and paste |

The shortcut can be a single modifier (either ⌃, Right ⌥, fn…), a chord (⌃⌥), or a combo (⌥Space, ⌃⇧D, F-keys). Combos are swallowed so they don't type. With a modifier-only hotkey, pressing another key within 1.5 s (⌃C) cancels the session. The bubble and the start sound wait 200 ms, so shortcuts never flash the UI. Listening starts immediately anyway, so no words are lost.

## Cleanup prompt (grok-4.3)

`GrokFormatter.systemPrompt` holds nine rules: apply self-corrections, drop filler, punctuate, structure lists, apply spoken formatting commands, keep the speaker's language and script, write numbers, emails, and money in written form, match the destination app, and continue from text already typed. The system prompt then adds:

- **About the speaker**: free text from Personalize, used only to resolve names and jargon and never inserted.
- **The speaker's instructions (highest priority)**: these override the defaults, for example "write Hindi in Latin script".
- **Selected text mode**: when a selection exists at start, the response is strict JSON `{action: replace_selection | insert_after_selection, text}`. Edits replace the selection and keep its labels and content; additions go after it and leave the selection untouched. When in doubt the model chooses insert-after, which is non-destructive.

**Privacy.** Grok sees:
- what you said
- the destination metadata
- the last few words before the cursor (at most 12 words / 100 characters, never the whole field)
- text you selected before pressing the shortcut

You can turn off the last-few-words context under Dictation → "Send the last few words before the cursor". Password fields are never read.

**Joining with existing text.** The text before the cursor comes from two sources:
- **Openflow's memory of its own last paste in that app.** It's exact while you haven't clicked or typed there since, and works in apps that expose nothing, like Google Docs. It's held in memory only.
- **What the app reports.** Hidden inputs, such as Google Docs' 938×1 box, count as unknown, not as an empty field.

Spacing is deterministic (`SmartSpacing`): one space after `. ! ? : ;` or a word, none before leading punctuation, none at the start of a line or field. In terminals, the joining space is typed as a real key press, because CLIs often trim leading whitespace from pasted text.

Grok's rule 9 continues the sentence correctly. It capitalizes after a full stop and lowercases a continuation. If the previous text lacked punctuation, it starts with the missing ". " or ", ".

`joinWithBefore` then applies deterministic safety nets:
- It drops an echo of the previous text.
- It lowercases a leading "And"/"Or" mid-sentence.
- It adds ". " when a new sentence follows unpunctuated prose. This applies only in prose fields, never terminals or code, and never before "I".

**Destination type.** `DestinationKind.classify` maps bundle ID, window title, and field label to email, chat, ai_prompt, document, code, terminal, or general. A terminal whose title shows a coding agent (grok, claude, codex…) counts as ai_prompt. Rule 8 of the prompt is a per-type style guide:
- email: greeting line, paragraphs, and a sign-off on its own line
- chat: one casual message
- ai_prompt: a clean first-person prompt that is never answered
- document: polished prose
- code and terminal: exact identifiers and commands

Rule 3 makes text read as typed, not transcribed. It keeps every point and hedges like "probably". Rule 1 keeps only the last value after corrections.

**Content guard.** The model occasionally drops a clause: about 1 in 12 engine runs of one scenario turned "Deploying to staging now, I'll ping you…" into "I'll ping you…". After each cleanup, `ContentGuardFormatter` checks that the transcript's meaningful words (4 letters or more) survived. Fillers, number and ordinal words, and spoken formatting commands are excluded, in several languages. If two or more are missing and the speaker made no spoken correction, it retries once and keeps the more complete answer. It is skipped for selection edits and for scripts without word spacing (Chinese, Japanese, Thai).

**Hedged cleanup.** If the cleanup call hasn't answered in 2.2 s, an identical second call is sent and the first answer wins. Spikes of 4–7 s were observed.

The user message carries a `<destination>` block: type, app, window title, field type (single-line or multi-line, from the AX role), and the field's placeholder or label (e.g. "Ask anything"). AI-chat prompt boxes are written as prompts, never answered. Single-line fields never get line breaks, and the formatter also joins lines defensively.

It also carries `<spoken_parts>`: the transcript split where the speaker really paused. The server locks a chunk at each silence (and every ~3 s of continuous speech), and the engine counts a chunk boundary as a pause only if its own voice detector saw ≥ 0.45 s of silence there. Word timestamps from the stream weren't reliable across chunks. Short parts in a row with pauses become list items.

It then carries the language hint, dictionary spellings, up to 600 characters before the cursor (password fields are never read), and the transcript. `prompt_cache_key` keeps the static prompt cached.

## Reading and writing other apps

- **Caret position** (`CaretLocator` gathers the inputs; `CaretResolver` in OpenflowCore decides and is unit-tested). The candidates, in order:
  0. **The editor's own drawn caret.** Google Docs keeps its real text input as a hidden 938×1 px element at the top-left, which is what the caret APIs report. It draws the visible caret as `div.kix-cursor-caret`, and Chrome exposes that div in the accessibility tree, as measured on a live Doc with `--docs-probe`. Openflow searches the focused Docs window for it (≈400 nodes, ~50 ms, 250 ms cap). If a stale second caret element lingers during a redraw, it picks the one nearest the click or typing estimate.
  1. **Browser caret API** (`AXSelectedTextMarkerRange` → `AXBoundsForTextMarkerRange`), used by Chrome, Safari, and Electron.
  2. **Native caret API** (`AXSelectedTextRange` → `AXBoundsForRange`), used by native text views.
  3. **Last click.** Passive global monitors record where you clicked and in which app's window. Scrolling, arrow keys, Return, Tab, or ⌘/⌃ shortcuts make it stale. Typed characters shift it right, at about 6.5 pt per character, clamped to the window.
  4. **The focused field**: a single-line field's start, or a multi-line field's first line. Only a point visible in the window counts, so a terminal's scrollback is skipped. Fields thinner than 8 pt in either direction are ignored, which rules out hidden inputs like Docs' 938×1 box.
  5. **The focused window.**
  6. **The mouse pointer**, only if there is no window at all.

  Each accessibility caret must be caret-sized, on a screen, inside the focused window, and not just the field's own frame. Otherwise it is rejected.

  A plausible reported caret always wins: clicks past a line's end or below the text put the caret somewhere other than the click. The last click is used only in two cases:
  - No caret is reported.
  - The window is Google Docs, Sheets, Slides, or Drawings in a browser. Docs draws the page on a canvas and reports a hidden input element as the caret.

  Terminals ignore clicks entirely. When nothing is known, the bubble goes to the field's first line or the window, never the mouse pointer. Chromium browsers get `AXEnhancedUserInterface` when they become active, so their web carets are available by the time you press the shortcut.

  After a paste, the bubble follows the caret only when the app reported the position. Otherwise it stays where it was.

  Each placement is logged to `~/Library/Logs/Openflow/caret.log`: app bundle ID, the chosen source, and every candidate's coordinates. No text or window titles are logged. `open -n -g /Applications/Openflow.app --args --caret-probe 10` logs the frontmost app's candidates once a second without any UI.
  Electron and Chromium apps get `AXManualAccessibility = true` so their accessibility tree exists.
- **Insert**: write a transient pasteboard item (marked `org.nspasteboard.TransientType` so clipboard managers skip it), post ⌘V, and restore the previous clipboard after 0.8 s, unless you copied something in the meantime.
- **Insert after selection**: post → (collapses the selection to its end), then paste with a smart leading space.

## Updates

`Updater.swift` wraps Sparkle's `SPUStandardUpdaterController` and uses Sparkle's gentle reminders for menu bar apps. Scheduled checks never pop a window. They set `availableVersion`, which drives the menu item, the icon badge, and the dashboard banner. Clicking opens Sparkle's standard update window.

`Info.plist` carries the feed settings:
- `SUPublicEDKey`
- `SUEnableAutomaticChecks`, with a daily interval
- `SUAllowsAutomaticUpdates = false` (click to install)
- `SUFeedURL`, added at build time from `scripts/release.conf`

The updater stays off without a feed. Events go to `~/Library/Logs/Openflow/updates.log` (versions and outcomes only).

## What is stored

- `usage.json` holds counts only:
  - totals: sessions, dictations, words, characters, spoken and streamed seconds, latency sum, Grok cost
  - per-day totals
  - dictations and words per app
- Dictated text is never written to disk.
- "Paste last dictation" keeps the latest dictation in memory only, until Openflow quits.
- Files from earlier builds that stored a dictation history are rewritten without it on launch.
- **API key.** Developer ID builds keep it in the Keychain. Self-signed builds keep it in `~/Library/Application Support/Openflow/api-key`, mode 600 inside a 700 folder. Migration from an older Keychain item runs once, off the main thread.

## Spend accounting

- Speech-to-text: seconds of audio streamed × $0.20/hour (streaming list price).
- Grok: exact per call, from `usage.cost_in_usd_ticks` (1 USD = 10¹⁰ ticks; checked against `grok-4.3` token prices).
- "Keystrokes saved" = characters inserted. "Time saved" = typing time at 40 wpm minus speaking time. "Time spoken" counts voiced audio plus a 350 ms hangover between words.

## Build

Identity is defined once in `AppIdentity.swift` and must match `Resources/Info.plist`; the build script refuses to build if they differ. Name **Openflow**, bundle ID `com.openflow.Openflow`. The bundle is assembled in `.build/app/` (hidden from Spotlight and Launch Services) so `/Applications/Openflow.app` is the only registered copy.

Swift Package Manager with three targets (`OpenflowCore`, `Openflow`, `openflow-cli`). `scripts/build-app.sh` assembles `Openflow.app` (`Info.plist` with `LSUIElement` and the microphone usage string, plus an icon rendered by `make-icon.swift`) and signs it. The SwiftUI `@State` macro plugin ships only with Xcode, so view-local state uses small `ObservableObject`s and the project builds with the Command Line Tools alone.
