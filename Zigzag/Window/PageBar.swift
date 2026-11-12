import AppKit

/// The bar on top of a window that holds one page, Zigzag Mini's and an installed app's: in the page's own color, as a
/// web app's title bar is in Chrome and Safari, so bar and page read as one surface. The color is the one the site
/// asks for (its theme color, which WebKit picks for light or dark; an installed app's manifest color after it), as
/// long as it's on the page's side of light and dark, else the page's own background at the top. Its ink is light or
/// dark, whichever reads more clearly on it, and a hairline marks where it ends only when the page under it is so
/// close in color that nothing else would.
enum PageBar {
    /// The bar's color: `theme` (the page's theme color), else `fallback` (an installed app's manifest color), each
    /// only while it's light on a light page or dark on a dark one (a dark site can keep a white theme color for its
    /// header, which would sit as a white band over it); else `page`, the page's own color (`Tab.pageColor`). Nil
    /// with none: the bar stays plain.
    static func color(theme: NSColor?, fallback: NSColor? = nil, page: NSColor?) -> NSColor? {
        for candidate in [theme, fallback] {
            guard let candidate else { continue }
            guard let page else { return candidate }
            if TopBarView.isDark(candidate) == TopBarView.isDark(page) { return candidate }
        }
        return page
    }

    /// Whether the bar needs a line at its foot: only when it and the page are so close in color the edge would be
    /// lost. Unknown, the line stays, as a plain bar over a page that hasn't come yet.
    static func needsHairline(bar: NSColor?, page: NSColor?) -> Bool {
        guard let bar, let page else { return true }
        return Brand.contrast(bar, page) < hairlineContrast
    }

    /// Under this contrast two colors read as one surface.
    static let hairlineContrast = 1.25

    /// The bar's color for a tab: its theme color, the given fallback, its page's color.
    static func color(for tab: Tab, fallback: NSColor? = nil) -> NSColor? {
        color(theme: tab.webView?.themeColor ?? tab.themeColor, fallback: fallback, page: tab.pageColor)
    }
}

/// The bar's ground: its color across the top of the window, and the hairline at its foot when it needs one. Its
/// appearance, light or dark for its color, is what the bar's controls read their ink from.
final class PageBarView: ColorView {
    private let hairline = ColorView(color: Tokens.Color.separator)
    /// The ink the bar's controls take, to give them as their appearance.
    private(set) var inkAppearance: NSAppearance?

    init() {
        super.init(color: Tokens.Color.cardBackground)
        addSubview(hairline)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Paints the bar for a page: `bar` its color (nil: the page card's plain ground), `page` the page's own.
    func show(bar: NSColor?, page: NSColor?, animated: Bool) {
        let name = PaneHeaderView.inkAppearance(on: bar)
        inkAppearance = name.flatMap(NSAppearance.init(named:))
        appearance = inkAppearance
        setColor(bar ?? Tokens.Color.cardBackground, animated: animated, duration: Tokens.Motion.quick)
        hairline.isHidden = !PageBar.needsHairline(bar: bar, page: page)
    }

    override func layout() {
        super.layout()
        let line = 1 / (window?.backingScaleFactor ?? 2)
        hairline.frame = NSRect(x: 0, y: bounds.height - line, width: bounds.width, height: line)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}
