import AppKit
import WebKit

/// The browser a site's pages are told they're in (#392), for sites that turn Zigzag away by its user agent. Chosen in
/// Site Controls and listed in Settings › Privacy › Sites. A site covers its subdomains and the most specific wins, as
/// with JavaScript. Private windows follow kept choices and don't offer the row, as other site choices.
@MainActor
enum SiteUserAgents {
    enum Choice: Equatable {
        case safari, chrome, firefox
        case custom(String)

        static let presets: [Choice] = [.safari, .chrome, .firefox]

        /// Safari's is Zigzag's own, written out so a subdomain can override a parent's choice with it.
        var string: String {
            switch self {
            case .safari: WebKitSetup.userAgent
            case .chrome: DeveloperState.UserAgent.chrome.string ?? ""
            case .firefox: DeveloperState.UserAgent.firefox.string ?? ""
            case .custom(let agent): agent
            }
        }

        var title: String {
            switch self {
            case .safari: "Safari"
            case .chrome: DeveloperTool.userAgentChrome.shortTitle
            case .firefox: DeveloperTool.userAgentFirefox.shortTitle
            case .custom: SiteUserAgents.customTitle
            }
        }

        var stored: String {
            switch self {
            case .safari: "safari"
            case .chrome: "chrome"
            case .firefox: "firefox"
            case .custom(let agent): "custom:" + agent
            }
        }

        init?(stored: String) {
            switch stored {
            case "safari": self = .safari
            case "chrome": self = .chrome
            case "firefox": self = .firefox
            default:
                guard stored.hasPrefix("custom:"), let agent = SiteUserAgents.cleaned(String(stored.dropFirst(7))) else { return nil }
                self = .custom(agent)
            }
        }

        var isCustom: Bool { if case .custom = self { true } else { false } }
    }

    /// Tests use their own.
    static var defaults: UserDefaults = .standard
    private static let key = "UserAgentSites"

    static var title: String { String(localized: "site.user-agent", defaultValue: "User agent", comment: "Row in the site panel's This Site group and in Settings › Privacy › Sites: the browser this site's pages are told they're in.") }
    static var defaultTitle: String { String(localized: "user-agent.default", defaultValue: "Default", comment: "First choice in the User agent dropdown of the site panel: the site gets Zigzag's own user agent, as any site.") }
    static var customTitle: String { String(localized: "user-agent.custom", defaultValue: "Custom", comment: "Choice in the User agent dropdown of the site panel and Settings › Privacy › Sites: the site is sent a user agent you typed.") }
    static var customAction: String { String(localized: "user-agent.custom-action", defaultValue: "Custom…", comment: "Item at the end of the User agent dropdown in the site panel: opens a sheet to type the user agent this site is sent.") }

    static var editCustomAction: String { String(localized: "user-agent.edit-custom-action", defaultValue: "Edit Custom…", comment: "Item at the end of the User agent dropdown in the site panel, once the site has a typed user agent: opens the sheet to change it.") }

    /// Hosts without "www.", each with its choice.
    static var all: [String: Choice] {
        get { (defaults.dictionary(forKey: key) as? [String: String] ?? [:]).compactMapValues(Choice.init(stored:)) }
        set { defaults.set(newValue.mapValues(\.stored), forKey: key) }
    }

    static var sites: Set<String> { Set(all.keys) }

    /// Longest allowed typed agent; real ones are under 300 characters.
    nonisolated static let maxLength = 512

    /// Trimmed, on one line, printable ASCII only (it's an HTTP header); nil when empty or not sendable.
    nonisolated static func cleaned(_ text: String) -> String? {
        let line = text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, line.count <= maxLength, line.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else { return nil }
        return line
    }

    /// The choice covering the page: its site's or a parent domain's, the most specific winning.
    static func choice(for url: URL?) -> Choice? {
        guard ["http", "https"].contains(url?.scheme?.lowercased() ?? ""), let site = ContentBlocker.site(of: url) else { return nil }
        let kept = all
        return kept.keys.filter { site == $0 || site.hasSuffix("." + $0) }.max { $0.count < $1.count }.flatMap { kept[$0] }
    }

