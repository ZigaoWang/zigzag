import AppKit

/// Download progress on the Dock icon: a slim bar along the bottom, like Safari and Finder.
final class DockProgress {
    static let shared = DockProgress()
    private let tileView = DockTileView()
    private var token: SignalToken?

    func start() {
        token = DownloadManager.shared.changed.observe { [weak self] item in self?.update(finished: item) }
    }

    private func update(finished item: DownloadItem?) {
        let manager = DownloadManager.shared
        let tile = NSApp.dockTile
        if manager.activeCount > 0 {
            tileView.progress = manager.overallProgress
            tileView.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = tileView
            tile.badgeLabel = manager.activeCount > 1 ? "\(manager.activeCount)" : nil
        } else {
            tile.contentView = nil
            tile.badgeLabel = nil
        }
        tile.display()
        // A finished download says so once, in a window of its own kind (a private one's name never shows in a
        // normal window, nor the other way round), unless the downloads panel is open there and already shows it. One
        // still flying to the button is announced after it lands, when that panel has opened. A failed one says so
        // too, with Try Again: otherwise it would only stop, unnoticed.
        guard let item, item.state == .finished || item.state == .failed, !announced.contains(item.id),
              let controller = Self.window(for: item) else { return }
        announced.insert(item.id)
        let failed = item.state == .failed
        let announce = { [weak controller] in
            guard let controller, !DownloadsPanel.isOpen(in: controller.window) else { return }
            if failed {
                Toast.show("Couldn’t download \(item.filename)", symbol: "exclamationmark.triangle",
                           action: DownloadManager.shared.canRetry(item) ? ("Try Again", { DownloadManager.shared.retry(item) }) : nil,
                           duration: 5, in: controller)
            } else {
                Toast.show("Downloaded \(item.filename)", symbol: "arrow.down.circle",
                           action: ("Show", { DownloadManager.shared.reveal(item) }), duration: 3, in: controller)
            }
        }
        if !failed, controller.flyingDownloads.contains(item.id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4 * Tokens.Motion.debugSlowdown, execute: announce)
        } else {
            announce()
        }
    }

    /// The window you're using if it's private when the download is (or isn't when it isn't), else another that is.
    private static func window(for item: DownloadItem) -> BrowserWindowController? {
        let all = WindowManager.shared.controllers.filter { $0.tabManager.isPrivate == item.isPrivate }
        if let key = WindowManager.shared.keyController, all.contains(where: { $0 === key }) { return key }
        return all.first
    }

    private var announced: Set<UUID> = []
}

final class DockTileView: NSView {
    var progress: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath).draw(in: bounds)
        let barHeight = bounds.height * 0.09
        let inset = bounds.width * 0.14
        let track = NSRect(x: inset, y: bounds.height * 0.12, width: bounds.width - inset * 2, height: barHeight)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSColor.black.withAlphaComponent(0.45).setFill()
        trackPath.fill()
        var fill = track.insetBy(dx: 2, dy: 2)
        fill.size.width = max(fill.height, fill.width * CGFloat(min(max(progress, 0), 1)))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
    }
}
