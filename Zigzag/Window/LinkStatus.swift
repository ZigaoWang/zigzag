import AppKit

/// Where a link goes, shown in the page's bottom-left corner while you hover it.
final class LinkStatusController {
    private weak var overlay: NSView?
    private let pill = FloatingPanelView()
    private let label = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let hideDebouncer = Debouncer(delay: 0.15)
    private var visible = false

    init(overlay: NSView) {
        self.overlay = overlay
        pill.radius = Tokens.Radius.control
        pill.addSubview(label)
        label.lineBreakMode = .byTruncatingMiddle
        pill.onLayout = { [weak self] in
            guard let self else { return }
            let h = self.label.lineHeight
            self.label.frame = NSRect(x: Tokens.Space.x2, y: (self.pill.bounds.height - h) / 2, width: self.pill.bounds.width - Tokens.Space.x4, height: h)
        }
    }

    func show(_ url: URL?, in area: NSRect) {
        guard let url, let overlay else {
            hideDebouncer.call { [weak self] in self?.hide() }
            return
        }
        hideDebouncer.cancel()
        label.stringValue = Self.describe(url)
        let height = Tokens.Space.x6
        let width = min(label.textWidth + Tokens.Space.x2, area.width * 0.6)
        pill.frame = NSRect(x: area.minX + Tokens.Space.x2, y: area.maxY - height - Tokens.Space.x2, width: ceil(width), height: height)
        pill.needsLayout = true
        if !visible {
            visible = true
            overlay.addSubview(pill)
            pill.alphaValue = 1
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        pill.dismiss()
    }

    /// Readable, without the noise: no "https://", no "www.", no trailing slash.
    static func describe(_ url: URL) -> String {
        if url.scheme == "mailto" { return url.absoluteString.replacingOccurrences(of: "mailto:", with: "Email ") }
        return CommandRanker.displayURL(url).removingPercentEncoding ?? CommandRanker.displayURL(url)
    }
}
