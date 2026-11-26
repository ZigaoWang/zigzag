#!/usr/bin/env python3
"""Lists the strings each shipped language still needs, in Localizable.xcstrings and InfoPlist.xcstrings, and checks
each language's release notes for the version being released.

    scripts/check-strings.py                  every language Zigzag ships
    scripts/check-strings.py ja ko            only these
    scripts/check-strings.py --all            every key, not the first 20 per language
    scripts/check-strings.py --notes 0.10.0   the notes of this version, not project.yml's

A string needs work when it has no translation, a form that isn't "translated" (needs_review, new, stale), an empty
value, or format arguments that differ from the English. A language's notes need work when
docs/i18n/changelog/CHANGELOG.<language>.md has no section for the version, or one with other sections, another
number of points or other issue links than CHANGELOG.md's. Exits 1 when any language needs either; release.sh stops
on it.
"""
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xcstrings  # noqa: E402


def report(languages, repo=xcstrings.REPO):
    """{language: [(catalog, key, notes)]} for every string a language still needs."""
    needs = {language: [] for language in languages}
    for name in xcstrings.CATALOGS:
        catalog, _ = xcstrings.load(xcstrings.path(name, repo))
        for key, entry in catalog["strings"].items():
            if not xcstrings.translatable(entry):
                continue
            for language in languages:
                notes = xcstrings.problems(key, entry, entry.get("localizations", {}).get(language))
                if notes:
                    needs[language].append((name, key, notes))
    return needs


def changelog(language, repo=xcstrings.REPO):
    """The language's release notes: CHANGELOG.md for English, the translation under docs/i18n/changelog otherwise."""
    if language == xcstrings.SOURCE:
        return os.path.join(repo, "CHANGELOG.md")
    return os.path.join(repo, "docs", "i18n", "changelog", f"CHANGELOG.{language}.md")


def notes(text, version):
    """A version's sections, each a list of its points' issue numbers, as What's New reads them; None without one."""
    sections, inside, found = [], False, False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("## "):
            if inside:
                break
            inside = line.startswith(f"## [{version}]")
            found = found or inside
        elif not inside:
            continue
        elif line.startswith("### "):
            sections.append([])
        elif line.startswith(("- ", "* ")) and sections:
            sections[-1].append([])
        if inside and sections and sections[-1] and not line.startswith("#"):
            # A point can run on over more lines; its issues are the #N links in any of them.
            sections[-1][-1] += [int(n) for n in re.findall(r"\[#(\d+)\]\(", line)]
    return sections if found else None


def notes_problems(version, languages, repo=xcstrings.REPO):
    """{language: problem} for each language whose notes for the version don't match the English."""
    source = changelog(xcstrings.SOURCE, repo)
    english = notes(open(source, encoding="utf-8").read(), version) if os.path.exists(source) else None
    if not english:
        return {}
    problems = {}
    for language in languages:
        file = changelog(language, repo)
        translated = notes(open(file, encoding="utf-8").read(), version) if os.path.exists(file) else None
        name = os.path.relpath(file, repo)
        if translated is None:
            problems[language] = f"{name} has no section for {version}"
        elif [len(s) for s in translated] != [len(s) for s in english]:
            problems[language] = (f"{name}'s {version} has {[len(s) for s in translated]} points per section, "
                                  f"the English {[len(s) for s in english]}")
        elif translated != english:
            problems[language] = f"{name}'s {version} links other issues than the English"
    return problems


def planned_version(repo=xcstrings.REPO):
    """The version being released: project.yml's MARKETING_VERSION."""
    project = os.path.join(repo, "project.yml")
    if not os.path.exists(project):
        return None
    match = re.search(r'MARKETING_VERSION:\s*"?([^"\s]+)', open(project, encoding="utf-8").read())
    return match and match.group(1)


def main(argv):
    version = None
    if "--notes" in argv:
        at = argv.index("--notes")
        if at + 1 >= len(argv):
            sys.exit(__doc__)
        version = argv[at + 1]
        argv = argv[:at] + argv[at + 2:]
    args = [a for a in argv if not a.startswith("--")]
    everything = "--all" in argv
    repo = os.environ.get("ZIGZAG_REPO", xcstrings.REPO)
    languages = args or xcstrings.shipped_languages(repo)
    needs = report(languages, repo)
    version = version or planned_version(repo)
    late = notes_problems(version, languages, repo) if version else {}
    failed = bool(late)
    for language in languages:
        missing = needs[language]
        if not missing:
            print(f"{language}: every string is translated")
            continue
        failed = True
        print(f"{language}: {len(missing)} strings need translating or review")
        for name, key, notes in missing if everything else missing[:20]:
            print(f"  {name}: {key!r}: {'; '.join(notes)}")
        if len(missing) > 20 and not everything:
            print(f"  … and {len(missing) - 20} more (--all lists them)")
    for language in languages:
        if language in late:
            print(f"{language}: release notes: {late[language]}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
