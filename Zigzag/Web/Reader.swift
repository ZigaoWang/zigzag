import AppKit
import WebKit

/// Reader: an article as clean, readable text. Mozilla's Readability (the engine behind Firefox's reader view,
/// bundled under its Apache licence) finds the article in Zigzag's own script world, where the page can't see
/// or interfere with it. The result is shown in a separate web view with JavaScript off, over the page,
/// which stays loaded underneath.
enum Reader {
    /// Readability itself plus a small helper that says whether a page looks like an article.
    static var scripts: [WKUserScript] {
        guard let readability = resource("Readability"), let readerable = resource("Readability-readerable") else { return [] }
        let check = """
        window.__zigzagReader = {
          // Readability's defaults pass over short articles (three good paragraphs); Safari offers Reader for those too.
          isArticle: () => { try { return isProbablyReaderable(document, { minScore: 10, minContentLength: 100 }); } catch (e) { return false; } },
          // Done ahead, while the page is idle, so opening Reader is instant. Kept for this address only.
          prepare: () => {
            const r = window.__zigzagReader;
            if (r.cached && r.cached.url === location.href) return;
            const run = () => { try { r.cached = { url: location.href, json: r.parse() }; } catch (e) {} };
            (window.requestIdleCallback || ((f) => setTimeout(f, 300)))(run, { timeout: 3000 });
          },
          take: () => {
            const r = window.__zigzagReader;
            if (r.cached && r.cached.url === location.href && r.cached.json) return r.cached.json;
            return r.parse();
          },
          parse: () => {
            try {
              const copy = document.cloneNode(true);
              // Wikipedia and other MediaWiki sites: the fact box, notes about other pages, edit links and footnote
              // markers are page furniture, and would otherwise open the article.
              if (copy.querySelector('.mw-parser-output')) {
                copy.querySelectorAll('.infobox, .navbox, .vertical-navbox, .sidebar, .metadata, .ambox, .hatnote, .shortdescription, ' +
                  '.mw-editsection, sup.reference, .mw-jump-link, #toc, .toc, .noprint, .mw-empty-elt').forEach(el => el.remove());
                // The little ⓘ after a pronunciation plays a sound on the page; in reading it's just a mark.
                copy.querySelectorAll('a, span, sup').forEach(el => { if (el.childElementCount === 0 && el.textContent.trim() === 'ⓘ') el.remove(); });
              }
              // Icons and spacers aren't pictures; big pictures get the full measure.
              copy.querySelectorAll('img').forEach(img => {
                const w = parseInt(img.getAttribute('width') || '0', 10), h = parseInt(img.getAttribute('height') || '0', 10);
                if ((w && w < 48) || (h && h < 48)) img.remove(); else if (w >= 480) img.classList.add('wide'); else if (w) img.classList.add('inset');
              });
              // What the site calls itself, when it says so briefly; otherwise its address. Never a company's legal name.
              const siteName = () => {
                const host = location.hostname.replace(/^(www|m)\\./, '');
                if (/(^|\\.)wikipedia\\.org$/.test(host)) return 'Wikipedia';
                const own = (meta('og:site_name') || '').trim();
                return own && own.length <= 28 && !/\\b(inc|llc|ltd|foundation|corporation)\\b/i.test(own) ? own : host;
              };
              const meta = n => (document.querySelector(`meta[property="${n}"], meta[name="${n}"]`) || {}).content || '';
              const article = new Readability(copy, { classesToPreserve: ['wide', 'inset', 'lead'] }).parse();
              if (!article) return null;
              const body = document.createElement('div');
              body.innerHTML = article.content || '';
              // The opening paragraph gets the drop cap: the first one that's a real paragraph, not a dateline.
              const lead = [...body.querySelectorAll('p')].find(p => p.textContent.trim().length > 120 && !p.closest('figure, blockquote, li, table'));
              if (lead) lead.classList.add('lead');
              // The site's own summary, unless it's just the opening paragraph again.
              const squash = t => (t || '').replace(/\\s+/g, ' ').trim().toLowerCase();
              let dek = squash(article.excerpt) ? (article.excerpt || '').replace(/\\s+/g, ' ').trim() : '';
              if (!dek || dek.length > 320 || (lead && squash(lead.textContent).startsWith(squash(dek).slice(0, 60)))) dek = '';
              // A lead picture from the page's own card, unless the article already opens with it.
              let image = meta('og:image') || meta('twitter:image');
              try { image = image ? new URL(image, location.href).href : ''; } catch (e) { image = ''; }
              const firstImage = body.querySelector('img');
              if (image && firstImage && body.innerHTML.indexOf(firstImage.outerHTML) < 400) image = '';
              if (!/^https:/.test(image)) image = '';
              // The address says where it's from better than a publisher's legal name; a long byline is metadata, not an author.
              const byline = (article.byline || '').trim();
              return JSON.stringify({ title: article.title || document.title, byline: byline.length <= 60 ? byline : '',
                site: siteName(),
                content: body.innerHTML, length: article.length || 0, lang: article.lang || document.documentElement.lang || '',
                dek: dek, image: image, url: location.href });
            } catch (e) { return null; }
          }
        };
        """
        return [WKUserScript(source: readability + "\n" + readerable + "\n" + check, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)]
    }

