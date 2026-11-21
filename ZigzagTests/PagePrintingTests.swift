import AppKit
import Testing
import WebKit
@testable import Zigzag

/// A page's own Print button reaches Zigzag: WebKit looks for these (unpublished) delegate methods on the web view's UI
/// delegate, and does nothing with `window.print()` without them.
@MainActor struct PagePrintingTests {
    @Test func aTabAnswersAPagesPrintRequest() {
        #expect(Tab.instancesRespond(to: NSSelectorFromString("_webView:printFrame:pdfFirstPageSize:completionHandler:")))
        #expect(Tab.instancesRespond(to: NSSelectorFromString("_webView:printFrame:")))
    }

    /// Popups answer a page's print() as tabs do (Zigzag Mini and installed apps are tabs).
    @Test func aPopupAnswersAPagesPrintRequest() {
        #expect(PopupWindowController.instancesRespond(to: NSSelectorFromString("_webView:printFrame:pdfFirstPageSize:completionHandler:")))
        #expect(PopupWindowController.instancesRespond(to: NSSelectorFromString("_webView:printFrame:")))
    }

    /// File › Print… (⌘P) reaches every kind of window with a page in front.
    @Test func everyPageWindowTakesPrint() {
        let print = #selector(BrowserWindowController.printPage(_:))
        #expect(BrowserWindowController.instancesRespond(to: print))
        #expect(PopupWindowController.instancesRespond(to: print))
        #expect(MiniWindowController.instancesRespond(to: print))
        #expect(WebAppWindowController.instancesRespond(to: print))
    }

    /// With a popup window in front, Print… is on: the popup takes it and doesn't turn it off.
    @Test func printIsOnWithAPopupInFront() {
        let popup = PopupWindowController.asking(configuration: WKWebViewConfiguration(), features: WKWindowFeatures(), parent: nil, opener: nil)
        defer { popup.discardHeldPage() }
        let item = NSMenuItem(title: "Print…", action: #selector(BrowserWindowController.printPage(_:)), keyEquivalent: "p")
        #expect(popup.window?.delegate === popup)
        #expect(popup.responds(to: item.action!))
        #expect((popup as NSObject as? NSMenuItemValidation)?.validateMenuItem(item) ?? true)
    }

    /// One print sheet per window: asking again while it's up gets nothing until it closes.
    @Test func oneSheetAtATime() {
        let window = NSWindow()
        let id = ObjectIdentifier(window)
        #expect(PagePrinting.claim(id))
        #expect(!PagePrinting.claim(id))
        PagePrinting.release(id)
        #expect(PagePrinting.claim(id))
        PagePrinting.release(id)
    }

    @Test func printingLaysAPageOutAsPrintDoes() {
        let info = PagePrinting.info()
        #expect(info.horizontalPagination == .fit)
        #expect(info.topMargin == 36 && info.leftMargin == 36)
    }

    /// A page's print() in a background tab (its page has no window) never gets a sheet: it's finished at once.
    @Test func aBackgroundTabsPrintFinishesAtOnce() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        #expect(!PagePrinting.isShown(webView, in: nil))
        var finished = false
        PagePrinting.printForPage(webView, frame: nil, in: nil) { finished = true }
        #expect(finished)
    }

    /// A page asking again just after its sheet closed is let be; after the pause it may ask again.
    @Test func printingAgainStraightAwayIsLetBe() {
        let now = Date()
        #expect(PagePrinting.mayPrint(shown: true, lastClosed: nil, now: now))
        #expect(!PagePrinting.mayPrint(shown: false, lastClosed: nil, now: now))
        #expect(!PagePrinting.mayPrint(shown: true, lastClosed: now.addingTimeInterval(-1), now: now))
        #expect(PagePrinting.mayPrint(shown: true, lastClosed: now.addingTimeInterval(-PagePrinting.pause - 0.1), now: now))
    }
}

/// Capture's arithmetic (#457): an area from a drag, its grips and nudges, how an element is taken, the card's
/// picture and the file's name.
struct PageCaptureGeometryTests {
    @MainActor @Test func aClickWithoutADragGivesNoEmptyCursorRect() {
        // A zero-size selection once handed AppKit a null move area, which it throws on, and Zigzag quit.
        for selection in [NSRect(x: 200, y: 150, width: 0, height: 0), NSRect(x: 200, y: 150, width: 6, height: 40)] {
            let rects = CaptureOverlay.cursorRects(for: selection)
            #expect(rects.allSatisfy { !$0.0.isNull && !$0.0.isEmpty && $0.0.width.isFinite })
            #expect(rects.count == 8)
        }
        #expect(CaptureOverlay.cursorRects(for: NSRect(x: 100, y: 100, width: 200, height: 100)).count == 9)
        #expect(CaptureOverlay.cursorRects(for: NSRect(x: CGFloat.nan, y: 0, width: 10, height: 10)).isEmpty)
    }

