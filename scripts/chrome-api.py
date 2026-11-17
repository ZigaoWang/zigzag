#!/usr/bin/env python3
"""Writes Zigzag/Resources/Extensions/chrome-api.json: every Chrome extension API, from Chrome's own definitions.

Chrome publishes its extension APIs as TypeScript types built from Chromium's API schemas (the `chrome-types` package
on npm). This reads them and keeps what an extension can reach at run time: per namespace, its functions, events,
constants, enums and objects (`storage.local`, `privacy.network.webRTCIPHandlingPolicy`), and the permissions it
needs. Zigzag fills in from this whatever WebKit doesn't have (Resources/Extensions/api-surface.js), so an extension
never meets an `undefined` where Chrome has something.

    scripts/chrome-api.py [path/to/chrome-types/index.d.ts]
    scripts/chrome-api.py --check [path/to/chrome-types/index.d.ts]

Without a path it downloads the pinned chrome-types package. Change CHROME_TYPES_VERSION to move to a newer one.
--check regenerates in memory and exits non-zero when the committed JSON differs, naming the first path that does.
"""
import io
import json
import re
import sys
import tarfile
import urllib.error
import urllib.request
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Zigzag/Resources/Extensions/chrome-api.json"
CHROME_TYPES_VERSION = "0.1.464"


def load_types(path=None):
    if path is not None:
        return Path(path).read_text()
    url = f"https://registry.npmjs.org/chrome-types/-/chrome-types-{CHROME_TYPES_VERSION}.tgz"
    try:
        data = urllib.request.urlopen(url, timeout=60).read()
    except (urllib.error.URLError, OSError) as error:
        sys.exit(f"chrome-types {CHROME_TYPES_VERSION}: can't download {url}: {error}. "
                 f"Pass a local index.d.ts path to generate offline.")
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        member = tar.extractfile("package/index.d.ts")
        if member is None:
            sys.exit(f"chrome-types {CHROME_TYPES_VERSION}: the package has no index.d.ts")
        return member.read().decode()


def enum_key(value):
    """Chrome's runtime name for an enum value: "bookmarks-bar" is BOOKMARKS_BAR, "modifyHeaders" MODIFY_HEADERS."""
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", value)
    return re.sub(r"[^A-Za-z0-9]+", "_", spaced).strip("_").upper()


def literal(text):
    """A constant's value as JSON holds it: a number, a string or a boolean."""
    text = text.rstrip(",").strip()
    if text.startswith('"') and text.endswith('"'):
        return text[1:-1]
    if text in ("true", "false"):
        return text == "true"
    return float(text) if "." in text else int(text)


def parse(text):
    start = text.index("declare namespace browser {")
    lines = text[start:].split("\n")[1:]
    namespaces = {}   # "system.display" -> entry
    interfaces = {}   # "types.ChromeSetting" -> {"functions": [...], "events": [...]}
    stack = [("namespace", "browser", 1)]  # (kind, name, depth at which its body lives)
    depth = 1
    doc = []
    in_doc = False

    def current_namespace():
        names = [name for kind, name, _ in stack if kind == "namespace"]
        return ".".join(n.lstrip("_") for n in names[1:])  # [0] is "browser"

    def entry(name):
        return namespaces.setdefault(name, {"permissions": [], "functions": [], "events": [], "constants": {},
                                            "enums": {}, "objects": {}, "flags": []})

    for raw in lines:
        line = raw.strip()
        if in_doc:
            doc.append(line)
            in_doc = not line.endswith("*/")
            continue
        if line.startswith("/**"):
            doc = [line]
            in_doc = not line.endswith("*/")
            continue
        if not line or line.startswith("//"):
            continue
        top = stack[-1]
        # Only a declaration's first line matters; types that run over more lines are skipped, braces still counted.
        if depth == top[2] and top[0] == "namespace":
            ns = current_namespace()
            text_doc = "\n".join(doc)
            m = re.match(r"export namespace ([\w.]+) \{", line)
            if m:
                stack.append(("namespace", m.group(1), depth + 1))
                e = entry(current_namespace())
                e["permissions"] = re.findall(r"@chrome-permission (\S+)", text_doc)
                for flag in ("chrome-channel", "chrome-platform", "chrome-install-location", "chrome-disallow-service-workers"):
                    found = re.findall(r"@%s ?(\S*)" % flag, text_doc)
                    if found:
                        e["flags"].append(flag + "=" + " ".join(found))
            elif re.match(r"export (?:interface|class) (\w+)", line) and line.endswith("{"):
                name = re.match(r"export (?:interface|class) (\w+)", line).group(1)
                stack.append(("interface", (ns + "." if ns else "") + name, depth + 1))
                interfaces.setdefault(stack[-1][1], {"functions": [], "events": []})
            elif ns:
                e = entry(ns)
                m = re.match(r"export function (\w+)\s*[(<]", line)
                if m and m.group(1) not in e["functions"]:
                    e["functions"].append(m.group(1))
                m = re.match(r"export const (\w+): \{$", line)
                if m:
                    # An object spelled out in place (privacy.network): its members are typed one per line.
                    stack.append(("inline", ns + "|" + m.group(1), depth + 1))
                    e["objects"][m.group(1)] = {"properties": {}}
                m = re.match(r"export const (\w+): ([\w.]+) & \{$", line)
                if m:
                    # An interface with extra members of its own (storage.local): both are the object.
                    stack.append(("inline", ns + "|" + m.group(1), depth + 1))
                    e["objects"][m.group(1)] = {"base": m.group(2), "properties": {}}
                m = re.match(r"export const (\w+): (.*)$", line)
                if m and not line.endswith("{"):
                    name, kind = m.group(1), m.group(2).rstrip(";").strip()
                    if "Event<" in kind:
                        e["events"].append(name)
                    elif re.fullmatch(r"-?\d+(\.\d+)?|true|false", kind):
                        e["constants"][name] = literal(kind)
                    elif re.fullmatch(r'"[^"]*"', kind):
                        e["constants"][name] = kind[1:-1]
                    elif re.match(r"[\w.]+", kind):
                        e["objects"][name] = re.match(r"[\w.]+", kind).group(0)
                m = re.match(r"export type (\w+) =", line)
                if m:
                    values = [v.replace("\\", "") for v in re.findall(r'@chrome-enum "([^"]*)"', text_doc)]
                    if values:
                        e["enums"][m.group(1)] = {enum_key(v): v for v in values}
        elif depth == top[2] and top[0] == "inline":
            ns, name = top[1].split("|")
            members = entry(ns)["objects"][name]
            text_doc = "\n".join(doc)
            m = re.match(r"export type (\w+) =", line)
            if m:
                # An enum written inside the object, rather than beside it in the namespace.
                values = [v.replace("\\", "") for v in re.findall(r'@chrome-enum "([^"]*)"', text_doc)]
                if values:
                    members.setdefault("enums", {})[m.group(1)] = {enum_key(v): v for v in values}
            else:
                m = re.match(r"(\w+)\??: (-?\d+(?:\.\d+)?|true|false|\"[^\"]*\")\s*,?$", line)
                if m:
                    # A constant of the object's own (storage.sync.QUOTA_BYTES), not a ChromeSetting to resolve.
                    members.setdefault("constants", {})[m.group(1)] = literal(m.group(2))
                else:
                    m = re.match(r"(\w+)\??: ([\w.]+)", line)
                    if m:
                        members.setdefault("properties", {})[m.group(1)] = m.group(2)
        elif depth == top[2] and top[0] == "interface":
            members = interfaces[top[1]]
            m = re.match(r"(\w+)\??: (.*)$", line)
            if m and "Event<" in m.group(2):
                members["events"].append(m.group(1))
            else:
                m = re.match(r"(\w+)\??\s*[(<]", line)
                if m and m.group(1) not in members["functions"]:
                    members["functions"].append(m.group(1))
        doc = []
        # Braces in string literals ("{...}") don't nest anything.
        code = re.sub(r'"[^"]*"', '""', line)
        depth += code.count("{") - code.count("}")
        while len(stack) > 1 and depth < stack[-1][2]:
            stack.pop()
        if depth < 1:
            break
    return namespaces, interfaces


