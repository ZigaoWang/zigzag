import AppKit

/// One of the developer tools (#141), said once: its name, its symbol, what it does and the words that find it. The
/// menu bar, the command bar and Site Controls all take it from here, so a tool has one name wherever it shows.
enum DeveloperTool: String, CaseIterable {
    /// Puts the site you're on on the list of development sites, or takes it off.
    case site
    case clearCache = "clear-cache"
    case clearCookies = "clear-cookies"
    case console
    case inspect
    case reloadIgnoringCache = "reload-ignoring-cache"
    case viewSource = "view-source"
    /// Opens Settings › Developer.
    case settings
    case appearanceFollowsMac = "appearance-mac"
    case appearanceLight = "appearance-light"
    case appearanceDark = "appearance-dark"
    case printStyles = "print-styles"
    case sizeFill = "size-fill"
    case sizeCustom = "size-custom"
    case rotate
    case javaScript = "javascript"
    case outlines
    case userAgentZigzag = "user-agent-zigzag"
    case userAgentPhone = "user-agent-iphone"
    case userAgentTablet = "user-agent-ipad"
    case userAgentChrome = "user-agent-chrome"
    case userAgentFirefox = "user-agent-firefox"
    /// The page's address for a phone on the same network, as a QR code (`PhoneLink`).
    case phone = "open-on-phone"
    /// The page's size and filling the window, one after the other: the last size it had, or a phone's.
    case sizeToggle = "size-toggle"

    var title: String {
        switch self {
        case .site: Self.siteTitle(listed: false)
        case .clearCache: String(localized: "Clear Cache for This Site…", comment: "View › Developer menu item, command and item in the … menu of the site panel: clears the cache of the site you're on, after asking.")
        case .clearCookies: String(localized: "Clear Cookies for This Site…", comment: "View › Developer menu item, command and item in the … menu of the site panel: clears the cookies of the site you're on, after asking.")
        // Named as the menu bar's own items are.
        case .console: String(localized: "JavaScript Console", comment: "View › Developer menu item: opens the Web Inspector's console.")
        case .inspect: String(localized: "Inspect Element", comment: "View › Developer menu item: pick an element on the page to see it in the Web Inspector.")
        case .reloadIgnoringCache: String(localized: "Reload Ignoring Cache", comment: "View menu item.")
        case .viewSource: String(localized: "View Source", comment: "View › Developer menu item.")
        case .settings: String(localized: "Developer Settings…", comment: "Item in the ⋯ menu of the developer tools above the page, and a command: opens Settings › Developer.")
        case .appearanceFollowsMac: String(localized: "Page Appearance: Follow the Mac", comment: "View › Developer menu item and command, on a development site: the page looks light or dark as the Mac does, as any page.")
        case .appearanceLight: String(localized: "Page Appearance: Light", comment: "View › Developer menu item and command, on a development site: the page is asked for its light look, whatever the Mac's is.")
        case .appearanceDark: String(localized: "Page Appearance: Dark", comment: "View › Developer menu item and command, on a development site: the page is asked for its dark look, whatever the Mac's is.")
        case .printStyles: String(localized: "Show Print Styles", comment: "View › Developer menu item and command, on a development site, checked while on: the page is laid out with its styles for print.")
        case .sizeFill: String(localized: "Page Size: Fill the Window", comment: "View › Developer menu item and command, on a development site, checked while so: the page takes all its room in the window, as any page.")
        case .sizeCustom: String(localized: "Custom Page Size…", comment: "View › Developer menu item and command, on a development site: asks for a width and height for the page.")
        case .rotate: String(localized: "Rotate Page", comment: "View › Developer menu item and command, on a development site whose page has a size of its own: swaps its width and height.")
        case .javaScript: String(localized: "Disable JavaScript", comment: "View › Developer menu item and command, on a development site, checked while so: the page's scripts don't run.")
        case .outlines: String(localized: "Outline Every Element", comment: "View › Developer menu item and command, on a development site, checked while on: draws a line around each element of the page.")
        case .userAgentZigzag: String(localized: "User Agent: Zigzag", comment: "View › Developer menu item and command, on a development site: the page is told it's in Zigzag, as any page.")
        case .userAgentPhone: String(localized: "User Agent: Safari on iPhone", comment: "View › Developer menu item and command, on a development site: the page is told it's in Safari on an iPhone.")
        case .userAgentTablet: String(localized: "User Agent: Safari on iPad", comment: "View › Developer menu item and command, on a development site: the page is told it's in Safari on an iPad.")
        case .userAgentChrome: String(localized: "User Agent: Chrome", comment: "View › Developer menu item and command, on a development site: the page is told it's in Chrome on a Mac.")
        case .userAgentFirefox: String(localized: "User Agent: Firefox", comment: "View › Developer menu item and command, on a development site: the page is told it's in Firefox on a Mac.")
        case .sizeToggle: String(localized: "Toggle Page Size", comment: "View › Developer menu item and command, on a development site: gives the page the last size it had (a phone's at first), or takes it back to filling the window.")
        case .phone: String(localized: "Open on Your Phone…", comment: "View › Developer menu item, command and item in the ⋯ menu of the developer tools above the page, on a development site: shows a QR code of the page's address for a phone on the same network.")
        }
    }

