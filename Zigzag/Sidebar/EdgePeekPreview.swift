import AppKit

/// The edge sidebar's own hover preview: a still card beside the row, after a short hover, drawn in a panel of its
/// own because the edge panel is over another app and the browser window's overlay is not on screen with it.
enum EdgePeekPreviewPolicy {
    static let delay: TimeInterval = Tokens.Motion.previewDelay

    static func shouldShow(hovered: Bool, peekVisible: Bool) -> Bool { hovered && !peekVisible }
}

final class EdgePeekPreview {
    static let shared = EdgePeekPreview()

    private var panel: NSPanel?
    private var card: TabPreviewView?
    private var pending: DispatchWorkItem?
    private var clickMonitor: Any?
    private static let width: CGFloat = 236
    private static let height: CGFloat = 176
    private static let gap = Tokens.Space.x3

    private init() {}

    /// The pointer is on a row: after the delay, or at once while the card is following it row to row.
    func hover(tab: Tab, at row: NSRect) {
        guard EdgePeekPreviewPolicy.shouldShow(hovered: true, peekVisible: EdgePeek.shared.isVisible) else {
            hide()
            return
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.present(tab: tab, at: row) }
        }
        pending = work
        let delay = panel?.isVisible == true ? 0 : EdgePeekPreviewPolicy.delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The pointer left, a row was picked, or the popout came out: the preview goes.
    func hide() {
        pending?.cancel()
        pending = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel?.orderOut(nil)
    }

    private func present(tab: Tab, at row: NSRect) {
        guard EdgePeekPreviewPolicy.shouldShow(hovered: true, peekVisible: EdgePeek.shared.isVisible) else { return }
        makePanel()
        guard let panel, let card else { return }
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
        panel.orderFrontRegardless()
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
        panel.ignoresMouseEvents = true
        let card = TabPreviewView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        card.autoresizingMask = [.width, .height]
        panel.contentView = card
        self.panel = panel
        self.card = card
    }
}
