#!/usr/bin/env python3
"""Builds zigzagbrowser.com/release-notes from CHANGELOG.md: every version, newest first, the same notes the app shows.
Also builds /<lang>/release-notes in every site language from docs/i18n/changelog/CHANGELOG.<lang>.md, with the
page's words from scripts/site-strings and the language links of scripts/site-languages.py.

Run by site/deploy.sh, so the pages are rebuilt whenever the site goes out (and so after every release). The sitemap
is scripts/site-languages.py's.

    scripts/changelog-page.py           # write the pages
    scripts/changelog-page.py --check   # fail if a page is out of date
"""
import datetime, html, importlib.util, pathlib, re, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("site_languages", root / "scripts" / "site-languages.py")
languages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(languages)

# Each language's long date, as CLDR writes it.
MONTHS = {
    "de": "Januar Februar März April Mai Juni Juli August September Oktober November Dezember",
    "fr": "janvier février mars avril mai juin juillet août septembre octobre novembre décembre",
    "it": "gennaio febbraio marzo aprile maggio giugno luglio agosto settembre ottobre novembre dicembre",
    "es": "enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre",
    "pt-BR": "janeiro fevereiro março abril maio junho julho agosto setembro outubro novembro dezembro",
    "ru": "января февраля марта апреля мая июня июля августа сентября октября ноября декабря",
    "nl": "januari februari maart april mei juni juli augustus september oktober november december",
    "pl": "stycznia lutego marca kwietnia maja czerwca lipca sierpnia września października listopada grudnia",
    "tr": "Ocak Şubat Mart Nisan Mayıs Haziran Temmuz Ağustos Eylül Ekim Kasım Aralık",
}
DATES = {"en": "{month} {d}, {y}", "zh-Hans": "{y}年{m}月{d}日", "zh-Hant": "{y}年{m}月{d}日", "ja": "{y}年{m}月{d}日",
         "ko": "{y}년 {m}월 {d}일", "de": "{d}. {month} {y}", "fr": "{d} {month} {y}", "it": "{d} {month} {y}",
         "es": "{d} de {month} de {y}", "pt-BR": "{d} de {month} de {y}", "ru": "{d} {month} {y} г.",
         "nl": "{d} {month} {y}", "pl": "{d} {month} {y}", "tr": "{d} {month} {y}"}


def day(iso, code):
    d = datetime.date.fromisoformat(iso)
    month = MONTHS[code].split()[d.month - 1] if code in MONTHS else d.strftime("%B")
    return DATES[code].format(y=d.year, m=d.month, d=d.day, month=month)


def parse(path, released):
    """The versions in a changelog that have a stable tag, newest first."""
    versions = []
    current = None  # None under a heading that isn't a released version, like [Unreleased]
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("## "):
            m = re.match(r"## \[([^\]]+)\] - (\d{4}-\d{2}-\d{2})", line)
            current = {"version": m[1], "date": m[2], "summary": [], "sections": []} if m and f"v{m[1]}" in released else None
            if current: versions.append(current)
        elif current and line.startswith("### "):
            current["sections"].append((line[4:], []))
        elif current and line.startswith("- ") and current["sections"]:
            current["sections"][-1][1].append(line[2:])
        elif current and line and not current["sections"] and not line.startswith("#"):
            # A line of prose under the version's heading, before its first section: what the version is about.
            current["summary"].append(line)
    return versions


LINK = re.compile(r"\[([^\]]+)\]\((https?://[^)\s]+)\)")
ISSUES = re.compile(r"\s*\((\[#\d+\]\(https?://[^)\s]+\)(?:,\s*)?)+\)\s*$")


def inline(text):
    """A note as the app shows it: its links are links, and its issue references ("([#3](…))") a quiet "#3" at the
    end. Everything else is escaped text, so nothing in a note can become markup."""
    issues = ""
    m = ISSUES.search(text)
    if m:
        issues = " ".join(f'<a class="issue" href="{html.escape(u)}">{html.escape(t)}</a>' for t, u in LINK.findall(m[0]))
        text = text[:m.start()]
    out, last = "", 0
    for m in LINK.finditer(text):
        out += html.escape(text[last:m.start()]) + f'<a href="{html.escape(m[2])}">{html.escape(m[1])}</a>'
        last = m.end()
    out += html.escape(text[last:])
    return out + (f" {issues}" if issues else "")


NONE_YET = 'Release notes in this language start with the next version. Until then, <a href="/release-notes/">read them in English</a>.'
EARLIER = 'Notes for earlier versions are in <a href="/release-notes/">English</a>.'


