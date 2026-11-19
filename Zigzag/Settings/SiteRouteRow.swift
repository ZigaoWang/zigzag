import AppKit

/// A click edits the rule. The space menu also works directly from the list.
final class SiteRouteRow: InteractiveView, SettingsSizedRow, SettingsSearchable, NSTextFieldDelegate {
    private let icon = FaviconView()
    private let address = Label("", font: Tokens.Font.row())
    private let detail = Label("", font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
    private let opensIn = Label("", font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let save = PillButton(title: String(localized: "Save", comment: "Save a space rule."), style: .prominent)
    private let cancel = PillButton(title: String(localized: "Cancel", comment: "Discard edits to a space rule."))
    private let enabledLabel = Label(String(localized: "Enabled", comment: "Switch in the space rule editor."), font: Tokens.Font.detail(), color: Tokens.Color.textSecondary)
    private let field = FilledField(placeholder: "github.com")
    private let match = DropdownButton()
    private let enabled = Toggle()
    let destination = DropdownButton()
    private var rule: SiteRoutes.Route
    private var spaces: [UUID] = []
    private var rowName = ""
    private(set) var isEditing = false
    var onSave: ((SiteRoutes.Route) -> Void)?
    var onDraftChange: (() -> Void)?
    var isLifted = false { didSet { stateDidChange(animated: false) } }
    var searchText: String {
        let index = destination.selectedIndex
        let space = destination.options.indices.contains(index) ? destination.options[index].title : ""
        return [rule.site, rule.match.title, space].joined(separator: " ")
    }

    init(_ rule: SiteRoutes.Route) {
        self.rule = rule
        super.init(frame: .zero)
        setAccessibilityRole(.row)
        layer?.cornerRadius = Tokens.Radius.row
        message.font = Tokens.Font.detail()
        message.isSelectable = false
        opensIn.setAccessibilityElement(false)
        destination.setAccessibilityLabel(String(localized: "Open in", comment: "Destination space for a rule."))
        field.isOutlined = true
        field.field.delegate = self
        field.field.setAccessibilityLabel(String(localized: "Address", comment: "Space rule address field."))
        match.options = SiteRoutes.Match.allCases.map { .init(title: $0.title) }
        match.setAccessibilityLabel(String(localized: "Match", comment: "Space rule match type."))
        match.setAccessibilityHelp(SiteRoutes.Match.overview)
        enabledLabel.setAccessibilityElement(false)
        enabled.setAccessibilityLabel(enabledLabel.stringValue)
        [icon, address, detail, field, match, opensIn, destination, enabledLabel, enabled, cancel, save, message].forEach { addSubview($0) }
        onClick = { [weak self] _ in self?.beginEditing() }
        onRightClick = { [weak self] _ in self?.actionsMenu() }
        save.onClick = { [weak self] _ in self?.commitDraft() }
        cancel.onClick = { [weak self] _ in self?.finishEditing() }
        match.onSelect = { [weak self] _ in self?.draftChanged() }
        enabled.onChange = { [weak self] _ in self?.draftChanged() }
        destination.onSelect = { [weak self] index in
            guard let self, spaces.indices.contains(index) else { return }
            if isEditing { draftChanged() } else {
                var updated = self.rule
                updated.spaceID = spaces[index]
                onSave?(updated)
            }
        }
        showControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh(_ saved: SiteRoutes.Route, spaces available: [SpaceInfo], number: Int) {
        let selected = isEditing && spaces.indices.contains(destination.selectedIndex) ? spaces[destination.selectedIndex] : saved.spaceID
        if !isEditing || saved.isEnabled != rule.isEnabled { enabled.isOn = saved.isEnabled }
        rule = saved
        spaces = available.map(\.id)
        let names = available.map(\.name)
        if destination.options.map(\.title) != names { destination.options = names.map { .init(title: $0) } }
        destination.selectedIndex = spaces.firstIndex(of: selected) ?? spaces.firstIndex(of: saved.spaceID) ?? 0
        icon.image = URL(string: "https://" + saved.site).flatMap { SiteIcons.shownIcon(for: $0) }
        address.stringValue = saved.site
        detail.stringValue = saved.isEnabled ? saved.match.rowDetail
            : String(localized: "\(saved.match.rowDetail), Off", comment: "Beside a space rule that's turned off: its scope, like “and subdomains”, then that it's off.")
        opensIn.stringValue = saved.match == .host
            ? String(localized: "opens in", comment: "Inline before the space menu for a single host: example.com (this host only) opens in Work.")
            : String(localized: "open in", comment: "Inline after a domain and its subdomains, or a path and the pages below it: example.com and subdomains open in Work.")
        rowName = String(localized: "Rule \(number)", comment: "A rule's position in the ordered list in Settings.")
        toolTip = saved.scopeDescription
        setAccessibilityLabel(Words.sentences(rowName, Words.sentences(saved.site, detail.stringValue)))
        showControls()
        validateDraft()
    }

    private var mode: SiteRoutes.Match { SiteRoutes.Match.allCases[match.selectedIndex] }

    private var draft: SiteRoutes.Route? {
        guard spaces.indices.contains(destination.selectedIndex) else { return nil }
        return rule.edited(address: field.stringValue, match: mode, spaceID: spaces[destination.selectedIndex], isEnabled: enabled.isOn)
    }

    var ruleForValidation: SiteRoutes.Route { isEditing ? draft ?? rule : rule }

    private func showControls() {
        alphaValue = isEditing || rule.isEnabled ? 1 : Tokens.Opacity.disabled
        [icon, address, detail].forEach { $0.isHidden = isEditing }
        [field, match, enabledLabel, enabled, cancel, save].forEach { $0.isHidden = !isEditing }
        needsLayout = true
    }

    private func actionsMenu() -> NSMenu {
        let library = Library.shared, routes = library.siteRoutes
        let menu = NSMenu()
        let id = rule.id
        guard let saved = routes.first(where: { $0.id == id }) else { return menu }
        menu.addItem(SidebarMenus.Item(String(localized: "Edit", comment: "Edit a space rule in its Settings row.")) { [weak self] in
            self?.beginEditing()
        })
        let title = saved.isEnabled ? String(localized: "Turn Off", comment: "Turn off a space rule from its context menu.")
            : String(localized: "Turn On", comment: "Turn on a space rule from its context menu.")
        menu.addItem(SidebarMenus.Item(title) {
            guard var updated = library.siteRoutes.first(where: { $0.id == id }) else { return }
            updated.isEnabled = !saved.isEnabled
            library.saveRoute(updated)
        })
        if routes.count > 1 { menu.addItem(.separator()) }
        SiteRouteReorderMenu.addMoves(to: menu, for: id, in: routes.map(\.id)) { library.moveRoute(id, before: $0) }
        if let i = SiteRoutes.blocker(for: saved, in: routes) {
            menu.addItem(SidebarMenus.Item(String(localized: "Move Above \(routes[i].site)", comment: "Moves a space rule above the earlier rule that covers it. The placeholder is that rule's address, like github.com.")) {
                library.moveRoute(id, before: routes[i].id)
            })
        }
        menu.addItem(.separator())
        menu.addItem(SidebarMenus.Item(String(localized: "Remove", comment: "Remove a space rule.")) {
            library.removeRoute(id)
        })
        return menu
    }

    private func beginEditing() {
        guard !isEditing else { return }
        field.stringValue = rule.site
        match.selectedIndex = SiteRoutes.Match.allCases.firstIndex(of: rule.match) ?? 0
        isEditing = true
        showControls()
        draftChanged()
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field.field)
    }

    private func finishEditing() {
        isEditing = false
        enabled.isOn = rule.isEnabled
        destination.selectedIndex = spaces.firstIndex(of: rule.spaceID) ?? 0
        showControls()
        draftChanged()
        window?.makeFirstResponder(self)
    }

    private func commitDraft() {
        guard isEditing, let updated = draft else { return }
        rule = updated
        finishEditing()
        onSave?(updated)
    }

    private func draftChanged() {
        validateDraft()
        onDraftChange?()
    }

    private func validateDraft() {
        if isEditing { mode.setInputHelp(on: field) }
        field.isInvalid = isEditing && draft == nil
        save.isEnabled = !field.isInvalid
    }

    func setWarning(_ warning: String?) {
        message.stringValue = field.isInvalid ? mode.inputHint : warning ?? ""
        message.textColor = field.isInvalid ? Tokens.Color.destructive : Tokens.Color.caution
        message.isHidden = message.stringValue.isEmpty
        setAccessibilityHelp(message.stringValue)
        needsLayout = true
    }

    func controlTextDidChange(_ notification: Notification) { draftChanged() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): finishEditing()
        case #selector(NSResponder.insertNewline(_:)): commitDraft()
        default: return false
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEditing, MenuPanel.current == nil, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let focus = window?.firstResponder as? NSView, focus.isDescendant(of: self),
              (focus as? NSTextView)?.hasMarkedText() != true else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 53: finishEditing()
        case 36, 76:
            if focus === cancel { finishEditing() } else { commitDraft() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private let pad = Tokens.Page.groupPad, gap = Tokens.Space.x2
    private var rowHeight: CGFloat { Tokens.Page.groupRowHeight }
    private var textX: CGFloat { pad + Tokens.Metric.favicon + gap }
    private var menuWidth: CGFloat { min(destination.naturalWidth, 160) }
    private var opensInWidth: CGFloat { opensIn.inkWidth + 2 * Label.inset }
    private func stacked(_ width: CGFloat) -> Bool {
        isEditing && width < 2 * pad + 120 + match.naturalWidth + opensInWidth + menuWidth + 3 * gap
    }

    private func controlsHeight(for width: CGFloat) -> CGFloat {
        guard isEditing else { return rowHeight }
        return rowHeight * (stacked(width) ? 3 : 2)
    }

    func height(for width: CGFloat) -> CGFloat {
        let controls = controlsHeight(for: width)
        guard !message.isHidden else { return controls }
        let start = isEditing ? pad : textX
        let size = NSSize(width: max(1, width - start - pad), height: .greatestFiniteMagnitude)
        return controls + ceil(message.sizeThatFits(size).height) + gap
    }

    override func layout() {
        super.layout()
        let h = rowHeight, w = bounds.width
        func rect(_ x: CGFloat, _ width: CGFloat, _ top: CGFloat = 0, _ height: CGFloat = Tokens.Page.controlHeight) -> NSRect {
            NSRect(x: x, y: top + (h - height) / 2, width: max(0, width), height: height)
        }
        let narrow = stacked(w)
        let spaceWidth = min(menuWidth, max(0, w * 0.3))
        destination.frame = rect(w - pad - spaceWidth, spaceWidth)
        opensIn.frame = NSRect(x: destination.frame.minX - gap - opensInWidth, y: opensIn.centeredY(in: h),
                               width: opensInWidth, height: opensIn.lineHeight)
        if isEditing {
            let matchEnd = opensIn.frame.minX - gap
            let matchWidth = min(match.naturalWidth, max(0, matchEnd - pad))
            match.frame = rect(narrow ? pad : matchEnd - matchWidth, matchWidth)
            field.frame = narrow ? rect(pad, w - 2 * pad, h) : rect(pad, match.frame.minX - gap - pad)
            let footer = narrow ? 2 * h : h
            let switchSize = enabled.intrinsicContentSize
            enabled.frame = rect(pad, switchSize.width, footer, switchSize.height)
            enabledLabel.frame = NSRect(x: enabled.frame.maxX + gap, y: footer + enabledLabel.centeredY(in: h),
                                        width: enabledLabel.inkWidth + 2 * Label.inset, height: enabledLabel.lineHeight)
            save.frame = rect(w - pad - save.fittingWidth, save.fittingWidth, footer)
            cancel.frame = rect(save.frame.minX - gap - cancel.fittingWidth, cancel.fittingWidth, footer)
        } else {
            let side = Tokens.Metric.favicon
            icon.frame = rect(pad, side, 0, side)
            let room = max(0, opensIn.frame.minX - gap - textX)
            let nameWidth = min(address.inkWidth + 2 * Label.inset, max(room * 0.6, room - detail.inkWidth - gap - 2 * Label.inset))
            address.frame = NSRect(x: textX - Label.inset, y: address.centeredY(in: h), width: nameWidth, height: address.lineHeight)
            detail.frame = NSRect(x: address.frame.maxX + gap, y: detail.centeredY(in: h), width: max(0, room - nameWidth - gap), height: detail.lineHeight)
        }
        let messageStart = isEditing ? pad : textX, top = controlsHeight(for: w)
        message.frame = NSRect(x: messageStart, y: top, width: max(1, w - messageStart - pad), height: max(0, bounds.height - top - gap))
    }

    override func stateDidChange(animated: Bool) {
        super.stateDidChange(animated: animated)
        layer?.backgroundColor = isLifted ? cgColor(Tokens.Color.surfaceGroup) : (isHovered ? cgColor(Tokens.Color.hoverFill) : nil)
    }
}

extension SiteRoutes.Match {
    fileprivate var rowDetail: String {
        switch self {
        case .host: String(localized: "this host only", comment: "Short scope beside the address of a space rule.")
        case .domain: String(localized: "and subdomains", comment: "Short scope beside the domain of a space rule.")
        case .path: String(localized: "and pages below it", comment: "Short scope beside the path of a space rule.")
        }
    }
}

/// Keyboard alternatives to dragging a routing rule.
@MainActor
enum SiteRouteReorderMenu {
    static func addMoves(to menu: NSMenu, for id: UUID, in order: [UUID], moveBefore: @escaping (UUID?) -> Void) {
        guard let index = order.firstIndex(of: id) else { return }
        if index > 0 {
            menu.addItem(SidebarMenus.Item(String(localized: "Move Up", comment: "Move a row one place up in Settings.")) {
                moveBefore(order[index - 1])
            })
        }
        if index + 1 < order.count {
            menu.addItem(SidebarMenus.Item(String(localized: "Move Down", comment: "Move a row one place down in Settings.")) {
                moveBefore(index + 2 < order.count ? order[index + 2] : nil)
            })
        }
    }
}
