#!/bin/zsh
# Refreshes the ad engine Zigzag runs uBlock Origin's filter lists with: Ghostery's adblocker
# (github.com/ghostery/adblocker, MPL-2.0), bundled unminified into one script by esbuild, with its license notices
# kept. Only the engine ships; the lists and the scriptlets it runs are downloaded by the app (Zigzag/Web/AdFilters.swift).
#
#   scripts/update_ad_engine.sh [version]
set -euo pipefail

repo=${0:A:h:h}
version=${1:-2.20.3}
out=$repo/Zigzag/Resources/AdEngine
work=$(mktemp -d)
trap 'rm -rf $work' EXIT

cd $work
npm init -y >/dev/null
npm install --silent --ignore-scripts --no-audit --no-fund @ghostery/adblocker@$version esbuild@0.24.2
tldts=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" node_modules/tldts-experimental/package.json)
print -r -- "export { FiltersEngine, ENGINE_VERSION } from '@ghostery/adblocker';
export { parse } from 'tldts-experimental';" > entry.js
./node_modules/.bin/esbuild entry.js --bundle --format=iife --global-name=GhosteryAdblocker --target=es2020 \
  --legal-comments=inline --log-level=warning \
  --banner:js="// @ghostery/adblocker $version (MPL-2.0) and tldts-experimental $tldts (MIT), bundled unmodified by scripts/update_ad_engine.sh. Source: https://github.com/ghostery/adblocker and https://github.com/remusao/tldts. Licenses: ghostery-adblocker-LICENSE.txt." \
  --outfile=$out/ghostery-adblocker.js

{
  print "Zigzag/Resources/AdEngine/ghostery-adblocker.js bundles these packages, unmodified:"
  print
  for package in node_modules/@ghostery/* node_modules/@remusao/* node_modules/tldts-core node_modules/tldts-experimental; do
    python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print(f\"- {d['name']} {d['version']} ({d['license']})\")" $package/package.json
  done
  print
  print "The packages licensed under the MPL-2.0 are Covered Software under the Mozilla Public License, Version 2.0,"
  print "which follows in full. Their Source Code Form is the bundled script itself, and the packages' own sources are at"
  print "https://github.com/ghostery/adblocker and https://github.com/remusao."
  print
  print "================================================================================"
  print
  cat node_modules/@ghostery/adblocker/LICENSE
  print
  print "================================================================================"
  print
  print "tldts-core and tldts-experimental:"
  print
  cat node_modules/tldts-experimental/LICENSE
} > $out/ghostery-adblocker-LICENSE.txt

echo "Wrote ghostery-adblocker.js ($(du -h $out/ghostery-adblocker.js | cut -f1)), engine $version"
