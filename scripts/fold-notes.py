"""Moves the Unreleased notes into a version's section in CHANGELOG.md and every translation: scripts/fold-notes.py 0.10.0

Each Unreleased point goes to the end of the version's section with the same heading; a heading the version doesn't
have yet is added in the order the Unreleased section has it. Unreleased is left empty. Writes nothing unless every
file folds cleanly.
"""
import glob
import re
import sys

version = sys.argv[1]
files = ["CHANGELOG.md"] + sorted(glob.glob("docs/i18n/changelog/CHANGELOG.*.md"))


def sections(body):
    """The (heading, points) pairs of a version's body, and the lines before its first heading."""
    intro, out, current = [], [], None
    for line in body.splitlines():
        if line.startswith("### "):
            current = (line, [])
            out.append(current)
        elif current is None:
            intro.append(line)
        elif line.strip():
            current[1].append(line)
    return intro, out


def render(intro, parts):
    text = "\n".join(intro).strip("\n")
    blocks = ([text] if text else []) + ["\n".join([h] + points) for h, points in parts if points]
    return "\n\n".join(blocks) + "\n\n"


folded = {}
for path in files:
    text = open(path, encoding="utf-8").read()
    u = re.search(r"^## \[Unreleased\]\n(.*?)(?=^## \[|\Z)", text, re.M | re.S)
    v = re.search(r"^(## \[" + re.escape(version) + r"\][^\n]*\n)(.*?)(?=^## \[|\Z)", text, re.M | re.S)
    if not u or not v:
        sys.exit(f"{path}: no Unreleased or {version} section")
    _, new = sections(u.group(1))
    if not any(points for _, points in new):
        sys.exit(f"{path}: Unreleased is empty")
    intro, old = sections(v.group(2))
    order = [h.strip() for h, _ in new]
    for i, (heading, points) in enumerate(new):
        match = next((p for h, p in old if h.strip() == heading.strip()), None)
        if match is None:
            # Before the first heading Unreleased puts after this one, so New, Changed, Fixed keep their order.
            later = set(order[i + 1:])
            at = next((j for j, (h, _) in enumerate(old) if h.strip() in later), len(old))
            old.insert(at, (heading, list(points)))
        else:
            match.extend(points)
    if any(re.search(r"^[-*] ", l) is None for _, p in old for l in p):
        sys.exit(f"{path}: a line that isn't a point in {version}")
    result = text[:u.start(1)] + "\n" + text[u.end(1):v.start(2)] + "\n" + render(intro, old) + text[v.end(2):]
    before = sum(len(p) for _, p in sections(v.group(2))[1]) + sum(len(p) for _, p in new)
    after_v = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)", result, re.M | re.S)
    if sum(len(p) for _, p in sections(after_v.group(1))[1]) != before:
        sys.exit(f"{path}: point count changed")
    folded[path] = result

for path, result in folded.items():
    open(path, "w", encoding="utf-8").write(result)
print(f"folded Unreleased into {version} in {len(folded)} files")
