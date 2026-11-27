import AppKit
import Testing
import WebKit
@testable import Zigzag

/// Developer tools (#141): JavaScript, images, styles, user agent, outlines, other browsers.
@MainActor
@Suite(.serialized)
struct DeveloperMoreTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "DeveloperMoreTests-\(UUID().uuidString)"
        let saved = DeveloperTools.defaults
        DeveloperTools.defaults = UserDefaults(suiteName: name)!
        defer {
            DeveloperTools.defaults.removeScratchSuite(name)
            DeveloperTools.defaults = saved
            DeveloperTools.changed.send()
        }
        try body()
    }

    private func withDefaultsAsync(_ body: () async throws -> Void) async rethrows {
        let name = "DeveloperMoreTests-\(UUID().uuidString)"
        let saved = DeveloperTools.defaults
        DeveloperTools.defaults = UserDefaults(suiteName: name)!
        defer {
            DeveloperTools.defaults.removeScratchSuite(name)
            DeveloperTools.defaults = saved
            DeveloperTools.changed.send()
            PageImages.sitesChanged()
        }
        PageImages.sitesChanged()
        try await body()
    }

    /// Serves a one-pixel PNG for any URL.
    private final class OnePixel: NSObject, WKURLSchemeHandler {
        static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "image/png", expectedContentLength: Self.png.count, textEncodingName: nil))
            task.didReceive(Self.png)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    @Test func onlyWhatAPageIsToldAsItLoadsNeedsItToLoadAgain() {
        let plain = DeveloperState()
        var state = plain
        state.outlines = true
        state.appearance = .dark
        state.size = CGSize(width: 393, height: 852)
        state.printStyles = true
        #expect(!state.needsReload(from: plain))
        state.javaScriptOff = true
        #expect(state.needsReload(from: plain))
        var agent = plain
        agent.userAgent = .iPhone
        #expect(agent.needsReload(from: plain))
        #expect(!agent.needsReload(from: agent))
    }

    @Test func imagesTurnedOffShowOnceThePageLoadsAgainAndStylesAtOnce() {
        let plain = DeveloperState()
        var images = plain
        images.imagesOff = true
        // The images rule applies at load, so toggling reloads.
        #expect(images.needsReload(from: plain) && plain.needsReload(from: images))
        var styles = plain
        styles.stylesOff = true
        #expect(!styles.needsReload(from: plain) && !plain.needsReload(from: styles))
    }

    @Test func imagesAndStylesOffAreCheckedWhileSoAndTakePrintStylesAndOutlinesWithThem() {
        var state = DeveloperState()
        #expect(!DeveloperTool.images.isChecked(in: state) && !DeveloperTool.styles.isChecked(in: state))
        #expect(DeveloperTool.printStyles.applies(in: state) && DeveloperTool.outlines.applies(in: state))
        state.imagesOff = true
        #expect(DeveloperTool.images.isChecked(in: state))
        state.stylesOff = true
        #expect(DeveloperTool.styles.isChecked(in: state))
        // Styles off disables print styles and outlines.
        #expect(!DeveloperTool.printStyles.applies(in: state) && !DeveloperTool.outlines.applies(in: state))
        // ⋯ shows both as active.
        #expect(DeveloperTool.hasChoiceInEffect(among: DeveloperBarTools.moreTools, in: state))
    }

    @Test func webKitHasTheStylesSwitchAndKeepsItForTheApp() {
        #expect(PageStyles.isAvailable && DeveloperTool.styles.isAvailable)
        let preferences = WKPreferences()
        #expect(preferences.value(forKey: PageStyles.key) as? Bool == true)
        PageStyles.set(false, in: preferences)
        #expect(preferences.value(forKey: PageStyles.key) as? Bool == false)
        PageStyles.set(true, in: preferences)
        #expect(preferences.value(forKey: PageStyles.key) as? Bool == true)
        // App-owned preference: Feature Flags never lists it.
        #expect(FeatureFlags.flags?.contains { $0.key.lowercased() == PageStyles.key.lowercased() } != true)
        // Unknown preferences are skipped.
        WebKitSetup.setIfAvailable(false, key: "noSuchPreferenceAnywhere", in: WKPreferences())
        #expect(!WebKitSetup.hasPreference("noSuchPreferenceAnywhere"))
    }

    @Test func theImagesRuleIsForTheDevelopmentListsSitesOnly() throws {
        let rules = try #require(PageImages.rules(for: ["localhost", "127.0.0.1", "app.localtest.me"]))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(rules.utf8)) as? [[String: [String: Any]]])
        #expect(json.count == 1)
        #expect(json[0]["trigger"]?["resource-type"] as? [String] == ["image"])
        #expect(json[0]["trigger"]?["if-top-url"] as? [String] == [#"^https?://([^/]*\.)?localhost[:/]"#, #"^https?://([^/]*\.)?127\.0\.0\.1[:/]"#, #"^https?://([^/]*\.)?app\.localtest\.me[:/]"#])
        #expect(PageImages.topURL(for: "::1") == #"^https?://\[::1\][:/]"#)
        #expect(json[0]["action"]?["type"] as? String == "block")
        // Identifier tracks the list content.
        let name = PageImages.identifier(for: rules)
        #expect(name.hasPrefix(PageImages.prefix))
        let same = try #require(PageImages.rules(for: ["localhost", "127.0.0.1", "app.localtest.me"]))
        let other = try #require(PageImages.rules(for: ["localhost"]))
        #expect(name == PageImages.identifier(for: same) && name != PageImages.identifier(for: other))
        // Empty list: no rule (WebKit rejects an empty condition); impossible hosts are dropped.
        #expect(PageImages.rules(for: []) == nil)
        #expect(PageImages.rules(for: ["Bücher.de"]) == nil)
    }

    /// Width of a `zztest:` image on a page at `base` loaded with `rules`; 0 if it didn't load.
    private func imageWidth(at base: String, rules: String) async throws -> Int {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(OnePixel(), forURLScheme: "zztest")
        let store = try #require(WKContentRuleListStore.default())
        let name = "zigzag-test-images-\(UUID().uuidString)"
        let list = try #require(try await store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: rules))
        // Compiled into the app store, removed afterward.
        defer { store.removeContentRuleList(forIdentifier: name) { _ in } }
        configuration.userContentController.add(list)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        webView.loadHTMLString("<img src='zztest://pixel.png' onload='window.settled=1' onerror='window.settled=1'>", baseURL: URL(string: base))
        for _ in 0..<100 {
            let settled = try? await webView.evaluateJavaScript("window.settled === 1") as? Bool
            if settled == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        return try await webView.evaluateJavaScript("document.images[0].naturalWidth") as? Int ?? -1
    }

    /// Test lists in the app's store.
    private func testLists() async -> Set<String> {
        let all = await WKContentRuleListStore.default().availableIdentifiers() ?? []
        return Set(all.filter { $0.hasPrefix("zigzag-test-images-") })
    }

    @Test func webKitBlocksTheImagesOnAListedSitesPagesOnly() async throws {
        let before = await testLists()
        let rules = try #require(PageImages.rules(for: ["localhost", "127.0.0.1", "::1"]))
        #expect(try await imageWidth(at: "http://localhost:3000/", rules: rules) == 0)
        #expect(try await imageWidth(at: "http://app.localhost/", rules: rules) == 0)
        #expect(try await imageWidth(at: "http://127.0.0.1:8080/", rules: rules) == 0)
        #expect(try await imageWidth(at: "http://[::1]:8080/", rules: rules) == 0)
        // Other sites keep their images.
        #expect(try await imageWidth(at: "https://example.com/", rules: rules) == 1)
        #expect(try await imageWidth(at: "https://notlocalhost.com/", rules: rules) == 1)
        // No test lists are left behind.
        for _ in 0..<100 where await !testLists().isSubset(of: before) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await testLists().isSubset(of: before))
    }

    /// Waits until `webView`'s rule state is `on`.
    private func rule(_ on: Bool, in webView: WKWebView) async throws -> Bool {
        for _ in 0..<200 where PageImages.isOn(in: webView) != on { try await Task.sleep(for: .milliseconds(20)) }
        return PageImages.isOn(in: webView) == on
    }

    @Test func theImagesRuleIsOnWhileAPageWantsItAndGoesWithThePagesThatDid() async throws {
        let name = "DeveloperMoreTests-\(UUID().uuidString)"
        let saved = DeveloperTools.defaults
        DeveloperTools.defaults = UserDefaults(suiteName: name)!
        defer {
            DeveloperTools.defaults.removeScratchSuite(name)
            DeveloperTools.defaults = saved
            PageImages.sitesChanged()
        }
        PageImages.sitesChanged()
        // A page and its popup share scripts and rules.
        var page: WKWebView? = WKWebView(frame: .zero)
        let popUp = WKWebView(frame: .zero, configuration: page!.configuration)
        #expect(popUp.configuration.userContentController === page!.configuration.userContentController)
        PageImages.set(true, in: page!)
        #expect(PageImages.isOff(in: page!) && !PageImages.isOff(in: popUp))
        #expect(try await rule(true, in: popUp))
        // Closing the page with images off removes the rule.
        PageImages.set(false, in: page!)
        page = nil
        #expect(try await rule(false, in: popUp))
        // On, then off, in the remaining one.
        PageImages.set(true, in: popUp)
        PageImages.set(true, in: popUp)
        #expect(try await rule(true, in: popUp))
        PageImages.set(false, in: popUp)
        #expect(!PageImages.isOn(in: popUp))
        // A new list replaces the rule.
        PageImages.set(true, in: popUp)
        #expect(try await rule(true, in: popUp))
        DevelopmentSites.add("app.localtest.me")
        PageImages.sitesChanged()
        #expect(!PageImages.isOn(in: popUp))
        #expect(try await rule(true, in: popUp))
        // Empty list: nothing to block.
        DevelopmentSites.sites = []
        PageImages.sitesChanged()
        #expect(!PageImages.isOn(in: popUp))
        PageImages.set(false, in: popUp)
    }

    @Test func aPageWaitingForTheRuleLoadsAgainOnceItIsIn() async throws {
        try await withDefaultsAsync {
            let tab = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            let webView = tab.ensureWebView()
            DevelopmentSites.add("waiting.localtest.me")
            PageImages.sitesChanged()
            // Images off before the new rule compiles: reload waits.
            tab.developer.imagesOff = true
            #expect(PageImages.isOff(in: webView))
            #expect(!PageImages.isOn(in: webView) && PageImages.defersReload(of: webView))
            let ready = try await rule(true, in: webView)
            #expect(ready)
            // Rule ready: reloads immediately.
            #expect(!PageImages.defersReload(of: webView))
            tab.close()
            // A closed tab releases it.
            #expect(!PageImages.isOff(in: webView) && !PageImages.isOn(in: webView))
        }
    }

    @Test func aPageEmptiedOffTheListNoLongerWaitsForTheRule() async throws {
        try await withDefaultsAsync {
            let tab = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            let webView = tab.ensureWebView()
            DevelopmentSites.add("emptied.localtest.me")
            PageImages.sitesChanged()
            // Images off while the rule compiles: the page waits.
            tab.developer.imagesOff = true
            #expect(PageImages.isWaiting(webView))
            // List emptied meanwhile: nothing waits.
            DevelopmentSites.sites = []
            PageImages.sitesChanged()
            #expect(!PageImages.isWaiting(webView))
            // Still nothing after compiling finishes.
            try await Task.sleep(for: .milliseconds(300))
            #expect(!PageImages.isWaiting(webView))
            tab.close()
        }
    }

    @Test func stylesGoWithThePageThatArrivesNotTheAddressOnItsWay() {
        withDefaults {
            let tab = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            let webView = tab.ensureWebView()
            let preferences = webView.configuration.preferences
            tab.developer.stylesOff = true
            tab.developer.printStyles = true
            #expect(preferences.value(forKey: PageStyles.key) as? Bool == false && webView.mediaType == "print")
            // The web view's URL leaves the list: the current page stays as drawn until the next arrives.
            DevelopmentSites.sites = ["127.0.0.1"]
            tab.applyDeveloperState()
            #expect(preferences.value(forKey: PageStyles.key) as? Bool == false && webView.mediaType == "print")
            // The new page, off the list, has styles.
            tab.refreshDevelopment()
            #expect(preferences.value(forKey: PageStyles.key) as? Bool == true && webView.mediaType == nil)
            tab.close()
        }
    }

    @Test func aTabAPageOpenedSharesItsImagesChoice() {
        withDefaults {
            let opener = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            let openerView = opener.ensureWebView()
            opener.developer.imagesOff = true
            // WebKit gives the new tab the opener's configuration, including the images rule.
            let handed = openerView.configuration.copy() as! WKWebViewConfiguration
            #expect(handed.userContentController === openerView.configuration.userContentController)
            let opened = Tab(url: nil, spaceID: UUID(), configuration: handed)
            let openedView = opened.ensureWebView()
            #expect(PageImages.sharing(with: openedView).contains { $0 === openerView })
            // It inherits the opener's setting.
            #expect(opened.developer.imagesOff)
            // Turned on in the child: on in both, rule removed.
            opened.developer.imagesOff = false
            #expect(!opener.developer.imagesOff && !PageImages.isOff(in: openerView))
            // And off in the opener is off in the child.
            opener.developer.imagesOff = true
            #expect(opened.developer.imagesOff)
            // An unrelated tab shares nothing.
            let other = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            let otherView = other.ensureWebView()
            #expect(!other.developer.imagesOff && PageImages.sharing(with: otherView).isEmpty)
            other.developer.imagesOff = true
            other.developer.imagesOff = false
            #expect(opener.developer.imagesOff && opened.developer.imagesOff)
            opener.developer.imagesOff = false
            [opener, opened, other].forEach { $0.close() }
        }
    }

    @Test func aPageAnotherOpenedHasPreferencesOfItsOwn() {
        withDefaults {
            // Opener has styles off; WebKit shares its preferences.
            let configuration = WKWebViewConfiguration()
            let opener = configuration.preferences
            PageStyles.set(false, in: opener)
            configuration.preferences.minimumFontSize = 3
            // A child tab never shares them, for any site or opener choice.
            for site in ["https://example.com/", "http://localhost:1/"] {
                let handed = configuration.copy() as! WKWebViewConfiguration
                #expect(handed.preferences === opener)
                let tab = Tab(url: URL(string: site), spaceID: UUID(), configuration: handed)
                let own = tab.ensureWebView().configuration.preferences
                #expect(own !== opener)
                // Matches WebKit's defaults for developer-tool settings.
                #expect(own.value(forKey: PageStyles.key) as? Bool == true)
                #expect(own.minimumFontSize == 3)
                // The opener keeps its own.
                PageStyles.set(false, in: own)
                PageStyles.set(true, in: own)
                #expect(opener.value(forKey: PageStyles.key) as? Bool == false)
                tab.close()
            }
        }
    }

    @Test func aPageAskedForAsAnotherBrowserIsAskedForAgain() {
        let phone = DeveloperState.UserAgent.iPhone.string
        // Leaving a development page told it's an iPhone for a site off the list: asked for again, as Zigzag.
        #expect(Tab.asksAgain(sent: phone, wanted: nil, isGet: true, type: .linkActivated))
        // Coming to one: asked for again, as the browser chosen.
        #expect(Tab.asksAgain(sent: nil, wanted: phone, isGet: true, type: .other))
        #expect(Tab.asksAgain(sent: "", wanted: phone, isGet: true, type: .other))
        // Nothing to change: the request stands.
        #expect(!Tab.asksAgain(sent: nil, wanted: nil, isGet: true, type: .linkActivated))
        #expect(!Tab.asksAgain(sent: "", wanted: nil, isGet: true, type: .linkActivated))
        #expect(!Tab.asksAgain(sent: phone, wanted: phone, isGet: true, type: .linkActivated))
        // Not what can't be made again as it was: a form's reply, Back or Forward, a reload.
        #expect(!Tab.asksAgain(sent: phone, wanted: nil, isGet: false, type: .other))
        for type in [WKNavigationType.backForward, .reload, .formSubmitted, .formResubmitted] {
            #expect(!Tab.asksAgain(sent: phone, wanted: nil, isGet: true, type: type))
        }
    }

    @Test func eachUserAgentSaysTheBrowserItNames() {
        #expect(DeveloperState.UserAgent.zigzag.string == nil)
        #expect(DeveloperState.UserAgent.iPhone.string?.contains("iPhone") == true)
        #expect(DeveloperState.UserAgent.iPad.string?.contains("iPad") == true)
        #expect(DeveloperState.UserAgent.chrome.string?.contains("Chrome/") == true)
        #expect(DeveloperState.UserAgent.firefox.string?.contains("Firefox/") == true)
        for tool in DeveloperTool.allCases {
            guard let agent = tool.userAgent else { continue }
            var state = DeveloperState()
            state.userAgent = agent
            #expect(tool.isChecked(in: state))
            #expect(tool.group == .userAgent && tool.isChoice)
        }
        #expect(DeveloperTool.allCases.compactMap(\.userAgent).count == DeveloperState.UserAgent.allCases.count)
    }

    @Test func thePageIsToldTheBrowserChosenOnlyOnADevelopmentSite() {
        withDefaults {
            let tab = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            let webView = tab.ensureWebView()
            tab.developer.userAgent = .iPhone
            #expect(webView.customUserAgent == DeveloperState.UserAgent.iPhone.string)
            #expect(!tab.pageIsUntouched(at: URL(string: "http://localhost:1/")))
            // A page anywhere else is as its site made it.
            #expect(tab.pageIsUntouched(at: URL(string: "https://example.com/")))
            #expect(!tab.developerInEffect(at: URL(string: "https://example.com/")).javaScriptOff)
            DeveloperTools.isOn = false
            tab.refreshDevelopment()
            #expect((webView.customUserAgent ?? "").isEmpty)
            tab.developer = DeveloperState()
            tab.close()
        }
    }

    @Test func whatIsOnOrOffIsCheckedWhileItIs() {
        let all = DeveloperBarTools.parts.count
        func underMore(_ state: DeveloperState, shown: Int = all) -> Bool {
            DeveloperTool.hasChoiceInEffect(among: DeveloperBarTools.toolsUnderMore(shown: shown), in: state)
        }
        var state = DeveloperState()
        #expect(!DeveloperTool.javaScript.isChecked(in: state) && !DeveloperTool.outlines.isChecked(in: state))
        #expect(!underMore(state) && !underMore(state, shown: 0))
        state.javaScriptOff = true
        #expect(DeveloperTool.javaScript.isChecked(in: state) && underMore(state))
        state = DeveloperState()
        state.outlines = true
        #expect(DeveloperTool.outlines.isChecked(in: state) && underMore(state))
        state = DeveloperState()
        state.userAgent = .chrome
        #expect(underMore(state))
        // Bar buttons aren't repeated under ⋯ until they overflow.
        state = DeveloperState()
        state.appearance = .dark
        #expect(!underMore(state) && underMore(state, shown: 0))
        state = DeveloperState()
        state.size = CGSize(width: 393, height: 852)
        #expect(!underMore(state) && underMore(state, shown: 0))
        state = DeveloperState()
        state.printStyles = true
        #expect(!underMore(state) && underMore(state, shown: 0))
    }

    @Test func theOutlineIsOneStylePutInAndTakenOutByName() {
        #expect(PageOutlines.script.contains("outline") && PageOutlines.script.contains("old.remove()"))
    }

    @Test func theOtherBrowsersLeaveOutEveryZigzag() {
        let apps = ["/Applications/Safari.app", "/Applications/Zigzag.app", "/Applications/Google Chrome.app", "/Applications/Zigzag Dev.app",
                    "/Users/me/Applications/Notes Site.app", "/Applications/Firefox.app", "/Volumes/Backup/Safari.app"].map { URL(fileURLWithPath: $0) }
        let ids = ["Safari": "com.apple.Safari", "Zigzag": "wang.zigao.zigzag", "Google Chrome": "com.google.Chrome", "Zigzag Dev": "wang.zigao.zigzag.dev",
                   "Notes Site": "wang.zigao.zigzag.webapp.notes", "Firefox": "org.mozilla.firefox"]
        let browsers = OtherBrowsers.browsers(among: apps, own: "wang.zigao.zigzag.dev") { ids[$0.deletingPathExtension().lastPathComponent] }
        // By name, each once, and none of Zigzag's own.
        #expect(browsers.map(\.name) == ["Firefox", "Google Chrome", "Safari"])
        #expect(browsers.last?.url.path == "/Applications/Safari.app")
    }

    @Test func aGroupsToolsShareItsSubmenuUnderTheirShortNames() {
        withDefaults {
            let menu = MainMenu.build()
            func find(_ menu: NSMenu, _ action: Selector) -> NSMenuItem? {
                for item in menu.items {
                    if item.action == action { return item }
                    if let found = item.submenu.flatMap({ find($0, action) }) { return found }
                }
                return nil
            }
            let dark = find(menu, DeveloperTool.appearanceDark.action)
            #expect(dark?.title == DeveloperTool.appearanceDark.shortTitle)
            #expect(dark?.menu?.title == DeveloperTool.Group.appearance.title)
            // The choices, a line, then what stands apart.
            #expect(dark?.menu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ==
                    [DeveloperTool.appearanceFollowsMac.shortTitle, DeveloperTool.appearanceLight.shortTitle, DeveloperTool.appearanceDark.shortTitle, "-", DeveloperTool.printStyles.shortTitle])
            #expect(find(menu, DeveloperTool.userAgentChrome.action)?.menu?.title == DeveloperTool.Group.userAgent.title)
            #expect(find(menu, DeveloperTool.rotate.action)?.menu?.title == DeveloperTool.Group.size.title)
            // A tool that's part of no group is in View › Developer itself, under its own name.
            let script = find(menu, DeveloperTool.javaScript.action)
            #expect(script?.title == DeveloperTool.javaScript.title)
            #expect(script?.menu === find(menu, #selector(BrowserWindowController.viewSource(_:)))?.menu)
            // Off, none of it is left.
            #expect(MainMenu.setDeveloperTools(false, in: menu))
            for tool in DeveloperTool.menuItems { #expect(find(menu, tool.action) == nil) }
        }
    }
}
