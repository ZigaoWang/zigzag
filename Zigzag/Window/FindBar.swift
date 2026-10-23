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
        let countWidth = ceil(countLabel.intrinsicContentSize.width)
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

    /// Springs in: a short scale up from 97% with a fade.
    func present() {
        alphaValue = 0
        layoutSubtreeIfNeeded()
        guard let layer else { alphaValue = 1; return }
        let scale = Tokens.Motion.springAnimation(keyPath: "transform")
        let from = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0), CATransform3DMakeScale(0.97, 0.97, 1)), CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0))
        scale.fromValue = from
        scale.toValue = CATransform3DIdentity
        layer.add(scale, forKey: "present")
        Tokens.Motion.animate(Tokens.Motion.feedback) { self.animator().alphaValue = 1 }
    }

    func dismiss(completion: (() -> Void)? = nil) {
        Tokens.Motion.animate(Tokens.Motion.feedback, { self.animator().alphaValue = 0 }, completion: {
            self.removeFromSuperview()
            self.alphaValue = 1
            completion?()
        })
    }
}

/// A brief confirmation at the bottom of the page ("Copied link"). Quiet, and gone in a moment.
enum Toast {
    private static weak var current: FloatingPanelView?
    private static let hide = Debouncer(delay: 1.4)

    static func show(_ text: String, in controller: BrowserWindowController) {
        current?.removeFromSuperview()
        let label = Label(text, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        let size = label.intrinsicContentSize
        let panel = FloatingPanelView()
        panel.radius = Tokens.Radius.row
        let width = ceil(size.width) + Tokens.Space.x8
        let height = Tokens.Space.x8 + Tokens.Space.x1
        let card = controller.root.cardFrame
        panel.frame = NSRect(x: card.midX - width / 2, y: card.maxY - height - Tokens.Space.x4, width: width, height: height)
        panel.addSubview(label)
        label.frame = NSRect(x: Tokens.Space.x4, y: (height - ceil(size.height)) / 2, width: ceil(size.width), height: ceil(size.height))
        controller.root.overlay.addSubview(panel)
        panel.present()
        current = panel
        hide.call { [weak panel] in panel?.dismiss() }
    }
}
