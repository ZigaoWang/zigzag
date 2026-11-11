import AppKit
import WebKit

/// Reader: an article as clean, readable text. Mozilla's Readability (the engine behind Firefox's reader view,
/// bundled under its Apache licence) finds the article in Zigzag's own script world, where the page can't see
/// or interfere with it. The result is shown in a separate web view with JavaScript off, over the page,
/// which stays loaded underneath.
enum Reader {
    /// Where a link clicked in Reader or a PDF goes. Only web pages open in Zigzag; another app's link asks first, as
    /// on a page; anything else (a file on your Mac, a script) goes nowhere, since these views read local files.
    enum LinkRoute: Equatable {
        case browse
        case externalApp
        case ignore
    }

    static func route(for url: URL) -> LinkRoute {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" { return url.host()?.isEmpty == false ? .browse : .ignore }
        return ExternalLinks.isExternal(url) ? .externalApp : .ignore
    }

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
              const wiki = !!copy.querySelector('.mw-parser-output');
              if (wiki) {
                copy.querySelectorAll('.infobox, .navbox, .navbox-styles, .vertical-navbox, .sidebar, .metadata, .ambox, .hatnote, ' +
                  '.shortdescription, .mw-editsection, sup.reference, .mw-jump-link, #toc, .toc, .noprint, .mw-empty-elt, ' +
                  '.side-box, .sistersitebox, .portalbox, .catlinks, .authority-control, .navigation-not-searchable').forEach(el => el.remove());
                // The little ⓘ after a pronunciation plays a sound on the page; in reading it's just a mark.
                copy.querySelectorAll('a, span, sup').forEach(el => { if (el.childElementCount === 0 && el.textContent.trim() === 'ⓘ') el.remove(); });
                // A picture floats beside the paragraph after it on the page; in one column it follows that paragraph,
                // so an article opens with its words, not a stack of pictures. Last first, so a run keeps its order.
                [...copy.querySelectorAll('.mw-parser-output figure')].reverse().forEach(figure => {
                  let next = figure.nextElementSibling;
                  while (next && next.tagName === 'FIGURE') next = next.nextElementSibling;
                  if (next && next.tagName === 'P' && next.textContent.trim()) next.after(figure);
                });
              }
              // Icons and spacers aren't pictures.
              copy.querySelectorAll('img').forEach(img => {
                const w = parseInt(img.getAttribute('width') || '0', 10), h = parseInt(img.getAttribute('height') || '0', 10);
                if ((w && w < 32 && h && h < 32) || (w && w <= 2) || (h && h <= 2)) img.remove();
              });
              // What the site calls itself, when it says so briefly; otherwise its address. Never a company's legal name.
              const siteName = () => {
                const host = location.hostname.replace(/^(www|m)\\./, '');
                if (/(^|\\.)wikipedia\\.org$/.test(host)) return 'Wikipedia';
                const own = (meta('og:site_name') || '').trim();
                return own && own.length <= 28 && !/\\b(inc|llc|ltd|foundation|corporation)\\b/i.test(own) ? own : host;
              };
              const meta = n => (document.querySelector(`meta[property="${n}"], meta[name="${n}"]`) || {}).content || '';
              const article = new Readability(copy).parse();
              if (!article) return null;
              const body = document.createElement('div');
              body.innerHTML = article.content || '';
              // A heading's own link marker (¶, #, §) is for sharing the spot on the page; in reading it's noise.
              body.querySelectorAll(':is(h1, h2, h3, h4, h5, h6) a, a.headerlink').forEach(a => {
                if (a.classList.contains('headerlink') || /^[¶#§]?$/.test(a.textContent.trim()) && !a.querySelector('img')) a.remove();
              });
              // A picture in a line of text (a formula, an emoji) stays in the line; every other one is a block.
              body.querySelectorAll('img').forEach(img => {
                const block = img.closest('p, li, td, th, dd');
                if (block && !img.closest('figure') && block.textContent.trim().length > 0) img.classList.add('inline');
              });
              // A wiki's date is when the page was started, not when what you read was written.
              const time = wiki ? null : document.querySelector('article time[datetime], main time[datetime], header time[datetime]');
              const published = wiki ? '' : article.publishedTime || meta('article:published_time') || (time ? time.getAttribute('datetime') : '') || '';
              return JSON.stringify({ title: article.title || document.title, byline: (article.byline || '').trim(),
                site: siteName(), siteTitle: (meta('og:site_name') || meta('application-name') || '').trim(),
                content: body.innerHTML, length: article.length || 0,
                lang: article.lang || document.documentElement.lang || '',
                sample: (article.textContent || '').replace(/\\s+/g, ' ').slice(0, 600),
                published: published,
                url: location.href });
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

    /// Reads the article ahead of time, while the page is idle, so Reader opens at once.
    static func prepare(_ webView: WKWebView) {
        webView.evaluateJavaScript("window.__zigzagReader && window.__zigzagReader.prepare(); 0", in: nil, in: .defaultClient, completionHandler: nil)
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
        /// The opening words, plain, to tell the language by when the page doesn't say or says wrong.
        var sample: String? = nil
        /// When it was published, as the page gives it.
        var published: String? = nil
        /// What the site calls itself in full, to take off the end of a title.
        var siteTitle: String? = nil
        var url: String? = nil
    }

    static func article(in webView: WKWebView) async -> Article? {
        guard let json = try? await webView.evaluateJavaScript("window.__zigzagReader ? window.__zigzagReader.take() : null", in: nil, contentWorld: .defaultClient) as? String,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Article.self, from: data)
    }

    // MARK: The header's facts

    /// The title without the site's name tacked on its end ("Make 命令教程 - 阮一峰的网络日志" → "Make 命令教程"): the
    /// part after the last separator goes when it's one of the site's names, or the author's own blog.
    static func title(_ raw: String, siteNames: [String], author: String) -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = siteNames.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        for separator in [" - ", " | ", " – ", " — ", " · ", " :: ", "_"] {
            guard let range = title.range(of: separator, options: .backwards) else { continue }
            let head = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = title[range.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            guard head.count >= 2, !tail.isEmpty else { continue }
            let isSite = names.contains { tail == $0 || ($0.count >= 4 && tail.contains($0)) }
            let isAuthors = author.count >= 2 && tail.contains(author.lowercased()) && tail.count > author.count
            if isSite || isAuthors { return head }
        }
        return title
    }

    /// Who wrote it, as a byline reads: "By" and the like trimmed off. Empty when the page's credit names no one
    /// ("Contributors to Wikimedia projects"), is just the site again, or is too long to be a name.
    static func author(from byline: String, site: String) -> String {
        var name = byline.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"^\s*(?:(?:written|posted|words|story)\s+)?by\s+|^\s*作者\s*[:：]?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " |-–—·•,:：/"))
        let lower = name.lowercased()
        if name.isEmpty || name.count > 60 || lower.contains("contributors") || lower.contains("http") || lower.contains("@")
            || lower == site.lowercased() { return "" }
        return name
    }

    /// The day it was published, written out in the reader's language ("March 3, 2024", "2024年3月3日"). The day
    /// is the publisher's own, whatever the time zone here. Empty when the page's date can't be read, or is in the
    /// future, which a real one never is.
    static func publishedDate(_ raw: String?, locale: Locale = .current, now: Date = Date()) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var day: Date?
        // "2024-03-03", "2024-03-03T10:00:00-05:00": the calendar day as written.
        if let match = text.firstMatch(of: /^(\d{4})-(\d{2})-(\d{2})/), let y = Int(match.1), let m = Int(match.2), let d = Int(match.3) {
            day = utc.date(from: DateComponents(year: y, month: m, day: d))
        } else {
            // RSS and HTTP's "Sun, 03 Mar 2024 10:00:00 +0000".
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "MMMM d, yyyy"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: text) {
                    let parts = Calendar(identifier: .gregorian).dateComponents(in: formatter.timeZone, from: date)
                    day = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
                    break
                }
            }
        }
        guard let day, day < now.addingTimeInterval(86_400), utc.component(.year, from: day) > 1990 else { return "" }
        return day.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: utc, timeZone: utc.timeZone))
    }

    /// The article's language, for hyphenation and the right typeface: what the page says, unless its words are
    /// plainly Chinese, Japanese or Korean and it says otherwise (or nothing), as many sites do.
    static func language(declared: String, sample: String) -> String {
        var letters = 0, han = 0, kana = 0, hangul = 0
        for scalar in sample.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            switch scalar.value {
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: han += 1
            default: break
            }
        }
        let code = declared.lowercased().split(separator: "-").first.map(String.init) ?? ""
        guard letters >= 20 else { return declared }
        if kana * 10 > letters { return code == "ja" ? declared : "ja" }
        if hangul * 3 > letters { return code == "ko" ? declared : "ko" }
        if (han + kana) * 3 > letters { return code == "zh" || code == "ja" ? declared : "zh" }
        return declared
    }

    /// A site's icon, small, as the header shows it beside the site's name.
    static func iconSource(_ image: NSImage?) -> String? {
        guard let image, image.size.width > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]).map { "data:image/png;base64," + $0.base64EncodedString() }
    }

    // MARK: How it reads

    /// One theme's paper and inks. Light and Dark are Zigzag's own page colors, warmed a touch for long reading.
    struct Palette: Equatable {
        let paper: UInt32
        let ink: UInt32
        let soft: UInt32
        let link: UInt32
        /// Hairlines, code's soft ground and the selection, as see-through washes of the ink or the link.
        let rule: String
        let code: String
        let select: String
        let isDark: Bool

        static let light = Palette(paper: 0xFBFAF8, ink: 0x1F1E1C, soft: 0x6D6A64, link: 0x2F5E98,
                                   rule: "rgba(31,30,28,.12)", code: "rgba(31,30,28,.05)", select: "rgba(47,94,152,.18)", isDark: false)
        static let sepia = Palette(paper: 0xF4ECDE, ink: 0x3B2F24, soft: 0x806B57, link: 0x8A5326,
                                   rule: "rgba(80,55,25,.16)", code: "rgba(80,55,25,.07)", select: "rgba(138,83,38,.2)", isDark: false)
        static let dark = Palette(paper: 0x1E1E20, ink: 0xE6E4DF, soft: 0x9A9893, link: 0x9DBDEB,
                                  rule: "rgba(255,255,255,.12)", code: "rgba(255,255,255,.06)", select: "rgba(157,189,235,.25)", isDark: true)

        /// The page's colors as CSS custom properties.
        var css: String {
            func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }
            return "--paper: \(hex(paper)); --ink: \(hex(ink)); --soft: \(hex(soft)); --link: \(hex(link)); " +
                "--rule: \(rule); --code: \(code); --select: \(select); color-scheme: \(isDark ? "dark" : "light");"
        }
    }

    /// How you like to read, remembered for every article: text size, typeface, column width and colors.
    struct Preferences: Equatable {
        enum Face: String, CaseIterable { case serif, sans }
        enum Theme: String, CaseIterable {
            case auto, light, sepia, dark
            /// Auto's are Light's; the page takes Dark's itself while the Mac is dark.
            var palette: Palette { switch self { case .auto, .light: .light; case .sepia: .sepia; case .dark: .dark } }
        }
        /// How wide the column runs, in the text's own size, so a line holds about the same number of characters at
        /// any size: Medium is the book's 66 to 72, Narrow a column's, Wide fills more of a big window.
        enum Width: String, CaseIterable {
            case narrow, medium, wide
            var measure: String { switch self { case .narrow: "29em"; case .medium: "34em"; case .wide: "40em" } }
        }
        static let sizes = 14...32
        static let defaultSize = 20
        /// One step of ⌘+ or the larger A: big enough to see, small enough to land where you want.
        static let step = 2
        var size = defaultSize
        var face = Face.serif
        var theme = Theme.auto
        var width = Width.medium

        /// A step bigger or smaller (0 back to the usual), never past the ends.
        func stepped(_ delta: Int) -> Preferences {
            var next = self
            next.size = delta == 0 ? Self.defaultSize : min(max(size + delta * Self.step, Self.sizes.lowerBound), Self.sizes.upperBound)
            return next
        }

        /// The size as against the usual one, as a whole percent: what the toast says.
        var percent: Int { Int((Double(size) / Double(Self.defaultSize) * 100).rounded()) }

        static func load(from defaults: UserDefaults) -> Preferences {
            let size = defaults.integer(forKey: "ReaderSize")
            return Preferences(size: sizes.contains(size) ? size : defaultSize,
                               face: Face(rawValue: defaults.string(forKey: "ReaderFace") ?? "") ?? .serif,
                               theme: Theme(rawValue: defaults.string(forKey: "ReaderTheme") ?? "") ?? .auto,
                               width: Width(rawValue: defaults.string(forKey: "ReaderWidth") ?? "") ?? .medium)
        }

        func save(to defaults: UserDefaults) {
            defaults.set(size, forKey: "ReaderSize")
            defaults.set(face.rawValue, forKey: "ReaderFace")
            defaults.set(theme.rawValue, forKey: "ReaderTheme")
            defaults.set(width.rawValue, forKey: "ReaderWidth")
        }

        static var saved: Preferences {
            get { load(from: .standard) }
            set { newValue.save(to: .standard) }
        }

        /// The size and measure, as the page's root element carries them.
        var rootStyle: String { "--size: \(size)px; --measure: \(width.measure)" }

        /// Applies these to an open reading page, without reloading it (and losing your place).
        var script: String {
            "document.documentElement.dataset.theme='\(theme.rawValue)';document.documentElement.dataset.face='\(face.rawValue)';" +
            "document.documentElement.setAttribute('style','\(rootStyle)');"
        }
    }

    /// The reading page: one column at a book's measure, and everything in it (the header, text, pictures, captions,
    /// quotes, code, tables) on that column's left edge. The header is where it's from, the title, and who wrote it
    /// and when, if the page says; then the text.
    static func html(for article: Article, preferences: Preferences = .saved, icon: String? = nil, locale: Locale = .current) -> String {
        let author = author(from: article.byline, site: article.site)
        let title = Self.title(article.title, siteNames: [article.site, article.siteTitle ?? ""], author: author)
        let date = publishedDate(article.published, locale: locale)
        let lang = language(declared: article.lang, sample: article.sample ?? "")
        let iconTag = icon.map { "<img src=\"\(escape($0))\" alt=\"\">" } ?? ""
        var byline = ""
        if !author.isEmpty || !date.isEmpty {
            byline = "<p class=\"byline\">" + (author.isEmpty ? "" : "<span class=\"author\">\(escape(author))</span>") +
                (date.isEmpty ? "" : "<time>\(escape(date))</time>") + "</p>"
        }
        let source = (article.url ?? "").isEmpty ? "" :
            "<footer class=\"end\"><a href=\"\(escape(article.url ?? ""))\">\(escape(String(localized: "Read the original on \(article.site)", comment: "Link at the end of an article in Reader, to the page it came from. The placeholder is the site's name.")))</a></footer>"
        return """
        <!doctype html><html lang="\(escape(lang))" data-theme="\(preferences.theme.rawValue)" data-face="\(preferences.face.rawValue)" style="\(preferences.rootStyle)">
        <head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'; font-src *">
        <title>\(escape(title))</title>
        <style>\(css)</style></head><body><main>
        <header>
        <p class="site">\(iconTag)<span>\(escape(article.site))</span></p>
        <h1 class="title">\(escape(title))</h1>
        \(byline)
        </header>
        <article>
        \(article.content)
        </article>
        \(source)
        </main></body></html>
        """
    }

    /// A face per script, regular and bold, made of the Mac's own fonts and limited to that script's characters
    /// (and its full-width punctuation), so it can lead a stack without taking over Latin text.
    private static let cjkFaces: String = {
        let ranges = "U+1100-11FF, U+2E80-2FDF, U+3000-30FF, U+3130-318F, U+3400-4DBF, U+4E00-9FFF, U+AC00-D7AF, U+F900-FAFF, U+FE30-FE4F, U+FF00-FFEF"
        let faces = [("Reader SC", "PingFangSC-Regular", "PingFangSC-Semibold"), ("Reader TC", "PingFangTC-Regular", "PingFangTC-Semibold"),
                     ("Reader JA", "HiraginoSans-W3", "HiraginoSans-W6"), ("Reader KO", "AppleSDGothicNeo-Regular", "AppleSDGothicNeo-SemiBold")]
        return faces.map { family, regular, bold in
            "@font-face { font-family: \"\(family)\"; src: local(\"\(regular)\"); font-weight: 100 499; unicode-range: \(ranges); }\n" +
            "@font-face { font-family: \"\(family)\"; src: local(\"\(bold)\"); font-weight: 500 900; unicode-range: \(ranges); }"
        }.joined(separator: "\n")
    }()

    /// The reading page's style sheet: its colors come from the palettes above.
    static let css = """
    /* Chinese, Japanese and Korean read in the Mac's own gothic faces (PingFang, Hiragino Sans, Apple SD Gothic Neo)
       in either typeface: these take only their scripts' characters, so Latin words among them stay New York or SF. */
    \(cjkFaces)
    :root { \(Palette.light.css)
            --serif: ui-serif, "New York", "Iowan Old Style", Georgia, serif;
            --sans: system-ui, -apple-system, "Helvetica Neue", sans-serif;
            --mono: ui-monospace, "SF Mono", Menlo, monospace;
            --face: var(--serif); --leading: 1.6; }
    :root[data-theme="sepia"] { \(Palette.sepia.css) }
    :root[data-theme="dark"] { \(Palette.dark.css) }
    @media (prefers-color-scheme: dark) { :root[data-theme="auto"] { \(Palette.dark.css) } }
    :root[data-face="sans"] { --face: var(--sans); --leading: 1.58; }
    /* Their own faces (there are no italics to fake), and more air between lines. */
    :root:lang(zh) { --serif: "Reader SC", ui-serif, serif; --sans: "Reader SC", system-ui, sans-serif; }
    :root:is(:lang(zh-Hant), :lang(zh-TW), :lang(zh-HK)) { --serif: "Reader TC", ui-serif, serif; --sans: "Reader TC", system-ui, sans-serif; }
    :root:lang(ja) { --serif: "Reader JA", ui-serif, serif; --sans: "Reader JA", system-ui, sans-serif; }
    :root:lang(ko) { --serif: "Reader KO", ui-serif, serif; --sans: "Reader KO", system-ui, sans-serif; }
    :root:is(:lang(zh), :lang(ja), :lang(ko)) { --leading: 1.8; }
    :is(:lang(zh), :lang(ja), :lang(ko)) :is(em, i, cite, dfn) { font-style: normal; font-weight: 600; }

    html { background: var(--paper); }
    ::selection { background: var(--select); }
    body { margin: 0; padding: 80px 40px 120px; color: var(--ink); font-family: var(--face); font-size: var(--size, 20px);
           line-height: var(--leading); -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
           font-kerning: normal; hanging-punctuation: first allow-end last; overflow-wrap: break-word;
           -webkit-hyphens: auto; hyphens: auto; }
    main { max-width: var(--measure, 34em); margin: 0 auto; }

    /* The header: where it's from, the title, who and when. Space below it, no rule. */
    header { margin: 0 0 2.2em; }
    .site { display: flex; align-items: center; gap: 8px; margin: 0 0 12px; font: 500 14px/1.4 var(--sans); color: var(--soft); }
    .site img { display: block; width: 16px; height: 16px; margin: 0; border-radius: 3px; flex: none; }
    h1.title { margin: 0; font-size: 2.1em; line-height: 1.12; font-weight: 700; letter-spacing: -0.016em; text-wrap: balance; -webkit-hyphens: manual; hyphens: manual; }
    :root:is(:lang(zh), :lang(ja), :lang(ko)) h1.title { line-height: 1.3; letter-spacing: 0; }
    .byline { display: flex; flex-wrap: wrap; column-gap: 14px; margin: 14px 0 0; font: 14px/1.45 var(--sans); color: var(--soft); }
    .byline .author { color: var(--ink); font-weight: 500; }

    /* The text's rhythm: a line of space between paragraphs, headings closer to what follows than to what came before. */
    article > :first-child { margin-top: 0; }
    p, ul, ol, dl, blockquote, pre, table, figure, details { margin: 0 0 1em; }
    p { text-wrap: pretty; }
    h2, h3, h4, h5, h6 { margin: 1.8em 0 .5em; line-height: 1.25; font-weight: 700; letter-spacing: -0.008em; text-wrap: balance;
                         -webkit-hyphens: manual; hyphens: manual; }
    h2 { font-size: 1.4em; } h3 { font-size: 1.15em; } h4, h5, h6 { font-size: 1em; }
    :is(h2, h3, h4) + :is(h3, h4, h5) { margin-top: .9em; }
    article h1 { font-size: 1.4em; margin: 1.8em 0 .5em; line-height: 1.25; }

    /* Links read as part of the sentence: the text's own color, a quiet underline, the link color when pointed at. */
    a { color: inherit; text-decoration: underline 1px; text-underline-offset: .2em;
        text-decoration-color: color-mix(in srgb, currentColor 24%, transparent); }
    a:hover { color: var(--link); text-decoration-color: currentColor; }
    :is(h1, h2, h3, h4, h5, h6) a, figure a { text-decoration: none; }

    /* Pictures at their own size, never bigger, on the column's edge; a caption small and quiet under each. */
    img, video, picture, svg, canvas { max-width: 100%; height: auto; }
    img, video { display: block; margin: 1.6em 0; border-radius: 3px; }
    img.inline { display: inline; margin: 0; vertical-align: middle; border-radius: 0; }
    figure { margin: 1.8em 0; }
    figure img, figure video, figure picture { margin: 0; }
    figure > a, picture { display: block; }
    figcaption { max-width: 36em; margin: .6em 0 0; font: 14px/1.45 var(--sans); color: var(--soft); text-wrap: pretty; -webkit-hyphens: manual; hyphens: manual; }
    :root:is(:lang(zh), :lang(ja), :lang(ko)) figcaption { line-height: 1.6; }
    figcaption p { margin: 0; }
    /* Picture galleries come as lists: no bullets, just the pictures. */
    :is(ul, ol):has(> li img) { list-style: none; padding: 0; }
    li:has(> img, > figure, > a > img) { margin: 0; }

    blockquote { margin: 1.4em 0; padding: 0 0 0 1.1em; border-left: 2px solid var(--rule); color: var(--soft); }
    blockquote > :last-child { margin-bottom: 0; }

    code, kbd, samp, pre { font-family: var(--mono); font-size: .84em; -webkit-hyphens: none; hyphens: none; }
    code, kbd { padding: .1em .32em; border-radius: 4px; background: var(--code); }
    pre { padding: 14px 16px; border-radius: 8px; background: var(--code); line-height: 1.55; overflow-x: auto; white-space: pre; tab-size: 4; }
    pre code { padding: 0; background: none; font-size: inherit; }

    table { display: block; width: max-content; max-width: 100%; overflow-x: auto; margin: 1.6em 0; border-collapse: collapse;
            font: 15px/1.5 var(--sans); }
    th, td { padding: 7px 16px 7px 0; border-bottom: 1px solid var(--rule); text-align: left; vertical-align: top; }
    th { font-weight: 600; }
    caption { caption-side: bottom; margin-top: .6em; text-align: left; font-size: 14px; color: var(--soft); }

    ul, ol { padding-left: 1.4em; }
    li { margin: .3em 0; } li > :is(p, ul, ol) { margin: .3em 0; }
    li::marker { color: var(--soft); }
    dt { font-weight: 600; } dd { margin: 0 0 .6em 1.4em; }
    hr { height: 1px; margin: 2em 0; border: 0; background: var(--rule); }
    sup, sub { line-height: 0; font-size: .7em; }
    abbr[title] { text-decoration: none; }

    .end { margin-top: 3em; padding-top: 1.2em; border-top: 1px solid var(--rule); font: 14px/1.45 var(--sans); color: var(--soft); }
    .end a { color: inherit; }

    /* Leftovers from the page that don't belong in reading. */
    button, input, select, textarea, form, iframe, nav, aside, [role="button"], [aria-hidden="true"] { display: none !important; }

    /* On paper: black on white whatever the theme, the page's margins, nothing split across a page break. */
    @page { margin: 18mm 20mm; }
    @media print {
      :root, :root[data-theme] { \(Palette.light.css) --ink: #000; }
      html, body { background: #fff; }
      body { padding: 0; font-size: 11.5pt; }
      main { max-width: none; }
      a { text-decoration: none; }
      pre { white-space: pre-wrap; overflow: visible; }
      table { overflow: visible; }
      img, figure, pre, blockquote, tr { break-inside: avoid; }
      h2, h3, h4 { break-after: avoid; }
    }
    """

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// The reading surface shown over a page card. Its one control, Aa, sits quietly at the top right: there at the top
/// of the article and whenever you scroll back up, out of the way while you read on.
final class ReaderView: NSView {
    let webView: WKWebView
    var onClose: (() -> Void)?
    var onOpenLink: ((URL) -> Void)?
    /// Shift-click: a look at the link in Peek, over the article. ⌘-click: a tab in the background.
    var onPeekLink: ((URL) -> Void)?
    var onBackgroundLink: ((URL) -> Void)?
    var onForegroundLink: ((URL) -> Void)?
    private let controls = ReaderControls()
    /// The page the article came from: the reading page's own address, the one load it makes by itself.
    private var articleURL: URL?
    private var scrollMonitor: Any?

