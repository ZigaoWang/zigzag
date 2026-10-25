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
        @keyframes appear { from { opacity: 0; } to { opacity: 1; } }
        @media (prefers-reduced-motion: reduce) { body { animation-name: appear; } }
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
    /// Shift-click: a look at the link in Peek, over the article. ⌘-click: a tab in the background.
    var onPeekLink: ((URL) -> Void)?
    var onBackgroundLink: ((URL) -> Void)?
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
                                      toggles: false)
    private let face = ReaderSegments([.text("Serif", NSFont(descriptor: NSFont.systemFont(ofSize: 14, weight: .medium).fontDescriptor.withDesign(.serif)!, size: 14)!),
                                       .text("Sans", .systemFont(ofSize: 14, weight: .medium))], toggles: true)
    private var tiles: [(Reader.Preferences.Theme, ThemeTile)] = []

    static let width: CGFloat = 236
    private static let pad: CGFloat = 10, row: CGFloat = 36, gap: CGFloat = 8
    var panelSize: NSSize { NSSize(width: Self.width, height: Self.pad * 2 + Self.row * 3 + Self.gap * 2) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        radius = 16
        [size, face].forEach { addSubview($0) }
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
        size.setEnabled(0, preferences.size > Reader.Preferences.sizes.lowerBound)
        size.setEnabled(1, preferences.size < Reader.Preferences.sizes.upperBound)
        for (theme, tile) in tiles { tile.isSelected = theme == preferences.theme }
    }

    private func layoutContent() {
        let pad = Self.pad, inner = bounds.width - pad * 2
        size.frame = NSRect(x: pad, y: pad, width: inner, height: Self.row)
        face.frame = NSRect(x: pad, y: size.frame.maxY + Self.gap, width: inner, height: Self.row)
        let y = face.frame.maxY + Self.gap, gap: CGFloat = 6
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

    init(_ items: [Item], toggles: Bool) {
        self.toggles = toggles
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
            if flags.contains(.shift) { onPeekLink?(url) }
            else if flags.contains(.command) || navigationAction.buttonNumber == 4 { onBackgroundLink?(url) }
            else { onOpenLink?(url) }
            return .cancel
        }
        return .allow
    }
}
