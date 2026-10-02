#!/usr/bin/env bash
# Packages Openflow into a drag-to-install DMG: dist/Openflow-<version>.dmg
#
#   scripts/make-dmg.sh
#
# Company-wide distribution without Gatekeeper warnings needs Apple Developer ID signing + notarization:
#   SIGN_IDENTITY="Developer ID Application: Your Co (TEAMID)" \
#   NOTARY_PROFILE=openflow-notary \
#   scripts/make-dmg.sh
# where the profile was stored once with:
#   xcrun notarytool store-credentials openflow-notary --apple-id you@company.com --team-id TEAMID
# Without those, the DMG is signed with the local certificate and recipients must approve it once
# (System Settings → Privacy & Security → Open Anyway). The DMG includes those steps.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${OPENFLOW_VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)}
UNIVERSAL=1 scripts/build-app.sh

STAGE=.build/dmg-stage
OUT=dist/Openflow-$VERSION.dmg
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R .build/app/Openflow.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

NOTARIZED=0
[[ -n "${NOTARY_PROFILE:-}" ]] && NOTARIZED=1
if [[ $NOTARIZED == 1 ]]; then
  cat > "$STAGE/Read me first.txt" <<EOF
Openflow $VERSION

1. Drag Openflow onto the Applications folder.
2. Open Openflow from Applications (or Spotlight).
3. Follow the setup assistant: paste your SpaceXAI API key (console.x.ai), allow the microphone,
   switch on Accessibility for Openflow, and try a dictation.
EOF
else
  cat > "$STAGE/Read me first.txt" <<EOF
Openflow $VERSION (not notarized by Apple)

1. Drag Openflow onto the Applications folder.
2. Open Openflow from Applications. macOS will say it can't verify the developer. Click Done.
3. Open System Settings → Privacy & Security, scroll down to "Openflow was blocked…" and click
   Open Anyway, then confirm. You only do this once.
4. Follow the setup assistant: paste your SpaceXAI API key (console.x.ai), allow the microphone,
   switch on Accessibility for Openflow, and try a dictation.
EOF
fi

chmod -R u+rwX,go+rX "$STAGE"   # readable for every account on the recipient's Mac
rm -f "$OUT"
hdiutil create -volname "Openflow" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$OUT" >/dev/null
IDENTITY=$(codesign -dvv .build/app/Openflow.app 2>&1 | sed -n 's/^Authority=//p' | head -1)
if [[ -n "$IDENTITY" ]]; then codesign --force --sign "$IDENTITY" --identifier com.openflow.Openflow.dmg "$OUT"; fi

if [[ $NOTARIZED == 1 ]]; then
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
fi
rm -rf "$STAGE"
echo "Created $OUT ($(du -h "$OUT" | cut -f1), notarized: $([[ $NOTARIZED == 1 ]] && echo yes || echo no))"
