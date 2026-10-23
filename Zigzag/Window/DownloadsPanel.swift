import AppKit

/// One download: file icon, name, progress or size, and a reveal button.
final class DownloadRowView: InteractiveView {
    private let icon = NSImageView()
    private let name = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let status = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let bar = ColorView(color: Tokens.Color.fieldFill)
    private let fill = ColorView(color: Tokens.Color.accent)
    let actionButton = IconButton(symbol: "magnifyingglass", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "Show in Finder")
    private(set) var item: DownloadItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 1.5
        bar.addSubview(fill)
        [icon, name, status, bar, actionButton].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: DownloadItem) {
        self.item = item
        name.stringValue = item.filename
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        switch item.state {
        case .downloading:
            let done = formatter.string(fromByteCount: item.completedBytes)
            status.stringValue = item.totalBytes > 0 ? "\(done) of \(formatter.string(fromByteCount: item.totalBytes))" : done
            actionButton.symbol = "xmark"
            actionButton.toolTip = "Cancel"
        case .finished:
            status.stringValue = formatter.string(fromByteCount: max(item.totalBytes, item.completedBytes))
            actionButton.symbol = "magnifyingglass"
            actionButton.toolTip = "Show in Finder"
        case .failed:
            status.stringValue = "Failed"
            actionButton.symbol = "xmark"
            actionButton.toolTip = "Remove"
        case .cancelled:
            status.stringValue = "Cancelled"
            actionButton.symbol = "xmark"
            actionButton.toolTip = "Remove"
        }
        bar.isHidden = item.state != .downloading
        let path = item.destination?.path ?? item.filename
        icon.image = NSWorkspace.shared.icon(for: .init(filenameExtension: (path as NSString).pathExtension) ?? .data)
        isEnabled = true
        alphaValue = item.state == .finished || item.state == .downloading ? 1 : 0.6
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x2
        let iconSize = Tokens.Space.x8
        icon.frame = NSRect(x: pad, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let b = actionButton.frame.size
        actionButton.frame.origin = NSPoint(x: bounds.width - pad - b.width, y: (bounds.height - b.height) / 2)
        let x = icon.frame.maxX + Tokens.Space.x2
        let width = actionButton.frame.minX - Tokens.Space.x2 - x
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

    static func show(from anchor: NSView, in controller: BrowserWindowController) {
        if let current { current.close(); return }
        let panel = DownloadsPanelView(controller: controller)
        current = panel
        panel.show(from: anchor)
    }
}

final class DownloadsPanelView: FloatingPanelView {
    private weak var controller: BrowserWindowController?
    private var rows: [DownloadRowView] = []
    private let title = Label("Downloads", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let clearButton = TextButton(title: "Clear")
    private var token: SignalToken?
    private var monitor: Any?
    private weak var anchor: NSView?
    private let rowHeight = Tokens.Space.x12 + Tokens.Space.x2
    private let width: CGFloat = 320

    init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        addSubview(title)
        addSubview(clearButton)
        clearButton.onClick = { _ in DownloadManager.shared.clearFinished() }
        token = DownloadManager.shared.changed.observe { [weak self] _ in self?.reload() }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(from anchor: NSView) {
        guard let controller else { return }
        self.anchor = anchor
        controller.root.overlay.addSubview(self)
        reload()
        present()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            let point = self.convert(event.locationInWindow, from: nil)
            let onAnchor = self.anchor.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
            if !self.bounds.contains(point) && !onAnchor { self.close() }
            return event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        dismiss()
    }

    private func reload() {
        let items = Array(DownloadManager.shared.items.prefix(6))
        while rows.count < items.count {
            let row = DownloadRowView()
            row.onClick = { [weak row] _ in if let item = row?.item { DownloadManager.shared.open(item) } }
            row.actionButton.onClick = { [weak row] _ in
                guard let item = row?.item else { return }
                switch item.state {
                case .downloading: DownloadManager.shared.cancel(item)
                case .finished: DownloadManager.shared.reveal(item)
                default: DownloadManager.shared.remove(item)
                }
            }
            rows.append(row)
            addSubview(row)
        }
        while rows.count > items.count { rows.removeLast().removeFromSuperview() }
        for (row, item) in zip(rows, items) { row.configure(item) }
        clearButton.isEnabled = DownloadManager.shared.items.contains { $0.state != .downloading }
        if items.isEmpty { close(); return }
        reposition()
    }

    private func reposition() {
        guard let controller, let anchor else { return }
        let header = Tokens.Space.x10
        let height = header + CGFloat(rows.count) * rowHeight + Tokens.Space.x2
        let anchorFrame = anchor.convert(anchor.bounds, to: controller.root.overlay)
        let x = max(Tokens.Metric.cardInset, anchorFrame.minX)
        frame = NSRect(x: x, y: anchorFrame.minY - Tokens.Space.x2 - height, width: width, height: height)
    }

    private func layoutContent() {
        let pad = Tokens.Space.x2
        let header = Tokens.Space.x10
        let h = title.lineHeight
        title.frame = NSRect(x: pad + Tokens.Space.x2, y: (header - h) / 2, width: 160, height: h)
        let cw = clearButton.fittingWidth
        clearButton.frame = NSRect(x: bounds.width - pad - cw, y: (header - Tokens.Space.x6) / 2, width: cw, height: Tokens.Space.x6)
        var y = header
        for row in rows {
            row.frame = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: rowHeight)
            y += rowHeight
        }
    }
}

/// A small text-only button ("Clear", "Open as Tab").
final class TextButton: InteractiveView {
    private let label: Label
    /// Shows a quiet fill even at rest, so the button reads as a button (used in Settings).
    var showsFillAtRest = false { didSet { stateDidChange(animated: false) } }

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
        set { label.stringValue = newValue; needsLayout = true }
    }

    var fittingWidth: CGFloat { label.textWidth + Tokens.Space.x4 }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        label.frame = NSRect(x: Tokens.Space.x2, y: (bounds.height - h) / 2, width: bounds.width - Tokens.Space.x4, height: h)
    }

    override func stateDidChange(animated: Bool) {
        let rest: NSColor? = showsFillAtRest ? Tokens.Color.fieldFill : nil
        let fill: NSColor? = !isEnabled ? (showsFillAtRest ? nil : nil) : isPressed ? Tokens.Color.pressedFill : isHovered ? (showsFillAtRest ? Tokens.Color.highlight : Tokens.Color.hoverFill) : rest
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
        label.textColor = showsFillAtRest ? Tokens.Color.textPrimary : (isHovered ? Tokens.Color.textPrimary : Tokens.Color.textSecondary)
        label.alphaValue = isEnabled ? 1 : Tokens.Opacity.disabled
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let event = NSApp.currentEvent else { return false }
        onClick?(event)
        return true
    }
}
