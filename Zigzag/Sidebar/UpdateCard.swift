import AppKit

/// The update, at the foot of the sidebar: its one home. One you asked for comes in here, "Downloading update" over
/// the version and how much has come, with a bar that fills; then "Preparing update" while Sparkle unpacks and
/// checks it; then "Update ready" over the version, with a Restart that restarts into it with everything back and a
/// close button that puts it away until Zigzag restarts (the update still installs when Zigzag quits). It goes from
/// one to the next in place. Two lines on a row's columns, so the version is always whole; while it's ready, a click
/// anywhere on it restarts, as Restart does.
final class UpdateCard: InteractiveView {
    private let icon = NSImageView()
    private let title = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
    private let version = Label("", font: UpdateCard.detailFont, color: Tokens.Color.textSecondary)
    /// How much has come, at the version's line's end: "12 of 40 MB", in figures that don't shift as they count.
    private let amount = Label("", font: UpdateCard.amountFont, color: Tokens.Color.textSecondary)
    private let bar = UpdateBar()
    /// The version and the amount under the title: a section label's size, regular, in quiet ink.
    private static var detailFont: NSFont { .systemFont(ofSize: Tokens.Sidebar.labelText) }
    private static var amountFont: NSFont { .monospacedDigitSystemFont(ofSize: Tokens.Sidebar.labelText, weight: .regular) }
    let restartButton = RestartPill(title: String(localized: "Restart", comment: "Button that restarts Zigzag into an update that's ready: on the sidebar's update card, in a toast and in Settings › General."))
    /// Last, where a tab row's close is.
    let hideButton = TabRowView.rowButton("xmark", toolTip: String(localized: "Not Now", comment: "Tooltip and VoiceOver action of the close button on the sidebar's update card: puts the card away; the update installs when Zigzag quits."))
    var onRestart: (() -> Void)?
    var onHide: (() -> Void)?
    /// Floating over the page with the sidebar hidden: the panel under it is its ground, so it has no field of its own.
    var isFloating = false { didSet { stateDidChange(animated: false) } }
    private(set) var state: UpdateCardState?
    private var sizeObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Sidebar.rowRadius
        layer?.cornerCurve = .continuous
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.fadesTail = true
        version.fadesTail = true
        amount.alignment = .right
        [icon, title, version, amount, bar, restartButton, hideButton].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard self?.state?.isReady == true else { return }
            self?.onRestart?()
        }
        restartButton.onClick = { [weak self] _ in self?.onRestart?() }
        hideButton.onClick = { [weak self] _ in self?.onHide?() }
        sizeObserver = NotificationCenter.default.addObserver(forName: Tokens.Sidebar.sizeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.title.font = Tokens.Font.sidebarRow()
                self.version.font = UpdateCard.detailFont
                self.amount.font = UpdateCard.amountFont
                self.hideButton.symbolSize = Tokens.Sidebar.rowGlyph
                self.restartButton.sizeChanged()
                self.needsLayout = true
            }
        }
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// How tall the card is for `state`: two lines when it's ready, and the bar under them while it comes in.
    static func height(for state: UpdateCardState?) -> CGFloat {
        state?.isReady == false ? Tokens.Sidebar.updateCardBusyHeight : Tokens.Sidebar.updateCardHeight
    }

    func show(_ state: UpdateCardState) {
        let old = self.state
        self.state = state
        let text = VersionName.display(state.version)
        version.stringValue = text
        let sentence: String
        switch state {
        case .downloading(_, let received, let total):
            title.stringValue = String(localized: "Downloading update", comment: "Title of the sidebar's update card while an update you asked for downloads.")
            amount.stringValue = total > 0 ? Self.amount(received, of: total) : ""
            bar.share = state.share
            sentence = String(localized: "Downloading Zigzag \(text)…", comment: "VoiceOver label of the sidebar's update card while an update downloads. The placeholder is the version.")
        case .preparing:
            title.stringValue = String(localized: "Preparing update", comment: "Title of the sidebar's update card once an update has downloaded, while it's unpacked and checked.")
            amount.stringValue = ""
            bar.share = nil
            sentence = String(localized: "Preparing Zigzag \(text)…", comment: "VoiceOver label of the sidebar's update card while a downloaded update is unpacked and checked. The placeholder is the version.")
        case .ready:
            title.stringValue = String(localized: "Update ready", comment: "The sidebar's card for an update that's downloaded and ready: Restart installs it.")
            sentence = String(localized: "Zigzag \(text) is ready. Restart to update.", comment: "Tooltip and VoiceOver label of the sidebar's update card. The placeholder is the version.")
        }
        let ready = state.isReady
        amount.isHidden = ready || amount.stringValue.isEmpty
        bar.isHidden = ready
        restartButton.isHidden = !ready
        hideButton.isHidden = !ready
        toolTip = ready ? sentence : nil
        setAccessibilityLabel(sentence)
        setAccessibilityCustomActions(ready ? actions : [])
        if !ready { isHovered = false }
        // A new step: the words cross-fade where they are, as the bar or the buttons come and go.
        if let old, old.isReady != ready || Self.step(old) != Self.step(state), let layer, window != nil, !Tokens.Motion.isFromKey {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Tokens.Motion.selection
            fade.timingFunction = Tokens.Motion.easeOut
            layer.add(fade, forKey: "step")
        }
        stateDidChange(animated: false)
        needsLayout = true
    }

    private static func step(_ state: UpdateCardState) -> Int {
        switch state {
        case .downloading: 0
        case .preparing: 1
        case .ready: 2
        }
    }

    /// "12 of 40 MB": whole megabytes, so the count never grows a decimal its total doesn't have.
    static func amount(_ received: UInt64, of total: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useMB
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        // Whole megabytes; what's come is rounded down, so it reads as all there only once it is.
        func megabytes(_ bytes: UInt64, _ rule: FloatingPointRoundingRule) -> Int64 {
            Int64((Double(bytes) / 1_000_000).rounded(rule)) * 1_000_000
        }
        let whole = formatter.string(fromByteCount: megabytes(total, .toNearestOrAwayFromZero))
        formatter.includesUnit = false
        let part = formatter.string(fromByteCount: megabytes(min(received, total), .down))
        return String(localized: "\(part) of \(whole)", comment: "On the sidebar's update card while an update downloads: how much has come of how much, like 12 of 40 MB.")
    }

    private lazy var actions: [NSAccessibilityCustomAction] = [
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
    ]

    override func layout() {
        super.layout()
        let ready = state?.isReady != false
        // The words, and the bar under them while it comes in, set by their capitals: the title's tops to the
        // bar's foot (or the version's baseline) in the middle, as much room above as below.
        let titleFont = title.font ?? Tokens.Font.sidebarRow(), detailFont = version.font ?? Self.detailFont
        let lines = titleFont.capHeight + Self.lineGap + detailFont.capHeight
        let block = lines + (ready ? 0 : Self.barGap + UpdateBar.height)
        let top = (bounds.height - block) / 2
        let margin = top
        // The icon beside the two lines, in the middle of them.
        let size = Tokens.Sidebar.favicon
        icon.frame = NSRect(x: SidebarRowView.inset, y: pixel(top + lines / 2 - size / 2), width: size, height: size)
        let b = Tokens.Sidebar.rowButton
        let y = (bounds.height - b) / 2
        let hide = NSRect(x: bounds.width - SidebarRowView.buttonEdge - b, y: y, width: b, height: b)
        let pill = restartButton.fittingWidth
        let restart = NSRect(x: hide.minX - Self.buttonGap - pill, y: y, width: pill, height: b)
        hideButton.frame = hide
        restartButton.frame = restart
        // On the text column; up to Restart, whose own room either side of its word is the gap before it, or, while
        // it comes in, as far from the right edge as the words are from the top.
        let x = icon.frame.maxX + SidebarRowView.titleOffset
        let end = ready ? restart.minX : bounds.width - margin + Label.inset
        let width = max(0, end - x)
        title.frame = NSRect(x: x, y: lineY(title, capsMiddle: top + titleFont.capHeight / 2), width: width, height: title.lineHeight)
        let detailY = top + lines - detailFont.capHeight / 2
        let amountWidth = amount.isHidden ? 0 : ceil(amount.inkWidth + Label.inset * 2)
        amount.frame = NSRect(x: end - amountWidth, y: lineY(amount, capsMiddle: detailY), width: amountWidth, height: amount.lineHeight)
        let versionEnd = amount.isHidden ? end : amount.frame.minX - Tokens.Space.x2 + Label.inset * 2
        version.frame = NSRect(x: x, y: lineY(version, capsMiddle: detailY), width: max(0, versionEnd - x), height: version.lineHeight)
        // The bar under the words, from the text's first letter to where the amount ends.
        bar.frame = NSRect(x: x + Label.inset, y: pixel(top + lines + Self.barGap), width: max(0, end - Label.inset - (x + Label.inset)), height: UpdateBar.height)
        title.fadeTail()
        version.fadeTail()
    }

    private func pixel(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    /// Where a line goes for its capitals' middle to land at `capsMiddle`, on the screen's pixels.
    private func lineY(_ label: Label, capsMiddle: CGFloat) -> CGFloat {
        let below = Label.capsBelowMiddle(of: label.font ?? Tokens.Font.sidebarRow(), lineHeight: label.lineHeight)
        return pixel(capsMiddle - label.lineHeight / 2 - below)
    }

    /// Between Restart and the close button, as between a row's buttons.
    private static let buttonGap: CGFloat = 2
    /// From the title's baseline to the tops of the version's capitals.
    private static let lineGap: CGFloat = 5
    /// From the version's baseline to the bar.
    private static let barGap: CGFloat = 7

    override func stateDidChange(animated: Bool) {
        let theme = Brand.Theme.for(self)
        title.textColor = theme.rowInk
        version.textColor = theme.quietInk
        amount.textColor = theme.quietInk
        bar.tint(track: theme.quietInk, fill: theme.accent)
        // The Now Playing card's look, a soft field of the space's color; under the pointer only while there's
        // something to click.
        let ready = state?.isReady != false
        let fill = !ready ? Tokens.Chrome.field : isPressed ? Tokens.Chrome.fieldPressed : isHovered ? Tokens.Chrome.fieldHover : Tokens.Chrome.field
        let ground = isFloating && (!ready || !isHovered) ? nil : cgColor(fill)
        layer?.set(backgroundColor: ground, animated: animated && !isHovered)
        Tokens.Motion.withoutAnimation { layer?.borderWidth = 0 }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange(animated: false)
    }
}