    private static func resource(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Reads the article ahead of time, while the page is idle, and fetches its lead picture, so Reader opens
    /// complete instead of with a gap that fills in later.
    static func prepare(_ webView: WKWebView) {
        webView.evaluateJavaScript("window.__zigzagReader && window.__zigzagReader.prepare(); 0", in: nil, in: .defaultClient, completionHandler: nil)
        let script = "(document.querySelector('meta[property=\"og:image\"]')||document.querySelector('meta[name=\"twitter:image\"]')||{}).content || ''"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            guard case .success(let value) = result, let text = value as? String, let url = URL(string: text, relativeTo: webView.url)?.absoluteURL,
                  url.scheme == "https", leadPictures[url.absoluteString] == nil else { return }
            Task {
                guard let (data, response) = try? await URLSession.shared.data(from: url), data.count < 3_000_000,
                      let type = (response as? HTTPURLResponse)?.mimeType, type.hasPrefix("image/") else { return }
                leadPictures[url.absoluteString] = "data:\(type);base64," + data.base64EncodedString()
                if leadPictures.count > 12 { leadPictures.removeValue(forKey: leadPictures.keys.first!) }
            }
        }
    }

    /// Lead pictures fetched ahead, by address, as data the reading page can show at once.
    private static var leadPictures: [String: String] = [:]

    /// Whether the page in a web view looks like an article.
    static func isArticle(_ webView: WKWebView) async -> Bool {
        let result = try? await webView.evaluateJavaScript("window.__zigzagReader ? window.__zigzagReader.isArticle() : false", in: nil, contentWorld: .defaultClient)
        return (result as? Bool) ?? false
    }

    struct Article: Decodable {
        let title: String
        let byline: String
        let site: String
        let content: String
        let length: Int
        let lang: String
        var dek: String? = nil
        var image: String? = nil
        var url: String? = nil
    }

