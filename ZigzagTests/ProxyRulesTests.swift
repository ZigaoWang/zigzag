import Foundation
import Testing
@testable import Zigzag

/// How `chrome.proxy.settings.set` values read as the proxies WebKit takes.
@MainActor
struct ProxyRulesTests {
    private func fixed(_ rules: [String: Any]) throws -> ProxyRules.Parsed {
        try ProxyRules.parse(["mode": "fixed_servers", "rules": rules])
    }

    @Test func singleProxyAsFoxyProxySetsIt() throws {
        let parsed = try fixed(["singleProxy": ["scheme": "http", "host": "proxy.example.net", "port": 3128], "bypassList": ["localhost", "*.corp.example"]])
        #expect(parsed == .fixed(ProxyServer(kind: .http, host: "proxy.example.net", port: 3128), excluded: ["localhost", "127.0.0.1", "::1", "corp.example"]))
    }

    @Test func schemesMapToWebKitsProxies() throws {
        #expect(try ProxyRules.server(["scheme": "https", "host": "p.example"]) == ProxyServer(kind: .https, host: "p.example", port: 443))
        #expect(try ProxyRules.server(["scheme": "SOCKS5", "host": "127.0.0.1", "port": 9050]) == ProxyServer(kind: .socks5, host: "127.0.0.1", port: 9050))
        // No scheme is http, on its own port.
        #expect(try ProxyRules.server(["host": "p.example"]) == ProxyServer(kind: .http, host: "p.example", port: 80))
        #expect(try ProxyRules.server(["scheme": "socks5", "host": "[::1]"]) == ProxyServer(kind: .socks5, host: "::1", port: 1080))
        // WebKit has no SOCKS4 or QUIC proxies: said, not quietly changed.
        #expect(throws: BridgeError.self) { try ProxyRules.server(["scheme": "socks4", "host": "p.example", "port": 1080]) }
        #expect(throws: BridgeError.self) { try ProxyRules.server(["scheme": "quic", "host": "p.example"]) }
        #expect(throws: BridgeError.self) { try ProxyRules.server(["scheme": "http", "host": ""]) }
        #expect(throws: BridgeError.self) { try ProxyRules.server(["scheme": "http", "host": "p.example", "port": 70_000]) }
    }

    @Test func perSchemeServersMustBeOne() throws {
        let server: [String: Any] = ["scheme": "http", "host": "p.example", "port": 8080]
        #expect(try fixed(["proxyForHttp": server, "proxyForHttps": server]) == .fixed(ProxyServer(kind: .http, host: "p.example", port: 8080), excluded: ["localhost", "127.0.0.1", "::1"]))
        #expect(throws: BridgeError.self) { try fixed(["proxyForHttp": server, "proxyForHttps": ["host": "other.example", "port": 8080]]) }
        #expect(throws: BridgeError.self) { try fixed([:]) }
    }

    @Test func modesWebKitCantFollowAreRefused() throws {
        #expect(throws: BridgeError.self) { try ProxyRules.parse(["mode": "pac_script", "pacScript": ["data": "function FindProxyForURL() { return 'DIRECT'; }"]]) }
        #expect(throws: BridgeError.self) { try ProxyRules.parse(["mode": "auto_detect"]) }
        #expect(throws: BridgeError.self) { try ProxyRules.parse(["mode": "nonsense"]) }
        #expect(try ProxyRules.parse(["mode": "system"]) == .system)
        #expect(try ProxyRules.parse(["mode": "direct"]) == .system)
    }

    @Test func bypassListBecomesExcludedDomains() {
        let domains = ProxyRules.excludedDomains([
            "<local>", "*.example.com", ".example.org", "example.net:8080", "https://secure.example", "192.168.1.1",
            "10.0.0.5/32", "10.0.0.0/8", "[fe80::1]", "fe80::2", "foo*bar.com", "  Mixed.Case  ", "",
        ])
        #expect(domains == ["localhost", "127.0.0.1", "::1", "local", "example.com", "example.org", "example.net", "secure.example",
                            "192.168.1.1", "10.0.0.5", "fe80::1", "fe80::2", "mixed.case"])
        // Loopback goes through the proxy only when the list says so.
        #expect(ProxyRules.excludedDomains(["<-loopback>", "localhost"]) == ["localhost"])
        #expect(ProxyRules.excludedDomains(["127.0.0.1"]) == ["localhost", "127.0.0.1", "::1"])
    }

    /// What's kept for the next launch reads back as the same proxy, and only a setting WebKit can follow is put back.
    @Test func keptSettingsReadBack() throws {
        let value: [String: Any] = ["mode": "fixed_servers", "rules": ["singleProxy": ["scheme": "socks5", "host": "127.0.0.1", "port": 9050], "bypassList": ["*.lan"]]]
        let kept = try #require(BridgeProxy.setting(from: JSONSerialization.data(withJSONObject: value)))
        #expect(try ProxyRules.parse(kept) == ProxyRules.parse(value))
        #expect(BridgeProxy.setting(from: Data(#"{"mode":"pac_script","pacScript":{"url":"http://wpad/wpad.dat"}}"#.utf8)) == nil)
        #expect(BridgeProxy.setting(from: Data(#"{"mode":"fixed_ser"#.utf8)) == nil)
    }
}
