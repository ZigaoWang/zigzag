import AppKit
import WebKit

/// What you changed about one site's pages, as Arc's Boosts: elements you zapped, hidden on every visit.
nonisolated struct SiteBoost: Codable, Equatable, Sendable {
    /// CSS selectors, one for each element zapped, in the order they were.
    var zaps: [String] = []

    var isEmpty: Bool { zaps.isEmpty }
}

/// Boosts for each site, kept under its host without "www.". Only web pages (http, https) have them: never Zigzag's
/// own pages, an extension's or an error page. A private window starts from what's kept and changes only its own
/// copy, gone when the window closes.
enum SiteBoosts {
    /// Where boosts are kept; tests use their own.
    static var defaults: UserDefaults = .standard
    private static let key = "SiteBoosts"
    /// The most zaps kept for one site.
    static let maxZaps = 200

    /// Every site's boosts, as kept.
    static var all: [String: SiteBoost] {
        get {
            guard let data = defaults.data(forKey: key), let all = try? JSONDecoder().decode([String: SiteBoost].self, from: data) else { return [:] }
            return all
        }
        set {
            let kept = newValue.filter { !$0.value.isEmpty }
            if kept.isEmpty { defaults.removeObject(forKey: key) } else if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: key) }
        }
    }

    static var sites: Set<String> { Set(all.keys) }

    /// "3 zapped": in Site Controls, and in Settings › Privacy › Sites.
    static func zapped(_ count: Int) -> String {
        String(localized: "\(count) zapped", comment: "How many elements on a site were hidden with Zap Element, like “3 zapped”: a row in the site panel, with Restore All after it, and a choice made for a site in Settings › Privacy › Sites.")
    }

    /// A private window's own boosts, by its store: they go when the window's store does.
    private final class Window {
        var boosts: [String: SiteBoost] = [:]
    }
    private static let windows = NSMapTable<WKWebsiteDataStore, Window>.weakToStrongObjects()

    /// The site a boost is kept under: a web page's host without "www.".
    static func site(of url: URL?) -> String? {
        guard ["http", "https"].contains(url?.scheme?.lowercased() ?? "") else { return nil }
        return ContentBlocker.site(of: url)
    }

    /// The site's boosts in a window: a private one's own copy once it changed them, otherwise the kept ones.
    static func boost(forSite site: String, privateStore: WKWebsiteDataStore? = nil) -> SiteBoost {
        if let privateStore, let own = windows.object(forKey: privateStore)?.boosts[site] { return own }
        return all[site] ?? SiteBoost()
    }

    static func boost(for url: URL?, privateStore: WKWebsiteDataStore? = nil) -> SiteBoost {
        site(of: url).map { boost(forSite: $0, privateStore: privateStore) } ?? SiteBoost()
    }

    /// Keeps a site's boosts, or in a private window keeps them for that window only.
    static func set(_ boost: SiteBoost, forSite site: String, privateStore: WKWebsiteDataStore? = nil) {
        if let privateStore {
            let window = windows.object(forKey: privateStore) ?? {
                let window = Window()
                windows.setObject(window, forKey: privateStore)
                return window
            }()
            window.boosts[site] = boost
            return
        }
        var all = all
        all[site] = boost.isEmpty ? nil : boost
        self.all = all
    }

    /// Adds a zapped element's selector for the site. Returns false for one that isn't a plain selector.
    @discardableResult
    static func zap(_ selector: String, forSite site: String, privateStore: WKWebsiteDataStore? = nil) -> Bool {
        let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlainSelector(selector) else { return false }
        var boost = boost(forSite: site, privateStore: privateStore)
        guard !boost.zaps.contains(selector) else { return true }
        boost.zaps.append(selector)
        if boost.zaps.count > maxZaps { boost.zaps.removeFirst(boost.zaps.count - maxZaps) }
        set(boost, forSite: site, privateStore: privateStore)
        return true
    }

    /// Restore All: every zapped element on the site shows again.
    static func restoreZaps(forSite site: String, privateStore: WKWebsiteDataStore? = nil) {
        var boost = boost(forSite: site, privateStore: privateStore)
        boost.zaps = []
        set(boost, forSite: site, privateStore: privateStore)
    }

    /// One site's boosts forgotten (Forget in Settings › Privacy › Sites).
    static func forget(site: String) {
        var all = all
        all[site] = nil
        self.all = all
    }

    /// Every site's (Settings › Privacy › Sites › Reset All).
    static func forgetAll() { all = [:] }

    /// A selector the picker made, as a style sheet may take it: nothing that could end its rule, start another or
    /// comment out the ones after it. Backslashes stay: `CSS.escape` writes them.
    nonisolated static func isPlainSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count <= 512 else { return false }
        return !selector.contains { "{};@<\"'\n\r".contains($0) } && !selector.contains("/*") && !selector.contains("*/")
    }

    /// The style sheet for a site's boosts: a rule for each zap, so one a browser can't read leaves the rest working.
    nonisolated static func css(for boost: SiteBoost) -> String {
        boost.zaps.filter(isPlainSelector).map { "\($0) { display: none !important; }" }.joined(separator: "\n")
    }
}

