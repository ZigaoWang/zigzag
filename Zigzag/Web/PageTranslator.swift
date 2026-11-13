import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import WebKit

/// Page translation with Apple's Translation framework: on this Mac, no account, nothing sent to us.
/// The page's text is read and written back in Zigzag's own script world, so the page's scripts can't see
/// or interfere; the original words are kept so "Show Original" puts them back exactly.
enum PageTranslator {
    /// The language pages are translated into: chosen in Settings, or the system's first language.
    static var readerLanguage: Locale.Language {
        if let chosen = UserDefaults.standard.string(forKey: "TranslateInto") { return Locale.Language(identifier: chosen) }
        return Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// nil follows the system.
    static var chosenLanguage: String? {
        get { UserDefaults.standard.string(forKey: "TranslateInto") }
        set { UserDefaults.standard.set(newValue, forKey: "TranslateInto") }
    }

    /// Offer to translate pages in other languages. On by default.
    static var offers: Bool {
        get { UserDefaults.standard.object(forKey: "TranslateOffers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "TranslateOffers") }
    }

    /// Languages translated without asking, by language code ("zh", "ja").
    static var alwaysLanguages: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "TranslateAlways") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "TranslateAlways") }
    }

    static func code(of language: Locale.Language) -> String { language.languageCode?.identifier ?? language.minimalIdentifier }

    static func translatesAlways(_ language: Locale.Language) -> Bool { alwaysLanguages.contains(code(of: language)) }

    static func setTranslatesAlways(_ always: Bool, _ language: Locale.Language) {
        var set = alwaysLanguages
        if always { set.insert(code(of: language)) } else { set.remove(code(of: language)) }
        alwaysLanguages = set
    }

    /// Languages Apple can translate into on this Mac, by name, for the Settings menu.
    @concurrent nonisolated static func targetLanguages() async -> [(id: String, name: String)] {
        let supported = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        return supported.compactMap { language -> (String, String)? in
            let id = language.minimalIdentifier
            guard seen.insert(id).inserted else { return nil }
            let name = Words.locale.localizedString(forIdentifier: id) ?? id
            return (id, name)
        }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    static func name(of language: Locale.Language) -> String {
        Words.locale.localizedString(forLanguageCode: language.languageCode?.identifier ?? language.minimalIdentifier)
            ?? language.minimalIdentifier
    }

    /// The page's language when it isn't the reader's and Apple can translate it; nil otherwise. What the offer
    /// goes by: the language most of the page is in, so an English page quoting a little Chinese doesn't ask.
    static func foreignLanguage(of webView: WKWebView) async -> Locale.Language? {
        await foreign(await pageLanguage(of: webView))
    }

    /// The language, when it isn't the reader's and Apple can translate it.
    static func foreign(_ language: Locale.Language?) async -> Locale.Language? {
        guard let language, language.languageCode != readerLanguage.languageCode else { return nil }
        return await canTranslate(from: language, to: readerLanguage) ? language : nil
    }

    /// "Translate to English", for the page's right-click menu and a tab's in the sidebar; "Show Original" once
    /// it's translated, the same words as in the site controls (#218).
    static func menuTitle(translated: Bool) -> String {
        translated ? String(localized: "Show Original", comment: "Tooltip of the Original action in the site panel.")
            : String(localized: "Translate to \(name(of: readerLanguage))", comment: "Item in a page's right-click menu and a tab's in the sidebar: translates the page, whatever language it seemed to be in. The language is the one you read, by name, like English.")
    }

    /// A tab whose page could be translated: a website or a file, not one of Zigzag's own pages.
    static func offersTranslation(_ tab: Tab) -> Bool {
        guard let scheme = tab.url?.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    /// One that can be now: a tab that isn't loaded has no text to translate until it is.
    static func canTranslate(_ tab: Tab) -> Bool { offersTranslation(tab) && tab.webView != nil }

    /// Apple can translate between these on this Mac (now, or once the language is downloaded).
    static func canTranslate(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        await LanguageAvailability().status(from: source, to: target) != .unsupported
    }

    /// The language most of the page is in, whatever it is; nil when there's too little text to tell.
    /// Told from the page's own paragraphs, the ones showing, each read on its own and counted by how much text it
    /// has: a Spanish page under an English menu, or one marked lang="en", is still Spanish (#218). A page that's
    /// all menus goes by all of its text.
    static func pageLanguage(of webView: WKWebView) async -> Locale.Language? {
        guard let json = try? await webView.evaluateJavaScript(script("sample()"), in: nil, contentWorld: .defaultClient) as? String,
              let sample = try? JSONDecoder().decode(Sample.self, from: Data(json.utf8)) else { return nil }
        return dominantLanguage(ofBlocks: sample.blocks) ?? dominantLanguage(of: sample.all)
    }

    private struct Sample: Decodable {
        var blocks: [String]
        var all: String
    }

    /// The language most of these blocks are in, by how much text each has; nil when too few can be told, or no
    /// one language has most of it.
    nonisolated static func dominantLanguage(ofBlocks blocks: [String]) -> Locale.Language? {
        var amounts: [NLLanguage: Int] = [:]
        var total = 0
        let recognizer = NLLanguageRecognizer()
        for block in blocks {
            let (amount, long) = measure(block)
            guard long else { continue }
            recognizer.reset()
            recognizer.processString(String(block.prefix(600)))
            guard let (code, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, code != .undetermined,
                  confidence >= 0.5 else { continue }
            amounts[code, default: 0] += amount
            total += amount
        }
        guard total >= 80, let (code, amount) = amounts.max(by: { $0.value < $1.value }), amount * 2 > total else { return nil }
        return Locale.Language(identifier: code.rawValue)
    }

    /// How much text this is, an ideograph, kana or hangul syllable counting as a few letters (each is about a
    /// word), and whether there's enough of it to tell its language by.
    private nonisolated static func measure(_ text: String) -> (amount: Int, long: Bool) {
        var amount = 0, letters = 0, latin = true
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if !isLatin(scalar) { latin = false }
            amount += isWordLike(scalar) ? 3 : 1
        }
        return (amount, latin ? letters >= 24 : letters >= 8)
    }

    private nonisolated static func isWordLike(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0xAC00...0xD7AF: return true
        default: return false
        }
    }

    nonisolated static func dominantLanguage(of sample: String) -> Locale.Language? {
        guard sample.count > 80 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (code, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.8,
              code != .undetermined else { return nil }
        return Locale.Language(identifier: code.rawValue)
    }

    /// The page's text as it's translated: each piece (a run of text in one place), and the block it's in (a
    /// paragraph, a heading, a list item), with each block's text whole, so its language is told from all of it.
    struct PageText: Decodable, Equatable {
        var pieces: [String]
        var blocks: [Int]
        var blockTexts: [String]
    }

    /// Pieces in one language, translated together.
    struct Group: Equatable {
        let source: Locale.Language
        let pieces: [Int]
    }

    /// The text pieces to translate, in page order, and the blocks they're in. Translations put back with `apply`
    /// go by these pieces' places.
    static func text(in webView: WKWebView) async -> PageText {
        let json = try? await webView.evaluateJavaScript(script("collect()"), in: nil, contentWorld: .defaultClient) as? String
        return json.flatMap { try? JSONDecoder().decode(PageText.self, from: Data($0.utf8)) } ?? PageText(pieces: [], blocks: [], blockTexts: [])
    }

    /// The language a page is taken to be in when you ask for it translated. Seen as in your own language, or as
    /// too little to tell, it's read again from all of its text: what was seen as it loaded can be a menu, or a
    /// page still drawing (#218). Still mostly yours, it stays so, and only what isn't is translated.
    nonisolated static func sourceLanguage(seen: Locale.Language?, text: PageText, into target: Locale.Language) -> Locale.Language? {
        guard seen == nil || seen?.languageCode == target.languageCode else { return seen }
        return dominantLanguage(ofBlocks: text.blockTexts) ?? seen
    }

    /// What to translate into `target`, a group for each language, the one with the most text first (#197). Each
    /// block is in the language it reads as; one too short to tell (a button, a menu item) is in the page's. Text
    /// already in the target language is left as it is, so a page in English with a paragraph of Chinese has just
    /// that paragraph translated.
    nonisolated static func plan(_ text: PageText, page: Locale.Language?, into target: Locale.Language) -> [Group] {
        var languages: [Int: Locale.Language?] = [:]
        var order: [String] = []
        var groups: [String: (source: Locale.Language, pieces: [Int], size: Int)] = [:]
        for (index, piece) in text.pieces.enumerated() {
            guard index < text.blocks.count else { break }
            let block = text.blocks[index]
            let language: Locale.Language?
            if let known = languages[block] { language = known } else {
                language = block < text.blockTexts.count ? blockLanguage(text.blockTexts[block], page: page) : page
                languages[block] = language
            }
            guard let language, language.languageCode != target.languageCode else { continue }
            let key = language.minimalIdentifier
            if groups[key] == nil { order.append(key); groups[key] = (language, [], 0) }
            groups[key]?.pieces.append(index)
            groups[key]?.size += piece.count
        }
        return order.compactMap { groups[$0] }.enumerated()
            .sorted { $0.element.size != $1.element.size ? $0.element.size > $1.element.size : $0.offset < $1.offset }
            .map { Group(source: $0.element.source, pieces: $0.element.pieces) }
    }

    /// The language a block of text reads as. Long enough, it's told from its own words. A few words in the page's
    /// alphabet ("Home", "Inicio") can't be told apart reliably, so they're taken as the page's language; a few in
    /// another script ("首页", "ニュース") can, and they're told from their own.
    nonisolated static func blockLanguage(_ text: String, page: Locale.Language?) -> Locale.Language? {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return nil }
        let latin = letters.allSatisfy(isLatin)
        // Ideographs carry a word each: a few are as much to go on as a sentence of letters.
        let long = measure(text).long
        if !long, latin, page != nil { return page }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(600)))
        if let (code, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, code != .undetermined,
           confidence >= (long ? 0.5 : 0.8) {
            return Locale.Language(identifier: code.rawValue)
        }
        return page
    }

    private nonisolated static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: true
        default: false
        }
    }

    static func apply(_ translations: [Int: String], in webView: WKWebView) async {
        guard let data = try? JSONEncoder().encode(translations.mapKeys(String.init)), let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await webView.evaluateJavaScript(script("apply(\(json))"), in: nil, contentWorld: .defaultClient)
    }

    static func restore(in webView: WKWebView) {
        webView.evaluateJavaScript(script("restore()"), in: nil, in: .defaultClient)
    }

    private static func script(_ call: String) -> String { core + "\n__zigzagTranslate." + call + ";" }

    /// Lives in Zigzag's script world. Text nodes are kept in order, with their original text, so translations
    /// land in the same places and the original can come back.
    private static let core = """
    window.__zigzagTranslate = window.__zigzagTranslate || (() => {
      const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'CODE', 'PRE', 'TEXTAREA', 'INPUT', 'SELECT', 'SVG', 'MATH', 'KBD', 'SAMP', 'VAR']);
      // Where a piece of text belongs, for telling its language: the paragraph, heading or cell it's in.
      const blockTags = new Set(['P', 'DIV', 'LI', 'DT', 'DD', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'BLOCKQUOTE', 'FIGCAPTION', 'TD', 'TH',
        'CAPTION', 'SECTION', 'ARTICLE', 'ASIDE', 'HEADER', 'FOOTER', 'NAV', 'MAIN', 'FORM', 'FIELDSET', 'LEGEND', 'LABEL', 'BUTTON',
        'OPTION', 'SUMMARY', 'DETAILS', 'ADDRESS', 'BODY']);
      let nodes = [];
      const originals = new WeakMap();
      const wanted = (node) => {
        const text = node.nodeValue;
        if (!text || !/\\p{L}/u.test(text)) return false;
        for (let el = node.parentElement; el; el = el.parentElement) {
          if (skip.has(el.tagName) || el.isContentEditable || el.getAttribute('translate') === 'no' || el.classList.contains('notranslate')) return false;
        }
        return true;
      };
      const walk = () => {
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
        const found = [];
        while (walker.nextNode() && found.length < 4000) { if (wanted(walker.currentNode)) found.push(walker.currentNode); }
        return found;
      };
      return {
        // The text of the paragraphs showing, a block each, leaving out the site's menus, header and footer; and the
        // start of all of it, for a page that's nothing but those.
        sample: () => {
          const root = document.body;
          if (!root) return JSON.stringify({ blocks: [], all: '' });
          const chrome = 'nav, header, footer, aside, [role=navigation], [role=banner], [role=contentinfo], [aria-hidden=true]';
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          const blocks = [], places = new Map();
          let seen = 0, total = 0;
          while (walker.nextNode() && seen < 4000 && total < 8000) {
            seen++;
            const node = walker.currentNode;
            if (!wanted(node)) continue;
            let block = node.parentElement;
            while (block && !blockTags.has(block.tagName)) block = block.parentElement;
            let place = places.get(block);
            if (place === undefined) {
              const shown = node.parentElement.getClientRects().length > 0 && !node.parentElement.closest(chrome);
              place = shown ? blocks.length : -1;
              places.set(block, place);
              if (shown) blocks.push('');
            }
            if (place < 0 || blocks[place].length >= 600) continue;
            const text = node.nodeValue.trim();
            blocks[place] += (blocks[place] ? ' ' : '') + text;
            total += text.length;
          }
          return JSON.stringify({ blocks, all: (root.innerText || '').slice(0, 2000) });
        },
        collect: () => {
          nodes = walk();
          const pieces = [], blocks = [], blockTexts = [], places = new Map();
          for (const node of nodes) {
            if (!originals.has(node)) originals.set(node, node.nodeValue);
            const text = originals.get(node).trim();
            let block = node.parentElement;
            while (block && !blockTags.has(block.tagName)) block = block.parentElement;
            let place = places.get(block);
            if (place === undefined) { place = blockTexts.length; places.set(block, place); blockTexts.push(''); }
            // Enough of each block to tell its language by.
            if (blockTexts[place].length < 600) blockTexts[place] += (blockTexts[place] ? ' ' : '') + text;
            pieces.push(text);
            blocks.push(place);
          }
          return JSON.stringify({ pieces, blocks, blockTexts });
        },
        apply: (translations) => {
          for (const [index, text] of Object.entries(translations)) {
            const node = nodes[+index];
            if (!node) continue;
            const original = originals.get(node) || node.nodeValue;
            // Keep the spacing around the words, so the page's layout doesn't shift.
            const lead = original.match(/^\\s*/)[0], trail = original.match(/\\s*$/)[0];
            node.nodeValue = lead + text + trail;
          }
          document.documentElement.setAttribute('data-zigzag-translated', '');
        },
        restore: () => {
          for (const node of nodes) { if (originals.has(node)) node.nodeValue = originals.get(node); }
          document.documentElement.removeAttribute('data-zigzag-translated');
        },
      };
    })();
    """
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] { Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) }) }
}

