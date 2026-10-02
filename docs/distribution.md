# Sharing Openflow

## Current build

`dist/Openflow-1.1.0.dmg`: version 1.1.0 (build 2), Apple Silicon + Intel, 2.4 MB, signed with "Openflow Local Signing" and the hardened runtime. Not notarized.

## Security properties of the build

- **Hardened runtime on every real signature.** It blocks code injection and dynamic-library tampering. `Resources/Openflow.entitlements` grants only microphone input.
- **Developer tools aren't in release builds.** `--snapshots`, `--demo-bubble`, `--usage-file`, and the text probe are compiled only in debug. The release build keeps two coordinate-only diagnostics, `--caret-probe` and `--docs-probe`.
- **No secrets in the bundle.** Each user's API key is stored on their Mac:
  - **Developer ID builds:** in the Keychain. The Team ID keeps access stable across updates.
  - **Local-signed builds:** in `~/Library/Application Support/Openflow/api-key`, mode 600 inside a 700 folder, encrypted at rest by FileVault. Without a Team ID, macOS ties Keychain access to each binary's hash, which would prompt after every update.
- **Library validation.** Local-signed builds carry `com.apple.security.cs.disable-library-validation` (`Resources/Openflow-local.entitlements`), because a certificate without a Team ID can't pass library validation for the embedded Sparkle.framework. DYLD environment injection stays blocked. Developer ID builds use `Openflow.entitlements` with library validation on.
- **Network:** only `api.x.ai` over TLS (WebSocket for speech-to-text, HTTPS for cleanup and key checks). Cleanup calls use `store: false`.
- **On disk:** counts-only usage stats, plus a placement log with app bundle IDs and coordinates. No dictated text, transcripts, or window titles are ever written.
- **Never read:** password fields, and the field's text beyond the last 12 words before the cursor (unless the user selected it).

## Build the installer

```bash
scripts/make-dmg.sh          # → dist/Openflow-<version>.dmg (Apple Silicon + Intel, ~3 MB)
```

The DMG contains `Openflow.app`, an `Applications` shortcut to drag it onto, and `Read me first.txt`. No API key or personal settings are inside: each person pastes their own key in the setup assistant, and it is stored in their Keychain.

## Over-the-air updates (Sparkle 2.10)

Installed copies check `https://raw.githubusercontent.com/<RELEASES_REPO>/updates/appcast.xml` once a day. When a newer version is listed, the menu bar shows **Update to Openflow x.y.z…** (plus a badge on the icon) and the dashboard shows an **Update** banner. Clicking either opens Sparkle's window, with release notes and **Install & Relaunch**. Nothing installs without a click. **Check for Updates…** is always in the menu.

**One-time setup**
1. `gh auth login` with the GitHub account that should own the public releases repo. It doesn't have to be your active account.
2. Create `scripts/release.local.conf` (gitignored) with `RELEASES_REPO="<account>/Openflow"` and `GH_ACCOUNT="<account>"`. The feed lives on the repo's `updates` branch, which the script creates on first use, so releases never touch the code history.
3. Back up the update-signing key. It was created by Sparkle's `generate_keys` and lives in your login Keychain as "Private key for signing Sparkle updates". Export it with `.build/sparkle/dist/bin/generate_keys -x openflow-sparkle-key.txt`, put it in your password manager, then delete the file. **If this key is lost, installed copies can't take updates anymore** and everyone would have to reinstall manually.
4. Sparkle's command-line tools live in `.build/sparkle/dist/bin`. If `.build` is wiped, download `Sparkle-2.10.0.tar.xz` from Sparkle's GitHub releases and extract it there.

**Each release**
```bash
scripts/release.sh 1.1.2 --notes notes.md   # notes.md: one change per line
```
The script:
1. Bumps the version and build number. The build number goes above both the repo and the feed, because Sparkle compares build numbers.
2. Builds a universal app and DMG, zips the app, and signs the zip with the EdDSA key.
3. Creates the GitHub release `v1.1.2` with the zip and DMG. It creates the public repo on first use.
4. Only after the upload succeeds, adds the version to `appcast.xml`.

If a run is interrupted after the upload, `scripts/release.sh X.Y.Z --feed-only` publishes just the feed entry for the existing release. GitHub's raw-file cache can serve a stale result for a few minutes after a feed change.

