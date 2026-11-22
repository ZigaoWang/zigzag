import AppKit
import WebKit

/// Where the edge lens's page sits: the rest of the screen beside the sidebar, its top and bottom the sidebar card's.
/// What keeps the lens out when it loses key: the sidebar itself (to pick another tab) and our own menus or sheets.
/// Everything else, including a third-party switcher that takes key without activating an app, closes it.
enum EdgePeekFocusPolicy {
    enum NewKey { case none, sidebar, owned, other }

    static func keepsOpen(newKey: NewKey, menuOpen: Bool) -> Bool {
        if menuOpen { return true }
        switch newKey {
        case .sidebar, .owned: return true
        case .none, .other: return false
        }
    }
}

/// Whether a page can go back where it came from: never into a closed tab, and not at all when it had no home. A
/// selection change puts it back only where its card still shows it; elsewhere the card now owns the place and the
/// page must not be painted over it.
enum EdgePeekRestorePolicy {
    static func canRestore(isClosed: Bool, hasOrigin: Bool, reason: EdgeLensReason = .escape,
                           cardStillShowsPage: Bool = false) -> Bool {
        guard !isClosed, hasOrigin else { return false }
        return reason != .selection || cardStillShowsPage
    }
}

/// Whether the lens can move to another page: not to the page it is on, and not to a closed tab. A page WebKit opened
/// for the lens has its configuration before its address, so a missing URL never keeps it out.
enum EdgePeekSwap {
    static func canTake(_ tab: Tab, from current: Tab?, isClosed: Bool) -> Bool {
        !isClosed && tab !== current
    }
}

/// How long the pointer rests on a row before its page is previewed. A pointer crossing rows previews nothing; a
/// pointer that stops on one does. Movement inside the row starts the wait again.
enum EdgePeekHoverPolicy {
    /// The rest before a preview: long enough that a pointer crossing rows previews nothing, short enough that
    /// stopping on one still feels immediate. Movement inside the row starts the wait again.
    static let dwell: TimeInterval = 0.2
    /// How often the pointer is looked at while it rests.
    static let check: TimeInterval = 0.05
    /// Movement, in points, that means the pointer is still travelling rather than resting.
    static let movement: CGFloat = 2

    /// The pointer has rested: it hasn't moved since `since`, and the dwell has passed.
    static func rests(now: TimeInterval, since: TimeInterval, moved: Bool) -> Bool {
        !moved && now - since >= dwell
    }
}

/// What the lens does when the browser's context changes under it: a space switch hands it the new space's selected
/// page, and a page opened from it stays in it.
enum EdgePeekRouting {
    enum NewPage { case peek, browser }

    static func keepsLensOnSpaceChange(peekVisible: Bool) -> Bool { peekVisible }
    static func newPage(peekVisible: Bool) -> NewPage { peekVisible ? .peek : .browser }
    /// A page opened from the lens replaces it; selecting any other tab is leaving the lens.
    static func selectionKeepsLens(lensTab: Tab?, selected: Tab?) -> Bool {
        guard let lensTab, let selected, selected !== lensTab else { return false }
        return selected.opener === lensTab
    }
}

/// The edge page, inside the sidebar's own panel (#365 prototype): the panel widens by a third of the screen, and the
/// tab's own page fills it. Hovering a row runs the page through the panel; a click keeps the one it is on; the page
/// and the sidebar slide, and collapse, as one object.
///
/// The page is the tab's own `pageHolder`, moved out of its pane and put straight back on close, so its state carries:
/// the same page, not a second load. Nothing in the close path waits on WebKit.
final class EdgePeek {
    static let shared = EdgePeek()

