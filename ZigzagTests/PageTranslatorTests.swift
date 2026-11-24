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

    // MARK: Script variants and downloads (#231)

    private static let traditional = Locale.Language(identifier: "zh-Hant")

    /// Simplified Wikipedia with a Traditional variant menu and notice: one translation, from Simplified.
    @Test func aPagesOwnLanguageInAnotherScriptGoesWithThePage() {
        let page = text([
            ["豫园是建于明朝时期的古典园林，座落于中华人民共和国上海市黄浦区，原上海老城厢东北部，北靠福佑路，东临安仁街。"],
            ["我們支援澳門繁體，選取內容的語言變體。儲存您偏好的中文語言變體，以避免顯示簡繁混雜的內容。"],
        ])
        let groups = PageTranslator.plan(page, page: Self.chinese, into: Self.english)
        #expect(groups.count == 1)
        #expect(groups.first?.source.minimalIdentifier == Self.chinese.minimalIdentifier)
        #expect(groups.first?.pieces == [0, 1])
    }

    /// A site translated from Simplified keeps Simplified on its next page, even if detected as Traditional.
    @Test func aTranslatedSitesNextPageKeepsItsLanguage() {
        #expect(PageTranslator.keeping(Self.chinese, over: Self.traditional) == Self.chinese)
        #expect(PageTranslator.keeping(Self.chinese, over: Locale.Language(identifier: "ja")) == Locale.Language(identifier: "ja"))
        #expect(PageTranslator.keeping(nil, over: Self.traditional) == Self.traditional)
        #expect(PageTranslator.keeping(Self.chinese, over: nil) == nil)
    }

    // MARK: Titles mixing scripts

    /// A Chinese GitHub issue with an English product name in the title, lang="en", and English template headings and replies: reads as English.
    static let chineseIssue = """
    <html lang="en"><body>
    <h1><bdi class="markdown-title">类似Little Arc功能</bdi><span> #246</span></h1>
    <h3>What you're trying to do</h3>
    <p>我的当前默认浏览器已改为zigzag</p>
    <ol><li>运行一个py脚本，里面使用了vectorbt.Portfolio画曲线图</li>
    <li>最后vectorbt.Portfolio.plot().show()时，打开的网页显示在主窗口(增加了一个标签)，而不是弹出桌面小窗口</li></ol>
    <h3>What you'd like</h3>
    <p>当在其他应用需要授权登录的时候，希望弹出一个类似Little Arc的小窗口。这是一个非常实用的功能。</p>
    <p>Thank you for setting Zigzag as the default browser! This is actually already available, it's just not turned on by default.</p>
    </body></html>
    """

    @Test func aChineseTitleNamingAnEnglishProductIsTranslated() async throws {
        let (webView, loading) = await page(Self.chineseIssue)
        defer { _ = loading }
        let text = await PageTranslator.text(in: webView)
        let title = try #require(text.pieces.firstIndex(of: "类似Little Arc功能"))
        let groups = PageTranslator.plan(text, page: Self.english, into: Self.english)
        #expect(groups.count == 1)
        #expect(groups.first?.pieces.contains(title) == true)
        // From Simplified, never a Traditional download just for the title (#231).
        #expect(groups.first?.source.minimalIdentifier == Self.chinese.minimalIdentifier)
        // Into Chinese, the title is skipped; the English is translated.
        let intoChinese = PageTranslator.plan(text, page: Self.english, into: Self.chinese)
        #expect(!intoChinese.flatMap(\.pieces).contains(title))
        #expect(texts(text, intoChinese.first).contains("What you're trying to do"))
    }

    @Test func textMostlyInAnotherScriptIsInALanguageWrittenInIt() {
        // Low-confidence English; the ideographs say Chinese.
        #expect(PageTranslator.blockLanguage("类似Little Arc功能", page: Self.english)?.languageCode == .chinese)
        #expect(PageTranslator.blockLanguage("功能", page: Self.english)?.languageCode == .chinese)
        // On a page in that script it's the page's language and script.
        #expect(PageTranslator.blockLanguage("类似Little Arc功能", page: Self.chinese) == Self.chinese)
        #expect(PageTranslator.blockLanguage("東京", page: Locale.Language(identifier: "ja"))?.languageCode == .japanese)
        // On an English page with Chinese, it matches that Chinese.
        #expect(PageTranslator.blockLanguage("功能", page: Self.english, onPage: [Self.english, Self.chinese]) == Self.chinese)
        // English quoting a Chinese name is English.
        #expect(PageTranslator.blockLanguage("An interview with 张艺谋 about his new film and the city he grew up in", page: Self.english)?.languageCode == .english)
    }

    @Test func scriptsAreToldByTheLanguagesWrittenInThem() {
        let han = Array("功能".unicodeScalars), kana = Array("ニュース".unicodeScalars), cyrillic = Array("Новости".unicodeScalars)
        #expect(PageTranslator.writes(Self.chinese, han) && PageTranslator.writes(Self.traditional, han))
        #expect(PageTranslator.writes(Locale.Language(identifier: "ja"), han + kana))
        #expect(!PageTranslator.writes(Self.chinese, kana) && !PageTranslator.writes(Self.english, han))
        #expect(PageTranslator.writes(Locale.Language(identifier: "ru"), cyrillic))
    }

    private func groups(_ codes: [String]) -> [PageTranslator.Group] {
        codes.enumerated().map { PageTranslator.Group(source: Locale.Language(identifier: $0.element), pieces: [$0.offset]) }
    }

    /// Only the page's own language may trigger a download when asked; language-name menus never do.
    @Test func onlyThePagesOwnLanguageAskedForMayDownload() {
        let planned = groups(["zh-Hans", "nl", "ja", "la"])
        let asked = PageTranslator.runnable(planned, status: [.supported, .supported, .installed, .unsupported], asked: true)
        #expect(asked.groups.map(\.source.minimalIdentifier) == ["zh", "ja"])
        #expect(asked.unsupported.map(\.minimalIdentifier) == ["la"])
        #expect(!asked.offer)
    }

    /// Auto-translation offers missing languages, never downloads them.
    @Test func translatingOnItsOwnNeverDownloads() {
        let planned = groups(["zh-Hant", "ja"])
        let missing = PageTranslator.runnable(planned, status: [.supported, .installed], asked: false)
        #expect(missing.groups.isEmpty && missing.offer)
        let here = PageTranslator.runnable(planned, status: [.installed, .supported], asked: false)
        #expect(here.groups.map(\.source) == [Self.traditional])
        #expect(!here.offer)
    }

    /// A language Apple can't translate is skipped for the next group.
    @Test func anUnsupportedFirstGroupPassesToTheNext() {
        let result = PageTranslator.runnable(groups(["la", "zh-Hans"]), status: [.unsupported, .supported], asked: true)
        #expect(result.groups.map(\.source.minimalIdentifier) == ["zh"])
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

    /// A translation's toasts show only while its page is the tab you're on.
    @Test func toastsFollowThePageInView() {
        let tab = Run(), other = Run()
        #expect(PageTranslator.isInView(tab, selected: tab))
        #expect(!PageTranslator.isInView(tab, selected: other))
    }

    /// A long page goes in small requests, on-screen text first, so each comes back well inside the limit (#465).
    @Test func aLongPageIsTranslatedInSmallBatchesOnScreenFirst() {
        let pieces = (0..<100).map { "Paragraphe numéro \($0)." }
        let batches = PageTranslator.batches(Array(0..<100), pieces: pieces, shown: [40, 41, 42], maxPieces: 24, maxCharacters: 10_000)
        #expect(batches.first?.prefix(3) == [40, 41, 42])
        #expect(batches.allSatisfy { $0.count <= 24 })
        #expect(batches.flatMap { $0 }.sorted() == Array(0..<100))
        // The rest follows in page order.
        #expect(Array(batches.flatMap { $0 }.dropFirst(3).prefix(3)) == [0, 1, 2])
        // Long paragraphs cut a request short by characters; one longer than the cap still goes, alone.
        let long = [String(repeating: "a", count: 1500), String(repeating: "b", count: 1500), String(repeating: "c", count: 5000), "d"]
        #expect(PageTranslator.batches([0, 1, 2, 3], pieces: long, maxPieces: 24, maxCharacters: 2400) == [[0], [1], [2], [3]])
        // Places past the page's text are skipped.
        #expect(PageTranslator.batches([0, 9], pieces: ["x"]) == [[0]])
    }

    /// The limit is on going quiet: each batch that comes back starts it again, so a page that keeps coming back
    /// keeps going (#465).
    @Test func theTimeLimitRunsFromTheLastBatch() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(PageTranslator.waitLeft(lastProgress: start, now: start.addingTimeInterval(10), limit: 45) == 35)
        #expect(PageTranslator.waitLeft(lastProgress: start, now: start.addingTimeInterval(45), limit: 45) == nil)
        // Two minutes in, with a batch back 5 seconds ago, it waits on.
        let recent = start.addingTimeInterval(115)
        #expect(PageTranslator.waitLeft(lastProgress: recent, now: start.addingTimeInterval(120), limit: 45) == 40)
        #expect(PageTranslator.percent(0) == 0)
        #expect(PageTranslator.percent(0.426) == 42)
        #expect(PageTranslator.percent(1) == 99)
    }

    /// Reading the page marks what's on screen, so it's translated first.
    @Test func theTextOnScreenIsMarked() async {
        let (webView, loading) = await page("<html><body style='margin:0'><p>En haut de la page.</p><div style='height:3000px'></div><p>Tout en bas de la page.</p></body></html>")
        defer { _ = loading }
        let text = await PageTranslator.text(in: webView)
        #expect(text.pieces == ["En haut de la page.", "Tout en bas de la page."])
        #expect(text.shown == [0])
    }
}

