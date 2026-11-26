import AppKit

/// New Live Folder… and a live folder's Edit…: a feed or site address, or a GitHub list for a username, a name, and
/// how many pages it shows. Typing an address looks for its feed, and the name follows the feed's until you edit it.
enum LiveFolderSheet {
    #if DEBUG
    private(set) static weak var current: FormSheet?
    #endif

    static var newTitle: String { String(localized: "New Live Folder…", comment: "Item in the menu of the sidebar's +, its empty space, a space's menu and a folder's menu: a folder that fills itself from a feed or GitHub.") }
    /// The live folder's mark on its menu items and sheet.
    static let symbol = "dot.radiowaves.up.forward"

    /// The site's icon a live folder wears (GitHub's for a GitHub list), fetched when it isn't kept yet.
    static func siteIcon(for source: LiveSource) -> NSImage? {
        guard let site = source.iconSite else { return nil }
        let icon = FaviconStore.shared.cachedIcon(for: site)
        if icon == nil { FaviconStore.shared.prefetch(for: site) }
        return icon
    }

    /// What's typed, as a web address: "example.com" is https, a feed: address is its https one.
    nonisolated static func address(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if text.lowercased().hasPrefix("feed:") {
            text = String(text.dropFirst(5))
            if text.hasPrefix("//") { text = "https:" + text }
        }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty, host.contains(".") || host == "localhost" || url.port != nil else { return nil }
        return url
    }

    static func listTitle(_ list: GitHubList) -> String {
        switch list {
        case .pullRequests: String(localized: "Pull Requests Opened", comment: "A GitHub list a live folder can follow: the open pull requests someone made.")
        case .issues: String(localized: "Issues Assigned", comment: "A GitHub list a live folder can follow: the open issues assigned to someone.")
        case .reviewRequests: String(localized: "Review Requests", comment: "A GitHub list a live folder can follow: the open pull requests someone is asked to review.")
        case .repositoryIssues: String(localized: "Issues in Owned Repositories", comment: "A GitHub list a live folder can follow: the open issues in the repositories someone owns, whoever opened them.")
        case .repositoryPullRequests: String(localized: "Pull Requests in Owned Repositories", comment: "A GitHub list a live folder can follow: the open pull requests in the repositories someone owns, whoever opened them.")
        }
    }

    static func limitTitle(_ count: Int) -> String {
        String(localized: "Latest \(count)", comment: "Choice of how many pages a live folder shows, in its sheet: the newest 10, 25 or 50.")
    }

    /// What a GitHub list shows, for the sheet's note.
    static func listNote(_ list: GitHubList, user: String?) -> String {
        let user = user ?? String(localized: "this user", comment: "Stands in for a GitHub username in the New Live Folder sheet's note until one is typed, as in “Open issues assigned to this user…”.")
        return switch list {
        case .pullRequests: String(localized: "Open pull requests \(user) opened in public repositories, newest activity first.", comment: "Under the fields of the New Live Folder sheet, for the Pull Requests Opened list. The placeholder is a GitHub username.")
        case .issues: String(localized: "Open issues assigned to \(user) in public repositories, newest activity first.", comment: "Under the fields of the New Live Folder sheet, for the Issues Assigned list. The placeholder is a GitHub username.")
        case .reviewRequests: String(localized: "Open pull requests \(user) is asked to review in public repositories, newest activity first.", comment: "Under the fields of the New Live Folder sheet, for the Review Requests list. The placeholder is a GitHub username.")
        case .repositoryIssues: String(localized: "Open issues in public repositories \(user) owns, newest activity first.", comment: "Under the fields of the New Live Folder sheet, for the Issues in Owned Repositories list. The placeholder is a GitHub username.")
        case .repositoryPullRequests: String(localized: "Open pull requests in public repositories \(user) owns, newest activity first.", comment: "Under the fields of the New Live Folder sheet, for the Pull Requests in Owned Repositories list. The placeholder is a GitHub username.")
        }
    }

    /// How often it checks, from `LiveSchedule`.
    static var scheduleNote: String {
        String(localized: "Checks every \(Int(LiveSchedule.interval / 60)) minutes, or hourly in Low Power Mode.", comment: "Under the fields of the New Live Folder sheet: how often a live folder fetches its feed or list. The number is minutes (30).")
    }

