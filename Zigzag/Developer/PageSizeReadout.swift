import AppKit

/// A side of a page's size typed into the size beside Page Size (#141): what counts as one, and the steps the arrow
/// keys take.
enum PageSizeInput {
    /// The side in what's typed: a number, "px" after it or not, rounded to a whole point and kept within
    /// `PageSizes.limits`. Nil when there's no number in it.
    static func side(from text: String) -> Int? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if typed.hasSuffix("px") { typed = String(typed.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        guard !typed.isEmpty, let value = Double(typed), value.isFinite else { return nil }
        return clamped(Int(value.rounded()))
    }

    static func clamped(_ side: Int) -> Int { min(max(side, PageSizes.limits.lowerBound), PageSizes.limits.upperBound) }

    /// ↑ and ↓ step a side by a point, by ten with ⇧, as a stylesheet's editor does.
    static func stepped(_ side: Int, up: Bool, shift: Bool) -> Int { clamped(side + (shift ? 10 : 1) * (up ? 1 : -1)) }

    /// The size with one side typed, the other as it was.
    static func size(_ size: CGSize, width: Int? = nil, height: Int? = nil) -> CGSize {
        CGSize(width: CGFloat(width ?? Int(size.width)), height: CGFloat(height ?? Int(size.height)))
    }
}

/// The page's size beside Page Size above the page, while it has one (#141), as Chrome's device toolbar has it: the
/// listed size's name when it's one ("iPhone 16"), then its width and height, each a field you click to type into
/// (Return sets it, Esc leaves it, ↑ and ↓ step it, Tab goes from the width to the height), and how large it's shown
/// when that's smaller ("at 86%"). Anywhere else on it opens Page Size's menu. Under the pointer it has the fill the
/// bar's buttons have.
final class PageSizeReadout: InteractiveView, NSTextFieldDelegate {
    /// A size typed or stepped to.
    var onSize: ((CGSize) -> Void)?
    /// Pressed off the fields: Page Size's menu, from here.
    var onMenu: (() -> Void)?

    private let nameLabel = Label("", font: Tokens.Font.figures(Tokens.TypeSize.label), color: Tokens.Color.textSecondary)
    private let widthField = PageSideField()
    private let heightField = PageSideField()
    private let times = Label("×", font: Tokens.Font.figures(Tokens.TypeSize.label), color: Tokens.Color.textTertiary)
    private let scaleLabel = Label("", font: Tokens.Font.figures(Tokens.TypeSize.label), color: Tokens.Color.textTertiary)
    private(set) var size: CGSize?
    /// Whether the size's name shows: it gives way first where the bar is short of room.
    var showsName = true { didSet { if showsName != oldValue { needsLayout = true } } }
    private var leaving = false

