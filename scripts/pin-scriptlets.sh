#!/bin/zsh
# Pins the ad blocking scriptlets a release accepts (Zigzag/Web/AdFilters.swift, pinnedScriptletRevisions).
#
# uBlock Origin's scriptlets (GPL-3.0) never ship in Zigzag: each Mac downloads them from Ghostery's CDN. But the app
# only runs a download whose SHA-256 is one it was released with, so a compromised CDN can't put code of its own in
# every page. This fetches the newest revision Ghostery publishes, checks that its file hashes to its name, prints the
# hash, and puts it first in the pins, keeping the one before it so a Mac with the last release's copy keeps it while
# the new one downloads. Run it before each release (scripts/release.sh asks) and commit the change.
#
#   scripts/pin-scriptlets.sh            # pin the newest revision
#   scripts/pin-scriptlets.sh --check    # only say whether the pins are current
set -euo pipefail

repo=${0:A:h:h}
source_file=$repo/Zigzag/Web/AdFilters.swift
base=https://cdn.ghostery.com/adblocker/resources/ublock-resources-json
work=$(mktemp -d)
trap 'rm -rf $work' EXIT

curl -fsSL -o $work/metadata.json $base/metadata.json
revision=$(python3 -I -c "
import json, re, sys
revisions = json.load(open(sys.argv[1])).get('revisions') or []
latest = revisions[-1] if revisions else ''
if not re.fullmatch(r'[0-9a-f]{64}', latest): sys.exit('The index names no revision')
print(latest)" $work/metadata.json)

curl -fsSL -o $work/list.txt $base/$revision/list.txt
actual=$(shasum -a 256 $work/list.txt | cut -d' ' -f1)
[[ $actual == $revision ]] || { echo "The scriptlets at $revision hash to $actual, not their name: not pinned" >&2; exit 1; }
count=$(python3 -I -c "import json, sys; print(len(json.load(open(sys.argv[1]))['scriptlets']))" $work/list.txt)
(( count >= 50 )) || { echo "Revision $revision has only $count scriptlets: not pinned" >&2; exit 1; }

current=($(python3 -I -c "
import re, sys
text = open(sys.argv[1]).read()
block = re.search(r'pinnedScriptletRevisions: \[String\] = \[(.*?)\]', text, re.S)
print(' '.join(re.findall(r'\"([0-9a-f]{64})\"', block.group(1))) if block else '')" $source_file))

echo "Newest scriptlets: $revision ($count scriptlets)"
if [[ ${current[1]:-} == $revision ]]; then
  echo "Already pinned."
  exit 0
fi
if [[ ${1:-} == --check ]]; then
  echo "Pinned: ${current[*]:-none}. Run scripts/pin-scriptlets.sh to pin the newest." >&2
  exit 1
fi

python3 -I -c "
import re, sys
path, new, previous = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(path).read()
pins = [new] + [p for p in previous if p != new][:1]
lines = ''.join(f'\n        \"{p}\",' for p in pins)
text, n = re.subn(r'(pinnedScriptletRevisions: \[String\] = \[).*?(\n    \])', lambda m: m.group(1) + lines + m.group(2), text, count=1, flags=re.S)
if n != 1: sys.exit('pinnedScriptletRevisions not found in ' + path)
open(path, 'w').write(text)" $source_file $revision ${current[@]}

echo "Pinned $revision in Zigzag/Web/AdFilters.swift${current[1]:+, keeping ${current[1]}}"