    private(set) var tab: Tab?
    /// The tab picked from the rows: the page the panel goes back to when the pointer leaves them. A preview passes
    /// over the rows without changing it.
    private(set) var lockedTab: Tab?
    /// One of Zigzag's own pages under the pointer: no page can be lent to the panel, so the page area says where it
    /// works and offers the window. Setting it does not change `tab`: the note has no page of its own.
    private(set) var noticeTab: Tab?
    var isVisible: Bool { tab != nil || noticeTab != nil }
    private weak var controller: BrowserWindowController?
    /// Where the page came from, so closing puts it back there.
    private weak var origin: NSView?
    private var originFrame: NSRect = .zero
    private var token: Any?
    private var managerObserver: Any?
    private var outsideMonitor: Any?
    private var keyObserver: NSObjectProtocol?
    /// The row the pointer is resting on: one page is brought after a short rest, not one per row passed over.
    private var hoverWork: DispatchWorkItem?
    /// The pointer has left the rows: after a moment, the panel goes back to the tab picked there. The short wait
    /// keeps a pass down the rows from swapping back and forth.
    private var leaveWork: DispatchWorkItem?
    /// A page swap folding in from the card's side: the new page over the old, which goes back when the fold ends.
    private struct Fold {
        let newHolder: PageHolder
        let old: Tab
        let oldHolder: PageHolder
        let origin: NSView?
        let originFrame: NSRect
        let controller: BrowserWindowController
    }
    private var fold: Fold?
    private var foldWork: DispatchWorkItem?

    private init() {}

    // MARK: Hovering and opening

    /// The pointer is on a row: after it rests there, that tab's page fills the panel's page area. Crossing rows
    /// previews nothing; a pointer that stops on one does, and moving within it starts the wait again.
    func hover(tab: Tab, from controller: BrowserWindowController) {
        guard EdgeSidebar.isOn, EdgeSidebar.shared.isShowing else { return }
        // A new row is a new preview: the trip back to the picked tab doesn't happen.
        leaveWork?.cancel()
        hoverWork?.cancel()
        // A row of Zigzag's own pages previews the note instead of a page, but only after the same rest.
        guard self.tab !== tab, self.noticeTab !== tab else { return }
        scheduleHoverCheck(tab: tab, from: controller, pointer: NSEvent.mouseLocation,
                           stillSince: ProcessInfo.processInfo.systemUptime)
    }

