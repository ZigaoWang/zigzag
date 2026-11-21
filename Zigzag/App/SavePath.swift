import AppKit

/// Where a page is pinned, and the one function every pin goes through (#326). The star, ⌘D and Pin in a page's or a
/// link's menu pin it at the end of the space's Pinned pages, no question; with ⇧ they ask where: a folder of the space,
/// a new one, and the page's name. A pin never crosses spaces. Favorites aren't a destination: a page is pinned once,
/// and Add to Favorites is a tick on it afterwards.
enum SavePath {
    /// Where a pin began.
    enum Entry {
        /// The star at the end of the address.
        case star
        /// File › Pin Tab (⌘D).
        case savePageCommand
        /// File › Pin Tab to Folder… (⇧⌘D).
        case savePageToFolderCommand
        /// Pin in a page's or a tab's right-click menu.
        case pageMenu
        /// Pin Link in a link's right-click menu.
        case linkMenu
    }

    /// What one pin is: a page, the pages of a split view, or a tab group pinned as a folder. Each moves as one: a
    /// group's pages and a split's halves are never pulled apart by a pin.
    enum Kind: Equatable {
        case page
        case split
        /// A tab group, pinned or to be pinned as a folder; `folder` is that folder once it's pinned.
        case group(name: String, folder: UUID?)
    }

    /// What pinning `tab` pins, or what it is pinned as.
    @MainActor static func kind(of tab: Tab, in manager: TabManager?) -> Kind {
        if let saved = tab.bookmarkID { return kind(ofPinned: saved) }
        if let manager, manager.pinsGroup(tab), let groupID = tab.groupID {
            return .group(name: manager.group(groupID)?.name ?? "", folder: nil)
        }
        if manager?.split(for: tab) != nil { return .split }
        return .page
    }

    /// What a pinned page is part of: its tab group's folder, its split view, or nothing.
    static func kind(ofPinned id: UUID) -> Kind {
        if let group = Library.shared.pinnedGroup(containing: id) { return .group(name: group.name, folder: group.id) }
        if Library.shared.pinnedSplit(containing: id) != nil { return .split }
        return .page
    }

    /// What an entry point asks for: the quick pin, or the place picker.
    enum Request: Equatable {
        case quick
        case picker
    }

    /// ⇧ on any entry point means the picker, and only there: ⇧⌘D is an item of its own, and the star and the menus
    /// read the key when they run.
    static func request(for entry: Entry, shiftHeld: Bool = false) -> Request {
        switch entry {
        case .savePageToFolderCommand: .picker
        case .star, .savePageCommand, .pageMenu, .linkMenu: shiftHeld ? .picker : .quick
        }
    }

    /// A place in one space a page is pinned to: a folder of its Pinned pages, or Favorites, which show in every space
    /// of the page's profile.
    struct Place: Equatable {
        /// The space the pin began in; nothing offers another.
        var spaceID: UUID
        /// The folder of the space's Pinned pages it goes in; nil, among them at the top level.
        var folderID: UUID?
        /// Favorites: shows in every space of the profile, a tick on the pinned page.
        var inEverySpace = false
        /// A folder to make in the space, named as typed, when no folder is chosen.
        var newFolder: String?
        /// Where in the space's Pinned list it goes; nil, the end.
        var index: Int?
    }

    /// The page being pinned: one open in a tab, or a link's, without opening it.
    struct Page {
        var url: URL
        var title: String
        var icon: String?
        /// The tab its page is open in: pinning keeps that page as the pinned page's.
        var tab: Tab?

        init(url: URL, title: String, icon: String? = nil, tab: Tab? = nil) {
            self.url = url
            self.title = title
            self.icon = icon
            self.tab = tab
        }

        /// The page a tab shows, or nil for a tab with nothing to pin: no address (a new tab), or one of Zigzag's
        /// own views (Settings, History, the archive), which are drawn by the app and can't come back after a launch.
        init?(tab: Tab) {
            guard let url = tab.url, Self.isPinnable(url) else { return nil }
            self.init(url: url, title: tab.displayTitle, icon: tab.customIcon, tab: tab)
        }

        /// Whether a page can be pinned. Zigzag's own views can't; a file can, as it always could.
        static func isPinnable(_ url: URL) -> Bool {
            switch url.scheme?.lowercased() {
            case "zigzag", "about": false
            default: url.isFileURL || url.scheme != nil
            }
        }
    }

    // MARK: Saving

    /// The quick pin's place: the end of the space's Pinned pages, at the top level. The star, ⌘D and the menus' Pin
    /// all pass this, so none can drift from the others.
    static func quickPlace(in spaceID: UUID) -> Place { Place(spaceID: spaceID) }

