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

extension BrowserRootView {
    /// A finger's tap in the middle of the zone that shows the group with the lights.
    func revealTap() {
        let zone = grabberRevealZone
        fingerLanded(at: NSPoint(x: zone.midX, y: zone.midY))
    }
}