/// Page language from its text and declared lang, and which page an offer belongs to.
struct PageLanguageChoiceTests {
    /// An English article about Shanghai with an infobox of short Chinese names.
    static let englishWithChineseNames = [
        "Shanghai is a direct-administered municipality and the most populous urban area in China.",
        "上海市，简称沪，是中华人民共和国直辖市之一",
        "上海直辖市人民政府位于黄浦区人民大道",
        "沪申海上上海滩外滩陆家嘴浦东新区",
        "The city is located on the southern estuary of the Yangtze River.",
    ]

    @Test func anEnglishPageQuotingChineseStaysEnglish() {
        // By character weight alone the Chinese names dominate.
        #expect(PageTranslator.pageLanguage(blocks: Self.englishWithChineseNames, declared: nil)?.languageCode == .chinese)
        // Declared English with enough English text: English.
        #expect(PageTranslator.pageLanguage(blocks: Self.englishWithChineseNames, declared: "en")?.languageCode == .english)
        #expect(PageTranslator.pageLanguage(blocks: Self.englishWithChineseNames, declared: "en-GB")?.languageCode == .english)
    }

    @Test func textClearlyInAnotherLanguageOverridesWhatThePageSays() {
        // #218: a Spanish page whose template says lang="en".
        let spanish = ["Pasamos toda la semana caminando por las calles estrechas del centro, probando la comida de los mercados.",
                       "La próxima vez queremos quedarnos más tiempo y visitar los pueblos de la costa, que todos nos recomendaron."]
        #expect(PageTranslator.pageLanguage(blocks: spanish, declared: "en")?.languageCode == .spanish)
        #expect(PageTranslator.pageLanguage(blocks: spanish, declared: "es")?.languageCode == .spanish)
        // Too little text: nil regardless of lang, so it's checked again after drawing.
        #expect(PageTranslator.pageLanguage(blocks: ["Inicio", "Contacto"], declared: "es") == nil)
    }

