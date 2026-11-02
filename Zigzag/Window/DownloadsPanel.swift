import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One download, a row in the panel's list: the file's icon or a picture of it, its name, progress or size in quiet
/// text, and its buttons at the trailing end. Rows take the one row look (`applyRowStyle`).
final class DownloadRowView: InteractiveView, NSDraggingSource {
    private let icon = NSImageView()
    private let name = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let status = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let bar = ColorView(color: Tokens.Color.fieldFill)
    private let fill = ColorView(color: Tokens.Color.accent)
    let actionButton = IconButton(symbol: "magnifyingglass", size: .compact, toolTip: "Show in Finder")
    /// Pause or resume, beside Cancel, while a download is under way or paused.
    let pauseButton = IconButton(symbol: "pause.fill", size: .compact, toolTip: "Pause")
    private(set) var item: DownloadItem?
    /// The newest download, finished in the last few minutes: the one you're looking for. Its status says so, in
    /// the space's accent; nothing else about the row changes.
    var isNewest = false
    private var isFresh: Bool {
        guard isNewest, let item, item.state == .finished, !item.fileIsMissing else { return false }
        return Date().timeIntervalSince(item.started) < 5 * 60
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = Tokens.Radius.small
        icon.layer?.cornerCurve = .continuous
        icon.layer?.masksToBounds = true
        name.lineBreakMode = .byTruncatingMiddle
        bar.wantsLayer = true
        bar.layer?.cornerRadius = Self.barHeight / 2
        fill.wantsLayer = true
        fill.layer?.cornerRadius = Self.barHeight / 2
        bar.addSubview(fill)
        [icon, name, status, bar, actionButton, pauseButton].forEach { addSubview($0) }
        // A finished file drags out of the list, into Finder, Mail or any app, like a file in Finder.
        onDragStart = { [weak self] event in
            guard let self, let item = self.item, item.state == .finished, let url = item.destination,
                  FileManager.default.fileExists(atPath: url.path) else { return false }
            let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = NSWorkspace.shared.icon(forFile: url.path)
            dragItem.setDraggingFrame(self.icon.frame, contents: image)
            self.beginDraggingSession(with: [dragItem], event: event, source: self)
            return true
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Previews made for finished files, by path, so reopening the panel doesn't make them again.
    private static var thumbnails: [String: NSImage] = [:]

    /// "3.7 of 9 MB": the unit once when both share it, so it fits beside the buttons.
    static func progress(_ done: Int64, of total: Int64, _ formatter: ByteCountFormatter) -> String {
        let a = formatter.string(fromByteCount: done), b = formatter.string(fromByteCount: total)
        let unitA = a.split(separator: " ").last, unitB = b.split(separator: " ").last
        guard unitA == unitB, let number = a.split(separator: " ").first else { return "\(a) of \(b)" }
        return "\(number) of \(b)"
    }

    private static func timeLeft(_ seconds: Double) -> String {
        if seconds < 5 { return "a few seconds left" }
        if seconds < 60 { return "\(Int(seconds.rounded())) seconds left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "a minute left" : "\(minutes) minutes left" }
        let hours = Int((seconds / 3600).rounded())
        return hours == 1 ? "about an hour left" : "about \(hours) hours left"
    }

    /// The file's own icon, as Finder shows it (a disk image looks like one); a picture of it for images, PDFs and
    /// videos once they're here.
    private func showIcon(for item: DownloadItem) {
        let path = item.destination?.path ?? item.filename
        let type = UTType(filenameExtension: (path as NSString).pathExtension) ?? .data
        icon.image = NSWorkspace.shared.icon(for: type)
        guard item.state == .finished, let url = item.destination, FileManager.default.fileExists(atPath: url.path) else { return }
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        guard type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie) else { return }
        if let cached = Self.thumbnails[url.path] { icon.image = cached; return }
        let scale = window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let image = thumbnail?.nsImage else { return }
            DispatchQueue.main.async {
                Self.thumbnails[url.path] = image
                if self?.item === item { self?.icon.image = image }
            }
        }
    }

    func configure(_ item: DownloadItem) {
        self.item = item
        name.stringValue = item.filename
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        switch item.state {
        case .downloading:
            let done = formatter.string(fromByteCount: item.completedBytes)
            let amount = item.totalBytes > 0 ? Self.progress(item.completedBytes, of: item.totalBytes, formatter) : done
            status.stringValue = item.secondsLeft.map { "\(amount), \(Self.timeLeft($0))" } ?? amount
            actionButton.symbol = "xmark"
            actionButton.toolTip = "Cancel"
            pauseButton.symbol = "pause.fill"
            pauseButton.toolTip = "Pause"
        case .paused:
            let done = formatter.string(fromByteCount: item.completedBytes)
            status.stringValue = item.totalBytes > 0 ? "Paused, \(done) of \(formatter.string(fromByteCount: item.totalBytes))" : "Paused"
            actionButton.symbol = "xmark"
            actionButton.toolTip = "Cancel"
            pauseButton.symbol = "play.fill"
            pauseButton.toolTip = "Resume"
        case .finished where item.fileIsMissing:
            // Deleted or moved since: say so, and offer to fetch it again when that's possible.
            let canFetch = ["http", "https"].contains(item.sourceURL?.scheme?.lowercased() ?? "")
            status.stringValue = "Moved or deleted"
            actionButton.symbol = canFetch ? "arrow.down" : "xmark"
            actionButton.toolTip = canFetch ? "Download Again" : "Remove"
        case .finished:
            let size = formatter.string(fromByteCount: max(item.totalBytes, item.completedBytes))
            let site = item.sourceURL.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0.host() : nil }
                .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            status.stringValue = isFresh ? "Just downloaded" : site.map { "\(size) from \($0)" } ?? size
            actionButton.symbol = "magnifyingglass"
            actionButton.toolTip = "Show in Finder"
        case .failed, .cancelled:
            // Say what happened, and offer to try again rather than only to remove it.
            let canRetry = DownloadManager.shared.canRetry(item)
            status.stringValue = item.state == .failed ? (item.failure.map { "Didn’t finish. \($0)." } ?? "Didn’t finish") : "Canceled"
            actionButton.symbol = canRetry ? "arrow.clockwise" : "xmark"
            actionButton.toolTip = canRetry ? "Try Again" : "Remove"
        }
        bar.isHidden = item.state != .downloading && item.state != .paused
        stateDidChange(animated: false)
        pauseButton.isHidden = !(item.state == .paused || DownloadManager.shared.canPause(item))
        // A paused bar is quiet, so it reads as stopped.
        fill.color = item.state == .paused ? Tokens.Color.textTertiary : Tokens.Color.accent
        showIcon(for: item)
        isEnabled = true
        let missing = item.fileIsMissing
        // Something that needs you reads in the caution color; what's simply gone is quieter.
        status.textColor = item.state == .failed ? Tokens.Color.caution : isFresh ? Brand.Theme.for(self).accent : Tokens.Color.textSecondary
        alphaValue = (item.state == .cancelled || missing) ? 0.6 : 1
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.filename + ", " + status.stringValue)
        needsLayout = true
    }

    /// The progress line under a download that's under way.
    private static let barHeight: CGFloat = 3

    override func layout() {
        super.layout()
        // The icon sits as far from the row's edge as a sidebar row's does; the buttons as far from the other end.
        let pad = CardRow.inset - 2
        let iconSize = Tokens.Space.x8
        icon.frame = NSRect(x: pad, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let b = actionButton.frame.size
        actionButton.frame.origin = NSPoint(x: bounds.width - pad - b.width, y: (bounds.height - b.height) / 2)
        pauseButton.frame.origin = NSPoint(x: actionButton.frame.minX - pauseButton.frame.width, y: actionButton.frame.minY)
        let x = icon.frame.maxX + CardRow.inset - Label.inset
        let right = !pauseButton.isHidden ? pauseButton.frame.minX : !actionButton.isHidden ? actionButton.frame.minX : bounds.width - pad
        let width = max(0, right - Tokens.Space.x2 - x)
        let nameH = name.lineHeight, statusH = status.lineHeight
        let top = (bounds.height - nameH - statusH - 2) / 2
        name.frame = NSRect(x: x, y: top, width: width, height: nameH)
        status.frame = NSRect(x: x, y: name.frame.maxY + 2, width: width, height: statusH)
        if !bar.isHidden {
            // Under the text, lined up with it, as long as the name may run.
            bar.frame = NSRect(x: x + Label.inset, y: bounds.height - Tokens.Space.x2 + 1, width: max(0, width - Label.inset * 2), height: Self.barHeight)
            fill.frame = NSRect(x: 0, y: 0, width: bar.bounds.width * CGFloat(item?.fractionCompleted ?? 0), height: Self.barHeight)
        }
    }

    /// A finished file's Show in Finder waits for the pointer, so a list of downloads reads as files, not buttons.
    /// Anything that needs you (under way, paused, failed, missing) keeps its button in view.
    private func refreshAction() {
        let quiet = item?.state == .finished && item?.fileIsMissing == false
        actionButton.isHidden = quiet && !isHovered
    }

    override func stateDidChange(animated: Bool) {
        applyRowStyle(animated: animated)
        refreshAction()
        needsLayout = true
    }
}