    /// What it shows, then how often it checks.
    static func withSchedule(_ note: String) -> String {
        String(localized: "\(note) \(scheduleNote)", comment: "Joins two sentences, one after the other. Leave out the space if your language doesn't put one between sentences.")
    }

    /// `editing`: the live folder to change; nil makes one, inside `parent` when given.
    static func show(in controller: BrowserWindowController, editing: UUID? = nil, parent: UUID? = nil) {
        guard !controller.tabManager.isPrivate, let host = controller.window?.contentView else { return }
        let form = Form(editing: editing.flatMap(Library.shared.folder))
        let sheet = FormSheet.show(in: host, title: form.existing == nil ? String(localized: "New Live Folder", comment: "Title of the sheet that makes a live folder.")
                                                                          : String(localized: "Edit Live Folder", comment: "Title of the sheet that changes a live folder."),
                                   symbol: symbol, rows: form.rows,
                                   confirmTitle: form.existing == nil ? String(localized: "Add", comment: "Button of the New Live Folder sheet.")
                                                                      : String(localized: "Save", comment: "Button of the Edit Live Folder sheet."),
                                   canConfirm: { form.canConfirm() }) { [weak controller] confirmed in
            guard confirmed, let controller else { return }
            form.commit(in: controller, parent: parent)
        }
        form.sheet = sheet
        sheet.header.makePictureClickable(toolTip: SidebarMenus.changeIconTitle) { [weak form] in form?.chooseIcon() }
        form.showIcon()
        sheet.heldUpNote = { [weak form] in form?.usernameProblem }
        #if DEBUG
        current = sheet
        #endif
        form.kind.onChange = { [weak form] _ in form?.showKind() }
        form.list.onSelect = { [weak sheet] _ in sheet?.revalidate() }
        form.count.onSelect = { [weak sheet] _ in sheet?.revalidate() }
        if form.isGitHub { sheet.window?.makeFirstResponder(form.user.field) }
    }

    /// The sheet's controls and what typing in them found.
    private final class Form {
        let existing: BookmarkFolder?
        let kind = SlidingSwitch([.text(String(localized: "Feed", comment: "Choice in the New Live Folder sheet: the folder follows a feed (RSS or Atom).")), .text("GitHub")])
        let address = FilledField(placeholder: String(localized: "Feed or site address", comment: "Placeholder of the address field in the New Live Folder sheet."))
        let list = DropdownButton()
        let user = FilledField(placeholder: String(localized: "GitHub username", comment: "Placeholder of the username field in the New Live Folder sheet."))
        let name = FilledField(placeholder: String(localized: "Name", comment: "Placeholder of the name field in the New Live Folder sheet."))
        let count = DropdownButton()
        let note = NSTextField.dialogText("", font: Tokens.Font.detail())
        weak var sheet: FormSheet?
        /// The icon chosen in the sheet, kept on Save or Add.
        private(set) var icon: String?
        private var iconToken: SignalToken?
        private var shownIcon: String?
        private let lists = GitHubList.allCases
        /// What looking up an address found, for the address it was for (nil while it looks).
        private var lookup: (url: URL, result: LiveFolders.Lookup?)?
        private let lookupDelay = Debouncer(delay: 0.6)

        init(editing folder: BookmarkFolder?) {
            existing = folder
            icon = folder?.icon
            let live = folder?.live
            kind.selectedIndex = live?.source.gitHub == nil ? 0 : 1
            kind.setAccessibilityLabel(String(localized: "Source", comment: "Accessibility label of the Feed or GitHub switch in the New Live Folder sheet."))
            address.stringValue = live?.source.address?.absoluteString ?? ""
            list.options = lists.map { DropdownButton.Option(title: LiveFolderSheet.listTitle($0)) }
            list.selectedIndex = live?.source.gitHub.flatMap(lists.firstIndex(of:)) ?? 0
            user.stringValue = live?.source.user ?? ""
            // Named after the feed: left empty, so it keeps following the feed's name.
            name.stringValue = folder.map { live?.namedByFeed == true ? "" : $0.name } ?? ""
            count.options = LiveFolder.limits.map { DropdownButton.Option(title: LiveFolderSheet.limitTitle($0)) }
            count.selectedIndex = LiveFolder.limits.firstIndex(of: live?.limit ?? LiveFolder.defaultLimit) ?? 1
            if let live, let typed = live.source.address, let feed = live.source.feed { lookup = (typed, .found(feed: feed, title: nil)) }
        }