def page(code, folder, versions, earlier):
    """One language's page. earlier: English has stable versions older than this language's notes."""
    if code == "en":
        t = lambda s: html.escape(s, quote=False)
    else:
        words = {**languages.strings(code), **languages.strings(code, "release-notes")}
        t = lambda s: words[s] if "<a " in s else html.escape(words[s], quote=False)
    home = f"/{folder}/" if folder else "/"
    here = f"{languages.url(folder)}release-notes/"
    entries = []
    for v in versions:
        sections = "".join(f'<p class="summary">{inline(line)}</p>' for line in v["summary"]) + "".join(
            f"<h3>{html.escape(title)}</h3><ul>" + "".join(f"<li>{inline(item)}</li>" for item in items) + "</ul>"
            for title, items in v["sections"])
        entries.append(
            f'<article class="rel" id="v{html.escape(v["version"])}">'
            f'<header><h2><a href="#v{html.escape(v["version"])}">{html.escape(v["version"])}</a></h2>'
            f'<time datetime="{v["date"]}">{day(v["date"], code)}</time></header>'
            f'<div class="notes">{sections}</div></article>')
    if code != "en" and not versions:
        entries.append(f'<p class="more">{t(NONE_YET)}</p>')
    elif code != "en" and earlier:
        entries.append(f'<p class="more">{t(EARLIER)}</p>')
    title, description = t("Zigzag Release Notes"), t("What's new in each version of Zigzag, the lightweight browser for Mac.")
    text = f"""<!doctype html>
<!-- Made by scripts/changelog-page.py from CHANGELOG.md, docs/i18n/changelog and scripts/site-strings. Edit those, not this. -->
<html lang="{code}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#F5F8FC" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0F141B" media="(prefers-color-scheme: dark)">
<title>{title}</title>
<meta name="description" content="{description}">
<link rel="canonical" href="{here}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Zigzag">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{description}">
<meta property="og:image" content="https://zigzagbrowser.com/assets/og.png">
<meta property="og:url" content="{here}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="https://zigzagbrowser.com/assets/og.png">
<link rel="icon" type="image/png" href="/assets/favicon-64.png">
<link rel="apple-touch-icon" href="/assets/icon-256.png">
<link rel="stylesheet" href="/assets/site.css?v=1799800000">
</head>
<body>
<header class="bar"><a class="bar-home" href="{home}" aria-label="{t("Zigzag home")}"><img src="/assets/icon-64.png" width="28" height="28" alt=""><span class="wm" role="img" aria-label="Zigzag"></span></a><span class="bar-end"><a class="gh" href="https://github.com/ZigaoWang/zigzag" aria-label="{t("Zigzag on GitHub")}" title="{t("Zigzag on GitHub")}"><svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg></a><a class="button small" href="/download">{t("Download")}</a></span></header>
<main class="log">
  <h1>{t("Release Notes")}</h1>
  <p class="lede">{t("What changed in each version of Zigzag. Updates install by themselves, so you're always on the newest.")}</p>
  {''.join(entries)}
</main>
<footer class="end end-simple">
  <nav class="foot-links">
    <a href="{home}release-notes/">{t("Release Notes")}</a>
    <a href="https://github.com/ZigaoWang/zigzag">GitHub</a>
    <a href="https://github.com/ZigaoWang/zigzag/issues">{t("Report a bug")}</a>
    <a href="https://github.com/ZigaoWang/zigzag/blob/main/LICENSE">{t("License")}</a>
    <a href="mailto:a@zigao.wang">a@zigao.wang</a>
  </nav>
  <p class="fine">© 2026 Zigao Wang</p>
</footer>
</body>
</html>
"""
    return languages.with_links(text, code, "release-notes/")


def main():
    check = "--check" in sys.argv
    # Only versions released as stable (a vX.Y.Z tag): a version still in beta has its notes in CHANGELOG.md already.
    subprocess.run(["git", "-C", str(root), "fetch", "-q", "--tags", "origin"], check=False)
    released = set(subprocess.run(["git", "-C", str(root), "tag", "-l", "v*"], capture_output=True, text=True, check=True).stdout.split())
    english = parse(root / "CHANGELOG.md", released)
    out = {root / "site" / "release-notes" / "index.html": page("en", "", english, False)}
    counts = [f"en {len(english)}"]
    for code, _, folder in languages.LANGS[1:]:
        versions = parse(root / "docs" / "i18n" / "changelog" / f"CHANGELOG.{code}.md", released)
        shown = {v["version"] for v in versions}
        earlier = bool(versions) and any(v["version"] not in shown and v["date"] <= versions[-1]["date"] for v in english)
        out[root / "site" / folder / "release-notes" / "index.html"] = page(code, folder, versions, earlier)
        counts.append(f"{code} {len(versions)}")
    # The page's first address still works.
    out[root / "site" / "changelog" / "index.html"] = (
        '<!doctype html><meta charset="utf-8"><title>Zigzag Release Notes</title>'
        '<link rel="canonical" href="/release-notes"><meta http-equiv="refresh" content="0; url=/release-notes">'
        '<a href="/release-notes">Zigzag Release Notes</a>\n')
    stale = [p for p, text in out.items() if not p.exists() or p.read_text(encoding="utf-8") != text]
    if check:
        if stale:
            sys.exit("changelog-page: out of date: " + ", ".join(str(p.relative_to(root)) for p in stale)
                     + "; run scripts/changelog-page.py")
        print("Checked the release notes in", len(out) - 1, "languages")
        return
    for p in stale:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(out[p], encoding="utf-8")
    print("Wrote the release notes, versions per language:", ", ".join(counts))


if __name__ == "__main__":
    main()
