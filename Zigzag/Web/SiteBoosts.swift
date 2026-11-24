import AppKit
import WebKit

/// Per-site changes, like Arc's Boosts: zapped elements hidden on every visit, plus custom CSS. No scripts (that's
/// Tampermonkey's job).
nonisolated struct SiteBoost: Codable, Equatable, Sendable {
    /// One CSS selector per zapped element, in zap order.
    var zaps: [String] = []
    /// A readable name per zap, read from the element when it was zapped; zaps from before have none (#498).
    var names: [String: String] = [:]
    /// Custom CSS from Edit Style…; empty is off.
    var style = ""

    var hasStyle: Bool { !style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isEmpty: Bool { zaps.isEmpty && !hasStyle }

    /// The name kept for `selector`, else one made from the selector.
    func name(forZap selector: String) -> String { names[selector] ?? SiteBoosts.label(forZap: selector) }
}

nonisolated extension SiteBoost {
    private enum Keys: String, CodingKey { case zaps, names, style }

    /// Any may be missing (boosts saved before styles or names existed).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        zaps = try c.decodeIfPresent([String].self, forKey: .zaps) ?? []
        names = (try? c.decodeIfPresent([String: String].self, forKey: .names)) ?? [:]
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? ""
    }
}

/// Why CSS was rejected: plain CSS only, nothing remote or HTML-like.
nonisolated enum StyleProblem: Equatable, Sendable {
    case tooLong, tag, loads

    var message: String {
        switch self {
        case .tooLong: String(localized: "That’s too long for a style. Keep it under 100 KB.", comment: "Under the code field of the Edit Style sheet, while the CSS is too long: why Save can't be pressed.")
        case .tag: String(localized: "A style can’t hold a tag like </style>.", comment: "Under the code field of the Edit Style sheet, while the CSS holds an HTML tag: why Save can't be pressed.")
        case .loads: String(localized: "A style can’t load anything from the web, with @import or a web address.", comment: "Under the code field of the Edit Style sheet, while the CSS imports or loads something from the web: why Save can't be pressed.")
        }
    }
}

/// Boosts keyed by host without "www.". Only http(s) pages; never Zigzag's own, extension or error pages. A private
/// window works on its own copy, dropped when it closes.
enum SiteBoosts {
    /// Tests use their own.
    static var defaults: UserDefaults = .standard
    private static let key = "SiteBoosts"
    static let maxZaps = 200

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

    /// "3 zapped", for Site Controls and Settings › Privacy › Sites.
    static func zapped(_ count: Int) -> String {
        String(localized: "\(count) zapped", comment: "How many elements on a site were hidden with Zap Element, like “3 zapped”: a row in the site panel that opens the list of them, and a choice made for a site in Settings › Privacy › Sites.")
    }

    /// A private window's boosts, keyed by its store.
    private final class Window {
        var boosts: [String: SiteBoost] = [:]
    }
    private static let windows = NSMapTable<WKWebsiteDataStore, Window>.weakToStrongObjects()

    /// Host without "www.", web pages only.
    static func site(of url: URL?) -> String? {
        guard ["http", "https"].contains(url?.scheme?.lowercased() ?? "") else { return nil }
        return ContentBlocker.site(of: url)
    }

    /// A private window's copy once it changed, else the kept boosts.
    static func boost(forSite site: String, privateStore: WKWebsiteDataStore? = nil) -> SiteBoost {
        if let privateStore, let own = windows.object(forKey: privateStore)?.boosts[site] { return own }
        return all[site] ?? SiteBoost()
    }

    static func boost(for url: URL?, privateStore: WKWebsiteDataStore? = nil) -> SiteBoost {
        site(of: url).map { boost(forSite: $0, privateStore: privateStore) } ?? SiteBoost()
    }

    /// In a private window, for that window only.
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