def render(namespaces):
    return json.dumps(namespaces, indent=1, sort_keys=True) + "\n"


def first_difference(expected, actual, path=""):
    """The first path at which two JSON values differ, nested as chrome-api.json nests it ("storage.objects.local")."""
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
        sys.exit("usage: scripts/chrome-api.py [--check] [path/to/chrome-types/index.d.ts]")
    namespaces, interfaces = parse(load_types(paths[0] if paths else None))
    # An object's methods, events, constants and enums, from its interface, in its namespace or in `types`.
    for ns, e in namespaces.items():
        def resolve(type_name):
            for key in (ns + "." + type_name, type_name, "types." + type_name.split(".")[-1]):
                if key in interfaces:
                    return interfaces[key]
            return None
        resolved = {}
        for name, kind in e["objects"].items():
            if isinstance(kind, str):
                if resolve(kind):
                    resolved[name] = resolve(kind)
                continue
            # An object spelled out in place, alone (privacy.network) or over an interface (storage.local).
            merged = {}
            base = resolve(kind["base"]) if "base" in kind else None
            for key, value in (base or {}).items():
                merged[key] = list(value) if isinstance(value, list) else dict(value)
            for key in ("functions", "events"):
                for member in kind.get(key, []):
                    merged.setdefault(key, []).append(member)
            for key in ("constants", "enums"):
                if kind.get(key):
                    merged.setdefault(key, {}).update(kind[key])
            properties = {p: resolve(t) for p, t in kind.get("properties", {}).items()}
            properties = {p: v for p, v in properties.items() if v}
            if properties:
                merged["properties"] = properties
            if merged:
                resolved[name] = merged
        e["objects"] = resolved
    for e in namespaces.values():
        for key in [k for k, v in e.items() if v in ([], {})]:
            del e[key]
    namespaces = {k: v for k, v in sorted(namespaces.items()) if k and len(v) > 0}
    output = render(namespaces)
    if check:
        if not OUT.exists():
            sys.exit(f"chrome-api.json is missing: {OUT}")
        committed = OUT.read_text()
        if committed == output:
            print(f"chrome-api.json matches chrome-types {CHROME_TYPES_VERSION}")
            return
        try:
            actual = json.loads(committed)
        except json.JSONDecodeError as error:
            sys.exit(f"chrome-api.json isn't JSON ({error}); run scripts/chrome-api.py")
        where = first_difference(json.loads(output), actual) or "<root>"
        sys.exit(f"chrome-api.json is out of date at {where}; run scripts/chrome-api.py")
    OUT.write_text(output)
    print(f"{len(namespaces)} namespaces, "
          f"{sum(len(e.get('functions', [])) for e in namespaces.values())} functions, "
          f"{sum(len(e.get('events', [])) for e in namespaces.values())} events -> {OUT}")


if __name__ == "__main__":
    main()
