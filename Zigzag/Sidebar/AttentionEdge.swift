import AppKit

/// The soft glow along the sidebar's edge while a question is waiting that the window cannot show: the hairline sits
/// where the resize handle does, in the space's accent, over a short outer glow. It fades in once and stays — it never
/// pulses — and clicking it brings the sidebar back and selects the tab the question is for.
@MainActor
final class AttentionEdge: NSView {
    /// How many tabs are waiting, for the tooltip.
    var waiting: Int = 0 { didSet { guard waiting != oldValue else { return }; toolTip = waiting > 0 ? Self.tip(waiting) : nil } }

    var onClick: (() -> Void)?

    private let hairline = CALayer()
    private var didFadeIn = false

    private static func tip(_ count: Int) -> String {
        count == 1
            ? String(localized: "A tab needs your answer", comment: "Tooltip of the glow along the sidebar's edge when one page is waiting for an answer.")
            : String(localized: "\(count) tabs need your answer", comment: "Tooltip of the glow along the sidebar's edge when more than one page is waiting for an answer. The placeholder is how many.")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hairline.cornerRadius = Tokens.Metric.hairline / 2
        layer?.addSublayer(hairline)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = min(Tokens.Space.x4, bounds.width)
        // On whichever edge the sidebar lives: the glow sits against it, its light spilling onto the page.
        let x = bounds.width > width ? bounds.width - width : 0
        hairline.frame = NSRect(x: x, y: bounds.minY, width: Tokens.Metric.hairline, height: bounds.height)
        layer?.backgroundColor = cgColor(Tokens.Color.accent.withAlphaComponent(0.16))
        Tokens.Motion.withoutAnimation {
            hairline.backgroundColor = cgColor(Tokens.Color.accent)
            layer?.shadowColor = cgColor(Tokens.Color.accent)
            layer?.shadowOpacity = 1
            layer?.shadowRadius = Tokens.Shadow.sheetRadius
            layer?.shadowOffset = .zero
            layer?.shadowPath = CGPath(rect: bounds.insetBy(dx: x, dy: 0), transform: nil)
        }
        if !didFadeIn { didFadeIn = true; fadeIn() }
    }

    /// In once, then still: something to notice, nothing to watch.
    private func fadeIn() {
        guard !Tokens.Motion.reduceMotion else { return }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.drawerIn
            animator().alphaValue = 1
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

extension AttentionEdge {
    /// Its frame for the page of a window that shows one page and has no sidebar to hang a dot on (Zigzag Mini, a web
    /// app): a hairline on the window's own edge, on the side `sidebarOnRight` puts the sidebar, its glow spilling
    /// onto the page. A browser window instead gives it the resize handle's frame, at the sidebar's edge.
    static func frame(forPage area: NSRect, sidebarOnRight: Bool) -> NSRect {
        NSRect(x: sidebarOnRight ? area.maxX - Tokens.Metric.hairline : area.minX,
               y: area.minY, width: Tokens.Metric.resizeHandleWidth, height: area.height)
    }
}