    /// Checks the pointer while a row is hovered: still for the dwell, its page comes; moved, the dwell starts over.
    private func scheduleHoverCheck(tab: Tab, from controller: BrowserWindowController,
                                    pointer: NSPoint, stillSince: TimeInterval) {
        let work = DispatchWorkItem { [weak self, weak tab, weak controller] in
            MainActor.assumeIsolated {
                guard let self, let tab, let controller, EdgeSidebar.shared.isShowing else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let point = NSEvent.mouseLocation
                let moved = abs(point.x - pointer.x) > EdgePeekHoverPolicy.movement
                    || abs(point.y - pointer.y) > EdgePeekHoverPolicy.movement
                if self.fold != nil {
                    // A fold is very short: this page comes when it has finished, so two folds never overlap.
                    self.scheduleHoverCheck(tab: tab, from: controller, pointer: point, stillSince: stillSince)
                } else if EdgePeekHoverPolicy.rests(now: now, since: stillSince, moved: moved) {
                    if EdgeLensPolicy.takesPage(url: tab.url) {
                        self.show(tab: tab, from: controller)
                    } else {
                        self.showNotice(tab: tab, from: controller)
                    }
                } else {
                    self.scheduleHoverCheck(tab: tab, from: controller, pointer: point,
                                            stillSince: moved ? now : stillSince)
                }
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgePeekHoverPolicy.check, execute: work)
    }

    /// The pointer has left the rows for the rest of the panel (the page, the spaces, a menu): once a tab has been
    /// picked, the page goes back to it. Before a pick there is no selected tab, so the preview stays.
    func rowsLeft(from controller: BrowserWindowController) {
        hoverWork?.cancel()
        hoverWork = nil
        leaveWork?.cancel()
        guard isVisible, lockedTab != nil else { return }
        let work = DispatchWorkItem { [weak self, weak controller] in
            MainActor.assumeIsolated {
                guard let self, let controller, let locked = self.lockedTab, !locked.isClosed,
                      self.tab !== locked, EdgeSidebar.shared.isShowing else { return }
                let fromNotice = self.noticeTab != nil
                if self.noticeTab != nil {
                    self.noticeTab = nil
                    EdgeSidebar.shared.noticeDetached(resize: false)
                }
                self.attach(locked, from: controller, swapping: true)
                if fromNotice { EdgeSidebar.shared.foldInSide() }
            }
        }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// A click on a row picks that tab: its page stays from then on unless another row is previewed, and the keyboard
    /// goes into it. The same row clicked again only takes the keyboard.
    func lock(tab: Tab, from controller: BrowserWindowController) {
        hoverWork?.cancel()
        hoverWork = nil
        leaveWork?.cancel()
        show(tab: tab, from: controller)
        guard self.tab === tab else { return }
        lockedTab = tab
        controller.setEdgeSelection(tab.id)
        makeKey()
    }

    /// A site panel describes one page: another page taking the area takes it away with it.
    private func closeSitePanel() {
        if SitePanel.isOpen(in: EdgeSidebar.shared.panelWindow) { SitePanel.closeCurrent() }
    }

    /// A page opened from the panel replaces the one it shows; a click on the row already showing locks it.
    func show(tab: Tab, from controller: BrowserWindowController, replacing: Bool = false) {
        guard EdgeLensPolicy.takesPage(url: tab.url) else { return }
        hoverWork?.cancel()
        // A note gives the area up at once: this is a page coming in, and the panel is already the width for it. The
        // page then unfolds from the card's side, as another page would.
        let fromNotice = noticeTab != nil
        if noticeTab != nil {
            noticeTab = nil
            EdgeSidebar.shared.noticeDetached(resize: false)
        }
        if isVisible {
            guard self.tab !== tab else { return }
            closeSitePanel()
            attach(tab, from: controller, swapping: true)
        } else {
            guard EdgeSidebar.isOn, EdgeSidebar.shared.isShowing else { return }
            attach(tab, from: controller, swapping: false)
        }
        if fromNotice { EdgeSidebar.shared.foldInSide() }
    }

    /// One of Zigzag's own pages under the pointer: the panel can't lend its page, so the page area says where it
    /// works and offers the window. The row itself stays inert; this note is the only action.
    func showNotice(tab: Tab, from controller: BrowserWindowController) {
        guard !EdgeLensPolicy.takesPage(url: tab.url), EdgeSidebar.isOn, EdgeSidebar.shared.isShowing else { return }
        hoverWork?.cancel()
        hoverWork = nil
        leaveWork?.cancel()
        if noticeTab === tab { return }
        // A page goes back to its tab first, and the panel keeps its width for the note. The note then unfolds from
        // the card's side, as another page would; a note already there just changes its words.
        let replacing = self.tab != nil
        let fromNotice = noticeTab != nil
        closeSitePanel()
        if self.tab != nil { detach(.sidebarClick, resize: false, forNote: true) }
        noticeTab = tab
        self.controller = controller
        controller.updateEdgeSidebarForNotice(tab)
        installObservers()
        EdgeSidebar.shared.noticeAttached(tab: tab) { [weak self] in self?.returnToBrowser() }
        if replacing || fromNotice { EdgeSidebar.shared.foldInSide() }
    }

    /// The note's button: the page is the window's, so the window comes forward on it and the panel puts itself away.
    private func returnToBrowser() {
        guard let noticeTab, !noticeTab.isClosed, let controller else { return }
        controller.tabManager.select(noticeTab)
        controller.bringForwardForEdge()
    }

    private func attach(_ tab: Tab, from controller: BrowserWindowController, swapping: Bool) {
        guard let area = EdgeSidebar.shared.pageArea else { return }
        _ = tab.ensureWebView()
        guard let holder = tab.pageHolder else { return }
        // A fold already running finishes at once, so its page goes back before this one starts.
        finishFold()
        let old = swapping ? self.tab : nil
        let oldHolder = old?.pageHolder
        let oldOrigin = origin
        let oldOriginFrame = originFrame
        if !swapping { self.controller = controller }
        origin = holder.superview
        originFrame = holder.frame
        holder.removeFromSuperview()
        // The page lays out once at the size it will have when the panel has widened, pinned to the card's side: the
        // widening reveals it from behind the card instead of resizing it every frame. A live page (the tab the window
        // already shows) would otherwise reflow through the whole animation; a page not yet loaded opens quietly.
        let pageSize = EdgeSidebar.shared.pageTargetSize ?? area.bounds.size
        holder.frame = EdgeSidebarLayout.pageHolderFrame(in: area.bounds, target: pageSize,
                                                         onRight: EdgeSidebar.shared.pagePinsOnRight)
        holder.autoresizingMask = EdgeSidebarLayout.pageHolderMask(onRight: EdgeSidebar.shared.pagePinsOnRight)
        // The page's place is rounded; the holder is too, so a PDF's own backdrop (which is a layer of its own) can't
        // square off the corners the way a web page's view is clipped by the area.
        holder.wantsLayer = true
        holder.layer?.cornerRadius = Tokens.Radius.large
        holder.layer?.cornerCurve = .continuous
        holder.layer?.masksToBounds = true
        // The page it leaves stays under it until the fold finishes: the new page unfolds over it from the card's
        // side, so the old one is not put back first (which would leave nothing to uncover).
        if let oldHolder, oldHolder !== holder {
            oldHolder.layer?.mask = nil
            oldHolder.frame = NSRect(origin: .zero, size: pageSize)
            if oldHolder.superview !== area { area.addSubview(oldHolder) }
        }
        area.addSubview(holder)
        if let old, let oldHolder, oldHolder !== holder {
            startFold(newHolder: holder, old: old, oldHolder: oldHolder, origin: oldOrigin, originFrame: oldOriginFrame,
                      size: pageSize, controller: controller)
        }
        adoptPDFViewer(of: tab, fitting: true)
        self.tab = tab
        controller.setEdgePeek(tab.id)
        controller.prepareEdgeSidebar()
        EdgeSidebar.shared.pageAttached(tab)
        token = tab.changed.observe { [weak self] _ in self?.refresh() }
        if !swapping { installObservers() }
        // A preview never takes the keyboard: the pointer is only passing over the row. A click locks it and does.
        refresh()
    }

    /// Folds the new page in over the old, from the card's side. The old page stays under it until the fold ends,
    /// then goes back to its tab. A layer mask reveals the new page; the page itself is laid out once and never
    /// resized, so the live tab folds without reflowing.
    private func startFold(newHolder: PageHolder, old: Tab, oldHolder: PageHolder, origin: NSView?, originFrame: NSRect,
                           size: NSSize, controller: BrowserWindowController) {
        let fold = Fold(newHolder: newHolder, old: old, oldHolder: oldHolder, origin: origin, originFrame: originFrame,
                        controller: controller)
        self.fold = fold
        guard !Tokens.Motion.reduceMotion else {
            finishFold()
            return
        }
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        // Anchored at the card: the page unfolds from the sidebar's side, on either edge.
        let onRight = EdgeSidebar.shared.pagePinsOnRight
        mask.anchorPoint = CGPoint(x: onRight ? 1 : 0, y: 0.5)
        mask.position = CGPoint(x: onRight ? size.width : 0, y: size.height / 2)
        mask.bounds = CGRect(origin: .zero, size: size)
        newHolder.layer?.mask = mask
        let reveal = CABasicAnimation(keyPath: "bounds.size.width")
        reveal.fromValue = 0
        reveal.toValue = size.width
        reveal.duration = 0.16
        reveal.timingFunction = Tokens.Motion.easeOut
        mask.add(reveal, forKey: "fold")
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finishFold() } }
        foldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17, execute: work)
    }

    /// The fold has finished (or another page is taking over): the new page is fully revealed and the old one goes
    /// back to its tab, if that card still shows it.
    private func finishFold() {
        foldWork?.cancel()
        foldWork = nil
        guard let fold else { return }
        self.fold = nil
        fold.newHolder.layer?.mask = nil
        fold.oldHolder.removeFromSuperview()
        fold.oldHolder.layer?.cornerRadius = 0
        fold.oldHolder.layer?.masksToBounds = false
        if let origin = fold.origin, fold.old.webView != nil,
           fold.controller.root.card.webView === fold.old.webView {
            fold.oldHolder.frame = fold.originFrame
            origin.addSubview(fold.oldHolder)
            origin.needsLayout = true
        }
    }

    /// A PDF's viewer covers the page, so it goes in the holder rather than the card. The holder is what the panel
    /// borrows: putting the viewer in it is what brings Zigzag's PDF into the popout instead of WebKit's own viewer.
    /// `fitting`: the page has just arrived in a narrow column, so the PDF fits its width rather than keeping the
    /// window's zoom and its scroll controls.
    private func adoptPDFViewer(of tab: Tab, fitting: Bool) {
        guard let holder = tab.pageHolder, let pdf = tab.pdfViewer else { return }
        // A viewer left over from an earlier page in this holder must not stay under or over this one: two white
        // documents in one holder read as a PDF with no page card around it.
        for other in holder.subviews.compactMap({ $0 as? PDFViewerView }) where other !== pdf {
            other.removeFromSuperview()
        }
        let moved = pdf.superview !== holder
        if moved {
            pdf.removeFromSuperview()
            pdf.frame = holder.bounds
            pdf.autoresizingMask = [.width, .height]
            holder.addSubview(pdf)
        }
        if moved || fitting { pdf.pdfView.fitWidth() }
    }

    /// The panel's own address and buttons follow the page in it.
    private func refresh() {
        guard let tab else { return }
        if tab.isClosed {
            dismiss(.sameTab)
            return
        }
        // A PDF that arrived after the page did (the viewer is made once the document opens) travels with it too.
        adoptPDFViewer(of: tab, fitting: false)
        controller?.updateEdgeSidebarForPeek(tab)
    }

    func makeKey() {
        guard isVisible else { return }
        EdgeSidebar.shared.makeKey()
        if let pdf = tab?.pdfViewer {
            EdgeSidebar.shared.panelWindow?.makeFirstResponder(pdf.pdfView)
        } else if let webView = tab?.webView {
            EdgeSidebar.shared.panelWindow?.makeFirstResponder(webView)
        }
    }

    // MARK: Dismissing

    /// Ends the page for `reason`. Its holder goes back first, then the panel narrows, or goes with it when the
    /// reason takes the whole object.
    func dismiss(_ reason: EdgeLensReason = .escape) {
        guard isVisible else { return }
        let hidePanel = EdgeLensPolicy.hidesSidebar(after: reason,
                                                    pointerInEdgeZone: EdgeSidebar.shared.pointerInEdgeZone,
                                                    panelCanShow: EdgeSidebar.shared.canStayOut)
        detach(reason, resize: !hidePanel)
        if hidePanel {
            EdgeSidebar.shared.hide(animated: true)
        } else if EdgeLensPolicy.keepsKey(after: reason), !EdgeSidebar.shared.isCommandBarOpen {
            EdgeSidebar.shared.makeKey()
        }
    }

    /// The panel is going away: the page goes back to its tab, and the panel leaves at whatever width it has.
    func detachForHide() {
        guard isVisible else { return }
        detach(.windowClose, resize: false)
    }

    private func detach(_ reason: EdgeLensReason, resize: Bool, forNote: Bool = false) {
        debugLog("edge peek detach reason=\(reason) panel=\(EdgeSidebar.shared.isShowing) pointer=\(NSEvent.mouseLocation)")
        // A page still folding goes back to its tab first, so no holder is left in the panel. The site panel described
        // that page, so it goes too, rather than describing nothing over the note or the next page.
        closeSitePanel()
        finishFold()
        hoverWork?.cancel()
        hoverWork = nil
        leaveWork?.cancel()
        leaveWork = nil
        // The note has no page to put back: its card goes, and the panel narrows unless it is leaving anyway.
        if noticeTab != nil {
            noticeTab = nil
            EdgeSidebar.shared.noticeDetached(resize: resize)
            // The note's page is not the window's page: the mirror goes back to what the window is on.
            controller?.prepareEdgeSidebar()
            releaseObservers()
            self.controller = nil
            return
        }
        let controller = self.controller
        let tab = self.tab
        let origin = self.origin
        let originFrame = self.originFrame
        // The page goes back to its tab. Folding into the card, it stays where it is until the panel has narrowed over
        // it, then goes; hiding it first made the narrow a jump with nothing moving.
        let restore = {
            guard let tab, let holder = tab.pageHolder else { return }
            holder.removeFromSuperview()
            holder.layer?.cornerRadius = 0
            holder.layer?.masksToBounds = false
            // A selection change puts the page back only if its card still shows it (the split's other pane); a page
            // the card has replaced stays out, so it never paints over the page that owns the place now.
            let cardStillShowsPage = controller?.root.card.webView === tab.webView
            if EdgePeekRestorePolicy.canRestore(isClosed: tab.isClosed, hasOrigin: origin != nil, reason: reason,
                                                cardStillShowsPage: cardStillShowsPage),
               let origin {
                holder.frame = originFrame
                origin.addSubview(holder)
                origin.needsLayout = true
            }
        }
        let folding = resize && EdgeSidebar.shared.isShowing
        if forNote, !Tokens.Motion.reduceMotion {
            // The note's fold covers the live page before it goes: the page stays in its place for the 0.16 s fold
            // instead of snapping to its tab a frame before the note arrives.
            EdgeSidebar.shared.pageFoldingIntoNote()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                MainActor.assumeIsolated {
                    restore()
                    EdgeSidebar.shared.pageFoldedIntoNote()
                }
            }
        } else if folding {
            EdgeSidebar.shared.pageDetached(resize: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                MainActor.assumeIsolated { restore() }
            }
        } else {
            restore()
            EdgeSidebar.shared.pageDetached(resize: false)
        }
        releaseObservers()
        self.tab = nil
        self.lockedTab = nil
        self.controller = nil
        self.origin = nil
        // The panel may stay (Esc, a blank click): its rows and address go back to the browser's selected tab.
        controller?.setEdgeSelection(nil)
        controller?.setEdgePeek(nil)
        controller?.prepareEdgeSidebar()
    }

    // MARK: Context

    private func installObservers() {
        guard controller != nil, outsideMonitor == nil else { return }
        if let window = controller?.window {
            // The browser coming forward ends the page: it is not the browser's window.
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(.browserFront) }
            }
        }
        managerObserver = controller?.tabManager.changed.observe { [weak self] change in
            MainActor.assumeIsolated { self?.managerChanged(change) }
        }
        // A click outside, in this app or another, puts the whole panel away, page and all.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, MenuPanel.current == nil else { return }
                guard EdgeSidebar.shared.panelWindow?.frame.contains(NSEvent.mouseLocation) != true else { return }
                EdgeSidebar.shared.hide()
            }
        }
    }

    /// A space change or the page's tab changing under it: both are dealt with rather than leaving a page with no row
    /// to come from or go back to.
    private func managerChanged(_ change: TabManager.Change) {
        guard isVisible else { return }
        switch change {
        case .space:
            if EdgePeekRouting.keepsLensOnSpaceChange(peekVisible: isVisible) {
                transitionToSpace()
            } else {
                dismiss(.spaceChange)
            }
        case .structure:
            if tab?.isClosed == true { dismiss(.sameTab) }
        case .selection:
            if tab?.isClosed == true {
                dismiss(.selection)
                return
            }
            if let lensTab = tab, let selected = controller?.tabManager.selectedTab, selected !== lensTab {
                // A page chosen in the panel's command bar is locked into it right after this notification, and a page
                // opened from the page replaces it. Both swap the panel's page here. Anything else is leaving it, but
                // give that turn its moment first: deciding now would dismiss the panel before the new page arrives.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.isVisible, let lensTab = self.tab,
                              let selected = self.controller?.tabManager.selectedTab, selected !== lensTab else { return }
                        self.dismiss(.selection)
                    }
                }
            }
        case .content:
            break
        }
    }

    /// The new space's selected tab takes the page's place with the same fold a hover swap uses. A page picked from
    /// the rows stays picked, now in the new space; a note has no page to keep.
    private func transitionToSpace() {
        guard let controller, let selected = controller.tabManager.selectedTab else {
            dismiss(.spaceChange)
            return
        }
        let keepsPick = lockedTab != nil
        if EdgeLensPolicy.takesPage(url: selected.url) {
            show(tab: selected, from: controller)
            guard tab === selected else { return }
            if keepsPick {
                lockedTab = selected
                controller.setEdgeSelection(selected.id)
            }
        } else {
            showNotice(tab: selected, from: controller)
            guard noticeTab === selected else { return }
            lockedTab = nil
            controller.setEdgeSelection(nil)
        }
    }

    private func releaseObservers() {
        token = nil
        managerObserver = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }
}
