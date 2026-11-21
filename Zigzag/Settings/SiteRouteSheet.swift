import AppKit

/// Adds a rule from Settings or edits the winning rule from Site Controls.
enum SiteRouteSheet {
    @discardableResult
    static func edit(_ existing: SiteRoutes.Route, in host: NSView, isNew: Bool = false) -> FormSheet {
        let library = Library.shared
        let spaces = library.spaces
        let field = FilledField(placeholder: "github.com")
        field.stringValue = existing.site
        let enabled = Toggle(isOn: existing.isEnabled)
        let enabledTitle = String(localized: "Enabled", comment: "Switch in the space rule editor.")
        enabled.setAccessibilityLabel(enabledTitle)
        let match = DropdownButton()
        let modes = SiteRoutes.Match.allCases
        match.options = modes.map { DropdownButton.Option(title: $0.title) }
        match.selectedIndex = modes.firstIndex(of: existing.match) ?? 0
        match.setAccessibilityHelp(SiteRoutes.Match.overview)
        existing.match.setInputHelp(on: field)
        let destination = DropdownButton()
        destination.options = spaces.map { DropdownButton.Option(title: $0.name) }
        destination.selectedIndex = spaces.firstIndex { $0.id == existing.spaceID } ?? 0

        // At the row's end, as the sheet's other menus are.
        let matchControls = NSStackView()
        matchControls.setViews([match, matchHelpButton()], in: .trailing)
        matchControls.spacing = Tokens.Space.x2
        let preview = NSTextField.dialogText("", font: Tokens.Font.detail())
        func draft() -> SiteRoutes.Route? {
            guard spaces.indices.contains(destination.selectedIndex) else { return nil }
            return existing.edited(address: field.stringValue, match: modes[match.selectedIndex],
                                   spaceID: spaces[destination.selectedIndex].id, isEnabled: enabled.isOn)
        }
        weak var presentedSheet: FormSheet?
        let sheet = FormSheet.show(in: host,
            title: isNew ? String(localized: "Add Space Rule", comment: "Title of the sheet that creates a space rule.") : String(localized: "Edit Space Rule", comment: "Existing space rule sheet title."),
            symbol: "square.stack",
            rows: [.init(label: String(localized: "Address", comment: "Space rule address field."), view: field),
                   .init(label: String(localized: "Match", comment: "Space rule match type."), view: matchControls),
                   .init(label: String(localized: "Open in", comment: "Destination space for a rule."), view: destination),
                   .init(label: enabledTitle, view: enabled),
                   .init(label: nil, view: preview, height: 0)],
            confirmTitle: String(localized: "Save", comment: "Save a space rule."),
            destructive: false, canConfirm: {
                let previous = preview.stringValue
                defer {
                    if previous != preview.stringValue { presentedSheet?.needsLayout = true }
                }
                guard let rule = draft() else {
                    field.isInvalid = !field.stringValue.isEmpty
                    preview.textColor = field.isInvalid ? Tokens.Color.destructive : Tokens.Color.textSecondary
                    preview.stringValue = modes[match.selectedIndex].inputHint
                    return false
                }
                field.isInvalid = false
                preview.textColor = Tokens.Color.textSecondary
                preview.stringValue = rule.scopeDescription
                var rules = library.siteRoutes
                let index = rules.firstIndex { $0.id == rule.id } ?? rules.count
                if index == rules.count { rules.append(rule) } else { rules[index] = rule }
                if let warning = SiteRoutes.coverage(in: rules)[index].warning(in: rules) { preview.stringValue += "\n" + warning }
                return true
            }) { confirmed in
                if confirmed, let rule = draft(), isNew || library.siteRoutes.contains(where: { $0.id == rule.id }) { library.saveRoute(rule) }
            }
        presentedSheet = sheet
        match.onSelect = { [weak sheet] index in
            modes[index].setInputHelp(on: field)
            sheet?.revalidate()
            sheet?.needsLayout = true
        }
        enabled.onChange = { [weak sheet] _ in sheet?.revalidate() }
        destination.onSelect = { [weak sheet] _ in sheet?.revalidate() }
        return sheet
    }

