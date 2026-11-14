import AppKit
import UniformTypeIdentifiers

/// The sheet that makes or changes one rule: what it's called, what it catches, and where the address goes. The
/// action kind is chosen before the sheet opens (from Add Rule or a preset), so the fields shown are exactly the ones
/// that action uses. Tokens are listed under the pattern, and every field can use them.
enum DownloadRuleSheet {
    /// Opens the editor for a new rule of `kind`, or for `rule` if one is given.
    static func show(in host: NSView, kind: DownloadRuleAction.Kind, preset: DownloadPreset? = nil, rule existing: DownloadRule? = nil) {
        let source = existing ?? preset?.rule ?? DownloadRule(name: "", action: DownloadRuleAction(kind: kind))
        // A preset's action may differ from the requested kind (the downloader presets are RPC): the action wins.
        let action = existing?.action ?? preset?.rule.action ?? DownloadRuleAction(kind: kind)

        let name = FilledField(placeholder: String(localized: "Name", comment: "Placeholder of the name field in the sheet that makes a download rule."))
        name.stringValue = source.name
        let pattern = FilledField(placeholder: String(localized: "example.com/files/", comment: "Placeholder of the pattern field in the sheet that makes a download rule."))
        pattern.stringValue = source.pattern

        let applies = DropdownButton()
        applies.options = DownloadRule.Applies.allCases.map { DropdownButton.Option(title: $0.title) }
        applies.selectedIndex = DownloadRule.Applies.allCases.firstIndex(of: source.applies) ?? 0
        let match = DropdownButton()
        match.options = DownloadRule.Match.allCases.map { DropdownButton.Option(title: $0.title) }
        match.selectedIndex = DownloadRule.Match.allCases.firstIndex(of: source.match) ?? 1
        let caseSensitive = DropdownButton()
        caseSensitive.options = [DropdownButton.Option(title: String(localized: "Off", comment: "A choice in a download rule: the address's case doesn't matter.")),
                                 DropdownButton.Option(title: String(localized: "On", comment: "A choice in a download rule: the address's case matters."))]
        caseSensitive.selectedIndex = source.isCaseSensitive ? 1 : 0

        // The action's own fields, one set per kind.
        var actionRows: [FormSheet.Row] = []
        var appField: FilledField?
        var urlField: FilledField?
        var scriptField: FilledField?
        var argumentView: MultilineField?
        var endpointField: FilledField?
        var methodField: FilledField?
        var parametersView: MultilineField?
        var secretField: FilledField?
        var stylePicker: DropdownButton?

        func choose(_ panel: NSOpenPanel, into field: FilledField) {
            if panel.runModal() == .OK, let url = panel.url { field.stringValue = url.path }
        }

        switch action.kind {
        case .openApp:
            let field = FilledField(placeholder: String(localized: "Choose an app…", comment: "Placeholder of the app field in a download rule's sheet."))
            field.stringValue = action.appPath
            appField = field
            let button = PillButton(title: String(localized: "Choose…", comment: "Button beside a path in a download rule's sheet: opens the open panel."))
            button.onClick = { _ in
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.treatsFilePackagesAsDirectories = false
                panel.allowedContentTypes = [.application]
                panel.prompt = String(localized: "Choose", comment: "Button of the open panel that picks an app for a download rule.")
                choose(panel, into: field)
            }
            actionRows.append(FormSheet.Row(label: String(localized: "App", comment: "Label of the app field in a download rule's sheet."),
                                            view: stack(field, button)))
        case .openURL:
            let field = FilledField(placeholder: "mpv://{encoded_link}")
            field.stringValue = action.urlTemplate
            urlField = field
            actionRows.append(FormSheet.Row(label: String(localized: "URL", comment: "Label of the URL field in a download rule's sheet."), view: field))
        case .runScript:
            let field = FilledField(placeholder: String(localized: "Choose a script…", comment: "Placeholder of the script field in a download rule's sheet."))
            field.stringValue = action.scriptPath
            scriptField = field
            let button = PillButton(title: String(localized: "Choose…", comment: "Button beside a path in a download rule's sheet: opens the open panel."))
            button.onClick = { _ in
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.treatsFilePackagesAsDirectories = false
                panel.prompt = String(localized: "Choose", comment: "Button of the open panel that picks a script for a download rule.")
                choose(panel, into: field)
            }
            actionRows.append(FormSheet.Row(label: String(localized: "Script", comment: "Label of the script field in a download rule's sheet."),
                                            view: stack(field, button)))
            let args = MultilineField(text: action.arguments.joined(separator: "\n"))
            argumentView = args
            actionRows.append(FormSheet.Row(label: String(localized: "Arguments", comment: "Label of the arguments field in a download rule's sheet: one argument a line."),
                                            view: args, height: 96))
            actionRows.append(.note(String(localized: "One argument a line. Each becomes its own argument, so a URL with &, ; or $() is never run as a shell command. The link, cookies and the rest are also in ZIGZAG_LINK, ZIGZAG_COOKIES and the other environment variables.",
                                           comment: "Under the arguments of a Run Script download rule, explaining argv and environment.")))
        case .jsonRPC:
            let endpoint = FilledField(placeholder: "http://127.0.0.1:6800/jsonrpc")
            endpoint.stringValue = action.rpcEndpoint
            endpointField = endpoint
            actionRows.append(FormSheet.Row(label: String(localized: "Endpoint", comment: "Label of the endpoint field in a JSON-RPC download rule's sheet."), view: endpoint))
            let method = FilledField(placeholder: "aria2.addUri")
            method.stringValue = action.rpcMethod
            methodField = method
            actionRows.append(FormSheet.Row(label: String(localized: "Method", comment: "Label of the method field in a JSON-RPC download rule's sheet."), view: method))
            let style = DropdownButton()
            style.options = DownloadRuleAction.RPCStyle.allCases.map { DropdownButton.Option(title: $0.title) }
            style.selectedIndex = DownloadRuleAction.RPCStyle.allCases.firstIndex(of: action.rpcStyle) ?? 0
            stylePicker = style
            actionRows.append(FormSheet.Row(label: String(localized: "Protocol", comment: "Label of the protocol choice in a JSON-RPC download rule's sheet."), view: style))
            let parameters = MultilineField(text: action.rpcParameters)
            parametersView = parameters
            actionRows.append(FormSheet.Row(label: String(localized: "Parameters", comment: "Label of the parameters field in a JSON-RPC download rule's sheet."),
                                            view: parameters, height: 110))
            let secret = FilledField(placeholder: String(localized: "Token, if the service asks for one", comment: "Placeholder of the token field in a JSON-RPC download rule's sheet. It's kept in the Keychain."), secure: true)
            secret.stringValue = existing.flatMap { HandoffSecrets.secret(for: $0.id) } ?? ""
            secretField = secret
            actionRows.append(FormSheet.Row(label: String(localized: "Token", comment: "Label of the token field in a JSON-RPC download rule's sheet."), view: secret))
            actionRows.append(.note(String(localized: "A JSON array. {link}, {filename}, {cookies} and the rest are filled in, safely quoted. The token is kept in the Keychain.",
                                           comment: "Under the parameters of a JSON-RPC download rule.")))
        }

        var sheetRef: FormSheet?
        let tokens = FormSheet.Row.note(String(localized: "Tokens: {link}, {encoded_link}, {referrer}, {cookies}, {cookie_header}, {filename}, {mime}, {space}.",
                                             comment: "The tokens a download rule's fields may use, listed in its sheet."))
        let matchRows: [FormSheet.Row] = [
            FormSheet.Row(label: String(localized: "Name", comment: "Label of the name field in a download rule's sheet."), view: name),
            FormSheet.Row(label: String(localized: "Applies to", comment: "Label of the choice of what a download rule catches, in its sheet."), view: applies),
            FormSheet.Row(label: String(localized: "Match", comment: "Label of the choice of how a download rule matches an address, in its sheet."), view: match),
            FormSheet.Row(label: String(localized: "Address", comment: "Label of the address pattern in a download rule's sheet."), view: pattern),
            FormSheet.Row(label: String(localized: "Match case", comment: "Label of the case choice in a download rule's sheet."), view: caseSensitive),
        ]
        let rows = matchRows + actionRows + [tokens]

        func ruleFromFields() -> DownloadRule? {
            var action = action
            switch action.kind {
            case .openApp: action.appPath = appField?.stringValue ?? ""
            case .openURL: action.urlTemplate = urlField?.stringValue ?? ""
            case .runScript:
                action.scriptPath = scriptField?.stringValue ?? ""
                action.arguments = (argumentView?.text ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            case .jsonRPC:
                action.rpcEndpoint = endpointField?.stringValue ?? ""
                action.rpcMethod = methodField?.stringValue ?? ""
                action.rpcParameters = parametersView?.text ?? "[]"
                action.rpcStyle = DownloadRuleAction.RPCStyle.allCases[stylePicker?.selectedIndex ?? 0]
            }
            var rule = existing ?? source
            rule.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.applies = DownloadRule.Applies.allCases[applies.selectedIndex]
            rule.match = DownloadRule.Match.allCases[match.selectedIndex]
            rule.pattern = pattern.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.isCaseSensitive = caseSensitive.selectedIndex == 1
            rule.action = action
            return rule
        }

        let valid = {
            guard let rule = ruleFromFields(), !rule.name.isEmpty else { return false }
            guard rule.match == .any || !rule.pattern.isEmpty else { return false }
            guard rule.isValidPattern else { return false }
            return rule.action.isComplete
        }
        for picker in [applies, match, caseSensitive] + [stylePicker].compactMap({ $0 }) {
            picker.onSelect = { _ in sheetRef?.revalidate() }
        }

        let sheet = FormSheet.show(in: host,
                                   title: existing == nil ? String(localized: "Add Download Rule", comment: "Title of the sheet that makes a download rule.")
                                                          : String(localized: "Edit Download Rule", comment: "Title of the sheet that changes a download rule."),
                                   symbol: action.kind.symbol,
                                   message: String(localized: "The first rule that matches an address wins. Rules run from the top of the list.",
                                                   comment: "Under the title of the sheet that makes a download rule."),
                                   rows: rows,
                                   confirmTitle: existing == nil ? String(localized: "Add", comment: "Button of the sheet that makes a download rule.")
                                                                 : String(localized: "Save", comment: "Button of the sheet that changes a download rule."),
                                   canConfirm: valid) { confirmed in
            guard confirmed, let rule = ruleFromFields() else { return }
            if let secret = secretField?.stringValue, action.kind == .jsonRPC { HandoffSecrets.setSecret(secret, for: rule.id) }
            if existing == nil { DownloadRulesStore.shared.add(rule) } else { DownloadRulesStore.shared.update(rule) }
        }
        sheetRef = sheet
    }

    /// A field with a button at its end, both stretched across the form's row.
    private static func stack(_ field: NSView, _ button: NSView) -> NSStackView {
        let stack = NSStackView(views: [field, button])
        stack.orientation = .horizontal
        stack.spacing = Tokens.Space.x2
        stack.distribution = .fill
        stack.alignment = .centerY
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return stack
    }
}

/// A plain multi-line field for a list of arguments or a JSON body, in the sheet's own type.
final class MultilineField: NSView {
    private let scroll = NSScrollView()
    private let textView: NSTextView

    var text: String {
        get { textView.string }
        set { textView.string = newValue }
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
        textView.minSize = NSSize(width: 0, height: 0)
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
        layer?.cornerRadius = Tokens.Radius.control
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = cgColor(Tokens.Color.fieldFill)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 1, dy: 1)
        let used = textView.textContainer.flatMap { textView.layoutManager?.usedRect(for: $0).height } ?? 0
        textView.frame = NSRect(origin: .zero, size: NSSize(width: scroll.contentSize.width,
                                                           height: max(scroll.contentSize.height, ceil(used) + textView.textContainerInset.height * 2)))
    }
}
