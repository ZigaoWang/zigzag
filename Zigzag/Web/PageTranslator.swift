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
        guard let language = await pageLanguage(of: webView), language.languageCode != readerLanguage.languageCode else { return nil }
        return await canTranslate(from: language, to: readerLanguage) ? language : nil
    }

    /// Apple can translate between these on this Mac (now, or once the language is downloaded).
    static func canTranslate(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        await LanguageAvailability().status(from: source, to: target) != .unsupported
    }

    /// The language most of the page is in, whatever it is; nil when there's too little text to tell.
    static func pageLanguage(of webView: WKWebView) async -> Locale.Language? {
        guard let sample = try? await webView.evaluateJavaScript(script("sample()"), in: nil, contentWorld: .defaultClient) as? String else { return nil }
        return dominantLanguage(of: sample)
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
        let long = latin ? letters.count >= 24 : letters.count >= 8
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
        sample: () => (document.body ? document.body.innerText : '').slice(0, 2000),
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

/// The Translation framework hands out sessions through a SwiftUI task, so each window keeps an invisible host
/// for it. It also gives macOS a window to show its own "download this language?" prompt on.
@MainActor
final class TranslationHost {
    private let model = Model()
    let view: NSView

    init() {
        view = NSHostingView(rootView: HostView(model: model))
        view.frame = .zero
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
            guard var job else { return }
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
