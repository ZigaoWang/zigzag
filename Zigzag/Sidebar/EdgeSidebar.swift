import AppKit

/// The sidebar's hot screen edge (#363): where the sidebar comes out on a screen, and the edge the pointer meets to
/// bring it. The screen's visible frame stands in for a window's bounds, so the same `SidebarEdgeZone` that decides
/// the window's hidden edge decides the screen's: where the pointer opens the sidebar, keeps it, and has gone past it.
enum EdgeSidebarLayout {
    /// The panel: the visible frame's full height, `width` wide against the screen's edge. Never wider than the screen.
    static func frame(in visible: NSRect, width: CGFloat, onRight: Bool) -> NSRect {
        let width = min(max(width, 0), visible.width)
        return NSRect(x: onRight ? visible.maxX - width : visible.minX, y: visible.minY, width: width, height: visible.height)
    }

    /// The pointer's place among the screen's, top-down from the visible frame's top edge, as `SidebarEdgeZone`
    /// reads it. Over the menu bar it's above the top, and so outside.
    static func point(_ point: NSPoint, in visible: NSRect) -> NSPoint {
        NSPoint(x: point.x - visible.minX, y: visible.maxY - point.y)
    }

    /// The screen-sized edge for a pointer at `point`: the panel where it comes out, and the strip along the
    /// screen's edge that opens it.
    static func zone(in visible: NSRect, width: CGFloat, onRight: Bool) -> SidebarEdgeZone {
        let out = frame(in: visible, width: width, onRight: onRight)
        return SidebarEdgeZone(
            bounds: NSRect(origin: .zero, size: visible.size),
            sidebar: NSRect(x: out.minX - visible.minX, y: 0, width: out.width, height: visible.height),
            onRight: onRight
        )
    }

    /// Which screen a pointer is on: the one whose visible frame holds it, in the order given. None where no visible
    /// frame reaches, as over a menu bar.
    static func screen(containing point: NSPoint, in screens: [NSRect]) -> Int? {
        screens.firstIndex { $0.contains(point) }
    }

    /// The page's share of the screen when it is open in the panel: a portrait third, the visible frame's height.
    static let pageShare: CGFloat = 1.0 / 3.0

    static func pageWidth(in visible: NSRect) -> CGFloat { floor(visible.width * pageShare) }

    /// The panel's width: the sidebar and its gutter, and the side area's width and its gutters when one is open.
    static func width(sidebar: CGFloat, side: CGFloat, inset: CGFloat, in visible: NSRect) -> CGFloat {
        sidebar + inset + (side > 0 ? side + inset * 2 : 0)
    }

    /// The panel's width with the page's third, or with neither: the sidebar and its gutter.
    static func width(sidebar: CGFloat, page: Bool, inset: CGFloat, in visible: NSRect) -> CGFloat {
        width(sidebar: sidebar, side: page ? pageWidth(in: visible) : 0, inset: inset, in: visible)
    }

    /// The sidebar card inside the panel: the sidebar's own width when a side is open, and the panel's whole inner
    /// width when it is not.
    static func cardFrame(in bounds: NSRect, sidebar: CGFloat, inset: CGFloat, sideShowing: Bool, onRight: Bool) -> NSRect {
        let width = sideShowing ? sidebar : max(0, bounds.width - inset)
        return NSRect(x: onRight ? bounds.width - inset - width : inset, y: inset,
                      width: width, height: max(0, bounds.height - inset * 2))
    }

    static func cardFrame(in bounds: NSRect, sidebar: CGFloat, inset: CGFloat, page: Bool, onRight: Bool) -> NSRect {
        cardFrame(in: bounds, sidebar: sidebar, inset: inset, sideShowing: page, onRight: onRight)
    }

    /// The page's or the space editor's place inside the panel: the side area on the inner side of the sidebar card,
    /// the same inset away from the card and the panel's inner edge, and the card's height.
    static func sideFrame(in bounds: NSRect, sidebar: CGFloat, inset: CGFloat, sideShowing: Bool, onRight: Bool) -> NSRect {
        guard sideShowing else { return .zero }
        let card = cardFrame(in: bounds, sidebar: sidebar, inset: inset, sideShowing: true, onRight: onRight)
        let x = onRight ? inset : card.maxX + inset
        let width = onRight ? card.minX - 2 * inset : bounds.width - card.maxX - 2 * inset
        return NSRect(x: x, y: inset, width: max(0, width), height: max(0, bounds.height - inset * 2))
    }

    static func pageFrame(in bounds: NSRect, sidebar: CGFloat, inset: CGFloat, page: Bool, onRight: Bool) -> NSRect {
        sideFrame(in: bounds, sidebar: sidebar, inset: inset, sideShowing: page, onRight: onRight)
    }

    /// Where the page's holder sits in the page area while the panel widens: at the size it will have once the panel
    /// has, pinned to the card's side. The area clips it until it is wide enough, so the live page is laid out once
    /// and revealed, not resized through every frame of the widening.
    static func pageHolderFrame(in area: NSRect, target: NSSize, onRight: Bool) -> NSRect {
        NSRect(x: onRight ? area.width - target.width : 0, y: 0, width: target.width, height: target.height)
    }

    /// The holder's autoresizing mask for that pin: the margin away from the card takes the widening.
    static func pageHolderMask(onRight: Bool) -> NSView.AutoresizingMask {
        onRight ? [.minXMargin] : [.maxXMargin]
    }

    /// Where the page area sits while the panel widens: already at its final width, against the card's side. The panel
    /// window grows over it, uncovering it, instead of resizing it every frame (which would step the live page's edge
    /// and reflow it through the animation).
    static func pageRevealFrame(in bounds: NSRect, sidebar: CGFloat, inset: CGFloat, width pageWidth: CGFloat,
                                onRight: Bool) -> NSRect {
        let card = cardFrame(in: bounds, sidebar: sidebar, inset: inset, sideShowing: true, onRight: onRight)
        let x = onRight ? card.minX - inset - pageWidth : card.maxX + inset
        return NSRect(x: x, y: inset, width: pageWidth, height: max(0, bounds.height - inset * 2))
    }

    /// Whether the panel may come out: whenever Zigzag is not the app in front, and the browser window it mirrors is
    /// not already on this desktop. There its own sidebar is on screen, so the panel would only be a second copy of it.
    /// A minimized, hidden or covered window is not here: the panel is the quick way back to it.
    static func canShow(appIsActive: Bool, browserHere: Bool = false) -> Bool {
        !appIsActive && !browserHere
    }

    /// The panel stays while the page is attached beside it: the popout taking the keyboard is the panel working,
    /// not the browser coming forward.
    static func keepsPanelOnActivation(holdsForPeek: Bool) -> Bool { holdsForPeek }
}

/// What ends the panel's popout, and how a non-activating panel joins another app's Space rather than bringing
/// Zigzag's own Space forward (#363).
enum EdgePopoutPolicy {
    /// A click outside the popout and the panel that opened it puts it away.
    static func closesOnOutsideClick(eventWindow: NSWindow?, mini: NSWindow?, panel: NSWindow?) -> Bool {
        eventWindow !== mini && eventWindow !== panel
    }

    /// Zigzag's own pages (Settings, History, Archive) are not a web site with a field or a dialog to back out of
    /// first: Esc closes the popout at once, as it closes a page in the browser.
    static func closesOnFirstEscape(isInternalPage: Bool, isLeaving: Bool, commandBarVisible: Bool) -> Bool {
        isInternalPage && !isLeaving && !commandBarVisible
    }