// MARK: - Running translations

/// The translations running in a window, one per tab, each on its own: asking for another tab's never makes one
/// already running stale, and asking again for a tab whose translation is running doesn't start a second.
struct TranslationRuns<Key: Hashable, Run: AnyObject> {
    private var runs: [Key: Run] = [:]

    /// Starts `run` for `key`. False, changing nothing, when one is running there already.
    mutating func begin(_ run: Run, for key: Key) -> Bool {
        guard runs[key] == nil else { return false }
        runs[key] = run
        return true
    }

    func run(for key: Key) -> Run? { runs[key] }

    /// Whether `run` is still the one for `key`: an answer from one that ended (gave up, its page went) changes nothing.
    func isCurrent(_ run: Run, for key: Key) -> Bool { runs[key] === run }

    /// Ends `run`. False when it wasn't the current one, so it's ended only once.
    @discardableResult
    mutating func end(_ run: Run, for key: Key) -> Bool {
        guard runs[key] === run else { return false }
        runs[key] = nil
        return true
    }

    var all: [Run] { Array(runs.values) }
}

extension PageTranslator {
    /// Whether a tab's translation toasts show: only while its page is the one in view, the page peeked at while
    /// Peek is open, otherwise the tab you're on.
    static func isInView(_ tab: AnyObject, selected: AnyObject?, peeked: AnyObject?) -> Bool {
        if let peeked { return peeked === tab }
        return selected === tab
    }
}