    /// Its name in a menu that already says what it's about (Page Appearance's menu above the page).
    var shortTitle: String {
        switch self {
        case .appearanceFollowsMac: String(localized: "Follow the Mac", comment: "Choice in the Page Appearance menu of the developer tools above the page: the page looks light or dark as the Mac does.")
        case .appearanceLight: String(localized: "Light", comment: "Choice in the Page Appearance menu of the developer tools above the page: the page is asked for its light look.")
        case .appearanceDark: String(localized: "Dark", comment: "Choice in the Page Appearance menu of the developer tools above the page: the page is asked for its dark look.")
        case .sizeFill: String(localized: "Fill the Window", comment: "Choice in the Page Size menu of the developer tools above the page: the page takes all its room in the window, as any page.")
        case .userAgentZigzag: "Zigzag"
        case .userAgentPhone: String(localized: "Safari on iPhone", comment: "Choice under User Agent in the developer tools' menus: the page is told it's in Safari on an iPhone.")
        case .userAgentTablet: String(localized: "Safari on iPad", comment: "Choice under User Agent in the developer tools' menus: the page is told it's in Safari on an iPad.")
        case .userAgentChrome: "Chrome"
        case .userAgentFirefox: "Firefox"
        default: title
        }
    }

    /// The look this tool chooses, for the three that choose one.
    var appearance: DeveloperState.Appearance? {
        switch self {
        case .appearanceFollowsMac: .followsMac
        case .appearanceLight: .light
        case .appearanceDark: .dark
        default: nil
        }
    }

    /// The browser this tool tells the page it's in, for the five that choose one.
    var userAgent: DeveloperState.UserAgent? {
        switch self {
        case .userAgentZigzag: .zigzag
        case .userAgentPhone: .iPhone
        case .userAgentTablet: .iPad
        case .userAgentChrome: .chrome
        case .userAgentFirefox: .firefox
        default: nil
        }
    }

    /// The thing a tool is a choice or a part of, which its menus put under one name: a submenu of View ›
    /// Developer, a heading in the menus above the page.
    enum Group: CaseIterable {
        case appearance, size, userAgent

        var title: String {
            switch self {
            case .appearance: String(localized: "Page Appearance", comment: "Tooltip and menu heading of a button among the developer tools above a development site's page: how the page looks, light or dark, and with its print styles.")
            case .size: String(localized: "Page Size", comment: "Tooltip and menu heading of a button among the developer tools above a development site's page: gives the page the size of a phone, a tablet or one of your own.")
            case .userAgent: String(localized: "User Agent", comment: "Submenu of View › Developer and heading in the ⋯ menu of the developer tools above the page: the browser a development site's page is told it's in.")
            }
        }
    }

