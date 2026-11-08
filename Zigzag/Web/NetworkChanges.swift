import Network
import SystemConfiguration
import WebKit

/// A site that speaks HTTP/3 says so, and WebKit keeps that across launches ("alternative services") so it can go
/// over QUIC at once next time. Kept from another network, it can go around the one you're on now: with a proxy app
/// in TUN mode (Clash and the like), a page reached a site over QUIC and IPv6 by itself, past the proxy, while Safari
/// went through it. So when the network changes (a VPN or TUN coming up, Wi-Fi to Ethernet, new
/// proxy or DNS settings), and once at launch, Zigzag forgets those records, and sites connect afresh through
/// whatever the network now is. Nothing else goes: cookies, logins, cache and storage all stay.
@MainActor
enum NetworkChanges {
    /// Not public, but in WebKit's list of website data types (NetworkChangesTests checks it's still there).
    nonisolated static let alternativeServices = "_WKWebsiteDataTypeAlternativeServices"
    /// A network coming up changes several things in a row; they settle into one forgetting.
    private static let settle: TimeInterval = 1.5
    private static var watch: NetworkWatch?

    static func start() {
        guard watch == nil else { return }
        Task { await forget() }
        watch = NetworkWatch(settle: settle) { Task { @MainActor in await forget() } }
    }

    /// Clears the records from the store your windows use and from each private window's own.
    static func forget() async {
        let stores = [WKWebsiteDataStore.default()] + WindowManager.shared.controllers.compactMap(\.tabManager.privateStore)
        for store in stores {
            await store.removeData(ofTypes: [alternativeServices], modifiedSince: .distantPast)
        }
    }
}

/// Watches the network paths and the proxy and DNS settings, off the main thread, and calls `onChange` once a real
/// change has settled. What each source says first is only noted: launch clears once anyway.
nonisolated final class NetworkWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.zigzag.network-watch", qos: .utility)
    private let detector: NetworkChangeDetector
    private let monitor = NWPathMonitor()
    private var store: SCDynamicStore?
    private let keys: [CFString] = [kSCEntNetProxies, kSCEntNetDNS].map {
        SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, $0)
    }

    init(settle: TimeInterval, onChange: @escaping @Sendable () -> Void) {
        detector = NetworkChangeDetector(settle: settle, queue: queue, onChange: onChange)
        monitor.pathUpdateHandler = { [detector] path in detector.note(Self.fingerprint(of: path), from: "path") }
        monitor.start(queue: queue)
        watchSettings()
    }

    deinit {
        monitor.cancel()
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }

    /// What a connection would go through: the interfaces in order (a TUN shows up as a utun), their gateways, and
    /// which kinds of address work.
    static func fingerprint(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        return "\(path.status) \(interfaces) \(gateways) v4=\(path.supportsIPv4) v6=\(path.supportsIPv6) dns=\(path.supportsDNS)"
    }

    private func watchSettings() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkWatch>.fromOpaque(info).takeUnretainedValue().noteSettings()
        }
        guard let store = SCDynamicStoreCreate(nil, "Zigzag" as CFString, callback, &context) else { return }
        SCDynamicStoreSetNotificationKeys(store, keys as CFArray, nil)
        SCDynamicStoreSetDispatchQueue(store, queue)
        self.store = store
        queue.async { self.noteSettings() }
    }

    /// The settings themselves, not just that something wrote them, so the same values written again aren't a change.
    private func noteSettings() {
        guard let store else { return }
        let values = keys.map { SCDynamicStoreCopyValue(store, $0).map { "\($0)" } ?? "-" }
        detector.note(values.joined(separator: "\n"), from: "settings")
    }
}

/// Tells a real change from the same network reported again, and lets a burst of changes settle into one call.
/// Used only on its queue.
nonisolated final class NetworkChangeDetector: @unchecked Sendable {
    private let settle: TimeInterval
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private var last: [String: String] = [:]
    private var pending: DispatchWorkItem?

    init(settle: TimeInterval, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.settle = settle
        self.queue = queue
        self.onChange = onChange
    }

    func note(_ fingerprint: String, from source: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        let before = last.updateValue(fingerprint, forKey: source)
        guard let before, before != fingerprint else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + settle, execute: work)
    }
}
