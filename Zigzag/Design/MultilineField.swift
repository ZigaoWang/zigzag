import AppKit

/// A multiline plain text field (script arguments, JSON bodies) with `FilledField`'s look and smart quotes and dashes
/// off.
final class MultilineField: NSView, NSTextViewDelegate {
    private let scroll = NSScrollView()
    private let textView: NSTextView
    private var responderWatch: NSKeyValueObservation?

    var text: String {
        get { textView.string }
        set { textView.string = newValue; needsLayout = true }
    }

    /// Called on every edit with the current text.
    var onChange: ((String) -> Void)?

    /// `font`: body by default (monospaced for code).
    init(text: String, font: NSFont = Tokens.Font.body()) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        textView.string = text
        textView.font = font
        textView.delegate = self
        textView.textColor = Tokens.Color.textPrimary
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubview(scroll)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.field
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1.5
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isEditing: Bool { window?.firstResponder === textView }

    func textDidChange(_ notification: Notification) {
        needsLayout = true
        onChange?(textView.string)
    }

    /// Focuses it once in a window.
    func focus() { window?.makeFirstResponder(textView) }

    override func setAccessibilityLabel(_ label: String?) {
        super.setAccessibilityLabel(label)
        textView.setAccessibilityLabel(label)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Focus ring follows the first responder, as on one-line fields.
        responderWatch = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateColors() }
        }
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Tokens.Color.fieldFill.cgColor
            let ring = Brand.Theme.for(self).accent.withAlphaComponent(Tokens.Color.focusAlpha)
            layer?.borderColor = (isEditing ? ring : .clear).cgColor
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 1.5, dy: 1.5)
        let used = textView.textContainer.flatMap { textView.layoutManager?.usedRect(for: $0).height } ?? 0
        textView.frame = NSRect(origin: .zero, size: NSSize(width: scroll.contentSize.width,
                                                           height: max(scroll.contentSize.height, ceil(used) + textView.textContainerInset.height * 2)))
    }
}
