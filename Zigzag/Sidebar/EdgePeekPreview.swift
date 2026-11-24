import AppKit

/// The edge sidebar's own hover preview: the card beside the row, at once, because it is the promise that the row
/// opens the lens.
enum EdgePeekPreviewPolicy {
    /// No wait: the edge preview is the closed lens, not the browser's delayed glance.
    static let delay: TimeInterval = 0
    /// The pointer may cross the gap between the row and the card on its way to click it.
    static let pointerGrace: TimeInterval = 0.18

    static func shouldShow(hovered: Bool, peekVisible: Bool) -> Bool { hovered && !peekVisible }
}

/// The card's own hit area: a transparent cover over the preview that takes the click. `TabPreviewView` stays a
/// picture only, exactly as it is in the browser.
final class EdgePreviewHitArea: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }
    /// The first click lands on the card even though the panel never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class EdgePeekPreview {
    static let shared = EdgePeekPreview()

    private var panel: NSPanel?
    private var card: TabPreviewView?
    private var hitArea: EdgePreviewHitArea?
    private var pending: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?
    private var followTimer: Timer?
    private var wasInside = false
    private var clickMonitor: Any?
    private var showingTab: Tab?
    private static let width: CGFloat = 236
    private static let height: CGFloat = 176
    private static let gap = Tokens.Space.x3

    private init() {}

    /// The card's frame wherever it last was: the lens grows from it, even when the preview is already gone.
    var currentFrame: NSRect? { panel?.frame }

    /// Whether the card is out and clickable. The sidebar stays out while it is: the preview is the closed lens.
    var isVisible: Bool { panel?.isVisible == true }

    /// The pointer is on a row: at once, or following it row to row.
    func hover(tab: Tab, at row: NSRect) {
        guard EdgePeekPreviewPolicy.shouldShow(hovered: true, peekVisible: EdgePeek.shared.isVisible) else {
            hide()
            return
        }
        pendingHide?.cancel()
        pendingHide = nil
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.present(tab: tab, at: row) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgePeekPreviewPolicy.delay, execute: work)
    }

    /// The pointer left a row: not at once, so it can cross the gap and click the card. A pointer that stops in the
    /// gap still loses it.
    func pointerLeftRow() {
        guard panel?.isVisible == true else {
            hide()
            return
        }
        scheduleHide(after: EdgePeekPreviewPolicy.pointerGrace)
    }

    /// The pointer left, a row was picked, the card was clicked, or the sidebar went: the preview goes.
    func hide() {
        pending?.cancel()
        pending = nil
        pendingHide?.cancel()
        pendingHide = nil
        followTimer?.invalidate()
        followTimer = nil
        wasInside = false
        showingTab = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel?.orderOut(nil)
    }

    private func scheduleHide(after delay: TimeInterval) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func present(tab: Tab, at row: NSRect) {
        guard EdgePeekPreviewPolicy.shouldShow(hovered: true, peekVisible: EdgePeek.shared.isVisible) else { return }
        makePanel()
        guard let panel, let card, let hitArea else { return }
        showingTab = tab
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.panel?.isVisible == true else { return }
                    if event.window === EdgeSidebar.shared.panelWindow { self.hide() }
                }
                return event
            }
        }
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(row) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        // On the page's side of the row, never over the sidebar it belongs to.
        let onRight = row.midX > visible.midX
        let x = onRight ? row.minX - Self.gap - Self.width : row.maxX + Self.gap
        let y = min(max(row.midY - Self.height / 2, visible.minY + Self.gap), visible.maxY - Self.height - Self.gap)
        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: Self.height), display: false)
        card.show(tab: tab, bookmark: nil)
        card.layoutSubtreeIfNeeded()
        hitArea.frame = card.bounds
        panel.orderFrontRegardless()
        startFollowing()
    }

    /// While the card is out, its frame is checked against the pointer: reaching it cancels the grace, leaving it
    /// dismisses it on the spot. A timer, not a tracking area or a global monitor, so it works over another app that
    /// has not given Zigzag input monitoring.
    private func startFollowing() {
        followTimer?.invalidate()
        wasInside = panel?.frame.contains(NSEvent.mouseLocation) == true
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followPointer() }
        }
    }

    private func followPointer() {
        guard let panel, panel.isVisible else { return }
        let point = NSEvent.mouseLocation
        let inside = panel.frame.contains(point)
        if inside {
            pendingHide?.cancel()
            pendingHide = nil
        } else if wasInside, EdgeSidebar.shared.panelWindow?.frame.contains(point) != true {
            hide()
        }
        wasInside = inside
    }

    private func makePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating - 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // The card is the closed lens: it takes the click that opens it.
        panel.ignoresMouseEvents = false
        let card = TabPreviewView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        card.autoresizingMask = [.width, .height]
        let hitArea = EdgePreviewHitArea(frame: card.bounds)
        hitArea.autoresizingMask = [.width, .height]
        hitArea.onClick = { [weak self] in
            guard let self, let tab = self.showingTab else { return }
            self.hide()
            EdgeSidebar.shared.openLens(for: tab)
        }
        card.addSubview(hitArea)
        panel.contentView = card
        self.panel = panel
        self.card = card
        self.hitArea = hitArea
    }
}
