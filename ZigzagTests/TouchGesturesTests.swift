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

    // MARK: In from the edge

    @Test func theEdgesGoBackAndForward() {
        #expect(TouchEdgeSwipe.direction(atX: 4, width: 800) == -1)
        #expect(TouchEdgeSwipe.direction(atX: TouchEdgeSwipe.edge, width: 800) == -1)
        #expect(TouchEdgeSwipe.direction(atX: 400, width: 800) == nil)
        #expect(TouchEdgeSwipe.direction(atX: 790, width: 800) == 1)
        // Too narrow a page has no edges to swipe from.
        #expect(TouchEdgeSwipe.direction(atX: 4, width: 100) == nil)
        // In from the left goes right; from the right goes left; along the edge is a scroll.
        #expect(TouchEdgeSwipe.isInward(NSPoint(x: 20, y: 2), direction: -1))
        #expect(!TouchEdgeSwipe.isInward(NSPoint(x: -20, y: 2), direction: -1))
        #expect(TouchEdgeSwipe.isInward(NSPoint(x: -20, y: 2), direction: 1))
        #expect(!TouchEdgeSwipe.isInward(NSPoint(x: 3, y: 30), direction: -1))
    }

    @Test func aPageWithNowhereToGoKeepsTheEdgeSwipe() {
        let page = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let holder = PageHolder(holding: page)
        #expect(holder.edgeSwipe != nil && holder.overviewPinch != nil)
        // No history and no window: neither way.
        #expect(!page.swipeNavigator.takesTouchSwipe(-1))
        #expect(!page.swipeNavigator.takesTouchSwipe(1))
        // Nothing tracking, nothing happens.
        page.swipeNavigator.touchMoved(dx: 120, at: 0)
        page.swipeNavigator.touchEnded(at: 0, cancelled: false)
        #expect(!page.swipeNavigator.isTracking)
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
