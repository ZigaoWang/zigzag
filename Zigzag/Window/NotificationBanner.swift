import AppKit

/// A site's notification, shown in Zigzag's own style over whatever app or space you are in: the "Everywhere" answer
/// for a site that does not want to use the Mac's Notification Center. It is the same toast the app shows inside a
/// window — trailing edge, favicon, Show and × — in its own floating panel, placed where the Mac puts a banner.
@MainActor
final class NotificationBanner {
    /// The banners on screen, newest first. Three at most; a fourth takes the oldest away, so a page cannot bury the
    /// screen in them.
    private static var showing: [NotificationBanner] = []
    private static let gap: CGFloat = Tokens.Space.x2
    private static let margin: CGFloat = Tokens.Space.x3

    private let panel: NSPanel
    private let toast = ToastView()
    private let screen: NSScreen
    private let onShow: () -> Void
    private var hideWork: DispatchWorkItem?

    private init(text: String, image: NSImage?, symbol: String, duration: TimeInterval, onShow: @escaping () -> Void) {
        self.onShow = onShow
        screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = NotificationBannerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
        self.panel = panel
        toast.label.stringValue = text
        toast.icon.image = image ?? Tokens.Symbol.image(symbol)
        toast.spinner.stopAnimation(nil)
        toast.actionButton.title = String(localized: "Show", comment: "Button on a site's notification shown over another app: brings its tab forward.")
        toast.actionButton.isHidden = false
        toast.closeButton.isHidden = false
        toast.closeButton.onClick = { [weak self] _ in self?.close() }
        let size = toast.size(maxWidth: Toast.bannerWidth)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.addSubview(toast)
        toast.frame = content.bounds
        toast.needsLayout = true
        panel.contentView = content
        panel.setContentSize(size)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        toast.actionButton.onClick = { [weak self] _ in
            guard let self else { return }
            self.onShow()
            self.close()
        }
        hideWork = DispatchWorkItem { [weak self] in self?.close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: hideWork!)
    }

    /// Shows a banner over whatever is in front, including other apps and screens. The caller keeps its own idea of
    /// what the notification is about (its tab, its page) and passes what Show should do.
    static func show(text: String, image: NSImage? = nil, symbol: String,
                     duration: TimeInterval = 8, onShow: @escaping () -> Void) {
        let banner = NotificationBanner(text: text, image: image, symbol: symbol, duration: duration, onShow: onShow)
        showing.insert(banner, at: 0)
        if showing.count > 3 { showing.last?.close() }
        banner.present()
        reposition()
    }

    private func present() {
        place(at: 0, animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = Tokens.Motion.easeOut
            panel.animator().alphaValue = 1
        }
    }

    private func place(at index: Int, animated: Bool) {
        let height = panel.frame.height
        let top = screen.visibleFrame.maxY - Self.margin
        var y = top
        for banner in Self.showing.prefix(index) { y -= banner.panel.frame.height + Self.gap }
        let origin = NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - Self.margin, y: y - height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = Tokens.Motion.easeOut
                panel.animator().setFrameOrigin(origin)
            }
        } else {
            panel.setFrameOrigin(origin)
        }
    }

    private static func reposition() {
        for (index, banner) in showing.enumerated() { banner.place(at: index, animated: true) }
    }

    private func close() {
        hideWork?.cancel()
        hideWork = nil
        guard let index = Self.showing.firstIndex(where: { $0 === self }) else { return }
        Self.showing.remove(at: index)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = Tokens.Motion.easeOut
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        }
        Self.reposition()
    }
}

/// A banner never makes Zigzag the app in front; it floats over other apps, on every space and beside full screen
/// windows, as the mini player does.
private final class NotificationBannerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
