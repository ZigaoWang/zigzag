import AppKit
import UniformTypeIdentifiers

/// The sheet that makes or changes one rule: what it's called, what it catches, and where the address goes. The
/// action kind is chosen before the sheet opens (from Add Rule or a preset), so the fields shown are exactly the ones
/// that action uses. Tokens are listed under the pattern: an Open URL template, a script's arguments and a service's
/// parameters take them; a path, an endpoint and a method are literal.
enum DownloadRuleSheet {
    /// Opens the editor for a new rule of `kind`, or for `rule` if one is given.
    static func show(in host: NSView, kind: DownloadRuleAction.Kind, preset: DownloadPreset? = nil, rule existing: DownloadRule? = nil) {
        let source = existing ?? preset?.rule ?? DownloadRule(name: "", action: DownloadRuleAction(kind: kind))
        // A preset's action may differ from the requested kind (the downloader presets are RPC): the action wins.
        let action = existing?.action ?? preset?.rule.action ?? DownloadRuleAction(kind: kind)
        // Declared before the fields, which hear the sheet and ask it to check them again.
        /// Opening this sheet for a destination (Open, Save) is the panel under Save downloads to asking for one file
        /// type: the sheet then asks *which type* (its extensions, not an address) and what happens to it, instead of
        /// the address matches and the four handoff actions.
        let isDestination = action.kind.isDestination
        /// The two destinations, in the order the choice offers them; the action's own kind is the one chosen.
        let destinationKinds: [DownloadRuleAction.Kind] = [.openFile, .saveToFolder]
        var sheetRef: FormSheet?

        let name = FilledField(placeholder: String(localized: "Name", comment: "Placeholder of the name field in the sheet that makes a download rule."))
        name.stringValue = source.name
        let pattern = FilledField(placeholder: isDestination
            ? String(localized: "pdf, epub", comment: "Placeholder of the file-extension field in the sheet that makes a per-extension destination: the extensions to list, like pdf, epub.")
            : String(localized: "example.com/files/", comment: "Placeholder of the pattern field in the sheet that makes a download rule."))
        pattern.stringValue = source.pattern

        let applies = DropdownButton()
        applies.options = DownloadRule.Applies.allCases.map { DropdownButton.Option(title: $0.title) }
        applies.selectedIndex = DownloadRule.Applies.allCases.firstIndex(of: source.applies) ?? 0
        // The Match dropdown offers the address matches: a file-type rule is a per-extension destination, made and
        // edited in the panel under Save downloads to, not here. One that arrives anyway keeps what it had. A sheet
        // opened *for* a destination is that panel's own editor, so there the one match it can have is the choice.
        let matchChoices = isDestination ? [.fileType] : DownloadRule.Match.allCases.filter { $0 != .fileType }
        let match = DropdownButton()
        match.options = matchChoices.map { DropdownButton.Option(title: $0.title) }
        match.selectedIndex = matchChoices.firstIndex(of: source.match) ?? matchChoices.firstIndex(of: .contains) ?? 0
        let caseSensitive = Toggle(isOn: source.isCaseSensitive)
        caseSensitive.setAccessibilityLabel(String(localized: "Match case", comment: "Label of the case choice in a download rule's sheet."))
        let runsInPrivate = Toggle(isOn: source.runsInPrivateWindows)
        runsInPrivate.setAccessibilityLabel(String(localized: "Run in private windows", comment: "Label of the switch in a download rule's sheet that lets the rule run in private windows."))

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
        /// A destination's two fields: which of the two it is, and the folder one of them saves into.
        var destinationField: DropdownButton?
        var folderField: FilledField?
        /// Where the folder row sits in `actionRows`, so it can be taken out while the other destination is chosen.
        var folderActionRow: Int?

        func choose(_ panel: NSOpenPanel, into field: FilledField) {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            field.stringValue = url.path
            // A path chosen, not typed: the form doesn't hear a programmatic change, so ask it again by hand.
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
            actionRows.append(.note(String(localized: "One argument a line. Each becomes its own argument, so a URL with &, ; or $() is never run as a shell command. The link, cookies and the rest are also in ZIGZAG_LINK, ZIGZAG_COOKIES and the other environment variables.",
                                           comment: "Under the arguments of a Run Script download rule, explaining argv and environment.")))
        case .jsonRPC:
            // The Torrents preset is one rule whose only real difference between services is the protocol: one
            // dropdown fills the endpoint, method, parameters and protocol in, and leaves the catch pattern alone.
            if preset == .torrents {
                let service = DropdownButton()
                service.options = TorrentService.allCases.map { DropdownButton.Option(title: $0.title) }
                service.selectedIndex = TorrentService.allCases.firstIndex(of: .rTorrent) ?? 0
                actionRows.append(FormSheet.Row(label: String(localized: "Service", comment: "Label of the service choice in the Torrents preset's sheet."),
                                                view: service))
                service.onSelect = { index in
                    guard TorrentService.allCases.indices.contains(index) else { return }
                    let chosen = TorrentService.allCases[index]
                    endpointField?.stringValue = chosen.endpoint
                    methodField?.stringValue = chosen.method
                    parametersView?.text = chosen.parameters
                    stylePicker?.selectedIndex = DownloadRuleAction.RPCStyle.allCases.firstIndex(of: chosen.style) ?? 0
                    // The name follows the service until it has been made the reader's own.
                    if chosen != .custom,
                       name.stringValue.isEmpty || TorrentService.allCases.contains(where: { $0.ruleName == name.stringValue }) {
                        name.stringValue = chosen.ruleName
                    }
                    sheetRef?.revalidate()
                }
            }
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
        case .saveToFolder, .openFile:
            // A destination's own two things: what happens to a file of this type, and, when it is saved, where.
            // The row that picks the kind is the one the panel's "Add File Type…" opens on; the folder row is
            // taken out of the form for Open, where the file goes to the ordinary place instead.
            let whereTo = DropdownButton()
            whereTo.options = destinationKinds.map { DropdownButton.Option(title: $0.title) }
            whereTo.selectedIndex = destinationKinds.firstIndex(of: action.kind) ?? 0
            destinationField = whereTo
            actionRows.append(FormSheet.Row(label: String(localized: "Destination", comment: "Label of the choice in a per-extension destination's sheet: a folder of its own, or Zigzag showing the file itself."),
                                            view: whereTo))
            let folder = FilledField(placeholder: String(localized: "Choose a folder…", comment: "Placeholder of the folder field in a per-extension destination's sheet."))
            // A new type starts in the folder downloads already go to: "Save" means save there unless it is changed.
            folder.stringValue = action.folderPath.isEmpty && existing == nil ? DownloadManager.folder.path : action.folderPath
            folderField = folder
            let chooseFolder = PillButton(title: String(localized: "Choose…", comment: "Button beside a path in a download rule's sheet: opens the open panel."))
            chooseFolder.onClick = { _ in
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.prompt = String(localized: "Choose", comment: "Button of the open panel that picks a folder for a download rule.")
                // It opens where the field already points — the folder downloads go to, for a new type — so the
                // ordinary answer is one click, not a walk back from wherever the panel was last.
                let typed = (folder.stringValue as NSString).expandingTildeInPath
                var isFolder: ObjCBool = false
                if !typed.isEmpty, FileManager.default.fileExists(atPath: typed, isDirectory: &isFolder), isFolder.boolValue {
                    panel.directoryURL = URL(fileURLWithPath: typed, isDirectory: true)
                } else {
                    panel.directoryURL = DownloadManager.folder
                }
                choose(panel, into: folder)
            }
            folderActionRow = actionRows.count
            actionRows.append(FormSheet.Row(label: String(localized: "Folder", comment: "Label of the folder field in a per-extension destination's sheet: which folder files of this type are saved into."),
                                            view: stack(folder, chooseFolder)))
        }

        let tokens = FormSheet.Row.note(String(localized: "Tokens: {link}, {encoded_link}, {host}, {path}, {query}, {referrer}, {cookies}, {cookie_header}, {filename}, {mime}, {space}.",
                                             comment: "The tokens a download rule's fields may use, listed in its sheet."))
        /// A destination is asked one thing of its own — which types of file — so it drops what only an address rule
        /// has any use for: what the rule applies to (a type is always a download), how it matches (the type is the
        /// match), whether case matters and whether the page goes on. An address rule keeps all of them.
        let matchRows: [FormSheet.Row] = isDestination ? [
            FormSheet.Row(label: String(localized: "Name", comment: "Label of the name field in a download rule's sheet."), view: name),
            FormSheet.Row(label: String(localized: "File Extensions", comment: "Label of the extensions field in a per-extension destination's sheet, where the types of file are listed."), view: pattern),
        ] : [
            FormSheet.Row(label: String(localized: "Name", comment: "Label of the name field in a download rule's sheet."), view: name),
            FormSheet.Row(label: String(localized: "Applies to", comment: "Label of the choice of what a download rule catches, in its sheet."), view: applies),
            FormSheet.Row(label: String(localized: "Match", comment: "Label of the choice of how a download rule matches an address, in its sheet."), view: match),
            FormSheet.Row(label: String(localized: "Address", comment: "Label of the address pattern in a download rule's sheet."), view: pattern),
            FormSheet.Row(label: String(localized: "Match case", comment: "Label of the case choice in a download rule's sheet."), view: caseSensitive),
            FormSheet.Row(label: String(localized: "Run in private windows", comment: "Label of the switch in a download rule's sheet that lets the rule run in private windows."), view: runsInPrivate),
        ]
        // A destination adds what it does; an address rule lists its tokens, unless its path is literal (Open App).
        let rows = matchRows + actionRows + (isDestination ? [
            FormSheet.Row.note(String(localized: "Files of this type are saved to the folder above, or opened in your Mac’s app for them. The first file type that matches wins.",
                                                 comment: "Under the fields of a per-extension destination's sheet: what it does, and that the first one that matches decides.")),
            FormSheet.Row.note(String(localized: "Apps, scripts, installers, archives and configuration profiles are always saved, never opened.",
                                      comment: "Under the fields of a per-extension destination's sheet: the file types Open never opens, whatever the choice says.")),
            tokens,
        ] : (action.kind == .openApp ? [] : [tokens]))

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
            case .saveToFolder, .openFile:
                // Which of the two it is, as the choice says, and the folder one of them saves into (kept even while
                // the other is chosen, so switching back finds it again).
                if let index = destinationField?.selectedIndex, destinationKinds.indices.contains(index) {
                    action.kind = destinationKinds[index]
                }
                action.folderPath = folderField?.stringValue ?? ""
            }
            var rule = existing ?? source
            rule.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.applies = DownloadRule.Applies.allCases[applies.selectedIndex]
            rule.match = matchChoices.indices.contains(match.selectedIndex) ? matchChoices[match.selectedIndex] : source.match
            rule.pattern = pattern.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.isCaseSensitive = caseSensitive.isOn
            rule.runsInPrivateWindows = runsInPrivate.isOn
            rule.action = action
            return rule
        }

        let valid = {
            guard let rule = ruleFromFields(), !rule.name.isEmpty || rule.action.kind.isDestination else { return false }
            guard rule.match == .any || !rule.pattern.isEmpty else { return false }
            guard rule.isValidPattern else { return false }
            // Open is not offered for an app, a script, an installer or an archive: such a rule could only be saved
            // and then refused, so the sheet asks for Save instead.
            guard !(rule.action.kind == .openFile && DownloadOpening.isRefused(pattern: rule.pattern)) else { return false }
            return rule.action.isComplete
        }
        for picker in [applies, match] + [stylePicker].compactMap({ $0 }) {
            picker.onSelect = { _ in sheetRef?.revalidate() }
        }

        // A destination is its own kind of form: a title of its own, and a line saying what it is for.
        let sheetTitle: String
        let sheetMessage: String
        if isDestination {
            sheetTitle = existing == nil
                ? String(localized: "Add a File Type", comment: "Title of the sheet that makes a per-extension destination in Settings › Downloads.")
                : String(localized: "Change This File Type", comment: "Title of the sheet that changes a per-extension destination in Settings › Downloads.")
            sheetMessage = String(localized: "What happens to files of this type.",
                                  comment: "Under the title of the sheet that makes a per-extension destination.")
        } else {
            sheetTitle = existing == nil ? String(localized: "Add Download Rule", comment: "Title of the sheet that makes a download rule.")
                                         : String(localized: "Edit Download Rule", comment: "Title of the sheet that changes a download rule.")
            sheetMessage = String(localized: "The first rule that matches wins.",
                                  comment: "Under the title of the sheet that makes a download rule.")
        }

        let sheet = FormSheet.show(in: host,
                                   title: sheetTitle,
                                   symbol: action.kind.symbol,
                                   message: isDestination ? sheetMessage : String(localized: "The first rule that matches an address wins. Rules run from the top of the list.",
                                                                                   comment: "Under the title of the sheet that makes a download rule."),
                                   rows: rows,
                                   confirmTitle: existing == nil ? String(localized: "Add", comment: "Button of the sheet that makes a download rule.")
                                                                 : String(localized: "Save", comment: "Button of the sheet that changes a download rule."),
                                   canConfirm: valid) { confirmed in
            // The sheet is done either way; the fields are read below, not from it.
            sheetRef = nil
            guard confirmed, let rule = ruleFromFields(),
                  !(rule.action.kind == .openFile && DownloadOpening.isRefused(pattern: rule.pattern)) else { return }
            if let secret = secretField?.stringValue, action.kind == .jsonRPC { HandoffSecrets.setSecret(secret, for: rule.id) }
            if existing == nil { DownloadRulesStore.shared.add(rule) } else { DownloadRulesStore.shared.update(rule) }
        }
        sheetRef = sheet
        // The folder belongs to one of the two destinations. Choosing the other takes the row out of the form
        // rather than leaving a field there that would be ignored — and puts it back, with the folder it had.
        if let whereTo = destinationField, let folderActionRow {
            let row = matchRows.count + folderActionRow
            whereTo.onSelect = { [weak sheet, weak whereTo] _ in
                guard let sheet, let whereTo else { return }
                sheet.setHidden(destinationKinds.firstIndex(of: .openFile) == whereTo.selectedIndex, forRow: row)
                sheet.revalidate()
            }
            sheet.setHidden(destinationKinds.firstIndex(of: .openFile) == whereTo.selectedIndex, forRow: row)
        }
    }

    /// A field with a button at its end, both stretched across the form's row.
    private static func stack(_ field: NSView, _ button: NSView) -> NSStackView {
        let stack = NSStackView(views: [field, button])
        stack.orientation = .horizontal
        stack.spacing = Tokens.Space.x2
        stack.distribution = .fill
        stack.alignment = .centerY
        // The sheet lays its rows out by frame; a stack built from views turns autoresizing off and would ignore it.
        stack.translatesAutoresizingMaskIntoConstraints = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // Shrinking is the other half: with both at the default resistance, a row narrower than field + button
        // lays the button out past the end rather than drawing it inside.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }
}
