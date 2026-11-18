import AppKit

/// Site Controls can change the winning rule without leaving the page.
enum SiteRouteSheet {
    @discardableResult
    static func edit(_ existing: SiteRoutes.Route, in host: NSView) -> FormSheet {
        let library = Library.shared
        let spaces = library.spaces
        let field = FilledField(placeholder: "github.com/org1")
        field.stringValue = existing.site
        let match = DropdownButton()
        let modes = SiteRoutes.Match.allCases
        match.options = modes.map { DropdownButton.Option(title: $0.title) }
        match.selectedIndex = modes.firstIndex(of: existing.match) ?? 0
        match.setAccessibilityHelp(SiteRoutes.Match.overview)
        existing.match.setInputHelp(on: field)
        let destination = DropdownButton()
        destination.options = spaces.map { DropdownButton.Option(title: $0.name) }
        let current = existing.spaceID
        destination.selectedIndex = spaces.firstIndex { $0.id == current } ?? 0

        let matchControls = NSStackView(views: [match, matchHelpButton()])
        matchControls.spacing = Tokens.Space.x2
        let preview = NSTextField.dialogText("", font: Tokens.Font.detail())
        func draft() -> SiteRoutes.Route? {
            let mode = modes[match.selectedIndex]
            guard let value = SiteRoutes.entry(from: field.stringValue, match: mode),
                  spaces.indices.contains(destination.selectedIndex) else { return nil }
            return .init(id: existing.id, match: mode, site: value, spaceID: spaces[destination.selectedIndex].id, isEnabled: existing.isEnabled)
        }
        weak var presentedSheet: FormSheet?
        let sheet = FormSheet.show(in: host,
            title: String(localized: "Edit Space Rule", comment: "Existing space rule sheet title."),
            symbol: "square.stack",
            rows: [.init(label: String(localized: "Address", comment: "Space rule address field."), view: field),
                   .init(label: String(localized: "Match", comment: "Space rule match type."), view: matchControls),
                   .init(label: String(localized: "Open in", comment: "Destination space for a rule."), view: destination),
                   .init(label: nil, view: preview, height: 0)],
            confirmTitle: String(localized: "Save", comment: "Save a space rule."),
            destructive: false, canConfirm: {
                let previous = preview.stringValue
                defer {
                    if previous != preview.stringValue { presentedSheet?.needsLayout = true }
                }
                guard let rule = draft() else {
                    field.isInvalid = true
                    preview.stringValue = modes[match.selectedIndex].inputHint
                    return false
                }
                field.isInvalid = false
                preview.stringValue = rule.scopeDescription
                var rules = library.siteRoutes
                if let i = rules.firstIndex(where: { $0.id == rule.id }) {
                    rules[i] = rule
                    if let warning = SiteRoutes.coverage(in: rules)[i].warning { preview.stringValue += "\n" + warning }
                }
                return true
            }) { confirmed in
                if confirmed, let rule = draft() { library.saveRoute(rule) }
            }
        presentedSheet = sheet
        match.onSelect = { [weak sheet] index in
            modes[index].setInputHelp(on: field)
            sheet?.revalidate()
            sheet?.needsLayout = true
        }
        destination.onSelect = { [weak sheet] _ in sheet?.revalidate() }
        return sheet
    }

    static func matchHelpButton() -> IconButton {
        let help = IconButton(symbol: "info.circle", size: .compact, toolTip: SiteRoutes.Match.overview)
        help.setAccessibilityLabel(String(localized: "About Match Types", comment: "Button opening space rule help."))
        help.setAccessibilityHelp(SiteRoutes.Match.overview)
        let helpPopover = NSPopover()
        helpPopover.behavior = .transient
        help.onClick = { [weak help] _ in
            guard let help else { return }
            if helpPopover.isShown { helpPopover.close(); return }
            let label = matchHelpLabel()
            let width: CGFloat = 300
            let padding = Tokens.Space.x4
            let height = label.wrappedHeight(width)
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * padding, height: height + 2 * padding))
            label.frame = controller.view.bounds.insetBy(dx: padding, dy: padding)
            controller.view.addSubview(label)
            helpPopover.contentViewController = controller
            helpPopover.show(relativeTo: help.bounds, of: help, preferredEdge: .maxY)
        }
        return help
    }

    private static func matchHelpLabel() -> NSTextField {
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
        let label = NSTextField.dialogText("")
        label.attributedStringValue = text
        return label
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
    var warning: String? {
        if let blockedBy {
            return String(localized: "Rule \(blockedBy + 1) covers every URL this rule matches.", comment: "Below a space rule made unreachable by an earlier rule.")
        }
        guard let first = blocks.first else { return nil }
        if blocks.count == 1 {
            return String(localized: "Blocks rule \(first + 1).", comment: "Below a space rule that makes one later rule unreachable.")
        }
        let numbers = Words.list(blocks.map { ($0 + 1).formatted(.number.locale(Words.locale)) })
        return String(localized: "Blocks rules \(numbers).", comment: "Below a space rule that makes several later rules unreachable. The argument lists their positions.")
    }
}

extension SiteRoutes.Match {
    fileprivate var example: String {
        switch self {
        case .host: String(localized: "Every page on github.com itself.", comment: "Exact host example in the match types popover.")
        case .path: String(localized: "The page at github.com/org1 and pages beneath it, such as github.com/org1/repo.", comment: "Path example in the match types popover.")
        case .domain: String(localized: "Pages on github.com and its subdomains, such as gist.github.com.", comment: "Domain example in the match types popover.")
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
