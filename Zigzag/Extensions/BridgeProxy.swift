import Foundation
import Network
import WebKit

/// `chrome.proxy`, over WebKit's own proxies for your normal windows (WKWebsiteDataStore.proxyConfigurations).
///
/// WebKit takes fixed proxy servers: HTTP CONNECT (in the clear, or over TLS for Chrome's "https") and SOCKS5, one for
/// all of a store's traffic, with domains that go around it. So `fixed_servers` works, and `system` and `direct` hand
/// back to the Mac's own network settings (WebKit has no way to go around a proxy the Mac sets). PAC scripts and
/// auto-detection have nothing in WebKit to run on, and say so.
///
/// Private windows stay on the Mac's settings: Chrome applies an extension's proxy to incognito only when the extension
/// is allowed there, and Zigzag keeps private windows hidden from extensions altogether.
///
/// As in Chrome, the extension installed most recently among those that set one is the one in control. What each set
/// is kept beside it (Extensions/<id>/proxy.json), applied again at launch, and gone when it's turned off or removed.
@available(macOS 15.4, *)
@MainActor
final class BridgeProxy: BridgeNamespace {
    static let name = "proxy"
    static let permission = "proxy"
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }

    /// Each extension's setting, as it gave it.
    private var settings: [String: [String: Any]] = [:]
    /// Proxy sign-ins an extension's onAuthRequired listeners gave, by the extension and the server they're for.
    /// Never written down: the extension gives them again each time it starts.
    private var credentials: [String: (server: ProxyServer, username: String, password: String)] = [:]
    /// Questions to an extension's onAuthRequired listeners still waiting for an answer, by request ID.
    private var asking: [String: (extensionID: String, server: ProxyServer)] = [:]
    private var asked = 0
    /// What WebKit was last given, so the same again changes nothing.
    private var applied: String?

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        let details = args.object(0)
        switch fn {
        case "settings.get":
            return describe(for: extensionID)
        case "settings.set":
            try Self.checkScope(details)
            guard let value = details["value"] as? [String: Any] else { throw BridgeError("Missing value") }
            // Read first: a setting WebKit can't follow changes nothing, as a failed set in Chrome.
            let parsed = try ProxyRules.parse(value)
            settings[extensionID] = value
            save(value, for: extensionID)
            if case .fixed(let server, _) = parsed, credentials[extensionID]?.server != server { credentials[extensionID] = nil }
            changed()
            askForSignIn(extensionID, again: true)
            return nil
        case "settings.clear":
            try Self.checkScope(details)
            forget(extensionID)
            return nil
        case "authAnswer":
            // What the extension's onAuthRequired listeners said to a question asked below.
            guard let id = args.string(0), let question = asking.removeValue(forKey: id), question.extensionID == extensionID else { return nil }
            let answer = args.object(1)
            guard let username = answer.string("username"), !username.isEmpty else { return nil }
            credentials[extensionID] = (question.server, username, answer.string("password") ?? "")
            if holder == extensionID { apply() }
            return nil
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    /// Only the regular windows' setting: private windows aren't the extension's to change.
    private static func checkScope(_ details: [String: Any]) throws {
        let scope = details.string("scope") ?? "regular"
        guard scope == "regular" || scope == "regular_only" else {
            throw BridgeError(scope.hasPrefix("incognito") ? "You do not have permission to access incognito preferences." : "Invalid scope")
        }
    }

    // MARK: Who's in control

    /// The extension whose setting applies: of those that set one, the one installed last.
    private var holder: String? {
        settings.keys.max { installed($0) < installed($1) || (installed($0) == installed($1) && $0 < $1) }
    }

    private func installed(_ id: String) -> Date {
        (try? host.profile.installs.folder(for: id).resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// Chrome's answer to settings.get: what applies now, and whether it's this extension's to change.
    private func describe(for extensionID: String) -> [String: Any] {
        guard let holder, let value = settings[holder] else {
            return ["value": ["mode": "system"], "levelOfControl": "controllable_by_this_extension"]
        }
        if holder == extensionID { return ["value": value, "levelOfControl": "controlled_by_this_extension"] }
        // One installed later wins, as in Chrome; one installed earlier can't take it over.
        let level = installed(extensionID) > installed(holder) ? "controllable_by_this_extension" : "controlled_by_other_extensions"
        return ["value": value, "levelOfControl": level]
    }

    // MARK: Applying

    /// Sets WebKit's proxies to what the extension in control asked for, and tells every extension listening.
    private func changed() {
        apply()
        for context in host.contexts {
            let id = context.uniqueIdentifier
            host.bridge.emit("proxy.settings.onChange", [describe(for: id)], to: id)
        }
    }

    private func apply() {
        var configurations: [ProxyConfiguration] = []
        var key = "system"
        if let holder, let value = settings[holder], case .fixed(let server, let excluded) = try? ProxyRules.parse(value) {
            var configuration = Self.configuration(for: server)
            configuration.excludedDomains = excluded
            // Chrome doesn't go around a proxy that's down: the page fails, rather than leave by your own address.
            configuration.allowFailover = false
            let signIn = credentials[holder].flatMap { $0.server == server ? $0 : nil }
            if let signIn { configuration.applyCredential(username: signIn.username, password: signIn.password) }
            configurations = [configuration]
            key = "\(server) \(excluded) \(signIn.map { "\($0.username) \($0.password)" } ?? "")"
        }
        // Changing WebKit's proxies can break loads under way: an extension setting the same again (FoxyProxy does
        // each time its background starts) changes nothing.
        guard key != applied else { return }
        applied = key
        WKWebsiteDataStore.default().proxyConfigurations = configurations
    }

    private static func configuration(for server: ProxyServer) -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(server.host), port: NWEndpoint.Port(rawValue: UInt16(server.port)) ?? .http)
        switch server.kind {
        case .http: return ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .https: return ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        case .socks5: return ProxyConfiguration(socksv5Proxy: endpoint)
        }
    }

    // MARK: Proxy sign-in

    /// In Chrome, a proxy that asks for a password is answered by the extension's webRequest.onAuthRequired listeners
    /// (FoxyProxy keeps each proxy's sign-in there). WebKit never asks: it signs in with what it was given up front.
    /// So once an extension sets an HTTP proxy, its listeners are asked for that proxy as Chrome would ask them, and
    /// their answer goes with the proxy. SOCKS proxies aren't asked about, as in Chrome.
    /// `again`: asked even with an answer for this proxy already, as its sign-in may have changed.
    private func askForSignIn(_ extensionID: String, again: Bool = false) {
        guard holder == extensionID, let value = settings[extensionID], case .fixed(let server, _) = try? ProxyRules.parse(value),
              server.kind != .socks5, again || credentials[extensionID]?.server != server,
              host.bridge.isListened("proxy.onAuthRequired", by: extensionID) else { return }
        asked += 1
        let id = "zigzag-proxy-\(asked)"
        // Only the latest question counts; a proxy with no password is never answered.
        asking = asking.filter { $0.value.extensionID != extensionID }
        asking[id] = (extensionID, server)
        let details: [String: Any] = [
            "requestId": id, "url": "https://\(server.host)/", "method": "GET", "frameId": -1, "parentFrameId": -1, "tabId": -1,
            "type": "other", "timeStamp": Date().timeIntervalSince1970 * 1000, "isProxy": true, "scheme": "basic", "realm": "",
            "challenger": ["host": server.host, "port": server.port], "statusCode": 407, "statusLine": "HTTP/1.1 407 Proxy Authentication Required",
        ]
        host.bridge.emit("proxy.onAuthRequired", [details], to: extensionID)
    }

    /// Its listeners may start listening after it set the proxy: they're asked then.
    func startEvents() {
        if let holder { askForSignIn(holder) }
    }

    // MARK: Keeping

    private func file(for id: String) -> URL { host.profile.installs.folder(for: id).appendingPathComponent("proxy.json") }

    private func save(_ value: [String: Any], for id: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? data.write(to: file(for: id), options: .atomic)
    }

    /// A kept setting, if it's one WebKit can still follow (a file cut short, or from a build that took more, isn't).
    static func setting(from data: Data) -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (try? ProxyRules.parse(value)) != nil else { return nil }
        return value
    }

    private func forget(_ id: String) {
        try? FileManager.default.removeItem(at: file(for: id))
        credentials[id] = nil
        asking = asking.filter { $0.value.extensionID != id }
        guard settings.removeValue(forKey: id) != nil else { return }
        changed()
    }

    /// At launch, before any page loads: the settings of extensions still installed and on, as they left them.
    func restore() {
        for id in host.profile.installs.installedIDs where host.profile.installs.isEnabled(id) && ExtensionStore.declaredPermissions(id).required.contains(Self.permission) {
            guard let data = try? Data(contentsOf: file(for: id)), let value = Self.setting(from: data) else { continue }
            settings[id] = value
        }
        if !settings.isEmpty { apply() }
    }

    /// Turned off or removed: its proxy goes with it. (Reloaded, it sets its proxy again as it starts.)
    func release(_ extensionID: String) {
        forget(extensionID)
    }
}