/// The Translation framework hands out sessions through a SwiftUI task, so each translation keeps an invisible host
/// for it, in its window. It also gives macOS a window to show its own "download this language?" prompt on.
@MainActor
final class TranslationHost {
    private let model = Model()
    let view: NSView

    init() {
        view = NSHostingView(rootView: HostView(model: model))
        view.frame = .zero
    }

    /// Stops it between batches: nothing more is put in the page, and the completion isn't called.
    func cancel() {
        model.isCancelled = true
        model.job = nil
    }

    /// Translates the pieces of the page in a web view, a language at a time, into `target`. `pieces` are the
    /// page's text as `PageTranslator.text(in:)` read it, and each group names the pieces in one language.
    /// Calls back with what happened.
    func translate(_ webView: WKWebView, pieces: [String], groups: [PageTranslator.Group], into target: Locale.Language,
                   progress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let first = groups.first else { completion(.success(())); return }
        model.job = Job(webView: webView, url: webView.url, pieces: pieces, groups: groups, target: target,
                        total: groups.reduce(0) { $0 + $1.pieces.count }, progress: progress, completion: completion)
        model.start(from: first.source, to: target)
    }

    /// The page went away before it was done: navigated elsewhere, or its tab closed.
    struct Cancelled: Error {}

    struct Job {
        weak var webView: WKWebView?
        /// The page it was asked for: a different page in the same web view is never translated by it.
        let url: URL?
        let pieces: [String]
        let groups: [PageTranslator.Group]
        let target: Locale.Language
        let total: Int
        /// The group being translated now, and how many pieces are done before it.
        var current = 0
        var done = 0
        let progress: (Double) -> Void
        let completion: (Result<Void, Error>) -> Void
    }

