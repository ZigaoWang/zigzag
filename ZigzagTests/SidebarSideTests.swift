import AppKit
import Testing
@testable import Zigzag

/// Sidebar on the right (#166): every frame is the left layout's mirror image, the page leaves the traffic lights
/// a strip at the window's top left, and the edges that resize and reveal the sidebar are on its side.
@MainActor
struct SidebarSideTests {
    let window = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let width: CGFloat = 240
    let inset = Tokens.Metric.cardInset

    private func mirror(_ rect: NSRect) -> NSRect { BrowserRootView.mirrored(rect, in: window, if: true) }

    @Test func mirroringTurnsAFrameOverTheWindowsMiddle() {
        let rect = NSRect(x: 10, y: 20, width: 100, height: 50)
        #expect(BrowserRootView.mirrored(rect, in: window, if: false) == rect)
        #expect(mirror(rect) == NSRect(x: 1170, y: 20, width: 100, height: 50))
        #expect(mirror(mirror(rect)) == rect)
    }

    @Test func theDockedSidebarRunsDownTheRightEdge() {
        let left = BrowserRootView.sidebarFrame(in: window, width: width, visible: true, revealed: false, onRight: false)
        let right = BrowserRootView.sidebarFrame(in: window, width: width, visible: true, revealed: false, onRight: true)
        #expect(left == NSRect(x: 0, y: 0, width: width, height: 800))
        #expect(right == NSRect(x: 1040, y: 0, width: width, height: 800))
    }

    @Test func hiddenItWaitsPastTheRightEdgeAndSlidesOutAnInsetIn() {
        let hidden = BrowserRootView.sidebarFrame(in: window, width: width, visible: false, revealed: false, onRight: true)
        let revealed = BrowserRootView.sidebarFrame(in: window, width: width, visible: false, revealed: true, onRight: true)
        #expect(hidden.minX > window.maxX)
        #expect(revealed.maxX == window.maxX - inset)
        #expect(revealed.minY == inset && revealed.height == 800 - inset * 2)
    }

