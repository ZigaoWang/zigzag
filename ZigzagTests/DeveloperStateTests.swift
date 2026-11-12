import AppKit
import Testing
import WebKit
@testable import Zigzag

/// A tab's own choices with the developer tools (#141): in effect only on a development site, and dark pages stand
/// back from a page whose look was chosen.
@MainActor
@Suite(.serialized)
struct DeveloperStateTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "DeveloperStateTests-\(UUID().uuidString)"
        let saved = DeveloperTools.defaults
        DeveloperTools.defaults = UserDefaults(suiteName: name)!
        defer {
            DeveloperTools.defaults.removePersistentDomain(forName: name)
            DeveloperTools.defaults = saved
            DeveloperTools.changed.send()
        }
        try body()
    }

    @Test func aTabsChoicesApplyOnlyWhileItIsADevelopmentTab() {
        withDefaults {
            let tab = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            #expect(tab.developerInEffect == DeveloperState())
            tab.developer.appearance = .dark
            tab.developer.printStyles = true
            #expect(tab.developerInEffect.appearance == .dark && tab.developerInEffect.printStyles)
            // No longer a development tab: nothing of them applies, and they're kept.
            DeveloperTools.isOn = false
            tab.refreshDevelopment()
            #expect(tab.developerInEffect == DeveloperState())
            #expect(tab.developer.appearance == .dark && tab.developer.printStyles)
            // Back: they apply again.
            DeveloperTools.isOn = true
            tab.refreshDevelopment()
            #expect(tab.developerInEffect.appearance == .dark && tab.developerInEffect.printStyles)
        }
    }

    @Test func aChoiceIsForThePageTheWebViewIsGoingTo() {
        withDefaults {
            let tab = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            tab.developer.appearance = .dark
            // Still showing its development page, with another site's on its way: that page starts without it.
            #expect(tab.isDevelopment)
            #expect(tab.chosenLook(at: URL(string: "https://example.com/")) == nil)
            #expect(tab.developerInEffect(at: URL(string: "https://example.com/")) == DeveloperState())
            #expect(tab.chosenLook(at: URL(string: "http://localhost:1/next")) == .darkAqua)
            #expect(tab.chosenLook(at: nil) == nil)
        }
    }

    @Test func aChoiceIsAnnouncedOnceAndOnlyWhenItChanges() {
        withDefaults {
            let tab = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            var heard = 0
            let token = tab.changed.observe { if $0 == .developer { heard += 1 } }
            tab.developer.appearance = .light
            tab.developer.appearance = .light
            tab.developer.printStyles = false
            #expect(heard == 1)
            token.cancel()
        }
    }

    @Test func thePageIsAskedForTheLookAndTheStylesChosen() {
        withDefaults {
            let tab = Tab(url: nil, spaceID: UUID())
            let webView = tab.ensureWebView()
            tab.developer.appearance = .dark
            tab.developer.printStyles = true
            // Not a development tab: the page is as any page.
            #expect(DarkPages.chosenLook(of: webView) == nil)
            #expect(webView.mediaType == nil)
            tab.close()

            let local = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            local.developer.appearance = .light
            let page = local.ensureWebView()
            // A new web view comes with the tab's choices.
            #expect(DarkPages.chosenLook(of: page) == .aqua)
            #expect(page.appearance?.name == .aqua)
            local.developer.appearance = .dark
            local.developer.printStyles = true
            #expect(page.appearance?.name == .darkAqua)
            #expect(page.mediaType == "print")
            // Lifted with Developer tools off, as on any other site.
            DeveloperTools.isOn = false
            local.refreshDevelopment()
            #expect(DarkPages.chosenLook(of: page) == nil)
            #expect(page.mediaType == nil)
            local.developer = DeveloperState()
            local.close()
        }
    }

    @Test func darkPagesStandBackFromAPageWhoseLookWasChosen() {
        let saved = DarkPages.defaults
        let name = "DeveloperStateTests-dark-\(UUID().uuidString)"
        DarkPages.defaults = UserDefaults(suiteName: name)!
        defer {
            DarkPages.defaults.removePersistentDomain(forName: name)
            DarkPages.defaults = saved
        }
        DarkPages.defaults.set("always", forKey: "DarkPages")
        DarkPages.defaults.set(["localhost"], forKey: "DarkPagesOnSites")
        DarkPages.defaults.set(["localhost"], forKey: "DarkPagesForcedSites")
        let url = URL(string: "http://localhost:1/")
        let usual = DarkPages.config(for: nil, url: url)
        #expect(usual["on"] as? Bool == true)
        #expect(usual["topWanted"] as? Bool == true)
        #expect(usual["sitesOn"] as? [String] == ["localhost"])
        let chosen = DarkPages.config(for: nil, url: url, standsBack: true)
        // What a page is told where dark pages are off.
        #expect(chosen["on"] as? Bool == false)
        #expect(chosen["topWanted"] as? Bool == false)
        #expect(chosen["topForced"] as? Bool == false)
        #expect(chosen["sitesOn"] as? [String] == [])
        #expect(chosen["sitesForced"] as? [String] == [])
    }

    @Test func eachChoiceIsCheckedWhileItIsTheOneInEffect() {
        var state = DeveloperState()
        #expect(DeveloperTool.appearanceFollowsMac.isChecked(in: state))
        #expect(!DeveloperTool.appearanceLight.isChecked(in: state) && !DeveloperTool.appearanceDark.isChecked(in: state))
        #expect(!DeveloperTool.printStyles.isChecked(in: state))
        state.appearance = .dark
        state.printStyles = true
        #expect(DeveloperTool.appearanceDark.isChecked(in: state) && !DeveloperTool.appearanceFollowsMac.isChecked(in: state))
        #expect(DeveloperTool.printStyles.isChecked(in: state))
        #expect(!DeveloperTool.console.isChecked(in: state))
    }

    @Test func theAppearanceButtonSaysWhichLookIsInEffect() throws {
        let part = try #require(DeveloperBarTools.parts.first { $0.tools.contains(.appearanceDark) })
        var state = DeveloperState()
        #expect(DeveloperBarTools.symbol(of: part, in: state) == DeveloperTool.appearanceFollowsMac.symbol)
        state.appearance = .light
        #expect(DeveloperBarTools.symbol(of: part, in: state) == DeveloperTool.appearanceLight.symbol)
        state.appearance = .dark
        #expect(DeveloperBarTools.symbol(of: part, in: state) == DeveloperTool.appearanceDark.symbol)
        state.printStyles = true
        #expect(DeveloperBarTools.symbol(of: part, in: state) == DeveloperTool.printStyles.symbol)
        // A button that holds no choice keeps its own.
        let console = try #require(DeveloperBarTools.parts.first { $0.tools == [.console] })
        #expect(DeveloperBarTools.symbol(of: console, in: state) == console.symbol)
        // The looks together in its menu, print styles after a line.
        #expect(DeveloperBarTools.grouped(part.tools) == [[.appearanceFollowsMac, .appearanceLight, .appearanceDark], [.printStyles]])
        #expect(DeveloperBarTools.grouped([.reloadIgnoringCache, .clearCache]) == [[.reloadIgnoringCache, .clearCache]])
    }
}
