import Foundation

/// A search engine an extension gives (`chrome_settings_overrides.search_provider`), as OpenAI's "ChatGPT search"
/// does. While the extension is on it's one of the engines in Settings, but it becomes yours only when you choose it:
/// Chrome asks before keeping the change, and Zigzag asks before making it. Turned off or removed while it's your
/// engine, the one you had before comes back.
struct ExtensionSearchProvider: Equatable {
    let extensionID: String
    let name: String
    /// The search address, with {searchTerms} where the words go.
    let template: String
    /// Where suggestions come from, in the same form, when the extension names a place.
    let suggestTemplate: String?

    /// Only a provider that asks to be the default, with an https address that has a place for the words.
    init?(manifest: [String: Any], extensionID: String) {
        guard let provider = (manifest["chrome_settings_overrides"] as? [String: Any])?["search_provider"] as? [String: Any],
              provider["is_default"] as? Bool == true,
              let template = (provider["search_url"] as? String)?.trimmingCharacters(in: .whitespaces), Self.isSafe(template),
              let host = URL(string: template.replacingOccurrences(of: "{searchTerms}", with: "q"))?.host() else { return nil }
        // Zigzag sends the words as UTF-8, what nearly every engine reads; one that wants another encoding would get them garbled.
        if let encoding = provider["encoding"] as? String, encoding.uppercased() != "UTF-8" { return nil }
        self.extensionID = extensionID
        // A name still to be translated ("__MSG_name__") reads as the site instead.
        let name = (provider["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = name.isEmpty || name.hasPrefix("__MSG_") ? (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) : name
        self.template = template
        suggestTemplate = (provider["suggest_url"] as? String).flatMap { Self.isSafe($0) ? $0 : nil }
    }

    /// An address Zigzag can search with: https, with a host and {searchTerms}, and no other {placeholder} Zigzag
    /// would have to guess at.
    static func isSafe(_ template: String) -> Bool {
        guard template.contains("{searchTerms}") else { return false }
        let filled = template.replacingOccurrences(of: "{searchTerms}", with: "q")
        guard !filled.contains("{"), !filled.contains("}"), let url = URL(string: filled),
              url.scheme?.lowercased() == "https", url.host() != nil else { return false }
        return true
    }

    /// The template with the words in place, encoded as the custom engine's are.
    static func expand(_ template: String, query: String) -> URL? {
        guard isSafe(template) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{searchTerms}", with: SearchEngine.encodedWords(query)))
    }

    func searchURL(_ query: String) -> URL? { Self.expand(template, query: query) }
    func suggestionsURL(_ query: String) -> URL? { suggestTemplate.flatMap { Self.expand($0, query: query) } }

    /// The site's front page, for its icon.
    var homeURL: URL {
        URL(string: template.replacingOccurrences(of: "{searchTerms}", with: "q"))
            .flatMap { $0.host().flatMap { URL(string: "https://\($0)") } } ?? URL(string: "https://www.google.com")!
    }

    // MARK: Which one is yours

    /// Fires when an extension's engine becomes yours, or goes.
    static let changed = Signal<Void>()

    private static let chosenKey = "ExtensionSearchEngine"
    private static let previousKey = "SearchEngineBeforeExtension"

    /// The extension whose engine you chose. It counts only while `Library.searchEngine` is `.fromExtension`.
    private static var chosenID: String? {
        get { UserDefaults.standard.string(forKey: chosenKey) }
        set { UserDefaults.standard.set(newValue, forKey: chosenKey) }
    }

    /// The engine you had before choosing an extension's, to go back to when it goes.
    static var previousEngine: SearchEngine {
        get { UserDefaults.standard.string(forKey: previousKey).flatMap(SearchEngine.init(rawValue:)).flatMap { $0 == .fromExtension ? nil : $0 } ?? .google }
        set { UserDefaults.standard.set(newValue == .fromExtension ? nil : newValue.rawValue, forKey: previousKey) }
    }

    /// The engine an extension gives, while it's installed and on.
    static func provider(for id: String) -> ExtensionSearchProvider? {
        guard ExtensionStore.isEnabled(id), let manifest = ExtensionStore.manifest(for: id) else { return nil }
        return ExtensionSearchProvider(manifest: manifest, extensionID: id)
    }

    /// Every engine extensions give now, for Settings.
    static var available: [ExtensionSearchProvider] { ExtensionStore.installedIDs.sorted().compactMap(provider(for:)) }

    /// The extension engine you search with, if it's still there.
    static var chosen: ExtensionSearchProvider? {
        guard Library.shared.searchEngine == .fromExtension else { return nil }
        return chosenID.flatMap(provider(for:))
    }

    /// Whether this extension's engine is the one you search with.
    static func isChosen(_ id: String) -> Bool { chosen?.extensionID == id }

    /// Makes an extension's engine yours, keeping the one you had to go back to.
    static func use(_ provider: ExtensionSearchProvider) {
        if Library.shared.searchEngine != .fromExtension { previousEngine = Library.shared.searchEngine }
        chosenID = provider.extensionID
        Library.shared.searchEngine = .fromExtension
        changed.send()
    }

    /// After an extension is turned off, removed or updated: if its engine was yours and it's gone, the one before.
    static func reconcile() {
        guard Library.shared.searchEngine == .fromExtension, chosen == nil else { return }
        Library.shared.searchEngine = previousEngine
        chosenID = nil
        changed.send()
    }
}