    let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)

    @Test func aDragMakesAnAreaWithinThePage() {
        #expect(CaptureGeometry.rect(from: NSPoint(x: 300, y: 200), to: NSPoint(x: 100, y: 50), in: bounds) == NSRect(x: 100, y: 50, width: 200, height: 150))
        #expect(CaptureGeometry.rect(from: NSPoint(x: 700, y: 500), to: NSPoint(x: 900, y: 700), in: bounds) == NSRect(x: 700, y: 500, width: 100, height: 100))
        #expect(CaptureGeometry.sizeText(NSSize(width: 640.4, height: 359.6)) == "640 × 360")
    }

    @Test func gripsResizeAndTurnOver() {
        let r = NSRect(x: 100, y: 100, width: 200, height: 100)
        #expect(CaptureGeometry.handles(of: r).count == 8)
        #expect(CaptureGeometry.handles(of: r)[0] == NSPoint(x: 100, y: 100))
        #expect(CaptureGeometry.handles(of: r)[4] == NSPoint(x: 300, y: 200))
        #expect(CaptureGeometry.resized(r, handle: 4, to: NSPoint(x: 400, y: 300), in: bounds) == NSRect(x: 100, y: 100, width: 300, height: 200))
        #expect(CaptureGeometry.resized(r, handle: 1, to: NSPoint(x: 999, y: 50), in: bounds) == NSRect(x: 100, y: 50, width: 200, height: 150))
        // Past the opposite edge it turns over instead of vanishing.
        #expect(CaptureGeometry.resized(r, handle: 7, to: NSPoint(x: 350, y: 0), in: bounds) == NSRect(x: 300, y: 100, width: 50, height: 100))
    }

    @Test func movingKeepsTheSizeAndStopsAtTheEdges() {
        let r = NSRect(x: 100, y: 100, width: 200, height: 100)
        #expect(CaptureGeometry.moved(r, by: NSPoint(x: 10, y: -5), in: bounds) == NSRect(x: 110, y: 95, width: 200, height: 100))
        #expect(CaptureGeometry.moved(r, by: NSPoint(x: 1000, y: 1000), in: bounds) == NSRect(x: 600, y: 500, width: 200, height: 100))
        #expect(CaptureGeometry.moved(r, by: NSPoint(x: -1000, y: -1000), in: bounds) == NSRect(x: 0, y: 0, width: 200, height: 100))
    }

    @Test func anElementIsTakenWholeEvenOffScreen() {
        let screen = NSSize(width: 800, height: 600)
        func route(_ r: NSRect, inner: Bool = false, pinned: Bool = false) -> CaptureGeometry.Route {
            CaptureGeometry.route(css: r, viewport: screen, inner: inner, pinned: pinned)
        }
        #expect(route(NSRect(x: 10, y: 10, width: 300, height: 200)) == .onScreen)
        #expect(route(NSRect(x: 10, y: 900, width: 300, height: 200)) == .scrollIntoView)
        #expect(route(NSRect(x: 10, y: 400, width: 300, height: 400)) == .scrollIntoView)
        #expect(route(NSRect(x: 10, y: 100, width: 700, height: 2000)) == .whole)
        #expect(route(NSRect(x: 10, y: 100, width: 700, height: 2000), inner: true) == .visiblePart)
        #expect(route(NSRect(x: 0, y: 500, width: 800, height: 200), pinned: true) == .visiblePart)
    }

    @Test func picturesFollowZoomOnWholePixels() {
        #expect(CaptureGeometry.viewRect(css: NSRect(x: 8, y: 16, width: 100, height: 40), zoom: 1.25) == NSRect(x: 10, y: 20, width: 125, height: 50))
        #expect(CaptureGeometry.pixelAligned(NSRect(x: 10.3, y: 0.26, width: 100.1, height: 50), scale: 2) == NSRect(x: 10.5, y: 0.5, width: 100, height: 50))
        #expect(CaptureGeometry.pixelAligned(NSRect(x: 10.3, y: 0.26, width: 100.1, height: 50), scale: 1) == NSRect(x: 10, y: 0, width: 100, height: 50))
    }

    @Test func theCardShowsATallPictureFromItsTop() {
        #expect(CaptureGeometry.thumbnailSize(for: NSSize(width: 1000, height: 500), width: 216, maxHeight: 160) == NSSize(width: 216, height: 108))
        #expect(CaptureGeometry.thumbnailSize(for: NSSize(width: 1000, height: 10_000), width: 216, maxHeight: 160) == NSSize(width: 216, height: 160))
        #expect(CaptureGeometry.thumbnailSize(for: NSSize(width: 2000, height: 50), width: 216, maxHeight: 160).height == Tokens.Space.x8)
    }

    @Test func theFileIsNamedAfterThePageAndTheTime() {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 11, 21, 14, 3, 22)
        let date = Calendar.current.date(from: parts)!
        #expect(CaptureGeometry.fileName(title: "Docs: a/b", date: date) == "Docs- a-b 2026-11-21 at 14.03.22.png")
        #expect(CaptureGeometry.fileName(title: "  ", date: date) == "Capture 2026-11-21 at 14.03.22.png")
        let long = CaptureGeometry.fileName(title: String(repeating: "x", count: 200), date: date)
        #expect(long.hasPrefix(String(repeating: "x", count: 80) + " 2026"))
    }
}

@MainActor struct PageCaptureKeysTests {
    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// ⇧⌘2 then ⌘T: the bar takes the typing, so Capture ends; a key Capture has no use for goes on (#457).
    @Test func theCommandBarEndsCaptureAndOtherKeysGoOn() throws {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "http://127.0.0.1:9/capture")!, title: "Capture", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        controller.window?.layoutIfNeeded()
        controller.capture.begin()
        #expect(controller.capture.isActive)
        #expect(!controller.capture.handle(try key("x", code: 7)))
        #expect(!controller.capture.handle(try key("1", code: 18)))
        #expect(!controller.capture.handle(try key("f", code: 3, flags: .command)))
        #expect(controller.capture.isActive)
        controller.commandBarWillShow()
        #expect(!controller.capture.isActive)
        controller.capture.begin()
        #expect(controller.capture.handle(try key("\u{1b}", code: 53)))
        #expect(!controller.capture.isActive)
    }
}
