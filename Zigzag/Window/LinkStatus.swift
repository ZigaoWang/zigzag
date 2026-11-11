import AppKit

/// Where a link goes, shown in the page's bottom-left corner while you hover it.
final class LinkStatusController {
    private weak var overlay: NSView?
    private let pill = FloatingPanelView()
    private let label = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let hideDebouncer = Debouncer(delay: 0.15)
    private var visible = false
    /// From the capsule's ends to the text: about half its height, so the round ends never crowd a letter.
    private static let padding = Tokens.Metric.linkStatusHeight / 2 - 2

    init(overlay: NSView) {
        self.overlay = overlay
        pill.radius = Tokens.Metric.linkStatusHeight / 2
        pill.addSubview(label)
        label.lineBreakMode = .byTruncatingMiddle
        pill.onLayout = { [weak self] in
            guard let self else { return }
            let h = self.label.lineHeight
            // The text field draws its text Label.inset in from its edges: set it that much wider, so the ink sits
            // the same padding from each end.
            self.label.frame = NSRect(x: Self.padding - Label.inset, y: (self.pill.bounds.height - h) / 2,
                                      width: self.pill.bounds.width - Self.padding * 2 + Label.inset * 2, height: h)
        }
    }

    func show(_ url: URL?, in area: NSRect) {
        guard let url, let overlay else {
            hideDebouncer.call { [weak self] in self?.hide() }
            return
        }
        hideDebouncer.cancel()
        label.stringValue = Self.describe(url)
        label.lineBreakMode = .byTruncatingMiddle
        let height = Tokens.Metric.linkStatusHeight
        // The pill is the padding wider than the text's ink on each side, the same both ends.
        let width = min(label.inkWidth + Self.padding * 2, area.width * 0.6)
        pill.frame = NSRect(x: area.minX + Tokens.Space.x2, y: area.maxY - height - Tokens.Space.x2, width: ceil(width), height: height)
        pill.needsLayout = true
        if !visible {
            visible = true
            overlay.addSubview(pill)
            // Pointing from link to link many times a minute: it's simply there, and caught while fading, it's back.
            pill.present(arrival: .instant)
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        pill.dismiss()
    }

    /// The whole address, so you know where a link goes before you click it, without the noise: no "https://", no
    /// "www.", no trailing slash. Too long for the pill, it's cut in the middle, keeping the site and the end.
    static func describe(_ url: URL) -> String {
        if url.scheme == "mailto" {
            let address = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return String(localized: "Email \(address)", comment: "Shown at the bottom of the window while pointing at an email link. The address is the link's.")
        }
        guard let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else { return url.absoluteString }
        var text = url.absoluteString
        if let range = text.range(of: "\(scheme)://") { text.removeSubrange(range) }
        text = text.withoutWWW
        if text.hasSuffix("/") { text.removeLast() }
        return text.removingPercentEncoding ?? text
    }
}