    @Test func aLangThatNamesNoLanguageIsIgnored() {
        #expect(PageTranslator.language(declared: "zh-Hans-CN")?.languageCode == .chinese)
        #expect(PageTranslator.language(declared: " EN_us ")?.languageCode == .english)
        for none in ["", "und", "mul", "zxx", "x-klingon", "1234", "english"] {
            #expect(PageTranslator.language(declared: none) == nil, "\(none)")
        }
    }

    /// Legacy codes (iw, in, ji, no) map to the recognizer's codes so lang agrees with the text.
    @Test func anOldLanguageCodeReadsAsTheNewOne() {
        #expect(PageTranslator.language(declared: "iw")?.languageCode?.identifier == "he")
        #expect(PageTranslator.language(declared: "iw-IL")?.region?.identifier == "IL")
        #expect(PageTranslator.language(declared: "in")?.languageCode?.identifier == "id")
        #expect(PageTranslator.language(declared: "JI")?.languageCode?.identifier == "yi")
        #expect(PageTranslator.language(declared: "no_NO")?.languageCode?.identifier == "nb")
        #expect(PageTranslator.language(declared: "nn")?.languageCode?.identifier == "nn")
        // Hebrew marked "iw" with enough Hebrew text reads as Hebrew, like "he".
        let hebrew = Array(repeating: "שלום לכולם, זהו עמוד בעברית שמספר על מזג האוויר ועל החדשות של היום בעיר.", count: 2)
        let english = Array(repeating: "Hello everyone, this page tells you about the weather and the news of the day in town.", count: 3)
        #expect(PageTranslator.pageLanguage(blocks: hebrew + english, declared: "he")?.languageCode?.identifier == "he")
        #expect(PageTranslator.pageLanguage(blocks: hebrew + english, declared: "iw")?.languageCode?.identifier == "he")
    }

