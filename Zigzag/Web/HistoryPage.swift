import AppKit
import WebKit

/// History as a page in a tab, as in Chrome: zigzag://history. Served by Zigzag itself (never the network), in the
/// space's own accent, light or dark with the window. The page asks for its rows through a message only it can send.
@MainActor
enum HistoryPage {
    static let url = URL(string: "zigzag://history")!
    static let scheme = "zigzag"

    static func isHistory(_ url: URL?) -> Bool { url?.scheme == scheme }

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
                replyHandler(HistoryPage.rows(HistoryStore.shared.page(before: before, limit: 200)), nil)
            case "search":
                let query = (body["query"] as? String) ?? ""
                replyHandler(HistoryPage.rows(HistoryStore.shared.search(query, limit: 300)), nil)
            case "delete":
                if let string = body["url"] as? String, let url = URL(string: string) { HistoryStore.shared.delete(url) }
                replyHandler(true, nil)
            case "clear":
                HistoryPage.confirmClear(body["range"] as? String ?? "all", from: message.webView, reply: replyHandler)
            default:
                replyHandler(nil, "Unknown")
            }
        }
    }

    private static func rows(_ entries: [HistoryEntry]) -> [[String: Any]] {
        entries.map { entry in
            [
                "url": entry.url.absoluteString,
                "title": entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title,
                "host": HistoryStore.normalizedHost(entry.url),
                "time": entry.lastVisit.timeIntervalSince1970 * 1000,
            ]
        }
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
  --hover: rgba(0,0,0,.05); --field: rgba(0,0,0,.05); --line: rgba(0,0,0,.08);
}
@media (prefers-color-scheme: dark) {
  :root { --accent: %ACCENT_DARK%; --bg: #1e1e20; --text: rgba(255,255,255,.92); --muted: rgba(255,255,255,.56);
          --faint: rgba(255,255,255,.36); --hover: rgba(255,255,255,.06); --field: rgba(255,255,255,.07); --line: rgba(255,255,255,.08); }
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text); font: 13px/1.4 -apple-system, BlinkMacSystemFont, sans-serif;
             -webkit-font-smoothing: antialiased; }
