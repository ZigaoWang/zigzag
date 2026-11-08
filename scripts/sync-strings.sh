#!/bin/zsh
# Brings Zigzag/Resources/Localizable.xcstrings in step with the code, as Xcode does when it builds: every
# String(localized:) the compiler found is added, and one no longer in the code is marked stale. Translations and
# the plural forms already in the catalog are kept. Build first, then run it and commit the catalog.
#
#   xcodebuild -project Zigzag.xcodeproj -scheme Zigzag -derivedDataPath build/dev build
#   scripts/sync-strings.sh build/dev
set -euo pipefail

repo=${0:A:h:h}
derived=${1:?Usage: scripts/sync-strings.sh <derived data path>}
objects=($derived/Build/Intermediates.noindex/Zigzag.build/*/Zigzag.build/Objects-normal/*(N))
(( ${#objects} )) || { echo "No build of Zigzag in $derived" >&2; exit 1; }
data=($objects[1]/*.stringsdata(N))
(( ${#data} )) || { echo "The build in $derived listed no strings: is SWIFT_EMIT_LOC_STRINGS on?" >&2; exit 1; }
xcrun xcstringstool sync $repo/Zigzag/Resources/Localizable.xcstrings --stringsdata $data
echo "$(xcrun xcstringstool print $repo/Zigzag/Resources/Localizable.xcstrings | wc -l | tr -d ' ') strings in the catalog"