    /// `store`: the one the page it reads is in (its profile's, or its private window's).
    init(store: WKWebsiteDataStore) {
        webView = WKWebView(frame: .zero, configuration: Self.configuration(store: store))

        super.init(frame: .zero)
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        addSubview(controls)
        controls.onChange = { [weak self] preferences in self?.apply(preferences) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// ⌘+ and ⌘−: the text a step bigger or smaller (0 back to the usual), kept for every article. Returns the new
    /// choices.
    @discardableResult
    func stepTextSize(_ delta: Int) -> Reader.Preferences {
        let preferences = controls.preferences.stepped(delta)
        controls.preferences = preferences
        apply(preferences)
        return preferences
    }

    private func apply(_ preferences: Reader.Preferences) {
        Reader.Preferences.saved = preferences
        // The page's own scripts are off; this runs in Zigzag's world, so the change is instant.
        webView.evaluateJavaScript(preferences.script, in: nil, in: .defaultClient, completionHandler: nil)
        controls.theme = preferences.theme
    }

    /// In the store of the page it reads, so the article's pictures are fetched as the page fetched them: one store
    /// shared by every reading page would carry a site's cookies from one profile to another, and out of a private
    /// window. Scripts stay off.
    static func configuration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = store
        return configuration
    }

    /// A reading page kept loaded in the background in the store Reader will next use, so its web process is
    /// already up when Reader opens, most of a second sooner. Not for a private window: it would keep the window's
    /// store, and what's in it, after the window closes.
    private static var warm: WKWebView?
    static func prewarm(for store: WKWebsiteDataStore) {
        guard store.isPersistent, warm?.configuration.websiteDataStore !== store else { return }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration(store: store))
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        warm = view
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        let side = ReaderControls.side
        controls.frame = NSRect(x: bounds.width - side - Tokens.Space.x4, y: Tokens.Space.x4, width: side, height: side)
    }

