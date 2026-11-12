import AppKit

/// The menu bar follows the window in front (#165): an installed app's window gets the app's own menus
/// (`MainMenu.buildWebApp`), named for it, so ⌘Q quits that app alone and the browser's File › New Tab and the rest
/// aren't there to open things by surprise; any other window gets Zigzag's menus back. A sheet or a pop-up over an
/// app's window counts as that window.
final class WebAppMenuBar {
    /// A menu bar and the menus `NSApp` is told about while it shows.
    struct Bar {
        var menu: NSMenu
        var windows: NSMenu?
        var services: NSMenu?
        var help: NSMenu?
    }

    enum Kind: Equatable {
        case browser
        case webApp(name: String)
    }

    static private(set) var shared: WebAppMenuBar?

    private let browser: Bar
    private let makeWebApp: (String) -> Bar
    private let install: (Bar) -> Void
    private(set) var shown: Kind = .browser
    private var tokens: [NSObjectProtocol] = []

    init(browser: Bar, makeWebApp: @escaping (String) -> Bar, install: @escaping (Bar) -> Void) {
        self.browser = browser
        self.makeWebApp = makeWebApp
        self.install = install
    }

    /// Once the menu bar is built: it's the browser's, and from here on it follows the key window.
    static func start() {
        guard shared == nil, let menu = NSApp.mainMenu else { return }
        let bar = WebAppMenuBar(browser: Bar(menu: menu, windows: NSApp.windowsMenu, services: NSApp.servicesMenu, help: NSApp.helpMenu),
                                makeWebApp: { name in
                                    let built = MainMenu.buildWebApp(name: name)
                                    Shortcuts.applySaved(to: built.menu)
                                    return Bar(menu: built.menu, windows: built.windows, services: built.services, help: nil)
                                },
                                install: { bar in
                                    NSApp.mainMenu = bar.menu
                                    NSApp.windowsMenu = bar.windows
                                    NSApp.servicesMenu = bar.services
                                    NSApp.helpMenu = bar.help
                                })
        shared = bar
        let center = NotificationCenter.default
        // The window just made key is the key window.
        bar.tokens.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { shared?.follow(NSApp.keyWindow) }
        })
        // The app's window going with nothing else made key: Zigzag's menus come back, once it's gone.
        bar.tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { shared?.follow(NSApp.keyWindow) } }
        })
    }

    /// Shows the menus for the window now in front; nil (none) is Zigzag's own.
    func follow(_ window: NSWindow?) {
        show(window.map { Self.kind(of: $0) } ?? .browser)
    }

    func show(_ kind: Kind) {
        guard kind != shown else { return }
        shown = kind
        switch kind {
        case .browser: install(browser)
        case .webApp(let name): install(makeWebApp(name))
        }
    }

    /// Which menus a window wants: an installed app's window, or a sheet or child window over one, the app's.
    static func kind(of window: NSWindow) -> Kind {
        var current: NSWindow? = window
        while let w = current {
            if let name = appName(w) { return .webApp(name: name) }
            current = w.sheetParent ?? w.parent
        }
        return .browser
    }

    /// The app's name, for an installed app's own window.
    static var appName: (NSWindow) -> String? = { window in
        (window.delegate as? WebAppWindowController)?.app.name
    }
}