    @Test func anOfferIsForItsOwnPage() {
        let page = URL(string: "https://zh.wikipedia.org/wiki/%E4%B8%8A%E6%B5%B7%E5%B8%82")!
        #expect(PageTranslator.offerStands(offeredFor: page, now: page, foreign: true, translated: false))
        // A fragment jump is the same page.
        #expect(PageTranslator.offerStands(offeredFor: page, now: URL(string: page.absoluteString + "#history")!, foreign: true, translated: false))
        // Another page, one detected as your language, or one translated: the offer goes.
        #expect(!PageTranslator.offerStands(offeredFor: page, now: URL(string: "https://en.wikipedia.org/wiki/Shanghai")!, foreign: true, translated: false))
        #expect(!PageTranslator.offerStands(offeredFor: page, now: page, foreign: false, translated: false))
        #expect(!PageTranslator.offerStands(offeredFor: page, now: page, foreign: true, translated: true))
        #expect(!PageTranslator.offerStands(offeredFor: nil, now: page, foreign: true, translated: false))
    }

    @Test func onlyASitesPageIsReadForItsLanguage() {
        #expect(PageTranslator.readsLanguage(of: URL(string: "https://en.wikipedia.org/wiki/Shanghai"), errorPage: false))
        #expect(PageTranslator.readsLanguage(of: URL(fileURLWithPath: "/tmp/notes.html"), errorPage: false))
        // Zigzag pages (History, Settings) are never offered.
        #expect(!PageTranslator.readsLanguage(of: URL(string: "zigzag://history"), errorPage: false))
        #expect(!PageTranslator.readsLanguage(of: URL(string: "zigzag://settings/general"), errorPage: false))
        #expect(!PageTranslator.readsLanguage(of: URL(string: "about:blank"), errorPage: false))
        #expect(!PageTranslator.readsLanguage(of: nil, errorPage: false))
        // Error pages are in your language.
        #expect(!PageTranslator.readsLanguage(of: URL(string: "https://expired.badssl.com"), errorPage: true))
    }

