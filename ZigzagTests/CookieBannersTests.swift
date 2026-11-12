import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Cookie banners (#175): the setting and each site's choice, what Zigzag answers Autoconsent (its rules for each frame,
/// as its own filterCompactRules picks them, what to do, the page's snippets), what a page's controls hear, and pages
/// with a consent pop-up answered with no, or left alone.
@MainActor
@Suite(.serialized)
struct CookieBannersTests {
    private func withDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
        let name = "CookieBannersTests-\(UUID().uuidString)"
        let saved = CookieBanners.defaults
        CookieBanners.defaults = UserDefaults(suiteName: name)!
        defer {
            CookieBanners.defaults.removePersistentDomain(forName: name)
            CookieBanners.defaults = saved
        }
        return try await body()
    }

    // MARK: Setting and site choices

    @Test func rejectsUntilToldOtherwise() async {
        await withDefaults {
            #expect(CookieBanners.mode == .reject)
            #expect(CookieBanners.handles(URL(string: "https://www.spiegel.de/")))
            CookieBanners.mode = .leave
            #expect(!CookieBanners.handles(URL(string: "https://www.spiegel.de/")))
        }
    }

    @Test func siteChoiceComesFirst() {
        #expect(CookieBanners.handles(mode: .reject, site: nil))
        #expect(!CookieBanners.handles(mode: .leave, site: nil))
        #expect(!CookieBanners.handles(mode: .reject, site: false))
        #expect(CookieBanners.handles(mode: .leave, site: true))
    }

    @Test func aSiteChoiceCoversSubdomainsAndIsntKeptWhenItsTheSettings() async {
        await withDefaults {
            let site = URL(string: "https://www.example.com/page")
            CookieBanners.setChoice(false, for: site)
            #expect(CookieBanners.sitesLeft == ["example.com"])
            #expect(CookieBanners.choice(for: URL(string: "https://news.example.com/")) == false)
            #expect(!CookieBanners.handles(URL(string: "https://news.example.com/")))
            #expect(CookieBanners.handles(URL(string: "https://example.org/")))
            // The same as the setting: the site just follows it.
            CookieBanners.setChoice(true, for: site)
            #expect(CookieBanners.sitesLeft.isEmpty && CookieBanners.sitesHandled.isEmpty)
            CookieBanners.mode = .leave
            CookieBanners.setChoice(true, for: site)
            #expect(CookieBanners.sitesHandled == ["example.com"])
            #expect(CookieBanners.handles(site))
            CookieBanners.setChoice(nil, for: site)
            #expect(CookieBanners.choice(for: site) == nil)
            CookieBanners.setChoice(true, for: site)
            CookieBanners.forgetAll()
            #expect(CookieBanners.sitesHandled.isEmpty)
        }
    }

    @Test func onlyWebPages() {
        #expect(CookieBanners.applies(to: URL(string: "https://example.com")))
        #expect(CookieBanners.applies(to: URL(string: "http://example.com")))
        #expect(!CookieBanners.applies(to: URL(string: "zigzag://history")))
        #expect(!CookieBanners.applies(to: URL(string: "webkit-extension://abc/popup.html")))
        #expect(!CookieBanners.applies(to: URL(string: "file:///tmp/a.html")))
        #expect(!CookieBanners.applies(to: nil))
    }

    // MARK: Answering Autoconsent

    @Test func toldToSayNoOrOnlyToLook() throws {
        let handled = CookieBanners.config(handles: true)
        #expect(handled["autoAction"] as? String == "optOut")
        #expect(handled["enablePrehide"] as? Bool == true)
        let left = CookieBanners.config(handles: false)
        #expect(left["autoAction"] is NSNull)
        #expect(left["enablePrehide"] as? Bool == false)
        for config in [handled, left] {
            // Never yes: no heuristics (which can accept), only rules; hiding only by rules that say it's safe.
            #expect(config["heuristicMode"] as? String == "off")
            #expect(config["enableHeuristicDetection"] as? Bool == false)
            #expect(config["enableCosmeticRules"] as? Bool == true)
            #expect(config["enabled"] as? Bool == true)
        }
    }

    @Test func initResponseIsAutoconsentsMessage() throws {
        let rules = try #require(CookieBanners.Rules.shared)
        let reply = CookieBanners.initResponse(config: CookieBanners.json(CookieBanners.config(handles: true)),
                                               rules: rules.json(url: "https://example.com/", mainFrame: true))
        let message = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(message["type"] as? String == "initResp")
        #expect((message["config"] as? [String: Any])?["autoAction"] as? String == "optOut")
        let bundle = try #require(message["rules"] as? [String: Any])
        #expect((bundle["autoconsent"] as? [Any])?.isEmpty == true)
        let compact = try #require(bundle["compact"] as? [String: Any])
        #expect(compact["v"] as? Int == 1)
        #expect((compact["r"] as? [Any])?.isEmpty == false)
    }

    @Test func evalAnswers() throws {
        let reply = CookieBanners.evalResponse(id: "a\"b", result: true)
        let message = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(message["type"] as? String == "evalResp")
        #expect(message["id"] as? String == "a\"b")
        #expect(message["result"] as? Bool == true)
    }

    @Test func onlyTheRulesOwnSnippetsRun() {
        #expect(CookieBanners.isSnippet("EVAL_COOKIEBOT_1"))
        #expect(CookieBanners.isSnippet("EVAL_DIDOMI_OPT_OUT"))
        #expect(!CookieBanners.isSnippet(nil))
        #expect(!CookieBanners.isSnippet(""))
        #expect(!CookieBanners.isSnippet("alert(1)"))
        #expect(!CookieBanners.isSnippet("EVAL_x"))
        #expect(!CookieBanners.isSnippet("EVAL_A; fetch()"))
    }

    @Test func whatAMessageMeansForThePage() {
        #expect(CookieBanners.outcome(of: ["type": "popupFound", "cmp": "Onetrust"]) == .found)
        #expect(CookieBanners.outcome(of: ["type": "autoconsentDone", "isCosmetic": false]) == .rejected)
        #expect(CookieBanners.outcome(of: ["type": "autoconsentDone", "isCosmetic": true]) == .hidden)
        #expect(CookieBanners.outcome(of: ["type": "optOutResult", "result": false]) == nil)
        #expect(CookieBanners.outcome(of: ["type": "cmpDetected"]) == nil)
        #expect(CookieBanners.outcome(of: [:]) == nil)
    }

    @Test func theSiteComesFromThePage() {
        let page = URL(string: "https://www.spiegel.de/")
        #expect(CookieBanners.topURL(frameURL: "https://www.spiegel.de/a", isMainFrame: true, webViewURL: page)?.absoluteString == "https://www.spiegel.de/a")
        // A consent platform's own frame belongs to the page it's in.
        #expect(CookieBanners.topURL(frameURL: "https://cdn.privacy-mgmt.com/x", isMainFrame: false, webViewURL: page) == page)
    }

    @Test func aPageKeepsWhatWasDoneOnItsSite() {
        let webView = WKWebView()
        #expect(CookieBanners.outcome(in: webView, site: "example.com") == nil)
        CookieBanners.note(.found, in: webView, site: "example.com")
        #expect(CookieBanners.outcome(in: webView, site: "example.com") == .found)
        CookieBanners.note(.rejected, in: webView, site: "example.com")
        // Found again in another frame: still answered.
        CookieBanners.note(.found, in: webView, site: "example.com")
        #expect(CookieBanners.outcome(in: webView, site: "example.com") == .rejected)
        #expect(CookieBanners.outcome(in: webView, site: "example.org") == nil)
        // Another site: what was found there only.
        CookieBanners.note(.found, in: webView, site: "example.org")
        #expect(CookieBanners.outcome(in: webView, site: "example.org") == .found)
        #expect(CookieBanners.outcome(in: webView, site: "example.com") == nil)
        CookieBanners.forget(in: webView)
        #expect(CookieBanners.outcome(in: webView, site: "example.org") == nil)
        #expect(CookieBanners.outcome(in: nil, site: "example.org") == nil)
    }

    // MARK: Rules

    @Test func bundledRulesAreRead() throws {
        let rules = try #require(CookieBanners.Rules.shared)
        #expect(rules.version == 1)
        #expect(rules.rules.count > 500)
        #expect(!rules.generic.isEmpty && !rules.specific.isEmpty && !rules.frames.isEmpty)
        // Every site's address pattern reads as a pattern here, as in JavaScript.
        let unread = rules.hasPattern.indices.filter { rules.hasPattern[$0] && rules.patterns[$0] == nil }
        #expect(unread.isEmpty, "\(unread.map { rules.rules[$0].prefix(80) })")
    }

    private func names(_ json: String) throws -> [String] {
        let set = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return (set["r"] as? [[Any]] ?? []).compactMap { $0[1] as? String }
    }

    @Test func thePageGetsGenericRulesAndItsSitesOwn() throws {
        let rules = try #require(CookieBanners.Rules.shared)
        // A site no rule names: the generic rules, as they're kept.
        let plain = rules.json(url: "https://nothing-here-\(UUID().uuidString.prefix(6)).test/", mainFrame: true)
        #expect(plain == rules.genericJSON)
        let generic = try names(plain)
        #expect(generic.count == rules.generic.count)
        // (The big platforms' rules, OneTrust's and Cookiebot's, are code in the script itself, not here.)
        #expect(generic.contains("123inkt"))
        // A site with a rule of its own: that too, after the generic ones.
        let specific = try #require(rules.specific.first { i in
            rules.runContexts[i] != 1 && rules.patterns[i] != nil && rules.patterns[i]!.pattern.hasPrefix("^https?://(www\\.)?")
        })
        let set = try #require(try JSONSerialization.jsonObject(with: Data(rules.rules[specific].utf8)) as? [Any])
        let name = try #require(set[1] as? String)
        let host = try #require(Self.host(of: rules.patterns[specific]!.pattern))
        let named = try names(rules.json(url: "https://www.\(host)/", mainFrame: true))
        #expect(named.contains(name))
        #expect(Array(named.prefix(generic.count)) == generic)
        #expect(!generic.contains(name))
    }

    /// "^https?://(www\.)?example\.com/" → "example.com".
    private static func host(of pattern: String) -> String? {
        var rest = Substring(pattern.dropFirst("^https?://(www\\.)?".count))
        var host = ""
        while let c = rest.first {
            if c == "\\", rest.count > 1 { host.append(rest.dropFirst().first!); rest = rest.dropFirst(2); continue }
            if c == "/" || c == "|" || c == "(" || c == "$" { break }
            host.append(c)
            rest = rest.dropFirst()
        }
        return host.isEmpty ? nil : host
    }

    @Test func aFrameGetsOnlyRulesThatRunInFrames() throws {
        let rules = try #require(CookieBanners.Rules.shared)
        let json = rules.json(url: "https://cdn.privacy-mgmt.com/index.html", mainFrame: false)
        let named = try names(json)
        #expect(!named.isEmpty)
        let inFrames = Set(rules.frames.compactMap { i -> String? in
            (try? JSONSerialization.jsonObject(with: Data(rules.rules[i].utf8)) as? [Any])?[1] as? String
        })
        #expect(Set(named).isSubset(of: inFrames))
        // None that says it runs only in the page itself.
        for i in rules.frames where [10, 12, 20, 22].contains(rules.runContexts[i]) {
            #expect(!rules.runs(i, url: "https://cdn.privacy-mgmt.com/index.html", mainFrame: false))
        }
    }

    @Test func aFrameGetsOnlyTheStringsItsRulesUse() throws {
        let rules = try #require(CookieBanners.Rules.shared)
        let json = rules.json(url: "https://cdn.privacy-mgmt.com/index.html", mainFrame: false)
        let set = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let strings = try #require(set["s"] as? [String])
        let chosen = try #require(set["r"] as? [[Any]])
        // Every string a chosen rule names is there, as it was.
        for rule in chosen {
            for i in CookieBanners.Rules.stringsUsed(by: rule) {
                #expect(i < strings.count && strings[i] == rules.strings[i])
            }
        }
        // And the others are left empty: a frame isn't sent the page's thousands.
        #expect(strings.filter { !$0.isEmpty }.count < rules.strings.count / 4)
        // The same frame again: the same answer.
        #expect(rules.json(url: "https://cdn.privacy-mgmt.com/index.html", mainFrame: false) == json)
    }

    @Test func stepsNameTheirStringsAtAnyDepth() {
        let rule: [Any] = [1, "x", 2, "", 22, [7],
                           [["e": 1]], [["if": ["v": 2], "then": [["c": 3]], "else": [["any": [["k": 4], ["wv": 5]]]]]],
                           [["h": 6, "cc": 8, "w": 9]], [], [:]]
        #expect(CookieBanners.Rules.stringsUsed(by: rule) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    @Test func aRuleOnlyForFramesSkipsThePage() throws {
        let rules = try #require(CookieBanners.Rules.shared)
        if let i = rules.runContexts.firstIndex(of: 1) {
            #expect(!rules.runs(i, url: "https://example.com/", mainFrame: true))
        }
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// A pop-up as one of Autoconsent's rules (123inkt) knows it: refusing it notes that it was refused.
    private static let popup = """
    <!doctype html><html><body style="height: 3000px">
    <p>Page</p>
    <div class="c-cookie-popup" style="position: fixed; bottom: 0; left: 0; right: 0; height: 120px; background: #eee">
      <button data-role="accept-cookies" onclick="document.body.dataset.answer = 'accepted'; this.parentNode.remove()">Accept</button>
      <button data-role="refuse-cookies" onclick="document.body.dataset.answer = 'refused'; this.parentNode.remove()">Refuse</button>
    </div>
    </body></html>
    """

    private func page(_ html: String, at origin: String) async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        CookieBanners.attach(to: configuration.userContentController)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: origin + "/"))
        }
        return webView
    }

    private func until(_ seconds: Double = 10, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }

    private func answer(_ webView: WKWebView) async throws -> String? {
        try await webView.callAsyncJavaScript("return document.body.dataset.answer || null", arguments: [:], in: nil, contentWorld: .page) as? String
    }

    @Test func aPopUpIsRefused() async throws {
        try await withDefaults {
            let site = "consent-\(UUID().uuidString.prefix(8).lowercased()).test"
            let webView = await page(Self.popup, at: "https://\(site)")
            #expect(try await until { try await answer(webView) != nil })
            #expect(try await answer(webView) == "refused")
            #expect(await until { CookieBanners.outcome(in: webView, site: site) == .rejected })
            // Autoconsent's own world, not the page's: the page sees none of it.
            let seen = try await webView.callAsyncJavaScript("return typeof window.autoconsentSendMessage", arguments: [:], in: nil, contentWorld: .page) as? String
            #expect(seen == "undefined")
        }
    }

    @Test func leftAloneItsOnlyFound() async throws {
        try await withDefaults {
            CookieBanners.mode = .leave
            let site = "consent-\(UUID().uuidString.prefix(8).lowercased()).test"
            let webView = await page(Self.popup, at: "https://\(site)")
            #expect(await until { CookieBanners.outcome(in: webView, site: site) == .found })
            try? await Task.sleep(for: .milliseconds(500))
            let answered = try await answer(webView)
            #expect(answered == nil)
        }
    }

    @Test func aSitesChoiceIsFollowed() async throws {
        try await withDefaults {
            let site = "consent-\(UUID().uuidString.prefix(8).lowercased()).test"
            CookieBanners.setChoice(false, for: URL(string: "https://\(site)/"))
            let webView = await page(Self.popup, at: "https://\(site)")
            #expect(await until { CookieBanners.outcome(in: webView, site: site) == .found })
            try? await Task.sleep(for: .milliseconds(500))
            let answered = try await answer(webView)
            #expect(answered == nil)
        }
    }
}
