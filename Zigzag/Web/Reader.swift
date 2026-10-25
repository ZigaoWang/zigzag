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
          parse: () => {
            try {
              const article = new Readability(document.cloneNode(true)).parse();
              // The address says where it's from better than a publisher's legal name; a long byline is metadata, not an author.
              const byline = (article.byline || '').trim();
              return article ? JSON.stringify({ title: article.title || document.title, byline: byline.length <= 60 ? byline : '',
                site: location.hostname.replace(/^www\\./, ''), content: article.content || '',
                length: article.length || 0, lang: article.lang || document.documentElement.lang || '' }) : null;
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
    }

    static func article(in webView: WKWebView) async -> Article? {
        guard let json = try? await webView.evaluateJavaScript("window.__zigzagReader ? window.__zigzagReader.parse() : null", in: nil, contentWorld: .defaultClient) as? String,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Article.self, from: data)
    }

    /// How you like to read, remembered: text size, typeface and colours.
    struct Preferences {
        enum Face: String, CaseIterable { case serif, sans }
        enum Theme: String, CaseIterable { case auto, light, sepia, dark }
        static let sizes = 15...28
        var size: Int
        var face: Face
        var theme: Theme

        static var saved: Preferences {
            get {
                let d = UserDefaults.standard
                let size = d.integer(forKey: "ReaderSize")
                return Preferences(size: sizes.contains(size) ? size : 20,
                                   face: Face(rawValue: d.string(forKey: "ReaderFace") ?? "") ?? .serif,
                                   theme: Theme(rawValue: d.string(forKey: "ReaderTheme") ?? "") ?? .auto)
            }
            set {
                let d = UserDefaults.standard
                d.set(newValue.size, forKey: "ReaderSize")
                d.set(newValue.face.rawValue, forKey: "ReaderFace")
                d.set(newValue.theme.rawValue, forKey: "ReaderTheme")
            }
        }

        /// Applies these to an open reading page, without reloading it (and losing your place).
        var script: String {
            "document.documentElement.dataset.theme='\(theme.rawValue)';document.documentElement.dataset.face='\(face.rawValue)';" +
            "document.documentElement.style.setProperty('--size','\(size)px');"
        }
    }

    /// The reading page: a comfortable line length, the system serif (or sans) for reading, and four themes.
    static func html(for article: Article, preferences: Preferences = .saved) -> String {
        let minutes = max(1, Int((Double(article.length) / 1100).rounded()))
        // A credit that names no one ("Contributors to Wikimedia projects") says nothing; leave it out.
        let author = article.byline.lowercased().contains("contributors") ? "" : article.byline
        let details = [article.site, author, "\(minutes) min read"].filter { !$0.isEmpty }.map(escape).joined(separator: " · ")
        return """
        <!doctype html><html lang="\(escape(article.lang))" data-theme="\(preferences.theme.rawValue)" data-face="\(preferences.face.rawValue)" style="--size: \(preferences.size)px">
        <head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'; font-src *">
        <title>\(escape(article.title))</title>
        <style>
        :root { --text: #1f1f21; --soft: #6e6e73; --rule: rgba(0,0,0,.09); --bg: #fdfcfa; --link: #2f5d9a; --code: rgba(0,0,0,.05);
                --serif: ui-serif, "New York", Georgia, serif; --sans: -apple-system, "SF Pro Text", system-ui, sans-serif; }
        :root[data-theme="sepia"] { --text: #45372a; --soft: #8a7560; --rule: rgba(90,60,20,.14); --bg: #f6efe2; --link: #8a5326; --code: rgba(90,60,20,.07); }
        :root[data-theme="dark"] { --text: #e6e4e0; --soft: #9a9a9f; --rule: rgba(255,255,255,.12); --bg: #1b1b1d; --link: #8fb4e6; --code: rgba(255,255,255,.07); color-scheme: dark; }
        @media (prefers-color-scheme: dark) {
          :root[data-theme="auto"] { --text: #e6e4e0; --soft: #9a9a9f; --rule: rgba(255,255,255,.12); --bg: #1b1b1d; --link: #8fb4e6; --code: rgba(255,255,255,.07); color-scheme: dark; }
        }
        html { background: var(--bg); transition: background .25s ease; }
        body { margin: 0; padding: 88px 32px 160px; color: var(--text); font-family: var(--serif); font-size: var(--size); line-height: 1.7;
               -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; transition: color .25s ease;
               animation: rise .45s cubic-bezier(.2,.8,.2,1) both; }
        :root[data-face="sans"] body { font-family: var(--sans); line-height: 1.62; }
        @keyframes rise { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: none; } }
        main { max-width: 36em; margin: 0 auto; }
        header { margin-bottom: 2em; }
        .details { font: 14px/1.4 var(--sans); color: var(--soft); margin-bottom: 10px; }
        h1.title { font-family: inherit; font-size: 1.9em; font-weight: 700; line-height: 1.18; letter-spacing: -0.012em; margin: 0; }
        h1, h2, h3, h4 { line-height: 1.25; margin: 1.8em 0 .6em; letter-spacing: -0.01em; }
        h2 { font-size: 1.35em; } h3 { font-size: 1.15em; } h4 { font-size: 1em; }
        p, ul, ol, blockquote, figure, pre, table, dl { margin: 0 0 1.15em; }
        li { margin: .3em 0; } ul, ol { padding-left: 1.3em; }
        a { color: var(--link); text-decoration: underline; text-decoration-color: color-mix(in srgb, var(--link) 35%, transparent);
            text-underline-offset: .18em; } a:hover { text-decoration-color: var(--link); }
        img, video, svg, picture { display: block; max-width: 100%; height: auto; margin: 1.6em auto; border-radius: 8px; }
        figure img, figure picture { margin: 0 auto; }
        figure { margin: 1.8em 0; } figcaption { font: 13px/1.45 var(--sans); color: var(--soft); margin-top: 10px; text-align: center; }
        blockquote { margin-left: 0; padding: .2em 0 .2em 1.1em; border-left: 3px solid var(--rule); color: var(--soft); font-style: italic; }
        pre, code, kbd { font: .82em/1.55 ui-monospace, "SF Mono", Menlo, monospace; }
        code { background: var(--code); padding: .1em .35em; border-radius: 4px; }
        pre { overflow-x: auto; padding: 14px 16px; border-radius: 10px; background: var(--code); } pre code { background: none; padding: 0; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2.4em 0; }
        table { border-collapse: collapse; width: 100%; font-size: .9em; } td, th { border-bottom: 1px solid var(--rule); padding: 8px 10px; text-align: left; }
        /* Leftovers from the page that don't belong in reading. */
        button, input, select, textarea, form, iframe, nav, aside, [role="button"], [aria-hidden="true"] { display: none !important; }
        </style></head><body><main>
        <header>
        <div class="details">\(details)</div>
        <h1 class="title">\(escape(article.title))</h1>
        </header>
        \(article.content)
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
    private let controls = ReaderControls()

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
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

    private let style = IconButton(symbol: "textformat.size", toolTip: "Text and Colours")
    private let close = IconButton(symbol: "xmark", toolTip: "Close Reader (esc)")
    private let options = ReaderOptions()
    private var monitor: Any?

    static let height: CGFloat = 40

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
        NSSize(width: Tokens.Metric.iconButton * 2 + 4 + Tokens.Space.x1 * 2, height: Self.height)
    }

    private func layoutContent() {
        let b = Tokens.Metric.iconButton, h = bounds.height
        style.frame = NSRect(x: Tokens.Space.x1, y: (h - b) / 2, width: b, height: b)
        close.frame = NSRect(x: style.frame.maxX + 4, y: (h - b) / 2, width: b, height: b)
    }

    func toggleOptions() {
        if options.superview != nil { hideOptions(); return }
        guard let host = superview else { return }
        options.preferences = preferences
        let size = options.panelSize
        options.frame = NSRect(x: frame.maxX - size.width, y: frame.maxY + Tokens.Space.x2, width: size.width, height: size.height)
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

/// How it reads: size, typeface, colours. Three short rows, nothing else.
private final class ReaderOptions: FloatingPanelView {
    var onChange: ((Reader.Preferences) -> Void)?
    var preferences = Reader.Preferences.saved { didSet { refresh() } }

    private let smaller = TextButton(title: "A", font: .systemFont(ofSize: 13, weight: .medium))
    private let larger = TextButton(title: "A", font: .systemFont(ofSize: 19, weight: .medium))
    private let face = SegmentedPills(["Serif", "Sans"])
    private var swatches: [(Reader.Preferences.Theme, ThemeSwatch)] = []
    private let rule1 = ColorView(color: Tokens.Color.separator)
    private let rule2 = ColorView(color: Tokens.Color.separator)

    var panelSize: NSSize { NSSize(width: 216, height: 160) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [smaller, larger, rule1, face, rule2].forEach { addSubview($0) }
        smaller.toolTip = "Smaller Text"
        larger.toolTip = "Larger Text"
        for theme in Reader.Preferences.Theme.allCases {
            let swatch = ThemeSwatch(theme: theme)
            swatch.onClick = { [weak self] in self?.change { $0.theme = theme } }
            addSubview(swatch)
            swatches.append((theme, swatch))
        }
        smaller.onClick = { [weak self] _ in self?.change { $0.size = max(Reader.Preferences.sizes.lowerBound, $0.size - 1) } }
        larger.onClick = { [weak self] _ in self?.change { $0.size = min(Reader.Preferences.sizes.upperBound, $0.size + 1) } }
        face.onChange = { [weak self] index in self?.change { $0.face = index == 0 ? .serif : .sans } }
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
        face.selectedIndex = preferences.face == .serif ? 0 : 1
        for (theme, swatch) in swatches { swatch.isChosen = theme == preferences.theme }
        smaller.isEnabled = preferences.size > Reader.Preferences.sizes.lowerBound
        larger.isEnabled = preferences.size < Reader.Preferences.sizes.upperBound
    }

    private func layoutContent() {
        let w = bounds.width, pad = Tokens.Space.x3, inner = w - pad * 2
        // Size: a small A and a big A, each half the row.
        let rowH: CGFloat = 40
        smaller.frame = NSRect(x: pad, y: pad - 2, width: inner / 2, height: rowH)
        larger.frame = NSRect(x: pad + inner / 2, y: pad - 2, width: inner / 2, height: rowH)
        rule1.frame = NSRect(x: pad, y: smaller.frame.maxY + 4, width: inner, height: 1)
        let fw = ceil(face.fittingWidth)
        face.frame = NSRect(x: (w - fw) / 2, y: rule1.frame.maxY + 9, width: fw, height: 30)
        rule2.frame = NSRect(x: pad, y: face.frame.maxY + 9, width: inner, height: 1)
        let dot: CGFloat = 30
        let gap = (inner - dot * CGFloat(swatches.count)) / CGFloat(max(swatches.count - 1, 1))
        for (i, (_, swatch)) in swatches.enumerated() {
            swatch.frame = NSRect(x: pad + CGFloat(i) * (dot + gap), y: rule2.frame.maxY + 11, width: dot, height: dot)
        }
    }
}

/// One theme: a plain round sample of its paper, ringed when chosen. Auto is half light, half dark.
private final class ThemeSwatch: NSView {
    var onClick: (() -> Void)?
    var isChosen = false { didSet { ring.isHidden = !isChosen } }
    private let ring = CAShapeLayer()
    private let fill = CALayer()
    private let half = CALayer()

    init(theme: Reader.Preferences.Theme) {
        super.init(frame: .zero)
        wantsLayer = true
        let paper: NSColor
        switch theme {
        case .auto, .light: paper = Tokens.Color.hex(0xFDFCFA)
        case .sepia: paper = Tokens.Color.hex(0xF3E9D6)
        case .dark: paper = Tokens.Color.hex(0x1B1B1D)
        }
        fill.backgroundColor = paper.cgColor
        fill.borderWidth = 1
        fill.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        fill.masksToBounds = true
        layer?.addSublayer(fill)
        if theme == .auto {
            half.backgroundColor = Tokens.Color.hex(0x1B1B1D).cgColor
            fill.addSublayer(half)
        }
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.isHidden = true
        layer?.addSublayer(ring)
        toolTip = theme.rawValue.capitalized
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(theme.rawValue.capitalized)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            let inner = bounds.insetBy(dx: 4, dy: 4)
            fill.frame = inner
            fill.cornerRadius = inner.width / 2
            half.frame = CGRect(x: inner.width / 2, y: 0, width: inner.width / 2, height: inner.height)
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
            ring.strokeColor = Tokens.Color.accent.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

extension ReaderView: WKNavigationDelegate {
    /// Links in an article open in the page, not inside the reader.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            onOpenLink?(url)
            return .cancel
        }
        return .allow
    }
}
