#!/usr/bin/env python3
"""Builds zigzagbrowser.com/changelog from CHANGELOG.md: every version, newest first, the same notes the app shows.

Run by site/deploy.sh, so the page is rebuilt whenever the site goes out (and so after every release).
"""
import datetime, html, pathlib, re

root = pathlib.Path(__file__).resolve().parent.parent
versions = []
for raw in (root / "CHANGELOG.md").read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if m := re.match(r"## \[([^\]]+)\] - (\d{4}-\d{2}-\d{2})", line):
        versions.append({"version": m[1], "date": m[2], "sections": []})
    elif line.startswith("### ") and versions:
        versions[-1]["sections"].append((line[4:], []))
    elif line.startswith("- ") and versions and versions[-1]["sections"]:
        versions[-1]["sections"][-1][1].append(line[2:])

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
<title>Zigzag Changelog</title>
<meta name="description" content="What's new in each version of Zigzag, the lightweight browser for Mac.">
<link rel="icon" type="image/png" href="/assets/favicon-64.png">
<link rel="stylesheet" href="/assets/site.css?v=changelog-1">
</head>
<body>
<header class="dl-bar"><a href="/" aria-label="Zigzag home"><span class="wm" role="img" aria-label="Zigzag"></span></a></header>
<main class="log">
  <h1>Changelog</h1>
  <p class="lede">What changed in each version of Zigzag. Updates install by themselves, so you're always on the newest.</p>
  {''.join(entries)}
</main>
<footer class="end"><p class="fine">Made in Shanghai by <a href="https://zigao.wang">Zigao Wang</a></p></footer>
</body>
</html>
"""
out = root / "site" / "changelog" / "index.html"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(page, encoding="utf-8")
print(f"Wrote {out.relative_to(root)} with {len(versions)} versions")
