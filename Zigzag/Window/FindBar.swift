import AppKit
import WebKit

/// A floating text field we draw ourselves: no bezel, our font, our colors.
final class PlainTextField: NSTextField {
    var onCancel: (() -> Void)?
    var onCommand: ((Selector) -> Bool)?
    /// Room at the sides for a selection and the first letter to draw whole (the address). Zero for fields lined up
    /// with a label they replace, like renaming.
    var textInset: CGFloat = 0
    /// Text centered top to bottom in a field taller than its line (the address). Off, the text sits where AppKit
    /// puts it, as every other field always has.
    var centersText = false

    init(font: NSFont, placeholder: String) {
        super.init(frame: .zero)
        // A new cell starts out read-only; a text field you type in needs it editable again.
        cell = PaddedTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
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

/// Draws and edits the text a little in from the sides, and centered in its height if the field asks, so a selection
/// that runs to the edge, or the first letter of a long address, isn't cut off.
private final class PaddedTextFieldCell: NSTextFieldCell {
    private func textRect(in rect: NSRect) -> NSRect {
        let field = controlView as? PlainTextField
        var r = rect.insetBy(dx: field?.textInset ?? 0, dy: 0)
        guard field?.centersText == true else { return r }
        let height = ceil(cellSize(forBounds: r).height)
        if height < r.height { r.origin.y += floor((r.height - height) / 2); r.size.height = height }
        return r
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { super.drawingRect(forBounds: textRect(in: rect)) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: textRect(in: rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: textRect(in: rect), in: controlView, editor: editor, delegate: delegate, start: start, length: length)
    }

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

    /// The page the last search ran in, so its highlight goes when you move to the other pane.
    private weak var searched: WKWebView?
    /// The PDF the last search ran in, for the same reason.
    private weak var searchedPDF: PDFViewerView?
    /// A PDF is searched a moment after you stop typing: a long one takes a while, and each letter shouldn't wait.
    private var pdfSearch: DispatchWorkItem?

    /// Over the page it searches: in split view, the pane you're working in.
    private var frame: NSRect {
        guard let window else { return .zero }
        let card = window.focusedPaneFrame
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

    /// Another pane (or tab) came to the front: the bar moves over it and searches there instead.
    func pageChanged() {
        guard isVisible else { return }
        let current = window?.selectedWebView
        guard current !== searched else { return }
        clearHighlights()
        let target = frame
        Tokens.Motion.animate(Tokens.Motion.snappy) { [panel] in panel.animator().frame = target }
        if query.isEmpty { countLabel.stringValue = ""; layoutPanel() } else { search(backwards: false, fromStart: true) }
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
        // A PDF is searched in its own viewer, which knows its pages and counts the matches itself.
        if let pdf = window?.selectedTab?.pdfViewer {
            searched = window?.selectedWebView
            searchedPDF = pdf
            pdfSearch?.cancel()
            let query = query
            let work = DispatchWorkItem { [weak self, weak pdf] in
                guard let self, let pdf else { return }
                let found = pdf.find(query, backwards: backwards, fromStart: fromStart)
                self.countLabel.stringValue = query.isEmpty ? "" : found.count == 0 ? "No matches" : found.count == 1 ? "1 match" : "\(found.place) of \(found.count)"
                self.countLabel.textColor = found.count > 0 ? Tokens.Color.textSecondary : Tokens.Color.textTertiary
                self.layoutPanel()
            }
            pdfSearch = work
            // Typing waits; Return and the arrows move at once.
            if fromStart { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work) } else { work.perform() }
            return
        }
        guard let webView = window?.selectedWebView, !query.isEmpty else { return }
        searched = webView
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
        // Counted over the same text twice, the whole page and the part before the match WebKit just selected, so
        // "3 of 12" is where you are in the page.
        let script = """
        (() => { const q = `\(escaped)`.toLowerCase(); if (!q || !document.body) return [0, 0];
          const count = (t) => { t = t.toLowerCase(); let n = 0, i = 0; while ((i = t.indexOf(q, i)) !== -1) { n++; i += q.length; } return n; };
          const all = document.createRange(); all.selectNodeContents(document.body);
          const total = count(all.toString());
          const sel = window.getSelection(); if (!sel.rangeCount) return [0, total];
          const before = document.createRange(); before.setStart(document.body, 0);
          const r = sel.getRangeAt(0); before.setEnd(r.startContainer, r.startOffset);
          return [count(before.toString()) + 1, total]; })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pair = (result as? [Int]) ?? [0, 0]
                let count = max(pair.count > 1 ? pair[1] : 0, 1), place = pair.first ?? 0
                self.countLabel.stringValue = !found ? "No matches" : count == 1 ? "1 match"
                    : (1...count).contains(place) ? "\(place) of \(count)" : "\(count) matches"
                self.countLabel.textColor = found ? Tokens.Color.textSecondary : Tokens.Color.textTertiary
                self.layoutPanel()
            }
        }
    }

    private func clearHighlights() {
        pdfSearch?.cancel()
        (searchedPDF ?? window?.selectedTab?.pdfViewer)?.clearFind()
        searchedPDF = nil
        if let webView = searched ?? window?.selectedWebView {
            webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
            // WebKit draws its own highlight over the match, apart from the selection; it stays until told to go.
            if webView.responds(to: Self.hideFindUI) { webView.perform(Self.hideFindUI) }
        }
        searched = nil
    }

    private static let hideFindUI = NSSelectorFromString("_hideFindUI")
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

    /// Empties the panel so it can show something else in the same place.
    func removeContent() { surface.subviews.forEach { $0.removeFromSuperview() } }

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
        matchCorners()
    }

    /// A button tucked into one of the panel's rounded corners follows that corner: its own radius is the panel's
    /// less the gap between them, so the two curves run side by side instead of a square-ish fill in a round shape.
    private func matchCorners() {
        for view in surface.subviews {
            guard view is IconButton || view is TextButton, !view.isHidden, let layer = view.layer else { continue }
            let f = view.frame
            let dx = min(f.minX, bounds.width - f.maxX), dy = min(f.minY, bounds.height - f.maxY)
            guard dx >= 0, dy >= 0, dx < radius, dy < radius else { continue }
            let fitted = min(max(radius - max(dx, dy), Tokens.Radius.control), min(f.width, f.height) / 2)
            if let button = view as? IconButton { button.radius = fitted } else { layer.cornerRadius = fitted }
            layer.cornerCurve = .continuous
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// A color mixed into the panel's surface, like the space's own, so the panel belongs to it. Nil is plain.
    var surfaceTint: NSColor? { didSet { refreshColors() } }
    /// How much of the tint goes in: more makes the panel read as part of what it's tinted from.
    var tintStrength: CGFloat? { didSet { refreshColors() } }
    /// Off for a panel that stands in for something in place (the address being edited): no shadow, no lift.
    var isElevated = true { didSet { refreshColors() } }
    /// The edge, if not the usual hairline (an edited field's soft accent outline).
    var edgeColor: NSColor? { didSet { refreshColors() } }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            if let tint = surfaceTint {
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    let base = Tokens.Color.panelBackground.usingColorSpace(.sRGB) ?? Tokens.Color.panelBackground
                    let mixed = base.blended(withFraction: tintStrength ?? (effectiveAppearance.isDark ? 0.55 : 0.6), of: tint.usingColorSpace(.sRGB) ?? tint) ?? base
                    surface.color = mixed
                }
            } else {
                surface.color = Tokens.Color.panelBackground
            }
            surface.layer?.borderColor = cgColor(edgeColor ?? Tokens.Color.panelEdge)
            surface.layer?.borderWidth = edgeColor == nil ? Tokens.Metric.hairline : 1.5
            layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
            layer?.shadowOpacity = isElevated ? 1 : 0
            layer?.shadowRadius = Tokens.Shadow.panelRadius / 2
            layer?.shadowOffset = Tokens.Shadow.panelOffset(flipped: isFlipped)
        }
    }

    /// The one way a panel arrives: it fades in while settling down 4pt from its top edge, as if dropping from
    /// whatever opened it. Opacity and movement run together on the layer, so they never drift apart.
    /// How a panel arrives. Anything attached to what opened it (the address dropdown) just appears; small panels
    /// from a button fade; free-floating notices drop in slightly.
    /// `.fade` (and `.pop`) grow out of `growsFrom`: a short, critically damped spring with no overshoot, so a panel opening from a button looks like it
    /// came out of that button. ⌘T's bar alone appears at once, being the thing you do most.
    /// `burst`: grows out of its corner from a little further than `pop`, for a panel that opens because something
    /// just landed in what it grows from (a download hitting its button). No overshoot.
    enum Arrival { case drop, fade, instant, zoom, pop, burst }

    /// Where a panel grows from, in its own bounds from the top-left: (0, 0) its top-left corner, (0.5, 0) its top
    /// middle. Set it to the side nearest what opened it.
    var growsFrom = CGPoint(x: 0.5, y: 0)

    /// Scaled by `k` around `growsFrom`, in layer coordinates (a view layer scales from its own corner).
    private func scaled(_ k: CGFloat) -> CATransform3D {
        let w = bounds.width, h = bounds.height
        let px = growsFrom.x * w
        let py = (layer?.isGeometryFlipped == true || isFlipped) ? growsFrom.y * h : (1 - growsFrom.y) * h
        return CATransform3DConcat(CATransform3DMakeScale(k, k, 1), CATransform3DMakeTranslation(px * (1 - k), py * (1 - k), 0))
    }

    func present(always: Bool = false, arrival: Arrival = .pop) {
        layoutSubtreeIfNeeded()
        layer?.removeAnimation(forKey: "dismiss")
        alphaValue = 1
        dismissing = false
        // Shown from the keyboard too: a panel appearing out of nowhere reads as a glitch, and this takes 0.2s.
        guard let layer, arrival != .instant else { return }
        if arrival == .burst, !Tokens.Motion.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let grow = CASpringAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: scaled(0.88))
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            grow.mass = 1
            grow.stiffness = 420
            grow.damping = 2 * sqrt(420)   // critically damped: it settles, it doesn't bounce
            grow.initialVelocity = 0
            grow.duration = grow.settlingDuration
            layer.add(fade, forKey: "present")
            layer.add(grow, forKey: "present.grow")
            return
        }
        if (arrival == .fade || arrival == .pop || arrival == .burst), !Tokens.Motion.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.16
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let grow = CASpringAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: scaled(0.97))
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            grow.mass = 1
            grow.stiffness = 520
            grow.damping = 48
            grow.initialVelocity = 0
            grow.duration = grow.settlingDuration
            layer.add(fade, forKey: "present")
            layer.add(grow, forKey: "present.grow")
            return
        }
        // With Reduce Motion on, panels only fade in; nothing moves.
        if arrival == .fade || arrival == .pop || arrival == .burst || Tokens.Motion.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.1
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "present")
            return
        }
        let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        if arrival == .zoom {
            // Grows a touch from its own middle, as Spotlight does: layers scale from their corner, so it's
            // shifted by half the shrink to stay centered.
            let k: CGFloat = 0.96, size = bounds.size
            let small = CATransform3DConcat(CATransform3DMakeScale(k, k, 1),
                                            CATransform3DMakeTranslation(size.width * (1 - k) / 2, size.height * (1 - k) / 2, 0))
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: small)
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            let group = CAAnimationGroup()
            group.animations = [fade, grow]
            group.duration = 0.2
            group.timingFunction = curve
            layer.add(group, forKey: "present")
            return
        }
        let drop = CABasicAnimation(keyPath: "transform.translation.y")
        drop.fromValue = isFlippedInSuperview ? -4 : 4
        drop.toValue = 0
        drop.duration = 0.2
        let group = CAAnimationGroup()
        group.animations = [fade, drop]
        group.duration = 0.2
        group.timingFunction = curve
        layer.add(group, forKey: "present")
    }

    private var isFlippedInSuperview: Bool { superview?.isFlipped ?? true }

    private var dismissing = false

    /// The one way a panel leaves: a quick fade as it eases a touch smaller, back toward where it came from.
    func dismiss(always: Bool = false, instantly: Bool = false, completion: (() -> Void)? = nil) {
        guard let layer, !instantly else { removeFromSuperview(); completion?(); return }
        layer.removeAnimation(forKey: "present")
        layer.removeAnimation(forKey: "present.grow")
        dismissing = true
        if !Tokens.Motion.reduceMotion {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: scaled(0.98))
            shrink.duration = 0.14
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "dismiss.shrink")
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // Shown again while fading (a repeat toast): it stays.
            guard let self, self.layer?.opacity == 0 else { completion?(); return }
            self.removeFromSuperview()
            self.layer?.removeAnimation(forKey: "dismiss.shrink")
            self.layer?.opacity = 1
            completion?()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(fade, forKey: "dismiss")
        layer.opacity = 0
        CATransaction.commit()
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
        actionButton.showsFillAtRest = true
        actionButton.isHidden = true
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    static let height = Tokens.Space.x8 + Tokens.Space.x1

    var fittingWidth: CGFloat {
        Tokens.Space.x3 + (icon.image == nil ? 0 : Tokens.Metric.favicon + Tokens.Space.x2) + label.textWidth
            + (actionButton.isHidden ? Tokens.Space.x3 : Tokens.Space.x3 + actionButton.fittingWidth + Tokens.Space.x2)
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
            // Inset evenly from the toast's edge, top, bottom and right alike.
            let h = Tokens.Space.x7Height
            actionButton.frame = NSRect(x: bounds.width - (bounds.height - h) / 2 - actionWidth, y: (bounds.height - h) / 2, width: actionWidth, height: h)
        }
        let textWidth = bounds.width - chromeWidth
        let h = label.usesSingleLineMode ? label.lineHeight : bounds.height - Tokens.Space.x4
        label.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: textWidth, height: h)
    }
}

enum Toast {
    /// Each window's toast and its timer, so a toast in one window never cancels another window's.
    private final class Showing {
        weak var toast: ToastView?
        var hideWork: DispatchWorkItem?
    }
    private static var showing: [ObjectIdentifier: Showing] = [:]

    private static func state(for host: NSView) -> Showing {
        showing = showing.filter { $0.value.toast?.superview != nil }
        if let state = showing[ObjectIdentifier(host)] { return state }
        let state = Showing()
        showing[ObjectIdentifier(host)] = state
        return state
    }

    /// Takes down the toast showing in this window, if any.
    static func hide(in controller: BrowserWindowController) {
        let state = state(for: controller.root.overlay)
        guard let toast = state.toast, toast.superview === controller.root.overlay else { return }
        state.hideWork?.cancel()
        toast.dismiss(always: true)
        state.toast = nil
    }

    static func show(_ text: String, symbol: String? = nil, action: (title: String, run: () -> Void)? = nil,
                     duration: TimeInterval = 1.3, in controller: BrowserWindowController) {
        show(text, symbol: symbol, action: action, duration: duration, over: controller.root.overlay, area: controller.root.cardFrame)
    }

    /// Shows a toast at the top center of `area` in any flipped host view (the Passwords window uses it too).
    static func show(_ text: String, symbol: String? = nil, action: (title: String, run: () -> Void)? = nil,
                     duration: TimeInterval = 1.3, over host: NSView, area: NSRect) {
        let state = state(for: host)
        let toast: ToastView
        let isNew: Bool
        if let existing = state.toast, existing.superview === host {
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
            // Springs down out of the top of the page, as a notice does, and eases back up when it goes.
            toast.growsFrom = CGPoint(x: 0.5, y: 0)
            toast.present(always: true, arrival: .pop)
        } else {
            // A repeat (zoom 90% → 80%) gives a small pulse so the change registers.
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1, 1.04, 1]
            pulse.duration = Tokens.Motion.standard
            toast.layer?.add(pulse, forKey: "pulse")
        }
        state.toast = toast
        state.hideWork?.cancel()
        // Toasts with an action wait for the pointer to leave before going.
        let work = DispatchWorkItem { [weak toast] in
            MainActor.assumeIsolated {
                guard let toast, toast.superview != nil else { return }
                if action != nil, toast.bounds.contains(toast.convert(toast.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) {
                    state.hideWork = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak toast] in toast?.dismiss(always: true) }
                    return
                }
                toast.dismiss(always: true)
            }
        }
        state.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
