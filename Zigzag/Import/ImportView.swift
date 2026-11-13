import AppKit
import UniformTypeIdentifiers

/// "Bring your stuff from another browser." Shown in the empty page on first launch, and in its own window
/// from Settings and the command bar. Pick browsers, pick what to bring, import; then a plain summary, and a
/// one-click fix for anything that couldn't come over.
final class ImportView: NSView {
    var onClose: (() -> Void)?

    /// First launch shows it as the right half of the welcome window (the brand panel on the left carries the
    /// titles); from Settings and the command bar it's its own window, under a header.
    enum Presentation { case welcome, window }
    let presentation: Presentation

    enum Stage { case choose, importing, done }
    private(set) var stage = Stage.choose {
        didSet {
            guard oldValue != stage else { return }
            // A row's Try Again waits while anything is importing.
            rows.forEach { $0.fixesEnabled = stage != .importing }
            onStageChange?(stage)
        }
    }
    /// The welcome window follows along, retitling its brand panel at each step.
    var onStageChange: ((Stage) -> Void)?
    private let showPasswords = TextButton(title: String(localized: "Show Passwords", comment: "Button in the Import window after passwords came over."), font: Tokens.Font.body(.medium))

    private let hero = ImportHero()
    private let banner = BrandBanner()
    private(set) var summaries: [ImportCoordinator.Summary] = []

