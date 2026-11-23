import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Reader's header facts (title, author, date, language), the choices it remembers, and how they reach the page.
@MainActor
struct ReaderTests {
    @Test func bylinesNameAPersonOrNothing() {
        #expect(Reader.author(from: "By Jane Doe", site: "The Verge") == "Jane Doe")
        #expect(Reader.author(from: "  written by   Jane   Doe | ", site: "x") == "Jane Doe")
        #expect(Reader.author(from: "作者：张三", site: "x") == "张三")
        #expect(Reader.author(from: "Byron Smith", site: "x") == "Byron Smith")
        #expect(Reader.author(from: "Contributors to Wikimedia projects", site: "Wikipedia").isEmpty)
        #expect(Reader.author(from: "The Verge", site: "The Verge").isEmpty)
        #expect(Reader.author(from: "https://example.com/about", site: "x").isEmpty)
        #expect(Reader.author(from: String(repeating: "word ", count: 20), site: "x").isEmpty)
    }

    @Test func datesAreThePublishersDayInTheReadersWords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let english = Locale(identifier: "en_US"), chinese = Locale(identifier: "zh-Hans")
        #expect(Reader.publishedDate("2024-03-03", locale: english, now: now) == "March 3, 2024")
        // Late at night where it was written: still that day, wherever it's read.
        #expect(Reader.publishedDate("2024-03-03T23:30:00-08:00", locale: english, now: now) == "March 3, 2024")
        #expect(Reader.publishedDate("Sun, 03 Mar 2024 10:00:00 +0000", locale: english, now: now) == "March 3, 2024")
        #expect(Reader.publishedDate("2024-03-03T10:00:00Z", locale: chinese, now: now) == "2024年3月3日")
        #expect(Reader.publishedDate("", locale: english, now: now).isEmpty)
        #expect(Reader.publishedDate(nil, locale: english, now: now).isEmpty)
        #expect(Reader.publishedDate("last Tuesday", locale: english, now: now).isEmpty)
        #expect(Reader.publishedDate("2099-01-01", locale: english, now: now).isEmpty)
    }

    @Test func titlesLoseTheSitesName() {
        #expect(Reader.title("Make 命令教程 - 阮一峰的网络日志", siteNames: ["ruanyifeng.com"], author: "阮一峰") == "Make 命令教程")
        #expect(Reader.title("How Pingora works | Cloudflare Blog", siteNames: ["Cloudflare Blog"], author: "") == "How Pingora works")
        #expect(Reader.title("Swift - Part 2", siteNames: ["example.com"], author: "") == "Swift - Part 2")
        #expect(Reader.title("Typography", siteNames: ["Wikipedia"], author: "") == "Typography")
    }

    @Test func languageFollowsTheWordsWhenThePageIsWrong() {
        let chinese = "代码变成可执行文件，叫做编译；先编译这个，还是先编译那个，叫做构建。Make是最常用的构建工具。"
        #expect(Reader.language(declared: "en", sample: chinese) == "zh")
        #expect(Reader.language(declared: "", sample: chinese) == "zh")
        #expect(Reader.language(declared: "zh-TW", sample: chinese) == "zh-TW")
        #expect(Reader.language(declared: "", sample: "これは日本語の文章です。ひらがなとカタカナが入っています。") == "ja")
        #expect(Reader.language(declared: "en", sample: "Typography is the art and technique of arranging type.") == "en")
    }

    @Test func choicesAreRememberedAndStepWithinBounds() throws {
        let defaults = try #require(UserDefaults(suiteName: "ReaderTests-\(UUID().uuidString)"))
        #expect(Reader.Preferences.load(from: defaults) == Reader.Preferences(size: 20, face: .serif, theme: .auto, width: .medium))
        Reader.Preferences(size: 24, face: .sans, theme: .sepia, width: .wide).save(to: defaults)
        #expect(Reader.Preferences.load(from: defaults) == Reader.Preferences(size: 24, face: .sans, theme: .sepia, width: .wide))
        defaults.set(99, forKey: "ReaderSize")
        #expect(Reader.Preferences.load(from: defaults).size == Reader.Preferences.defaultSize)

        let usual = Reader.Preferences()
        #expect(usual.stepped(1).size == 22)
        #expect(usual.stepped(1).percent == 110)
        #expect(usual.stepped(-100).size == Reader.Preferences.sizes.lowerBound)
        #expect(usual.stepped(100).size == Reader.Preferences.sizes.upperBound)
        #expect(Reader.Preferences(size: 30).stepped(0).size == 20)
    }

    @Test func choicesReachThePageAsVariables() {
        let preferences = Reader.Preferences(size: 22, face: .sans, theme: .dark, width: .narrow)
        #expect(preferences.rootStyle == "--size: 22px; --measure: 28rem")
        #expect(preferences.script.contains("dataset.theme='dark'"))
        #expect(preferences.script.contains("dataset.face='sans'"))
        #expect(Reader.Palette.dark.css.contains("--paper: #1E1E20;"))
        #expect(Reader.Palette.dark.css.contains("color-scheme: dark"))
        #expect(Reader.Palette.sepia.css.contains("--paper: #F4ECDE;"))
        #expect(Reader.Preferences.Theme.auto.palette == .light)
    }

    @Test func pageKeepsScriptsOutAndOneHeader() {
        let article = Reader.Article(title: "A title - Example", byline: "By Ada", site: "Example", content: "<p>Hello</p><script>x()</script>",
                                     length: 5, lang: "en", sample: "Hello", published: "2024-03-03", url: "https://example.com/a")
        let page = Reader.html(for: article, preferences: Reader.Preferences(), locale: Locale(identifier: "en_US"))
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("<h1 class=\"title\">A title</h1>"))
        #expect(page.contains("<span class=\"author\">Ada</span><time>March 3, 2024</time>"))
        #expect(page.contains("style=\"--size: 20px; --measure: 34rem\""))
    }

    /// Wide has no cap of its own: the column is the window inside its margins.
    @Test func wideFillsTheWindow() {
        #expect(Reader.Preferences.Width.wide.measure == "100vw")
        #expect(Reader.css.contains("main { max-width: var(--measure, 34rem)"))
        #expect(Reader.css.contains("padding: 80px var(--gutter) 120px"))
        // Changing a choice keeps the space's paper and the line you were on.
        let script = Reader.Preferences(width: .wide).script
        #expect(script.contains("setProperty('--measure','100vw')"))
        #expect(!script.contains("setAttribute('style'"))
        #expect(script.contains("scrollBy"))
    }

    /// Auto's paper is a breath of the space's color, and the inks keep their contrast on it in every hue.
    @Test func autoPaperTakesTheSpacesColorAndKeepsContrast() throws {
        #expect(Reader.AutoPaper.of(.navy) == Reader.AutoPaper())
        for step in 0..<20 {
            var theme = Brand.Theme(hue: Double(step) / 20)
            theme.surfaceHue = Double(step) / 20
            let paper = Reader.AutoPaper.of(theme)
            #expect(paper != Reader.AutoPaper())
            #expect(Brand.contrast(Tokens.Color.hex(Reader.Palette.light.ink), Tokens.Color.hex(paper.light)) >= 12)
            #expect(Brand.contrast(Tokens.Color.hex(Reader.Palette.light.soft), Tokens.Color.hex(paper.light)) >= 4.5)
            #expect(Brand.contrast(Tokens.Color.hex(Reader.Palette.dark.ink), Tokens.Color.hex(paper.dark)) >= 10)
            #expect(Brand.contrast(Tokens.Color.hex(Reader.Palette.dark.soft), Tokens.Color.hex(paper.dark)) >= 4.5)
        }
        let article = Reader.Article(title: "T", byline: "", site: "S", content: "<p>x</p>", length: 1, lang: "en")
        let tinted = Reader.AutoPaper(light: 0xF8F9FC, dark: 0x1D2026)
        let page = Reader.html(for: article, preferences: Reader.Preferences(), paper: tinted, reducedMotion: true)
        #expect(page.contains("--tint: #F8F9FC; --tint-dark: #1D2026;"))
        #expect(page.contains("data-motion=\"reduce\" style="))
        #expect(!Reader.html(for: article, preferences: Reader.Preferences()).contains("data-motion=\"reduce\" style="))
    }

    /// Space's paper is the space's own color, and its inks read on it: body text and links at 7:1 or more, soft words
    /// at 4.5:1, in every curated color, custom hues at every strength, every shade from white to black and see-through.
    @Test func spaceColorsReadInEverySpace() {
        var spaces = SpaceColor.allCases.map { SpaceInfo(name: $0.name, color: $0) }
        for step in 0..<24 {
            for intensity in [0.0, 0.4, 1.0] {
                var custom = SpaceInfo(name: "hue", color: .sky)
                custom.hue = Double(step) / 24
                custom.intensity = intensity
                spaces.append(custom)
            }
            for depth in stride(from: 0.0, through: 1.0, by: 0.1) {
                for tint in [0.0, 0.5, 1.0] {
                    var painted = SpaceInfo(name: "paint", color: .sky)
                    painted.hue = Double(step) / 24
                    painted.brightness = depth
                    painted.tint = tint
                    spaces.append(painted)
                }
            }
        }
        var glass = SpaceInfo(name: "glass", color: .rose)
        glass.translucency = 0.8
        spaces.append(glass)
        var worst = (ink: 99.0, link: 99.0, soft: 99.0)
        for space in spaces {
            let colors = Reader.SpaceColors.of(space)
            for palette in [colors.light, colors.dark] {
                let paper = Tokens.Color.hex(palette.paper)
                worst.ink = min(worst.ink, Brand.contrast(Tokens.Color.hex(palette.ink), paper))
                worst.link = min(worst.link, Brand.contrast(Tokens.Color.hex(palette.link), paper))
                worst.soft = min(worst.soft, Brand.contrast(Tokens.Color.hex(palette.soft), paper))
                #expect(palette.isDark == (Brand.relativeLuminance(paper) < 0.18))
            }
        }
        #expect(worst.ink >= 7)
        #expect(worst.link >= 7)
        #expect(worst.soft >= 4.5)
        // White stays white, black stays black, and a curated color is the sidebar's own.
        #expect(Reader.SpaceColors.of(SpaceInfo(name: "w", color: .snow)).light.paper == 0xFFFFFF)
        #expect(Reader.SpaceColors.of(SpaceInfo(name: "b", color: .ink)).dark.paper == 0x000000)
        let sage = SpaceInfo(name: "s", color: .sage)
        var frame = sage.background
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { frame = sage.background.usingColorSpace(.sRGB) ?? frame }
        #expect(Reader.SpaceColors.of(sage).light.paper == Reader.hex(frame))
        #expect(Reader.SpaceColors.of(sage).light.paper != Reader.SpaceColors.of(SpaceInfo(name: "r", color: .rose)).light.paper)
    }

    /// Space is a theme of its own, saved by name: an older Zigzag that doesn't know it reads Auto.
    @Test func spaceIsSavedAndReachesThePage() throws {
        let defaults = try #require(UserDefaults(suiteName: "ReaderTests-\(UUID().uuidString)"))
        Reader.Preferences(theme: .space).save(to: defaults)
        #expect(defaults.string(forKey: "ReaderTheme") == "space")
        #expect(Reader.Preferences.load(from: defaults).theme == .space)
        defaults.set("someday", forKey: "ReaderTheme")
        #expect(Reader.Preferences.load(from: defaults).theme == .auto)
        #expect(Reader.Preferences(theme: .space).script.contains("dataset.theme='space'"))
        let colors = Reader.SpaceColors.of(SpaceInfo(name: "s", color: .lavender))
        let article = Reader.Article(title: "T", byline: "", site: "S", content: "<p>x</p>", length: 1, lang: "en")
        let page = Reader.html(for: article, preferences: Reader.Preferences(theme: .space), space: colors)
        #expect(page.contains("data-theme=\"space\""))
        #expect(page.contains("<style id=\"zigzag-colors\">"))
        #expect(page.contains(":root[data-theme=\"space\"] { \(colors.light.css) }"))
        #expect(page.contains("@media (prefers-color-scheme: dark) { :root[data-theme=\"space\"] { \(colors.dark.css) } }"))
        // Print stays black on white whatever the theme.
        #expect(Reader.css.contains(":root, :root[data-theme] { \(Reader.Palette.light.css) --ink: #000;"))
    }

    /// The site's icon sits on the text's left edge: the pictures' centering doesn't move it.
    @Test func headerIconSitsOnTheTextsEdge() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let article = Reader.Article(title: "A title", byline: "", site: "example.com", content: "<p>Body text.</p>", length: 10, lang: "en")
        let dot = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
        webView.loadHTMLString(Reader.html(for: article, preferences: Reader.Preferences(), icon: dot, reducedMotion: true), baseURL: nil)
        while webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let script = "const r = s => document.querySelector(s).getBoundingClientRect();" +
            "return [r('.site img').left, r('.site span').left, r('h1.title').left, r('article p').left];"
        let edges = try await webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .defaultClient) as? [Double] ?? []
        try #require(edges.count == 4)
        #expect(edges[0] == edges[2])
        #expect(edges[0] == edges[3])
        #expect(edges[1] == edges[0] + 16 + 8)
    }

    /// The article's own "By …" line goes when the header already names that author; the text itself never does.
    @Test func aBylineTheHeaderShowsIsntRepeated() async throws {
        let webView = WKWebView()
        webView.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        while webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        func strip(_ html: String, byline: String, site: String = "Field Notes") async throws -> String {
            let script = "const d = document.createElement('div'); d.innerHTML = html; (\(Reader.repeatedBylineScript))(d, byline, site); return d.innerHTML;"
            return try await webView.callAsyncJavaScript(script, arguments: ["html": html, "byline": byline, "site": site], contentWorld: .page) as? String ?? ""
        }
        #expect(try await strip("<div><p class=\"byline\">By Ada Palmer</p><p>Text.</p></div>", byline: "Ada Palmer") == "<div><p>Text.</p></div>")
        #expect(try await strip("<div><p>BY  <a href=\"#\">ada   palmer</a></p><p>Text.</p></div>", byline: "By Ada Palmer") == "<div><p>Text.</p></div>")
        #expect(try await strip("<p>作者：张三</p><p>正文。</p>", byline: "张三") == "<p>正文。</p>")
        // Words about the author, or the name inside a sentence, are the text.
        let sentence = "<p>Ada Palmer wrote this.</p><p>Read <a href=\"#\">Ada Palmer</a> here.</p>"
        #expect(try await strip(sentence, byline: "Ada Palmer") == sentence)
        // Past the article's opening, a line with the name alone is the text too (a signature).
        let late = "<p>One.</p><p>Two.</p><p>Three.</p><p>Ada Palmer</p>"
        #expect(try await strip(late, byline: "Ada Palmer") == late)
        // A credit the header doesn't show (the site's own name) stays.
        #expect(try await strip("<p>By Field Notes</p><p>Text.</p>", byline: "Field Notes") == "<p>By Field Notes</p><p>Text.</p>")
        #expect(try await strip("<p>By Ada Palmer</p>", byline: "") == "<p>By Ada Palmer</p>")
    }

    /// The title is a calm semibold, smaller than before, and the page's spaces are shares of one line.
    @Test func headerAndRhythmFollowOneLine() {
        #expect(Reader.css.contains("--line: calc(var(--leading) * 1rem)"))
        #expect(Reader.css.contains("h1.title { margin: 0; font-size: 1.75em; line-height: 1.2; font-weight: 600;"))
        #expect(Reader.css.contains("header { margin: 0 0 calc(var(--line) * 1.5); }"))
        #expect(Reader.css.contains("border-radius: \(Int(Tokens.Radius.thumbnail))px"))
    }

    /// The reading page is in the store of the page it reads, never one every reading page shares: the article's
    /// pictures would carry a site's cookies from one profile to another, and out of a private window.
    @Test func aReadingPageIsInItsPagesStore() {
        let one = WKWebsiteDataStore.nonPersistent(), other = WKWebsiteDataStore.nonPersistent()
        let first = ReaderView(store: one), second = ReaderView(store: other)
        #expect(first.webView.configuration.websiteDataStore === one)
        #expect(second.webView.configuration.websiteDataStore === other)
        #expect(first.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
    }

    /// Aa shows at the top, goes as you read on, and comes back on the way up, with the pointer near the top, and
    /// for as long as its panel is open.
    @Test func theAaButtonGoesAsYouReadOn() {
        var p = Reader.ButtonPresence()
        #expect(p.isShown)
        p.scrolled(to: 4)
        #expect(p.isShown)
        p.scrolled(to: 300)
        #expect(!p.isShown)
        // A small wobble back doesn't count as heading up.
        p.scrolled(to: 296)
        #expect(!p.isShown)
        p.scrolled(to: 280)
        #expect(p.isShown)
        p.scrolled(to: 600)
        #expect(!p.isShown)
        p.pointerNearTop = true
        #expect(p.isShown)
        // Brought back by the pointer, it stays until you read on.
        p.pointerNearTop = false
        #expect(p.isShown)
        p.scrolled(to: 700)
        #expect(!p.isShown)
        p.panelOpen = true
        p.scrolled(to: 900)
        #expect(p.isShown)
        p.panelOpen = false
        #expect(!p.isShown)
        p.scrolled(to: 0)
        #expect(p.isShown && p.atTop)
    }

    /// Aa sits in the reading page's top-right corner as a toolbar-sized button, and takes no clicks while put away.
    @Test func theAaButtonIsInThePagesCorner() {
        let view = ReaderView(store: .nonPersistent())
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()
        let button = view.optionsButton
        #expect(button.superview === view)
        #expect(button.frame.size == NSSize(width: Tokens.Metric.iconButton, height: Tokens.Metric.iconButton))
        #expect(button.frame.minY == Tokens.Space.x4)
        #expect(view.bounds.maxX - button.frame.maxX == Tokens.Space.x4)
        #expect(button.button.symbol == "textformat.size")
        #expect(button.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) != nil)
        button.setShown(false, animated: false)
        #expect(button.alphaValue == 0)
        #expect(button.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) == nil)
    }

    /// The colors are five plain dots, each named, in the space editor's swatch size.
    @Test func theColorsKeepAllFiveThemes() {
        let row = ReaderSwatches()
        #expect(row.themes == Reader.Preferences.Theme.allCases)
        #expect(row.themes == [.auto, .light, .sepia, .dark, .space])
        #expect(row.intrinsicContentSize.height == SwatchRing.side)
        let names = Reader.Preferences.Theme.allCases.map { ThemeSwatch(theme: $0).accessibilityLabel() }
        #expect(names == ["Auto", "Light", "Sepia", "Dark", "Space"])
        #expect(ThemeSwatch(theme: .light).toolTip == "Light")
    }
}

