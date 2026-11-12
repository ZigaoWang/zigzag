import Foundation
import Testing
import WebKit
@testable import Zigzag

/// The count of a development tab's page errors (#141): what counts, where, and how it's shown.
@MainActor
@Suite(.serialized)
struct PageErrorCountTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "PageErrorCountTests-\(UUID().uuidString)"
        let saved = DeveloperTools.defaults
        DeveloperTools.defaults = UserDefaults(suiteName: name)!
        defer {
            DeveloperTools.defaults.removePersistentDomain(forName: name)
            DeveloperTools.defaults = saved
            DeveloperTools.changed.send()
        }
        try body()
    }

    @Test func errorsAndFailedPromisesCountAndFailedRequestsDont() {
        #expect(PageErrors.errors(in: ["kind": "error", "text": "x is not defined"]) == 1)
        #expect(PageErrors.errors(in: ["kind": "rejection", "text": "TypeError"]) == 1)
        #expect(PageErrors.errors(in: ["kind": "http", "text": "500 from localhost:3000"]) == 0)
        #expect(PageErrors.errors(in: [:]) == 0)
        // Past the few a page describes, it says how many more.
        #expect(PageErrors.more(240) == 240)
        #expect(PageErrors.more("many") == 0)
        #expect(PageErrors.more(-3) == 0)
        #expect(PageErrors.more(9_000_000) == 100_000)
    }

    @Test func aPageSaysHowManyMoreOnlyWhereADevelopmentTabListens() {
        // The page script looks for the listener before it counts on: without one it stops at the few it describes.
        #expect(PageErrors.script.source.contains("window.webkit.messageHandlers.\(PageErrors.countName))"))
        let webView = WKWebView(frame: .zero)
        PageErrors.counts(in: webView, true)
        // Twice is once: a second listener of the same name would be refused.
        PageErrors.counts(in: webView, true)
        PageErrors.counts(in: webView, false)
        PageErrors.counts(in: webView, false)
        PageErrors.counts(in: webView, true)
        PageErrors.counts(in: webView, false)
        #expect(!PageErrors.isCounting(in: webView))
    }

    @Test func aPopUpThatIsNoDevelopmentTabLeavesItsOpenersListenerIn() {
        // A page and the pop-up it opened share one set of scripts, so one listener.
        let opener = WKWebView(frame: .zero)
        let popUp = WKWebView(frame: .zero, configuration: opener.configuration)
        #expect(popUp.configuration.userContentController === opener.configuration.userContentController)
        PageErrors.counts(in: opener, true)
        PageErrors.counts(in: popUp, false)
        #expect(PageErrors.isCounting(in: opener))
        // Both listened to, then neither: in once, out once.
        PageErrors.counts(in: popUp, true)
        PageErrors.counts(in: opener, false)
        #expect(PageErrors.isCounting(in: popUp))
        PageErrors.counts(in: popUp, false)
        #expect(!PageErrors.isCounting(in: opener))
    }

    @Test func onlyADevelopmentTabCounts() {
        withDefaults {
            let space = UUID()
            let local = Tab(url: URL(string: "http://localhost:3000/"), spaceID: space)
            let other = Tab(url: URL(string: "https://example.com/"), spaceID: space)
            var heard = 0
            let token = local.changed.observe { if $0 == .pageErrors { heard += 1 } }
            local.countPageErrors(1)
            local.countPageErrors(4)
            local.countPageErrors(0)
            other.countPageErrors(3)
            #expect(local.pageErrorCount == 5)
            #expect(other.pageErrorCount == 0)
            #expect(heard == 2)
            // No longer a development tab: nothing is kept of it.
            DeveloperTools.isOn = false
            local.refreshDevelopment()
            #expect(local.pageErrorCount == 0)
            local.countPageErrors(2)
            #expect(local.pageErrorCount == 0)
            token.cancel()
        }
    }

    @Test func theCountIsShownUpToNinetyNine() {
        #expect(DeveloperTool.errorBadge(0) == "")
        #expect(DeveloperTool.errorBadge(-1) == "")
        #expect(DeveloperTool.errorBadge(1) == "1")
        #expect(DeveloperTool.errorBadge(99) == "99")
        #expect(DeveloperTool.errorBadge(100) == "99+")
        #expect(DeveloperTool.errorBadge(100) .count <= BadgeView.maxLength)
        #expect(DeveloperTool.errorValue(0) == nil)
        #expect(DeveloperTool.errorValue(3)?.contains("3") == true)
    }

    @Test func theCountSitsOnTheConsoleOrOnMoreWhileTheConsoleIsUnderIt() {
        withDefaults {
            let tab = Tab(url: URL(string: "http://localhost:3000/"), spaceID: UUID())
            let tools = DeveloperBarTools(frame: NSRect(x: 0, y: 0, width: 600, height: TopBarView.height))
            tools.show(tab, in: nil)
            tools.layoutSubtreeIfNeeded()
            func badges() -> [BadgeView] { tools.subviews.flatMap { $0.subviews.compactMap { $0 as? BadgeView } } }
            #expect(badges().isEmpty)
            tab.countPageErrors(3)
            #expect(badges().map(\.text) == ["3"])
            let console = badges().first?.superview
            // Too narrow for any button: the count moves to ⋯.
            tools.frame.size.width = Tokens.Sidebar.button
            tools.needsLayout = true
            tools.layoutSubtreeIfNeeded()
            #expect(badges().count == 1 && badges().first?.superview !== console)
            tab.countPageErrors(200)
            #expect(badges().map(\.text) == ["99+"])
        }
    }
}
