#!/usr/bin/env python3
"""The release notes for the update window and the GitHub release, from CHANGELOG.md and CHANGELOG.zh-Hans.md.

Usage: scripts/release-notes.py VERSION PLANNED OUT

Writes, for the version being released (a beta uses the section of the version it leads up to, PLANNED):
- OUT/updates/Zigzag-VERSION.html: the English notes, which generate_appcast embeds in the feed.
- OUT/updates/Zigzag-VERSION.en.html and .zh.html, when CHANGELOG.zh-Hans.md has the version: generate_appcast
  links each with xml:lang, and Sparkle shows the one in the app's language (English for any other).
- OUT/notes.md: the English notes as Markdown, for `gh release create --notes-file`.

Run by scripts/release.sh; it reads nothing else and touches nothing outside OUT, so it can be run on its own.
"""
import html, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
STYLE = ("<style>:root{color-scheme:light dark}body{font:13px -apple-system,sans-serif;margin:0 4px}"
         "h3{font-size:13px;margin:14px 0 6px}ul{margin:0;padding-left:18px}li{margin:4px 0;line-height:1.4}"
         "p{margin:10px 0 0;line-height:1.4}</style>")


def section(text, version):
    """A version's summary lines and its sections, each a heading and its points: ([], []) when it has none."""
    sections, summary, inside = [], [], False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("## "):
            if inside: break
            inside = line.startswith(f"## [{version}]")
        elif inside and line.startswith("### "): sections.append((line[4:], []))
        elif inside and line.startswith("- ") and sections: sections[-1][1].append(line[2:])
        # A line of prose under the version's heading, before its first section, is its summary.
        elif inside and line and not sections and not line.startswith(("#", "<!--")): summary.append(line)
    return summary, sections


def body(summary, sections):
    return "".join(f"<p>{html.escape(s)}</p>" for s in summary) + "".join(
        f"<h3>{html.escape(t)}</h3><ul>" + "".join(f"<li>{html.escape(i)}</li>" for i in items) + "</ul>"
        for t, items in sections)


def page(lang, summary, sections):
    """A whole page, for a linked file: served on its own, it says it's UTF-8 rather than leave it to the server."""
    return (f'<!doctype html><html lang="{lang}"><head><meta charset="utf-8">{STYLE}</head>'
            f"<body>{body(summary, sections)}</body></html>")


def write(version, planned, out, root=ROOT):
    out = pathlib.Path(out)
    (out / "updates").mkdir(parents=True, exist_ok=True)
    summary, sections = section((root / "CHANGELOG.md").read_text(encoding="utf-8"), planned)
    if not sections: sys.exit(f"CHANGELOG.md has no notes for {planned}")
    # A fragment, without <body>: generate_appcast embeds it as the update's description.
    (out / "updates" / f"Zigzag-{version}.html").write_text(STYLE + body(summary, sections), encoding="utf-8")
    zh = root / "CHANGELOG.zh-Hans.md"
    zh_summary, zh_sections = section(zh.read_text(encoding="utf-8"), planned) if zh.exists() else ([], [])
    if zh_sections:
        # generate_appcast takes the language from the name's ISO 639 code: "zh", which macOS matches to zh-Hans.
        # English gets a link of its own too, or Sparkle would show the only link, the Chinese one, to everyone.
        (out / "updates" / f"Zigzag-{version}.en.html").write_text(page("en", summary, sections), encoding="utf-8")
        (out / "updates" / f"Zigzag-{version}.zh.html").write_text(page("zh-Hans", zh_summary, zh_sections), encoding="utf-8")
    else:
        print(f"Warning: CHANGELOG.zh-Hans.md has no notes for {planned}; the update window shows English to everyone.",
              file=sys.stderr)
    md = "".join(f"{s}\n\n" for s in summary) + "\n\n".join(f"## {t}\n" + "\n".join(f"- {i}" for i in items) for t, items in sections)
    md += ("\n\nDownload the DMG, open it, and drag Zigzag to Applications. Requires macOS 15.4 or later. Updates install automatically."
           "\n\nEvery version's notes: https://zigzagbrowser.com/release-notes\n")
    (out / "notes.md").write_text(md, encoding="utf-8")
    return bool(zh_sections)


if __name__ == "__main__":
    if len(sys.argv) != 4: sys.exit(__doc__)
    write(*sys.argv[1:4])
