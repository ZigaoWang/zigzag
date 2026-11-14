import Foundation

/// Words put together in the language Zigzag speaks, which can differ from the Mac's region: someone in the US may
/// run Zigzag in Chinese.
enum Words {
    /// The locale of the language Zigzag is showing. The Mac's own locale when they share a language, so its
    /// conventions (the comma before "and" in American English, say) stay as they are.
    nonisolated static let locale: Locale = {
        let language = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en").language
        return Locale.current.language.languageCode == language.languageCode ? .current : Locale(identifier: language.minimalIdentifier)
    }()

    /// The locale dates are written in: the language's own, with American English kept as Zigzag always wrote
    /// it ("Sunday afternoon, October 18"), whatever the Mac's region.
    nonisolated static var dates: Locale {
        locale.language.languageCode == .english ? Locale(identifier: "en_US") : locale
    }

    /// Two whole sentences, one after the other, spaced as this language spaces them (not at all after a
    /// full-width full stop). With no second sentence, the first as it is, and with no first, the second.
    static func sentences(_ first: String, _ second: String?) -> String {
        guard let second, !second.isEmpty else { return first }
        guard !first.isEmpty else { return second }
        // A full-width stop carries its own space, in any language Zigzag shows: never one more after it.
        // A closing quote is English's too (“…”), so it counts only after a full-width stop (“好。”).
        var marks = first.reversed().makeIterator()
        var last = marks.next()
        if last == "”" { last = marks.next() }
        if let last, fullWidthStops.contains(last) { return first + second }
        return String(localized: "\(first) \(second)", comment: "Joins two sentences, one after the other. Leave out the space if your language doesn't put one between sentences.")
    }

    /// The marks that end a sentence in Chinese and Japanese, with their own room after them: full-width ones only.
    private static let fullWidthStops: Set<Character> = ["。", "！", "？", "；", "：", "」", "』", "）", "．"]

    /// "Chrome, Arc and Safari": a list joined the way this language joins one ("Chrome、Arc 和 Safari").
    static func list(_ items: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }
}
