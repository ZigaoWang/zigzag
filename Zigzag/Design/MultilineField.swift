import AppKit

/// A field for several lines of plain text (a script's arguments, a JSON body): `FilledField`'s fill, corners and
/// focus ring around a scrolling text view, in the body type, with the Mac's smart quotes and dashes off so what you
/// type is what's kept.
final class MultilineField: NSView {
    private let scroll = NSScrollView()
    private let textView: NSTextView
    private var responderWatch: NSKeyValueObservation?

    var text: String {
        get { textView.string }
        set { textView.string = newValue; needsLayout = true }
    }

    init(text: String) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        textView.string = text
        textView.font = Tokens.Font.body()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The ring follows the keyboard, as on a one-line field.
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
