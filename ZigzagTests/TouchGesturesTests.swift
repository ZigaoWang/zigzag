import AppKit
import ObjectiveC
import Testing
import WebKit
@testable import Zigzag

/// Touch support: every recognizer is touch-only, the mouse works as before with them attached, and a finger reaches
/// the hooks a mouse-down does.
@MainActor
struct TouchGesturesTests {
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow? = nil, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// A touch object nothing reads, for the delegate's yes or no. Kept for good: it was never set up to be freed.
    private static var blanks: [AnyObject] = []
    private func blankTouch() -> NSTouch {
        let touch = class_createInstance(NSTouch.self, 0)! as AnyObject
        Self.blanks.append(touch)
        return unsafeBitCast(touch, to: NSTouch.self)
    }

    // MARK: The helper

    @Test func recognizersAreTouchOnly() throws {
        let press = TouchPressRecognizer()
        let pan = TouchPanRecognizer()
        let watch = TouchWatch()
        #expect(press.buttonMask == 0)
        #expect(pan.buttonMask == 0)
        for recognizer in [press, pan, watch] as [NSGestureRecognizer] {
            #expect(recognizer.allowedTouchTypes == .direct)
            #expect(!recognizer.delaysPrimaryMouseButtonEvents)
            #expect(!recognizer.delaysSecondaryMouseButtonEvents)
            #expect(!recognizer.delaysOtherMouseButtonEvents)
            #expect(!recognizer.delaysKeyEvents)
            let delegate = try #require(recognizer.delegate as? TouchOnly)
            for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .leftMouseUp] {
                #expect(delegate.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: mouse(type, at: .zero)) == false)
            }
            #expect(delegate.gestureRecognizer(recognizer, shouldReceive: blankTouch()))
        }
        if #available(macOS 27, *) {
            #expect(press.isCancellableByScrollGesture)
            #expect(watch.isCancellableByScrollGesture)
            #expect(!pan.isCancellableByScrollGesture)
        }
        // The watch never takes a touch from what's under it.
        #expect((watch.delegate as? TouchOnly)?.simultaneous == true)
    }

    @Test func targetsGrowToThirtySixPoints() {
        #expect(TouchGestures.target == 36)
        // An 8-point strip: 36 across, as tall as it is.
        #expect(TouchGestures.box(around: NSRect(x: 100, y: 0, width: 8, height: 400)) == NSRect(x: 86, y: 0, width: 36, height: 400))
        // The row's 20-point ×: 36 each way, on the same middle.
        let close = NSRect(x: 200, y: 6, width: 20, height: 20)
        let box = TouchGestures.box(around: close)
        #expect(box.size == NSSize(width: 36, height: 36))
        #expect(box.midX == close.midX && box.midY == close.midY)
        // Big enough already: unchanged.
        #expect(TouchGestures.box(around: NSRect(x: 0, y: 0, width: 50, height: 40)) == NSRect(x: 0, y: 0, width: 50, height: 40))
    }

    @Test func theNearestStripTakesTheFinger() {
        let frames = [NSRect(x: 100, y: 0, width: 8, height: 400), NSRect(x: 130, y: 0, width: 8, height: 400)]
        #expect(BrowserRootView.touchTarget(frames, at: NSPoint(x: 90, y: 50)) == 0)
        #expect(BrowserRootView.touchTarget(frames, at: NSPoint(x: 118, y: 50)) == 0)
        #expect(BrowserRootView.touchTarget(frames, at: NSPoint(x: 125, y: 50)) == 1)
        #expect(BrowserRootView.touchTarget(frames, at: NSPoint(x: 60, y: 50)) == nil)
        #expect(BrowserRootView.touchTarget(frames, at: NSPoint(x: 104, y: 420)) == nil)
        // A strip drags along its own way only; a corner both.
        #expect(ResizeHandle.touchDrags(NSPoint(x: 12, y: 3), vertical: false, bothWays: false))
        #expect(!ResizeHandle.touchDrags(NSPoint(x: 3, y: 12), vertical: false, bothWays: false))
        #expect(ResizeHandle.touchDrags(NSPoint(x: 3, y: 12), vertical: true, bothWays: false))
        #expect(ResizeHandle.touchDrags(NSPoint(x: 3, y: 12), vertical: false, bothWays: true))
    }

    @Test func aTapIsShortAndStill() {
        #expect(TouchGestures.isTap(from: .zero, to: NSPoint(x: 3, y: 4), duration: 0.2))
        #expect(!TouchGestures.isTap(from: .zero, to: NSPoint(x: 12, y: 0), duration: 0.2))
        #expect(!TouchGestures.isTap(from: .zero, to: .zero, duration: 0.8))
    }

    // MARK: The mouse, unchanged

    @Test func aClickStillClicksAControlWithAHeldFingerMenu() {
        let view = InteractiveView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        view.drawsMenu = true
        var menus = 0, clicks = 0
        view.onRightClick = { _ in menus += 1; return nil }
        view.onClick = { _ in clicks += 1 }
        #expect(view.touchMenuRecognizer != nil)
        view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 50, y: 15)))
        view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 50, y: 15)))
        #expect(clicks == 1)
        view.rightMouseDown(with: mouse(.rightMouseDown, at: NSPoint(x: 50, y: 15)))
        #expect(menus == 1)
        // No menu, no recognizer.
        view.onRightClick = nil
        #expect(view.touchMenuRecognizer == nil)
        let plain = InteractiveView(frame: .zero)
        plain.onRightClick = { _ in nil }
        #expect(plain.touchMenuRecognizer == nil)
    }

    @Test func aHeldFingerOpensTheMenuARightClickOpens() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let view = InteractiveView(frame: NSRect(x: 20, y: 20, width: 200, height: 30))
        window.contentView?.addSubview(view)
        view.drawsMenu = true
        var asked: NSEvent?
        view.onRightClick = { event in
            asked = event
            let menu = NSMenu()
            menu.addItem(withTitle: "One", action: nil, keyEquivalent: "")
            return menu
        }
        #expect(view.touchHeld(at: NSPoint(x: 30, y: 10)))
        let event = try #require(asked)
        #expect(event.type == .rightMouseDown)
        #expect(event.locationInWindow == view.convert(NSPoint(x: 30, y: 10), to: nil))
        #expect(MenuPanel.current?.anchor === view)
        // Once open, not again (AppKit's own right-click from the hold).
        asked = nil
        #expect(!view.touchHeld(at: NSPoint(x: 30, y: 10)))
        #expect(asked == nil)
        MenuPanel.current?.close(animated: false)
    }

    @Test func aRowStillClicksAndDragsWithTheWatchOn() {
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        row.layoutSubtreeIfNeeded()
        #expect(row.gestureRecognizers.contains { $0 is TouchWatch })
        var clicks = 0, closes = 0
        row.onClick = { _ in clicks += 1 }
        row.onClose = { closes += 1 }
        row.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 60, y: 17)))
        row.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 60, y: 17)))
        #expect(clicks == 1 && closes == 0)
        // Next to a showing ×, a mouse click is still the row's.
        row.isSelected = true
        row.layoutSubtreeIfNeeded()
        #expect(!row.closeButton.isHidden)
        let near = NSPoint(x: row.closeButton.frame.minX - 5, y: row.closeButton.frame.midY)
        row.mouseDown(with: mouse(.leftMouseDown, at: near))
        row.mouseUp(with: mouse(.leftMouseUp, at: near))
        #expect(clicks == 2 && closes == 0)
    }

    @Test func aFingerNearTheCloseButtonCloses() {
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        row.isSelected = true
        row.layoutSubtreeIfNeeded()
        var clicks = 0, closes = 0
        row.onClick = { _ in clicks += 1 }
        row.onClose = { closes += 1 }
        let close = row.closeButton.frame
        #expect(row.closeTouchBox.width >= 36 || row.closeTouchBox.maxX == row.bounds.maxX)
        let near = NSPoint(x: close.minX - 6, y: close.midY)
        #expect(row.closeTouchBox.contains(near) && !close.contains(near))
        // The click AppKit makes from the tap is the ×'s.
        row.touchDown(at: near)
        row.mouseDown(with: mouse(.leftMouseDown, at: near))
        row.mouseUp(with: mouse(.leftMouseUp, at: near))
        #expect(closes == 1 && clicks == 0)
        row.touchTapped(at: near)
        #expect(closes == 1)
        // No click came: the tap closes all the same.
        row.touchDown(at: near)
        row.touchTapped(at: near)
        #expect(closes == 2 && clicks == 0)
        // Far from the ×, a finger is the row's.
        row.touchDown(at: NSPoint(x: 40, y: 17))
        row.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 40, y: 17)))
        row.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 40, y: 17)))
        #expect(clicks == 1 && closes == 2)
    }

    @Test func aResizeStripStillDragsByMouse() {
        let handle = ResizeHandle(frame: NSRect(x: 100, y: 0, width: 8, height: 400))
        var began = 0, dragged: [CGFloat] = [], ended = 0
        handle.onBegin = { began += 1 }
        handle.onDrag = { value, _ in dragged.append(value) }
        handle.onEnd = { _ in ended += 1 }
        handle.line = 104
        handle.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 104, y: 50)))
        handle.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 140, y: 50)))
        handle.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 140, y: 50)))
        #expect(began == 1 && ended == 1)
        // A finger does the same.
        handle.touchBegan(at: NSPoint(x: 104, y: 50))
        handle.touchMoved(to: NSPoint(x: 140, y: 50))
        handle.touchEnded()
        #expect(began == 2 && ended == 2)
        #expect(dragged.count == 2 && dragged[0] == dragged[1])
    }

    // MARK: Hidden controls

    @Test func aTapShowsARowsButtonsUntilThePointerOrAFingerElsewhere() {
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        row.layoutSubtreeIfNeeded()
        #expect(row.closeButton.isHidden)
        row.touchReveal(at: NSPoint(x: 60, y: 17))
        #expect(row.touchRevealed && !row.closeButton.isHidden)
        // A finger landing elsewhere puts it away.
        TouchReveal.touchLanded(mouse(.leftMouseDown, at: NSPoint(x: 400, y: 400)))
        #expect(!row.touchRevealed && row.closeButton.isHidden)
        // Inside it, it stays.
        row.touchReveal(at: NSPoint(x: 60, y: 17))
        TouchReveal.touchLanded(mouse(.leftMouseDown, at: NSPoint(x: 30, y: 10)))
        #expect(row.touchRevealed)
        // Another row tapped: the first one's go.
        let other = TabRowView(frame: NSRect(x: 0, y: 34, width: 240, height: 34))
        other.touchReveal(at: NSPoint(x: 60, y: 17))
        #expect(!row.touchRevealed && other.touchRevealed)
        // The pointer moving over it: hover takes over.
        other.mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 60, y: 17), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        #expect(!other.touchRevealed)
        #expect(!TouchReveal.isRevealed(other))
        TouchReveal.finish()
    }

    @Test func theRevealRules() {
        #expect(TouchReveal.keeps(touchInArea: true, sameWindow: true))
        #expect(!TouchReveal.keeps(touchInArea: false, sameWindow: true))
        #expect(!TouchReveal.keeps(touchInArea: true, sameWindow: false))
        var swallow = TouchSwallow()
        var took = swallow.takes(now: 10)
        #expect(!took)
        swallow.arm(now: 10)
        took = swallow.takes(now: 10.2)
        #expect(took)
        took = swallow.takes(now: 10.3)
        #expect(!took)
        swallow.arm(now: 10)
        took = swallow.takes(now: 11.5)
        #expect(!took)
        swallow.arm(now: 10)
        swallow.disarm()
        took = swallow.takes(now: 10.1)
        #expect(!took)
    }

    @Test func aTapAlongTheTopBringsAaBack() {
        let reader = ReaderView(store: .nonPersistent())
        reader.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        reader.layoutSubtreeIfNeeded()
        reader.scrolled(to: 0)
        reader.scrolled(to: 400)
        #expect(!reader.presence.isShown)
        // Low on the page, nothing.
        reader.touchTapped(at: reader.convert(NSPoint(x: 300, y: 600), to: nil))
        #expect(!reader.presence.isShown)
        reader.touchTapped(at: reader.convert(NSPoint(x: 300, y: 10), to: nil))
        #expect(reader.presence.isShown)
    }

    // MARK: The window's hooks

    @Test func aFingerLandingRunsTheMouseDownHooks() throws {
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let page = WKWebView(frame: NSRect(x: 300, y: 0, width: 500, height: 500))
        content.addSubview(page)
        window.contentView = content
        // One watch on the window's frame, title bar included.
        let frame = try #require(content.superview)
        let watch = try #require(frame.gestureRecognizers.compactMap { $0 as? TouchWatch }.first)
        window.contentView = content
        #expect(frame.gestureRecognizers.filter { $0 is TouchWatch }.count == 1)
        var intercepted: [NSEvent] = []
        window.eventInterceptor = { event in intercepted.append(event); return false }
        PopupNotice.forgetInput(in: page)
        var heard: [NSEvent] = []
        let monitor = try #require(TouchPress.addMonitor(matching: [.leftMouseDown, .keyDown]) { event in heard.append(event); return event })
        let point = NSPoint(x: 500, y: 250)
        watch.touchDown(at: point)
        // The window controller's hook (a split's pane focus, ending a rename) gets the mouse-down the finger stands for.
        #expect(intercepted.count == 1)
        #expect(intercepted.first?.type == .leftMouseDown && intercepted.first?.locationInWindow == point)
        // A pop-up the page opens now counts as clicked.
        #expect(PopupNotice.sinceInput(in: page).map { $0 < 1 } == true)
        // Panels that close on a click elsewhere hear it.
        #expect(heard.count == 1 && heard.first?.window === window)
        TouchPress.removeMonitor(monitor)
        watch.touchDown(at: point)
        #expect(heard.count == 1)
        // A finger off the page doesn't count for it.
        PopupNotice.forgetInput(in: page)
        watch.touchDown(at: NSPoint(x: 100, y: 250))
        #expect(PopupNotice.sinceInput(in: page) == nil)
        window.close()
    }

    @Test func aMonitorWithoutMouseDownsIsPlain() throws {
        let monitor = try #require(TouchPress.addMonitor(matching: .keyDown) { $0 })
        #expect(!(monitor is TouchPress.Monitor))
        TouchPress.removeMonitor(monitor)
    }
}
