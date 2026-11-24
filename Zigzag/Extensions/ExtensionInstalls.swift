import Foundation

/// What one profile decided about its extensions: which it has, whether each is on, what each is allowed and where,
/// and which are pinned to the address. The packages themselves are shared (ExtensionStore): every profile runs the
/// same files, each with its own answers here.
final class ExtensionInstalls {
    unowned let profile: Profile

    init(profile: Profile) { self.profile = profile }

    // MARK: State

    /// What the profile remembers about one extension it has.
    struct State: Codable {
        var enabled = true
        /// Permissions and site patterns the person approved. Nil until the first load records them.
        var grantedPermissions: [String]?
        var grantedMatchPatterns: [String]?
        /// Site patterns allowed when it asked for them (permissions.request), on top of its site access.
        var requestedMatchPatterns: [String]?
        /// Whether `grantedPermissions` also holds the permissions Zigzag's bridge answers (history, a proxy, user
        /// scripts), which WebKit doesn't know. Nil in records made before it did: those take what the manifest asks of
        /// the bridge as approved, once, as they always had, and keep it from then on.
        var bridgeRecorded: Bool?
        /// Where it may read and change pages. Nil means the default: everywhere it was approved for.
        var siteAccess: SiteAccess?
        /// For `.sites`: the sites it may use ("github.com"). Older records may hold sites clicked on; they count for nothing.
        var accessSites: [String]?
        /// Sites where it's off regardless of site access, set from EnergyWatch's high-energy notice.
        var offSites: [String]?
        /// Whether the person turned on Apps on This Mac for it: its own code may reach a program listening on this
        /// Mac over loopback. Off when nil, and carried with the other approvals to another profile.
        var localReceivers: Bool?
        /// Allowed in private windows (#353). Nil is off, as in Chrome.
        var allowsPrivate: Bool?

        static let keys = ["enabled", "grantedPermissions", "grantedMatchPatterns", "requestedMatchPatterns", "bridgeRecorded", "siteAccess", "accessSites", "offSites", "localReceivers", "allowsPrivate"]

        /// What another profile starts with when it gets this extension too: what was approved here and where it
        /// may run, so it gets nothing it wasn't allowed without the install sheet. Sites it was clicked on stay
        /// this profile's: they'd tell the other profile where you've been.
        func carried(enabled: Bool) -> State {
            var next = self
            next.enabled = enabled
            if siteAccess == .click { next.accessSites = nil }
            next.offSites = nil
            // Private windows are asked for again in each profile.
            next.allowsPrivate = nil
            return next
        }
    }

    enum SiteAccess: String, Codable {
        /// Every site it was approved for.
        case all
        /// Only the tab where the person clicked its button, while it stays on that site.
        case click
        /// Only the sites the person listed.
        case sites
    }

