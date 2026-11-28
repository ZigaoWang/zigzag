#!/bin/bash
# Readies a checkout for the CI test build: ad-hoc signing, no team, no profile. CI only, it edits the entitlements.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -n "${CI:-}" ] || { echo "scripts/ci-prepare.sh changes Zigzag/Zigzag.entitlements, so it only runs in CI (CI=1)" >&2; exit 2; }

# Ad-hoc signing can't carry entitlements that need a provisioning profile (push, iCloud, the keychain group).
for key in com.apple.developer.aps-environment com.apple.developer.icloud-container-identifiers \
  com.apple.developer.icloud-services keychain-access-groups; do
  /usr/libexec/PlistBuddy -c "Delete :$key" Zigzag/Zigzag.entitlements >/dev/null 2>&1 || true
done

mkdir -p build
xcconfig="$PWD/build/ci-signing.xcconfig"
cat > "$xcconfig" <<'EOF'
CODE_SIGN_IDENTITY = -
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM =
PROVISIONING_PROFILE_SPECIFIER =
EOF

# xcodebuild reads XCODE_XCCONFIG_FILE over every target's own settings.
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "XCODE_XCCONFIG_FILE=$xcconfig" >> "$GITHUB_ENV"
else
  echo "export XCODE_XCCONFIG_FILE=$xcconfig"
fi
