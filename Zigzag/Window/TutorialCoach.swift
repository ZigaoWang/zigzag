import AppKit

/// The Getting started guide: a small card in the bottom corner of the window with just the step to do now.
/// It follows you from tab to tab, and moves on by itself the moment you've done the step.
final class TutorialCoach: FloatingPanelView {
    private static weak var current: TutorialCoach?
    private weak var controller: BrowserWindowController?
    private let eyebrow = Label("Getting started", font: Tokens.Font.small(.semibold), color: Brand.Theme.brand.accent)
    private let count = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textTertiary)
    private let close = IconButton(symbol: "xmark", size: Tokens.Space.x6, symbolSize: 9, toolTip: "Hide Getting Started")
    private let check = NSImageView()
    private let title = Label("", font: .systemFont(ofSize: 15, weight: .semibold), color: Tokens.Color.textPrimary)
    private let how = NSTextField(wrappingLabelWithString: "")
    private var caps: [(ColorView, Label)] = []
    private let skip = TextButton(title: "Skip", font: Tokens.Font.small(.medium))
    private let done = PrimaryButton(title: "Done")
    private var token: SignalToken?
    private var celebrating = false

    static let width: CGFloat = 320

    /// Shows the guide in a window, if there's a step left and you haven't hidden it.
    static func show(in controller: BrowserWindowController) {
        guard Tutorial.current != nil, !Tutorial.isHidden else { return }
        current?.removeFromSuperview()
        let coach = TutorialCoach(controller: controller)
        current = coach
        controller.root.overlay.addSubview(coach)
        coach.refresh(animated: false)
        coach.present(arrival: .drop)
    }

    private init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 160))
        radius = Tokens.Radius.panel + 2
        check.image = Tokens.Symbol.image("checkmark.circle.fill", size: 18)
        check.contentTintColor = Brand.Theme.brand.accent
        check.isHidden = true
        how.font = Tokens.Font.body()
        how.textColor = Tokens.Color.textSecondary
        how.isSelectable = false
        skip.textColor = Tokens.Color.textTertiary
        [eyebrow, count, close, check, title, how, skip, done].forEach { addSubview($0) }
        close.onClick = { _ in
            Tutorial.isHidden = true
            TutorialCoach.current?.dismiss()
        }
        skip.onClick = { _ in Tutorial.skip() }
        done.onClick = { [weak self] _ in self?.dismiss() }
        done.isHidden = true
        token = Tutorial.changed.observe { [weak self] in self?.stepDone() }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A beat with a check on the step you just did, then the next one.
    private func stepDone() {
        guard !celebrating else { return }
        celebrating = true
        check.isHidden = false
        title.textColor = Tokens.Color.textSecondary
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.celebrating = false
            self.check.isHidden = true
            self.title.textColor = Tokens.Color.textPrimary
            self.refresh(animated: true)
        }
    }

    private func refresh(animated: Bool) {
        caps.forEach { $0.0.removeFromSuperview() }
        caps = []
        if let task = Tutorial.current, let index = Tutorial.tasks.firstIndex(where: { $0.id == task.id }) {
            count.stringValue = "\(index + 1) of \(Tutorial.tasks.count)"
            title.stringValue = task.title
            how.stringValue = task.how
            for key in task.keys {
                let cap = ColorView(color: Tokens.Color.fieldFill)
                cap.wantsLayer = true
                cap.layer?.cornerRadius = 6
                cap.layer?.cornerCurve = .continuous
                let label = Label(key, font: .systemFont(ofSize: 12, weight: .semibold), color: Tokens.Color.textPrimary)
                label.alignment = .center
                cap.addSubview(label)
                addSubview(cap)
                caps.append((cap, label))
            }
            skip.isHidden = false
            done.isHidden = true
        } else {
            count.stringValue = ""
            title.stringValue = "That’s the basics"
            how.stringValue = "You’ve opened, pinned, peeked, split and made a space. Help › Getting Started brings this back anytime."
            skip.isHidden = true
            done.isHidden = false
        }
        let oldHeight = frame.height
        needsLayout = true
        layoutSubtreeIfNeeded()
        place()
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            layer?.add(fade, forKey: "step")
        }
        _ = oldHeight
    }

    private var contentHeight: CGFloat {
        let pad = Tokens.Space.x4
        let hh = ceil(how.sizeThatFits(NSSize(width: Self.width - pad * 2, height: 200)).height)
        return pad + eyebrow.lineHeight + Tokens.Space.x3 + title.lineHeight + Tokens.Space.x1 + hh + Tokens.Space.x4 + 26 + pad
    }

    /// Bottom right of the page, inside the window.
    private func place() {
        guard let controller else { return }
        let card = controller.root.cardFrame
        let h = contentHeight
        frame = NSRect(x: card.maxX - Self.width - Tokens.Space.x4, y: card.maxY - h - Tokens.Space.x4, width: Self.width, height: h)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil else { return }
        superview?.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(windowResized), name: NSView.frameDidChangeNotification, object: superview)
    }

    @objc private func windowResized() { place() }

    private func layoutContent() {
        let pad = Tokens.Space.x4
        let w = bounds.width
        eyebrow.frame = NSRect(x: pad, y: pad, width: 160, height: eyebrow.lineHeight)
        close.frame.origin = NSPoint(x: w - pad - close.frame.width + Tokens.Space.x1, y: pad - 4)
        let cw = count.textWidth + 2
        count.frame = NSRect(x: close.frame.minX - Tokens.Space.x2 - cw, y: pad, width: cw, height: count.lineHeight)
        var y = eyebrow.frame.maxY + Tokens.Space.x3
        check.frame = NSRect(x: pad, y: y, width: 18, height: 18)
        let tx = check.isHidden ? pad : check.frame.maxX + Tokens.Space.x2
        title.frame = NSRect(x: tx, y: y, width: w - tx - pad, height: title.lineHeight)
        y = title.frame.maxY + Tokens.Space.x1
        let hh = ceil(how.sizeThatFits(NSSize(width: w - pad * 2, height: 200)).height)
        how.frame = NSRect(x: pad, y: y, width: w - pad * 2, height: hh)
        y = how.frame.maxY + Tokens.Space.x4
        var x = pad
        for (cap, label) in caps {
            let cw = max(26, label.inkWidth + Tokens.Space.x4)
            cap.frame = NSRect(x: x, y: y, width: cw, height: 26)
            label.frame = NSRect(x: 0, y: (26 - label.lineHeight) / 2, width: cw, height: label.lineHeight)
            x += cw + 4
        }
        let sw = skip.fittingWidth
        skip.frame = NSRect(x: w - pad - sw + Tokens.Space.x2, y: y - 3, width: sw, height: Tokens.Space.x8)
        let dw = max(done.fittingWidth, 80)
        done.frame = NSRect(x: w - pad - dw, y: y - 3, width: dw, height: Tokens.Space.x8)
    }
}