    @Test func aLanguageNotDownloadedIsNamedWhenTranslatingFails() {
        // The download sheet closed without downloading French: say so, not "try again".
        let french = Locale.Language(identifier: "fr")
        let missing = PageTranslator.failureMessage(notDownloaded: french)
        #expect(missing.contains(PageTranslator.name(of: french)))
        #expect(missing != PageTranslator.failureMessage(notDownloaded: nil))
        #expect(PageTranslator.failureMessage(notDownloaded: nil) == String(localized: "Couldn’t translate this page. Try again in a moment.", comment: "Toast when translating a page fails."))
    }

    // MARK: Always and Never

    private func withChoices(_ body: (PageTranslator.Choices) throws -> Void) rethrows {
        let name = "PageTranslatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(PageTranslator.Choices(defaults: defaults))
    }

    @Test func alwaysAndNeverDecideWhatHappensOnTheirOwn() {
        withChoices { choices in
            let french = Locale.Language(identifier: "fr-FR")
            @MainActor func automatic(site: String = "lemonde.fr", translatedHere: Bool = false, neverHere: Set<String> = [],
                           offers: Bool = true, declined: Bool = false) -> PageTranslator.Automatic {
                choices.automatic(language: french, site: site, translatedHere: translatedHere, neverHere: neverHere, offers: offers, declined: declined)
            }
            // Nothing chosen: offered on each page until closed for the site, and not at all with the offer off.
            #expect(automatic() == .offer)
            #expect(automatic(declined: true) == .nothing)
            #expect(automatic(offers: false) == .nothing)
            // Always French translates on every site, by language code, even with the offer off.
            choices.setAlways(true, "fr")
            #expect(automatic(offers: false) == .translate)
            #expect(automatic(site: "liberation.fr", declined: true) == .translate)
            // Never French replaces Always French.
            choices.setNever(true, "fr")
            #expect(choices.alwaysLanguages.isEmpty)
            #expect(automatic() == .nothing)
            choices.setAlways(true, "fr")
            #expect(choices.neverLanguages.isEmpty)
            // Never This Site beats Always, whether kept or only for a private window.
            choices.setNeverSite(true, "lemonde.fr", isPrivate: false)
            #expect(automatic() == .nothing)
            #expect(automatic(site: "liberation.fr") == .translate)
            #expect(automatic(site: "liberation.fr", neverHere: ["liberation.fr"]) == .nothing)
            // A site translated a moment ago keeps translating as you browse it, unless it's a Never site.
            #expect(automatic(site: "liberation.fr", translatedHere: true, offers: false) == .translate)
            #expect(automatic(translatedHere: true) == .nothing)
        }
    }

    @Test func theAddressBarButtonSaysATranslationIsRunning() {
        let address = AddressView()
        address.setTranslation(available: true, translated: false, translating: true)
        #expect(!address.translateButton.isSelected)
        #expect(address.translateButton.toolTip == String(localized: "Translating Page…", comment: "Tooltip of the address bar's translate button while the page is being translated."))
        address.setTranslation(available: true, translated: true)
        #expect(address.translateButton.isSelected)
        #expect(address.translateButton.tint == Tokens.Color.icon)
    }

