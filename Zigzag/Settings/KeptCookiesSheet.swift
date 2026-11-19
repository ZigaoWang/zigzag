import AppKit

/// Settings › Privacy › Keep cookies for these sites › Add Site… (#334).
enum KeptCookiesSheet {
    @discardableResult
    static func add(in host: NSView, profile: UUID) -> FormSheet {
        let field = FilledField(placeholder: "github.com")
        return FormSheet.show(in: host, title: String(localized: "Keep Cookies for a Site", comment: "Title of the sheet that adds a site whose cookies are kept, from Settings › Privacy."), symbol: "person.crop.circle.badge.checkmark",
                              message: String(localized: "Clear Cookies… and quitting leave its cookies alone, on http and https and every subdomain, so you stay signed in.", comment: "Under the title of the sheet that adds a site whose cookies are kept, from Settings › Privacy."),
                              rows: [FormSheet.Row(label: nil, view: field)],
                              confirmTitle: String(localized: "Add", comment: "Button that adds the site, in the sheet that adds a site whose cookies are kept."),
                              canConfirm: { [weak field] in KeptCookies.entry(from: field?.stringValue ?? "") != nil }) { confirmed in
            guard confirmed, let site = KeptCookies.entry(from: field.stringValue) else { return }
            KeptCookies.add(site, in: profile)
        }
    }
}
