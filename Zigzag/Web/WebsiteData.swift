import WebKit

/// Clearing what sites keep on this Mac: their cache (pages load fresh) or their cookies and storage (signed
/// out). For one site, or for all of them. Private windows keep nothing to begin with.
@MainActor
enum WebsiteData {
    enum Kind {
        case cache, cookies

        var types: Set<String> {
            switch self {
            case .cache:
                [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]
            case .cookies:
                // Signing out takes the site's storage too, or it would sign straight back in.
                [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases,
                 WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeServiceWorkerRegistrations, WKWebsiteDataTypeFileSystem]
            }
        }
    }

    /// Clears `kind` for a site ("youtube.com", covering its subdomains), or for every site when `site` is nil, in
    /// one store: a profile's, or a private window's own. Every site's cookies leave the `kept` sites' alone (#334).
    static func clear(_ kind: Kind, site: String? = nil, keeping kept: Set<String> = [], in store: WKWebsiteDataStore) async {
        await clearStore(kind, site: site, keeping: kept, in: store)
        // Session cookies kept for the next launch go with them.
        if kind == .cookies { SessionCookies.cleared(site: site, keeping: site == nil ? kept : [], in: store) }
    }

    private static func clearStore(_ kind: Kind, site: String?, keeping kept: Set<String>, in store: WKWebsiteDataStore) async {
        if kind == .cookies, site == nil, !kept.isEmpty {
            let removed = await KeptCookies.clear(kind.types, keeping: kept, in: store) ?? []
            for name in Set(removed.compactMap(KeptCookies.site(ofHost:))) {
                DarkSeen.forget(in: store, site: name)
                forgetConnections(in: store, site: name)
            }
            return
        }
        // Dark pages' sites seen dark name the sites they were seen on: they go with either.
        DarkSeen.forget(in: store, site: site)
        // Clearing cookies also clears its trusted certificate exceptions and HSTS state.
        if kind == .cookies { forgetConnections(in: store, site: site) }
        guard let site else {
            await store.removeData(ofTypes: kind.types, modifiedSince: .distantPast)
            return
        }
        let records = await store.dataRecords(ofTypes: kind.types)
        let matching = records.filter { record in
            let name = record.displayName.lowercased()
            return name == site || site.hasSuffix("." + name) || name.hasSuffix("." + site)
        }
        guard !matching.isEmpty else { return }
        await store.removeData(ofTypes: kind.types, for: matching)
    }

    /// Forgets certificate exceptions and HSTS hosts, for one site or all.
    static func forgetConnections(in store: WKWebsiteDataStore, site: String? = nil) {
        CertificateExceptions.forget(in: store, site: site)
        StrictTransport.forget(in: store, site: site)
    }
}
