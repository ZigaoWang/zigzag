import WebKit

/// Built-in ad and tracker blocking: EasyList, EasyPrivacy and EasyList China, converted to WebKit's own content-blocker
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
        // The small built-in list, until the full one is ready: compiled once per version, then looked up. Compiling
        // it on every launch held the main thread for a few hundred milliseconds as Zigzag started (#89).
        let fallbackID = "zigzag-trackers-" + String(Data(fallbackJSON.utf8).hashValueStable, radix: 36)
        let useFallback: @MainActor (WKContentRuleList?) -> Void = { list in
            fallbackList = list
            if ruleList == nil, list != nil { changed.send() }
        }
        store.lookUpContentRuleList(forIdentifier: fallbackID) { list, _ in
            MainActor.assumeIsolated {
                if let list { useFallback(list); return }
                store.compileContentRuleList(forIdentifier: fallbackID, encodedContentRuleList: fallbackJSON) { list, _ in
                    MainActor.assumeIsolated {
                        useFallback(list)
                        // Earlier versions' copies of it (and the one every launch used to rewrite) go.
                        removeOld(withPrefix: "zigzag-trackers-", keeping: fallbackID)
                    }
                }
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
        removeOld(withPrefix: identifierPrefix, keeping: current)
    }

    private static func removeOld(withPrefix prefix: String, keeping current: String) {
        let store = WKContentRuleListStore.default()!
        store.getAvailableContentRuleListIdentifiers { identifiers in
            MainActor.assumeIsolated {
                for id in identifiers ?? [] where id.hasPrefix(prefix) && id != current {
                    store.removeContentRuleList(forIdentifier: id) { _ in }
                }
            }
        }
    }

    // MARK: Applying

    /// The list a page should be blocked with right now, if any.
    static var activeList: WKContentRuleList? { ruleList ?? fallbackList }

    // MARK: YouTube

    /// YouTube serves its video ads from its own servers, where no blocklist reaches: a script in its pages takes
    /// them out instead (Resources/YouTubeAds.js), asking first whether ad blocking is on for the page.
    static let youTubeScript: WKUserScript = {
        let source = Bundle.main.url(forResource: "YouTubeAds", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }()

    static func attachYouTube(to configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(youTubeScript)
        configuration.userContentController.addScriptMessageHandler(YouTubeAnswer.shared, contentWorld: .page, name: "zigzagAds")
    }

    /// The ad blocker extension that handles YouTube for this web view's pages, if one does. Private windows run no
    /// extensions, so there it's always Zigzag.
    static func youTubeBlocker(for webView: WKWebView) -> String? {
        let configuration = webView.configuration
        if #available(macOS 15.4, *), configuration.webExtensionController == nil { return nil }
        let store = configuration.websiteDataStore
        guard let profile = Profiles.shared.opened.first(where: { $0.storeIfMade === store }) else { return nil }
        return AdBlockers.active(in: profile)
    }

    /// Takes Zigzag's YouTube script out of a web view while an ad blocker extension handles YouTube there, so two
    /// blockers never change the same responses, and puts it back once none does. Pages see it from their next load.
    static func applyYouTube(to webView: WKWebView) {
        setYouTube(youTubeBlocker(for: webView) == nil, in: webView.configuration.userContentController)
    }

    /// Puts Zigzag's YouTube script into a set of page scripts, or takes it out, leaving the others as they were.
    static func setYouTube(_ wanted: Bool, in controller: WKUserContentController) {
        let scripts = controller.userScripts
        let has = scripts.contains { $0 === youTubeScript }
        guard has != wanted else { return }
        if wanted {
            controller.addUserScript(youTubeScript)
        } else {
            // Picked out before they're removed: the list WebKit hands over is its own, and empties with them.
            let others = scripts.filter { $0 !== youTubeScript }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
        }
    }

    /// Answers whether ads are blocked on the page asking (the tab's own site decides, as for the blocklist), and
    /// not while an ad blocker extension handles YouTube there.
    private final class YouTubeAnswer: NSObject, WKScriptMessageHandlerWithReply {
        static let shared = YouTubeAnswer()
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            let page = message.webView?.url ?? message.frameInfo.request.url
            let extensionBlocks = message.webView.map { ContentBlocker.youTubeBlocker(for: $0) != nil } ?? false
            return (ContentBlocker.isEnabled && !ContentBlocker.isAllowed(on: page) && !extensionBlocks, nil)
        }
    }

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
        applyYouTube(to: webView)
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

/// Ad blocker extensions. Where one is installed and on, and may run on YouTube, it blocks ads there and Zigzag's own
/// YouTube script steps aside: in that profile, since each profile has its own extensions. Zigzag's blocklists stay
/// on beside it, as browsers' built-in blockers do beside one: both only stop what their lists name, and a site you
/// allow ads on in Zigzag is still allowed in Zigzag's lists.
enum AdBlockers {
    /// Each by the ID the Chrome Web Store gives it, with the name people know it by.
    static let known: [String: String] = [
        "ddkjiahejlhfcafbddmgiahcphecmpfh": "uBlock Origin Lite",
        "cjpalhdlnbpafiamejdnhcphjbkeiagm": "uBlock Origin",
        "bgnkhhnnamicmpeenaelnjfhikgbkllg": "AdGuard",
        "gighmmpiobklfepjocnamgkkbiglidom": "AdBlock",
        "cfhdojbkjhnklbpkdaibdccddilifddb": "Adblock Plus",
        "mlomiejdfkolichcflejclcbmpeaniij": "Ghostery",
    ]

    /// The ad blocker installed, on and allowed on YouTube in a profile, by name. Read from what the profile has
    /// installed, not from what's running, as for password managers: pages restored at launch already get it right.
    static func active(in profile: Profile) -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        let installs = profile.installs
        let offSites = ExtensionStore.extensionsOffSites
        return active(among: known.keys.filter { id in
            guard installs.isEnabled(id), installs.isInstalled(id) else { return false }
            return reachesYouTube(access: installs.siteAccess(id), approved: installs.state(id)?.grantedMatchPatterns,
                                  sites: installs.accessSites(id), offSites: offSites)
        })
    }

    /// With several on, the first by name, so the answer doesn't change from one time to the next.
    static func active(among ids: [String]) -> String? { ids.compactMap { known[$0] }.sorted().first }

    /// Whether an extension may run on YouTube as its site access stands: everywhere it was approved for (nil until
    /// its first load records that, when it gets all it asks for), or only the sites listed or clicked on. A site
    /// where extensions are off is off for it too.
    static func reachesYouTube(access: ExtensionInstalls.SiteAccess, approved: [String]?, sites: [String], offSites: Set<String>) -> Bool {
        let youTube: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com"]
        if !offSites.isDisjoint(with: youTube) { return false }
        switch access {
        case .all: return approved.map { $0.contains(where: coversYouTube) } ?? true
        case .click, .sites: return !youTube.isDisjoint(with: sites)
        }
    }

    /// Whether a match pattern ("<all_urls>", "*://*/*", "https://*.youtube.com/*") takes in YouTube's pages.
    static func coversYouTube(_ pattern: String) -> Bool {
        if pattern == "<all_urls>" { return true }
        guard let schemeEnd = pattern.range(of: "://") else { return false }
        let scheme = pattern[..<schemeEnd.lowerBound]
        guard scheme == "*" || scheme == "https" else { return false }
        let host = pattern[schemeEnd.upperBound...].prefix { $0 != "/" }
        return host == "*" || host == "*.youtube.com" || host == "www.youtube.com"
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
