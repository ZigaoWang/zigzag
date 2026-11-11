import CFNetwork
import Foundation

/// Whether pages go through a proxy running on this Mac (Clash and the like, often at 127.0.0.1:7890). Such a proxy
/// answers for every address, even one that doesn't exist, so its failures look like the network's or the site's.
enum ProxyCheck {
    /// The proxy on this Mac that a page at `url` goes through, as host:port, or nil when there's none. Reads the
    /// system's proxy settings, which is quick.
    static func localProxy(for url: URL) -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        return localProxy(in: settings, scheme: url.scheme ?? "")
    }

    /// The same, from the system's proxy settings (`CFNetworkCopySystemProxySettings`): the proxy for the address's
    /// scheme, or else a SOCKS proxy, when it's on and on this Mac. A proxy elsewhere (at work) doesn't count.
    static func localProxy(in settings: [String: Any], scheme: String) -> String? {
        let kinds = scheme.lowercased() == "https" ? ["HTTPS", "SOCKS"] : scheme.lowercased() == "http" ? ["HTTP", "SOCKS"] : []
        for kind in kinds {
            guard flag(settings["\(kind)Enable"]), let host = settings["\(kind)Proxy"] as? String, isOnThisMac(host) else { continue }
            let port = (settings["\(kind)Port"] as? NSNumber)?.intValue
            let name = host.contains(":") ? "[\(host)]" : host
            return port.map { "\(name):\($0)" } ?? name
        }
        return nil
    }

    private static func flag(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false
    }

    private static func isOnThisMac(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}
