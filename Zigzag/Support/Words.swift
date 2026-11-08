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

    /// "Chrome, Arc and Safari": a list joined the way this language joins one ("Chrome、Arc 和 Safari").
    static func list(_ items: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }
}
