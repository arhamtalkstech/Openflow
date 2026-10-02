#!/usr/bin/env bash
# Publishes an Openflow update that every installed copy picks up (menu bar → "Update to x.y.z…").
#
#   scripts/release.sh 1.1.2 --notes notes.md          # GitHub: release assets + appcast.xml in RELEASES_REPO
#   scripts/release.sh 1.1.2 --local DIR --base-url URL # local test feed (nothing is published)
#
# Steps: bump version → universal build + DMG → zip → EdDSA-sign the zip with the Sparkle key in your
# Keychain → upload the zip/DMG → add the version to appcast.xml (only after the upload succeeded).
# Settings: scripts/release.conf (RELEASES_REPO, GH_ACCOUNT). The gh account's token is used for this
# script only (`gh auth token --user`); your active gh account is not changed and no token is written to disk.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"; shift || true
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/release.sh X.Y.Z [--notes FILE] [--local DIR --base-url URL]" >&2; exit 2; }
NOTES=""; LOCAL_DIR=""; BASE_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --local) LOCAL_DIR="$2"; shift 2 ;;
    --base-url) BASE_URL="${2%/}"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
source scripts/release.conf
SIGN_UPDATE=.build/sparkle/dist/bin/sign_update
[[ -x "$SIGN_UPDATE" ]] || { echo "Missing $SIGN_UPDATE (download Sparkle's release tools, see docs/distribution.md)" >&2; exit 1; }

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
# Sparkle compares build numbers: always go above both the repo and everything already in the feed.
max_feed_build() { grep -oE '<sparkle:version>[0-9]+' 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1; }
REPO_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)

if [[ -n "$LOCAL_DIR" ]]; then
  [[ -n "$BASE_URL" ]] || { echo "--local needs --base-url" >&2; exit 2; }
  FEED_BUILD=$(max_feed_build < "$LOCAL_DIR/appcast.xml" 2>/dev/null || true)
  BUILD=$(( (REPO_BUILD > ${FEED_BUILD:-0} ? REPO_BUILD : ${FEED_BUILD:-0}) + 1 ))
  export OPENFLOW_FEED_URL="$BASE_URL/appcast.xml"
  DOWNLOAD_URL="$BASE_URL/Openflow-$VERSION.zip"
else
  [[ -n "$RELEASES_REPO" && -n "$GH_ACCOUNT" ]] || { echo "Set RELEASES_REPO and GH_ACCOUNT in scripts/release.conf" >&2; exit 1; }
  GH_TOKEN=$(gh auth token --user "$GH_ACCOUNT") || { echo "gh has no login for $GH_ACCOUNT (run: gh auth login)" >&2; exit 1; }
  export GH_TOKEN
  DOWNLOAD_URL="https://github.com/$RELEASES_REPO/releases/download/v$VERSION/Openflow-$VERSION.zip"
  BRANCH="${APPCAST_BRANCH:-updates}"
  FEED_BUILD=$(gh api "repos/$RELEASES_REPO/contents/appcast.xml?ref=$BRANCH" --jq .content 2>/dev/null | base64 --decode 2>/dev/null | max_feed_build || true)
  BUILD=$(( (REPO_BUILD > ${FEED_BUILD:-0} ? REPO_BUILD : ${FEED_BUILD:-0}) + 1 ))
  # The repo version is the source of truth for releases.
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Resources/Info.plist
fi
echo "Releasing Openflow $VERSION (build $BUILD; previous $CURRENT)"

OPENFLOW_VERSION="$VERSION" OPENFLOW_BUILD="$BUILD" scripts/make-dmg.sh
ZIP="dist/Openflow-$VERSION.zip"
DMG="dist/Openflow-$VERSION.dmg"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent .build/app/Openflow.app "$ZIP"
SIG_ATTRS=$("$SIGN_UPDATE" "$ZIP")   # sparkle:edSignature="…" length="…"
echo "Signed: $SIG_ATTRS"

NOTES_HTML=$(python3 - "$NOTES" <<'EOF'
import html, sys
path = sys.argv[1]
lines = [l.strip() for l in open(path).read().splitlines()] if path else []
items = [l.lstrip("-*• ").strip() for l in lines if l.strip()]
print("<ul>" + "".join(f"<li>{html.escape(i)}</li>" for i in items) + "</ul>" if items else "<p>Improvements and fixes.</p>")
EOF
)

