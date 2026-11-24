import AppKit
import WebKit

/// The glass card that shows a tab's page when you hover it in the sidebar: the picture inset a little, its corners
/// running with the panel's, and the title and address under it. A split is one card, as in desk view: both pages
/// where they sit on screen, and each one's title under its own side.
final class TabPreviewView: FloatingPanelView, NSTextFieldDelegate {
    private let picture = PagePicture()
    private let placeholder = FaviconView()
    private let title = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let detail = Label("", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
    private let title2 = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let detail2 = Label("", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
    /// A page's line under its address: Developer Mode, if it's in it; and if its page isn't running, why (asleep, and
    /// about how much memory that freed, or not loaded since Zigzag reopened).
    private let note = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let note2 = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let imageClip = NSView()
    /// How a split's or tile group's pages share the picture; nil for one page.
    private var shape: TileShape?
    /// The lens's caption: back, forward, the editable address, reload and Site Controls, in place of the detail line
    /// while the card is the live page.
    private let lensControls = NSView()
    let lensBack = IconButton(symbol: "chevron.left", size: .compact, toolTip: String(localized: "Back", comment: "Tooltip of the lens's Back button."))
    let lensForward = IconButton(symbol: "chevron.right", size: .compact, toolTip: String(localized: "Forward", comment: "Tooltip of the lens's Forward button."))
    let lensAddress = NSTextField()
    let lensReload = IconButton(symbol: "arrow.clockwise", size: .compact, toolTip: String(localized: "Reload", comment: "Tooltip of the lens's Reload button."))
    let lensSiteControls = IconButton(symbol: "slider.horizontal.3", size: .compact, toolTip: String(localized: "Site Controls", comment: "Name of the button by the lens's address that opens the site panel."))
    let lensClose = IconButton(symbol: "xmark", size: .compact, toolTip: String(localized: "Close", comment: "Tooltip of the lens's Close button."))
    private let lensAddressBackground = ColorView(color: NSColor.labelColor.withAlphaComponent(0.07))
    /// The live page, over the snapshot while the lens is out.
    private let liveClip = NSView()
    private var liveHolder: NSView?
    private var addressBeforeEditing = ""

    var onLensBack: (() -> Void)?
    var onLensForward: (() -> Void)?
    var onLensReload: (() -> Void)?
    var onLensAddress: ((String) -> Void)?
    var onLensSiteControls: ((IconButton) -> Void)?
    var onLensClose: (() -> Void)?

    /// The lens's bar: a standard strip on top of the card, the page under it. One size for every page, so a tab
    /// brought into the lens never moves or resizes it.
    static let lensBarHeight: CGFloat = Tokens.Space.x10

    /// While the card is the lens: the controls replace the plain detail line. Off, the browser's preview is exactly
    /// as it was.
    var showsLensControls = false {
        didSet {
            refreshCaptionVisibility()
            needsLayout = true
        }
    }

    /// The live page's shape, width over height.
    private(set) var pageAspect: CGFloat = 16.0 / 10.0

    /// The caption height this card declared when it first appeared: a card keeps one size while it is up.
    private(set) var declaredFooter: CGFloat?

    /// Fixes the caption's height for this card and returns it; later layouts use the same height.
    @discardableResult
    func declareFooter(width: CGFloat) -> CGFloat {
        if let declaredFooter { return declaredFooter }
        let footer = footerHeight(width: width)
        declaredFooter = footer
        return footer
    }

    static let footerHeight = Tokens.Metric.previewCaptionHeight
    /// The caption's height in a card this wide: taller by its note while a page in it is in Developer Mode or sleeps
    /// (three lines at most, when it's half of a split).
    func footerHeight(width: CGFloat) -> CGFloat {
        let textX = Self.textX, first = firstCaptionWidth(width)
        func height(_ label: Label, _ room: CGFloat) -> CGFloat {
            guard !label.isHidden, let cell = label.cell else { return 0 }
            return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(0, room), height: 200)).height)
        }
        return Self.footerHeight + max(height(note, first - textX * 2), height(note2, width - first - textX * 2))
    }

    private static let textX = Tokens.Space.x3 - Label.inset

    /// How far across a card this wide the first page's caption runs: all of it, or its side of a split.
    private func firstCaptionWidth(_ width: CGFloat) -> CGFloat {
        guard !title2.isHidden, let shape else { return width }
        return round(Self.inset + (width - Self.inset * 2) * (shape.isStacked ? 0.5 : shape.column))
    }
    /// From the panel's edge to the picture; the picture's corners are the panel's less this, so the two run together.
    private static let inset = Tokens.Space.x1

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageClip.wantsLayer = true
        imageClip.layer?.masksToBounds = true
        imageClip.layer?.cornerRadius = Tokens.Radius.panel - Self.inset
        imageClip.layer?.cornerCurve = .continuous
        imageClip.layer?.addSublayer(picture.layer)
        addSubview(imageClip)
        addSubview(placeholder)
        liveClip.wantsLayer = true
        liveClip.layer?.masksToBounds = true
        liveClip.layer?.cornerRadius = Tokens.Radius.panel - Self.inset
        liveClip.layer?.cornerCurve = .continuous
        liveClip.isHidden = true
        addSubview(liveClip)
        [title, detail, note, title2, detail2, note2].forEach { addSubview($0) }
        detail.identifier = NSUserInterfaceItemIdentifier("preview.detail")
        configureLensControls()
        addSubview(lensControls)
        for label in [note, note2] {
            label.usesSingleLineMode = false
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byWordWrapping
        }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A page, or with `partners`, a split's or tile group's pages, sharing the picture as `shape` says. A split's
    /// two each have their title under their side; a group's first page names the card.
    func show(tab: Tab?, bookmark: Bookmark?, partners: [Tab] = [], shape: TileShape? = nil) {
        self.shape = partners.isEmpty ? nil : shape.flatMap { $0.regions.count == partners.count + 1 ? $0 : nil }
        let partner = partners.count == 1 && self.shape != nil ? partners[0] : nil
        title.stringValue = bookmark?.title ?? tab?.displayTitle ?? ""
        let url = tab?.url ?? bookmark?.url
        detail.stringValue = url.map(CommandRanker.displayURL) ?? ""
        title2.stringValue = partner?.displayTitle ?? ""
        detail2.stringValue = partner?.url.map(CommandRanker.displayURL) ?? ""
        title2.isHidden = partner == nil
        note.stringValue = Self.note(for: tab)
        note2.stringValue = Self.note(for: partner)
        refreshCaptionVisibility()
        placeholder.image = tab?.displayIcon ?? bookmark?.displayIcon
        setImages([tab?.snapshot] + partners.map(\.snapshot))
        needsLayout = true
    }

    /// The line under a page's address: that it's in Developer Mode (#141), and why its page isn't running: asleep,
    /// or not loaded since Zigzag reopened (#205).
    private static func note(for tab: Tab?) -> String {
        [tab?.isDevelopment == true ? DeveloperTool.modeName : nil, tab?.notLoadedNote].compactMap { $0 }.joined(separator: "\n")
    }

    /// Each page's picture, in order.
    func setImages(_ pictures: [NSImage?]) {
        let count = shape?.regions.count ?? 1
        let shown = Array(pictures.prefix(count))
        picture.show(shown, shape: shape)
        let empty = shown.allSatisfy { $0 == nil }
        placeholder.isHidden = !empty
        Tokens.Motion.withoutAnimation { picture.layer.isHidden = empty }
        refreshColors()
    }

    /// The live page, over the snapshot while the lens is out.
    func showLive(holder: NSView) {
        if holder.bounds.width > 1, holder.bounds.height > 1 {
            pageAspect = holder.bounds.width / holder.bounds.height
        }
        // Only a page still in the clip belongs to it. A page already put back in its tab is not taken again.
        if liveHolder?.superview === liveClip { liveHolder?.removeFromSuperview() }
        liveHolder = holder
        liveClip.addSubview(holder)
        holder.frame = liveClip.bounds
        holder.autoresizingMask = [.width, .height]
        liveClip.alphaValue = 0
        liveClip.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            liveClip.animator().alphaValue = 1
        }
    }

    /// The page left: the snapshot is the card's picture again. A page the close already put back in its tab stays
    /// there; only a page still in the live clip is taken out.
    func endLive() {
        if liveHolder?.superview === liveClip { liveHolder?.removeFromSuperview() }
        liveHolder = nil
        liveClip.isHidden = true
    }

    /// The live page's address and controls, as the browser shows them.
    func updateLens(address: String, canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        if lensAddress.currentEditor() == nil { lensAddress.stringValue = address }
        addressBeforeEditing = address
        lensBack.isEnabled = canGoBack
        lensForward.isEnabled = canGoForward
        lensReload.isLoading = isLoading
    }

    @objc func submitLensAddress() {
        onLensAddress?(lensAddress.stringValue)
        window?.makeFirstResponder(nil)
    }

    /// ⌘L in the lens: the address is selected, ready to type over.
    func focusLensAddress() {
        window?.makeFirstResponder(lensAddress)
        lensAddress.currentEditor()?.selectAll(nil)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        addressBeforeEditing = lensAddress.stringValue
        lensAddress.currentEditor()?.selectAll(nil)
    }

    /// Esc in the address puts the page's address back and keeps the lens; the next Esc closes it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === lensAddress else { return false }
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        lensAddress.stringValue = addressBeforeEditing
        window?.makeFirstResponder(nil)
        return true
    }

    private func refreshCaptionVisibility() {
        lensControls.isHidden = !showsLensControls
        title.isHidden = showsLensControls
        title2.isHidden = showsLensControls || title2.stringValue.isEmpty
        detail.isHidden = showsLensControls
        note.isHidden = showsLensControls || note.stringValue.isEmpty
        detail2.isHidden = showsLensControls || title2.isHidden
        note2.isHidden = showsLensControls || note2.stringValue.isEmpty
    }

    private func configureLensControls() {
        lensControls.identifier = NSUserInterfaceItemIdentifier("preview.lensControls")
        lensBack.identifier = NSUserInterfaceItemIdentifier("preview.lensBack")
        lensForward.identifier = NSUserInterfaceItemIdentifier("preview.lensForward")
        lensReload.identifier = NSUserInterfaceItemIdentifier("preview.lensReload")
        lensSiteControls.identifier = NSUserInterfaceItemIdentifier("preview.lensSiteControls")
        lensClose.identifier = NSUserInterfaceItemIdentifier("preview.lensClose")
        liveClip.identifier = NSUserInterfaceItemIdentifier("preview.live")
        lensAddress.identifier = NSUserInterfaceItemIdentifier("preview.lensAddress")
        lensAddressBackground.layer?.cornerRadius = Tokens.Radius.field
        lensAddressBackground.layer?.cornerCurve = .continuous
        lensAddress.isBordered = false
        lensAddress.drawsBackground = false
        lensAddress.focusRingType = .none
        lensAddress.font = .systemFont(ofSize: Tokens.Pane.addressText)
        lensAddress.textColor = Tokens.Color.textPrimary
        lensAddress.lineBreakMode = .byTruncatingTail
        lensAddress.usesSingleLineMode = true
        lensAddress.delegate = self
        lensAddress.target = self
        lensAddress.action = #selector(submitLensAddress)
        [lensBack, lensForward, lensAddressBackground, lensReload, lensSiteControls, lensClose].forEach(lensControls.addSubview)
        lensAddressBackground.addSubview(lensAddress)
        lensBack.onClick = { [weak self] _ in
            guard self?.lensBack.isEnabled == true else { return }
            self?.onLensBack?()
        }
        lensForward.onClick = { [weak self] _ in
            guard self?.lensForward.isEnabled == true else { return }
            self?.onLensForward?()
        }
        lensReload.onClick = { [weak self] _ in self?.onLensReload?() }
        lensSiteControls.onClick = { [weak self] _ in
            guard let self else { return }
            self.onLensSiteControls?(self.lensSiteControls)
        }
        lensClose.onClick = { [weak self] _ in self?.onLensClose?() }
        lensControls.isHidden = true
    }

    private func layoutLensControls() {
        let button = Tokens.Pane.button
        let height = lensControls.bounds.height
        let y = (height - button) / 2
        lensBack.frame = NSRect(x: 0, y: y, width: button, height: button)
        lensForward.frame = NSRect(x: lensBack.frame.maxX + Tokens.Space.x1, y: y, width: button, height: button)
        lensClose.frame = NSRect(x: lensControls.bounds.width - button, y: y, width: button, height: button)
        lensSiteControls.frame = NSRect(x: lensClose.frame.minX - button - Tokens.Space.x1, y: y,
                                        width: button, height: button)
        lensReload.frame = NSRect(x: lensSiteControls.frame.minX - button - Tokens.Space.x1, y: y,
                                  width: button, height: button)
        let addressX = lensForward.frame.maxX + Tokens.Space.x2
        let addressRight = lensReload.frame.minX - Tokens.Space.x2
        let addressHeight = Tokens.Pane.addressHeight
        lensAddressBackground.frame = NSRect(x: addressX, y: (height - addressHeight) / 2,
                                            width: max(0, addressRight - addressX), height: addressHeight)
        lensAddress.frame = lensAddressBackground.bounds.insetBy(dx: Tokens.Space.x2, dy: 0)
    }

    /// With no picture yet, a soft wash of the space under the site's icon instead of a blank white page, as the tab
    /// switcher's cards have.
    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            picture.dividerColor = cgColor(Tokens.Color.cardEdge)
            imageClip.layer?.backgroundColor = cgColor(placeholder.isHidden ? Tokens.Color.cardBackground : Brand.Theme.for(self).wash)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func layoutContent() {
        let pad = Self.inset
        // The height the card was sized with, not what its caption happens to say this pass.
        let footer = declaredFooter ?? footerHeight(width: bounds.width)
        if showsLensControls {
            // The lens: the standard bar on top, the page under it, one size for every page.
            lensControls.frame = NSRect(x: Self.textX, y: bounds.height - Self.lensBarHeight,
                                        width: max(0, bounds.width - Self.textX * 2), height: Self.lensBarHeight)
            layoutLensControls()
            imageClip.frame = NSRect(x: pad, y: pad, width: max(0, bounds.width - pad * 2),
                                     height: max(0, bounds.height - Self.lensBarHeight - pad * 2))
        } else {
            imageClip.frame = NSRect(x: pad, y: pad, width: bounds.width - pad * 2, height: bounds.height - footer - pad)
        }
        liveClip.frame = imageClip.frame
        picture.layout(size: imageClip.bounds.size)
        Tokens.Motion.withoutAnimation { picture.layer.position = CGPoint(x: imageClip.bounds.midX, y: imageClip.bounds.midY) }
        let icon = Tokens.Space.x8
        placeholder.frame = NSRect(x: imageClip.frame.midX - icon / 2, y: imageClip.frame.midY - icon / 2, width: icon, height: icon)
        let textX = Self.textX
        let titleH = title.lineHeight, detailH = detail.lineHeight
        let noteH = footer - Self.footerHeight
        let top = imageClip.frame.maxY + (Self.footerHeight - titleH - detailH) / 2
        // One title, or with a split, each page's under its own side; stacked pages share the row half and half.
        let firstWidth = firstCaptionWidth(bounds.width)
        if !showsLensControls {
            title.frame = NSRect(x: textX, y: top, width: firstWidth - textX * 2, height: titleH)
            detail.frame = NSRect(x: textX, y: title.frame.maxY, width: firstWidth - textX * 2, height: detailH)
            note.frame = NSRect(x: textX, y: detail.frame.maxY, width: firstWidth - textX * 2, height: noteH)
            let secondX = firstWidth + textX, secondWidth = max(0, bounds.width - firstWidth - textX * 2)
            title2.frame = NSRect(x: secondX, y: top, width: secondWidth, height: titleH)
            detail2.frame = NSRect(x: secondX, y: title2.frame.maxY, width: secondWidth, height: detailH)
            note2.frame = NSRect(x: secondX, y: detail2.frame.maxY, width: secondWidth, height: noteH)
        }
    }

    /// The area the pages' pictures fill: what a caption changing must leave exactly where it is.
    var pictureArea: NSRect { imageClip.frame }
}

