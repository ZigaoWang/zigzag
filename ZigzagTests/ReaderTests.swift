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
