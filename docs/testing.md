# How Openflow was tested

## Real-audio harness (`openflow-cli suite`)

Every scenario runs against the live SpaceXAI APIs, with no stubs or recorded transcripts:

1. **Audio**: the scenario text is synthesized with **SpaceXAI TTS** (`POST /v1/tts`, voices `eve`/`ara`/`rex`/`sal`/`leo`, `output_format {codec: pcm, sample_rate: 16000}`). Low-level noise is added to the speech and to the silences between segments, to resemble a room mic. TTS audio is cached in `.cache/tts/` (gitignored), so reruns cost only STT and Grok.
2. **Streaming**: the audio is fed to the same `DictationEngine` the app uses, in 100 ms frames at real-time pace. It runs through the same local voice detector, the same `wss://api.x.ai/v1/stt` stream, and the same `grok-4.3` cleanup.
3. **Insertion**: pastes go into a simulated text field. It applies the same smart spacing, can start with a selection, and reports the destination app name to the formatter (Mail, Slack, Notion, WhatsApp…).
4. **Checks**: number of pastes, required and forbidden phrases, list structure, insert action (replace or insert-after), final field contents, and latency from speech end to paste.

```bash
export XAI_API_KEY=…
swift run openflow-cli suite                          # all scenarios
swift run openflow-cli suite --only selection-edit -v # one scenario with an engine trace
swift run openflow-cli say "Your own sentence" --voice rex --lang en
swift run openflow-cli format "raw transcript text"   # cleanup step only
swift run openflow-cli suite --usage-out /tmp/u.json  # keep the run's stats (view with Openflow --usage-file /tmp/u.json)
```

## Scenarios (35)