    /// Where the profile keeps what's its own about an extension: its answers, the copy WebKit loads, and what the
    /// extension set through Zigzag (a proxy, user scripts). The first profile's have always been in the package's
    /// own folder; another profile's are in the profile's.
    func folder(for id: String) -> URL {
        guard !profile.isDefault else { return ExtensionStore.folder(for: id) }
        return profile.folder.appendingPathComponent("Extensions", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    private func stateFile(for id: String) -> URL { folder(for: id).appendingPathComponent("state.json") }

    /// The folder WebKit loads this extension from, in this profile.
    func loadDirectory(for id: String) async -> URL? { await ExtensionStore.loadDirectory(for: id, copyIn: folder(for: id)) }

    /// This profile's loaded copy, where Zigzag may add files of its own; nil when WebKit loads the package itself.
    func overlayDirectory(for id: String) -> URL? { ExtensionStore.overlayDirectory(for: id, copyIn: folder(for: id)) }

    func state(_ id: String) -> State? { ExtensionStore.read(State.self, from: stateFile(for: id)) }

    func save(_ state: State, for id: String) {
        try? FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
        ExtensionStore.write(state, keys: State.keys, to: stateFile(for: id))
    }

    /// The profile no longer has it. Its package stays for the profiles that do.
    func remove(_ id: String) {
        forgetPasswordSaving(id)
        if profile.isDefault {
            // Its file is the package's too.
            ExtensionStore.remove(keys: State.keys, from: stateFile(for: id))
            for name in ["loaded", "proxy.json", "UserScripts.json", "ContextMenus.json"] { try? FileManager.default.removeItem(at: folder(for: id).appendingPathComponent(name)) }
        } else {
            try? FileManager.default.removeItem(at: folder(for: id))
            ExtensionStore.forgetWhatWasRead()
        }
    }

    func update(_ id: String, _ change: (inout State) -> Void) {
        guard var current = state(id) else { return }
        change(&current)
        save(current, for: id)
    }

    /// Whether the person approved one of the bridge's permissions for this extension, by what was recorded when they
    /// did, and its manifest still asks for it. What its files ask for now never counts by itself: an extension read
    /// from a folder (one inside an app, or Install from Folder) can change them at any time.
    func approves(_ permission: String, for id: String) -> Bool {
        let declared = ExtensionStore.declaredPermissions(id)
        guard declared.required.contains(permission) || declared.optional.contains(permission), let state = state(id) else { return false }
        // Not yet recorded (a record from before): what it was always given, until its next load records it.
        guard state.bridgeRecorded == true, let granted = state.grantedPermissions else { return declared.required.contains(permission) }
        return granted.contains(permission)
    }

    /// The extensions this profile has, on or off, whose package can be read.
    var installedIDs: [String] { installedRead.value(at: ExtensionStore.generation) { ExtensionStore.packageIDs.filter { state($0) != nil } } }

    // Worked out once from what was read, until extension files change (ExtensionStore.forgetWhatWasRead).
    private var installedRead = Remembered<[String]>()
    private var declaresRead = Remembered<[String: Bool]>()
    private var connectableRead = Remembered<[String: [String]]>()

    func isInstalled(_ id: String) -> Bool { state(id) != nil && ExtensionStore.packageDirectory(for: id) != nil }
    /// Whether the profile still has this extension, even if its package can't be read right now (an unpacked folder
    /// on a drive that isn't connected).
    func hasRecord(_ id: String) -> Bool { state(id) != nil }
    func isEnabled(_ id: String) -> Bool { state(id)?.enabled ?? false }
    func siteAccess(_ id: String) -> SiteAccess { state(id)?.siteAccess ?? .all }
    func accessSites(_ id: String) -> [String] { state(id).flatMap { $0.siteAccess == .sites ? $0.accessSites : nil } ?? [] }
    func offSites(_ id: String) -> [String] { state(id)?.offSites ?? [] }
    func allowsPrivate(_ id: String) -> Bool { state(id)?.allowsPrivate ?? false }

    /// Lets it run in private windows, or keeps it out; it starts again either way, as in Chrome.
    func setAllowsPrivate(_ id: String, _ allowed: Bool) {
        guard allowsPrivate(id) != allowed else { return }
        update(id) { $0.allowsPrivate = allowed ? true : nil }
        profile.extensions.applyPrivateAccess(id)
    }

    /// Whether this extension may reach a program listening on this Mac. The person's switch, never a manifest
    /// permission: a Chrome Web Store extension cannot declare one Chrome doesn't have.
    func localReceivers(_ id: String) -> Bool { state(id)?.localReceivers == true }

    func setLocalReceivers(_ allowed: Bool, for id: String) {
        update(id) { $0.localReceivers = allowed }
    }

    /// Turns the extension off or back on for one site and its subdomains.
    func setOff(_ id: String, on site: String, _ off: Bool) {
        update(id) {
            var sites = $0.offSites ?? []
            sites.removeAll { $0 == site }
            if off { sites.append(site) }
            $0.offSites = sites.isEmpty ? nil : sites
        }
        profile.extensions.applySiteAccess(id)
    }

    func setSiteAccess(_ id: String, _ access: SiteAccess, sites: [String]? = nil) {
        update(id) {
            // Another choice starts over, without the sites it asked for.
            if ($0.siteAccess ?? .all) != access { $0.requestedMatchPatterns = nil }
            $0.siteAccess = access
            if access == .sites, let sites { $0.accessSites = sites } else if access != .sites { $0.accessSites = nil }
        }
        profile.extensions.applySiteAccess(id)
    }

    /// Settings' Site access choice: a new choice starts with no sites, as the address menu's do.
    func chooseSiteAccess(_ id: String, _ access: SiteAccess) {
        guard siteAccess(id) != access else { return }
        setSiteAccess(id, access, sites: access == .all ? nil : [])
    }

    /// Adds a site to an extension's On Specific Sites list.
    func addAccessSite(_ id: String, _ site: String) {
        let sites = siteAccess(id) == .sites ? accessSites(id) : []
        guard !sites.contains(site) else { return }
        setSiteAccess(id, .sites, sites: sites + [site])
    }

    func removeAccessSite(_ id: String, _ site: String) {
        setSiteAccess(id, .sites, sites: accessSites(id).filter { $0 != site })
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard isEnabled(id) != enabled else { return }
        update(id) { $0.enabled = enabled }
        if enabled {
            Task { await profile.extensions.load(id) }
        } else {
            // Its search engine goes with it, if it was yours.
            ExtensionSearchProvider.reconcile()
            forgetPasswordSaving(id)
            profile.extensions.unload(id)
        }
    }

    /// Turned off or removed: what it set the browser's password saving to goes too (#513).
    private func forgetPasswordSaving(_ id: String) {
        guard PasswordSavingClaims.clear(by: id, in: profile.id) else { return }
        guard #available(macOS 15.4, *), let host = profile.startedExtensions else { return }
        Task { @MainActor in host.bridge.passwordSaving.changed() }
    }

    /// Installed since Zigzag started, until the extension's background has heard so (BridgeRuntime).
    var newlyInstalled: Set<String> = []

    // MARK: Pins

    private var pinsKey: String { ProfileKey.extensionsPinned.name(in: profile.id) }

    /// The extensions pinned to the address, in every window showing this profile.
    var pins: ExtensionPins {
        get { ExtensionPins(ids: UserDefaults.standard.stringArray(forKey: pinsKey) ?? []) }
        set { UserDefaults.standard.set(newValue.ids, forKey: pinsKey) }
    }

    /// Whether this extension can be pinned now: there's a free slot, counting only those that are on.
    func canPin(_ id: String) -> Bool {
        !pins.contains(id) && pins.canPin(loaded: Set(profile.extensions.contexts.map(\.uniqueIdentifier)))
    }

    /// Pins it, if there's a free slot, or unpins it: decided from what's true now, whoever asks.
    func togglePin(_ id: String) {
        if pins.contains(id) {
            changePins(pins.unpinning(id))
        } else if canPin(id) {
            changePins(pins.pinning(id))
        }
    }

    /// The showing pins dropped into a new order.
    func reorderPins(visible: [String]) {
        changePins(pins.reordered(visible: visible))
    }

    func unpin(_ id: String) { changePins(pins.unpinning(id)) }

    private func changePins(_ new: ExtensionPins) {
        guard new != pins else { return }
        pins = new
        profile.extensions.changed.send()
    }

    // MARK: What pages need to know

    /// Whether an extension that's on here asked for a permission, required or optional.
    func someEnabledExtensionDeclares(_ permission: String) -> Bool {
        var known = declaresRead.value(at: ExtensionStore.generation) { [:] }
        if let answer = known[permission] { return answer }
        let answer = installedIDs.contains { id in
            guard isEnabled(id) else { return false }
            let declared = ExtensionStore.declaredPermissions(id)
            return declared.required.contains(permission) || declared.optional.contains(permission)
        }
        known[permission] = answer
        declaresRead.set(known, at: ExtensionStore.generation)
        return answer
    }

    /// The sites each extension that's on here lets message it (`externally_connectable.matches`), never every site.
    func externallyConnectablePatterns() -> [String: [String]] {
        connectableRead.value(at: ExtensionStore.generation) { readExternallyConnectablePatterns() }
    }

    private func readExternallyConnectablePatterns() -> [String: [String]] {
        var byExtension: [String: [String]] = [:]
        for id in installedIDs where isEnabled(id) {
            let matches = ((ExtensionStore.manifest(for: id)?["externally_connectable"] as? [String: Any])?["matches"] as? [String]) ?? []
            let narrow = matches.filter { $0 != "<all_urls>" && !$0.hasPrefix("*://*/") && !$0.hasPrefix("https://*/") && !$0.hasPrefix("http://*/") }
            if !narrow.isEmpty { byExtension[id] = narrow.sorted() }
        }
        return byExtension
    }
}

/// An answer worked out from files, kept while they're unchanged: until the generation it was worked out at moves on.
struct Remembered<Value> {
    private var value: Value?
    private var generation: Int?

    mutating func value(at generation: Int, _ make: () -> Value) -> Value {
        if let value, self.generation == generation { return value }
        let made = make()
        set(made, at: generation)
        return made
    }

    mutating func set(_ value: Value, at generation: Int) {
        self.value = value
        self.generation = generation
    }
}

/// Who sees private windows (#353): everyday browsing is every extension's to see; a private window's tabs, pages and
/// downloads only an extension allowed in private windows sees.
enum PrivateAccess {
    static func sees(isPrivate: Bool, allowed: Bool) -> Bool { !isPrivate || allowed }
}