    @Test func thePageSitsLeftOfTheSidebarUnderTheLightsStrip() {
        let room = BrowserRootView.lightsStripHeight
        for borderless in [false, true] {
            let left = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: borderless, topBar: false)
            let right = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: borderless, topBar: false,
                                                 onRight: true, lightsRoom: room)
            // The left layout's mirror image, only starting under the strip the traffic lights sit in.
            #expect(right.minX == window.maxX - left.maxX && right.width == left.width)
            #expect(right.maxX == window.maxX - width)
            #expect(right.minY == room && right.maxY == left.maxY)
        }
    }

    @Test func theStripLinesThePageUpWithTheSidebarsAddress() {
        #expect(BrowserRootView.lightsStripHeight == Tokens.Sidebar.addressTop)
        // The lights' center line is well inside it.
        #expect(Tokens.Sidebar.lightsCenter + 7 < BrowserRootView.lightsStripHeight)
    }

    @Test func hiddenOrUnderTheBarThePageIsTheSameOnEitherSide() {
        for edgeToEdge in [false, true] {
            let left = BrowserRootView.pageArea(in: window, sidebarVisible: false, sidebarWidth: width, edgeToEdge: edgeToEdge, borderless: true, topBar: false)
            let right = BrowserRootView.pageArea(in: window, sidebarVisible: false, sidebarWidth: width, edgeToEdge: edgeToEdge, borderless: true, topBar: false, onRight: true)
            #expect(left == right)
        }
        // The bar above the page holds the lights itself: no strip, and the page under the bar as on the left.
        let left = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: true, topBar: true)
        let right = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: true, topBar: true,
                                             onRight: true, lightsRoom: BrowserRootView.lightsStripHeight)
        #expect(right == mirror(left))
    }

    @Test func theBarAboveThePageRunsFromTheWindowsLeftEdgeToTheSidebar() {
        let bar = BrowserRootView.topBarFrame(in: window, sidebarVisible: true, sidebarWidth: width, onRight: true)
        #expect(bar.minX == 0 && bar.maxX == window.maxX - width && bar.height == TopBarView.height)
        let hidden = BrowserRootView.topBarFrame(in: window, sidebarVisible: false, sidebarWidth: width, onRight: true)
        #expect(hidden == BrowserRootView.topBarFrame(in: window, sidebarVisible: false, sidebarWidth: width))
    }

    @Test func theBarsControlsKeepClearOfTheWindowsLeftEdge() {
        let bar = BrowserRootView.topBarFrame(in: window, sidebarVisible: true, sidebarWidth: width, onRight: true)
        let page = BrowserRootView.pageArea(in: window, sidebarVisible: true, sidebarWidth: width, edgeToEdge: false, borderless: true, topBar: true, onRight: true)
        // Borderless, the page meets the window's left edge: the controls start an edge in from it, as they end an
        // edge in from the right one with the sidebar on the left.
        #expect(TopBarView.edgeInset(page: page, window: window) == Tokens.Sidebar.edge)
        let ends = TopBarView.insets(bar: bar, page: page, window: window)
        #expect(ends.leading == Tokens.Sidebar.edge)
    }

    @Test func theResizeHandleIsOnTheSidebarsEdgeByThePage() {
        let handle = Tokens.Metric.resizeHandleWidth
        let left = BrowserRootView.resizeHandleFrame(in: window, sidebarWidth: width, onRight: false)
        let right = BrowserRootView.resizeHandleFrame(in: window, sidebarWidth: width, onRight: true)
        #expect(left.midX == width && left.width == handle)
        #expect(right.midX == window.maxX - width && right.width == handle && right.height == window.height)
    }

    @Test func draggingTheEdgeMeasuresFromTheSidebarsSide() {
        #expect(BrowserRootView.reach(of: 300, in: window, onRight: false) == 300)
        #expect(BrowserRootView.reach(of: 980, in: window, onRight: true) == 300)
    }

    @Test func aHiddenSidebarComesOutAtItsOwnEdge() {
        let middle = window.midY
        #expect(BrowserRootView.isAtRevealEdge(NSPoint(x: 2, y: middle), in: window, onRight: false))
        #expect(!BrowserRootView.isAtRevealEdge(NSPoint(x: 1278, y: middle), in: window, onRight: false))
        #expect(BrowserRootView.isAtRevealEdge(NSPoint(x: 1278, y: middle), in: window, onRight: true))
        #expect(!BrowserRootView.isAtRevealEdge(NSPoint(x: 2, y: middle), in: window, onRight: true))
        #expect(!BrowserRootView.isAtRevealEdge(NSPoint(x: 640, y: middle), in: window, onRight: true))
    }

    @Test func theMiniPlayerFirstGoesToTheCornerAwayFromTheSidebar() {
        #expect(MiniPlayerLayout.firstCorner(sidebarOnRight: false) == .bottomRight)
        #expect(MiniPlayerLayout.firstCorner(sidebarOnRight: true) == .bottomLeft)
    }

    @Test func theSettingIsOffUntilTurnedOn() {
        let key = "sidebarOnRight"
        let saved = UserDefaults.standard.object(forKey: key) as? Bool
        defer {
            // Back as it was, windows included.
            BrowserRootView.sidebarOnRight = saved ?? false
            if saved == nil { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(!BrowserRootView.sidebarOnRight)
        final class Count: @unchecked Sendable { var heard = 0 }
        let count = Count()
        let token = NotificationCenter.default.addObserver(forName: BrowserRootView.sidebarSideChanged, object: nil, queue: nil) { _ in count.heard += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        BrowserRootView.sidebarOnRight = true
        #expect(BrowserRootView.sidebarOnRight && count.heard == 1)
    }
}
