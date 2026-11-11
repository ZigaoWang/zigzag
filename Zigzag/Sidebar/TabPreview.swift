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
    private let imageClip = NSView()
    /// How a split's two pages share the picture; nil for one page.
    private var split: (ratio: CGFloat, vertical: Bool)?
    static let footerHeight = Tokens.Metric.previewCaptionHeight
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
        [title, detail, title2, detail2].forEach { addSubview($0) }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A page, or with `partner`, a split's two pages, sharing the picture as `split` says.
    func show(tab: Tab?, bookmark: Bookmark?, partner: Tab? = nil, split: (ratio: CGFloat, vertical: Bool)? = nil) {
        self.split = partner == nil ? nil : split ?? (0.5, false)
        title.stringValue = bookmark?.title ?? tab?.displayTitle ?? ""
        let url = tab?.url ?? bookmark?.url
        detail.stringValue = url.map(CommandRanker.displayURL) ?? ""
        title2.stringValue = partner?.displayTitle ?? ""
        detail2.stringValue = partner?.url.map(CommandRanker.displayURL) ?? ""
        title2.isHidden = partner == nil
        detail2.isHidden = partner == nil
        placeholder.image = tab?.favicon ?? bookmark.flatMap { FaviconStore.shared.cachedIcon(for: $0.url) }
        setImages(tab?.snapshot, partner?.snapshot)
        needsLayout = true
    }

    /// The first page's picture, and with a split, the second's.
    func setImages(_ first: NSImage?, _ second: NSImage?) {
        let second = split == nil ? nil : second
        picture.show(first, second, split: split)
        let empty = first == nil && second == nil
        placeholder.isHidden = !empty
        Tokens.Motion.withoutAnimation { picture.layer.isHidden = empty }
        refreshColors()
    }

    /// With no picture yet, a soft wash of the space under the site's icon instead of a blank white page, as the tab
    /// switcher's cards have.
    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            picture.divider.backgroundColor = cgColor(Tokens.Color.cardEdge)
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
        let footer = Self.footerHeight
        imageClip.frame = NSRect(x: pad, y: pad, width: bounds.width - pad * 2, height: bounds.height - footer - pad)
        picture.layout(size: imageClip.bounds.size)
        Tokens.Motion.withoutAnimation { picture.layer.position = CGPoint(x: imageClip.bounds.midX, y: imageClip.bounds.midY) }
        let icon = Tokens.Space.x8
        placeholder.frame = NSRect(x: imageClip.frame.midX - icon / 2, y: imageClip.frame.midY - icon / 2, width: icon, height: icon)
        let textX = Tokens.Space.x3 - Label.inset
        let titleH = title.lineHeight, detailH = detail.lineHeight
        let top = imageClip.frame.maxY + (footer - titleH - detailH) / 2
        // One title, or with a split, each page's under its own side; stacked pages share the row half and half.
        let share = split.map { $0.vertical ? 0.5 : $0.ratio } ?? 1
        let firstWidth = split == nil ? bounds.width : round(imageClip.frame.minX + imageClip.frame.width * share)
        title.frame = NSRect(x: textX, y: top, width: firstWidth - textX * 2, height: titleH)
        detail.frame = NSRect(x: textX, y: title.frame.maxY, width: firstWidth - textX * 2, height: detailH)
        let secondX = firstWidth + textX, secondWidth = max(0, bounds.width - firstWidth - textX * 2)
        title2.frame = NSRect(x: secondX, y: top, width: secondWidth, height: titleH)
        detail2.frame = NSRect(x: secondX, y: title2.frame.maxY, width: secondWidth, height: detailH)
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
           tab === selected || controller?.tabManager.partner(of: tab) === selected {
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
        let first = pair.flatMap { manager.tab(with: $0.left) } ?? tab
        let partner = pair.flatMap { manager.tab(with: $0.right) }
        let pages = [first, partner].compactMap { $0 }
        self.tab = first
        panel.show(tab: first, bookmark: bookmark, partner: partner, split: pair.map { (CGFloat($0.ratio), $0.vertical) })
        if watchTimer == nil {
            watchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkStillHovering() }
            }
            watchTimer?.tolerance = 0.1
        }
        snapshotTokens = pages.map { page in
            page.changed.observe { [weak self, weak first, weak partner] change in
                guard change == .snapshot, let self, let first, first === self.tab else { return }
                self.panel?.setImages(first.snapshot, partner?.snapshot)
            }
        }

        let card = controller.root.cardFrame
        let width = Tokens.Metric.previewWidth
        let aspect = card.height > 0 ? min(card.height / max(card.width, 1), 0.9) : 0.62
        let height = round(width * aspect) + TabPreviewView.footerHeight
        let rowFrame = row.convert(row.bounds, to: overlay)
        let x = controller.root.sidebarContainer.frame.maxX + Tokens.Space.x2
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
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak first, weak partner] _ in
                MainActor.assumeIsolated {
                    [first, partner].forEach { if let page = $0, !page.isSuspended { page.captureSnapshot(keep: false) } }
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
