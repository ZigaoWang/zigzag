#!/usr/bin/env python3
"""Writes Zigzag/Resources/Extensions/chrome-api.json: every Chrome extension API, from Chrome's own definitions.

Chrome publishes its extension APIs as TypeScript types built from Chromium's API schemas (the `chrome-types` package
on npm). This reads them and keeps what an extension can reach at run time: per namespace, its functions, events,
constants, enums and objects (`storage.local`, `privacy.network.webRTCIPHandlingPolicy`), and the permissions it
needs. Zigzag fills in from this whatever WebKit doesn't have (Resources/Extensions/api-surface.js), so an extension
never meets an `undefined` where Chrome has something.

    scripts/chrome-api.py [path/to/chrome-types/index.d.ts]

Without a path it downloads the latest package. Run it again when Chrome adds APIs.
"""
import io
import json
import re
import sys
import tarfile
import urllib.request
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Zigzag/Resources/Extensions/chrome-api.json"


def load_types(argv):
    if len(argv) > 1:
        return Path(argv[1]).read_text()
    meta = json.load(urllib.request.urlopen("https://registry.npmjs.org/chrome-types/latest"))
    data = urllib.request.urlopen(meta["dist"]["tarball"]).read()
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        return tar.extractfile("package/index.d.ts").read().decode()


def enum_key(value):
    """Chrome's runtime name for an enum value: "bookmarks-bar" is BOOKMARKS_BAR, "modifyHeaders" MODIFY_HEADERS."""
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", value)
    return re.sub(r"[^A-Za-z0-9]+", "_", spaced).strip("_").upper()


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
                m = re.match(r"export const (\w+): (.*)$", line)
                if m and not line.endswith("{"):
                    name, kind = m.group(1), m.group(2).rstrip(";").strip()
                    if "Event<" in kind:
                        e["events"].append(name)
                    elif re.fullmatch(r"-?\d+(\.\d+)?", kind):
                        e["constants"][name] = float(kind) if "." in kind else int(kind)
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
            m = re.match(r"(\w+)\??: ([\w.]+)", line)
            if m:
                entry(ns)["objects"][name]["properties"][m.group(1)] = m.group(2)
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


def main():
    namespaces, interfaces = parse(load_types(sys.argv))
    # An object's methods and events, from its interface, in its namespace or in `types`.
    for ns, e in namespaces.items():
        def resolve(type_name):
            for key in (ns + "." + type_name, type_name, "types." + type_name.split(".")[-1]):
                if key in interfaces:
                    return interfaces[key]
            return None
        resolved = {}
        for name, kind in e["objects"].items():
            if isinstance(kind, dict):
                props = {p: resolve(t) for p, t in kind["properties"].items()}
                props = {p: v for p, v in props.items() if v}
                if props:
                    resolved[name] = {"properties": props}
            elif resolve(kind):
                resolved[name] = resolve(kind)
        e["objects"] = resolved
    for e in namespaces.values():
        for key in [k for k, v in e.items() if v in ([], {})]:
            del e[key]
    namespaces = {k: v for k, v in sorted(namespaces.items()) if k and len(v) > 0}
    OUT.write_text(json.dumps(namespaces, indent=1, sort_keys=True) + "\n")
    print(f"{len(namespaces)} namespaces, "
          f"{sum(len(e.get('functions', [])) for e in namespaces.values())} functions, "
          f"{sum(len(e.get('events', [])) for e in namespaces.values())} events -> {OUT}")


if __name__ == "__main__":
    main()
