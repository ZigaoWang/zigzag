import AppKit
import WebKit

/// A floating text field we draw ourselves: no bezel, our font, our colors.
final class PlainTextField: NSTextField {
    var onCancel: (() -> Void)?
    var onCommand: ((Selector) -> Bool)?

    init(font: NSFont, placeholder: String) {
        super.init(frame: .zero)
        self.font = font
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        textColor = Tokens.Color.textPrimary
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: Tokens.Color.textTertiary,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Find in page. Sits at the top right of the page card.
final class FindBarController: NSObject, NSTextFieldDelegate {
    private weak var window: BrowserWindowController?
    private let panel = FloatingPanelView()
    private let field = PlainTextField(font: Tokens.Font.body(), placeholder: "Find on page")
    private let countLabel = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let previousButton = IconButton(symbol: "chevron.up", size: Tokens.Space.x6, toolTip: "Previous")
    private let nextButton = IconButton(symbol: "chevron.down", size: Tokens.Space.x6, toolTip: "Next")
    private let doneButton = IconButton(symbol: "xmark", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "Done")
    private(set) var isVisible = false
    private var query = ""
    var hasQuery: Bool { !query.isEmpty }

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        field.delegate = self
        panel.addSubview(field)
        panel.addSubview(countLabel)
        panel.addSubview(previousButton)
        panel.addSubview(nextButton)
        panel.addSubview(doneButton)
        previousButton.onClick = { [weak self] _ in self?.next(backwards: true) }
        nextButton.onClick = { [weak self] _ in self?.next(backwards: false) }
        doneButton.onClick = { [weak self] _ in self?.hide() }
        panel.onLayout = { [weak self] in self?.layoutPanel() }
    }

    private var frame: NSRect {
        guard let window else { return .zero }
        let card = window.root.cardFrame
        let height = Tokens.Space.x10
        let width = Tokens.Metric.findBarWidth
        return NSRect(x: card.maxX - width - Tokens.Space.x3, y: card.minY + Tokens.Space.x3, width: width, height: height)
    }

    private func layoutPanel() {
        let b = panel.bounds
        let button = Tokens.Space.x6
        let y = (b.height - button) / 2
        doneButton.frame = NSRect(x: b.width - Tokens.Space.x2 - button, y: y, width: button, height: button)
        nextButton.frame = NSRect(x: doneButton.frame.minX - button, y: y, width: button, height: button)
        previousButton.frame = NSRect(x: nextButton.frame.minX - button, y: y, width: button, height: button)
        let countWidth = countLabel.textWidth
        let countHeight = ceil(countLabel.intrinsicContentSize.height)
        countLabel.frame = NSRect(x: previousButton.frame.minX - Tokens.Space.x2 - countWidth, y: (b.height - countHeight) / 2, width: countWidth, height: countHeight)
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: Tokens.Space.x3, y: (b.height - fieldHeight) / 2, width: countLabel.frame.minX - Tokens.Space.x3 - Tokens.Space.x2, height: fieldHeight)
    }

    func show(query newQuery: String? = nil) {
        guard let window else { return }
        if let newQuery { query = newQuery; field.stringValue = newQuery }
        if !isVisible {
            isVisible = true
            panel.frame = frame
            window.root.overlay.addSubview(panel)
            panel.present()
        } else {
            panel.frame = frame
        }
        window.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        if !query.isEmpty { search(backwards: false) }
    }

    func reposition() {
        guard isVisible else { return }
        panel.frame = frame
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        panel.dismiss()
        clearHighlights()
        if let webView = window?.selectedWebView { window?.window?.makeFirstResponder(webView) }
    }

    func next(backwards: Bool) {
        if !isVisible { show() }
        search(backwards: backwards)
    }

