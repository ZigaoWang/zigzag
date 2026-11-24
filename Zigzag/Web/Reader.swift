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

    /// Readability itself plus a small helper that says whether a page looks like an article. Read from the app once,
    /// not for every page made.
    static let scripts: [WKUserScript] = {
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
                // A local file has no host: its name, as the address shows it.
                const name = host || decodeURIComponent(location.pathname.split('/').pop() || '');
                return own && own.length <= 28 && !/\\b(inc|llc|ltd|foundation|corporation)\\b/i.test(own) ? own : name;
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
              // The header names the author; the article's own "By …" line would say it twice.
              (\(Reader.repeatedBylineScript))(body, article.byline || '', siteName());
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
    }()

    /// Takes out the article's opening line when it only names the author the header shows: "By Ada Palmer" under a
    /// header that says Ada Palmer. Compared without case, "By" or extra spaces, and only among the first few blocks,
    /// never inside a paragraph, so the text itself is left alone.
    static let repeatedBylineScript = #"""
    (root, byline, site) => {
      const norm = s => (s || '').normalize('NFKC').replace(/\s+/g, ' ').trim().toLowerCase()
        .replace(/^(?:(?:written|posted|words|story)\s+)?by\s+|^作者\s*[:：]?\s*/, '')
        .replace(/^[\s|\-–—·•,:：/]+|[\s|\-–—·•,:：/]+$/g, '');
      const name = norm(byline);
      if (name.length < 2 || name.length > 60 || /contributors|http|@/.test(name) || name === norm(site)) return;
      let blocks = 0;
      const visit = parent => {
        for (const el of [...parent.children]) {
          const text = norm(el.textContent);
          if (!text) { if (el.matches('img, picture, figure, video, svg')) blocks++; continue; }
          if (text === name) { el.remove(); return true; }
          if (el.matches('p, h1, h2, h3, h4, h5, h6, li, ul, ol, dl, blockquote, pre, table, figure')) {
            if (++blocks >= 3) return true;
            continue;
          }
          if (visit(el)) return true;
        }
        return false;
      };
      visit(root);
    }
    """#

    private static func resource(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Reads the article ahead of time, while the page is idle, so Reader opens at once.
    static func prepare(_ webView: WKWebView) {
        webView.runOwnScript("window.__zigzagReader && window.__zigzagReader.prepare(); 0")
    }

    /// Whether the page in a web view looks like an article.
    static func isArticle(_ webView: WKWebView) async -> Bool {
        let result = try? await webView.runOwnScript("window.__zigzagReader ? window.__zigzagReader.isArticle() : false")
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
        guard let json = try? await webView.runOwnScript("window.__zigzagReader ? window.__zigzagReader.take() : null") as? String,
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

        /// Space's: the space's own paper (`Theme.spacePaper`), with inks of its hue solved against it: body text at
        /// 11:1 where the paper allows and never under 7:1, links at 7:1, soft words at 4.6:1.
        static func space(paper: NSColor, hue: Double?) -> Palette {
            // Judged as the page draws it, in whole bytes.
            let ground = Tokens.Color.hex(Reader.hex(paper))
            let isDark = Brand.relativeLuminance(ground) < 0.18
            let h = hue ?? Brand.navyHue
            // From a starting lightness toward black (or white) until it reads.
            func solved(_ start: Double, chroma: Double, target: Double) -> UInt32 {
                var l = start
                var ink = Reader.hex(SpaceColor.tone(hue: h, lightness: l, chroma: chroma))
                while Brand.contrast(Tokens.Color.hex(ink), ground) < target, isDark ? l < 1 : l > 0 {
                    l = isDark ? min(1, l + 0.01) : max(0, l - 0.01)
                    ink = Reader.hex(SpaceColor.tone(hue: h, lightness: l, chroma: chroma))
                }
                return ink
            }
            let tinted = hue == nil ? 0.0 : 1.0
            let ink = solved(isDark ? 0.93 : 0.25, chroma: 0.015 * tinted, target: 11)
            let soft = solved(isDark ? 0.74 : 0.52, chroma: 0.025 * tinted, target: 4.6)
            let link = solved(isDark ? 0.82 : 0.45, chroma: 0.1, target: 7)
            func rgba(_ v: UInt32, _ alpha: Double) -> String { "rgba(\(v >> 16 & 0xFF),\(v >> 8 & 0xFF),\(v & 0xFF),\(alpha))" }
            return Palette(paper: Reader.hex(ground), ink: ink, soft: soft, link: link, rule: rgba(ink, 0.13),
                           code: rgba(ink, 0.06), select: rgba(link, isDark ? 0.28 : 0.2), isDark: isDark)
        }

        /// The page's colors as CSS custom properties.
        var css: String {
            func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }
            return "--paper: \(hex(paper)); --ink: \(hex(ink)); --soft: \(hex(soft)); --link: \(hex(link)); " +
                "--rule: \(rule); --code: \(code); --select: \(select); color-scheme: \(isDark ? "dark" : "light");"
        }
    }

    /// Auto's paper by day and at night: a breath of the window's space, or the plain Light and Dark papers in a
    /// white, gray or black one. The inks stay the palettes', so the text keeps its contrast.
    struct AutoPaper: Equatable {
        var light = Palette.light.paper
        var dark = Palette.dark.paper

        static func of(_ theme: Brand.Theme) -> AutoPaper {
            guard let paper = theme.readerPaper else { return AutoPaper() }
            return AutoPaper(light: hex(paper.light), dark: hex(paper.dark))
        }

        var css: String { String(format: ":root { --tint: #%06X; --tint-dark: #%06X; }", light, dark) }

        func paper(dark isDark: Bool) -> UInt32 { isDark ? dark : light }
    }

    /// Space's palettes by day and at night, from the window's space.
    struct SpaceColors: Equatable {
        var light = Palette.space(paper: Tokens.Color.hex(Palette.light.paper), hue: nil)
        var dark = Palette.space(paper: Tokens.Color.hex(Palette.dark.paper), hue: nil)

        static func of(_ space: SpaceInfo?) -> SpaceColors {
            guard let space else { return SpaceColors() }
            let paper = Brand.Theme.spacePaper(space), hue = Brand.Theme.of(space).surfaceHue
            return SpaceColors(light: .space(paper: paper.light, hue: hue), dark: .space(paper: paper.dark, hue: hue))
        }

        func palette(dark isDark: Bool) -> Palette { isDark ? dark : light }

        var css: String {
            ":root[data-theme=\"space\"] { \(light.css) }\n@media (prefers-color-scheme: dark) { :root[data-theme=\"space\"] { \(dark.css) } }"
        }
    }

    /// The colors that follow the space, in a style sheet of their own so they can change in place.
    static func colorsCSS(paper: AutoPaper, space: SpaceColors) -> String { paper.css + "\n" + space.css }

    static func hex(_ color: NSColor) -> UInt32 {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }

    /// How you like to read, remembered for every article: text size, typeface, column width and colors.
    struct Preferences: Equatable {
        enum Face: String, CaseIterable { case serif, sans }
        enum Theme: String, CaseIterable {
            case auto, light, sepia, dark, space
            /// Auto's are Light's; the page takes Dark's itself while the Mac is dark. Space's come from the space
            /// (`SpaceColors`).
            var palette: Palette { switch self { case .auto, .light, .space: .light; case .sepia: .sepia; case .dark: .dark } }
        }
        /// How wide the column runs, in the text's own size, so a line holds about the same number of characters at
        /// any size: Narrow a column's 55 or so, Medium the book's 66 to 72, Wide the whole window inside its margins.
        enum Width: String, CaseIterable {
            case narrow, medium, wide
            var measure: String { switch self { case .narrow: "28rem"; case .medium: "34rem"; case .wide: "100vw" } }
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

        /// Applies these to an open reading page without reloading it, keeping the line you were on in place while
        /// the text reflows.
        var script: String {
            "(() => { const d = document.documentElement;" +
            "const a = [...document.querySelectorAll('main :is(p, li, h1, h2, h3, h4, figure, pre, blockquote, table)')].find(e => e.getBoundingClientRect().bottom > 0);" +
            "const top = a ? a.getBoundingClientRect().top : 0;" +
            "d.dataset.theme='\(theme.rawValue)';d.dataset.face='\(face.rawValue)';" +
            "d.style.setProperty('--size','\(size)px');d.style.setProperty('--measure','\(width.measure)');" +
            "if (a && scrollY > 0) scrollBy(0, a.getBoundingClientRect().top - top); })(); 0"
        }
    }

    /// Whether the page's Aa button shows: at the top, on the way back up, with the pointer near the top and while
    /// its panel is open. Reading on down the article puts it away.
    struct ButtonPresence: Equatable {
        /// How far down still counts as the top, and how far a scroll runs before it counts as a direction.
        static let top: CGFloat = 8, slack: CGFloat = 8
        var panelOpen = false
        var pointerNearTop = false {
            // Brought back by the pointer, it stays until you read on.
            didSet { if pointerNearTop { scrolledShown = true } }
        }
        private(set) var atTop = true
        private var scrolledShown = true
        private var anchor: CGFloat = 0

        var isShown: Bool { panelOpen || pointerNearTop || atTop || scrolledShown }

        /// The page scrolled to `y`, from its top.
        mutating func scrolled(to y: CGFloat) {
            atTop = y <= Self.top
            if atTop {
                scrolledShown = true
                anchor = y
            } else if y >= anchor + Self.slack {
                scrolledShown = false
                anchor = y
            } else if y <= anchor - Self.slack {
                scrolledShown = true
                anchor = y
            }
        }
    }

    /// The reading page: one column at the chosen measure, its words on that column's left edge, with large pictures
    /// and code free to run wider when the window has room. The header is where it's from, the title, and who wrote
    /// it and when, if the page says; then the text. `reducedMotion`: the text doesn't settle in as it opens.
    static func html(for article: Article, preferences: Preferences = .saved, icon: String? = nil, locale: Locale = .current,
                     paper: AutoPaper = AutoPaper(), space: SpaceColors = SpaceColors(), reducedMotion: Bool = false) -> String {
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
        <!doctype html><html lang="\(escape(lang))" data-theme="\(preferences.theme.rawValue)" data-face="\(preferences.face.rawValue)"\(reducedMotion ? " data-motion=\"reduce\"" : "") style="\(preferences.rootStyle)">
        <head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'; font-src *">
        <title>\(escape(title))</title>
        <style id="zigzag-colors">\(colorsCSS(paper: paper, space: space))</style>
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
            --face: var(--serif); --leading: 1.6;
            /* One line of the text: every space between blocks is a share of it. */
            --line: calc(var(--leading) * 1rem);
            font-size: var(--size, 20px);
            /* The page's margins: Zigzag's page gutter in a small window, generous in a big one. */
            --gutter: clamp(\(Int(Tokens.Page.gutter))px, 6vw, 112px);
            /* How far pictures may run past the text on each side: what the window leaves, up to 8rem. */
            --bleed: clamp(0px, (100vw - var(--measure, 34rem)) / 2 - var(--gutter), 8rem);
            --code-bleed: min(var(--bleed), 2.5rem); }
    :root[data-theme="auto"] { --paper: var(--tint, #\(String(format: "%06X", Palette.light.paper))); }
    :root[data-theme="sepia"] { \(Palette.sepia.css) }
    :root[data-theme="dark"] { \(Palette.dark.css) }
    @media (prefers-color-scheme: dark) { :root[data-theme="auto"] { \(Palette.dark.css) --paper: var(--tint-dark, #\(String(format: "%06X", Palette.dark.paper))); } }
    :root[data-face="sans"] { --face: var(--sans); --leading: 1.58; }
    /* Their own faces (there are no italics to fake), and more air between lines. */
    :root:lang(zh) { --serif: "Reader SC", ui-serif, serif; --sans: "Reader SC", system-ui, sans-serif; }
    :root:is(:lang(zh-Hant), :lang(zh-TW), :lang(zh-HK)) { --serif: "Reader TC", ui-serif, serif; --sans: "Reader TC", system-ui, sans-serif; }
    :root:lang(ja) { --serif: "Reader JA", ui-serif, serif; --sans: "Reader JA", system-ui, sans-serif; }
    :root:lang(ko) { --serif: "Reader KO", ui-serif, serif; --sans: "Reader KO", system-ui, sans-serif; }
    :root:is(:lang(zh), :lang(ja), :lang(ko)) { --leading: 1.8; }
    :is(:lang(zh), :lang(ja), :lang(ko)) :is(em, i, cite, dfn) { font-style: normal; font-weight: 600; }

    html { background: var(--paper); overflow-x: hidden; }
    ::selection { background: var(--select); }
    body { margin: 0; padding: 80px var(--gutter) 120px; color: var(--ink); font-family: var(--face); font-size: 1rem;
           line-height: var(--leading); -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
           font-kerning: normal; hanging-punctuation: first allow-end last; overflow-wrap: break-word;
           -webkit-hyphens: auto; hyphens: auto; }
    main { max-width: var(--measure, 34rem); margin: 0 auto; }

    /* Opening, the text settles up into place as the paper fades in (Motion's enter, eased out); never with Reduce Motion. */
    @keyframes reader-in { from { opacity: 0; transform: translateY(\(Int(Tokens.Motion.edgeOffset))px); } }
    main { animation: reader-in \(Int(Tokens.Motion.enter * 1000))ms cubic-bezier(0.23, 1, 0.32, 1); }
    :root[data-motion="reduce"] main { animation: none; }
    @media (prefers-reduced-motion: reduce) { main { animation: none; } }

    /* The header: where it's from, the title, who and when, in quiet steps of half a line. A line and a half below it, no rule. */
    header { margin: 0 0 calc(var(--line) * 1.5); }
    .site { display: flex; align-items: center; gap: 8px; margin: 0 0 calc(var(--line) * .5); font: 500 \(Int(Tokens.TypeSize.body))px/1.4 var(--sans); color: var(--soft); }
    .site img { display: block; width: 16px; height: 16px; margin: 0; transform: none; border-radius: \(Int(Tokens.Radius.small) - 1)px; flex: none; }
    h1.title { margin: 0; font-size: 1.75em; line-height: 1.2; font-weight: 600; letter-spacing: -0.012em; text-wrap: balance; -webkit-hyphens: manual; hyphens: manual; }
    :root:is(:lang(zh), :lang(ja), :lang(ko)) h1.title { line-height: 1.35; letter-spacing: 0; }
    .byline { display: flex; flex-wrap: wrap; column-gap: 12px; margin: calc(var(--line) * .5) 0 0; font: \(Int(Tokens.TypeSize.body))px/1.45 var(--sans); color: var(--soft); }
    .byline .author { font-weight: 500; }

    /* The text's rhythm, in shares of a line: three quarters between paragraphs, a line around pictures, quotes and
       code, a line and a half over a heading and half a line under it, so it sits with what it heads. */
    article > :first-child { margin-top: 0; }
    p, ul, ol, dl, details { margin: 0 0 calc(var(--line) * .75); }
    p { text-wrap: pretty; }
    h2, h3, h4, h5, h6 { margin: calc(var(--line) * 1.5) 0 calc(var(--line) * .5); line-height: 1.3; font-weight: 600; letter-spacing: -0.006em; text-wrap: balance;
                         -webkit-hyphens: manual; hyphens: manual; }
    h2 { font-size: 1.3em; } h3 { font-size: 1.1em; } h4, h5, h6 { font-size: 1em; }
    :is(h2, h3, h4) + :is(h3, h4, h5) { margin-top: calc(var(--line) * .75); }
    article h1 { font-size: 1.3em; margin: calc(var(--line) * 1.5) 0 calc(var(--line) * .5); line-height: 1.3; font-weight: 600; }

    /* Links read as part of the sentence: the text's own color over a thin underline in the link color, all link color
       when pointed at. */
    a { color: inherit; text-decoration: underline 1px; text-underline-offset: .22em;
        text-decoration-color: color-mix(in srgb, var(--link) 50%, transparent); }
    a:hover { color: var(--link); text-decoration-color: currentColor; }
    :is(h1, h2, h3, h4, h5, h6) a, figure a { text-decoration: none; }

    /* Pictures at their own size, never bigger, centered on the column; a large one runs past the text into the
       margins as far as the window allows. A caption small and quiet under each, on the text's edge. */
    img, video, picture, svg, canvas { max-width: 100%; height: auto; }
    img, video { display: block; max-width: calc(100% + 2 * var(--bleed)); margin: var(--line) 0 var(--line) 50%; transform: translateX(-50%); border-radius: \(Int(Tokens.Radius.thumbnail))px; }
    img.inline { display: inline; max-width: 100%; margin: 0; transform: none; vertical-align: middle; border-radius: 0; }
    figure { margin: var(--line) calc(-1 * var(--bleed)); }
    figure :is(img, video) { max-width: 100%; margin: 0 auto; transform: none; }
    figure > a, picture { display: block; }
    figcaption { max-width: 40rem; margin: calc(var(--line) * .375) 0 0; padding: 0 var(--bleed); font: \(Int(Tokens.TypeSize.row))px/1.45 var(--sans); color: var(--soft); text-wrap: pretty; -webkit-hyphens: manual; hyphens: manual; }
    /* Inside a list, a quote or a table, pictures and code keep to their box. */
    :is(li, blockquote, td, th, dd) :is(img, video) { max-width: 100%; margin-left: 0; transform: none; }
    :is(li, blockquote, td, th, dd) figure { margin-inline: 0; }
    :is(li, blockquote, td, th, dd) figcaption { padding: 0; }
    :root:is(:lang(zh), :lang(ja), :lang(ko)) figcaption { line-height: 1.6; }
    figcaption p { margin: 0; }
    /* Picture galleries come as lists: no bullets, just the pictures. */
    :is(ul, ol):has(> li img) { list-style: none; padding: 0; }
    li:has(> img, > figure, > a > img) { margin: 0; }

    blockquote { margin: var(--line) 0; padding: 0 0 0 1.1em; border-left: 2px solid var(--rule); color: var(--soft); }
    blockquote > :last-child { margin-bottom: 0; }

    code, kbd, samp, pre { font-family: var(--mono); font-size: .82em; -webkit-hyphens: none; hyphens: none; }
    code, kbd { padding: .08em .3em; border-radius: \(Int(Tokens.Radius.small))px; background: var(--code); }
    /* Code's box hangs into the margins when there's room, its first column on the text's edge, so long lines get
       more room before they scroll. */
    pre { margin: var(--line) calc(-1 * var(--code-bleed)); padding: 14px 16px 14px max(16px, var(--code-bleed)); border-radius: \(Int(Tokens.Radius.field))px;
          background: var(--code); line-height: 1.55; overflow-x: auto; white-space: pre; tab-size: 4; }
    :is(li, blockquote, td, th, dd) pre { margin-inline: 0; padding-left: 16px; }
    pre code { padding: 0; background: none; font-size: inherit; }

    table { display: block; width: max-content; max-width: calc(100% + var(--bleed)); overflow-x: auto; margin: var(--line) 0; border-collapse: collapse;
            font: 15px/1.5 var(--sans); }
    th, td { padding: 7px 16px 7px 0; border-bottom: 1px solid var(--rule); text-align: left; vertical-align: top; }
    th { font-weight: 600; }
    caption { caption-side: bottom; margin-top: .6em; text-align: left; font-size: 14px; color: var(--soft); }

    ul, ol { padding-left: 1.4em; }
    li { margin: calc(var(--line) * .25) 0; } li > :is(p, ul, ol) { margin: calc(var(--line) * .25) 0; }
    li::marker { color: var(--soft); }
    dt { font-weight: 600; } dd { margin: 0 0 calc(var(--line) * .5) 1.4em; }
    hr { height: 1px; margin: calc(var(--line) * 1.5) 0; border: 0; background: var(--rule); }
    sup, sub { line-height: 0; font-size: .7em; }
    abbr[title] { text-decoration: none; }

    .end { margin-top: calc(var(--line) * 2); padding-top: calc(var(--line) * .75); border-top: 1px solid var(--rule); font: \(Int(Tokens.TypeSize.body))px/1.45 var(--sans); color: var(--soft); }
    .end a { color: inherit; }

    /* Leftovers from the page that don't belong in reading. */
    button, input, select, textarea, form, iframe, nav, aside, [role="button"], [aria-hidden="true"] { display: none !important; }

    /* On paper: black on white whatever the theme, the page's margins, nothing split across a page break. */
    @page { margin: 18mm 20mm; }
    @media print {
      :root, :root[data-theme] { \(Palette.light.css) --ink: #000; --bleed: 0px; --code-bleed: 0px; }
      html, body { background: #fff; }
      body { padding: 0; font-size: 11.5pt; }
      main { max-width: none; animation: none; }
      pre { padding-left: 16px; }
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

/// The reading surface shown over a page card: the article, and Aa in its top-right corner for how it reads
/// (`ReaderOptions`), as Apple Books keeps its choices on the page. The address's Reader button only turns it on and off.
final class ReaderView: NSView {
    let webView: WKWebView
    var onClose: (() -> Void)?
    var onOpenLink: ((URL) -> Void)?
    /// Shift-click: the link in Zigzag Mini, over the article. ⌘-click: a tab in the background.
    var onPeekLink: ((URL) -> Void)?
    var onBackgroundLink: ((URL) -> Void)?
    var onForegroundLink: ((URL) -> Void)?
    /// Aa pressed: the window opens or closes the panel under it.
    var onOptions: (() -> Void)?
    /// How it reads now, as shown.
    private(set) var preferences = Reader.Preferences.saved
    /// Auto's paper, the space's breath of color, for the panel's swatches.
    private(set) var paper = Reader.AutoPaper()
    /// Space's palettes, from the window's space.
    private(set) var spaceColors = Reader.SpaceColors()
    /// The window's space now, read again whenever a space or its color changes.
    var currentSpace: (() -> SpaceInfo?)?
    private var themeToken: SignalToken?
    /// The page the article came from: the reading page's own address, the one load it makes by itself.
    private var articleURL: URL?
    let optionsButton = ReaderOptionsButton()
    private(set) var presence = Reader.ButtonPresence() { didSet { if presence != oldValue { optionsButton.setShown(presence.isShown) } } }
    private var topArea: NSTrackingArea?
    private static let buttonInset = Tokens.Space.x4

    /// `store`: the one the page it reads is in (its profile's, or its private window's).
    init(store: WKWebsiteDataStore) {
        webView = WKWebView(frame: .zero, configuration: Self.configuration(store: store))

        super.init(frame: .zero)
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        addSubview(optionsButton)
        optionsButton.button.onClick = { [weak self] _ in
            guard let self, !self.touchSwallow.takes() else { return }
            self.onOptions?()
        }
        if TouchGestures.isAvailable { addTouchWatch() }
        // The page's own scripts are off; this one, in Zigzag's world, says where it's scrolled to.
        let scroll = ScrollMessages()
        scroll.reader = self
        let content = webView.configuration.userContentController
        content.add(scroll, contentWorld: .defaultClient, name: ScrollMessages.name)
        content.addUserScript(WKUserScript(source: ScrollMessages.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// ⌘+ and ⌘−: the text a step bigger or smaller (0 back to the usual), kept for every article. Returns the new
    /// choices.
    @discardableResult
    func stepTextSize(_ delta: Int) -> Reader.Preferences {
        let next = preferences.stepped(delta)
        apply(next)
        return next
    }

    /// New choices, kept for every article and applied to this one at once.
    func apply(_ preferences: Reader.Preferences) {
        self.preferences = preferences
        Reader.Preferences.saved = preferences
        // The page's own scripts are off; this runs in Zigzag's world, so the change is instant.
        webView.runOwnScript(preferences.script)
        refreshButton()
        ReaderOptions.showing(preferences, for: self)
    }

    /// In the store of the page it reads, so the article's pictures are fetched as the page fetched them: one store
    /// shared by every reading page would carry a site's cookies from one profile to another, and out of a private
    /// window. Scripts stay off.
    static func configuration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = store
        FeatureFlags.applyOwn(to: configuration.preferences)
        return configuration
    }

    /// A reading page kept loaded in the background in the store Reader will next use, so its web process is
    /// already up when Reader opens, most of a second sooner. Not for a private window: it would keep the window's
    /// store, and what's in it, after the window closes.
    /// One for each of the last few stores, so articles in two profiles one after the other don't make a new web
    /// view each time (#89).
    private static var warm: [WKWebView] = []
    static func prewarm(for store: WKWebsiteDataStore) {
        guard store.isPersistent, !warm.contains(where: { $0.configuration.websiteDataStore === store }) else { return }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration(store: store))
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        warm.append(view)
        if warm.count > 3 { warm.removeFirst() }
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        let side = ReaderOptionsButton.side
        optionsButton.frame = NSRect(x: bounds.width - side - Self.buttonInset, y: Self.buttonInset, width: side, height: side)
    }

    /// The band along the top where the pointer brings Aa back.
    private var topBand: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.buttonInset * 2 + ReaderOptionsButton.side + Tokens.Space.x4)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let topArea { removeTrackingArea(topArea) }
        let area = NSTrackingArea(rect: topBand, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        topArea = area
    }

    override func mouseEntered(with event: NSEvent) { presence.pointerNearTop = true }
    override func mouseExited(with event: NSEvent) { presence.pointerNearTop = false }

    /// The click from a tap on Aa while it was hidden: the tap only shows it.
    private var touchSwallow = TouchSwallow()

    private func addTouchWatch() {
        let watch = TouchWatch()
        watch.onDown = { [weak self] point in self?.touchDown(at: point) }
        watch.onTap = { [weak self] point in self?.touchTapped(at: point) }
        addGestureRecognizer(watch)
    }

    func touchDown(at windowPoint: NSPoint) {
        if !presence.isShown, optionsButton.frame.contains(convert(windowPoint, from: nil)) { touchSwallow.arm() }
    }

    /// A tap along the top brings Aa back, as the pointer there does, and it stays until you read on.
    func touchTapped(at windowPoint: NSPoint) {
        touchSwallow.disarm()
        guard topBand.contains(convert(windowPoint, from: nil)) else { return }
        presence.pointerNearTop = true
        presence.pointerNearTop = false
    }

    #if DEBUG
    func debugPointerNearTop(_ near: Bool) { presence.pointerNearTop = near }
    #endif

    /// The page scrolled: Aa goes as you read on and comes back on the way up.
    func scrolled(to y: CGFloat) { presence.scrolled(to: y) }

    /// The panel opened or closed: Aa stays while it's open.
    func optionsShown(_ open: Bool) {
        presence.panelOpen = open
        optionsButton.button.isSelected = open
    }

    /// Auto's breath of color and Space's palettes come from `currentSpace`.
    func show(_ article: Reader.Article, from url: URL, icon: NSImage? = nil) {
        articleURL = url
        webView.navigationDelegate = self
        preferences = Reader.Preferences.saved
        let space = currentSpace?()
        paper = Reader.AutoPaper.of(Brand.Theme.of(space))
        spaceColors = Reader.SpaceColors.of(space)
        presence = Reader.ButtonPresence()
        optionsButton.setShown(true, animated: false)
        refreshButton()
        webView.loadHTMLString(Reader.html(for: article, preferences: preferences, icon: Reader.iconSource(icon), paper: paper,
                                           space: spaceColors, reducedMotion: Tokens.Motion.reduceMotion), baseURL: url)
        themeToken = Brand.themeChanged.observe { [weak self] in self?.spaceDidChange() }
    }

    /// Another space, or a new color for this one: the page's colors change in place, and the panel's swatches.
    private func spaceDidChange() {
        let space = currentSpace?()
        let paper = Reader.AutoPaper.of(Brand.Theme.of(space)), colors = Reader.SpaceColors.of(space)
        guard paper != self.paper || colors != spaceColors else { return }
        self.paper = paper
        spaceColors = colors
        refreshButton()
        let css = Reader.colorsCSS(paper: paper, space: colors)
        guard let data = try? JSONEncoder().encode(css), let literal = String(data: data, encoding: .utf8) else { return }
        webView.runOwnScript("(() => { const s = document.getElementById('zigzag-colors'); if (s) s.textContent = \(literal); })(); 0")
        ReaderOptions.colorsChanged(for: self)
    }

    /// Aa on the article's paper, in the light or dark look that paper reads in.
    private func refreshButton() {
        let isDark = effectiveAppearance.isDark
        let theme = preferences.theme
        let palette = theme == .space ? spaceColors.palette(dark: isDark) : theme.palette
        let paper = theme == .auto ? self.paper.paper(dark: isDark) : palette.paper
        let dark = theme == .auto ? isDark : theme == .space ? palette.isDark : theme == .dark
        optionsButton.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        optionsButton.paper = Tokens.Color.hex(paper)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshButton()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Reader closed with its panel open: the panel, and its listener for Esc and clicks, go with it.
        if window == nil { ReaderOptions.close(for: self) }
    }

    /// Where the reading page is scrolled to, from a script in Zigzag's world, once a frame at most.
    private final class ScrollMessages: NSObject, WKScriptMessageHandler {
        static let name = "zigzagReaderScroll"
        static let script = "(() => { let f = 0; addEventListener('scroll', () => { if (f) return; f = requestAnimationFrame(() => { f = 0;" +
            " webkit.messageHandlers.\(name).postMessage(scrollY); }); }, { passive: true }); })();"
        weak var reader: ReaderView?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let y = message.body as? Double else { return }
            reader?.scrolled(to: CGFloat(y))
        }
    }
}

/// Aa, alone in the reading page's top-right corner: a quiet icon button as the toolbar's, on the article's own
/// paper so the text never shows through it. Put away, it takes no clicks.
final class ReaderOptionsButton: NSView {
    static var side: CGFloat { Tokens.Metric.iconButton }
    let button = IconButton(symbol: "textformat.size", toolTip: String(localized: "Reader Text and Colors", comment: "View menu item: opens Reader's text size, typeface, column width and color choices."))
    var paper: NSColor = .clear {
        didSet {
            button.ground = paper
            effectiveAppearance.performAsCurrentDrawingAppearance { Tokens.Motion.withoutAnimation { layer?.backgroundColor = paper.cgColor } }
        }
    }
    private(set) var isShown = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = button.radius
        layer?.cornerCurve = .continuous
        button.isOnPage = true
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        button.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isShown ? super.hitTest(point) : nil }
    override func isAccessibilityHidden() -> Bool { !isShown }

    /// Fades in or out as a change of state; with Reduce Motion it shows and goes at once.
    func setShown(_ shown: Bool, animated: Bool = true) {
        guard shown != isShown || !animated else { return }
        isShown = shown
        let time = animated && !Tokens.Motion.reduceMotion ? Tokens.Motion.Role.state.duration() * Tokens.Motion.debugSlowdown : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = time
            ctx.timingFunction = Tokens.Motion.easeOut
            (time > 0 ? animator() : self).alphaValue = shown ? 1 : 0
        }
    }
}

/// How it reads, as the site panel's rows: each choice named on the left, its control on the right. Text size
/// steps as the page's zoom does, the face and the width slide, and the colors are a row of round dots. Hangs
/// under the page's Aa button, as Site Controls hangs from its own.
final class ReaderOptions: FloatingPanelView {
    private static weak var current: ReaderOptions?
    static func isOpen(in window: NSWindow?) -> Bool { current?.superview != nil && current?.window === window }
    static func closeCurrent() { current?.close() }
    /// The panel open for a reading page, if any.
    static func close(for reader: ReaderView) { if current?.reader === reader { current?.close() } }
    /// ⌘+ or ⌘− while it's open: its stepper follows.
    static func showing(_ preferences: Reader.Preferences, for reader: ReaderView) {
        if let current, current.reader === reader { current.preferences = preferences }
    }
    /// The space or its color changed while it's open: Auto's and Space's dots follow.
    static func colorsChanged(for reader: ReaderView) {
        guard let current, current.reader === reader else { return }
        current.swatches.paper = reader.paper
        current.swatches.spaceColors = reader.spaceColors
    }

    private var preferences = Reader.Preferences.saved { didSet { refresh() } }
    private weak var reader: ReaderView?
    /// Where it goes for its size, worked out again as the window resizes.
    private var place: ((NSSize) -> NSPoint)?
    private var monitor: Any?

    private let size = ZoomStepper()
    private let face = SlidingSwitch([.styled(String(localized: "Serif", comment: "Choice of typeface in Reader's text and color choices."), NSFont(descriptor: Tokens.Font.body(.medium).fontDescriptor.withDesign(.serif)!, size: Tokens.TypeSize.body)!),
                                      .text(String(localized: "Sans", comment: "Choice of typeface in Reader's text and color choices: sans serif."))])
    private let measure = SlidingSwitch([.text(String(localized: "Narrow", comment: "Choice of column width in Reader's text and color choices.")), .text(String(localized: "Medium", comment: "Choice of column width in Reader's text and color choices.")),
                                         .text(String(localized: "Wide", comment: "Choice of column width in Reader's text and color choices."))])
    private let swatches = ReaderSwatches()
    private var rows: [PanelRow] = []

    static let width: CGFloat = 336
    /// The site panel's margins, counted to the words' and controls' ink.
    private static let pad = Tokens.Space.x4
    private var inkTop: CGFloat { rows.first?.topSlack ?? 0 }
    private var inkBottom: CGFloat { rows.last?.bottomSlack ?? 0 }
    var panelSize: NSSize {
        NSSize(width: Self.width, height: ceil(Self.pad * 2 + PanelRow.height * CGFloat(rows.count) - inkTop - inkBottom))
    }

    /// Opens the panel for `reader` in `overlay` under its Aa button, or closes the one open. `place`: its top-left
    /// corner for its size.
    static func toggle(for reader: ReaderView, in overlay: NSView, place: @escaping (NSSize) -> NSPoint) {
        if let current, current.superview != nil {
            let same = current.reader === reader
            current.close()
            if same { return }
        }
        let panel = ReaderOptions(frame: .zero)
        panel.reader = reader
        panel.place = place
        panel.preferences = reader.preferences
        panel.swatches.paper = reader.paper
        panel.swatches.spaceColors = reader.spaceColors
        let size = panel.panelSize
        panel.frame = NSRect(origin: place(size), size: size)
        overlay.addSubview(panel)
        let opener = reader.optionsButton
        if opener.window != nil {
            let b = opener.convert(opener.bounds, to: overlay)
            panel.growsFrom = CGPoint(x: min(max((b.midX - panel.frame.minX) / size.width, 0), 1), y: 0)
        } else {
            panel.growsFrom = CGPoint(x: 1, y: 0)
        }
        panel.present(arrival: .pop)
        reader.optionsShown(true)
        current = panel
        panel.monitor = TouchPress.addMonitor(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak panel] event in
            guard let panel else { return event }
            return panel.handle(event)
        }
    }

    /// In its own window only: Esc closes it; a click outside it and its button closes it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, MenuPanel.current == nil else { return event }
        if event.type == .keyDown {
            if event.keyCode == 53 { close(); return nil }
            return event
        }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let onOpener = reader.map { $0.optionsButton.bounds.contains($0.optionsButton.convert(event.locationInWindow, from: nil)) } ?? false
        if !inside && !onOpener { close() }
        return event
    }

    func close() {
        if let monitor { TouchPress.removeMonitor(monitor) }
        monitor = nil
        reader?.optionsShown(false)
        if Self.current === self { Self.current = nil }
        dismiss()
    }

    /// The window grew or shrank under it: back under its button.
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        guard let place, monitor != nil else { return }
        frame.origin = place(frame.size)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityLabel(String(localized: "Reader Text and Colors", comment: "View menu item: opens Reader's text size, typeface, column width and color choices."))
        let typeface = String(localized: "Typeface", comment: "VoiceOver label of the typeface choice in Reader's text and color choices.")
        let width = String(localized: "Column Width", comment: "VoiceOver label of the column width choice in Reader's text and color choices.")
        let colors = String(localized: "Colors", comment: "Row in Reader's text and color choices: the paper and ink the article is shown in.")
        face.setAccessibilityLabel(typeface)
        measure.setAccessibilityLabel(width)
        swatches.setAccessibilityLabel(colors)
        size.steps = stride(from: Reader.Preferences.sizes.lowerBound, through: Reader.Preferences.sizes.upperBound, by: Reader.Preferences.step)
            .map { CGFloat($0) / CGFloat(Reader.Preferences.defaultSize) }
        size.reset = { 1 }
        size.lessTip = String(localized: "Smaller Text", comment: "VoiceOver label of the button in Reader's text choices that makes the text smaller.")
        size.moreTip = String(localized: "Larger Text", comment: "VoiceOver label of the button in Reader's text choices that makes the text larger.")
        size.resetTip = String(localized: "Actual Size", comment: "Tooltip of the percentage on the Zoom row of the site panel: sets the page back to 100%.")
        size.percentName = String(localized: "Text %@, Actual Size", comment: "VoiceOver name of the percentage on Reader's Text Size row: the size now, then what pressing it does.")
        size.typingTip = nil
        rows = [.custom(String(localized: "Text Size", comment: "Row in Reader's text and color choices: the − 100% + stepper."), control: size),
                .custom(typeface, control: Fixed(face, NSSize(width: 136, height: Tokens.Metric.controlHeight))),
                .custom(width, control: Fixed(measure, NSSize(width: 212, height: Tokens.Metric.controlHeight))),
                .custom(colors, control: swatches)]
        rows.forEach { addSubview($0) }
        swatches.onPick = { [weak self] theme in self?.change { $0.theme = theme } }
        size.onChange = { [weak self] zoom in
            self?.change { $0.size = Int((zoom * CGFloat(Reader.Preferences.defaultSize)).rounded()) }
        }
        face.onChange = { [weak self] index in self?.change { $0.face = index == 0 ? .serif : .sans } }
        measure.onChange = { [weak self] index in self?.change { $0.width = Reader.Preferences.Width.allCases[index] } }
        onLayout = { [weak self] in self?.layoutContent() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func change(_ edit: (inout Reader.Preferences) -> Void) {
        var next = preferences
        edit(&next)
        guard next != preferences else { return }
        preferences = next
        reader?.apply(next)
    }

    private func refresh() {
        size.zoom = CGFloat(preferences.size) / CGFloat(Reader.Preferences.defaultSize)
        face.selectedIndex = preferences.face == .serif ? 0 : 1
        measure.selectedIndex = Reader.Preferences.Width.allCases.firstIndex(of: preferences.width) ?? 1
        swatches.selected = preferences.theme
    }

    private func layoutContent() {
        // `pad` from the panel's edge to the first row's ink, and from the last row's ink to the bottom.
        let top = Self.pad - inkTop
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: Self.pad, y: top + CGFloat(i) * PanelRow.height, width: bounds.width - Self.pad * 2, height: PanelRow.height)
        }
    }

    #if DEBUG
    /// The open panel's color dot at `index` as if the pointer were over it; nil: none.
    static func debugHoverSwatch(_ index: Int?) { current?.swatches.debugHover(index) }
    /// The open panel's rows and dots, for tests.
    static var debugCurrent: ReaderOptions? { current }
    var debugThemes: [Reader.Preferences.Theme] { swatches.themes }
    var debugRowCount: Int { rows.count }
    #endif
}

/// A control at a set size, so a row can lay it out by what it asks for.
private final class Fixed: NSView {
    private let size: NSSize

    init(_ control: NSView, _ size: NSSize) {
        self.size = size
        super.init(frame: NSRect(origin: .zero, size: size))
        addSubview(control)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { size }
    override var fittingSize: NSSize { size }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }
}

/// The colors as a row of round dots, as macOS picks an accent color, at the space editor's swatch size.
final class ReaderSwatches: NSView {
    var onPick: ((Reader.Preferences.Theme) -> Void)?
    var selected = Reader.Preferences.Theme.auto { didSet { for tile in tiles { tile.isSelected = tile.theme == selected } } }
    var paper = Reader.AutoPaper() { didSet { tiles.forEach { $0.paper = paper } } }
    var spaceColors = Reader.SpaceColors() { didSet { tiles.forEach { $0.spaceColors = spaceColors } } }
    var themes: [Reader.Preferences.Theme] { tiles.map(\.theme) }

    func debugHover(_ index: Int?) { for (i, tile) in tiles.enumerated() { tile.isHovered = i == index } }
    private var tiles: [ThemeSwatch] = []
    private static let side = SwatchRing.side, gap = Tokens.Space.x1

    override init(frame: NSRect) {
        super.init(frame: frame)
        for theme in Reader.Preferences.Theme.allCases {
            let tile = ThemeSwatch(theme: theme)
            tile.onClick = { [weak self] _ in self?.onPick?(theme) }
            addSubview(tile)
            tiles.append(tile)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side * CGFloat(tiles.count) + Self.gap * CGFloat(tiles.count - 1), height: Self.side)
    }
    override var fittingSize: NSSize { intrinsicContentSize }
    override func accessibilityChildren() -> [Any]? { tiles }

    override func layout() {
        super.layout()
        // Flush with the row's end, as the other rows' controls are.
        let x0 = bounds.width - intrinsicContentSize.width
        for (i, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: x0 + CGFloat(i) * (Self.side + Self.gap), y: (bounds.height - Self.side) / 2, width: Self.side, height: Self.side)
        }
    }
}

/// One color as a plain round dot of its paper, drawn as the space editor's swatches (`SwatchRing`): Auto split
/// corner to corner between its day and night papers, Space in the space's paper as it reads now. Chosen, an accent
/// ring with a gap; under the pointer a faint ring, nothing moving.
final class ThemeSwatch: InteractiveView {
    let theme: Reader.Preferences.Theme
    var paper = Reader.AutoPaper() { didSet { stateDidChange(animated: false) } }
    var spaceColors = Reader.SpaceColors() { didSet { stateDidChange(animated: false) } }
    private let ring = CALayer()
    private let fill = CALayer()
    private let darkHalf = CAShapeLayer()

    static func name(_ theme: Reader.Preferences.Theme) -> String {
        switch theme {
        case .auto: String(localized: "Auto", comment: "Color choice in Reader: follows the Mac's light or dark look.")
        case .light: String(localized: "Light", comment: "Color choice in Reader.")
        case .sepia: String(localized: "Sepia", comment: "Color choice in Reader: warm paper.")
        case .dark: String(localized: "Dark", comment: "Color choice in Reader.")
        case .space: String(localized: "Space", comment: "Color choice in Reader: the colors of the space you're in.")
        }
    }

    init(theme: Reader.Preferences.Theme) {
        self.theme = theme
        super.init(frame: .zero)
        layer?.addSublayer(ring)
        layer?.addSublayer(fill)
        fill.masksToBounds = true
        fill.addSublayer(darkHalf)
        darkHalf.isHidden = theme != .auto
        toolTip = theme == .auto ? String(localized: "Auto: follows your Mac", comment: "Tooltip of the Auto color choice in Reader: light by day, dark at night, as the Mac is.")
            : theme == .space ? String(localized: "Space: your space’s colors", comment: "Tooltip of the Space color choice in Reader: the article takes the colors of the space you're in.")
            : Self.name(theme)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(Self.name(theme))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange(animated: false)
    }

    /// The dot's paper: Auto's by day (its night half is `darkHalf`), Space's as the Mac's look has it.
    var dotColor: UInt32 {
        switch theme {
        case .auto: paper.light
        case .space: spaceColors.palette(dark: effectiveAppearance.isDark).paper
        default: theme.palette.paper
        }
    }

    override func stateDidChange(animated: Bool) {
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                SwatchRing.draw(ring: ring, fill: fill, in: bounds, selected: isSelected, hovered: isHovered, chosen: Tokens.Color.accent)
                fill.backgroundColor = Tokens.Color.hex(dotColor).cgColor
                // Night's half below the diagonal from the top-right corner to the bottom-left.
                let w = fill.bounds.width, h = fill.bounds.height
                darkHalf.frame = fill.bounds
                let path = CGMutablePath()
                path.addLines(between: [CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])
                path.closeSubpath()
                darkHalf.path = path
                darkHalf.fillColor = Tokens.Color.hex(paper.dark).cgColor
            }
        }
        setAccessibilityValue(NSNumber(value: isSelected ? 1 : 0))
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
            // The same as on any page: ⌘ for a tab behind, ⌘⇧ for one in front, ⇧ alone for Zigzag Mini.
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