/// Downloads, shown above the sidebar's download button. Closes when you click anywhere else.
enum DownloadsPanel {
    private static weak var current: DownloadsPanelView?
    static var isOpen: Bool { current?.superview != nil }
    static func isOpen(in window: NSWindow?) -> Bool { isOpen && current?.window === window }
    static func closeCurrent() { current?.close() }

    /// Opened by a download landing in the button: it goes away by itself a while after that download is done,
    /// unless you're using it; a click elsewhere closes it sooner, as always.
    static func reveal(from anchor: NSView, in controller: BrowserWindowController, closingAfter item: DownloadItem) {
        // Already open: it shows this one too, at the top, marked as new.
        if let current {
            // Showing just one download: the newest takes its place.
            if current.focused != nil { current.focused = item }
            current.reload()
            return
        }
        controller.closeFloatingPanels()
        let panel = DownloadsPanelView(controller: controller)
        panel.focused = item
        current = panel
        panel.show(from: anchor, arrival: .burst)
        panel.closeWhenDone(item)
    }

    static func show(from anchor: NSView, in controller: BrowserWindowController, arrival: FloatingPanelView.Arrival = .pop) {
        if let current { current.close(); return }
        controller.closeFloatingPanels()
        let panel = DownloadsPanelView(controller: controller)
        current = panel
        panel.show(from: anchor, arrival: arrival)
    }
}

