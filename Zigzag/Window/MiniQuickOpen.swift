import AppKit

/// ⌃⌘N: Zigzag's command bar on its own, over whatever is on screen, the same bar ⌘T opens in a browser window.
/// Return opens what you chose in Zigzag Mini, which grows out of where the bar was; Esc, a click outside it or
/// ⌃⌘N again puts it away.
final class MiniQuickOpen: NSWindowController, NSWindowDelegate {
    private static var shown: MiniQuickOpen?
    static var isShown: Bool { shown != nil }

    /// Opens the bar, or puts it away if it's up.
    static func toggle() {
        if let shown { shown.bar.dismiss(restoringFocus: false); return }
        let quickOpen = MiniQuickOpen()
        shown = quickOpen
        quickOpen.present()
    }

    #if DEBUG
    static var current: MiniQuickOpen? { shown }
    var debugBar: CommandBarController { bar }
    var debugPanelFrame: NSRect { barFrameOnScreen }
    #endif

    /// The browser window Zigzag Mini belongs to: the front everyday one, if there is one.
    private static var browser: BrowserWindowController? {
        let manager = WindowManager.shared
        return manager.keyController.flatMap { $0.tabManager.isPrivate ? nil : $0 } ?? manager.controllers.last { !$0.tabManager.isPrivate }
    }

    /// The space Zigzag Mini wears: the one you're in, in the front browser window, else your first.
    static var space: SpaceInfo { browser?.tabManager.currentSpace ?? Library.shared.spaces[0] }
    /// Open tabs, among the results and for completing an address: the front browser window's.
    static var tabs: TabManager? { browser?.tabManager }

    /// The page a chosen result opens in Zigzag Mini, and whether it's a search; nil for one that isn't a page.
    static func page(for kind: CommandResult.Kind) -> (url: URL, search: Bool)? {
        switch kind {
        case .open(let url), .history(let url): (url, false)
        case .search(let query), .suggestion(let query): (Library.shared.searchEngine.searchURL(query), true)
        case .searchOn(let url): (url, true)
        case .bookmark(let id): Library.shared.bookmark(id).map { ($0.url, false) }
        case .switchTo, .action, .note: nil
        }
    }

    /// Switch to Tab: that tab's browser window comes forward with it, rather than a copy of it opening here.
    static func switchToTab(_ kind: CommandResult.Kind) -> Bool {
        guard case .switchTo(let id) = kind else { return false }
        for controller in WindowManager.shared.controllers {
            guard let tab = controller.tabManager.tab(with: id) else { continue }
            controller.tabManager.select(tab)
            controller.window?.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }

    private let content = PassthroughView()
    private lazy var bar = CommandBarController(host: self)
    /// Room for the bar with every row it can show, and its shadow.
    private static let size = NSSize(width: Tokens.Metric.commandBarWidth + Tokens.Space.x8 * 2,
                                     height: Tokens.Metric.commandBarFieldHeight + Tokens.Metric.commandBarRowHeight * CGFloat(Tokens.Metric.commandBarMaxRows) + Tokens.Space.x12 * 3)
    /// The bar's top, from the window's: where the bar puts itself over a page of this height (`CommandBarController`).
    private static var barTop: CGFloat { max(Tokens.Space.x12, floor(size.height * 0.18)) }

    private init() {
        let panel = QuickOpenPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The bar casts its own shadow; the window would add a second one around nothing.
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Over a full-screen app too, on the desktop you're looking at.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = content
        panel.setAccessibilityTitle(MiniWindowController.name)
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Centered on the screen you're using, the bar where ⌘T's sits over a page that size.
    /// Whether it came up over a full-screen window, so the page opens in that same Space: by the time a result is
    /// clicked, the bar itself is the window in front.
    private var overFullScreen = false

    private func present() {
        guard let window else { return }
        overFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
        let screen = NSApp.keyWindow?.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(origin: .zero, size: Tokens.Metric.windowDefaultSize)
        let top = area.maxY - max(Tokens.Space.x12, floor(area.height * 0.18))
        let size = Self.size
        window.setFrame(NSRect(x: round(area.midX - size.width / 2), y: top + Self.barTop - size.height, width: size.width, height: size.height), display: false)
        let mode = Self.space.readableAppearance
        window.appearance = (mode == "light" ? NSAppearance.Name.aqua : mode == "dark" ? .darkAqua : nil).flatMap(NSAppearance.init(named:))
        bar.showsDesktop = true
        // Called up while another app is in front (the Dock's menu): Zigzag comes forward first, and the window it
        // last had in front takes the keys back as it does, which mustn't count as clicking away.
        if !NSApp.isActive {
            isActivating = true
            activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.activation.map(NotificationCenter.default.removeObserver)
                    self.activation = nil
                    self.window?.makeKeyAndOrderFront(nil)
                    self.isActivating = false
                }
            }
            NSApp.activate()
        }
        window.makeKeyAndOrderFront(nil)
        bar.show(mode: .newTab)
    }

    private var isActivating = false
    private var activation: NSObjectProtocol?

    /// Where the bar is on screen, for Zigzag Mini to grow out of.
    private var barFrameOnScreen: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(content.convert(bar.panelView.frame, to: nil))
    }

    // Put away by anything that takes you elsewhere: another window, another app.
    func windowDidResignKey(_ notification: Notification) {
        guard !isActivating else { return }
        bar.dismiss(restoringFocus: false)
    }

    /// ⌘W, as on any floating panel, puts it away.
    @objc func closeTab(_ sender: Any?) { bar.dismiss(restoringFocus: false) }
}

// MARK: - The bar in it

extension MiniQuickOpen: SpaceTinted {
    var tintSpace: SpaceInfo? { Self.space }
}

extension MiniQuickOpen: CommandBarHost {
    var commandBarOverlay: NSView { content }
    var commandBarPageFrame: NSRect { content.bounds }
    func commandBarAnchor(asked: NSView?) -> NSView? { nil }
    var commandBarTabs: TabManager? { Self.tabs }
    var commandBarTab: Tab? { nil }
    var commandBarSpace: SpaceInfo? { Self.space }
    var commandBarIsPrivate: Bool { false }
    func commandBarWillShow() {}
    func commandBarRestoreFocus() {}

    func commandBarOpen(_ kind: CommandResult.Kind, modifiers: NSEvent.ModifierFlags, editing: Bool) -> Bool {
        if Self.switchToTab(kind) { return true }
        guard let (url, search) = Self.page(for: kind) else { return true }
        MiniWindowController.open(url: url, isSearch: search, from: barFrameOnScreen, overFullScreen: overFullScreen)
        return true
    }

    func commandBarDidHide() {
        activation.map(NotificationCenter.default.removeObserver)
        activation = nil
        isActivating = false
        window?.orderOut(nil)
        if Self.shown === self { Self.shown = nil }
    }
}

/// A borderless panel that takes the keyboard, so the bar in it can be typed in.
private final class QuickOpenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Where it's put, even partly over the menu bar: only its bar is ever drawn, and that is well inside the screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
