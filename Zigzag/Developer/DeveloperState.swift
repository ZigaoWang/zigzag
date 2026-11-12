import AppKit
import WebKit

/// What you chose with the developer tools for one tab (#141): how its page should look, and the rest as each tool
/// comes. The tab's alone: never saved, never another tab's, gone when the tab closes. In effect only while the tab
/// is a development tab (`Tab.developerInEffect`): on any other site its page is as it would be without them, and
/// they apply again when the tab comes back.
nonisolated struct DeveloperState: Equatable {
    /// The look the page is asked for: the Mac's, as any page, or one of the two whatever the Mac's is.
    enum Appearance: Int, CaseIterable {
        case followsMac, light, dark

        /// The web view's appearance for it; none to follow the window.
        var name: NSAppearance.Name? {
            switch self {
            case .followsMac: nil
            case .light: .aqua
            case .dark: .darkAqua
            }
        }
    }

    var appearance = Appearance.followsMac
    /// The page is laid out with its styles for print, as it would be on paper.
    var printStyles = false
    /// The page's own size, in points; nil fills the room it has, as any page.
    var size: CGSize?

    /// The size the other way up.
    var rotatedSize: CGSize? { size.map { CGSize(width: $0.height, height: $0.width) } }

    /// The browser the page is told it's in: Zigzag's own, as any page, or another's, for a site that serves each
    /// its own page.
    enum UserAgent: Int, CaseIterable {
        case zigzag, iPhone, iPad, chrome, firefox

        /// What the page is sent in its place; nil for Zigzag's own. Each as its browser sent it in November 2026
        /// (Safari 27, Chrome 157, Firefox 160): the one place to bring them up to date. Safari on an iPhone or iPad
        /// names iOS 18.7 whatever it runs on, and Chrome names macOS 10.15.7: both keep that part still on purpose.
        var string: String? {
            switch self {
            case .zigzag: nil
            case .iPhone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"
            case .iPad: "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"
            case .chrome: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36"
            case .firefox: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:160.0) Gecko/20100101 Firefox/160.0"
            }
        }
    }

    var userAgent = UserAgent.zigzag
    /// The page's scripts don't run.
    var javaScriptOff = false
    /// Every element of the page is drawn with a line around it.
    var outlines = false

    /// Nothing is chosen: the page is as any page.
    var isUnchanged: Bool { self == DeveloperState() }

    /// Whether a change from `old` only shows once the page loads again: what a page is told and allowed as it
    /// loads, not how one already here is drawn.
    func needsReload(from old: DeveloperState) -> Bool { userAgent != old.userAgent || javaScriptOff != old.javaScriptOff }
}

extension Tab {
    /// The choices in effect on the page the tab shows, for what shows them: the tab's own on a development site,
    /// none anywhere else.
    var developerInEffect: DeveloperState { isDevelopment ? developer : DeveloperState() }

    /// The choices in effect on a page at `url`. What puts them on the page asks by the address its web view is
    /// going to, which is ahead of the page the tab shows while another is on its way: a page off the list never
    /// starts with them, and one on it starts with them from its first frame.
    /// A tab with nothing chosen (nearly every tab) answers at once, without reading the list: dark pages ask this
    /// of every open page each time they look at one.
    func developerInEffect(at url: URL?) -> DeveloperState {
        guard !developer.isUnchanged, DeveloperTools.applies(to: url) else { return DeveloperState() }
        return developer
    }

    /// The look chosen for a page at `url` in this tab, light or dark whatever the Mac's is; none to follow it.
    func chosenLook(at url: URL?) -> NSAppearance.Name? {
        guard developer.appearance != .followsMac else { return nil }
        return developerInEffect(at: url).appearance.name
    }

    /// Puts the choices in effect on the page: when one changes, when the web view's address does, when the tab
    /// becomes or stops being a development tab, and for a new web view. One path for all of them, so the page is
    /// never left with a choice nothing shows.
    func applyDeveloperState() {
        guard let webView else { return }
        let state = developerInEffect(at: webView.url ?? url)
        let media: String? = state.printStyles ? "print" : nil
        if webView.mediaType != media { webView.mediaType = media }
        if (webView.customUserAgent ?? "") != (state.userAgent.string ?? "") { webView.customUserAgent = state.userAgent.string }
        DarkPages.lookChanged(for: webView)
    }

    /// Puts into the page that's here what the developer tools put into a page itself (its outlines): once it has
    /// arrived, and when the choice changes. Never by the address a web view is going to: the page still showing
    /// would get it.
    func applyDeveloperStateToPage() {
        guard let webView else { return }
        PageOutlines.set(developerInEffect.outlines, in: webView)
    }

    /// Whether a page being gone to has to be asked for again: the web view asked for it as the browser the page
    /// it's leaving was told it's in, and this one is told another. So a site off the list is never asked for as an
    /// iPhone, and one on it never as Zigzag when you chose otherwise. Only a plain load you could make again: not
    /// Back or Forward, a reload, or a form's reply.
    static func asksAgain(sent: String?, wanted: String?, isGet: Bool, type: WKNavigationType) -> Bool {
        (sent ?? "") != (wanted ?? "") && isGet && type != .backForward && type != .reload && type != .formSubmitted && type != .formResubmitted
    }

    /// Whether a page at `url` in this tab is as its site made it: nothing chosen for it with the developer tools.
    /// What's learned from pages for later (a site's dark look, its colors) isn't learned from one that isn't.
    func pageIsUntouched(at url: URL?) -> Bool { developerInEffect(at: url).isUnchanged }
}

/// Outline Every Element (#141): a line around each element of the page, to see how it's laid out. One style in
/// the page, put in and taken out by name; it loads nothing and changes nothing else. A page that loads while it's
/// on gets it as it arrives (`Tab.applyDeveloperState` on each new address, and when the page has loaded).
enum PageOutlines {
    static let world = WKContentWorld.world(name: "zigzag-developer")
    static let styleID = "zigzag-developer-outlines"

    /// Run with `on` and the style's `id`: puts the style in, or takes it out.
    static let script = """
    const old = document.getElementById(id);
    if (!on) { if (old) old.remove(); return; }
    if (old || !document.documentElement) return;
    const style = document.createElement('style');
    style.id = id;
    style.textContent = '* { outline: 1px solid rgba(255, 45, 85, 0.55) !important; outline-offset: -1px !important; }';
    document.documentElement.appendChild(style);
    """

    /// Web views with the style in their page, so one that never had it is never run a script for it.
    private static let outlined = NSHashTable<WKWebView>.weakObjects()

    static func set(_ on: Bool, in webView: WKWebView) {
        guard on || outlined.contains(webView) else { return }
        if on { outlined.add(webView) } else { outlined.remove(webView) }
        webView.callAsyncJavaScript(script, arguments: ["on": on, "id": styleID], in: nil, in: world) { _ in }
    }
}
