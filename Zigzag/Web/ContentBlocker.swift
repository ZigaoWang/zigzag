import WebKit

/// Blocks well-known ad and tracking services when they're loaded by another site. Only third-party requests
/// are blocked, so a site's own pages and sign-ins keep working. Built in, always on, nothing to set.
enum ContentBlocker {
    private(set) static var ruleList: WKContentRuleList?

    /// Ad networks and cross-site trackers. Kept short and well known on purpose: nothing that sites
    /// commonly depend on to work (no CDNs, no sign-in providers, no payment or captcha services).
    static let domains = [
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

    static var rulesJSON: String {
        let rules = domains.map { domain -> String in
            let parts = domain.split(separator: "/", maxSplits: 1)
            let host = String(parts[0]).replacingOccurrences(of: ".", with: "\\\\.")
            let path = parts.count > 1 ? "/" + parts[1] : "[/:?]"
            return #"{"trigger":{"url-filter":"^https?://([^/]+\\.)?\#(host)\#(path)","load-type":["third-party"]},"action":{"type":"block"}}"#
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    /// Compiles once per launch (WebKit caches the result) and attaches to every web view.
    static func prepare() {
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "zigzag-trackers-1", encodedContentRuleList: rulesJSON) { list, error in
            MainActor.assumeIsolated {
                guard let list else {
                    if let error { debugLog("Content blocker failed to compile: \(error)") }
                    return
                }
                ruleList = list
                for controller in WindowManager.shared.controllers {
                    for tab in controller.tabManager.allTabs {
                        tab.webView?.configuration.userContentController.add(list)
                    }
                }
            }
        }
    }

    static func attach(to configuration: WKWebViewConfiguration) {
        guard let ruleList else { return }
        configuration.userContentController.add(ruleList)
    }
}