    @Test func aPageLoadedAgainIsNoLongerTranslated() throws {
        let tab = Tab(url: URL(string: "http://127.0.0.1:1/a.html"), spaceID: UUID())
        _ = tab.ensureWebView()
        tab.isTranslated = true
        tab.webView(try #require(tab.webView), didCommit: nil)
        #expect(!tab.isTranslated)
    }

    @Test func aTranslationIsRememberedForItsLanguagesOnly() {
        let memory = TranslationMemory()
        let french = Locale.Language(identifier: "fr"), dutch = Locale.Language(identifier: "nl"), english = Locale.Language(identifier: "en")
        memory[.init("Aide", from: french, to: english)] = "Help"
        #expect(memory[.init("Aide", from: french, to: english)] == "Help")
        #expect(memory[.init("Aide", from: dutch, to: english)] == nil)
    }

    /// A Never chosen while a site was translated this session wins at once: the site, or every site translated from
    /// that language, no longer translates its next page on its own.
    @Test func aNeverChoiceStopsASiteTranslatedThisSession() {
        withChoices { choices in
            let french = Locale.Language(identifier: "fr-FR"), german = Locale.Language(identifier: "de")
            let sites: [String: Locale.Language] = ["lemonde.fr": french, "liberation.fr": french, "spiegel.de": german]
            @MainActor func automatic(_ site: String, _ translated: [String: Locale.Language]) -> PageTranslator.Automatic {
                choices.automatic(language: translated[site] ?? french, site: site, translatedHere: translated[site] != nil,
                                  offers: true, declined: true)
            }
            #expect(automatic("lemonde.fr", sites) == .translate)
            // Never This Site, from another tab of the site: only that site stops.
            choices.setNeverSite(true, "lemonde.fr", isPrivate: false)
            let afterSite = PageTranslator.translated(sites, neverSite: "lemonde.fr")
            #expect(afterSite.keys.sorted() == ["liberation.fr", "spiegel.de"])
            #expect(automatic("lemonde.fr", afterSite) == .nothing)
            #expect(automatic("liberation.fr", afterSite) == .translate)
            // Never French: every site translated from French stops, German ones go on.
            choices.setNever(true, "fr")
            let afterLanguage = PageTranslator.translated(afterSite, neverLanguage: "fr")
            #expect(afterLanguage.keys.sorted() == ["spiegel.de"])
            #expect(automatic("liberation.fr", afterLanguage) == .nothing)
            #expect(choices.automatic(language: german, site: "spiegel.de", translatedHere: afterLanguage["spiegel.de"] != nil,
                                      offers: true, declined: true) == .translate)
        }
    }

    /// A Never chosen in one window, or in Settings, holds in a window that still counts the site as translated.
    @Test func aNeverChoiceBeatsASiteTranslatedInAnotherWindow() {
        withChoices { choices in
            let french = Locale.Language(identifier: "fr-FR")
            @MainActor func automatic(_ site: String = "lemonde.fr") -> PageTranslator.Automatic {
                choices.automatic(language: french, site: site, translatedHere: true, offers: true, declined: true)
            }
            #expect(automatic() == .translate)
            choices.setNeverSite(true, "lemonde.fr", isPrivate: false)
            #expect(automatic() == .nothing)
            #expect(automatic("liberation.fr") == .translate)
            choices.setNever(true, "fr")
            #expect(automatic("liberation.fr") == .nothing)
        }
    }

    @Test func aPrivateWindowKeepsNoSites() {
        withChoices { choices in
            #expect(!choices.setNeverSite(true, "lemonde.fr", isPrivate: true))
            #expect(choices.neverSites.isEmpty)
            #expect(choices.defaults.object(forKey: "TranslateNeverSites") == nil)
            // What was chosen in a normal window still counts there.
            #expect(choices.setNeverSite(true, "lemonde.fr", isPrivate: false))
            #expect(!choices.setNeverSite(false, "lemonde.fr", isPrivate: true))
            #expect(choices.neverSites == ["lemonde.fr"])
            #expect(choices.automatic(language: Locale.Language(identifier: "fr"), site: "lemonde.fr", translatedHere: false,
                                      offers: true, declined: false) == .nothing)
        }
    }

    @Test func settingsListsTheChoicesAndRemovesOne() {
        withChoices { choices in
            let names = ["fr": "French", "de": "German", "ja": "Japanese", "es": "Spanish"]
            choices.setAlways(true, "ja")
            choices.setAlways(true, "fr")
            choices.setNever(true, "es")
            choices.setNever(true, "de")
            choices.setNeverSite(true, "lemonde.fr", isPrivate: false)
            let listed = choices.entries { names[$0] ?? $0 }
            #expect(listed.always == [.always("fr"), .always("ja")])
            #expect(listed.never == [.neverLanguage("de"), .neverLanguage("es"), .neverSite("lemonde.fr")])
            choices.remove(.always("fr"))
            choices.remove(.neverSite("lemonde.fr"))
            let after = choices.entries { names[$0] ?? $0 }
            #expect(after.always == [.always("ja")])
            #expect(after.never == [.neverLanguage("de"), .neverLanguage("es")])
            #expect(choices.defaults.object(forKey: "TranslateNeverSites") == nil)
            // Kept in the existing setting, so Always choices made before this still show.
            #expect(choices.defaults.stringArray(forKey: "TranslateAlways") == ["ja"])
        }
    }
}