/// Shows previews after a short hover, then follows the pointer from row to row without delay.
final class TabPreviewController {
    private weak var controller: BrowserWindowController?
    private var panel: TabPreviewView?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    /// When the card has finished sliding out. Until then the pictures it shows are the ones it appeared with, so
    /// tiles don't change size under the entrance as live snapshots land.
    private var settlesAt: CFTimeInterval = 0
    private weak var tab: Tab?
    private weak var row: NSView?
    private var snapshotTokens: [SignalToken] = []
    private struct WeakPage { weak var tab: Tab? }
    /// Hover can end without a word: the row closes under the pointer, or you switch apps. This checks while a
    /// preview is up and takes it away once the pointer has really left.
    private var watchTimer: Timer?
    /// A click in the sidebar puts the preview away at once.
    nonisolated(unsafe) private var clickMonitor: Any?
    #if DEBUG
    /// The debug bridge's hover: this row counts as under the pointer, wherever the real one is.
    weak var debugRow: NSView?
    #endif

    /// A menu is open (row context menu or menu bar): no preview half under it.
    private var menuOpen = false
    // Set once in init and only let go in deinit.
    nonisolated(unsafe) private var menuTokens: [NSObjectProtocol] = []

    init(controller: BrowserWindowController) {
        self.controller = controller
        let center = NotificationCenter.default
        menuTokens = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuOpen = true; self?.hide() }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuOpen = false }
            },
        ]
    }

    deinit {
        menuTokens.forEach(NotificationCenter.default.removeObserver)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    func hover(_ tab: Tab?, row: NSView?, bookmark: Bookmark?) {
        // No preview over an open panel or menu, or for a tab under the mini player while hovering or dragging it.
        guard !menuOpen, controller?.hasFloatingPanel != true, controller?.miniPlayer.isUnderPointer != true, let row, tab != nil || bookmark != nil else {
            // One about to appear doesn't: leaving the row, or starting to drag it, means you've moved on.
            showWork?.cancel()
            showWork = nil
            scheduleHide()
            return
        }
        hideWork?.cancel()
        // No preview for the page you're already looking at, or the split it's in.
        if let tab, let selected = controller?.tabManager.selectedTab,
           controller?.tabManager.panes(of: tab).contains(where: { $0 === selected }) == true {
            scheduleHide(immediately: true)
            return
        }
        if panel != nil {
            present(tab, bookmark: bookmark, row: row)
        } else {
            showWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak row] in
                MainActor.assumeIsolated {
                    // Pressed meanwhile (a click or the start of a drag): no preview.
                    guard let self, let row, !self.menuOpen, self.isPointer(over: row), NSEvent.pressedMouseButtons == 0,
                          self.controller?.miniPlayer.isUnderPointer != true else { return }
                    self.present(tab, bookmark: bookmark, row: row)
                }
            }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.previewDelay, execute: work)
        }
    }

    private func present(_ tab: Tab?, bookmark: Bookmark?, row: NSView) {
        guard let controller else { return }
        let overlay = controller.root.overlay
        let isNew = panel == nil
        let panel = self.panel ?? TabPreviewView()
        self.panel = panel
        self.row = row
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let controller = self.controller, event.window === controller.window else { return }
                    if controller.root.sidebarFrame.contains(event.locationInWindow) { self.hide() }
                }
                return event
            }
        }
        // A split's row is one card: its first page, then the other, laid out as they share the window.
        let manager = controller.tabManager
        let pair = tab.flatMap { manager.split(for: $0) }
        let grouped = tab.map { manager.panes(of: $0) } ?? []
        let pages = pair != nil && grouped.count == pair?.count ? grouped : [tab].compactMap { $0 }
        let first = pages.first ?? tab
        let partners = Array(pages.dropFirst())
        let refs = pages.map { WeakPage(tab: $0) }
        self.tab = first
        panel.show(tab: first, bookmark: bookmark, partners: partners, shape: pages.count > 1 ? pair?.shape : nil)
        if watchTimer == nil {
            watchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkStillHovering() }
            }
            watchTimer?.tolerance = 0.1
        }
        snapshotTokens = pages.map { page in
            page.changed.observe { [weak self, weak first] change in
                guard change == .snapshot, let self, let first, first === self.tab,
                      CACurrentMediaTime() >= self.settlesAt else { return }
                self.panel?.setImages(refs.map { $0.tab?.snapshot })
            }
        }

        let card = controller.root.cardFrame
        let width = Tokens.Metric.previewWidth
        let aspect = card.height > 0 ? min(card.height / max(card.width, 1), 0.9) : 0.62
        // A card declares one size and keeps it, so a note coming or going can't move the pictures under it.
        let height = isNew ? round(width * aspect) + panel.declareFooter(width: width) : panel.bounds.height
        let rowFrame = row.convert(row.bounds, to: overlay)
        // Beside the sidebar, over the page: right of it, or left of it on the right.
        let x = controller.root.besideSidebar(width: width)
        var y = rowFrame.midY - height / 2
        y = max(Tokens.Metric.cardInset * 2, min(y, overlay.bounds.height - height - Tokens.Metric.cardInset * 2))
        let frame = NSRect(x: x, y: round(y), width: width, height: height)

        if isNew {
            panel.frame = frame
            overlay.addSubview(panel)
            // The card comes out of the sidebar's side at the size it keeps. Growing it from a point scaled every
            // tile inside by 96% and back, which read as the pane resizing into place rather than the card arriving.
            panel.attachedEdge = controller.root.sidebarOnRight ? .maxX : .minX
            panel.present()
            // Tiles 2-4 used to change scale while the card was still sliding out: their cached snapshots were
            // full-window, the live pages were recaptured the moment the card was asked for, and each new picture
            // re-covered its tile at a different scale. The hovered page was already fresh, which is why only the
            // others moved. Let the entrance finish on the pictures it began with.
            settlesAt = CACurrentMediaTime() + Tokens.Motion.enter * Tokens.Motion.debugSlowdown
        } else {
            settlesAt = 0
            // Only its place follows the pointer; its size stays the one it declared on the way out.
            var next = frame
            next.size = panel.bounds.size
            if panel.frame != next {
                Tokens.Motion.animate(Tokens.Motion.snappy, moves: true) { panel.animator().frame = next }
            }
        }
        // Live pages refresh while you look at the preview.
        refreshTimer?.invalidate()
        let live = pages.filter { !$0.isSuspended }
        keepWatched()
        watched = live
        if !live.isEmpty {
            // In memory while you watch; written to disk once, when the preview goes. A card coming out waits for
            // its entrance to finish, so a snapshot landing mid-slide can't resize a tile under it; one already
            // out refreshes at once.
            if isNew {
                DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.standard * Tokens.Motion.debugSlowdown) { [weak self, weak first] in
                    MainActor.assumeIsolated {
                        guard let self, let first, self.tab === first else { return }
                        refs.forEach { if let page = $0.tab, !page.isSuspended { page.captureSnapshot(keep: false) } }
                        self.panel?.setImages(refs.map { $0.tab?.snapshot })
                    }
                }
            } else {
                live.forEach { $0.captureSnapshot(keep: false) }
            }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    refs.forEach { if let page = $0.tab, !page.isSuspended { page.captureSnapshot(keep: false) } }
                }
            }
            // Roughly once a second is plenty; slack lets the system batch the wake-ups.
            refreshTimer?.tolerance = 0.3
        }
    }

    /// The live pages the preview refreshed, whose last picture is saved when it stops watching them.
    private var watched: [Tab] = []

    private func keepWatched() {
        watched.forEach { if !$0.isClosed { $0.keepSnapshot() } }
        watched = []
    }

    private func scheduleHide(immediately: Bool = false) {
        showWork?.cancel()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.12), execute: work)
    }

    /// The pointer is over this row, in the front window of the active app.
    private func isPointer(over row: NSView) -> Bool {
        #if DEBUG
        // Scripts drive a copy that may stay in the background, so neither the app's focus nor the pointer counts.
        if row === debugRow { return row.window?.isVisible == true && !row.isHiddenOrHasHiddenAncestor }
        #endif
        guard NSApp.isActive, let window = row.window, window.isVisible, !row.isHiddenOrHasHiddenAncestor else { return false }
        return row.bounds.contains(row.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func checkStillHovering() {
        guard let row, tab?.isClosed != true, controller?.hasFloatingPanel != true else { hide(); return }
        // Onto the mini player over the row: the preview goes at once, so it never covers the card you're on.
        if controller?.miniPlayer.isUnderPointer == true { hide(); return }
        // Moving on to the next row cancels this, so only really leaving ends the preview.
        if !isPointer(over: row) { scheduleHide() }
    }

    func hide() {
        showWork?.cancel()
        watchTimer?.invalidate()
        watchTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        keepWatched()
        snapshotTokens = []
        guard let panel else { return }
        self.panel = nil
        panel.dismiss()
    }
}
