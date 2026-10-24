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

    /// Clears `kind` for a site ("youtube.com", covering its subdomains), or for every site when `site` is nil.
    static func clear(_ kind: Kind, site: String? = nil) async {
        let store = WKWebsiteDataStore.default()
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
}
