import AppKit

/// With the sidebar hidden, a link opened in a background tab (⌘-click, middle click, Open Link in New Tab) gave no
/// feedback (#272). The tab's own sidebar row slides out from the sidebar's edge at the place it has in the list, holds,
/// then glides back in. Each new tab gets its own row; its title and spinner follow the page as it loads. Clicking one
/// goes to its tab; hovering any holds them all.
@MainActor
final class NewTabNote {
    /// How long each row stays without hover.
    static let duration: TimeInterval = 2.5

    private weak var controller: BrowserWindowController?
    /// Showing, oldest first.
    private(set) var peeks: [NewTabPeekView] = []
    /// The pointer is on one of them: every hold waits.
    private var hovering = false

    init(controller: BrowserWindowController) {
        self.controller = controller
    }

    /// Only with the sidebar hidden; docked or slid out, the new row shows there already.
    static func shows(sidebarVisible: Bool, sidebarFloating: Bool, deskVisible: Bool) -> Bool {
        !sidebarVisible && !sidebarFloating && !deskVisible
    }

    /// What a row says while WebKit's empty tab has no page yet: the site it's about to load. Nil once the tab has a
    /// page, so the row reads the tab's own title, as the sidebar's does.
    static func placeholder(for tab: Tab, site: URL?) -> String? {
        guard tab.isBlank, tab.customTitle?.isEmpty ?? true, let host = site?.host(), !host.isEmpty else { return nil }
        return host
    }

    static func announcement(for title: String) -> String {
        String(localized: "Opened \(title) in background", comment: "Said by VoiceOver when a link opens in a new tab behind the page while the sidebar is hidden. The placeholder is the tab's title, or its site.")
    }

    var isShowing: Bool { peeks.contains { !$0.dismissing } }

    #if DEBUG
    /// Each row's frame from the window's top left, and its title.
    var debugPeeks: [(NSRect, String)] {
        peeks.compactMap { peek in
            guard !peek.dismissing, let window = peek.window else { return nil }
            let r = peek.convert(peek.bounds, to: nil)
            return (NSRect(x: r.minX, y: window.frame.height - r.maxY, width: r.width, height: r.height), peek.row.title.stringValue)
        }
    }

    /// Clicks the row at `index`, as the pointer would.
    func debugClick(_ index: Int) {
        let shown = peeks.filter { !$0.dismissing }
        guard shown.indices.contains(index) else { return }
        shown[index].onClick?()
    }
    #endif

    /// A background tab opened from a link in this window.
    func show(_ tab: Tab, site: URL? = nil) {
        guard let controller, !controller.tabManager.isPrivate,
              Self.shows(sidebarVisible: controller.root.sidebarVisible, sidebarFloating: controller.root.isSidebarFloatingVisible,
                         deskVisible: controller.desk.isVisible),
              !peeks.contains(where: { $0.tab === tab }) else { return }
        let peek = NewTabPeekView(tab: tab, site: site)
        peek.onClick = { [weak self, weak peek] in self?.go(to: peek?.tab) }
        peek.onClose = { [weak self, weak peek] in
            guard let self, let peek else { return }
            if let tab = peek.tab { self.controller?.closeWithUndo(tab) }
            self.dismiss(peek)
        }
        peek.onHover = { [weak self] in self?.hoverChanged() }
        peek.slidesFromSide = controller.root.sidebarOnRight ? .maxX : .minX
        peeks.append(peek)
        controller.root.overlay.addSubview(peek)
        place()
        peek.present()
        Announcement.post(Self.announcement(for: peek.row.title.stringValue))
        schedule(peek, Self.duration * Tokens.Motion.debugSlowdown)
    }

    /// Sends every row back in.
    func hide() {
        for peek in peeks { dismiss(peek) }
    }

    /// Layout changed: gone if the sidebar came back or slid out, else each row follows its place.
    func reposition() {
        guard let controller, !peeks.isEmpty else { return }
        guard Self.shows(sidebarVisible: controller.root.sidebarVisible, sidebarFloating: controller.root.isSidebarFloatingVisible,
                         deskVisible: controller.desk.isVisible) else { hide(); return }
        for peek in peeks { peek.slidesFromSide = controller.root.sidebarOnRight ? .maxX : .minX }
        place(animated: true)
    }

    /// The list changed: a row for a tab that closed, or that you went to, goes; the rest follow their places.
    func listChanged() {
        guard let controller, !peeks.isEmpty else { return }
        let selected = controller.tabManager.selectedTab
        for peek in peeks {
            let open = peek.tab.map { tab in !tab.isClosed && tab !== selected && controller.tabManager.allTabs.contains { $0 === tab } } ?? false
            if !open { dismiss(peek) }
        }
        place(animated: true)
    }

    private func dismiss(_ peek: NewTabPeekView) {
        peek.hold?.cancel()
        peek.hold = nil
        peeks.removeAll { $0 === peek }
        if !peek.dismissing, peek.superview != nil { peek.dismiss() }
        hoverChanged()
    }

