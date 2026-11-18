import AppKit

/// With the sidebar hidden, a link opened in a background tab (⌘-click, middle click, Open Link in New Tab) gave no
/// feedback (#272). A toast-style note slides in from the sidebar's edge with the tab's icon and title. Clicking it
/// selects the tab; hovering keeps it. Further links update the same note instead of stacking.
@MainActor
final class NewTabNote {
    /// How long it stays without hover.
    static let duration: TimeInterval = 2.5

    private weak var controller: BrowserWindowController?
    private var view: NewTabNoteView?
    private weak var tab: Tab?
    /// The site for a tab WebKit created empty; shown until the page has a title.
    private var site: URL?
    private var tabToken: SignalToken?
    private var hideWork: DispatchWorkItem?
    /// When it hides, without hover.
    private var deadline = Date()
    /// Time left when hover began.
    private var remaining: TimeInterval?

    init(controller: BrowserWindowController) {
        self.controller = controller
    }

    /// Only with the sidebar hidden; docked or floating, the new row shows it already.
    static func shows(sidebarVisible: Bool, sidebarFloating: Bool, deskVisible: Bool) -> Bool {
        !sidebarVisible && !sidebarFloating && !deskVisible
    }

    /// The tab's title once it has one, the site's name until then.
    static func title(of tab: Tab, site: URL?) -> String {
        if tab.isBlank, let host = site?.host(), !host.isEmpty { return host.withoutWWW }
        let title = tab.displayTitle
        if title == tab.url?.host(), let host = tab.url?.host() { return host.withoutWWW }
        return title
    }

    static func announcement(for title: String) -> String {
        String(localized: "Opened in new tab: \(title)", comment: "Said by VoiceOver when a link opens in a new tab behind the page while the sidebar is hidden. The placeholder is the tab's title, or its site.")
    }

    var isShowing: Bool { view?.superview != nil && view?.dismissing == false }

    #if DEBUG
    /// Its frame from the window's top left while shown.
    var debugFrame: NSRect? {
        guard isShowing, let view, let window = view.window else { return nil }
        let r = view.convert(view.bounds, to: nil)
        return NSRect(x: r.minX, y: window.frame.height - r.maxY, width: r.width, height: r.height)
    }
    #endif

    /// A background tab opened from a link in this window.
    func show(_ tab: Tab, site: URL? = nil) {
        guard let controller, Self.shows(sidebarVisible: controller.root.sidebarVisible, sidebarFloating: controller.root.isSidebarFloatingVisible,
                                         deskVisible: controller.desk.isVisible) else { return }
        self.tab = tab
        self.site = site
        tabToken = tab.changed.observe { [weak self] change in
            guard [.title, .favicon, .url, .renamed].contains(change) else { return }
            self?.refresh()
        }
        let note: NewTabNoteView
        let isNew: Bool
        if let existing = view, existing.superview === controller.root.overlay {
            note = existing
            isNew = false
            if controller.root.overlay.subviews.last !== existing {
                controller.root.overlay.addSubview(existing, positioned: .above, relativeTo: nil)
            }
        } else {
            note = NewTabNoteView()
            note.onClick = { [weak self] in self?.goToTab() }
            note.onHover = { [weak self] inside in self?.hovered(inside) }
            view = note
            isNew = true
        }
        fill(note)
        note.slidesFromSide = controller.root.sidebarOnRight ? .maxX : .minX
        place(note)
        if isNew {
            controller.root.overlay.addSubview(note)
            note.present()
        } else if note.dismissing {
            // Caught while hiding: reverse from where it is.
            note.present()
        }
        // Already showing: update it with the new tab and restart its timer, without moving.
        Announcement.post(Self.announcement(for: note.label.stringValue))
        remaining = note.isHovered ? Self.duration : nil
        if !note.isHovered { schedule(Self.duration) }
        else { hideWork?.cancel(); hideWork = nil }
    }

    /// Hides it if shown.
    func hide() {
        hideWork?.cancel()
        hideWork = nil
        tabToken = nil
        remaining = nil
        guard let view, view.superview != nil, !view.dismissing else { return }
        view.dismiss()
    }

    /// Layout changed: hide if the sidebar came back or slid out, else keep it at its corner.
    func reposition() {
        guard let controller, let view, view.superview != nil, !view.dismissing else { return }
        guard Self.shows(sidebarVisible: controller.root.sidebarVisible, sidebarFloating: controller.root.isSidebarFloatingVisible,
                         deskVisible: controller.desk.isVisible) else { hide(); return }
        view.slidesFromSide = controller.root.sidebarOnRight ? .maxX : .minX
        place(view)
    }

    private func fill(_ note: NewTabNoteView) {
        guard let tab else { return }
        note.icon.image = tab.displayIcon ?? FaviconView.globeIcon
        note.label.stringValue = Self.title(of: tab, site: site)
        note.setAccessibilityLabel(Self.announcement(for: note.label.stringValue))
    }

    /// The page sent its title or icon: update, keeping position.
    private func refresh() {
        guard let view, view.superview != nil, !view.dismissing else { return }
        fill(view)
        place(view)
    }

    /// At the top of the page on the sidebar's side, below any page question (like a toast), away from the bottom link
    /// status.
    private func place(_ note: NewTabNoteView) {
        guard let controller else { return }
        let area = Toast.area(in: controller)
        let size = note.size(maxWidth: min(Self.maxWidth, max(120, area.width - Tokens.Space.x12)))
        let x = controller.root.sidebarOnRight ? area.maxX - Tokens.Space.x3 - size.width : area.minX + Tokens.Space.x3
        note.frame = NSRect(x: round(x), y: area.minY + Tokens.Space.x3, width: size.width, height: size.height)
        note.needsLayout = true
    }

    /// Long titles are truncated.
    static let maxWidth: CGFloat = 320

    private func schedule(_ delay: TimeInterval) {
        hideWork?.cancel()
        deadline = Date().addingTimeInterval(delay)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hideWork = nil
                self?.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Hover holds it; leaving resumes the remaining time, with a short minimum.
    private func hovered(_ inside: Bool) {
        guard let view, view.superview != nil, !view.dismissing else { return }
        if inside {
            remaining = max(deadline.timeIntervalSinceNow, 0)
            hideWork?.cancel()
            hideWork = nil
        } else {
            schedule(max(remaining ?? Self.duration, 1))
            remaining = nil
        }
    }

    private func goToTab() {
        defer { hide() }
        guard let controller, let tab, controller.tabManager.allTabs.contains(where: { $0 === tab }) else { return }
        controller.tabManager.select(tab)
    }
}

/// A toast that's a button: handles clicks anywhere and hover.
final class NewTabNoteView: ToastView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private(set) var isHovered = false
    private var pressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Site icons come in any size.
        icon.imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Single line, truncated at the end.
    override func size(maxWidth: CGFloat) -> NSSize {
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = false
        radius = Self.height / 2
        return NSSize(width: min(ceil(fittingWidth), maxWidth), height: Self.height)
    }

    /// The whole note takes the press, label and icon included.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !dismissing, frame.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The window swallows panel surface presses; this one is a button.
    override var takesPress: Bool { true }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover?(false)
    }
}
