import AppKit
import WebKit

/// The floating card that shows a tab's page when you hover it in the sidebar.
final class TabPreviewView: FloatingPanelView {
    private let imageView = NSImageView()
    private let placeholder = FaviconView()
    private let title = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    private let detail = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let imageClip = NSView()
    static let footerHeight = Tokens.Space.x12

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageClip.wantsLayer = true
        imageClip.layer?.masksToBounds = true
        imageClip.layer?.cornerRadius = Tokens.Radius.thumbnail
        imageClip.layer?.cornerCurve = .continuous
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop
        imageClip.addSubview(imageView)
        addSubview(imageClip)
        addSubview(placeholder)
        addSubview(title)
        addSubview(detail)
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(tab: Tab?, bookmark: Bookmark?) {
        title.stringValue = bookmark?.title ?? tab?.displayTitle ?? ""
        let url = tab?.url ?? bookmark?.url
        detail.stringValue = url.map(CommandRanker.displayURL) ?? ""
        image = tab?.snapshot
        placeholder.image = tab?.favicon ?? bookmark.flatMap { FaviconStore.shared.cachedIcon(for: $0.url) }
        needsLayout = true
    }

    var image: NSImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            imageView.isHidden = newValue == nil
            placeholder.isHidden = newValue != nil
            imageClip.layer?.backgroundColor = cgColor(Tokens.Color.cardBackground)
        }
    }

    private func layoutContent() {
        let pad = Tokens.Space.x2
        let footer = Self.footerHeight
        imageClip.frame = NSRect(x: pad, y: pad, width: bounds.width - pad * 2, height: bounds.height - footer - pad)
        imageView.frame = imageClip.bounds
        let icon = Tokens.Space.x8
        placeholder.frame = NSRect(x: imageClip.frame.midX - icon / 2, y: imageClip.frame.midY - icon / 2, width: icon, height: icon)
        let textX = pad + Tokens.Space.x1
        let titleH = title.lineHeight, detailH = detail.lineHeight
        let top = imageClip.frame.maxY + (footer - titleH - detailH) / 2
        title.frame = NSRect(x: textX, y: top, width: bounds.width - textX * 2, height: titleH)
        detail.frame = NSRect(x: textX, y: title.frame.maxY, width: bounds.width - textX * 2, height: detailH)
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
    private var snapshotToken: SignalToken?

    init(controller: BrowserWindowController) { self.controller = controller }

    func hover(_ tab: Tab?, row: NSView?, bookmark: Bookmark?) {
        // No preview over an open panel.
        guard controller?.hasFloatingPanel != true, let row, tab != nil || bookmark != nil else {
            scheduleHide()
            return
        }
        hideWork?.cancel()
        // No preview for the page you're already looking at.
        if let tab, tab === controller?.tabManager.selectedTab {
            scheduleHide(immediately: true)
            return
        }
        if panel != nil {
            present(tab, bookmark: bookmark, row: row)
        } else {
            showWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak row] in
                MainActor.assumeIsolated {
                    guard let self, let row, row.window != nil else { return }
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
        self.tab = tab
        panel.show(tab: tab, bookmark: bookmark)
        snapshotToken = tab?.changed.observe { [weak self, weak tab] change in
            guard change == .snapshot, let tab, tab === self?.tab else { return }
            self?.panel?.image = tab.snapshot
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
            Tokens.Motion.animate(Tokens.Motion.snappy) { panel.animator().frame = frame }
        }
        // Live pages refresh while you look at the preview.
        refreshTimer?.invalidate()
        if let tab, !tab.isSuspended {
            tab.captureSnapshot()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak tab] _ in
                MainActor.assumeIsolated { tab?.captureSnapshot() }
            }
        }
    }

    private func scheduleHide(immediately: Bool = false) {
        showWork?.cancel()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.12), execute: work)
    }

    func hide() {
        showWork?.cancel()
        refreshTimer?.invalidate()
        refreshTimer = nil
        snapshotToken = nil
        guard let panel else { return }
        self.panel = nil
        panel.dismiss()
    }
}
