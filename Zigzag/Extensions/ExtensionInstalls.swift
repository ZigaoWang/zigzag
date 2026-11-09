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
        /// Where it may read and change pages. Nil means the default: everywhere it was approved for.
        var siteAccess: SiteAccess?
        /// For `.sites`: the sites it may use ("github.com"), and for `.click`, the ones clicked on so far.
        var accessSites: [String]?

        fileprivate static let keys = ["enabled", "grantedPermissions", "grantedMatchPatterns", "siteAccess", "accessSites"]
    }

    enum SiteAccess: String, Codable {
        /// Every site it was approved for.
        case all
        /// Only a site where the person clicked its button.
        case click
        /// Only the sites the person listed.
        case sites
    }

    /// The first profile's answers have always been kept beside the package's own record, in one file.
    private func stateFile(for id: String) -> URL { ExtensionStore.stateFile(for: id) }

    func state(_ id: String) -> State? { ExtensionStore.read(State.self, from: stateFile(for: id)) }

    func save(_ state: State, for id: String) {
        ExtensionStore.write(state, keys: State.keys, to: stateFile(for: id))
    }

    /// The profile no longer has it. Its package stays for the profiles that do.
    func remove(_ id: String) {
        ExtensionStore.remove(keys: State.keys, from: stateFile(for: id))
    }

    func update(_ id: String, _ change: (inout State) -> Void) {
        guard var current = state(id) else { return }
        change(&current)
        save(current, for: id)
    }

    /// The extensions this profile has, on or off, whose package can be read.
    var installedIDs: [String] { ExtensionStore.packageIDs.filter { state($0) != nil } }

    func isInstalled(_ id: String) -> Bool { state(id) != nil && ExtensionStore.packageDirectory(for: id) != nil }
    /// Whether the profile still has this extension, even if its package can't be read right now (an unpacked folder
    /// on a drive that isn't connected).
    func hasRecord(_ id: String) -> Bool { state(id) != nil }
    func isEnabled(_ id: String) -> Bool { state(id)?.enabled ?? false }
    func siteAccess(_ id: String) -> SiteAccess { state(id)?.siteAccess ?? .all }
    func accessSites(_ id: String) -> [String] { state(id)?.accessSites ?? [] }

    func setSiteAccess(_ id: String, _ access: SiteAccess, sites: [String]? = nil) {
        update(id) {
            $0.siteAccess = access
            if let sites { $0.accessSites = sites } else if access == .all { $0.accessSites = nil }
        }
        profile.extensions.applySiteAccess(id)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard isEnabled(id) != enabled else { return }
        update(id) { $0.enabled = enabled }
        if enabled {
            Task { await profile.extensions.load(id) }
        } else {
            // Its search engine goes with it, if it was yours.
            ExtensionSearchProvider.reconcile()
            profile.extensions.unload(id)
        }
    }

    /// Installed since Zigzag started, until the extension's background has heard so (BridgeRuntime).
    var newlyInstalled: Set<String> = []

    // MARK: Pins

    /// The first profile's pins keep the name they've always been saved under.
    private var pinsKey: String { profile.isDefault ? "ExtensionsPinned" : "ExtensionsPinned.\(profile.id.uuidString)" }

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
        installedIDs.contains { id in
            guard isEnabled(id) else { return false }
            let declared = ExtensionStore.declaredPermissions(id)
            return declared.required.contains(permission) || declared.optional.contains(permission)
        }
    }

    /// The sites each extension that's on here lets message it (`externally_connectable.matches`), never every site.
    func externallyConnectablePatterns() -> [String: [String]] {
        var byExtension: [String: [String]] = [:]
        for id in installedIDs where isEnabled(id) {
            let matches = ((ExtensionStore.manifest(for: id)?["externally_connectable"] as? [String: Any])?["matches"] as? [String]) ?? []
            let narrow = matches.filter { $0 != "<all_urls>" && !$0.hasPrefix("*://*/") && !$0.hasPrefix("https://*/") && !$0.hasPrefix("http://*/") }
            if !narrow.isEmpty { byExtension[id] = narrow.sorted() }
        }
        return byExtension
    }
}
