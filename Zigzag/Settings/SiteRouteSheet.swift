import AppKit

/// Settings › Spaces › Add Site…: asks for a site and the space it always opens in (#286).
enum SiteRouteSheet {
    @discardableResult
    static func add(in host: NSView) -> FormSheet {
        let field = FilledField(placeholder: "youtube.com")
        let spaces = Library.shared.spaces
        let choice = DropdownButton()
        choice.options = spaces.map { DropdownButton.Option(title: $0.name) }
        // The space you're in is likely where the site is wanted.
        let current = BrowserWindowController.undoTarget?.tabManager.currentSpaceID
        choice.selectedIndex = spaces.firstIndex { $0.id == current } ?? 0
        return FormSheet.show(in: host, title: String(localized: "Always Open a Site in a Space", comment: "Title of the sheet that sends a site to a space, from Settings › Spaces."), symbol: "square.stack",
                              message: String(localized: "Links to the site and its subdomains open in this space, wherever they come from.", comment: "Under the title of the sheet that sends a site to a space, from Settings › Spaces."),
                              rows: [FormSheet.Row(label: nil, view: field),
                                     FormSheet.Row(label: String(localized: "Space", comment: "Label of the space menu in the sheet that sends a site to a space, from Settings › Spaces."), view: choice)],
                              confirmTitle: String(localized: "Add", comment: "Button that sends the site to the space, in the sheet that adds a site to Sites in Spaces."),
                              canConfirm: { [weak field] in SiteRoutes.entry(from: field?.stringValue ?? "") != nil }) { confirmed in
            guard confirmed, let site = SiteRoutes.entry(from: field.stringValue), spaces.indices.contains(choice.selectedIndex) else { return }
            Library.shared.setSiteRoute(site, to: spaces[choice.selectedIndex].id)
        }
    }
}