::selection { background: color-mix(in srgb, var(--accent) 30%, transparent); }
main { max-width: 680px; margin: 0 auto; padding: 36px 20px 64px; }
header { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
h1 { font-size: 20px; font-weight: 600; margin: 0; flex: 1; }
.clear { position: relative; }
.clear > button { appearance: none; border: 0; background: none; color: var(--muted); font: inherit; padding: 4px 8px; border-radius: 6px; cursor: default; }
.clear > button:hover { background: var(--hover); color: var(--text); }
.menu { position: absolute; right: 0; top: calc(100% + 4px); background: var(--bg); border-radius: 8px; padding: 4px; min-width: 200px;
        box-shadow: 0 0 0 .5px var(--line), 0 8px 24px rgba(0,0,0,.16); display: none; z-index: 5; }
.menu.open { display: block; }
.menu button { display: block; width: 100%; text-align: left; border: 0; background: none; color: var(--text); font: inherit;
               padding: 4px 9px; border-radius: 5px; cursor: default; }
.menu button:hover { background: var(--accent); color: #fff; }
.search { display: flex; align-items: center; gap: 8px; background: var(--field); border-radius: 8px; padding: 0 10px; height: 32px; margin-bottom: 20px; }
.search svg { flex: none; opacity: .45; }
.search input { flex: 1; border: 0; outline: 0; background: none; color: var(--text); font: inherit; caret-color: var(--accent); }
.search input::-webkit-search-cancel-button { display: none; }
.day { margin-bottom: 18px; }
.day h2 { font-size: 12px; font-weight: 600; color: var(--muted); margin: 0 8px 4px; }
.row { display: flex; align-items: center; gap: 10px; height: 32px; padding: 0 8px; border-radius: 6px; color: inherit; text-decoration: none; }
.row:hover { background: var(--hover); }
.row img, .row .dot { width: 16px; height: 16px; flex: none; border-radius: 3px; }
.row .dot { background: var(--field); }
/* Dark: icons drawn in black (GitHub, Wikipedia) sit on a light tile, as in the sidebar. */
@media (prefers-color-scheme: dark) { .row img { background: #fff; padding: 1px; border-radius: 4px; } }
.row .title { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.row .host { color: var(--faint); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex: 1; min-width: 40px; }
.row time { color: var(--faint); font-size: 12px; font-variant-numeric: tabular-nums; flex: none; }
.row .remove { display: none; flex: none; width: 20px; height: 20px; border: 0; border-radius: 4px; background: none; color: var(--muted);
               font-size: 14px; line-height: 20px; padding: 0; cursor: default; }
.row:hover time { display: none; }
.row:hover .remove { display: block; }
.row .remove:hover { background: var(--field); color: var(--text); }
.empty { text-align: center; padding: 80px 0; color: var(--muted); }
.empty svg { width: 120px; height: auto; color: var(--text); opacity: .08; display: block; margin: 0 auto 16px; }
.empty svg path { stroke: currentColor; }
#more { height: 1px; }
</style>
</head>
<body>
<main>
  <header>
    <h1>History</h1>
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
  <label class="search">
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="7" cy="7" r="5"/><path d="M11 11l3.5 3.5"/></svg>
    <input id="query" type="search" placeholder="Search history" autocomplete="off" autofocus>
  </label>
  <div id="list"></div>
  <div class="empty" id="empty" hidden>%MARK%<div id="emptyText"></div></div>
  <div id="more"></div>
</main>
<script>
const ask = (body) => window.webkit.messageHandlers.zigzagHistory.postMessage(body);
const list = document.getElementById('list');
const empty = document.getElementById('empty');
const query = document.getElementById('query');
let rows = [], done = false, loading = false, searching = '';

const dayTitle = (d) => {
  const today = new Date(); today.setHours(0,0,0,0);
  const day = new Date(d); day.setHours(0,0,0,0);
  const diff = Math.round((today - day) / 86400000);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Yesterday';
  return day.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
};
const timeOf = (d) => new Date(d).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

function row(item) {
  const a = el('a', 'row'); a.href = item.url; a.title = item.url;
  const img = new Image(); img.alt = ''; img.src = 'zigzag://icon/?u=' + encodeURIComponent(item.url);
  img.onerror = () => img.replaceWith(el('span', 'dot'));
  a.append(img, el('span', 'title', item.title), el('span', 'host', item.host), el('time', null, timeOf(item.time)));
  const remove = el('button', 'remove', '×'); remove.title = 'Remove from History';
  remove.onclick = async (e) => {
    e.preventDefault(); e.stopPropagation();
    await ask({ action: 'delete', url: item.url });
    rows = rows.filter((r) => r.url !== item.url);
    render();
  };
  a.append(remove);
  return a;
}

function render() {
  list.textContent = '';
  const groups = new Map();
  for (const r of rows) { const d = dayTitle(r.time); if (!groups.has(d)) groups.set(d, []); groups.get(d).push(r); }
  for (const [title, items] of groups) {
    const section = el('section', 'day');
    section.append(el('h2', null, title));
    items.forEach((i) => section.append(row(i)));
    list.append(section);
  }
  empty.hidden = rows.length > 0;
  document.getElementById('emptyText').textContent = searching ? 'Nothing in your history matches “' + searching + '”.' : 'Pages you visit show up here.';
}

async function loadMore() {
  if (done || loading || searching) return;
  loading = true;
  const before = rows.length ? rows[rows.length - 1].time : null;
  const more = await ask({ action: 'page', before });
  loading = false;
  if (!more.length) { done = true; render(); return; }
  rows = rows.concat(more); render();
}

let timer;
query.addEventListener('input', () => {
  clearTimeout(timer);
  timer = setTimeout(async () => {
    searching = query.value.trim();
    if (searching) { rows = await ask({ action: 'search', query: searching }); done = true; render(); }
    else { rows = []; done = false; await loadMore(); }
  }, 120);
});
query.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { const first = list.querySelector('.row'); if (first) location.href = first.href; }
  if (e.key === 'Escape' && query.value) { query.value = ''; query.dispatchEvent(new Event('input')); e.preventDefault(); }
});

const menu = document.getElementById('clearMenu');
document.getElementById('clearButton').onclick = (e) => { e.stopPropagation(); menu.classList.toggle('open'); };
document.addEventListener('click', () => menu.classList.remove('open'));
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') menu.classList.remove('open'); });
menu.querySelectorAll('button').forEach((b) => b.onclick = async (e) => {
  e.stopPropagation(); menu.classList.remove('open');
  if (await ask({ action: 'clear', range: b.dataset.range })) { rows = []; done = false; searching = ''; query.value = ''; await loadMore(); }
});

new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting)) loadMore(); }, { rootMargin: '600px' })
  .observe(document.getElementById('more'));
loadMore();
</script>
</body>
</html>
"""#
}