/// The address's Reader button turns Reader on and off; Aa in the page opens how it reads.
@MainActor
struct ReaderToggleTests {
    @Test func aSecondClickTurnsReaderOff() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let url = try #require(URL(string: "https://example.com/story"))
        let tab = Tab(url: url, title: "Story", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        let article = Reader.Article(title: "T", byline: "", site: "S", content: "<p>x</p>", length: 1, lang: "en")
        controller.showReader(article, in: tab, from: url, store: .nonPersistent())
        let button = controller.sidebar.address.readerButton
        #expect(controller.isReaderOnHere)
        #expect(button.isSelected)
        let reader = try #require(controller.readerHere)
        reader.optionsButton.button.onClick?(NSEvent())
        #expect(ReaderOptions.isOpen(in: controller.window))
        #expect(reader.optionsButton.button.isSelected && reader.presence.panelOpen)
        #expect(ReaderOptions.debugCurrent?.debugRowCount == 4)
        #expect(ReaderOptions.debugCurrent?.debugThemes == Reader.Preferences.Theme.allCases)
        // A second click on the address's button: Reader goes, its panel with it, never the panel alone.
        button.onClick?(NSEvent())
        #expect(!controller.isReaderOnHere)
        #expect(!ReaderOptions.isOpen(in: controller.window))
        #expect(!button.isSelected)
    }
}