    /// Every pin ends here. `manager`: the window pinning, which keeps an open page as the pinned page's; nil for one
    /// pinned with no window of its own. Nothing is written in a private window: pins and favorites are shared.
    ///
    /// `name`: what the pinned page is called, when the picker asked; nil keeps the name it has, or the page's own.
    @discardableResult
    static func save(_ page: Page, to place: Place, in manager: TabManager?, name typed: String? = nil) -> Bookmark? {
        guard manager?.isPrivate != true, Library.shared.space(place.spaceID) != nil else { return nil }
        let profile = Library.shared.profileID(ofSpace: place.spaceID)
        let name = named(typed) ?? name(of: page)

        // Add to Favorites: a tick on the page already pinned, never a second pin of it.
        if place.inEverySpace {
            let id: UUID
            if let tab = page.tab, let manager {
                if tab.bookmarkID == nil {
                    manager.favoriteTab(tab)
                } else if let saved = tab.bookmarkID, !Library.shared.isFavorite(saved) {
                    manager.favoriteBookmark(saved, at: nil)
                }
                guard let saved = tab.bookmarkID, Library.shared.isFavorite(saved) else { return nil }
                id = saved
            } else if let saved = alreadySaved(page, inEverySpace: true, profile: profile, space: place.spaceID) {
                if !Library.shared.isFavorite(saved) { Library.shared.makeFavorite(saved, in: profile) }
                id = saved
            } else {
                return Library.shared.addFavorite(url: page.url, title: name, icon: page.icon, in: profile)
            }
            rename(id, to: name)
            return Library.shared.bookmark(id)
        }

        let folder = folder(for: place)
        let id: UUID
        if let tab = page.tab {
            if let saved = tab.bookmarkID {
                // Saved already: the picker files it where you said, rather than saving it twice.
                file(saved, into: place, folder: folder)
                if case .group(let groupName, let groupFolder?) = kind(ofPinned: saved) {
                    if let typed = named(typed), typed != groupName { Library.shared.renameFolder(groupFolder, to: typed) }
                    return Library.shared.bookmark(saved)
                }
                id = saved
            } else {
                // It stays open as the saved page's, as saving has always kept it.
                guard let manager else { return nil }
                manager.bookmarkTab(tab, at: place.index, in: place.spaceID)
                guard let saved = tab.bookmarkID else { return nil }
                // A tab group pins as its own folder: that folder goes where you said, its pages all in it.
                if let group = Library.shared.pinnedGroup(containing: saved) {
                    if let folder { Library.shared.moveFolder(group.id, to: Int.max, in: place.spaceID, parent: .some(folder)) }
                    if let typed = named(typed), typed != group.name { Library.shared.renameFolder(group.id, to: typed) }
                    return Library.shared.bookmark(saved)
                }
                if let folder { Library.shared.setFolder(of: saved, to: folder) }
                id = saved
            }
        } else if let saved = alreadySaved(page, inEverySpace: false, profile: profile, space: place.spaceID) {
            // A link saved again is the same page: filed where you said, never twice.
            file(saved, into: place, folder: folder)
            id = saved
        } else {
            // A link: saved where it would have been saved had it been opened, and never opened.
            guard let made = Library.shared.addBookmark(url: page.url, title: name, icon: page.icon, to: place.spaceID, at: place.index) else { return nil }
            if let folder { Library.shared.setFolder(of: made.id, to: folder) }
            return Library.shared.bookmark(made.id)
        }
        rename(id, to: name)
        return Library.shared.bookmark(id)
    }

    /// Pin Link in a link's menu: the link, pinned without opening it, wherever the picker said, else at the end.
    @discardableResult
    static func saveLink(_ url: URL, title: String = "", to place: Place, in manager: TabManager?) -> Bookmark? {
        save(Page(url: url, title: title), to: place, in: manager)
    }

    /// The page already pinned with this address, if it is: pinning it again files it, never twice.
    static func alreadySaved(_ url: URL, in spaceID: UUID) -> Bookmark? {
        let wanted = TabManager.normalize(url)
        return Library.shared.bookmarks(in: spaceID).first { TabManager.normalize($0.url) == wanted }
    }

    /// What the picker offers for a pin that began in `spaceID`: that space's folders, and no other space.
    struct Options: Equatable {
        var spaceID: UUID
        var folders: [BookmarkFolder]
    }

    /// The folders of a space a pin can go into: for a pinned group, never its own folder or one inside it.
    static func folders(in spaceID: UUID, for kind: Kind) -> [BookmarkFolder] {
        let all = Library.shared.folders(in: spaceID)
        guard case .group(_, let group?) = kind else { return all }
        let inside = Set(Library.shared.subfolderIDs(of: group)).union([group])
        return all.filter { !inside.contains($0.id) }
    }

