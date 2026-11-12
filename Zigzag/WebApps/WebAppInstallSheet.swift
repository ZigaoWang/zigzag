import AppKit

/// File › Install as App… and Site Controls' ⋯ menu: a small sheet with the app's icon and its name to change, then
/// Install. While the site's own icon loads, Zigzag's spinner stands in its place and Install waits; the icon fades in
/// when it comes, or the one Zigzag has (the tab's, else the letter) after a few seconds. The name follows the site's
/// until you edit it. Installed, the app opens at once, as Chrome's do.
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
        let well = WebAppIconWell()
        var picture: CGImage? = tab.favicon.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        // The icon is in: shown, and Install can be pressed.
        var ready = false
        let rows = [
            FormSheet.Row(label: nil, view: well, height: WebAppIconWell.side),
            FormSheet.Row(label: nil, view: name),
        ]
        let sheet = FormSheet.show(in: host, title: String(localized: "Install as App", comment: "Title of the sheet that makes the site an app of its own."),
                                   message: String(localized: "It gets its own window and Dock icon, and stays signed in as you are here.", comment: "Under the title of the Install as App sheet."),
                                   rows: rows, confirmTitle: String(localized: "Install", comment: "Button of the Install as App sheet."),
                                   canConfirm: { [weak name] in ready && !(name?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }) { [weak controller] confirmed in
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
                WebAppInstaller.launch(app)
            }
        }
        #if DEBUG
        current = sheet
        #endif
        func redraw() { well.show(WebAppIcon.render(picture, name: name.stringValue)) }
        func settle() {
            guard !ready else { return }
            ready = true
            redraw()
            sheet.revalidate()
        }
        // The page's own name and large icon, when they come; the icon Zigzag has if they take longer than a moment.
        // One that comes after that still takes its place.
        well.startLoading()
        DispatchQueue.main.asyncAfter(deadline: .now() + WebAppIconWell.patience) { settle() }
        WebAppIconFinder.find(for: tab) { found in
            if let large = found.picture { picture = large }
            if name.stringValue == guess, !found.name.isEmpty { name.stringValue = found.name }
            if ready { redraw() } else { settle() }
        }
    }
}

/// The icon in the Install as App sheet: Zigzag's spinner while the site's icon loads, then the icon, faded in.
final class WebAppIconWell: NSView {
    static let side: CGFloat = 72
    /// How long the sheet waits for the site's icon before it settles for the one it has.
    static let patience: TimeInterval = 3

    private let image = NSImageView()
    private let spinner = Spinner()

    override init(frame: NSRect) {
        super.init(frame: frame)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel(String(localized: "App icon", comment: "VoiceOver name of the icon in the Install as App sheet."))
        image.alphaValue = 0
        [image, spinner].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func startLoading() { spinner.startAnimation(nil) }

    /// The icon: faded in the first time, swapped in place after.
    func show(_ icon: CGImage?) {
        image.image = icon.map { NSImage(cgImage: $0, size: NSSize(width: Self.side, height: Self.side)) }
        spinner.stopAnimation(nil)
        guard image.alphaValue < 1 else { return }
        Tokens.Motion.animate(Tokens.Motion.entering, evenFromKeyboard: true) { self.image.animator().alphaValue = 1 }
    }

    override func layout() {
        super.layout()
        image.frame = bounds
        let spin = Tokens.Space.x6
        spinner.frame = NSRect(x: round(bounds.midX - spin / 2), y: round(bounds.midY - spin / 2), width: spin, height: spin)
    }
}
