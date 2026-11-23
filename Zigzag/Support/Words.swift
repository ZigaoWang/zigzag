import Foundation

/// Words put together in the language Zigzag speaks, which can differ from the Mac's region: someone in the US may
/// run Zigzag in Chinese.
enum Words {
    /// The locale of the language Zigzag is showing. Keep the Mac's conventions when the language and script
    /// agree, but don't format a Traditional Chinese interface with a Simplified Chinese locale or vice versa.
    nonisolated static let locale: Locale = {
        let language = Locale.Language(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let current = Locale.current.language
        return current.languageCode == language.languageCode && current.script == language.script
            ? .current : Locale(identifier: language.minimalIdentifier)
    }()

    /// The locale dates are written in: the language's own, with American English kept as Zigzag always wrote
    /// it ("Sunday afternoon, October 18"), whatever the Mac's region.
    nonisolated static var dates: Locale {
        locale.language.languageCode == .english ? Locale(identifier: "en_US") : locale
    }

    /// Lowercases a feature name following another in an English list; other languages keep their case. Ideographs are
    /// checked explicitly since a short Chinese string with an English brand can look English.
    static func lowercasedForList(_ text: String) -> String {
        guard NSLinguisticTagger.dominantLanguage(for: text) == "en",
              !text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// Joins two sentences with this language's spacing (none after a full-width stop). Either may be empty.
    static func sentences(_ first: String, _ second: String?) -> String {
        guard let second, !second.isEmpty else { return first }
        guard !first.isEmpty else { return second }
        // Full-width stops carry their own space. A closing quote counts only after one (“好。”), since English uses it
        // too (“…”).
        var marks = first.reversed().makeIterator()
        var last = marks.next()
        if last == "”" { last = marks.next() }
        if let last, fullWidthStops.contains(last) { return first + second }
        return String(localized: "\(first) \(second)", comment: "Joins two sentences, one after the other. Leave out the space if your language doesn't put one between sentences.")
    }

    /// Full-width sentence-ending marks in Chinese and Japanese.
    private static let fullWidthStops: Set<Character> = ["。", "！", "？", "；", "：", "」", "』", "）", "．"]

    /// "Chrome, Arc and Safari": a list joined the way this language joins one ("Chrome、Arc 和 Safari").
    static func list(_ items: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }
}
