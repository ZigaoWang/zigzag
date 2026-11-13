#if DEBUG
import AppKit
import WebKit

/// Debug builds only: fills a test copy's profile with made-up sites, and times Settings' list of what websites
/// keep (#207). Nothing is visited: each site is a cookie set straight in the store, on a reserved name
/// (`.example`), so the list has thousands of sites without a page loading.
enum SiteDataBench {
    /// sitedata seed <count>: that many sites, a few of them with a second subdomain, each with a cookie.
    static func seed(_ count: Int, in store: WKWebsiteDataStore) async {
        let cookies = store.httpCookieStore
        let words = ["maple", "harbor", "copper", "lantern", "meadow", "pixel", "summit", "willow", "orbit", "cedar"]
        for i in 0..<count {
            let site = "\(words[i % words.count])-\(String(format: "%04d", i)).example"
            let hosts = i % 7 == 0 ? [site, "shop." + site] : [site]
            for host in hosts {
                guard let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: "zz\(i)", .value: "1",
                                                           .expires: Date().addingTimeInterval(86_400 * 30)]) else { continue }
                await cookies.setCookie(cookie)
            }
        }
        debugLog("sitedata seeded \(count)")
    }

    /// sitedata storage <count>: that many more made-up sites keeping local storage of different sizes, so the list
    /// has sizes to show. Each is a page written here and given the site's address as its base: nothing is fetched.
    static func seedStorage(_ count: Int, in store: WKWebsiteDataStore) async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        for i in 0..<count {
            let kilobytes = (i + 1) * 40
            let html = "<script>localStorage.setItem('zz', 'x'.repeat(\(kilobytes * 512)))</script>"
            webView.loadHTMLString(html, baseURL: URL(string: "https://storage-\(String(format: "%02d", i)).example/"))
            try? await Task.sleep(for: .milliseconds(400))
        }
        debugLog("sitedata storage seeded \(count)")
    }

    /// sitedata bench <path>: Show All timed from the click to the frame that shows it, the longest the main thread
    /// went without a turn meanwhile, then the page scrolled through the list a step a frame, each step's work timed
    /// (scroll, layout, drawing and the layer commit), as JSON.
    static func run(_ settings: SettingsView, to path: String) async {
        var result: [String: Any] = [:]
        // The list read, before anything is timed.
        var waited = 0
        while !settings.debugSiteDataReady, waited < 600 { try? await Task.sleep(for: .milliseconds(50)); waited += 1 }
        result["sites"] = settings.debugSiteDataCount
        guard let window = settings.window, let scroll = settings.debugScroll, let document = scroll.documentView else {
            debugLog("sitedata bench: no Settings"); return
        }
        document.scroll(NSPoint(x: 0, y: max(0, settings.debugSiteDataTop - 200)))
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))

        // The main thread's longest wait between turns, from a timer that wants one every millisecond.
        var last = CFAbsoluteTimeGetCurrent(), longest = 0.0
        let watch = Timer(timeInterval: 0.001, repeats: true) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            longest = max(longest, now - last)
            last = now
        }
        RunLoop.main.add(watch, forMode: .common)
        let start = CFAbsoluteTimeGetCurrent()
        settings.debugSiteDataShowAll()
        while !settings.debugSiteDataExpanded, CFAbsoluteTimeGetCurrent() - start < 30 { try? await Task.sleep(for: .milliseconds(1)) }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let shown = CFAbsoluteTimeGetCurrent() - start
        try? await Task.sleep(for: .milliseconds(100))
        watch.invalidate()
        result["showAllMs"] = round(shown * 10_000) / 10
        result["longestStallMs"] = round(longest * 10_000) / 10

        // Through the list, 24pt a step, as a quick two-finger scroll moves at 120 frames a second.
        let top = settings.debugSiteDataTop, height = settings.debugSiteDataHeight
        var y = max(0, top - 200)
        let end = min(document.frame.height - scroll.contentSize.height, top + height)
        var steps: [Double] = []
        while y < end, steps.count < 4000 {
            y = min(end, y + 24)
            let t = CFAbsoluteTimeGetCurrent()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            steps.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            if steps.count % 8 == 0 { await Task.yield() }
        }
        let sorted = steps.sorted()
        func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : round(sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 100) / 100 }
        result["scrollSteps"] = steps.count
        result["scrollP50Ms"] = percentile(0.5)
        result["scrollP95Ms"] = percentile(0.95)
        result["scrollMaxMs"] = round((sorted.last ?? 0) * 100) / 100
        // Steps that wouldn't fit in a frame at 120 Hz.
        result["scrollOver8ms"] = steps.filter { $0 > 1000.0 / 120 }.count
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        debugLog("sitedata bench \(result)")
    }
}
#endif
