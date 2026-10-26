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
        // A finished download says so once, in the window you're using.
        // Not when the downloads panel is open there: it already shows the file arriving.
        if let item, item.state == .finished, !announced.contains(item.id), let controller = WindowManager.shared.keyController {
            announced.insert(item.id)
            // With the sidebar showing, the download lands in its button and the panel opens there: that's the notice.
            if DownloadsPanel.isOpen(in: controller.window) || controller.root.sidebarVisible || controller.root.isSidebarFloatingVisible { return }
            if DownloadsPanel.isOpen(in: controller.window) { return }
            Toast.show("Downloaded \(item.filename)", symbol: "arrow.down.circle",
                       action: ("Show", { DownloadManager.shared.reveal(item) }), duration: 3, in: controller)
        }
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