    /// Where each row goes in the overlay: at its tab's row in the hidden sidebar's list, as if the sidebar were out.
    private func place(animated: Bool = false) {
        guard let controller else { return }
        let root = controller.root, overlay = root.overlay, list = controller.sidebar.list
        guard let clip = list.enclosingScrollView?.contentView else { return }
        // From where the hidden sidebar sits to where it sits slid out.
        let out = BrowserRootView.sidebarFrame(in: root.bounds, width: root.sidebarWidth, visible: false, revealed: true, onRight: root.sidebarOnRight)
        let dx = out.minX - root.sidebarContainer.frame.minX
        let visible = clip.convert(clip.bounds, to: overlay).offsetBy(dx: dx, dy: 0)
        let rows: [NSRect?] = peeks.map { peek in
            guard let tab = peek.tab, let frame = list.layoutFrame(ofTab: tab.id) else { return nil }
            return list.convert(frame, to: overlay).offsetBy(dx: dx, dy: 0)
        }
        let height = Tokens.Sidebar.rowHeight
        let ys = Self.slots(rows: rows.map { $0?.minY }, visible: visible.minY...max(visible.minY, visible.maxY), height: height, gap: Tokens.Sidebar.rowGap)
        for (i, peek) in peeks.enumerated() {
            let row = rows[i] ?? NSRect(x: visible.minX, y: 0, width: visible.width, height: height)
            let target = NSRect(x: row.minX, y: ys[i], width: row.width, height: height)
            guard peek.frame != target else { continue }
            if animated, peek.frame.width > 0 {
                Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true, moves: true) { peek.animator().frame = target }
            } else {
                peek.frame = target
            }
        }
    }

    /// Each row's y (top-down): at its row in the list when that's in sight. One scrolled past or in a closed folder
    /// (nil) comes out at the nearest end of the list in sight instead, stacked inward in list order, clear of the rest.
    nonisolated static func slots(rows: [CGFloat?], visible: ClosedRange<CGFloat>, height: CGFloat, gap: CGFloat) -> [CGFloat] {
        var result = [CGFloat](repeating: 0, count: rows.count)
        var taken: [CGFloat] = []
        var above: [Int] = [], below: [Int] = []
        for (i, y) in rows.enumerated() {
            if let y, y >= visible.lowerBound, y + height <= visible.upperBound {
                result[i] = y
                taken.append(y)
            } else if let y, y < visible.lowerBound {
                above.append(i)
            } else {
                below.append(i)
            }
        }
        func free(_ y: CGFloat) -> Bool { !taken.contains { abs($0 - y) < height } }
        // Above: nearest the top, in list order down from it.
        var y = visible.lowerBound
        for i in above.sorted(by: { rows[$0]! < rows[$1]! }) {
            while !free(y), y + height < visible.upperBound { y += height + gap }
            result[i] = y
            taken.append(y)
            y += height + gap
        }
        // Below: the last in the list lowest, going up.
        y = visible.upperBound - height
        for i in below.sorted(by: { (rows[$0] ?? .infinity) > (rows[$1] ?? .infinity) }) {
            while !free(y), y > visible.lowerBound { y -= height + gap }
            result[i] = y
            taken.append(y)
            y -= height + gap
        }
        return result
    }

    private func schedule(_ peek: NewTabPeekView, _ delay: TimeInterval) {
        peek.hold?.cancel()
        peek.hold = nil
        guard !hovering else { peek.remaining = delay; return }
        peek.deadline = Date().addingTimeInterval(delay)
        peek.remaining = nil
        let work = DispatchWorkItem { [weak self, weak peek] in
            MainActor.assumeIsolated {
                guard let self, let peek else { return }
                self.dismiss(peek)
            }
        }
        peek.hold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The pointer came onto a row or left them all: every hold waits, then resumes with what it had left (at least a
    /// second, to move away).
    private func hoverChanged() {
        let now = peeks.contains { $0.row.isHovered && !$0.dismissing }
        guard now != hovering else { return }
        hovering = now
        for peek in peeks {
            if now {
                peek.remaining = max(peek.deadline.timeIntervalSinceNow, 0)
                peek.hold?.cancel()
                peek.hold = nil
            } else {
                schedule(peek, max(peek.remaining ?? Self.duration * Tokens.Motion.debugSlowdown, 1))
            }
        }
    }

    /// The tab, with the sidebar slid out at its row.
    private func go(to tab: Tab?) {
        guard let controller, let tab, controller.tabManager.allTabs.contains(where: { $0 === tab }) else { hide(); return }
        controller.tabManager.select(tab)
        hide()
        _ = controller.sidebar.list.tabRow(tab.id)
        controller.root.reveal(true)
    }
}

/// A new background tab's row out from the hidden sidebar: the sidebar's own tab row, on a panel's surface.
final class NewTabPeekView: FloatingPanelView {
    let row = TabRowView()
    private(set) weak var tab: Tab?
    private let site: URL?
    private var token: SignalToken?
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: (() -> Void)?
    /// Its going back in, while it holds.
    var hold: DispatchWorkItem?
    /// When it goes back in, without hover.
    var deadline = Date()
    /// Time it had left when a hover began.
    var remaining: TimeInterval?

    init(tab: Tab, site: URL?) {
        self.tab = tab
        self.site = site
        super.init(frame: .zero)
        radius = Tokens.Sidebar.rowRadius
        addSubview(row)
        row.configure(tab: tab)
        row.onClick = { [weak self] _ in self?.onClick?() }
        row.onClose = { [weak self] in self?.onClose?() }
        row.onMiddleClick = row.onClose
        row.hoverChanged = { [weak self] _ in self?.onHover?() }
        token = tab.changed.observe { [weak self] change in
            if change == .url || change == .title { self?.refreshTitle() }
        }
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refreshTitle() {
        guard let tab else { return }
        row.fixedTitle = NewTabNote.placeholder(for: tab, site: site)
    }

    override func layout() {
        super.layout()
        row.frame = bounds
    }
}