final class DownloadsPanelView: FloatingPanelView {
    private weak var controller: BrowserWindowController?
    private var rows: [DownloadRowView] = []
    /// Opened by a download landing: just that one (and any others still coming), not the whole list.
    fileprivate var focused: DownloadItem?
    /// How many it lists when you open it yourself; the rest are in the folder.
    private static let recentCount = 5
    private let title: Label = {
        let label = Label("", font: Tokens.Font.voice(), color: Tokens.Color.textPrimary)
        label.attributedStringValue = Tokens.Font.voiceText("Downloads")
        return label
    }()
    private let clearButton = PillButton(title: "Clear", style: .quiet)
    /// The last row: the folder, or the whole list when the panel opened on one download.
    private let folderButton = CardRow(title: "Open Downloads Folder", symbol: "folder", font: Tokens.Font.body())
    /// Nothing downloaded yet: an arrow and a line, so the panel says what it's for.
    private let emptyIcon = NSImageView(image: Tokens.Symbol.image("arrow.down.circle", size: Tokens.TypeSize.display))
    private let emptyNote = Label("Nothing downloaded yet", font: Tokens.Font.body(), color: Tokens.Color.textTertiary)
    /// More: where new downloads are saved (the same choice as in Settings), in a menu rather than on the panel.
    private let more = IconButton(symbol: "ellipsis", toolTip: "More")
    private var token: SignalToken?
    private var monitor: Any?
    private weak var anchor: NSView?
    private let rowHeight = Tokens.Space.x12 + Tokens.Space.x2
    private let rowGap = Tokens.Metric.rowGap
    /// The title's strip, the rows inset `Space.x1` from the panel's sides so their corners run with its corners.
    private let header = Tokens.Space.x10 + Tokens.Space.x1
    private let inset = Tokens.Space.x1
    private var footer: CGFloat { Tokens.Space.x1 + Tokens.Metric.rowHeight + inset }
    private let emptyHeight = Tokens.Space.x10
    /// Lined up with the sidebar's rows: the same left and right edges, so it never spills onto the page.
    private var sidebarLane: (x: CGFloat, width: CGFloat)? {
        guard let controller else { return nil }
        // The address bar's edges, the same as the site panel's.
        let address = controller.sidebar.address.convert(controller.sidebar.address.bounds, to: controller.root.overlay)
        return (address.minX, address.width)
    }

