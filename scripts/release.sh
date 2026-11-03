#!/bin/zsh
# Builds a signed, notarized Zigzag release and its Sparkle appcast.
#
# One-time setup:
#   xcrun notarytool store-credentials zigzag-notary --apple-id <you> --team-id 432GL3WKY2
#   (Sparkle's EdDSA private key lives in the login keychain; see generate_keys.)
#
# Usage: scripts/release.sh            build, sign, notarize, staple, appcast
#        scripts/release.sh --publish  also upload the build and appcast to zigzagbrowser.com
#        scripts/release.sh --local    build and sign with Developer ID only, to use on this Mac
#        scripts/release.sh --beta N   build version-beta.N and publish it to the beta feed only (Settings ›
#                                      General › Beta updates); no DMG, website, GitHub release or Homebrew
#        (plain run: build, sign, notarize and staple; --publish also writes the appcast and uploads both)
# Before releasing: add the version's section to CHANGELOG.md (New and Fixed); every place notes appear reads it.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${NOTARY_PROFILE:-zigzag-notary}
SERVER=${SITE_SERVER:-bwh}
SITE_HOST=zigzagbrowser.com
SITE_ROOT=/www/wwwroot/zigzagbrowser.com
OUT=build/release
# Tidier build output when xcbeautify is installed; otherwise just the lines that matter.
pretty() { if command -v xcbeautify >/dev/null; then xcbeautify; else grep -E "error:|ARCHIVE|EXPORT|BUILD" || true; fi; }
rm -rf "$OUT" && mkdir -p "$OUT/updates"

# The notes come first: CHANGELOG.md needs a section for the version being released, or nothing is built.
PLANNED=$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
grep -q "^## \[$PLANNED\]" CHANGELOG.md || { echo "CHANGELOG.md has no section for $PLANNED. Add one, then release."; exit 1; }

# A beta is the planned version with a suffix (0.5.0-beta.2), and its notes are the planned version's.
VERSION_OVERRIDE=()
if [[ "${1:-}" == "--beta" ]]; then
  [[ "${2:-}" == <-> ]] || { echo "Usage: scripts/release.sh --beta N"; exit 1; }
  VERSION_OVERRIDE=(MARKETING_VERSION="$PLANNED-beta.$2")
fi

# Only --publish and --beta write a feed; a plain or --local run builds without the network or Sparkle's tools.
PUBLISHING=false
if [[ "${1:-}" == "--publish" || "${1:-}" == "--beta" ]]; then PUBLISHING=true; fi