    func show(_ article: Reader.Article, from url: URL, icon: NSImage? = nil) {
        articleURL = url
        webView.navigationDelegate = self
        let preferences = Reader.Preferences.saved
        webView.loadHTMLString(Reader.html(for: article, preferences: preferences, icon: Reader.iconSource(icon)), baseURL: url)
        controls.preferences = preferences
        controls.theme = preferences.theme
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

    /// Scrolling on through the article puts Aa away; scrolling back up brings it back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            if event.scrollingDeltaY < -1 { self.controls.setShown(false) } else if event.scrollingDeltaY > 1 { self.controls.setShown(true) }
            return event
        }
    }
}

/// Aa, alone at the top right on the article's own paper: how it reads opens in a small panel underneath. Reader
/// itself goes with the address's Reader button, Esc or ⌘⇧R, as it came.
final class ReaderControls: NSView {
    var onChange: ((Reader.Preferences) -> Void)?
    var preferences = Reader.Preferences.saved { didSet { options.preferences = preferences } }
    /// The article's colors: the button sits on its paper, in its ink, so it reads as part of the page.
    var theme = Reader.Preferences.Theme.auto { didSet { refreshColors() } }

    private let style = IconButton(symbol: "textformat.size", toolTip: String(localized: "Text and Colors", comment: "Tooltip of the button in Reader's bar that shows its text and color choices."))
    private let options = ReaderOptions()
    private var monitor: Any?
    private var isShown = true

