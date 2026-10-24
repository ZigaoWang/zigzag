#!/bin/zsh
# Builds a signed, notarized Zigzag release and its Sparkle appcast.
#
# One-time setup:
#   xcrun notarytool store-credentials zigzag-notary --apple-id <you> --team-id 432GL3WKY2
#   (Sparkle's EdDSA private key lives in the login keychain; see generate_keys.)
#
# Usage: scripts/release.sh            build, sign, notarize, staple, appcast
#        scripts/release.sh --publish  also create the GitHub release with gh
#        scripts/release.sh --local    build and sign with Developer ID only, to use on this Mac
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${NOTARY_PROFILE:-zigzag-notary}
REPO=${GITHUB_REPO:-ZigaoWang/zigzag}
OUT=build/release
# Tidier build output when xcbeautify is installed; otherwise just the lines that matter.
pretty() { if command -v xcbeautify >/dev/null; then xcbeautify; else grep -E "error:|ARCHIVE|EXPORT|BUILD" || true; fi; }
rm -rf "$OUT" && mkdir -p "$OUT/updates"

xcodegen generate -q
xcodebuild -project Zigzag.xcodeproj -scheme Zigzag -configuration Release -allowProvisioningUpdates \
  -derivedDataPath build/rd -archivePath "$OUT/Zigzag.xcarchive" archive | pretty
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

echo "Writing appcast…"
GENERATE=$(find build/rd/SourcePackages build/dd/SourcePackages -name generate_appcast -type f -perm +111 2>/dev/null | head -1)
"$GENERATE" --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" "$OUT/updates"

if [[ "${1:-}" == "--publish" ]]; then
  gh release create "v$VERSION" "$ZIP" "$OUT/updates/appcast.xml" --repo "$REPO" --title "Zigzag $VERSION" --notes "Zigzag $VERSION"
fi
echo "Done: $ZIP"