    init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        [title, clearButton, more, folderButton, emptyIcon, emptyNote].forEach { addSubview($0) }
        more.onClick = { [weak self] _ in self?.showMoreMenu() }
        emptyIcon.contentTintColor = Tokens.Color.textTertiary
        emptyNote.alignment = .left
        clearButton.onClick = { [weak self] _ in DownloadManager.shared.clearFinished(isPrivate: self?.isPrivate ?? false) }
        folderButton.onClick = { [weak self] _ in
            guard let self else { return }
            if self.focused != nil, self.folderButton.title.stringValue == "show all downloads" {
                self.focused = nil
                self.touched = true
                self.reload()
                return
            }
            NSWorkspace.shared.open(DownloadManager.folder)
            self.close()
        }
        token = DownloadManager.shared.changed.observe { [weak self] _ in
            self?.reload()
            self?.checkWatched()
        }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isPrivate: Bool { controller?.tabManager.isPrivate ?? false }

    /// One short menu, like the sidebar's: a "Save Downloads To" heading over the folder, Ask Each Time and
    /// Choose Folder…, the one in use checked.
    private func showMoreMenu() {
        let folder = DownloadManager.folder
        let asks = DownloadManager.asksWhereToSave
        MenuPanel.show([
            .header("Save Downloads To"),
            .item(.init(title: FileManager.default.displayName(atPath: folder.path), isChecked: !asks) { DownloadPlace.pick(0) }),
            .item(.init(title: "Ask Each Time", isChecked: asks) { DownloadPlace.pick(1) }),
            .item(.init(title: "Choose Folder…") { DownloadPlace.pick(2) }),
        ], from: more)
    }

