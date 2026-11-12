import AppKit
import Testing
import WebKit
@testable import Zigzag

/// The rest of the developer tools (#141): JavaScript off, the user agent, outlines, and the other browsers.
@MainActor
@Suite(.serialized)
struct DeveloperMoreTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "DeveloperMoreTests-\(UUID().uuidString)"
        let saved = DeveloperTools.defaults
        DeveloperTools.defaults = UserDefaults(suiteName: name)!
        defer {
            DeveloperTools.defaults.removePersistentDomain(forName: name)
            DeveloperTools.defaults = saved
            DeveloperTools.changed.send()
        }
        try body()
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
        var state = DeveloperState()
        #expect(!DeveloperTool.javaScript.isChecked(in: state) && !DeveloperTool.outlines.isChecked(in: state))
        #expect(!DeveloperBarTools.hasHiddenChoice(state))
        state.javaScriptOff = true
        #expect(DeveloperTool.javaScript.isChecked(in: state) && DeveloperBarTools.hasHiddenChoice(state))
        state = DeveloperState()
        state.outlines = true
        #expect(DeveloperTool.outlines.isChecked(in: state) && DeveloperBarTools.hasHiddenChoice(state))
        state = DeveloperState()
        state.userAgent = .chrome
        #expect(DeveloperBarTools.hasHiddenChoice(state))
        // What a button above the page shows for itself isn't hidden.
        state = DeveloperState()
        state.appearance = .dark
        state.size = CGSize(width: 393, height: 852)
        #expect(!DeveloperBarTools.hasHiddenChoice(state))
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
