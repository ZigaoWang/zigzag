import AppKit

/// Settings › Developer › Add Site…: asks for a site and puts it on the list of development sites.
enum DevelopmentSiteSheet {
    @discardableResult
    static func add(in host: NSView) -> FormSheet {
        let field = FilledField(placeholder: "app.localtest.me")
        return FormSheet.show(in: host, title: String(localized: "Add a Development Site", comment: "Title of the sheet that adds a site to the list in Settings › Developer."), symbol: "hammer",
                              message: String(localized: "Developer tools show on this site, on every port and on its subdomains.", comment: "Under the title of the sheet that adds a site to the list in Settings › Developer."),
                              rows: [FormSheet.Row(label: nil, view: field)],
                              confirmTitle: String(localized: "Add", comment: "Button that adds the site, in the sheet that adds a development site."),
                              canConfirm: { [weak field] in DevelopmentSites.entry(from: field?.stringValue ?? "") != nil }) { confirmed in
            guard confirmed, let site = DevelopmentSites.entry(from: field.stringValue) else { return }
            DevelopmentSites.add(site)
        }
    }
}
