#!/usr/bin/env python3
# Fetches the built Chrome DevTools frontend that Settings › Developer › Chrome DevTools shows (ChromeDevTools.swift)
# into DevToolsFrontend/, by following the references from its entry pages. Usage, with a Chromium commit from
# https://chromiumdash.appspot.com/releases (a stable Chrome's):
#   rm -rf DevToolsFrontend && python3 scripts/update-devtools-frontend.py <commit> DevToolsFrontend \
#     devtools_app.html devtools_compatibility.js core/i18n/locales/en-US.json
# then put the LICENSE back from https://github.com/ChromeDevTools/devtools-frontend and write the commit to REVISION.
import sys, re, os, urllib.request, urllib.parse, concurrent.futures, threading
rev, out = sys.argv[1], sys.argv[2]
base = f"https://chrome-devtools-frontend.appspot.com/serve_rev/@{rev}/"
seen, lock = set(), threading.Lock()
missing = []
ref = re.compile(r'''["'`]((?:\.{1,2}/|/)?[A-Za-z0-9_@./-]+\.(?:js|mjs|css|json|svg|png|avif|webp|woff2|html|wasm|map))["'`]''')
cssurl = re.compile(r'url\(\s*["\']?([^"\')]+)["\']?\s*\)')
def norm(path, frm):
    if path.startswith(("http:", "https:", "data:", "//")): return None
    if path.startswith("/"): path = path[1:]
    elif path.startswith("."): path = os.path.normpath(os.path.join(os.path.dirname(frm), path))
    path = path.split("?")[0].split("#")[0]
    if path.startswith("..") or not path: return None
    return path
def fetch(path):
    try:
        with urllib.request.urlopen(base + path, timeout=30) as r:
            return r.read()
    except Exception:
        return None
def visit(path):
    data = fetch(path)
    if data is None:
        missing.append(path); return []
    dst = os.path.join(out, path); os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, "wb").write(data)
    if not path.endswith((".js", ".mjs", ".css", ".html", ".json")): return []
    text = data.decode("utf-8", "ignore")
    found = set()
    for m in ref.findall(text) + (cssurl.findall(text) if path.endswith(".css") or path.endswith(".js") else []):
        for cand in {norm(m, path), norm("./" + m if not m.startswith((".", "/")) else m, path)}:
            if cand: found.add(cand)
    return found
todo = set(sys.argv[3:])
with concurrent.futures.ThreadPoolExecutor(24) as ex:
    while todo:
        batch = [p for p in todo if p not in seen]; seen.update(batch); todo = set()
        for res in ex.map(visit, batch):
            for p in res:
                if p not in seen: todo.add(p)
        print(len(seen), "seen", len(missing), "missing", flush=True)
print("done; missing sample:", missing[:15])
