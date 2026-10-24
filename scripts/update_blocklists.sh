#!/bin/zsh
# Refreshes Zigzag's built-in ad and tracker blocking from EasyList and EasyPrivacy.
#
# The lists are converted to WebKit content-blocker rules with AdGuard's SafariConverterLib, run here as a
# separate tool (it is GPL-3.0; only its output ships in the app). The result is one rule list, compressed,
# in Zigzag/Resources/Blocklists. Run it before a release; commit what it writes.
#
#   scripts/update_blocklists.sh
set -euo pipefail

repo=${0:A:h:h}
out=$repo/Zigzag/Resources/Blocklists
tools=${ZIGZAG_TOOLS:-$HOME/Library/Caches/Zigzag-build}
converter_version=v4.3.1
converter=$tools/SafariConverterLib-$converter_version/.build/release/ConverterTool
# Zigzag's minimum macOS is 15.4, which ships Safari 18.4's content blocker.
safari_version=18.4
# WebKit refuses a rule list longer than this.
max_rules=150000

if [[ ! -x $converter ]]; then
  echo "Building SafariConverterLib $converter_version…"
  mkdir -p $tools
  rm -rf $tools/SafariConverterLib-$converter_version
  git -c advice.detachedHead=false clone -q --depth 1 --branch $converter_version https://github.com/AdguardTeam/SafariConverterLib.git $tools/SafariConverterLib-$converter_version
  (cd $tools/SafariConverterLib-$converter_version && swift build -c release --product ConverterTool >/dev/null 2>&1)
fi

work=$(mktemp -d)
trap 'rm -rf $work' EXIT

echo "Downloading lists…"
curl -fsSL https://easylist.to/easylist/easylist.txt -o $work/easylist.txt
curl -fsSL https://easylist.to/easylist/easyprivacy.txt -o $work/easyprivacy.txt
version() { grep -m1 '^! Version:' $1 | sed 's/^! Version: *//' }

echo "Converting…"
cat $work/easylist.txt $work/easyprivacy.txt > $work/combined.txt
$converter convert -s $safari_version --input-path $work/combined.txt \
  --safari-rules-json-path $work/blocklist.json --advanced-blocking-rules-path $work/advanced.txt >/dev/null

count=$(python3 -I -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" $work/blocklist.json)
if (( count > max_rules )); then
  echo "The combined list has $count rules, more than WebKit's $max_rules. Split it before shipping." >&2
  exit 1
fi

mkdir -p $out
compression_tool -encode -a lzfse -i $work/blocklist.json -o $out/blocklist.json.lzfse
cat > $out/blocklist.info.json <<JSON
{
  "easylist": "$(version $work/easylist.txt)",
  "easyprivacy": "$(version $work/easyprivacy.txt)",
  "rules": $count,
  "safari": "$safari_version",
  "converter": "SafariConverterLib $converter_version"
}
JSON
echo "Wrote $count rules ($(du -h $out/blocklist.json.lzfse | cut -f1) compressed) to ${out#$repo/}"
