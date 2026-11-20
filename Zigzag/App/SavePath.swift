import AppKit

/// Where a page is saved, and the one function every save goes through (#326). Two ways in: a quick save, which is the
/// star, ⌘D and Save in a page's or a link's menu, puts the page at the end of the space's Pinned pages with no
/// question; and the same three with ⇧ ask where, offering the folders of the space you're in, a new one, and the
/// page's name. A save never crosses spaces. Favorites aren't a destination: a page is saved once, and In Every Space is
/// a tick on it afterwards.
enum SavePath {
    /// Where a save began: the star, one of the menu bar's two items, or a page's or a link's menu.
    enum Entry {
        /// The star at the end of the address.
        case star
        /// File › Save Page (⌘D).
        case savePageCommand
        /// File › Save Page to Folder… (⇧⌘D).
        case savePageToFolderCommand
        /// Save Page in a page's (or a tab's) right-click menu.
        case pageMenu
        /// Save to Pins in a link's right-click menu.
        case linkMenu
    }

    /// What an entry point asks for: the quick save, or the place picker.
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

    /// A place in one space a page is saved to: a folder of its Pinned pages, or, with `inEverySpace`, Favorites, which
    /// show in every space of the page's profile.
    struct Place: Equatable {
        /// The space: the one the save began in. Nothing offers another.
        var spaceID: UUID
        /// The folder of the space's Pinned pages it goes in; nil, among them at the top level.
        var folderID: UUID?
        /// Favorites: the page shows in every space of its profile, a tick on the saved page.
        var inEverySpace = false
        /// A folder to make in the space, named as typed, when no folder is chosen.
        var newFolder: String?
        /// Where in the space's Pinned list it goes; nil, the end.
        var index: Int?
    }

    /// The page being saved: one open in a tab, or a link's saved without opening it.
    struct Page {
        var url: URL
        var title: String
        var icon: String?
        /// The tab its page is open in, when it is: saving keeps that page as the saved page's.
        var tab: Tab?

        init(url: URL, title: String, icon: String? = nil, tab: Tab? = nil) {
            self.url = url
            self.title = title
            self.icon = icon
            self.tab = tab
        }

        /// The page a tab shows, or nil for a tab with no address (a new tab).
        init?(tab: Tab) {
            guard let url = tab.url else { return nil }
            self.init(url: url, title: tab.displayTitle, icon: tab.customIcon, tab: tab)
        }
    }

    // MARK: Saving

    /// The quick save's place: the end of the space's Pinned pages, at the top level. The star, ⌘D and the menus' Save
    /// all pass this, so none of them can drift from the others.
    static func quickPlace(in spaceID: UUID) -> Place { Place(spaceID: spaceID) }