    private let title = Label("", font: Tokens.Font.title(.semibold), color: Tokens.Color.textPrimary)
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private var sources: [ImportCoordinator.Source] = []
    private var rows: [SourceRow] = []
    /// The browsers scroll when there are more than fit, so the choices and Import stay in view.
    private let rowScroll = NSScrollView()
    private let rowList = FlippedView()
    private let choiceLabel = Label(String(localized: "Bring", comment: "Label in the Import window, before the choices of what to bring over: Passwords, Bookmarks…"), font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    private var choiceButtons: [(ImportCoordinator.Choice, ChoicePill)] = []
    /// With more than one profile: which one what's imported goes into. The profile of the space you're in, to begin with.
    private let intoLabel = Label(String(localized: "Into", comment: "Label in the Import window, with more than one profile, before the choice of the profile that what's imported goes into."), font: Tokens.Font.small(.medium), color: Tokens.Color.textSecondary)
    private let intoPicker = DropdownButton()
    private var intoProfile = WindowManager.shared.keyController?.tabManager.profile.id ?? Profile.defaultID
    /// The profiles as the choice lists them.
    private var intoIDs: [UUID] = []
    private var profilesToken: SignalToken?
    /// The profile it all goes into.
    private var target: Profile { Profiles.shared.profile(intoProfile) }
    private let chooseFile = TextButton(title: String(localized: "Choose File…", comment: "Button in the Import window: choose a passwords export or Safari export file."), font: Tokens.Font.body(.medium))
    private let primary = PrimaryButton(title: String(localized: "Import", comment: "Main button in the Import window."))
    private let secondary = TextButton(title: String(localized: "Not Now", comment: "Button in the Import window: close it without importing."), font: Tokens.Font.body(.medium))
    /// What Sign-ins means, in a line, while it's offered.
    private let signInsNote = NSTextField(wrappingLabelWithString: String(localized: "Sign-ins keep you signed in to your sites, so you don’t have to sign in again. They come from this Mac and stay on it.",
                                                                              comment: "Note under the choices in the Import window, explaining Sign-ins."))
    /// The note's lines: what Sign-ins are, and, with Firefox or Safari chosen too, that extensions come only from
    /// Chrome and its kin.
    private static let signInsText = String(localized: "Sign-ins keep you signed in to your sites, so you don’t have to sign in again. They come from this Mac and stay on it.",
                                            comment: "Note under the choices in the Import window, explaining Sign-ins.")
    private static let extensionsText = String(localized: "Extensions come from Chrome and browsers built on it. Firefox and Safari get theirs from stores of their own.",
                                               comment: "Note under the choices in the Import window, when Extensions is chosen along with Firefox or Safari.")
    /// The extensions coming over, under the browsers, once there are any.
    private let extensionsRow = ImportExtensionsRow()
    /// The one question before they're added, in place of the list while it's asked.
    private var review: ImportExtensionsReview?
    private var reviewAnswer: CheckedContinuation<Bool, Never>?
    private var importTask: Task<Void, Never>?
    private var extensionFailures: [ExtensionImport.Failure] = []
    /// With no other browser found: says so, and what can still come over from a file.
    private let emptyState = ImportEmptyState()
    /// Finds the browsers to list; a test hands in its own, so no run reads a real browser's folders.
    private let detect: @MainActor () -> [ImportCoordinator.Source]

    init(presentation: Presentation, detect: @escaping @MainActor () -> [ImportCoordinator.Source] = ImportCoordinator.detectedSources) {
        self.presentation = presentation
        self.detect = detect
        super.init(frame: .zero)
        wantsLayer = true
        switch presentation {
        case .welcome:
            title.stringValue = ""
            subtitle.stringValue = ""
            secondary.title = String(localized: "Skip", comment: "Button in the welcome window's import step: go on without importing.")
        case .window:
            title.stringValue = ""
            subtitle.stringValue = ""
            banner.title = String(localized: "Bring your stuff over", comment: "Title of the Import window.")
            // Words only: the ribbon stays the app's icon, not a decoration on a form.
            banner.ribbonMark.isHidden = true
            banner.subtitle = String(localized: "Passwords, bookmarks, history and extensions, from any browser on this Mac.", comment: "Subtitle of the Import window.")
            addSubview(banner)
        }
        subtitle.font = Tokens.Font.body()
        subtitle.textColor = Tokens.Color.textSecondary
        subtitle.isSelectable = false
        signInsNote.font = Tokens.Font.small()
        signInsNote.textColor = Tokens.Color.textSecondary
        signInsNote.isSelectable = false
        rowScroll.drawsBackground = false
        rowScroll.useSlimScroller()
        rowScroll.verticalScrollElasticity = .allowed
        rowScroll.horizontalScrollElasticity = .none
        rowScroll.contentView = FlippedClipView()
        rowScroll.contentView.drawsBackground = false
        rowScroll.documentView = rowList
        emptyState.isHidden = true
        [title, subtitle, emptyState, rowScroll, choiceLabel, signInsNote, intoLabel, intoPicker, chooseFile, primary, secondary].forEach { addSubview($0) }
        intoIDs = ProfileChoice.fill(intoPicker, selected: intoProfile)
        intoPicker.setAccessibilityLabel(intoLabel.stringValue)
        intoPicker.onSelect = { [weak self] index in
            guard let self, self.intoIDs.indices.contains(index) else { return }
            self.intoProfile = self.intoIDs[index]
            // What each browser has that this profile doesn't.
            self.rows.forEach { $0.loadPreview(in: self.target) }
        }
        // A profile made, renamed or removed while the window is open: the choice shows what there is now, and one
        // that's gone gives way to the first, where you can see it.
        profilesToken = Library.shared.changed.observe { [weak self] in
            guard let self else { return }
            let wasGone = Library.shared.directory.profile(self.intoProfile) == nil
            if wasGone { self.intoProfile = Profile.defaultID }
            self.intoIDs = ProfileChoice.fill(self.intoPicker, selected: self.intoProfile)
            if wasGone { self.rows.forEach { $0.loadPreview(in: self.target) } }
            self.needsLayout = true
        }
        // Sign-ins start on, as passwords do; the line under the choices says what they are.
        for (choice, name) in [(ImportCoordinator.Choice.passwords, String(localized: "Passwords", comment: "Choice in the Import window: bring passwords over.")),
                               (.bookmarks, String(localized: "Bookmarks", comment: "Choice in the Import window: bring bookmarks over.")),
                               (.history, String(localized: "History", comment: "Choice in the Import window: bring browsing history over.")),
                               (.tabs, String(localized: "Spaces and Pinned Tabs", comment: "Choice in the Import window: bring Arc's spaces, pinned tabs and favorites over.")),
                               (.openTabs, String(localized: "Open Tabs", comment: "Choice in the Import window: bring the tabs open in each of Arc's spaces over, not pinned ones.")),
                               (.signIns, String(localized: "Sign-ins", comment: "Choice in the Import window: bring over the sites you're signed in to.")),
                               (.extensions, String(localized: "Extensions", comment: "Choice in the Import window: bring extensions over from the Chrome Web Store."))] {
            let box = ChoicePill(title: name)
            box.tint = Brand.Theme.brand.accent
            box.onChange = { [weak self] _ in self?.choicesChanged() }
            addSubview(box)
            choiceButtons.append((choice, box))
        }
        chooseFile.onClick = { [weak self] _ in self?.pickFile() }
        showPasswords.showsFillAtRest = true
        showPasswords.isHidden = true
        showPasswords.onClick = { _ in PasswordsWindowController.show() }
        addSubview(showPasswords)
        primary.onClick = { [weak self] _ in self?.primaryAction() }
        secondary.onClick = { [weak self] _ in self?.secondaryAction() }
        reloadSources()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Lists the browsers found now. Again later (a browser installed while it's open), it starts the choice over.
    func reloadSources() {
        guard stage == .choose else { return }
        rows.forEach { $0.removeFromSuperview() }
        let found = detect()
        let suggested = ImportCoordinator.suggested(found)
        // The browser you use first and on; the rest start off so nothing comes over by surprise.
        sources = found.filter { suggested.contains($0.id) } + found.filter { !suggested.contains($0.id) }
        rows = sources.map { source in
            let row = SourceRow(source: source, countsExtensions: presentation == .window, profile: target)
            row.isChosen = suggested.contains(source.id)
            row.onToggle = { [weak self] in self?.choicesChanged() }
            rowList.addSubview(row)
            return row
        }
        choicesChanged()
        fitWindow()
    }

    /// Whether there are browsers to choose from and what to bring from them: not with none found, nor once importing.
    private var showsChoices: Bool { stage == .choose && !sources.isEmpty }
    var foundNone: Bool { sources.isEmpty }
    /// With no browser found, a file is the only way in, so choosing one is the main button.
    private var choosesFileFirst: Bool { stage == .choose && sources.isEmpty }

    @objc private func choicesChanged() {
        func anyChosen(offering choice: ImportCoordinator.Choice) -> Bool { rows.contains { $0.isChosen && $0.source.offers.contains(choice) } }
        // Safari's stay behind (they need Full Disk Access), so Sign-ins shows only for a browser that has them.
        let anySignIns = anyChosen(offering: .signIns)
        for (choice, pill) in choiceButtons {
            let offered: Bool
            switch choice {
            case .tabs, .openTabs: offered = anyChosen(offering: .tabs)
            // A browser whose Keychain item isn't known (Comet) brings no passwords; alone, it offers none.
            case .passwords: offered = !rows.contains(where: \.isChosen) || anyChosen(offering: .passwords)
            case .signIns: offered = anySignIns
            // Only in their own window: the welcome has a step of its own for extensions.
            case .extensions: offered = presentation == .window && anyChosen(offering: .extensions)
            default: offered = true
            }
            // With nothing to choose from, no choice shows at all: left showing, they drew with no frame, piled in
            // the window's corner.
            pill.isHidden = !showsChoices || !offered
        }
        choiceLabel.isHidden = !showsChoices
        let extensionsPill = choiceButtons.first { $0.0 == .extensions }?.1
        let otherStores = extensionsPill.map { !$0.isHidden && $0.isOn } == true && rows.contains { $0.isChosen && !$0.source.offers.contains(.extensions) }
        signInsNote.stringValue = [anySignIns ? Self.signInsText : nil, otherStores ? Self.extensionsText : nil].compactMap { $0 }.joined(separator: " ")
        emptyState.isHidden = !choosesFileFirst
        if stage == .choose {
            chooseFile.isHidden = choosesFileFirst
            primary.title = choosesFileFirst ? chooseFile.title : String(localized: "Import", comment: "Main button in the Import window.")
        }
        primary.isEnabled = stage != .choose || choosesFileFirst || (rows.contains(where: \.isChosen) && !chosenData.isEmpty)
        needsLayout = true
    }

    private var chosenData: ImportCoordinator.Choice {
        choiceButtons.reduce(into: []) { result, pair in if pair.1.isOn, !pair.1.isHidden { result.insert(pair.0) } }
    }

    private func primaryAction() {
        switch stage {
        case .choose: if choosesFileFirst { pickFile() } else { startImport(rows.filter(\.isChosen)) }
        case .importing: if review != nil { answerReview(true) }
        case .done: onClose?()
        }
    }

    /// Not Now, or Don't Add while the extensions are asked about.
    private func secondaryAction() {
        if review != nil { answerReview(false) } else { onClose?() }
    }

    // MARK: Importing

    /// `data`: what to bring; by default what's ticked, read before the choices are hidden (a hidden choice counts
    /// as not chosen).
    private func startImport(_ chosen: [SourceRow], data: ImportCoordinator.Choice? = nil) {
        guard !chosen.isEmpty else { return }
        let data = data ?? chosenData
        stage = .importing
        title.stringValue = String(localized: "Bringing it over…", comment: "Title of the Import window while importing.")
        // Only Chrome and its kin keep their passwords and sign-ins behind a Keychain item that macOS asks about.
        let fromChromium = chosen.contains { if case .chromium(let browser) = $0.source.kind { browser.safeStorage != nil } else { false } }
        let note: String
        switch (data.contains(.passwords), data.contains(.signIns)) {
        case (true, true): note = String(localized: "macOS will ask for your Mac’s password to open your passwords and sign-ins. Type it, then click Always Allow.",
                                            comment: "Import window while importing from Chrome or a browser like it. Always Allow is macOS's own button.")
        case (true, false): note = String(localized: "macOS will ask for your Mac’s password to open your passwords. Type it, then click Always Allow.",
                                             comment: "Import window while importing from Chrome or a browser like it. Always Allow is macOS's own button.")
        case (false, true): note = String(localized: "macOS will ask for your Mac’s password to open your sign-ins. Type it, then click Always Allow.",
                                             comment: "Import window while importing from Chrome or a browser like it. Always Allow is macOS's own button.")
        case (false, false): note = ""
        }
        subtitle.stringValue = fromChromium ? note : ""
        primary.title = String(localized: "Importing…", comment: "Main button in the Import window while importing.")
        primary.isEnabled = false
        secondary.isHidden = true
        chooseFile.isHidden = true
        choiceLabel.isHidden = true
        signInsNote.isHidden = true
        choiceButtons.forEach { $0.1.isHidden = true }
        rows.filter { !$0.isChosen }.forEach { $0.isHidden = true }
        chosen.forEach { $0.state = .waiting }
        needsLayout = true
        importTask = Task { @MainActor in
            for row in chosen { await run(row, data) }
            if data.contains(.extensions) { await importExtensions() }
            guard !Task.isCancelled else { return }
            finish()
        }
    }

    /// The window is going: an extension half-way stops there, and any downloaded but not added are thrown away.
    func stop() {
        importTask?.cancel()
        answerReview(false)
    }

    /// Every browser's extensions Zigzag doesn't have, once each: got ready one by one, asked about once, then added
    /// one at a time.
    private func importExtensions() async {
        let profile = target
        // Held while they're added, as while the rest came over, so the profile isn't removed under them.
        guard Profiles.shared.hold(profile.id) else { return }
        defer { Profiles.shared.done(profile.id) }
        let found = ChromiumExtensions.toAdd(summaries.flatMap(\.foundExtensions), installed: Set(profile.installs.installedIDs))
        for index in summaries.indices { summaries[index].foundExtensions = [] }
        guard !found.isEmpty else { return }
        rowList.addSubview(extensionsRow)
        extensionsRow.state = .preparing(0, of: found.count)
        needsLayout = true
        let steps = ExtensionImport.store(in: profile)
        let prepared = await ExtensionImport.prepare(found, with: steps) { [weak self] index in
            self?.extensionsRow.state = .preparing(index, of: found.count)
        }
        guard !Task.isCancelled else {
            prepared.ready.forEach { steps.discard($0.1) }
            return
        }
        var added: [(ChromiumExtensions.Found, String)] = []
        var failed = prepared.failed
        var declined = false
        if !prepared.ready.isEmpty {
            if await askToAdd(prepared.ready), !Task.isCancelled {
                let installed = await ExtensionImport.install(prepared.ready, with: steps) { [weak self] index, item in
                    // By the name it gives itself, as the question showed it.
                    let name = prepared.ready[index].1.extensionInfo.displayName ?? item.name
                    self?.extensionsRow.state = .adding(name, index, of: prepared.ready.count)
                }
                added = installed.added
                failed += installed.failed
            } else {
                prepared.ready.forEach { steps.discard($0.1) }
                declined = true
            }
        }
        guard !Task.isCancelled else { return }
        extensionFailures = failed
        extensionsRow.state = .finished(added: added.map(\.1), failed: failed, declined: declined)
        // Each browser's line counts what came from it.
        for (item, _) in added {
            guard let index = summaries.firstIndex(where: { $0.source == item.source }) else { continue }
            summaries[index].extensions += 1
        }
        for row in rows {
            if case .done = row.state, let summary = summaries.first(where: { $0.source == row.source.name }) { row.state = .done(summary) }
        }
        needsLayout = true
    }

    /// Asks once, in the window, before any extension is added.
    private func askToAdd(_ ready: [(ChromiumExtensions.Found, ExtensionStore.PreparedInstall)]) async -> Bool {
        let review = ImportExtensionsReview(ready)
        self.review = review
        rows.forEach { $0.isHidden = true }
        extensionsRow.isHidden = true
        rowList.addSubview(review)
        let names = Set(ready.map(\.0.source)).sorted()
        title.stringValue = ready.count == 1 ? String(localized: "Add 1 extension?", comment: "Title of the Import window when asking before adding the one extension found.")
                                             : String(localized: "Add \(ready.count) extensions?", comment: "Title of the Import window when asking before adding the extensions found: how many.")
        subtitle.stringValue = String(localized: "The ones you use in \(Words.list(names)), each downloaded from the Chrome Web Store and checked as if you added it here. You can turn any of them off in Settings › Extensions.",
                                      comment: "Import window, when asking before adding the extensions found. The placeholder is a browser's name, like Chrome, or a list of them.")
        primary.title = ready.count == 1 ? String(localized: "Add Extension", comment: "Button that adds the extension, in the sheet that asks first.")
                                         : String(localized: "Add \(ready.count) Extensions", comment: "Button in the Import window that adds the extensions found: how many.")
        primary.isEnabled = true
        secondary.title = String(localized: "Don’t Add", comment: "Button in the Import window: leave the extensions found behind.")
        secondary.isHidden = false
        needsLayout = true
        fitWindow()
        let answer = await withCheckedContinuation { reviewAnswer = $0 }
        review.removeFromSuperview()
        self.review = nil
        rows.forEach { $0.isHidden = !$0.isChosen }
        extensionsRow.isHidden = false
        title.stringValue = String(localized: "Bringing it over…", comment: "Title of the Import window while importing.")
        subtitle.stringValue = ""
        primary.title = String(localized: "Importing…", comment: "Main button in the Import window while importing.")
        primary.isEnabled = false
        secondary.isHidden = true
        needsLayout = true
        return answer
    }

    private func answerReview(_ add: Bool) {
        let answer = reviewAnswer
        reviewAnswer = nil
        answer?.resume(returning: add)
    }

    private func run(_ row: SourceRow, _ data: ImportCoordinator.Choice, primaryPassword: String = "") async {
        row.state = .working
        let choice = data.intersection(row.source.offers)
        var summary = await ImportCoordinator.run(row.source, choice, primaryPassword: primaryPassword, into: target)
        // Trying again brings the rest; what came the first time still counts.
        summary.extensions += summaries.first { $0.source == summary.source }?.extensions ?? 0
        summaries.removeAll { $0.source == summary.source }
        summaries.append(summary)
        row.state = .done(summary)
        row.onFix = { [weak self, weak row] fix, password in
            guard let self, let row else { return }
            self.fix(fix, for: row, data: data, primaryPassword: password)
        }
        needsLayout = true
    }

    private func finish() {
        stage = .done
        let passwords = summaries.map { $0.passwords + $0.updatedPasswords }.reduce(0, +)
        let signedIn = summaries.map(\.signedInSites).reduce(0, +)
        let fixable = summaries.contains { !$0.problems.isEmpty }
        let problems = fixable || !extensionFailures.isEmpty
        let broughtAny = summaries.contains(where: \.broughtAny)
        // Only "all set" when it is: with a problem, the title says how far it got and the rows below say why.
        title.stringValue = presentation == .welcome ? ""
            : !problems ? String(localized: "You’re all set", comment: "Title of the Import window when the import is done.")
            : broughtAny ? String(localized: "Not everything came over yet", comment: "Title of the Import window when some things came over and others hit a problem.")
            : String(localized: "Something got in the way", comment: "Title of the Import window when nothing came over because of a problem.")
        // In the welcome window the brand panel already says where everything went; here only the count and the
        // next step remain.
        subtitle.stringValue = presentation == .welcome ? ""
            : problems && !fixable ? String(localized: "What couldn’t come over is below.", comment: "Import window when some extensions couldn't be added, which the list below explains.")
            : problems ? (broughtAny ? String(localized: "What stopped the rest is below, with a way to fix it.",
                                              comment: "Import window when some things came over and others hit a problem, which the rows below explain.")
                                     : String(localized: "What stopped it is below, with a way to fix it.", comment: "Import window when nothing came over because of a problem."))
            : passwords > 0
            ? String(localized: "Your passwords are saved in Zigzag, in your Mac’s Keychain, and sync with iCloud Keychain. Find them in Zigzag › Passwords.",
                     comment: "Import window when the import is done. Zigzag › Passwords is the menu item's path; Keychain and iCloud Keychain are Apple's names.")
            : signedIn > 0 ? String(localized: "You’re signed in to your sites here too, and everything else is in your sidebar. You can bring more over anytime from Settings.",
                                    comment: "Import window when the import is done and sign-ins came over.")
            // Extensions are by the address, not in the sidebar.
            : summaries.allSatisfy({ $0.bookmarks + $0.history + $0.spaces == 0 }) && summaries.contains(where: { $0.extensions > 0 })
            ? String(localized: "Find your extensions in site controls, by the address. You can bring more over anytime from Settings.",
                     comment: "Import window when the import is done and only extensions came over. Site controls is the panel by the address.")
            : String(localized: "Everything that came over is in your sidebar. You can bring more over anytime from Settings.", comment: "Import window when the import is done.")
        // Rows that hit a problem stay, with their fix; the ones that went fine give way to the summary.
        if presentation == .welcome {
            for row in rows {
                if case .done(let summary) = row.state, !summary.problems.isEmpty { row.isHidden = false } else { row.isHidden = true }
            }
        }
        showPasswords.isHidden = passwords == 0
        // The finished moment: the lit surface, the count, and the ribbon writing itself across it.
        if hero.superview == nil { addSubview(hero) }
        banner.isHidden = true
        hero.showSuccess(summaries, somethingFailed: problems)
        primary.title = presentation == .welcome ? String(localized: "Start Browsing", comment: "Last button of the welcome window, after importing.")
                                                  : String(localized: "Done", comment: "Button that closes the Import window when the import is done.")
        fitWindow()
        primary.isEnabled = true
        needsLayout = true
    }

    /// In its own window, the window follows the content: shorter once only the summary is left.
    func fitWindow() {
        guard presentation == .window, let window else { return }
        layoutSubtreeIfNeeded()
        let bottom = subviews.filter { !$0.isHidden && $0.superview === self }.map(\.frame.maxY).max() ?? bounds.height
        let height = min(bottom + Tokens.Space.x6, 780)
        var frame = window.frame
        // Against the view's own height, as the window was first sized: it runs under the title bar, so the
        // layout rect (below it) fitted every later change a title bar too tall.
        let delta = height - bounds.height
        guard abs(delta) > 1 else { return }
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: window.isVisible && !Tokens.Motion.reduceMotion)
    }

    #if DEBUG
    /// For the debug bridge: the finished screen with sample numbers, without importing anything.
    func debugShowSuccess() {
        var arc = ImportCoordinator.Summary(source: "Arc")
        arc.passwords = 214
        arc.bookmarks = 86
        arc.spaces = 3
        summaries = [arc]
        rows.filter { !$0.isChosen }.forEach { $0.isHidden = true }
        [secondary, chooseFile, choiceLabel, signInsNote].forEach { $0.isHidden = true }
        choiceButtons.forEach { $0.1.isHidden = true }
        finish()
    }

    /// For the debug bridge: a choice ("Sign-ins") or a browser ("Chrome") turned on or off, and Import pressed,
    /// as clicks would.
    func debugChoose(_ name: String, on: Bool) {
        choiceButtons.first { $0.1.accessibilityLabel() == name }?.1.isOn = on
        rows.first { $0.source.name == name }?.isChosen = on
        choicesChanged()
    }

    func debugImport() { primaryAction() }
    func debugNotNow() { secondaryAction() }
    #endif

    private func fix(_ fix: ImportProblem.Fix, for row: SourceRow, data: ImportCoordinator.Choice, primaryPassword: String) {
        switch fix {
        case .retry, .primaryPassword:
            // One import at a time: while the others are still coming over, this one waits for them.
            guard stage != .importing else { return }
            stage = .importing
            primary.isEnabled = false
            var scope = data
            if case .done(let summary) = row.state { scope = ImportCoordinator.Choice.retrying(summary.problems, else: data) }
            // Extensions are asked about once, for every browser together: never again from one row's Try Again.
            scope.remove(.extensions)
            Task { @MainActor in
                await run(row, scope, primaryPassword: primaryPassword)
                finish()
            }
        case .fullDiskAccess:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
        case .exportFromApplePasswords:
            // Safari's own export holds its bookmarks and history; for passwords alone it's the Passwords app.
            // Firefox and its kin export from their own Passwords page.
            let bundleID: String = {
                switch row.source.kind {
                case .safari: SafariImporter.bundleID
                case .firefox(let browser): browser.bundleID
                case .orion: OrionImporter.bundleID
                default: "com.apple.Passwords"
                }
            }()
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
            pickFile()
        case .none:
            break
        }
    }

    /// A password CSV, or Safari's browsing data zip.
    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .zip]
        panel.message = String(localized: "Choose a password export (a .csv file) or Safari’s browsing data export (a .zip file).", comment: "Message of the open panel from the Import window's Choose File… button.")
        panel.prompt = String(localized: "Import", comment: "Main button in the Import window.")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let row = SourceRow(source: ImportCoordinator.fileSource(url))
            row.isChosen = true
            self.rowList.addSubview(row)
            self.rows.append(row)
            // A file you picked brings everything in it, whatever was ticked (and the ticks are hidden after an
            // import, so reading them would bring nothing).
            self.startImport([row], data: [.passwords, .bookmarks, .history])
            row.exportFile = url
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width: CGFloat = min(440, bounds.width - Tokens.Space.x8 * 2)
        let x = round((bounds.width - width) / 2)
        var y: CGFloat = 0
        func place(_ view: NSView, height: CGFloat, gap: CGFloat = 0) {
            view.frame = NSRect(x: x, y: y, width: width, height: height)
            y += height + gap
        }
        let subtitleHeight = ceil(subtitle.sizeThatFits(NSSize(width: width, height: 200)).height)
        var items: [any ImportListItem] = rows
        items.append(extensionsRow)
        if let review { items.append(review) }
        let visibleRows = items.filter { !$0.isHidden && $0.superview === rowList }
        let rowHeights: [CGFloat] = visibleRows.map { $0.preferredHeight(for: width) }
        let rowsHeight: CGFloat = rowHeights.reduce(0, +) + CGFloat(max(0, visibleRows.count - 1)) * Tokens.Space.x2
        let signInsShown = showsChoices && !signInsNote.stringValue.isEmpty
        let noteHeight: CGFloat = signInsShown ? Tokens.Space.x2 + ceil(signInsNote.sizeThatFits(NSSize(width: width, height: 200)).height) : 0
        // The choices wrap onto a second line when they don't fit one (Arc's Spaces and Tabs with Sign-ins).
        var pillLines = 1, used: CGFloat = 0
        for (_, box) in choiceButtons where !box.isHidden {
            if used > 0, used + box.fittingWidth > width { pillLines += 1; used = 0 }
            used += box.fittingWidth + Tokens.Space.x2
        }
        let pillsHeight = CGFloat(pillLines) * Tokens.Space.x8 + CGFloat(pillLines - 1) * Tokens.Space.x2
        let choicesHeight: CGFloat = showsChoices ? Tokens.Space.x4 + Tokens.Space.x2 + pillsHeight + noteHeight : 0
        // Where it goes is asked only once there's a choice, and only before importing.
        let showsInto = stage == .choose && Library.shared.hasManyProfiles
        let intoHeight: CGFloat = showsInto ? Tokens.Space.x4 + intoLabel.lineHeight + Tokens.Space.x2 + Tokens.Space.x8 : 0
        let emptyHeight: CGFloat = choosesFileFirst ? emptyState.preferredHeight(for: width) + Tokens.Space.x4 : 0
        let showsHero = hero.superview != nil
        let heroHeight: CGFloat = showsHero ? ImportHero.height + Tokens.Space.x8 : 0
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let total = heroHeight + titleHeight + Tokens.Space.x2 + subtitleHeight + Tokens.Space.x6 + rowsHeight + emptyHeight
            + (showsChoices ? Tokens.Space.x6 + choicesHeight : 0) + intoHeight + Tokens.Space.x8 + Tokens.Space.x8
        if presentation == .window {
            banner.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 128)
            banner.contentInset = x
            y = (banner.isHidden ? Tokens.Space.x12 : banner.frame.maxY + Tokens.Space.x6)
        } else {
            y = max(Tokens.Space.x16, round((bounds.height - total) / 2))
        }
        if showsHero {
            hero.frame = NSRect(x: x, y: y, width: width, height: ImportHero.height)
            y = hero.frame.maxY + Tokens.Space.x6
        }
        title.alignment = .left
        title.attributedStringValue = Brand.display(title.stringValue, size: Tokens.TypeSize.display, color: Tokens.Color.textPrimary)
        // What isn't placed is hidden, so nothing is left drawing where it last was, or in the corner.
        title.isHidden = title.stringValue.isEmpty
        subtitle.isHidden = subtitle.stringValue.isEmpty
        if !title.isHidden { place(title, height: titleHeight, gap: Tokens.Space.x2) }
        if !subtitle.isHidden { place(subtitle, height: subtitleHeight, gap: Tokens.Space.x6) }
        emptyState.isHidden = emptyHeight == 0
        if emptyHeight > 0 { place(emptyState, height: emptyHeight - Tokens.Space.x4, gap: Tokens.Space.x4) }
        // The rows get what's left once everything else fits: in their own window, as tall as the screen allows.
        let limit: CGFloat
        if presentation == .window {
            let screen = window?.screen?.visibleFrame.height ?? 900
            limit = min(780, screen - 60) - (window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 28)
        } else {
            limit = bounds.height
        }
        let fixed = (presentation == .window ? 128 + Tokens.Space.x6 : Tokens.Space.x16 * 2) + heroHeight + (title.stringValue.isEmpty ? 0 : titleHeight + Tokens.Space.x2)
            + (subtitle.stringValue.isEmpty ? 0 : subtitleHeight + Tokens.Space.x6) + emptyHeight
            + (showsChoices ? Tokens.Space.x6 + choicesHeight : 0) + intoHeight + Tokens.Space.x8 * 2 + Tokens.Space.x6
        let listHeight = max(120, min(rowsHeight, limit - fixed))
        var ry: CGFloat = 0
        for (row, height) in zip(visibleRows, rowHeights) {
            row.frame = NSRect(x: 0, y: ry, width: width, height: height)
            ry += height + Tokens.Space.x2
        }
        rowList.frame = NSRect(x: 0, y: 0, width: width, height: rowsHeight)
        rowScroll.isHidden = visibleRows.isEmpty
        if !visibleRows.isEmpty { place(rowScroll, height: rowsHeight > listHeight ? listHeight : rowsHeight, gap: Tokens.Space.x2) }
        if showsChoices {
            y += Tokens.Space.x4
            place(choiceLabel, height: choiceLabel.lineHeight, gap: Tokens.Space.x2)
            var cx = x
            for (_, box) in choiceButtons where !box.isHidden {
                let w = box.fittingWidth
                if cx + w > x + width { cx = x; y += Tokens.Space.x8 + Tokens.Space.x2 }
                box.frame = NSRect(x: cx, y: y, width: w, height: Tokens.Space.x8)
                cx += w + Tokens.Space.x2
            }
            y += Tokens.Space.x8
            signInsNote.isHidden = !signInsShown
            if signInsShown {
                y += Tokens.Space.x2
                place(signInsNote, height: noteHeight - Tokens.Space.x2)
            }
        } else {
            signInsNote.isHidden = true
        }
        intoLabel.isHidden = !showsInto
        intoPicker.isHidden = !showsInto
        if showsInto {
            y += Tokens.Space.x4
            place(intoLabel, height: intoLabel.lineHeight, gap: Tokens.Space.x2)
            intoPicker.frame = NSRect(x: x, y: y, width: min(intoPicker.intrinsicContentSize.width, width), height: Tokens.Space.x8)
            y += Tokens.Space.x8
        }
        y += Tokens.Space.x8
        let buttonHeight = Tokens.Space.x8
        let pw = max(primary.fittingWidth, 96)
        primary.frame = NSRect(x: x + width - pw, y: y, width: pw, height: buttonHeight)
        if !secondary.isHidden {
            let sw = secondary.fittingWidth
            secondary.frame = NSRect(x: primary.frame.minX - Tokens.Space.x2 - sw, y: y, width: sw, height: buttonHeight)
        }
        if !showPasswords.isHidden {
            let w = showPasswords.fittingWidth + Tokens.Space.x2
            showPasswords.frame = NSRect(x: primary.frame.minX - Tokens.Space.x2 - w, y: y, width: w, height: buttonHeight)
        }
        if !chooseFile.isHidden {
            chooseFile.frame = NSRect(x: x - Tokens.Space.x2, y: y, width: chooseFile.fittingWidth, height: buttonHeight)
        }
    }
}