/// Puts a site's boosts in its pages: a style sheet added as the document starts, in the main frame only, the way the
/// ad blocker hides what its lists name (`PageFilters.styleSource`). Changed while you're on the page, it changes in
/// place.
enum PageBoosts {
    /// Where the style sheet and the picker run, apart from the page's own scripts.
    static let world = WKContentWorld.world(name: "ZigzagBoosts")
    private static let mark = "/* zigzag boosts */"
    /// The world's name for the style element, so a change finds it.
    private static let styleName = "__zigzagBoost"

    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(mark) }

    /// Readies a web view for a page at `url` before it loads: the site's boosts, or none. Error pages get none.
    static func prepare(_ webView: WKWebView, for url: URL?, privateStore: WKWebsiteDataStore?, errorPage: Bool) {
        let controller = webView.configuration.userContentController
        OwnScripts.remove(from: controller, where: isOurs)
        guard !errorPage, let site = SiteBoosts.site(of: url) else { return }
        let css = SiteBoosts.css(for: SiteBoosts.boost(forSite: site, privateStore: privateStore))
        guard !css.isEmpty else { return }
        controller.addUserScript(WKUserScript(source: source(css: css, site: site), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }

    /// The boosts of the page in `tab` changed: the page shows it now, and its next load too.
    static func refresh(_ tab: Tab) {
        guard let webView = tab.webView else { return }
        let url = webView.url ?? tab.url
        prepare(webView, for: url, privateStore: tab.privateStore, errorPage: ErrorPage.pending.contains(webView))
        guard let site = SiteBoosts.site(of: url), !ErrorPage.pending.contains(webView) else { return }
        let css = SiteBoosts.css(for: SiteBoosts.boost(forSite: site, privateStore: tab.privateStore))
        webView.runOwnScript(source(css: css, site: site), world: world)
    }

    /// The script that puts `css` in a page of `site`, kept under one name so the next change replaces it.
    static func source(css: String, site: String) -> String {
        "\(mark)\nif (\(siteCheck(site))) {\n\(PageFilters.styleSource(css, keptAs: styleName))\n}"
    }

    /// Whether the document is on `site`, as `ContentBlocker.site` names it.
    private static func siteCheck(_ site: String) -> String {
        "location.hostname.toLowerCase().replace(/\\.$/, '').replace(/^www\\./, '') === \(PageFilters.jsString(site))"
    }

    // MARK: Picking

    /// Makes a unique, lasting selector for an element: its id when that's stable, otherwise its tag with up to two
    /// classes that don't look generated, then its place among siblings of its tag, going up to `maxDepth` parents.
    /// An element inside an SVG drawing is the drawing. The page itself (html, body) never is.
    static let selectorSource = #"""
    window.ZigzagBoostSelector = (() => {
      const maxDepth = 10;
      const landmarks = ['header', 'nav', 'main', 'aside', 'footer'];
      const generated = (name) => {
        if (name.length > 40 || /\d{4,}/.test(name)) return true;
        if (/^(css|sc|jsx|svelte|emotion|styled|tw)[-_]/i.test(name)) return true;
        return name.split(/[-_:]+/).some((part) => {
          const digits = (part.match(/\d/g) || []).length;
          if (part.length >= 5 && digits >= 2 && /[a-z]/i.test(part)) return true;
          return part.length >= 6 && /^[a-zA-Z]+$/.test(part) && /[a-z][A-Z][a-z]*[A-Z]|[A-Z]{3}[a-z]/.test(part);
        });
      };
      const passing = (name) => /^(is-|has-)/.test(name) || /^(active|selected|hover|focus|focused|open|opened|show|shown|visible|hidden|current|loaded|loading)$/i.test(name);
      const unique = (selector, element) => {
        try { const found = document.querySelectorAll(selector); return found.length === 1 && found[0] === element; } catch (e) { return false; }
      };
      const stableId = (element) => element.id && !generated(element.id) && !/^\d/.test(element.id) && unique('#' + CSS.escape(element.id), element);
      const classes = (element) => Array.from(element.classList).filter((name) => !generated(name) && !passing(name)).slice(0, 2);
      const place = (element) => {
        let index = 1, others = false;
        for (let s = element.previousElementSibling; s; s = s.previousElementSibling) if (s.localName === element.localName) index++;
        for (let s = element.nextElementSibling; s; s = s.nextElementSibling) if (s.localName === element.localName) { others = true; break; }
        return index > 1 || others ? ':nth-of-type(' + index + ')' : '';
      };
      return (picked) => {
        let element = picked;
        if (!element || element.nodeType !== 1) return null;
        const drawing = element.closest && element.closest('svg');
        if (drawing && drawing !== element) element = drawing;
        if (['html', 'body', 'head'].includes(element.localName)) return null;
        const path = [];
        for (let node = element, depth = 0; node && node.nodeType === 1 && depth < maxDepth; node = node.parentElement, depth++) {
          if (node.localName === 'body') {
            const full = ['body'].concat(path).join(' > ');
            return unique(full, element) ? full : null;
          }
          if (stableId(node)) {
            const anchored = ['#' + CSS.escape(node.id)].concat(path).join(' > ');
            if (unique(anchored, element)) return anchored;
          }
          const tag = CSS.escape(node.localName);
          const kept = classes(node);
          const named = tag + kept.map((name) => '.' + CSS.escape(name)).join('');
          const step = named + place(node);
          // A path starts from something with a name of its own (a class, a landmark), not a bare tag and place.
          if (kept.length || landmarks.includes(node.localName)) {
            const plain = [named].concat(path).join(' > ');
            if (unique(plain, element)) return plain;
            const placed = [step].concat(path).join(' > ');
            if (unique(placed, element)) return placed;
          }
          path.unshift(step);
        }
        return null;
      };
    })();
    """#

    /// The picker over the page: the element under the pointer outlined in `accent`, its tag and size by it; a click
    /// zaps it and nothing else in the page hears the click. `stop()` takes every trace of it away.
    static func pickerSource(accent: String, hint: String) -> String {
        selectorSource + "\n" + #"""
        (() => {
          if (window.__zigzagZap) return;
          const accent = ACCENT, hint = HINT;
          const host = document.createElement('zigzag-zap');
          host.style.cssText = 'all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483647;';
          const root = host.attachShadow({ mode: 'closed' });
          root.innerHTML = '<style>' +
            '.box { position: fixed; box-sizing: border-box; border: 1px solid ' + accent + '; border-radius: 3px; pointer-events: none; display: none; }' +
            '.tag { position: fixed; font: 500 11px/16px -apple-system, system-ui, sans-serif; color: #fff; background: rgba(28, 28, 30, 0.88);' +
            ' padding: 1px 6px; border-radius: 4px; pointer-events: none; display: none; white-space: nowrap; font-variant-numeric: tabular-nums; }' +
            '</style><div class="box"></div><div class="tag"></div>';
          const box = root.querySelector('.box'), tag = root.querySelector('.tag');
          let target = null;
          const show = (element) => {
            if (element && element.closest && element.closest('svg') && element.closest('svg') !== element) element = element.closest('svg');
            target = element && !['html', 'body'].includes(element.localName) ? element : null;
            if (!target) { box.style.display = 'none'; tag.style.display = 'none'; return; }
            const r = target.getBoundingClientRect();
            Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
            tag.textContent = target.localName + '  ' + Math.round(r.width) + ' × ' + Math.round(r.height);
            tag.style.display = 'block';
            const above = r.top - 20;
            tag.style.left = Math.max(4, Math.min(r.left, innerWidth - tag.offsetWidth - 4)) + 'px';
            tag.style.top = (above >= 4 ? above : Math.min(r.bottom + 4, innerHeight - 20)) + 'px';
          };
          const post = (body) => { try { webkit.messageHandlers.zigzagZap.postMessage(body); } catch (e) {} };
          const move = (event) => show(document.elementFromPoint(event.clientX, event.clientY));
          const swallow = (event) => { event.preventDefault(); event.stopImmediatePropagation(); };
          const click = (event) => {
            swallow(event);
            if (event.button !== 0) return;
            const picked = document.elementFromPoint(event.clientX, event.clientY) || target;
            const selector = window.ZigzagBoostSelector(picked);
            post(selector ? { zap: selector } : { failed: true });
            show(null);
          };
          const key = (event) => { if (event.key === 'Escape') { swallow(event); post({ done: true }); } };
          const scrolled = () => show(target);
          const blocked = ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'auxclick', 'dblclick', 'touchstart', 'touchend'];
          addEventListener('mousemove', move, true);
          addEventListener('click', click, true);
          addEventListener('keydown', key, true);
          addEventListener('scroll', scrolled, true);
          blocked.forEach((name) => addEventListener(name, swallow, true));
          (document.body || document.documentElement).appendChild(host);
          document.documentElement.style.setProperty('cursor', 'crosshair', 'important');
          host.title = hint;
          window.__zigzagZap = {
            show: (element) => show(element),
            stop: () => {
              removeEventListener('mousemove', move, true);
              removeEventListener('click', click, true);
              removeEventListener('keydown', key, true);
              removeEventListener('scroll', scrolled, true);
              blocked.forEach((name) => removeEventListener(name, swallow, true));
              document.documentElement.style.removeProperty('cursor');
              host.remove();
              delete window.__zigzagZap;
            },
          };
        })();
        """#.replacingOccurrences(of: "ACCENT", with: PageFilters.jsString(accent)).replacingOccurrences(of: "HINT", with: PageFilters.jsString(hint))
    }

    static let stopSource = "window.__zigzagZap && window.__zigzagZap.stop();"
}

/// Zap Element, from Site Controls: picking elements on the page you're on to hide, until Esc, a click outside the
/// page, a shortcut or the page going elsewhere. One page at a time.
final class ZapPicker: NSObject, WKScriptMessageHandler {
    private(set) static var current: ZapPicker?
    static let messageName = "zigzagZap"

    private weak var tab: Tab?
    private weak var webView: WKWebView?
    private weak var controller: BrowserWindowController?
    private let site: String
    private var monitor: Any?
    private var tabToken: SignalToken?

    static func canZap(_ tab: Tab) -> Bool {
        guard let webView = tab.webView, SiteBoosts.site(of: webView.url ?? tab.url) != nil else { return false }
        return !ErrorPage.pending.contains(webView) && tab.pdfViewer == nil
    }

    private init(tab: Tab, webView: WKWebView, site: String, controller: BrowserWindowController) {
        self.tab = tab
        self.webView = webView
        self.site = site
        self.controller = controller
    }

    /// Starts picking on the page in `tab`.
    static func start(in tab: Tab, controller: BrowserWindowController) {
        current?.stop()
        guard canZap(tab), let webView = tab.webView, let site = SiteBoosts.site(of: webView.url ?? tab.url) else { return }
        let picker = ZapPicker(tab: tab, webView: webView, site: site, controller: controller)
        current = picker
        let content = webView.configuration.userContentController
        content.removeScriptMessageHandler(forName: messageName, contentWorld: PageBoosts.world)
        content.add(picker, contentWorld: PageBoosts.world, name: messageName)
        let accent = DarkPages.hex(Brand.Theme.for(webView).accent)
        webView.runOwnScript(PageBoosts.pickerSource(accent: accent, hint: Self.hint), world: PageBoosts.world)
        controller.window?.makeFirstResponder(webView)
        // Esc and shortcuts end it from Zigzag's side too, as does a click anywhere but the page.
        picker.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak picker] event in
            guard let picker else { return event }
            return picker.handle(event)
        }
        picker.tabToken = tab.changed.observe { [weak picker] change in
            if change == .url || change == .navigation || change == .webView { picker?.stop() }
        }
        Toast.show(hint, symbol: "scope", duration: 4, in: controller)
    }

    static let hint = String(localized: "Click what to zap. Press Esc when you’re done.", comment: "Toast while picking elements to hide on a page with Zap Element from Site Controls.")

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let webView, event.window === webView.window else { return event }
        if event.type == .keyDown {
            if event.keyCode == 53 { stop(); return nil }
            if !event.modifierFlags.intersection([.command, .control]).isEmpty { stop() }
            return event
        }
        let point = webView.convert(event.locationInWindow, from: nil)
        if !webView.bounds.contains(point) { stop() }
        return event
    }

    /// Takes the picker off the page, which then hears its clicks again.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        tabToken = nil
        if let webView {
            webView.runOwnScript(PageBoosts.stopSource, world: PageBoosts.world)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName, contentWorld: PageBoosts.world)
        }
        if Self.current === self { Self.current = nil }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard Self.current === self, message.frameInfo.isMainFrame, message.webView === webView,
              let body = message.body as? [String: Any] else { return }
        if body["done"] != nil { stop(); return }
        guard let tab, SiteBoosts.site(of: message.webView?.url) == site else { return }
        if let selector = body["zap"] as? String {
            Self.zap(selector, site: site, in: tab)
        } else if body["failed"] != nil, let controller = self.controller {
            Toast.show(String(localized: "That can’t be zapped. Try something around it.", comment: "Toast when the element clicked with Zap Element can't be named well enough to hide on later visits."),
                       symbol: "scope", in: controller)
        }
    }

    /// Hides an element by its selector on the site, here and on later visits (or for a private window, in it).
    static func zap(_ selector: String, site: String, in tab: Tab) {
        guard SiteBoosts.zap(selector, forSite: site, privateStore: tab.privateStore) else { return }
        PageBoosts.refresh(tab)
    }

    #if DEBUG
    /// zap <css selector>: what the picker does on a click on the first element that matches, in the page in front.
    static func debugZap(_ query: String, in tab: Tab) {
        guard let webView = tab.webView, let site = SiteBoosts.site(of: webView.url) else { debugLog("zap: no site"); return }
        let script = PageBoosts.selectorSource + "\nwindow.ZigzagBoostSelector(document.querySelector(\(PageFilters.jsString(query))))"
        webView.runOwnScript(script, world: PageBoosts.world) { result in
            guard case .success(let value) = result, let selector = value as? String else { debugLog("zap \(query): no selector"); return }
            debugLog("zap \(query) => \(selector)")
            zap(selector, site: site, in: tab)
        }
    }

    /// zaphover <css selector>: the picker's outline on the first element that matches, as the pointer would put it.
    static func debugHover(_ query: String) {
        current?.webView?.runOwnScript("window.__zigzagZap && window.__zigzagZap.show(document.querySelector(\(PageFilters.jsString(query))))", world: PageBoosts.world)
    }
    #endif
}