    var group: Group? {
        switch self {
        case .appearanceFollowsMac, .appearanceLight, .appearanceDark, .printStyles: .appearance
        case .sizeFill, .sizeCustom, .rotate, .sizeToggle: .size
        case .userAgentZigzag, .userAgentPhone, .userAgentTablet, .userAgentChrome, .userAgentFirefox: .userAgent
        default: nil
        }
    }

    /// One of several of which exactly one is in effect (a look, a size, a browser), rather than something on or off
    /// or something to do.
    var isChoice: Bool { appearance != nil || userAgent != nil || self == .sizeFill }

    /// Whether the tool is one that's on or chosen now, for the check beside it.
    func isChecked(in state: DeveloperState) -> Bool {
        if let appearance { return state.appearance == appearance }
        if let userAgent { return state.userAgent == userAgent }
        switch self {
        case .sizeFill: return state.size == nil
        case .printStyles: return state.printStyles
        case .javaScript: return state.javaScriptOff
        case .outlines: return state.outlines
        default: return false
        }
    }

    /// Whether the tool has something to do with the choices as they are: only a page with a size of its own turns.
    func applies(in state: DeveloperState) -> Bool { self != .rotate || state.size != nil }

    /// A word or two under its tile in Site Controls; its title is the tile's tooltip.
    var caption: String {
        switch self {
        case .console: String(localized: "Console", comment: "Under a tile in the site panel's Developer group: opens the JavaScript console.")
        case .inspect: String(localized: "Inspect", comment: "Under a tile in the site panel's Developer group: picks an element on the page to inspect.")
        case .reloadIgnoringCache: String(localized: "Reload", comment: "Under a tile in the site panel's Developer group: reloads the page ignoring the cache.")
        default: title
        }
    }

    /// Listing a site is named for what it will do, as Pin Tab and Unpin Tab are.
    static func siteTitle(listed: Bool) -> String {
        listed ? String(localized: "Remove This Site from Development Sites", comment: "View › Developer menu item and command, on a site that's on the list in Settings › Developer: takes it off, and the developer tools go from it.")
               : String(localized: "Add This Site to Development Sites", comment: "View › Developer menu item and command, on a site that isn't on the list in Settings › Developer: puts it on, and the developer tools show on it.")
    }

    var symbol: String {
        switch self {
        case .site: "hammer"
        case .clearCache: "arrow.clockwise"
        case .clearCookies: "trash"
        case .console: "terminal"
        case .inspect: "cursorarrow.rays"
        case .reloadIgnoringCache: "arrow.clockwise"
        case .viewSource: "curlybraces"
        case .settings: "gearshape"
        case .appearanceFollowsMac: "circle.lefthalf.filled"
        case .appearanceLight: "sun.max"
        case .appearanceDark: "moon"
        case .printStyles: "printer"
        case .sizeFill: "ipad.and.iphone"
        case .sizeCustom: "ruler"
        case .rotate: "rotate.right"
        case .javaScript: "curlybraces.square"
        case .outlines: "square.dashed"
        case .userAgentZigzag: "globe"
        case .userAgentPhone: "iphone"
        case .userAgentTablet: "ipad"
        case .userAgentChrome, .userAgentFirefox: "macwindow"
        case .phone: "qrcode"
        case .sizeToggle: "arrow.left.and.right.square"
        }
    }

