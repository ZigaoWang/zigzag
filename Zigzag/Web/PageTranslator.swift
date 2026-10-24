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
            let name = Locale.current.localizedString(forIdentifier: id) ?? id
            return (id, name)
        }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forLanguageCode: language.languageCode?.identifier ?? language.minimalIdentifier)
            ?? language.minimalIdentifier
    }

    /// The page's language when it isn't the reader's and Apple can translate it; nil otherwise.
    static func foreignLanguage(of webView: WKWebView) async -> Locale.Language? {
        guard let sample = try? await webView.evaluateJavaScript(script("sample()"), in: nil, contentWorld: .defaultClient) as? String,
              sample.count > 80 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (code, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.8,
              code != .undetermined else { return nil }
        let language = Locale.Language(identifier: code.rawValue)
        guard language.languageCode != readerLanguage.languageCode else { return nil }
        let status = await LanguageAvailability().status(from: language, to: readerLanguage)
        return status == .unsupported ? nil : language
    }

    /// The text pieces to translate, in page order, and a way to put translations back.
    static func pieces(in webView: WKWebView) async -> [String] {
        let json = try? await webView.evaluateJavaScript(script("collect()"), in: nil, contentWorld: .defaultClient) as? String
        return json.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
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
      const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'TEXTAREA', 'SVG', 'MATH', 'KBD', 'SAMP', 'VAR']);
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
          return JSON.stringify(nodes.map((n) => { if (!originals.has(n)) originals.set(n, n.nodeValue); return originals.get(n).trim(); }));
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

    /// Translates the page in a web view from one language into the reader's. Calls back with what happened.
    func translate(_ webView: WKWebView, from source: Locale.Language, progress: @escaping (Double) -> Void,
                   completion: @escaping (Result<Void, Error>) -> Void) {
        model.job = Job(webView: webView, progress: progress, completion: completion)
        model.configuration = TranslationSession.Configuration(source: source, target: PageTranslator.readerLanguage)
        model.configuration?.invalidate()
    }

    struct Job {
        weak var webView: WKWebView?
        let progress: (Double) -> Void
        let completion: (Result<Void, Error>) -> Void
    }

    @Observable @MainActor final class Model {
        var configuration: TranslationSession.Configuration?
        @ObservationIgnored var job: Job?

        func run(_ session: TranslationSession) async {
            guard let job, let webView = job.webView else { return }
            self.job = nil
            let pieces = await PageTranslator.pieces(in: webView)
            guard !pieces.isEmpty else { job.completion(.success(())); return }
            do {
                // In page order, a batch at a time, so the top of the page changes first.
                let batch = 120
                for start in stride(from: 0, to: pieces.count, by: batch) {
                    let end = min(start + batch, pieces.count)
                    // The framework hands the session to this task alone, and it's used one batch at a time;
                    // its types just aren't marked as safe to pass to the framework's own executor.
                    nonisolated(unsafe) let requests = (start..<end).map { TranslationSession.Request(sourceText: pieces[$0], clientIdentifier: String($0)) }
                    nonisolated(unsafe) let session = session
                    let responses = try await session.translations(from: requests)
                    var translated: [Int: String] = [:]
                    for response in responses { if let id = response.clientIdentifier.flatMap(Int.init) { translated[id] = response.targetText } }
                    await PageTranslator.apply(translated, in: webView)
                    job.progress(Double(end) / Double(pieces.count))
                }
                job.completion(.success(()))
            } catch {
                job.completion(.failure(error))
            }
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
