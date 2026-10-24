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

    /// The reading page. Type and spacing follow the app: system serif for reading, system sans for the details.
    static func html(for article: Article) -> String {
        let minutes = max(1, Int((Double(article.length) / 1100).rounded()))
        let details = [article.site, article.byline, "\(minutes) min read"].filter { !$0.isEmpty }.map(escape).joined(separator: " · ")
        return """
        <!doctype html><html lang="\(escape(article.lang))"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'; font-src *">
        <title>\(escape(article.title))</title>
        <style>
        :root { color-scheme: light dark; --text: #1d1d1f; --soft: #6e6e73; --rule: rgba(0,0,0,.1); --bg: #fbfaf8; --link: #2f5d9a; }
        @media (prefers-color-scheme: dark) { :root { --text: #e8e6e3; --soft: #98989d; --rule: rgba(255,255,255,.12); --bg: #1c1c1e; --link: #8fb4e6; } }
        html { background: var(--bg); }
        body { margin: 0; padding: 72px 32px 120px; color: var(--text); font: 19px/1.65 ui-serif, "New York", Georgia, serif;
               -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }
        main { max-width: 680px; margin: 0 auto; }
        .details { font: 500 13px/1.4 -apple-system, system-ui; color: var(--soft); margin-bottom: 12px; }
        h1.title { font: 700 34px/1.2 ui-serif, "New York", Georgia, serif; letter-spacing: -0.01em; margin: 0 0 40px; }
        h1, h2, h3, h4 { line-height: 1.25; margin: 1.6em 0 .6em; }
        p, ul, ol, blockquote, figure, pre, table { margin: 0 0 1.1em; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        img, video, svg { max-width: 100%; height: auto; border-radius: 6px; }
        figure { margin-left: 0; margin-right: 0; } figcaption { font: 13px/1.4 -apple-system, system-ui; color: var(--soft); margin-top: 8px; }
        blockquote { border-left: 3px solid var(--rule); margin-left: 0; padding-left: 20px; color: var(--soft); }
        pre, code { font: 15px/1.5 ui-monospace, Menlo, monospace; } pre { overflow-x: auto; padding: 14px 16px; border-radius: 8px; background: var(--rule); }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
        table { border-collapse: collapse; } td, th { border-bottom: 1px solid var(--rule); padding: 6px 10px; text-align: left; }
        </style></head><body><main>
        <div class="details">\(details)</div>
        <h1 class="title">\(escape(article.title))</h1>
        \(article.content)
        </main></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// The reading surface shown over a page card.
final class ReaderView: NSView {
    let webView: WKWebView
    var onClose: (() -> Void)?
    var onOpenLink: ((URL) -> Void)?

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    func show(_ article: Reader.Article, from url: URL) {
        webView.navigationDelegate = self
        webView.loadHTMLString(Reader.html(for: article), baseURL: url)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }
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
