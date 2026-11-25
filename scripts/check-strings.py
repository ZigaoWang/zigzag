#!/usr/bin/env python3
"""Lists the strings each shipped language still needs, in Localizable.xcstrings and InfoPlist.xcstrings.

    scripts/check-strings.py              every language Zigzag ships
    scripts/check-strings.py ja ko        only these
    scripts/check-strings.py --all        every key, not the first 20 per language

A string needs work when it has no translation, a form that isn't "translated" (needs_review, new, stale), an empty
value, or format arguments that differ from the English. Exits 1 when any language has one; release.sh stops on it.
"""
import os
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


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    everything = "--all" in argv
    repo = os.environ.get("ZIGZAG_REPO", xcstrings.REPO)
    languages = args or xcstrings.shipped_languages(repo)
    needs = report(languages, repo)
    failed = False
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
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