    /// The bar is the top of the page's card, in the page's color: the neutral fills, as its buttons take.
    var isOnPage = false { didSet { if isOnPage != oldValue { stateDidChange(animated: false); [widthField, heightField].forEach { $0.isOnPage = isOnPage } } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.small + 1
        layer?.cornerCurve = .continuous
        for field in [widthField, heightField] {
            field.delegate = self
            addSubview(field)
        }
        widthField.setAccessibilityLabel(String(localized: "Page width", comment: "VoiceOver name of the field beside Page Size above the page that holds the page's width in points; type into it to change it."))
        heightField.setAccessibilityLabel(String(localized: "Page height", comment: "VoiceOver name of the field beside Page Size above the page that holds the page's height in points; type into it to change it."))
        widthField.nextKeyView = heightField
        [nameLabel, times, scaleLabel].forEach { $0.setAccessibilityElement(false); addSubview($0) }
        onClick = { [weak self] _ in self?.onMenu?() }
        toolTip = DeveloperTool.Group.size.title
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = isPressed ? (isOnPage ? Tokens.Color.pressedFill : Tokens.Chrome.pressed)
            : isHovered || isSelected ? (isOnPage ? Tokens.Color.hoverFill : Tokens.Chrome.hover) : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
    }

    /// How large the page is shown when that's smaller than its size: "at 86%"; nil at its size.
    static func scaleText(_ scale: CGFloat) -> String? {
        guard scale < 0.995 else { return nil }
        let percent = Int((scale * 100).rounded())
        return String(localized: "at \(percent)%", comment: "After the page's width and height above the page, while a page larger than the window is shown smaller to fit: how large it's shown, like “at 72%”.")
    }

    /// Shows `size` (nil: none, and the readout is hidden by its bar), named if it's a listed one. A field you're
    /// typing in keeps what you typed.
    func show(size: CGSize?, name: String?, scale: CGFloat) {
        self.size = size
        nameLabel.stringValue = name ?? ""
        if let size {
            if !widthField.isEditing { widthField.stringValue = String(Int(size.width)) }
            if !heightField.isEditing { heightField.stringValue = String(Int(size.height)) }
        }
        scaleLabel.stringValue = Self.scaleText(scale) ?? ""
        setAccessibilityElement(false)
        needsLayout = true
    }

    private static let pad = Tokens.Space.x2
    private static let gap = Tokens.Space.x1

    private var fieldWidth: CGFloat {
        // Room for four figures whatever is shown, so typing never moves what follows.
        ceil(("0000" as NSString).size(withAttributes: [.font: Tokens.Font.figures(Tokens.TypeSize.label)]).width) + PageSideField.pad * 2
    }

    /// Its width with or without the size's name.
    func width(withName: Bool) -> CGFloat {
        guard size != nil else { return 0 }
        var w = Self.pad * 2 + fieldWidth * 2 + times.inkWidth + Self.gap * 2
        if withName, !nameLabel.stringValue.isEmpty { w += nameLabel.inkWidth + Tokens.Space.x2 }
        if !scaleLabel.stringValue.isEmpty { w += scaleLabel.inkWidth + Tokens.Space.x2 }
        return ceil(w)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        func place(_ label: Label, at x: CGFloat) -> CGFloat {
            let height = label.lineHeight
            label.frame = NSRect(x: x - Label.inset, y: floor((h - height) / 2), width: label.inkWidth + Label.inset * 2, height: height)
            return x + label.inkWidth
        }
        var x = Self.pad
        let named = showsName && !nameLabel.stringValue.isEmpty
        nameLabel.isHidden = !named
        if named { x = place(nameLabel, at: x) + Tokens.Space.x2 }
        let fieldHeight = min(h, Tokens.Sidebar.rowButton)
        widthField.frame = NSRect(x: x, y: floor((h - fieldHeight) / 2), width: fieldWidth, height: fieldHeight)
        x = widthField.frame.maxX + Self.gap
        x = place(times, at: x) + Self.gap
        heightField.frame = NSRect(x: x, y: widthField.frame.minY, width: fieldWidth, height: fieldHeight)
        x = heightField.frame.maxX
        scaleLabel.isHidden = scaleLabel.stringValue.isEmpty
        if !scaleLabel.isHidden { _ = place(scaleLabel, at: x + Tokens.Space.x2) }
    }

    // MARK: Typing

    private func side(of field: NSTextField) -> Int? { PageSizeInput.side(from: field.stringValue) }

    /// Sets the size from what's in `field`; nothing that's a number puts back the size it has.
    private func apply(_ field: NSTextField) {
        guard let size else { return }
        guard let side = side(of: field) else { field.stringValue = String(Int(field === widthField ? size.width : size.height)); return }
        field.stringValue = String(side)
        let next = field === widthField ? PageSizeInput.size(size, width: side) : PageSizeInput.size(size, height: side)
        if next != size { onSize?(next) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? NSTextField else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            apply(field)
            leave()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            leaving = true
            if let size { field.stringValue = String(Int(field === widthField ? size.width : size.height)) }
            leave()
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
             #selector(NSResponder.moveUpAndModifySelection(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)):
            guard let size else { return true }
            let up = selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveUpAndModifySelection(_:))
            let shift = selector == #selector(NSResponder.moveUpAndModifySelection(_:)) || selector == #selector(NSResponder.moveDownAndModifySelection(_:))
            let now = side(of: field) ?? Int(field === widthField ? size.width : size.height)
            field.stringValue = String(PageSizeInput.stepped(now, up: up, shift: shift))
            apply(field)
            textView.selectAll(nil)
            return true
        case #selector(NSResponder.insertTab(_:)):
            apply(field)
            if field === widthField { window?.makeFirstResponder(heightField) } else { leave() }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            apply(field)
            if field === heightField { window?.makeFirstResponder(widthField) } else { leave() }
            return true
        default:
            return false
        }
    }

    /// Clicked away: what's typed is set, as Return does.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if leaving { leaving = false } else { apply(field) }
        (field as? PageSideField)?.isEditing = false
    }

    func controlTextDidBeginEditing(_ obj: Notification) { (obj.object as? PageSideField)?.isEditing = true }

    /// Done typing: the page has the keys again.
    private func leave() {
        leaving = true
        window?.makeFirstResponder(nil)
        leaving = false
    }
}

/// One side of the page's size, in figures: a field with no border that shows it's one under the pointer and while
/// you type, and takes the whole number at a click, ready to be typed over.
final class PageSideField: NSTextField {
    static let pad: CGFloat = 3
    var isOnPage = false { didSet { refresh() } }
    var isEditing = false { didSet { if isEditing != oldValue { refresh() } } }
    private var isHovered = false { didSet { if isHovered != oldValue { refresh() } } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        isBezeled = false
        focusRingType = .none
        alignment = .center
        font = Tokens.Font.figures(Tokens.TypeSize.label)
        textColor = Tokens.Color.textPrimary
        usesSingleLineMode = true
        maximumNumberOfLines = 1
        cell?.isScrollable = true
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.small
        layer?.cornerCurve = .continuous
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            isEditing = true
            // The whole number, to type over, as a browser's size fields do.
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
        return became
    }

    private func refresh() {
        let fill: NSColor? = isEditing ? Tokens.Color.fieldFill : isHovered ? (isOnPage ? Tokens.Color.hoverFill : Tokens.Chrome.hover) : nil
        layer?.backgroundColor = fill.map { cgColor($0) }
    }
}
