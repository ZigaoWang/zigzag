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

    // MARK: Pages detection missed (#218)

    /// A Spanish page marked lang="en", under a long English menu that fills the start of its text.
    static let spanishUnderAnEnglishMenu = """
    <html lang="en"><body>
    <nav>\((1...40).map { "<a href=\"/\($0)\">Section number \($0) of the site menu</a>" }.joined(separator: " "))</nav>
    <h1>Un paseo por el casco antiguo de la ciudad</h1>
    <p>Pasamos toda la semana caminando por las calles estrechas del centro, probando la comida de los mercados y
    hablando con la gente del barrio. Cada tarde el sol se ponía detrás de la catedral y las plazas se llenaban de música.</p>
    <p>La próxima vez queremos quedarnos más tiempo y visitar los pueblos de la costa, que todos nos recomendaron.</p>
    <p>Inicio</p><p>Contacto</p>
    </body></html>
    """

    @Test func aPageIsToldByItsParagraphsNotItsMenuOrLangAttribute() async throws {
        let (webView, loading) = await page(Self.spanishUnderAnEnglishMenu)
        defer { _ = loading }
        #expect(await PageTranslator.pageLanguage(of: webView)?.languageCode == .spanish)
    }

    @Test func blocksAreWeighedByHowMuchTheySay() {
        // A Chinese page under a few lines of English: the Chinese, a word a character, says more.
        let blocks = ["Sign in to your account to keep reading this article",
                      "上海是一座充满活力的城市，外滩的夜景非常美丽。我们每天晚上都在江边散步，品尝当地的小吃。",
                      "这座城市有很多博物馆和公园，周末的时候人们喜欢去那里放松。"]
        #expect(PageTranslator.dominantLanguage(ofBlocks: blocks)?.languageCode == .chinese)
        // Too little to tell by.
        #expect(PageTranslator.dominantLanguage(ofBlocks: ["Home", "News"]) == nil)
    }

    @Test func askedForTranslationAPageSeenAsYoursIsReadAgain() {
        // Seen as English (its menu, as it loaded), the page is mostly Spanish: its short words go with it too.
        let page = text([
            ["Inicio"], ["Contacto"],
            ["Pasamos toda la semana caminando por las calles estrechas del centro, probando la comida de los mercados."],
            ["La próxima vez queremos quedarnos más tiempo y visitar los pueblos de la costa, que todos nos recomendaron."],
        ])
        let source = PageTranslator.sourceLanguage(seen: Self.english, text: page, into: Self.english)
        #expect(source?.languageCode == .spanish)
        let groups = PageTranslator.plan(page, page: source, into: Self.english)
        #expect(groups.count == 1 && groups.first?.pieces == [0, 1, 2, 3])
        // Not known at all, the same.
        #expect(PageTranslator.sourceLanguage(seen: nil, text: page, into: Self.english)?.languageCode == .spanish)
        // A language seen as someone else's stands as it is.
        #expect(PageTranslator.sourceLanguage(seen: Self.chinese, text: page, into: Self.english)?.languageCode == .chinese)
    }

    @Test func aPageMostlyInYourLanguageStaysSoWhenForced() {
        // An English page with one Chinese paragraph: just that is translated, its menu left alone (#197).
        let page = text([
            ["Home"],
            ["We spent most of the week walking along the river and eating far too many dumplings in the old town."],
            ["Next time we want to take the train out to the water towns, which everyone told us not to miss at all."],
            ["上海是一座充满活力的城市。"],
        ])
        let source = PageTranslator.sourceLanguage(seen: Self.english, text: page, into: Self.english)
        #expect(source?.languageCode == .english)
        let groups = PageTranslator.plan(page, page: source, into: Self.english)
        #expect(groups.map { $0.source.languageCode } == [.chinese])
        #expect(groups.first?.pieces == [3])
    }

    // MARK: Translate in the menus (#218)

    @Test func theMenuItemSaysTranslateThenShowOriginal() {
        let into = PageTranslator.name(of: PageTranslator.readerLanguage)
        #expect(PageTranslator.menuTitle(translated: false) == String(localized: "Translate to \(into)", comment: "Item in a page's right-click menu and a tab's in the sidebar: translates the page, whatever language it seemed to be in. The language is the one you read, by name, like English."))
        #expect(PageTranslator.menuTitle(translated: true) == String(localized: "Show Original", comment: "Tooltip of the Original action in the site panel."))
    }

    @Test func aTabsMenuTranslatesItsLoadedPage() throws {
        let tab = Tab(url: URL(string: "http://127.0.0.1:1/a.html"), spaceID: UUID())
        // Not loaded: there's no text yet, so it's there, dimmed.
        let unloaded = try #require(SidebarMenus.translateItem(for: tab) {})
        #expect(!unloaded.isEnabled && unloaded.title == PageTranslator.menuTitle(translated: false))
        _ = tab.ensureWebView()
        var asked = 0
        let item = try #require(SidebarMenus.translateItem(for: tab) { asked += 1 })
        #expect(item.isEnabled && item.title == PageTranslator.menuTitle(translated: false))
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        #expect(asked == 1)
        tab.isTranslated = true
        #expect(SidebarMenus.translateItem(for: tab) {}?.title == PageTranslator.menuTitle(translated: true))
        // Zigzag's own pages have nothing to translate.
        let own = Tab(url: URL(string: "zigzag://history"), spaceID: UUID())
        #expect(SidebarMenus.translateItem(for: own) {} == nil)
    }

    @Test func thePagesMenuHasTranslateUnderReload() throws {
        let tab = Tab(url: URL(string: "https://example.com/"), spaceID: UUID())
        func menu(_ identifiers: [String]) -> NSMenu {
            let menu = NSMenu()
            for id in identifiers {
                let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier(id)
                menu.addItem(item)
            }
            return menu
        }
        let page = menu(["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward", "WKMenuItemIdentifierReload", "WKMenuItemIdentifierInspectElement"])
        BrowserWebView.addTranslate(to: page, for: tab, target: nil, action: #selector(NSText.copy(_:)))
        let index = try #require(page.items.firstIndex { $0.identifier?.rawValue == BrowserWebView.translateItemIdentifier })
        #expect(page.items[index - 1].identifier?.rawValue == "WKMenuItemIdentifierReload")
        #expect(page.items[index].title == PageTranslator.menuTitle(translated: false))
        tab.isTranslated = true
        let translated = menu(["WKMenuItemIdentifierReload"])
        BrowserWebView.addTranslate(to: translated, for: tab, target: nil, action: #selector(NSText.copy(_:)))
        #expect(translated.items.last?.title == PageTranslator.menuTitle(translated: true))
        // A link's or a selection's menu isn't about the page: no Translate there.
        let link = menu(["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierCopyLink"])
        BrowserWebView.addTranslate(to: link, for: tab, target: nil, action: #selector(NSText.copy(_:)))
        #expect(link.items.count == 2)
    }

    @Test func theDominantLanguageNeedsEnoughText() {
        #expect(PageTranslator.dominantLanguage(of: "Bonjour") == nil)
        let french = String(repeating: "Nous avons passé la semaine à marcher le long de la rivière. ", count: 3)
        #expect(PageTranslator.dominantLanguage(of: french)?.languageCode == .french)
    }

    private final class Run {}

    /// Each tab translates on its own: asking for a second tab's never makes the first's stale, and asking again
    /// for one already translating doesn't start another.
    @Test func eachTabsTranslationRunsOnItsOwn() {
        var runs = TranslationRuns<Int, Run>()
        let first = Run(), second = Run(), again = Run()
        let step1 = runs.begin(first, for: 1)
        #expect(step1)
        let step2 = runs.begin(second, for: 2)
        #expect(step2)
        #expect(runs.isCurrent(first, for: 1) && runs.isCurrent(second, for: 2))
        let step3 = runs.begin(again, for: 1)
        #expect(!step3)
        #expect(runs.run(for: 1) === first)
        // The second finishing leaves the first running.
        let step4 = runs.end(second, for: 2)
        #expect(step4)
        #expect(runs.isCurrent(first, for: 1))
        // Ended once only; a late answer from it changes nothing.
        let step5 = runs.end(second, for: 2)
        #expect(!step5)
        #expect(!runs.isCurrent(second, for: 2))
        let step6 = runs.end(first, for: 1)
        #expect(step6)
        #expect(runs.all.isEmpty)
    }

    /// A translation's toasts show only while its page is in view: the peeked page while Peek is open, otherwise
    /// the tab you're on.
    @Test func toastsFollowThePageInView() {
        let tab = Run(), other = Run(), peeked = Run()
        #expect(PageTranslator.isInView(tab, selected: tab, peeked: nil))
        #expect(!PageTranslator.isInView(tab, selected: other, peeked: nil))
        #expect(!PageTranslator.isInView(tab, selected: tab, peeked: peeked))
        #expect(PageTranslator.isInView(peeked, selected: tab, peeked: peeked))
    }
}