    /// ⌘O is the Return button's shortcut. A status-bar panel over another app does not get the main menu's key
    /// equivalents, so the panel reads this one itself.
    static func isReturnKey(command: Bool, key: String?) -> Bool {
        command && key?.lowercased() == "o"
    }

    /// A floating popout is ordered front regardless and made key without activating Zigzag: the way the edge panel
    /// and the Peek join another app's Space, full-screen included. `showWindow`/`makeKeyAndOrderFront` asks the app
    /// to come forward, and its own Space with it.
    static func ordersFrontRegardless(floating: Bool) -> Bool { floating }
}

/// The sidebar's hot screen edge (#363): one switch, and the one panel that comes out of it.
///
/// While the switch is on, every pointer move is read against the screen edge on the sidebar's side. The window's own
/// `SidebarEdgeReveal` decides whether the pointer meant to bring the sidebar out, and the panel shows a live second
/// `SidebarView` belonging to the last browser window in front. Nothing in that window is moved, hidden or frozen.
final class EdgeSidebar {
    static let shared = EdgeSidebar()

    static let defaultsKey = "EdgeSidebar"
    static let changed = Notification.Name("EdgeSidebarChanged")

    /// Off until turned on in Settings › Appearance.
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            guard newValue != isOn else { return }
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Zigzag is active with a window of its own in front, so the pointer is in the browser, not at the screen's
    /// edge. The panel and its command bar are not that window: showing them can make Zigzag active, and they must
    /// not read their own act of taking the keyboard as the browser being in front.
    private var isBrowserInFront: Bool {
        NSApp.isActive && NSApp.keyWindow !== panel && NSApp.keyWindow !== commandBarPopup
    }

    /// The window the panel mirrors is on the desktop the pointer is on, and not minimized: its own sidebar is right
    /// there, so the panel would only be a second copy of it. Hidden (⌘H) is away, like minimized: the panel stays the
    /// quick way back.
    private var browserIsHere: Bool {
        guard let window = target?.window, window.isVisible, !window.isMiniaturized else { return false }
        return window.isOnActiveSpace
    }
    /// The last browser window that was in front: its sidebar is the one that comes out.
    private weak var target: BrowserWindowController?
    private var panel: EdgeSidebarPanel?
    private var host: EdgeSidebarHost?
    /// The browser's command bar, over the screen while the panel is in use (#363).
    private var commandBarPopup: EdgeCommandBarPopup?
    /// The bar is open in that popup, not in the window.
    private(set) var isCommandBarOpen = false
    private var reveal = SidebarEdgeReveal()
    /// Whether the panel is out now (or on its way back in).
    private(set) var isShowing = false
    /// Attributes of the panel's own that put the pointer somewhere else for a moment (the command bar, a page
    /// arriving, a sheet): not the pointer leaving. The panel stays until this passes.
    private var heldUntil: TimeInterval = 0
    /// The visible frame of the screen the panel is on, while it's out.
    private var shownScreen: NSRect?
    /// The side the panel last came out on, so it slides back the same way after its window has gone.
    private var lastPanelWasOnRight = false
    private var decideTimer: Timer?
    private var followTimer: Timer?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var isActivated = false
    /// The last moved event's time and speed toward the edge; once the pointer stops, none comes.
    private var lastMoveTime: TimeInterval = 0
    private var lastMoveSpeed: CGFloat = 0
    /// Counts shows, so a hide under way only orders out the panel it hid.
    private var generation = 0

    private init() {}

    // MARK: The switch

