import AppKit

/// Settings › Developer › Add Site…: asks for a site and turns Developer Mode on for it.
enum DevelopmentSiteSheet {
    @discardableResult
    static func add(in host: NSView) -> FormSheet {
        let field = FilledField(placeholder: "app.localtest.me")
        return FormSheet.show(in: host, title: String(localized: "Add a Site to Developer Mode", comment: "Title of the sheet that turns Developer Mode on for a site, from Settings › Developer."), symbol: DeveloperTool.modeSymbol,
                              message: String(localized: "The developer tools show on this site, on every port and on its subdomains.", comment: "Under the title of the sheet that turns Developer Mode on for a site, from Settings › Developer."),
                              rows: [FormSheet.Row(label: nil, view: field)],
                              confirmTitle: String(localized: "Add", comment: "Button that turns Developer Mode on for the site, in the sheet that adds a site to Developer Mode."),
                              canConfirm: { [weak field] in DevelopmentSites.entry(from: field?.stringValue ?? "") != nil }) { confirmed in
            guard confirmed, let site = DevelopmentSites.entry(from: field.stringValue) else { return }
            DevelopmentSites.add(site)
        }
    }
}
