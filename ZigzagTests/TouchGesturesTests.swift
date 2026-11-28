import AppKit
import JavaScriptCore
import ObjectiveC
import Testing
import WebKit
@testable import Zigzag

/// Touch support: every recognizer is touch-only, the mouse works as before with them attached, and a finger reaches
/// the hooks a mouse-down does.
@MainActor
struct TouchGesturesTests {
    @MainActor @Test func aPageThatFitsDoesntBounceSideways() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        webView.bouncesSidewaysOnlyWhenWide()
        #expect(webView.value(forKey: "_alwaysBounceHorizontal") as? Bool == false)
        #expect(webView.value(forKey: "_alwaysBounceVertical") as? Bool == true)
    }

    @Test func aTouchSwipeGoesAtTheFingersOwnDistance() {
        // The trackpad's distance is scrolled points; fingers on the screen go about 2 cm.
        #expect(SwipeDecision.touchDistance < SwipeDecision.distance(forWidth: 1200))
        func touchGoes(_ progress: CGFloat, _ speed: CGFloat) -> Bool { var a = SwipeArming(); return a.release(progress: progress, touchSpeed: speed) }
        func trackpadGoes(_ progress: CGFloat, _ speed: CGFloat) -> Bool { var a = SwipeArming(); return a.release(progress: progress, speed: speed) }
        #expect(touchGoes(1, 0))
        #expect(!touchGoes(0.5, 200))
        #expect(touchGoes(0.5, 400))
        // The trackpad's flick still needs its own speed.
        #expect(!trackpadGoes(0.5, 400))
    }

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

    @Test func aTapShowsAnOpenFavoritesClose() {
        #expect(FavoriteTile.showsClose(open: true, hovered: true, numbered: false, placeholder: false))
        #expect(!FavoriteTile.showsClose(open: false, hovered: true, numbered: false, placeholder: false))
        #expect(!FavoriteTile.showsClose(open: true, hovered: false, numbered: false, placeholder: false))
        #expect(!FavoriteTile.showsClose(open: true, hovered: true, numbered: true, placeholder: false))
        let tile = FavoriteTile(bookmark: Bookmark(url: URL(string: "https://example.com/")!, title: "E"))
        tile.frame = NSRect(x: 0, y: 0, width: 60, height: Tokens.Sidebar.favoriteHeight)
        tile.touchTapped()
        #expect(tile.touchRevealed && TouchReveal.isRevealed(tile))
        // A finger landing elsewhere puts it away, as for a row.
        TouchReveal.touchLanded(mouse(.leftMouseDown, at: NSPoint(x: 400, y: 400)))
        #expect(!tile.touchRevealed)
        // The pointer coming over it: hover takes over.
        tile.touchTapped()
        tile.mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        #expect(!tile.touchRevealed)
        TouchReveal.finish()
    }

    @Test func aTapShowsClearAboveTheTabs() {
        let separator = SeparatorRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        separator.hasTabs = true
        separator.layoutSubtreeIfNeeded()
        #expect(separator.clearButton.isHidden)
        separator.touchTapped()
        #expect(separator.touchRevealed && !separator.clearButton.isHidden)
        TouchReveal.touchLanded(mouse(.leftMouseDown, at: NSPoint(x: 400, y: 400)))
        #expect(!separator.touchRevealed)
        TouchReveal.finish()
    }

    /// A tap on the mini player toggles its controls, as hovering shows them (#582); a tap on a control that shows
    /// presses it and they stay; the finger lifting off isn't the pointer leaving.
    @Test func aTapTogglesTheMiniPlayersControls() {
        let card = MiniPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        card.layoutSubtreeIfNeeded()
        let empty = NSPoint(x: 40, y: 120)
        #expect(!card.showsControls)
        let now = ProcessInfo.processInfo.systemUptime
        card.touchDown(at: now)
        card.touchTapped(at: empty)
        #expect(card.showsControls && card.touchRevealed)
        card.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: NSPoint(x: 500, y: 500), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        #expect(card.showsControls)
        // A tap on the close or play button that showed: pressed, and the controls stay.
        card.touchDown(at: now + 1)
        card.touchTapped(at: NSPoint(x: 160, y: 90))
        #expect(card.showsControls)
        // Another tap off the controls: they go.
        card.touchDown(at: now + 2)
        card.touchTapped(at: empty)
        #expect(!card.showsControls && !card.touchRevealed)
        // The tap's own click brought them up a moment before: the tap keeps them.
        card.setControls(true, animated: false)
        card.touchDown(at: ProcessInfo.processInfo.systemUptime)
        card.touchTapped(at: empty)
        #expect(card.showsControls)
        // A finger landing elsewhere puts them away.
        TouchReveal.touchLanded(mouse(.leftMouseDown, at: NSPoint(x: 400, y: 400)))
        #expect(!card.showsControls && !card.touchRevealed)
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

/// Touch, phase two: hold and slide through a menu or drag, a finger across the sidebar, pinch for Show All Tabs, and
/// a finger in from a page's edge. The recognizers can't be fed real touches, so their actions are driven directly.
@MainActor
struct TouchMovesTests {
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow? = nil) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func window(height: CGFloat = 700) -> NSWindow {
        MenuPanel.current?.close(animated: false)
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: height), styleMask: [.titled], backing: .buffered, defer: true)
    }

    /// A control near the top of a tall window, so its menu opens below the finger with room to spare.
    private func control(in window: NSWindow, chosen: @escaping (String) -> Void) -> InteractiveView {
        let view = InteractiveView(frame: NSRect(x: 20, y: 600, width: 240, height: 34))
        window.contentView?.addSubview(view)
        view.drawsMenu = true
        view.onRightClick = { _ in
            let menu = NSMenu()
            for title in ["One", "Two", "Three"] { menu.addItem(SidebarMenus.Item(title) { chosen(title) }) }
            return menu
        }
        return view
    }

    private func middle(of view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }

    // MARK: The helper

    @Test func theNewRecognizersAreTouchOnly() throws {
        let pinch = TouchPinchRecognizer()
        let follow = TouchFollow()
        for recognizer in [pinch, follow] as [NSGestureRecognizer] {
            #expect(recognizer.allowedTouchTypes == .direct)
            #expect(!recognizer.delaysPrimaryMouseButtonEvents && !recognizer.delaysMagnificationEvents)
            let delegate = try #require(recognizer.delegate as? TouchOnly)
            for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp] {
                #expect(delegate.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: mouse(type, at: .zero)) == false)
            }
            // Alongside the page's own pinch zoom, and everything under the window's follower.
            #expect(delegate.simultaneous)
        }
        // A list's scrolling waits for a swipe across it to fail only when the swipe says so.
        let pan = TouchPanRecognizer()
        let other = NSPanGestureRecognizer()
        #expect(!pan.touchOnly.gestureRecognizer(pan, shouldBeRequiredToFailBy: other))
        pan.touchOnly.outranks = { $0 === other }
        #expect(pan.touchOnly.gestureRecognizer(pan, shouldBeRequiredToFailBy: other))
        #expect(!pan.touchOnly.gestureRecognizer(pan, shouldBeRequiredToFailBy: NSPanGestureRecognizer()))
    }

    @Test func aDragByTouchGetsAHoldWithoutAMenu() {
        let view = InteractiveView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        view.onDragStart = { _ in true }
        #expect(view.touchMenuRecognizer == nil)
        view.dragsByTouch = true
        #expect(view.touchMenuRecognizer != nil)
        view.onDragStart = nil
        #expect(view.touchMenuRecognizer == nil)
    }

    // MARK: Hold, slide, lift

    @Test func theHoldRules() {
        let start = NSPoint(x: 100, y: 100)
        // Onto the menu: an item lights, however near.
        #expect(TouchHold.step(from: start, to: NSPoint(x: 104, y: 96), onMenu: true, wasOnMenu: false, canDrag: true) == .highlight)
        // Away from it past the distance: picked up.
        #expect(TouchHold.step(from: start, to: NSPoint(x: 100 - TouchHold.dragDistance, y: 100), onMenu: false, wasOnMenu: false, canDrag: true) == .drag)
        // Not that far yet, nothing.
        #expect(TouchHold.step(from: start, to: NSPoint(x: 92, y: 106), onMenu: false, wasOnMenu: false, canDrag: true) == .wait)
        // Off the menu again after being on it: never a drag, as on an iPhone.
        #expect(TouchHold.step(from: start, to: NSPoint(x: 40, y: 160), onMenu: false, wasOnMenu: true, canDrag: true) == .wait)
        // Something that can't be dragged only has its menu.
        #expect(TouchHold.step(from: start, to: NSPoint(x: 40, y: 160), onMenu: false, wasOnMenu: false, canDrag: false) == .wait)
        // Lifting.
        #expect(TouchHold.lift(menuShown: true, onMenu: true, dragging: false) == .choose)
        #expect(TouchHold.lift(menuShown: true, onMenu: false, dragging: false) == .keepOpen)
        #expect(TouchHold.lift(menuShown: false, onMenu: false, dragging: true) == .drop)
        #expect(TouchHold.lift(menuShown: false, onMenu: false, dragging: false) == .nothing)
    }

    @Test func slidingOntoTheMenuAndLiftingChooses() throws {
        let window = window()
        var chosen: [String] = []
        let view = control(in: window) { chosen.append($0) }
        let start = middle(of: view)
        let hold = try #require(view.beginTouchHold(at: start))
        #expect(TouchHold.current === hold)
        // Still for a moment more: the menu opens where the finger is.
        hold.showMenu()
        let menu = try #require(MenuPanel.current)
        #expect(menu.anchor === view && menu.isHeldByTouch)
        #expect(menu.highlightedIndex == nil)
        hold.moved(to: menu.debugItemPoint(0))
        #expect(menu.highlightedIndex == 0)
        hold.moved(to: menu.debugItemPoint(2))
        #expect(menu.highlightedIndex == 2)
        hold.lifted(at: menu.debugItemPoint(2))
        #expect(chosen == ["Three"])
        #expect(MenuPanel.current == nil)
        #expect(TouchHold.current == nil)
        #expect(!view.isPressed)
    }

    @Test func liftingOffTheMenuLeavesItOpen() throws {
        let window = window()
        var chosen: [String] = []
        let view = control(in: window) { chosen.append($0) }
        let start = middle(of: view)
        let hold = try #require(view.beginTouchHold(at: start))
        hold.showMenu()
        let menu = try #require(MenuPanel.current)
        // Onto it, then off and far away: no drag, and lifting there leaves the menu as a menu, to be tapped.
        hold.moved(to: menu.debugItemPoint(1))
        hold.moved(to: NSPoint(x: start.x - 60, y: start.y + 60))
        #expect(menu.highlightedIndex == nil)
        hold.lifted(at: NSPoint(x: start.x - 60, y: start.y + 60))
        #expect(chosen.isEmpty)
        #expect(MenuPanel.current === menu)
        #expect(!menu.isHeldByTouch)
        menu.close(animated: false)
    }

    @Test func heldAndLiftedBeforeTheMenuStillOpensIt() throws {
        let window = window()
        let view = control(in: window) { _ in }
        let start = middle(of: view)
        let hold = try #require(view.beginTouchHold(at: start))
        #expect(MenuPanel.current == nil)
        hold.lifted(at: start)
        let menu = try #require(MenuPanel.current)
        #expect(menu.anchor === view && !menu.isHeldByTouch)
        // The hold's own delayed opening comes to nothing: one menu, where it was.
        hold.showMenu()
        #expect(MenuPanel.current === menu)
        menu.close(animated: false)
    }

    /// The row's drag, as any caller has it: picked up through `onDragStart`, carried by `CarriedCopy.carry`.
    private func draggable(_ view: InteractiveView, in window: NSWindow, starts: @escaping (NSPoint) -> Void,
                           steps: @escaping (NSEvent) -> Void, ended: @escaping (NSEvent?) -> Void) {
        view.onDragStart = { event in
            starts(event.locationInWindow)
            CarriedCopy.carry(in: window, moved: steps, ended: ended)
            return true
        }
        view.dragsByTouch = true
    }

    @Test func movingAwayFromTheMenuPicksItUp() throws {
        let window = window()
        let view = control(in: window) { _ in }
        var starts: [NSPoint] = [], steps: [(NSEvent.EventType, NSPoint)] = [], ends: [NSPoint?] = []
        draggable(view, in: window, starts: { starts.append($0) }, steps: { steps.append(($0.type, $0.locationInWindow)) },
                  ended: { ends.append($0?.locationInWindow) })
        let start = middle(of: view)
        let hold = try #require(view.beginTouchHold(at: start))
        hold.showMenu()
        #expect(MenuPanel.current != nil)
        // The menu opens below and to the right of the finger: up and to the left is away from it.
        hold.moved(to: NSPoint(x: start.x - 8, y: start.y + 8))
        #expect(starts.isEmpty && MenuPanel.current != nil)
        let away = NSPoint(x: start.x - 14, y: start.y + 14)
        hold.moved(to: away)
        // The menu goes and the row is picked up where it was held, the copy straight under the finger.
        #expect(MenuPanel.current == nil)
        #expect(starts == [start])
        #expect(steps.count == 1 && steps.last?.0 == .leftMouseDragged && steps.last?.1 == away)
        #expect(hold.carry != nil)
        hold.moved(to: NSPoint(x: 200, y: 300))
        hold.lifted(at: NSPoint(x: 210, y: 280))
        // Every step, then the release as a mouse-up, then the drop where it was let go.
        #expect(steps.map(\.0) == [.leftMouseDragged, .leftMouseDragged, .leftMouseUp])
        #expect(steps.last?.1 == NSPoint(x: 210, y: 280))
        #expect(ends.count == 1 && ends.first == NSPoint(x: 210, y: 280))
        #expect(TouchHold.current == nil)
    }

    @Test func aHoldThatMovesBeforeTheMenuDragsAndCanBeCalledOff() throws {
        let window = window()
        let view = control(in: window) { _ in }
        var starts = 0, ends: [NSPoint?] = []
        draggable(view, in: window, starts: { _ in starts += 1 }, steps: { _ in }, ended: { ends.append($0?.locationInWindow) })
        let start = middle(of: view)
        let hold = try #require(view.beginTouchHold(at: start))
        hold.moved(to: NSPoint(x: start.x, y: start.y - 30))
        #expect(starts == 1)
        // The menu's moment comes and goes: it never opens over a drag.
        hold.showMenu()
        #expect(MenuPanel.current == nil)
        hold.cancelled()
        #expect(ends.count == 1 && ends[0] == nil)
        #expect(TouchHold.current == nil)
    }

    /// The mouse's loop and a finger feed a drag the same steps, in the same order, and end it the same way.
    @Test func theMouseAndAFingerDriveTheSameDrag() throws {
        let window = window()
        let a = NSPoint(x: 50, y: 60), b = NSPoint(x: 80, y: 120)
        var mouseSteps: [(NSEvent.EventType, NSPoint)] = [], mouseEnd: NSPoint??
        var returned = false
        CarriedCopy.carry(in: window, tracking: { window, moved in
            let up = self.mouse(.leftMouseUp, at: b, window: window)
            for event in [self.mouse(.leftMouseDragged, at: a, window: window), self.mouse(.leftMouseDragged, at: b, window: window), up] { moved(event) }
            return up
        }, moved: { mouseSteps.append(($0.type, $0.locationInWindow)) }, ended: { mouseEnd = .some($0?.locationInWindow) })
        returned = true
        // The mouse's drag is over before `carry` returns, as `track` always had it.
        #expect(returned && mouseEnd == .some(b))

        var fingerSteps: [(NSEvent.EventType, NSPoint)] = [], fingerEnd: NSPoint??
        let finger = TouchCarry()
        TouchCarry.starting = finger
        CarriedCopy.carry(in: window, tracking: { _, _ in Issue.record("the mouse's loop ran for a finger"); return nil },
                          moved: { fingerSteps.append(($0.type, $0.locationInWindow)) }, ended: { fingerEnd = .some($0?.locationInWindow) })
        #expect(TouchCarry.starting == nil && finger.isAttached && fingerEnd == nil)
        finger.move(to: a)
        finger.move(to: b)
        finger.release(at: b)
        #expect(fingerSteps.map(\.0) == mouseSteps.map(\.0))
        #expect(fingerSteps.map(\.1) == mouseSteps.map(\.1))
        #expect(fingerEnd == .some(b))
        // Called off: nil, as Esc gives the mouse's.
        var cancelled: NSPoint?? = nil
        let other = TouchCarry()
        TouchCarry.starting = other
        CarriedCopy.carry(in: window, moved: { _ in }, ended: { cancelled = .some($0?.locationInWindow) })
        other.cancel()
        #expect(cancelled == .some(nil))
    }

    @Test func aFingerCarriesAPinAlongTheField() throws {
        let window = window(height: 200)
        let address = AddressView(frame: NSRect(x: 0, y: 100, width: 224 + AddressView.buttonSide + 2, height: 30))
        window.contentView?.addSubview(address)
        address.setSaved(false, canSave: true)
        address.setPins(["a", "b", "c"].map { AddressView.Pin(id: $0, image: nil, label: $0, badge: "", action: { _ in }, menu: { nil }) }, animated: false)
        var order: [String]?
        address.onPinsReordered = { order = $0 }
        let a = try #require(address.pinButton(for: "a")), c = try #require(address.pinButton(for: "c"))
        let hold = try #require(a.beginTouchHold(at: middle(of: a)))
        hold.moved(to: address.convert(NSPoint(x: c.frame.midX + 9, y: c.frame.midY), to: nil))
        #expect(address.pinDropDestination == 2)
        #expect(a.alphaValue == CarriedCopy.faint)
        hold.lifted(at: address.convert(NSPoint(x: c.frame.midX + 9, y: c.frame.midY), to: nil))
        // What the mouse's drop gives (`droppingAPinReportsTheNewOrder`).
        #expect(order == ["b", "c", "a"])
        #expect(a.alphaValue == 1)
    }

    // MARK: Lift, as on an iPad

    @Test func theLiftRules() {
        let start = NSPoint(x: 100, y: 100)
        #expect(TouchHold.pressDuration >= 0.3 && TouchHold.pressDuration <= 0.35)
        // Lifted with no menu up: a few points picks it up.
        #expect(TouchHold.step(from: start, to: NSPoint(x: 100, y: 100 - TouchHold.pickUpDistance), onMenu: false, wasOnMenu: false,
                               canDrag: true, menuShown: false) == .drag)
        #expect(TouchHold.step(from: start, to: NSPoint(x: 104, y: 104), onMenu: false, wasOnMenu: false, canDrag: true, menuShown: false) == .wait)
        // With the menu up it takes the longer way off it, as before.
        #expect(TouchHold.step(from: start, to: NSPoint(x: 100, y: 100 - TouchHold.pickUpDistance), onMenu: false, wasOnMenu: false,
                               canDrag: true, menuShown: true) == .wait)
        #expect(TouchHold.pickUpDistance >= 6 && TouchHold.pickUpDistance <= 8 && TouchHold.stillSlop < TouchHold.pickUpDistance)
        // Something that drags waits for a still finger before its menu; one with only a menu opens it soon.
        #expect(TouchHold.menuWait(canDrag: true) == TouchHold.stillDelay)
        #expect(TouchHold.menuWait(canDrag: false) == TouchHold.menuDelay)
        #expect(TouchHold.menuOpensOnTime(canDrag: true, moved: 2))
        #expect(!TouchHold.menuOpensOnTime(canDrag: true, moved: TouchHold.stillSlop))
        #expect(TouchHold.menuOpensOnTime(canDrag: false, moved: 40))
    }

    @Test func aDraggableControlLiftsSooner() throws {
        let window = window()
        let view = control(in: window) { _ in }
        let press = try #require(view.touchMenuRecognizer)
        // Only a menu: AppKit's own hold.
        #expect(press.minimumPressDuration == press.standardDuration)
        draggable(view, in: window, starts: { _ in }, steps: { _ in }, ended: { _ in })
        #expect(press.minimumPressDuration == TouchHold.pressDuration)
        #expect(press.allowableMovement >= TouchGestures.tapSlop)
        view.dragsByTouch = false
        #expect(press.minimumPressDuration == press.standardDuration && press.allowableMovement == press.standardMovement)
    }

    @Test func scrollingCantCancelAHoldOnceRecognized() throws {
        guard #available(macOS 27, *) else { return }
        let press = TouchPressRecognizer()
        // Before it's recognized, the list's scrolling takes the finger.
        #expect(press.isCancellableByScrollGesture)
        press.note(.began)
        #expect(press.isHolding && !press.isCancellableByScrollGesture)
        press.reset()
        #expect(!press.isHolding && press.isCancellableByScrollGesture)
    }

    @Test func aHeldRowLiftsAndAMovingFingerKeepsTheMenuAway() throws {
        let window = window()
        let view = control(in: window) { _ in }
        var starts = 0
        draggable(view, in: window, starts: { _ in starts += 1 }, steps: { _ in }, ended: { _ in })
        let start = middle(of: view)
        let hold = try #require(view.beginTouchHold(at: start))
        // Lifted at once.
        #expect(view.isTouchLifted)
        #expect(TouchHold.began(since: ProcessInfo.processInfo.systemUptime - 1))
        // Moving, not yet far enough to pick it up: the menu's moment passes without it.
        hold.moved(to: NSPoint(x: start.x, y: start.y - TouchHold.stillSlop - 0.5))
        if !Tokens.Motion.reduceMotion { #expect(view.touchLiftOffset.height != 0) }
        hold.menuWaitEnded()
        #expect(MenuPanel.current == nil && starts == 0)
        // On a few points more it's picked up, the copy taking over from the lifted row.
        hold.moved(to: NSPoint(x: start.x, y: start.y - TouchHold.pickUpDistance - 1))
        #expect(starts == 1 && hold.carry != nil && !view.isTouchLifted)
        hold.cancelled()
        #expect(TouchHold.current == nil)
    }

    @Test func aStillLiftedRowOpensItsMenu() throws {
        let window = window()
        let view = control(in: window) { _ in }
        draggable(view, in: window, starts: { _ in }, steps: { _ in }, ended: { _ in })
        let start = middle(of: view)
        let hold = try #require(view.beginTouchHold(at: start))
        hold.moved(to: NSPoint(x: start.x + 2, y: start.y))
        hold.menuWaitEnded()
        let menu = try #require(MenuPanel.current)
        #expect(menu.anchor === view)
        hold.lifted(at: NSPoint(x: start.x + 2, y: start.y))
        // Let go: it settles back.
        #expect(!view.isTouchLifted)
        menu.close(animated: false)
    }

    @Test func aLiftedRowFollowsTheFingerTheWayItGoes() throws {
        guard !Tokens.Motion.reduceMotion else { return }
        let window = window()
        let content = try #require(window.contentView)
        content.wantsLayer = true
        let list = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        list.wantsLayer = true
        content.addSubview(list)
        let row = InteractiveView(frame: NSRect(x: 10, y: 40, width: 200, height: 30))
        list.addSubview(row)
        content.layoutSubtreeIfNeeded()
        let start = row.convert(NSPoint(x: 100, y: 15), to: nil)
        row.setTouchLifted(true, animated: false)
        // Ten points down the screen.
        row.followTouchLift(from: start, to: NSPoint(x: start.x, y: start.y - 10))
        let shown = try #require(row.layer?.frame)
        #expect(abs(shown.midY - (row.frame.midY + 10)) < 0.5)
        #expect(abs(shown.midX - row.frame.midX) < 0.5)
        #expect(shown.width > row.frame.width)
        row.setTouchLifted(false, animated: false)
        #expect(row.layer.map { CATransform3DIsIdentity($0.transform) } == true)
    }

    @Test func theListScrollsNearItsEdgesFasterNearer() throws {
        // Within the zone, faster nearer the edge; outside the list, none.
        #expect(TouchAutoscroll.velocity(y: 150, bottom: 0, top: 300) == 0)
        #expect(TouchAutoscroll.velocity(y: 290, bottom: 0, top: 300) > 0)
        #expect(TouchAutoscroll.velocity(y: 298, bottom: 0, top: 300) > TouchAutoscroll.velocity(y: 290, bottom: 0, top: 300))
        #expect(TouchAutoscroll.velocity(y: 5, bottom: 0, top: 300) < 0)
        #expect(TouchAutoscroll.velocity(y: 310, bottom: 0, top: 300) == 0)
        #expect(TouchAutoscroll.speed(inset: 0) == TouchAutoscroll.topSpeed)
        #expect(TouchAutoscroll.speed(inset: TouchAutoscroll.zone) == 0)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scroll.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        // Toward the bottom, then back to the top, and no further.
        #expect(TouchAutoscroll.scroll(scroll, by: -50))
        #expect(abs(scroll.contentView.bounds.minY - 50) < 0.5)
        #expect(TouchAutoscroll.scroll(scroll, by: 100))
        #expect(abs(scroll.contentView.bounds.minY) < 0.5)
        #expect(!TouchAutoscroll.scroll(scroll, by: 10))
    }

    @Test func theMovesAreMeasured() {
        var stats = TouchMoveStats()
        stats.add(age: 0.004, work: 0.001)
        stats.add(age: nil, work: 0.003)
        #expect(stats.count == 2 && stats.aged == 1)
        #expect(stats.summary == "2 moves, age avg 4.0 max 4.0 ms, work avg 2.0 max 3.0 ms")
    }

    // MARK: Across the sidebar

    /// Two taps on a control with a double-click action run it, as two clicks do; a mouse's single clicks don't.
    @Test func twoTapsOnAControlAreADoubleClick() {
        let saved = TouchPress.landedAt
        defer { TouchPress.landedAt = saved }
        let control = InteractiveView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        var doubles = 0
        control.onDoubleClick = { doubles += 1 }
        let point = NSPoint(x: 20, y: 10)
        TouchPress.landedAt = nil
        control.mouseDown(with: mouse(.leftMouseDown, at: point))
        control.mouseDown(with: mouse(.leftMouseDown, at: point))
        #expect(doubles == 0)
        for _ in 0..<2 {
            TouchPress.landedAt = ProcessInfo.processInfo.systemUptime
            control.mouseDown(with: mouse(.leftMouseDown, at: point))
        }
        #expect(doubles == 1)
        TouchPress.landedAt = nil
        control.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
        #expect(doubles == 2)
    }

    /// A hold whose view goes before the finger has moved still ends when the finger lifts.
    @Test func aHoldEndsAfterItsViewHasGone() throws {
        let window = window(height: 200)
        let content = try #require(window.contentView)
        content.addGestureRecognizer(TouchFollow())
        let view = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 30))
        content.addSubview(view)
        let point = middle(of: view)
        let hold = TouchHold.begin(on: view, at: point, openMenu: nil, startDrag: nil)
        #expect(hold.followed && TouchHold.current === hold)
        // The recognizer on the view still hears the finger: the follower's lift is left to it.
        hold.fingerLifted(at: point, in: window)
        #expect(!hold.isFinished)
        view.removeFromSuperview()
        hold.fingerLifted(at: point, in: window)
        #expect(hold.isFinished && TouchHold.current == nil)
    }

    @Test func sidewaysIsMostlySideways() {
        #expect(TouchSwipe.isSideways(NSPoint(x: 12, y: 3)))
        #expect(TouchSwipe.isSideways(NSPoint(x: -12, y: 5)))
        #expect(!TouchSwipe.isSideways(NSPoint(x: 3, y: 12)))
        #expect(!TouchSwipe.isSideways(NSPoint(x: 10, y: 9)))
        #expect(!TouchSwipe.isSideways(NSPoint(x: 2, y: 0)))
    }

    /// The sidebar takes a curved swipe: up to about 55° off level is across, steeper is a scroll.
    @Test func acrossTheSidebarForgivesACurvedSwipe() {
        #expect(TouchSwipe.isAcrossSidebar(NSPoint(x: 10, y: 9)))
        #expect(TouchSwipe.isAcrossSidebar(NSPoint(x: -14, y: 18)))
        #expect(!TouchSwipe.isAcrossSidebar(NSPoint(x: 6, y: 12)))
        #expect(!TouchSwipe.isAcrossSidebar(NSPoint(x: 3, y: 30)))
        #expect(!TouchSwipe.isAcrossSidebar(NSPoint(x: 2, y: 0)))
    }

    /// Two taps on the title bar are a double-click; a mouse's own clicks are left alone.
    @Test func twoTapsOnTheTitleBarAreADoubleClick() {
        #expect(TouchDoubleTap.isFromFinger(10.02, landedAt: 10))
        #expect(!TouchDoubleTap.isFromFinger(10, landedAt: nil))
        #expect(!TouchDoubleTap.isFromFinger(12, landedAt: 10))
        let first = (time: TimeInterval(10), point: NSPoint(x: 100, y: 20))
        #expect(TouchDoubleTap.isSecondTap(after: first, at: 10.3, point: NSPoint(x: 110, y: 24), interval: 0.5))
        #expect(!TouchDoubleTap.isSecondTap(after: first, at: 10.8, point: NSPoint(x: 110, y: 24), interval: 0.5))
        #expect(!TouchDoubleTap.isSecondTap(after: first, at: 10.3, point: NSPoint(x: 200, y: 24), interval: 0.5))
        #expect(!TouchDoubleTap.isSecondTap(after: nil, at: 10.3, point: NSPoint(x: 100, y: 20), interval: 0.5))
    }

    /// The title bar strip's empty space counts for a double tap; the window's own buttons don't.
    @Test func theTitlebarStripsEmptySpaceTakesADoubleTap() throws {
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let close = try #require(window.standardWindowButton(.closeButton))
        let onClose = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        #expect(!window.isOnEmptyTitlebar(onClose))
        #expect(window.isOnEmptyTitlebar(NSPoint(x: 400, y: onClose.y)))
        #expect(!window.isOnEmptyTitlebar(NSPoint(x: 400, y: 300)))
    }

    /// A finger's two taps there are heard on AppKit's title bar, which takes them, and zoom the window once.
    @Test func theTitlebarHearsADoubleTapAndZooms() throws {
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { window.close() }
        window.attachTitlebarDoubleTap()
        let container = try #require(window.standardWindowButton(.closeButton)?.superview?.superview)
        let tap = try #require(window.titlebarDoubleTap)
        #expect(tap.view === container && tap.numberOfClicksRequired == 2 && tap.buttonMask == 0)
        // Again on the same title bar: still one.
        window.attachTitlebarDoubleTap()
        #expect(container.gestureRecognizers.filter { $0 === tap }.count == 1)
        let close = try #require(window.standardWindowButton(.closeButton))
        let onClose = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        let before = TitleBarAction.lastAt
        TitleBarAction.lastAt = 0
        defer { TitleBarAction.lastAt = before }
        window.titlebarDoubleTapped(at: onClose)
        #expect(TitleBarAction.lastAt == 0)
        window.titlebarDoubleTapped(at: NSPoint(x: 400, y: onClose.y))
        let zoomed = TitleBarAction.lastAt
        #expect(zoomed > 0)
        // The window's own watch hearing the same taps doesn't zoom it back.
        window.titlebarDoubleTapped(at: NSPoint(x: 400, y: onClose.y))
        #expect(TitleBarAction.lastAt == zoomed)
    }

    @Test func aFingerAcrossTheSidebarSwitchesSpaces() throws {
        let added = Library.shared.addSpace(name: "Touch swipe test")
        defer { Library.shared.removeSpace(added.id) }
        let spaces = Library.shared.spaces
        let here = try #require(spaces.firstIndex { $0.id == added.id }).advanced(by: -1)
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 700))
        sidebar.currentSpaceID = spaces[here].id
        #expect(sidebar.touchSwipe != nil)
        var switched: [Int] = []
        sidebar.onSwipeSpace = { switched.append($0); return false }
        let now = ProcessInfo.processInfo.systemUptime
        // A short, slow move springs home.
        sidebar.touchSwipeBegan()
        sidebar.touchSwipeMoved(by: -20, at: now)
        sidebar.touchSwipeEnded(velocity: 0, cancelled: false)
        #expect(switched.isEmpty)
        // A flick to the left brings in the next space, as two fingers on the trackpad do.
        sidebar.touchSwipeBegan()
        for step in 0..<4 { sidebar.touchSwipeMoved(by: -15, at: now + 1 + Double(step) * 0.016) }
        sidebar.touchSwipeEnded(velocity: -800, cancelled: false)
        #expect(switched == [1])
        // Far enough, slowly: lands too. Called off: home.
        sidebar.touchSwipeBegan()
        sidebar.touchSwipeMoved(by: -200, at: now + 2)
        sidebar.touchSwipeEnded(velocity: 0, cancelled: true)
        #expect(switched == [1])
    }

    /// A slide added since the screen was last drawn is where it starts; one already drawn, where it is on screen.
    @Test func aSlideNotYetDrawnIsWhereItStarts() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        let layer = CALayer()
        try #require(window.contentView?.layer).addSublayer(layer)
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = CGFloat(-40)
        slide.toValue = CGFloat(0)
        slide.duration = 5
        CATransaction.begin()
        layer.add(slide, forKey: "slide")
        #expect(Tokens.Motion.shownSlide(layer) == -40)
        CATransaction.commit()
        CATransaction.flush()
        // Drawn: it has its start time, and is read from the screen from now on.
        #expect((layer.animation(forKey: "slide")?.beginTime ?? 0) != 0)
        #expect(Tokens.Motion.shownSlide(CALayer()) == nil)
    }

    /// A finger swiping again the moment a swipe was called off picks the list up where it is, mid spring back, so
    /// carrying on the same way past the distance still switches space.
    @Test func aSwipeRightAfterOneCalledOffCarriesOnFromTheList() throws {
        let added = Library.shared.addSpace(name: "Touch swipe again test")
        defer { Library.shared.removeSpace(added.id) }
        let spaces = Library.shared.spaces
        let here = try #require(spaces.firstIndex { $0.id == added.id }).advanced(by: -1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView?.wantsLayer = true
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 700))
        window.contentView?.addSubview(sidebar)
        sidebar.currentSpaceID = spaces[here].id
        var switched: [Int] = []
        sidebar.onSwipeSpace = { switched.append($0); return false }
        let now = ProcessInfo.processInfo.systemUptime
        // Both swipes before the screen is drawn again, as a quick finger does between frames.
        CATransaction.begin()
        defer { CATransaction.commit() }
        sidebar.touchSwipeBegan()
        sidebar.touchSwipeMoved(by: -78, at: now)
        sidebar.touchSwipeEnded(velocity: 0, cancelled: true)
        #expect(switched.isEmpty)
        // From the 78 points it's still out, 52 more is half the sidebar: it switches.
        sidebar.touchSwipeBegan()
        sidebar.touchSwipeMoved(by: -52, at: now + 0.2)
        sidebar.touchSwipeEnded(velocity: 0, cancelled: false)
        #expect(switched == [1])
    }

    // MARK: Deciding

    /// Nothing is decided in the first ten points, where a landing finger jitters; then the angle is the hand's.
    @Test func aTouchSwipeDecidesAfterTenPoints() {
        #expect(TouchSwipe.decision == 10)
        #expect(TouchSwipe.verdict(NSPoint(x: 3, y: 0), forgiving: true) == .undecided)
        #expect(TouchSwipe.verdict(NSPoint(x: 6, y: 7), forgiving: true) == .undecided)
        #expect(TouchSwipe.verdict(NSPoint(x: 10, y: 0), forgiving: true) == .sideways)
        #expect(TouchSwipe.verdict(NSPoint(x: -10, y: 1), forgiving: false) == .sideways)
        // About 50° off level: across the sidebar, not on a page.
        #expect(TouchSwipe.verdict(NSPoint(x: 8, y: 9.5), forgiving: true) == .sideways)
        #expect(TouchSwipe.verdict(NSPoint(x: 8, y: 9.5), forgiving: false) == .other)
        // Steeper than 55°: a scroll either way.
        #expect(TouchSwipe.verdict(NSPoint(x: 6, y: 12), forgiving: true) == .other)
        #expect(TouchSwipe.verdict(NSPoint(x: 0, y: -10), forgiving: true) == .other)
    }

    /// One finger on a page is the page's; two go back or forward unless they pinch; three are left to macOS.
    @Test func fingersOnAPageRouteByCount() {
        let sideways = NSPoint(x: 14, y: 2)
        #expect(!TouchSwipe.goesBackOrForward(fingers: 1, translation: sideways, spread: 0))
        #expect(TouchSwipe.goesBackOrForward(fingers: 2, translation: sideways, spread: 0))
        #expect(TouchSwipe.goesBackOrForward(fingers: 2, translation: NSPoint(x: -14, y: 3), spread: 1))
        #expect(!TouchSwipe.goesBackOrForward(fingers: 2, translation: NSPoint(x: 2, y: 14), spread: 0))
        #expect(!TouchSwipe.goesBackOrForward(fingers: 2, translation: sideways, spread: 10))
        #expect(!TouchSwipe.goesBackOrForward(fingers: 4, translation: sideways, spread: 0))
        #expect(!TouchSwipe.goesBackOrForward(fingers: 2, translation: NSPoint(x: 5, y: 0), spread: 0))
    }

    /// macOS takes three fingers for switching desktops: nothing of ours routes them.
    @Test func threeFingersRouteNowhere() {
        #expect(!TouchSwipe.goesBackOrForward(fingers: 3, translation: NSPoint(x: 30, y: 0), spread: 0))
        #expect(!TouchSwipe.goesBackOrForward(fingers: 3, translation: NSPoint(x: -9, y: 10), spread: 0))
        let holder = PageHolder(holding: BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)))
        #expect(holder.pageSwipe?.maxFingers == 2)
    }

    @Test func aTouchSwipesSpeedIsItsLastMoment() {
        let samples: [(time: TimeInterval, point: NSPoint)] = [(0, .zero), (0.9, NSPoint(x: 10, y: 0)), (0.95, NSPoint(x: 40, y: 0)),
                                                               (1, NSPoint(x: 70, y: 0))]
        #expect(abs(TouchSwipeRecognizer.velocity(samples, at: 1).x - 600) < 1)
        // Resting before lifting: no flick.
        #expect(TouchSwipeRecognizer.velocity(samples, at: 1.5) == .zero)
        #expect(TouchSwipeRecognizer.velocity([], at: 1) == .zero)
    }

    @Test func theSwipesAreTouchOnly() throws {
        let page = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let holder = PageHolder(holding: page)
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 700))
        let root = BrowserRootView(sidebar: SidebarView())
        let swipes = [holder.pageSwipe, sidebar.touchSwipe, root.sidebarPull].compactMap { $0 }
        #expect(swipes.count == 3)
        for swipe in swipes {
            #expect(swipe.allowedTouchTypes == .direct)
            #expect(!swipe.delaysPrimaryMouseButtonEvents && !swipe.delaysKeyEvents)
            let delegate = try #require(swipe.delegate as? TouchOnly)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown] {
                #expect(delegate.gestureRecognizer(swipe, shouldAttemptToRecognizeWith: mouse(type, at: .zero)) == false)
            }
        }
        #expect(holder.pageSwipe?.maxFingers == 2)
        #expect(sidebar.touchSwipe?.maxFingers == 2 && root.sidebarPull?.maxFingers == 1)
    }

    /// A trackpad's scrolls are never taken for a finger's: nothing is following one.
    @Test func theTrackpadsScrollsAreNotClaimed() throws {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -20, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let event = try #require(NSEvent(cgEvent: cg))
        #expect(!TouchSwipeRecognizer.isFollowing)
        #expect(!TouchSwipeRecognizer.claims(event))
    }

    // MARK: On the page

    @Test func twoFingersOnAPageGoBackAndForward() {
        let page = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let holder = PageHolder(holding: page)
        #expect(holder.pageSwipe != nil && holder.overviewPinch != nil)
        // No history and no window: neither way, and the page keeps the fingers.
        #expect(!holder.takesBackForward(dx: 20))
        #expect(!holder.takesBackForward(dx: -20))
        #expect(!page.swipeNavigator.takesTouchSwipe(-1))
        // Decided: the arrow follows the fingers from where they are, and calling it off puts it away.
        holder.touchSwipeBegan(dx: 30)
        #expect(page.swipeNavigator.isTracking)
        holder.touchSwipeMoved(dx: 120)
        holder.touchSwipeEnded(cancelled: true)
        #expect(!page.swipeNavigator.isTracking)
        // Nothing tracking, nothing happens.
        holder.touchSwipeMoved(dx: 200)
        holder.touchSwipeEnded(cancelled: false)
        #expect(!page.swipeNavigator.isTracking)
    }

    /// The swipe sits on the page's holder, an ancestor of the web view where WebKit's recognizers are, so it sees
    /// the page's fingers; WebKit's touch scrolling waits for it, and nothing else of WebKit's does.
    @Test func webKitsTouchScrollingWaitsForTheSwipe() throws {
        let page = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let holder = PageHolder(holding: page)
        let swipe = try #require(holder.pageSwipe)
        #expect(swipe.view === holder && page.isDescendant(of: holder))
        let delegate = try #require(swipe.delegate as? TouchOnly)
        let pan = try #require(page.gestureRecognizers.first { $0 is NSPanGestureRecognizer })
        #expect(holder.isPageScrolling(pan))
        #expect(delegate.gestureRecognizer(swipe, shouldBeRequiredToFailBy: pan))
        for other in page.gestureRecognizers where !(other is NSPanGestureRecognizer) {
            #expect(!delegate.gestureRecognizer(swipe, shouldBeRequiredToFailBy: other))
        }
        // A pan elsewhere (the sidebar's list) doesn't wait on it.
        let elsewhere = NSPanGestureRecognizer()
        NSView().addGestureRecognizer(elsewhere)
        #expect(!delegate.gestureRecognizer(swipe, shouldBeRequiredToFailBy: elsewhere))
        // The swipe never runs alongside the page's scrolling; the pinch does, so the page still zooms.
        #expect(!delegate.gestureRecognizer(swipe, shouldRecognizeSimultaneouslyWith: pan))
        let pinch = try #require(holder.overviewPinch)
        let magnification = try #require(page.gestureRecognizers.first { $0 is NSMagnificationGestureRecognizer })
        #expect(try #require(pinch.delegate as? TouchOnly).gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: magnification))
    }

    /// Fingers that can't be a swipe let WebKit scroll at once: nowhere to go, three of them, or a pinch.
    @Test func fingersThatCantSwipeAreLetGoAtOnce() {
        let out = { (fingers: Int, spread: CGFloat, canGo: Bool) in
            TouchSwipe.ruledOutOnPage(fingers: fingers, spread: spread, moved: 0, sinceLanding: 0, canGoEitherWay: canGo)
        }
        #expect(out(1, 0, false))
        #expect(out(2, 0, false))
        #expect(!out(1, 0, true))
        #expect(!out(2, 4, true))
        #expect(out(2, 10, true))
        #expect(out(2, -12, true))
        #expect(out(3, 0, true))
        // No history and no window here: the holder lets the fingers go as they land.
        let holder = PageHolder(holding: BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)))
        #expect(holder.swipeRuledOut(TouchSwipeRecognizer()))
    }

    /// One finger scrolls the page at once: it's let go within 3 points, or still after 120 ms, while a second
    /// finger landing soon after keeps the swipe possible, and two fingers still take the full 10 points to decide.
    @Test func aLoneFingerIsLetGoAtOnce() {
        let lone = { (fingers: Int, moved: CGFloat, since: TimeInterval) in
            TouchSwipe.ruledOutOnPage(fingers: fingers, spread: 0, moved: moved, sinceLanding: since, canGoEitherWay: true)
        }
        #expect(!lone(1, 0, 0))
        #expect(!lone(1, 2.9, 0.09))
        #expect(lone(1, 3, 0.005))
        #expect(lone(1, 0.5, 0.12))
        // The second finger at 20, 60 or 90 ms: still possible, then as far as two fingers decide.
        for since in [0.02, 0.06, 0.09] { #expect(!lone(2, 0, since)) }
        #expect(!lone(2, 9, 0.2))
        #expect(TouchSwipe.isLoneFinger(fingers: 1, moved: 3, sinceLanding: 0))
        #expect(!TouchSwipe.isLoneFinger(fingers: 2, moved: 30, sinceLanding: 1))
    }

    /// Two fingers on a page as a hand lands them: the first rests with a little jitter, the second lands up to
    /// 100 ms later, then both go at `degrees` off level. Each event runs the rules in the recognizer's order.
    private func pageFingers(secondAfter stagger: TimeInterval, degrees: CGFloat, leftward: Bool = false, fingers: Int = 2,
                             loneMove: NSPoint = .zero) -> (ruledOut: Bool, swipes: Bool) {
        var hand = TouchFingers()
        let ids = [NSNumber(value: 1), NSNumber(value: 2)]
        let starts = [NSPoint(x: 300, y: 300), NSPoint(x: 302, y: 345)]
        let tick = 1.0 / 120, speed: CGFloat = 400
        let angle = degrees * .pi / 180, sign: CGFloat = leftward ? -1 : 1
        func out(_ t: TimeInterval) -> Bool {
            TouchSwipe.ruledOutOnPage(fingers: hand.count, spread: hand.spread, moved: hypot(hand.translation.x, hand.translation.y),
                                      sinceLanding: t, canGoEitherWay: true, sideways: TouchSwipe.startsSideways(hand.translation))
        }
        hand.land(ids[0], at: starts[0])
        if out(0) { return (true, false) }
        var t = 0.0, moving = 0.0
        while t < 0.6 {
            t += tick
            if fingers == 2, hand.count == 1, t >= stagger {
                hand.land(ids[1], at: starts[1])
                if out(t) { return (true, false) }
                continue
            }
            if hand.count == 2 || fingers == 1 {
                moving += tick
                let d = speed * CGFloat(moving)
                for (i, id) in ids.prefix(hand.count).enumerated() {
                    let wobble = CGFloat(i == 0 ? 0.4 : -0.3) * sin(CGFloat(t) * 90)
                    hand.move(id, to: NSPoint(x: starts[i].x + sign * d * cos(angle) + wobble, y: starts[i].y + d * sin(angle) - wobble))
                }
            } else {
                // Resting while it waits for its partner: under a point of jitter, or the drift `loneMove` asks for.
                let jitter = 0.6 * sin(CGFloat(t) * 70)
                let drift = loneMove == .zero ? NSPoint(x: jitter, y: jitter / 3) : loneMove
                hand.move(ids[0], to: NSPoint(x: starts[0].x + drift.x, y: starts[0].y + drift.y))
            }
            if out(t) { return (true, false) }
            // One finger on its way sideways waits for its partner, as PageHolder.swipeWaits says.
            let waits = hand.count == 1 && TouchSwipe.startsSideways(hand.translation)
            if !waits, hypot(hand.translation.x, hand.translation.y) >= TouchSwipe.decision {
                return (false, TouchSwipe.goesBackOrForward(fingers: hand.count, translation: hand.translation, spread: hand.spread))
            }
        }
        return (false, false)
    }

    /// A second finger landing up to 100 ms after the first, and a swipe up to 25° off level either way, still go
    /// back or forward: every one of them.
    @Test func staggeredDriftingTwoFingerSwipesGoBackOrForward() {
        var tried = 0, swiped = 0
        for stagger in stride(from: 0.0, through: 0.1, by: 0.01) {
            for degrees in stride(from: -25.0, through: 25.0, by: 5.0) {
                for leftward in [false, true] {
                    tried += 1
                    if pageFingers(secondAfter: stagger, degrees: CGFloat(degrees), leftward: leftward).swipes { swiped += 1 }
                }
            }
        }
        #expect(swiped * 100 >= tried * 95)
        #expect(swiped == tried)
        for stagger in [0.02, 0.06, 0.09] {
            for degrees: CGFloat in [10, 30, 45] {
                #expect(pageFingers(secondAfter: stagger, degrees: degrees).swipes)
                #expect(pageFingers(secondAfter: stagger, degrees: -degrees, leftward: true).swipes)
            }
        }
    }

    /// Two fingers up and down scroll, however late the second lands; one finger moving 3 points up or down alone is
    /// let go at once, so the page scrolls without waiting.
    @Test func steepFingersAndALoneMovingFingerScroll() {
        for stagger in [0.0, 0.02, 0.06, 0.09] {
            for degrees: CGFloat in [70, 85, -70, -85, 90] {
                let result = pageFingers(secondAfter: stagger, degrees: degrees)
                #expect(!result.ruledOut && !result.swipes)
            }
        }
        #expect(pageFingers(secondAfter: 1, degrees: 0, fingers: 1).ruledOut)
        #expect(pageFingers(secondAfter: 1, degrees: 90, fingers: 1).ruledOut)
        #expect(pageFingers(secondAfter: 0.06, degrees: 0, loneMove: NSPoint(x: 1, y: 3)).ruledOut)
        // Sideways, it waits for its partner instead (#581).
        #expect(!pageFingers(secondAfter: 0.06, degrees: 0, loneMove: NSPoint(x: 3, y: 1)).ruledOut)
        #expect(TouchSwipe.isAcrossPage(NSPoint(x: 10, y: 11.5)))
        #expect(!TouchSwipe.isAcrossPage(NSPoint(x: 10, y: 21.5)))
        #expect(!TouchSwipe.isAcrossPage(NSPoint(x: 5, y: 0)))
        #expect(TouchSwipe.degreesOffLevel(NSPoint(x: -10, y: 10)) == 45)
    }

    /// A hand that lands already moving: the first finger is on its way sideways before the second lands, up to 100 ms
    /// later. It still goes back or forward, rather than being let go as a lone finger that scrolls the page (#581).
    @Test func aSwipeWhoseFirstFingerLandsMovingGoesBackOrForward() {
        for stagger in [0.01, 0.03, 0.06, 0.09] {
            for degrees: CGFloat in [0, 15, -20, 35] {
                var hand = TouchFingers()
                let ids = [NSNumber(value: 1), NSNumber(value: 2)]
                let starts = [NSPoint(x: 300, y: 300), NSPoint(x: 302, y: 345)]
                let angle = degrees * .pi / 180, speed: CGFloat = 500
                var t = 0.0, swipes: Bool?
                hand.land(ids[0], at: starts[0])
                while t < 0.6, swipes == nil {
                    t += 1.0 / 120
                    let d = speed * CGFloat(t)
                    let at = { (i: Int) in NSPoint(x: starts[i].x + d * cos(angle), y: starts[i].y + d * sin(angle)) }
                    if hand.count == 1, t >= stagger { hand.land(ids[1], at: at(1)) }
                    for i in 0..<hand.count { hand.move(ids[i], to: at(i)) }
                    let moved = hypot(hand.translation.x, hand.translation.y)
                    if TouchSwipe.ruledOutOnPage(fingers: hand.count, spread: hand.spread, moved: moved, sinceLanding: t,
                                                 canGoEitherWay: true, sideways: TouchSwipe.startsSideways(hand.translation)) {
                        swipes = false
                    } else if hand.count == 2, moved >= TouchSwipe.decision {
                        swipes = TouchSwipe.goesBackOrForward(fingers: 2, translation: hand.translation, spread: hand.spread)
                    }
                }
                #expect(swipes == true, "second finger \(Int(stagger * 1000)) ms late, \(Int(degrees))°")
            }
        }
        // One finger alone sideways is still the page's, once a partner would have landed.
        #expect(TouchSwipe.ruledOutOnPage(fingers: 1, spread: 0, moved: 30, sinceLanding: 0.12, canGoEitherWay: true, sideways: true))
        // Up and down, at once.
        #expect(TouchSwipe.ruledOutOnPage(fingers: 1, spread: 0, moved: 3, sinceLanding: 0.01, canGoEitherWay: true, sideways: false))
        #expect(TouchSwipe.startsSideways(NSPoint(x: 3, y: 1)) && !TouchSwipe.startsSideways(NSPoint(x: 1, y: 3)))
    }

    /// tabs.md: fingers on a page keep to the axis they start on, as on an iPad. Started mostly sideways, the page
    /// never moves up or down under them, their glide included; started up or down, never sideways; a slant scrolls
    /// freely. Until they've gone far enough to tell, nothing moves (#581).
    @Test func fingersOnAPageKeepToTheAxisTheyStartOn() {
        var lock = TouchScrollLock()
        #expect(lock.step(began: true, dx: 4, dy: 2) == .zero)
        #expect(lock.step(began: false, dx: 8, dy: 3) == NSPoint(x: 8, y: 0))
        #expect(lock.step(began: false, dx: 2, dy: 9) == NSPoint(x: 2, y: 0))
        #expect(lock.step(began: false, dx: 3, dy: -4) == NSPoint(x: 3, y: 0))
        #expect(lock.axis == .sideways)
        // A new gesture decides afresh: up and down keeps to up and down.
        #expect(lock.step(began: true, dx: 1, dy: 12) == NSPoint(x: 0, y: 12))
        #expect(lock.step(began: false, dx: 5, dy: 3) == NSPoint(x: 0, y: 3))
        #expect(lock.axis == .upDown)
        // Between 50° and 65° off level: as the fingers go.
        #expect(lock.step(began: true, dx: 6, dy: 10) == NSPoint(x: 6, y: 10))
        #expect(lock.step(began: false, dx: 5, dy: -3) == NSPoint(x: 5, y: -3))
        #expect(lock.axis == .free)
    }

    /// The lock on a real page: a touch scroll that starts sideways reaches the page with nothing up or down in it; a
    /// trackpad's scroll is left as it is (#581).
    @Test func aTouchScrollThatStartsSidewaysNeverScrollsThePageUpOrDown() throws {
        let saved = (TouchPress.landedAt, TouchPress.fingerDown)
        defer { TouchPress.landedAt = saved.0; TouchPress.fingerDown = saved.1 }
        let page = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let now = ProcessInfo.processInfo.systemUptime
        func scroll(_ phase: Int64, dx: Int32, dy: Int32, momentum: Int64 = 0, at offset: TimeInterval) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
            cg.timestamp = CGEventTimestamp((now + offset) * 1_000_000_000)
            return try #require(NSEvent(cgEvent: cg))
        }
        TouchPress.landedAt = now
        TouchPress.fingerDown = true
        let first = page.touchLocked(try scroll(1, dx: 12, dy: 4, at: 0.01))
        #expect(first.scrollingDeltaY == 0 && first.scrollingDeltaX == 12)
        let drift = page.touchLocked(try scroll(2, dx: 3, dy: 7, at: 0.02))
        #expect(drift.scrollingDeltaY == 0 && drift.scrollingDeltaX == 3)
        TouchPress.fingerDown = false
        let glide = page.touchLocked(try scroll(0, dx: 4, dy: -6, momentum: 2, at: 0.05))
        #expect(glide.scrollingDeltaY == 0 && glide.scrollingDeltaX == 4)
        // The trackpad, long after the finger: untouched.
        TouchPress.landedAt = now - 10
        let trackpad = try scroll(1, dx: 12, dy: 4, at: 0.1)
        #expect(page.touchLocked(trackpad) === trackpad)
        let next = try scroll(2, dx: 3, dy: 7, at: 0.11)
        #expect(page.touchLocked(next) === next)
    }

    /// The fingers' shared travel counts each finger from where it landed, so a late second finger adds no jump.
    @Test func aLateFingerAddsNoJump() {
        var hand = TouchFingers()
        hand.land(NSNumber(value: 1), at: NSPoint(x: 0, y: 0))
        hand.move(NSNumber(value: 1), to: NSPoint(x: 2, y: 0))
        hand.land(NSNumber(value: 2), at: NSPoint(x: 0, y: 50))
        #expect(hand.translation == NSPoint(x: 1, y: 0))
        #expect(abs(hand.spread) < 1)
        hand.move(NSNumber(value: 2), to: NSPoint(x: 12, y: 50))
        hand.move(NSNumber(value: 1), to: NSPoint(x: 14, y: 0))
        #expect(hand.translation == NSPoint(x: 13, y: 0))
    }

    /// Two fingers sideways go back or forward, up and down scroll, a pinch zooms, and a page that keeps the spot
    /// sideways keeps the fingers.
    @Test func twoFingersRouteBySpotAndShape() {
        typealias Room = SwipeDecision.TouchRoom
        let open = Room(left: false, right: false, frame: false, still: false, pansItself: false)
        #expect(TouchSwipe.goesBackOrForward(fingers: 2, translation: NSPoint(x: 14, y: 2), spread: 0))
        #expect(!TouchSwipe.goesBackOrForward(fingers: 2, translation: NSPoint(x: 1, y: -14), spread: 0))
        #expect(!TouchSwipe.goesBackOrForward(fingers: 2, translation: NSPoint(x: 3, y: 1), spread: 12))
        #expect(SwipeDecision.touch(-1, room: open, waited: 0.01) == true)
        #expect(SwipeDecision.touch(1, room: open, waited: 0.01) == true)
        // A carousel with room to the left keeps a swipe back there, not one forward.
        var carousel = open
        carousel.left = true
        #expect(SwipeDecision.touch(-1, room: carousel, waited: 0.01) == false)
        #expect(SwipeDecision.touch(1, room: carousel, waited: 0.01) == true)
        for keeps in [Room(left: false, right: false, frame: true, still: false, pansItself: false),
                      Room(left: false, right: false, frame: false, still: true, pansItself: false),
                      Room(left: false, right: false, frame: false, still: false, pansItself: true)] {
            #expect(SwipeDecision.touch(-1, room: keeps, waited: 0.01) == false)
        }
        // Not answered yet: it waits a moment, then goes on without the answer, as a trackpad swipe does.
        #expect(SwipeDecision.touch(-1, room: nil, waited: 0.01) == nil)
        #expect(SwipeDecision.touch(-1, room: nil, waited: SwipeDecision.frameWait) == true)
    }

    /// The navigator's answer for the fingers comes from what the page said where they landed.
    @Test func thePagesAnswerDecidesTheFingers() {
        let page = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let now = ProcessInfo.processInfo.systemUptime
        page.swipeNavigator.debugSetTouchRoom(nil, landedAt: now)
        #expect(page.swipeNavigator.touchPageLeaves(-1, at: now + 0.01) == nil)
        page.swipeNavigator.debugSetTouchRoom(SwipeDecision.TouchRoom(left: true, right: false, frame: false, still: false, pansItself: false), landedAt: now)
        #expect(page.swipeNavigator.touchPageLeaves(-1, at: now + 0.01) == false)
        #expect(page.swipeNavigator.touchPageLeaves(1, at: now + 0.01) == true)
    }

    /// `touch-action` without sideways panning (a map, a carousel) is the page's own.
    @Test func touchActionTellsWhoPansSideways() throws {
        let context = try #require(JSContext())
        context.evaluateScript("const pansItself = \(SwipeAnswers.pansItself);")
        let check: (String) -> Bool = { actions in
            let script = """
            (() => {
              const list = \(actions);
              let el = null;
              for (let i = list.length - 1; i >= 0; i--) el = { nodeType: 1, touchAction: list[i], parentElement: el };
              return pansItself(el, (e) => ({ touchAction: e.touchAction }));
            })()
            """
            return context.evaluateScript(script)?.toBool() ?? false
        }
        #expect(!check("['auto', 'auto']"))
        #expect(!check("['manipulation', 'auto']"))
        #expect(!check("['pan-x pan-y', 'auto']"))
        #expect(!check("['pan-left', 'auto']"))
        #expect(check("['none', 'auto']"))
        #expect(check("['auto', 'pan-y']"))
        #expect(check("['pinch-zoom', 'auto']"))
        // An engine without the property leaves it to the room.
        #expect(!check("[undefined, '']"))
    }

    // MARK: The hidden sidebar from the edge

    @Test func theEdgeRules() {
        // Hidden: the window's outer 12 points are macOS's, to resize it; from there to 40 in from the page's edge
        // pulls; further in is the page's.
        #expect(TouchSidebarPull.take(atX: 4, pageEdge: 0, revealed: false, held: false, onCard: false) == nil)
        #expect(TouchSidebarPull.take(atX: 11, pageEdge: 8, revealed: false, held: false, onCard: false) == nil)
        #expect(TouchSidebarPull.take(atX: 12, pageEdge: 0, revealed: false, held: false, onCard: false) == .pull)
        #expect(TouchSidebarPull.take(atX: 48, pageEdge: 8, revealed: false, held: false, onCard: false) == .pull)
        #expect(TouchSidebarPull.take(atX: 49, pageEdge: 8, revealed: false, held: false, onCard: false) == nil)
        // Out by touch: off it pushes back; on it is the sidebar's own. Out by the pointer: nothing.
        #expect(TouchSidebarPull.take(atX: 400, pageEdge: 8, revealed: true, held: true, onCard: false) == .push)
        #expect(TouchSidebarPull.take(atX: 100, pageEdge: 8, revealed: true, held: true, onCard: true) == nil)
        #expect(TouchSidebarPull.take(atX: 400, pageEdge: 8, revealed: true, held: false, onCard: false) == nil)
        // Pulling goes away from the edge, pushing toward it, both sideways.
        #expect(TouchSidebarPull.goes(.pull, NSPoint(x: 12, y: 4)))
        #expect(!TouchSidebarPull.goes(.pull, NSPoint(x: -12, y: 4)))
        #expect(!TouchSidebarPull.goes(.pull, NSPoint(x: 3, y: 14)))
        #expect(TouchSidebarPull.goes(.push, NSPoint(x: -12, y: 4)))
        #expect(!TouchSidebarPull.goes(.push, NSPoint(x: 12, y: 0)))
        // One to one, never past hidden, held back past out.
        #expect(TouchSidebarPull.reach(base: 10, travel: 50, hidden: -32, out: 248) == 60)
        #expect(TouchSidebarPull.reach(base: 248, travel: -400, hidden: -32, out: 248) == -32)
        let over = TouchSidebarPull.reach(base: 10, travel: 400, hidden: -32, out: 248)
        #expect(over > 248 && over < 248 + TouchSidebarPull.overshoot)
        // Let go a third of the way out, or flicked out, it stays; pushed a third back in, or flicked in, it goes.
        #expect(!TouchSidebarPull.keeps(reach: 70, out: 248, velocity: 0, wasOut: false))
        #expect(TouchSidebarPull.keeps(reach: 90, out: 248, velocity: 0, wasOut: false))
        #expect(TouchSidebarPull.keeps(reach: 40, out: 248, velocity: 500, wasOut: false))
        #expect(TouchSidebarPull.keeps(reach: 200, out: 248, velocity: 0, wasOut: true))
        #expect(!TouchSidebarPull.keeps(reach: 150, out: 248, velocity: 0, wasOut: true))
        #expect(!TouchSidebarPull.keeps(reach: 240, out: 248, velocity: -500, wasOut: true))
        // A tap sends it back; a scroll or more fingers don't.
        #expect(TouchSidebarPull.isTap(fingers: 1, translation: NSPoint(x: 2, y: 3)))
        #expect(!TouchSidebarPull.isTap(fingers: 1, translation: NSPoint(x: 2, y: 30)))
        #expect(!TouchSidebarPull.isTap(fingers: 3, translation: .zero))
    }

    @Test func aFingerFromTheEdgePullsOutTheSidebar() {
        let root = BrowserRootView(sidebar: SidebarView())
        root.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        root.setSidebarVisible(false, animated: false)
        root.layoutSubtreeIfNeeded()
        let width = root.sidebarWidth, inset = Tokens.Metric.cardInset
        // The card's far edge comes to the finger and follows it.
        root.touchPullBegan(.pull, base: 12)
        root.touchPullMoved(by: 40)
        #expect(root.isPullingSidebar)
        #expect(abs(root.sidebarContainer.frame.maxX - 52) < 0.5)
        // Let go short and slow: back out of sight.
        root.touchPullEnded(velocity: 0, cancelled: false)
        #expect(!root.isPullingSidebar && !root.sidebarRevealed)
        #expect(root.sidebarContainer.frame.maxX <= 0)
        // Past a third: it stays out, held for the finger.
        root.touchPullBegan(.pull, base: 12)
        root.touchPullMoved(by: (width + inset) / 3 + 10)
        root.touchPullEnded(velocity: 0, cancelled: false)
        #expect(root.sidebarRevealed && root.isTouchHeld)
        #expect(root.sidebarContainer.frame.minX == inset)
        // Pushed back a little: it stays; flicked toward the edge: it goes.
        root.touchPullBegan(.push, base: width + inset)
        root.touchPullMoved(by: -30)
        root.touchPullEnded(velocity: 0, cancelled: false)
        #expect(root.sidebarRevealed && root.isTouchHeld)
        #expect(root.sidebarContainer.frame.minX == inset)
        root.touchPullBegan(.push, base: width + inset)
        root.touchPullMoved(by: -20)
        root.touchPullEnded(velocity: -800, cancelled: false)
        #expect(!root.sidebarRevealed && !root.isTouchHeld)
        // A flick out keeps it however short; picking a tab sends it back.
        root.touchPullBegan(.pull, base: 6)
        root.touchPullMoved(by: 20)
        root.touchPullEnded(velocity: 900, cancelled: false)
        #expect(root.sidebarRevealed && root.isTouchHeld)
        root.endTouchHold()
        #expect(!root.sidebarRevealed && !root.isTouchHeld)
        // Showing the sidebar ends any of it.
        root.touchPullBegan(.pull, base: 6)
        root.touchPullEnded(velocity: 900, cancelled: false)
        root.setSidebarVisible(true, animated: false)
        #expect(!root.isTouchHeld && !root.sidebarRevealed)
    }

    @Test func aSidebarOnTheRightComesFromTheRightEdge() {
        let root = BrowserRootView(sidebar: SidebarView())
        root.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        root.setSidebarOnRight(true, animated: false)
        defer { root.setSidebarOnRight(false, animated: false) }
        root.setSidebarVisible(false, animated: false)
        root.layoutSubtreeIfNeeded()
        root.touchPullBegan(.pull, base: 12)
        root.touchPullMoved(by: 40)
        #expect(abs(root.sidebarContainer.frame.minX - (1000 - 52)) < 0.5)
        root.touchPullEnded(velocity: 0, cancelled: true)
        #expect(!root.sidebarRevealed)
    }

    // MARK: The grabber

    private func hiddenRoot(onRight: Bool = false) -> BrowserRootView {
        let root = BrowserRootView(sidebar: SidebarView())
        root.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        if onRight { root.setSidebarOnRight(true, animated: false) }
        root.setSidebarVisible(false, animated: false)
        root.layoutSubtreeIfNeeded()
        return root
    }

    @Test func theGrabberShowsForARecentFinger() {
        let recent = TouchSidebarGrabber.recent
        #expect(TouchSidebarGrabber.shows(sidebarShown: false, touchedAt: 100, pointerMovedAt: nil, now: 200))
        #expect(TouchSidebarGrabber.shows(sidebarShown: false, touchedAt: 100, pointerMovedAt: 50, now: 200))
        #expect(!TouchSidebarGrabber.shows(sidebarShown: false, touchedAt: 100, pointerMovedAt: 150, now: 200))
        #expect(!TouchSidebarGrabber.shows(sidebarShown: false, touchedAt: 100, pointerMovedAt: nil, now: 100 + recent))
        #expect(!TouchSidebarGrabber.shows(sidebarShown: true, touchedAt: 100, pointerMovedAt: nil, now: 200))
        #expect(!TouchSidebarGrabber.shows(sidebarShown: false, touchedAt: nil, pointerMovedAt: nil, now: 200))
        #expect(!TouchSidebarGrabber.shows(sidebarShown: false, barShown: true, touchedAt: 100, pointerMovedAt: nil, now: 200))
        let root = hiddenRoot()
        #expect(!root.isGrabberShown)
        let now = ProcessInfo.processInfo.systemUptime
        // Nothing over the page by default, a finger in use or not.
        root.noteTouch(at: now - 2)
        #expect(!root.isGrabberShown && root.grabber.isHidden)
        root.revealTap()
        #expect(root.isGrabberShown && !root.grabber.isHidden)
        // The mouse or trackpad moving: gone until a finger lands again.
        root.notePointerMoved(at: now - 1)
        #expect(!root.isGrabberShown && !root.isGrabberRevealed)
        root.noteTouch(at: now)
        #expect(!root.isGrabberShown)
        // The sidebar shown: gone. Hidden again with a finger in use: shown a moment as a hint.
        root.revealTap()
        root.setSidebarVisible(true, animated: false)
        #expect(!root.isGrabberShown)
        root.setSidebarVisible(false, animated: false)
        #expect(root.isGrabberShown)
        // The bar above the page has its own toggle: no second one.
        root.showsTopBar = true
        #expect(!root.isGrabberShown)
        root.showsTopBar = false
        #expect(!root.isGrabberShown)
    }

    @Test func aTapWhereTheGroupSitsShowsItAWhile() {
        for onRight in [false, true] {
            let root = hiddenRoot(onRight: onRight)
            root.noteTouch(at: ProcessInfo.processInfo.systemUptime)
            let zone = root.grabberRevealZone
            // From the window's edge on the sidebar's side to past the toggle, along the top.
            let toggle = root.convert(root.grabber.toggleFrame, from: root.grabber)
            #expect(onRight ? zone.maxX == root.bounds.maxX : zone.minX == 0)
            #expect(onRight ? abs(zone.minX - (root.grabber.frame.minX - TouchSidebarGrabber.zonePadding)) < 0.5
                            : abs(zone.maxX - (root.grabber.frame.maxX + TouchSidebarGrabber.zonePadding)) < 0.5)
            #expect(zone.contains(NSPoint(x: toggle.midX, y: toggle.midY)) && zone.height >= TouchSidebarGrabber.zoneHeight)
            #expect(abs((root.isFlipped ? zone.minY : root.bounds.maxY - zone.maxY)) < 0.5)
            // Elsewhere on the page: nothing.
            root.fingerLanded(at: NSPoint(x: 500, y: 350))
            #expect(!root.isGrabberShown)
            // In the zone: it shows, and that tap doesn't press the toggle.
            let point = NSPoint(x: toggle.midX, y: toggle.midY)
            root.fingerLanded(at: point)
            #expect(root.isGrabberRevealed && root.grabberPlace == .lights)
            #expect(!root.grabberTapTakes(point))
            // A second tap on it while shown presses it.
            root.fingerLanded(at: point)
            #expect(root.isGrabberRevealed && root.grabberTapTakes(point))
            // A finger elsewhere: gone at once.
            root.fingerLanded(at: NSPoint(x: 500, y: 350))
            #expect(!root.isGrabberRevealed && root.grabberPlace == nil)
            // Its time up: gone.
            root.fingerLanded(at: point)
            root.concealGrabber()
            #expect(root.grabberPlace == nil)
        }
    }

    @Test func theGroupGoesAfterItsTime() async throws {
        let root = hiddenRoot()
        root.noteTouch(at: ProcessInfo.processInfo.systemUptime)
        root.revealGrabber(for: 0.05)
        #expect(root.isGrabberShown)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!root.isGrabberShown && !root.isGrabberRevealed)
        #expect(TouchSidebarGrabber.revealFor == 3 && TouchSidebarGrabber.hintFor == 2)
    }

    @Test func theGrabbersLandings() {
        #expect(TouchSidebarGrabber.landing(inZone: true, revealed: false, available: true) == .reveal)
        #expect(TouchSidebarGrabber.landing(inZone: true, revealed: true, available: true) == .keep)
        #expect(TouchSidebarGrabber.landing(inZone: false, revealed: true, available: true) == .hide)
        #expect(TouchSidebarGrabber.landing(inZone: false, revealed: false, available: true) == .none)
        #expect(TouchSidebarGrabber.landing(inZone: true, revealed: false, available: false) == .none)
        #expect(TouchSidebarGrabber.landing(inZone: true, revealed: true, available: false) == .hide)
        let group = NSRect(x: 7, y: 6, width: 113, height: 32)
        #expect(TouchSidebarGrabber.revealZone(group: group, width: 1000, onRight: false) == NSRect(x: 0, y: 0, width: 136, height: 52))
        let right = NSRect(x: 880, y: 6, width: 113, height: 32)
        #expect(TouchSidebarGrabber.revealZone(group: right, width: 1000, onRight: true) == NSRect(x: 864, y: 0, width: 136, height: 52))
    }

    /// The docked sidebar's toggle, in the root's coordinates.
    private func dockedToggle(_ controller: BrowserWindowController) -> NSRect {
        let root = controller.root
        root.setSidebarVisible(true, animated: false)
        root.layoutSubtreeIfNeeded()
        controller.layoutTrafficLights()
        root.sidebarContainer.sidebar.layoutSubtreeIfNeeded()
        let button = root.sidebarContainer.sidebar.sidebarButton
        return root.convert(button.bounds, from: button)
    }

    @Test func theGrabberSitsWhereTheSidebarsToggleDoes() throws {
        for onRight in [false, true] {
            let manager = TabManager(spaceID: Library.shared.spaces[0].id)
            defer { manager.invalidate() }
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            defer { controller.window?.close() }
            let root = controller.root
            if onRight { root.setSidebarOnRight(true, animated: false) }
            defer { if onRight { root.setSidebarOnRight(false, animated: false) } }
            root.showsTopBar = false
            let toggle = dockedToggle(controller)
            root.setSidebarVisible(false, animated: false)
            root.layoutSubtreeIfNeeded()
            controller.layoutTrafficLights()
            let window = controller.browserWindow
            #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
            root.noteTouch(at: ProcessInfo.processInfo.systemUptime)
            #expect(root.grabberPlace == nil && window.standardWindowButton(.closeButton)?.isHidden == true)
            root.revealTap()
            #expect(root.isGrabberShown && root.grabberPlace == .lights && root.grabberStrip == nil)
            // Same place, size and symbol as the sidebar's own toggle, in the title bar beside the lights.
            let shown = root.convert(root.grabber.toggleFrame, from: root.grabber)
            #expect(abs(shown.minX - toggle.minX) < 0.5 && abs(shown.minY - toggle.minY) < 0.5)
            #expect(shown.size == toggle.size)
            #expect(root.grabber.button.symbol == SidebarView.toggleSymbol(onRight: onRight))
            // The lights show with it, on its backing: one group, never the toggle alone.
            let close = try #require(window.standardWindowButton(.closeButton)), zoom = try #require(window.standardWindowButton(.zoomButton))
            #expect(!close.isHidden)
            let lights = root.convert(close.convert(close.bounds, to: nil), from: nil).union(root.convert(zoom.convert(zoom.bounds, to: nil), from: nil))
            #expect(root.grabber.frame.contains(lights) && root.grabber.frame.contains(shown))
            // The lights as far in from its leading edge as the toggle's glyph from its trailing one.
            #expect(abs((lights.minX - root.grabber.frame.minX) - (root.grabber.frame.maxX - shown.maxX + (shown.width - Tokens.Sidebar.glyph) / 2)) < 1)
            // A finger's target at least 44 points each way, clear of the lights.
            #expect(root.grabberTarget.width >= 44 && root.grabberTarget.height >= 44)
            #expect(root.grabberTarget.contains(NSPoint(x: shown.midX, y: shown.midY)) && root.grabberTarget.minX >= lights.maxX - 0.5)
            let container = try #require(window.standardWindowButton(.closeButton)?.superview?.superview)
            #expect(container.frame.contains(root.convert(NSPoint(x: shown.midX, y: shown.midY), to: nil)))
            // A finger on it is heard on the title bar, where it lands.
            if TouchGestures.isAvailable { #expect(root.titlebarPull?.view === container) }
            // The pointer moving: the group goes, and the lights with it.
            root.notePointerMoved(at: ProcessInfo.processInfo.systemUptime + 1)
            #expect(root.grabberPlace == nil && close.isHidden)
        }
    }

    @Test func theGrabberJoinsTheTopPanesStrip() throws {
        for onRight in [false, true] {
            let manager = TabManager(spaceID: Library.shared.spaces[0].id)
            defer { manager.invalidate() }
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
            defer { controller.window?.close() }
            let root = controller.root
            if onRight { root.setSidebarOnRight(true, animated: false) }
            defer { if onRight { root.setSidebarOnRight(false, animated: false) } }
            root.showsTopBar = false
            root.setSidebarVisible(false, animated: false)
            let shapes = [TileShape(regions: [.left, .right]), TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])]
            for shape in shapes {
                root.setTiles(shape, animated: false)
                for card in root.paneCards.prefix(shape.regions.count) { card.showsHeader = true }
                root.layoutSubtreeIfNeeded()
                controller.layoutTrafficLights()
                root.noteTouch(at: ProcessInfo.processInfo.systemUptime)
                root.layoutSubtreeIfNeeded()
                // In the top pane's strip on the sidebar's side, as one of its buttons; nothing floats over the page.
                #expect(root.grabberPlace == .strip && root.grabber.isHidden)
                #expect(controller.browserWindow.standardWindowButton(.closeButton)?.isHidden == true)
                let strip = try #require(root.grabberStrip)
                let owner = try #require(root.paneCards.first { $0.header === strip })
                let tops = root.paneCards.prefix(shape.regions.count).filter { abs($0.frame.maxY - owner.frame.maxY) < 0.5 }
                #expect(tops.allSatisfy { onRight ? $0.frame.maxX <= owner.frame.maxX : $0.frame.minX >= owner.frame.minX })
                #expect(root.paneCards.filter { $0.header.showsSidebarButton }.count == 1)
                strip.layoutSubtreeIfNeeded()
                let button = strip.sidebarButton
                #expect(!button.isHidden && button.frame.size == strip.back.frame.size)
                #expect(button.symbol == SidebarView.toggleSymbol(onRight: onRight))
                if onRight {
                    #expect(button.frame.maxX > strip.closeTab.frame.maxX && abs(button.frame.minY - strip.closeTab.frame.minY) < 0.5)
                } else {
                    #expect(abs(button.frame.maxX - strip.back.frame.minX) < 0.5 && abs(button.frame.minY - strip.back.frame.minY) < 0.5)
                }
                // A finger takes it within 44 points, but Back stays Back's.
                let target = TouchSidebarGrabber.target(around: button.frame)
                #expect(target.width >= 44 && target.height >= 44)
                #expect(strip.fingerTakesSidebarButton(at: NSPoint(x: button.frame.midX, y: button.frame.midY)))
                #expect(!strip.fingerTakesSidebarButton(at: NSPoint(x: strip.back.frame.midX, y: strip.back.frame.midY)))
                // A tap shows the sidebar in the window, as the toggle's click does, and the strip gives the button back.
                #expect(button.accessibilityPerformPress())
                #expect(root.sidebarVisible)
                #expect(!root.sidebarRevealed)
                #expect(root.grabberPlace == nil)
                #expect(!strip.showsSidebarButton)
                root.setSidebarVisible(false, animated: false)
            }
            // Out of split view: hidden until a tap where the lights sit shows it with them.
            root.setTiles(nil, animated: false)
            root.card.showsHeader = false
            root.layoutSubtreeIfNeeded()
            root.concealGrabber()
            #expect(root.grabberPlace == nil && root.paneCards.allSatisfy { !$0.header.showsSidebarButton })
            root.revealTap()
            #expect(root.grabberPlace == .lights)
        }
    }

    @Test func theGrabbersPlacesAndTarget() {
        #expect(TouchSidebarGrabber.place(stripOnTop: true) == .strip)
        #expect(TouchSidebarGrabber.place(stripOnTop: false) == .lights)
        // Bottom-up frames: a 2×2 grid, and a split stacked top and bottom.
        let grid = [NSRect(x: 0, y: 350, width: 500, height: 350), NSRect(x: 500, y: 350, width: 500, height: 350),
                    NSRect(x: 0, y: 0, width: 500, height: 350), NSRect(x: 500, y: 0, width: 500, height: 350)]
        #expect(TouchSidebarGrabber.stripPane(grid, onRight: false) == 0)
        #expect(TouchSidebarGrabber.stripPane(grid, onRight: true) == 1)
        let stacked = [NSRect(x: 0, y: 0, width: 1000, height: 350), NSRect(x: 0, y: 350, width: 1000, height: 350)]
        #expect(TouchSidebarGrabber.stripPane(stacked, onRight: false) == 1)
        #expect(TouchSidebarGrabber.stripPane([], onRight: false) == nil)
        let toggle = NSRect(x: 90, y: 9, width: 26, height: 26)
        let target = TouchSidebarGrabber.target(around: toggle)
        #expect(target.width == 44 && target.height == 44 && target.contains(toggle))
        let clear = TouchSidebarGrabber.target(around: toggle, clearOf: 86)
        #expect(clear.minX == 86 && clear.width == 44 && clear.contains(toggle))
        let group = TouchSidebarGrabber.groupFrame(toggle: toggle, lightsMinX: 20)
        #expect(group.minX == 20 - TouchSidebarGrabber.lightsMargin && group.maxX == toggle.maxX + TouchSidebarGrabber.inset)
        #expect(group.height == toggle.height + 2 * TouchSidebarGrabber.inset)
        #expect(TouchSidebarGrabber.groupFrame(toggle: toggle, lightsMinX: nil) == toggle.insetBy(dx: -3, dy: -3))
    }

    @Test func aTapOnTheGrabberBringsTheSidebarOutToStay() {
        let root = hiddenRoot()
        root.noteTouch(at: ProcessInfo.processInfo.systemUptime)
        root.revealTap()
        #expect(root.grabber.button.accessibilityLabel() == String(localized: "Show Sidebar", comment: "Tooltip of the sidebar button while the sidebar is hidden."))
        #expect(root.grabber.button.accessibilityPerformPress())
        // Shown in the window, as the toggle's click does.
        #expect(root.sidebarVisible && !root.sidebarRevealed)
        #expect(!root.isGrabberShown)
        root.setSidebarVisible(false, animated: false)
        #expect(!root.sidebarVisible)
        // Dragged from the grabber, the sidebar follows the finger and keeps the pull's thresholds.
        let width = root.sidebarWidth, inset = Tokens.Metric.cardInset
        root.touchPullBegan(.pull, base: 10)
        #expect(!root.isGrabberShown)
        root.touchPullMoved(by: 40)
        #expect(abs(root.sidebarContainer.frame.maxX - 50) < 0.5)
        root.touchPullEnded(velocity: 0, cancelled: false)
        #expect(!root.sidebarRevealed && root.isGrabberShown)
        root.touchPullBegan(.pull, base: 10)
        root.touchPullMoved(by: (width + inset) / 3 + 10)
        root.touchPullEnded(velocity: 0, cancelled: false)
        #expect(root.sidebarRevealed && root.isTouchHeld)
    }

    @Test func aTapOnTheBarsToggleDocksTheSidebar() {
        let manager = TabManager(spaceID: Library.shared.spaces[0].id)
        defer { manager.invalidate() }
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root
        root.setSidebarVisible(false, animated: false)
        root.noteTouch(at: ProcessInfo.processInfo.systemUptime)
        root.openFromGrabber()
        // The same button as the docked toggle: a tap shows the sidebar in the window, as a click does.
        #expect(root.sidebarVisible && !root.sidebarRevealed && !root.isTouchHeld)
        controller.toggleBrowserSidebar(nil)
        #expect(!root.sidebarVisible)
        controller.toggleBrowserSidebar(nil)
        #expect(root.sidebarVisible)
    }

    /// AppKit's click at `point` (window coordinates), as a finger's tap makes it.
    private func click(at point: NSPoint, in window: NSWindow, time: TimeInterval) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
        }
    }

    @Test func aTapThatOpensTheSidebarDoesNothingElse() {
        let manager = TabManager(spaceID: Library.shared.spaces[0].id)
        defer { manager.invalidate() }
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root, window = controller.browserWindow
        root.showsTopBar = false
        root.setSidebarVisible(false, animated: false)
        root.layoutSubtreeIfNeeded()
        controller.layoutTrafficLights()
        let now = ProcessInfo.processInfo.systemUptime
        root.noteTouch(at: now)
        let landed = TouchPress.landedAt
        TouchPress.landedAt = now
        defer { TouchPress.landedAt = landed }
        let grabbed = root.convert(root.grabber.toggleFrame, from: root.grabber)
        let point = NSPoint(x: grabbed.midX, y: grabbed.midY)
        let inWindow = root.convert(point, to: nil)
        root.grabberTapped(at: point)
        root.layoutSubtreeIfNeeded()
        controller.layoutTrafficLights()
        #expect(root.sidebarVisible)
        // The same tap's click, now over the docked sidebar's own toggle, then the window's tap: both go nowhere.
        click(at: inWindow, in: window, time: now)
        if let event = TouchPress.mouseDown(at: inWindow, in: window) { window.touchTapped(event, downAt: now) }
        #expect(root.sidebarVisible)
        #expect(!controller.commandBar.isVisible)
        // A mouse's click on the toggle a moment later is the toggle's, as always: it hides the sidebar.
        TouchPress.landedAt = nil
        let toggle = root.sidebarContainer.sidebar.sidebarButton
        let onToggle = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: nil)
        click(at: onToggle, in: window, time: ProcessInfo.processInfo.systemUptime)
        #expect(!root.sidebarVisible)
    }

    @Test func theTapThatShowsTheGroupClicksNothing() {
        let manager = TabManager(spaceID: Library.shared.spaces[0].id)
        defer { manager.invalidate() }
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        let root = controller.root, window = controller.browserWindow
        root.showsTopBar = false
        root.setSidebarVisible(false, animated: false)
        root.layoutSubtreeIfNeeded()
        controller.layoutTrafficLights()
        let now = ProcessInfo.processInfo.systemUptime
        root.noteTouch(at: now)
        let landed = TouchPress.landedAt
        TouchPress.landedAt = now
        defer { TouchPress.landedAt = landed }
        let zone = root.grabberRevealZone
        let toggle = root.convert(root.grabber.toggleFrame, from: root.grabber)
        #expect(zone.contains(NSPoint(x: toggle.midX, y: toggle.midY)))
        let point = NSPoint(x: toggle.midX, y: toggle.midY), inWindow = root.convert(point, to: nil)
        root.fingerLanded(at: point)
        controller.layoutTrafficLights()
        #expect(root.grabberPlace == .lights)
        // Its click, now over the toggle, and the window's tap go nowhere.
        click(at: inWindow, in: window, time: now)
        if let event = TouchPress.mouseDown(at: inWindow, in: window) { window.touchTapped(event, downAt: now) }
        #expect(!root.sidebarRevealed && !root.sidebarVisible && root.grabberPlace == .lights)
        root.concealGrabber()
    }

    /// A finger's taps on tab rows, one after another as fast as a hand goes, each select their row.
    @Test func tapsOnTabRowsSelectThem() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = (0..<4).map { Tab(url: URL(string: "https://example.com/tap/\($0)")!, title: "Tap \($0)", spaceID: space) }
        manager.adopt(tabs, in: space)
        manager.select(tabs[0])
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        let window = controller.browserWindow
        controller.sidebar.list.reload(animated: false)
        controller.root.layoutSubtreeIfNeeded()
        let landed = TouchPress.landedAt
        defer { TouchPress.landedAt = landed }
        for tab in [tabs[1], tabs[2], tabs[3], tabs[2], tabs[1]] {
            let row = try #require(controller.sidebar.list.row(for: tab) as? TabRowView)
            let point = row.convert(NSPoint(x: row.bounds.midX - 30, y: row.bounds.midY), to: nil)
            #expect(window.contentView?.superview?.hitTest(point) === row)
            // The finger lands, then AppKit's click from it comes as it lifts.
            TouchPress.landedAt = ProcessInfo.processInfo.systemUptime
            row.mouseDown(with: mouse(.leftMouseDown, at: point, window: window))
            row.mouseUp(with: mouse(.leftMouseUp, at: point, window: window))
            #expect(manager.selectedTab === tab)
            #expect(!row.subviews.contains { $0 is PlainTextField })
        }
        // Two taps on the same row are still its double-click: it renames.
        let row = try #require(controller.sidebar.list.row(for: tabs[0]) as? TabRowView)
        let point = row.convert(NSPoint(x: row.bounds.midX - 30, y: row.bounds.midY), to: nil)
        for _ in 0..<2 {
            TouchPress.landedAt = ProcessInfo.processInfo.systemUptime
            row.mouseDown(with: mouse(.leftMouseDown, at: point, window: window))
            row.mouseUp(with: mouse(.leftMouseUp, at: point, window: window))
        }
        #expect(row.subviews.contains { $0 is PlainTextField })
    }

    @Test func aSpentTouchDropsOnlyItsOwnClick() {
        var swallow = TouchSwallow()
        swallow.arm(at: [NSPoint(x: 20, y: 300)], now: 10)
        let away = swallow.takes(at: NSPoint(x: 400, y: 300), now: 10.1)
        let near = swallow.takes(at: NSPoint(x: 24, y: 296), now: 10.1)
        // Once: the next click there is a click.
        let again = swallow.takes(at: NSPoint(x: 20, y: 300), now: 10.2)
        #expect(!away && near && !again)
        swallow.arm(at: [NSPoint(x: 20, y: 300)], now: 10)
        let late = swallow.takes(at: NSPoint(x: 20, y: 300), now: 11.1)
        #expect(!late)
    }

    /// The bar's sidebar toggle takes a finger anywhere in 36 points around it.
    @Test func theBarsToggleTakesAFingerBesideIt() {
        let toggle = NSRect(x: 80, y: 7, width: 26, height: 26)
        #expect(TopBarView.fingerTakesToggle(at: NSPoint(x: 77, y: 20), toggle: toggle))
        #expect(TopBarView.fingerTakesToggle(at: NSPoint(x: 110, y: 3), toggle: toggle))
        #expect(!TopBarView.fingerTakesToggle(at: NSPoint(x: 70, y: 20), toggle: toggle))
        #expect(!TopBarView.fingerTakesToggle(at: NSPoint(x: 93, y: 40), toggle: toggle))
    }

    @Test func aFingerDraggingThePageIsNotATrackpadSwipe() {
        // A finger down, or one that landed a moment ago: its scroll is the page's.
        #expect(TouchPress.isTouchScroll(at: 10.2, landedAt: 10, fingerDown: false))
        #expect(TouchPress.isTouchScroll(at: 14, landedAt: 10, fingerDown: true))
        // The trackpad, long after any finger: a swipe as before.
        #expect(!TouchPress.isTouchScroll(at: 12, landedAt: 10, fingerDown: false))
        #expect(!TouchPress.isTouchScroll(at: 12, landedAt: nil, fingerDown: false))
        #expect(!TouchPress.isTouchScroll(at: 60, landedAt: 10, fingerDown: true))
        #expect(!TouchPress.isTouchScroll(at: 9, landedAt: 10, fingerDown: true))
    }

    // MARK: Pinch

    @Test func pinchingInAtTheUsualSizeOpensTheOverview() {
        #expect(TouchPinch.opensOverview(magnification: -0.25, startZoom: 1))
        #expect(!TouchPinch.opensOverview(magnification: -0.1, startZoom: 1))
        // Pinching out zooms the page, never the overview.
        #expect(!TouchPinch.opensOverview(magnification: 0.4, startZoom: 1))
        // Zoomed in, pinching in zooms back out.
        #expect(!TouchPinch.opensOverview(magnification: -0.5, startZoom: 1.6))
        #expect(TouchPinch.opensCard(magnification: 0.25))
        #expect(!TouchPinch.opensCard(magnification: 0.1))
        #expect(!TouchPinch.opensCard(magnification: -0.3))
    }

    // MARK: Touch-sized menus

    @Test func aMenuAFingerOpensHasTouchSizedRows() throws {
        let saved = (TouchPress.landedAt, TouchPress.fingerDown)
        defer { TouchPress.landedAt = saved.0; TouchPress.fingerDown = saved.1 }
        TouchPress.landedAt = nil
        TouchPress.fingerDown = false
        let window = window()
        var chosen: [String] = []
        let view = control(in: window) { chosen.append($0) }
        // Opened by the mouse: as it always was.
        #expect(view.showContextMenu())
        let mouseMenu = try #require(MenuPanel.current)
        #expect(!mouseMenu.isTouchSized && mouseMenu.rowHeight == Tokens.Page.controlHeight)
        let titles = mouseMenu.itemTitles, mouseSize = mouseMenu.frame.size
        mouseMenu.close(animated: false)
        // Held by a finger: the same items and width, each row 44 points tall.
        let hold = try #require(view.beginTouchHold(at: middle(of: view)))
        hold.showMenu()
        let menu = try #require(MenuPanel.current)
        #expect(menu.isTouchSized && menu.rowHeight == 44)
        #expect(menu.itemTitles == titles && menu.frame.width == mouseSize.width)
        #expect(menu.frame.height == mouseSize.height + CGFloat(titles.count) * (44 - Tokens.Page.controlHeight))
        // Sliding onto an item and lifting runs it, as before.
        hold.moved(to: menu.debugItemPoint(1))
        #expect(menu.highlightedIndex == 1)
        hold.lifted(at: menu.debugItemPoint(1))
        #expect(chosen == ["Two"])
        #expect(MenuPanel.current == nil)
    }

    @Test func aTappedDropdownOpensItsMenuTouchSized() throws {
        let saved = (TouchPress.landedAt, TouchPress.fingerDown)
        defer { TouchPress.landedAt = saved.0; TouchPress.fingerDown = saved.1 }
        TouchPress.fingerDown = false
        let window = window()
        let dropdown = DropdownButton(frame: NSRect(x: 20, y: 600, width: 160, height: Tokens.Page.controlHeight))
        dropdown.options = ["One", "Two"].map { DropdownButton.Option(title: $0) }
        window.contentView?.addSubview(dropdown)
        let point = middle(of: dropdown)
        // A mouse click: as it always was.
        TouchPress.landedAt = nil
        dropdown.mouseDown(with: mouse(.leftMouseDown, at: point, window: window))
        dropdown.mouseUp(with: mouse(.leftMouseUp, at: point, window: window))
        #expect(MenuPanel.current?.isTouchSized == false)
        MenuPanel.current?.close(animated: false)
        // AppKit's click from a tap: touch-sized.
        TouchPress.landedAt = ProcessInfo.processInfo.systemUptime
        dropdown.mouseDown(with: mouse(.leftMouseDown, at: point, window: window))
        dropdown.mouseUp(with: mouse(.leftMouseUp, at: point, window: window))
        #expect(MenuPanel.current?.isTouchSized == true)
        MenuPanel.current?.close(animated: false)
        // A submenu opens the same size as the menu it's from.
        MenuPanel.openingForTouch = true
        let more = MenuPanel.Item(title: "More", submenu: [.item(MenuPanel.Item(title: "Inside") {})]) {}
        let menu = try #require(MenuPanel.show([.item(more)], from: dropdown))
        MenuPanel.openingForTouch = false
        menu.debugOpenSubmenu("More")
        #expect(menu.isTouchSized && menu.openSubmenu?.isTouchSized == true)
        menu.close(animated: false)
        // A hold, or a click from a finger that just landed; never the keyboard, nor the mouse long after a finger.
        #expect(MenuPanel.opensForTouch(holding: true, eventType: nil, eventTime: 0, landedAt: nil, fingerDown: false))
        #expect(MenuPanel.opensForTouch(holding: false, eventType: .leftMouseDown, eventTime: 10.2, landedAt: 10, fingerDown: false))
        #expect(!MenuPanel.opensForTouch(holding: false, eventType: .keyDown, eventTime: 10.2, landedAt: 10, fingerDown: true))
        #expect(!MenuPanel.opensForTouch(holding: false, eventType: .leftMouseDown, eventTime: 12, landedAt: 10, fingerDown: false))
        #expect(!MenuPanel.opensForTouch(holding: false, eventType: .rightMouseDown, eventTime: 12, landedAt: nil, fingerDown: false))
    }

    // MARK: Touch targets

    /// Back and Forward, 28 points and 4 apart on a plain strip, over a control filling the window under it.
    private func buttonStrip(in window: NSWindow) throws -> (back: IconButton, forward: IconButton) {
        let content = try #require(window.contentView)
        let page = InteractiveView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        page.onClick = { _ in }
        let strip = NSView(frame: NSRect(x: 0, y: 200, width: 500, height: 36))
        let back = IconButton(symbol: "chevron.left"), forward = IconButton(symbol: "chevron.right")
        back.frame = NSRect(x: 20, y: 4, width: 28, height: 28)
        forward.frame = NSRect(x: 52, y: 4, width: 28, height: 28)
        for button in [back, forward] {
            button.onClick = { _ in }
            strip.addSubview(button)
        }
        content.addSubview(page)
        content.addSubview(strip)
        return (back, forward)
    }

    @Test func aFingerBesideASmallControlTakesIt() throws {
        let window = window(height: 300)
        let (back, forward) = try buttonStrip(in: window)
        func taker(_ x: CGFloat, _ y: CGFloat) -> NSView? {
            TouchTargets.point(for: NSPoint(x: x, y: y), in: window).flatMap { TouchTargets.hit(at: $0, in: window) }
        }
        // Back spans 20 to 48 and 204 to 232; a finger takes it 44 points across.
        #expect(taker(13, 218) === back)
        #expect(taker(34, 239) === back)
        #expect(taker(11, 218) == nil)
        // Between the two, the nearer one.
        #expect(taker(49, 218) === back)
        #expect(taker(51, 218) === forward)
        // On a control, it's that control's own.
        #expect(TouchTargets.point(for: NSPoint(x: 34, y: 218), in: window) == nil)
        // On the control under the strip, though in Back's box: that control's.
        #expect(TouchTargets.point(for: NSPoint(x: 34, y: 198), in: window) == nil)
        // Hidden or dimmed: none.
        back.isHidden = true
        #expect(taker(13, 218) == nil)
        back.isHidden = false
        back.isEnabled = false
        #expect(taker(13, 218) == nil)
        // A big control's room is its own.
        #expect(TouchTargets.isSmall(width: 28, height: 28) && !TouchTargets.isSmall(width: 240, height: 34))
    }

    @Test func aFingersClickMovesOntoTheControlAndTheMousesDoesnt() throws {
        let saved = (TouchPress.landedAt, TouchPress.landedPoint)
        defer { TouchPress.landedAt = saved.0; TouchPress.landedPoint = saved.1 }
        let window = window(height: 300)
        let (back, _) = try buttonStrip(in: window)
        var clicks = 0
        back.onClick = { _ in clicks += 1 }
        let beside = NSPoint(x: 13, y: 218), retarget = TouchRetarget()
        // The mouse's click stays where it is.
        TouchPress.landedAt = nil
        #expect(retarget.adjust(mouse(.leftMouseDown, at: beside, window: window), in: window).locationInWindow == beside)
        #expect(retarget.adjust(mouse(.leftMouseUp, at: beside, window: window), in: window).locationInWindow == beside)
        // A finger's: its press and lift land in Back, which is clicked.
        TouchPress.landedAt = ProcessInfo.processInfo.systemUptime
        TouchPress.landedPoint = (beside, window.windowNumber)
        let down = retarget.adjust(mouse(.leftMouseDown, at: beside, window: window), in: window)
        let up = retarget.adjust(mouse(.leftMouseUp, at: NSPoint(x: beside.x + 2, y: beside.y), window: window), in: window)
        let frame = back.convert(back.bounds, to: nil)
        #expect(frame.contains(down.locationInWindow) && frame.contains(up.locationInWindow))
        back.mouseDown(with: down)
        back.mouseUp(with: up)
        #expect(clicks == 1)
        // After its lift, nothing more moves.
        #expect(retarget.adjust(mouse(.leftMouseUp, at: beside, window: window), in: window).locationInWindow == beside)
        // A click far from where the finger landed isn't the finger's.
        TouchPress.landedPoint = (NSPoint(x: 400, y: 100), window.windowNumber)
        #expect(retarget.adjust(mouse(.leftMouseDown, at: beside, window: window), in: window).locationInWindow == beside)
    }

    @Test func aRowsCloseTakesAFingerAcrossATouchTarget() {
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        row.isSelected = true
        row.layoutSubtreeIfNeeded()
        var clicks = 0, closes = 0
        row.onClick = { _ in clicks += 1 }
        row.onClose = { closes += 1 }
        let close = row.closeButton.frame
        #expect(row.closeTouchBox.width >= 44 || row.closeTouchBox.maxX == row.bounds.maxX)
        // Ten points before the ×: the finger's tap closes, the mouse's click there is the row's.
        let near = NSPoint(x: close.minX - 10, y: close.midY)
        #expect(row.closeTouchBox.contains(near))
        row.touchDown(at: near)
        row.mouseDown(with: mouse(.leftMouseDown, at: near))
        row.mouseUp(with: mouse(.leftMouseUp, at: near))
        row.touchTapped(at: near)
        #expect(closes == 1 && clicks == 0)
        row.mouseDown(with: mouse(.leftMouseDown, at: near))
        row.mouseUp(with: mouse(.leftMouseUp, at: near))
        #expect(clicks == 1 && closes == 1)
        TouchReveal.finish()
    }

    // MARK: Picked rows

    @Test func holdingAPickedRowLiftsAndCarriesThemAll() throws {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        let tabs = (0..<3).map { _ in manager.newTab(url: nil, spaceID: space, select: false) }
        defer { tabs.forEach { $0.close() }; manager.invalidate() }
        let host = TouchListHost(manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView?.addSubview(list)
        list.delegate = host
        list.reload(animated: false)
        list.mark(pages: [tabs[0], tabs[2]])
        #expect(list.marked.count == 2)
        let held = try #require(list.tabRow(tabs[0].id) as? InteractiveView)
        let other = try #require(list.tabRow(tabs[2].id) as? InteractiveView)
        let unpicked = try #require(list.tabRow(tabs[1].id) as? InteractiveView)
        let start = held.convert(NSPoint(x: held.bounds.midX, y: held.bounds.midY), to: nil)
        let hold = try #require(held.beginTouchHold(at: start))
        // Both picked rows rise together; the other row stays.
        #expect(held.isTouchLifted && other.isTouchLifted && !unpicked.isTouchLifted)
        // Moved off: picked up together, as the mouse drags them, the carried copy taking over.
        hold.moved(to: NSPoint(x: start.x, y: start.y - 30))
        #expect(list.isDragging && hold.carry != nil)
        #expect(held.alphaValue == CarriedCopy.faint && other.alphaValue == CarriedCopy.faint && unpicked.alphaValue == 1)
        #expect(!held.isTouchLifted && !other.isTouchLifted)
        hold.cancelled()
        #expect(TouchHold.current == nil && !other.isTouchLifted)
        // Not picked: a held row rises alone.
        let lone = try #require(unpicked.beginTouchHold(at: unpicked.convert(NSPoint(x: unpicked.bounds.midX, y: unpicked.bounds.midY), to: nil)))
        #expect(unpicked.isTouchLifted && !held.isTouchLifted && !other.isTouchLifted)
        lone.cancelled()
        #expect(!unpicked.isTouchLifted)
    }

    // MARK: The sidebar's edge

    @Test func aFingerResizesTheSidebarByItsEdge() {
        let root = BrowserRootView(sidebar: SidebarView())
        root.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        root.layoutSubtreeIfNeeded()
        let edge = root.sidebarWidth
        // 22 points either side of the edge, its full height.
        #expect(root.resizeHandle(atTouch: NSPoint(x: edge - 21, y: 350)) === root.resizeHandle)
        #expect(root.resizeHandle(atTouch: NSPoint(x: edge + 21, y: 350)) === root.resizeHandle)
        #expect(root.resizeHandle(atTouch: NSPoint(x: edge, y: 3)) === root.resizeHandle)
        #expect(root.resizeHandle(atTouch: NSPoint(x: edge - 23, y: 350)) == nil)
        #expect(root.resizeHandle(atTouch: NSPoint(x: edge + 23, y: 350)) == nil)
        // On the right, the same about its edge there.
        root.setSidebarOnRight(true, animated: false)
        defer { root.setSidebarOnRight(false, animated: false) }
        root.layoutSubtreeIfNeeded()
        #expect(root.resizeHandle(atTouch: NSPoint(x: 1000 - edge - 21, y: 350)) === root.resizeHandle)
        #expect(root.resizeHandle(atTouch: NSPoint(x: 1000 - edge + 21, y: 350)) === root.resizeHandle)
        #expect(root.resizeHandle(atTouch: NSPoint(x: 1000 - edge + 23, y: 350)) == nil)
        // Sideways it drags; up and down it scrolls past.
        #expect(BrowserRootView.edgePanBegins(NSPoint(x: 12, y: 3), vertical: false, bothWays: false, holding: false))
        #expect(!BrowserRootView.edgePanBegins(NSPoint(x: 3, y: 12), vertical: false, bothWays: false, holding: false))
    }

    @Test func theSidebarsEdgeTakesAFingerFirst() {
        let root = BrowserRootView(sidebar: SidebarView())
        root.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        root.layoutSubtreeIfNeeded()
        let sidebar = root.sidebarContainer.sidebar, edge = root.sidebarWidth
        func switchesSpaces(_ x: CGFloat) -> Bool { sidebar.touchSwipeTakes(at: sidebar.convert(NSPoint(x: x, y: 350), from: root)) }
        // At the edge a finger resizes; further in, sideways switches spaces.
        #expect(!switchesSpaces(edge - 10))
        #expect(switchesSpaces(edge - 30))
        #expect(switchesSpaces(80))
        // A row held there until it lifted drags as a row.
        #expect(!BrowserRootView.edgePanBegins(NSPoint(x: 12, y: 3), vertical: false, bothWays: false, holding: true))
        // The window's outer 12 points stay macOS's, to resize the window.
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 700)
        #expect(BrowserRootView.sidebarEdgeTouchBox(line: 20, frame: NSRect(x: 10, y: 0, width: 14, height: 700), in: bounds).minX == 12)
        #expect(BrowserRootView.sidebarEdgeTouchBox(line: 980, frame: NSRect(x: 976, y: 0, width: 14, height: 700), in: bounds).maxX == 988)
        // Hidden, the edge takes nothing: a finger in from the page's edge pulls the sidebar out.
        root.setSidebarVisible(false, animated: false)
        root.layoutSubtreeIfNeeded()
        #expect(root.resizeHandle(atTouch: NSPoint(x: 20, y: 350)) == nil)
        #expect(TouchSidebarPull.take(atX: 20, pageEdge: 0, revealed: false, held: false, onCard: false) == .pull)
    }

    @Test func aPinchOutsideABrowserWindowDoesNothing() {
        let page = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let holder = PageHolder(holding: page)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = holder
        // A pop-up's page: no overview to open, and the pinch is only the page's.
        holder.touchPinchedIn()
        #expect(window.windowController == nil)
    }
}