    static func matchHelpButton() -> IconButton {
        let help = IconButton(symbol: "info.circle", size: .compact, toolTip: SiteRoutes.Match.overview)
        help.setAccessibilityLabel(String(localized: "About Match Types", comment: "Button opening space rule help."))
        help.setAccessibilityHelp(SiteRoutes.Match.overview)
        help.onClick = { [weak help] _ in
            guard let help else { return }
            if let open = MenuPanel.current, open.anchor === help { open.close(); return }
            MenuPanel.show([.note(matchHelpText())], from: help, minWidth: 300)
        }
        return help
    }

    static func matchHelpText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = Tokens.Space.x4
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
        paragraph.paragraphSpacing = Tokens.Space.x2
        paragraph.lineBreakMode = .byWordWrapping

        let text = NSMutableAttributedString()
        for mode in SiteRoutes.Match.allCases {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: "•\t\(mode.title)\u{2028}", attributes: [
                .font: Tokens.Font.body(.semibold), .foregroundColor: Tokens.Color.textPrimary
            ]))
            text.append(NSAttributedString(string: mode.example, attributes: [
                .font: Tokens.Font.body(), .foregroundColor: Tokens.Color.textSecondary
            ]))
        }
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return text
    }
}

extension SiteRoutes.Route {
    var scopeDescription: String {
        switch match {
        case .host: String(localized: "Pages on \(site) only.", comment: "Preview of an exact host rule.")
        case .domain: String(localized: "\(site) and all its subdomains.", comment: "Preview of a domain rule.")
        case .path: String(localized: "\(site) and pages below it, such as \(site)/repo.", comment: "Preview of a path rule.")
        }
    }
}

extension SiteRoutes.Coverage {
    /// Names the other rules by their address: the list shows no numbers.
    func warning(in rules: [SiteRoutes.Route]) -> String? {
        if let blockedBy, rules.indices.contains(blockedBy) {
            return String(localized: "Never used: \(rules[blockedBy].site) above covers all of it.", comment: "Below a space rule that an earlier rule covers completely. The placeholder is the earlier rule's address, like github.com.")
        }
        let covered = blocks.filter(rules.indices.contains).map { rules[$0].site }
        guard let first = covered.first else { return nil }
        if covered.count == 1 {
            return String(localized: "Covers all of \(first) below, so that rule is never used.", comment: "Below a space rule that covers a later rule completely. The placeholder is the later rule's address, like github.com/org1.")
        }
        return String(localized: "Covers all of \(Words.list(covered)) below, so those rules are never used.", comment: "Below a space rule that covers several later rules completely. The placeholder lists their addresses.")
    }
}

extension SiteRoutes.Match {
    fileprivate var example: String {
        switch self {
        case .host: String(localized: "Matches pages on the exact hostname you enter (for example, github.com).", comment: "Exact host example in the match types popover.")
        case .path: String(localized: "Matches a path and pages below it on the same host (for example, github.com/org1 and github.com/org1/repo).", comment: "Path example in the match types popover.")
        case .domain: String(localized: "Matches pages on a domain and its subdomains (for example, github.com and gist.github.com).", comment: "Domain example in the match types popover.")
        }
    }

    static var overview: String {
        allCases.map { "• \($0.title) — \($0.example)" }.joined(separator: "\n")
    }

    var inputHint: String {
        switch self {
        case .host: String(localized: "Enter one hostname, such as github.com, without a path.", comment: "Example input for a domain-only space rule.")
        case .domain: String(localized: "Enter the parent hostname, such as github.com, without a wildcard or path.", comment: "Example input for a space rule that includes subdomains.")
        case .path: String(localized: "Enter a host and path, such as github.com/org1.", comment: "Example input for a path rule.")
        }
    }

    func setInputHelp(on address: FilledField) {
        let help = Words.sentences(inputHint, String(localized: "The http:// or https:// prefix is optional.", comment: "Space rule address tooltip."))
        if address.field.toolTip != help {
            address.toolTip = help
            address.field.toolTip = help
            address.field.setAccessibilityHelp(help)
        }
    }
}
