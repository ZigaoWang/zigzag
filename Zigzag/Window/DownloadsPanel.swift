import AppKit
import QuickLookThumbnailing

/// One download: file icon, name, progress or size, and a reveal button.
final class DownloadRowView: InteractiveView, NSDraggingSource {
    private let icon = NSImageView()
    private let name = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let status = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let bar = ColorView(color: Tokens.Color.fieldFill)
    private let fill = ColorView(color: Tokens.Color.accent)
    let actionButton = IconButton(symbol: "magnifyingglass", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "Show in Finder")
    /// Pause or resume, beside Cancel, while a download is under way or paused.
    let pauseButton = IconButton(symbol: "pause.fill", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "Pause")
    private(set) var item: DownloadItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 4
        icon.layer?.masksToBounds = true
        name.lineBreakMode = .byTruncatingMiddle
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 1.5
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

    private static func timeLeft(_ seconds: Double) -> String {
        if seconds < 5 { return "a few seconds left" }
        if seconds < 60 { return "\(Int(seconds.rounded())) seconds left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "a minute left" : "\(minutes) minutes left" }
        let hours = Int((seconds / 3600).rounded())
        return hours == 1 ? "about an hour left" : "about \(hours) hours left"
    }

    /// The real picture for images, PDFs and videos once they're here; the file type's icon before that.
    private func showIcon(for item: DownloadItem) {
        let path = item.destination?.path ?? item.filename
        icon.image = NSWorkspace.shared.icon(for: .init(filenameExtension: (path as NSString).pathExtension) ?? .data)
        guard item.state == .finished, let url = item.destination else { return }
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
            let amount = item.totalBytes > 0 ? "\(done) of \(formatter.string(fromByteCount: item.totalBytes))" : done
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
            status.stringValue = site.map { "\(size) from \($0)" } ?? size
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
        pauseButton.isHidden = !(item.state == .paused || DownloadManager.shared.canPause(item))
        // A paused bar is quiet, so it reads as stopped.
        fill.color = item.state == .paused ? Tokens.Color.textTertiary : Tokens.Color.accent
        showIcon(for: item)
        isEnabled = true
        let missing = item.fileIsMissing
        // Something that needs you reads in the caution color; what's simply gone is quieter.
        status.textColor = item.state == .failed ? Tokens.Color.caution : Tokens.Color.textSecondary
        alphaValue = (item.state == .cancelled || missing) ? 0.6 : 1
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.filename + ", " + status.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x2
        let iconSize = Tokens.Space.x8
        icon.frame = NSRect(x: pad, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let b = actionButton.frame.size
        actionButton.frame.origin = NSPoint(x: bounds.width - pad - b.width, y: (bounds.height - b.height) / 2)
        pauseButton.frame.origin = NSPoint(x: actionButton.frame.minX - Tokens.Space.x1 - pauseButton.frame.width, y: actionButton.frame.minY)
        let x = icon.frame.maxX + Tokens.Space.x2
        let width = (pauseButton.isHidden ? actionButton.frame.minX : pauseButton.frame.minX) - Tokens.Space.x2 - x
        let nameH = name.lineHeight, statusH = status.lineHeight
        let top = (bounds.height - nameH - statusH - Tokens.Space.x1) / 2
        name.frame = NSRect(x: x, y: top, width: width, height: nameH)
        if bar.isHidden {
            status.frame = NSRect(x: x, y: name.frame.maxY + Tokens.Space.x1, width: width, height: statusH)
        } else {
            status.frame = NSRect(x: x, y: name.frame.maxY + Tokens.Space.x1, width: width, height: statusH)
            status.isHidden = false
            bar.frame = NSRect(x: x, y: bounds.height - Tokens.Space.x2, width: width, height: 3)
            fill.frame = NSRect(x: 0, y: 0, width: bar.bounds.width * CGFloat(item?.fractionCompleted ?? 0), height: 3)
        }
    }

    override func stateDidChange(animated: Bool) {
        let color: NSColor? = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: color.map { cgColor($0) }, animated: animated && !isHovered)
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
        guard current == nil else { return }
        show(from: anchor, in: controller, arrival: .burst)
        current?.closeWhenDone(item)
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
    private let title = Label("Downloads", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let clearButton = TextButton(title: "Clear", font: Tokens.Font.body(.medium))
    private let folderButton = TextButton(title: "Open Downloads Folder", font: Tokens.Font.body(.medium))
    /// Nothing downloaded yet: an arrow and a line, so the panel says what it's for.
    private let emptyIcon = NSImageView(image: Tokens.Symbol.image("arrow.down.circle", size: 24))
    private let emptyNote = Label("Files you download show up here.", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    /// More: where new downloads are saved (the same choice as in Settings), in a menu rather than on the panel.
    private let more = IconButton(symbol: "ellipsis", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "More")
    private var token: SignalToken?
    private var monitor: Any?
    private weak var anchor: NSView?
    private let rowHeight = Tokens.Space.x12 + Tokens.Space.x2
    private let footer = Tokens.Space.x12
    private let emptyHeight = Tokens.Space.x16 + Tokens.Space.x4
    private let width: CGFloat = 340

    init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        [title, clearButton, more, folderButton, emptyIcon, emptyNote].forEach { addSubview($0) }
        more.onClick = { [weak self] _ in self?.showMoreMenu() }
        emptyIcon.contentTintColor = Tokens.Color.textTertiary
        emptyNote.alignment = .center
        folderButton.showsFillAtRest = true
        clearButton.onClick = { [weak self] _ in DownloadManager.shared.clearFinished(isPrivate: self?.isPrivate ?? false) }
        folderButton.onClick = { [weak self] _ in
            NSWorkspace.shared.open(DownloadManager.folder)
            self?.close()
        }
        token = DownloadManager.shared.changed.observe { [weak self] _ in
            self?.reload()
            self?.checkWatched()
        }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isPrivate: Bool { controller?.tabManager.isPrivate ?? false }

    /// "Save Downloads To ›" with the folder, Ask Each Time and Choose Folder…, checked as they are now.
    private func showMoreMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let save = NSMenuItem(title: "Save Downloads To", action: nil, keyEquivalent: "")
        let places = NSMenu()
        let folder = DownloadManager.folder
        let folderItem = SidebarMenus.Item(FileManager.default.displayName(atPath: folder.path)) { DownloadPlace.pick(0) }
        let icon = NSWorkspace.shared.icon(forFile: folder.path)
        icon.size = NSSize(width: 16, height: 16)
        folderItem.image = icon
        folderItem.state = DownloadManager.asksWhereToSave ? .off : .on
        let ask = SidebarMenus.Item("Ask Each Time") { DownloadPlace.pick(1) }
        ask.state = DownloadManager.asksWhereToSave ? .on : .off
        places.addItem(folderItem)
        places.addItem(ask)
        places.addItem(.separator())
        places.addItem(SidebarMenus.Item("Choose Folder…") { DownloadPlace.pick(2) })
        save.submenu = places
        menu.addItem(save)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.isFlipped ? more.bounds.maxY + 4 : -4), in: more)
    }

    func show(from anchor: NSView, arrival: Arrival = .pop) {
        guard let controller else { return }
        self.anchor = anchor
        controller.root.overlay.addSubview(self)
        reload()
        growsFrom = CGPoint(x: 0.1, y: 1)
        present(arrival: arrival)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            // Only its own window: keys and clicks in Settings or another window are theirs.
            guard let self, event.window === self.window else { return event }
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
    }

    private func reload() {
        let all = DownloadManager.shared.items(isPrivate: isPrivate)
        let items = Array(all.prefix(8))
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
        for (row, item) in zip(rows, items) { row.configure(item) }
        clearButton.isEnabled = all.contains { ![.downloading, .paused].contains($0.state) }
        clearButton.isHidden = items.isEmpty
        emptyNote.isHidden = !items.isEmpty
        emptyIcon.isHidden = !items.isEmpty
        reposition()
        needsLayout = true
    }

    private func reposition() {
        guard let controller, let anchor else { return }
        let header = Tokens.Space.x10
        let body = rows.isEmpty ? emptyHeight : CGFloat(rows.count) * rowHeight
        let height = header + body + footer
        let anchorFrame = anchor.convert(anchor.bounds, to: controller.root.overlay)
        let x = max(Tokens.Metric.cardInset, anchorFrame.minX)
        frame = NSRect(x: x, y: anchorFrame.minY - Tokens.Space.x2 - height, width: width, height: height)
    }

    private func layoutContent() {
        let pad = Tokens.Space.x2
        let header = Tokens.Space.x10
        let h = title.lineHeight
        let side = Tokens.Space.x6
        more.frame = NSRect(x: bounds.width - pad - side, y: (header - side) / 2, width: side, height: side)
        let cw = clearButton.fittingWidth
        clearButton.frame = NSRect(x: more.frame.minX - Tokens.Space.x1 - cw, y: (header - Tokens.Space.x6) / 2, width: cw, height: Tokens.Space.x6)
        title.frame = NSRect(x: pad + Tokens.Space.x2, y: (header - h) / 2, width: clearButton.frame.minX - pad * 2 - Tokens.Space.x2, height: h)
        var y = header
        if rows.isEmpty {
            let icon: CGFloat = 28
            emptyIcon.frame = NSRect(x: (bounds.width - icon) / 2, y: y + Tokens.Space.x3, width: icon, height: icon)
            emptyNote.frame = NSRect(x: pad, y: emptyIcon.frame.maxY + Tokens.Space.x2, width: bounds.width - pad * 2, height: emptyNote.lineHeight)
            y += emptyHeight
        }
        for row in rows {
            row.frame = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: rowHeight)
            y += rowHeight
        }
        // A real button across the bottom, not a line of text.
        folderButton.frame = NSRect(x: pad, y: y + (footer - Tokens.Space.x8) / 2 - 2, width: bounds.width - pad * 2, height: Tokens.Space.x8)
    }
}

