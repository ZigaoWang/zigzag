import AppKit
import Foundation
import Testing
@testable import Zigzag

/// An installed app's window (#165) and Zigzag Mini: the bar in the page's color, the toolbar choice that's kept per
/// app, and the menu bar that turns into the app's own while its window is in front.
@MainActor
struct WebAppWindowTests {
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private let paper = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)
    private let ink = NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1)
    private let slate = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.15, alpha: 1)
    private let red = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)

    // MARK: The bar's color

    @Test func barTakesTheSitesThemeColorOnItsSideOfLightAndDark() {
        // A theme color on the page's side of light and dark wins, as in Chrome and Safari.
        #expect(PageBar.color(theme: slate, page: ink) == slate)
        #expect(PageBar.color(theme: paper, page: white) == paper)
        // A dark site that keeps a white theme color for its header: the page's dark instead, never a white band.
        #expect(PageBar.color(theme: white, page: ink) == ink)
        // The manifest's color comes after the page's own theme color, by the same rule.
        #expect(PageBar.color(theme: nil, fallback: red, page: ink) == red)
        #expect(PageBar.color(theme: nil, fallback: white, page: ink) == ink)
        #expect(PageBar.color(theme: slate, fallback: red, page: ink) == slate)
        // Nothing yet but a theme color: that.
        #expect(PageBar.color(theme: red, page: nil) == red)
        #expect(PageBar.color(theme: nil, page: nil) == nil)
    }

    @Test func hairlineOnlyWhereBarAndPageMeetAsOne() {
        #expect(PageBar.needsHairline(bar: white, page: white))
        #expect(PageBar.needsHairline(bar: paper, page: white))
        #expect(!PageBar.needsHairline(bar: slate, page: white))
        #expect(!PageBar.needsHairline(bar: white, page: ink))
        #expect(PageBar.needsHairline(bar: nil, page: white))
    }

    @Test func manifestThemeColorIsReadAsHex() {
        let json = ##"{"name":"GitHub","theme_color":"#1E2327","icons":[]}"##
        #expect(WebAppIcon.manifest(Data(json.utf8), base: URL(string: "https://github.com/manifest.json")!).themeColor == "#1e2327")
        #expect(WebAppIcon.hexColor("#FFF") == "#ffffff")
        #expect(WebAppIcon.hexColor("rgb(0, 0, 0)") == nil)
        #expect(WebAppIcon.hexColor("#12345") == nil)
    }

    // MARK: The toolbar choice

    @Test func onlyTheSmallAppThatWentIsIgnoredAfterAClose() {
        let closed = Date()
        // The small app that was running as the window closed asks again as it goes: not you asking.
        #expect(WebAppWindowController.isLeftover(sender: 501, closing: [501], closedAt: closed, now: closed.addingTimeInterval(0.3)))
        // A new one, opened again from the Dock right away, is you, however soon.
        #expect(!WebAppWindowController.isLeftover(sender: 777, closing: [501], closedAt: closed, now: closed.addingTimeInterval(0.3)))
        // Who asked unknown: only a moment after the close is taken for the leftover.
        #expect(WebAppWindowController.isLeftover(sender: nil, closing: [501], closedAt: closed, now: closed.addingTimeInterval(1)))
        #expect(!WebAppWindowController.isLeftover(sender: nil, closing: [501], closedAt: closed, now: closed.addingTimeInterval(2)))
        #expect(!WebAppWindowController.isLeftover(sender: nil, closing: [], closedAt: nil))
    }

    @Test func appsSavedBeforeTheChoiceShowTheToolbar() throws {
        let old = #"{"id":"0123456789abcdef","name":"Wiki","url":"https://en.wikipedia.org/","profileID":"11111111-2222-3333-4444-555555555555","spaceID":"11111111-2222-3333-4444-555555555555","bundlePath":"/x.app","created":0}"#
        let app = try JSONDecoder().decode(WebApp.self, from: Data(old.utf8))
        #expect(app.showsToolbar)
        #expect(app.themeColor == nil)
    }

    @Test func toolbarChoiceIsKeptPerApp() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("WebApps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WebAppStore(file: file)
        let profile = UUID()
        func app(_ id: String) -> WebApp {
            WebApp(id: id, name: id, url: URL(string: "https://example.com/")!, profileID: profile, spaceID: profile, bundlePath: "/x.app", created: Date())
        }
        store.save(app("aaaaaaaaaaaaaaaa"))
        store.save(app("bbbbbbbbbbbbbbbb"))
        var heard = 0
        let token = store.changed.observe { heard += 1 }
        store.setShowsToolbar(false, for: "aaaaaaaaaaaaaaaa")
        #expect(store.app("aaaaaaaaaaaaaaaa")?.showsToolbar == false)
        #expect(store.app("bbbbbbbbbbbbbbbb")?.showsToolbar == true)
        // Set to what it is: nothing to save or say.
        store.setShowsToolbar(false, for: "aaaaaaaaaaaaaaaa")
        #expect(heard == 1)
        // And it's kept for the next launch.
        #expect(WebAppStore(file: file).app("aaaaaaaaaaaaaaaa")?.showsToolbar == false)
        store.setShowsToolbar(true, for: "aaaaaaaaaaaaaaaa")
        #expect(store.app("aaaaaaaaaaaaaaaa")?.hidesToolbar == nil)
        _ = token
    }

    // MARK: The menu bar

    private func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(items) ?? []) }
    }

    @Test func appMenuBarQuitsAndHidesTheAppAlone() {
        let built = MainMenu.buildWebApp(name: "Wikipedia")
        let first = built.menu.items.first?.submenu
        #expect(built.menu.items.first?.title == "Wikipedia")
        let quit = first?.items.first { $0.keyEquivalent == "q" }
        #expect(quit?.title == "Quit Wikipedia")
        #expect(quit?.action == #selector(WebAppWindowController.quitWebApp(_:)))
        let hide = first?.items.first { $0.keyEquivalent == "h" && $0.keyEquivalentModifierMask == [.command] }
        #expect(hide?.title == "Hide Wikipedia")
        #expect(hide?.action == #selector(WebAppWindowController.hideWebApp(_:)))
        let all = items(built.menu)
        // Nothing that ends Zigzag, or opens a tab or a browser window by surprise.
        let browserOnly: [Selector] = [#selector(NSApplication.terminate(_:)), #selector(BrowserWindowController.newTab(_:)),
                                       #selector(AppDelegate.newWindow(_:)), #selector(AppDelegate.newPrivateWindow(_:)),
                                       #selector(BrowserWindowController.openLocation(_:)), #selector(BrowserWindowController.installAsApp(_:)),
                                       #selector(BrowserWindowController.reopenClosedTab(_:)), #selector(AppDelegate.showHistory(_:)),
                                       #selector(BrowserWindowController.showFindBar(_:))]
        for selector in browserOnly { #expect(!all.contains { $0.action == selector }, "\(selector)") }
        // What a web app does want: the toolbar, going back, the page's text.
        for selector in [#selector(WebAppWindowController.toggleToolbar(_:)), #selector(WebAppWindowController.goBack(_:)),
                         #selector(WebAppWindowController.reloadPage(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:))] {
            #expect(all.contains { $0.action == selector }, "\(selector)")
        }
        #expect(built.menu.items.contains { $0.submenu === built.windows })
    }

    @Test func menuBarFollowsTheWindowInFront() {
        let browser = WebAppMenuBar.Bar(menu: NSMenu(title: "Zigzag"))
        var installed: [String] = []
        let bar = WebAppMenuBar(browser: browser, makeWebApp: { name in WebAppMenuBar.Bar(menu: NSMenu(title: name)) },
                                install: { installed.append($0.menu.title) })
        bar.show(.webApp(name: "Wikipedia"))
        bar.show(.webApp(name: "Wikipedia"))
        #expect(installed == ["Wikipedia"])
        bar.show(.webApp(name: "GitHub"))
        bar.show(.browser)
        bar.show(.browser)
        #expect(installed == ["Wikipedia", "GitHub", "Zigzag"])
        #expect(bar.shown == .browser)
    }

    @Test func aSheetOverAnAppsWindowKeepsTheAppsMenus() {
        let app = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let child = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        app.isReleasedWhenClosed = false
        child.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        let saved = WebAppMenuBar.appName
        defer { WebAppMenuBar.appName = saved }
        WebAppMenuBar.appName = { $0 === app ? "Wikipedia" : nil }
        app.addChildWindow(child, ordered: .above)
        defer { app.removeChildWindow(child) }
        #expect(WebAppMenuBar.kind(of: app) == .webApp(name: "Wikipedia"))
        #expect(WebAppMenuBar.kind(of: child) == .webApp(name: "Wikipedia"))
        #expect(WebAppMenuBar.kind(of: other) == .browser)
    }
}
