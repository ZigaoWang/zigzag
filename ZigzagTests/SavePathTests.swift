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

    /// A favorite filed into Pinned or a folder, from the picker or the toast, leaves Favorites: one page, never both.
    @Test func aFavoriteFiledInASpaceLeavesFavorites() throws {
        try scratch { space, _, folder in
            let profile = library.profileID(ofSpace: space)
            for move in 0..<3 {
                let favorite = library.addFavorite(url: URL(string: "https://example.com/favorite\(move)")!, title: "Favorite", in: profile)
                defer { library.removeBookmark(favorite.id) }
                switch move {
                case 0: #expect(SavePath.moveToTop(favorite.id, in: space))
                case 1:
                    #expect(SavePath.move(favorite.id, to: SavePath.place(in: space, folder: folder.id)))
                    #expect(library.folderID(containing: favorite.id) == folder.id)
                default: #expect(SavePath.move(favorite.id, to: SavePath.place(in: space, folder: nil, atTop: true)))
                }
                #expect(!library.isFavorite(favorite.id), "move \(move)")
                #expect(library.spaceID(ofBookmark: favorite.id) == space, "move \(move)")
                #expect(library.bookmarks(in: space).filter { $0.id == favorite.id }.count == 1, "move \(move)")
            }
        }
    }

    /// ⇧ on a click of Pin Tab asks where; keys of yours for Pin Tab that hold ⇧ pin and unpin as they always did.
    @Test func pinTabsOwnKeysNeverAsk() {
        #expect(BrowserWindowController.shiftAsks(event: .leftMouseUp, shiftHeld: true))
        #expect(BrowserWindowController.shiftAsks(event: nil, shiftHeld: true))
        #expect(!BrowserWindowController.shiftAsks(event: .keyDown, shiftHeld: true))
        #expect(!BrowserWindowController.shiftAsks(event: .leftMouseUp, shiftHeld: false))
    }

    // MARK: Groups and split views move as one

    /// Tabs in the scratch space, adopted by a manager of their own.
    private func tabs(_ count: Int, in space: UUID, _ body: (TabManager, [Tab]) throws -> Void) rethrows {
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tabs = (0..<count).map { Tab(url: URL(string: "https://example.com/unit/\($0)")!, title: "Unit \($0)", spaceID: space) }
        manager.adopt(tabs, in: space)
        try body(manager, tabs)
    }

    /// What's pinned says what it is, and the picker's words follow it.
    @Test func thePickerNamesWhatItPins() throws {
        try scratch { space, _, _ in
            try tabs(4, in: space) { manager, tabs in
                #expect(SavePath.kind(of: tabs[0], in: manager) == .page)
                manager.makeSplit(tabs[0], with: tabs[1])
                #expect(SavePath.kind(of: tabs[0], in: manager) == .split)
                _ = try #require(manager.makeGroup(with: [tabs[2], tabs[3]], name: "Reading"))
                #expect(SavePath.kind(of: tabs[3], in: manager) == .group(name: "Reading", folder: nil))
                #expect(SavePlaceSheet.words(for: .page, space: "S").title == String(localized: "Pin Page", comment: "Title of the sheet that pins the page you're on, with where in the space it goes and its name."))
                #expect(SavePlaceSheet.words(for: .split, space: "S").title == String(localized: "Pin Split View", comment: "Title of the sheet that pins the split view you're in, with where in the space it goes and its name."))
                #expect(SavePlaceSheet.words(for: .group(name: "Reading", folder: nil), space: "S").title == String(localized: "Pin Group", comment: "Title of the sheet that pins the tab group you're in as a folder, with where in the space it goes and its name."))
            }
        }
    }

    /// A group pinned with the picker into a folder: its own folder goes inside that one, every page still in it, named
    /// as the picker said.
    @Test func aGroupPinnedIntoAFolderGoesWhole() throws {
        try scratch { space, _, folder in
            try tabs(3, in: space) { manager, tabs in
                _ = try #require(manager.makeGroup(with: tabs, name: "Reading list"))
                let page = try #require(SavePath.Page(tab: tabs[1]))
                _ = SavePath.save(page, to: SavePath.place(in: space, folder: folder.id), in: manager, name: "Weekend")
                let group = try #require(tabs[1].bookmarkID.flatMap(Library.shared.pinnedGroup(containing:)))
                #expect(group.bookmarkIDs == tabs.compactMap(\.bookmarkID))
                #expect(group.bookmarkIDs.count == 3)
                #expect(group.name == "Weekend")
                #expect(Library.shared.folder(group.id)?.parentID == folder.id)
                #expect(Library.shared.allBookmarkIDs(inFolder: folder.id).count == 3)
            }
        }
    }

    /// A pinned group moved to a folder, to the top or into a new folder, by the picker or the toast, moves its folder
    /// and never pulls a page out of it. Its own folder isn't offered, nor Favorites.
    @Test func aPinnedGroupMovesAsItsFolder() throws {
        try scratch { space, _, folder in
            try tabs(3, in: space) { manager, tabs in
                _ = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/first")!, title: "First", to: space))
                _ = try #require(manager.makeGroup(with: tabs, name: "Reading"))
                manager.bookmarkTab(tabs[0], in: space)
                let member = try #require(tabs[2].bookmarkID)
                let group = try #require(Library.shared.pinnedGroup(containing: member))
                let pages = group.bookmarkIDs

                let entries = SavePath.placeEntries(of: member, in: space)
                #expect(!entries.contains { $0.kind == .everySpace })
                #expect(!entries.contains { $0.kind == .folder(group.id) })
                #expect(entries.contains { $0.kind == .folder(folder.id) })

                #expect(SavePath.move(member, to: SavePath.place(in: space, folder: folder.id)))
                #expect(Library.shared.folder(group.id)?.parentID == folder.id)
                #expect(Library.shared.folder(group.id)?.bookmarkIDs == pages)
                #expect(SavePath.placeEntries(of: member, in: space).first { $0.kind == .folder(folder.id) }?.isOn == true)

                #expect(SavePath.moveToTop(member, in: space))
                #expect(Library.shared.folder(group.id)?.parentID == nil)
                #expect(Array(Library.shared.bookmarks(in: space).prefix(3).map(\.id)) == pages)
                #expect(Library.shared.folder(group.id)?.bookmarkIDs == pages)

                #expect(SavePath.move(member, to: SavePath.place(in: space, folder: nil, newFolder: "Later")))
                let made = try #require(Library.shared.folders(in: space).first { $0.name == "Later" })
                #expect(Library.shared.folder(group.id)?.parentID == made.id)
                #expect(Library.shared.folder(group.id)?.bookmarkIDs == pages)

                // ⇧⌘D on a page of the pinned group: the picker files the group too.
                let page = try #require(SavePath.Page(tab: tabs[1]))
                _ = SavePath.save(page, to: SavePath.place(in: space, folder: folder.id), in: manager, name: "Reading")
                #expect(Library.shared.folder(group.id)?.parentID == folder.id)
                #expect(Library.shared.folder(group.id)?.bookmarkIDs == pages)
            }
        }
    }

    /// A split view pinned into a folder, then moved by the toast to another folder and the top: both pages go each
    /// time, and they stay a split.
    @Test func aSplitViewMovesAsOne() throws {
        try scratch { space, _, folder in
            try tabs(2, in: space) { manager, tabs in
                manager.makeSplit(tabs[0], with: tabs[1])
                let page = try #require(SavePath.Page(tab: tabs[0]))
                _ = SavePath.save(page, to: SavePath.place(in: space, folder: folder.id), in: manager)
                let ids = tabs.compactMap(\.bookmarkID)
                #expect(ids.count == 2)
                #expect(Library.shared.pinnedSplit(containing: ids[0])?.ids.sorted { $0.uuidString < $1.uuidString } == ids.sorted { $0.uuidString < $1.uuidString })
                #expect(Set(Library.shared.folder(folder.id)?.bookmarkIDs ?? []) == Set(ids))

                let other = try #require(Library.shared.addFolder(named: "Other", with: [], in: space))
                #expect(SavePath.move(ids[1], to: SavePath.place(in: space, folder: other.id)))
                #expect(Set(Library.shared.folder(other.id)?.bookmarkIDs ?? []) == Set(ids))
                #expect(Library.shared.folder(folder.id)?.bookmarkIDs.isEmpty != false)

                #expect(SavePath.moveToTop(ids[1], in: space))
                #expect(ids.allSatisfy { Library.shared.folderID(containing: $0) == nil })
                #expect(Set(Library.shared.bookmarks(in: space).prefix(2).map(\.id)) == Set(ids))
                #expect(Library.shared.pinnedSplit(containing: ids[0]) != nil)
            }
        }
    }

    /// The toast keeps the pin and its space from when it was made: after a switch to another space, its menu moves
    /// that pin in its own space, and each move is one ⌘Z.
    @Test func theToastMovesItsOwnPinInItsOwnSpaceUndoably() throws {
        try scratch { space, elsewhere, folder in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let tab = Tab(url: URL(string: "https://example.com/toast")!, spaceID: space)
            manager.adopt([tab], in: space)
            manager.select(tab)
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            defer { controller.window?.close() }
            _ = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/top")!, title: "Top", to: space))
            // One group per step, as each click is in the app.
            let undo = controller.sidebarUndo
            undo.groupsByEvent = false
            func step(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }
            step { controller.saveFromStar() }
            let item = try #require(controller.pinnedItem(of: tab))
            #expect(item.spaceID == space)
            manager.switchToSpace(elsewhere)
            #expect(manager.currentSpaceID == elsewhere)

            step { controller.moveSaved(item, to: .folder(folder.id)) }
            #expect(Library.shared.spaceID(ofBookmark: item.bookmarkID) == space)
            #expect(Library.shared.folderID(containing: item.bookmarkID) == folder.id)
            step { controller.moveSaved(item, to: .top) }
            #expect(Library.shared.bookmarks(in: space).first?.id == item.bookmarkID)
            #expect(Library.shared.bookmarks(in: elsewhere).isEmpty)

            undo.undo()
            #expect(Library.shared.folderID(containing: item.bookmarkID) == folder.id)
            undo.undo()
            #expect(Library.shared.folderID(containing: item.bookmarkID) == nil)
            #expect(Library.shared.bookmarks(in: space).last?.id == item.bookmarkID)
        }
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
        defer { suite.removeScratchSuite("SavePathTests.remembered") }
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

            controller.toggleBookmark(nil)
            #expect(tab.bookmarkID != nil)
            #expect(controller.sidebar.address.isSaved)

            controller.toggleBookmark(nil)
            #expect(tab.bookmarkID == nil)
            #expect(!controller.sidebar.address.isSaved)
        }
    }

    /// Pinned or unpinned some other way than the star or ⌘D (the row's menu, a drag, ⌘Z): the star shows it too.
    @Test func theStarFollowsAPinMadeFromTheRow() throws {
        try scratch { space, _, _ in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let tab = Tab(url: URL(string: "https://example.com/row")!, spaceID: space)
            manager.adopt([tab], in: space)
            manager.select(tab)
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            defer { controller.window?.close() }
            #expect(!controller.sidebar.address.isSaved)

            controller.bookmarkWithUndo(tab, at: nil, in: space)
            #expect(tab.bookmarkID != nil)
            #expect(controller.sidebar.address.isSaved)

            controller.sidebarUndo.undo()
            #expect(tab.bookmarkID == nil)
            #expect(!controller.sidebar.address.isSaved)

            controller.bookmarkWithUndo(tab, at: nil, in: space)
            controller.unbookmarkWithUndo(try #require(tab.bookmarkID), to: 0)
            let unpinned = try #require(manager.selectedTab)
            #expect(unpinned.bookmarkID == nil)
            #expect(!controller.sidebar.address.isSaved)
        }
    }

    /// Pin Tab and Pin Tab to Folder… in the menu bar are offered by the rule the star and the tab's menu use: not on
    /// Zigzag's own views.
    @Test func theMenuBarsPinFollowsTheStarsRule() throws {
        try scratch { space, _, _ in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let settings = Tab(url: try #require(URL(string: "zigzag://settings")), title: "Settings", spaceID: space)
            let page = Tab(url: try #require(URL(string: "https://example.com/menu")), title: "Page", spaceID: space)
            manager.adopt([settings, page], in: space)
            manager.select(settings)
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            defer { controller.window?.close() }
            let pin = NSMenuItem(title: "", action: #selector(BrowserWindowController.toggleBookmark(_:)), keyEquivalent: "")
            let folder = NSMenuItem(title: "", action: #selector(BrowserWindowController.savePageToFolder(_:)), keyEquivalent: "")
            #expect(!AddressView.canSave(for: settings))
            #expect(!controller.validateMenuItem(pin))
            #expect(!controller.validateMenuItem(folder))
            manager.select(page)
            #expect(AddressView.canSave(for: page))
            #expect(controller.validateMenuItem(pin))
            #expect(controller.validateMenuItem(folder))
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

    // MARK: The saved toast's chevron

    /// The menu behind the toast lists every place once, ticks the one the page is in, and ticks nothing of the
    /// space's while the page is a favorite.
    @Test func thePlaceMenuTicksWhereThePageIs() {
        let folders = [BookmarkFolder(name: "Reading"), BookmarkFolder(name: "Work")]
        let atTop = SavePath.placeEntries(folders: folders, folderID: nil, inEverySpace: false, isAtTop: true)
        #expect(atTop == [SavePath.PlaceEntry(kind: .everySpace, isOn: false),
                          SavePath.PlaceEntry(kind: .top, isOn: true),
                          SavePath.PlaceEntry(kind: .folder(folders[0].id), isOn: false),
                          SavePath.PlaceEntry(kind: .folder(folders[1].id), isOn: false)])
        // At the bottom of Pinned, outside every folder: nothing is ticked, since Top of Pinned is where it isn't.
        let atEnd = SavePath.placeEntries(folders: folders, folderID: nil, inEverySpace: false, isAtTop: false)
        #expect(atEnd.filter(\.isOn).isEmpty)
        let inWork = SavePath.placeEntries(folders: folders, folderID: folders[1].id, inEverySpace: false, isAtTop: false)
        #expect(inWork.filter(\.isOn).map(\.kind) == [.folder(folders[1].id)])
        let everywhere = SavePath.placeEntries(folders: folders, folderID: folders[0].id, inEverySpace: true, isAtTop: true)
        #expect(everywhere.filter(\.isOn).map(\.kind) == [.everySpace])
    }

    /// Top of Pinned in the picker puts the page at the very top, as its name says, not at the end.
    @Test func topOfPinnedIsTheTop() throws {
        try scratch { space, _, _ in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let first = try #require(SavePath.save(page("one"), to: SavePath.quickPlace(in: space), in: manager))
            let last = try #require(SavePath.save(page("two"), to: SavePath.quickPlace(in: space), in: manager))
            #expect(library.bookmarks(in: space).map(\.id) == [first.id, last.id])
            let place = SavePath.place(in: space, folder: nil, atTop: true)
            #expect(SavePath.move(last.id, to: place))
            #expect(library.bookmarks(in: space).map(\.id) == [last.id, first.id])
        }
    }

    /// The chevron's moves change where an already saved page sits, without saving it twice: into a folder, out of
    /// one to the top, and one record either way.
    @Test func thePlaceMenuMovesASavedPage() throws {
        try scratch { space, _, folder in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let saved = try #require(SavePath.save(page(), to: SavePath.quickPlace(in: space), in: manager))
            #expect(SavePath.move(saved.id, to: SavePath.place(in: space, folder: folder.id)))
            #expect(library.folderID(containing: saved.id) == folder.id)
            #expect(library.bookmarks(in: space).count == 1, "moved, not saved again")
            #expect(SavePath.moveToTop(saved.id, in: space))
            #expect(library.folderID(containing: saved.id) == nil)
        }
    }


    /// Zigzag's own views have an address but nothing to pin: the star isn't offered, and the save path refuses them
    /// as ⌘D and the menus already did (#442).
    @Test func zigzagsOwnViewsCannotBePinned() throws {
        #expect(!SavePath.Page.isPinnable(try #require(URL(string: "zigzag://settings"))))
        #expect(!SavePath.Page.isPinnable(try #require(URL(string: "zigzag://history"))))
        #expect(!SavePath.Page.isPinnable(try #require(URL(string: "about:blank"))))
        #expect(SavePath.Page.isPinnable(try #require(URL(string: "https://example.com/a"))))
        #expect(SavePath.Page.isPinnable(try #require(URL(string: "file:///tmp/a.pdf"))))
        let space = library.spaces[0].id
        let settings = Tab(url: try #require(URL(string: "zigzag://settings")), title: "Settings", spaceID: space)
        #expect(SavePath.Page(tab: settings) == nil)
        // The star is offered by the same rule the save path uses, so a Zigzag view hides it in the app too.
        #expect(!AddressView.canSave(for: settings))
        #expect(!AddressView.canSave(for: nil))
        let address = AddressView()
        address.setSaved(false, canSave: AddressView.canSave(for: settings))
        #expect(address.saveButton.isHidden)
        let page = Tab(url: try #require(URL(string: "https://example.com/")), title: "Example", spaceID: space)
        #expect(AddressView.canSave(for: page))
        address.setSaved(false, canSave: AddressView.canSave(for: page))
        #expect(!address.saveButton.isHidden)
        address.setSaved(true, canSave: SavePath.Page(tab: settings) != nil)
        #expect(address.saveButton.isHidden)
    }

    /// A pinned tab gone to a Zigzag view or about:blank still unpins with ⌘D and keeps its filled star; a new pin of
    /// one is still refused (#472).
    @Test func aPinnedTabShowingAZigzagViewStillUnpins() throws {
        try scratch { space, _, _ in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let blank = Tab(url: try #require(URL(string: "about:blank")), title: "Blank", spaceID: space)
            let settings = Tab(url: try #require(URL(string: "zigzag://settings")), title: "Settings", spaceID: space)
            manager.adopt([blank, settings], in: space)
            manager.select(blank)
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            defer { controller.window?.close() }
            #expect(!controller.save(settings, request: .quick))
            #expect(settings.bookmarkID == nil)
            #expect(!AddressView.canSave(for: blank))

            let pinned = SavePath.Page(url: try #require(URL(string: "https://example.com/pinned")), title: "Pinned", tab: blank)
            let saved = try #require(SavePath.save(pinned, to: SavePath.quickPlace(in: space), in: manager))
            #expect(blank.bookmarkID == saved.id)
            #expect(AddressView.canSave(for: blank))
            let address = AddressView()
            address.setSaved(true, canSave: AddressView.canSave(for: blank))
            #expect(!address.saveButton.isHidden)
            #expect(address.saveButton.symbol == "star.fill")

            #expect(controller.save(blank, request: .quick))
            #expect(blank.bookmarkID == nil)
            #expect(library.bookmark(saved.id) == nil)
        }
    }

    /// Dragged into Pinned, onto a folder or a pinned page, into the favorites, or from the command bar, a Zigzag view
    /// stays a tab (#472). A page split beside one doesn't take it along either.
    @Test func zigzagsOwnViewsCannotBeDraggedIntoPinned() throws {
        try scratch { space, _, folder in
            let manager = TabManager(spaceID: space)
            defer { manager.invalidate() }
            let settings = Tab(url: try #require(URL(string: "zigzag://settings")), title: "Settings", spaceID: space)
            let page = Tab(url: try #require(URL(string: "https://example.com/drag")), title: "Example", spaceID: space)
            manager.adopt([settings, page], in: space)
            manager.select(settings)
            let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            defer { controller.window?.close() }
            let pinned = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/pinned")!, title: "Pinned", to: space))
            let before = Library.shared.bookmarks(in: space).count
            #expect(!manager.canPin(settings))
            #expect(!SidebarListView.pinnable([.tab(settings.id)], in: manager))
            #expect(!SidebarListView.pinnable([.tab(page.id), .tab(settings.id)], in: manager))
            #expect(SidebarListView.pinnable([.tab(page.id), .bookmark(pinned.id), .folder(folder.id)], in: manager))
            controller.listBookmark(settings, at: 0, in: space)
            controller.listPinSplit(settings, onto: pinned.id, tabOnRight: true)
            controller.favoriteWithUndo(settings)
            controller.fileMarked([.tab(settings.id)], in: folder.id)
            #expect(settings.bookmarkID == nil && !settings.isFavorite)
            #expect(Library.shared.bookmarks(in: space).count == before)
            let actions = CommandRanker.contextActions(CommandRanker.context(for: manager)).map(\.id)
            #expect(!actions.contains("pin") && !actions.contains("pin-to-folder") && !actions.contains("favorite"))
            // Split beside Settings, the page would bring it into Pinned with it.
            manager.select(page)
            #expect(CommandRanker.contextActions(CommandRanker.context(for: manager)).map(\.id).contains("pin"))
            try #require(manager.canSplit(page, with: settings))
            manager.makeSplit(page, with: settings)
            #expect(!manager.canPin(page))
            controller.bookmarkWithUndo(page, at: nil, in: space)
            #expect(page.bookmarkID == nil && settings.bookmarkID == nil)
        }
    }
}
