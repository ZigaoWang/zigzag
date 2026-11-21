import AppKit
import WebKit

/// zigzag://archive, as in Arc: auto-archived tabs grouped by day; a click restores one to its space. Served and
/// styled like History.
@MainActor
enum ArchivePage {
    static let host = "archive"
    static let url = URL(string: "\(HistoryPage.scheme)://\(host)")!

    static func isArchive(_ url: URL?) -> Bool { HistoryPage.isInternal(url) && url?.host() == host }

    /// Used for the page, its tab and the address.
    static var title: String { String(localized: "Archive", comment: "Title of the Archive page, the list of tabs that were archived; also its tab's name.") }

    /// Reuses this window's Archive tab in the space, or opens one. Private windows archive nothing, so it opens in a
    /// normal window, like Settings.
    static func open(in controller: BrowserWindowController) {
        if controller.tabManager.isPrivate {
            let normal = NSApp.orderedWindows.lazy.compactMap { window in
                WindowManager.shared.controllers.first { $0.window === window && !$0.tabManager.isPrivate }
            }.first
            open(in: normal ?? WindowManager.shared.restoreIfNoWindows() ?? WindowManager.shared.newWindow(showCommandBar: false))
            return
        }
        if let existing = controller.tabManager.currentTabs.first(where: { isArchive($0.url) }) {
            controller.tabManager.select(existing)
            existing.reload()
        } else {
            controller.open(url, disposition: .foregroundTab)
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Refreshes every open Archive page.
    static func refreshOpenPages() {
        for tab in WindowManager.shared.controllers.flatMap(\.tabManager.allTabs) where isArchive(tab.url) {
            tab.webView?.evaluateJavaScript("window.zigzagRefresh && window.zigzagRefresh()")
        }
    }

    /// Archived from one of this profile's spaces.
    private static func belongs(to webView: WKWebView?) -> (ArchivedTab) -> Bool {
        let profile = HistoryPage.profile(of: webView).id
        return { Library.shared.profileID(ofSpace: $0.spaceID) == profile }
    }

    // MARK: The page's questions

    final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = Bridge()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            // Only the Archive page itself, never a website or frame.
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == HistoryPage.scheme,
                  message.frameInfo.securityOrigin.host == ArchivePage.host,
                  let body = message.body as? [String: Any], let action = body["action"] as? String else {
                replyHandler(nil, "Not allowed")
                return
            }
            let webView = message.webView
            switch action {
            case "list":
                replyHandler(ArchivePage.list(query: body["query"] as? String ?? "", for: webView), nil)
            case "restore":
                guard let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)), let entry = TabArchive.shared.entry(id),
                      let controller = HistoryPage.controller(for: webView) else { replyHandler(false, nil); return }
                controller.tabManager.restore(entry)
                controller.window?.makeKeyAndOrderFront(nil)
                replyHandler(true, nil)
            case "clear":
                ArchivePage.confirmClear(from: webView, reply: replyHandler)
            case "settings":
                if let controller = HistoryPage.controller(for: webView) { SettingsPage.open(.tabs, in: controller) }
                replyHandler(true, nil)
            default:
                replyHandler(nil, "Unknown")
            }
        }
    }

    /// Days and rows for the page, and whether archiving is on.
    private static func list(query: String, for webView: WKWebView?) -> [String: Any] {
        let belongs = belongs(to: webView)
        let words = ArchiveDays.words(query)
        let ours = TabArchive.shared.entries.filter(belongs)
        let found = ours.filter { ArchiveDays.matches($0, words: words, space: Library.shared.space($0.spaceID)?.name) }
        let now = Date()
        return [
            "on": TabArchive.after != .never,
            "any": !ours.isEmpty,
            "days": ArchiveDays.group(found).map { day in
                [
                    "title": ArchiveDays.title(of: day.start, now: now),
                    "items": day.entries.map { entry in
                        [
                            "id": entry.id.uuidString,
                            "url": entry.url.absoluteString,
                            "title": entry.title.isEmpty ? CommandRanker.displayURL(entry.url) : entry.title,
                            "site": entry.url.host()?.withoutWWW ?? CommandRanker.displayURL(entry.url),
                            "space": Library.shared.space(entry.spaceID)?.name ?? "",
                            "time": entry.archivedAt.timeIntervalSince1970 * 1000,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
    }

    private static func confirmClear(from webView: WKWebView?, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let host = webView?.window?.contentView else { reply(false, nil); return }
        let belongs = belongs(to: webView)
        ConfirmSheet.show(in: host, title: String(localized: "Clear the archive?", comment: "Title of the sheet that asks before clearing the Archive page."),
                          message: String(localized: "Archived tabs are forgotten. History keeps the pages you visited.", comment: "Message of the sheet that asks before clearing the Archive page."),
                          confirmTitle: clearTitle, destructive: true) { confirmed in
            if confirmed {
                let taken = TabArchive.shared.take(since: nil, where: belongs)
                if let controller = HistoryPage.controller(for: webView), !taken.isEmpty {
                    Toast.show(String(localized: "Archive cleared", comment: "Toast after the Archive page is cleared."), symbol: "archivebox",
                               action: (String(localized: "Undo", comment: "Button in the toast after the Archive page is cleared."), { TabArchive.shared.putBack(taken) }),
                               duration: Toast.undoDuration, in: controller)
                }
            }
            reply(confirmed, nil)
        }
    }

    static var clearTitle: String { String(localized: "Clear Archive", comment: "Button on the Archive page, and the button of the sheet that asks before clearing it.") }

    // MARK: The page

    static func html(for webView: WKWebView) -> String {
        let escape = HistoryPage.escape
        return template
            .replacingOccurrences(of: "%LANG%", with: Bundle.main.preferredLocalizations.first ?? "en")
            .replacingOccurrences(of: "%PAGETITLE%", with: escape(title))
            .replacingOccurrences(of: "%CLEAR%", with: escape(clearTitle))
            .replacingOccurrences(of: "%SETTINGS%", with: escape(String(localized: "Open Settings", comment: "Button on the Archive page while archiving is off: opens Settings › Tabs.")))
            .replacingOccurrences(of: "%WORDS%", with: words)
            .replacingOccurrences(of: "%STYLE%", with: PageStyle.css(theme: HistoryPage.theme(for: webView)))
            .replacingOccurrences(of: "%TITLE%", with: PageStyle.title(escape(title)))
            .replacingOccurrences(of: "%SEARCH%", with: PageStyle.search(id: "query", placeholder: escape(String(localized: "Search archive", comment: "Placeholder of the search field on the Archive page."))))
            .replacingOccurrences(of: "%MARK%", with: WordmarkView.svg(class: "mark", label: nil))
            .replacingOccurrences(of: "%GLOBE%", with: HistoryPage.globe?.base64EncodedString() ?? "")
    }

    private static var words: String {
        let words: [String: String] = [
            "locale": Words.dates.identifier(.bcp47),
            "restore": String(localized: "Open in \("{space}")", comment: "Tooltip of a row on the Archive page: the tab opens again in the space it came from. The placeholder is the space's name."),
            "noMatch": String(localized: "No archived tabs match “\("{query}")”.", comment: "On the Archive page when a search finds nothing. The placeholder is what was typed."),
            "empty": String(localized: "Tabs you haven’t used in a while show up here.", comment: "On the Archive page while it's empty and archiving is on."),
            "off": String(localized: "Archived tabs show up here when Settings › Tabs › Archive tabs you haven’t used is on.", comment: "On the Archive page while archiving is off. Name the setting as it reads in Settings › Tabs."),
        ]
        let json = (try? JSONSerialization.data(withJSONObject: words, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return json.replacingOccurrences(of: "</", with: "<\\/")
    }

    static let template = #"""
<!doctype html>
<html lang="%LANG%">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%PAGETITLE%</title>
<style>
%STYLE%
/* The Archive's own: days of tabs, in History's grid, under the shared header. */
main { max-width: calc(var(--max) + 2 * var(--gutter)); margin: 0 auto; }
/* A pill button sets its own display, which would otherwise show it while hidden. */
[hidden] { display: none !important; }
#list { padding: 4px calc(var(--gutter) - var(--row-inset)) 48px; }
.day { margin-bottom: var(--group-gap); }
.day-head { position: sticky; top: var(--header, 56px); z-index: 2; background: var(--bg); display: flex; align-items: baseline;
            gap: var(--space-2); padding: var(--space-3) var(--row-inset) var(--space-1); color: var(--faint); font-size: var(--label); font-weight: 500; }
.day-head h2 { font-size: inherit; font-weight: inherit; margin: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
/* Icon, title, site, space, time: one grid, so every column lines up down the page. */
.row { display: grid; grid-template-columns: var(--favicon) minmax(0, 1fr) minmax(0, 24%) minmax(0, 16%) 72px; align-items: center; column-gap: 10px;
       min-height: var(--row); padding: 0 var(--row-inset); border-radius: var(--radius-row); color: inherit; text-decoration: none; width: 100%; text-align: left; }
.row:hover { background: var(--hover); }
.row:active { background: var(--pressed); }
.row:focus-visible { background: color-mix(in srgb, var(--accent) var(--selection), transparent); outline: none; }
.row img, .row .dot { width: var(--favicon); height: var(--favicon); border-radius: var(--radius-small); }
.row .dot { background: var(--muted); -webkit-mask: url(data:image/png;base64,%GLOBE%) center / 17px no-repeat; }
.row .title { font-size: var(--row-text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.row .site, .row .space { color: var(--faint); font-size: var(--label); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.row time { color: var(--faint); font-size: var(--small); font-variant-numeric: tabular-nums; text-align: right; white-space: nowrap; }
@media (max-width: 640px) {
  .row { grid-template-columns: var(--favicon) minmax(0, 1fr) minmax(0, 28%) auto; }
  .row .site { display: none; }
}
.empty { text-align: center; padding: var(--no-match-top) 0; color: var(--muted); }
.empty.searching svg { display: none; }
.empty svg { width: var(--empty-mark); height: auto; color: var(--text); opacity: var(--empty-mark-opacity); display: block; margin: 0 auto var(--empty-gap); }
.empty #emptyText { max-width: var(--empty-width); margin: 0 auto; }
.empty .button { margin-top: var(--empty-action-gap); }
</style>
</head>
<body>
<header class="page-header" id="bar"><div class="inner">
  %TITLE%
  %SEARCH%
  <button class="button" id="clearButton" hidden>%CLEAR%</button>
</div></header>
<main>
  <div id="list"></div>
  <div class="empty" id="empty" hidden>%MARK%<div id="emptyText"></div><button class="button" id="settingsButton" hidden>%SETTINGS%</button></div>
</main>
<script>
const ask = (body) => window.webkit.messageHandlers.zigzagArchive.postMessage(body);
const words = %WORDS%;
const fill = (text, values) => text.replace(/\{(\w+)\}/g, (m, k) => (k in values ? String(values[k]) : m));
const list = document.getElementById('list');
const empty = document.getElementById('empty');
const query = document.getElementById('query');
const bar = document.getElementById('bar');
const clearButton = document.getElementById('clearButton');
const settingsButton = document.getElementById('settingsButton');
const timeOf = (ms) => new Date(ms).toLocaleTimeString(words.locale, { hour: 'numeric', minute: '2-digit' });
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const icon = (url) => {
  const img = new Image(); img.alt = ''; img.src = 'zigzag://icon/?u=' + encodeURIComponent(url);
  img.onerror = () => img.replaceWith(el('span', 'dot'));
  return img;
};

// Restores the tab to its space and removes it from the archive.
function row(item) {
  const b = el('button', 'row');
  b.title = item.space ? fill(words.restore, { space: item.space }) : item.url;
  b.append(icon(item.url), el('span', 'title', item.title), el('span', 'site', item.site), el('span', 'space', item.space), el('time', null, timeOf(item.time)));
  b.onclick = () => ask({ action: 'restore', id: item.id });
  return b;
}

let generation = 0;
async function load() {
  const mine = ++generation;
  const typed = query.value.trim();
  const answer = await ask({ action: 'list', query: typed });
  if (mine !== generation || !answer) return;
  list.textContent = '';
  for (const day of answer.days) {
    const section = el('section', 'day');
    const head = el('div', 'day-head'); head.append(el('h2', null, day.title));
    const rows = el('div', 'rows'); day.items.forEach((i) => rows.append(row(i)));
    section.append(head, rows);
    list.append(section);
  }
  clearButton.hidden = !answer.any;
  empty.hidden = answer.days.length > 0;
  // Off and empty: show where to turn it on. Off with tabs kept: show them as usual.
  const off = !answer.on && !answer.any;
  settingsButton.hidden = !off;
  const searching = typed && answer.any;
  document.getElementById('emptyText').textContent = searching ? fill(words.noMatch, { query: typed }) : off ? words.off : words.empty;
  empty.classList.toggle('searching', !!searching);
}
window.zigzagRefresh = load;

let timer;
query.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(load, 120); });
query.addEventListener('keydown', (e) => {
  if (e.isComposing || e.keyCode === 229) return;
  if (e.key === 'Enter') { e.preventDefault(); const first = list.querySelector('.row'); if (first) first.click(); }
  if (e.key === 'Escape' && query.value) { query.value = ''; load(); e.preventDefault(); }
});
// Arrow keys move through rows, from the search field and back.
document.addEventListener('keydown', (e) => {
  if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
  const rows = [...list.querySelectorAll('.row')];
  const at = rows.indexOf(document.activeElement);
  if (document.activeElement === query && e.key === 'ArrowDown' && rows.length) { rows[0].focus(); e.preventDefault(); return; }
  if (at < 0) return;
  e.preventDefault();
  if (e.key === 'ArrowDown') rows[Math.min(at + 1, rows.length - 1)].focus();
  else if (at === 0) query.focus(); else rows[at - 1].focus();
});
clearButton.onclick = () => ask({ action: 'clear' });
settingsButton.onclick = () => ask({ action: 'settings' });

new ResizeObserver(() => document.documentElement.style.setProperty('--header', bar.offsetHeight + 'px')).observe(bar);
addEventListener('scroll', () => bar.classList.toggle('scrolled', scrollY > 0), { passive: true });
load();
</script>
</body>
</html>
"""#
}
