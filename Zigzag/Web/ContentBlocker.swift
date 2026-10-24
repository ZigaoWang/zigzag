import WebKit

/// Built-in ad and tracker blocking: EasyList and EasyPrivacy, converted to WebKit's own content-blocker
/// rules when the app is built (scripts/update_blocklists.sh) and matched natively as pages load, with no
/// extension and no JavaScript per request. On by default; can be turned off for everything, or allowed on a site.
enum ContentBlocker {
    /// The bundled lists, compiled. Nil until the first compile finishes (once per list version).
    private(set) static var ruleList: WKContentRuleList?
    /// A short list of well-known ad and tracking services, used until the full lists are ready.
    private(set) static var fallbackList: WKContentRuleList?
    /// Fires when the lists or the settings change, so open tabs can pick it up.
    static let changed = Signal<Void>()

    private static let enabledKey = "BlockAdsAndTrackers"
    private static let allowedKey = "AdsAllowedSites"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey); changed.send() }
    }

    /// Sites where the person chose to allow ads, by host without "www.".
    static var allowedSites: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: allowedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: allowedKey); changed.send() }
    }

    static func site(of url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func isAllowed(on url: URL?) -> Bool {
        guard let site = site(of: url) else { return false }
        let allowed = allowedSites
        // Allowing a site covers its subdomains too.
        return allowed.contains { site == $0 || site.hasSuffix("." + $0) }
    }

    static func setAllowed(_ allowed: Bool, on url: URL?) {
        guard let site = site(of: url) else { return }
        var sites = allowedSites
        if allowed { sites.insert(site) } else { sites = sites.filter { !(site == $0 || site.hasSuffix("." + $0)) } }
        allowedSites = sites
    }

    // MARK: Compiling

    private static let identifierPrefix = "zigzag-blocklist-"

    /// Looks up the compiled lists, compiling the bundled ones if this version hasn't been compiled yet.
    static func prepare() {
        let store = WKContentRuleListStore.default()!
        store.compileContentRuleList(forIdentifier: "zigzag-trackers-1", encodedContentRuleList: fallbackJSON) { list, _ in
            MainActor.assumeIsolated {
                fallbackList = list
                if ruleList == nil { changed.send() }
            }
        }
        guard let info = Bundle.main.url(forResource: "blocklist.info", withExtension: "json"),
              let infoData = try? Data(contentsOf: info) else { return }
        // The identifier carries the list version, so an app update with new lists compiles them once.
        let identifier = identifierPrefix + String(infoData.hashValueStable, radix: 36)
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            MainActor.assumeIsolated {
                if let list {
                    ruleList = list
                    changed.send()
                } else {
                    compileBundled(identifier: identifier)
                }
            }
        }
    }

    private static func compileBundled(identifier: String) {
        guard let url = Bundle.main.url(forResource: "blocklist.json", withExtension: "lzfse"),
              let compressed = try? Data(contentsOf: url) else { return }
        Task.detached(priority: .utility) {
            guard let json = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
                  let rules = String(data: json, encoding: .utf8) else { return }
            await MainActor.run {
                let store = WKContentRuleListStore.default()!
                store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, _ in
                    MainActor.assumeIsolated {
                        guard let list else { return }
                        ruleList = list
                        changed.send()
                        removeOldVersions(keeping: identifier)
                    }
                }
            }
        }
    }

    private static func removeOldVersions(keeping current: String) {
        let store = WKContentRuleListStore.default()!
        store.getAvailableContentRuleListIdentifiers { identifiers in
            MainActor.assumeIsolated {
                for id in identifiers ?? [] where id.hasPrefix(identifierPrefix) && id != current {
                    store.removeContentRuleList(forIdentifier: id) { _ in }
                }
            }
        }
    }

    // MARK: Applying

    /// The list a page should be blocked with right now, if any.
    static var activeList: WKContentRuleList? { ruleList ?? fallbackList }

    static func attach(to configuration: WKWebViewConfiguration) {
        guard isEnabled, let list = activeList else { return }
        configuration.userContentController.add(list)
    }

    /// Puts the right list on a page's web view for where it's going: none if blocking is off or the site
    /// is allowed, otherwise the full list (or the short one until the full one is ready).
    static func apply(to webView: WKWebView, for url: URL?) {
        let controller = webView.configuration.userContentController
        let wanted = isEnabled && !isAllowed(on: url) ? activeList : nil
        for list in [ruleList, fallbackList].compactMap({ $0 }) where list !== wanted {
            controller.remove(list)
        }
        if let wanted { controller.add(wanted) }
    }

    // MARK: Fallback

    /// Ad networks and cross-site trackers. Kept short and well known on purpose: nothing that sites
    /// commonly depend on to work (no CDNs, no sign-in providers, no payment or captcha services).
    private static let fallbackDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com", "adservice.google.com",
        "googletagservices.com", "2mdn.net", "adnxs.com", "adsrvr.org", "advertising.com", "amazon-adsystem.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "scorecardresearch.com", "quantserve.com",
        "quantcount.com", "moatads.com", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com",
        "bidswitch.net", "smartadserver.com", "teads.tv", "yieldmo.com", "sharethrough.com", "33across.com",
        "media.net", "contextweb.com", "lijit.com", "sovrn.com", "indexww.com", "adform.net", "serving-sys.com",
        "zedo.com", "revcontent.com", "mgid.com", "zemanta.com", "hotjar.com", "mouseflow.com", "fullstory.com",
        "crazyegg.com", "luckyorange.com", "clarity.ms", "mixpanel.com", "amplitude.com", "segment.io",
        "segment.com", "heap.io", "heapanalytics.com", "kissmetrics.com", "chartbeat.com", "chartbeat.net",
        "newrelic.com", "nr-data.net", "bluekai.com", "krxd.net", "exelator.com", "demdex.net", "everesttech.net",
        "omtrdc.net", "2o7.net", "adsymptotic.com", "tapad.com", "agkn.com", "rlcdn.com", "liadm.com",
        "pippio.com", "addthis.com", "sharethis.com", "branch.io", "app-measurement.com", "bat.bing.com",
        "ads-twitter.com", "ads.linkedin.com", "analytics.tiktok.com", "ads.yahoo.com", "adroll.com",
        "perfectaudience.com", "steelhousemedia.com", "yandex.ru/metrika", "mc.yandex.ru", "top-fwz1.mail.ru",
    ]

    private static var fallbackJSON: String {
        let rules = fallbackDomains.map { domain -> String in
            let parts = domain.split(separator: "/", maxSplits: 1)
            let host = String(parts[0]).replacingOccurrences(of: ".", with: "\\\\.")
            let path = parts.count > 1 ? "/" + parts[1] : "[/:?]"
            return #"{"trigger":{"url-filter":"^https?://([^/]+\\.)?\#(host)\#(path)","load-type":["third-party"]},"action":{"type":"block"}}"#
        }
        return "[" + rules.joined(separator: ",") + "]"
    }
}

private extension Data {
    /// FNV-1a: stable across launches, unlike `hashValue`.
    var hashValueStable: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in self { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
}