    /// Called at launch: with the switch on, the edge listens from now on, and follows it as it's turned on and off.
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        observers.append(NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Self.isOn ? self.start() : self.stop()
            }
        })
        // A screen coming or going changes the edge under the panel: it goes until it's asked for again.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        })
        // Zigzag coming forward with one of its windows puts it back: the panel is for reaching a tab from another
        // app. The panel making itself key is not that: it can make Zigzag active while it is the window in front.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.async {
                    guard let self, self.isBrowserInFront else { return }
                    // The popout taking key is the panel working, not the browser coming forward.
                    guard !EdgeSidebarLayout.keepsPanelOnActivation(holdsForPeek: self.isPageShowing || self.isNoticeShowing) else { return }
                    self.hide(animated: false)
                }
            }
        })
        // Another app or another space is a change of context: the panel goes, and the peek closes with it.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        })
        if Self.isOn { start() }
    }

    private func start() {
        guard monitors.isEmpty else { return }
        // The pointer over any app: the global one hears the others', the local one Zigzag's own.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.moved(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.moved(event) }
            return event
        }) { monitors.append(local) }
        // Esc puts the panel away. The lens consumes its own Esc first; once it has collapsed, the next Esc is the
        // sidebar's. A field being edited keeps its Esc to cancel the edit.
        if let esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.keyCode == 53, self.panel?.isKeyWindow == true,
                      !self.isCommandBarOpen else { return false }
                if self.panel?.firstResponder is NSTextView { return false }
                // With the page open, the first Esc closes it and leaves the sidebar; the next puts the panel away.
                if self.isPageShowing { EdgePeek.shared.dismiss(.escape); return true }
                self.hide()
                return true
            }
            return handled ? nil : event
        }) { monitors.append(esc) }
        target = WindowManager.shared.keyController ?? target
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hide(animated: false, force: true)
        target = nil
    }

    /// A tab, favorite or other action picked in the panel: it goes at once, and its window comes forward.
    func picked() { hide(animated: false) }

    /// The live page beside the sidebar, inside the same panel: hovering a row brings it, and the panel widens.
    private(set) var pageTab: Tab?
    var isPageShowing: Bool { pageTab != nil }
    var pageArea: NSView? { host?.pageArea }
    /// The page area's size once the panel has widened: the tab's page is laid out at this from the first frame, so
    /// the panel's widening reveals it rather than resizing it through the animation.
    var pageTargetSize: NSSize? {
        guard let target, let visible = shownScreen else { return nil }
        let width = EdgeSidebarLayout.width(sidebar: target.edgeSidebarWidth,
                                            side: EdgeSidebarLayout.pageWidth(in: visible),
                                            inset: Tokens.Metric.cardInset, in: visible)
        let bounds = NSRect(origin: .zero, size: NSSize(width: width, height: visible.height))
        return EdgeSidebarLayout.sideFrame(in: bounds, sidebar: target.edgeSidebarWidth, inset: Tokens.Metric.cardInset,
                                           sideShowing: true, onRight: target.edgeSidebarOnRight).size
    }
    /// The side the card is on: the page is pinned to it, so it doesn't slide as the panel widens.
    var pagePinsOnRight: Bool { host?.onRight ?? target?.edgeSidebarOnRight ?? false }
    /// The space editor, when one was opened from the panel rather than in the window behind it.
    private weak var spaceEditor: SpaceEditorPanel?
    var isSpaceEditorOpen: Bool { spaceEditor != nil }

    /// Something the panel itself is showing has the pointer, or the keyboard, for now: a page, the note for Zigzag's
    /// own pages, the command bar, a sheet, the editor. The pointer leaving the edge strip for a moment is not the
    /// pointer leaving the panel.
    var isHoldingOpen: Bool {
        isPageShowing || isNoticeShowing || isCommandBarOpen || isSpaceEditorOpen
            || ProcessInfo.processInfo.systemUptime < heldUntil
            || NSApp.modalWindow != nil
    }

    /// The page area is showing the note for one of Zigzag's own pages (Settings, History, the archive), which the
    /// panel can't lend: the panel is as wide as for a page, and the note offers the way back to the window.
    private(set) var isNoticeShowing = false

    /// Keeps the panel out for a moment whatever the pointer does: a surface it opened moved the pointer elsewhere
    /// (the command bar in the middle of the screen), and the panel is still the thing being used.
    func holdOpen(for seconds: TimeInterval = 0.5) {
        heldUntil = max(heldUntil, ProcessInfo.processInfo.systemUptime + seconds)
    }

    /// The page's holder is in the panel's page area: widen the one panel so both collapse together. Another preview
    /// replacing the first changes the page only: the panel is already the right shape, and nothing slides again.
    func pageAttached(_ tab: Tab) {
        // A page arriving during the note's fold takes the side at once.
        host?.endPageFoldOut()
        let already = pageTab != nil
        pageTab = tab
        if let target { host?.sidebarWidth = target.edgeSidebarWidth }
        if let host, let visible = shownScreen {
            let pageWidth = EdgeSidebarLayout.pageWidth(in: visible)
            // The first page: the area is already the width it will keep, so the panel's widening uncovers it
            // instead of resizing it (and the live page) every frame.
            if !already { host.pageRevealWidth = pageWidth }
            host.sideWidth = max(host.sideWidth, pageWidth)
        }
        host?.pageShowing = true
        guard !already else { return }
        resizeForSide()
        holdOpen(for: 0.6)
        let generation = sideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sideGeneration == generation else { return }
                self.host?.pageRevealWidth = nil
            }
        }
    }

    /// The page has gone back to its tab: fold it into the card and narrow the panel, unless the panel is going away
    /// itself. While the window narrows, the page is still there at its full place, so its edge covers the page (a
    /// fold); the page area is let go once the narrow has finished. The card keeps the sidebar's width until then, so
    /// it never jumps wide and then shrinks.
    func pageDetached(resize: Bool = true) {
        let pageWidth = shownScreen.map { EdgeSidebarLayout.pageWidth(in: $0) }
        pageTab = nil
        guard resize else {
            host?.pageRevealWidth = nil
            host?.pageShowing = false
            return
        }
        // The area keeps its full width under the narrowing window: the window's edge folds the page into the card
        // instead of the page vanishing in one frame.
        if let pageWidth, let host {
            host.pageRevealWidth = pageWidth
            host.pageShowing = true
        }
        if isSpaceEditorOpen {
            host?.sideWidth = max(pageWidth ?? 0, SpaceEditorPanel.width + Tokens.Space.x2)
            resizeForSide()
        } else {
            resizeForSide(closing: true)
        }
        let generation = sideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sideGeneration == generation else { return }
                self.host?.pageRevealWidth = nil
                self.host?.pageShowing = false
            }
        }
    }

    /// The page is making way for the note: it stays in the side under the note's fold, then goes back to its tab
    /// once the fold has covered it.
    func pageFoldingIntoNote() {
        pageTab = nil
        host?.beginPageFoldOut()
    }

    /// The note's fold has covered the old page: the side is the note's now.
    func pageFoldedIntoNote() {
        host?.endPageFoldOut()
    }

    /// A row of Zigzag's own pages has been previewed: no page can be lent, so the page area shows a note saying where
    /// the page works and a button back to it. The panel widens exactly as for a page, so the row's behaviour is the
    /// same shape; only the page's contents are the note's.
    func noticeAttached(tab: Tab, onReturn: @escaping () -> Void) {
        let already = isNoticeShowing || isPageShowing
        isNoticeShowing = true
        if let target { host?.sidebarWidth = target.edgeSidebarWidth }
        if let host, let visible = shownScreen {
            let pageWidth = EdgeSidebarLayout.pageWidth(in: visible)
            if !already { host.pageRevealWidth = pageWidth }
            host.sideWidth = max(host.sideWidth, pageWidth)
        }
        host?.noticeShowing = true
        host?.notice.show(tab: tab)
        host?.notice.onReturn = onReturn
        guard !already else { return }
        resizeForSide()
        holdOpen(for: 0.6)
        let generation = sideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sideGeneration == generation else { return }
                self.host?.pageRevealWidth = nil
            }
        }
    }

    /// Unfolds the side from the card's edge after its content changed (a page becoming the note, or the note a page):
    /// the same move a page swap makes, without a second state to keep alive. A space switch passes the side its
    /// list slid in from.
    func foldInSide(fromRight: Bool? = nil) {
        host?.foldInSide(fromRight: fromRight)
    }

    /// The note has gone: the panel narrows to the card, unless a page or the space editor is taking the area.
    func noticeDetached(resize: Bool = true) {
        guard isNoticeShowing else { return }
        isNoticeShowing = false
        host?.noticeShowing = false
        host?.notice.onReturn = nil
        guard resize, !isPageShowing, !isSpaceEditorOpen else { return }
        resizeForSide(closing: true)
    }

    // MARK: The sidebar's edge

    /// The card's inner edge is the sidebar's edge in the panel, as in the window: the panel keeps the width a drag
    /// gives it, and the page keeps its third beside it (#431).
    func resizeBegan() {
        holdOpen(for: 10)
    }

    func resizeDragged(toX windowX: CGFloat) {
        guard isShowing, let target, let host, let panel, let visible = shownScreen else { return }
        // The handle reports the window's x; the host fills the panel's content, so its x is the same space.
        let x = host.convert(NSPoint(x: windowX, y: 0), from: nil).x
        let inset = Tokens.Metric.cardInset
        let raw = target.edgeSidebarOnRight ? host.bounds.width - inset - x : x - inset
        let width = Tokens.Space.snap(min(max(raw, Tokens.Metric.sidebarMinWidth), Tokens.Metric.sidebarMaxWidth))
        guard abs(width - host.sidebarWidth) >= 0.5 else { return }
        host.sidebarWidth = width
        // The window behind keeps the width too, as a drag on its own edge does (#431).
        target.root.sidebarWidth = width
        target.root.needsLayout = true
        let panelWidth = EdgeSidebarLayout.width(sidebar: width, side: host.sideWidth, inset: inset, in: visible)
        panel.setFrame(EdgeSidebarLayout.frame(in: visible, width: panelWidth, onRight: target.edgeSidebarOnRight),
                       display: true)
        holdOpen(for: 0.5)
    }

    func resizeEnded() {
        guard let target else { return }
        target.root.saveSidebarWidth()
        target.root.onSidebarWidthChange?(target.root.sidebarWidth)
        holdOpen(for: 0.5)
    }

    /// Double-clicking the edge puts the sidebar back to its usual width, as in the window.
    func resetSidebarWidth() {
        guard isShowing, let target, let host, let panel, let visible = shownScreen else { return }
        let width = Tokens.Metric.sidebarWidth
        host.sidebarWidth = width
        target.root.sidebarWidth = width
        target.root.needsLayout = true
        let panelWidth = EdgeSidebarLayout.width(sidebar: width, side: host.sideWidth, inset: Tokens.Metric.cardInset,
                                                 in: visible)
        panel.setFrame(EdgeSidebarLayout.frame(in: visible, width: panelWidth, onRight: target.edgeSidebarOnRight),
                       display: true)
        target.root.saveSidebarWidth()
        target.root.onSidebarWidthChange?(width)
        holdOpen(for: 0.5)
    }

    // MARK: The space editor

    /// A space editor opened from the panel: the panel widens to hold it beside the card, and the editor takes the
    /// keyboard there. The window behind stays where it is.
    func present(spaceEditor editor: SpaceEditorPanel) {
        guard isShowing, let visible = shownScreen, let target, let host else { return }
        spaceEditor = editor
        host.sidebarWidth = target.edgeSidebarWidth
        host.sideWidth = max(EdgeSidebarLayout.pageWidth(in: visible), SpaceEditorPanel.width + Tokens.Space.x2)
        host.editorShowing = true
        resizeForSide()
        let panelWidth = EdgeSidebarLayout.width(sidebar: target.edgeSidebarWidth, side: host.sideWidth,
                                                 inset: Tokens.Metric.cardInset, in: visible)
        let bounds = NSRect(origin: .zero, size: NSSize(width: panelWidth, height: visible.height))
        let side = EdgeSidebarLayout.sideFrame(in: bounds, sidebar: target.edgeSidebarWidth,
                                               inset: Tokens.Metric.cardInset, sideShowing: true,
                                               onRight: target.edgeSidebarOnRight)
        let width = min(SpaceEditorPanel.width, max(0, side.width - Tokens.Space.x2 * 2))
        let height = min(editor.contentHeight, max(0, side.height - Tokens.Space.x2 * 2))
        editor.onClose = { [weak self] in self?.spaceEditorDidClose() }
        editor.show(inEdgeHost: host, frame: NSRect(x: side.midX - width / 2, y: side.minY + Tokens.Space.x2,
                                                    width: width, height: height))
        panel?.makeKey()
        holdOpen(for: 1)
    }

    /// The editor has gone: the page's third comes back if one is showing, else the panel narrows to the card.
    private func spaceEditorDidClose() {
        spaceEditor = nil
        guard isShowing, let host else { return }
        host.setEditor(nil)
        host.editorShowing = false
        if isPageShowing || isNoticeShowing {
            if let visible = shownScreen { host.sideWidth = EdgeSidebarLayout.pageWidth(in: visible) }
            resizeForSide()
        } else {
            resizeForSide(closing: true)
        }
        makeKey()
    }

    /// The panel's width follows its side area: the page's third or the editor, or neither.
    private var sideGeneration = 0
    private func resizeForSide(animated: Bool = true, closing: Bool = false) {
        guard isShowing, let visible = shownScreen, let panel, let target, let host else { return }
        sideGeneration += 1
        let generation = sideGeneration
        host.sidebarWidth = target.edgeSidebarWidth
        if !closing {
            // The note takes the page's third too: it stands in the page area, at the same size and in the same place.
            let page = (isPageShowing || isNoticeShowing) ? EdgeSidebarLayout.pageWidth(in: visible) : 0
            let editor = isSpaceEditorOpen ? SpaceEditorPanel.width + Tokens.Space.x2 : 0
            host.sideWidth = max(page, editor)
        }
        let width = EdgeSidebarLayout.width(sidebar: target.edgeSidebarWidth, side: closing ? 0 : host.sideWidth,
                                            inset: Tokens.Metric.cardInset, in: visible)
        let frame = EdgeSidebarLayout.frame(in: visible, width: width, onRight: target.edgeSidebarOnRight)
        if panel.frame == frame {
            if closing { host.sideWidth = 0 }
            return
        }
        let reduced = !animated || Tokens.Motion.reduceMotion
        guard !reduced else {
            panel.setFrame(frame, display: true)
            if closing { host.sideWidth = 0 }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = Tokens.Motion.easeOut
            panel.animator().setFrame(frame, display: true)
        }
        // The shrink has to finish with the card still the sidebar's width, so the card keeps its place and only the
        // panel narrows; the side area lets go once it's home.
        guard closing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sideGeneration == generation else { return }
                self.host?.sideWidth = 0
            }
        }
    }

    /// The sidebar's address, clicked while the page is open: the command bar over the screen, as ⌘T is, and its
    /// page opens in the panel.
    /// Whether the pointer is still in the strip that keeps the panel out.
    var pointerInEdgeZone: Bool {
        guard isShowing, let visible = shownScreen, let zone = zone(in: visible) else { return false }
        return zone.keeps(at: EdgeSidebarLayout.point(NSEvent.mouseLocation, in: visible))
    }

    /// Whether the panel could stay out at all: the browser coming forward takes that away.
    var canStayOut: Bool { !isBrowserInFront }

    /// The edge panel takes the keyboard back after the lens closes without hiding it.
    func makeKey() {
        guard isShowing else { return }
        panel?.makeKey()
    }

    /// A preview or a row was clicked: the lens opens for that tab.
    func openLens(for tab: Tab) {
        target?.openEdgeLens(for: tab)
    }

    /// Whether a click in the panel is one of the list's own actions (a row, New Tab, blank space), which closes the
    /// lens, rather than one of the sidebar's controls (back, reload, the address) that act on the lens instead.
    func clickClosesLens(at point: NSPoint) -> Bool {
        guard let target else { return true }
        let (sidebar, _) = target.edgeSidebarForDisplay()
        let list = sidebar.list
        return list.convert(list.bounds, to: nil).contains(point)
    }

    /// The panel's window, so the Peek can tell a click on the sidebar from a click outside.
    var panelWindow: NSWindow? { panel }

    /// Where Site Controls and other floating pieces sit over the panel's card.
    var panelOverlay: PassthroughView? { host?.overlay }

    /// The panel's address field: the command bar opens over it when the address is clicked, as it does over the
    /// sidebar's in the window, rather than in the middle of the screen like New Tab.
    var addressView: NSView? {
        guard isShowing, let target else { return nil }
        let (sidebar, _) = target.edgeSidebarForDisplay()
        let address = sidebar.address
        guard !address.isHidden, address.window != nil else { return nil }
        return address
    }

    /// The panel is along the screen's right edge; the page attaches on the other side of it.
    var panelOnRight: Bool { sideIsRight }

    /// The card's look follows the space on show, as the window's own does: its color, gradient, grain, and light or
    /// dark, so a switch in the panel is seen there at once and not only after reopening it.
    func setCardLook(tint: NSColor, gradient: (end: NSColor, angle: Double)?, grain: Double) {
        guard let container = host?.container else { return }
        container.tint = tint
        container.gradient = gradient
        container.grain = grain
    }

    func setCardAppearance(_ name: NSAppearance.Name?) {
        panel?.appearance = name.flatMap(NSAppearance.init(named:))
    }

    /// The sidebar card's frame on screen: the page sits beside its inner edge.
    var sidebarCardScreenFrame: NSRect? {
        guard let panel, let host else { return nil }
        return panel.convertToScreen(host.convert(host.cardFrame, to: nil))
    }

    /// The last browser window to become key: what the edge brings out from now on.
    func noteFocused(_ controller: BrowserWindowController) {
        guard controller.window?.isVisible == true else { return }
        guard target !== controller else { return }
        target = controller
        if isShowing { hide() }
    }

    func windowClosed(_ controller: BrowserWindowController) {
        guard target === controller else { return }
        hide(animated: false, force: true)
        target = nil
    }

    // MARK: The pointer

    private var sideIsRight: Bool { target?.edgeSidebarOnRight ?? false }

    private func moved(_ event: NSEvent) {
        let elapsed = event.timestamp - lastMoveTime
        lastMoveSpeed = elapsed > 0 && elapsed < 0.1 ? (sideIsRight ? event.deltaX : -event.deltaX) / max(elapsed, 1.0 / 240) : 0
        lastMoveTime = event.timestamp
        guard !isShowing, case .hidden = reveal.phase else { return }
        // The window whose sidebar comes out: the last one in front, or, after that one closed, the one Zigzag would
        // have brought forward.
        if target == nil { target = WindowManager.shared.keyController }
        guard let target, EdgeSidebarLayout.canShow(appIsActive: isBrowserInFront, browserHere: browserIsHere) else { return }
        let point = NSEvent.mouseLocation
        guard let (zone, local, _) = zone(at: point), zone.opens(at: local) else { return }
        met(at: event.timestamp)
    }

    /// The screen-sized edge under the pointer: the screen's visible frame stands in for a window's bounds.
    private func zone(at point: NSPoint) -> (SidebarEdgeZone, NSPoint, NSRect)? {
        guard let target else { return nil }
        let frames = NSScreen.screens.map(\.visibleFrame)
        guard let index = EdgeSidebarLayout.screen(containing: point, in: frames) else { return nil }
        let visible = frames[index]
        return (zone(in: visible)!, EdgeSidebarLayout.point(point, in: visible), visible)
    }

    private func zone(in visible: NSRect) -> SidebarEdgeZone? {
        guard let target else { return nil }
        // The panel is the card and the gutter it stands off the screen's edge by: the card's inner edge is the panel's.
        // With the page open the panel is wider, and the pointer over the page is over the panel, not leaving it.
        let width = EdgeSidebarLayout.width(sidebar: target.edgeSidebarWidth, page: isPageShowing || isNoticeShowing,
                                            inset: Tokens.Metric.cardInset, in: visible)
        return EdgeSidebarLayout.zone(in: visible, width: width, onRight: target.edgeSidebarOnRight)
    }

    private func met(at time: TimeInterval) {
        guard target != nil else { return }
        reveal.met(at: time, speed: lastMoveSpeed)
        guard decideTimer == nil else { return }
        // A breath after meeting it, as at the window's edge: brushing past leaves it be.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.decide() }
        }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        decideTimer = timer
    }

    private func decide() {
        let point = NSEvent.mouseLocation
        guard let (zone, local, visible) = zone(at: point) else { return stopDeciding(dismiss: true) }
        switch reveal.decide(at: local, time: ProcessInfo.processInfo.systemUptime, in: zone) {
        case .some(true):
            stopDeciding(dismiss: false)
            show(on: visible)
        case .some(false):
            stopDeciding(dismiss: true)
        case .none:
            break
        }
    }

    private func stopDeciding(dismiss: Bool) {
        decideTimer?.invalidate()
        decideTimer = nil
        if dismiss { reveal.dismiss() }
    }

    private func startFollowing() {
        followTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.follow() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func follow() {
        guard isShowing, let visible = shownScreen, let zone = zone(in: visible) else { return }
        // Zigzag came forward, or the window's sidebar came out: the panel has nothing left to show.
        guard let target, EdgeSidebarLayout.canShow(appIsActive: isBrowserInFront, browserHere: browserIsHere) else {
            hide()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let point = EdgeSidebarLayout.point(NSEvent.mouseLocation, in: visible)
        // A pressed button holds it out, as a drag from the panel does. So does a menu opened from it, whose tracking
        // (system menus) or open panel (MenuPanel) runs while the pointer is over it.
        // So does a surface of the panel's own that moved the pointer elsewhere for a moment: the command bar in the
        // middle of the screen, a save or permission sheet, the space editor. And the panel's own actual frame counts
        // as being over it, whatever the edge strip's arithmetic says while the page widens or narrows it.
        let overPanel = panel.map {
            $0.isVisible && $0.frame.insetBy(dx: -Tokens.Space.x2, dy: -Tokens.Space.x2).contains(NSEvent.mouseLocation)
        } ?? false
        let ownedKey = NSApp.keyWindow.map { $0 !== panel && $0 !== commandBarPopup && $0 !== target.window } ?? false
        let held = NSEvent.pressedMouseButtons != 0
            || RunLoop.current.currentMode == .eventTracking
            || MenuPanel.current != nil
            || isCommandBarOpen
            || isSpaceEditorOpen
            || now < heldUntil
            || overPanel
            || ownedKey
            || NSApp.modalWindow != nil
            || panel?.attachedSheet != nil
        // The panel is a surface of its own, not a strip: a glance away across the screen gets a beat longer than the
        // window's own edge, and a page being read gets longer still.
        let leaveDelay: TimeInterval = (isPageShowing || isNoticeShowing || isSpaceEditorOpen) ? 0.3 : 0.15
        if reveal.follow(at: point, time: now, in: zone, held: held, leaveDelay: leaveDelay) {
            debugLog("edge follow hides point=\(point) mouse=\(NSEvent.mouseLocation) held=\(held) overPanel=\(overPanel) keeps=\(zone.keeps(at: point)) past=\(zone.isPast(point)) visible=\(visible) panel=\(panel.map { NSStringFromRect($0.frame) } ?? "-")")
            hide()
        }
    }

    // MARK: The panel

    /// A sideways scroll over the panel's sidebar changes space there, as it does in the window's own. The panel is
    /// a window of its own, so the window's event interceptor never sees these.
    private func intercept(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel, isShowing, let target, let host else { return false }
        let (sidebar, _) = target.edgeSidebarForDisplay()
        let point = host.convert(event.locationInWindow, from: nil)
        // Only where the sidebar card is what's under the pointer: a menu over it keeps its own scrolls.
        guard host.cardFrame.contains(point),
              host.hitTest(point)?.isDescendant(of: sidebar) == true else { return false }
        return sidebar.handleSwipe(event)
    }

    // MARK: The command bar

    /// The surface the browser's command bar draws in while the panel is in use: the screen the panel is on.
    var commandBarOverlay: NSView? { isCommandBarOpen ? commandBarPopup?.overlay : nil }
    var commandBarPageFrame: NSRect? {
        guard isCommandBarOpen, let popup = commandBarPopup else { return nil }
        return NSRect(origin: .zero, size: popup.frame.size)
    }

    /// New Tab from the panel — ⌘T or its row: the browser's own bar, over the screen, not in the window behind it.
    func newTabInPlace() {
        openCommandBarInPlace(.newTab)
    }

    /// The address clicked in the panel: the same bar, editing the page the panel shows. The panel is the browser
    /// while it is out, so neither the window behind it nor the pointer's place in it changes what is typed into.
    func editAddressInPlace() {
        openCommandBarInPlace(.editCurrent)
    }

    private func openCommandBarInPlace(_ mode: CommandBarController.Mode) {
        guard isShowing, !isCommandBarOpen, let target, let visible = shownScreen else { return }
        // The bar sits in the middle of the screen, away from the panel: the panel is still the surface being used.
        holdOpen(for: 1)
        let popup = commandBarPopup ?? makeCommandBarPopup()
        popup.setFrame(visible, display: true)
        popup.overlay.frame = NSRect(origin: .zero, size: visible.size)
        isCommandBarOpen = true
        popup.orderFrontRegardless()
        target.showEdgeCommandBar(mode: mode)
    }

    /// The bar's field is in the popup, and the popup takes the keyboard for it.
    func focusCommandBar(_ field: NSTextField) {
        guard isCommandBarOpen, let popup = commandBarPopup else { return }
        holdOpen(for: 1)
        popup.makeKeyAndOrderFront(nil)
        popup.makeFirstResponder(field)
    }

    /// The bar has finished leaving: the popup goes, and the panel (still out) takes the keyboard back. The pointer
    /// is still where the bar was, away from the panel, so the panel gets a moment before proximity counts again.
    func commandBarDidHide() {
        guard isCommandBarOpen else { return }
        isCommandBarOpen = false
        commandBarPopup?.orderOut(nil)
        holdOpen(for: 1)
        if EdgePeek.shared.isVisible { EdgePeek.shared.makeKey() } else if isShowing { panel?.makeKey() }
    }

    private func makeCommandBarPopup() -> EdgeCommandBarPopup {
        let popup = EdgeCommandBarPopup(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.level = .statusBar
        popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = false
        popup.hidesOnDeactivate = false
        popup.isMovable = false
        popup.isReleasedWhenClosed = false
        popup.animationBehavior = .none
        popup.contentView = popup.overlay
        commandBarPopup = popup
        return popup
    }

    private func show(on visible: NSRect) {
        guard let target, EdgeSidebarLayout.canShow(appIsActive: isBrowserInFront, browserHere: browserIsHere) else { return }
        let (sidebar, container) = target.edgeSidebarForDisplay()
        target.prepareEdgeSidebar()
        let onRight = target.edgeSidebarOnRight
        lastPanelWasOnRight = onRight
        // The card keeps the window's sidebar's width; the panel is that and the gutter it stands off the edge by.
        let width = EdgeSidebarLayout.width(sidebar: target.edgeSidebarWidth, page: false,
                                            inset: Tokens.Metric.cardInset, in: visible)
        let panel = panel ?? makePanel()
        guard let host else { return }
        sidebar.isOnRight = onRight
        let look = target.edgeSidebarLook
        container.isFloating = true
        container.tint = look.tint
        container.gradient = look.gradient
        container.grain = look.grain
        container.windowGlass = look.glass
        host.onRight = onRight
        host.sidebarWidth = target.edgeSidebarWidth
        host.sideWidth = 0
        // A fold still running as the panel went belongs to the last time it was out.
        host.endPageFoldOut()
        host.pageShowing = false
        host.noticeShowing = false
        host.editorShowing = false
        isNoticeShowing = false
        host.set(container)

        generation += 1
        panel.setFrame(EdgeSidebarLayout.frame(in: visible, width: width, onRight: onRight), display: true)
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.placeCard()
        shownScreen = visible
        isShowing = true
        panel.orderFrontRegardless()
        // The panel has the keyboard while it's out: ⌘T and typing work there, over the app in front.
        panel.makeKey()

        // The card slides in from beyond the screen's edge, as the window's hidden sidebar does.
        let card = host.cardFrame
        let start = card.offsetBy(dx: onRight ? card.width + host.inset : -(card.width + host.inset), dy: 0)
        Tokens.Motion.withoutAnimation { container.frame = card }
        let duration = Tokens.Motion.slide(container, fromOffsetX: start.minX - card.minX, curve: Tokens.Motion.edgeSlide)
        reveal.shown(true, at: ProcessInfo.processInfo.systemUptime, settling: duration)
        startFollowing()
    }

    /// Downloads from the panel: the list in the panel's window, over the mirror's lane, not in the window behind.
    func showDownloads(from anchor: NSView, in controller: BrowserWindowController) {
        guard isShowing, let host, let target else { return }
        let (sidebar, _) = target.edgeSidebarForDisplay()
        DownloadsPanel.show(from: anchor, in: controller, host: host, lane: host.cardFrame, receding: [sidebar.list])
    }

    /// Puts the panel away. Without the slide for a pick, so its window can come forward at once.
    func hide(animated: Bool = true, force: Bool = false) {
        debugLog("edge hide page=\(isPageShowing) pointer=\(NSEvent.mouseLocation) panel=\(panel.map { NSStringFromRect($0.frame) } ?? "-") shown=\(shownScreen.map(NSStringFromRect) ?? "-") browserHere=\(browserIsHere) key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "-") callers=\(Thread.callStackSymbols.dropFirst().prefix(4).joined(separator: " <- "))")
        // The editor is the panel's too: closing it commits its name, and it doesn't try to resize a panel on its way
        // out.
        if let editor = spaceEditor {
            spaceEditor = nil
            editor.onClose = nil
            editor.close()
            host?.setEditor(nil)
            host?.editorShowing = false
        }
        // The page is the panel's: it goes back to its tab before the panel goes, and neither outlives the other.
        EdgePeek.shared.detachForHide()
        // The lens and the sidebar are one session: the lens collapses first, and only then does the sidebar follow.
        // A stop or a closed window is the exception: there is nothing left to follow.
        guard force || !EdgeLensPolicy.blocksSidebarHide(lensOpen: EdgePeek.shared.isVisible) else { return }
        // The panel's popout is its page: it goes with the panel, however the panel goes.
        target?.edgePopoutDidDismiss()
        stopDeciding(dismiss: true)
        // The bar and the downloads list open over the screen go with the panel.
        if isCommandBarOpen, let target { target.commandBar.dismiss(restoringFocus: false) }
        if let host, DownloadsPanel.isOpen(in: host.window) { DownloadsPanel.closeCurrent() }
        followTimer?.invalidate()
        followTimer = nil
        guard isShowing else { return }
        isShowing = false
        shownScreen = nil
        reveal.shown(false, at: ProcessInfo.processInfo.systemUptime, settling: 0)
        generation += 1
        let current = generation
        guard let panel = panel, let host, let container = host.container else {
            self.panel?.orderOut(nil)
            return
        }
        guard animated else { panel.orderOut(nil); return }
        let card = host.cardFrame
        let onRight = target?.edgeSidebarOnRight ?? lastPanelWasOnRight
        let out = card.offsetBy(dx: onRight ? card.width + host.inset : -(card.width + host.inset), dy: 0)
        Tokens.Motion.withoutAnimation { container.frame = out }
        let duration = Tokens.Motion.slide(container, fromOffsetX: card.minX - out.minX, curve: Tokens.Motion.edgeTuck)
        guard duration > 0 else { panel.orderOut(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> EdgeSidebarPanel {
        let panel = EdgeSidebarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above other apps' windows, on every space and over full-screen apps; never the key window, never in ⌘`.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.eventInterceptor = { [weak self] event in self?.intercept(event) ?? false }
        let host = EdgeSidebarHost()
        panel.contentView = host
        host.overlay.frame = host.bounds
        host.overlay.autoresizingMask = [.width, .height]
        host.addSubview(host.overlay)
        self.host = host
        self.panel = panel
        return panel
    }
}

/// The edge sidebar's panel: it comes out over another app without taking the front; it takes the keyboard while it's
/// out, so ⌘T and typing in it work there, and gives it back when it goes.
final class EdgeSidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Before the views: sideways scrolls over the sidebar change space, as in the window behind.
    var eventInterceptor: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if eventInterceptor?(event) == true { return }
        super.sendEvent(event)
    }

    /// ⌘T in either panel — the sidebar's or the lens's — opens the panel's own command bar, as a new tab there.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "t" {
            EdgeSidebar.shared.newTabInPlace()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The panel's content: the floating sidebar card, set off the screen's edge as it is from a window's, and flush at
/// the panel's other edge, which is the page's side. The panel is the card and that gutter, so the card is what shows.
final class EdgeSidebarHost: NSView {
    private(set) weak var container: SidebarContainer?
    /// Where the site panel and other floating pieces sit, above the card.
    let overlay = PassthroughView()
    /// The live page beside the sidebar: the same panel, so both slide and collapse as one.
    let pageArea = EdgePageArea()
    /// The page's card behind it: the page area clips its page, so its own bounds are drawn here, with the card's
    /// shadow. A PDF's backdrop can be the same dark as the panel, and without this the page has no visible edge.
    private let pageCard = NSView()
    /// The card's page area for one of Zigzag's own pages, which the panel can't lend: where the page works, and the
    /// button back to the window.
    let notice = EdgeSystemPageNotice()
    let inset = Tokens.Metric.cardInset
    /// The sidebar's own width while a side is open; the card keeps it then. Dragging the card's inner edge changes it
    /// live, and the panel widens beside it.
    var sidebarWidth: CGFloat = 0 { didSet { if sidebarWidth != oldValue { placeCard() } } }
    /// The sidebar's edge in the panel, as in the window: the card's inner edge dragged to set the width every window
    /// keeps. A thin band over the edge, above the page, so the page's own clicks stay its own away from the edge.
    let resizeHandle = ResizeHandle()
    /// The side area's width: the page's third or the space editor, 0 while neither is open. Kept until the panel has
    /// finished narrowing, so the card never jumps wide and then shrinks.
    var sideWidth: CGFloat = 0 { didSet { if sideWidth != oldValue { placeCard() } } }
    /// While the page's third is being revealed: its width, with the area already there and the panel widening over
    /// it. Nil once the panel has widened, when the ordinary side frame takes over (at the same place).
    var pageRevealWidth: CGFloat? { didSet { if pageRevealWidth != oldValue { placeCard() } } }
    var pageShowing = false { didSet { updateSideVisibility() } }
    var noticeShowing = false { didSet { updateSideVisibility() } }
    var editorShowing = false { didSet { updateSideVisibility() } }
    /// A page making way for the note: it stays under the note's fold until the fold has covered it, so the page
    /// doesn't vanish a frame before the note arrives.
    private(set) var pageFoldingOut = false
    private weak var editor: NSView?

    /// The page area, the note and the editor share one side: the note is only there when no page is, and the editor
    /// takes the side from both. While a page folds out, its area stays up under the note for the fold.
    private func updateSideVisibility() {
        pageArea.isHidden = !(pageShowing || pageFoldingOut) || editorShowing
        notice.isHidden = !noticeShowing || editorShowing
        editor?.isHidden = !editorShowing
        placeCard()
    }

    /// The note is taking the page's place: bring its card above the live page, still masked to nothing, so the
    /// note's fold covers the page from the card's edge instead of uncovering a blank side.
    func beginPageFoldOut() {
        guard !pageFoldingOut else { return }
        pageFoldingOut = true
        addSubview(pageCard, positioned: .above, relativeTo: pageArea)
        placeCard()
    }

    /// The fold has covered the old page: put the page area back above the card for the next page, and let it go.
    func endPageFoldOut() {
        guard pageFoldingOut else { return }
        pageFoldingOut = false
        pageShowing = false
        pageCard.layer?.mask = nil
        addSubview(pageArea, positioned: .above, relativeTo: pageCard)
    }

    /// The panel is along the screen's right edge: its gutter is on the right.
    var onRight = false { didSet { placeCard() } }
    private var sideIsShowing: Bool { sideWidth > 0 }
    var cardFrame: NSRect {
        EdgeSidebarLayout.cardFrame(in: bounds, sidebar: sidebarWidth, inset: inset, sideShowing: sideIsShowing, onRight: onRight)
    }
    var sideFrame: NSRect {
        EdgeSidebarLayout.sideFrame(in: bounds, sidebar: sidebarWidth, inset: inset, sideShowing: sideIsShowing, onRight: onRight)
    }
    var pageFrame: NSRect { sideFrame }

    override var isFlipped: Bool { true }

    func set(_ container: SidebarContainer) {
        self.container?.removeFromSuperview()
        self.container = container
        container.autoresizingMask = []
        addSubview(container)
        if pageArea.superview == nil {
            pageCard.wantsLayer = true
            pageCard.layer?.cornerRadius = Tokens.Radius.large
            pageCard.layer?.cornerCurve = .continuous
            pageCard.layer?.backgroundColor = cgColor(Tokens.Color.cardBackground)
            pageCard.layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
            pageCard.layer?.shadowOpacity = 1
            pageCard.layer?.shadowRadius = Tokens.Shadow.sheetRadius
            pageCard.layer?.shadowOffset = Tokens.Shadow.panelOffset(flipped: isFlipped)
            pageCard.addSubview(notice)
            addSubview(pageCard)
            addSubview(pageArea)
        }
        if resizeHandle.superview == nil {
            resizeHandle.onBegin = { EdgeSidebar.shared.resizeBegan() }
            resizeHandle.onDrag = { x, _ in EdgeSidebar.shared.resizeDragged(toX: x) }
            resizeHandle.onEnd = { _ in EdgeSidebar.shared.resizeEnded() }
            resizeHandle.onDoubleClick = { EdgeSidebar.shared.resetSidebarWidth() }
            addSubview(resizeHandle)
        }
        // Above the card, whatever was added before: showing the panel again re-adds the card, and Site Controls and
        // the rest of the overlay must still draw over it.
        addSubview(overlay, positioned: .above, relativeTo: nil)
        placeCard()
    }

    /// The space editor, above the page: the panel's side is the editor's while it is open.
    func setEditor(_ view: NSView?) {
        editor?.removeFromSuperview()
        editor = view
        guard let view else { placeCard(); return }
        addSubview(view, positioned: .above, relativeTo: pageArea)
        view.isHidden = !editorShowing
        placeCard()
    }

    override func layout() {
        super.layout()
        placeCard()
    }

    /// Unfolds what the side shows from the card's edge, as a page swap does. The page swaps run their own mask on the
    /// holder; this is for a page and the note taking each other's place. `fromRight`: the side a space switch's list
    /// slid in from; nil keeps to the card's edge.
    func foldInSide(fromRight: Bool? = nil) {
        guard !Tokens.Motion.reduceMotion else { return }
        let view: NSView = noticeShowing ? pageCard : pageArea
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let right = fromRight ?? onRight
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.anchorPoint = CGPoint(x: right ? 1 : 0, y: 0.5)
        mask.position = CGPoint(x: right ? size.width : 0, y: size.height / 2)
        mask.bounds = CGRect(origin: .zero, size: size)
        view.layer?.mask = mask
        let fold = CABasicAnimation(keyPath: "bounds.size.width")
        fold.fromValue = 0
        fold.toValue = size.width
        fold.duration = 0.16
        fold.timingFunction = Tokens.Motion.easeOut
        mask.add(fold, forKey: "fold")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak view] in
            MainActor.assumeIsolated { view?.layer?.mask = nil }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        pageCard.layer?.backgroundColor = cgColor(Tokens.Color.cardBackground)
        pageCard.layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
    }

    func placeCard() {
        container?.frame = cardFrame
        pageArea.frame = pageRevealWidth.map {
            EdgeSidebarLayout.pageRevealFrame(in: bounds, sidebar: sidebarWidth, inset: inset, width: $0, onRight: onRight)
        } ?? pageFrame
        pageCard.frame = pageArea.frame
        // The card stands behind the page, or behind the note when the panel can't lend the page.
        pageCard.isHidden = !(pageShowing || noticeShowing) || editorShowing
        notice.frame = pageCard.bounds
        pageCard.layer?.shadowPath = CGPath(roundedRect: pageCard.bounds,
                                            cornerWidth: Tokens.Radius.large, cornerHeight: Tokens.Radius.large,
                                            transform: nil)
        if let editor, editorShowing {
            let side = sideFrame
            let size = editor.frame.size
            editor.frame = NSRect(x: side.midX - size.width / 2,
                                  y: side.minY + Tokens.Space.x2,
                                  width: min(size.width, max(0, side.width - Tokens.Space.x2 * 2)),
                                  height: min(size.height, max(0, side.height - Tokens.Space.x2 * 2)))
        }
        // The sidebar's edge: the card's inner side, whichever edge the panel is on.
        let card = cardFrame
        let handleWidth = Tokens.Metric.resizeHandleWidth
        let edge = onRight ? card.minX : card.maxX
        resizeHandle.frame = NSRect(x: edge - handleWidth / 2, y: card.minY, width: handleWidth, height: card.height)
        resizeHandle.line = handleWidth / 2
        resizeHandle.isHidden = container == nil
        overlay.frame = bounds
    }

    /// File › New Tab (⌘T) with the panel key: the browser's own bar, in place over the screen.
    @objc func newTab(_ sender: Any?) { EdgeSidebar.shared.newTabInPlace() }

    /// Esc while the panel has the keyboard puts it away, as it closes anything else opened to use for a moment. A
    /// menu or the command bar is the first responder while either is up, so it closes itself first instead.
    override func cancelOperation(_ sender: Any?) { EdgeSidebar.shared.hide() }

    /// A click outside the card, in the panel's gutter, puts it away; clicks on the card belong to the sidebar in it
    /// (its own blank space does the same). The page and the editor are the panel's too, and take their own clicks;
    /// while either is out, a click in the gutter between them is not a dismissal.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if container?.frame.contains(point) != true, !sideFrame.contains(point) {
            if pageShowing || noticeShowing || editorShowing { return }
            EdgeSidebar.shared.hide()
            return
        }
        super.mouseDown(with: event)
    }
}

/// One page's worth of the panel: clipped to the card's corners, with the page's own holder filling it.
final class EdgePageArea: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.large
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        // The page's own backdrop (a PDF's especially) can match the panel behind it: a hairline says where the
        // card is, whatever the page happens to draw.
        layer?.borderWidth = Tokens.Metric.hairline
        layer?.borderColor = cgColor(Tokens.Color.cardEdge)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = cgColor(Tokens.Color.cardEdge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The page area for one of Zigzag's own pages (Settings, History, the archive): the panel lends the tab its page, and
/// these pages are the window's own, so the card says where the page works and offers the way back. The row that
/// brought it stays greyed in the list; this button is the only action here.
final class EdgeSystemPageNotice: NSView {
    private let icon = NSImageView()
    private let title = Label("", font: Tokens.Font.heading(), color: Tokens.Color.textPrimary)
    private let detail = Label(String(localized: "Zigzag's own pages only work in the browser window.",
                                      comment: "Under the page's name in the edge sidebar's note for one of Zigzag's own pages, which the panel can't show."),
                               font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
    let returnButton = PillButton(title: String(localized: "Return to Zigzag",
                                                comment: "Button in the edge sidebar's note for one of Zigzag's own pages: brings the browser forward on that page."),
                                  style: .prominent)
    var onReturn: (() -> Void)? {
        didSet {
            returnButton.onClick = { [weak self] _ in self?.onReturn?() }
        }
    }

    init() {
        super.init(frame: .zero)
        icon.image = NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.alignment = .center
        detail.alignment = .center
        addSubview(icon)
        addSubview(title)
        addSubview(detail)
        addSubview(returnButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(tab: Tab) {
        title.stringValue = tab.title.isEmpty
            ? String(localized: "This page opens in Zigzag", comment: "The edge sidebar's note for one of Zigzag's own pages when the page's name is not known yet.")
            : tab.title
        title.toolTip = tab.title
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = min(320, max(0, bounds.width - Tokens.Space.x6 * 2))
        let iconSide: CGFloat = 34
        let gap = Tokens.Space.x2
        let button = returnButton.intrinsicContentSize
        let buttonWidth = max(button.width, 132)
        let titleHeight = title.lineHeight
        let detailHeight = detail.lineHeight
        let total = iconSide + gap * 2 + titleHeight + gap + detailHeight + gap * 2 + button.height
        // From the bottom up: the button, the explanation, the page's name, the symbol.
        var y = max(Tokens.Space.x6, (bounds.height - total) / 2)
        returnButton.frame = NSRect(x: bounds.midX - buttonWidth / 2, y: y, width: buttonWidth, height: button.height)
        y = returnButton.frame.maxY + gap * 2
        detail.frame = NSRect(x: bounds.midX - width / 2, y: y, width: width, height: detailHeight)
        y = detail.frame.maxY + gap
        title.frame = NSRect(x: bounds.midX - width / 2, y: y, width: width, height: titleHeight)
        y = title.frame.maxY + gap * 2
        icon.frame = NSRect(x: bounds.midX - iconSide / 2, y: y, width: iconSide, height: iconSide)
    }
}

/// The edge panel as a place for Site Controls: the page is the one the popout is showing, and the panel opens over
/// the sidebar card instead of bringing the browser window forward.
@MainActor final class EdgeSitePanelHost: SitePanelPageHost {
    let tab: Tab
    let overlay: PassthroughView
    private let hostWindow: NSWindow?

    init(tab: Tab, overlay: PassthroughView, window: NSWindow? = nil) {
        self.tab = tab
        self.overlay = overlay
        self.hostWindow = window
    }

    var window: NSWindow? { hostWindow ?? EdgeSidebar.shared.panelWindow }
    var listsExtensions: Bool { false }

    func copyPageURL(_ sender: Any?) {
        guard let url = tab.url else { return }
        CleanLink.write(url, title: tab.displayTitle)
        Toast.show(String(localized: "Link copied", comment: "Toast after the page's address is copied."), symbol: "link", over: overlay, area: overlay.bounds)
    }

    func confirmClear(_ kind: WebsiteData.Kind, of tab: Tab) {
        BrowserWindowController.confirmClear(kind, of: tab, over: overlay) { [weak self] text in
            guard let self else { return }
            Toast.show(text, symbol: "checkmark.circle", over: self.overlay, area: self.overlay.bounds)
        }
    }
}

/// The browser's command bar over the screen while the edge sidebar is in use: it takes the keyboard without bringing
/// Zigzag forward, so the bar can be typed in over another app.
final class EdgeCommandBarPopup: NSPanel {
    /// Flipped, as the window's command-bar overlay is: the bar's frames count down from the screen's top.
    let overlay = PassthroughView()
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
