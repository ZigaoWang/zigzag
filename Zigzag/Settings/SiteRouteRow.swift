import AppKit

/// A rule stays in its row while it is edited. Only a valid, committed address changes where links open.
final class SiteRouteRow: InteractiveView, SettingsSizedRow, SettingsSearchable, SettingsDragRow, NSTextFieldDelegate {
    let grip = IconButton(symbol: "line.3.horizontal", size: .compact)
    let address = FilledField(placeholder: "github.com")
    let match = DropdownButton()
    let destination = DropdownButton()
    let enabled = Toggle()
    private let enabledLabel = caption(String(localized: "Enabled", comment: "Label above a space rule's switch."))
    private let matchLabel = caption(String(localized: "Match", comment: "Space rule match type."))
    private let addressLabel = caption("")
    private let destinationLabel = caption(String(localized: "Open in", comment: "Destination space for a rule."))

    private static func caption(_ title: String) -> Label {
        let label = Label(title, font: Tokens.Font.label(), color: Tokens.Color.textSecondary)
        // The control speaks its label when focused.
        label.setAccessibilityElement(false)
        return label
    }

    private let position = Label("", font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var rule: SiteRoutes.Route
    private var spaces: [UUID] = []
    private var warning: String?
    private var isNew = false
    var onSave: ((SiteRoutes.Route) -> Void)?
    var onDiscard: (() -> Void)?
    var onDraftChange: (() -> Void)?
    var onHeightChange: (() -> Void)?
    var isLifted = false {
        didSet { layer?.backgroundColor = isLifted ? cgColor(Tokens.Color.surfaceGroup) : nil }
    }
    var searchText: String {
        let i = destination.selectedIndex
        let name = destination.options.indices.contains(i) ? destination.options[i].title : ""
        return [rule.site, rule.match.title, name].joined(separator: " ")
    }

    override var isFlipped: Bool { true }

    init(_ rule: SiteRoutes.Route) {
        self.rule = rule
        super.init(frame: .zero)
        setAccessibilityRole(.row)
        address.isOutlined = true
        address.stringValue = rule.site
        address.field.delegate = self
        match.options = SiteRoutes.Match.allCases.map { DropdownButton.Option(title: $0.title) }
        match.selectedIndex = SiteRoutes.Match.allCases.firstIndex(of: rule.match) ?? 0
        match.setAccessibilityHelp(SiteRoutes.Match.overview)
        rule.match.setInputHelp(on: address)
        message.font = Tokens.Font.detail()
        message.isSelectable = false
        position.alignment = .right
        position.setAccessibilityElement(false)
        [grip, position, enabledLabel, enabled, matchLabel, match, addressLabel, address, destinationLabel, destination, message].forEach { addSubview($0) }
        grip.onClick = { [weak self] event in
            guard let self else { return }
            onRightClick?(event)?.popUp(positioning: nil, at: NSPoint(x: 0, y: grip.bounds.maxY), in: grip)
        }
        match.onSelect = { [weak self] _ in self?.commitAddress(); self?.onDraftChange?() }
        destination.onSelect = { [weak self] i in
            guard let self, spaces.indices.contains(i) else { return }
            var changed = self.rule
            changed.spaceID = spaces[i]
            self.rule = changed
            onSave?(changed)
        }
        enabled.onChange = { [weak self] value in
            guard let self else { return }
            var changed = self.rule
            changed.isEnabled = value
            self.rule = changed
            onSave?(changed)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh(_ saved: SiteRoutes.Route, spaces available: [SpaceInfo], number: Int, isNew: Bool) {
        if saved.site != rule.site || saved.match != rule.match {
            address.stringValue = saved.site
            match.selectedIndex = SiteRoutes.Match.allCases.firstIndex(of: saved.match) ?? 0
        }
        rule = saved
        self.isNew = isNew
        spaces = available.map(\.id)
        let names = available.map(\.name)
        if destination.options.map(\.title) != names { destination.options = names.map { DropdownButton.Option(title: $0) } }
        destination.selectedIndex = spaces.firstIndex(of: saved.spaceID) ?? 0
        enabled.isOn = saved.isEnabled
        let rowName = String(localized: "Rule \(number)", comment: "A rule's position in the ordered list in Settings.")
        position.stringValue = String(number)
        setAccessibilityLabel(rowName)
        grip.toolTip = String(localized: "Reorder or remove rule \(number)", comment: "Drag handle and menu for a space rule.")
        enabled.setAccessibilityLabel(String(localized: "Turn \(rowName) on or off", comment: "Enable or disable a space rule."))
        match.setAccessibilityLabel(matchLabel.stringValue)
        destination.setAccessibilityLabel(destinationLabel.stringValue)
        validate(notify: false)
    }

    private var mode: SiteRoutes.Match { SiteRoutes.Match.allCases[match.selectedIndex] }

    var ruleForValidation: SiteRoutes.Route {
        guard let value = SiteRoutes.entry(from: address.stringValue, match: mode) else { return rule }
        var draft = rule
        draft.match = mode
        draft.site = value
        return draft
    }

    func setWarning(_ value: String?) {
        guard value != warning else { return }
        warning = value
        validate()
    }

    @discardableResult
    private func validate(notify: Bool = true) -> String? {
        mode.setInputHelp(on: address)
        let title = mode == .path
            ? String(localized: "Host and path", comment: "Label above an address that matches a host and path.")
            : String(localized: "Hostname", comment: "Label above a space rule that takes only a hostname.")
        if addressLabel.stringValue != title {
            addressLabel.stringValue = title
            address.field.setAccessibilityLabel(title)
            needsLayout = true
        }
        let value = SiteRoutes.entry(from: address.stringValue, match: mode)
        let invalid = value == nil && !(isNew && address.stringValue.isEmpty)
        address.isInvalid = invalid
        let note: String
        if invalid {
            note = mode.inputHint
        } else {
            note = warning ?? ""
        }
        message.textColor = invalid ? Tokens.Color.destructive : Tokens.Color.caution
        if message.stringValue != note {
            message.stringValue = note
            message.isHidden = note.isEmpty
            needsLayout = true
            if notify { onHeightChange?() }
        }
        address.field.setAccessibilityHelp(Words.sentences(address.field.toolTip ?? mode.inputHint, invalid ? nil : warning))
        return value
    }

    private func commitAddress() {
        guard let value = validate() else { return }
        var changed = rule
        changed.match = mode
        changed.site = value
        address.stringValue = value
        if changed != rule { onSave?(changed) }
    }

    func controlTextDidChange(_ notification: Notification) {
        validate()
        onDraftChange?()
    }
    func controlTextDidEndEditing(_ notification: Notification) { commitAddress() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if isNew {
                address.stringValue = ""
                textView.string = ""
                onDiscard?()
            } else {
                match.selectedIndex = SiteRoutes.Match.allCases.firstIndex(of: rule.match) ?? 0
                address.stringValue = rule.site
                textView.string = rule.site
                validate()
                onDraftChange?()
            }
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitAddress()
            if !address.isInvalid { window?.makeFirstResponder(nil) }
            return true
        }
        return false
    }

    private let pad = Tokens.Page.groupPad
    private let gap = Tokens.Space.x2
    private var controlsHeight: CGFloat { Tokens.Page.controlHeight }
    private var captionHeight: CGFloat { enabledLabel.lineHeight + Tokens.Space.x1 }
    private var enabledWidth: CGFloat { max(enabled.intrinsicContentSize.width, enabledLabel.inkWidth) }
    private var positionWidth: CGFloat { max(Tokens.Space.x4, position.inkWidth + Label.inset * 2) }
    private var prefixWidth: CGFloat { Tokens.Metric.compactIconButton + positionWidth + enabledWidth + gap * 3 }
    private func stacked(at width: CGFloat) -> Bool {
        width - pad * 2 < prefixWidth + match.naturalWidth + min(destination.naturalWidth, 160) + gap * 2 + 140
    }

    func height(for width: CGFloat) -> CGFloat {
        var height = Tokens.Page.groupRowPad * 2 + captionHeight + controlsHeight
        if stacked(at: width) { height += captionHeight + controlsHeight + gap }
        if !message.stringValue.isEmpty {
            height += gap + ceil(message.sizeThatFits(NSSize(width: max(1, width - pad * 2), height: .greatestFiniteMagnitude)).height)
        }
        return height
    }

    override func layout() {
        super.layout()
        let top = Tokens.Page.groupRowPad + captionHeight, h = controlsHeight
        let end = bounds.width - pad
        let side = Tokens.Metric.compactIconButton
        grip.frame = NSRect(x: pad, y: top + (h - side) / 2, width: side, height: side)
        position.frame = NSRect(x: grip.frame.maxX + gap, y: top + (h - position.lineHeight) / 2, width: positionWidth, height: position.lineHeight)
        let size = enabled.intrinsicContentSize
        enabled.frame = NSRect(x: position.frame.maxX + gap, y: top + (h - size.height) / 2, width: size.width, height: size.height)
        let start = enabled.frame.minX + enabledWidth + gap
        let compact = stacked(at: bounds.width)
        let menusWidth = max(0, end - start - gap)
        let matchWidth = compact ? min(match.naturalWidth, menusWidth * 0.57) : match.naturalWidth
        match.frame = NSRect(x: start, y: top, width: matchWidth, height: h)
        let destinationWidth = min(destination.naturalWidth, compact ? menusWidth - matchWidth : 160)
        destination.frame = NSRect(x: end - destinationWidth, y: top, width: destinationWidth, height: h)
        let fieldStart = compact ? pad : match.frame.maxX + gap
        let fieldEnd = compact ? end : destination.frame.minX - gap
        address.frame = NSRect(x: fieldStart, y: compact ? top + h + gap + captionHeight : top, width: max(1, fieldEnd - fieldStart), height: h)
        message.frame = NSRect(x: pad, y: address.frame.maxY + gap, width: max(1, end - pad), height: max(0, bounds.height - Tokens.Page.groupRowPad - address.frame.maxY - gap))
        func place(_ label: Label, at x: CGFloat, above y: CGFloat, width: CGFloat) {
            label.frame = NSRect(x: x - Label.inset, y: y - captionHeight,
                                 width: width + 2 * Label.inset, height: label.lineHeight)
        }
        place(enabledLabel, at: enabled.frame.minX, above: top, width: enabledWidth)
        place(matchLabel, at: match.frame.minX, above: match.frame.minY, width: match.frame.width)
        place(addressLabel, at: address.frame.minX, above: address.frame.minY, width: address.frame.width)
        place(destinationLabel, at: destination.frame.minX, above: destination.frame.minY, width: destination.frame.width)
    }
}
