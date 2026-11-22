import AppKit
import Testing
@testable import Zigzag

/// Traffic light placement, and that it survives AppKit's title bar relayouts.
@MainActor
struct TrafficLightTests {
    @Test func buttonsSitInARowFromTheOrigin() {
        let origins = NSWindow.trafficLightOrigins(at: NSPoint(x: 12, y: 15), step: 23, buttonHeight: 14, titlebarHeight: 33)
        #expect(origins == [NSPoint(x: 12, y: 4), NSPoint(x: 35, y: 4), NSPoint(x: 58, y: 4)])
    }

    @Test func titleBarLeavesRoomBelowTheButtons() {
        #expect(NSWindow.titlebarHeight(forTrafficLightsAt: NSPoint(x: 12, y: 15), buttonHeight: 14) == 15 + 14 + Tokens.Space.x1)
    }

    /// AppKit resets the buttons on each title bar relayout (title, represented URL, key change); they must be back before the frame draws, or they flash in AppKit's spot for a frame.
    @Test func buttonsAreBackBeforeTheFrameIsDrawn() {
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -6000, y: 200))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        let origin = NSPoint(x: 40, y: 15)
        window.trafficLightOrigin = origin
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        #expect(buttons.count == 3)
        func topLefts() -> [NSPoint] {
            buttons.map { b in
                let r = b.convert(b.bounds, to: nil)
                return NSPoint(x: r.minX, y: (window.contentView?.frame.height ?? 0) - r.maxY)
            }
        }
        let placed = topLefts()
        #expect(placed.first == origin)
        for change in 0..<4 {
            // Each of these triggers a title bar relayout; Zigzag doesn't observe subtitle.
            switch change {
            case 0: window.subtitle = "Moved"
            case 1: window.representedURL = nil
            case 2: window.title = "Another page"
            default: window.subtitle = ""
            }
            window.layoutIfNeeded()
            #expect(topLefts() == placed, "change \(change)")
        }
    }

    /// Every way through full screen ends windowed or full screen, never between, with the title bar each wants (#401).
    @Test func fullScreenPhasesEndSettled() {
        let paths: [([FullScreenPhase.Event], FullScreenPhase)] = [
            ([.willEnter, .didEnter], .fullScreen),
            ([.willEnter, .didFailToEnter], .windowed),
            ([.willEnter, .didEnter, .willExit, .didExit], .windowed),
            ([.willEnter, .didEnter, .willExit, .didFailToExit], .fullScreen),
            // A did with no will before it still lands where it says.
            ([.didEnter], .fullScreen),
            ([.didExit], .windowed),
        ]
        for (events, end) in paths {
            let phase = events.reduce(FullScreenPhase.windowed) { $0.after($1) }
            #expect(phase == end, "\(events)")
            #expect(!phase.isMoving)
        }
        for phase in [FullScreenPhase.windowed, .entering, .fullScreen, .exiting] {
            #expect(phase.titlebarAppearsTransparent, "\(phase)")
        }

        #expect(FullScreenPhase.fullScreen.after(.willExit).dropsTrafficLightBacking)
        for phase in [FullScreenPhase.windowed, .entering, .fullScreen] { #expect(!phase.dropsTrafficLightBacking, "\(phase)") }
    }

    /// The lights get a backing in full screen only when the page, not the bar or sidebar, is under them (#462).
    @Test func backingOnlyWhenNothingOfOursIsUnderTheLights() {
        #expect(BrowserWindowController.needsTrafficLightBacking(fullScreen: true, barShown: false,
                                                                  sidebarVisible: false, sidebarFloating: false))
        #expect(!BrowserWindowController.needsTrafficLightBacking(fullScreen: true, barShown: true,
                                                                   sidebarVisible: false, sidebarFloating: false))
        #expect(!BrowserWindowController.needsTrafficLightBacking(fullScreen: true, barShown: false,
                                                                   sidebarVisible: true, sidebarFloating: false))
        #expect(!BrowserWindowController.needsTrafficLightBacking(fullScreen: true, barShown: false,
                                                                   sidebarVisible: false, sidebarFloating: true))
        #expect(!BrowserWindowController.needsTrafficLightBacking(fullScreen: false, barShown: false,
                                                                   sidebarVisible: false, sidebarFloating: false))
    }

    /// In full screen the lights are in the title bar, not the sidebar: the sidebar keeps no room for them.
    @Test func noRoomForTheLightsInTheSidebarInFullScreen() {
        #expect(BrowserWindowController.trafficLightRoom(fullScreen: true, barKeepsLights: false, width: 60) == 0)
        #expect(BrowserWindowController.trafficLightRoom(fullScreen: false, barKeepsLights: true, width: 60) == 0)
        #expect(BrowserWindowController.trafficLightRoom(fullScreen: false, barKeepsLights: false, width: 60) == 60)
    }

    /// While AppKit moves the title bar into or out of full screen, Zigzag doesn't move or hide the buttons (#401).
    @Test func buttonsAreLeftAloneMidTransition() throws {
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -6000, y: 200))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        let close = try #require(window.standardWindowButton(.closeButton))
        func topLeft() -> NSPoint {
            let r = close.convert(close.bounds, to: nil)
            return NSPoint(x: r.minX, y: (window.contentView?.frame.height ?? 0) - r.maxY)
        }
        window.trafficLightOrigin = NSPoint(x: 40, y: 15)
        #expect(topLeft() == NSPoint(x: 40, y: 15))

        window.fullScreenPhase = .entering
        window.trafficLightOrigin = NSPoint(x: 90, y: 15)
        window.trafficLightsHidden = true
        #expect(topLeft() == NSPoint(x: 40, y: 15))
        #expect(!close.isHidden)

        // Given up: the window lays them out again.
        window.fullScreenPhase = window.fullScreenPhase.after(.didFailToEnter)
        window.layoutTrafficLights()
        window.trafficLightsHidden = true
        #expect(topLeft() == NSPoint(x: 90, y: 15))
        #expect(close.isHidden)
    }
}
