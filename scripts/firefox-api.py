#!/usr/bin/env python3
"""Writes Zigzag/Resources/Extensions/firefox-api.json: every Firefox extension API, from Mozilla's own definitions.

Firefox's WebExtension APIs are published as TypeScript types by DefinitelyTyped (`@types/firefox-webext-browser`).
They declare each API as a top-level `declare namespace browser.<name>` block, with its functions, events, constants,
string enums and objects (`storage.local`, `privacy.network.networkPredictionEnabled`). This reads them and writes the
same namespace/function/event/constant/enum/object shape scripts/chrome-api.py writes, so api-surface.js and the claims
validator can be pointed at either browser. `browser._manifest` is types for manifest.json, not a runtime API, and is
skipped. The package does not annotate permissions, so none are invented here: Firefox permission rows are seeded by
hand from Mozilla's documented list.

    scripts/firefox-api.py [path/to/firefox-webext-browser/index.d.ts]
    scripts/firefox-api.py --check [path/to/firefox-webext-browser/index.d.ts]

Without a path it downloads the pinned package. Change FIREFOX_TYPES_VERSION to move to a newer one. --check
regenerates in memory and exits non-zero when the committed JSON differs, naming the first path that does.
"""
import io
import json
import re
import sys
import tarfile
import urllib.error
import urllib.request
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Zigzag/Resources/Extensions/firefox-api.json"
FIREFOX_TYPES_VERSION = "143.0.1"


def load_types(path=None):
    if path is not None:
        return Path(path).read_text()
    url = ("https://registry.npmjs.org/@types/firefox-webext-browser/-/"
           f"firefox-webext-browser-{FIREFOX_TYPES_VERSION}.tgz")
    try:
        data = urllib.request.urlopen(url, timeout=60).read()
    except (urllib.error.URLError, OSError) as error:
        sys.exit(f"firefox-webext-browser {FIREFOX_TYPES_VERSION}: can't download {url}: {error}. "
                 f"Pass a local index.d.ts path to generate offline.")
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        member = tar.extractfile("firefox-webext-browser/index.d.ts")
        if member is None:
            sys.exit(f"firefox-webext-browser {FIREFOX_TYPES_VERSION}: the package has no index.d.ts")
        return member.read().decode()


def enum_key(value):
    """Firefox's runtime name for an enum value: "browser_update" is BROWSER_UPDATE, "modifyHeaders" MODIFY_HEADERS."""
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", value)
    return re.sub(r"[^A-Za-z0-9]+", "_", spaced).strip("_").upper()


def braces(line):
    """How many braces a line opens, with strings emptied first so a "{...}" literal doesn't nest anything."""
    return re.sub(r'"[^"]*"', '""', line).count("{") - re.sub(r'"[^"]*"', '""', line).count("}")


def is_event(kind):
    """A WebExtEvent<...> member, or one of the few custom event interfaces the package names `_...Event`."""
    return "Event<" in kind or bool(re.search(r"\b_?\w*Event\b", kind))


def is_primitive(kind):
    kind = re.sub(r"\s*\|\s*undefined$", "", kind.strip()).strip()
    return bool(re.fullmatch(r"string|number|boolean|any|unknown|[-+]?\d+(\.\d+)?|true|false|\"[^\"]*\"", kind))


def split_bases(text):
    """The plain interface names in an `extends` list. A generic contract (`Omit<T, "k">`, `Array<T>`) is not a base
    this document can resolve, so it is dropped rather than guessing the members it adds or removes."""
    bases = []
    depth = 0
    current = ""
    for char in text:
        if char in "<([":
            depth += 1
        elif char in ">)]":
            depth -= 1
        if char == "," and depth == 0:
            bases.append(current)
            current = ""
            continue
        current += char
    bases.append(current)
    return [base for base in (b.strip() for b in bases) if re.fullmatch(r"[\w.]+", base)]


def add_const(spec, name, kind):
    """A namespace const: an event or a runtime object. Never a constant: Firefox's types declare `const TAB_ID_NONE:
    number` and give no value, and a wrong value (`"number"`) installed by api-surface.js is worse than an absent one."""
    kind = re.sub(r"\s*\|\s*undefined\s*$", "", kind.strip()).strip().strip("|").strip()
    if is_event(kind):
        spec["events"].append(name)
    elif not is_primitive(kind):
        spec["objects"].append([name, kind])


