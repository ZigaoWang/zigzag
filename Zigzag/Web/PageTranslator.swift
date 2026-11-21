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
        get { Choices().alwaysLanguages }
        set { Choices().alwaysLanguages = newValue }
    }

    nonisolated static func code(of language: Locale.Language) -> String { language.languageCode?.identifier ?? language.minimalIdentifier }

    static func translatesAlways(_ language: Locale.Language) -> Bool { alwaysLanguages.contains(code(of: language)) }

    static func setTranslatesAlways(_ always: Bool, _ language: Locale.Language) { Choices().setAlways(always, code(of: language)) }

    /// Always and Never Translate choices, by language code and by site.
    struct Choices {
        var defaults: UserDefaults = .standard

        var alwaysLanguages: Set<String> {
            get { read("TranslateAlways") }
            nonmutating set { write(newValue, "TranslateAlways") }
        }
        var neverLanguages: Set<String> {
            get { read("TranslateNever") }
            nonmutating set { write(newValue, "TranslateNever") }
        }
        var neverSites: Set<String> {
            get { read("TranslateNeverSites") }
            nonmutating set { write(newValue, "TranslateNeverSites") }
        }

        private func read(_ key: String) -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
        private func write(_ value: Set<String>, _ key: String) {
            if value.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(value.sorted(), forKey: key) }
        }

        /// A language is either always or never translated, not both.
        func setAlways(_ on: Bool, _ code: String) {
            if on { alwaysLanguages.insert(code); neverLanguages.remove(code) } else { alwaysLanguages.remove(code) }
        }

        func setNever(_ on: Bool, _ code: String) {
            if on { neverLanguages.insert(code); alwaysLanguages.remove(code) } else { neverLanguages.remove(code) }
        }

        /// A private window keeps no list of sites: returns false and writes nothing there.
        @discardableResult
        func setNeverSite(_ on: Bool, _ site: String, isPrivate: Bool) -> Bool {
            guard !isPrivate else { return false }
            if on { neverSites.insert(site) } else { neverSites.remove(site) }
            return true
        }

        /// One line of the lists in Settings › Translation.
        enum Entry: Hashable {
            case always(String), neverLanguage(String), neverSite(String)
        }

        /// Always first, then Never: languages by name, then sites.
        func entries(name: (String) -> String) -> (always: [Entry], never: [Entry]) {
            func byName(_ codes: Set<String>) -> [String] { codes.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending } }
            return (byName(alwaysLanguages).map(Entry.always),
                    byName(neverLanguages).map(Entry.neverLanguage) + neverSites.sorted().map(Entry.neverSite))
        }

        func remove(_ entry: Entry) {
            switch entry {
            case .always(let code): alwaysLanguages.remove(code)
            case .neverLanguage(let code): neverLanguages.remove(code)
            case .neverSite(let site): neverSites.remove(site)
            }
        }

        /// What happens on its own when a page in `language` opens on `site`. A site translated this session keeps
        /// translating; Never beats Always; otherwise the offer, once per site.
        func automatic(language: Locale.Language, site: String, translatedHere: Bool, neverHere: Set<String> = [],
                       offers: Bool, offered: Bool) -> Automatic {
            if translatedHere { return .translate }
            if neverSites.contains(site) || neverHere.contains(site) { return .nothing }
            let code = PageTranslator.code(of: language)
            if neverLanguages.contains(code) { return .nothing }
            if alwaysLanguages.contains(code) { return .translate }
            return offers && !offered ? .offer : .nothing
        }
    }

    enum Automatic: Equatable { case translate, offer, nothing }

    /// The sites translated this session, after a Never choice: the site chosen, or every site translated from the
    /// language chosen, stops translating its pages on its own, so the Never holds at once.
    static func translated(_ sites: [String: Locale.Language], neverSite site: String? = nil, neverLanguage code: String? = nil) -> [String: Locale.Language] {
        sites.filter { entry in entry.key != site && (code == nil || self.code(of: entry.value) != code) }
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

    /// Apple can translate between these on this Mac (now, or once the language is downloaded).
    static func canTranslate(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        await status(from: source, to: target) != .unsupported
    }

    /// Whether Apple can translate this pair here: installed, downloadable, or unsupported.
    static func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    /// The page's main language, or nil when there's too little text. Each visible paragraph is detected separately
    /// and weighted by length, combined with the page's `lang`. A few foreign words on an English page don't change
    /// it; only clearly dominant text overrides `lang` (a Spanish page with lang="en" is Spanish, #218). Menu-only
    /// pages use all their text.
    static func pageLanguage(of webView: WKWebView) async -> Locale.Language? {
        guard let json = try? await webView.runOwnScript(script("sample()")) as? String,
              let sample = try? JSONDecoder().decode(Sample.self, from: Data(json.utf8)) else { return nil }
        return pageLanguage(blocks: sample.blocks, declared: sample.lang) ?? dominantLanguage(of: sample.all)
    }

    private struct Sample: Decodable {
        var blocks: [String]
        var all: String
        var lang: String?
    }

    /// The language most of these blocks are in, by how much text each has; nil when too few can be told, or no
    /// one language has most of it.
    nonisolated static func dominantLanguage(ofBlocks blocks: [String]) -> Locale.Language? {
        pageLanguage(blocks: blocks, declared: nil)
    }

    /// Without `declared`, the language with most text. With it, `declared` wins if there's enough text and at least
    /// a quarter is in it; three quarters in another language overrides it.
    nonisolated static func pageLanguage(blocks: [String], declared: String?) -> Locale.Language? {
        let (amounts, total) = tally(blocks)
        guard total >= 80 else { return nil }
        let top = amounts.max { $0.value != $1.value ? $0.value < $1.value : $0.key.rawValue > $1.key.rawValue }
        let topLanguage = top.map { Locale.Language(identifier: $0.key.rawValue) }
        let topShare = top.map { Double($0.value) / Double(total) } ?? 0
        if let said = declared.flatMap(language(declared:)) {
            if let topLanguage, topLanguage.languageCode == said.languageCode { return topLanguage }
            if let topLanguage, topShare >= 0.75 { return topLanguage }
            let saidAmount = amounts.filter { Locale.Language(identifier: $0.key.rawValue).languageCode == said.languageCode }.values.reduce(0, +)
            if Double(saidAmount) / Double(total) >= 0.25 { return said }
        }
        guard let topLanguage, topShare > 0.5 else { return nil }
        return topLanguage
    }

    /// From the first subtag ("zh" of "zh-Hans-CN"); nil for none, "und", "mul", "zxx" or a private "x-" tag.
    nonisolated static func language(declared: String) -> Locale.Language? {
        let tag = declared.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        guard let first = tag.split(separator: "-").first?.lowercased(), (2...3).contains(first.count),
              first.allSatisfy({ $0.isASCII && $0.isLetter }), !["und", "mul", "zxx", "mis"].contains(first) else { return nil }
        // Legacy codes mapped to what the recognizer uses: Hebrew, Indonesian, Yiddish, and Norwegian as Bokmål.
        guard let modern = legacyCodes[first] else { return Locale.Language(identifier: tag) }
        return Locale.Language(identifier: ([modern] + tag.split(separator: "-").dropFirst().map(String.init)).joined(separator: "-"))
    }

    private nonisolated static let legacyCodes = ["iw": "he", "in": "id", "ji": "yi", "no": "nb"]

    /// Text amount per language, and in total; blocks too short or too uncertain are skipped.
    private nonisolated static func tally(_ blocks: [String]) -> (amounts: [NLLanguage: Int], total: Int) {
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
        return (amounts, total)
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
        /// Pieces on screen when it was read, translated first.
        var shown: [Int]? = nil
    }

    /// Most pieces in one request to Apple's translation.
    nonisolated static let batchPieces = 24
    /// Most characters in one request, so a request of long paragraphs still comes back well inside the time limit.
    nonisolated static let batchCharacters = 2400

    /// A group's pieces in the order they're translated, cut into requests: the ones on screen first, then the rest,
    /// each in page order; a request ends at `maxPieces` pieces or `maxCharacters` characters (#465).
    nonisolated static func batches(_ group: [Int], pieces: [String], shown: Set<Int> = [],
                                    maxPieces: Int = batchPieces, maxCharacters: Int = batchCharacters) -> [[Int]] {
        let order = group.filter { shown.contains($0) } + group.filter { !shown.contains($0) }
        var batches: [[Int]] = [], current: [Int] = [], characters = 0
        for index in order where index < pieces.count {
            let size = pieces[index].count
            if !current.isEmpty, current.count >= maxPieces || characters + size > maxCharacters {
                batches.append(current)
                current = []
                characters = 0
            }
            current.append(index)
            characters += size
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// How much longer to wait for the next translated batch, or nil when it's been `limit` since the last one:
    /// the limit is on a translation going quiet, not on the whole page (#465).
    nonisolated static func waitLeft(lastProgress: Date, now: Date, limit: TimeInterval) -> TimeInterval? {
        let left = limit - now.timeIntervalSince(lastProgress)
        return left > 0 ? left : nil
    }

    /// The whole percent done, for the toast; never 100 before it's done.
    nonisolated static func percent(_ fraction: Double) -> Int {
        min(99, max(0, Int((fraction * 100).rounded(.down))))
    }

    /// Pieces in one language, translated together.
    struct Group: Equatable {
        let source: Locale.Language
        let pieces: [Int]
    }

    /// The text pieces to translate, in page order, and the blocks they're in. Translations put back with `apply`
    /// go by these pieces' places.
    static func text(in webView: WKWebView) async -> PageText {
        let json = try? await webView.runOwnScript(script("collect()")) as? String
        return json.flatMap { try? JSONDecoder().decode(PageText.self, from: Data($0.utf8)) } ?? PageText(pieces: [], blocks: [], blockTexts: [])
    }

    /// The language a page is taken to be in when you ask for it translated. Seen as in your own language, or as
    /// too little to tell, it's read again from all of its text: what was seen as it loaded can be a menu, or a
    /// page still drawing (#218). Still mostly yours, it stays so, and only what isn't is translated.
    nonisolated static func sourceLanguage(seen: Locale.Language?, text: PageText, into target: Locale.Language) -> Locale.Language? {
        guard seen == nil || seen?.languageCode == target.languageCode else { return seen }
        return dominantLanguage(ofBlocks: text.blockTexts) ?? seen
    }

    /// On a site translated before, keeps the earlier source when it's the same language in another variant
    /// (Wikipedia's switcher showing Traditional instead of Simplified), so no extra macOS download is needed (#231).
    nonisolated static func keeping(_ kept: Locale.Language?, over seen: Locale.Language?) -> Locale.Language? {
        guard let kept, let seen, seen.languageCode == kept.languageCode else { return seen }
        return kept
    }

    /// After a failed translation: the first source still not downloaded (its download sheet was closed). Nil if all
    /// are here or unsupported.
    static func notDownloaded(_ sources: [Locale.Language], into target: Locale.Language) async -> Locale.Language? {
        for source in sources where await status(from: source, to: target) == .supported { return source }
        return nil
    }

    /// Names a missing language and how to get it; otherwise says to try again.
    static func failureMessage(notDownloaded language: Locale.Language?) -> String {
        guard let language else {
            return String(localized: "Couldn’t translate this page. Try again in a moment.", comment: "Toast when translating a page fails.")
        }
        return String(localized: "\(name(of: language)) isn’t downloaded for translation. Choose Translate again to download it.",
                      comment: "Toast when a page couldn't be translated because macOS's download of its language was closed without downloading it. The language is its name, like French.")
    }

    /// Which groups to translate given each one's `status` (same order). Unsupported languages are skipped and named.
    /// A language still to download runs only if it's the page's own (first group) and you asked: macOS's download
    /// sheet should only follow your action, never a menu of language names or an automatic translation (#231). For
    /// automatic translation with the language missing, nothing runs and `offer` offers it instead.
    nonisolated static func runnable(_ groups: [Group], status: [LanguageAvailability.Status], asked: Bool)
        -> (groups: [Group], unsupported: [Locale.Language], offer: Bool) {
        var run: [Group] = [], unsupported: [Locale.Language] = []
        var first = true
        for (group, status) in zip(groups, status) {
            switch status {
            case .unsupported: unsupported.append(group.source); continue
            case .installed: run.append(group)
            default:
                if first {
                    if asked { run.append(group) } else { return ([], unsupported, true) }
                }
            }
            first = false
        }
        return (run, unsupported, false)
    }

    /// What to translate into `target`, a group for each language, the one with the most text first (#197). Each
    /// block is in the language it reads as; one too short to tell (a button, a menu item) is in the page's. Text
    /// already in the target language is left as it is, so a page in English with a paragraph of Chinese has just
    /// that paragraph translated.
    nonisolated static func plan(_ text: PageText, page: Locale.Language?, into target: Locale.Language) -> [Group] {
        // Confidently detected blocks first, so ambiguous ones (a title mixing Chinese and a product name) can join
        // the page's text in their script.
        let used = Set(text.blocks.filter { $0 < text.blockTexts.count })
        var told: [Int: Locale.Language] = [:]
        var amounts: [String: (language: Locale.Language, amount: Int)] = [:]
        for block in used.sorted() {
            guard let language = surely(text.blockTexts[block]) else { continue }
            told[block] = language
            amounts[language.minimalIdentifier, default: (language, 0)].amount += measure(text.blockTexts[block]).amount
        }
        let onPage = amounts.values.sorted { $0.amount > $1.amount }.map(\.language)
        var languages: [Int: Locale.Language?] = [:]
        var order: [String] = []
        var groups: [String: (variants: [String: (language: Locale.Language, size: Int)], pieces: [Int], size: Int)] = [:]
        for (index, piece) in text.pieces.enumerated() {
            guard index < text.blocks.count else { break }
            let block = text.blocks[index]
            let language: Locale.Language?
            if let known = languages[block] { language = known } else {
                if let sure = told[block] { language = sure }
                else if block < text.blockTexts.count { language = blockLanguage(text.blockTexts[block], page: page, onPage: onPage) }
                else { language = page }
                languages[block] = language
            }
            guard var language, language.languageCode != target.languageCode else { continue }
            // Another variant of the page's language (Traditional on a Simplified page) translates with the page;
            // separately it would need a second download (#231).
            if let page, page.languageCode == language.languageCode { language = page }
            let key = code(of: language)
            if groups[key] == nil { order.append(key); groups[key] = ([:], [], 0) }
            groups[key]?.variants[language.minimalIdentifier, default: (language, 0)].size += piece.count
            groups[key]?.pieces.append(index)
            groups[key]?.size += piece.count
        }
        // Each language's pieces translate together, from their majority script, so a Traditional title on a
        // Simplified page needs no second download (#231).
        return order.compactMap { groups[$0] }.enumerated()
            .sorted { $0.element.size != $1.element.size ? $0.element.size > $1.element.size : $0.offset < $1.offset }
            .compactMap { entry in
                entry.element.variants.values.max { $0.size != $1.size ? $0.size < $1.size : $0.language.minimalIdentifier > $1.language.minimalIdentifier }
                    .map { Group(source: $0.language, pieces: entry.element.pieces) }
            }
    }

    /// A block's language. Long text is detected from its own words. A few words in the page's script ("Home",
    /// "Inicio") are unreliable, so they take the page's language; a few in another script ("首页", "ニュース") are
    /// detected. Mostly non-Latin text that can't be told for sure ("类似Little Arc功能") is taken as a language in that
    /// script, treating the Latin words as names: the page's if it uses that script, else the page's most common one
    /// that does (`onPage`, most first), else what the letters alone suggest.
    nonisolated static func blockLanguage(_ text: String, page: Locale.Language?, onPage: [Locale.Language] = []) -> Locale.Language? {
        let letters = Array(text.unicodeScalars.filter { $0.properties.isAlphabetic })
        guard !letters.isEmpty else { return nil }
        let others = letters.filter { !isLatin($0) }
        if others.isEmpty, !measure(text).long, page != nil { return page }
        if let told = surely(text) { return told }
        guard mostlyOtherScript(letters) else { return page }
        if let fitting = ([page].compactMap { $0 } + onPage).first(where: { writes($0, others) }) { return fitting }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(String.UnicodeScalarView(text.unicodeScalars.map { isLatin($0) ? " " : $0 }).prefix(600)))
        if let (code, _) = recognizer.languageHypotheses(withMaximum: 1).first, code != .undetermined {
            let alone = Locale.Language(identifier: code.rawValue)
            if script(of: alone) != "Latn", !contradicts(alone, others) { return alone }
        }
        return page
    }

    /// Detected confidently from enough text and, for mostly non-Latin text, a language written in that script.
    private nonisolated static func surely(_ text: String) -> Locale.Language? {
        let letters = Array(text.unicodeScalars.filter { $0.properties.isAlphabetic })
        guard !letters.isEmpty else { return nil }
        // Ideographs carry a word each: a few are as much to go on as a sentence of letters.
        let long = measure(text).long
        if !long, letters.allSatisfy(isLatin) { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(600)))
        guard let (code, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, code != .undetermined,
              confidence >= (long ? 0.5 : 0.8) else { return nil }
        let language = Locale.Language(identifier: code.rawValue)
        if mostlyOtherScript(letters), script(of: language) == "Latn" || contradicts(language, letters.filter { !isLatin($0) }) { return nil }
        return language
    }

    /// Weighted by how much each letter carries.
    private nonisolated static func mostlyOtherScript(_ letters: [Unicode.Scalar]) -> Bool {
        var latin = 0, other = 0
        for scalar in letters {
            if isLatin(scalar) { latin += 1 } else { other += isWordLike(scalar) ? 3 : 1 }
        }
        return other > 0 && other >= latin
    }

    /// By the language's usual script (Chinese in ideographs, Japanese in those and kana, Russian in Cyrillic).
    nonisolated static func writes(_ language: Locale.Language, _ letters: [Unicode.Scalar]) -> Bool {
        guard !letters.isEmpty, let script = script(of: language) else { return false }
        return letters.allSatisfy { scripts(of: $0).contains(script) }
    }

    /// Whether any letter is in a known script the language isn't written in.
    private nonisolated static func contradicts(_ language: Locale.Language, _ letters: [Unicode.Scalar]) -> Bool {
        guard let script = script(of: language) else { return false }
        return letters.contains { let known = scripts(of: $0); return !known.isEmpty && !known.contains(script) }
    }

    /// "Hans" for Chinese, "Jpan" for Japanese, "Latn" for English.
    private nonisolated static func script(of language: Locale.Language) -> String? {
        (language.script ?? Locale.Language(identifier: language.maximalIdentifier).script)?.identifier
    }

    /// ISO 15924 scripts for the scripts distinguished here; empty for others.
    private nonisolated static func scripts(of scalar: Unicode.Scalar) -> Set<String> {
        if scalar.properties.isIdeographic { return ["Hans", "Hant", "Jpan", "Kore"] }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return ["Jpan"]
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF: return ["Kore"]
        case 0x0400...0x052F, 0x1C80...0x1C8F: return ["Cyrl"]
        case 0x0370...0x03FF, 0x1F00...0x1FFF: return ["Grek"]
        case 0x0590...0x05FF, 0xFB1D...0xFB4F: return ["Hebr"]
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return ["Arab"]
        case 0x0E00...0x0E7F: return ["Thai"]
        case 0x0900...0x097F: return ["Deva"]
        default: return []
        }
    }

    private nonisolated static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: true
        default: false
        }
    }

    static func apply(_ translations: [Int: String], in webView: WKWebView) async {
        guard let data = try? JSONEncoder().encode(translations.mapKeys(String.init)), let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await webView.runOwnScript(script("apply(\(json))"))
    }

    static func restore(in webView: WKWebView) {
        webView.runOwnScript(script("restore()"))
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
          const lang = document.documentElement.getAttribute('lang') || root.getAttribute('lang') || '';
          return JSON.stringify({ blocks, all: (root.innerText || '').slice(0, 2000), lang });
        },
        collect: () => {
          nodes = walk();
          const pieces = [], blocks = [], blockTexts = [], shown = [], places = new Map();
          const height = window.innerHeight, width = window.innerWidth;
          for (const node of nodes) {
            const box = node.parentElement && node.parentElement.getBoundingClientRect();
            if (box && box.width > 0 && box.height > 0 && box.bottom > 0 && box.top < height && box.right > 0 && box.left < width) shown.push(pieces.length);
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
          return JSON.stringify({ pieces, blocks, blockTexts, shown });
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
    /// Site pages only: never Zigzag's own pages (History and Settings list titles in other languages) or error
    /// pages.
    nonisolated static func readsLanguage(of url: URL?, errorPage: Bool) -> Bool {
        guard let scheme = url?.scheme?.lowercased(), !errorPage else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    /// Whether an offer made for `offeredFor` still applies: same page (a `#` jump counts), still foreign, not yet
    /// translated.
    nonisolated static func offerStands(offeredFor: URL?, now: URL?, foreign: Bool, translated: Bool) -> Bool {
        guard foreign, !translated, let offeredFor, let now else { return false }
        func page(_ url: URL) -> String {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.fragment = nil
            return parts?.string ?? url.absoluteString
        }
        return page(offeredFor) == page(now)
    }

    /// Whether a browser window's tab's translation toasts show: only while it's the tab you're on.
    static func isInView(_ tab: AnyObject, selected: AnyObject?) -> Bool { selected === tab }
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
    func translate(_ webView: WKWebView, pieces: [String], shown: Set<Int> = [], groups: [PageTranslator.Group], into target: Locale.Language,
                   progress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let first = groups.first else { completion(.success(())); return }
        model.job = Job(webView: webView, url: webView.url, pieces: pieces, shown: shown, groups: groups, target: target,
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
        let shown: Set<Int>
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
                // On-screen text first, in small batches, each put in the page as it comes back.
                var finished = 0
                for chunk in PageTranslator.batches(group.pieces, pieces: job.pieces, shown: job.shown) {
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
                    finished += chunk.count
                    job.progress(Double(job.done + finished) / Double(max(job.total, 1)))
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