    static func options(in spaceID: UUID) -> Options {
        Options(spaceID: spaceID, folders: Library.shared.folders(in: spaceID))
    }

    /// The place the picker's answers make: the space it began in, a folder, a new one, or the top of Pinned.
    static func place(in spaceID: UUID, folder: UUID?, newFolder: String? = nil, inEverySpace: Bool = false,
                      atTop: Bool = false) -> Place {
        var place = Place(spaceID: spaceID)
        place.inEverySpace = inEverySpace
        if !inEverySpace {
            if let typed = named(newFolder) {
                place.newFolder = typed
            } else if let folder, Library.shared.folders(in: spaceID).contains(where: { $0.id == folder }) {
                place.folderID = folder
            } else if atTop {
                place.index = 0
            }
        }
        return place
    }

    /// What a pinned page is called: the title a home page shaves down to its site (`TabManager.bookmarkTitle`), or the
    /// site itself when the page gave no name.
    static func name(of page: Page) -> String { name(ofTitle: page.title, url: page.url) }

    static func name(ofTitle title: String, url: URL) -> String {
        let shaved = TabManager.bookmarkTitle(title, url: url)
        return named(shaved) ?? (url.host() ?? url.absoluteString)
    }

    /// A name typed or the page's own, trimmed; nil when there's nothing to call it.
    private static func named(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The folder the page goes in, made if the picker asked for a new one.
    private static func folder(for place: Place) -> UUID? {
        if let typed = named(place.newFolder) { return Library.shared.addFolder(named: typed, with: [], in: place.spaceID)?.id }
        guard let id = place.folderID, Library.shared.folder(id) != nil else { return nil }
        return id
    }

    /// A page already pinned with this address, when a link is pinned again: ticking it is enough.
    private static func alreadySaved(_ page: Page, inEverySpace: Bool, profile: UUID, space: UUID) -> UUID? {
        let wanted = TabManager.normalize(page.url)
        let marks = inEverySpace ? Library.shared.favorites(in: profile) : Library.shared.bookmarks(in: space)
        return marks.first { TabManager.normalize($0.url) == wanted }?.id
    }

    /// Files a page already pinned where the picker said. Its folder is left as it was unless one was chosen.
    private static func file(_ id: UUID, into place: Place, folder: UUID?) {
        if place.newFolder == nil, place.folderID == nil, place.index == nil { return }
        // A page of a pinned tab group moves the group's folder, with every page in it.
        if case .group(_, let group?) = kind(ofPinned: id) {
            if let folder {
                Library.shared.moveFolder(group, to: Int.max, in: place.spaceID, parent: .some(folder))
            } else if let index = place.index {
                Library.shared.moveFolder(group, to: index, in: place.spaceID, parent: .some(nil))
            }
            return
        }
        leaveFavorites(id, for: place.spaceID)
        if Library.shared.spaceID(ofBookmark: id) != place.spaceID {
            Library.shared.moveBookmark(id, to: Int.max, in: place.spaceID, folder: .some(folder))
        } else {
            Library.shared.setFolder(of: id, to: folder)
            if let index = place.index { Library.shared.moveBookmark(id, to: index, in: place.spaceID, folder: .some(folder)) }
        }
    }

    private static func rename(_ id: UUID, to name: String) {
        guard let bookmark = Library.shared.bookmark(id), bookmark.title != name else { return }
        Library.shared.updateBookmark(id, title: name)
    }

    // MARK: Favorites

    /// Add to Favorites on a page already pinned: it shows in every space of its profile. The tick is the only way
    /// there: nothing pins straight into Favorites.
    @discardableResult
    static func keepInEverySpace(_ bookmarkID: UUID, profile: UUID) -> Bool {
        guard Library.shared.bookmark(bookmarkID) != nil else { return false }
        guard !Library.shared.isFavorite(bookmarkID) else { return true }
        Library.shared.makeFavorite(bookmarkID, at: nil, in: profile)
        return Library.shared.isFavorite(bookmarkID)
    }

    /// The tick taken off: the page stays saved, among the space's Pinned pages from now on.
    @discardableResult
    static func keepInThisSpace(_ bookmarkID: UUID, spaceID: UUID, at index: Int = 0) -> Bool {
        guard Library.shared.isFavorite(bookmarkID), Library.shared.space(spaceID) != nil else { return false }
        Library.shared.pinFavorite(bookmarkID, in: spaceID, at: index)
        return !Library.shared.isFavorite(bookmarkID)
    }

    // MARK: The picker's last place

    /// The defaults that remember the last place a page was filed; a test's own keeps the ones you use out of it.
    static var defaults: UserDefaults = .standard
    private static let folderKey = "SavePlaceFolder"

    /// Remembers where in this space the page was filed, for the picker to open on. A folder it had to make isn't
    /// remembered: next time it's one of the space's own.
    static func remember(_ place: Place) {
        if let folder = place.folderID, place.newFolder == nil {
            defaults.set(folder.uuidString, forKey: folderKey)
        } else {
            defaults.removeObject(forKey: folderKey)
        }
    }

    /// The place the picker opens on: the last folder a page was filed in, while it's still in this space, else the top
    /// of its Pinned pages. Never another space.
    static func lastPlace(in spaceID: UUID) -> Place {
        let folder = defaults.string(forKey: folderKey).flatMap { UUID(uuidString: $0) }
        let there = folder.flatMap { candidate in Library.shared.folders(in: spaceID).first { $0.id == candidate }?.id }
        return Place(spaceID: spaceID, folderID: there)
    }

    // MARK: Names

    /// What ⌘Z says after a save.
    static var saveName: String {
        String(localized: "Pin Tab", comment: "Undo action name, shown in the Edit menu as Undo Pin Tab.")
    }

    /// What ⌘Z says after a saved page is taken out of Pinned.
    static var unsaveName: String {
        String(localized: "Unpin Tab", comment: "Undo action name, shown in the Edit menu as Undo Unpin Tab.")
    }

    // MARK: The saved toast's chevron (#326)

    /// One line of the place menu behind the saved toast's chevron: a place the page can be, and whether it is in it.
    struct PlaceEntry: Equatable {
        enum Kind: Equatable { case everySpace, top, folder(UUID) }
        let kind: Kind
        let isOn: Bool
    }

    /// Every place a saved page can be moved to, in menu order, with the one it is in ticked. A favorite lives in
    /// every space, so the space's own places aren't ticked for it; a saved page without a folder is at the top.
    static func placeEntries(folders: [BookmarkFolder], folderID: UUID?, inEverySpace: Bool, isAtTop: Bool,
                             offersEverySpace: Bool = true) -> [PlaceEntry] {
        var entries = offersEverySpace ? [PlaceEntry(kind: .everySpace, isOn: inEverySpace)] : []
        entries.append(PlaceEntry(kind: .top, isOn: !inEverySpace && folderID == nil && isAtTop))
        entries += folders.map { PlaceEntry(kind: .folder($0.id), isOn: !inEverySpace && $0.id == folderID) }
        return entries
    }

    /// The places a pin can move to in `spaceID`, as the toast's chevron lists them, ticked where it is. A tab group's
    /// folder can go into another folder or to the top, never into itself, and isn't offered Favorites.
    static func placeEntries(of id: UUID, in spaceID: UUID) -> [PlaceEntry] {
        let kind = kind(ofPinned: id)
        let folders = folders(in: spaceID, for: kind)
        let first = Library.shared.bookmarks(in: spaceID).first?.id
        if case .group(_, let group?) = kind {
            let parent = Library.shared.folder(group)?.parentID
            let isAtTop = parent == nil && first.map { Library.shared.allBookmarkIDs(inFolder: group).contains($0) } == true
            return placeEntries(folders: folders, folderID: parent, inEverySpace: false, isAtTop: isAtTop, offersEverySpace: false)
        }
        return placeEntries(folders: folders, folderID: Library.shared.folderID(containing: id),
                            inEverySpace: Library.shared.isFavorite(id), isAtTop: first == id)
    }

    /// Moves a page already saved into a folder of its space (#326), the toast's chevron: the page keeps its name,
    /// icon and undo, and is never saved twice.
    @discardableResult
    static func move(_ bookmarkID: UUID, to place: Place) -> Bool {
        guard Library.shared.bookmark(bookmarkID) != nil, Library.shared.space(place.spaceID) != nil else { return false }
        file(bookmarkID, into: place, folder: folder(for: place))
        return true
    }

    /// The same page to the top of its space's Pinned pages, out of any folder.
    @discardableResult
    static func moveToTop(_ bookmarkID: UUID, in spaceID: UUID) -> Bool {
        guard Library.shared.bookmark(bookmarkID) != nil, Library.shared.space(spaceID) != nil else { return false }
        if case .group(_, let group?) = kind(ofPinned: bookmarkID) {
            Library.shared.moveFolder(group, to: 0, in: spaceID, parent: .some(nil))
            return true
        }
        leaveFavorites(bookmarkID, for: spaceID)
        Library.shared.moveBookmark(bookmarkID, to: 0, in: spaceID, folder: .some(nil))
        return true
    }

    /// A favorite filed into a space leaves Favorites first, so it's never a favorite and a pinned page at once.
    private static func leaveFavorites(_ id: UUID, for spaceID: UUID) {
        guard Library.shared.isFavorite(id) else { return }
        Library.shared.pinFavorite(id, in: spaceID, at: Int.max)
    }
}