/// A small text-only button ("Clear", "Open as Tab").
final class TextButton: InteractiveView {
    private let label: Label
    /// Shows a quiet fill even at rest, so the button reads as a button (used in Settings).
    var showsFillAtRest = false { didSet { stateDidChange(animated: false) } }
    /// Overrides the label color (destructive actions).
    var textColor: NSColor? { didSet { stateDidChange(animated: false) } }
    /// Moves the title off center, to leave room for something beside it (a keycap).
    var labelOffset: CGFloat = 0 { didSet { needsLayout = true } }

    init(title: String, font: NSFont = Tokens.Font.small(.medium)) {
        label = Label(title, font: font, color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize(); needsLayout = true; superview?.needsLayout = true }
    }

    /// Says what just happened in place of the title for a moment ("Cleared"), then goes back.
    func flash(_ text: String, for seconds: TimeInterval = 1.6) {
        let original = title
        title = text
        isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.title = original
            self?.isEnabled = true
        }
    }

    /// The button used in forms and windows: body text on a quiet fill.
    static func form(_ title: String) -> TextButton {
        let button = TextButton(title: title, font: Tokens.Font.body(.medium))
        button.showsFillAtRest = true
        return button
    }

    /// `textWidth` already carries the label's own inset; the label is centered, so the padding is even.
    var fittingWidth: CGFloat { label.textWidth + Tokens.Space.x3 }

    /// So stacks and form rows can size it like any control.
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(fittingWidth), height: Tokens.Space.x7Height) }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        label.alignment = .center
        label.frame = NSRect(x: labelOffset, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }

    override func stateDidChange(animated: Bool) {
        let rest: NSColor? = showsFillAtRest ? Tokens.Color.fieldFill : nil
        let fill: NSColor? = !isEnabled ? (showsFillAtRest ? nil : nil) : isPressed ? Tokens.Color.pressedFill : isHovered ? (showsFillAtRest ? Tokens.Color.highlight : Tokens.Color.hoverFill) : rest
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        label.textColor = textColor ?? (showsFillAtRest ? Tokens.Color.textPrimary : (isHovered ? Tokens.Color.textPrimary : Tokens.Color.textSecondary))
        label.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let event = NSApp.currentEvent else { return false }
        onClick?(event)
        return true
    }
}
