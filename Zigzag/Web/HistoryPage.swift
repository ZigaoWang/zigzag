import AppKit
import WebKit

/// History as a page in a tab, as in Chrome: zigzag://history. Served by Zigzag itself (never the network), in the
/// space's own accent, light or dark with the window. The page asks for its rows through a message only it can send.
@MainActor
enum HistoryPage {
    static let url = URL(string: "zigzag://history")!
    static let scheme = "zigzag"

    static func isHistory(_ url: URL?) -> Bool { isInternal(url) && url?.host() == "history" }
    /// One of Zigzag's own pages (History, Settings): never a visit, never fetched from the network.
    static func isInternal(_ url: URL?) -> Bool { url?.scheme == scheme }

    /// Lets a page configuration show History. A configuration WebKit hands over for a popup already has it.
    static func attach(to configuration: WKWebViewConfiguration) {
        guard configuration.urlSchemeHandler(forURLScheme: scheme) == nil else { return }
        configuration.setURLSchemeHandler(SchemeHandler.shared, forURLScheme: scheme)
        configuration.userContentController.addScriptMessageHandler(Bridge.shared, contentWorld: .page, name: "zigzagHistory")
    }

    /// ⌘Y: the History tab you already have in this space, or a new one.
    static func open(in controller: BrowserWindowController) {
        if let existing = controller.tabManager.currentTabs.first(where: { isHistory($0.url) }) {
            controller.tabManager.select(existing)
            existing.reload()
        } else {
            controller.open(url, disposition: .foregroundTab)
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Serving

    final class SchemeHandler: NSObject, WKURLSchemeHandler {
        static let shared = SchemeHandler()

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let data: Data
            let type: String
            if url.host() == "icon", let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value.flatMap(URL.init(string:)),
               let png = FaviconStore.shared.cachedIcon(for: target).flatMap(HistoryPage.png) {
                data = png
                type = "image/png"
            } else if url.host() == "history" {
                data = Data(HistoryPage.html(for: webView).utf8)
                type = "text/html"
            } else if url.host() == SettingsPage.host {
                data = Data(SettingsPage.html.utf8)
                type = "text/html"
            } else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: The page's questions

    final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Bridge()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            // Only History itself may ask: never a website's page or frame.
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == HistoryPage.scheme,
                  let body = message.body as? [String: Any], let action = body["action"] as? String else {
                replyHandler(nil, "Not allowed")
                return
            }
            switch action {
            case "page":
                let before = (body["before"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                replyHandler(HistoryPage.sessions(HistoryPage.batch(before: before)), nil)
            case "search":
                let query = (body["query"] as? String) ?? ""
                replyHandler(HistoryPage.sessions(HistoryStore.shared.search(query, limit: 300)), nil)
            case "delete":
                // One page, or every page in a cluster.
                let strings = (body["urls"] as? [String]) ?? [body["url"] as? String].compactMap { $0 }
                for url in strings.compactMap(URL.init(string:)) { HistoryStore.shared.delete(url) }
                replyHandler(true, nil)
            case "clear":
                HistoryPage.confirmClear(body["range"] as? String ?? "all", from: message.webView, reply: replyHandler)
            default:
                replyHandler(nil, "Unknown")
            }
        }
    }

    /// The next stretch of history before `before`, ending where a session ends: a batch that stopped halfway
    /// through an afternoon would show it as two sessions, and removing one would leave the other.
    private static func batch(before: Date?, limit: Int = 200) -> [HistoryEntry] {
        var entries = HistoryStore.shared.page(before: before, limit: limit)
        guard entries.count == limit else { return entries }
        while let last = entries.last {
            let more = HistoryStore.shared.page(before: last.lastVisit, limit: 50)
            var joining = 0
            while joining < more.count, HistoryClusters.continues(joining == 0 ? last : more[joining - 1], with: more[joining]) { joining += 1 }
            entries += more.prefix(joining)
            if joining < more.count || more.count < 50 { break }
        }
        return entries
    }

    /// Sessions of clusters, as the page draws them.
    private static func sessions(_ entries: [HistoryEntry]) -> [[String: Any]] {
        HistoryClusters.group(entries).map { session in
            [
                "title": HistoryClusters.title(startingAt: session.start),
                "clusters": session.clusters.map { cluster in
                    ["host": cluster.host, "items": cluster.entries.map(row)] as [String: Any]
                },
            ]
        }
    }

    private static func row(_ entry: HistoryEntry) -> [String: Any] {
        [
            "url": entry.url.absoluteString,
            "title": entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title,
            "time": entry.lastVisit.timeIntervalSince1970 * 1000,
        ]
    }

    private static func confirmClear(_ range: String, from webView: WKWebView?, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let host = webView?.window?.contentView else { reply(false, nil); return }
        let calendar = Calendar.current, now = Date()
        let (title, since): (String, Date?) = switch range {
        case "hour": ("the last hour", now.addingTimeInterval(-3600))
        case "today": ("today", calendar.startOfDay(for: now))
        case "yesterday": ("today and yesterday", calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        default: ("all history", nil)
        }
        let what = since == nil ? "all of your history" : "your history from \(title)"
        ConfirmSheet.show(in: host, title: "Clear \(title)?", message: "This removes \(what) from Zigzag. Pinned tabs and open tabs stay.",
                          confirmTitle: "Clear", destructive: true) { confirmed in
            if confirmed {
                if let since { HistoryStore.shared.clear(since: since) } else { HistoryStore.shared.clearAll() }
            }
            reply(confirmed, nil)
        }
    }

    // MARK: The page

    /// The space's accent, as the page's CSS color, for light and dark.
    private static func accents(for webView: WKWebView) -> (light: String, dark: String) {
        let controller = WindowManager.shared.controllers.first { $0.window === webView.window } ?? WindowManager.shared.keyController
        let theme = controller.map { Brand.Theme.of($0.tabManager.currentSpace) } ?? .brand
        func css(_ color: NSColor, _ name: NSAppearance.Name) -> String {
            var out = "#3366cc"
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                if let c = color.usingColorSpace(.sRGB) {
                    out = String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
                }
            }
            return out
        }
        return (css(theme.accent, .aqua), css(theme.accent, .darkAqua))
    }

    static func html(for webView: WKWebView) -> String {
        let accent = accents(for: webView)
        return template
            .replacingOccurrences(of: "%ACCENT_LIGHT%", with: accent.light)
            .replacingOccurrences(of: "%ACCENT_DARK%", with: accent.dark)
            .replacingOccurrences(of: "%MARK%", with: mark)
    }

    private static let mark = #"""
<svg class="mark" viewBox="0 0 372 73" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="13" stroke-linecap="round" stroke-linejoin="round"><path d="M6.50,6.50 L56.50,6.50 L11.12,36.50 L51.88,36.50 L6.50,66.50 L56.50,66.50"/><path d="M77.50,66.50 L77.50,6.50"/><path d="M145.62,13.38 L142.35,11.03 L138.79,9.13 L135.00,7.73 L131.07,6.85 L127.05,6.50 L123.02,6.70 L119.05,7.44 L115.22,8.70 L111.59,10.47 L108.23,12.70 L105.20,15.37 L102.56,18.42 L100.35,21.79 L98.61,25.44 L97.38,29.28 L96.68,33.25 L96.51,37.28 L96.89,41.30 L97.80,45.23 L99.23,49.00 L101.15,52.55 L103.54,55.80 L106.33,58.71 L109.50,61.22 L112.97,63.27 L116.68,64.85 L120.57,65.91 L124.57,66.44 L128.61,66.43 L132.60,65.87 L136.49,64.79 L140.20,63.19 L143.65,61.11 L146.80,58.59 L149.58,55.66 L151.94,52.39 L153.85,48.84 L155.25,45.05 L156.14,41.12 L156.49,37.10 L156.50,36.50 L135.50,36.50"/><path d="M170.50,6.50 L220.50,6.50 L175.12,36.50 L215.88,36.50 L170.50,66.50 L220.50,66.50"/><path d="M237.50,66.50 L263.50,6.50 L289.50,66.50"/><path d="M249.50,46.50 L277.50,46.50"/><path d="M352.62,13.38 L349.35,11.03 L345.79,9.13 L342.00,7.73 L338.07,6.85 L334.05,6.50 L330.02,6.70 L326.05,7.44 L322.22,8.70 L318.59,10.47 L315.23,12.70 L312.20,15.37 L309.56,18.42 L307.35,21.79 L305.61,25.44 L304.38,29.28 L303.68,33.25 L303.51,37.28 L303.89,41.30 L304.80,45.23 L306.23,49.00 L308.15,52.55 L310.54,55.80 L313.33,58.71 L316.50,61.22 L319.97,63.27 L323.68,64.85 L327.57,65.91 L331.57,66.44 L335.61,66.43 L339.60,65.87 L343.49,64.79 L347.20,63.19 L350.65,61.11 L353.80,58.59 L356.58,55.66 L358.94,52.39 L360.85,48.84 L362.25,45.05 L363.14,41.12 L363.49,37.10 L363.50,36.50 L342.50,36.50"/></g></svg>
"""#

    private static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>History</title>
<style>
:root {
  color-scheme: light dark;
  --accent: %ACCENT_LIGHT%;
  --bg: #ffffff; --text: rgba(0,0,0,.86); --muted: rgba(0,0,0,.54); --faint: rgba(0,0,0,.36);
  --hover: rgba(0,0,0,.045); --field: rgba(0,0,0,.05); --line: rgba(0,0,0,.08);
  --gutter: 28px;
}
@media (prefers-color-scheme: dark) {
  :root { --accent: %ACCENT_DARK%; --bg: #1e1e20; --text: rgba(255,255,255,.92); --muted: rgba(255,255,255,.56);
          --faint: rgba(255,255,255,.36); --hover: rgba(255,255,255,.06); --field: rgba(255,255,255,.07); --line: rgba(255,255,255,.08); }
}
/* A split pane or a small window: tighter edges, and the address column steps aside for the title. */
@media (max-width: 640px) { :root { --gutter: 16px; } }
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text); font: 13px/1.4 -apple-system, BlinkMacSystemFont, sans-serif;
             -webkit-font-smoothing: antialiased; -webkit-user-select: none; cursor: default; }
::selection { background: color-mix(in srgb, var(--accent) 30%, transparent); }
button { appearance: none; border: 0; background: none; color: inherit; font: inherit; padding: 0; cursor: default; }
:focus-visible { outline: 2px solid color-mix(in srgb, var(--accent) 70%, transparent); outline-offset: -2px; }

/* The toolbar stays put while the sessions scroll under it, like a window's own. */
header { position: sticky; top: 0; z-index: 4; background: var(--bg); display: flex; flex-wrap: wrap; align-items: center;
         gap: 8px 12px; padding: 16px var(--gutter) 12px; box-shadow: 0 1px 0 transparent; transition: box-shadow .15s; }
header.scrolled { box-shadow: 0 1px 0 var(--line); }
h1 { font-size: 15px; font-weight: 600; margin: 0 auto 0 0; }
.search { display: flex; align-items: center; gap: 6px; background: var(--field); border-radius: 8px; padding: 0 8px; height: 28px;
          width: clamp(220px, 36vw, 420px); }
.search svg { flex: none; opacity: .45; }
.search input { flex: 1; min-width: 0; border: 0; outline: 0; background: none; color: var(--text); font: inherit; caret-color: var(--accent);
                -webkit-user-select: text; }
.search input::-webkit-search-cancel-button { display: none; }
@media (max-width: 520px) { .search { order: 3; width: 100%; } }
.clear { position: relative; }
.clear > button { color: var(--muted); padding: 4px 8px; border-radius: 6px; }
.clear > button:hover { background: var(--hover); color: var(--text); }
.menu { position: absolute; right: 0; top: calc(100% + 4px); background: var(--bg); border-radius: 8px; padding: 4px; min-width: 200px;
        box-shadow: 0 0 0 .5px var(--line), 0 8px 24px rgba(0,0,0,.16); display: none; z-index: 5; }
.menu.open { display: block; }
.menu button { display: block; width: 100%; text-align: left; padding: 4px 9px; border-radius: 5px; }
.menu button:hover { background: var(--accent); color: #fff; }

#list { padding: 4px calc(var(--gutter) - 8px) 48px; }
/* A session: one sitting, from the first page to a break. Its heading stays in view while its pages scroll. */
.session { margin-bottom: 16px; }
.session + .session { border-top: 1px solid var(--line); padding-top: 8px; }
.session-head { position: sticky; top: var(--header, 56px); z-index: 2; background: var(--bg); display: flex; align-items: baseline;
                gap: 8px; padding: 8px 8px 6px; }
.session-head h2 { font-size: 13px; font-weight: 600; margin: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.session-head .range { color: var(--muted); white-space: nowrap; }
.session-head .count { margin-left: auto; color: var(--faint); font-size: 11px; white-space: nowrap; }
.session-head .remove { flex: none; align-self: center; width: 20px; height: 20px; border-radius: 4px; color: var(--muted); font-size: 13px; line-height: 20px; }
.session-head:not(:hover):not(:focus-within) .remove { opacity: 0; }
.session-head .remove:hover { background: var(--field); color: var(--text); }
@media (max-width: 520px) { .session-head .count { display: none; } .session-head .remove { margin-left: auto; } }

/* One grid for every row, so titles, addresses and times line up down the whole page at any width:
   disclosure, icon, title, address, time, remove. */
.row { display: grid; grid-template-columns: 12px 16px minmax(0, 1fr) minmax(0, 34%) 120px 20px; align-items: center; column-gap: 10px;
       min-height: 30px; padding: 0 8px; border-radius: 6px; color: inherit; text-decoration: none; width: 100%; text-align: left; }
.row:hover { background: var(--hover); }
.row img, .row .dot { grid-column: 2; width: 16px; height: 16px; border-radius: 3px; }
.row .dot { background: var(--field); }
/* Dark: icons drawn in black (GitHub, Wikipedia) sit on a light tile, as in the sidebar. */
@media (prefers-color-scheme: dark) { .row img { background: #fff; padding: 1px; border-radius: 4px; } }
.row .title { grid-column: 3; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.row .where { grid-column: 4; color: var(--faint); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.row time { grid-column: 5; color: var(--faint); font-size: 11px; font-variant-numeric: tabular-nums; text-align: right; white-space: nowrap; }
.row .remove { grid-column: 6; width: 20px; height: 20px; border-radius: 4px; color: var(--muted); font-size: 13px; line-height: 20px; text-align: center; }
/* Out of sight until the pointer or keyboard focus reaches the row, but still in the Tab order. */
.row:not(:hover):not(:focus-within) .remove { opacity: 0; }
.row .remove:hover { background: var(--field); color: var(--text); }
@media (max-width: 640px) {
  .row { grid-template-columns: 12px 16px minmax(0, 1fr) auto 20px; }
  .row .where { display: none; }
  .row time { grid-column: 4; }
  .row .remove { grid-column: 5; }
}

/* A cluster: one site, several pages in a row. Its pages sit under it, indented past the icon. */
.cluster > .head .title { font-weight: 500; }
.cluster > .head .chevron { grid-column: 1; width: 12px; height: 12px; color: var(--muted); transition: transform .15s; }
.cluster.open > .head .chevron { transform: rotate(90deg); }
/* Indented by a wider first column rather than padding, so the address and time columns still line up with the rows above. */
.pages .row { grid-template-columns: 38px 16px minmax(0, 1fr) minmax(0, 34%) 120px 20px; }
.pages .more { display: block; color: var(--accent); padding: 6px 8px 6px 82px; font-size: 12px; }
.pages .more:hover { text-decoration: underline; }
@media (max-width: 640px) { .pages .row { grid-template-columns: 38px 16px minmax(0, 1fr) auto 20px; } }
@media (prefers-reduced-motion: reduce) { .chevron, header { transition: none; } }

.empty { text-align: center; padding: 96px 0; color: var(--muted); }
.empty svg { width: 120px; height: auto; color: var(--text); opacity: .08; display: block; margin: 0 auto 16px; }
.empty svg path { stroke: currentColor; }
#more { height: 1px; }
</style>
</head>
<body>
<header id="bar">
  <h1>History</h1>
  <label class="search">
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="7" cy="7" r="5"/><path d="M11 11l3.5 3.5"/></svg>
    <input id="query" type="search" placeholder="Search history" autocomplete="off" autofocus>
  </label>
  <div class="clear">
    <button id="clearButton" aria-haspopup="menu">Clear History…</button>
    <div class="menu" id="clearMenu" role="menu">
      <button data-range="hour">The Last Hour</button>
      <button data-range="today">Today</button>
      <button data-range="yesterday">Today and Yesterday</button>
      <button data-range="all">All History</button>
    </div>
  </div>
</header>
<main>
  <div id="list"></div>
  <div class="empty" id="empty" hidden>%MARK%<div id="emptyText"></div></div>
  <div id="more"></div>
</main>
<script>
const ask = (body) => window.webkit.messageHandlers.zigzagHistory.postMessage(body);
const list = document.getElementById('list');
const empty = document.getElementById('empty');
const query = document.getElementById('query');
const bar = document.getElementById('bar');
// Sessions, newest first, each holding clusters of pages on one site: { title, clusters: [{ host, items, open }] }.
let sessions = [], done = false, loading = false, searching = '';
const batch = 100;

const timeOf = (ms) => new Date(ms).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
// "2:10 to 4:45 PM", or "11:40 AM to 1:05 PM" across noon; items are newest first.
const span = (items) => {
  const newest = timeOf(items[0].time), oldest = timeOf(items[items.length - 1].time);
  if (newest === oldest) return newest;
  const suffix = / [AP]M$/;
  const from = oldest.match(suffix)?.[0] === newest.match(suffix)?.[0] ? oldest.replace(suffix, '') : oldest;
  return from + ' to ' + newest;
};
// The address without its scheme, as the address bar shows it.
const where = (url) => url.replace(/^https?:\/\/(www\.)?/, '').replace(/\/$/, '');
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const icon = (url) => {
  const img = new Image(); img.alt = ''; img.src = 'zigzag://icon/?u=' + encodeURIComponent(url);
  img.onerror = () => img.replaceWith(el('span', 'dot'));
  return img;
};
const removeButton = (label, action) => {
  const b = el('button', 'remove', '×'); b.title = label; b.setAttribute('aria-label', label);
  b.onclick = (e) => { e.preventDefault(); e.stopPropagation(); action(); };
  return b;
};

function page(item, session) {
  const a = el('a', 'row'); a.href = item.url; a.title = item.url;
  a.append(icon(item.url), el('span', 'title', item.title), el('span', 'where', where(item.url)), el('time', null, timeOf(item.time)),
           removeButton('Remove from History', () => forget([item.url], session)));
  return a;
}

function clusterElement(cluster, session) {
  const box = el('div', 'cluster' + (cluster.open ? ' open' : ''));
  const head = el('button', 'row head');
  head.setAttribute('aria-expanded', cluster.open);
  const chevron = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  chevron.setAttribute('class', 'chevron'); chevron.setAttribute('viewBox', '0 0 12 12');
  chevron.innerHTML = '<path d="M4.5 2.5L8 6l-3.5 3.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>';
  const count = cluster.items.length;
  head.append(chevron, icon(cluster.items[0].url), el('span', 'title', cluster.host), el('span', 'where', count + ' pages'),
              el('time', null, span(cluster.items)),
              removeButton('Remove ' + count + ' Pages from History', () => forget(cluster.items.map((i) => i.url), session)));
  head.onclick = () => { cluster.open = !cluster.open; box.replaceWith(clusterElement(cluster, session)); };
  box.append(head);
  if (cluster.open) {
    // A long afternoon on one site can be hundreds of pages: draw them a hundred at a time.
    const pages = el('div', 'pages');
    const shown = cluster.shown || batch;
    cluster.items.slice(0, shown).forEach((i) => pages.append(page(i, session)));
    if (count > shown) {
      const more = el('button', 'more', 'Show ' + Math.min(batch, count - shown) + ' More');
      more.onclick = () => { cluster.shown = shown + batch; box.replaceWith(clusterElement(cluster, session)); };
      pages.append(more);
    }
    box.append(pages);
  }
  return box;
}

function sessionElement(session) {
  const section = el('section', 'session');
  const items = session.clusters.flatMap((c) => c.items);
  const head = el('div', 'session-head');
  head.append(el('h2', null, session.title), el('span', 'range', span(items)),
              el('span', 'count', items.length === 1 ? '1 page' : items.length + ' pages'),
              removeButton('Remove Session from History', () => forget(items.map((i) => i.url), session)));
  section.append(head);
  for (const c of session.clusters) section.append(c.items.length > 1 ? clusterElement(c, session) : page(c.items[0], session));
  return section;
}

// Draws one session again in place: only the one that changed, so a long history never redraws as a whole.
function redraw(session) {
  const fresh = session.clusters.length ? sessionElement(session) : null;
  if (session.el && fresh) session.el.replaceWith(fresh); else if (session.el) session.el.remove(); else if (fresh) list.append(fresh);
  session.el = fresh;
}

function render() {
  list.textContent = '';
  for (const s of sessions) { s.el = null; redraw(s); }
  showEmpty();
}

function showEmpty() {
  empty.hidden = sessions.length > 0 || (!done && !searching);
  document.getElementById('emptyText').textContent = searching ? 'Nothing in your history matches “' + searching + '”.' : 'Pages you visit show up here.';
}

// Removes pages from History, then from the session they were drawn in.
async function forget(urls, session) {
  await ask({ action: 'delete', urls });
  const gone = new Set(urls);
  for (const c of session.clusters) c.items = c.items.filter((i) => !gone.has(i.url));
  session.clusters = session.clusters.filter((c) => c.items.length);
  redraw(session);
  if (!session.clusters.length) sessions = sessions.filter((s) => s !== session);
  showEmpty();
}

async function loadMore() {
  if (done || loading || searching) return;
  loading = true;
  const last = sessions[sessions.length - 1];
  const before = last ? last.clusters[last.clusters.length - 1].items.slice(-1)[0].time : null;
  const more = await ask({ action: 'page', before });
  loading = false;
  if (searching) return;
  if (!more.length) { done = true; showEmpty(); return; }
  // Batches end where a session ends, so each one only adds.
  for (const s of more) { sessions.push(s); redraw(s); }
  showEmpty();
  // Collapsed clusters take little room, so one batch may not fill a tall window: keep going until it does.
  requestAnimationFrame(() => { if (document.getElementById('more').getBoundingClientRect().top < innerHeight + 600) loadMore(); });
}

async function reload() { sessions = []; done = false; list.textContent = ''; await loadMore(); }

let timer;
query.addEventListener('input', () => {
  clearTimeout(timer);
  timer = setTimeout(async () => {
    searching = query.value.trim();
    if (searching) {
      const found = await ask({ action: 'search', query: searching });
      if (query.value.trim() !== searching) return;
      // Clusters that hold a match open by themselves.
      found.forEach((s) => s.clusters.forEach((c) => c.open = true));
      sessions = found; done = true; render();
    } else { await reload(); }
  }, 120);
});
query.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { const first = list.querySelector('a.row'); if (first) location.href = first.href; }
  if (e.key === 'Escape' && query.value) { query.value = ''; query.dispatchEvent(new Event('input')); e.preventDefault(); }
});

const menu = document.getElementById('clearMenu');
document.getElementById('clearButton').onclick = (e) => { e.stopPropagation(); menu.classList.toggle('open'); };
document.addEventListener('click', () => menu.classList.remove('open'));
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') menu.classList.remove('open'); });
menu.querySelectorAll('button').forEach((b) => b.onclick = async (e) => {
  e.stopPropagation(); menu.classList.remove('open');
  if (await ask({ action: 'clear', range: b.dataset.range })) { searching = ''; query.value = ''; await reload(); }
});

// Session headings stick just under the toolbar, which grows when a narrow window wraps the search field.
new ResizeObserver(() => document.documentElement.style.setProperty('--header', bar.offsetHeight + 'px')).observe(bar);
addEventListener('scroll', () => bar.classList.toggle('scrolled', scrollY > 0), { passive: true });
new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting)) loadMore(); }, { rootMargin: '600px' })
  .observe(document.getElementById('more'));
loadMore();
</script>
</body>
</html>
"""#
}
