#!/usr/bin/env python3
"""Folds translations/<lang>.json files into Localizable.xcstrings and InfoPlist.xcstrings.

    scripts/merge-translations.py translations/ko.json [translations/de.json …]
    scripts/merge-translations.py --check translations/ko.json     validate only, write nothing
    scripts/merge-translations.py --allow-missing translations/ko.json   merge a partial file

Each file is
    {"language": "ko",
     "Localizable": {"<catalog key>": <what goes at strings[key].localizations.ko>, …},
     "InfoPlist": {"<key>": <the same, for InfoPlist.xcstrings>, …}}
with values shaped as the catalog keeps zh-Hans: {"stringUnit": {"state": "translated", "value": "…"}}, or
{"variations": {"plural": {…}}}, or substitutions, as the English entry has. Each value replaces that language's
localization as it is; nothing else in the catalogs changes, so the diff only adds (or, for a replaced language,
changes) lines.

It refuses, writing nothing, when a file names a key the catalog doesn't have, lacks a key the catalog has (unless
--allow-missing), has a form that isn't "translated", or reads different format arguments than the English.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xcstrings  # noqa: E402


def check(translation, catalogs, allow_missing=False):
    """The problems with one file, as lines; empty when it can be merged."""
    language = translation.get("language")
    if not isinstance(language, str) or not language or language in (xcstrings.SOURCE, "Base"):
        return [f"language is {language!r}, not a language to translate into"]
    lines = []
    for name in xcstrings.CATALOGS:
        given = translation.get(name, {})
        if not isinstance(given, dict):
            lines.append(f"{name}: not a map of keys")
            continue
        strings = catalogs[name][0]["strings"]
        for key in sorted(set(given) - set(strings)):
            lines.append(f"{name}: unknown key {key!r}")
        for key in sorted(set(given) & set(strings)):
            if not xcstrings.translatable(strings[key]):
                lines.append(f"{name}: {key!r} isn't translated (stale or marked do-not-translate)")
                continue
            for note in xcstrings.problems(key, strings[key], given[key]):
                lines.append(f"{name}: {key!r}: {note}")
        missing = sorted(key for key, entry in strings.items() if xcstrings.translatable(entry) and key not in given)
        if missing and not allow_missing:
            lines.append(f"{name}: {len(missing)} keys missing, the first: " + ", ".join(repr(k) for k in missing[:10]))
    return lines


def merge(translation, catalogs):
    """Puts the file's localizations into the catalogs, each language in Xcode's sorted place."""
    language = translation["language"]
    for name in xcstrings.CATALOGS:
        strings = catalogs[name][0]["strings"]
        for key, value in translation.get(name, {}).items():
            entry = strings[key]
            old = entry.get("localizations", {})
            new = {}
            placed = False
            for existing, localization in old.items():
                if not placed and existing >= language:
                    new[language] = xcstrings.sorted_object(value)
                    placed = True
                if existing != language:
                    new[existing] = localization
            if not placed:
                new[language] = xcstrings.sorted_object(value)
            had = "localizations" in entry
            entry["localizations"] = new
            if not had:
                # An entry's own keys in Xcode's order too.
                strings[key] = {k: entry[k] for k in sorted(entry)}

def main(argv):
    dry = "--check" in argv
    allow_missing = "--allow-missing" in argv
    files = [a for a in argv if not a.startswith("--")]
    if not files:
        print(__doc__.strip())
        return 2
    repo = os.environ.get("ZIGZAG_REPO", xcstrings.REPO)
    catalogs = {name: xcstrings.load(xcstrings.path(name, repo)) for name in xcstrings.CATALOGS}
    translations, failed = [], False
    for file in files:
        try:
            with open(file, encoding="utf-8") as f:
                translation = json.load(f)
        except (OSError, ValueError) as error:
            print(f"{file}: can't be read: {error}")
            failed = True
            continue
        lines = check(translation, catalogs, allow_missing) if isinstance(translation, dict) else ["not a JSON object"]
        stem = os.path.splitext(os.path.basename(file))[0]
        if isinstance(translation, dict) and translation.get("language") != stem:
            lines.insert(0, f"language {translation.get('language')!r} doesn't match the file name {stem!r}")
        label = translation.get("language", file) if isinstance(translation, dict) else file
        if lines:
            failed = True
            print(f"{label}: {len(lines)} problems, not merged")
            for line in lines:
                print(f"  {line}")
        else:
            counts = ", ".join(f"{len(translation.get(n, {}))} {n}" for n in xcstrings.CATALOGS)
            print(f"{label}: ready ({counts})")
            translations.append(translation)
    if failed:
        print("Nothing was merged.")
        return 1
    if dry:
        return 0
    for translation in translations:
        merge(translation, catalogs)
    for name, (catalog, tail) in catalogs.items():
        with open(xcstrings.path(name, repo), "w", encoding="utf-8") as f:
            f.write(xcstrings.dump(catalog, tail))
    print("Merged " + ", ".join(t["language"] for t in translations) + ". Run scripts/check-strings.py, then the tests.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
