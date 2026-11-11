import WebKit

/// What a profile keeps to itself: where its websites store things, and its own copy of each extension. A page is
/// built from its profile, so two pages on different profiles share no sign-in and no extension data.
final class Profile {
    /// The profile everything was in before there were profiles. Its extensions' storage has always been kept under
    /// this identifier, so it stays the one their controller is made with.
    nonisolated static let defaultID = UUID(uuidString: "6F1E2D6A-5B0C-4C1B-9E1A-2A7B5D3C9E10")!

    let id: UUID
    var isDefault: Bool { id == Self.defaultID }
    /// Cookies and everything else websites keep. One object for as long as Zigzag runs: certificate exceptions,
    /// sign-in prompts and downloads tell stores apart by which object they are. Made the first time something in
    /// the profile needs it: WebKit creates a store on disk when it's asked for, and won't remove one this run has
    /// opened, so a profile that's only listed (in Settings, in a menu) doesn't get one.
    var store: WKWebsiteDataStore {
        if let madeStore { return madeStore }
        let store: WKWebsiteDataStore = isDefault ? .default() : WKWebsiteDataStore(forIdentifier: id)
        WebKitSetup.allowCrossSiteCookies(in: store)
        madeStore = store
        return store
    }
    /// Its store if anything has used it since Zigzag started, without making it.
    var storeIfMade: WKWebsiteDataStore? { madeStore }
    private var madeStore: WKWebsiteDataStore?
    /// Where its own files are kept. The first profile's are where Zigzag's have always been.
    var folder: URL {
        isDefault ? Paths.support : Profiles.folder(of: id)
    }
    /// The pages visited in it. The first profile's is the file History has always been.
    private(set) lazy var history: HistoryStore = {
        guard !isDefault else { return HistoryStore(path: Paths.history.path) }
        // Its folder may not be there yet: a profile that has no extensions has had nothing to keep in it.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return HistoryStore(path: folder.appendingPathComponent("History.sqlite").path, profile: id)
    }()
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

    init(id: UUID) {
        self.id = id
    }
}

/// The profiles there are, as the library lists them (Profiles.json), each with the one object that holds its store
/// and extensions for as long as Zigzag runs.
final class Profiles {
    static let shared = Profiles()

    /// The first profile, which holds what Zigzag kept before there were profiles.
    let `default` = Profile(id: Profile.defaultID)
    private var others: [UUID: Profile] = [:]

    /// Every profile, the first one first.
    var all: [Profile] { Library.shared.profiles.map { profile($0.id) } }
    /// The profiles whose store something has used since Zigzag started: the ones there is anything to tidy in.
    var opened: [Profile] { all.filter { $0.isDefault || $0.storeIfMade != nil } }

    /// The profile with this ID. One that's gone, or was never there, is the first profile.
    func profile(_ id: UUID) -> Profile {
        listed(id) ?? `default`
    }

    /// The profile with this ID while it's listed; nil for one that's gone. For a profile you chose (where something
    /// is added or imported): one removed meanwhile is refused, never swapped for the first.
    func listed(_ id: UUID) -> Profile? {
        if id == Profile.defaultID { return `default` }
        guard Library.shared.directory.profile(id) != nil else { return nil }
        if let known = others[id] { return known }
        let made = Profile(id: id)
        others[id] = made
        return made
    }

    /// The profile a space is on.
    func profile(forSpace id: UUID) -> Profile { profile(Library.shared.profileID(ofSpace: id)) }

    /// The profile a page was made in. None for a private page, whose store is its window's own.
    func profile(of webView: WKWebView) -> Profile? { profile(ofStore: webView.configuration.websiteDataStore) }

    func profile(ofStore store: WKWebsiteDataStore) -> Profile? { all.first { $0.storeIfMade === store } }

    /// The profile a page is in: its tab's, or for a page that isn't a tab's (a pop-up window), the one it was made
    /// in; the first for a page that's in none. Where a page's history is looked up.
    func profile(ofPage webView: WKWebView?) -> Profile {
        (webView as? BrowserWebView)?.owner?.profile ?? webView.flatMap { profile(of: $0) } ?? `default`
    }

    // MARK: Profiles in use

    /// The profiles something is writing into for a while (an import, an extension being added), each with how
    /// many are. One of these isn't
    /// removed until they're done (`remove`): what's being written would land in data that's being erased.
    private var writers: [UUID: Int] = [:]
    var inUse: Set<UUID> { Set(writers.keys) }

    /// Says a profile is being written into, until `done` is called with it. False, with nothing held, for one
    /// that's no longer listed: there's nowhere to write.
    func hold(_ id: UUID) -> Bool {
        guard id == Profile.defaultID || Library.shared.directory.profile(id) != nil else { return false }
        writers[id, default: 0] += 1
        return true
    }

    func done(_ id: UUID) {
        guard let count = writers[id] else { return }
        writers[id] = count > 1 ? count - 1 : nil
    }

