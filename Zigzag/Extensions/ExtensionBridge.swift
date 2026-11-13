import Foundation
import WebKit

/// Chrome extension APIs that WebKit doesn't have, answered by Zigzag itself.
///
/// An extension's scripts call `chrome.history.search(…)` as they would in Chrome. The bridge script
/// (Resources/Extensions/bridge.js, run before the extension's own code in its background and pages) turns that into
/// a native message to `zigzag.bridge`, which lands here and is handed to the namespace that answers it. Events
/// (`chrome.history.onVisited`) go the other way over a port the script opens only once something listens.
///
/// Every call is checked against what the person approved for the extension: one that wasn't allowed "history" can't
/// read history through the bridge, whatever its scripts send, and one whose files now ask for more (an extension read
/// from a folder can change them) gets it only once the person allows it (ExtensionHost.restoreGrants). Private
/// windows never show through.
@available(macOS 15.4, *)
@MainActor
final class ExtensionBridge {
    /// The name extensions' scripts send their calls to.
    static let hostName = "zigzag.bridge"

    /// The extensions it answers: one profile's. What a namespace keeps by an extension's ID is kept here, so two
    /// profiles' copies of the same extension never see each other's.
    unowned let host: ExtensionHost
    private let namespaces: [String: any BridgeNamespace]
    /// Side panels, which the toolbar's click handling asks first (ExtensionHost.performAction).
    let sidePanel: BridgeSidePanel
    /// Offscreen pages, which runtime.getContexts reports.
    let offscreen: BridgeOffscreen
    /// Tab capture, whose captures end with the popup that made them.
    let tabCapture: BridgeTabCapture
    /// Proxy settings, put back at launch before any page loads.
    let proxy: BridgeProxy
    /// Sites' own sign-ins, which extensions' onAuthRequired listeners may answer before the sheet asks.
    let webRequest: BridgeWebRequest
    /// User scripts, which every web view of the profile runs (Tab attaches its own).
    let userScripts: BridgeUserScripts
    /// Open event ports, by extension, with the events each has listeners for.
    private var ports: [ObjectIdentifier: (port: WKWebExtension.MessagePort, id: String, events: Set<String>)] = [:]

    init(host: ExtensionHost) {
        self.host = host
        sidePanel = BridgeSidePanel(host: host)
        offscreen = BridgeOffscreen(host: host)
        tabCapture = BridgeTabCapture(host: host)
        proxy = BridgeProxy(host: host)
        webRequest = BridgeWebRequest(host: host)
        userScripts = BridgeUserScripts(host: host)
        let others: [any BridgeNamespace.Type] = [BridgeHistory.self, BridgeTopSites.self, BridgeBookmarks.self, BridgeDownloads.self, BridgeNotifications.self, BridgeIdle.self,
                                                  BridgeDisplay.self, BridgeContexts.self, BridgeRuntime.self, BridgeSpeech.self, BridgePower.self, BridgeIdentity.self,
                                                  BridgeFavicons.self, BridgeExtensionFetch.self]
        let all: [any BridgeNamespace] = others.map { $0.init(host: host) } + [offscreen, sidePanel, tabCapture, proxy, webRequest, userScripts]
        namespaces = Dictionary(uniqueKeysWithValues: all.map { (type(of: $0).name, $0) })
    }

    // MARK: Calls

    /// One call: `{ ns, fn, args }`. Answers `{ value }`, or `{ error }` with a message the extension can show.
    func handle(_ message: Any, from context: WKWebExtensionContext, reply: @escaping (Any?, (any Error)?) -> Void) {
        guard let body = message as? [String: Any], let ns = body["ns"] as? String, let fn = body["fn"] as? String,
              let namespace = namespaces[ns] else {
            reply(["error": "Unknown call"], nil)
            return
        }
        let id = context.uniqueIdentifier
        guard Self.allows(type(of: namespace).permission, for: context) else {
            reply(["error": "\(ns) needs the “\(type(of: namespace).permission)” permission"], nil)
            return
        }
        let args = body["args"] as? [Any] ?? []
        let host = host
        Task { @MainActor in
            do {
                // A queued fetch must not inherit a replacement context's grants after unload/reload.
                if ns == BridgeExtensionFetch.name, host.context(for: id) !== context {
                    throw BridgeError("The extension is no longer loaded.")
                }
                let value = try await namespace.call(fn, args: args, extensionID: id)
                reply(["value": Self.plain(value) ?? NSNull()], nil)
            } catch {
                let text = (error as? BridgeError)?.message ?? error.localizedDescription
                // In the extensions log, so "it didn't work" can be traced to the call that said no.
                ExtensionLog.write("\(context.webExtension.displayName ?? id) \(ns).\(fn) failed: \(text)")
                reply(["error": text], nil)
            }
        }
    }