    /// Every save ends here. `manager`: the window saving, which keeps an open page as the saved page's; nil for a
    /// page saved from somewhere with no window of its own. Nothing is written in a private window: pins and favorites
    /// are shared by every window.
    ///
    /// `name`: what the saved page is to be called, when the picker asked; nil keeps the name it has, or the page's own
    /// for a page saved for the first time.
    @discardableResult
    static func save(_ page: Page, to place: Place, in manager: TabManager?, name typed: String? = nil) -> Bookmark? {
        guard manager?.isPrivate != true, Library.shared.space(place.spaceID) != nil else { return nil }
        let profile = Library.shared.profileID(ofSpace: place.spaceID)
        let name = named(typed) ?? name(of: page)

        // In Every Space: a tick on the page already saved, never a second save of it.
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
                id = saved
            } else {
                // It stays open as the saved page's, as saving has always kept it.
                guard let manager else { return nil }
                manager.bookmarkTab(tab, at: place.index, in: place.spaceID)
                guard let saved = tab.bookmarkID else { return nil }
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

    /// Save to Pins in a link's menu: the link, saved without opening it, wherever the picker said (or at the end of
    /// Pinned when the quick save said nothing).
    @discardableResult
    static func saveLink(_ url: URL, title: String = "", to place: Place, in manager: TabManager?) -> Bookmark? {
        save(Page(url: url, title: title), to: place, in: manager)
    }

    /// The page already saved with this address, if it is: saving it again files it, never saves it twice.
    static func alreadySaved(_ url: URL, in spaceID: UUID) -> Bookmark? {
        let wanted = TabManager.normalize(url)
        return Library.shared.bookmarks(in: spaceID).first { TabManager.normalize($0.url) == wanted }
    }

    /// What the place picker offers for a save that began in `spaceID`: the folders of that space, and no other space.
    /// A save never crosses spaces, so there is nothing else to choose.
    struct Options: Equatable {
        var spaceID: UUID
        var folders: [BookmarkFolder]
    }

    static func options(in spaceID: UUID) -> Options {
        Options(spaceID: spaceID, folders: Library.shared.folders(in: spaceID))
    }

    /// The place the picker's answers make: always in the space the save began in, with one of its folders, a new one,
    /// or the top of its Pinned pages.
    static func place(in spaceID: UUID, folder: UUID?, newFolder: String? = nil, inEverySpace: Bool = false) -> Place {
        var place = Place(spaceID: spaceID)
        place.inEverySpace = inEverySpace
        if !inEverySpace {
            if let typed = named(newFolder) {
                place.newFolder = typed
            } else if let folder, Library.shared.folders(in: spaceID).contains(where: { $0.id == folder }) {
                place.folderID = folder
            }
        }
        return place
    }

    /// What a saved page is called: the title a home page shaves down to its site (`TabManager.bookmarkTitle`), or the
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

    /// A page already saved with this address, when a link is saved again: ticking it is enough.
    private static func alreadySaved(_ page: Page, inEverySpace: Bool, profile: UUID, space: UUID) -> UUID? {
        let wanted = TabManager.normalize(page.url)
        let marks = inEverySpace ? Library.shared.favorites(in: profile) : Library.shared.bookmarks(in: space)
        return marks.first { TabManager.normalize($0.url) == wanted }?.id
    }

    /// Files a page already saved where the picker said. Its folder is left as it was unless one was chosen.
    private static func file(_ id: UUID, into place: Place, folder: UUID?) {
        if place.newFolder == nil, place.folderID == nil { return }
        if Library.shared.spaceID(ofBookmark: id) != place.spaceID {
            Library.shared.moveBookmark(id, to: Int.max, in: place.spaceID, folder: .some(folder))
        } else {
            Library.shared.setFolder(of: id, to: folder)
        }
    }

    private static func rename(_ id: UUID, to name: String) {
        guard let bookmark = Library.shared.bookmark(id), bookmark.title != name else { return }
        Library.shared.updateBookmark(id, title: name)
    }

    // MARK: In Every Space

    /// In Every Space ticked on a page already saved: a favorite, which shows in every space of its profile. The tick
    /// is the only way there: nothing saves straight into Favorites.
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
    static func placeEntries(folders: [BookmarkFolder], folderID: UUID?, inEverySpace: Bool) -> [PlaceEntry] {
        var entries = [PlaceEntry(kind: .everySpace, isOn: inEverySpace),
                       PlaceEntry(kind: .top, isOn: !inEverySpace && folderID == nil)]
        entries += folders.map { PlaceEntry(kind: .folder($0.id), isOn: !inEverySpace && $0.id == folderID) }
        return entries
    }

    /// Moves a page already saved into a folder of its space (#326), the toast's chevron: the page keeps its name,
    /// icon and undo, and is never saved twice.
    @discardableResult
    static func move(_ bookmarkID: UUID, to place: Place) -> Bool {
        guard Library.shared.bookmark(bookmarkID) != nil, Library.shared.space(place.spaceID) != nil else { return false }
        file(bookmarkID, into: place, folder: place.folderID)
        return true
    }

    /// The same page to the top of its space's Pinned pages, out of any folder.
    @discardableResult
    static func moveToTop(_ bookmarkID: UUID, in spaceID: UUID) -> Bool {
        guard Library.shared.bookmark(bookmarkID) != nil, Library.shared.space(spaceID) != nil else { return false }
        Library.shared.moveBookmark(bookmarkID, to: 0, in: spaceID, folder: .some(nil))
        return true
    }
}
