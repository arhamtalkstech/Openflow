#!/usr/bin/env bash
# Openflow installer: downloads the latest release from GitHub, verifies it, and installs it.
#
#   curl -fsSL https://raw.githubusercontent.com/arhamtalkstech/Openflow/main/install.sh | bash
#
# Options (environment variables):
#   OPENFLOW_VERSION=1.1.2   install a specific version instead of the latest
#   OPENFLOW_DIR=~/Applications   install somewhere other than /Applications
#
# What it does:
#   1. Reads the latest version from the update feed (or uses OPENFLOW_VERSION).
#   2. Downloads Openflow-<version>.zip from this repository's GitHub Releases over HTTPS.
#   3. Verifies the zip's SHA-256 checksum (published with the release) and the app's code signature.
#   4. Quits a running Openflow, installs the app, and launches it.
# Files downloaded with curl aren't marked as "downloaded from the internet", so macOS opens the app
# without the "unidentified developer" prompt. Re-run the same command at any time to update.
set -euo pipefail

REPO="arhamtalkstech/Openflow"
FEED="https://raw.githubusercontent.com/$REPO/updates/appcast.xml"
BUNDLE_ID="com.openflow.Openflow"

TMP_DIR=""   # global: the EXIT trap runs after main() has returned
cleanup() { [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; return 0; }
trap cleanup EXIT

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

main() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "Openflow runs on macOS only."
  local macos major
  macos=$(sw_vers -productVersion); major=${macos%%.*}
  (( major >= 14 )) || fail "Openflow needs macOS 14 or later (this Mac has $macos)."

  local version="${OPENFLOW_VERSION:-}"
  if [[ -z "$version" ]]; then
    local feed
    feed=$(curl -fsSL "$FEED") || fail "Couldn't read the latest version from $FEED"
    version=$(grep -m1 -oE '<sparkle:shortVersionString>[0-9]+\.[0-9]+\.[0-9]+' <<<"$feed" | sed 's/.*>//' || true)
    [[ -n "$version" ]] || fail "Couldn't find a version in the update feed."
  fi
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid version: $version"
  say "Installing Openflow $version"

  TMP_DIR=$(mktemp -d)
  local tmp="$TMP_DIR"
  local base="https://github.com/$REPO/releases/download/v$version"
  curl -fL --progress-bar -o "$tmp/Openflow.zip" "$base/Openflow-$version.zip" \
    || fail "Download failed. Check the version and your connection."

  # Integrity: the checksum published with the release must match the download.
  local expected actual
  expected=$(curl -fsSL "$base/Openflow-$version.zip.sha256" | awk '{print $1}') \
    || fail "Couldn't download the release checksum."
  actual=$(shasum -a 256 "$tmp/Openflow.zip" | awk '{print $1}')
  [[ -n "$expected" && "$expected" == "$actual" ]] || fail "Checksum mismatch: the download is not the published release."
  say "Checksum verified"

  ditto -x -k "$tmp/Openflow.zip" "$tmp/unpacked"
  local app="$tmp/unpacked/Openflow.app"
  [[ -d "$app" ]] || fail "The download doesn't contain Openflow.app."
  codesign --verify --deep --strict "$app" 2>/dev/null || fail "The app's code signature is invalid."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$BUNDLE_ID" ]] \
    || fail "Unexpected app identity."
  say "Code signature verified"

  # /Applications when writable (admin accounts), otherwise ~/Applications.
  local dest="${OPENFLOW_DIR:-/Applications}"
  if [[ ! -w "$dest" ]]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
  fi

  if pgrep -x Openflow >/dev/null; then
    say "Quitting the running Openflow"
    pkill -x Openflow || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Openflow >/dev/null || break; sleep 0.3; done
    pkill -x Openflow 2>/dev/null || true
  fi

  rm -rf "$dest/Openflow.app"
  ditto "$app" "$dest/Openflow.app"
  xattr -dr com.apple.quarantine "$dest/Openflow.app" 2>/dev/null || true
  say "Installed $dest/Openflow.app"

  open "$dest/Openflow.app"
  cat <<EOF

Openflow $version is running. Look for the waveform icon in the menu bar.
The setup assistant walks you through your SpaceXAI API key (https://console.x.ai),
microphone, and Accessibility. Updates install from the app (Openflow → Updates).
EOF
}

main "$@"
