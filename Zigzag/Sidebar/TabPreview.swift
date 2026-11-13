import AppKit
import WebKit

/// The glass card that shows a tab's page when you hover it in the sidebar: the picture inset a little, its corners
/// running with the panel's, and the title and address under it. A split is one card, as in desk view: both pages
/// where they sit on screen, and each one's title under its own side.
final class TabPreviewView: FloatingPanelView {
    private let picture = PagePicture()
    private let placeholder = FaviconView()
    private let title = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let detail = Label("", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
    private let title2 = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let detail2 = Label("", font: Tokens.Font.small(), color: Tokens.Color.textTertiary)
    /// A page's line under its address: Developer Mode, if it's in it; and if it sleeps, why, and about how much memory
    /// that freed.
    private let note = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let note2 = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let imageClip = NSView()
    /// How a split's or tile group's pages share the picture; nil for one page.
    private var shape: TileShape?
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
        [title, detail, note, title2, detail2, note2].forEach { addSubview($0) }
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
        detail2.isHidden = partner == nil
        note.stringValue = Self.note(for: tab)
        note.isHidden = note.stringValue.isEmpty
        note2.stringValue = Self.note(for: partner)
        note2.isHidden = note2.stringValue.isEmpty
        placeholder.image = tab?.displayIcon ?? bookmark?.displayIcon
        setImages([tab?.snapshot] + partners.map(\.snapshot))
        needsLayout = true
    }

    /// The line under a page's address: that it's in Developer Mode (#141), and why it sleeps.
    private static func note(for tab: Tab?) -> String {
        [tab?.isDevelopment == true ? DeveloperTool.modeName : nil, tab?.asleepNote].compactMap { $0 }.joined(separator: "\n")
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
        let footer = footerHeight(width: bounds.width)
        imageClip.frame = NSRect(x: pad, y: pad, width: bounds.width - pad * 2, height: bounds.height - footer - pad)
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
        title.frame = NSRect(x: textX, y: top, width: firstWidth - textX * 2, height: titleH)
        detail.frame = NSRect(x: textX, y: title.frame.maxY, width: firstWidth - textX * 2, height: detailH)
        note.frame = NSRect(x: textX, y: detail.frame.maxY, width: firstWidth - textX * 2, height: noteH)
        let secondX = firstWidth + textX, secondWidth = max(0, bounds.width - firstWidth - textX * 2)
        title2.frame = NSRect(x: secondX, y: top, width: secondWidth, height: titleH)
        detail2.frame = NSRect(x: secondX, y: title2.frame.maxY, width: secondWidth, height: detailH)
        note2.frame = NSRect(x: secondX, y: detail2.frame.maxY, width: secondWidth, height: noteH)
    }
}

/// Shows previews after a short hover, then follows the pointer from row to row without delay.
final class TabPreviewController {
    private weak var controller: BrowserWindowController?
    private var panel: TabPreviewView?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private weak var tab: Tab?
    private weak var row: NSView?
    private var snapshotTokens: [SignalToken] = []
    private struct WeakPage { weak var tab: Tab? }
    /// Hover can end without a word: the row closes under the pointer, or you switch apps. This checks while a
    /// preview is up and takes it away once the pointer has really left.
    private var watchTimer: Timer?
    #if DEBUG
    /// The debug bridge's hover: this row counts as under the pointer, wherever the real one is.
    weak var debugRow: NSView?
    #endif

    init(controller: BrowserWindowController) { self.controller = controller }

    func hover(_ tab: Tab?, row: NSView?, bookmark: Bookmark?) {
        // No preview over an open panel, or for a tab under the mini player while you point at it or drag it.
        guard controller?.hasFloatingPanel != true, controller?.miniPlayer.isUnderPointer != true, let row, tab != nil || bookmark != nil else {
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
                    guard let self, let row, self.isPointer(over: row), NSEvent.pressedMouseButtons == 0,
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
                guard change == .snapshot, let self, let first, first === self.tab else { return }
                self.panel?.setImages(refs.map { $0.tab?.snapshot })
            }
        }

        let card = controller.root.cardFrame
        let width = Tokens.Metric.previewWidth
        let aspect = card.height > 0 ? min(card.height / max(card.width, 1), 0.9) : 0.62
        let height = round(width * aspect) + panel.footerHeight(width: width)
        let rowFrame = row.convert(row.bounds, to: overlay)
        // Beside the sidebar, over the page: right of it, or left of it on the right.
        let x = controller.root.besideSidebar(width: width)
        var y = rowFrame.midY - height / 2
        y = max(Tokens.Metric.cardInset * 2, min(y, overlay.bounds.height - height - Tokens.Metric.cardInset * 2))
        let frame = NSRect(x: x, y: round(y), width: width, height: height)

        if isNew {
            panel.frame = frame
            overlay.addSubview(panel)
            panel.present()
        } else if panel.frame != frame {
            Tokens.Motion.animate(Tokens.Motion.snappy, moves: true) { panel.animator().frame = frame }
        }
        // Live pages refresh while you look at the preview.
        refreshTimer?.invalidate()
        let live = pages.filter { !$0.isSuspended }
        keepWatched()
        watched = live
        if !live.isEmpty {
            // In memory while you watch; written to disk once, when the preview goes.
            live.forEach { $0.captureSnapshot(keep: false) }
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
        keepWatched()
        snapshotTokens = []
        guard let panel else { return }
        self.panel = nil
        panel.dismiss()
    }
}