    func show(from anchor: NSView, arrival: Arrival = .pop) {
        guard let controller else { return }
        self.anchor = anchor
        // A glass panel over the sidebar's lane, with the tabs under it faded back so nothing shows around it.
        if controller.root.sidebarVisible, !controller.root.isSidebarFloatingVisible {
            recedes = [controller.sidebar.list]
        }
        controller.root.overlay.addSubview(self)
        reload()
        growsFrom = CGPoint(x: 0.1, y: 1)
        present(arrival: arrival)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            // Only its own window: keys and clicks in Settings or another window are theirs. A menu open over it
            // takes Esc and the click that closes it.
            guard let self, event.window === self.window, MenuPanel.current == nil else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) { self.touched = true }
            let onAnchor = self.anchor.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
            if !self.bounds.contains(point) && !onAnchor { self.close() }
            return event
        }
    }

    private weak var watched: DownloadItem?
    /// Clicked inside: it's being used, so it stays until you click away.
    private var touched = false

    fileprivate func closeWhenDone(_ item: DownloadItem) {
        watched = item
        checkWatched()
    }

    private func checkWatched() {
        guard let item = watched, item.state != .downloading else { return }
        watched = nil
        // Done: it tidies itself away. Paused or failed: it stays, so you see what happened.
        if item.state == .finished { closeLater() }
    }

    /// Six seconds after the download is done, if nobody has reached for it; with the pointer on it, it waits.
    private func closeLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.superview != nil, !self.touched else { return }
            if self.isPointerInside { self.closeLater() } else { self.close() }
        }
    }

    private var isPointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        dismiss()
        // With the sidebar hidden, the Downloads button that stood in for it goes with the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak controller] in controller?.hideFloatingDownloads() }
    }

    fileprivate func reload() {
        let all = DownloadManager.shared.items(isPrivate: isPrivate)
        let items: [DownloadItem]
        if let focused {
            items = all.filter { $0 === focused || $0.state == .downloading || $0.state == .paused }
        } else {
            items = Array(all.prefix(Self.recentCount))
        }
        // Focused with more to see: the button shows the rest here; otherwise it opens the folder.
        let more = focused != nil && all.count > items.count
        folderButton.title.stringValue = more ? "Show All Downloads" : "Open Downloads Folder"
        folderButton.symbol = more ? "list.bullet" : "folder"
        folderButton.setAccessibilityLabel(folderButton.title.stringValue)
        while rows.count < items.count {
            let row = DownloadRowView()
            row.onClick = { [weak row] _ in if let item = row?.item { DownloadManager.shared.open(item) } }
            row.actionButton.onClick = { [weak row] _ in
                guard let item = row?.item else { return }
                switch item.state {
                case .downloading, .paused: DownloadManager.shared.cancel(item)
                case .finished where item.fileIsMissing:
                    if !DownloadManager.shared.downloadAgain(item) { DownloadManager.shared.remove(item) }
                case .finished: DownloadManager.shared.reveal(item)
                default:
                    // Fetched on the download's own data store, so a private one never uses your cookies.
                    if !DownloadManager.shared.retry(item) { DownloadManager.shared.remove(item) }
                }
            }
            row.pauseButton.onClick = { [weak row] _ in
                guard let item = row?.item else { return }
                if item.state == .paused { DownloadManager.shared.resume(item) } else { DownloadManager.shared.pause(item) }
            }
            rows.append(row)
            addSubview(row)
        }
        while rows.count > items.count { rows.removeLast().removeFromSuperview() }
        let newest = all.first { $0.state == .finished }
        for (row, item) in zip(rows, items) {
            row.isNewest = item === newest
            row.configure(item)
        }
        clearButton.isEnabled = all.contains { ![.downloading, .paused].contains($0.state) }
        clearButton.isHidden = items.isEmpty
        emptyNote.isHidden = !items.isEmpty
        emptyIcon.isHidden = true
        reposition()
        needsLayout = true
    }

    private func reposition() {
        guard let controller, let anchor else { return }
        let body = rows.isEmpty ? emptyHeight : CGFloat(rows.count) * (rowHeight + rowGap) - rowGap
        let height = header + body + footer
        // Sidebar hidden: above the stand-in Downloads button in the same corner, at the sidebar's usual width.
        guard controller.root.sidebarVisible || controller.root.isSidebarFloatingVisible else {
            let button = anchor.convert(anchor.bounds, to: controller.root.overlay)
            let width = controller.root.sidebarWidth - Tokens.Metric.sidebarPadding * 2
            frame = NSRect(x: button.minX, y: button.minY - Tokens.Space.x2 - height, width: width, height: height)
            return
        }
        let anchorFrame = anchor.convert(anchor.bounds, to: controller.root.overlay)
        let lane = sidebarLane ?? (max(Tokens.Metric.cardInset, anchorFrame.minX), 300)
        frame = NSRect(x: lane.x, y: anchorFrame.minY - Tokens.Space.x2 - height, width: lane.width, height: height)
    }

    private func layoutContent() {
        let control = Tokens.Page.controlHeight, b = Tokens.Metric.iconButton
        // More sits as far from the top as from the side, so its corner runs with the panel's.
        let edge = Tokens.Space.x2
        more.frame = NSRect(x: bounds.width - edge - b, y: edge, width: b, height: b)
        let cw = clearButton.fittingWidth
        clearButton.frame = NSRect(x: more.frame.minX - Tokens.Space.x1 - cw, y: more.frame.midY - control / 2, width: cw, height: control)
        // The title lines up with the rows' icons below it.
        let h = title.lineHeight
        let x = inset + CardRow.inset - 2 - Label.inset
        let end = clearButton.isHidden ? more.frame.minX : clearButton.frame.minX
        title.frame = NSRect(x: x, y: more.frame.midY - h / 2, width: max(0, end - x - Tokens.Space.x2), height: h)
        var y = header
        if rows.isEmpty {
            let icon = Tokens.Space.x8
            emptyIcon.frame = NSRect(x: (bounds.width - icon) / 2, y: y + Tokens.Space.x2, width: icon, height: icon)
            // One quiet line, no picture.
            emptyNote.frame = NSRect(x: x, y: y + (emptyHeight - emptyNote.lineHeight) / 2, width: bounds.width - x - Tokens.Space.x3, height: emptyNote.lineHeight)
            y += emptyHeight
        }
        for row in rows {
            row.frame = NSRect(x: inset, y: y, width: bounds.width - inset * 2, height: rowHeight)
            y += rowHeight + rowGap
        }
        if !rows.isEmpty { y -= rowGap }
        folderButton.frame = NSRect(x: inset, y: y + Tokens.Space.x1, width: bounds.width - inset * 2, height: Tokens.Metric.rowHeight)
    }
}
