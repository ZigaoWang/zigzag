#!/bin/zsh
# Refreshes the engine behind Settings › Privacy › Cookie banners (#175): DuckDuckGo's Autoconsent
# (github.com/duckduckgo/autoconsent, MPL-2.0), the library DuckDuckGo's browsers use to answer cookie consent pop-ups,
# from its `@duckduckgo/autoconsent` npm package, into Zigzag/Resources/Autoconsent. Every file is copied unchanged.
#
#   scripts/update-autoconsent.sh            the version pinned below
#   scripts/update-autoconsent.sh 18.3.0     another one (pick one that's been out a couple of weeks: it's released daily)
#
# It writes:
#   autoconsent.playwright.js        the package's dist/autoconsent.playwright.js: the whole content script as one plain
#                                    script, talking to its background through window.autoconsentSendMessage and
#                                    window.autoconsentReceiveMessage. Zigzag runs it in a script world of its own and
#                                    is its background (Zigzag/Web/CookieBanners.swift).
#   autoconsent-compact-rules.json   rules/compact-rules.json: the rules for each consent pop-up, in their compact form.
#   autoconsent-LICENSE.txt          the package's LICENSE (the MPL-2.0).
#   autoconsent.info.json            the version and where it came from.
# Then build, try a few sites with consent pop-ups, run the tests, and commit what it wrote. Needs node.
set -euo pipefail

repo=${0:A:h:h}
out=$repo/Zigzag/Resources/Autoconsent
version=${1:-16.63.0}

work=$(mktemp -d)
trap 'rm -rf $work' EXIT

echo "Autoconsent $version…"
tarball=https://registry.npmjs.org/@duckduckgo/autoconsent/-/autoconsent-$version.tgz
meta=$(curl -fsSL --retry 3 https://registry.npmjs.org/@duckduckgo/autoconsent/$version)
integrity=$(print -r -- $meta | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).dist.integrity))')
curl -fsSL --retry 3 $tarball -o $work/package.tgz
# The registry's own sha512 of the tarball.
actual="sha512-$(openssl dgst -sha512 -binary $work/package.tgz | base64 | tr -d '\n')"
[[ $actual == $integrity ]] || { echo "The tarball doesn't match the registry's integrity ($integrity)" >&2; exit 1; }
tar -xzf $work/package.tgz -C $work
grep -q '"license": "MPL-2.0"' $work/package/package.json || { echo "The package's license isn't MPL-2.0 any more: check before updating" >&2; exit 1; }

script=$work/package/dist/autoconsent.playwright.js
rules=$work/package/rules/compact-rules.json
# What Zigzag's side counts on: the two globals the script talks through, and rules in the compact form, version 1,
# with the index that says which rules are generic, for frames, or for given sites.
grep -q 'new AutoConsent(window.autoconsentSendMessage' $script || { echo "The content script talks another way now: update CookieBanners.swift" >&2; exit 1; }
grep -q 'window.autoconsentReceiveMessage = ' $script || { echo "The content script hears another way now: update CookieBanners.swift" >&2; exit 1; }
node - $rules <<'JS'
const rules = require(process.argv[2]);
const i = rules.index;
if (rules.v !== 1 || !Array.isArray(rules.s) || !Array.isArray(rules.r) || !i || !i.genericRuleRange || !i.frameRuleRange
    || !i.specificRuleRange || typeof i.genericStringEnd !== 'number' || typeof i.frameStringEnd !== 'number') {
  throw new Error('The compact rules are in another form now: update CookieBanners.swift');
}
console.log(`${rules.r.length} rules`);
JS

mkdir -p $out
cp $script $out/autoconsent.playwright.js
cp $rules $out/autoconsent-compact-rules.json
cp $work/package/LICENSE $out/autoconsent-LICENSE.txt
cat > $out/autoconsent.info.json <<EOF
{
  "version": "$version",
  "package": "$tarball",
  "integrity": "$integrity",
  "files": ["dist/autoconsent.playwright.js", "rules/compact-rules.json", "LICENSE"]
}
EOF
echo "Wrote $out: $(wc -c < $out/autoconsent.playwright.js | tr -d ' ') bytes of script, $(wc -c < $out/autoconsent-compact-rules.json | tr -d ' ') bytes of rules"
