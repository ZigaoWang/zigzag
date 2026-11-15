import AppKit

/// An update that's ready, at the foot of the sidebar: Zigzag's icon, "Update ready" and the version, a Restart that
/// restarts into it with everything back, and a close button that puts it away until Zigzag restarts (the update
/// still installs when Zigzag quits). Laid out as the Now Playing card is, a row's height with a row's columns; a
/// click anywhere on it restarts, as Restart does.
final class UpdateCard: InteractiveView {
    private let icon = NSImageView()
    private let title = Label(String(localized: "Update ready", comment: "The sidebar's card for an update that's downloaded and ready: Restart installs it."),
                              font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
    private let version = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textSecondary)
    let restartButton = RestartPill(title: String(localized: "Restart", comment: "Button that restarts Zigzag into an update that's ready: on the sidebar's update card, in a toast and in Settings › General."))
    /// Last, where a tab row's close is.
    let hideButton = TabRowView.rowButton("xmark", toolTip: String(localized: "Not Now", comment: "Tooltip and VoiceOver action of the close button on the sidebar's update card: puts the card away; the update installs when Zigzag quits."))
    var onRestart: (() -> Void)?
    var onHide: (() -> Void)?
    private var sizeObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Sidebar.rowRadius
        layer?.cornerCurve = .continuous
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        version.fadesTail = true
        [icon, title, version, restartButton, hideButton].forEach { addSubview($0) }
        onClick = { [weak self] _ in self?.onRestart?() }
        restartButton.onClick = { [weak self] _ in self?.onRestart?() }
        hideButton.onClick = { [weak self] _ in self?.onHide?() }
        sizeObserver = NotificationCenter.default.addObserver(forName: Tokens.Sidebar.sizeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.title.font = Tokens.Font.sidebarRow()
                self.version.font = Tokens.Font.sidebarRow()
                self.hideButton.symbolSize = Tokens.Sidebar.rowGlyph
                self.restartButton.sizeChanged()
                self.needsLayout = true
            }
        }
        setAccessibilityRole(.group)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: restartButton.title) { [weak self] in
                MainActor.assumeIsolated {
                    guard let restart = self?.onRestart else { return false }
                    restart()
                    return true
                }
            },
            NSAccessibilityCustomAction(name: hideButton.toolTip ?? "") { [weak self] in
                MainActor.assumeIsolated {
                    guard let hide = self?.onHide else { return false }
                    hide()
                    return true
                }
            },
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The version that's ready, as people know it (0.9.2).
    func show(version text: String) {
        version.stringValue = text
        let sentence = String(localized: "Zigzag \(text) is ready. Restart to update.", comment: "Tooltip and VoiceOver label of the sidebar's update card. The placeholder is the version.")
        toolTip = sentence
        setAccessibilityLabel(sentence)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = Tokens.Sidebar.favicon
        icon.frame = NSRect(x: SidebarRowView.inset, y: (bounds.height - size) / 2, width: size, height: size)
        let b = Tokens.Sidebar.rowButton
        let y = (bounds.height - b) / 2
        let hide = NSRect(x: bounds.width - SidebarRowView.buttonEdge - b, y: y, width: b, height: b)
        let pill = restartButton.fittingWidth
        let restart = NSRect(x: hide.minX - Self.buttonGap - pill, y: y, width: pill, height: b)
        hideButton.frame = hide
        restartButton.frame = restart
        // "Update ready" whole while it fits, then the version after it, fading out at its end when it runs short.
        let x = icon.frame.maxX + SidebarRowView.titleOffset
        // Restart's own room either side of its word is the gap before it.
        let end = restart.minX
        let h = ceil(title.intrinsicContentSize.height)
        let titleWidth = min(ceil(title.inkWidth + Label.inset * 2), max(0, end - x))
        title.frame = NSRect(x: x, y: title.centeredY(in: bounds.height), width: titleWidth, height: h)
        // A word space from the title's last letter to the version's first, the labels' insets set aside.
        let versionX = title.frame.maxX - Label.inset * 2 + Self.versionGap
        version.frame = NSRect(x: versionX, y: version.centeredY(in: bounds.height), width: max(0, end - versionX), height: h)
        version.isHidden = version.frame.width < Tokens.Space.x4
        version.fadeTail()
    }

    /// Between Restart and the close button, as between a row's buttons.
    private static let buttonGap: CGFloat = 2
    /// Between "Update ready" and the version: a word space.
    private static let versionGap: CGFloat = 4

    override func stateDidChange(animated: Bool) {
        let theme = Brand.Theme.for(self)
        title.textColor = theme.rowInk
        version.textColor = theme.quietInk
        // The Now Playing card's look: a soft field of the space's color.
        let fill = isPressed ? Tokens.Chrome.fieldPressed : isHovered ? Tokens.Chrome.fieldHover : Tokens.Chrome.field
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        Tokens.Motion.withoutAnimation { layer?.borderWidth = 0 }
    }
}

/// The update card's Restart: a word in the space's accent, medium, as tall as a row's buttons, with a soft wash of
/// the accent under the pointer; its word centered by its capitals, as much room either side as above and below.
final class RestartPill: InteractiveView {
    private let label: Label
    let title: String

    init(title: String) {
        self.title = title
        label = Label(title, font: Self.font, color: Tokens.Color.onPrimary)
        super.init(frame: .zero)
        pressScales = true
        layer?.cornerRadius = Tokens.Radius.small + 1
        layer?.cornerCurve = .continuous
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        stateDidChange(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static var font: NSFont { .systemFont(ofSize: Tokens.Sidebar.labelText, weight: .medium) }

    func sizeChanged() {
        label.font = Self.font
        needsLayout = true
    }

    /// Its word, with as much room either side as above its capitals and below its baseline.
    var fittingWidth: CGFloat {
        let font = label.font ?? Self.font
        let room = round((Tokens.Sidebar.rowButton - font.capHeight) / 2)
        return ceil(label.inkWidth + room * 2)
    }

    override func layout() {
        super.layout()
        label.alignment = .center
        label.frame = NSRect(x: 0, y: label.centeredY(in: bounds.height), width: bounds.width, height: label.lineHeight)
    }

    override func stateDidChange(animated: Bool) {
        let accent = Brand.Theme.for(self).accent
        label.textColor = accent
        let wash: CGFloat = isPressed ? 0.2 : isHovered ? 0.12 : 0
        layer?.set(backgroundColor: wash > 0 ? cgColor(accent.withAlphaComponent(wash)) : nil, animated: false)
    }
}
