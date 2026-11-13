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
                       strip.pinButton, strip.copyButton, strip.openButton].map(\.frame).filter { $0.width > 0 }
            for (a, b) in zip(row, row.dropFirst()) { #expect(a.maxX <= b.minX + 0.5, "at \(width)") }
            #expect(strip.reloadButton.frame.minX > strip.trafficLightsWidth)
            #expect(strip.openButton.frame.maxX <= width)
        }
    }
}
