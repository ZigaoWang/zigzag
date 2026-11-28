import AppKit

/// Where a link goes, shown in the page's bottom-left corner while you hover it.
///
/// The pill sits where a page's own links may be: at the bottom-left, a big button a site could put there. It never
/// takes a press — a click goes through it to the page, and so does the pointer hovering a link under it (#592) — and
/// while the pointer is over it, it steps aside so the link under it reads.
final class LinkStatusController {
    private weak var overlay: NSView?
    private let pill = LinkStatusPill()
    private let label = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let hideDebouncer = Debouncer(delay: 0.15)
    private var visible = false
    /// Where the pointer is over the pill, as its tracking area last said. Kept here so the fade can be worked out
    /// without a window, and so it holds while the link under the pointer changes.
    private(set) var pointerOver = false
    /// From the capsule's ends to the text: about half its height, so the round ends never crowd a letter.
    private static let padding = Tokens.Metric.linkStatusHeight / 2 - 2

    /// How far the pill steps back while the pointer is over it: enough that the link under it reads through, still
    /// there so the address can be read by moving off it. It's the one fade the pass-through pairs with: it never
    /// dims without letting the click through, since the pill can't take one at all.
    static let steppedAside: CGFloat = 0.25

    init(overlay: NSView) {
        self.overlay = overlay
        pill.radius = Tokens.Metric.linkStatusHeight / 2
        pill.addSubview(label)
        label.lineBreakMode = .byTruncatingMiddle
        pill.onPointerChange = { [weak self] over in self?.pointerMoved(over: over) }
        pill.onLayout = { [weak self] in
            guard let self else { return }
            let h = self.label.lineHeight
            // The text field draws its text Label.inset in from its edges: set it that much wider, so the ink sits
            // the same padding from each end.
            self.label.frame = NSRect(x: Self.padding - Label.inset, y: self.label.centeredY(in: self.pill.bounds.height),
                                      width: self.pill.bounds.width - Self.padding * 2 + Label.inset * 2, height: h)
        }
    }

    /// Settings › Appearance › Show link address on hover (#537). On by default.
    static var showsOnHover: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
    static let defaultsKey = "ShowLinkAddressOnHover"

    /// Whether the pill is up now.
    var isShowing: Bool { visible }

    func show(_ url: URL?, in area: NSRect) {
        guard let url, Self.showsOnHover, let overlay else {
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
        // The pointer can stay put over the pill while the link under it changes: it must stay stepped aside, not
        // flash back whole on every move of the link.
        applyStepAside()
    }

    func hide() {
        guard visible else { return }
        visible = false
        pointerOver = false
        pill.dismiss()
    }

    /// The pointer is over the pill (`over`), or has left it. The pill fades back so the link under it reads, and
    /// comes back whole when the pointer is off it. The pill's tracking area calls it as the pointer moves; the tests
    /// call it directly.
    func pointerMoved(over: Bool) {
        guard visible else { return }
        pointerOver = over
        applyStepAside()
    }

    /// Puts the pill where the pointer says it should be: stepped aside under the pointer, whole otherwise.
    private func applyStepAside() {
        let alpha = pointerOver ? Self.steppedAside : 1
        guard pill.alphaValue != alpha else { return }
        Tokens.Motion.animate(Tokens.Motion.change) { [weak self] in
            self?.pill.animator().alphaValue = alpha
        }
    }

    /// The whole address, so you know where a link goes before you click it, without the noise: no "https://", no
    /// "www.", no trailing slash. Too long for the pill, it's cut in the middle, keeping the site and the end.
    static func describe(_ url: URL) -> String {
        if url.scheme == "mailto" {
            let address = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return String(localized: "Email \(address)", comment: "Shown at the bottom of the window while pointing at an email link. The address is the link's.")
        }
        guard let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else { return url.absoluteString }
        // Strip user info ahead of the host ("good.example%2F@evil.example" goes to evil.example) and show the host as
        // is: only the rest is decoded, never into a "/" or "@".
        var text = AddressText.withoutUserInfo(url).absoluteString
        if let range = text.range(of: "\(scheme)://") { text.removeSubrange(range) }
        text = text.withoutWWW
        if text.hasSuffix("/") { text.removeLast() }
        guard let end = text.firstIndex(where: { "/?#".contains($0) }) else { return text }
        return String(text[..<end]) + AddressText.readable(String(text[end...]))
    }
}

/// The link address pill's own view. It never takes a press: a click on it goes through to the page under it, where a
/// link may be (#592). That's why it's this instead of a bare `FloatingPanelView`, which real panels need to keep
/// their presses.
///
/// A tracking area still hears the pointer come and go even though `hitTest` answers nothing: AppKit works out
/// tracking areas from where the pointer is, not from what would take a press. So the pill can step aside while it's
/// under the pointer, and come back as the pointer leaves.
final class LinkStatusPill: FloatingPanelView {
    /// The pointer came over the pill (`true`) or left it (`false`).
    var onPointerChange: ((Bool) -> Void)?
    private var pointerArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerChange?(true)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerChange?(false)
        super.mouseExited(with: event)
    }
}
