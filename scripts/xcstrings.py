"""Reads and writes Zigzag's string catalogs the way Xcode does, for check-strings.py and merge-translations.py."""
import json
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOGS = ("Localizable", "InfoPlist")
SOURCE = "en"

# A format argument: an optional position, then a substitution (%#@name@) or a printf conversion.
_ARGUMENT = re.compile(r"%(?:(\d+)\$)?(#@\w+@|[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaFi]|%)")


def path(name, repo=REPO):
    return os.path.join(repo, "Zigzag", "Resources", f"{name}.xcstrings")


def load(file):
    """The catalog, and its raw text's trailing whitespace, so writing it back changes nothing else."""
    with open(file, encoding="utf-8") as f:
        raw = f.read()
    return json.loads(raw), raw[len(raw.rstrip()):]


def dump(catalog, tail):
    """Xcode's own layout: two spaces, `"key" : value`, non-ASCII as is."""
    return json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : ")) + tail


def sorted_object(value):
    """Keys in the order Xcode writes them."""
    if isinstance(value, dict):
        return {key: sorted_object(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [sorted_object(item) for item in value]
    return value


def translatable(entry):
    """A string the app uses and someone should translate: not stale, not marked do-not-translate."""
    return entry.get("shouldTranslate", True) and entry.get("extractionState") != "stale"


def shipped_languages(repo=REPO):
    """Every language the app ships: the project's known regions, and any language either catalog has a string in."""
    languages = set()
    project = os.path.join(repo, "Zigzag.xcodeproj", "project.pbxproj")
    if os.path.exists(project):
        text = open(project, encoding="utf-8").read()
        block = re.search(r"knownRegions = \((.*?)\);", text, re.S)
        if block:
            languages |= {name.strip().strip('"') for name in block.group(1).split(",") if name.strip()}
    for name in CATALOGS:
        catalog, _ = load(path(name, repo))
        for entry in catalog["strings"].values():
            languages |= set(entry.get("localizations", {}))
    return sorted(languages - {"Base", SOURCE})


def units(node, where=""):
    """Every string unit under a localization, with where it sits: "", "plural.one", "substitutions.n.plural.other"."""
    found = []
    if not isinstance(node, dict):
        return found
    if "stringUnit" in node:
        found.append((where, node["stringUnit"]))
    for kind, forms in node.get("variations", {}).items():
        for form, child in forms.items():
            found += units(child, f"{where}.{kind}.{form}".lstrip("."))
    for name, sub in node.get("substitutions", {}).items():
        found += units(sub, f"{where}.substitutions.{name}".lstrip("."))
    return found


def arguments(text, localization):
    """The arguments a format reads, as {position: type}: "%2$@ has %lld" reads {1: "lld", 2: "@"}."""
    subs = (localization or {}).get("substitutions", {})
    found, following = {}, 0
    for match in _ARGUMENT.finditer(text):
        kind = match.group(2)
        if kind == "%":
            continue
        following += 1
        position = int(match.group(1)) if match.group(1) else following
        if kind.startswith("#@"):
            sub = subs.get(kind[2:-1], {})
            found[sub.get("argNum", position)] = sub.get("formatSpecifier")
        else:
            found[position] = "lld" if kind.endswith("lld") else kind[-1]
    return found


def english(key, entry):
    """The English localization, or one made from the key when the code's English is the key itself."""
    return entry.get("localizations", {}).get(SOURCE) or {"stringUnit": {"state": "translated", "value": key}}


def problems(key, entry, localization):
    """What's wrong with one language's localization of a string, as short notes. Empty when it's ready to ship."""
    if not isinstance(localization, dict):
        return ["no translation"]
    source = english(key, entry)
    notes = []
    found = units(localization)
    if not found:
        notes.append("no string")
    for where, unit in found:
        state = unit.get("state") if isinstance(unit, dict) else None
        value = unit.get("value") if isinstance(unit, dict) else None
        if state != "translated":
            notes.append(f"{where or 'string'} is {state or 'without a state'}")
        if not isinstance(value, str) or not value.strip():
            notes.append(f"{where or 'string'} is empty")
    # The same shape as the English: plural where it's plural, the same substitutions.
    plural = "plural" in source.get("variations", {})
    if plural and "other" not in localization.get("variations", {}).get("plural", {}):
        notes.append("plural has no other form")
    if not plural and "stringUnit" not in localization:
        notes.append("not one string, as the English is")
    wanted_subs, given_subs = source.get("substitutions", {}), localization.get("substitutions", {})
    if set(wanted_subs) != set(given_subs):
        notes.append(f"substitutions {sorted(given_subs)} instead of {sorted(wanted_subs)}")
    for name, sub in wanted_subs.items():
        mine = given_subs.get(name, {})
        if (mine.get("argNum"), mine.get("formatSpecifier")) != (sub.get("argNum"), sub.get("formatSpecifier")):
            notes.append(f"substitution {name} reads a different argument")
        if "other" not in mine.get("variations", {}).get("plural", {}):
            notes.append(f"substitution {name} has no other form")
    notes += _argument_problems(source, localization)
    return notes


def _argument_problems(source, localization):
    """Each form takes the English's arguments. A plural form other than "other" may leave some out, as "Close Tab"
    leaves out the count, but never reads one the English doesn't or reads one as another type."""
    notes = []
    english_units = dict(units(source))
    full = None
    for where, unit in units(source):
        if where in ("", "plural.other"):
            full = arguments(unit.get("value", ""), source)
    for where, unit in units(localization):
        value = unit.get("value") if isinstance(unit, dict) else None
        if not isinstance(value, str):
            continue
        if where.startswith("substitutions."):
            # A substitution's forms read only its own number, as %arg or its specifier.
            spec = source.get("substitutions", {}).get(where.split(".")[1], {}).get("formatSpecifier")
            kinds = set(arguments(value.replace("%arg", ""), None).values())
            if kinds - {spec}:
                notes.append(f"{where} reads {sorted(kinds)}, not %{spec}")
            continue
        given = arguments(value, localization)
        if where in ("", "plural.other"):
            if given != full:
                notes.append(f"{where or 'string'} reads {_show(given)}, the English {_show(full)}")
        else:
            reference = arguments(english_units[where].get("value", ""), source) if where in english_units else {}
            allowed = {**reference, **(full or {})}
            if any(allowed.get(position) != kind for position, kind in given.items()):
                notes.append(f"{where} reads {_show(given)}, the English {_show(allowed)}")
    return notes


def _show(args):
    return "nothing" if not args else ", ".join(f"{p}:%{k}" for p, k in sorted(args.items()))
