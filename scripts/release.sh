#!/bin/zsh
# Builds a signed, notarized Zigzag release and its Sparkle appcast.
#
# One-time setup:
#   xcrun notarytool store-credentials zigzag-notary --apple-id <you> --team-id 432GL3WKY2
#   (Sparkle's EdDSA private key lives in the login keychain; see generate_keys.)
#
# Usage: scripts/release.sh            build, sign, notarize, staple
#        scripts/release.sh --publish  also upload the build and appcast to zigzagbrowser.com
#        scripts/release.sh --local    build and sign with Developer ID only, to use on this Mac
#        scripts/release.sh --beta N   build version-beta.N and publish it to the beta feed only (Settings ›
#                                      General › Beta updates); no DMG, website, GitHub release or Homebrew
# Before releasing: add the version's section to CHANGELOG.md (New and Fixed); every place notes appear reads it.
# Add it in Chinese to CHANGELOG.zh-Hans.md too (新功能 and 修复), for the app and the update window on a Mac in
# Chinese; without it they show the English, and this script warns.
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
# The Chinese notes should come with them. Without, a Mac in Chinese shows the English ones, so it's only a warning.
grep -q "^## \[$PLANNED\]" CHANGELOG.zh-Hans.md || echo "Warning: CHANGELOG.zh-Hans.md has no section for $PLANNED, so Chinese readers get the English notes."

# The ad blocking scriptlets a release accepts are pinned by hash in the app: one older than Ghostery's newest keeps
# working, but misses its fixes. Pinning is a code change, so it's for before the release, not here.
scripts/pin-scriptlets.sh --check || echo "Warning: the pinned scriptlets aren't the newest. Run scripts/pin-scriptlets.sh, commit, then release."

# The network to the site and to Apple can drop for a moment: each upload is tried a few times before giving up.
again() { local n; for n in 1 2 3 4 5; do "$@" && return 0; echo "Retrying ($n): $1"; sleep 5; done; return 1; }

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
    # Only a missing feed (404) means "nothing live yet": any other failure stops here, rather than publishing a
    # build number that may be no higher than the live one.
    STATUS=$(curl -sS --retry 6 --retry-all-errors --retry-delay 5 --max-time 30 -o /tmp/zigzag-live-$FEED.xml -w '%{http_code}' "https://$SITE_HOST/updates/$FEED.xml" || echo 000)
    if [[ "$STATUS" != 200 && "$STATUS" != 404 ]]; then
      echo "Couldn't read the live $FEED feed (HTTP $STATUS), so the build number can't be checked. Try again."
      exit 1
    fi
    LIVE=""
    [[ "$STATUS" == 200 ]] && LIVE=$(grep -oE 'sparkle:version="?>?[0-9]+' /tmp/zigzag-live-$FEED.xml | grep -oE '[0-9]+$' | sort -n | tail -1 || true)
    if [[ -n "$LIVE" && "$BUILD" -le "$LIVE" ]]; then
      echo "CURRENT_PROJECT_VERSION is $BUILD but the $FEED feed already has build $LIVE. Raise it in project.yml, then release."
      exit 1
    fi
  done
fi

xcodegen generate -q
# Signing asks Apple's timestamp server for every file it signs, and that server drops a request now and then
# ("The timestamp service is not available"): one drop fails the step, so archiving and exporting get a few tries.
TRIES=4
for try in $(seq 1 $TRIES); do
  rm -rf "$OUT/Zigzag.xcarchive"
  xcodebuild -project Zigzag.xcodeproj -scheme Zigzag -configuration Release -allowProvisioningUpdates \
    -derivedDataPath build/rd -archivePath "$OUT/Zigzag.xcarchive" archive "${VERSION_OVERRIDE[@]}" | pretty || true
  [[ -d "$OUT/Zigzag.xcarchive" ]] && break
  (( try < TRIES )) && { echo "Archive failed, trying again ($try of $TRIES)…"; sleep 20; }
done
[[ -d "$OUT/Zigzag.xcarchive" ]] || { echo "Archive failed"; exit 1; }

# Exporting signs with Developer ID and its provisioning profile (which carries the Keychain access group).
APP="$OUT/export/Zigzag.app"
for try in $(seq 1 $TRIES); do
  rm -rf "$OUT/export"
  xcodebuild -exportArchive -archivePath "$OUT/Zigzag.xcarchive" -exportPath "$OUT/export" \
    -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates | pretty || true
  [[ -d "$APP" ]] && break
  (( try < TRIES )) && { echo "Export failed, trying again ($try of $TRIES)…"; sleep 20; }