It acts as `GH_ACCOUNT` through `gh auth token --user`, without switching your active gh account and without writing a token to disk.

**Safety**
- An update installs only if the zip's EdDSA signature matches `SUPublicEDKey` in the installed app, and the new app is code-signed with the same certificate. Tested: a download changed by one byte after signing was refused ("improperly signed").
- Builds must therefore be made on a Mac that has both the signing certificate and the update key.

**Testing an update locally** (nothing is published):
```bash
OPENFLOW_UPDATE_TEST=1 scripts/release.sh 1.1.2 --local /tmp/feed --base-url http://127.0.0.1:18765
(cd /tmp/feed && python3 -m http.server 18765 --bind 127.0.0.1) &
OPENFLOW_FEED_URL=http://127.0.0.1:18765/appcast.xml OPENFLOW_UPDATE_TEST=1 scripts/build-app.sh --install
```
A test build checks at launch and installs without a click. Progress is logged to `~/Library/Logs/Openflow/updates.log`. Reinstall a normal build afterwards (`scripts/build-app.sh --install`).

People with an Openflow from before 1.1.1 install the first updater-enabled DMG manually once; every later version arrives through the Update button.

## Two ways to sign it

| | Local-signed build | Developer ID build |
|---|---|---|
| Signed with | "Openflow Local Signing" (self-signed, this Mac) | Your company's **Developer ID Application** certificate |
| Notarized by Apple | No | Yes (`notarytool`, stapled) |
| First launch on someone else's Mac | Blocked once; they click **System Settings → Privacy & Security → Open Anyway** | Opens normally |
| Command | `scripts/make-dmg.sh` | `SIGN_IDENTITY="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=openflow-notary scripts/make-dmg.sh` |

For the company-ready build you need:
1. Access to the company Apple Developer team and its **Developer ID Application** certificate (with private key) in your login keychain.
2. A notarization profile, stored once:
   `xcrun notarytool store-credentials openflow-notary --apple-id you@company.com --team-id TEAMID` (uses an app-specific password).
3. Ideally, a bundle ID under the company's domain. Change it in both `Resources/Info.plist` and `Sources/OpenflowCore/AppIdentity.swift`; the build refuses to run if they differ.

The build script switches to the hardened runtime and timestamping automatically for Developer ID identities. `Resources/Openflow.entitlements` grants microphone access under the hardened runtime.

## What each person does

1. Open the DMG and drag Openflow to Applications.
2. Open it. For local-signed builds, approve it once under Privacy & Security → Open Anyway.
3. The **setup assistant** opens and checks each step on their Mac:
   - **API key**: validates the key, opens a real speech-to-text connection, and makes a one-word Grok 4.3 call. A key restricted to other models is flagged with a clear message.
   - **Microphone**: requests access, then shows a live level meter ("We hear you").
   - **Accessibility**: opens the right System Settings pane and continues by itself once Openflow is switched on.
   - **Shortcut**: pick a preset or record one, then press it to confirm it's detected.
   - **Try it**: a practice box. Hold the shortcut and say the sample sentence; the step confirms the real paste and its latency.
   - **About you** (optional), then **open at login**.

The assistant can be rerun from the menu bar (**Setup assistant…**) or **Openflow → Setup**.

## Updating

There is no auto-update yet. Ship a new DMG with a higher `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist`. Keep signing with the **same** certificate and bundle ID: macOS keys the Accessibility and Microphone grants to them, so people keep their permissions across updates.

## Before a company-wide rollout

- **Signing**: Developer ID signing and notarization (see above). Without it, every person sees the "Open Anyway" step.
- **Pilot**: run a small group of daily users for a week across Slack, Chrome, Google Docs, Notion, VS Code, Terminal, and Mail, including selection edits and non-English speakers.
- **Keys and spend**: decide whether people use personal keys or team keys with per-person limits. Openflow's dashboard shows each person's own spend.
- **Data**: audio, transcripts, and up to 600 characters before the cursor (password fields excluded) go to the SpaceXAI API with `store: false`. Turn off "Use the text before the cursor as context" under Dictation if that's too much for a team.
- **Updates**: there's no auto-updater yet; a Sparkle feed would be the next step.
