import AppKit

/// Update progress at the bottom of the sidebar. A requested update shows "Downloading update" with version, amount
/// and a bar, then "Preparing update" while Sparkle unpacks and verifies, then "Update ready" with Restart and a close
/// button (hides it until relaunch; it still installs on quit). States change in place. While ready, clicking anywhere
/// restarts. With automatic installs off, a found update shows "Update available" with Update and Skip.
final class UpdateCard: InteractiveView {
    private let icon = NSImageView()
    private let title = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
    private let version = Label("", font: UpdateCard.detailFont, color: Tokens.Color.textSecondary)
    /// Downloaded amount, "12 of 40 MB", in tabular figures.
    private let amount = Label("", font: UpdateCard.amountFont, color: Tokens.Color.textSecondary)
    private let bar = UpdateBar()
    /// Version and amount under the title: section label size, regular, secondary ink.
    private static var detailFont: NSFont { .systemFont(ofSize: Tokens.Sidebar.labelText) }
    private static var amountFont: NSFont { .monospacedDigitSystemFont(ofSize: Tokens.Sidebar.labelText, weight: .regular) }
    let restartButton = RestartPill(title: String(localized: "Restart", comment: "Button that restarts Zigzag into an update that's ready: on the sidebar's update card, in a toast and in Settings › General."))
    /// Last, where a tab row's close is.
    let hideButton = TabRowView.rowButton("xmark", toolTip: String(localized: "Not Now", comment: "Tooltip and VoiceOver action of the close button on the sidebar's update card: puts the card away; the update installs when Zigzag quits."))
    /// Available only: downloads, then restarts.
    let updateButton = RestartPill(title: String(localized: "Update", comment: "Button on the sidebar's update card and in Settings › General while automatic installs are off: downloads the update, then restarts Zigzag into it."))
    let skipButton = RestartPill(title: String(localized: "Skip", comment: "Button on the sidebar's update card while automatic installs are off: skips this version."), quiet: true)
    var onRestart: (() -> Void)?
    var onHide: (() -> Void)?
    var onUpdate: (() -> Void)?
    var onSkip: (() -> Void)?
    /// Over the page with the sidebar hidden: the panel is its background, so no field of its own.
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
        skipButton.toolTip = Self.skipName
        [icon, title, version, amount, bar, restartButton, hideButton, updateButton, skipButton].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard self?.state?.isReady == true else { return }
            self?.onRestart?()
        }
        restartButton.onClick = { [weak self] _ in self?.onRestart?() }
        hideButton.onClick = { [weak self] _ in self?.onHide?() }
        updateButton.onClick = { [weak self] _ in self?.onUpdate?() }
        skipButton.onClick = { [weak self] _ in self?.onSkip?() }
        sizeObserver = NotificationCenter.default.addObserver(forName: Tokens.Sidebar.sizeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.title.font = Tokens.Font.sidebarRow()
                self.version.font = UpdateCard.detailFont
                self.amount.font = UpdateCard.amountFont
                self.hideButton.symbolSize = Tokens.Sidebar.rowGlyph
                self.restartButton.sizeChanged()
                self.updateButton.sizeChanged()
                self.skipButton.sizeChanged()
                self.needsLayout = true
            }
        }
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Card height for `state`: two lines when ready or available, plus the bar while downloading.
    static func height(for state: UpdateCardState?) -> CGFloat {
        state?.isBusy == true ? Tokens.Sidebar.updateCardBusyHeight : Tokens.Sidebar.updateCardHeight
    }

    private static var skipName: String {
        String(localized: "Skip This Version", comment: "Tooltip and VoiceOver action of Skip on the sidebar's update card: this version isn't offered again; a newer one is.")
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
        case .available:
            title.stringValue = String(localized: "Update available", comment: "Title of the sidebar's update card for an update found while automatic installs are off: Update downloads it and restarts.")
            sentence = String(localized: "Zigzag \(text) is available. Update downloads it and restarts Zigzag.",
                              comment: "VoiceOver label of the sidebar's update card while automatic installs are off. The placeholder is the version.")
        }
        let ready = state.isReady
        let available: Bool = if case .available = state { true } else { false }
        amount.isHidden = !state.isBusy || amount.stringValue.isEmpty
        bar.isHidden = !state.isBusy
        restartButton.isHidden = !ready
        hideButton.isHidden = !ready
        updateButton.isHidden = !available
        skipButton.isHidden = !available
        toolTip = ready ? sentence : nil
        setAccessibilityLabel(sentence)
        setAccessibilityCustomActions(ready ? actions : available ? offerActions : [])
        if !ready { isHovered = false }
        // New state: cross-fade the text while the bar or buttons change.
        if let old, Self.step(old) != Self.step(state), let layer, window != nil, !Tokens.Motion.isFromKey {
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
        case .available: 3
        }
    }

    /// "9.4 of 18.2 MB", one decimal as Finder shows; whole kilobytes below a megabyte.
    static func amount(_ received: UInt64, of total: UInt64) -> String {
        let inMB = total >= 1_000_000
        let step: Double = inMB ? 100_000 : 1_000
        let unitSize: Double = inMB ? 1_000_000 : 1_000
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.minimumFractionDigits = inMB ? 1 : 0
        number.maximumFractionDigits = inMB ? 1 : 0
        // Round the downloaded amount down, so it only reads complete when it is.
        func figure(_ bytes: UInt64, _ rule: FloatingPointRoundingRule) -> String {
            let value = (Double(bytes) / step).rounded(rule) * step / unitSize
            return number.string(from: NSNumber(value: value)) ?? "\(value)"
        }
        let unit = ByteCountFormatter()
        unit.allowedUnits = inMB ? .useMB : .useKB
        unit.countStyle = .file
        unit.includesCount = false
        let whole = figure(total, .toNearestOrAwayFromZero) + " " + unit.string(fromByteCount: Int64(total))
        let part = figure(min(received, total), .down)
        return String(localized: "\(part) of \(whole)", comment: "On the sidebar's update card while an update downloads: how much has come of how much, like 9.4 of 18.2 MB.")
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

    private lazy var offerActions: [NSAccessibilityCustomAction] = [
        NSAccessibilityCustomAction(name: updateButton.title) { [weak self] in
            MainActor.assumeIsolated {
                guard let update = self?.onUpdate else { return false }
                update()
                return true
            }
        },
        NSAccessibilityCustomAction(name: Self.skipName) { [weak self] in
            MainActor.assumeIsolated {
                guard let skip = self?.onSkip else { return false }
                skip()
                return true
            }
        },
    ]

    override func layout() {
        super.layout()
        let ready = state?.isBusy != true
        let available: Bool = if case .available = state { true } else { false }
        // Text (and the bar while downloading) centered vertically by caps: title cap top to bar bottom (or version baseline).
        let titleFont = title.font ?? Tokens.Font.sidebarRow(), detailFont = version.font ?? Self.detailFont
        let lines = titleFont.capHeight + Self.lineGap + detailFont.capHeight
        let block = lines + (ready ? 0 : Self.barGap + UpdateBar.height)
        let top = (bounds.height - block) / 2
        // Icon centered beside the two lines.
        let size = Tokens.Sidebar.favicon
        icon.frame = NSRect(x: SidebarRowView.inset, y: pixel(top + lines / 2 - size / 2), width: size, height: size)
        let b = Tokens.Sidebar.rowButton
        let y = (bounds.height - b) / 2
        let hide = NSRect(x: bounds.width - SidebarRowView.buttonEdge - b, y: y, width: b, height: b)
        let pill = restartButton.fittingWidth
        let restart = NSRect(x: hide.minX - Self.buttonGap - pill, y: y, width: pill, height: b)
        hideButton.frame = hide
        restartButton.frame = restart
        // Skip where close is, Update before it.
        let skipWidth = skipButton.fittingWidth, updateWidth = updateButton.fittingWidth
        let skip = NSRect(x: bounds.width - SidebarRowView.buttonEdge - skipWidth, y: y, width: skipWidth, height: b)
        skipButton.frame = skip
        updateButton.frame = NSRect(x: skip.minX - Self.buttonGap - updateWidth, y: y, width: updateWidth, height: b)
        // Text column ends at Restart (its padding is the gap), or while downloading as far from the right as the icon's art from the left.
        let x = icon.frame.maxX + SidebarRowView.titleOffset
        let art = SidebarRowView.inset + round(size * 100 / 1024 * 2) / 2
        let end = available ? updateButton.frame.minX : ready ? restart.minX : bounds.width - art + Label.inset
        let width = max(0, end - x)
        title.frame = NSRect(x: x, y: lineY(title, capsMiddle: top + titleFont.capHeight / 2), width: width, height: title.lineHeight)
        let detailY = top + lines - detailFont.capHeight / 2
        let amountWidth = amount.isHidden ? 0 : ceil(amount.inkWidth + Label.inset * 2)
        amount.frame = NSRect(x: end - amountWidth, y: lineY(amount, capsMiddle: detailY), width: amountWidth, height: amount.lineHeight)
        let versionEnd = amount.isHidden ? end : amount.frame.minX - Tokens.Space.x2 + Label.inset * 2
        version.frame = NSRect(x: x, y: lineY(version, capsMiddle: detailY), width: max(0, versionEnd - x), height: version.lineHeight)
        // Bar from the text's first letter to the amount's end.
        bar.frame = NSRect(x: x + Label.inset, y: pixel(top + lines + Self.barGap), width: max(0, end - Label.inset - (x + Label.inset)), height: UpdateBar.height)
        title.fadeTail()
        version.fadeTail()
    }

    private func pixel(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    /// Line origin that puts its cap middle at `capsMiddle`, pixel-aligned.
    private func lineY(_ label: Label, capsMiddle: CGFloat) -> CGFloat {
        let below = Label.capsBelowMiddle(of: label.font ?? Tokens.Font.sidebarRow(), lineHeight: label.lineHeight)
        return pixel(capsMiddle - label.lineHeight / 2 - below)
    }

    /// Gap between Restart and close, as between row buttons.
    private static let buttonGap: CGFloat = 2
    /// Title baseline to version cap top.
    private static let lineGap: CGFloat = 5
    /// Version baseline to bar.
    private static let barGap: CGFloat = 7

    override func stateDidChange(animated: Bool) {
        let theme = Brand.Theme.for(self)
        title.textColor = theme.rowInk
        version.textColor = theme.quietInk
        amount.textColor = theme.quietInk
        bar.tint(track: theme.quietInk, fill: theme.accent)
        // Same field as the Now Playing card (space tint); hover only while clickable.
        let ready = state?.isReady ?? true
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

/// Thin rounded progress bar: secondary ink track, space accent fill, eased to each value. With no value (preparing or
/// unknown size) a short segment slides across, like macOS indeterminate bars.
final class UpdateBar: NSView {
    static let height: CGFloat = 4
    private let track = CALayer()
    private let fill = CALayer()

    /// 0 to 1, or nil for indeterminate.
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
            // Indeterminate: a quarter-width segment looping across.
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

/// Restart button: accent-colored medium text, row-button height, accent wash on hover, caps-centered with equal padding.
/// `quiet` uses the secondary ink instead, for the lesser choice beside it.
final class RestartPill: InteractiveView {
    private let label: Label
    let title: String
    private let quiet: Bool

    init(title: String, quiet: Bool = false) {
        self.title = title
        self.quiet = quiet
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

    /// Equal padding around the word: sides match space above caps and below baseline.
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
        let theme = Brand.Theme.for(self)
        let ink = quiet ? (isHovered ? theme.rowInk : theme.quietInk) : theme.accent
        label.textColor = ink
        let wash: CGFloat = isPressed ? 0.2 : isHovered ? 0.12 : 0
        let washInk = quiet ? theme.quietInk : theme.accent
        layer?.set(backgroundColor: wash > 0 ? cgColor(washInk.withAlphaComponent(wash)) : nil, animated: false)
    }
}