done
[[ -d "$APP" ]] || { echo "Export failed"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier"
# The picture helper reads what websites send: it must be signed like the app, with the hardened runtime, and
# sandboxed. Exporting signs it with the app; a release where it isn't stops here.
HELPER="$APP/Contents/XPCServices/ZigzagImageDecoder.xpc"
codesign -dvv "$HELPER" 2>&1 | grep -q "Authority=Developer ID Application" || { echo "The picture helper isn't signed with Developer ID"; exit 1; }
codesign -dvv "$HELPER" 2>&1 | grep -q "flags=.*runtime" || { echo "The picture helper lacks the hardened runtime"; exit 1; }
codesign -d --entitlements - --xml "$HELPER" 2>/dev/null | grep -q "com.apple.security.app-sandbox" || { echo "The picture helper isn't sandboxed"; exit 1; }

if [[ "${1:-}" == "--local" ]]; then
  echo "Done (not notarized): $APP"
  exit 0
fi

ZIP="$OUT/updates/Zigzag-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Apple's notary service is a long upload from here, and it sometimes times out ("connectTimeout") though nothing is
# wrong with the build. A few tries before giving up; a build Apple rejects still stops at stapling, as before.
notarize() {
  for attempt in 1 2 3; do
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait && return 0
    [[ $attempt -lt 3 ]] && { echo "Apple's notary service didn't answer; trying again ($((attempt + 1)) of 3)…"; sleep 20; }
  done
  echo "Couldn't reach Apple's notary service after 3 tries. Nothing was published; run the release again later."
  exit 1
}

echo "Notarizing…"
notarize "$ZIP"
xcrun stapler staple "$APP"
rm "$ZIP" && ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"

# The release notes for the update window: this version's section of CHANGELOG.md as HTML, with
# CHANGELOG.zh-Hans.md's beside it for a Mac in Chinese, and for a GitHub release as Markdown (build/release/notes.md,
# for --notes-file). A beta uses the section of the version it leads up to. See scripts/release-notes.py.
write_notes() { python3 scripts/release-notes.py "$VERSION" "$PLANNED" "$OUT"; }
# The notes in each language are files of their own that the feed links to, so they go up before it.
upload_notes() {
  local notes=("$OUT"/updates/Zigzag-"$VERSION".*.html(N))
  if (( ${#notes} )); then again rsync -a "${notes[@]}" "$SERVER:$SITE_ROOT/updates/"; fi
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
  "$GENERATE" --download-url-prefix "https://$SITE_HOST/releases/" --release-notes-url-prefix "https://$SITE_HOST/updates/" --full-release-notes-url "https://$SITE_HOST/release-notes/" --link "https://$SITE_HOST/" "$OUT/updates"
  mv "$OUT/updates/appcast.xml" "$OUT/updates/beta.xml"
  again rsync -a "$ZIP" "$SERVER:$SITE_ROOT/releases/"
  upload_notes
  again rsync -a "$OUT/updates/beta.xml" "$SERVER:$SITE_ROOT/updates/beta.xml"
  echo "Done: $VERSION is on the beta feed."
  exit 0
fi

# The DMG people download: the app beside an Applications shortcut, signed, notarized and stapled itself, so it
# opens without a warning on a Mac that has never seen Zigzag. (Updates use the zip above.)
# The window it opens to: Zigzag on the left, Applications on the right, an arrow between, a welcome above, on the
# site's sky (scripts/dmg/background.html, drawn by scripts/dmg/render.swift).
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
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

if [[ "${1:-}" == "--publish" ]]; then
  # The appcast needs Sparkle's signing key from the keychain, which may ask; only publishing needs it.
  # Builds and the feed are served from zigzagbrowser.com (reachable everywhere, no GitHub needed).
  write_notes
  echo "Writing appcast…"
  "$GENERATE" --download-url-prefix "https://$SITE_HOST/releases/" --release-notes-url-prefix "https://$SITE_HOST/updates/" --full-release-notes-url "https://$SITE_HOST/release-notes/" --link "https://$SITE_HOST/" "$OUT/updates"
  echo "Uploading to $SITE_HOST…"
  again rsync -a "$ZIP" "$DMG" "$SERVER:$SITE_ROOT/releases/"
  again ssh "$SERVER" "ln -sfn Zigzag-$VERSION.dmg $SITE_ROOT/releases/Zigzag-latest.dmg && ln -sfn Zigzag-$VERSION.zip $SITE_ROOT/releases/Zigzag-latest.zip"
  upload_notes
  # The feed goes last, so no Mac is offered an update before its zip and notes are there.
  again rsync -a "$OUT/updates/appcast.xml" "$SERVER:$SITE_ROOT/updates/appcast.xml"
  # The beta feed carries each stable release too, so anyone on a beta moves on to it, unless its betas already
  # lead up to a later version (0.5.0-beta.3 leads up to 0.5.0): replacing it then would move them back.
  if BETA_FEED=$(curl -fsSL --retry 6 --retry-all-errors --retry-delay 5 --max-time 30 "https://$SITE_HOST/updates/beta.xml"); then
    NEWEST_BETA=$(print -r -- "$BETA_FEED" | grep -oE '[0-9]+(\.[0-9]+)*-beta\.[0-9]+' | sed -E 's/-beta\.[0-9]+$//' \
      | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)
    if [[ -z "$NEWEST_BETA" ]] || zsh scripts/version-at-least.sh "$VERSION" "$NEWEST_BETA"; then
      again rsync -a "$OUT/updates/appcast.xml" "$SERVER:$SITE_ROOT/updates/beta.xml"
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
