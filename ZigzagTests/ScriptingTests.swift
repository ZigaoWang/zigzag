import Foundation
import Testing
@testable import Zigzag

/// AppleScript's view of Zigzag: what it may open, which tabs and windows it sees, and when it may run JavaScript.
@MainActor
struct ScriptingTests {
    @Test func opensOnlyWebAddresses() {
        #expect(Scripting.webAddress("https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(Scripting.webAddress("  http://127.0.0.1:8000/\n")?.host() == "127.0.0.1")
        for address in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/hosts", "zigzag://settings", "webkit-extension://abc/page.html",
                        "example.com", "https://", "", "about:blank"] {
            #expect(Scripting.webAddress(address) == nil, "\(address)")
        }
    }

    @Test func tabsInSidebarOrder() {
        let favorite = UUID(), pinnedA = UUID(), pinnedB = UUID(), closedPin = UUID(), spaceA = UUID(), spaceB = UUID()
        let live: [UUID: String] = [favorite: "favorite", pinnedA: "pinned A", pinnedB: "pinned B"]
        let tabs: [UUID: [String]] = [spaceA: ["a1", "a2"], spaceB: ["b1"]]
        let ordered = Scripting.ordered(favorites: [favorite], spaces: [(spaceA, [pinnedA, closedPin]), (spaceB, [pinnedB])],
                                        bookmarkTabs: live, tabs: { tabs[$0] ?? [] })
        #expect(ordered == ["favorite", "pinned A", "a1", "a2", "pinned B", "b1"])
    }

    @Test func tabIDsStayTheSameAndFindTheirTab() {
        let first = UUID(), second = UUID()
        let one = Scripting.id(for: first), two = Scripting.id(for: second)
        #expect(two > one)
        #expect(Scripting.id(for: first) == one)
        let tabs = [(first, "first"), (second, "second")]
        #expect(Scripting.tab(withID: two, in: tabs, uuid: \.0)?.1 == "second")
        #expect(Scripting.tab(withID: one, in: tabs, uuid: \.0)?.1 == "first")
        #expect(Scripting.tab(withID: two + 1000, in: tabs, uuid: \.0) == nil)
    }

    @Test func privateWindowsAreNeverListed() {
        let windows = [("work", false), ("private", true), ("home", false)]
        #expect(Scripting.scriptable(windows, isPrivate: \.1).map(\.0) == ["work", "home"])
    }

    @Test func javaScriptWaitsForTheSetting() {
        let page = URL(string: "https://example.com")
        #expect(Scripting.javaScriptRefusal(url: page, isPrivate: false, allowed: false) == .turnedOff)
        #expect(Scripting.javaScriptRefusal(url: page, isPrivate: false, allowed: true) == nil)
        #expect(Scripting.javaScriptRefusal(url: URL(fileURLWithPath: "/tmp/a.html"), isPrivate: false, allowed: true) == nil)
    }

    @Test func javaScriptNeverInPrivateWindowsOrZigzagsOwnPages() {
        #expect(Scripting.javaScriptRefusal(url: URL(string: "https://example.com"), isPrivate: true, allowed: true) == .privateWindow)
        for address in ["zigzag://settings", "zigzag://history", "webkit-extension://abc/popup.html"] {
            #expect(Scripting.javaScriptRefusal(url: URL(string: address), isPrivate: false, allowed: true) == .notAWebPage, "\(address)")
        }
        #expect(Scripting.javaScriptRefusal(url: nil, isPrivate: false, allowed: true) == .notAWebPage)
    }

    @Test func readsOnlyWebPagesOutsidePrivateWindows() {
        #expect(Scripting.isReadable(url: URL(string: "https://example.com"), isPrivate: false))
        #expect(!Scripting.isReadable(url: URL(string: "https://example.com"), isPrivate: true))
        #expect(!Scripting.isReadable(url: URL(string: "zigzag://history"), isPrivate: false))
    }

    @Test func awaitOrReturnRunsAsAFunction() {
        #expect(Scripting.runsAsFunction(source: "const r = await fetch('/'); return r.status", exceptionMessage: "SyntaxError: Unexpected identifier 'fetch'"))
        #expect(Scripting.runsAsFunction(source: "return 1", exceptionMessage: "SyntaxError: Return statements are only valid inside functions."))
        // A mistake of another kind ran (or failed) already, and never runs twice.
        #expect(!Scripting.runsAsFunction(source: "return nope()", exceptionMessage: "ReferenceError: Can't find variable: nope"))
        #expect(!Scripting.runsAsFunction(source: "1 +", exceptionMessage: "SyntaxError: Unexpected end of script"))
        #expect(!Scripting.runsAsFunction(source: "returned = 1; (", exceptionMessage: "SyntaxError: Unexpected end of script"))
    }

    @Test func resultsAsText() {
        #expect(Scripting.text(of: "hi") == "hi")
        #expect(Scripting.text(of: NSNumber(value: 42)) == "42")
        #expect(Scripting.text(of: NSNumber(value: 1.5)) == "1.5")
        #expect(Scripting.text(of: NSNumber(value: true)) == "true")
        #expect(Scripting.text(of: [1, ["a": 2]] as [Any]) == #"[1,{"a":2}]"#)
        #expect(Scripting.text(of: nil) == nil)
        #expect(Scripting.text(of: NSNull()) == nil)
        let nothing: Any? = nil
        #expect(Scripting.text(of: nothing as Any) == nil)
    }
}
