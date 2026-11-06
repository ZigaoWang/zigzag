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
            // Only Zigzag's own pages may load from here. A web page embedding zigzag://icon could otherwise learn which
            // sites are in the icon cache, and so which you've visited.
            let document = task.request.mainDocumentURL ?? url
            guard document.scheme == HistoryPage.scheme else {
                task.didFailWithError(URLError(.noPermissionsToReadFile))
                return
            }
            let data: Data
            let type: String
            if url.host() == "icon", let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value.flatMap(URL.init(string:)),
               let icon = FaviconStore.shared.cachedIcon(for: target),
               let png = HistoryPage.png(FaviconView.isMonochrome(icon) ? HistoryPage.inked(icon, dark: webView.effectiveAppearance.isDark) : icon) {
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

    /// A site with no icon gets the sidebar's fallback, the globe: drawn black at 2x, set in the page as a mask that
    /// takes the page's own muted text color.
    static let globe: Data? = {
        guard let symbol = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: Tokens.Symbol.weight)) else { return nil }
        let side: CGFloat = 32
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let size = symbol.size
            let place = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
            symbol.draw(in: place)
            NSColor.black.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return png(image)
    }()

    /// An icon in one colorless ink (GitHub, ChatGPT) redrawn in the page's text color, as the sidebar draws it, so
    /// a white mark never sits on a white page or a black one on a dark page.
    private static func inked(_ icon: NSImage, dark: Bool) -> NSImage {
        let size = NSSize(width: 32, height: 32)
        return NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            (dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.12, alpha: 1)).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
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
                let urls = strings.compactMap(URL.init(string:))
                HistoryPage.change(urls.count == 1 ? "Remove Page from History" : "Remove Pages from History", from: message.webView) {
                    HistoryStore.shared.remove(urls)
                }
                replyHandler(true, nil)
            case "clear":
                HistoryPage.confirmClear(body["range"] as? String ?? "all", from: message.webView, reply: replyHandler)
            case "forget":
                // Every page a search found, selected with ⌘A: asked first, as clearing is.
                let urls = ((body["urls"] as? [String]) ?? []).compactMap(URL.init(string:))
                HistoryPage.confirmForget(urls, from: message.webView, reply: replyHandler)
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
        ConfirmSheet.show(in: host, title: since == nil ? clearTitle : "Clear history from \(title)?",
                          message: since == nil ? clearMessage : "Pages you visited \(range == "hour" ? "in the last hour" : title) are forgotten on this Mac. Tabs, pinned tabs and passwords stay.",
                          confirmTitle: "Clear History", destructive: true) { confirmed in
            if confirmed {
                change("Clear History", from: webView) { HistoryStore.shared.remove(since: since) }
                if let controller = controller(for: webView) { clearedToast(in: controller) }
            }
            reply(confirmed, nil)
        }
    }

    private static func confirmForget(_ urls: [URL], from webView: WKWebView?, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let host = webView?.window?.contentView, !urls.isEmpty else { reply(false, nil); return }
        let pages = urls.count == 1 ? "this page" : "these \(urls.count) pages"
        ConfirmSheet.show(in: host, title: "Remove \(pages) from History?",
                          message: "They’re forgotten on this Mac. Tabs, pinned tabs and passwords stay.",
                          confirmTitle: "Remove", destructive: true) { confirmed in
            if confirmed { change("Remove Pages from History", from: webView) { HistoryStore.shared.remove(urls) } }
            reply(confirmed, nil)
        }
    }

    /// Clearing all history asks the same way, and says it's done the same way, from the menu, Settings and here.
    static let clearTitle = "Clear all history?"
    static let clearMessage = "Every page you’ve visited is forgotten on this Mac, and the command bar stops suggesting them. Tabs, pinned tabs and passwords stay."
    /// With Undo right there, as ⌘Z does.
    static func clearedToast(in controller: BrowserWindowController) {
        Toast.show("History cleared", symbol: "clock.arrow.circlepath", action: ("Undo", { [weak controller] in
            guard let undo = controller?.sidebarUndo, undo.canUndo, undo.undoActionName == "Clear History" else { return }
            undo.undo()
        }), duration: 5, in: controller)
    }

    private static func controller(for webView: WKWebView?) -> BrowserWindowController? {
        WindowManager.shared.controllers.first { $0.window != nil && $0.window === webView?.window }
    }

    /// A change to History from this page, undoable with ⌘Z in its window. The page shows it itself.
    private static func change(_ name: String, from webView: WKWebView?, _ take: @escaping () -> HistoryRemoval) {
        if let controller = controller(for: webView) { controller.historyChange(name, refresh: false, take) } else { BrowserWindowController.historyChange(name, take) }
    }

    /// Every open History page shows History as it is now, after a change made elsewhere or undone.
    static func refreshOpenPages() {
        for tab in WindowManager.shared.controllers.flatMap(\.tabManager.allTabs) where isHistory(tab.url) {
            tab.webView?.evaluateJavaScript("window.zigzagRefresh && window.zigzagRefresh()")
        }
    }

    // MARK: The page

    /// The space this page is in, for its accent and the wordmark's color.
    private static func theme(for webView: WKWebView) -> Brand.Theme {
        let controller = WindowManager.shared.controllers.first { $0.window === webView.window } ?? WindowManager.shared.keyController
        return controller.map { Brand.Theme.of($0.tabManager.currentSpace) } ?? .brand
    }

    static func html(for webView: WKWebView) -> String {
        template
            .replacingOccurrences(of: "%STYLE%", with: PageStyle.css(theme: theme(for: webView)))
            .replacingOccurrences(of: "%TITLE%", with: PageStyle.title("History"))
            .replacingOccurrences(of: "%SEARCH%", with: PageStyle.search(id: "query", placeholder: "Search history"))
            .replacingOccurrences(of: "%MARK%", with: WordmarkView.svg(class: "mark", label: nil))
            .replacingOccurrences(of: "%GLOBE%", with: globe?.base64EncodedString() ?? "")
    }

    private static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>History</title>