def parse(text):
    namespaces = {}   # "privacy.network" -> entry
    interfaces = {}   # "storage.StorageArea" -> {"functions", "events", "constants", "properties", "bases"}
    stack = [("root", "", 0)]  # (kind, name, depth at which its body lives)
    depth = 0
    skipping = 0      # inside browser._manifest, whose contents are manifest types, not APIs
    pending = None    # ["type"|"const", entry, name, lines, brace delta] until the declaration reaches its `;`
    in_doc = False

    def entry(name):
        return namespaces.setdefault(name, {"functions": [], "events": [], "constants": {},
                                            "enums": {}, "objects": []})

    def current_namespace():
        for kind, name, _ in reversed(stack):
            if kind == "namespace":
                return name
        return ""

    def finish(pending):
        kind, spec, name, parts, _ = pending
        body = " ".join(parts)
        if kind == "const":
            match = re.match(r"const \w+:\s*(.*?);", body, re.S)
            if match:
                add_const(spec, name, match.group(1))
            return
        match = re.match(r"type (\w+) =(.*)$", body, re.S)
        if not match:
            return
        values = re.findall(r'"([^"]*)"', match.group(2))
        # Only an all-string union is a runtime enum; a union that also names a type (`Permission`) is not.
        cleaned = re.sub(r'"[^"]*"', "", match.group(2)).replace("|", "").replace(";", "").strip()
        if values and not cleaned:
            spec["enums"][name] = {enum_key(value): value for value in values}

    for raw in text.split("\n"):
        line = raw.strip()
        if in_doc:
            in_doc = not line.endswith("*/")
            continue
        if line.startswith("/**"):
            in_doc = not line.endswith("*/")
            continue
        if not line or line.startswith("//") or line.startswith("/*") or line.startswith("*"):
            continue
        if skipping:
            skipping += braces(line)
            continue
        if pending is not None:
            pending[3].append(line)
            pending[4] += braces(line)
            if line.endswith(";") and pending[4] == 0:
                finish(pending)
                depth += pending[4]
                pending = None
                while len(stack) > 1 and depth < stack[-1][2]:
                    stack.pop()
            continue
        top = stack[-1]
        declaration_depth = top[2]
        if top[0] == "root":
            # The `declare namespace browser.<ns> {` line itself.
            match = re.match(r"declare namespace browser\.([\w.]+) \{", line)
            if match:
                name = match.group(1)
                if name == "_manifest":
                    skipping = braces(line)
                    continue
                stack.append(("namespace", name, depth + 1))
                entry(name)
        elif depth == declaration_depth and top[0] == "namespace":
            ns = current_namespace()
            e = entry(ns)
            match = re.match(r"function (\w+)\s*[(<]", line)
            if match and match.group(1) not in e["functions"]:
                e["functions"].append(match.group(1))
            match = re.match(r"const (\w+):\s*(.*)$", line)
            if match:
                # A declaration that ends on this line is complete; one that runs on — a multi-line event type, a
                # union ending in `| undefined`, or an object spelled out below — is gathered until its `;`.
                rest = match.group(2)
                if ";" in rest and braces(line) == 0:
                    add_const(e, match.group(1), rest.split(";", 1)[0])
                else:
                    pending = ["const", e, match.group(1), [line], braces(line)]
                    continue
            match = re.match(r"type (\w+) =", line)
            if match:
                pending = ["type", e, match.group(1), [line], braces(line)]
                if line.endswith(";") and pending[4] == 0:
                    finish(pending)
                    depth += pending[4]
                    pending = None
                    while len(stack) > 1 and depth < stack[-1][2]:
                        stack.pop()
                continue
            match = re.match(r"interface (\w+)(?:<[^>]*>)?(?:\s+extends\s+(.+?))?\s*\{", line)
            if match:
                key = (ns + "." if ns else "") + match.group(1)
                stack.append(("interface", key, depth + 1))
                interfaces.setdefault(key, {"functions": [], "events": [],
                                            "properties": {}, "bases": split_bases(match.group(2) or "")})
        elif depth == declaration_depth and top[0] == "interface":
            members = interfaces[top[1]]
            match = re.match(r"(\w+)\??\s*[(<]", line)
            if match:
                if match.group(1) not in members["functions"]:
                    members["functions"].append(match.group(1))
            else:
                match = re.match(r"(\w+)\??: (.+?);", line)
                if match:
                    name, kind = match.group(1), match.group(2).strip()
                    if is_event(kind):
                        members["events"].append(name)
                    else:
                        members["properties"][name] = kind
        # A declaration's own braces are counted on its line, exactly as chrome-api.py does.
        depth += braces(line)
        while len(stack) > 1 and depth < stack[-1][2]:
            stack.pop()
        if depth < 0:
            break
    return namespaces, interfaces


