import AppKit
import UniformTypeIdentifiers

/// Edits one download rule: name, match, and action. The action kind is chosen before opening (Add Rule or a preset),
/// so only its fields show. Tokens apply to Open URL templates, script arguments and service parameters; paths,
/// endpoints and methods are literal.
enum DownloadRuleSheet {
    /// Every way a rule can match. A destination is a file type only; any other rule may match an address or, since
    /// links have no name, a download's own file type.
    static func matchChoices(isDestination: Bool) -> [DownloadRule.Match] {
        isDestination ? [.fileType] : DownloadRule.Match.allCases
    }

    /// What the pattern field asks for: extensions for a file-type rule, an address for the rest.
    static func patternPlaceholder(for match: DownloadRule.Match) -> String {
        match == .fileType
            ? String(localized: "pdf, epub", comment: "Placeholder of the file-extension field in the sheet that makes a per-extension destination: the extensions to list, like pdf, epub.")
            : String(localized: "example.com/files/", comment: "Placeholder of the pattern field in the sheet that makes a download rule.")
    }

    /// Edits a new rule of `kind`, or `rule` if given.
    static func show(in host: NSView, kind: DownloadRuleAction.Kind, preset: DownloadPreset? = nil, rule existing: DownloadRule? = nil) {
        let source = existing ?? preset?.rule ?? DownloadRule(name: "", action: DownloadRuleAction(kind: kind))
        // A preset's action may differ from the requested kind (the downloader presets are RPC): the action wins.
        let action = existing?.action ?? preset?.rule.action ?? DownloadRuleAction(kind: kind)
        // Declared before the fields, which call back to revalidate.
        /// Opened for a destination (Open, Save) from Save downloads to: asks for file extensions and what to do,
        /// instead of address matches and the four handoff actions.
        let isDestination = action.kind.isDestination
        /// Both destinations in menu order; the action's kind is selected.
        let destinationKinds: [DownloadRuleAction.Kind] = [.openFile, .saveToFolder]
        var sheetRef: FormSheet?

        let name = FilledField(placeholder: String(localized: "Name", comment: "Placeholder of the name field in the sheet that makes a download rule."))
        name.stringValue = source.name
        let pattern = FilledField(placeholder: Self.patternPlaceholder(for: isDestination ? .fileType : source.match))
        pattern.stringValue = source.pattern
        /// Pointer over the main button, which shows every field blocking Add.
        var addHovered = false

        let applies = DropdownButton()
        applies.options = DownloadRule.Applies.allCases.map { DropdownButton.Option(title: $0.title) }
        applies.selectedIndex = DownloadRule.Applies.allCases.firstIndex(of: source.applies) ?? 0
        /// URL hands over the address as before; File downloads in Zigzag first, then hands over the saved file.
        let handoff = DropdownButton()
        handoff.options = DownloadRule.HandoffType.allCases.map { DropdownButton.Option(title: $0.title) }
        handoff.selectedIndex = DownloadRule.HandoffType.allCases.firstIndex(of: source.handoffType) ?? 0
        handoff.setAccessibilityLabel(String(localized: "Hand off", comment: "Label of the choice between handing off a download rule's URL or its saved file."))
        // A destination is only a file type. Any other rule matches an address, or a download's own type whatever its
        // address says, so a tracker's download.php address can still reach the downloader.
        let matchChoices = Self.matchChoices(isDestination: isDestination)
        let match = DropdownButton()
        match.options = matchChoices.map { DropdownButton.Option(title: $0.title) }
        match.selectedIndex = matchChoices.firstIndex(of: source.match) ?? matchChoices.firstIndex(of: .contains) ?? 0
        let matchCase = Toggle(isOn: source.isCaseSensitive)
        matchCase.setAccessibilityLabel(String(localized: "Match case", comment: "Label of the case choice in a download rule's sheet."))
        let runsInPrivate = Toggle(isOn: source.runsInPrivateWindows)
        runsInPrivate.setAccessibilityLabel(String(localized: "Allow in private windows", comment: "Label of the switch in a download rule's sheet that lets the rule run in private windows."))

        // Fields per action kind.
        var actionRows: [FormSheet.Row] = []
        var appField: FilledField?
        var urlField: FilledField?
        /// Open URL: where a web address opens. Ask asks on first use; Default Browser is the pre-places behavior.
        var openInField: DropdownButton?
        /// Ask, the Mac's browser, then Zigzag's three places.
        let openInChoices = OpenInZigzag.Choice.allCases
        var scriptField: FilledField?
        var argumentView: MultilineField?
        var endpointField: FilledField?
        var methodField: FilledField?
        var parametersView: MultilineField?
        var secretField: FilledField?
        var userField: FilledField?
        var passwordField: FilledField?
        var stylePicker: DropdownButton?
        /// A destination's kind and save folder.
        var destinationField: DropdownButton?
        var folderField: FilledField?
        /// The folder row's index in `actionRows`, hidden for the other destination.
        var folderActionRow: Int?

        switch action.kind {
        case .openApp:
            let field = FilledField(placeholder: String(localized: "Choose an app…", comment: "Placeholder of the app field in a download rule's sheet."))
            field.stringValue = action.appPath
            appField = field
            // Like the script field below: apps in the listed folders are one click away, others via Choose an App…;
            // stored as a full path.
            let chooseAnApp = {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.treatsFilePackagesAsDirectories = false
                panel.allowedContentTypes = [.application]
                panel.prompt = String(localized: "Choose", comment: "Button of the open panel that picks an app for a download rule.")
                guard panel.runModal() == .OK, let url = panel.url else { return }
                field.stringValue = url.path
                sheetRef?.revalidate()
            }
            let button = PillButton(title: String(localized: "Choose…", comment: "Button beside a path in a download rule's sheet: opens the open panel."))
            // Its menu opens as the press goes down, as a pop-up button's does.
            button.clicksOnMouseDown = true
            button.onClick = { [weak button] _ in
                guard let button else { return }
                var entries: [MenuPanel.Entry] = Applications.named().map { app in
                    .item(MenuPanel.Item(title: app.name, image: Applications.icon(app.path)) {
                        field.stringValue = app.path
                        sheetRef?.revalidate()
                    })
                }
                if !entries.isEmpty { entries.append(.separator) }
                entries.append(.item(MenuPanel.Item(title: String(localized: "Choose an App…", comment: "Item in the menu beside an Open App rule's app field: picks an app kept outside the Applications folders.")) {
                    chooseAnApp()
                }))
                entries.append(.item(MenuPanel.Item(title: String(localized: "Show Applications Folder", comment: "Item in the menu beside an Open App rule's app field: opens this Mac's Applications folder in Finder."), symbol: "folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                }))
                button.isSelected = true
                MenuPanel.show(entries, from: button) { [weak button] in button?.isSelected = false }
            }
            actionRows.append(FormSheet.Row(label: String(localized: "App", comment: "Label of the app field in a download rule's sheet."),
                                            view: stack(field, button)))
        case .openURL:
            let field = FilledField(placeholder: "mpv://{encoded_link}")
            field.stringValue = action.urlTemplate
            urlField = field
            actionRows.append(FormSheet.Row(label: String(localized: "URL", comment: "Label of the URL field in a download rule's sheet."), view: field))
            // Where a web address opens: the Mac's browser or one of Zigzag's places. Non-web addresses (mpv://,
            // magnet) go to their own app, as the note says.
            let place = DropdownButton()
            place.options = OpenInZigzag.Choice.allCases.map { DropdownButton.Option(title: $0.title) }
            place.selectedIndex = openInChoices.firstIndex(of: action.openIn) ?? 0
            place.toolTip = String(localized: "A rule that hasn’t been told asks the first time it fires, and keeps your answer.", comment: "Tooltip on the Open in choice of an Open URL download rule.")
            openInField = place
            actionRows.append(FormSheet.Row(label: String(localized: "Opens in", comment: "Label of the choice of where a web address opens, in an Open URL download rule's sheet."),
                                            view: place))
            actionRows.append(.note(String(localized: "A web address opens in Zigzag or your default browser. Anything else opens in its own app.",
                                           comment: "Under the Open in choice of an Open URL download rule: only the web's own addresses are Zigzag's to open.")))
        case .runScript:
            let field = FilledField(placeholder: String(localized: "Choose a script…", comment: "Placeholder of the script field in a download rule's sheet."))
            field.stringValue = action.scriptPath
            scriptField = field
            // Scripts in the folder are listed; others via Choose a Script…. Folder scripts are stored by name, so the
            // rule reads `yt-dlp.sh` and keeps working.
            let pickAScript = {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.treatsFilePackagesAsDirectories = false
                panel.prompt = String(localized: "Choose", comment: "Button of the open panel that picks a script for a download rule.")
                guard panel.runModal() == .OK, let url = panel.url else { return }
                field.stringValue = Paths.scriptName(for: url)
                sheetRef?.revalidate()
            }
            let button = PillButton(title: String(localized: "Choose…", comment: "Button beside a path in a download rule's sheet: opens the open panel."))
            // Its menu opens as the press goes down, as a pop-up button's does.
            button.clicksOnMouseDown = true
            button.onClick = { [weak button] _ in
                guard let button else { return }
                var entries: [MenuPanel.Entry] = Paths.scriptNames().map { name in
                    .item(MenuPanel.Item(title: name, symbol: "terminal") {
                        field.stringValue = name
                        sheetRef?.revalidate()
                    })
                }
                if !entries.isEmpty { entries.append(.separator) }
                entries.append(.item(MenuPanel.Item(title: String(localized: "Choose a Script…", comment: "Item in the menu beside a Run Script rule's script field: picks a script kept outside the scripts folder.")) {
                    pickAScript()
                }))
                entries.append(.item(MenuPanel.Item(title: String(localized: "Show Scripts Folder", comment: "Item in the menu beside a Run Script rule's script field: opens the folder the scripts live in, in Finder."), symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.scripts])
                }))
                button.isSelected = true
                MenuPanel.show(entries, from: button) { [weak button] in button?.isSelected = false }
            }
            actionRows.append(FormSheet.Row(label: String(localized: "Script", comment: "Label of the script field in a download rule's sheet."),
                                            view: stack(field, button)))
            let args = MultilineField(text: action.arguments.joined(separator: "\n"))
            argumentView = args
            actionRows.append(FormSheet.Row(label: String(localized: "Arguments", comment: "Label of the arguments field in a download rule's sheet: one argument a line."),
                                            view: args, height: 96))
            actionRows.append(.note(String(localized: "One argument a line. The link and the cookies arrive in ZIGZAG_LINK and ZIGZAG_COOKIES; a File handoff also sets ZIGZAG_FILE.",
                                           comment: "Under the arguments of a Run Script download rule: one argument a line, and the names the link, the cookies and a File handoff's saved file arrive under.")))
            actionRows.append(FormSheet.Row(label: nil,
                                            view: StatusLabel(String(localized: "Run directly, never through a shell",
                                                                     comment: "Beside an icon, under the arguments of a Run Script download rule: the arguments can never become part of a command line, since the script is run directly."),
                                                              symbol: "checkmark.shield.fill"),
                                            height: 0))
        case .jsonRPC:
            let endpoint = FilledField(placeholder: "http://127.0.0.1:6800/jsonrpc")
            endpoint.stringValue = action.rpcEndpoint
            endpointField = endpoint
            actionRows.append(FormSheet.Row(label: String(localized: "Endpoint", comment: "Label of the endpoint field in a JSON-RPC download rule's sheet."), view: endpoint))
            // Optional sign-in, kept in the Keychain: an endpoint that needs one says who it is with a header, so the
            // address itself never carries a password.
            let savedUser = existing.flatMap { HandoffSecrets.endpointCredentials(for: $0.id, endpoint: $0.action.rpcEndpoint) }
            let user = FilledField(placeholder: String(localized: "Username, if the service asks", comment: "Placeholder of the username field in a JSON-RPC download rule's sheet. It's kept in the Keychain."))
            user.stringValue = savedUser?.user ?? ""
            userField = user
            actionRows.append(FormSheet.Row(label: String(localized: "Username", comment: "Label of the username field in a JSON-RPC download rule's sheet."), view: user))
            let password = FilledField(placeholder: String(localized: "Password, if the service asks", comment: "Placeholder of the password field in a JSON-RPC download rule's sheet. It's kept in the Keychain."), secure: true)
            password.stringValue = savedUser?.password ?? ""
            password.toolTip = String(localized: "Kept in the Keychain", comment: "Tooltip on the token field of a JSON-RPC download rule's sheet.")
            passwordField = password
            actionRows.append(FormSheet.Row(label: String(localized: "Password", comment: "Label of the password field in a JSON-RPC download rule's sheet."), view: password))
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
        case .saveToFolder, .openFile:
            // A destination's kind and, when saving, its folder. The kind row is where "Add File Type…" opens; the
            // folder row is hidden for Open.
            let whereTo = DropdownButton()
            whereTo.options = destinationKinds.map { DropdownButton.Option(title: $0.title) }
            whereTo.selectedIndex = destinationKinds.firstIndex(of: action.kind) ?? 0
            destinationField = whereTo
            actionRows.append(FormSheet.Row(label: String(localized: "Destination", comment: "Label of the choice in a per-extension destination's sheet: a folder of its own, or Zigzag showing the file itself."),
                                            view: whereTo))
            let folder = FilledField(placeholder: String(localized: "Choose a folder…", comment: "Placeholder of the folder field in a per-extension destination's sheet."))
            // New types default to the downloads folder.
            folder.stringValue = action.folderPath.isEmpty && existing == nil ? DownloadManager.folder.path : action.folderPath
            folderField = folder
            let chooseFolder = PillButton(title: String(localized: "Choose…", comment: "Button beside a path in a download rule's sheet: opens the open panel."))
            chooseFolder.onClick = { _ in
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.prompt = String(localized: "Choose", comment: "Button of the open panel that picks a folder for a download rule.")
                // The panel opens at the field's folder, so the default is one click.
                let typed = (folder.stringValue as NSString).expandingTildeInPath
                var isFolder: ObjCBool = false
                if !typed.isEmpty, FileManager.default.fileExists(atPath: typed, isDirectory: &isFolder), isFolder.boolValue {
                    panel.directoryURL = URL(fileURLWithPath: typed, isDirectory: true)
                } else {
                    panel.directoryURL = DownloadManager.folder
                }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                folder.stringValue = url.path
                sheetRef?.revalidate()
            }
            folderActionRow = actionRows.count
            actionRows.append(FormSheet.Row(label: String(localized: "Folder", comment: "Label of the folder field in a per-extension destination's sheet: which folder files of this type are saved into."),
                                            view: stack(folder, chooseFolder)))
        }

        let tokens = FormSheet.Row.note(String(localized: "Tokens: {link}, {encoded_link}, {host}, {path}, {query}, {referrer}, {cookies}, {cookie_header}, {filename}, {mime}, {space}, {file}, {file_url}, {file_raw}. {file}, {file_url} and {file_raw} need File handoff; {file_raw} is the file’s bytes, for a service’s parameters.",
                                             comment: "The tokens a download rule's fields may use, listed in its sheet. File, file_url and file_raw are only filled in when the rule hands off a saved file; file_raw, the file's contents in base64, only in a JSON-RPC or XML-RPC rule's parameters."))
        let handoffNote = FormSheet.Row.note(String(localized: "File saves the download in Zigzag first, using the page’s session, then hands off the saved file; links still hand off their address.",
                                                    comment: "Under the Hand off choice in a download rule's sheet: what File does, and that links are unaffected."))
        // Destinations only ask for file types; they drop the address rule rows (applies to, match, case, page
        // continues). A rule that matches a file's own type shows the same field as "File Extensions", not "Address".
        let addressLabel = String(localized: "Address", comment: "Label of the address pattern in a download rule's sheet.")
        let extensionsLabel = String(localized: "File Extensions", comment: "Label of the extensions field in a per-extension destination's sheet, where the types of file are listed.")
        let matchRows: [FormSheet.Row]
        /// The pattern row, whose label follows the match.
        let patternRow: Int
        if isDestination {
            matchRows = [
                FormSheet.Row(label: String(localized: "Name", comment: "Label of the name field in a download rule's sheet."), view: name),
                FormSheet.Row(label: extensionsLabel, view: pattern),
                FormSheet.Row(label: String(localized: "Allow in private windows", comment: "Label of the switch in a download rule's sheet that lets the rule run in private windows."), view: runsInPrivate),
            ]
            patternRow = 1
        } else {
            matchRows = [
                FormSheet.Row(label: String(localized: "Name", comment: "Label of the name field in a download rule's sheet."), view: name),
                FormSheet.Row(label: String(localized: "Applies to", comment: "Label of the choice of what a download rule catches, in its sheet."), view: applies),
                FormSheet.Row(label: String(localized: "Hand off", comment: "Label of the choice between handing off a download rule's URL or its saved file, in its sheet."), view: handoff),
                FormSheet.Row(label: String(localized: "Match", comment: "Label of the choice of how a download rule matches an address, in its sheet."), view: match),
                FormSheet.Row(label: source.match == .fileType ? extensionsLabel : addressLabel, view: pattern),
                FormSheet.Row(label: String(localized: "Match case", comment: "Label of the case choice in a download rule's sheet."), view: matchCase),
                FormSheet.Row(label: String(localized: "Allow in private windows", comment: "Label of the switch in a download rule's sheet that lets the rule run in private windows."), view: runsInPrivate),
            ]
            patternRow = 4
        }
        // Destinations add their action; address rules list tokens unless the path is literal (Open App).
        let trailingRows: [FormSheet.Row]
        if isDestination {
            trailingRows = [
                FormSheet.Row.note(String(localized: "Save writes files of this type to the folder; Open saves them where downloads go and opens them in your Mac’s app. The first file type that matches wins.",
                                                     comment: "Under the fields of a per-extension destination's sheet: what each destination does, and that the first one that matches decides.")),
                FormSheet.Row.note(String(localized: "Allow in private windows affects only Open, not Save.",
                                          comment: "Under the fields of a per-extension destination's sheet: the private-windows switch only stops Open, not Save.")),
                FormSheet.Row.note(String(localized: "Apps, scripts, installers, archives and .mobileconfig files are always saved, never opened.",
                                          comment: "Under the fields of a per-extension destination's sheet: the file types Open never opens, whatever the choice says.")),
                tokens,
            ]
        } else {
            trailingRows = action.kind == .openApp ? [] : [tokens]
        }
        let rows = matchRows + (isDestination ? [] : [handoffNote]) + actionRows + trailingRows

        func ruleFromFields() -> DownloadRule? {
            var action = action
            switch action.kind {
            case .openApp: action.appPath = appField?.stringValue ?? ""
            case .openURL:
                action.urlTemplate = urlField?.stringValue ?? ""
                if let index = openInField?.selectedIndex, openInChoices.indices.contains(index) { action.openIn = openInChoices[index] }
            case .runScript:
                action.scriptPath = scriptField?.stringValue ?? ""
                action.arguments = (argumentView?.text ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            case .jsonRPC:
                action.rpcEndpoint = endpointField?.stringValue ?? ""
                action.rpcMethod = methodField?.stringValue ?? ""
                action.rpcParameters = parametersView?.text ?? "[]"
                action.rpcStyle = DownloadRuleAction.RPCStyle.allCases[stylePicker?.selectedIndex ?? 0]
            case .saveToFolder, .openFile:
                // The selected kind, and the folder (kept while the other kind is selected, so switching back restores
                // it).
                if let index = destinationField?.selectedIndex, destinationKinds.indices.contains(index) {
                    action.kind = destinationKinds[index]
                }
                action.folderPath = folderField?.stringValue ?? ""
            }
            var rule = existing ?? source
            rule.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.applies = DownloadRule.Applies.allCases[applies.selectedIndex]
            rule.handoffType = DownloadRule.HandoffType.allCases.indices.contains(handoff.selectedIndex)
                ? DownloadRule.HandoffType.allCases[handoff.selectedIndex]
                : source.handoffType
            rule.match = matchChoices.indices.contains(match.selectedIndex) ? matchChoices[match.selectedIndex] : source.match
            rule.pattern = pattern.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.isCaseSensitive = matchCase.isOn
            rule.runsInPrivateWindows = runsInPrivate.isOn
            rule.action = action
            return rule
        }

        /// Marks fields blocking Add: the pattern and the action's field. `all` also marks an empty name and pattern,
        /// for hover on the disabled button. One list drives markers, tooltips and the note so they agree.
        func markHeldUp(_ rule: DownloadRule?) {
            let held = rule.map { Self.heldUp($0, all: addHovered) } ?? []
            let notes = Dictionary(held.map { ($0.field, $0.note) }, uniquingKeysWith: { first, _ in first })
            // Every field this sheet can show.
            let fields: [HeldField: FilledField?] = [.name: name, .pattern: pattern, .action(.app): appField,
                                                     .action(.url): urlField, .action(.script): scriptField,
                                                     .action(.endpoint): endpointField, .action(.method): methodField,
                                                     .action(.folder): folderField]
            for (which, field) in fields {
                let note = notes[which]
                field?.isInvalid = note != nil
                field?.toolTip = note
            }
        }

        /// The disabled Add button's tooltip: the first problem, in form order.
        func heldUpNote() -> String? {
            ruleFromFields().flatMap { Self.heldUp($0, all: true).first?.note }
        }

        /// Valid when nothing blocks it, from the same list as the markers.
        func isValid(_ rule: DownloadRule) -> Bool { Self.heldUp(rule, all: true).isEmpty }

        let valid = {
            let rule = ruleFromFields()
            markHeldUp(rule)
            return rule.map(isValid) ?? false
        }
        applies.onSelect = { _ in sheetRef?.revalidate() }
        for picker in [stylePicker].compactMap({ $0 }) {
            picker.onSelect = { _ in sheetRef?.revalidate() }
        }
        // The match decides what the pattern field asks for and what its row is called.
        match.onSelect = { index in
            guard matchChoices.indices.contains(index) else { return }
            let chosen = matchChoices[index]
            pattern.placeholder = Self.patternPlaceholder(for: chosen)
            sheetRef?.setLabel(chosen == .fileType ? extensionsLabel : addressLabel, forRow: patternRow)
            sheetRef?.revalidate()
        }
        matchCase.onChange = { _ in sheetRef?.revalidate() }

        // Destinations get their own title and description.
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
            sheetMessage = String(localized: "The first rule that matches wins. Rules run from the top of the list.",
                                  comment: "Under the title of the sheet that makes a download rule.")
        }

        let sheet = FormSheet.show(in: host,
                                   title: sheetTitle,
                                   symbol: action.kind.symbol,
                                   message: sheetMessage,
                                   rows: rows,
                                   confirmTitle: existing == nil ? String(localized: "Add", comment: "Button of the sheet that makes a download rule.")
                                                                 : String(localized: "Save", comment: "Button of the sheet that changes a download rule."),
                                   canConfirm: valid) { confirmed in
            // Done either way; fields are read below.
            sheetRef = nil
            guard confirmed, var rule = ruleFromFields(), isValid(rule) else { return }
            // Sign-in goes to the Keychain, never the rules file: from the fields, or from an address typed with
            // `user:pass@`, which older rules and habit both produce.
            var credentials = (user: userField?.stringValue ?? "", password: passwordField?.stringValue ?? "")
            if let (clean, user, password) = HandoffSecrets.endpointWithoutCredentials(rule.action.rpcEndpoint) {
                rule.action.rpcEndpoint = clean
                // The fields win when both are filled in.
                if credentials.user.isEmpty, credentials.password.isEmpty { credentials = (user, password) }
            }
            if rule.action.kind == .jsonRPC {
                HandoffSecrets.setEndpointCredentials(credentials, for: rule.id, endpoint: rule.action.rpcEndpoint)
            }
            let save = {
                if let secret = secretField?.stringValue, action.kind == .jsonRPC { HandoffSecrets.setSecret(secret, for: rule.id) }
                if existing == nil {
                    let store = DownloadRulesStore.shared
                    store.add(rule, at: rule.action.kind.isDestination ? DownloadRulesStore.placeForNewFileType(in: store.rules) : nil)
                } else {
                    DownloadRulesStore.shared.update(rule)
                }
            }
            save()
        }
        sheetRef = sheet
        // Hovering the disabled Add button marks every blocking field and the tooltip names the first; leaving clears
        // them.
        sheet.onConfirmHover = { over in
            addHovered = over
            sheetRef?.revalidate()
        }
        sheet.heldUpNote = { heldUpNote() }
        // The folder only applies to Save: hide the row for Open, and restore it with its value.
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

    /// A field with a button beside it (a path and Choose…). Rows are laid out by frame and `NSStackView(views:)`
    /// disables autoresizing, so without this the stack sizes to its content and the button overflows the row unseen.
    /// The field shrinks; the button keeps its width.
    static func stack(_ field: NSView, _ button: NSView) -> NSStackView {
        let stack = NSStackView(views: [field, button])
        stack.orientation = .horizontal
        stack.spacing = Tokens.Space.x2
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // With equal compression resistance, a narrow row can't be resolved and the button overflows.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    /// What blocks Add, in form order: name, match, then the action's field. `all` adds an empty name and pattern, for
    /// hover on the disabled button; a bad regex always counts. Empty means valid.
    static func heldUp(_ rule: DownloadRule, all: Bool) -> [(field: HeldField, note: String)] {
        var held: [(field: HeldField, note: String)] = []
        // Destinations are named by their extensions.
        if all, rule.name.isEmpty, !rule.action.kind.isDestination {
            held.append((.name, String(localized: "Give the rule a name.", comment: "Tooltip on the name field of a download rule being added without one, so its Add button can't be pressed.")))
        }
        if rule.match == .fileType {
            // Commas with nothing between aren't extensions.
            if DownloadRule.Match.extensions(in: rule.pattern).isEmpty {
                if all || !rule.pattern.isEmpty {
                    held.append((.pattern, String(localized: "List the file extensions this rule catches, like pdf, epub.", comment: "Tooltip on the extensions field of a file-type rule that names none, so its Add button can't be pressed.")))
                }
            } else if rule.action.kind == .openFile, DownloadOpening.isRefused(pattern: rule.pattern) {
                held.append((.pattern, String(localized: "Apps, scripts, installers and archives are always saved, never opened.", comment: "Tooltip on the extensions field of a per-extension destination that Open refuses, so its Add button can't be pressed.")))
            }
        } else if rule.match != .any, rule.pattern.isEmpty {
            if all {
                held.append((.pattern, String(localized: "Type what this rule catches.", comment: "Tooltip on the address field of a download rule with no pattern yet, so its Add button can't be pressed.")))
            }
        } else if !rule.isValidPattern {
            held.append((.pattern, String(localized: "That isn’t a working regular expression. Zigzag saves nothing it can’t read.", comment: "Tooltip on the address field of a download rule whose regular expression doesn't compile.")))
        }
        if let action = actionHoldUp(rule.action) { held.append((.action(action.field), action.note)) }
        return held
    }

    /// Sheet fields that can carry a note.
    enum HeldField: Hashable {
        case name
        case pattern
        case action(ActionField)
    }

    /// An action field that blocks Add.
    enum ActionField: Hashable { case app, url, script, endpoint, method, folder }

    /// The action field still missing input and its note; nil when runnable. Outside the sheet so `isComplete` is
    /// tested for every kind, and a disabled Add always names the field. A scheme-less address (`bing.com`) has its own
    /// note.
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
            if action.folderPath.isEmpty {
                return (.folder, String(localized: "Choose the folder this type is saved into.", comment: "Tooltip on the folder field of a per-extension destination that saves files with no folder chosen, so its Add button is greyed."))
            }
            // A missing folder, or a file, would silently fall back to the downloads folder. Paths with tokens are
            // checked at download time.
            guard action.folderPath.contains("{") else {
                let path = (action.folderPath as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                return exists ? nil
                    : (.folder, String(localized: "That folder isn’t there. Choose one that is.", comment: "Tooltip on the folder field of a per-extension destination whose folder has gone or is a file, so its Add button is greyed."))
            }
            return nil
        case .openFile:
            return nil
        }
    }
}

/// Apps an Open App rule can use, by name: /Applications, /System/Applications (and Utilities), and ~/Applications, one
/// level deep, never inside bundles. Choose an App… covers the rest.
enum Applications {
    static func named() -> [(name: String, path: String)] {
        named(in: ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                   FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path])
    }

    /// For explicit folders, for tests.
    static func named(in folders: [String]) -> [(name: String, path: String)] {
        var seen = Set<String>()
        var found: [(name: String, path: String)] = []
        for folder in folders {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where item.hasSuffix(".app") {
                let path = (folder as NSString).appendingPathComponent(item)
                guard seen.insert(path).inserted else { continue }
                // Finder's localized name ("计算器" for Calculator.app), without .app.
                found.append((name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards]), path: path))
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The app icon at menu size.
    static func icon(_ path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
