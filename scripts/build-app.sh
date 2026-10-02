#!/usr/bin/env bash
# Builds Openflow.app and optionally installs it to /Applications.
#   scripts/build-app.sh                 # Apple Silicon build into .build/app/Openflow.app
#   scripts/build-app.sh --install       # build, replace /Applications/Openflow.app, relaunch
#   UNIVERSAL=1 scripts/build-app.sh     # Apple Silicon + Intel (what scripts/make-dmg.sh uses)
#
# The bundle is built inside the hidden .build/ folder on purpose: Spotlight/Launch Services skip it,
# so macOS only ever knows one "Openflow" (the one in /Applications). Two registered copies with the
# same bundle ID make permission prompts and the System Settings "+" picker point at the wrong one.
#
# Signing, first match wins:
#   SIGN_IDENTITY env var  → e.g. "Developer ID Application: Your Co (TEAMID)"
#   a "Developer ID Application" identity in the keychain → hardened runtime + timestamp (notarizable)
#   "Openflow Local Signing" (scripts/create-signing-cert.sh) → keeps permissions across rebuilds
#   ad-hoc
set -euo pipefail
cd "$(dirname "$0")/.."

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)
if ! grep -q "bundleID = \"$BUNDLE_ID\"" Sources/OpenflowCore/AppIdentity.swift; then
  echo "Bundle ID mismatch: Info.plist has $BUNDLE_ID but AppIdentity.swift differs" >&2
  exit 1
fi

APP=.build/app/Openflow.app
BIN_DIR=.build/app-bin
mkdir -p "$BIN_DIR"

build_arch() {  # $1 = arm64 | x86_64 ; copies the binary out before the next build overwrites it
  local triple="$1-apple-macosx14.0"
  swift build -c release --product Openflow --triple "$triple"
  cp "$(swift build -c release --product Openflow --triple "$triple" --show-bin-path)/Openflow" "$BIN_DIR/Openflow-$1"
}

build_arch arm64
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  build_arch x86_64
  lipo -create "$BIN_DIR/Openflow-arm64" "$BIN_DIR/Openflow-x86_64" -output "$BIN_DIR/Openflow"
else
  cp "$BIN_DIR/Openflow-arm64" "$BIN_DIR/Openflow"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Openflow" "$APP/Contents/MacOS/Openflow"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sparkle (over-the-air updates): the universal framework SwiftPM unpacked from the pinned binary target.
SPARKLE=$(find .build -path '*/Products/Release/Sparkle.framework' -maxdepth 5 -type d | head -1)
[[ -z "$SPARKLE" ]] && SPARKLE=$(find .build -path '*/release/Sparkle.framework' -maxdepth 5 -type d | head -1)
[[ -d "$SPARKLE" ]] || { echo "Sparkle.framework not found in .build" >&2; exit 1; }
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

# Update feed from scripts/release.conf (or OPENFLOW_FEED_URL). Without one, the updater stays off.
source scripts/release.conf
FEED_URL="${OPENFLOW_FEED_URL:-}"
if [[ -z "$FEED_URL" && -n "${RELEASES_REPO:-}" ]]; then
  FEED_URL="https://raw.githubusercontent.com/$RELEASES_REPO/${APPCAST_BRANCH:-updates}/appcast.xml"
fi
if [[ -n "$FEED_URL" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$APP/Contents/Info.plist"
fi
# Version override for release builds (scripts/release.sh) without editing Resources/Info.plist.
[[ -n "${OPENFLOW_VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $OPENFLOW_VERSION" "$APP/Contents/Info.plist"
[[ -n "${OPENFLOW_BUILD:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $OPENFLOW_BUILD" "$APP/Contents/Info.plist"
# Local end-to-end update tests only: check at launch, install without a click
# (OPENFLOW_UPDATE_PROBE_TEST=1: only the Updates page's in-page check, never installs).
if [[ "${OPENFLOW_UPDATE_TEST:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Add :OpenflowUpdateTest bool true" -c "Set :SUAllowsAutomaticUpdates true" \
    -c "Add :SUAutomaticallyUpdate bool true" "$APP/Contents/Info.plist"
  [[ "${OPENFLOW_UPDATE_PROBE_TEST:-0}" == "1" ]] && /usr/libexec/PlistBuddy -c "Add :OpenflowUpdateProbeTest bool true" "$APP/Contents/Info.plist"
fi

# Icon: render once, cache in .build.
ICNS=.build/AppIcon.icns
if [[ ! -f "$ICNS" || scripts/make-icon.swift -nt "$ICNS" ]]; then
  TMP=$(mktemp -d)
  swift scripts/make-icon.swift "$TMP/icon.png" >/dev/null
  mkdir -p "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o "$ICNS"
  rm -rf "$TMP"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"   # Sparkle's MIT license travels with the app

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true)
fi
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "Openflow Local Signing"; then
  IDENTITY="Openflow Local Signing"
fi
IDENTITY="${IDENTITY:--}"
# Sparkle's helpers must carry the same signature as the app (inside-out, as Sparkle documents).
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
RT=(); [[ "$IDENTITY" != "-" ]] && RT=(--options runtime)
for part in "$SPK/XPCServices/Installer.xpc" "$SPK/Autoupdate" "$SPK/Updater.app"; do
  [[ -e "$part" ]] && codesign --force "${RT[@]}" --sign "$IDENTITY" "$part"
done
[[ -e "$SPK/XPCServices/Downloader.xpc" ]] && codesign --force "${RT[@]}" --preserve-metadata=entitlements --sign "$IDENTITY" "$SPK/XPCServices/Downloader.xpc"
codesign --force "${RT[@]}" --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"

# Hardened runtime for every real signature (blocks code injection / DYLD tampering); the entitlement
# keeps microphone access under it. Developer ID builds also get a secure timestamp for notarization.
if [[ "$IDENTITY" == Developer\ ID\ Application* ]]; then
  codesign --force --options runtime --timestamp --entitlements Resources/Openflow.entitlements \
    --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
elif [[ "$IDENTITY" != "-" ]]; then
  # No Apple Team ID: library validation would reject the embedded Sparkle.framework (see the entitlements file).
  codesign --force --options runtime --entitlements Resources/Openflow-local.entitlements \
    --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --entitlements Resources/Openflow.entitlements --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
fi
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true   # keep the build copy out of Launch Services
echo "Built $APP ($BUNDLE_ID $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"), $(lipo -archs "$APP/Contents/MacOS/Openflow"), signed with: $IDENTITY, feed: ${FEED_URL:-none})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Openflow 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Openflow.app
  cp -R "$APP" /Applications/Openflow.app
  "$LSREGISTER" -f /Applications/Openflow.app
  open /Applications/Openflow.app
  echo "Installed /Applications/Openflow.app and launched"
fi