/// One browser (or a chosen file): its real icon, its name, and as the import runs, what came over.
private final class SourceRow: InteractiveView, ImportListItem {
    enum State { case idle, waiting, working, done(ImportCoordinator.Summary) }

    let source: ImportCoordinator.Source
    /// Whether its line counts the extensions it would bring.
    private let countsExtensions: Bool
    var onToggle: (() -> Void)?
    var onFix: ((ImportProblem.Fix, String) -> Void)?
    /// Off while an import runs: the fixes that import again wait for it.
    var fixesEnabled = true { didSet { fixViews.forEach { ($0 as? TextButton)?.isEnabled = fixesEnabled || !importsAgain($0) } } }
    private var importButtons: [ObjectIdentifier] = []
    private func importsAgain(_ view: NSView) -> Bool { importButtons.contains(ObjectIdentifier(view)) }
    /// A chosen export: once its passwords are in, offer to move it to the Trash, since it holds them unprotected.
    var exportFile: URL?

    var isChosen = false { didSet { stateDidChange(animated: true); refresh() } }
    override func accessibilityValue() -> Any? { isChosen ? 1 : 0 }
    var state = State.idle { didSet { refresh() } }

    private let icon = NSImageView()
    private let name: Label
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let check = NSImageView()
    private let spinner = RibbonView()
    private var fixViews: [NSView] = []
    private var passwordField: FilledField?
    /// What the browser holds, filled in once counted.
    private var preview = String(localized: "Looking…", comment: "Under a browser's name in the Import window while counting what it holds.") { didSet { refresh() } }

