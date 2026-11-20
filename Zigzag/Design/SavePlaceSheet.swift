import AppKit

/// The place picker ⇧ opens (#326): where in this space the page lands, a folder or a new one, and its name. Never
/// another space: a pin stays in the space it began in.
enum SavePlaceSheet {
    /// What the picker was answered with: where in the space the page goes, and what it's called.
    struct Answer {
        var place: SavePath.Place
        var name: String
    }

    /// Shows the picker over `host` for a page pinned from `spaceID`, opening on the last folder used there. Nothing
    /// is pinned until the button is clicked.
    @discardableResult
    static func show(page: SavePath.Page, spaceID: UUID, in host: NSView, completion: @escaping (Answer) -> Void) -> FormSheet {
        let library = Library.shared
        let space = library.space(spaceID)?.name ?? ""
        let last = SavePath.lastPlace(in: spaceID)

        let folderChoice = DropdownButton()
        let name = FilledField(placeholder: String(localized: "Name", comment: "Placeholder of the name field in the sheet that saves a page to a place: what the saved page is called."))
        name.stringValue = SavePath.name(of: page)
        let newFolder = FilledField(placeholder: String(localized: "New Folder", comment: "Placeholder of the field that names a new folder in the sheet that saves a page to a place."))
        let everySpace = Toggle(isOn: false)
        everySpace.setAccessibilityLabel(InEverySpace.title)

        /// The folders the folder menu offers, in its order: nil is the top of Pinned.
        var folderIDs: [UUID?] = []
        /// The row the new folder's field sits in, shown only once New Folder… is chosen.
        let newFolderRow = 2
        var form: FormSheet?

        func refreshFolders(_ folderID: UUID?) {
            let folders = library.folders(in: spaceID)
            folderIDs = [nil] + folders.map(\.id)
            folderChoice.options = [DropdownButton.Option(title: String(localized: "Top of Pinned", comment: "Choice in the sheet that saves a page to a place: among the space's pinned pages, in no folder."))]
                + folders.map { DropdownButton.Option(title: $0.name) }
            folderChoice.selectedIndex = folderID.flatMap { folderIDs.firstIndex(of: $0) } ?? 0
        }

        func showNewFolder(_ showing: Bool) {
            form?.setHidden(!showing, forRow: newFolderRow)
            form?.layoutSubtreeIfNeeded()
            if showing { newFolder.field.window?.makeFirstResponder(newFolder.field) }
        }

        refreshFolders(last.folderID)

        let rows = [
            FormSheet.Row(label: String(localized: "Folder", comment: "Label of the folder menu in the sheet that saves a page to a place."), view: folderChoice),
            FormSheet.Row(label: nil, view: name),
            FormSheet.Row(label: nil, view: newFolder, isHidden: true),
            FormSheet.Row(label: InEverySpace.title, view: everySpace),
        ]

        let sheet = FormSheet.show(in: host,
                                   title: String(localized: "Pin Page", comment: "Title of the sheet that pins the page you're on, with where in the space it goes and its name."),
                                   symbol: "star",
                                   message: String(localized: "The page is pinned in \(space). Add to Favorites shows it in all of the profile’s spaces instead.", comment: "Under the title of the sheet that pins a page: the space it's pinned in, which the sheet doesn't let you change, and what Add to Favorites means. The placeholder is the space's name."),
                                   rows: rows,
                                   confirmTitle: String(localized: "Pin Page", comment: "Button of the sheet that pins the page, with where in the space it goes and its name."),
                                   canConfirm: { !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { confirmed in
            guard confirmed else { return }
            let typed = newFolder.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let folder = typed.isEmpty && folderIDs.indices.contains(folderChoice.selectedIndex) ? folderIDs[folderChoice.selectedIndex] : nil
            let place = SavePath.place(in: spaceID, folder: folder, newFolder: typed.isEmpty ? nil : typed, inEverySpace: everySpace.isOn, atTop: typed.isEmpty && folder == nil)
            SavePath.remember(place)
            completion(Answer(place: place, name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        form = sheet

        // Making a folder is the folder menu's own last item, as filing is elsewhere: the field shows under it, and a
        // name typed there is what files the page in a new folder.
        folderChoice.actions = [DropdownButton.Action(title: String(localized: "New Folder…", comment: "Item at the foot of the folder menu in the sheet that saves a page to a place: names a new folder to save the page in."), symbol: "folder.badge.plus") {
            newFolder.stringValue = ""
            showNewFolder(true)
        }]
        folderChoice.onSelect = { _ in
            newFolder.stringValue = ""
            showNewFolder(false)
            form?.revalidate()
        }
        everySpace.onChange = { on in
            form?.setHidden(on, forRow: 0)
            form?.setHidden(on, forRow: newFolderRow)
            form?.layoutSubtreeIfNeeded()
            form?.revalidate()
        }
        return sheet
    }
}

/// The words of the Add to Favorites tick, shared by the picker and a pinned page's menu.
enum InEverySpace {
    static var title: String {
        String(localized: "Add to Favorites", comment: "A tick on a pinned page: it shows in every space of its profile, as a favorite does.")
    }
}