    /// Returns false if the selector isn't plain. `name` is what the element said about itself, if anything.
    @discardableResult
    static func zap(_ selector: String, name: String? = nil, forSite site: String, privateStore: WKWebsiteDataStore? = nil) -> Bool {
        let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlainSelector(selector) else { return false }
        var boost = boost(forSite: site, privateStore: privateStore)
        guard !boost.zaps.contains(selector) else { return true }
        boost.zaps.append(selector)
        if let name = zapName(name) { boost.names[selector] = name }
        if boost.zaps.count > maxZaps {
            boost.zaps.removeFirst(boost.zaps.count - maxZaps)
            let kept = Set(boost.zaps)
            boost.names = boost.names.filter { kept.contains($0.key) }
        }
        set(boost, forSite: site, privateStore: privateStore)
        return true
    }

    nonisolated static let maxZapName = 40

    /// One line, trimmed, at most `maxZapName` characters; nil when nothing is left.
    nonisolated static func zapName(_ name: String?) -> String? {
        let words = (name ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        guard words.count > maxZapName else { return words }
        return words.prefix(maxZapName - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Restore All: unhides every zapped element on the site.
    static func restoreZaps(forSite site: String, privateStore: WKWebsiteDataStore? = nil) {
        var boost = boost(forSite: site, privateStore: privateStore)
        boost.zaps = []
        boost.names = [:]
        set(boost, forSite: site, privateStore: privateStore)
    }

    /// Shows one zapped element again; the rest keep their order.
    static func unzap(_ selector: String, forSite site: String, privateStore: WKWebsiteDataStore? = nil) {
        var boost = boost(forSite: site, privateStore: privateStore)
        guard let index = boost.zaps.firstIndex(of: selector) else { return }
        boost.zaps.remove(at: index)
        boost.names[selector] = nil
        set(boost, forSite: site, privateStore: privateStore)
    }

    /// Tooltip of the × on one zapped element's row, in Site Controls and Settings › Privacy › Sites.
    static let restoreTitle = String(localized: "Restore", comment: "Tooltip of the × on one zapped element's row in the site panel and in Settings › Privacy › Sites: shows that element again.")

    /// VoiceOver name of that ×, with the element's name, like “Restore div.banner”.
    static func restoreLabel(_ name: String) -> String {
        String(localized: "Restore \(name)", comment: "VoiceOver name of the × on one zapped element's row in the site panel and Settings › Privacy › Sites. The placeholder is the element's short name, like div.banner.")
    }

    /// A short name for a zapped element: the last step's tag with its id or first class ("#promo", "div.banner"),
    /// or, for a bare tag, the nearest named step before it ("#list › li").
    nonisolated static func label(forZap selector: String) -> String {
        let steps = selectorSteps(selector).map(stepName)
        guard let last = steps.last else { return selector }
        if !last.mark.isEmpty { return last.shown }
        let landmarks: Set = ["header", "nav", "main", "aside", "footer"]
        let before = steps.dropLast()
        if let named = before.last(where: { !$0.mark.isEmpty }) ?? before.last(where: { landmarks.contains($0.tag) }) {
            return "\(named.shown) › \(last.tag.isEmpty ? "*" : last.tag)"
        }
        return last.tag.isEmpty ? selector : last.tag
    }

    /// Compound selectors, split at combinators outside brackets; escapes stay as written.
    nonisolated static func selectorSteps(_ selector: String) -> [String] {
        var steps: [String] = [], current = "", depth = 0
        var chars = Array(selector)[...]
        while let c = chars.popFirst() {
            if c == "\\" {
                current.append(c)
                current += escapeTail(&chars)
                continue
            }
            if c == "(" || c == "[" { depth += 1 } else if c == ")" || c == "]" { depth = max(0, depth - 1) }
            if depth == 0, c.isWhitespace || ">+~".contains(c) {
                if !current.isEmpty { steps.append(current) }
                current = ""
                continue
            }
            current.append(c)
        }
        if !current.isEmpty { steps.append(current) }
        return steps
    }

    /// What follows a backslash: up to six hex digits and one space, or one character.
    private nonisolated static func escapeTail(_ chars: inout ArraySlice<Character>) -> String {
        var out = ""
        while out.count < 6, let c = chars.first, c.isHexDigit { out.append(c); chars.removeFirst() }
        if out.isEmpty { return chars.popFirst().map(String.init) ?? "" }
        if let c = chars.first, c == " " || c == "\t" || c == "\n" { out.append(c); chars.removeFirst() }
        return out
    }

    /// One step's tag, its id or first class, and how it's shown, unescaped.
    private nonisolated static func stepName(_ step: String) -> (tag: String, mark: String, shown: String) {
        var tag = "", id = "", firstClass = "", word = "", depth = 0
        var part: Character?
        func flush() {
            let name = unescaped(word)
            switch part {
            case nil: tag = name == "*" ? "" : name.lowercased()
            case "#": if id.isEmpty { id = name }
            case ".": if firstClass.isEmpty { firstClass = name }
            default: break
            }
            word = ""
        }
        var chars = Array(step)[...]
        while let c = chars.popFirst() {
            if depth > 0 {
                if c == "(" || c == "[" { depth += 1 } else if c == ")" || c == "]" { depth -= 1 }
                continue
            }
            if c == "\\" { word.append(c); word += escapeTail(&chars); continue }
            if "#.:[(".contains(c) {
                flush()
                part = c == "(" ? ":" : c
                if c == "[" || c == "(" { depth = 1 }
                continue
            }
            word.append(c)
        }
        flush()
        let mark = !id.isEmpty ? "#" + id : !firstClass.isEmpty ? "." + firstClass : ""
        return (tag, mark, id.isEmpty ? tag + mark : mark)
    }

    /// Forget in Settings › Privacy › Sites.
    static func forget(site: String) {
        var all = all
        all[site] = nil
        self.all = all
    }

    /// Settings › Privacy › Sites › Reset All.
    static func forgetAll() { all = [:] }

    /// Rejects anything that could close the rule, start another or comment out later ones. Backslashes are allowed
    /// since `CSS.escape` writes them.
    nonisolated static func isPlainSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count <= 512 else { return false }
        return !selector.contains { "{};@<\"'\n\r".contains($0) } && !selector.contains("/*") && !selector.contains("*/")
    }

    /// One rule per zap, so an invalid selector doesn't break the rest, then the site's CSS if it's plain.
    nonisolated static func css(for boost: SiteBoost) -> String {
        var parts = boost.zaps.filter(isPlainSelector).map { "\($0) { display: none !important; }" }
        if boost.hasStyle, styleProblem(boost.style) == nil { parts.append(boost.style) }
        return parts.joined(separator: "\n")
    }

    /// Empty turns it off. Returns false if the CSS can't be used.
    @discardableResult
    static func setStyle(_ css: String, forSite site: String, privateStore: WKWebsiteDataStore? = nil) -> Bool {
        guard styleProblem(css) == nil else { return false }
        var boost = boost(forSite: site, privateStore: privateStore)
        boost.style = css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : css
        set(boost, forSite: site, privateStore: privateStore)
        return true
    }

    /// In bytes.
    nonisolated static let maxStyle = 100_000

    /// Nil for plain CSS. Read as a browser would, with comments removed and escapes (`\75 rl(`) undone: no tags, no
    /// @import, and url(), src() or image-set() only for data: or a #fragment.
    nonisolated static func styleProblem(_ css: String) -> StyleProblem? {
        guard css.utf8.count <= maxStyle else { return .tooLong }
        let plain = unescaped(withoutComments(css)).lowercased()
        if plain.range(of: #"<\s*/?\s*[a-z!]"#, options: .regularExpression) != nil { return .tag }
        if plain.contains("@import") { return .loads }
        // Every address-taking function must get inline content.
        var rest = plain[...]
        while let call = rest.range(of: #"(url|src|image-set|-webkit-image-set|image|cross-fade|-webkit-cross-fade)\s*\("#, options: .regularExpression) {
            let name = plain[call].prefix { $0.isLetter || $0 == "-" }
            let argument = rest[call.upperBound...].drop { $0.isWhitespace || $0 == "\"" || $0 == "'" }
            if name == "url" || name == "src" {
                if !(argument.hasPrefix("data:") || argument.hasPrefix("#")) { return .loads }
            } else {
                // Strings in an address list are addresses too.
                let inside = rest[call.upperBound...].prefix { $0 != ")" }
                if inside.contains("\"") || inside.contains("'") { return .loads }
            }
            rest = rest[call.upperBound...]
        }
        return nil
    }

    /// Replaces each comment with a space, as the browser does (`u/**/rl` is two words).
    nonisolated static func withoutComments(_ css: String) -> String {
        var out = "", rest = css[...]
        while let start = rest.range(of: "/*") {
            out += rest[..<start.lowerBound] + " "
            guard let end = rest[start.upperBound...].range(of: "*/") else { return out }
            rest = rest[end.upperBound...]
        }
        return out + rest
    }

    /// A backslash plus up to six hex digits (and one trailing space) is that code point; a backslash plus anything
    /// else is that character.
    nonisolated static func unescaped(_ css: String) -> String {
        var out = "", chars = Array(css.unicodeScalars), i = 0
        while i < chars.count {
            guard chars[i] == "\\", i + 1 < chars.count else { out.unicodeScalars.append(chars[i]); i += 1; continue }
            var j = i + 1, hex = ""
            while j < chars.count, hex.count < 6, chars[j].properties.isASCIIHexDigit { hex.unicodeScalars.append(chars[j]); j += 1 }
            if hex.isEmpty {
                out.unicodeScalars.append(chars[j])
                i = j + 1
            } else {
                out.unicodeScalars.append(UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) ?? "\u{FFFD}")
                if j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" { j += 1 }
                i = j
            }
        }
        return out
    }
}

/// Injects boosts as a style sheet at document start, main frame only, like the ad blocker's cosmetic rules
/// (`PageFilters.styleSource`). Edits apply in place.
enum PageBoosts {
    /// Isolated from the page's scripts.
    static let world = WKContentWorld.world(name: "ZigzagBoosts")
    private static let mark = "/* zigzag boosts */"
    private static let styleName = "__zigzagBoost"

    static func isOurs(_ script: WKUserScript) -> Bool { (script.source as NSString).hasPrefix(mark) }

    /// Sets up a web view's boosts before it loads `url`; none for error pages.
    static func prepare(_ webView: WKWebView, for url: URL?, privateStore: WKWebsiteDataStore?, errorPage: Bool) {
        let controller = webView.configuration.userContentController
        OwnScripts.remove(from: controller, where: isOurs)
        guard !errorPage, let site = SiteBoosts.site(of: url) else { return }
        let css = SiteBoosts.css(for: SiteBoosts.boost(forSite: site, privateStore: privateStore))
        guard !css.isEmpty else { return }
        controller.addUserScript(WKUserScript(source: source(css: css, site: site), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }

    /// Previews `boost` without saving (Edit Style while typing).
    static func show(_ boost: SiteBoost, site: String, in tab: Tab) {
        guard let webView = tab.webView, !ErrorPage.pending.contains(webView), SiteBoosts.site(of: webView.url) == site else { return }
        webView.runOwnScript(source(css: SiteBoosts.css(for: boost), site: site), world: world)
    }

    /// Applies now and on the next load.
    static func refresh(_ tab: Tab) {
        guard let webView = tab.webView else { return }
        let url = webView.url ?? tab.url
        prepare(webView, for: url, privateStore: tab.privateStore, errorPage: ErrorPage.pending.contains(webView))
        guard let site = SiteBoosts.site(of: url), !ErrorPage.pending.contains(webView) else { return }
        let css = SiteBoosts.css(for: SiteBoosts.boost(forSite: site, privateStore: tab.privateStore))
        webView.runOwnScript(source(css: css, site: site), world: world)
    }

    /// Applies a kept change to every open tab of `site` outside private windows (Settings › Privacy › Sites).
    static func refreshOpenTabs(site: String) {
        for tab in WindowManager.shared.openTabs where tab.privateStore == nil && SiteBoosts.site(of: tab.webView?.url ?? tab.url) == site {
            refresh(tab)
        }
    }

    /// Injects `css` under one name so the next change replaces it.
    static func source(css: String, site: String) -> String {
        "\(mark)\nif (\(siteCheck(site))) {\n\(PageFilters.styleSource(css, keptAs: styleName))\n}"
    }

    /// Matches `site` as `ContentBlocker.site` names it.
    private static func siteCheck(_ site: String) -> String {
        "location.hostname.toLowerCase().replace(/\\.$/, '').replace(/^www\\./, '') === \(PageFilters.jsString(site))"
    }

    // MARK: Picking

    /// Builds a stable selector: a stable id, else the tag with up to two non-generated classes and its nth-of-type,
    /// up to `maxDepth` parents. Elements in an SVG resolve to the SVG. Never html or body. `ZigzagBoostName` reads
    /// what the element says about itself: its aria-label, title or alt, else its heading's or its own first line.
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
          // Start from a named element (a class or a landmark), not a bare tag and position.
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
    window.ZigzagBoostName = (picked) => {
      if (!picked || picked.nodeType !== 1) return null;
      const element = (picked.closest && picked.closest('svg')) || picked;
      const clean = (text) => (text || '').replace(/\s+/g, ' ').trim();
      const said = ['aria-label', 'title', 'alt'].map((name) => clean(element.getAttribute(name))).find(Boolean);
      if (said) return said;
      const line = (node) => (node.innerText || '').split('\n').map(clean).find(Boolean) || '';
      const heading = element.matches('h1, h2, h3, h4, h5, h6') ? element : element.querySelector('h1, h2, h3, h4, h5, h6, [role="heading"]');
      return (heading && line(heading)) || line(element) || null;
    };
    """#

    /// Outlines the hovered element in `accent` with its tag and size; a click zaps it and the page never sees the
    /// click. `stop()` removes every trace.
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
            post(selector ? { zap: selector, name: window.ZigzagBoostName(picked) } : { failed: true });
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

/// Zap Element from Site Controls: picks elements to hide until Esc, a click outside the page, a shortcut or
/// navigation. One page at a time.
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
        // Esc, shortcuts and clicks outside the page end it from Zigzag's side too.
        picker.monitor = TouchPress.addMonitor(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak picker] event in
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

    /// Removes the picker so the page gets clicks again.
    func stop() {
        if let monitor { TouchPress.removeMonitor(monitor) }
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
            Self.zap(selector, name: body["name"] as? String, site: site, in: tab)
        } else if body["failed"] != nil, let controller = self.controller {
            Toast.show(String(localized: "That can’t be zapped. Try something around it.", comment: "Toast when the element clicked with Zap Element can't be named well enough to hide on later visits."),
                       symbol: "scope", in: controller)
        }
    }

    /// Hides `selector` on the site now and on later visits (in a private window, only there).
    static func zap(_ selector: String, name: String? = nil, site: String, in tab: Tab) {
        guard SiteBoosts.zap(selector, name: name, forSite: site, privateStore: tab.privateStore) else { return }
        PageBoosts.refresh(tab)
    }

    /// Shows `selector` again on the site now and on later visits (in a private window, only there).
    static func unzap(_ selector: String, site: String, in tab: Tab, refresh: @MainActor (Tab) -> Void = PageBoosts.refresh) {
        SiteBoosts.unzap(selector, forSite: site, privateStore: tab.privateStore)
        refresh(tab)
    }

    #if DEBUG
    /// zap <css selector>: zaps the first match in the front page, as a click would.
    static func debugZap(_ query: String, in tab: Tab) {
        guard let webView = tab.webView, let site = SiteBoosts.site(of: webView.url) else { debugLog("zap: no site"); return }
        let picked = "document.querySelector(\(PageFilters.jsString(query)))"
        let script = PageBoosts.selectorSource + "\n[window.ZigzagBoostSelector(\(picked)), window.ZigzagBoostName(\(picked))]"
        webView.runOwnScript(script, world: PageBoosts.world) { result in
            guard case .success(let value) = result, let pair = value as? [Any], let selector = pair.first as? String else { debugLog("zap \(query): no selector"); return }
            debugLog("zap \(query) => \(selector)")
            zap(selector, name: pair.last as? String, site: site, in: tab)
        }
    }

    /// zaphover <css selector>: outlines the first match, as hovering would.
    static func debugHover(_ query: String) {
        current?.webView?.runOwnScript("window.__zigzagZap && window.__zigzagZap.show(document.querySelector(\(PageFilters.jsString(query))))", world: PageBoosts.world)
    }
    #endif
}
