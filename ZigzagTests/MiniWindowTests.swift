import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Where a mini window opens, and which links from other apps go to one.
@MainActor
struct MiniWindowTests {
    let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
    let size = NSSize(width: 900, height: 640)

    @Test func firstOneIsCenteredOnTheScreen() {
        let frame = MiniWindowController.frame(size: size, in: screen, taken: [])
        #expect(frame.size == size)
        #expect(frame.midX == screen.midX)
        #expect(abs(frame.midY - screen.midY) <= 0.5)
    }

    @Test func nextOnesCascadeDownAndRight() {
        let first = MiniWindowController.frame(size: size, in: screen, taken: [])
        let second = MiniWindowController.frame(size: size, in: screen, taken: [first])
        let third = MiniWindowController.frame(size: size, in: screen, taken: [first, second])
        #expect(second.minX > first.minX && second.maxY < first.maxY)
        #expect(third.minX > second.minX && third.maxY < second.maxY)
        #expect(second.size == size)
    }

    @Test func aClosedOnesSpotIsUsedAgain() {
        // The first was closed: the second still sits a step down, and the next new one takes the middle again.
        let first = MiniWindowController.frame(size: size, in: screen, taken: [])
        let second = MiniWindowController.frame(size: size, in: screen, taken: [first])
        #expect(MiniWindowController.frame(size: size, in: screen, taken: [second]) == first)
    }

    @Test func smallScreenFitsAndStaysInsideIt() {
        let small = NSRect(x: 0, y: 0, width: 800, height: 500)
        let frame = MiniWindowController.frame(size: size, in: small, taken: [])
        #expect(small.contains(frame))
        #expect(frame.size == NSSize(width: 800, height: 500))
        // No room to cascade: back to the middle rather than off the screen.
        #expect(MiniWindowController.frame(size: size, in: small, taken: [frame]) == frame)
    }

    @Test func onlyWebLinksWithTheSettingOnAfterOnboarding() {
        let web = URL(string: "https://example.com/a")!
        #expect(MiniWindowController.takes(web, settingOn: true, needsOnboarding: false))
        #expect(MiniWindowController.takes(URL(string: "HTTP://example.com")!, settingOn: true, needsOnboarding: false))
        // Off by default, and links before onboarding keep opening in the first window.
        #expect(!MiniWindowController.takes(web, settingOn: false, needsOnboarding: false))
        #expect(!MiniWindowController.takes(web, settingOn: true, needsOnboarding: true))
        // Files opened from Finder stay tabs.
        #expect(!MiniWindowController.takes(URL(fileURLWithPath: "/tmp/page.html"), settingOn: true, needsOnboarding: false))
    }

    /// Every way another app hands Zigzag a page, as AppDelegate takes it: an Apple Event link (`open location`, what
    /// Python's webbrowser and most apps send), a URL handed over as a document (`open -a`, Finder), and Handoff,
    /// which all end in `takes` (#246).
    @Test func everyLinkFromAnotherAppGoesToZigzagMiniWhenOn() {
        func viaAppleEvent(_ string: String) -> Bool? {
            Scripting.webAddress(string).map { MiniWindowController.takes($0, settingOn: true, needsOnboarding: false) }
        }
        func viaDocument(_ url: URL) -> Bool? {
            AppDelegate.opensAsDocument(url) ? MiniWindowController.takes(url, settingOn: true, needsOnboarding: false) : nil
        }
        // A script's local plot server and an OAuth page from another app: Zigzag Mini.
        #expect(viaAppleEvent("http://127.0.0.1:54123/") == true)
        #expect(viaAppleEvent("https://github.com/login/oauth/authorize?client_id=x") == true)
        #expect(viaDocument(URL(string: "https://accounts.google.com/o/oauth2/auth")!) == true)
        // A file opened from Finder or `open page.html`: a tab, to keep.
        #expect(viaDocument(URL(fileURLWithPath: "/tmp/report.html")) == false)
        // Never Zigzag's own pages, an extension's or a script's: nothing opens.
        #expect(viaAppleEvent("zigzag://settings") == nil)
        #expect(viaAppleEvent("javascript:alert(1)") == nil)
        #expect(viaDocument(URL(string: "zigzag://history")!) == nil)
    }

    // MARK: The one-time offer (#246)

    @Test func theOfferIsMadeOnlyOnceAndOnlyWhileOff() {
        let web = URL(string: "https://accounts.example.com/sign-in")!
        #expect(MiniWindowController.offersMini(for: web, settingOn: false, asked: false, needsOnboarding: false))
        // Asked before, whatever the answer, it never comes back.
        #expect(!MiniWindowController.offersMini(for: web, settingOn: false, asked: true, needsOnboarding: false))
        // Already on: the link went to Zigzag Mini, nothing to offer.
        #expect(!MiniWindowController.offersMini(for: web, settingOn: true, asked: false, needsOnboarding: false))
        // The first window after onboarding is where you start: no offer over it.
        #expect(!MiniWindowController.offersMini(for: web, settingOn: false, asked: false, needsOnboarding: true))
        // Files opened from Finder stay tabs even with the setting on, so they don't offer it.
        #expect(!MiniWindowController.offersMini(for: URL(fileURLWithPath: "/tmp/plot.html"), settingOn: false, asked: false, needsOnboarding: false))
    }