        var isGitHub: Bool { kind.selectedIndex == 1 }

        var rows: [FormSheet.Row] {
            [.init(label: nil, view: kind),
             .init(label: String(localized: "Address", comment: "Label of the address field in the New Live Folder sheet."), view: address, isHidden: isGitHub),
             .init(label: String(localized: "Username", comment: "Label of the GitHub username field in the New Live Folder sheet."), view: user, isHidden: !isGitHub),
             .init(label: String(localized: "List", comment: "Label of the GitHub list menu in the New Live Folder sheet."), view: list, isHidden: !isGitHub, fills: true),
             .init(label: String(localized: "Name", comment: "Label of the name field in the New Live Folder sheet."), view: name),
             .init(label: String(localized: "Show", comment: "Label of the menu in the New Live Folder sheet that picks how many pages it shows."), view: count, fills: true),
             .init(label: nil, view: note, height: 0)]
        }

        func showKind() {
            sheet?.setHidden(isGitHub, forRow: 1)
            sheet?.setHidden(!isGitHub, forRow: 2)
            sheet?.setHidden(!isGitHub, forRow: 3)
            sheet?.revalidate()
            sheet?.window?.makeFirstResponder(isGitHub ? user.field : address.field)
        }

        private var typedAddress: URL? { LiveFolderSheet.address(from: address.stringValue) }

        /// The username as typed, without spaces or an @.
        private var login: String { user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "") }

        var source: LiveSource? {
            if isGitHub { return GitHubList.isUsername(login) ? .gitHub(lists[list.selectedIndex], user: login) : nil }
            guard let url = typedAddress else { return nil }
            if let lookup, lookup.url == url, case .found(let feed, _)? = lookup.result { return .feed(url, found: feed) }
            return .feed(url)
        }

        private var feedTitle: String? {
            guard let lookup, lookup.url == typedAddress, case .found(_, let title)? = lookup.result else { return nil }
            return title
        }

        var defaultName: String {
            if isGitHub { return LiveFolderSheet.listTitle(lists[list.selectedIndex]) }
            return feedTitle ?? typedAddress.flatMap { LiveSource.feed($0).siteName }
                ?? String(localized: "Live Folder", comment: "Name of a new live folder whose feed has no name.")
        }

        /// The name an empty Name field gives, as Save names it.
        var emptyName: String {
            if let existing, !isGitHub, existing.live?.namedByFeed == true, existing.live?.source == source { return existing.name }
            return defaultName
        }

        /// Why what's typed can't be a GitHub username; nil while it can, or while it's empty.
        var usernameProblem: String? {
            guard isGitHub, !login.isEmpty, !GitHubList.isUsername(login) else { return nil }
            return String(localized: "GitHub usernames have only letters, numbers and single hyphens.", comment: "Tooltip on the username field of the New Live Folder sheet when what's typed can't be a GitHub username, so its button can't be pressed.")
        }

        /// The source the header's icon is for: a feed once it's found, a GitHub list once the username can be one.
        private var iconSource: LiveSource? {
            if isGitHub { return source }
            guard let lookup, lookup.url == typedAddress, case .found? = lookup.result else { return existing?.live?.source }
            return source
        }

        /// The heading's icon, as the folder's sidebar row shows it: its own icon in a folder, else its site's icon,
        /// else the folder; the feed mark while a new folder has no source yet.
        func showIcon() {
            guard let header = sheet?.header else { return }
            let source = icon == nil ? iconSource : nil
            let site = source.flatMap(LiveFolderSheet.siteIcon(for:))
            let key = [icon ?? "", source?.iconSite?.absoluteString ?? "", site.map { "\(ObjectIdentifier($0).hashValue)" } ?? ""].joined(separator: "|")
            guard key != shownIcon else { return }
            shownIcon = key
            let side = Tokens.TypeSize.heading
            if let icon {
                let image = IconChoice.folder(icon, open: false, size: side)
                if IconChoice.isEmoji(icon) || PageImageIcon.isImage(icon) { header.setImage(image) } else { header.setTemplate(image, tint: Tokens.Color.icon) }
                return
            }
            guard let source else {
                header.setSymbol(existing == nil ? LiveFolderSheet.symbol : "folder", tint: Tokens.Color.icon)
                return
            }
            if let site {
                header.setImage(site)
            } else {
                header.setSymbol("folder", tint: Tokens.Color.icon)
                let key = FaviconStore.shared.iconKey(for: source.iconSite)
                iconToken = FaviconStore.shared.updated.observe { [weak self] site in if site == key { self?.showIcon() } }
            }
        }