    init(source: ImportCoordinator.Source, countsExtensions: Bool = false, profile: Profile? = nil) {
        self.source = source
        self.countsExtensions = countsExtensions
        name = Label(source.name, font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.group
        layer?.cornerCurve = .continuous
        icon.image = source.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        detail.font = Tokens.Font.small()
        detail.textColor = Tokens.Color.textSecondary
        detail.isSelectable = false
        spinner.color = Brand.Theme.brand.accent
        spinner.isHidden = true
        check.isHidden = true
        [icon, name, detail, check, spinner].forEach { addSubview($0) }
        onClick = { [weak self] _ in
            guard let self, case .idle = self.state else { return }
            self.isChosen.toggle()
            self.onToggle?()
        }
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(source.name)
        refresh()
        loadPreview(in: profile)
    }

    /// What it holds, in a line. `profile`: the one its extensions are counted against (left out, the first).
    func loadPreview(in profile: Profile?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.preview = await ImportCoordinator.preview(self.source, extensions: self.countsExtensions, in: profile)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Measured at the width the row will really have, so nothing is cut off.
    func preferredHeight(for width: CGFloat) -> CGFloat {
        let base = Tokens.Space.x12 + Tokens.Space.x2
        let textWidth = width - textX - Tokens.Space.x3 - Tokens.Space.x8
        let detailHeight = detail.stringValue.isEmpty ? 0 : ceil(detail.sizeThatFits(NSSize(width: textWidth, height: 400)).height)
        let lines = fixLines(for: width - textX - Tokens.Space.x3).count
        let fixes = lines == 0 ? 0 : CGFloat(lines) * (Tokens.Space.x8 + Tokens.Space.x2)
        return max(base, Tokens.Space.x3 + name.lineHeight + 2 + detailHeight + Tokens.Space.x3 + fixes)
    }

    private var textX: CGFloat { Tokens.Space.x3 + Tokens.Space.x8 + Tokens.Space.x3 }

    private func fixWidth(_ view: NSView) -> CGFloat { view is FilledField ? 180 : ((view as? TextButton)?.fittingWidth ?? 80) }

    /// The fix buttons, wrapped onto as many lines as the row's width needs.
    private func fixLines(for width: CGFloat) -> [[NSView]] {
        var lines: [[NSView]] = [], line: [NSView] = [], used: CGFloat = 0
        for view in fixViews {
            let w = fixWidth(view)
            if !line.isEmpty, used + w > width { lines.append(line); line = []; used = 0 }
            line.append(view)
            used += w + Tokens.Space.x2
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    private func refresh() {
        fixViews.forEach { $0.removeFromSuperview() }
        fixViews = []
        importButtons = []
        passwordField = nil
        spinner.stopLooping()
        spinner.isHidden = true
        check.isHidden = true
        switch state {
        case .idle:
            detail.stringValue = preview
            check.isHidden = !isChosen
            check.image = Tokens.Symbol.image("checkmark.circle.fill", size: Tokens.TypeSize.title)
            check.contentTintColor = Brand.Theme.brand.accent
        case .waiting:
            detail.stringValue = String(localized: "Waiting…", comment: "Under a browser's name in the Import window, while another browser is imported first.")
        case .working:
            detail.stringValue = String(localized: "Bringing it over…", comment: "Under a browser's name in the Import window while importing from it.")
            spinner.isHidden = false
            spinner.startLooping()
        case .done(let summary):
            detail.stringValue = ([summary.sentence] + summary.problems.map(\.message) + summary.notes).joined(separator: "\n")
            check.isHidden = false
            let clean = summary.problems.isEmpty
            check.image = Tokens.Symbol.image(clean ? "checkmark.circle.fill" : "exclamationmark.circle.fill", size: Tokens.TypeSize.title)
            check.contentTintColor = clean ? Tokens.Color.success : Tokens.Color.warning
            for problem in summary.problems { addFix(problem.fix) }
            if let exportFile, summary.passwords + summary.updatedPasswords > 0, FileManager.default.fileExists(atPath: exportFile.path) {
                detail.stringValue += "\n" + String(localized: "The file still holds your passwords unprotected. It’s safer to move it to the Trash.",
                                                     comment: "Import window, after passwords came over from an exported file.")
                let button = TextButton(title: String(localized: "Move to Trash", comment: "Button in the Import window: move the exported passwords file to the Trash."), font: Tokens.Font.body(.medium))
                button.showsFillAtRest = true
                button.onClick = { [weak self, weak button] _ in
                    NSWorkspace.shared.recycle([exportFile]) { _, error in
                        DispatchQueue.main.async {
                            if error == nil {
                                button?.title = String(localized: "Moved to Trash", comment: "The Move to Trash button in the Import window, once the file is in the Trash.")
                                button?.isEnabled = false
                            } else {
                                // Not a dead end: say so, and take you to the file to delete it yourself.
                                self?.detail.stringValue += "\n" + String(localized: "Zigzag couldn’t move it to the Trash. Show it in Finder and delete it there.",
                                                                                     comment: "Import window, when the exported passwords file couldn't be moved to the Trash.")
                                button?.title = String(localized: "Show in Finder", comment: "Button in the Import window: show the exported passwords file in Finder.")
                                button?.onClick = { _ in NSWorkspace.shared.activateFileViewerSelecting([exportFile]) }
                            }
                            self?.needsLayout = true
                        }
                    }
                }
                addSubview(button)
                fixViews.append(button)
            }
        }
        superview?.needsLayout = true
        needsLayout = true
    }

    private func addFix(_ fix: ImportProblem.Fix) {
        let title: String
        switch fix {
        case .retry: title = String(localized: "Try Again", comment: "Button under a problem in the Import window.")
        case .fullDiskAccess: title = String(localized: "Open System Settings", comment: "Button under a problem in the Import window. System Settings is macOS's app.")
        // Named for the app it opens to export from, so it says what happens.
        case .exportFromApplePasswords:
            switch source.kind {
            case .safari: title = String(localized: "Open Safari", comment: "Button under a note in the Import window: open Safari to export from it.")
            case .firefox(let browser): title = String(localized: "Open \(browser.name)", comment: "Button under a problem in the Import window: open a browser, like Firefox, to export from it.")
            case .orion: title = String(localized: "Open \(OrionImporter.name)", comment: "Button under a problem in the Import window: open a browser, like Firefox, to export from it.")
            default: title = String(localized: "Open Passwords", comment: "Button under a note in the Import window: open Apple's Passwords app to export from it.")
            }
        case .primaryPassword: title = String(localized: "Unlock", comment: "Button in the Import window after typing Firefox's primary password.")
        case .none: return
        }
        guard !fixViews.contains(where: { ($0 as? TextButton)?.title == title }) else { return }
        if fix == .primaryPassword {
            let field = FilledField(placeholder: String(localized: "Primary password", comment: "Placeholder of the field for Firefox's primary password, in the Import window."), secure: true)
            addSubview(field)
            fixViews.append(field)
            passwordField = field
        }
        let button = TextButton(title: title, font: Tokens.Font.body(.medium))
        button.showsFillAtRest = true
        if fix == .retry || fix == .primaryPassword {
            importButtons.append(ObjectIdentifier(button))
            button.isEnabled = fixesEnabled
        }
        button.onClick = { [weak self] _ in
            guard let self, self.fixesEnabled || !(fix == .retry || fix == .primaryPassword) else { return }
            self.onFix?(fix, self.passwordField?.stringValue ?? "")
            self.passwordField?.stringValue = ""
        }
        addSubview(button)
        fixViews.append(button)
    }

    override func layout() {
        super.layout()
        let pad = Tokens.Space.x3
        let side = Tokens.Space.x8
        icon.frame = NSRect(x: pad, y: pad, width: side, height: side)
        let textX = icon.frame.maxX + Tokens.Space.x3
        let textWidth = bounds.width - textX - pad - Tokens.Space.x8
        name.frame = NSRect(x: textX, y: pad, width: textWidth, height: name.lineHeight)
        let detailHeight = ceil(detail.sizeThatFits(NSSize(width: textWidth, height: 400)).height)
        detail.preferredMaxLayoutWidth = textWidth
        detail.frame = NSRect(x: textX, y: name.frame.maxY + 2, width: textWidth, height: detailHeight)
        let indicator = NSRect(x: bounds.width - pad - Tokens.Space.x5, y: pad + (side - Tokens.Space.x5) / 2, width: Tokens.Space.x5, height: Tokens.Space.x5)
        check.frame = indicator
        spinner.frame = indicator.insetBy(dx: 2, dy: 2)
        var fy = detail.frame.maxY + Tokens.Space.x2
        for line in fixLines(for: bounds.width - textX - Tokens.Space.x3) {
            var fx = textX
            for view in line {
                let w = fixWidth(view)
                view.frame = NSRect(x: fx, y: fy, width: w, height: Tokens.Space.x8)
                fx += w + Tokens.Space.x2
            }
            fy += Tokens.Space.x8 + Tokens.Space.x2
        }
    }

    override func stateDidChange(animated: Bool) {
        // The chosen browser on a soft wash of the accent, as the address bar marks its choice; no outline.
        let accent = Brand.Theme.for(self).accent
        let fill: NSColor? = isChosen ? accent.withAlphaComponent(isHovered ? 0.22 : 0.16) : isHovered ? Tokens.Color.hoverFill : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated)
        layer?.borderWidth = 0
    }
}

/// The import screen in its own window, from Settings and the command bar.
final class ImportWindowController: NSWindowController, NSWindowDelegate {
    static var shared: ImportWindowController?

    static func show() {
        if let shared {
            // A finished import left open behind the browser starts over when asked for again: brought back as it
            // was, it showed the last result as if it had just imported, and its Done imported nothing (a space
            // deleted since stayed gone).
            guard Self.startsOver((shared.window?.contentView as? ImportView)?.stage) else { shared.window?.makeKeyAndOrderFront(nil); return }
            shared.window?.close()
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.title = String(localized: "Import", comment: "Title of the Import window.")
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = Tokens.Color.formBackground
        let view = ImportView(presentation: .window)
        view.frame = window.contentLayoutRect
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        let controller = ImportWindowController(window: window)
        view.onClose = { [weak window] in window?.close() }
        window.delegate = controller
        view.frame.size.width = 560
        view.needsLayout = true
        // Laid out once tall, so the content's real height can be measured, then fitted.
        view.frame.size.height = 2000
        view.layoutSubtreeIfNeeded()
        let height = view.subviews.filter { !$0.isHidden }.map(\.frame.maxY).max().map { $0 + Tokens.Space.x6 } ?? 560
        window.setContentSize(NSSize(width: 560, height: min(height, 780)))
        window.center()
        shared = controller
        controller.showWindow(nil)
    }

    /// Whether the Import window, asked for again, opens afresh: once its import is done. Choosing or importing,
    /// it comes forward as it is.
    static func startsOver(_ stage: ImportView.Stage?) -> Bool { stage == .done }

    /// With none found, coming back to it looks again: a browser installed meanwhile shows up.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let view = window?.contentView as? ImportView, view.foundNone else { return }
        view.reloadSources()
    }

    func windowWillClose(_ notification: Notification) {
        (window?.contentView as? ImportView)?.stop()
        Self.shared = nil
    }
}

/// The brand moment above the import: the wordmark on the lit surface on first launch, and the count of what
/// came over when it's done.
private final class ImportHero: NSView {
    static let height: CGFloat = 168
    private let surface = BrandSurface()
    private let wordmark = WordmarkView()
    private let count = Label("", font: Brand.displayFont(Tokens.Welcome.countSize), color: Brand.ribbon)
    private let caption = Label("", font: Tokens.Font.title(.semibold), color: Brand.ribbon)
    private let detail = Label("", font: Tokens.Font.body(), color: Brand.ribbon.withAlphaComponent(0.7))

    override init(frame: NSRect) {
        super.init(frame: frame)
        [surface, wordmark, count, caption, detail].forEach { addSubview($0) }
        [count, caption, detail].forEach { $0.isHidden = true }
        // A long name or a longer language wraps rather than ending in "…"; layout makes room for it.
        for label in [caption, detail] {
            label.usesSingleLineMode = false
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
        }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var theme: Brand.Theme { Brand.Theme.brand }

    private func applyTheme() {
        wordmark.color = theme.tint
        caption.textColor = theme.tint
        detail.textColor = theme.tint.withAlphaComponent(0.7)
    }

    /// The big line, in a face of its own size: the label lays out its line by its font, so a smaller text set
    /// over the larger face would sit low and run into the caption.
    private func setCount(_ text: String, size: CGFloat) {
        count.font = Brand.displayFont(size)
        count.attributedStringValue = Brand.display(text, size: size, color: theme.tint)
    }

    /// `somethingFailed`: a browser's problem, or an extension that couldn't be added.
    func showSuccess(_ summaries: [ImportCoordinator.Summary], somethingFailed: Bool) {
        applyTheme()
        let passwords = summaries.map { $0.passwords + $0.updatedPasswords }.reduce(0, +)
        let bookmarks = summaries.map(\.bookmarks).reduce(0, +)
        let spaces = summaries.map(\.spaces).reduce(0, +)
        let history = summaries.map(\.history).reduce(0, +)
        let signedIn = summaries.map(\.signedInSites).reduce(0, +)
        let extensions = summaries.map(\.extensions).reduce(0, +)
        // The biggest thing that came over leads, its number large and what it counts under it; the rest follow in a line.
        let kinds: [(n: Int, unit: (Int) -> String, phrase: (Int) -> String)] = [
            (passwords, { $0 == 1 ? String(localized: "import.lead.passwords.one", defaultValue: "password",
                                           comment: "Under the big number when an import finishes, which is 1, so without the number.")
                                 : String(localized: "import.lead.passwords", defaultValue: "passwords",
                                          comment: "Under the big number when an import finishes, so without the number. Several, never 1.") },
             { String(localized: "\($0) passwords", comment: "Item in a list of what a browser holds or what came over, in the Import window.") }),
            (bookmarks, { $0 == 1 ? String(localized: "import.lead.bookmarks.one", defaultValue: "bookmark",
                                           comment: "Under the big number when an import finishes, which is 1, so without the number.")
                                 : String(localized: "import.lead.bookmarks", defaultValue: "bookmarks",
                                          comment: "Under the big number when an import finishes, so without the number. Several, never 1.") },
             { String(localized: "\($0) bookmarks", comment: "Item in a list of what a browser holds or what came over, in the Import window.") }),
            (spaces, { $0 == 1 ? String(localized: "import.lead.spaces.one", defaultValue: "space",
                                        comment: "Under the big number when an import finishes, which is 1, so without the number.")
                              : String(localized: "import.lead.spaces", defaultValue: "spaces",
                                       comment: "Under the big number when an import finishes, so without the number. Several, never 1.") },
             { String(localized: "\($0) spaces", comment: "Item in the list of what came over, in the Import window.") }),
            (signedIn, { $0 == 1 ? String(localized: "import.lead.sites-with-sign-ins.one", defaultValue: "site with sign-ins",
                                          comment: "Under the big number when an import finishes, which is 1, so without the number.")
                                : String(localized: "import.lead.sites-with-sign-ins", defaultValue: "sites with sign-ins",
                                         comment: "Under the big number when an import finishes, so without the number. Several, never 1.") },
             { String(localized: "\($0) sites with sign-ins", comment: "Item in the list of what came over, in the Import window.") }),
            (history, { $0 == 1 ? String(localized: "import.lead.pages-of-history.one", defaultValue: "page of history",
                                         comment: "Under the big number when an import finishes, which is 1, so without the number.")
                               : String(localized: "import.lead.pages-of-history", defaultValue: "pages of history",
                                        comment: "Under the big number when an import finishes, so without the number. Several, never 1.") },
             { String(localized: "\($0) pages of history", comment: "Item in the list of what came over, in the Import window.") }),
            (extensions, { $0 == 1 ? String(localized: "import.lead.extensions.one", defaultValue: "extension",
                                            comment: "Under the big number when an import finishes, which is 1, so without the number.")
                                  : String(localized: "import.lead.extensions", defaultValue: "extensions",
                                           comment: "Under the big number when an import finishes, so without the number. Several, never 1.") },
             { String(localized: "\($0) extensions", comment: "Item in a list of what a browser holds or what came over, in the Import window.") }),
        ]
        var lead: (Int, String)?
        var rest: [String] = []
        for kind in kinds where kind.n > 0 {
            if lead == nil {
                let unit = kind.unit(kind.n)
                lead = (kind.n, summaries.count == 1
                    ? String(localized: "\(unit) from \(summaries[0].source)",
                             comment: "Under the big number when an import finishes: what it counts, then a browser's name, like “passwords from Arc”.")
                    : unit)
            } else {
                rest.append(kind.phrase(kind.n))
            }
        }
        wordmark.isHidden = true
        [count, caption, detail].forEach { $0.isHidden = false }
        if let lead {
            caption.stringValue = lead.1
            detail.stringValue = rest.isEmpty ? "" : String(localized: "Plus \(Words.list(rest)).", comment: "Under the big number when an import finishes: the rest of what came over, like “Plus 86 bookmarks and 3 spaces.”")
            setCount(lead.0.formatted(), size: Tokens.Welcome.countSize)
        } else if somethingFailed || summaries.contains(where: { !$0.problems.isEmpty }) {
            // Never a cheerful "all set" over a failure: say nothing came; the window's own lines say why.
            setCount(String(localized: "Not yet", comment: "Shown large when an import finishes and nothing came over because of a problem."), size: 44)
            caption.stringValue = String(localized: "Nothing came over", comment: "Under “Not yet” when an import finishes with a problem.")
            detail.stringValue = ""
        } else {
            setCount(String(localized: "All set", comment: "Shown large when an import finishes and everything was already in Zigzag."), size: 44)
            caption.stringValue = String(localized: "Nothing new to bring over", comment: "Under “All set” when an import finishes and everything was already in Zigzag.")
            detail.stringValue = String(localized: "Everything was already here.", comment: "Under “All set” when an import finishes and everything was already in Zigzag.")
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        // The panel arrives, its lines a beat apart, then the ribbon writes itself across it.
        Brand.enter([surface, count, caption, detail])
        surface.watermark.drawIn(delay: 0.2)
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let pad = Tokens.Space.x8
        let wordmarkHeight: CGFloat = 44
        wordmark.frame = NSRect(x: pad, y: (bounds.height - wordmarkHeight) / 2, width: wordmarkHeight * WordmarkView.aspect, height: wordmarkHeight)
        // Measured from the text itself: the label's own size can lag a change of text.
        let countHeight = ceil(count.attributedStringValue.size().height)
        let textWidth = bounds.width * 0.62
        func height(_ label: Label) -> CGFloat { ceil(label.sizeThatFits(NSSize(width: textWidth, height: 200)).height) }
        let captionHeight = height(caption)
        let detailHeight = detail.stringValue.isEmpty ? 0 : height(detail)
        let total = countHeight + captionHeight + (detailHeight > 0 ? 4 + detailHeight : 0)
        var y = max(0, (bounds.height - total) / 2)
        count.frame = NSRect(x: pad - 3, y: y, width: textWidth, height: countHeight)
        y = count.frame.maxY
        caption.frame = NSRect(x: pad, y: y, width: textWidth, height: captionHeight)
        y = caption.frame.maxY + 4
        detail.frame = NSRect(x: pad, y: y, width: textWidth, height: detailHeight)
    }
}

/// No other browser on this Mac: said plainly, on a faint panel where the browsers would be, with what can still
/// come over from a file.
final class ImportEmptyState: NSView {
    private let heading = NSTextField(wrappingLabelWithString: String(localized: "No other browsers found on this Mac", comment: "Import window, when no other browser was found."))
    private let note = NSTextField(wrappingLabelWithString: String(localized: "You can still bring passwords from an exported .csv file, or bookmarks and history from Safari’s export (a .zip file).",
                                                                   comment: "Import window, under “No other browsers found on this Mac”: what can still come over from a file."))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.group
        layer?.cornerCurve = .continuous
        heading.font = Tokens.Font.body(.medium)
        heading.textColor = Tokens.Color.textPrimary
        note.font = Tokens.Font.body()
        note.textColor = Tokens.Color.textSecondary
        for label in [heading, note] {
            label.isSelectable = false
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = cgColor(Tokens.Color.chromeFill)
    }

    private var pad: CGFloat { Tokens.Space.x4 }

    private func heights(for width: CGFloat) -> (heading: CGFloat, note: CGFloat) {
        let text = NSSize(width: max(0, width - pad * 2), height: 400)
        return (ceil(heading.sizeThatFits(text).height), ceil(note.sizeThatFits(text).height))
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let h = heights(for: width)
        return pad + h.heading + Tokens.Space.x1 + h.note + pad
    }

    override func layout() {
        super.layout()
        let h = heights(for: bounds.width)
        let textWidth = max(0, bounds.width - pad * 2)
        for label in [heading, note] { label.preferredMaxLayoutWidth = textWidth }
        heading.frame = NSRect(x: pad, y: pad, width: textWidth, height: h.heading)
        note.frame = NSRect(x: pad, y: heading.frame.maxY + Tokens.Space.x1, width: textWidth, height: h.note)
    }
}
