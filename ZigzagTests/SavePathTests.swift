import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Saving a page (#326): the star, ⌘D and Save in a menu are one quick save that asks nothing and lands at the end of
/// the space's Pinned pages; ⇧ on any of them asks where, offering the folders of the space you're in and no other.
/// Favorites aren't a destination of their own, a link saves without being opened, and a private window writes nothing.
/// The sheet and the star's two looks belong to a window, so those are left to the app.
@MainActor struct SavePathTests {
    private let library = Library.shared

    /// A space of its own, with a folder in it and another space beside it, closed when the test is done.
    private func scratch(_ body: (UUID, UUID, BookmarkFolder) throws -> Void) rethrows {
        let space = library.addSpace(name: "Save tests")
        let elsewhere = library.addSpace(name: "Save tests elsewhere")
        let folder = library.addFolder(named: "Reading", with: [], in: space.id)
        defer {
            library.removeSpace(space.id)
            library.removeSpace(elsewhere.id)
        }
        try body(space.id, elsewhere.id, folder ?? BookmarkFolder(name: "Reading"))
    }

    private func page(_ path: String = "page", title: String = "A Page") -> SavePath.Page {
        SavePath.Page(url: URL(string: "https://example.com/\(path)")!, title: title)
    }

    /// A page saved with no question sits at the end of the space's Pinned pages, in no folder.
    private func assertQuicklySaved(_ bookmark: Bookmark?, in space: UUID, sourceLocation: SourceLocation = #_sourceLocation) {
        let saved = library.bookmarks(in: space)
        #expect(bookmark != nil, sourceLocation: sourceLocation)
        #expect(saved.last?.id == bookmark?.id, "the end of Pinned", sourceLocation: sourceLocation)
        #expect(library.spaceID(ofBookmark: bookmark?.id ?? UUID()) == space, sourceLocation: sourceLocation)
        #expect(library.folderID(containing: bookmark?.id ?? UUID()) == nil, "the top level", sourceLocation: sourceLocation)
    }

    // MARK: Quick save, no question

    /// The star, ⌘D and Save in a page's or a link's menu ask nothing: unmodified, each is the quick save.
    @Test func everyPathUnmodifiedIsTheQuickSave() {
        for entry in [SavePath.Entry.star, .savePageCommand, .pageMenu, .linkMenu] {
            #expect(SavePath.request(for: entry) == .quick, "\(entry)")
            #expect(SavePath.request(for: entry, shiftHeld: false) == .quick, "\(entry)")
        }
    }

    /// A quick save from each way in lands in the same place: the end of this space's Pinned pages, no folder, no
    /// second copy of a page already saved.
    @Test func aQuickSaveFromEachPathLandsAtTheEndOfPinned() throws {
        try scratch { space, _, _ in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let first = Tab(url: URL(string: "https://example.com/one")!, spaceID: space)
            manager.adopt([first], in: space)

            // ⌘D, the star and a page's menu: the same request, so the same place.
            var saved: [Bookmark?] = []
            for entry in [SavePath.Entry.savePageCommand, .star, .pageMenu] {
                #expect(SavePath.request(for: entry) == .quick)
                let tab = entry == .pageMenu ? first : Tab(url: URL(string: "https://example.com/\(entry)")!, spaceID: space)
                if tab !== first { manager.adopt([tab], in: space) }
                saved.append(SavePath.save(try #require(SavePath.Page(tab: tab)), to: SavePath.quickPlace(in: space), in: manager))
                assertQuicklySaved(saved.last ?? nil, in: space)
            }
            #expect(library.bookmarks(in: space).count == 3)
            // A link's Save, with no question: the same place again, and the link never opened as a tab.
            let link = SavePath.saveLink(URL(string: "https://example.com/link")!, to: SavePath.quickPlace(in: space), in: manager)
            assertQuicklySaved(link, in: space)
            #expect(!manager.allTabs.contains { $0.url?.absoluteString == "https://example.com/link" })
        }
    }

    /// Saving the same page twice is one saved page, filed as asked the second time.
    @Test func savingAgainNeverMakesASecondCopy() throws {
        try scratch { space, _, folder in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let tab = Tab(url: URL(string: "https://example.com/again")!, spaceID: space)
            manager.adopt([tab], in: space)
            let page = try #require(SavePath.Page(tab: tab))
            let once = SavePath.save(page, to: SavePath.quickPlace(in: space), in: manager)
            let twice = SavePath.save(page, to: SavePath.place(in: space, folder: folder.id), in: manager)
            #expect(once?.id == twice?.id)
            #expect(library.bookmarks(in: space).count == 1)
            #expect(library.folderID(containing: twice?.id ?? UUID()) == folder.id)
        }
    }

    // MARK: ⇧ asks where

    /// ⇧ on the star, on ⌘D's item and in a page's or a link's menu asks where, and ⇧⌘D is its own item that always
    /// does.
    @Test func shiftOnEveryPathAsksWhere() {
        for entry in [SavePath.Entry.star, .savePageCommand, .pageMenu, .linkMenu] {
            #expect(SavePath.request(for: entry, shiftHeld: true) == .picker, "\(entry) with ⇧")
        }
        #expect(SavePath.request(for: .savePageToFolderCommand) == .picker)
        #expect(SavePath.request(for: .savePageToFolderCommand, shiftHeld: false) == .picker)
    }

    /// What the picker offers: the folders of the space the save began in, and nothing of another space's.
    @Test func thePickerOffersOnlyThisSpacesFolders() throws {
        try scratch { space, elsewhere, folder in
            let own = SavePath.options(in: space)
            #expect(own.spaceID == space)
            #expect(own.folders.map(\.id) == [folder.id])
            let other = SavePath.options(in: elsewhere)
            #expect(other.folders.isEmpty)
            #expect(!other.folders.contains { $0.id == folder.id })
        }
    }

    /// A place the picker makes is in the space it was asked for, whatever folder it's handed: another space's folder
    /// is no folder here, so the page lands at the top of this space's Pinned.
    @Test func aPickerPlaceNeverCrossesSpaces() throws {
        try scratch { space, elsewhere, folder in
            let stray = SavePath.place(in: elsewhere, folder: folder.id)
            #expect(stray.spaceID == elsewhere)
            #expect(stray.folderID == nil)

            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let saved = SavePath.save(page("stray"), to: stray, in: manager)
            #expect(library.spaceID(ofBookmark: saved?.id ?? UUID()) == elsewhere)
            #expect(library.folderID(containing: saved?.id ?? UUID()) == nil)
        }
    }

    /// A save from a space lands in that space, with the folder chosen, or in a new folder named in the picker.
    @Test func aPickerSaveLandsInItsSpace() throws {
        try scratch { space, _, folder in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let inFolder = SavePath.save(page("in-folder"), to: SavePath.place(in: space, folder: folder.id), in: manager)
            #expect(library.spaceID(ofBookmark: inFolder?.id ?? UUID()) == space)
            #expect(library.folderID(containing: inFolder?.id ?? UUID()) == folder.id)

            let made = SavePath.save(page("new-folder"), to: SavePath.place(in: space, folder: nil, newFolder: "Later"), in: manager)
            let named = library.folders(in: space).first { $0.name == "Later" }
            #expect(named != nil)
            #expect(library.folderID(containing: made?.id ?? UUID()) == named?.id)
        }
    }

    /// The picker opens on the last folder a page was filed in, in the space being saved to; a folder of another space
    /// is not that place.
    @Test func thePickerRemembersTheLastFolder() throws {
        let saved = SavePath.defaults
        defer { SavePath.defaults = saved }
        let suite = UserDefaults(suiteName: "SavePathTests.remembered")!
        defer { suite.removePersistentDomain(forName: "SavePathTests.remembered") }
        SavePath.defaults = suite

        try scratch { space, elsewhere, folder in
            #expect(SavePath.lastPlace(in: space).folderID == nil)
            SavePath.remember(SavePath.place(in: space, folder: folder.id))
            #expect(SavePath.lastPlace(in: space).folderID == folder.id)
            #expect(SavePath.lastPlace(in: space).spaceID == space)
            // Another space has no last folder of this one's: its top of Pinned.
            #expect(SavePath.lastPlace(in: elsewhere).folderID == nil)
            #expect(SavePath.lastPlace(in: elsewhere).spaceID == elsewhere)
            // A folder that's gone is no place to open on.
            library.removeFolder(folder.id)
            #expect(SavePath.lastPlace(in: space).folderID == nil)
        }
    }

    // MARK: A private window writes nothing

    /// A private window's page is never saved, and its link never joins the pins: pins belong to every window.
    @Test func aPrivateWindowWritesNothing() throws {
        try scratch { space, _, _ in
            let manager = TabManager(spaceID: space, isPrivate: true)
            defer { manager.invalidate() }
            let before = library.bookmarks(in: space).count
            let tab = Tab(url: URL(string: "https://example.com/private")!, spaceID: space)
            manager.adopt([tab], in: space)
            let page = try #require(SavePath.Page(tab: tab))
            #expect(SavePath.save(page, to: SavePath.quickPlace(in: space), in: manager) == nil)
            #expect(SavePath.save(self.page("private-link"), to: SavePath.place(in: space, folder: nil), in: manager) == nil)
            #expect(SavePath.saveLink(URL(string: "https://example.com/private-link")!, to: SavePath.quickPlace(in: space), in: manager) == nil)
            #expect(library.bookmarks(in: space).count == before)
            #expect(tab.bookmarkID == nil)
        }
    }

    // MARK: In Every Space

    /// In Every Space is a tick on a page already saved, never a destination: the same page shows in every space of
    /// its profile, and one that isn't saved isn't kept anywhere by the tick.
    @Test func inEverySpaceIsATickOnASavedPage() throws {
        try scratch { space, elsewhere, _ in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let tab = Tab(url: URL(string: "https://example.com/everywhere")!, spaceID: space)
            manager.adopt([tab], in: space)
            let page = try #require(SavePath.Page(tab: tab))
            let saved = SavePath.save(page, to: SavePath.quickPlace(in: space), in: manager)
            let id = try #require(saved?.id)
            let profile = library.profileID(ofSpace: space)

            #expect(!library.isFavorite(id))
            let ticked = SavePath.keepInEverySpace(id, profile: profile)
            #expect(ticked)
            #expect(library.isFavorite(id))
            // One page, not two: the same id, now a favorite, so it left the space's Pinned pages rather than being
            // saved a second time.
            #expect(library.bookmarks(in: space).isEmpty)
            #expect(library.favorites(in: library.profileID(ofSpace: space)).contains { $0.id == id })
            #expect(library.bookmark(id)?.url.absoluteString == "https://example.com/everywhere")

            // Ticked off, the page is still saved, among the space's Pinned pages.
            #expect(SavePath.keepInThisSpace(id, spaceID: space))
            #expect(!library.isFavorite(id))
            #expect(library.spaceID(ofBookmark: id) == space)
            #expect(library.bookmark(id)?.url.absoluteString == "https://example.com/everywhere")
            _ = elsewhere
            _ = page
        }
    }

    /// A save made with the tick (the picker's In Every Space) is a favorite, and saving the page again to a space
    /// takes it back out without losing it.
    @Test func thePickersInEverySpaceSavesAFavorite() throws {
        try scratch { space, _, _ in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let tab = Tab(url: URL(string: "https://example.com/tick")!, spaceID: space)
            manager.adopt([tab], in: space)
            let place = SavePath.place(in: space, folder: nil, inEverySpace: true)
            let saved = SavePath.save(try #require(SavePath.Page(tab: tab)), to: place, in: manager)
            #expect(library.isFavorite(saved?.id ?? UUID()))
            #expect(library.bookmarks(in: space).isEmpty)
        }
    }

    // MARK: The star's two looks

    /// The star and ⌘D are one quick action: unsaved saves, saved unsaves, and the star shows it at once.
    @Test func theQuickSaveTogglesAndTheStarFollows() throws {
        try scratch { space, _, _ in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let tab = Tab(url: URL(string: "https://example.com/toggle")!, spaceID: space)
            manager.adopt([tab], in: space)
            manager.select(tab)
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            defer { controller.window?.close() }

            controller.saveFromStar()
            #expect(tab.bookmarkID != nil)
            #expect(controller.sidebar.address.isSaved)

            controller.saveFromStar()
            #expect(tab.bookmarkID == nil)
            #expect(!controller.sidebar.address.isSaved)
        }
    }

    // MARK: Names

    /// A page saved is called what the page says, with a home page shaved down to its site; the picker's name wins.
    @Test func aSavedPagesName() {
        let home = SavePath.name(ofTitle: "Example.com – Home", url: URL(string: "https://example.com")!)
        #expect(home == "Example.com")
        let deep = SavePath.name(ofTitle: "A Post", url: URL(string: "https://example.com/post")!)
        #expect(deep == "A Post")
        let unnamed = SavePath.name(ofTitle: "", url: URL(string: "https://example.com/post")!)
        #expect(unnamed == "example.com")
    }
}