extension PageTranslatorTests {
    /// A page in a language or on a site set to Never gets no translate button; a translated one keeps it.
    @Test func neverHidesTheTranslateButton() {
        #expect(PageTranslator.offersButton(foreign: true, translated: false, never: false))
        #expect(!PageTranslator.offersButton(foreign: true, translated: false, never: true))
        #expect(PageTranslator.offersButton(foreign: true, translated: true, never: true))
        #expect(!PageTranslator.offersButton(foreign: false, translated: false, never: false))
    }
}

extension PageTranslatorTests {
    /// Every Always or Never choice says it changed, so each window's translate button and Settings › Translation
    /// follow one made anywhere.
    @MainActor @Test func everyChoiceSaysItChanged() {
        let name = "PageTranslatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let choices = PageTranslator.Choices(defaults: defaults)
        var heard = 0
        let token = PageTranslator.choicesChanged.observe { heard += 1 }
        defer { token.cancel() }
        choices.setNever(true, "fr")
        #expect(heard > 0)
        heard = 0
        choices.setNeverSite(true, "lemonde.fr", isPrivate: false)
        #expect(heard > 0)
        heard = 0
        choices.remove(.neverSite("lemonde.fr"))
        #expect(heard > 0)
        heard = 0
        choices.setAlways(true, "ja")
        #expect(heard > 0)
    }
}

/// What a page is read as for the translate offer: English pages, however they're marked or whatever else they show,
/// are English, and a language list or a few odd lines never make a page Hindi or Marathi.
extension PageTranslatorTests {
    private func language(_ html: String) async -> Locale.Language? {
        let (webView, loading) = await page(html)
        defer { _ = loading }
        return await PageTranslator.pageLanguage(of: webView)
    }

    private static let article = """
    <h1>Release notes for the spring update</h1>
    <p>This update makes opening tabs faster and fixes a crash that could happen when a window was closed while a page was still loading.</p>
    <p>Thanks to everyone who sent in reports. If something still looks wrong, open an issue and tell us what you were doing when it happened.</p>
    """

    /// A site's language picker, each language in its own script, in a plain div rather than a nav or footer.
    private static let indicPicker = "<div>हिंदी मराठी বাংলা தமிழ் తెలుగు ಕನ್ನಡ മലയാളം ગુજરાતી ਪੰਜਾਬੀ ଓଡ଼ିଆ অসমীয়া नेपाली संस्कृतम्</div>"

    @Test func anEnglishPageMarkedEnINIsEnglish() async {
        #expect(await language("<html lang=\"en-IN\"><body>\(Self.article)</body></html>")?.languageCode == .english)
        #expect(PageTranslator.language(declared: "en-IN")?.languageCode == .english)
    }

    @Test func anEnglishPageWithNoLangIsEnglish() async {
        #expect(await language("<html><body>\(Self.article)</body></html>")?.languageCode == .english)
    }

    @Test func anEnglishPageWithAFewHindiAndChineseWordsIsEnglish() async {
        let html = """
        <html><body>\(Self.article)<p>Namaste and 你好 to our readers: <span>नमस्ते</span>, thanks for reading.</p>
        <p>हिन्दी में पढ़ें</p><p>阅读中文版</p></body></html>
        """
        #expect(await language(html)?.languageCode == .english)
    }

    @Test func aWrongLangOnAnEnglishPageIsNotBelieved() async {
        for lang in ["hi", "hi-IN", "IN", "in", "mr"] {
            #expect(await language("<html lang=\"\(lang)\"><body>\(Self.article)</body></html>")?.languageCode == .english, "\(lang)")
        }
    }