        /// The same grid as the folder's Change Icon…, under the heading's icon.
        func chooseIcon() {
            guard let sheet, let button = sheet.header.pictureButton else { return }
            if let open = IconPickerPanel.current, open.isDescendant(of: sheet) { open.close(); return }
            let panel = IconPickerPanel.forFolder(selected: icon) { [weak self] picked in
                self?.icon = picked
                self?.showIcon()
            }
            let corner = button.convert(NSPoint(x: button.bounds.minX, y: button.bounds.maxY + Tokens.Space.x1), to: sheet)
            panel.show(at: corner, in: sheet, growsFrom: CGPoint(x: 0, y: 1))
        }

        func canConfirm() -> Bool {
            lookUp()
            showNote()
            showIcon()
            if name.placeholder != emptyName { name.placeholder = emptyName }
            user.isInvalid = usernameProblem != nil
            user.toolTip = usernameProblem
            guard source != nil else { return false }
            if !isGitHub, let lookup, lookup.url == typedAddress, case .problem? = lookup.result { return false }
            return true
        }

        /// Typing an address looks for its feed, a moment after the typing stops.
        private func lookUp() {
            guard !isGitHub, let url = typedAddress else { lookupDelay.cancel(); return }
            guard lookup?.url != url else { return }
            lookup = (url, nil)
            lookupDelay.call { [weak self] in
                Task { @MainActor [weak self] in
                    let result = await LiveFolders.shared.lookUp(url)
                    guard let self, self.lookup?.url == url else { return }
                    self.lookup = (url, result)
                    self.sheet?.revalidate()
                }
            }
        }

        private func showNote() {
            var text = ""
            var problem = false
            let fromFeed = String(localized: "New pages from the feed, newest first.", comment: "Under the fields of the New Live Folder sheet, for a feed.")
            if isGitHub {
                text = LiveFolderSheet.withSchedule(LiveFolderSheet.listNote(lists[list.selectedIndex], user: GitHubList.isUsername(login) ? login : nil))
            } else if let lookup, lookup.url == typedAddress {
                switch lookup.result {
                case .found(_, let title)?:
                    text = LiveFolderSheet.withSchedule(title.map { String(localized: "New pages from “\($0)”, newest first.", comment: "Under the address in the New Live Folder sheet: the feed found there, by its name.") } ?? fromFeed)
                case .problem(let reason)?: text = reason.message; problem = true
                case nil: text = String(localized: "Looking for a feed…", comment: "Under the address in the New Live Folder sheet, while Zigzag looks for the feed.")
                }
            } else {
                text = LiveFolderSheet.withSchedule(fromFeed)
            }
            note.textColor = problem ? Tokens.Color.destructive : Tokens.Color.textSecondary
            guard note.stringValue != text else { return }
            note.stringValue = text
            sheet?.needsLayout = true
        }

        func commit(in controller: BrowserWindowController, parent: UUID?) {
            guard let chosen = source else { return }
            let typed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = LiveFolder.limits[count.selectedIndex]
            let followsFeed = typed.isEmpty && !isGitHub
            if let existing {
                let changed = existing.live?.source != chosen
                let title = typed.isEmpty ? (changed || !followsFeed ? defaultName : existing.name) : typed
                controller.libraryChange(String(localized: "Edit Live Folder", comment: "Undo action name, shown in Edit › Undo.")) {
                    Library.shared.updateLiveFolder(existing.id, name: title, namedByFeed: followsFeed, source: chosen, limit: limit)
                    if icon != existing.icon { Library.shared.setIcon(icon, forFolder: existing.id) }
                }
                if changed { LiveFolders.shared.reset(existing.id) }
                LiveFolders.shared.refreshNow(existing.id)
                return
            }
            let spaceID = controller.tabManager.currentSpaceID
            var made: BookmarkFolder?
            controller.libraryChange(String(localized: "New Live Folder", comment: "Undo action name, shown in Edit › Undo.")) {
                made = Library.shared.addLiveFolder(named: typed.isEmpty ? defaultName : typed, source: chosen, limit: limit,
                                                    namedByFeed: followsFeed, in: spaceID, parent: parent)
                if let made, let icon { Library.shared.setIcon(icon, forFolder: made.id) }
            }
            guard let made else { return }
            if SidebarListView.isCollapsed(spaceID) { SidebarListView.setCollapsed(spaceID, false) }
            controller.sidebar.list.reload(animated: true)
            LiveFolders.shared.refreshNow(made.id)
        }
    }
}