| Scenario | What it proves |
|---|---|
| self-correction | "Thursday at three, no wait, Friday at four PM" → only Friday 4 PM |
| spoken-list | "first… second… third…" → intro line + numbered list |
| scratch-that | "scratch that" drops the previous sentence |
| resume-before-paste | cleanup already started speculatively, speaker resumes → paste cancelled, one combined paste |
| append-after-paste | hands-free: a long pause pastes; the next sentence is pasted after it as a second paste |
| question-not-answered | a dictated question is cleaned up, never answered |
| push-to-talk | a 1.6 s mid-sentence pause while holding does not paste; one paste on release |
| about-me-context | the About-you profile and dictionary give correct "Priya", "Openflow", "Joaquín" |
| spanish-correction | Spanish (auto-detected) self-correction |
| german-list | German enumeration → list, untranslated |
| hindi-correction | Devanagari Hindi with a correction (3 → 4 o'clock) |
| japanese-correction | Japanese correction (10 → 11 o'clock) |
| hinglish-code-switch | mixed Hindi/English stays mixed, nothing translated |
| custom-instructions-hinglish | custom instruction "write Hindi in Latin script" is obeyed |
| spoken-formatting-commands | "new line" applied, not typed |
| selection-edit | selection + "make this a bulleted list and fix the typo" → replaced in place, label kept |
| selection-add | selection + "by the way…" → selection untouched, new sentence after it |
| ai-chat-paused-list | exact repro of a real dictation: a prompt to an AI chat in Chrome ("Ask anything"), with items said after pauses. The request stays a prompt and the items become bullets |
| paused-items-become-list | no "list" word: short items with pauses become a list |
| inline-items-stay-inline | "I grabbed eggs, milk and bread…" in Slack stays a sentence |
| single-line-field-no-breaks | paused items in a single-line search box stay on one line |
| correction-15th-to-16th | "move it to the 15th? No, actually, do it the 16th" → only 16th |
| correction-several-values | "Starbucks, sorry, Blue Bottle, at three, no, four, actually five" → "Blue Bottle at 5" |
| style-email | rambling speech into Mail → "Hi Priya," line, paragraphs, "Thanks," / "Sam" |
| style-slack | the same speech into Slack → one casual message, no email layout |
| style-ai-prompt-in-terminal | talking to a coding agent in Terminal → clean prompt, tics removed, not answered |
| style-notes-prose | rambling thought in Notes → clean prose, hedges like "probably" kept |
| continue-after-full-stop | reported bug: a second dictation after "…at 3 PM." → "PM. Actually, …", with no echo and no fragment |
| continue-mid-sentence | "…bring the slides" + "and the demo laptop" → lowercase continuation, one space |
| new-sentence-after-unpunctuated | "See you at 3" + "Also, can you bring the deck?" → "3. Also, …" |
| no-audio-then-speech | 2.6 s of silence → "No audio detected", which clears while still listening once speech starts; the paste is normal |
| offline-recovers-from-audio | streaming endpoint unreachable → "Offline · still recording" → kept audio transcribed via `/v1/stt` at stop → pasted |
| offline-retry-later | both endpoints unreachable → "SpaceXAI unreachable · audio kept [Retry]" → Retry with the network back pastes the full sentence |
| paste-did-not-land | the field ignores ⌘V → no ✓; "Didn't paste · copied [Paste]" → Paste lands it |
| numbers-and-email | "$2,450", "billing@acme.com", "the 15th" |

## Latest result

The latest full output is in [`sample-suite-run.txt`](sample-suite-run.txt): **35/35 passed**. Speech end to paste: p50 1.73 s, p90 2.35 s, max 3.25 s, including the 1.0 s pause. `grok-4.3` cleanup: p50 0.93 s, p90 1.92 s. The run streamed 307 s of audio and cost $0.070 in total. The content guard retried once, on a genuine omission. (The 1.1.0 release run was 31/31.)

The app-side paste check (field fingerprint, modifier wait, second ⌘V) runs against real apps and can't be driven from the harness without typing into your apps. The harness covers the engine's side of it: a failed paste shows Paste, and no ✓.

Release checks on `dist/Openflow-1.1.0.dmg`:
- `hdiutil verify` reports the image is valid.
- The binary is universal, and the signature satisfies its designated requirement under `--strict`.
- The hardened runtime flag and the microphone entitlement are present.
- No dev-only symbols and no `xai-` key strings are in the binary.
- Installed from the DMG, it kept its Accessibility grant.

`openflow-cli hedge-selftest` also covers the content guard with 6 cases:
- A dropped clause is retried.
- A complete answer, fillers and numbers, a spoken correction, an ordinal list, or a selection edit is never retried.

`openflow-cli spacing-selftest` runs 27 joining cases:
- spacing after punctuation, mid-sentence, after the model's own joining punctuation, after a CLI agent prompt, at the start of a line, and after quotes
- validity of the paste memory
- recent words (CLI chrome stripped, last 12 words)
- the safety nets: echo strip, And/Or lowercase, the added period, terminals untouched

`openflow-cli hedge-selftest` checks the cleanup hedge with a fake server:
- A fast answer sends no second request.
- A 7 s spike is answered by the hedge at 0.64 s.
- An error on the first call still returns the second.

## Bugs the harness caught (and fixes)

- **Stale chunk-final counted as new speech**: a late chunk-final for the old utterance arrived after `finalize`, triggered a second finalize, and restarted cleanup. Only interim partials received while not awaiting a final now count as speech.
- **Grok latency added on top of the pause**: the paste took pause + finalize + Grok, about 2.4 s. The engine now finalizes and starts cleanup at 60% of the pause, then pastes at the full pause.
- **Lost tail words on a slow finalize**: the server sometimes answers `finalize` after more than 2 s. The old 2.5 s fallback pasted lagging interim text and dropped "Sourdough bread". Stop now sends `audio.done` (the server must flush everything), and a slow finalize is resent and waited on longer.
- **Custom instructions ignored**: "keep the speaker's script" outranked "write Hindi in Latin script". The About-you profile and custom instructions moved into the system prompt as highest priority.
- **Paused list items pasted as one sentence** (reported from real use in a Chrome AI chat): pauses never reached the cleanup step, and the prompt only knew the app name. The engine now splits each utterance where a server chunk boundary coincides with ≥ 0.45 s of local silence and sends those parts. The prompt also gets the field type, its placeholder or label, and the window title. The list rule was rewritten, with guards for inline mentions and single-line fields.
- **Bubble at the mouse click instead of the text cursor** (from real use, found in `caret.log`). A rule preferred the last click whenever the reported caret was far from it. That is wrong in three cases: a click past a line's end, a click below the text, and terminals, where clicks don't move the cursor. A plausible reported caret now always wins; the click is used only when no caret is reported, or in Google Docs. Fallbacks are now the field, then the window, never the mouse. Chromium browsers get `AXEnhancedUserInterface` on activation, so web carets are available.
- **Bubble at the top-left in Google Docs** (from real use). After a multi-line paste made the last click stale, the fallback used Docs' hidden 938×1 px input as the field. `--docs-probe` on a live Doc showed Chrome exposes Docs' drawn caret (`kix-cursor-caret`, 3×26 pt, moving as you type). That caret is now the first choice in Docs, and degenerate fields are rejected. Both logged Docs cases are in `caret-selftest` (31 cases).
- **No space between two dictations** ("…3 PM.Actually", from real use in a CLI coding agent in Terminal). The fix remembers Openflow's own last paste per app, so the text before the cursor is known even when the app hides it. It types the joining space as a key in terminals, whose CLIs can trim pasted leading whitespace. It sends the last few words to Grok so it can capitalize or continue correctly, and adds deterministic join safety nets. The scenario runs also surfaced two model slips, both now covered: the model echoed the previous sentence once, and it kept a transcription fragment (". Which is…").
- **Rare dropped clause** (found while finalizing 1.1.0): "Deploying to staging now, I'll ping you…" was pasted as "I'll ping you…" in 1 of 12 runs. The transcript was complete, so this was a model omission (0 in 80 isolated calls). Fixed with the content guard. Afterwards, 12 of 12 runs of that case were complete. Multilingual false alarms (German ordinals, Japanese) were excluded.
- **Occasional 4–7 s cleanups**: hedged requests (a second identical call after 2.2 s; the first answer wins).
- **Selection edits dropping a label line**: added a rule plus a worked example (different content than the test) to keep all selected content. It then passed 4 of 4 runs.

## Bubble placement

`swift run openflow-cli caret-selftest` runs 24 cases through `CaretResolver`, all passing. They cover:
- native apps
- browser carets
- the Google Docs hidden input versus the click
- typing after a click, including the window-edge clamp
- scrolling invalidating the click
- AX disagreeing with a fresh click
- AX returning the whole text area
- rects outside the window or off every screen
- clicks in other apps, clicks that are too old, and clicks outside the window
- field and mouse fallbacks
- Google Docs/Sheets/Slides detection by bundle ID and title

On this Mac, `--caret-probe` against Terminal read the caret through `AXBoundsForRange` (a 1×19 rect at the prompt) and correctly ignored the whole-window element frame. The Google Docs path is covered by the unit cases; it hasn't yet been observed live in Chrome.

## Key check (what the setup assistant runs)

`swift run openflow-cli check-key [key]` runs the same check as the assistant's API key step. Real results:
- Valid key: ✅ key active · ✅ grok-voice-transcribe-2.0 connected in 354 ms · ✅ grok-4.3 answered in 1,178 ms.
- Bogus key: ❌ "SpaceXAI didn't accept this key…", and the other two checks are skipped.

## Installer

`scripts/make-dmg.sh` was mounted and inspected. Results: the binary is universal (`x86_64 arm64`), `codesign --verify --deep --strict` passes, the microphone entitlement is present, and no `xai-` key string is in the binary. File modes are world-readable. `spctl` rejects the local-signed build, as expected without notarization (see `distribution.md`).

## Over-the-air updates

These ran end to end on this Mac against a local feed (`127.0.0.1`), with nothing published:
- **Update:** the test build of 1.1.1 found 1.1.2 within a second of checking, downloaded it, verified the EdDSA signature, installed it, and relaunched as 1.1.2, 5 s after launch. 1.1.2 then reported "up to date".
- **After updating:** the signature verified (`--deep --strict`), the app was universal and not quarantined, settings were kept, Accessibility was still granted, and no Keychain access blocked the main thread.
- **Tampered update:** a 1.1.3 zip changed by one byte after signing was refused ("The update is improperly signed and could not be validated"). The app stayed on 1.1.2.
- **Bugs found and fixed:**
  - Hardened runtime library validation rejected Sparkle.framework, because a self-signed certificate has no Team ID.
  - The Keychain prompted after every build, which is why local builds now use a private key file.
  - Local test releases reused a build number. Build numbers now go above the feed's maximum.

## UI verification

`Openflow --snapshots <dir>` renders offscreen to PNG: every bubble state (connecting, waveform quiet and loud, hover ✕, spinner circle, check, error), every dashboard section, and all 8 setup-assistant steps. The API key step runs the live key check. with `NSView.cacheDisplay`, so no Screen Recording permission is needed. `Openflow --demo-bubble` plays the live bubble animation at screen center.

## What still needs a person

The live loop (global hotkey → microphone → paste into another app) needs Accessibility and Microphone permission for Openflow, and only the Mac's user can grant those in System Settings. Verify it after setup: Notes, Slack, a browser text field, a selection edit, and Esc.