    /// Whether a profile may be removed now, and if not, why: asked before the question is put, and again by
    /// `remove` itself.
    func removalBlock(_ id: UUID) -> ProfileDirectory.RemovalBlock? { Library.shared.directory.removalBlock(id, inUse: inUse) }

    // MARK: Removing a profile

    /// Removes a profile and everything it kept: its extensions and what they stored, its sign-ins and website
    /// data. Its spaces move to the first profile. It can't be undone.
    ///
    /// The removal is written down before anything is erased (the library's `deleting` list), so one that's cut
    /// short is finished the next time Zigzag starts. That's also when WebKit lets go of the store: it won't remove
    /// one this run has opened.
    ///
    /// False, with nothing changed, when it can't be removed now (`removalBlock`).
    @discardableResult
    func remove(_ id: UUID) async -> Bool {
        guard removalBlock(id) == nil else { return false }
        let profile = profile(id)
        // Never the first profile, whatever was asked for: its folder is all of Zigzag's data.
        guard !profile.isDefault else { return false }
        let had = profile.installs.installedIDs
        // From here it's in no list: its spaces are on the first profile, and their pages are rebuilt there. Nothing
        // is erased unless that's on disk.
        guard Library.shared.removeProfile(id) else { return false }
        others[id] = nil
        for popup in PopupWindowController.all where popup.webView.configuration.websiteDataStore === profile.storeIfMade { popup.window?.close() }
        for mini in MiniWindowController.all { mini.settleProfile() }
        if let host = profile.startedExtensions { await host.shutDown() }
        ProfileKey.forget(id)
        try? FileManager.default.removeItem(at: profile.folder)
        UpdateBackup.forget(profile: id)
        // A package no profile has any more goes too.
        for id in had where ExtensionStore.profiles(with: id).isEmpty && !ExtensionStore.isUnpacked(id) {
            try? FileManager.default.removeItem(at: ExtensionStore.folder(for: id))
        }
        await Self.eraseStore(id)
        return true
    }

    /// At launch, before anything has opened their stores: the profiles whose removal isn't finished.
    static func finishRemovals() {
        // Never the first profile, and never one that's listed as in use.
        let waiting = Library.shared.directory.deleting.map(\.id).filter { $0 != Profile.defaultID && Library.shared.directory.profile($0) == nil }
        guard !waiting.isEmpty else { return }
        Task {
            for id in waiting { await erase(id) }
            // A removal cut short didn't get to the packages only that profile had.
            for id in ExtensionStore.packageIDs where ExtensionStore.profiles(with: id).isEmpty && !ExtensionStore.isUnpacked(id) {
                try? FileManager.default.removeItem(at: ExtensionStore.folder(for: id))
            }
        }
    }

    /// Erases what's on disk and in the backups under an ID that's written down as being removed
    /// and that no page has opened in this run.
    private static func erase(_ id: UUID) async {
        guard id != Profile.defaultID, Library.shared.directory.profile(id) == nil else { return }
        try? FileManager.default.removeItem(at: folder(of: id))
        UpdateBackup.forget(profile: id)
        ProfileKey.forget(id)
        await eraseStore(id)
    }

    /// Where a profile other than the first keeps its files.
    static func folder(of id: UUID) -> URL {
        Paths.support.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: Data that's no profile's

    /// What's on disk under an ID that's neither a profile's nor being removed: a store WebKit keeps, or a profile's
    /// folder. It's left by a Profiles.json put back from a backup made before the profile was, or one that
    /// couldn't be read and was set aside. Never erased without asking: it may be a profile you still want.
    func orphans() async -> [UUID] {
        let stores = await WKWebsiteDataStore.allDataStoreIdentifiers
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: Paths.support.appendingPathComponent("Profiles", isDirectory: true).path)) ?? []
        return Library.shared.directory.orphans(amongStores: stores + folders.compactMap(UUID.init(uuidString:)))
    }

    /// Erases what's on disk under an ID that's no profile's, once that's written down, so it's finished at the
    /// next start if it can't be now.
    func eraseOrphan(_ id: UUID) async {
        guard Library.shared.markForErasing(id) else { return }
        await Self.erase(id)
    }

    /// Has WebKit remove a profile's store, then removes what WebKit leaves of its extensions' storage. Only then
    /// is the removal done; if WebKit won't yet, it stays written down for the next start.
    private static func eraseStore(_ id: UUID) async {
        guard id != Profile.defaultID else { return }
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: id)
        } catch {
            // The store was never made (a profile no page was opened in) or is in use until Zigzag quits.
            guard !FileManager.default.fileExists(atPath: ExtensionStore.websiteData(ofStore: id).deletingLastPathComponent().path) else { return }
        }
        try? FileManager.default.removeItem(at: ExtensionStore.extensionData(ofController: id))
        Library.shared.finishedRemovingProfile(id)
    }
}
