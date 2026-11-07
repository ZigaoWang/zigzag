import Foundation
import WebKit

/// Chrome extension APIs that WebKit doesn't have, answered by Zigzag itself.
///
/// An extension's scripts call `chrome.history.search(…)` as they would in Chrome. The bridge script
/// (Resources/Extensions/bridge.js, run before the extension's own code in its background and pages) turns that into
/// a native message to `zigzag.bridge`, which lands here and is handed to the namespace that answers it. Events
/// (`chrome.history.onVisited`) go the other way over a port the script opens only once something listens.
///
/// Every call is checked against what the extension asked for in its own manifest: an extension that didn't ask for
/// "history" can't read history through the bridge, whatever its scripts send. Private windows never show through.
@available(macOS 15.4, *)
@MainActor
final class ExtensionBridge {
    static let shared = ExtensionBridge()
    static let host = "zigzag.bridge"

    private let namespaces: [String: any BridgeNamespace]
    /// Open event ports, by extension, with the events each has listeners for.
    private var ports: [ObjectIdentifier: (port: WKWebExtension.MessagePort, id: String, events: Set<String>)] = [:]

    private init() {
        let all: [any BridgeNamespace] = [BridgeHistory(), BridgeTopSites(), BridgeBookmarks(), BridgeDownloads(), BridgeNotifications(), BridgeIdle(),
                                          BridgeSpeech(), BridgePower(), BridgeOffscreen(), BridgeIdentity()]
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
        Task { @MainActor in
            do {
                let value = try await namespace.call(fn, args: args, extensionID: id)
                reply(["value": Self.plain(value) ?? NSNull()], nil)
            } catch let error as BridgeError {
                reply(["error": error.message], nil)
            } catch {
                reply(["error": error.localizedDescription], nil)
            }
        }
    }

    /// Whether the extension asked for a permission in its own manifest (required, or optional and since granted).
    /// The loaded copy's manifest also asks for native messaging, so the package's own is what counts.
    static func allows(_ permission: String, for context: WKWebExtensionContext) -> Bool {
        let declared = ExtensionStore.declaredPermissions(context.uniqueIdentifier)
        if declared.required.contains(permission) { return true }
        return declared.optional.contains(permission) && context.hasPermission(WKWebExtension.Permission(rawValue: permission))
    }

    /// The same, by the extension's ID, for namespaces that check a further permission ("downloads.open").
    static func allows(_ permission: String, for extensionID: String) -> Bool {
        ExtensionHost.shared.context(for: extensionID).map { allows(permission, for: $0) } ?? false
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
    func isListened(_ event: String) -> Bool { ports.values.contains { $0.events.contains(event) } }

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
struct BridgeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
    static func unsupported(_ ns: String, _ fn: String) -> BridgeError { BridgeError("\(ns).\(fn) isn't available in Zigzag") }
}

/// The script side of the bridge (Resources/Extensions/bridge.js), run before an extension's own code.
enum ExtensionBridgeScript {
    /// The permissions whose APIs the bridge answers, so the install sheet doesn't list them as missing.
    static let permissions: Set<String> = ["history", "topSites", "bookmarks", "downloads", "downloads.open", "notifications", "idle", "tts", "power", "offscreen", "identity"]

    static let source: String = {
        guard let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
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
