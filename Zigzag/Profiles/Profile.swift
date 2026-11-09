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
    /// Its extensions, made the first time something asks for them.
    private(set) lazy var extensions = ExtensionHost(profile: self)

    init(id: UUID, store: WKWebsiteDataStore) {
        self.id = id
        self.store = store
        WebKitSetup.allowCrossSiteCookies(in: store)
    }
}

/// The profiles there are. Today that's one, which holds what Zigzag has always kept.
final class Profiles {
    static let shared = Profiles()

    let `default` = Profile(id: Profile.defaultID, store: .default())
    var all: [Profile] { [`default`] }
}