/// The update card's progress: a thin rounded bar, a soft tint of the card's quiet ink for its track and the space's
/// accent filling it, easing to each new amount. With no amount (preparing, or before the size is known), a short
/// piece of it slides across, as the Mac's own bars do when they can't say how long.
final class UpdateBar: NSView {
    static let height: CGFloat = 4
    private let track = CALayer()
    private let fill = CALayer()

    /// 0 to 1, or nil for the sliding piece.
    var share: Double? = nil {
        didSet { apply(from: oldValue) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.masksToBounds = true
        track.cornerCurve = .continuous
        fill.cornerCurve = .continuous
        fill.anchorPoint = .zero
        track.addSublayer(fill)
        layer?.addSublayer(track)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func tint(track trackInk: NSColor, fill fillInk: NSColor) {
        Tokens.Motion.withoutAnimation {
            track.backgroundColor = cgColor(trackInk.withAlphaComponent(0.18))
            fill.backgroundColor = cgColor(fillInk)
        }
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            track.frame = bounds
            track.cornerRadius = bounds.height / 2
            fill.cornerRadius = bounds.height / 2
        }
        apply(from: share, animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply(from: share, animated: false)
    }

    private func apply(from old: Double?, animated: Bool = true) {
        let w = bounds.width, h = bounds.height
        guard w > 0 else { return }
        guard let share else {
            // The sliding piece: a quarter of the track, across and round again.
            let piece = round(w * 0.28)
            Tokens.Motion.withoutAnimation { fill.frame = CGRect(x: 0, y: 0, width: piece, height: h) }
            guard fill.animation(forKey: "slide") == nil, window != nil else { return }
            fill.removeAnimation(forKey: "grow")
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = -piece
            slide.toValue = w
            slide.duration = 1.3
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            slide.repeatCount = .infinity
            fill.add(slide, forKey: "slide")
            return
        }
        fill.removeAnimation(forKey: "slide")
        let target = max(h, w * CGFloat(min(max(share, 0), 1)))
        let shown = fill.presentation()?.bounds.width ?? fill.bounds.width
        Tokens.Motion.withoutAnimation { fill.frame = CGRect(x: 0, y: 0, width: target, height: h) }
        guard animated, old != nil, window != nil, abs(shown - target) > 0.5 else { return }
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = shown
        grow.toValue = target
        grow.duration = 0.3
        grow.timingFunction = CAMediaTimingFunction(name: .linear)
        fill.add(grow, forKey: "grow")
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