# Sparkle orders updates by build number: one no higher than what either feed already offers would never arrive.
BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
if $PUBLISHING; then
  for FEED in appcast beta; do
    LIVE=$(curl -fsSL "https://$SITE_HOST/updates/$FEED.xml" 2>/dev/null | grep -oE 'sparkle:version="?>?[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1 || true)
    if [[ -n "$LIVE" && "$BUILD" -le "$LIVE" ]]; then
      echo "CURRENT_PROJECT_VERSION is $BUILD but the $FEED feed already has build $LIVE. Raise it in project.yml, then release."
      exit 1
    fi
  done
fi

xcodegen generate -q
xcodebuild -project Zigzag.xcodeproj -scheme Zigzag -configuration Release -allowProvisioningUpdates \
  -derivedDataPath build/rd -archivePath "$OUT/Zigzag.xcarchive" archive "${VERSION_OVERRIDE[@]}" | pretty
[[ -d "$OUT/Zigzag.xcarchive" ]] || { echo "Archive failed"; exit 1; }

# Exporting signs with Developer ID and its provisioning profile (which carries the Keychain access group).
xcodebuild -exportArchive -archivePath "$OUT/Zigzag.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates | pretty
APP="$OUT/export/Zigzag.app"
[[ -d "$APP" ]] || { echo "Export failed"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier"

if [[ "${1:-}" == "--local" ]]; then
  echo "Done (not notarized): $APP"
  exit 0
fi

ZIP="$OUT/updates/Zigzag-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Notarizing…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP" && ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"

# The release notes for the update window: this version's section of CHANGELOG.md as HTML, and for a GitHub release
# as Markdown (build/release/notes.md, for --notes-file). A beta uses the section of the version it leads up to.
write_notes() {
  python3 - "$VERSION" "$PLANNED" "$OUT" <<'PY'
import html, sys
version, planned, out = sys.argv[1], sys.argv[2], sys.argv[3]
sections, inside = [], False
for raw in open("CHANGELOG.md", encoding="utf-8"):
    line = raw.strip()
    if line.startswith("## "):
        if inside: break
        inside = line.startswith(f"## [{planned}]")
    elif inside and line.startswith("### "): sections.append((line[4:], []))
    elif inside and line.startswith("- ") and sections: sections[-1][1].append(line[2:])
if not sections: sys.exit(f"CHANGELOG.md has no notes for {planned}")
style = ("<style>:root{color-scheme:light dark}body{font:13px -apple-system,sans-serif;margin:0 4px}"
         "h3{font-size:13px;margin:14px 0 6px}ul{margin:0;padding-left:18px}li{margin:4px 0;line-height:1.4}</style>")
body = "".join(f"<h3>{html.escape(t)}</h3><ul>" + "".join(f"<li>{html.escape(i)}</li>" for i in items) + "</ul>" for t, items in sections)
open(f"{out}/updates/Zigzag-{version}.html", "w", encoding="utf-8").write(style + body)
md = "\n\n".join(f"## {t}\n" + "\n".join(f"- {i}" for i in items) for t, items in sections)
md += ("\n\nDownload the DMG, open it, and drag Zigzag to Applications. Requires macOS 15.4 or later. Updates install automatically."
       "\n\nEvery version's notes: https://zigzagbrowser.com/release-notes\n")
open(f"{out}/notes.md", "w", encoding="utf-8").write(md)
PY
}
# Sparkle's tool comes with the package the archive just resolved.
if $PUBLISHING; then
  GENERATE=$(find build/rd/SourcePackages -name generate_appcast -type f -perm +111 2>/dev/null | head -1 || true)
  [[ -x "$GENERATE" ]] || { echo "Sparkle's generate_appcast wasn't found under build/rd."; exit 1; }
fi

if [[ "${1:-}" == "--beta" ]]; then
  # Only the beta feed: everyone else stays on the stable one. The zip sits with the other releases.
  write_notes
  echo "Writing the beta feed…"
  "$GENERATE" --download-url-prefix "https://$SITE_HOST/releases/" "$OUT/updates"
  mv "$OUT/updates/appcast.xml" "$OUT/updates/beta.xml"
  rsync -a "$ZIP" "$SERVER:$SITE_ROOT/releases/"
  rsync -a "$OUT/updates/beta.xml" "$SERVER:$SITE_ROOT/updates/beta.xml"
  echo "Done: $VERSION is on the beta feed."
  exit 0
fi

# The DMG people download: the app beside an Applications shortcut, signed, notarized and stapled itself, so it
# opens without a warning on a Mac that has never seen Zigzag. (Updates use the zip above.)
# The window it opens to: Zigzag on the left, Applications on the right, an arrow between, the wordmark above.
# 500 tall: Finder's tab and status bars take ~100 of it, leaving the 400 the background is drawn for.
DMG="$OUT/Zigzag-$VERSION.dmg"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Zigzag.app"
SetFile -a E "$STAGE/Zigzag.app"
rm -f "$DMG"
create-dmg --volname "Zigzag" --volicon "$APP/Contents/Resources/AppIcon.icns" \
  --background scripts/dmg-background.tiff --window-pos 200 160 --window-size 640 500 --text-size 13 \
  --icon-size 112 --icon "Zigzag.app" 180 200 --hide-extension "Zigzag.app" --app-drop-link 460 200 \
  --no-internet-enable --format UDZO "$DMG" "$STAGE" >/dev/null
rm -rf "$STAGE"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
codesign --sign "$IDENTITY" --timestamp "$DMG"
echo "Notarizing the DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

if [[ "${1:-}" == "--publish" ]]; then
  # The appcast needs Sparkle's signing key from the keychain, which may ask; only publishing needs it.
  # Builds and the feed are served from zigzagbrowser.com (reachable everywhere, no GitHub needed).
  write_notes
  echo "Writing appcast…"
  "$GENERATE" --download-url-prefix "https://$SITE_HOST/releases/" "$OUT/updates"
  echo "Uploading to $SITE_HOST…"
  rsync -a "$ZIP" "$DMG" "$SERVER:$SITE_ROOT/releases/"
  ssh "$SERVER" "ln -sfn Zigzag-$VERSION.dmg $SITE_ROOT/releases/Zigzag-latest.dmg && ln -sfn Zigzag-$VERSION.zip $SITE_ROOT/releases/Zigzag-latest.zip"
  # The feed goes last, so no Mac is offered an update before its zip is there.
  rsync -a "$OUT/updates/appcast.xml" "$SERVER:$SITE_ROOT/updates/appcast.xml"
  # The beta feed carries each stable release too, so anyone on a beta moves on to it, unless its betas already
  # lead up to a later version (0.5.0-beta.3 leads up to 0.5.0): replacing it then would move them back.
  if BETA_FEED=$(curl -fsSL "https://$SITE_HOST/updates/beta.xml"); then
    NEWEST_BETA=$(print -r -- "$BETA_FEED" | grep -oE '[0-9]+(\.[0-9]+)*-beta\.[0-9]+' | sed -E 's/-beta\.[0-9]+$//' \
      | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)
    if [[ -z "$NEWEST_BETA" ]] || zsh scripts/version-at-least.sh "$VERSION" "$NEWEST_BETA"; then
      rsync -a "$OUT/updates/appcast.xml" "$SERVER:$SITE_ROOT/updates/beta.xml"
    else
      echo "The beta feed is left as it is: its betas lead up to $NEWEST_BETA, after $VERSION."
    fi
  else
    echo "The beta feed is left as it is: it couldn't be read to check its betas against $VERSION."
  fi
  # The website's changelog page, with this version on top.
  # deploy.sh holds the server's details, so it's kept out of git: a clean checkout (a release worktree) uses the one
  # in the main checkout, with this checkout's site files.
  DEPLOY=site/deploy.sh
  [[ -f "$DEPLOY" ]] || DEPLOY="$(git rev-parse --path-format=absolute --git-common-dir)/../site/deploy.sh"
  if [[ -f "$DEPLOY" ]]; then
    [[ "$DEPLOY" == site/deploy.sh ]] || cp "$DEPLOY" site/deploy.sh
    zsh site/deploy.sh
  else
    echo "No site/deploy.sh found: the website wasn't updated."
  fi
  # The Homebrew cask, in a checkout of ZigaoWang/homebrew-tap beside this repository. It points at the DMG on
  # GitHub Releases, so push the tap only after `gh release create`.
  TAP="${ZIGZAG_TAP:-../homebrew-tap}"
  if [[ -f "$TAP/Casks/zigzag.rb" ]]; then
    SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
    sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/zigzag.rb"
    git -C "$TAP" commit -q -am "zigzag $VERSION"
    echo "Homebrew cask bumped to $VERSION in $TAP; push it after the GitHub release is up."
  fi
fi
echo "Done: $ZIP and $DMG"
