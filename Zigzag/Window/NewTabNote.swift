import AppKit

/// With the sidebar hidden, a link opened in a new tab behind the page (⌘-click, a middle click, Open Link in New
/// Tab) went without a sign that anything happened (#272). A note slides in from the sidebar's edge for a moment, with
/// the new tab's icon and title, in a toast's look. A click on it goes to the tab; the pointer on it keeps it there.
/// Links opened one after another update the one note, the latest tab's, rather than stacking.
@MainActor
final class NewTabNote {
    /// How long it stays once the pointer isn't on it.
    static let duration: TimeInterval = 2.5

    private weak var controller: BrowserWindowController?
    private var view: NewTabNoteView?
    private weak var tab: Tab?
    /// The site the tab is about to load, for a tab WebKit made empty: named until its page says what it is.
    private var site: URL?
    private var tabToken: SignalToken?
    private var hideWork: DispatchWorkItem?
    /// When it goes, while the pointer isn't on it.
    private var deadline = Date()
    /// What was left of its time when the pointer came onto it.
    private var remaining: TimeInterval?

    init(controller: BrowserWindowController) {
        self.controller = controller
    }

    /// Only with the sidebar out of sight: docked or slid out, the new row in it already says so.
    static func shows(sidebarVisible: Bool, sidebarFloating: Bool, deskVisible: Bool) -> Bool {
        !sidebarVisible && !sidebarFloating && !deskVisible
    }

    /// What it calls the tab: its title once the page has one, the site's name until then.
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

    /// A tab you opened in the background in this window, from a link.
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
            // Caught on its way out: it turns around from where it is.
            note.present()
        }
        // Another one: the same note, with the new tab in it, and its time starts over. Nothing moves.
        Announcement.post(Self.announcement(for: note.label.stringValue))
        remaining = note.isHovered ? Self.duration : nil
        if !note.isHovered { schedule(Self.duration) }
        else { hideWork?.cancel(); hideWork = nil }
    }

    /// Takes it down, if it's up.
    func hide() {
        hideWork?.cancel()
        hideWork = nil
        tabToken = nil
        remaining = nil
        guard let view, view.superview != nil, !view.dismissing else { return }
        view.dismiss()
    }

    /// The window's layout changed: the sidebar came back (or slid out), and the note steps away, or the page moved,
    /// and it stays at its corner.
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

    /// Its page said its title or sent its icon: the note shows it, keeping its corner.
    private func refresh() {
        guard let view, view.superview != nil, !view.dismissing else { return }
        fill(view)
        place(view)
    }

    /// At the top of the page, on the sidebar's side: under a page's question, as a toast is, and clear of where a
    /// link's address shows at the bottom.
    private func place(_ note: NewTabNoteView) {
        guard let controller else { return }
        let area = Toast.area(in: controller)
        let size = note.size(maxWidth: min(Self.maxWidth, max(120, area.width - Tokens.Space.x12)))
        let x = controller.root.sidebarOnRight ? area.maxX - Tokens.Space.x3 - size.width : area.minX + Tokens.Space.x3
        note.frame = NSRect(x: round(x), y: area.minY + Tokens.Space.x3, width: size.width, height: size.height)
        note.needsLayout = true
    }

    /// Long titles are cut short: it's a glance at what opened, not the page's whole name.
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

    /// The pointer on it holds it; off it, the rest of its time runs, never less than a moment to move away.
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

/// A toast that's also a button: a click anywhere on it, and the pointer coming onto it and leaving.
final class NewTabNoteView: ToastView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private(set) var isHovered = false
    private var pressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A site's icon comes at whatever size the site gave it.
        icon.imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// One line, cut short at the end: a title never wraps under its icon.
    override func size(maxWidth: CGFloat) -> NSSize {
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = false
        radius = Self.height / 2
        return NSSize(width: min(ceil(fittingWidth), maxWidth), height: Self.height)
    }

    /// The whole note takes the press, its words and icon included.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !dismissing, frame.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
