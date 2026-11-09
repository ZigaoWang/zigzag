import WebKit

/// What a profile keeps to itself: where its websites store things, and its own copy of each extension. A page is
/// built from its profile, so two pages on different profiles share no sign-in and no extension data.
final class Profile {
    /// The profile everything was in before there were profiles. Its extensions' storage has always been kept under
    /// this identifier, so it stays the one their controller is made with.
    static let defaultID = UUID(uuidString: "6F1E2D6A-5B0C-4C1B-9E1A-2A7B5D3C9E10")!

    let id: UUID
    var isDefault: Bool { id == Self.defaultID }
    /// Cookies and everything else websites keep. One object for as long as Zigzag runs: certificate exceptions,
    /// sign-in prompts and downloads tell stores apart by which object they are.
    let store: WKWebsiteDataStore
    /// Where its own files are kept. The first profile's are where Zigzag's have always been.
    var folder: URL {
        isDefault ? Paths.support : Paths.directory("Profiles").appendingPathComponent(id.uuidString, isDirectory: true)
    }
    /// What it decided about its extensions: which it has, on or off, what each is allowed.
    private(set) lazy var installs = ExtensionInstalls(profile: self)
    private var host: ExtensionHost?
    /// Its extensions, brought up the first time something in the profile needs them: a profile you haven't opened
    /// since Zigzag started runs none. The first profile's start with the app (ExtensionStore.setUpIfNeeded).
    var extensions: ExtensionHost {
        if let host { return host }
        let made = ExtensionHost(profile: self)
        host = made
        if !isDefault { made.start() }
        return made
    }
    /// Its extensions if they've been brought up, without bringing them up.
    var startedExtensions: ExtensionHost? { host }

    init(id: UUID, store: WKWebsiteDataStore) {
        self.id = id
        self.store = store
        WebKitSetup.allowCrossSiteCookies(in: store)
    }
}

/// The profiles there are, as the library lists them (Profiles.json), each with the one object that holds its store
/// and extensions for as long as Zigzag runs.
final class Profiles {
    static let shared = Profiles()

    /// The first profile, which holds what Zigzag kept before there were profiles.
    let `default` = Profile(id: Profile.defaultID, store: .default())
    private var others: [UUID: Profile] = [:]

    /// Every profile, the first one first.
    var all: [Profile] { Library.shared.profiles.map { profile($0.id) } }

    /// The profile with this ID. One that's gone, or was never there, is the first profile.
    func profile(_ id: UUID) -> Profile {
        guard id != Profile.defaultID, Library.shared.directory.profile(id) != nil else { return `default` }
        if let known = others[id] { return known }
        // WebKit keeps a store for each identifier, made the first time it's asked for.
        let made = Profile(id: id, store: WKWebsiteDataStore(forIdentifier: id))
        others[id] = made
        return made
    }

    /// The profile a space is on.
    func profile(forSpace id: UUID) -> Profile { profile(Library.shared.profileID(ofSpace: id)) }

    /// The profile a page was made in. None for a private page, whose store is its window's own.
    func profile(of webView: WKWebView) -> Profile? { profile(ofStore: webView.configuration.websiteDataStore) }

    func profile(ofStore store: WKWebsiteDataStore) -> Profile? { all.first { $0.store === store } }
}