// MARK: - Reading Chrome's settings

/// One proxy server, as WebKit can use it.
struct ProxyServer: Equatable {
    enum Kind: String { case http, https, socks5 }
    var kind: Kind
    var host: String
    var port: Int
}

/// A `chrome.proxy.settings` value (Chrome's ProxyConfig), read in what WebKit's proxies can do.
enum ProxyRules {
    enum Parsed: Equatable {
        /// The Mac's own network settings: `system`, and `direct`, which WebKit can't make go around them.
        case system
        /// One server for every address but the excluded domains.
        case fixed(ProxyServer, excluded: [String])
    }

    static func parse(_ value: [String: Any]) throws -> Parsed {
        switch value.string("mode") {
        case "system", "direct":
            return .system
        case "fixed_servers":
            guard let rules = value["rules"] as? [String: Any] else { throw BridgeError("fixed_servers needs rules") }
            // One server for everything, as WebKit takes: singleProxy, or the same server named for each scheme.
            // (No FTP in WebKit, so proxyForFtp has nothing to apply to.)
            var servers: [ProxyServer] = []
            if let single = rules["singleProxy"] as? [String: Any] {
                servers = [try server(single)]
            } else {
                for key in ["proxyForHttp", "proxyForHttps", "fallbackProxy"] {
                    if let given = rules[key] as? [String: Any] { servers.append(try server(given)) }
                }
            }
            guard let first = servers.first else { throw BridgeError("fixed_servers needs a proxy server") }
            guard servers.allSatisfy({ $0 == first }) else {
                throw BridgeError("Zigzag uses one proxy server for all addresses: give singleProxy, or the same server for each scheme")
            }
            return .fixed(first, excluded: excludedDomains(rules["bypassList"] as? [String] ?? []))
        case "pac_script":
            throw BridgeError("Zigzag can't run proxy auto-config (PAC) scripts: WebKit takes fixed proxy servers only")
        case "auto_detect":
            throw BridgeError("Zigzag can't detect proxies on its own: use \"system\" for the Mac's network settings")
        default:
            throw BridgeError("Invalid proxy mode")
        }
    }