/// A list's delegate that does nothing, for driving its rows by touch.
@MainActor
final class TouchListHost: SidebarListDelegate {
    let tabManager: TabManager
    init(_ manager: TabManager) { tabManager = manager }
    func listSelect(_ tab: Tab) {}
    func listOpenBookmark(_ bookmark: Bookmark) {}
    func listRenameBookmark(_ id: UUID, to name: String) {}
    func listClose(_ tab: Tab) {}
    func listClose(_ tabs: [Tab]) {}
    func listRemove(_ items: [SidebarItem]) {}
    func listNewTab() {}
    func listClearTabs() {}
    func listSetFolderOpen(_ id: UUID, _ open: Bool) {}
    func listSetGroupOpen(_ id: UUID, _ open: Bool) {}
    func listRenameGroup(_ id: UUID, to name: String) {}
    func listMoveGroup(_ id: UUID, to index: Int, in spaceID: UUID) {}
    func listPinGroup(_ id: UUID, at index: Int, in spaceID: UUID, folder: UUID?) {}
    func listAddToGroup(_ tabs: [Tab], group: UUID) {}
    func listRenameFolder(_ id: UUID, to name: String) {}
    func listSetFolder(of bookmarkID: UUID, to folderID: UUID?) {}
    func listAsOne(_ name: String, _ body: @escaping () -> Void) { body() }
    func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID, folder: UUID?) {}
    func listMoveFolder(_ id: UUID, to index: Int, in spaceID: UUID, parent: UUID?) {}
    func listHover(_ tab: Tab?, row: NSView?, bookmark: Bookmark?) {}
    func listMenu(for item: SidebarItem) -> NSMenu? { nil }
    func listMenu(forMarked items: [SidebarItem]) -> NSMenu? { nil }
    func listDragHoverSpace(at windowPoint: NSPoint) -> UUID? { nil }
    func listDragEnded() {}
    func listDropFinished() {}
    func listMove(_ tab: Tab, to index: Int, in spaceID: UUID, nesting: TabManager.Nesting, grouping: TabManager.Grouping) {}
    func listBookmark(_ tab: Tab, at index: Int, in spaceID: UUID) {}
    func listUnbookmark(_ bookmarkID: UUID, to index: Int, under parent: UUID?, group: UUID?) {}
    func listSetNestedTabsCollapsed(_ tab: Tab, _ collapsed: Bool) {}
    func listSwitchSpaceDuringDrag(_ spaceID: UUID) {}
    func listDropOutside(_ tabs: [Tab], at screenPoint: NSPoint) -> Bool { false }
    func listMoveToWindow(_ tabs: [Tab], controller: BrowserWindowController, index: Int) -> Bool { false }
    func listMovePinnedToWindow(_ bookmarkID: UUID, controller: BrowserWindowController, at screenPoint: NSPoint) -> NSView? { nil }
    func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID) {}
    func listDragOverFavorites(at windowPoint: NSPoint?, carrying: TabManager.SplitSide?) -> Bool { false }
    func listSplit(_ tab: Tab, with other: Tab, otherOnRight: Bool) {}
    func listJoinSplit(_ page: TabManager.RowPage, onto target: TabManager.RowPage, onRight: Bool) {}
    func listZoomPane(_ tab: Tab) {}
    func listPinSplit(_ tab: Tab, onto bookmarkID: UUID, tabOnRight: Bool) {}
    func listUnpinSplit(_ bookmarkID: UUID, onto tab: Tab, pinnedOnRight: Bool) {}
    func listJoinPinned(_ bookmarkID: UUID, onto targetID: UUID, onRight: Bool) {}
    func listDropOnFavorites(_ items: [SidebarItem], dragged: SidebarItem) -> Bool { false }
    func listFavoriteTile(for bookmarkID: UUID) -> NSView? { nil }
    func listDragOverPage(at windowPoint: NSPoint?, item: SidebarItem) {}
    func listDropOnPage(_ item: SidebarItem) -> Bool { false }
}

extension BrowserRootView {
    /// A finger's tap in the middle of the zone that shows the group with the lights.
    func revealTap() {
        let zone = grabberRevealZone
        fingerLanded(at: NSPoint(x: zone.midX, y: zone.midY))
    }
}