    @Observable @MainActor final class Model {
        var configuration: TranslationSession.Configuration?
        @ObservationIgnored var job: Job?
        @ObservationIgnored var isCancelled = false

        /// Runs the task with a session for these languages. The same languages as last time take the same
        /// configuration, invalidated: a new one would equal the last (invalidated just as often) and never run.
        func start(from source: Locale.Language, to target: Locale.Language) {
            if configuration?.source == source, configuration?.target == target {
                configuration?.invalidate()
            } else {
                configuration = TranslationSession.Configuration(source: source, target: target)
            }
        }

        func run(_ session: TranslationSession) async {
            guard !isCancelled, var job else { return }
            self.job = nil
            guard let webView = job.webView, webView.url == job.url else { job.completion(.failure(Cancelled())); return }
            let group = job.groups[job.current]
            do {
                // In page order, a batch at a time, so the top of the page changes first.
                let batch = 120
                for start in stride(from: 0, to: group.pieces.count, by: batch) {
                    let chunk = group.pieces[start..<min(start + batch, group.pieces.count)]
                    // The framework hands the session to this task alone, and it's used one batch at a time;
                    // its types just aren't marked as safe to pass to the framework's own executor.
                    nonisolated(unsafe) let requests = chunk.compactMap { index in
                        index < job.pieces.count ? TranslationSession.Request(sourceText: job.pieces[index], clientIdentifier: String(index)) : nil
                    }
                    nonisolated(unsafe) let session = session
                    let responses = try await session.translations(from: requests)
                    var translated: [Int: String] = [:]
                    for response in responses { if let id = response.clientIdentifier.flatMap(Int.init) { translated[id] = response.targetText } }
                    // Cancelled meanwhile: quietly, with nothing more put in the page.
                    if isCancelled { return }
                    guard webView.url == job.url else { throw Cancelled() }
                    await PageTranslator.apply(translated, in: webView)
                    job.progress(Double(job.done + start + chunk.count) / Double(max(job.total, 1)))
                }
            } catch {
                job.completion(.failure(error))
                return
            }
            job.done += group.pieces.count
            job.current += 1
            guard job.current < job.groups.count else { job.completion(.success(())); return }
            // The next language takes a session of its own: the task runs again with it.
            let next = job.groups[job.current].source
            self.job = job
            start(from: next, to: job.target)
        }
    }

    private struct HostView: View {
        @Bindable var model: Model
        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(model.configuration) { session in await model.run(session) }
        }
    }
}
