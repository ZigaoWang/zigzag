#!/usr/bin/env python3
"""Makes Zigzag/Resources/hsts_preload.txt from Chromium's HSTS preload list.

Only the host names of `force-https` entries are kept (no pins, no test entries), one a line: a name alone covers its
subdomains too, `=name` covers that name only. Run from the repository root:

    scripts/update-hsts-preload.py

then note the Chromium commit in THIRD_PARTY_NOTICES.md.
"""
import json
import pathlib
import urllib.request

SOURCE = "https://raw.githubusercontent.com/chromium/chromium/main/net/http/transport_security_state_static.json"
OUT = pathlib.Path(__file__).resolve().parent.parent / "Zigzag" / "Resources" / "hsts_preload.txt"


def main():
    text = urllib.request.urlopen(SOURCE, timeout=60).read().decode("utf-8")
    # The file is JSON with // comment lines.
    data = json.loads("\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//")))
    covers, alone = set(), set()
    for entry in data["entries"]:
        if entry.get("mode") != "force-https" or entry.get("policy") == "test":
            continue
        name = entry["name"].lower().strip(".")
        (covers if entry.get("include_subdomains") else alone).add(name)
    # One list sorted byte by byte, which Zigzag searches in place without reading it into memory.
    lines = sorted(list(covers) + ["=" + name for name in alone - covers], key=lambda line: line.encode("utf-8"))
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{len(covers)} with subdomains, {len(alone - covers)} alone")


if __name__ == "__main__":
    main()
