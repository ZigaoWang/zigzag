import AppKit

/// The developer tools' menus for one tab's page (#141): a button's menu and ⋯'s, as the bar above the page has them,
/// and what ⋯ says of what's under it. Built from the tab and its window; every item runs its tool for that tab
/// (`BrowserWindowController.runDeveloperTool`), so a menu over another pane still acts on its own page.
@MainActor
struct DeveloperMenu {
    let tab: Tab?
    weak var controller: BrowserWindowController?

    private var isPrivate: Bool { controller?.tabManager.isPrivate ?? false }
    /// Whether the tab is one of a split's: the tools for a page shown on its own aren't offered there.
    private var inSplit: Bool { tab.flatMap { controller?.tabManager.shownSplit(for: $0) } != nil }

    /// One tool as an item. `short`: under a heading that already says what it's about.
    func entry(_ tool: DeveloperTool, short: Bool = false) -> MenuPanel.Entry {
        let state = tab?.developerInEffect ?? DeveloperState()
        let title = tool == .site ? DeveloperTool.siteShortTitle(listed: DevelopmentSites.covers(tab?.url))
            : tool == .pixelRatioDevice ? DeveloperTool.pixelRatioDeviceTitle(for: state.size, short: short)
            : short ? tool.shortTitle : tool.title
        return .item(.init(title: title, symbol: tool.symbol, isChecked: tab?.isDevelopment == true && tool.isChecked(in: state),
                           isEnabled: tool.isOffered(for: tab, isPrivate: isPrivate, inSplit: inSplit) && tool.applies(in: state),
                           shortcut: Shortcuts.keys(for: tool.action)) { [tab, weak controller] in controller?.runDeveloperTool(tool, on: tab) })
    }

    /// A button's menu: its tools in their groups, and for the page's size the listed sizes among them, the one the
    /// page has checked either way up.
    func entries(of part: DeveloperBarTools.Part) -> [MenuPanel.Entry] {
        let sets = DeveloperBarTools.grouped(part.tools)
        var groups = sets.map { set in
            (set.first?.choice?.heading.map { [MenuPanel.Entry.header($0)] } ?? []) + set.map { entry($0, short: part.title != nil) }
        }
        // The listed sizes are choices of the page's size, with Fill the Window.
        if let sizes = sets.firstIndex(where: { $0.first?.choice == .size }) {
            let state = tab?.developerInEffect ?? DeveloperState()
            let now = PageSizes.named(state.size)
            groups[sizes] += PageSizes.all.map { size in
                .item(.init(title: PageSizes.menuTitle(size),
                            isChecked: size == now, isEnabled: tab?.isDevelopment == true) { [weak controller] in controller?.setPageSize(size.size) })
            }
        }
        return (part.title.map { [.header($0)] } ?? []) + groups.joined(separator: [.separator]).map { $0 }
    }

    /// ⋯'s menu: the buttons `folded` into it, then the tools that are always under it, each list a line apart.
    func moreEntries(folded: some Sequence<DeveloperBarTools.Part>) -> [MenuPanel.Entry] {
        var entries = folded.map(entries(of:)).joined(separator: [.separator]).map { $0 }
        for group in DeveloperBarTools.moreGroups {
            if !entries.isEmpty { entries.append(.separator) }
            // The choices of one thing under its name.
            let heading = group.first?.group.flatMap { name in group.allSatisfy { $0.group == name } ? name.title : nil }
            if let heading { entries.append(.header(heading)) }
            entries += group.map { entry($0, short: heading != nil) }
            if group.contains(.userAgentZigzag) { entries += openInEntries() }
        }
        return entries
    }

    /// Open In: the page in the other browsers on this Mac.
    func openInEntries() -> [MenuPanel.Entry] {
        guard let url = tab?.url, tab?.isDevelopment == true else { return [] }
        let browsers = OtherBrowsers.all(for: url)
        guard !browsers.isEmpty else { return [] }
        let heading = String(localized: "Open In", comment: "Heading in the ⋯ menu of the developer tools above the page, over the other browsers on this Mac: opens the page in one of them.")
        return [.separator, .header(heading)] + browsers.map { browser in
            .item(.init(title: browser.name, image: NSWorkspace.shared.icon(forFile: browser.url.path)) { OtherBrowsers.open(url, in: browser) })
        }
    }

    /// ⋯'s symbol: filled while something chosen under it is in effect, so no choice is one nothing shows.
    static func moreSymbol(hasChoice: Bool) -> String { hasChoice ? "ellipsis.circle.fill" : "ellipsis" }

    /// What VoiceOver says after ⋯: the page's errors while it carries their count, else whether a choice under it is
    /// in effect.
    static func moreValue(errors: Int?, hasChoice: Bool) -> String? {
        if let errors, let said = DeveloperTool.errorValue(errors) { return said }
        return hasChoice ? String(localized: "Choices in effect", comment: "Spoken by VoiceOver after More Developer Tools while something chosen in its menu is in effect, like JavaScript off, another user agent, or a look the page was asked for while its button is in the menu.") : nil
    }
}
