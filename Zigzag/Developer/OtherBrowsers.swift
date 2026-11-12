import AppKit
import UniformTypeIdentifiers

/// The other browsers on this Mac, for the developer tools' Open In (#141): the page you're building, as it is
/// somewhere else.
enum OtherBrowsers {
    struct Browser: Equatable {
        var name: String
        var url: URL
    }

    /// The apps that open web pages, without Zigzag's own (a copy of it, its Mini, a site installed as an app), by
    /// name. A browser takes both a web address and an HTML file, as the Mac's own list of browsers has it: an app
    /// that only takes links (a chat app that opens the ones you click) isn't one.
    static func all(for page: URL) -> [Browser] {
        let opensPages = Set(NSWorkspace.shared.urlsForApplications(toOpen: UTType.html))
        return browsers(among: NSWorkspace.shared.urlsForApplications(toOpen: page).filter(opensPages.contains)) { Bundle(url: $0)?.bundleIdentifier }
    }

    static func browsers(among apps: [URL], own: String = Bundle.main.bundleIdentifier ?? "wang.zigao.zigzag", bundleID: (URL) -> String?) -> [Browser] {
        // Every Zigzag there is shares the first three parts of its name: this one, a test copy, a site's own app.
        let family = own.split(separator: ".").prefix(3).joined(separator: ".")
        var seen = Set<String>()
        return apps.compactMap { app -> Browser? in
            guard let id = bundleID(app), !id.hasPrefix(family), seen.insert(id).inserted else { return nil }
            return Browser(name: app.deletingPathExtension().lastPathComponent, url: app)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func open(_ page: URL, in browser: Browser) {
        NSWorkspace.shared.open([page], withApplicationAt: browser.url, configuration: NSWorkspace.OpenConfiguration())
    }
}