    /// Whether the extension may use a permission: the person granted it (when they approved the extension or an
    /// update, or allowed it later), and its own manifest still asks for it. The manifest alone is never enough: what
    /// a folder's files ask for can change behind the person's back. The loaded copy's manifest also asks for native
    /// messaging, so the package's own is what's read.
    static func allows(_ permission: String, for context: WKWebExtensionContext) -> Bool {
        // Namespaces about the extension's own pages need no permission.
        if permission.isEmpty { return true }
        return allows(permission, declared: ExtensionStore.declaredPermissions(context.uniqueIdentifier), granted: context.grantedPermissions)
    }

    /// Asked for (required or optional), and granted and not yet expired. WebKit keeps permissions it doesn't know
    /// itself (the bridge's) among the granted ones too.
    static func allows(_ permission: String, declared: (required: Set<String>, optional: Set<String>),
                       granted: [WKWebExtension.Permission: Date], now: Date = Date()) -> Bool {
        guard declared.required.contains(permission) || declared.optional.contains(permission) else { return false }
        return granted[WKWebExtension.Permission(rawValue: permission)].map { $0 > now } ?? false
    }

    /// The same, by the extension's ID, for namespaces that check a further permission ("downloads.open").
    func allows(_ permission: String, for extensionID: String) -> Bool {
        host.context(for: extensionID).map { Self.allows(permission, for: $0) } ?? false
    }

    // MARK: Events

    /// The event port: the script says which events it listens to (`{ listen: ["history.onVisited"] }`).
    func connect(_ port: WKWebExtension.MessagePort, for context: WKWebExtensionContext) {
        let key = ObjectIdentifier(port)
        ports[key] = (port, context.uniqueIdentifier, [])
        port.messageHandler = { [weak self, weak context] message, _ in
            guard let self, let context, let events = (message as? [String: Any])?["listen"] as? [String] else { return }
            // Only events of namespaces it may use.
            let allowed = events.filter { name in
                guard let ns = name.split(separator: ".").first.map(String.init), let namespace = self.namespaces[ns] else { return false }
                return Self.allows(type(of: namespace).permission, for: context)
            }
            self.ports[key]?.events.formUnion(allowed)
            for ns in Set(allowed.compactMap { $0.split(separator: ".").first.map(String.init) }) {
                self.namespaces[ns]?.startEvents()
            }
        }
        port.disconnectHandler = { [weak self] _ in self?.ports[key] = nil }
    }

    /// Whether any extension listens to an event, so a namespace only watches (idle, say) while someone cares.
    func isListened(_ event: String, by extensionID: String? = nil) -> Bool {
        ports.values.contains { $0.events.contains(event) && (extensionID == nil || $0.id == extensionID) }
    }

    /// Tells every extension listening to `event` (all of them, or only `extensionID`).
    func emit(_ event: String, _ args: [Any], to extensionID: String? = nil) {
        let payload: [String: Any] = ["event": event, "args": Self.plain(args) ?? []]
        for entry in ports.values where entry.events.contains(event) && (extensionID == nil || entry.id == extensionID) {
            entry.port.sendMessage(payload, completionHandler: nil)
        }
    }

    /// An extension turned off or removed: whatever it held (a keep-awake, a voice) is let go.
    func release(_ extensionID: String) {
        for namespace in namespaces.values { namespace.release(extensionID) }
        ports = ports.filter { $0.value.id != extensionID }
    }

    // MARK: Values

    /// Only what JSON can carry crosses to the extension: dates become Chrome's milliseconds, optionals drop out.
    static func plain(_ value: Any?) -> Any? {
        switch value {
        case nil: return nil
        case let date as Date: return date.timeIntervalSince1970 * 1000
        case let array as [Any?]: return array.compactMap { plain($0) ?? NSNull() }
        case let dictionary as [String: Any?]: return dictionary.compactMapValues { plain($0) }
        case let string as String: return string
        case let number as NSNumber: return number
        case let bool as Bool: return bool
        case let int as Int: return int
        case let double as Double: return double
        default: return nil
        }
    }
}