    static var side: CGFloat { Tokens.Metric.iconButton }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        addSubview(style)
        style.onClick = { [weak self] _ in self?.toggleOptions() }
        options.onChange = { [weak self] preferences in
            self?.preferences = preferences
            self?.onChange?(preferences)
        }
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        style.frame = bounds
    }

    /// Put away, it takes no clicks: the article under it does.
    override func hitTest(_ point: NSPoint) -> NSView? { isShown ? super.hitTest(point) : nil }

    /// Shown at the top and on the way back up, put away on the way down; never while its panel is open.
    func setShown(_ shown: Bool) {
        guard shown != isShown, options.superview == nil else { return }
        isShown = shown
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Tokens.Motion.quick * Tokens.Motion.debugSlowdown
            ctx.timingFunction = Tokens.Motion.easeOut
            animator().alphaValue = shown ? 1 : 0
        }
    }

    private func refreshColors() {
        // Light, Sepia and Dark are the page's whatever the Mac's look; Auto follows the Mac, as the page does.
        appearance = theme == .auto ? nil : NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        let paper = theme == .auto ? (effectiveAppearance.isDark ? Reader.Palette.dark : .light).paper : theme.palette.paper
        Tokens.Motion.withoutAnimation { layer?.backgroundColor = Tokens.Color.hex(paper).cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    func toggleOptions() {
        if options.superview != nil { hideOptions(); return }
        guard let host = superview else { return }
        setShown(true)
        options.preferences = preferences
        let size = options.panelSize
        // Under the Aa button, its right edge with the button's, but always whole inside the page.
        let margin = Tokens.Space.x3
        let x = min(max(margin, frame.maxX - size.width), host.bounds.width - size.width - margin)
        options.frame = NSRect(x: x, y: frame.maxY + 6, width: size.width, height: size.height)
        options.growsFrom = CGPoint(x: 1, y: 0)
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

    /// Reader closed with the panel open: the panel, and its listener for Esc and clicks, go with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, monitor != nil { hideOptions() }
    }
}

/// How it reads: size, typeface, colours. Four even rows, each one control across the panel: the size buttons, two
/// sliding switches, and the theme swatches.
private final class ReaderOptions: FloatingPanelView {
    var onChange: ((Reader.Preferences) -> Void)?
    var preferences = Reader.Preferences.saved { didSet { refresh() } }

    private let size = ReaderSizeButtons()
    private let face = SlidingSwitch([.styled(String(localized: "Serif", comment: "Choice of typeface in Reader's text and color choices."), NSFont(descriptor: Tokens.Font.body(.medium).fontDescriptor.withDesign(.serif)!, size: Tokens.TypeSize.body)!),
                                      .text(String(localized: "Sans", comment: "Choice of typeface in Reader's text and color choices: sans serif."))])
    private let measure = SlidingSwitch([.text(String(localized: "Narrow", comment: "Choice of column width in Reader's text and color choices.")), .text(String(localized: "Medium", comment: "Choice of column width in Reader's text and color choices.")),
                                         .text(String(localized: "Wide", comment: "Choice of column width in Reader's text and color choices."))])
    private var tiles: [(Reader.Preferences.Theme, ThemeTile)] = []

    static let width: CGFloat = 252
    private static let pad = Tokens.Space.x3, row = Tokens.Metric.rowHeight, gap = Tokens.Space.x2
    var panelSize: NSSize { NSSize(width: Self.width, height: Self.pad * 2 + Self.row * 4 + Self.gap * 3) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        radius = Tokens.Radius.large
        [size, face, measure].forEach { addSubview($0) }
        face.setAccessibilityLabel(String(localized: "Typeface", comment: "VoiceOver label of the typeface choice in Reader's text and color choices."))
        measure.setAccessibilityLabel(String(localized: "Column Width", comment: "VoiceOver label of the column width choice in Reader's text and color choices."))
        for theme in Reader.Preferences.Theme.allCases {
            let tile = ThemeTile(theme: theme)
            tile.onClick = { [weak self] _ in self?.change { $0.theme = theme } }
            addSubview(tile)
            tiles.append((theme, tile))
        }
        size.onPick = { [weak self] larger in self?.change { $0 = $0.stepped(larger ? 1 : -1) } }
        face.onChange = { [weak self] index in self?.change { $0.face = index == 0 ? .serif : .sans } }
        measure.onChange = { [weak self] index in self?.change { $0.width = Reader.Preferences.Width.allCases[index] } }
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
        measure.selectedIndex = Reader.Preferences.Width.allCases.firstIndex(of: preferences.width) ?? 1
        size.canShrink = preferences.size > Reader.Preferences.sizes.lowerBound
        size.canGrow = preferences.size < Reader.Preferences.sizes.upperBound
        for (theme, tile) in tiles { tile.isSelected = theme == preferences.theme }
    }

    private func layoutContent() {
        let pad = Self.pad, inner = bounds.width - pad * 2
        size.frame = NSRect(x: pad, y: pad, width: inner, height: Self.row)
        face.frame = NSRect(x: pad, y: size.frame.maxY + Self.gap, width: inner, height: Self.row)
        measure.frame = NSRect(x: pad, y: face.frame.maxY + Self.gap, width: inner, height: Self.row)
        let y = measure.frame.maxY + Self.gap, gap = Tokens.Space.x2
        let w = (inner - gap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)
        for (i, (_, tile)) in tiles.enumerated() {
            tile.frame = NSRect(x: pad + CGFloat(i) * (w + gap), y: y, width: w, height: Self.row)
        }
    }
}

/// Smaller and larger text: two buttons in one soft track, shaped like the sliding switches under them.
private final class ReaderSizeButtons: NSView {
    var onPick: ((_ larger: Bool) -> Void)?
    var canShrink = true { didSet { setEnabled(smaller, canShrink) } }
    var canGrow = true { didSet { setEnabled(larger, canGrow) } }
    private let smaller = InteractiveView(), larger = InteractiveView()
    private let smallLabel = Label("A", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let largeLabel = Label("A", font: Tokens.Font.title(.semibold), color: Tokens.Color.textPrimary)
    private let divider = ColorView(color: Tokens.Color.separator)
    /// The same gap as `SlidingSwitch`'s, so the corners are concentric with the track's.
    private let inset: CGFloat = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.field + inset
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = cgColor(Tokens.Color.fieldFill)
        addSubview(divider)
        for (button, label, name, larger) in [(smaller, smallLabel, String(localized: "Smaller Text", comment: "VoiceOver label of the button in Reader's text choices that makes the text smaller."), false),
                                                (self.larger, largeLabel, String(localized: "Larger Text", comment: "VoiceOver label of the button in Reader's text choices that makes the text larger."), true)] {
            button.wantsLayer = true
            button.layer?.cornerRadius = Tokens.Radius.field
            button.layer?.cornerCurve = .continuous
            label.alignment = .center
            button.addSubview(label)
            button.setAccessibilityRole(.button)
            button.setAccessibilityLabel(name)
            button.onClick = { [weak self, weak button] _ in
                guard let button, button.isEnabled else { return }
                self?.onPick?(larger)
            }
            button.hoverChanged = { [weak button, weak self] hovering in
                guard let button, let self else { return }
                button.layer?.backgroundColor = hovering && button.isEnabled ? self.cgColor(Tokens.Color.hoverFill) : nil
            }
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func setEnabled(_ button: InteractiveView, _ enabled: Bool) {
        button.isEnabled = enabled
        (button === smaller ? smallLabel : largeLabel).textColor = enabled ? Tokens.Color.textPrimary : Tokens.Color.textTertiary
        if !enabled { button.layer?.backgroundColor = nil }
    }

    override func layout() {
        super.layout()
        let w = (bounds.width - inset * 2) / 2
        for (i, (button, label)) in [(smaller, smallLabel), (larger, largeLabel)].enumerated() {
            button.frame = NSRect(x: inset + CGFloat(i) * w, y: inset, width: w, height: bounds.height - inset * 2)
            label.frame = NSRect(x: 0, y: (button.bounds.height - label.lineHeight) / 2, width: button.bounds.width, height: label.lineHeight)
        }
        divider.frame = NSRect(x: bounds.midX, y: Tokens.Space.x2, width: Tokens.Metric.hairline, height: bounds.height - Tokens.Space.x4)
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

    /// The article's own paper and ink.
    private static func colors(_ theme: Reader.Preferences.Theme) -> (paper: NSColor, ink: NSColor) {
        (Tokens.Color.hex(theme.palette.paper), Tokens.Color.hex(theme.palette.ink))
    }

    private static func name(_ theme: Reader.Preferences.Theme) -> String {
        switch theme {
        case .auto: String(localized: "Auto", comment: "Color choice in Reader: follows the Mac's light or dark look.")
        case .light: String(localized: "Light", comment: "Color choice in Reader.")
        case .sepia: String(localized: "Sepia", comment: "Color choice in Reader: warm paper.")
        case .dark: String(localized: "Dark", comment: "Color choice in Reader.")
        }
    }

    init(theme: Reader.Preferences.Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        let (paper, ink) = Self.colors(theme)
        layer?.backgroundColor = paper.cgColor
        layer?.cornerRadius = Tokens.Radius.field + 3
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = Tokens.Metric.hairline
        layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        if theme == .auto {
            // Rounded on its own outer corners, so it keeps the swatch's shape whatever clips it.
            darkHalf.backgroundColor = Tokens.Color.hex(Reader.Palette.dark.paper).cgColor
            darkHalf.cornerRadius = Tokens.Radius.field + 3
            darkHalf.cornerCurve = .continuous
            darkHalf.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            layer?.addSublayer(darkHalf)
        }
        for (text, color) in [(lightInk, ink), (darkInk, Tokens.Color.hex(Reader.Palette.dark.ink))] {
            text.string = "Aa"
            text.font = NSFont(descriptor: Tokens.Font.body(.semibold).fontDescriptor.withDesign(.serif)!, size: Tokens.TypeSize.body)
            text.fontSize = Tokens.TypeSize.body
            text.alignmentMode = .center
            text.foregroundColor = color.cgColor
            text.contentsScale = 2
            layer?.addSublayer(text)
        }
        darkInk.isHidden = theme != .auto
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.isHidden = true
        layer?.addSublayer(ring)
        toolTip = theme == .auto ? String(localized: "Auto: follows your Mac", comment: "Tooltip of the Auto color choice in Reader: light by day, dark at night, as the Mac is.") : Self.name(theme)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(Self.name(theme))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func stateDidChange(animated: Bool) {
        ring.isHidden = !isSelected
        if isSelected { ring.strokeColor = cgColor(Brand.Theme.for(self).accent) }
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
            // Inside the edge, its corners concentric with the swatch's; in the window's accent, as a field's ring is.
            let r = (layer?.cornerRadius ?? 0) - 1
            ring.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: r, cornerHeight: r, transform: nil)
            ring.strokeColor = cgColor(Brand.Theme.for(self).accent)
        }
    }
}

extension ReaderView: WKNavigationDelegate {
    /// Links in an article open in the page, not inside the reader.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            // A footnote or a heading in the article itself: Reader scrolls to it, and stays.
            if url.fragment != nil, let articleURL,
               url.absoluteString.prefix(while: { $0 != "#" }) == articleURL.absoluteString.prefix(while: { $0 != "#" }) {
                return .allow
            }
            switch Reader.route(for: url) {
            case .browse: break
            case .externalApp:
                ExternalLinks.open(url, isMainFrame: true, isClick: true, from: webView)
                return .cancel
            case .ignore:
                return .cancel
            }
            let flags = navigationAction.modifierFlags
            // The same as on any page: ⌘ for a tab behind, ⌘⇧ for one in front, ⇧ alone to peek.
            if flags.contains(.command) || navigationAction.buttonNumber == 4 {
                if flags.contains(.shift) { onForegroundLink?(url) } else { onBackgroundLink?(url) }
            } else if flags.contains(.shift) { onPeekLink?(url) }
            else { onOpenLink?(url) }
            return .cancel
        }
        // Nothing else leaves the article for a file on your Mac, whatever the article's markup tries.
        if let url = navigationAction.request.url, url.isFileURL, url != articleURL { return .cancel }
        return .allow
    }
}
