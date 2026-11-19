import AppKit

/// Glow on the sidebar edge while a question waits that the window can't show: an accent hairline at the resize
/// handle over a short outer glow. Fades in once, never pulses; clicking shows the sidebar and selects the tab.
@MainActor
final class AttentionEdge: NSView {
    /// Waiting tab count, for the tooltip.
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
        // Against the sidebar's edge, glowing onto the page.
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

    /// Colors are set in `layout`, which reruns on appearance change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// Fades in once, then stays still.
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
    /// Frame in a single-page window without a sidebar (Zigzag Mini, web apps): a hairline on the window edge on the
    /// `sidebarOnRight` side. Browser windows use the resize handle's frame instead.
    static func frame(forPage area: NSRect, sidebarOnRight: Bool) -> NSRect {
        NSRect(x: sidebarOnRight ? area.maxX - Tokens.Metric.hairline : area.minX,
               y: area.minY, width: Tokens.Metric.resizeHandleWidth, height: area.height)
    }
}
