import Foundation
import Testing
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
        #expect(preferences.rootStyle == "--size: 22px; --measure: 29em")
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
        #expect(page.contains("style=\"--size: 20px; --measure: 34em\""))
    }
}