def resolve(interfaces, ns, kind):
    """The interface a member's type names, looked up in its namespace, at the root, or in `types`."""
    kind = re.sub(r"\s*\|\s*undefined$", "", kind.strip()).strip()
    kind = kind.split("<")[0].strip()
    for key in (ns + "." + kind, kind, "types." + kind.split(".")[-1]):
        if key in interfaces:
            return interfaces[key]
    return None


def merged(interfaces, ns, kind, seen=()):
    """An object's own members: what its interface declares plus everything its base interfaces do."""
    found = resolve(interfaces, ns, kind)
    if not found:
        return None
    key = (ns + "." + kind, kind)
    if key in seen:
        return None
    seen = seen + (key,)
    spec = {"functions": [], "events": []}
    for base in found["bases"]:
        inherited = merged(interfaces, ns, base, seen)
        if not inherited:
            continue
        for member in inherited["functions"]:
            if member not in spec["functions"]:
                spec["functions"].append(member)
        spec["events"].extend(inherited["events"])
        if inherited.get("properties"):
            spec.setdefault("properties", {}).update(inherited["properties"])
    for member in found["functions"]:
        if member not in spec["functions"]:
            spec["functions"].append(member)
    spec["events"].extend(found["events"])
    properties = {}
    for name, member_kind in found["properties"].items():
        inner = merged(interfaces, ns, member_kind, seen)
        if inner:
            properties[name] = inner
    if properties:
        spec.setdefault("properties", {}).update(properties)
    for member in [key for key, value in spec.items() if value in ([], {})]:
        del spec[member]
    return spec or None


def document(text):
    namespaces, interfaces = parse(text)
    for ns, e in namespaces.items():
        objects = {}
        for name, kind in e["objects"]:
            spec = merged(interfaces, ns, kind)
            if spec:
                objects[name] = spec
        e["objects"] = objects
        for key in [k for k, value in e.items() if value in ([], {})]:
            del e[key]
    return {ns: e for ns, e in sorted(namespaces.items()) if e}


def render(namespaces):
    return json.dumps(namespaces, indent=1, sort_keys=True) + "\n"


def first_difference(expected, actual, path=""):
    """The first path at which two JSON values differ, nested as firefox-api.json nests it ("storage.objects.local")."""
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(set(expected) | set(actual)):
            child = f"{path}.{key}" if path else key
            if key not in expected or key not in actual:
                return child
            found = first_difference(expected[key], actual[key], child)
            if found:
                return found
        return None
    if isinstance(expected, list) and isinstance(actual, list):
        for index in range(min(len(expected), len(actual))):
            found = first_difference(expected[index], actual[index], f"{path}[{index}]")
            if found:
                return found
        if len(expected) != len(actual):
            return f"{path}[{min(len(expected), len(actual))}]"
        return None
    return None if expected == actual else path


def main():
    args = sys.argv[1:]
    check = "--check" in args
    paths = [arg for arg in args if arg != "--check"]
    if len(paths) > 1:
        sys.exit("usage: scripts/firefox-api.py [--check] [path/to/firefox-webext-browser/index.d.ts]")
    namespaces = document(load_types(paths[0] if paths else None))
    output = render(namespaces)
    if check:
        if not OUT.exists():
            sys.exit(f"firefox-api.json is missing: {OUT}")
        committed = OUT.read_text()
        if committed == output:
            print(f"firefox-api.json matches firefox-webext-browser {FIREFOX_TYPES_VERSION}")
            return
        try:
            actual = json.loads(committed)
        except json.JSONDecodeError as error:
            sys.exit(f"firefox-api.json isn't JSON ({error}); run scripts/firefox-api.py")
        where = first_difference(json.loads(output), actual) or "<root>"
        sys.exit(f"firefox-api.json is out of date at {where}; run scripts/firefox-api.py")
    OUT.write_text(output)
    print(f"{len(namespaces)} namespaces, "
          f"{sum(len(e.get('functions', [])) for e in namespaces.values())} functions, "
          f"{sum(len(e.get('events', [])) for e in namespaces.values())} events -> {OUT}")


if __name__ == "__main__":
    main()