    /// Chrome's ProxyServer: a scheme (http when none), a host, and a port (the scheme's own when none).
    static func server(_ object: [String: Any]) throws -> ProxyServer {
        let scheme = (object.string("scheme") ?? "http").lowercased()
        guard let kind = ProxyServer.Kind(rawValue: scheme) else {
            throw BridgeError("Zigzag doesn't support \(scheme) proxies: use http, https or socks5")
        }
        let host = (object.string("host") ?? "").trimmingCharacters(in: .whitespaces)
        // An IPv6 address may come in brackets, as in an address.
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard !bare.isEmpty, !bare.contains(where: { $0.isWhitespace || $0 == "/" }) else { throw BridgeError("Invalid proxy host") }
        let port = object.number("port").map(Int.init) ?? [.http: 80, .https: 443, .socks5: 1080][kind]!
        guard (1...65_535).contains(port) else { throw BridgeError("Invalid proxy port") }
        return ProxyServer(kind: kind, host: bare, port: port)
    }

    /// Chrome's bypass list, as the domains WebKit sends around the proxy. WebKit matches a domain and everything under
    /// it, so "example.com" and "*.example.com" both cover example.com and its subdomains. What it can't say is left
    /// out: address ranges wider than one address ("10.0.0.0/8"), wildcards inside a name ("*foo*"), a scheme or port
    /// (the host stays), and "<local>"'s names without a dot, of which only .local ones are sent around.
    /// Loopback goes around the proxy unless "<-loopback>" says otherwise, as in Chrome.
    static func excludedDomains(_ bypassList: [String]) -> [String] {
        var domains: [String] = []
        var loopback = true
        for rule in bypassList.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !rule.isEmpty {
            switch rule {
            case "<-loopback>": loopback = false
            case "<local>": domains.append("local")
            default: if let domain = domain(rule) { domains.append(domain) }
            }
        }
        if loopback { domains = ["localhost", "127.0.0.1", "::1"] + domains }
        var seen = Set<String>()
        return domains.filter { seen.insert($0).inserted }
    }

    private static func domain(_ rule: String) -> String? {
        var rule = Substring(rule)
        if let scheme = rule.range(of: "://") { rule = rule[scheme.upperBound...] }
        // An address range: only a single address can be said.
        if let slash = rule.firstIndex(of: "/") {
            let address = String(rule[..<slash]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")), bits = Int(rule[rule.index(after: slash)...])
            if bits == 32, IPv4Address(address) != nil { return address }
            if bits == 128, IPv6Address(address) != nil { return address }
            return nil
        }
        if rule.hasPrefix("[") {
            guard let end = rule.firstIndex(of: "]") else { return nil }
            let address = String(rule[rule.index(after: rule.startIndex)..<end])
            return IPv6Address(address) != nil ? address : nil
        }
        if IPv6Address(String(rule)) != nil { return String(rule) }
        if let colon = rule.lastIndex(of: ":") {
            guard Int(rule[rule.index(after: colon)...]) != nil else { return nil }
            rule = rule[..<colon]
        }
        if rule.hasPrefix("*.") { rule = rule.dropFirst(2) } else if rule.hasPrefix(".") { rule = rule.dropFirst() }
        guard !rule.isEmpty, !rule.contains("*"), !rule.contains("/") else { return nil }
        return String(rule)
    }
}