/// A failure to say to the extension, in words.
nonisolated struct BridgeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
    static func unsupported(_ ns: String, _ fn: String) -> BridgeError { BridgeError("\(ns).\(fn) isn't available in Zigzag") }
}

/// The script side of the bridge (Resources/Extensions/bridge.js), run before an extension's own code.
enum ExtensionBridgeScript {
    /// The permissions whose APIs the bridge answers, so the install sheet doesn't list them as missing.
    static let permissions: Set<String> = ["history", "topSites", "bookmarks", "downloads", "downloads.open", "notifications", "idle", "tts", "power", "offscreen", "identity", "sidePanel", "tabCapture", "system.display", "userScripts", "proxy", "webRequestAuthProvider"]

    static let source: String = {
        guard let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    /// Where WebKit answers differently from Chrome, made to answer as Chrome does (webkit-differences.js).
    static let differences: String = webLocks + "\n" + differencesSource

    /// The stand-in for navigator.locks (web-locks.js); also goes in front of worker scripts that use it.
    static let webLocks: String = {
        Bundle.main.url(forResource: "web-locks", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }()
    static let webLocksMark = "zigzag.webLocks"

    private static let differencesSource: String = {
        Bundle.main.url(forResource: "webkit-differences", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }()

    /// Everything Zigzag puts before an extension's own code, after the bridge and the compatibility layer.
    static var afterCompatibility: String { differences + "\n" + surface }

    /// The rest of Chrome's API, from Chrome's own definitions (api-surface.js over chrome-api.json): runs after the
    /// bridge and the compatibility layer, and fills only what's still missing.
    static let surface: String = {
        guard let script = Bundle.main.url(forResource: "api-surface", withExtension: "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
              let data = Bundle.main.url(forResource: "chrome-api", withExtension: "json").flatMap({ try? String(contentsOf: $0, encoding: .utf8) })
        else { return "" }
        return script.replacingOccurrences(of: "__SURFACE__", with: data)
    }()
}

/// One Chrome namespace the bridge answers.
@available(macOS 15.4, *)
@MainActor
protocol BridgeNamespace: AnyObject {
    /// The namespace's name, as in `chrome.<name>`.
    static var name: String { get }
    /// The manifest permission an extension needs to use it.
    static var permission: String { get }
    /// Made for one profile's extensions.
    init(host: ExtensionHost)
    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any?
    /// Something now listens to this namespace's events: start watching for them, if it needs to.
    func startEvents()
    /// The extension is gone: let go of anything kept for it.
    func release(_ extensionID: String)
}

@available(macOS 15.4, *)
extension BridgeNamespace {
    func startEvents() {}
    func release(_ extensionID: String) {}
}

/// Reading arguments as Chrome passes them: an options object, a string, a number.
extension Array where Element == Any {
    func object(_ index: Int) -> [String: Any] { indices.contains(index) ? self[index] as? [String: Any] ?? [:] : [:] }
    func string(_ index: Int) -> String? { indices.contains(index) ? self[index] as? String : nil }
    func number(_ index: Int) -> Double? { indices.contains(index) ? (self[index] as? NSNumber)?.doubleValue : nil }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func number(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    /// Chrome's times are milliseconds since 1970.
    func date(_ key: String) -> Date? { number(key).map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// The name macOS knows an extension's notification by: whose it is, so a click on it reaches the extension that made
/// it, in the profile it's in. The first profile's keep the form they've always had.
nonisolated struct ExtensionNotificationKey: Equatable {
    static let prefix = "ext|"
    /// Nil for the first profile.
    var profile: UUID?
    var extensionID: String
    var id: String

    init(profile: UUID?, extensionID: String, id: String) {
        self.profile = profile
        self.extensionID = extensionID
        self.id = id
    }

    /// From a notification's name; nil if it isn't an extension's. An extension's ID is never a UUID, so a UUID in
    /// first place is a profile.
    init?(_ string: String) {
        guard string.hasPrefix(Self.prefix) else { return nil }
        let rest = string.dropFirst(Self.prefix.count)
        let first = rest.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard first.count == 2 else { return nil }
        if let profile = UUID(uuidString: first[0]) {
            let parts = first[1].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            self.init(profile: profile, extensionID: parts[0], id: parts[1])
        } else {
            self.init(profile: nil, extensionID: first[0], id: first[1])
        }
    }

    var string: String {
        Self.prefix + (profile.map { "\($0.uuidString)|" } ?? "") + "\(extensionID)|\(id)"
    }
}