    @Test func aChinesePageOfEnglishPostsIsEnglish() async {
        let html = """
        <html lang="zh-CN"><body><nav>首页 最新 热门 类别</nav>
        <div>回复</div><div>3 天前</div>\(Self.article)<div>分享</div><div>书签</div></body></html>
        """
        #expect(await language(html)?.languageCode == .english)
    }

    @Test func aLanguagePickerOnAShortEnglishPageIsNotHindi() async {
        let html = "<html><body><h1>Sign in</h1><p>Use your account to keep reading.</p><p>Choose your language</p>\(Self.indicPicker)</body></html>"
        let seen = await language(html)
        #expect(seen == nil || seen?.languageCode == .english, "\(String(describing: seen))")
    }

    @Test func aLanguagePickerNamesNoLanguage() {
        let picker = "हिंदी मराठी বাংলা தமிழ் తెలుగు ಕನ್ನಡ മലയാളം ગુજરાતી ਪੰਜਾਬੀ ଓଡ଼ିଆ অসমীয়া नेपाली संस्कृतम्"
        #expect(PageTranslator.pageLanguage(blocks: [picker, picker], declared: nil) == nil)
        let english = "Use your account to keep reading the articles you saved and the newsletters you follow, on any device."
        #expect(PageTranslator.pageLanguage(blocks: [picker, picker, english], declared: nil)?.languageCode == .english)
        #expect(PageTranslator.dominantLanguage(of: String(repeating: picker + " ", count: 3)) == nil)
    }

    @Test func shortLinesTheRecognizerGuessesAtDontDecide() {
        // Place names read as Indonesian at about half confidence; the English around them is the page.
        let blocks = ["Mumbai Delhi Bangalore Chennai Kolkata Hyderabad Pune",
                      "Mumbai Delhi Bangalore Chennai Kolkata Hyderabad Pune",
                      "ok ok ok lol lmao haha yes yes yes yes",
                      "Our offices are open on weekdays."]
        #expect(PageTranslator.pageLanguage(blocks: blocks, declared: nil)?.languageCode != .indonesian)
    }

    @Test func aPageInAnyOfYourLanguagesIsntForeign() {
        let readers = ["zh-Hans-CN", "en-US"].map { Locale.Language(identifier: $0) }
        #expect(!PageTranslator.isForeign(Locale.Language(identifier: "en"), readers: readers, always: []))
        #expect(!PageTranslator.isForeign(Locale.Language(identifier: "en-IN"), readers: readers, always: []))
        #expect(!PageTranslator.isForeign(Locale.Language(identifier: "zh-Hant"), readers: readers, always: []))
        #expect(PageTranslator.isForeign(Locale.Language(identifier: "hi"), readers: readers, always: []))
        #expect(PageTranslator.isForeign(Locale.Language(identifier: "en"), readers: [Locale.Language(identifier: "zh-Hans")], always: []))
        // Always Translate English still translates it.
        #expect(PageTranslator.isForeign(Locale.Language(identifier: "en"), readers: readers, always: ["en"]))
    }

    @Test func aLanguageMustBeWrittenInTheTextsScript() {
        #expect(PageTranslator.fits(Locale.Language(identifier: "hi"), "हिन्दी में पढ़ें और सुनें"))
        #expect(!PageTranslator.fits(Locale.Language(identifier: "mr"), "हिंदी मराठी বাংলা தமிழ் తెలుగు ಕನ್ನಡ മലയാളം"))
        #expect(!PageTranslator.fits(Locale.Language(identifier: "hi"), "Read this page in Hindi"))
        #expect(PageTranslator.fits(Locale.Language(identifier: "en"), "Read this in Hindi: हिन्दी"))
        #expect(PageTranslator.fits(Locale.Language(identifier: "ja"), "東京の天気はとても良いです"))
        #expect(PageTranslator.fits(Locale.Language(identifier: "zh-Hans"), "上海是一座城市"))
    }
}