<style>
%STYLE%
/* History's own: sessions of pages, in one grid, under the shared header. */
main { max-width: calc(var(--max) + 2 * var(--gutter)); margin: 0 auto; }
.clear { position: relative; }

#list { padding: 4px calc(var(--gutter) - var(--row-inset)) 48px; }
/* A session: one sitting, from the first page to a break. Sessions are set apart by room and a quiet label, never a
   line. Its label stays in view while its pages scroll. */
.session { margin-bottom: var(--group-gap); }
.session-head { position: sticky; top: var(--header, 56px); z-index: 2; background: var(--bg); display: flex; align-items: baseline;
                gap: var(--space-2); padding: var(--space-3) var(--row-inset) var(--space-1); color: var(--faint); font-size: var(--label); font-weight: 500; }
.session-head h2 { font-size: inherit; font-weight: inherit; margin: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.session-head .range { white-space: nowrap; }
.session-head .count { margin-left: auto; color: var(--faint); font-size: var(--small); white-space: nowrap; }
/* A row's own small button, as the sidebar's: a 20px target with a thin drawn ×, the app's one line weight. */
.remove { flex: none; width: 20px; height: 20px; padding: 0; display: grid; place-items: center; border-radius: var(--radius-small); color: var(--muted); }
.remove svg { width: 10px; height: 10px; }
.remove:hover { background: var(--hover); color: var(--text); }
.remove:active { background: var(--pressed); }
.session-head .remove { align-self: center; }
.session-head:not(:hover):not(:focus-within) .remove { opacity: 0; }
@media (max-width: 520px) { .session-head .count { display: none; } .session-head .remove { margin-left: auto; } }

/* One grid for every row, so titles, addresses and times line up down the whole page at any width:
   disclosure, icon, title, address, time, remove. */
.row { display: grid; grid-template-columns: 12px var(--favicon) minmax(0, 1fr) minmax(0, 34%) 120px 20px; align-items: center; column-gap: 10px;
       min-height: var(--row); padding: 0 var(--row-inset); border-radius: var(--radius-row); color: inherit; text-decoration: none;
       width: 100%; text-align: left; }
.row:hover { background: var(--hover); }
.row:active { background: var(--pressed); }
/* Reached with the keyboard: chosen, as a section is in Settings. */
.row:focus-visible { background: color-mix(in srgb, var(--accent) var(--selection), transparent); outline: none; }
/* Everything selected (⌘A): each session's pages as one lit block, as Finder shows a selection, not a stack of pills. */
.rows { border-radius: var(--radius-row); }
.all-selected .rows { background: color-mix(in srgb, var(--accent) var(--selection), transparent); }
.all-selected .row:hover, .all-selected .row:focus-visible { background: none; }
.row img, .row .dot { grid-column: 2; width: var(--favicon); height: var(--favicon); border-radius: var(--radius-small); }
.row .dot { background: var(--muted); -webkit-mask: url(data:image/png;base64,%GLOBE%) center / 17px no-repeat; }
/* One-color icons (GitHub, ChatGPT) come drawn in the page's own ink, so no icon needs a tile. */
.row .title { grid-column: 3; font-size: var(--row-text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.row .where { grid-column: 4; color: var(--faint); font-size: var(--label); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.row time { grid-column: 5; color: var(--faint); font-size: var(--small); font-variant-numeric: tabular-nums; text-align: right; white-space: nowrap; }
.row .remove { grid-column: 6; }
/* Out of sight until the pointer or keyboard focus reaches the row, but still in the Tab order. */
.row:not(:hover):not(:focus-within) .remove { opacity: 0; }
@media (max-width: 640px) {
  .row { grid-template-columns: 12px var(--favicon) minmax(0, 1fr) auto 20px; }
  .row .where { display: none; }
  .row time { grid-column: 4; }
  .row .remove { grid-column: 5; }
}

/* A cluster: one site, several pages in a row. Its pages sit under it, indented past the icon. */
.cluster > .head .title { font-weight: 500; }
.cluster > .head .chevron { grid-column: 1; width: 12px; height: 12px; color: var(--muted); transition: transform .15s cubic-bezier(.23, 1, .32, 1); }
.cluster.open > .head .chevron { transform: rotate(90deg); }
/* Indented by a wider first column rather than padding, so the address and time columns still line up with the rows above. */
.pages .row { grid-template-columns: 38px var(--favicon) minmax(0, 1fr) minmax(0, 34%) 120px 20px; }
.pages .more { display: block; color: var(--accent); padding: 6px 8px 6px 84px; font-size: var(--label); }
.pages .more:hover { text-decoration: underline; }
@media (max-width: 640px) { .pages .row { grid-template-columns: 38px var(--favicon) minmax(0, 1fr) auto 20px; } }
@media (prefers-reduced-motion: reduce) { .chevron, .page-header { transition: none; } }

.empty { text-align: center; padding: 96px 0; color: var(--muted); }
.empty svg { width: var(--empty-mark); height: auto; color: var(--text); opacity: var(--empty-mark-opacity); display: block; margin: 0 auto var(--empty-gap); }
#more { height: 1px; }
</style>
</head>
<body>
<header class="page-header" id="bar"><div class="inner">
  %TITLE%
  %SEARCH%
  <div class="clear">
    <button class="button" id="clearButton" aria-haspopup="menu" aria-expanded="false" aria-controls="clearMenu">Clear History</button>
    <div class="menu" id="clearMenu" role="menu" aria-label="Clear History">
      <button role="menuitem" data-range="hour">The Last Hour…</button>
      <button role="menuitem" data-range="today">Today…</button>
      <button role="menuitem" data-range="yesterday">Today and Yesterday…</button>
      <hr role="separator">
      <button role="menuitem" class="destructive" data-range="all">All History…</button>
    </div>
  </div>
</div></header>
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
  const b = el('button', 'remove'); b.title = label; b.setAttribute('aria-label', label);
  b.innerHTML = '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M1.5 1.5l7 7M8.5 1.5l-7 7" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/></svg>';
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
  chevron.innerHTML = '<path d="M4.5 2.5L8 6l-3.5 3.5" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" stroke-linejoin="round"/>';
  const count = cluster.items.length;
  head.append(chevron, icon(cluster.items[0].url), el('span', 'title', cluster.host), el('span', 'where', count + ' pages'),
              el('time', null, span(cluster.items)),
              removeButton('Remove ' + count + ' Pages from History', () => forget(cluster.items.map((i) => i.url), session)));
  head.onclick = () => {
    // Opened or closed from the keyboard, the new heading keeps the focus, so the arrows carry on from it.
    const focused = document.activeElement === head;
    cluster.open = !cluster.open;
    const fresh = clusterElement(cluster, session);
    box.replaceWith(fresh);
    if (focused) fresh.firstChild.focus();
  };
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
  const rows = el('div', 'rows');
  for (const c of session.clusters) rows.append(c.items.length > 1 ? clusterElement(c, session) : page(c.items[0], session));
  section.append(head, rows);
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

// Each reload or search starts a new generation; an answer that comes back for an older one is dropped, so a slow
// search or page never lands on top of what you asked for since.
let generation = 0;

async function loadMore() {
  if (done || loading || searching) return;
  loading = true;
  const mine = generation;
  const last = sessions[sessions.length - 1];
  const before = last ? last.clusters[last.clusters.length - 1].items.slice(-1)[0].time : null;
  const more = await ask({ action: 'page', before });
  loading = false;
  if (mine !== generation) { if (!searching) loadMore(); return; }
  if (searching) return;
  if (!more.length) { done = true; showEmpty(); return; }
  // Batches end where a session ends, so each one only adds.
  for (const s of more) { sessions.push(s); redraw(s); }
  showEmpty();
  // Collapsed clusters take little room, so one batch may not fill a tall window: keep going until it does.
  requestAnimationFrame(() => { if (document.getElementById('more').getBoundingClientRect().top < innerHeight + 600) loadMore(); });
}

async function reload() { generation++; sessions = []; done = false; list.textContent = ''; await loadMore(); }
// The browser asks after History changed (a clear, or ⌘Z bringing pages back): shown again as it is now, the search
// kept.
window.zigzagRefresh = () => { selectAll(false); return query.value.trim() ? search() : reload(); };

let timer;
// Shows what matches the search field now. Typing waits a moment before calling it; Return calls it at once.
async function search() {
  clearTimeout(timer); timer = null;
  searching = query.value.trim();
  if (searching) {
    const mine = ++generation;
    const found = await ask({ action: 'search', query: searching });
    if (mine !== generation) return;
    // Clusters that hold a match open by themselves.
    found.forEach((s) => s.clusters.forEach((c) => c.open = true));
    sessions = found; done = true; render();
  } else { await reload(); }
}
query.addEventListener('input', () => {
  clearTimeout(timer);
  timer = setTimeout(search, 120);
});
query.addEventListener('keydown', async (e) => {
  // Return and Escape while composing (Japanese, Chinese) belong to the input method, not to History.
  if (e.isComposing || e.keyCode === 229) return;
  if (e.key === 'Enter') {
    e.preventDefault();
    // Typed and returned at once: the search hasn't run yet, so run it first, or the top of everything opens.
    if (timer || query.value.trim() !== searching) await search();
    const first = list.querySelector('a.row');
    if (first) location.href = first.href;
  }
  if (e.key === 'Escape' && query.value) { query.value = ''; query.dispatchEvent(new Event('input')); e.preventDefault(); }
});

// The arrow keys walk the rows, from the search field down and back up to it.
document.addEventListener('keydown', (e) => {
  if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
  if (menu.classList.contains('open')) return;
  const rows = [...list.querySelectorAll('.row')];
  const at = rows.indexOf(document.activeElement);
  if (document.activeElement === query && e.key === 'ArrowDown' && rows.length) { rows[0].focus(); e.preventDefault(); return; }
  if (at < 0) return;
  e.preventDefault();
  if (e.key === 'ArrowDown') rows[Math.min(at + 1, rows.length - 1)].focus();
  else if (at === 0) query.focus(); else rows[at - 1].focus();
});

// ⌘A selects every row, as in Safari, and Delete then clears them, after asking: all of History, or while searching,
// just what it found. Esc, a click or typing lets go. In the search field with something typed, ⌘A selects that text.
let allSelected = false;
const selectAll = (on) => { allSelected = on; list.classList.toggle('all-selected', on); };
// Edit › Select All comes here from the browser (it takes ⌘A before the page sees it). False: select as usual.
window.zigzagSelectAll = () => {
  if ((document.activeElement === query && query.value) || !list.querySelector('.row')) return false;
  if (document.activeElement === query) query.blur();
  selectAll(true);
  return true;
};
document.addEventListener('keydown', async (e) => {
  if (e.isComposing || e.keyCode === 229) return;
  if (e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey && e.key.toLowerCase() === 'a') {
    if (window.zigzagSelectAll()) e.preventDefault();
    return;
  }
  if (!allSelected) return;
  // Typing in the search field is about the search: the selection lets go rather than being cleared.
  if (e.target === query) { selectAll(false); return; }
  if (e.key === 'Escape') { e.preventDefault(); selectAll(false); return; }
  if (e.key !== 'Backspace' && e.key !== 'Delete') return;
  e.preventDefault();
  const urls = sessions.flatMap((s) => s.clusters.flatMap((c) => c.items.map((i) => i.url)));
  const cleared = searching ? await ask({ action: 'forget', urls }) : await ask({ action: 'clear', range: 'all' });
  selectAll(false);
  if (cleared) { searching = ''; query.value = ''; await reload(); }
});
document.addEventListener('mousedown', () => { if (allSelected) selectAll(false); });
query.addEventListener('input', () => selectAll(false));
query.addEventListener('focus', () => selectAll(false));

// Clear History…: a menu as Zigzag's panels draw it, opened by click, Return or the arrow keys, walked with the arrows.
const menu = document.getElementById('clearMenu');
const clearButton = document.getElementById('clearButton');
const items = [...menu.querySelectorAll('[role="menuitem"]')];
// It leaves as Zigzag's menus do: quicker and subtler than it came, then gone.
const setMenu = (open, focusFirst) => {
  if (!open && menu.classList.contains('open')) {
    menu.classList.add('closing');
    setTimeout(() => menu.classList.remove('closing'), 120);
  }
  menu.classList.toggle('open', open);
  clearButton.setAttribute('aria-expanded', open);
  if (open && focusFirst) items[0].focus();
};
clearButton.onclick = (e) => { e.stopPropagation(); setMenu(!menu.classList.contains('open'), e.detail === 0); };
clearButton.addEventListener('keydown', (e) => { if (e.key === 'ArrowDown') { e.preventDefault(); setMenu(true, true); } });
menu.addEventListener('keydown', (e) => {
  const at = items.indexOf(document.activeElement);
  if (e.key === 'ArrowDown') { e.preventDefault(); items[(at + 1) % items.length].focus(); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); items[(at - 1 + items.length) % items.length].focus(); }
  else if (e.key === 'Tab') setMenu(false);
});
document.addEventListener('click', () => setMenu(false));
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape' || !menu.classList.contains('open')) return;
  const inside = menu.contains(document.activeElement);
  setMenu(false);
  if (inside) clearButton.focus();
});
items.forEach((b) => b.onclick = async (e) => {
  e.stopPropagation(); setMenu(false);
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