    var action: Selector {
        switch self {
        case .site: #selector(BrowserWindowController.toggleDevelopmentSite(_:))
        case .clearCache: #selector(BrowserWindowController.clearSiteCache(_:))
        case .clearCookies: #selector(BrowserWindowController.clearSiteCookies(_:))
        case .console: #selector(BrowserWindowController.showJavaScriptConsole(_:))
        case .inspect: #selector(BrowserWindowController.inspectElement(_:))
        case .reloadIgnoringCache: #selector(BrowserWindowController.reloadPageFromOrigin(_:))
        case .viewSource: #selector(BrowserWindowController.viewSource(_:))
        case .settings: #selector(BrowserWindowController.showDeveloperSettings(_:))
        case .appearanceFollowsMac: #selector(BrowserWindowController.pageAppearanceFollowsMac(_:))
        case .appearanceLight: #selector(BrowserWindowController.pageAppearanceLight(_:))
        case .appearanceDark: #selector(BrowserWindowController.pageAppearanceDark(_:))
        case .printStyles: #selector(BrowserWindowController.togglePrintStyles(_:))
        case .sizeFill: #selector(BrowserWindowController.pageSizeFill(_:))
        case .sizeCustom: #selector(BrowserWindowController.pageSizeCustom(_:))
        case .rotate: #selector(BrowserWindowController.rotatePage(_:))
        case .javaScript: #selector(BrowserWindowController.toggleJavaScript(_:))
        case .outlines: #selector(BrowserWindowController.toggleOutlines(_:))
        case .userAgentZigzag: #selector(BrowserWindowController.userAgentZigzag(_:))
        case .userAgentPhone: #selector(BrowserWindowController.userAgentPhone(_:))
        case .userAgentTablet: #selector(BrowserWindowController.userAgentTablet(_:))
        case .userAgentChrome: #selector(BrowserWindowController.userAgentChrome(_:))
        case .userAgentFirefox: #selector(BrowserWindowController.userAgentFirefox(_:))
        case .phone: #selector(BrowserWindowController.openOnPhone(_:))
        case .sizeToggle: #selector(BrowserWindowController.togglePageSize(_:))
        }
    }

    /// The tool an action is, for what's handed the action alone (a menu item being validated).
    init?(action: Selector?) {
        guard let action, let tool = Self.allCases.first(where: { $0.action == action }) else { return nil }
        self = tool
    }

    /// Does what its menu item does, in `controller`'s window.
    func run(in controller: BrowserWindowController) { NSApp.sendAction(action, to: controller, from: nil) }

    /// The words the command bar finds it by, beside its name.
    var keywords: [String] {
        switch self {
        case .site: ["developer", "tools", "devtools", "development", "site", "localhost"]
        case .clearCache: ["clear", "cache", "site", "reload", "refresh", "developer"]
        case .clearCookies: ["clear", "cookies", "site", "sign", "out", "logout", "developer"]
        case .console: ["javascript", "console", "errors", "log", "developer", "devtools", "inspector"]
        case .inspect: ["inspect", "element", "pick", "developer", "devtools", "inspector"]
        case .reloadIgnoringCache: ["reload", "ignoring", "cache", "hard", "refresh", "developer"]
        case .viewSource: ["view", "source", "html", "developer"]
        case .settings: ["developer", "settings", "development", "sites", "devtools"]
        case .appearanceFollowsMac: ["page", "appearance", "follow", "mac", "system", "auto", "theme", "developer"]
        case .appearanceLight: ["page", "appearance", "light", "mode", "theme", "developer"]
        case .appearanceDark: ["page", "appearance", "dark", "mode", "theme", "developer"]
        case .printStyles: ["print", "styles", "media", "paper", "developer"]
        case .sizeFill: ["page", "size", "fill", "window", "full", "responsive", "developer"]
        case .sizeCustom: ["custom", "page", "size", "width", "height", "responsive", "device", "developer"]
        case .rotate: ["rotate", "page", "landscape", "portrait", "turn", "developer"]
        case .javaScript: ["disable", "javascript", "scripts", "off", "noscript", "developer"]
        case .outlines: ["outline", "every", "element", "layout", "boxes", "borders", "developer"]
        case .userAgentZigzag: ["user", "agent", "zigzag", "default", "developer"]
        case .userAgentPhone: ["user", "agent", "safari", "iphone", "mobile", "phone", "developer"]
        case .userAgentTablet: ["user", "agent", "safari", "ipad", "tablet", "developer"]
        case .userAgentChrome: ["user", "agent", "chrome", "developer"]
        case .userAgentFirefox: ["user", "agent", "firefox", "developer"]
        case .sizeToggle: ["toggle", "page", "size", "device", "responsive", "mobile", "fill", "developer"]
        case .phone: ["open", "phone", "mobile", "qr", "code", "device", "network", "lan", "wifi", "developer"]
        }
    }

