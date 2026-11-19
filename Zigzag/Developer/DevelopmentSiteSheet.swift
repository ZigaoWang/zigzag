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

/// Settings › Developer › Trusted Certificates › Add Site…: opens a local server so its certificate can be trusted
/// from the warning page. Only the servers this section can remember are accepted: https on this Mac or its network.
enum TrustedCertificateSheet {
    @discardableResult
    static func add(in host: NSView, open: @escaping (URL) -> Void) -> FormSheet {
        let field = FilledField(placeholder: "https://10.0.0.10:8443")
        return FormSheet.show(in: host, title: String(localized: "Add a Local Server", comment: "Title of the sheet that opens a local server so its certificate can be trusted, from Settings › Developer › Trusted Certificates."),
                              symbol: "lock",
                              message: String(localized: "Zigzag opens the server in a new tab. If its certificate isn’t trusted, choose Visit this site anyway on the warning. Only servers on this Mac or your network can be added.",
                                             comment: "Under the title of the sheet that opens a local server to trust its certificate."),
                              rows: [FormSheet.Row(label: nil, view: field)],
                              confirmTitle: String(localized: "Open", comment: "Button that opens the local server whose certificate is to be trusted, in the sheet from Settings › Developer."),
                              canConfirm: { [weak field] in url(from: field?.stringValue ?? "") != nil }) { confirmed in
            guard confirmed, let url = url(from: field.stringValue) else { return }
            open(url)
        }
    }

    /// The address the sheet accepts: https, with a local name or address, and no sign-in.
    static func url(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty,
              url.user == nil, url.password == nil,
              ErrorPage.isOnThisMac(url) || IconAddress.isLocal(url) else { return nil }
        return url
    }
}