extension BrowserWindowController {
    func newLiveFolder(inside parent: UUID? = nil) { LiveFolderSheet.show(in: self, parent: parent) }

    func editLiveFolder(_ id: UUID) { LiveFolderSheet.show(in: self, editing: id) }

    /// The folder and its pages go; ⌘Z brings them back.
    func deleteLiveFolderWithUndo(_ id: UUID) {
        libraryChange(String(localized: "Delete Live Folder", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.removeFolder(id) }
    }
}

extension SidebarMenus {
    /// "Updated 5 Minutes Ago", "Updated Just Now" under a minute, in the app's language; title case in English.
    static func updatedTitle(_ date: Date, now: Date = Date(), locale: Locale = Words.locale) -> String {
        guard now.timeIntervalSince(date) >= 60 else {
            return String(localized: "Updated Just Now", comment: "Line at the top of a live folder's menu in the sidebar: it was fetched less than a minute ago.")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        formatter.formattingContext = .middleOfSentence
        var ago = formatter.localizedString(for: min(date, now), relativeTo: now)
        if locale.language.languageCode == .english { ago = ago.capitalized(with: locale) }
        return String(localized: "Updated \(ago)", comment: "Line at the top of a live folder's menu in the sidebar: when it was last fetched. The placeholder is a relative time, like “5 Minutes Ago”.")
    }

    /// A live folder's menu: when it was updated, its state when it couldn't refresh, then reading, folding, its source
    /// and deleting it.
    static func liveFolderMenu(for folder: BookmarkFolder, controller: BrowserWindowController) -> NSMenu {
        let live = LiveFolders.shared
        var updated: [NSMenuItem] = []
        if live.isRefreshing(folder.id) {
            updated.append(Item(String(localized: "Updating…", comment: "Line at the top of a live folder's menu in the sidebar, while it's being fetched."), symbol: "clock", enabled: false) {})
        } else if let checked = live.state(folder.id).checked {
            updated.append(Item(updatedTitle(checked, now: live.now()), symbol: "clock", enabled: false) {})
        }
        var problem: [NSMenuItem] = []
        if let reason = live.state(folder.id).problem {
            problem.append(.sectionHeader(title: String(localized: "Couldn’t Refresh", comment: "Heading in a live folder's menu in the sidebar, over why its feed couldn't be fetched.")))
            problem.append(Item(reason.message, symbol: "exclamationmark.triangle", enabled: false) {})
            problem.append(Item(String(localized: "Try Again", comment: "Item in a live folder's menu in the sidebar, after it couldn't refresh."), symbol: Symbol.reload) { live.refreshNow(folder.id) })
        }
        var open: [NSMenuItem] = []
        if !folder.bookmarkIDs.isEmpty {
            open.append(Item(String(localized: "Open All in Tabs", comment: "Item in a folder's context menu in the sidebar: opens every page in the folder and the folders inside it as new tabs."), symbol: Symbol.openAll) { controller.openAllInTabs(folder.id) })
        }
        let view = [Item(folder.isOpen ? String(localized: "Close Folder", comment: "Item in a folder's context menu in the sidebar.") : String(localized: "Open Folder", comment: "Item in a folder's context menu in the sidebar."), symbol: folder.isOpen ? Symbol.collapse : Symbol.expand) { controller.listSetFolderOpen(folder.id, !folder.isOpen) }]
        var reading = [Item(String(localized: "Mark All as Read", comment: "Item in a live folder's menu in the sidebar: takes the dot off every new page in it."), symbol: "checkmark.circle", enabled: live.unreadCount(folder.id) > 0) { live.markAllRead(folder.id) }]
        if problem.isEmpty { reading.append(Item(String(localized: "Refresh Now", comment: "Item in a live folder's menu in the sidebar: fetches its feed now instead of at the next half hour."), symbol: Symbol.reload) { live.refreshNow(folder.id) }) }
        let edit = [
            Item(String(localized: "Edit…", comment: "Item in a live folder's menu in the sidebar: opens its sheet to change its name, source or how many pages it shows."), symbol: Symbol.edit) { controller.editLiveFolder(folder.id) },
            Item(changeIconTitle, symbol: Symbol.changeIcon) { controller.chooseFolderIcon(folder.id) },
        ]
        let close = [Item(String(localized: "Delete Live Folder", comment: "Item in a live folder's menu in the sidebar: the folder and its pages go."), symbol: Symbol.remove, destructive: true) { controller.deleteLiveFolderWithUndo(folder.id) }]
        let result = menu([updated, problem, open, view, reading, edit, close])
        result.updates = MenuUpdates(changes: live.changed) { [weak controller] in
            guard let controller, let now = Library.shared.folder(folder.id), now.live != nil else { return nil }
            return liveFolderMenu(for: now, controller: controller)
        }
        return result
    }

    /// A live folder's page belongs to its feed: no renaming, filing or removing, but read or unread, and copies
    /// of it can go to Favorites.
    static func livePageMenu(for bookmark: Bookmark, controller: BrowserWindowController) -> NSMenu {
        let manager = controller.tabManager
        let open = manager.bookmarkTab(for: bookmark.id)
        func keyed(_ item: NSMenuItem, _ action: Selector) -> NSMenuItem { withShortcut(item, of: action) }
        var context: [NSMenuItem] = []
        if open != nil, manager.isAway(bookmark.id) {
            context.append(Item(String(localized: "Back to Pinned Page", comment: "Item in a pinned tab's context menu in the sidebar. Goes back to the page the tab was pinned with."), symbol: Symbol.back) { manager.resetBookmarkTab(bookmark.id) })
            context.append(Item(String(localized: "Separate from Pinned Tab", comment: "Item in a pinned tab's context menu in the sidebar. The page wandered off; this opens it as a tab of its own."), symbol: Symbol.separate) { manager.separateBookmarkTab(bookmark.id) })
        }
        let unread = LiveFolders.shared.isUnread(bookmark: bookmark.id)
        let reading = [Item(unread ? String(localized: "Mark as Read", comment: "Item in the menu of a live folder's page in the sidebar: takes its dot off.")
                                   : String(localized: "Mark as Unread", comment: "Item in the menu of a live folder's page in the sidebar: gives it the dot of a new page again."),
                            symbol: unread ? "checkmark.circle" : "circle.fill") { LiveFolders.shared.setRead(bookmark: bookmark.id, unread) }]
        var page = [keyed(Item(String(localized: "Copy Link", comment: "Item in a pinned tab's context menu in the sidebar."), symbol: Symbol.copyLink) { controller.copyLink(bookmark.url, title: bookmark.title) }, #selector(BrowserWindowController.copyPageURL(_:)))]
        if !manager.isPrivate { page.append(keyed(Item(String(localized: "Add to Favorites", comment: "Item in a pinned tab's context menu in the sidebar."), symbol: Symbol.favorite) {
            controller.libraryChange(String(localized: "Add to Favorites", comment: "Undo action name, shown in Edit › Undo.")) { Library.shared.makeFavorite(bookmark.id, in: manager.profile.id) }
            open?.isFavorite = true
        }, #selector(BrowserWindowController.addToFavorites(_:)))) }
        var view: [NSMenuItem] = []
        if let current = manager.selectedTab, current.bookmarkID == nil, open.map({ manager.split(for: $0) == nil }) ?? true {
            view.append(Item(String(localized: "Open in Split View", comment: "Item in a pinned tab's context menu in the sidebar. Shows this pinned tab beside the current one."), symbol: Symbol.split) { controller.splitWithUndo(current, with: manager.pageTab(for: bookmark)) })
        }
        var close: [NSMenuItem] = []
        if let open {
            close.append(Item(String(localized: "Unload Page", comment: "Item in a pinned tab's context menu in the sidebar. Unloads the page; the pinned tab stays."), symbol: Symbol.close) { manager.close(open) })
        }
        return menu([context, reading, page, view, close])
    }
}
