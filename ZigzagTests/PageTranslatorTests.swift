import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Translating a page with more than one language in it (#197): the parts not in your language are translated,
/// the parts already in it are left alone, and a page only says it's already in your language when all of it is.
@MainActor
struct PageTranslatorTests {
    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func page(_ html: String) async -> (WKWebView, Loading) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
        return (webView, loading)
    }

    private static let english = Locale.Language(identifier: "en")
    private static let chinese = Locale.Language(identifier: "zh-Hans")

    /// An English page with a paragraph of Chinese and a quote in Japanese.
    static let englishWithChineseAndJapanese = """
    <html><body>
    <nav><a href="/">Home</a> <a href="/news">News</a></nav>
    <h1>Notes from a week in Shanghai</h1>
    <p>We spent most of the week walking along the river and eating far too many dumplings. The weather was warm and
    the evenings were long, so we stayed out late every night and saw a different part of the city each time.</p>
    <p id="zh">上海是一座充满活力的城市，外滩的夜景非常美丽。我们每天晚上都在江边散步，品尝当地的小吃，感受这座城市独特的魅力。</p>
    <blockquote id="ja">旅はいつも新しい発見をくれる。知らない街を歩くと、自分のことも少しずつわかってくる。</blockquote>
    <p>Next time we want to take the train out to the water towns, which everyone told us not to miss.</p>
    <pre><code>let city = "上海"</code></pre>
    <input value="上海是一座城市">
    <div contenteditable="true">我在这里写的东西不应该被翻译</div>
    </body></html>
    """

    /// A Chinese page with English code blocks and a short English button.
    static let chineseWithCode = """
    <html><body>
    <h1>如何在终端里安装这个工具</h1>
    <p>首先打开终端，然后输入下面的命令。安装完成以后，重新启动终端，就可以开始使用了。如果遇到问题，请查看常见问题页面。</p>
    <pre><code>brew install example-tool
    example-tool --version</code></pre>
    <p>安装好之后，你可以用下面这行命令检查它是否正常工作，输出应该显示当前的版本号。</p>
    <code>example-tool doctor</code>
    <button>Copy</button>
    </body></html>
    """

    private func texts(_ text: PageTranslator.PageText, _ group: PageTranslator.Group?) -> [String] {
        (group?.pieces ?? []).map { text.pieces[$0] }
    }

    // MARK: Pages in a real web view

    @Test func anEnglishPageHasJustItsChineseAndJapaneseTranslatedIntoEnglish() async throws {
        let (webView, loading) = await page(Self.englishWithChineseAndJapanese)
        defer { _ = loading }
        let language = await PageTranslator.pageLanguage(of: webView)
        #expect(language?.languageCode == .english)
        let text = await PageTranslator.text(in: webView)
        // Code, fields and what you're editing are never read for translating.
        #expect(!text.pieces.contains { $0.contains("let city") || $0.contains("不应该") || $0 == "上海是一座城市" })
        let groups = PageTranslator.plan(text, page: language, into: Self.english)
        #expect(groups.count == 2)
        #expect(groups.map { $0.source.languageCode } == [.chinese, .japanese])
        #expect(texts(text, groups.first).count == 1 && texts(text, groups.first).first?.hasPrefix("上海是") == true)
        #expect(texts(text, groups.last).first?.hasPrefix("旅は") == true)
        // English, including the menu's short words, is left alone.
        let chosen = Set(groups.flatMap(\.pieces))
        #expect(!chosen.contains { text.pieces[$0] == "Home" || text.pieces[$0].hasPrefix("We spent") })
    }

    @Test func intoChineseTheEnglishIsTranslatedAndTheChineseLeftAlone() async throws {
        let (webView, loading) = await page(Self.englishWithChineseAndJapanese)
        defer { _ = loading }
        let language = await PageTranslator.pageLanguage(of: webView)
        let text = await PageTranslator.text(in: webView)
        let groups = PageTranslator.plan(text, page: language, into: Self.chinese)
        #expect(groups.map { $0.source.languageCode } == [.english, .japanese])
        let english = texts(text, groups.first)
        #expect(english.contains("Home") && english.contains { $0.hasPrefix("We spent") })
        #expect(!english.contains { $0.hasPrefix("上海是") })
    }

    @Test func aChinesePageWithCodeIsAlreadyInChinese() async throws {
        let (webView, loading) = await page(Self.chineseWithCode)
        defer { _ = loading }
        let language = await PageTranslator.pageLanguage(of: webView)
        #expect(language?.languageCode == .chinese)
        let text = await PageTranslator.text(in: webView)
        #expect(!text.pieces.contains { $0.contains("brew") || $0.contains("doctor") })
        // Nothing to translate: the page says it's already in Chinese.
        #expect(PageTranslator.plan(text, page: language, into: Self.chinese).isEmpty)
        // Into English, the Chinese is translated; the code stays as it is.
        let groups = PageTranslator.plan(text, page: language, into: Self.english)
        #expect(groups.count == 1 && groups.first?.source.languageCode == .chinese)
        #expect(texts(text, groups.first).contains { $0.hasPrefix("首先") })
    }

    @Test func translationsLandInPlaceAndTheOriginalComesBack() async throws {
        let (webView, loading) = await page(Self.englishWithChineseAndJapanese)
        defer { _ = loading }
        let text = await PageTranslator.text(in: webView)
        let groups = PageTranslator.plan(text, page: Self.english, into: Self.english)
        let zh = try #require(groups.first?.pieces.first)
        await PageTranslator.apply([zh: "Shanghai is a lively city."], in: webView)
        #expect(try await webView.evaluateJavaScript("document.getElementById('zh').textContent") as? String == "Shanghai is a lively city.")
        #expect(try await webView.evaluateJavaScript("document.getElementById('ja').textContent")as? String == "旅はいつも新しい発見をくれる。知らない街を歩くと、自分のことも少しずつわかってくる。")
        PageTranslator.restore(in: webView)
        try await Task.sleep(for: .milliseconds(100))
        #expect((try await webView.evaluateJavaScript("document.getElementById('zh').textContent") as? String)?.hasPrefix("上海是") == true)
    }

    @Test func aPageTypedIntoATranslatedTabIsntTakenAsTranslated() {
        // Without this, Translate on the new page took it as translated and only "showed the original".
        let tab = Tab(url: URL(string: "http://127.0.0.1:1/a.html"), spaceID: UUID())
        tab.isTranslated = true
        tab.load(URL(string: "http://127.0.0.1:1/b.html")!)
        #expect(!tab.isTranslated)
    }

    // MARK: Choosing what to translate

    private func text(_ blocks: [[String]]) -> PageTranslator.PageText {
        var pieces: [String] = [], places: [Int] = [], blockTexts: [String] = []
        for (index, block) in blocks.enumerated() {
            for piece in block { pieces.append(piece); places.append(index) }
            blockTexts.append(block.joined(separator: " "))
        }
        return PageTranslator.PageText(pieces: pieces, blocks: places, blockTexts: blockTexts)
    }

    @Test func aPageAllInTheTargetLanguageHasNothingToTranslate() {
        let page = text([["Home"], ["The quick brown fox jumps over the lazy dog, again and again, all afternoon."]])
        #expect(PageTranslator.plan(page, page: Self.english, into: Self.english).isEmpty)
    }

    @Test func shortWordsInThePagesAlphabetGoWithThePage() {
        // "Inicio" alone could be anything: on an English page it's left, on a Spanish one it's translated.
        let page = text([["Inicio"], ["Contacto"]])
        #expect(PageTranslator.plan(page, page: Self.english, into: Self.english).isEmpty)
        let spanish = PageTranslator.plan(page, page: Locale.Language(identifier: "es"), into: Self.english)
        #expect(spanish.first?.pieces == [0, 1])
    }

    @Test func aFewWordsInAnotherScriptAreToldOnTheirOwn() {
        #expect(PageTranslator.blockLanguage("ひらがなとカタカナのニュース", page: Self.english)?.languageCode == .japanese)
        #expect(PageTranslator.blockLanguage("这是一段很短的中文", page: Self.english)?.languageCode == .chinese)
        #expect(PageTranslator.blockLanguage("Новости дня", page: Self.english)?.languageCode == .russian)
    }

    @Test func aPieceGoesWithItsWholeBlock() {
        // A link inside a Chinese paragraph is Chinese, short as it is.
        let page = text([["在这里", "阅读全文", "，然后告诉我们你的想法。我们会认真阅读每一条留言。"], ["Read more about our work and our team on the about page."]])
        let groups = PageTranslator.plan(page, page: Self.english, into: Self.english)
        #expect(groups.count == 1 && groups.first?.pieces == [0, 1, 2])
    }

    @Test func blocksWithoutLettersAreLeftAlone() {
        let page = text([["12:30"], ["→"]])
        #expect(PageTranslator.plan(page, page: Self.chinese, into: Self.english).isEmpty)
    }

    @Test func theLanguageWithTheMostTextComesFirst() {
        let page = text([
            ["这是一个很短的句子。"],
            ["日本語の文章はこちらです。少し長めに書いておきます。もっと長くするためにもう一文を足します。"],
        ])
        let groups = PageTranslator.plan(page, page: Self.english, into: Self.english)
        #expect(groups.map { $0.source.languageCode } == [.japanese, .chinese])
    }

    @Test func theDominantLanguageNeedsEnoughText() {
        #expect(PageTranslator.dominantLanguage(of: "Bonjour") == nil)
        let french = String(repeating: "Nous avons passé la semaine à marcher le long de la rivière. ", count: 3)
        #expect(PageTranslator.dominantLanguage(of: french)?.languageCode == .french)
    }
}
