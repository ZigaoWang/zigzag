#!/usr/bin/env python3
"""Builds the home page in every app language from site/index.html and scripts/site-strings/<lang>.json.

site/index.html stays the English source. Each strings file maps an exact piece of it to its translation, and
site/<lang>/index.html is written from it, so the pages can't drift. Also writes the language links (hreflang in the
head, the line of languages in the footer) into every page, English included, and site/sitemap.xml.

    scripts/site-languages.py           # write the pages
    scripts/site-languages.py --check   # fail if a page is out of date or a strings file doesn't match the source
"""
import datetime, json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE, STRINGS = ROOT / "site", ROOT / "scripts" / "site-strings"
BASE = "https://zigzagbrowser.com"
# (code for lang and hreflang, its own name, folder). The codes are the app's own.
LANGS = [("en", "English", ""), ("zh-Hans", "简体中文", "zh-hans"), ("zh-Hant", "繁體中文", "zh-hant"),
         ("ja", "日本語", "ja"), ("ko", "한국어", "ko"), ("de", "Deutsch", "de"), ("fr", "Français", "fr"),
         ("it", "Italiano", "it"), ("es", "Español", "es"), ("pt-BR", "Português (Brasil)", "pt-br"),
         ("ru", "Русский", "ru"), ("nl", "Nederlands", "nl"), ("pl", "Polski", "pl"), ("tr", "Türkçe", "tr")]
# Languages written without spaces: their statement is split into chunks with "|", joined with nothing.
NO_SPACES = {"zh-Hans", "zh-Hant", "ja"}
GENERATED = "<!-- Made by scripts/site-languages.py from site/index.html and scripts/site-strings. Edit those, not this. -->\n"


def url(folder):
    return f"{BASE}/{folder}/" if folder else f"{BASE}/"


def fail(msg):
    sys.exit(f"site-languages: {msg}")


def with_links(html, current):
    """The page with hreflang links after its canonical, and the line of languages in its footer."""
    html = re.sub(r'<link rel="alternate" hreflang="[^"]*" href="[^"]*">\n', "", html)
    alts = "".join(f'<link rel="alternate" hreflang="{c}" href="{url(f)}">\n' for c, _, f in LANGS)
    alts += f'<link rel="alternate" hreflang="x-default" href="{url("")}">\n'
    html = re.sub(r'(<link rel="canonical" href="[^"]*">\n)', lambda m: m.group(1) + alts, html, count=1)
    here = ' aria-current="page"'
    links = "".join(f'<a href="/{f + "/" if f else ""}" hreflang="{c}" lang="{c}"{here if c == current else ""}>{name}</a>'
                    for c, name, f in LANGS)
    line = f'<p class="langs">{links}</p>'
    html = re.sub(r'\n    <p class="langs">.*?</p>', "", html)
    html = html.replace('\n    <p class="fine">© ', f'\n    {line}\n    <p class="fine">© ', 1)
    return html


def tags(s):
    return sorted(re.findall(r"<[^>]+>", s))


def main():
    check = "--check" in sys.argv
    source = (SITE / "index.html").read_text()
    keys = json.loads((STRINGS / "en.json").read_text())

    # The statement lights up word by word, so each word is its own span. Translate it as one sentence.
    m = re.search(r'(<p class="statement">)(.*?)(</p>)', source)
    words = re.findall(r'<span class="w">(.*?)</span>', m.group(2))
    statement = " ".join(words)
    plain = source[:m.start(2)] + statement + source[m.end(2):]

    for k in keys:
        if k not in plain:
            fail(f"the English page no longer has {k!r}: update scripts/site-strings/en.json and every language")
    pattern = re.compile(r"(?<![A-Za-z0-9])(" + "|".join(re.escape(k) for k in sorted(keys, key=len, reverse=True)) + r")(?![A-Za-z0-9])")

    out = {SITE / "index.html": with_links(source, "en")}
    for code, _, folder in LANGS[1:]:
        f = STRINGS / f"{code}.json"
        if not f.exists():
            fail(f"{f.relative_to(ROOT)} is missing")
        tr = json.loads(f.read_text())["strings"]
        if set(tr) != set(keys):
            fail(f"{code}: missing {sorted(set(keys) - set(tr))[:3]}, extra {sorted(set(tr) - set(keys))[:3]}")
        for k, v in tr.items():
            if not v.strip():
                fail(f"{code}: {k!r} is empty")
            if tags(k) != tags(v):
                fail(f"{code}: {k!r} has to keep the same tags")
            if '"' in re.sub(r"<[^>]+>", "", v):
                fail(f"{code}: {k!r} has a straight double quote; use the language's own quotes")
            if "|" in v and k != statement:
                fail(f"{code}: {k!r} has a |")
        html = pattern.sub(lambda m: tr[m.group(1)], plain)
        # Each word, or for languages without spaces each chunk, back in its span.
        def wrap(m):
            parts = m.group(2).split("|") if code in NO_SPACES else m.group(2).split(" ")
            sep = "" if code in NO_SPACES else " "
            return m.group(1) + sep.join(f'<span class="w">{p}</span>' for p in parts if p) + m.group(3)
        html = re.sub(r'(<p class="statement">)(.*?)(</p>)', wrap, html, count=1)
        html = html.replace('<html lang="en">', f'<html lang="{code}">', 1)
        html = html.replace(f'<link rel="canonical" href="{BASE}/">', f'<link rel="canonical" href="{url(folder)}">', 1)
        html = html.replace(f'<meta property="og:url" content="{BASE}/">', f'<meta property="og:url" content="{url(folder)}">', 1)
        html = html.replace('href="/"', f'href="/{folder}/"')
        html = html.replace("<!doctype html>\n", "<!doctype html>\n" + GENERATED, 1)
        for block in re.findall(r'<script type="application/ld\+json">(.*?)</script>', html):
            json.loads(block)
        out[SITE / folder / "index.html"] = with_links(html, code)

    today = datetime.date.today().isoformat()
    alts = "".join(f'\n    <xhtml:link rel="alternate" hreflang="{c}" href="{url(f)}"/>' for c, _, f in LANGS)
    alts += f'\n    <xhtml:link rel="alternate" hreflang="x-default" href="{url("")}"/>'
    old = (SITE / "sitemap.xml").read_text()
    if check:
        today = (re.search(r"<lastmod>(.*?)</lastmod>", old) or [None, today])[1]
    rows = [f"  <url><loc>{url(f)}</loc><lastmod>{today}</lastmod>{alts}\n  </url>" for _, _, f in LANGS]
    rows += [f"  <url><loc>{BASE}/{p}/</loc><lastmod>{today}</lastmod></url>" for p in ("download", "release-notes")]
    out[SITE / "sitemap.xml"] = ('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
                                 'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n' + "\n".join(rows) + "\n</urlset>\n")

    stale = []
    for path, text in out.items():
        if not path.exists() or path.read_text() != text:
            stale.append(path.relative_to(ROOT))
            if not check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
    if check and stale:
        fail("out of date: " + ", ".join(map(str, stale)) + "; run scripts/site-languages.py")
    print(f"{'Checked' if check else 'Wrote'} {len(LANGS)} languages" + (f", updated {len(stale)} files" if stale and not check else ""))


if __name__ == "__main__":
    main()