/// Reader up over one page of a split, with the other page focused: the address's button, the menu bar and Site
/// Controls all say it's on, since pressing any of them closes it.
@MainActor
struct ReaderInSplitTests {
    @Test func everyPlaceSaysReaderIsOnInTheOtherPane() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let url = try #require(URL(string: "https://example.com/story"))
        let story = Tab(url: url, title: "Story", spaceID: space)
        let other = Tab(url: try #require(URL(string: "https://example.com/other")), title: "Other", spaceID: space)
        manager.adopt([story, other], in: space)
        manager.makeSplit(story, with: other)
        manager.select(story)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        let article = Reader.Article(title: "T", byline: "", site: "S", content: "<p>x</p>", length: 1, lang: "en")
        controller.showReader(article, in: story, from: url, store: .nonPersistent())
        manager.select(other)
        #expect(controller.isShowingReader)
        let item = NSMenuItem(title: "", action: #selector(BrowserWindowController.toggleReader(_:)), keyEquivalent: "")
        _ = controller.validateMenuItem(item)
        #expect(item.title == String(localized: "Hide Reader", comment: "Menu bar item: closes Reader."))
        let button = controller.sidebar.address.readerButton
        #expect(button.isSelected)
        button.onClick?(NSEvent())
        #expect(!controller.isShowingReader)
        #expect(!button.isSelected)
    }
}

/// Reader pressed while waiting for a load cancels the wait only on that tab.
@MainActor
struct ReaderWaitTests {
    @Test func onlyTheSameTabCallsTheWaitOff() {
        let space = UUID()
        let waiting = Tab(url: URL(string: "https://example.com/slow"), spaceID: space)
        let other = Tab(url: URL(string: "https://example.org/"), spaceID: space)
        #expect(BrowserWindowController.readerPressCancelsWait(waitingFor: waiting, selected: waiting))
        #expect(!BrowserWindowController.readerPressCancelsWait(waitingFor: waiting, selected: other))
        #expect(!BrowserWindowController.readerPressCancelsWait(waitingFor: nil, selected: other))
    }
}
