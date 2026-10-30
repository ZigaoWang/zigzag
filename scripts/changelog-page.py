#!/usr/bin/env python3
"""Builds zigzagbrowser.com/release-notes from CHANGELOG.md: every version, newest first, the same notes the app shows.

Run by site/deploy.sh, so the page is rebuilt whenever the site goes out (and so after every release).
"""
import datetime, html, pathlib, re

root = pathlib.Path(__file__).resolve().parent.parent
versions = []
current = None  # None under a heading that isn't a released version, like [Unreleased]
for raw in (root / "CHANGELOG.md").read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if line.startswith("## "):
        m = re.match(r"## \[([^\]]+)\] - (\d{4}-\d{2}-\d{2})", line)
        current = {"version": m[1], "date": m[2], "sections": []} if m else None
        if current: versions.append(current)
    elif current and line.startswith("### "):
        current["sections"].append((line[4:], []))
    elif current and line.startswith("- ") and current["sections"]:
        current["sections"][-1][1].append(line[2:])

# The same footer as the rest of the site.
FOOTER = """<footer class="end">
  <nav class="foot-links">
    <a href="/release-notes">Release Notes</a>
    <a href="https://github.com/ZigaoWang/zigzag">GitHub</a>
    <a href="https://github.com/ZigaoWang/zigzag/issues">Report a bug</a>
    <a href="https://github.com/ZigaoWang/zigzag/blob/main/LICENSE">License</a>
    <a href="mailto:a@zigao.wang">a@zigao.wang</a>
  </nav>
  <p class="fine">© 2026 Zigao Wang</p>
</footer>"""

def day(iso):
    d = datetime.date.fromisoformat(iso)
    return f"{d.strftime('%B')} {d.day}, {d.year}"

entries = []
for v in versions:
    sections = "".join(
        f"<h3>{html.escape(title)}</h3><ul>" + "".join(f"<li>{html.escape(item)}</li>" for item in items) + "</ul>"
        for title, items in v["sections"])
    entries.append(
        f'<article class="rel" id="v{html.escape(v["version"])}">'
        f'<header><h2><a href="#v{html.escape(v["version"])}">{html.escape(v["version"])}</a></h2>'
        f'<time datetime="{v["date"]}">{day(v["date"])}</time></header>'
        f'<div class="notes">{sections}</div></article>')

page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Zigzag Release Notes</title>
<meta name="description" content="What's new in each version of Zigzag, the lightweight browser for Mac.">
<link rel="icon" type="image/png" href="/assets/favicon-64.png">
<link rel="stylesheet" href="/assets/site.css?v=1793110000">
</head>
<body>
<header class="bar"><a href="/" aria-label="Zigzag home"><span class="wm" role="img" aria-label="Zigzag"></span></a><a class="button small" href="/download">Download</a></header>
<main class="log">
  <h1>Release Notes</h1>
  <p class="lede">What changed in each version of Zigzag. Updates install by themselves, so you're always on the newest.</p>
  {''.join(entries)}
</main>
{FOOTER}
</body>
</html>
"""
out = root / "site" / "release-notes" / "index.html"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(page, encoding="utf-8")
# The page's first address still works.
old = root / "site" / "changelog" / "index.html"
old.parent.mkdir(parents=True, exist_ok=True)
old.write_text('<!doctype html><meta charset="utf-8"><title>Zigzag Release Notes</title>'
               '<link rel="canonical" href="/release-notes"><meta http-equiv="refresh" content="0; url=/release-notes">'
               '<a href="/release-notes">Zigzag Release Notes</a>\n', encoding="utf-8")
print(f"Wrote {out.relative_to(root)} with {len(versions)} versions")