    func controlTextDidChange(_ obj: Notification) {
        query = field.stringValue
        if query.isEmpty { countLabel.stringValue = ""; clearHighlights(); layoutPanel(); return }
        search(backwards: false, fromStart: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            search(backwards: shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    private func search(backwards: Bool, fromStart: Bool = false) {
        guard let webView = window?.selectedWebView, !query.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        if fromStart { webView.evaluateJavaScript("window.getSelection().removeAllRanges()") }
        webView.find(query, configuration: config) { [weak self] result in
            self?.updateCount(found: result.matchFound)
        }
    }

    private func updateCount(found: Bool) {
        guard let webView = window?.selectedWebView else { return }
        // WebKit's public find API doesn't count; a quick text scan does.
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "$", with: "\\$")
        let script = """
        (() => { const q = `\(escaped)`.toLowerCase(); const t = (document.body ? document.body.innerText : '').toLowerCase();
          if (!q) return 0; let n = 0, i = 0; while ((i = t.indexOf(q, i)) !== -1) { n++; i += q.length; } return n; })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let count = (result as? Int) ?? 0
                self.countLabel.stringValue = found ? (count == 1 ? "1 match" : "\(max(count, 1)) matches") : "No matches"
                self.countLabel.textColor = found ? Tokens.Color.textSecondary : Tokens.Color.textTertiary
                self.layoutPanel()
            }
        }
    }

    private func clearHighlights() {
        window?.selectedWebView?.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }
}

/// A floating rounded surface with a real shadow (it sits above the page) and spring in/out.
class FloatingPanelView: NSView {
    private let surface = ColorView(color: Tokens.Color.panelBackground)
    var onLayout: (() -> Void)?
    var radius: CGFloat = Tokens.Radius.panel { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        surface.wantsLayer = true
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = Tokens.Metric.hairline
        addSubview(surface)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Content goes in the surface so it is clipped to the rounded shape.
    override func addSubview(_ view: NSView) {
        if view === surface { super.addSubview(view) } else { surface.addSubview(view) }
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        surface.layer?.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        onLayout?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            surface.layer?.borderColor = cgColor(Tokens.Color.panelEdge)
            layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
            layer?.shadowOpacity = 1
            layer?.shadowRadius = Tokens.Shadow.panelRadius / 2
            layer?.shadowOffset = CGSize(width: 0, height: -Tokens.Space.x2)
        }
    }

    /// Springs in: a short scale up from 97% with a fade. Skipped for keyboard actions unless `always`.
    func present(always: Bool = false) {
        layoutSubtreeIfNeeded()
        guard let layer, always || !Tokens.Motion.isKeyboardDriven else { alphaValue = 1; return }
        alphaValue = 0
        let scale = Tokens.Motion.springAnimation(keyPath: "transform")
        let from = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0), CATransform3DMakeScale(0.97, 0.97, 1)), CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0))
        scale.fromValue = from
        scale.toValue = CATransform3DIdentity
        layer.add(scale, forKey: "present")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Tokens.Motion.quick
            self.animator().alphaValue = 1
        }
    }

    func dismiss(always: Bool = false, completion: (() -> Void)? = nil) {
        let fade = { self.animator().alphaValue = 0 }
        let done = {
            self.removeFromSuperview()
            self.alphaValue = 1
            completion?()
        }
        if always {
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = Tokens.Motion.standard; fade() }, completionHandler: done)
            return
        }
        Tokens.Motion.animate(Tokens.Motion.feedback, { self.animator().alphaValue = 0 }, completion: {
            self.removeFromSuperview()
            self.alphaValue = 1
            completion?()
        })
    }
}

/// A brief confirmation pill at the top of the page ("Link Copied", "90%"). Shown at once, gone in a moment;
/// pressing the same shortcut again updates it in place instead of stacking another.
final class ToastView: FloatingPanelView {
    let icon = NSImageView()
    let label = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    let actionButton = TextButton(title: "", font: Tokens.Font.body(.semibold))

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleNone
        icon.contentTintColor = Tokens.Color.icon
        addSubview(icon)
        addSubview(label)
        addSubview(actionButton)
        actionButton.textColor = Tokens.Color.accent
        actionButton.isHidden = true
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    static let height = Tokens.Space.x8 + Tokens.Space.x1

    var fittingWidth: CGFloat {
        Tokens.Space.x3 + (icon.image == nil ? 0 : Tokens.Metric.favicon + Tokens.Space.x2) + label.textWidth
            + (actionButton.isHidden ? Tokens.Space.x3 : Tokens.Space.x1 + actionButton.fittingWidth + Tokens.Space.x1)
    }

    /// The space around the text: the icon on the left, the action (or padding) on the right.
    private var chromeWidth: CGFloat { fittingWidth - label.textWidth }

    /// Fits `maxWidth`: one line when it can, two wrapped lines when it can't, never past the page.
    func size(maxWidth: CGFloat) -> NSSize {
        let width = min(ceil(fittingWidth), maxWidth)
        let textWidth = width - chromeWidth
        let wraps = label.textWidth > textWidth + 0.5
        label.usesSingleLineMode = !wraps
        label.maximumNumberOfLines = wraps ? 2 : 1
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        label.cell?.wraps = wraps
        label.cell?.truncatesLastVisibleLine = true
        let textHeight = wraps ? ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 200)).height ?? label.lineHeight * 2) : label.lineHeight
        radius = wraps ? Tokens.Radius.panel : Self.height / 2
        return NSSize(width: width, height: max(Self.height, textHeight + Tokens.Space.x4))
    }

    private func layoutContent() {
        var x = Tokens.Space.x3
        if icon.image != nil {
            icon.frame = NSRect(x: x, y: (bounds.height - Tokens.Metric.favicon) / 2, width: Tokens.Metric.favicon, height: Tokens.Metric.favicon)
            x = icon.frame.maxX + Tokens.Space.x2
        }
        let actionWidth = actionButton.isHidden ? 0 : actionButton.fittingWidth
        if !actionButton.isHidden {
            actionButton.frame = NSRect(x: bounds.width - Tokens.Space.x1 - actionWidth, y: (bounds.height - Tokens.Space.x6) / 2, width: actionWidth, height: Tokens.Space.x6)
        }
        let textWidth = bounds.width - chromeWidth
        let h = label.usesSingleLineMode ? label.lineHeight : bounds.height - Tokens.Space.x4
        label.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: textWidth, height: h)
    }
}

enum Toast {
    private static weak var current: ToastView?
    private static var hideWork: DispatchWorkItem?

    /// Takes down the toast showing in this window, if any.
    static func hide(in controller: BrowserWindowController) {
        guard let toast = current, toast.superview === controller.root.overlay else { return }
        hideWork?.cancel()
        toast.dismiss(always: true)
        current = nil
    }

    static func show(_ text: String, symbol: String? = nil, action: (title: String, run: () -> Void)? = nil,
                     duration: TimeInterval = 1.3, in controller: BrowserWindowController) {
        show(text, symbol: symbol, action: action, duration: duration, over: controller.root.overlay, area: controller.root.cardFrame)
    }

    /// Shows a toast at the top center of `area` in any flipped host view (the Passwords window uses it too).
    static func show(_ text: String, symbol: String? = nil, action: (title: String, run: () -> Void)? = nil,
                     duration: TimeInterval = 1.3, over host: NSView, area: NSRect) {
        let toast: ToastView
        let isNew: Bool
        if let existing = current, existing.superview === host {
            toast = existing
            isNew = false
        } else {
            toast = ToastView()
            isNew = true
        }
        toast.label.stringValue = text
        toast.icon.image = symbol.map { Tokens.Symbol.image($0) }
        toast.actionButton.isHidden = action == nil
        if let action {
            toast.actionButton.title = action.title
            toast.actionButton.onClick = { [weak toast] _ in
                action.run()
                toast?.dismiss(always: true)
            }
        }
        let size = toast.size(maxWidth: max(160, area.width - Tokens.Space.x12))
        // Top center of the page: where your eyes already are, clear of the content you're reading.
        toast.frame = NSRect(x: round(area.midX - size.width / 2), y: area.minY + Tokens.Space.x3, width: size.width, height: size.height)
        toast.needsLayout = true
        if isNew {
            host.addSubview(toast)
            toast.present(always: true)
            Tokens.Motion.slideVertically(toast, fromOffsetY: -Tokens.Space.x2)
        } else {
            // A repeat (zoom 90% → 80%) gives a small pulse so the change registers.
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1, 1.04, 1]
            pulse.duration = Tokens.Motion.standard
            toast.layer?.add(pulse, forKey: "pulse")
        }
        current = toast
        hideWork?.cancel()
        // Toasts with an action wait for the pointer to leave before going.
        let work = DispatchWorkItem { [weak toast] in
            MainActor.assumeIsolated {
                guard let toast, toast.superview != nil else { return }
                if action != nil, toast.bounds.contains(toast.convert(toast.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) {
                    Toast.hideWork = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak toast] in toast?.dismiss(always: true) }
                    return
                }
                toast.dismiss(always: true)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