    /// It never takes the place of another toast, nor gets its place taken by the offer to translate that comes as
    /// the page loads: two quiet checks in a row first.
    @Test func theOfferWaitsItsTurn() {
        #expect(MiniWindowController.offerTurn(quiet: true, quietBefore: true, inFront: true) == .now)
        #expect(MiniWindowController.offerTurn(quiet: true, quietBefore: false, inFront: true) == .wait)
        #expect(MiniWindowController.offerTurn(quiet: false, quietBefore: true, inFront: true) == .wait)
        // Gone to another tab: not over a page it isn't about (and not counted as asked, so the next link asks).
        #expect(MiniWindowController.offerTurn(quiet: true, quietBefore: true, inFront: false) == .never)
    }

    @Test func theOfferIsRememberedOnceShown() {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: "MiniOfferShown")
        defer { defaults.set(before, forKey: "MiniOfferShown") }
        defaults.removeObject(forKey: "MiniOfferShown")
        #expect(!MiniWindowController.miniOffered)
        MiniWindowController.miniOffered = true
        #expect(defaults.bool(forKey: "MiniOfferShown"))
    }

    // MARK: Its size

    @Test func opensAtTheSizeLastLeftAt() {
        #expect(MiniWindowController.size(remembered: nil) == Tokens.Metric.miniWindowSize)
        #expect(MiniWindowController.size(remembered: NSSize(width: 700.4, height: 820)) == NSSize(width: 700, height: 820))
        // Never smaller than it can be made.
        #expect(MiniWindowController.size(remembered: NSSize(width: 100, height: 820)) == Tokens.Metric.miniWindowSize)
        #expect(MiniWindowController.size(remembered: .zero) == Tokens.Metric.miniWindowSize)
    }

    // MARK: Back, forward and reload (#213)

    @Test func backAndForwardFollowTheHistory() {
        let strip = MiniStripView()
        strip.showNavigation(canGoBack: false, canGoForward: false, isLoading: false)
        #expect(!strip.backButton.isEnabled && !strip.forwardButton.isEnabled)
        strip.showNavigation(canGoBack: true, canGoForward: false, isLoading: false)
        #expect(strip.backButton.isEnabled && !strip.forwardButton.isEnabled)
        strip.showNavigation(canGoBack: true, canGoForward: true, isLoading: false)
        #expect(strip.backButton.isEnabled && strip.forwardButton.isEnabled)
        strip.showNavigation(canGoBack: false, canGoForward: true, isLoading: false)
        #expect(!strip.backButton.isEnabled && strip.forwardButton.isEnabled)
        // Forward stays in its place, dimmed, as in a browser window: nothing shifts as you go back and forth.
        #expect(!strip.forwardButton.isHidden)
    }

    @Test func reloadIsStopWhileLoading() {
        let strip = MiniStripView()
        strip.showNavigation(canGoBack: false, canGoForward: false, isLoading: true)
        #expect(strip.reloadButton.symbol == "xmark")
        #expect(strip.reloadButton.isEnabled)
        strip.showNavigation(canGoBack: false, canGoForward: false, isLoading: false)
        #expect(strip.reloadButton.symbol == "arrow.clockwise")
    }

    @Test func nothingOverlapsAtAnyWidth() {
        let strip = MiniStripView()
        strip.trafficLightsWidth = 52
        strip.openButton.show("Open in A Space With a Long Name", keys: "⌘O")
        let minimum = Tokens.Metric.miniWindowMinSize.width
        for width in stride(from: minimum, through: 1400, by: 20) {
            strip.frame = NSRect(x: 0, y: 0, width: width, height: Tokens.Metric.miniStripHeight)
            strip.layout()
            let row = [strip.backButton, strip.forwardButton, strip.reloadButton, strip.spaceChip, strip.title,
                       strip.siteButton, strip.pinButton, strip.copyButton, strip.openButton].map(\.frame).filter { $0.width > 0 }
            for (a, b) in zip(row, row.dropFirst()) { #expect(a.maxX <= b.minX + 0.5, "at \(width)") }
            #expect(strip.reloadButton.frame.minX > strip.trafficLightsWidth)
            #expect(strip.openButton.frame.maxX <= width)
        }
    }

    /// Site Controls (#225) ends the strip's room as it ends the address in a browser window: right before Keep on
    /// Top, with the address field and the site's name kept clear of it, and Open in still as far in from the right
    /// edge as from the top, concentric with the window's corner.
    @Test func siteControlsComeBeforeKeepOnTop() {
        let strip = MiniStripView()
        strip.trafficLightsWidth = 52
        strip.openButton.show("Open in Personal", keys: "⌘O")
        for width in [Tokens.Metric.miniWindowMinSize.width, 640, 900, 1400] {
            strip.frame = NSRect(x: 0, y: 0, width: width, height: Tokens.Metric.miniStripHeight)
            strip.layout()
            #expect(strip.siteButton.frame.width > 0, "at \(width)")
            #expect(strip.siteButton.frame.maxX == strip.pinButton.frame.minX, "at \(width)")
            // Editing the address always opens a field wide enough to use; where the strip has room, clear of the buttons.
            #expect(strip.anchor.frame.width >= MiniStripView.narrowestField, "at \(width)")
            if width >= 640 { #expect(strip.anchor.frame.maxX <= strip.siteButton.frame.minX - Tokens.Space.x2, "at \(width)") }
            #expect(strip.title.frame.width == 0 || strip.title.frame.maxX <= strip.siteButton.frame.minX + 0.5, "at \(width)")
            // Concentric with the window's corner: as far in from the right as from the top.
            #expect(strip.openButton.frame.maxX == width - strip.openButton.frame.minY, "at \(width)")
        }
    }
}
