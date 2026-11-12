#!/bin/zsh
# Refreshes the Dark Reader engine behind dark pages (#134): the `darkreader` npm package (its dynamic theme, MIT) and
# the site fixes from the Dark Reader repository at the same version, in Zigzag/Resources/DarkReader.
#
#   scripts/update-darkreader.sh            the version pinned below
#   scripts/update-darkreader.sh 4.9.140    another one (pick one that's been out a couple of weeks)
#
# It writes:
#   darkreader.js           the package's darkreader.js, with two changes: instead of putting its proxy into the page as
#                           an inline <script> (which a page's Content-Security-Policy can block), it asks for it with an
#                           event, and Zigzag's own page-world script runs it (see DarkPages.swift); and a rule waiting
#                           on a picture that failed to load keeps the picture rather than dropping it from its value.
#   darkreader-proxy.js     that proxy (the package's `injectProxy`), as it is, for the page's own world.
#   darkreader-fixes.config src/config/dynamic-theme-fixes.config from the repository, unchanged.
#   darkreader.info.json    the version and where each file came from.
# Then build, try a few sites with dark pages on, run the tests, and commit what it wrote. Needs node.
set -euo pipefail

repo=${0:A:h:h}
out=$repo/Zigzag/Resources/DarkReader
version=${1:-4.9.134}

work=$(mktemp -d)
trap 'rm -rf $work' EXIT

echo "Dark Reader $version…"
tarball=https://registry.npmjs.org/darkreader/-/darkreader-$version.tgz
integrity=$(curl -fsSL --retry 3 https://registry.npmjs.org/darkreader/$version | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).dist.integrity))')
curl -fsSL --retry 3 $tarball -o $work/package.tgz
# The registry's own sha512 of the tarball.
actual="sha512-$(openssl dgst -sha512 -binary $work/package.tgz | base64 | tr -d '\n')"
[[ $actual == $integrity ]] || { echo "The tarball doesn't match the registry's integrity ($integrity)" >&2; exit 1; }
tar -xzf $work/package.tgz -C $work
grep -q "\"license\": \"MIT\"" $work/package/package.json || { echo "The package's license isn't MIT any more: check before updating" >&2; exit 1; }

fixes=https://raw.githubusercontent.com/darkreader/darkreader/v$version/src/config/dynamic-theme-fixes.config
curl -fsSL --retry 3 $fixes -o $work/fixes.config

node - $work/package/darkreader.js $work/darkreader.js $work/darkreader-proxy.js <<'JS'
const fs = require('fs');
const [input, output, proxyOut] = process.argv.slice(2);
let src = fs.readFileSync(input, 'utf8');

// The proxy, as a function's source: from `function injectProxy(` to its closing brace (it has no template literals
// or regular expressions, so counting braces outside strings finds it), checked by parsing it.
const start = src.indexOf('function injectProxy(');
if (start < 0) throw new Error('No injectProxy in darkreader.js');
let depth = 0, end = -1, quote = '';
for (let i = src.indexOf('{', start); i < src.length; i++) {
  const ch = src[i];
  if (quote) { if (ch === '\\') i++; else if (ch === quote) quote = ''; continue; }
  if (ch === '"' || ch === "'") quote = ch;
  else if (ch === '`') throw new Error('injectProxy has a template literal now: extract it another way');
  else if (ch === '{') depth++;
  else if (ch === '}' && --depth === 0) { end = i + 1; break; }
}
const proxy = src.slice(start, end);
new Function('return ' + proxy);
fs.writeFileSync(proxyOut, `// Dark Reader's proxy (https://darkreader.org, MIT; see THIRD_PARTY_NOTICES.md), from darkreader.js by
// scripts/update-darkreader.sh. Zigzag runs it in the page's own world when its Dark Reader asks (DarkPages.swift).
${proxy}
`);

// Asked for with an event rather than put in as an inline script.
const inline = /const proxyScript = createOrUpdateScript\("darkreader--proxy"\);\s*proxyScript\.append\(\s*`\(\$\{injectProxy\}\)\(\$\{enableStyleSheetsProxy\}, \$\{enableCustomElementRegistryProxy\}\)`\s*\);\s*document\.head\.insertBefore\([\s\S]*?\);\s*proxyScript\.remove\(\);/;
if (!inline.test(src)) throw new Error('The proxy is put in another way now: update the patch');
src = src.replace(inline, 'document.dispatchEvent(new CustomEvent(`__zigzag_darkreader_proxy_${enableStyleSheetsProxy ? 1 : 0}${enableCustomElementRegistryProxy ? 1 : 0}`));');

// A rule waiting on a picture another rule is already loading got nothing back when that load failed, and dropped the
// picture from its value: "url(a), linear-gradient(...)" became ", linear-gradient(...)", which isn't a value, so the
// element lost its background altogether (Hacker News's vote arrows). It keeps the picture as it was instead, as the
// rule that did the loading does.
const waited = /(imageDetails = await new Promise\(\(resolve\) =>\s*awaiters\.push\(resolve\)\s*\);)\s*if \(!imageDetails\) \{\s*return null;\s*\}/;
if (!waited.test(src)) throw new Error('Waiting for a picture works another way now: check the patch is still needed');
src = src.replace(waited, '$1');
fs.writeFileSync(output, src);
JS

mkdir -p $out
cp $work/darkreader.js $out/darkreader.js
cp $work/darkreader-proxy.js $out/darkreader-proxy.js
cp $work/fixes.config $out/darkreader-fixes.config
cat > $out/darkreader.info.json <<EOF
{
  "version": "$version",
  "package": "$tarball",
  "integrity": "$integrity",
  "fixes": "$fixes"
}
EOF
echo "Wrote $out: $(wc -c < $out/darkreader.js | tr -d ' ') bytes of engine, $(grep -c '^====' $out/darkreader-fixes.config) site fixes"