    /// What a page at `url` is sent outside the developer tools: Firefox's on addons.mozilla.org, then the site's
    /// choice; nil for Zigzag's own.
    static func agent(for url: URL?) -> String? {
        if let url, Tab.addonsPage(url) != nil { return DeveloperState.UserAgent.firefox.string }
        return choice(for: url)?.string
    }

    /// Site Controls' dropdown: Default (nil), the presets, and the site's typed one while it has one.
    static func offered(with now: Choice?) -> [Choice?] {
        [nil] + Choice.presets + (now?.isCustom == true ? [now] : [])
    }

    /// A page's new window or pop-up, before its first request: sent the site's choice from the start.
    static func prepare(_ webView: WKWebView?, for url: URL?) {
        guard let webView, (webView.customUserAgent ?? "").isEmpty, let agent = agent(for: url) else { return }
        webView.customUserAgent = agent
    }

    /// Only the choice under this exact name, for Site Controls and Settings.
    static func choice(forSite site: String) -> Choice? { all[site] }

    /// Nil forgets it; parent and subdomain choices are untouched.
    static func set(_ choice: Choice?, for url: URL?) {
        guard let site = ContentBlocker.site(of: url) else { return }
        set(choice, forSite: site)
    }

    static func set(_ choice: Choice?, forSite site: String) {
        var kept = all
        kept[site] = choice
        all = kept
    }

    static func forget(site: String) { set(nil, forSite: site) }

    static func forgetAll() { defaults.removeObject(forKey: key) }

    /// From Site Controls: kept for the site; `tab` reloads when what its page is sent changed, other tabs on their
    /// next load.
    static func choose(_ choice: Choice?, for url: URL?, in tab: Tab?) {
        guard let site = ContentBlocker.site(of: url), tab?.isPrivate != true else { return }
        let page = tab.flatMap { $0.webView?.url ?? $0.url }
        let before = tab?.userAgent(at: page)
        set(choice, forSite: site)
        // Default under a parent domain's choice still has to mean Zigzag's own, which Safari's is.
        if choice == nil, self.choice(for: url) != nil { set(.safari, forSite: site) }
        guard let tab, before != tab.userAgent(at: page) else { return }
        Diagnostics.note("User agent", site: site, "\(choice.map { $0.isCustom ? "custom" : $0.stored } ?? "default"), reloaded", isPrivate: false)
        tab.reload()
    }

    /// Custom…: a sheet to type the agent, starting from the one the site is sent now.
    @discardableResult
    static func showCustomSheet(for url: URL, in host: NSView, tab: Tab?) -> FormSheet {
        let field = FilledField(placeholder: WebKitSetup.userAgent)
        field.stringValue = agent(for: url) ?? WebKitSetup.userAgent
        let site = ContentBlocker.site(of: url) ?? ""
        let sheet = FormSheet.show(in: host, title: String(localized: "Custom User Agent", comment: "Title of the sheet from Custom… in the site panel's User agent dropdown."),
                                   message: String(localized: "Pages on \(site) are sent this in place of Zigzag’s own.", comment: "Under the title of the Custom User Agent sheet. The placeholder is the site's name, like example.com."),
                                   rows: [FormSheet.Row(label: nil, view: field)],
                                   confirmTitle: String(localized: "Use", comment: "Button of the Custom User Agent sheet: the site is sent what was typed."),
                                   canConfirm: { [weak field] in cleaned(field?.stringValue ?? "") != nil }) { confirmed in
            guard confirmed, let agent = cleaned(field.stringValue) else { return }
            choose(.custom(agent), for: url, in: tab)
        }
        #if DEBUG
        customSheet = sheet
        #endif
        return sheet
    }

    #if DEBUG
    private(set) static weak var customSheet: FormSheet?
    #endif
}

extension Tab {
    /// What a page at `url` is sent: the developer tools' choice on a development site, else `SiteUserAgents.agent`.
    func userAgent(at url: URL?) -> String? {
        if let url, Self.addonsPage(url) != nil { return DeveloperState.UserAgent.firefox.string }
        return developerInEffect(at: url).userAgent.string ?? SiteUserAgents.agent(for: url)
    }

    /// Sets the web view's user agent for the page it's going to, when that differs.
    func applyUserAgent() {
        guard let webView else { return }
        let wanted = userAgent(at: webView.url ?? url)
        if (webView.customUserAgent ?? "") != (wanted ?? "") { webView.customUserAgent = wanted }
    }
}
