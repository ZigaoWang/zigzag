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
        /// The sheet, once it's up, so a value filled in from somewhere other than the keyboard (the open panel's
        /// own answer) can still be followed by the main button.
        var sheetRef: FormSheet?

        let name = FilledField(placeholder: String(localized: "Name", comment: "Placeholder of the name field in the sheet that makes a download rule."))
        name.stringValue = source.name
        let pattern = FilledField(placeholder: String(localized: "example.com/files/", comment: "Placeholder of the pattern field in the sheet that makes a download rule."))
        pattern.stringValue = source.pattern
        /// Whether the pointer is over the main button, which asks for the whole answer to "why can't I add this?".
        var addHovered = false

        let applies = DropdownButton()
        applies.options = DownloadRule.Applies.allCases.map { DropdownButton.Option(title: $0.title) }
        applies.selectedIndex = DownloadRule.Applies.allCases.firstIndex(of: source.applies) ?? 0
        // The Match dropdown offers the address matches: a file-type rule is a per-extension destination, made and
        // edited in the panel under Save downloads to, not here. One that arrives anyway keeps what it had.
        let matchChoices = DownloadRule.Match.allCases.filter { $0 != .fileType }
        let match = DropdownButton()
        match.options = matchChoices.map { DropdownButton.Option(title: $0.title) }
        match.selectedIndex = matchChoices.firstIndex(of: source.match) ?? 1
        let matchCase = Toggle(isOn: source.isCaseSensitive)
        matchCase.setAccessibilityLabel(String(localized: "Match case", comment: "Label of the case choice in a download rule's sheet."))

        // The action's own fields, one set per kind.
        var actionRows: [FormSheet.Row] = []
        var appField: FilledField?
        var urlField: FilledField?
        var scriptField: FilledField?
        var argumentView: MultilineField?
        var endpointField: FilledField?
        /// The line under the parameters saying where the site's cookies would go, kept so one icon and a few words
        /// can turn from a calm state into a warning as the endpoint changes.
        var cookieStatus: StatusLabel?
        /// Which of its two things it is saying, so it's only re-said when that changes.
        var cookiesLeaveThisMac: Bool?
        var methodField: FilledField?
        var parametersView: MultilineField?
        var secretField: FilledField?
        var stylePicker: DropdownButton?

        func choose(_ panel: NSOpenPanel, into field: FilledField) {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            field.stringValue = url.path
            // What's picked can decide whether the rule may be added at all: the main button hears it too.
            sheetRef?.revalidate()
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
            actionRows.append(.note(String(localized: "One argument a line. The link and the cookies arrive in ZIGZAG_LINK and ZIGZAG_COOKIES.",
                                           comment: "Under the arguments of a Run Script download rule: one argument a line, and the names the link and the cookies arrive under.")))
            actionRows.append(FormSheet.Row(label: nil,
                                            view: StatusLabel(String(localized: "Run directly, never through a shell",
                                                                     comment: "Beside an icon, under the arguments of a Run Script download rule: the arguments can never become part of a command line, since the script is run directly."),
                                                              symbol: "checkmark.shield.fill"),
                                            height: Tokens.Metric.controlHeight))
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
            secret.toolTip = String(localized: "Kept in the Keychain", comment: "Tooltip on the token field of a JSON-RPC download rule's sheet.")
            secretField = secret
            actionRows.append(FormSheet.Row(label: String(localized: "Token", comment: "Label of the token field in a JSON-RPC download rule's sheet."), view: secret))
            actionRows.append(.note(String(localized: "A JSON array. Tokens are filled in.",
                                           comment: "Under the parameters of a JSON-RPC download rule.")))
            let status = StatusLabel(String(localized: "Cookies stay on this Mac",
                                            comment: "Beside an icon, under the parameters of a JSON-RPC download rule whose endpoint is on this Mac: the site's cookies would go no further than it."))
            cookieStatus = status
            actionRows.append(FormSheet.Row(label: nil, view: status, height: Tokens.Metric.controlHeight))
        case .saveToFolder, .showInZigzag:
            // A destination is made in the panel under Save downloads to, which is where its folder lives: this
            // sheet is only ever opened for a handoff action.
            break
        }

        let tokens = FormSheet.Row.note(String(localized: "Tokens: {link}, {encoded_link}, {referrer}, {cookies}, {cookie_header}, {filename}, {mime}, {space}.",
                                             comment: "The tokens a download rule's fields may use, listed in its sheet."))
        let matchRows: [FormSheet.Row] = [
            FormSheet.Row(label: String(localized: "Name", comment: "Label of the name field in a download rule's sheet."), view: name),
            FormSheet.Row(label: String(localized: "Applies to", comment: "Label of the choice of what a download rule catches, in its sheet."), view: applies),
            FormSheet.Row(label: String(localized: "Match", comment: "Label of the choice of how a download rule matches an address, in its sheet."), view: match),
            FormSheet.Row(label: String(localized: "Address", comment: "Label of the address pattern in a download rule's sheet."), view: pattern),
            FormSheet.Row(label: String(localized: "Match case", comment: "Label of the case choice in a download rule's sheet."), view: matchCase),
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
            case .saveToFolder, .showInZigzag:
                // A destination never reaches this sheet; should one, its own fields are left as they were.
                break
            }
            var rule = existing ?? source
            rule.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.applies = DownloadRule.Applies.allCases[applies.selectedIndex]
            rule.match = matchChoices.indices.contains(match.selectedIndex) ? matchChoices[match.selectedIndex] : source.match
            rule.pattern = pattern.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.isCaseSensitive = matchCase.isOn
            rule.action = action
            return rule
        }

        /// Where the site's cookies would go, as a state said calmly: an icon and five words that turn into a warning
        /// the moment the endpoint leaves this Mac. No paragraph under it — the endpoint is yours to write, and what
        /// it hands over is worth a glance as you write it, not an essay read once.
        func refreshCookieStatus(_ rule: DownloadRule?) {
            guard let status = cookieStatus else { return }
            let offThisMac = rule?.sendsCookiesOffThisMac ?? false
            guard cookiesLeaveThisMac != offThisMac else { return }
            cookiesLeaveThisMac = offThisMac
            status.say(offThisMac
                       ? String(localized: "Cookies leave this Mac",
                                comment: "Beside an icon, under the parameters of a JSON-RPC download rule whose endpoint isn't on this Mac: the site's cookies would go to another machine.")
                       : String(localized: "Cookies stay on this Mac",
                                comment: "Beside an icon, under the parameters of a JSON-RPC download rule whose endpoint is on this Mac: the site's cookies would go no further than it."),
                       symbol: offThisMac ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                       color: offThisMac ? Tokens.Color.warning : nil)
        }

        /// Mark the fields holding Add back: the pattern, and the action's own field. `all` also marks the two you
        /// may simply not have reached yet — a name and a pattern that is still empty — which is what the pointer over
        /// the dead button asks for. One list serves the markers, the tooltips and the button's own answer, so the
        /// three can never disagree.
        func markHeldUp(_ rule: DownloadRule?) {
            let held = rule.map { Self.heldUp($0, all: addHovered) } ?? []
            let notes = Dictionary(held.map { ($0.field, $0.note) }, uniquingKeysWith: { first, _ in first })
            // The fields this sheet holds. A `.folder` is a destination's, and the panel that makes one keeps its own;
            // nothing this sheet can show is left unmarked.
            let fields: [HeldField: FilledField?] = [.name: name, .pattern: pattern, .action(.app): appField,
                                                     .action(.url): urlField, .action(.script): scriptField,
                                                     .action(.endpoint): endpointField, .action(.method): methodField]
            for (which, field) in fields {
                let note = notes[which]
                field?.isInvalid = note != nil
                field?.toolTip = note
            }
        }

        /// What the dead Add button says for itself: the first thing to fix, in the order the form is filled in.
        func heldUpNote() -> String? {
            ruleFromFields().flatMap { Self.heldUp($0, all: true).first?.note }
        }

        let valid = {
            let rule = ruleFromFields()
            refreshCookieStatus(rule)
            markHeldUp(rule)
            guard let rule, !rule.name.isEmpty else { return false }
            guard rule.match == .any || !rule.pattern.isEmpty else { return false }
            guard rule.isValidPattern else { return false }
            return rule.action.isComplete
        }
        for picker in [applies, match] + [stylePicker].compactMap({ $0 }) {
            picker.onSelect = { _ in sheetRef?.revalidate() }
        }
        matchCase.onChange = { _ in sheetRef?.revalidate() }

        let sheet = FormSheet.show(in: host,
                                   title: existing == nil ? String(localized: "Add Download Rule", comment: "Title of the sheet that makes a download rule.")
                                                          : String(localized: "Edit Download Rule", comment: "Title of the sheet that changes a download rule."),
                                   symbol: action.kind.symbol,
                                   message: String(localized: "The first rule that matches wins.",
                                                   comment: "Under the title of the sheet that makes a download rule."),
                                   rows: rows,
                                   confirmTitle: existing == nil ? String(localized: "Add", comment: "Button of the sheet that makes a download rule.")
                                                                 : String(localized: "Save", comment: "Button of the sheet that changes a download rule."),
                                   canConfirm: valid) { confirmed in
            guard confirmed, let rule = ruleFromFields() else { return }
            let save = {
                if let secret = secretField?.stringValue, action.kind == .jsonRPC { HandoffSecrets.setSecret(secret, for: rule.id) }
                if existing == nil { DownloadRulesStore.shared.add(rule) } else { DownloadRulesStore.shared.update(rule) }
            }
            // The site's sign-in leaving this Mac is worth one deliberate answer, the moment a rule starts doing it:
            // Add isn't dead and the rule isn't refused — but this isn't a Return meant for a field either, since
            // the sheet won't go ahead on Return, so sending them takes a click. A rule that already did this is
            // asked about once, when it started, not again on every later edit.
            let alreadyRemote = existing?.sendsCookiesOffThisMac ?? false
            guard rule.sendsCookiesOffThisMac, !alreadyRemote else { return save() }
            let place = URL(string: rule.action.rpcEndpoint)?.host() ?? rule.action.rpcEndpoint
            ConfirmSheet.show(in: host,
                              title: String(localized: "Send the site’s cookies off this Mac?",
                                            comment: "Title of the sheet that asks before saving a download rule which would send the site's cookies to another machine."),
                              message: String(localized: "“\(rule.name)” sends them to \(place).",
                                              comment: "Message of the sheet that asks before saving a download rule that sends the site's cookies to another machine. The placeholders are the rule's name and the machine its endpoint is on."),
                              confirmTitle: String(localized: "Send Anyway",
                                                   comment: "Button of the sheet that asks before saving a download rule that sends the site's cookies to another machine."),
                              destructive: true) { sure in
                if sure { save() }
            }
        }
        sheetRef = sheet
        // Hovering the dead Add button marks every field holding it up, and the button says the first of them for
        // itself; leaving it takes the markers back.
        sheet.onConfirmHover = { over in
            addHovered = over
            sheetRef?.revalidate()
        }
        sheet.heldUpNote = { heldUpNote() }
    }

    /// A field with a button beside it (a path and Choose…). The sheet lays its rows out by frame, and
    /// `NSStackView(views:)` turns autoresizing off, so without this the stack would size to its content — the field's
    /// own width plus the button — and the button would be drawn past the row's end, unseen. The field is what gives
    /// way when the row is narrower than the two together; the button keeps its own width.
    static func stack(_ field: NSView, _ button: NSView) -> NSStackView {
        let stack = NSStackView(views: [field, button])
        stack.orientation = .horizontal
        stack.spacing = Tokens.Space.x2
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // Shrinking is the other half of it: with both at the default resistance, a row narrower than field + button
        // can't be resolved and the stack lays the button out past the end rather than drawing it inside.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    /// Everything holding a rule's Add button back, in the order the form is filled in: the name, what it matches,
    /// then the action's own field. `all` adds the two you may simply not have reached yet — an empty name and an
    /// empty pattern — which is what the pointer over the dead button asks for; a broken expression is always worth
    /// saying. Empty means Add can be pressed.
    static func heldUp(_ rule: DownloadRule, all: Bool) -> [(field: HeldField, note: String)] {
        var held: [(field: HeldField, note: String)] = []
        if all, rule.name.isEmpty {
            held.append((.name, String(localized: "Give the rule a name.", comment: "Tooltip on the name field of a download rule being added without one, so its Add button can't be pressed.")))
        }
        if rule.match != .any, rule.pattern.isEmpty {
            if all {
                held.append((.pattern, rule.match == .fileType
                             ? String(localized: "List the file extensions this rule catches, like pdf, epub.", comment: "Tooltip on the extensions field of a download rule with none yet, so its Add button can't be pressed.")
                             : String(localized: "Type what this rule catches.", comment: "Tooltip on the address field of a download rule with no pattern yet, so its Add button can't be pressed.")))
            }
        } else if !rule.isValidPattern {
            held.append((.pattern, String(localized: "That isn’t a working regular expression. Zigzag saves nothing it can’t read.", comment: "Tooltip on the address field of a download rule whose regular expression doesn't compile.")))
        }
        if let action = actionHoldUp(rule.action) { held.append((.action(action.field), action.note)) }
        return held
    }

    /// Which of the sheet's fields something can be said about.
    enum HeldField: Hashable {
        case name
        case pattern
        case action(ActionField)
    }

    /// Which of a rule action's own fields is holding its Add button back, if one is.
    enum ActionField: Equatable { case app, url, script, endpoint, method, folder }

    /// The field a rule's action still needs something in, and what to say about it: nil when the action can run.
    /// Kept out of the sheet so the one thing that decides it — `isComplete` — is tested against every kind, and so a
    /// greyed Add button never leaves the person guessing which field to fill. An address with no scheme (`bing.com`)
    /// is complete's own case, and its own words.
    static func actionHoldUp(_ action: DownloadRuleAction) -> (field: ActionField, note: String)? {
        switch action.kind {
        case .openApp:
            return action.appPath.isEmpty
                ? (.app, String(localized: "Choose the app this rule opens the link with.", comment: "Tooltip on the app field of a download rule whose action has no app yet, so its Add button is greyed."))
                : nil
        case .openURL:
            if action.urlTemplate.isEmpty {
                return (.url, String(localized: "Type the address this rule sends the link to.", comment: "Tooltip on the address field of a download rule whose action has no address yet, so its Add button is greyed."))
            }
            return action.isComplete ? nil
                : (.url, String(localized: "This address needs a scheme, like “mpv://” or “https://”.", comment: "Tooltip on the address field of a download rule whose address has no scheme, so nothing could open it and its Add button is greyed."))
        case .runScript:
            return action.scriptPath.isEmpty
                ? (.script, String(localized: "Choose the script this rule runs.", comment: "Tooltip on the script field of a download rule whose action has no script yet, so its Add button is greyed."))
                : nil
        case .jsonRPC:
            if !action.endpointIsUsable {
                return (.endpoint, String(localized: "Type the address of the JSON-RPC service, like http://127.0.0.1:6800/jsonrpc.", comment: "Tooltip on the endpoint field of a JSON-RPC download rule that has none, or one that has a scheme missing or no address at all, so its Add button is greyed."))
            }
            return action.rpcMethod.isEmpty
                ? (.method, String(localized: "Name the method to call on the service.", comment: "Tooltip on the method field of a JSON-RPC download rule that names no method, so its Add button is greyed."))
                : nil
        case .saveToFolder:
            return action.folderPath.isEmpty
                ? (.folder, String(localized: "Choose the folder these files are saved into.", comment: "Tooltip on the folder field of a per-extension destination that has no folder yet, so it can't be saved."))
                : nil
        case .showInZigzag:
            return nil
        }
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