    static func article(in webView: WKWebView) async -> Article? {
        guard let json = try? await webView.evaluateJavaScript("window.__zigzagReader ? window.__zigzagReader.take() : null", in: nil, contentWorld: .defaultClient) as? String,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Article.self, from: data)
    }

    /// How you like to read, remembered: text size, typeface and colours.
    struct Preferences {
        enum Face: String, CaseIterable { case serif, sans }
        enum Theme: String, CaseIterable { case auto, light, sepia, dark }
        /// How wide the column of text runs. Medium is a comfortable book's measure; wide fills more of a big window.
        enum Width: String, CaseIterable {
            case narrow, medium, wide
            var measure: String { switch self { case .narrow: "34em"; case .medium: "40em"; case .wide: "48em" } }
        }
        static let sizes = 13...32
        var size: Int
        var face: Face
        var theme: Theme
        var width: Width = .medium

        static var saved: Preferences {
            get {
                let d = UserDefaults.standard
                let size = d.integer(forKey: "ReaderSize")
                return Preferences(size: sizes.contains(size) ? size : 19,
                                   face: Face(rawValue: d.string(forKey: "ReaderFace") ?? "") ?? .sans,
                                   theme: Theme(rawValue: d.string(forKey: "ReaderTheme") ?? "") ?? .auto,
                                   width: Width(rawValue: d.string(forKey: "ReaderWidth") ?? "") ?? .medium)
            }
            set {
                let d = UserDefaults.standard
                d.set(newValue.size, forKey: "ReaderSize")
                d.set(newValue.face.rawValue, forKey: "ReaderFace")
                d.set(newValue.theme.rawValue, forKey: "ReaderTheme")
                d.set(newValue.width.rawValue, forKey: "ReaderWidth")
            }
        }

        /// Applies these to an open reading page, without reloading it (and losing your place).
        var script: String {
            "document.documentElement.dataset.theme='\(theme.rawValue)';document.documentElement.dataset.face='\(face.rawValue)';" +
            "document.documentElement.style.setProperty('--size','\(size)px');" +
            "document.documentElement.style.setProperty('--measure','\(width.measure)');"
        }
    }

    /// The reading page, set like a well-made magazine: a masthead (where it's from, the title, the site's own
    /// summary, who wrote it), the lead picture, then the text at a book's measure. On a wide window small pictures
    /// sit in a margin beside the text with their captions, and wide ones span both; narrower, it's one column.
    static func html(for article: Article, preferences: Preferences = .saved) -> String {
        // A credit that names no one ("Contributors to Wikimedia projects") says nothing; leave it out.
        let author = article.byline.lowercased().contains("contributors") ? "" : article.byline
        // Where it's from, and who wrote it when the page says.
        let meta = escape(author.isEmpty ? article.site : "\(article.site), by \(author)")
        let dek = (article.dek ?? "").isEmpty ? "" : "<p class=\"dek\">\(escape(article.dek ?? ""))</p>"
        let heroSource = article.image.map { leadPictures[$0] ?? $0 } ?? ""
        let hero = heroSource.isEmpty ? "" : "<figure class=\"hero\"><img src=\"\(escape(heroSource))\" alt=\"\"></figure>"
        let source = (article.url ?? "").isEmpty ? "" :
            "<footer class=\"end\"><a href=\"\(escape(article.url ?? ""))\">Read the original on \(escape(article.site))</a></footer>"
        return """
        <!doctype html><html lang="\(escape(article.lang))" data-theme="\(preferences.theme.rawValue)" data-face="\(preferences.face.rawValue)" style="--size: \(preferences.size)px; --measure: \(preferences.width.measure)">
        <head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'; font-src *">
        <title>\(escape(article.title))</title>
        <style>
        :root { --text: #1d1d1f; --soft: #6e6e73; --faint: rgba(0,0,0,.42); --rule: rgba(0,0,0,.1); --bg: #fbfaf7; --link: #2f5d9a;
                --code: rgba(0,0,0,.05); --select: rgba(47,93,154,.18);
                --serif: "New York", ui-serif, Georgia, serif; --sans: -apple-system, "SF Pro Text", system-ui, sans-serif;
                --measure: 32em; --margin: 12em; --gap: 2em; }
        :root[data-theme="sepia"] { --text: #3f3226; --soft: #86705a; --faint: rgba(70,45,20,.45); --rule: rgba(90,60,20,.16); --bg: #f4ecdd;
                --link: #8a5326; --code: rgba(90,60,20,.07); --select: rgba(138,83,38,.2); }
        :root[data-theme="dark"] { --text: #e8e6e1; --soft: #9d9b97; --faint: rgba(255,255,255,.4); --rule: rgba(255,255,255,.12); --bg: #161618;
                --link: #9cbcec; --code: rgba(255,255,255,.07); --select: rgba(156,188,236,.25); color-scheme: dark; }
        @media (prefers-color-scheme: dark) {
          :root[data-theme="auto"] { --text: #e8e6e1; --soft: #9d9b97; --faint: rgba(255,255,255,.4); --rule: rgba(255,255,255,.12); --bg: #161618;
                --link: #9cbcec; --code: rgba(255,255,255,.07); --select: rgba(156,188,236,.25); color-scheme: dark; }
        }
        html { background: var(--bg); transition: background .25s ease; }
        ::selection { background: var(--select); }
        body { margin: 0; padding: 112px 48px 160px; color: var(--text); font-family: var(--serif); font-size: var(--size); line-height: 1.65;
               -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; font-kerning: normal; hanging-punctuation: first;
               transition: color .25s ease; animation: rise .5s cubic-bezier(.2,.85,.25,1) both; }
        :root[data-face="sans"] body { font-family: var(--sans); line-height: 1.6; letter-spacing: -0.003em; }
        @keyframes rise { from { transform: translateY(14px); } to { transform: none; } }
        @media (prefers-reduced-motion: reduce) { body { animation: none; } html, body { transition: none; } }

        /* One centered column at a book's measure: nothing to the side, nothing competing. */
        main { max-width: var(--measure, 40em); margin: 0 auto; transition: max-width .25s ease; }

        /* The title page: the headline, the site's summary, then where it's from in small type. */
        header { margin: 0 0 3em; }
        h1.title { font-family: var(--serif); font-size: 2.05em; font-weight: 600; line-height: 1.14; letter-spacing: -0.012em;
                   margin: 0; text-wrap: balance; }
        :root[data-face="sans"] h1.title { font-family: var(--sans); font-weight: 700; letter-spacing: -0.022em; }
        .dek { font-size: 1.12em; line-height: 1.45; color: var(--soft); margin: .6em 0 0; text-wrap: pretty; }
        .meta { font: 13px/1.4 var(--sans); color: var(--soft); margin: 1.4em 0 0; }
        .meta .dot { margin: 0 .5em; color: var(--faint); }
        figure.hero { margin: 2.2em 0 0; }
        /* Its room is kept from the start, so the text never jumps when the picture arrives. */
        figure.hero { aspect-ratio: 16 / 9; max-height: 22em; width: 100%; border-radius: 8px; overflow: hidden; background: var(--code); }
        figure.hero img { width: 100%; height: 100%; max-height: none; object-fit: cover; border-radius: 0; margin: 0; }

        h1, h2, h3, h4 { line-height: 1.25; margin: 2em 0 .5em; letter-spacing: -0.01em; text-wrap: balance; font-weight: 600; }
        h2 { font-size: 1.3em; } h3 { font-size: 1.08em; } h4 { font-size: 1em; }
        h3, h4 { font-family: var(--sans); letter-spacing: -0.004em; }
        p, ul, ol, blockquote, figure, pre, table, dl { margin: 0 0 1.05em; }
        p { text-wrap: pretty; }
        li { margin: .3em 0; } ul, ol { padding-left: 1.15em; } li::marker { color: var(--soft); }

        /* Links read as part of the sentence; the underline is barely there until you point at it. */
        a { color: inherit; text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: .22em;
            text-decoration-color: color-mix(in srgb, var(--text) 22%, transparent); transition: color .15s, text-decoration-color .15s; }
        a:hover { color: var(--link); text-decoration-color: currentColor; }
        h1 a, h2 a, h3 a, figcaption a { text-decoration: none; }

        /* Pictures sit in the column at their own size, centered; captions small and quiet beneath. */
        img, video, svg, picture { display: block; max-width: 100%; height: auto; margin: 1.8em auto; border-radius: 6px; }
        figure { margin: 2em 0; text-align: center; } figure img, figure picture, figure video { margin: 0 auto; }
        img.wide, figure:has(img.wide) img { width: 100%; }
        /* Picture galleries come as lists: no bullets, just the pictures. */
        ul:has(> li img), ol:has(> li img) { list-style: none; padding: 0; }
        li:has(img) { margin: 0; } li:has(img)::marker { content: none; }
        figcaption { font: 13px/1.5 var(--sans); color: var(--soft); margin: 10px auto 0; max-width: 30em; text-wrap: pretty; }

        blockquote { margin: 1.6em 0; padding: 0 0 0 1em; border-left: 2px solid var(--rule); color: var(--soft); }
        blockquote p:last-child { margin-bottom: 0; }
        pre, code, kbd { font: .84em/1.55 ui-monospace, "SF Mono", Menlo, monospace; }
        code { background: var(--code); padding: .12em .36em; border-radius: 4px; }
        pre { overflow-x: auto; padding: 16px 18px; border-radius: 8px; background: var(--code); } pre code { background: none; padding: 0; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2.4em auto; width: 4em; }
        table { border-collapse: collapse; width: 100%; font: 14px/1.5 var(--sans); margin: 1.6em 0; }
        td, th { border-bottom: 1px solid var(--rule); padding: 8px 12px 8px 0; text-align: left; vertical-align: top; }
        th { font-weight: 600; }
        sup, sub { line-height: 0; font-size: .68em; }

        .end { margin-top: 3em; padding-top: 1.2em; border-top: 1px solid var(--rule); font: 13px/1.4 var(--sans); color: var(--soft); }
        .end a { text-decoration-color: var(--rule); }

        /* Leftovers from the page that don't belong in reading. */
        button, input, select, textarea, form, iframe, nav, aside, [role="button"], [aria-hidden="true"] { display: none !important; }
        </style></head><body><main>
        <header>
        <h1 class="title">\(escape(article.title))</h1>
        \(dek)
        <p class="meta">\(meta)</p>
        \(hero)
        </header>
        \(article.content)
        \(source)
        </main></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// The reading surface shown over a page card, with its controls at the top right.
final class ReaderView: NSView {
    let webView: WKWebView
    var onClose: (() -> Void)?
    var onOpenLink: ((URL) -> Void)?
    /// Shift-click: a look at the link in Peek, over the article. ⌘-click: a tab in the background.
    var onPeekLink: ((URL) -> Void)?
    var onBackgroundLink: ((URL) -> Void)?
    var onForegroundLink: ((URL) -> Void)?
    private let controls = ReaderControls()

    override init(frame: NSRect) {
        webView = WKWebView(frame: .zero, configuration: Self.configuration())

        super.init(frame: frame)
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        addSubview(controls)
        controls.onChange = { [weak self] preferences in
            Reader.Preferences.saved = preferences
            // The page's own scripts are off; this runs in Zigzag's world, so the change is instant.
            self?.webView.evaluateJavaScript(preferences.script, in: nil, in: .defaultClient, completionHandler: nil)
        }
        controls.onClose = { [weak self] in self?.onClose?() }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// ⌘+ and ⌘−: the text a size bigger or smaller (0 back to the usual), kept for every article. Returns the new size.
    @discardableResult
    func stepTextSize(_ delta: Int) -> Int {
        var preferences = controls.preferences
        preferences.size = delta == 0 ? 19 : min(max(preferences.size + delta * 2, Reader.Preferences.sizes.lowerBound), Reader.Preferences.sizes.upperBound)
        controls.preferences = preferences
        Reader.Preferences.saved = preferences
        webView.evaluateJavaScript(preferences.script, in: nil, in: .defaultClient, completionHandler: nil)
        return preferences.size
    }

    /// One private store for every reading page: a fresh one each time starts a new web process, which is most of
    /// a second before anything shows. Scripts stay off.
    private static let store = WKWebsiteDataStore.nonPersistent()
    private static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = store
        return configuration
    }

    /// A reading page kept loaded in the background, so the first Reader of the session is as quick as the rest.
    private static var warm: WKWebView?
    static func prewarm() {
        guard warm == nil else { return }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration())
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        warm = view
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        let size = controls.barSize
        controls.frame = NSRect(x: bounds.width - size.width - Tokens.Space.x4, y: Tokens.Space.x4, width: size.width, height: size.height)
    }

    func show(_ article: Reader.Article, from url: URL) {
        webView.navigationDelegate = self
        webView.loadHTMLString(Reader.html(for: article), baseURL: url)
        controls.preferences = .saved
        controls.present(arrival: .fade)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

}

/// Two quiet buttons at the top right: Aa for how it reads, and done. Aa opens a small panel underneath.
final class ReaderControls: FloatingPanelView {
    var onChange: ((Reader.Preferences) -> Void)?
    var onClose: (() -> Void)?
    var preferences = Reader.Preferences.saved { didSet { options.preferences = preferences } }

    private let style = IconButton(symbol: "textformat.size", toolTip: "Text and Colors")
    private let close = IconButton(symbol: "xmark", toolTip: "Close Reader (esc)")
    private let options = ReaderOptions()
    private var monitor: Any?

    /// Buttons with the same small gap all round: top, bottom and sides.
    static let inset: CGFloat = 4
    static var height: CGFloat { Tokens.Metric.iconButton + inset * 2 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        radius = Self.height / 2
        [style, close].forEach { addSubview($0) }
        style.onClick = { [weak self] _ in self?.toggleOptions() }
        close.onClick = { [weak self] _ in self?.onClose?() }
        options.onChange = { [weak self] preferences in
            self?.preferences = preferences
            self?.onChange?(preferences)
        }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    var barSize: NSSize {
        NSSize(width: Tokens.Metric.iconButton * 2 + 2 + Self.inset * 2, height: Self.height)
    }

    private func layoutContent() {
        let b = Tokens.Metric.iconButton, h = bounds.height
        style.frame = NSRect(x: Self.inset, y: (h - b) / 2, width: b, height: b)
        close.frame = NSRect(x: style.frame.maxX + 2, y: (h - b) / 2, width: b, height: b)
    }

    func toggleOptions() {
        if options.superview != nil { hideOptions(); return }
        guard let host = superview else { return }
        options.preferences = preferences
        let size = options.panelSize
        options.frame = NSRect(x: frame.maxX - size.width, y: frame.maxY + 6, width: size.width, height: size.height)
        host.addSubview(options)
        options.present()
        style.isSelected = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown { if event.keyCode == 53 { self.hideOptions(); return nil }; return event }
            let inOptions = self.options.bounds.contains(self.options.convert(event.locationInWindow, from: nil))
            let onStyle = self.style.bounds.contains(self.style.convert(event.locationInWindow, from: nil))
            if !inOptions && !onStyle { self.hideOptions() }
            return event
        }
    }

    private func hideOptions() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        style.isSelected = false
        options.dismiss()
    }

    override func removeFromSuperview() {
        if options.superview != nil { hideOptions() }
        super.removeFromSuperview()
    }
}

/// How it reads: size, typeface, colours. Three even rows, each one control across the panel.
private final class ReaderOptions: FloatingPanelView {
    var onChange: ((Reader.Preferences) -> Void)?
    var preferences = Reader.Preferences.saved { didSet { refresh() } }

    private let size = ReaderSegments([.text("A", .systemFont(ofSize: 13, weight: .semibold)), .text("A", .systemFont(ofSize: 19, weight: .semibold))],
                                      toggles: false, accessibilityNames: ["Smaller Text", "Larger Text"])
    private let face = ReaderSegments([.text("Serif", NSFont(descriptor: NSFont.systemFont(ofSize: 14, weight: .medium).fontDescriptor.withDesign(.serif)!, size: 14)!),
                                       .text("Sans", .systemFont(ofSize: 14, weight: .medium))], toggles: true, accessibilityNames: ["Serif", "Sans Serif"])
    private let measure = ReaderSegments([.text("Narrow", .systemFont(ofSize: 13, weight: .medium)), .text("Medium", .systemFont(ofSize: 13, weight: .medium)),
                                          .text("Wide", .systemFont(ofSize: 13, weight: .medium))], toggles: true,
                                         accessibilityNames: ["Narrow Column", "Medium Column", "Wide Column"])
    private var tiles: [(Reader.Preferences.Theme, ThemeTile)] = []

    static let width: CGFloat = 252
    private static let pad: CGFloat = 10, row: CGFloat = 36, gap: CGFloat = 8
    var panelSize: NSSize { NSSize(width: Self.width, height: Self.pad * 2 + Self.row * 4 + Self.gap * 3) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        radius = 16
        [size, face, measure].forEach { addSubview($0) }
        for theme in Reader.Preferences.Theme.allCases {
            let tile = ThemeTile(theme: theme)
            tile.onClick = { [weak self] _ in self?.change { $0.theme = theme } }
            addSubview(tile)
            tiles.append((theme, tile))
        }
        size.onPick = { [weak self] index in
            self?.change { $0.size = index == 0 ? max(Reader.Preferences.sizes.lowerBound, $0.size - 1) : min(Reader.Preferences.sizes.upperBound, $0.size + 1) }
        }
        face.onPick = { [weak self] index in self?.change { $0.face = index == 0 ? .serif : .sans } }
        measure.onPick = { [weak self] index in self?.change { $0.width = Reader.Preferences.Width.allCases[index] } }
        onLayout = { [weak self] in self?.layoutContent() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func change(_ edit: (inout Reader.Preferences) -> Void) {
        var next = preferences
        edit(&next)
        preferences = next
        onChange?(next)
    }

    private func refresh() {
        face.selected = preferences.face == .serif ? 0 : 1
        measure.selected = Reader.Preferences.Width.allCases.firstIndex(of: preferences.width) ?? 1
        size.setEnabled(0, preferences.size > Reader.Preferences.sizes.lowerBound)
        size.setEnabled(1, preferences.size < Reader.Preferences.sizes.upperBound)
        for (theme, tile) in tiles { tile.isSelected = theme == preferences.theme }
    }

    private func layoutContent() {
        let pad = Self.pad, inner = bounds.width - pad * 2
        size.frame = NSRect(x: pad, y: pad, width: inner, height: Self.row)
        face.frame = NSRect(x: pad, y: size.frame.maxY + Self.gap, width: inner, height: Self.row)
        measure.frame = NSRect(x: pad, y: face.frame.maxY + Self.gap, width: inner, height: Self.row)
        let y = measure.frame.maxY + Self.gap, gap: CGFloat = 6
        let w = (inner - gap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)
        for (i, (_, tile)) in tiles.enumerated() {
            tile.frame = NSRect(x: pad + CGFloat(i) * (w + gap), y: y, width: w, height: Self.row)
        }
    }
}

/// A row of equal halves in one soft field: either a choice (one lit, sliding between) or a pair of buttons.
private final class ReaderSegments: NSView {
    enum Item { case text(String, NSFont) }
    var onPick: ((Int) -> Void)?
    var selected = 0 { didSet { if toggles { moveHighlight(animated: window != nil && oldValue != selected) } } }
    private let toggles: Bool
    private let highlight = ColorView(color: Tokens.Color.selectedFill)
    private var segments: [InteractiveView] = []
    private var labels: [Label] = []
    private let divider = ColorView(color: Tokens.Color.separator)

    /// What each segment does, for VoiceOver.
    var accessibilityNames: [String]

    init(_ items: [Item], toggles: Bool, accessibilityNames: [String] = []) {
        self.toggles = toggles
        self.accessibilityNames = accessibilityNames
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = cgColor(Tokens.Color.fieldFill)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 8
        highlight.layer?.cornerCurve = .continuous
        highlight.isHidden = !toggles
        addSubview(highlight)
        divider.isHidden = toggles
        addSubview(divider)
        for (i, item) in items.enumerated() {
            let segment = InteractiveView()
            segment.wantsLayer = true
            segment.layer?.cornerRadius = 8
            segment.layer?.cornerCurve = .continuous
            guard case .text(let text, let font) = item else { continue }
            let label = Label(text, font: font, color: Tokens.Color.textPrimary)
            label.alignment = .center
            segment.addSubview(label)
            // Two "A"s read as nothing to VoiceOver: each says what it does.
            segment.setAccessibilityRole(toggles ? .radioButton : .button)
            segment.setAccessibilityLabel(accessibilityNames.indices.contains(i) ? accessibilityNames[i] : text)
            segment.onClick = { [weak self] _ in
                guard let self, segment.isEnabled else { return }
                if self.toggles { self.selected = i }
                self.onPick?(i)
            }
            segment.hoverChanged = { [weak segment, weak self] hovering in
                guard let segment, let self, !self.toggles || self.selected != i else { return }
                segment.layer?.backgroundColor = hovering && segment.isEnabled ? self.cgColor(Tokens.Color.hoverFill) : nil
            }
            addSubview(segment)
            segments.append(segment)
            labels.append(label)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func setEnabled(_ index: Int, _ enabled: Bool) {
        guard segments.indices.contains(index) else { return }
        segments[index].isEnabled = enabled
        labels[index].textColor = enabled ? Tokens.Color.textPrimary : Tokens.Color.textTertiary
        if !enabled { segments[index].layer?.backgroundColor = nil }
    }

    private func frame(of index: Int) -> NSRect {
        let inset: CGFloat = 3, w = (bounds.width - inset * 2) / CGFloat(max(segments.count, 1))
        return NSRect(x: inset + CGFloat(index) * w, y: inset, width: w, height: bounds.height - inset * 2)
    }

    private func moveHighlight(animated: Bool) {
        guard segments.indices.contains(selected) else { return }
        for (i, label) in labels.enumerated() { label.textColor = i == selected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary }
        for (i, segment) in segments.enumerated() { segment.setAccessibilityValue(i == selected ? 1 : 0) }
        segments[selected].layer?.backgroundColor = nil
        let target = frame(of: selected)
        if animated, !Tokens.Motion.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                highlight.animator().frame = target
            }
        } else {
            highlight.frame = target
        }
    }

    override func layout() {
        super.layout()
        for (i, segment) in segments.enumerated() {
            segment.frame = frame(of: i)
            let label = labels[i]
            label.frame = NSRect(x: 0, y: (segment.bounds.height - label.lineHeight) / 2, width: segment.bounds.width, height: label.lineHeight)
        }
        divider.frame = NSRect(x: bounds.midX, y: 9, width: 1, height: bounds.height - 18)
        if toggles { moveHighlight(animated: false) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = cgColor(Tokens.Color.fieldFill)
    }
}

/// One theme as it reads: "Aa" in its own ink on its own paper. Auto is half light, half dark.
private final class ThemeTile: InteractiveView {
    private let theme: Reader.Preferences.Theme
    private let darkHalf = CALayer()
    private let lightInk = CATextLayer()
    private let darkInk = CATextLayer()
    private let ring = CAShapeLayer()

    private static func colors(_ theme: Reader.Preferences.Theme) -> (paper: NSColor, ink: NSColor) {
        switch theme {
        case .auto, .light: return (Tokens.Color.hex(0xFDFCFA), Tokens.Color.hex(0x1F1F21))
        case .sepia: return (Tokens.Color.hex(0xF3E9D6), Tokens.Color.hex(0x45372A))
        case .dark: return (Tokens.Color.hex(0x1B1B1D), Tokens.Color.hex(0xE6E4E0))
        }
    }

    init(theme: Reader.Preferences.Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        let (paper, ink) = Self.colors(theme)
        layer?.backgroundColor = paper.cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        if theme == .auto {
            darkHalf.backgroundColor = Tokens.Color.hex(0x1B1B1D).cgColor
            layer?.addSublayer(darkHalf)
        }
        for (text, color) in [(lightInk, ink), (darkInk, Tokens.Color.hex(0xE6E4E0))] {
            text.string = "Aa"
            text.font = NSFont(descriptor: NSFont.systemFont(ofSize: 14, weight: .semibold).fontDescriptor.withDesign(.serif)!, size: 14)
            text.fontSize = 14
            text.alignmentMode = .center
            text.foregroundColor = color.cgColor
            text.contentsScale = 2
            layer?.addSublayer(text)
        }
        darkInk.isHidden = theme != .auto
        ring.fillColor = nil
        ring.lineWidth = 2.5
        ring.isHidden = true
        layer?.addSublayer(ring)
        toolTip = theme == .auto ? "Auto: follows your Mac" : theme.rawValue.capitalized
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(theme.rawValue.capitalized)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func stateDidChange(animated: Bool) {
        ring.isHidden = !isSelected
    }

    override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            let h = bounds.height, textH: CGFloat = 18
            darkHalf.frame = CGRect(x: bounds.midX, y: 0, width: bounds.width / 2, height: h)
            if theme == .auto {
                // "A" on the light half, "a" on the dark: the same word, both ways.
                lightInk.string = "A"
                darkInk.string = "a"
                lightInk.frame = CGRect(x: 0, y: (h - textH) / 2, width: bounds.width / 2, height: textH)
                darkInk.frame = CGRect(x: bounds.midX, y: (h - textH) / 2, width: bounds.width / 2, height: textH)
            } else {
                lightInk.frame = CGRect(x: 0, y: (h - textH) / 2, width: bounds.width, height: textH)
            }
            ring.path = CGPath(roundedRect: bounds.insetBy(dx: 1.25, dy: 1.25), cornerWidth: 9, cornerHeight: 9, transform: nil)
            ring.strokeColor = Tokens.Color.accent.cgColor
        }
    }
}

extension ReaderView: WKNavigationDelegate {
    /// Links in an article open in the page, not inside the reader.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            let flags = navigationAction.modifierFlags
            // The same as on any page: ⌘ for a tab behind, ⌘⇧ for one in front, ⇧ alone to peek.
            if flags.contains(.command) || navigationAction.buttonNumber == 4 {
                if flags.contains(.shift) { onForegroundLink?(url) } else { onBackgroundLink?(url) }
            } else if flags.contains(.shift) { onPeekLink?(url) }
            else { onOpenLink?(url) }
            return .cancel
        }
        return .allow
    }
}
