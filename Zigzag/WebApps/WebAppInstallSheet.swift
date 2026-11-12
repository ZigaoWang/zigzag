import AppKit

/// File › Install as App… and Site Controls' ⋯ menu: a small sheet with the app's icon and its name to change, then
/// Install. The site's own icon arrives a moment later, once it's loaded; the name follows it until you edit it.
enum WebAppInstallSheet {
    #if DEBUG
    private(set) static weak var current: FormSheet?
    #endif

    static var title: String { String(localized: "Install as App…", comment: "File menu item and item in the … menu of Site Controls: makes the site an app of its own, with its own Dock icon.") }

    /// Only a web page in an everyday window: not a private one, Zigzag's own pages or a file.
    static func canInstall(_ tab: Tab?, isPrivate: Bool) -> Bool {
        guard let tab, !isPrivate, !tab.isPrivate, let url = tab.url else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    static func show(for tab: Tab, in controller: BrowserWindowController) {
        guard canInstall(tab, isPrivate: controller.tabManager.isPrivate), let url = tab.url,
              let host = controller.window?.contentView else { return }
        let spaceID = tab.spaceID
        let guess = String(tab.displayTitle.prefix(60))
        let name = FilledField(placeholder: String(localized: "App name", comment: "Placeholder of the name field in the Install as App sheet."))
        name.stringValue = guess
        let preview = NSImageView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityLabel(String(localized: "App icon", comment: "VoiceOver name of the icon in the Install as App sheet."))
        var picture: CGImage? = tab.favicon.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        func redraw() {
            let icon = WebAppIcon.render(picture, name: name.stringValue)
            preview.image = icon.map { NSImage(cgImage: $0, size: NSSize(width: 72, height: 72)) }
        }
        redraw()
        let rows = [
            FormSheet.Row(label: nil, view: preview, height: 72),
            FormSheet.Row(label: nil, view: name),
        ]
        let sheet = FormSheet.show(in: host, title: String(localized: "Install as App", comment: "Title of the sheet that makes the site an app of its own."),
                                   message: String(localized: "It gets its own window and Dock icon, and stays signed in as you are here.", comment: "Under the title of the Install as App sheet."),
                                   rows: rows, confirmTitle: String(localized: "Install", comment: "Button of the Install as App sheet."),
                                   canConfirm: { [weak name] in !(name?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) { [weak controller] confirmed in
            guard confirmed else { return }
            let chosen = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let icon = WebAppIcon.render(picture, name: chosen) else { return }
            WebAppInstaller.install(name: chosen, url: url, spaceID: spaceID, icon: icon) { app in
                guard let controller else { return }
                guard let app else {
                    Toast.show(String(localized: "Couldn’t install \(chosen)", comment: "Toast when Install as App fails. The placeholder is the app's name."),
                               symbol: "exclamationmark.triangle", duration: 4, in: controller)
                    return
                }
                Toast.show(String(localized: "Installed in your Applications folder", comment: "Toast after Install as App made the app."), symbol: "checkmark.circle",
                           action: (String(localized: "Show in Finder", comment: "Button in the toast after Install as App: shows the new app in Finder."),
                                    { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.bundlePath)]) }),
                           duration: 6, closes: true, in: controller)
            }
        }
        #if DEBUG
        current = sheet
        #endif
        // The page's own name and large icon, when they come.
        WebAppIconFinder.find(for: tab) { found in
            if let large = found.picture { picture = large }
            if name.stringValue == guess, !found.name.isEmpty { name.stringValue = found.name }
            redraw()
            sheet.revalidate()
        }
    }
}