    /// The count on the console's button: the page's errors, "99+" past that, nothing with none.
    static func errorBadge(_ count: Int) -> String { count <= 0 ? "" : count > 99 ? "99+" : String(count) }

    /// What VoiceOver says after the console's name while the page has errors.
    static func errorValue(_ count: Int) -> String? {
        count <= 0 ? nil : String(localized: "Errors: \(count)", comment: "Spoken by VoiceOver after JavaScript Console on a development site: how many errors the page has thrown since it loaded.")
    }

    /// Its shortcut as Zigzag ships it; none for most.
    /// ⌥⇧⌘D for listing the site: never a key a text field uses (⌃D deletes forward in every one of them, the
    /// address and a page's own fields included), and free in the menu bar and in macOS.
    /// ⌥⇧⌘M for Toggle Page Size: Chrome's device toolbar is ⇧⌘M, which is Mute Tab here, and ⌥⌘M is the system's
    /// Minimize All.
    var key: (String, NSEvent.ModifierFlags)? {
        switch self {
        case .site: ("d", [.command, .option, .shift])
        case .sizeToggle: ("m", [.command, .option, .shift])
        default: nil
        }
    }

    /// The tools with a tile of their own in Site Controls, where a development page doesn't have them above it.
    static let tiles: [DeveloperTool] = [.console, .inspect, .reloadIgnoringCache]

    /// The tools Developer tools adds to View › Developer. The others have had their items there all along.
    static let menuItems: [DeveloperTool] = [.site, .clearCache, .clearCookies, .appearanceFollowsMac, .appearanceLight, .appearanceDark, .printStyles,
                                           .sizeFill, .sizeCustom, .rotate, .sizeToggle,
                                           .userAgentZigzag, .userAgentPhone, .userAgentTablet, .userAgentChrome, .userAgentFirefox,
                                           .javaScript, .outlines, .phone]

    /// Its id among the command bar's commands.
    var commandID: String { Self.commandPrefix + rawValue }
    static let commandPrefix = "developer:"
    init?(commandID: String) {
        guard commandID.hasPrefix(Self.commandPrefix) else { return nil }
        self.init(rawValue: String(commandID.dropFirst(Self.commandPrefix.count)))
    }

    /// Whether the tool is offered for the page you're on. Listing a site: with Developer tools on, for a web page,
    /// and not in a private window. Every other tool: on a development tab; clearing has nothing to clear in a
    /// private window, which keeps nothing.
    /// A page's own size is for a page shown on its own: not in a split, whose panes share the window as they are.
    static func isOffered(_ tool: DeveloperTool, isOn: Bool, isDevelopment: Bool, url: URL?, isPrivate: Bool, inSplit: Bool = false) -> Bool {
        switch tool {
        case .site: isOn && DevelopmentSites.isOffered(for: url, isPrivate: isPrivate)
        case .clearCache, .clearCookies: isDevelopment && !isPrivate
        case .sizeFill, .sizeCustom, .rotate, .sizeToggle: isDevelopment && !inSplit
        case .console, .inspect, .reloadIgnoringCache, .viewSource, .settings,
             .appearanceFollowsMac, .appearanceLight, .appearanceDark, .printStyles, .javaScript, .outlines,
             .userAgentZigzag, .userAgentPhone, .userAgentTablet, .userAgentChrome, .userAgentFirefox, .phone: isDevelopment
        }
    }

    func isOffered(for tab: Tab?, isPrivate: Bool, inSplit: Bool = false) -> Bool {
        Self.isOffered(self, isOn: DeveloperTools.isOn, isDevelopment: tab?.isDevelopment == true, url: tab?.url, isPrivate: isPrivate, inSplit: inSplit)
    }
}