# appcast.xml: newest first, last 10 versions kept.
make_appcast() {  # $1 = existing appcast file ("" if none), writes to stdout
  python3 - "$1" "$VERSION" "$BUILD" "$DOWNLOAD_URL" "$SIG_ATTRS" "$NOTES_HTML" <<'EOF'
import re, sys, email.utils
existing, version, build, url, sig, notes = sys.argv[1:7]
old_items = []
if existing:
    text = open(existing).read()
    old_items = [m for m in re.findall(r"<item>.*?</item>", text, re.S) if f"<sparkle:shortVersionString>{version}<" not in m]
item = f"""<item>
      <title>Openflow {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{url}" {sig} type="application/octet-stream"/>
    </item>"""
items = [item] + old_items[:9]
print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Openflow</title>
    {chr(10).join("    " + i for i in items).strip()}
  </channel>
</rss>""")
EOF
}

if [[ -n "$LOCAL_DIR" ]]; then
  mkdir -p "$LOCAL_DIR"
  mv "$ZIP" "$LOCAL_DIR/"
  rm -f "$DMG"   # local test builds point at a test feed: keep them out of dist/
  EXISTING=""; [[ -f "$LOCAL_DIR/appcast.xml" ]] && EXISTING="$LOCAL_DIR/appcast.xml"
  ZIP="$LOCAL_DIR/Openflow-$VERSION.zip"
  make_appcast "$EXISTING" > "$LOCAL_DIR/appcast.xml.new" && mv "$LOCAL_DIR/appcast.xml.new" "$LOCAL_DIR/appcast.xml"
  echo "Local feed: $LOCAL_DIR/appcast.xml → $DOWNLOAD_URL"
  exit 0
fi

# GitHub: the repo must exist; the feed branch is created on first use (from the default branch).
gh repo view "$RELEASES_REPO" >/dev/null || { echo "Repo $RELEASES_REPO not found for $GH_ACCOUNT" >&2; exit 1; }
if ! gh api "repos/$RELEASES_REPO/branches/$BRANCH" >/dev/null 2>&1; then
  BASE_SHA=$(gh api "repos/$RELEASES_REPO/commits/HEAD" --jq .sha)
  gh api -X POST "repos/$RELEASES_REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$BASE_SHA" >/dev/null
fi
NOTES_FILE=$(mktemp); trap 'rm -f "$NOTES_FILE"' EXIT
[[ -n "$NOTES" ]] && cp "$NOTES" "$NOTES_FILE" || echo "Improvements and fixes." > "$NOTES_FILE"
gh release create "v$VERSION" "$ZIP" "$DMG" --repo "$RELEASES_REPO" --title "Openflow $VERSION" --notes-file "$NOTES_FILE"

# Then publish the feed entry (GitHub contents API; no local clone, no token on disk).
TMP_OLD=$(mktemp); TMP_NEW=$(mktemp)
SHA=$(gh api "repos/$RELEASES_REPO/contents/appcast.xml?ref=$BRANCH" --jq .sha 2>/dev/null || true)
if [[ -n "$SHA" ]]; then
  gh api "repos/$RELEASES_REPO/contents/appcast.xml?ref=$BRANCH" --jq .content | base64 --decode > "$TMP_OLD"
  make_appcast "$TMP_OLD" > "$TMP_NEW"
else
  make_appcast "" > "$TMP_NEW"
fi
gh api -X PUT "repos/$RELEASES_REPO/contents/appcast.xml" -f message="Openflow $VERSION" -f branch="$BRANCH" \
  -f content="$(base64 < "$TMP_NEW" | tr -d '\n')" ${SHA:+-f sha="$SHA"} >/dev/null
rm -f "$TMP_OLD" "$TMP_NEW"
echo "Published Openflow $VERSION: https://github.com/$RELEASES_REPO/releases/tag/v$VERSION"
echo "Feed: https://raw.githubusercontent.com/$RELEASES_REPO/$BRANCH/appcast.xml (installed copies see it within a day, or via Check for Updates)"
