import AppKit

/// The developer tools' buttons (#141), in the bar above the page at its trailing end (`TopBarView.accessory`),
/// after the address: Console, Inspect Element, the page's look and size, reload's choices, and the rest under ⋯.
/// With the address kept in the sidebar the bar is there for them alone, on a development tab only, and they sit
/// at its trailing end the same; the address and the sidebar never move for them. In a narrow window the buttons
/// give way into ⋯, the last first. They're the bar's own kind of button, so they wear its ink and its fills.
///
/// Everything here is its own tab's (`show(_:in:)`): its buttons act on that page.
final class DeveloperBarTools: NSView, TopBarAccessory {

    /// One of the buttons: one tool, which it runs, or several, which it offers in a menu.
    struct Part {
        var symbol: String
        var tools: [DeveloperTool]
        /// Its name when it holds several tools; a single tool's is its own.
        var title: String?
    }

    /// The buttons, leading to trailing. The last gives way first.
    static let parts: [Part] = [
        Part(symbol: DeveloperTool.console.symbol, tools: [.console]),
        Part(symbol: DeveloperTool.inspect.symbol, tools: [.inspect]),
        Part(symbol: DeveloperTool.appearanceFollowsMac.symbol, tools: [.appearanceFollowsMac, .appearanceLight, .appearanceDark, .printStyles],
             title: DeveloperTool.Group.appearance.title),
        Part(symbol: DeveloperTool.sizeFill.symbol, tools: [.sizeFill, .sizeCustom, .rotate, .sizeToggle],
             title: DeveloperTool.Group.size.title),
        Part(symbol: "arrow.clockwise", tools: [.reloadIgnoringCache, .clearCache, .clearCookies],
             title: String(localized: "Reload Options", comment: "Tooltip of a button among the developer tools above a development site's page: opens a menu to reload ignoring the cache, or clear this site's cache or cookies.")),
    ]
    /// What ⋯ always holds, after the buttons that gave way: what's on or off, the browser the page is told it's
    /// in, and the rest. Each list is set apart by a line.
    static let moreGroups: [[DeveloperTool]] = [[.javaScript, .outlines],
                                                [.userAgentZigzag, .userAgentPhone, .userAgentTablet, .userAgentChrome, .userAgentFirefox],
                                                [.phone, .viewSource, .settings, .site]]
    static var moreTools: [DeveloperTool] { moreGroups.flatMap { $0 } }

    /// Whether something chosen under ⋯ is in effect, so its button can say so: a choice nothing shows is one
    /// you forget you made.
    static func hasHiddenChoice(_ state: DeveloperState) -> Bool { state.javaScriptOff || state.outlines || state.userAgent != .zigzag }

    /// Whether a page gets the tools above it: a development tab, shown on its own (a split's panes have the row
    /// above them for their own strips), with Tools above the page on. Where it's a development tab and this says
    /// no, Site Controls has the tools instead.
    static func shows(isDevelopment: Bool, showsInBar: Bool, inSplit: Bool) -> Bool { isDevelopment && showsInBar && !inSplit }

    /// How many of `count` buttons fit in `width`, beside ⋯, which always shows.
    static func fit(width: CGFloat, count: Int) -> Int {
        let b = Tokens.Sidebar.button
        return max(0, min(count, Int(floor((width - b) / b))))
    }

    /// The width `shown` buttons and ⋯ take, with the words after one of them (`words`, 0 for none).
    static func width(shown: Int, words: CGFloat = 0) -> CGFloat { CGFloat(shown + 1) * Tokens.Sidebar.button + words }

    private let buttons: [IconButton]
    /// The page's own size, said beside its button while it has one.
    private let sizeLabel = Label("", font: Tokens.Font.figures(Tokens.TypeSize.label), color: Tokens.Color.textSecondary)
    private let more = SidebarView.chromeButton("ellipsis", toolTip: String(localized: "More Developer Tools", comment: "Tooltip of the ⋯ button among the developer tools above a development site's page: opens a menu with the rest of the tools."))
    private(set) weak var tab: Tab?
    private weak var controller: BrowserWindowController?
    private var token: SignalToken?
    private var shortcutsToken: SignalToken?
    private(set) var shown = DeveloperBarTools.parts.count

    override init(frame: NSRect) {
        buttons = Self.parts.map { SidebarView.chromeButton($0.symbol, toolTip: "") }
        super.init(frame: frame)
        buttons.forEach(addSubview)
        addSubview(more)
        sizeLabel.isHidden = true
        sizeLabel.setAccessibilityElement(false)
        addSubview(sizeLabel)
        for (i, button) in buttons.enumerated() {
            button.onClick = { [weak self] _ in self?.pressed(i) }
        }
        more.onClick = { [weak self] _ in self?.showMore() }
        // Its shortcuts are said in its tooltips: they follow a change in Settings › Shortcuts.
        shortcutsToken = Shortcuts.changed.observe { [weak self] in self?.refreshTips() }
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Developer tools", comment: "VoiceOver name of the developer tools' buttons in the bar above a development site's page."))
        refreshTips()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Part of the bar: between its buttons a press moves the window, as anywhere on the bar.
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.titleBarMouseDown(event) }

    /// The bar is the top of the page's card, in the page's color: the buttons' fills are a page's.
    var isOnPage = false { didSet { (buttons + [more]).forEach { $0.isOnPage = isOnPage } } }

    /// The tab whose page it sits on, and the window that runs its tools.
    func show(_ tab: Tab?, in controller: BrowserWindowController?) {
        self.controller = controller
        if tab !== self.tab || token == nil {
            self.tab = tab
            token = tab?.changed.observe { [weak self, weak tab] change in
                guard let self, let tab, tab === self.tab else { return }
                if change == .pageErrors { self.refreshErrors() }
            }
        }
        refreshTips()
        refreshErrors()
        refreshChoices()
    }

    // MARK: Errors

    private var errorBadge: BadgeView?
    /// What ⋯ says of the choices under it, where it doesn't carry the count.
    private var hiddenChoiceValue: String? { didSet { if hiddenChoiceValue != oldValue { refreshErrors() } } }

    /// The page's errors, counted on the console's button, or on ⋯ while the console is under it.
    private func refreshErrors() {
        let count = tab?.pageErrorCount ?? 0
        let text = DeveloperTool.errorBadge(count)
        let console = Self.parts.firstIndex { $0.tools == [.console] }
        let holder = console.flatMap { $0 < shown ? buttons[$0] : nil } ?? more
        if text.isEmpty {
            errorBadge?.removeFromSuperview()
            errorBadge = nil
        } else {
            let badge = errorBadge ?? BadgeView(text: text, attention: false)
            badge.update(text: text, attention: false)
            if badge.superview !== holder { holder.addSubview(badge) }
            errorBadge = badge
        }
        // Said by the button that carries it; ⋯ otherwise says whether a choice under it is in effect.
        let errors = DeveloperTool.errorValue(count)
        if let console { buttons[console].setAccessibilityValue(holder === buttons[console] ? errors : nil) }
        more.setAccessibilityValue(holder === more ? errors ?? hiddenChoiceValue : hiddenChoiceValue)
    }

    // MARK: Size and names

    /// The page's own area as the card laid it out: the size said beside Page Size is the one the page really is.
    var pageRoom = NSSize.zero { didSet { if pageRoom != oldValue { refreshChoices() } } }
    /// How much smaller than its size the page is shown, to fit the window (`PageCardView.pageFit`); 1 at its size.
    var pageScale: CGFloat = 1 { didSet { if pageScale != oldValue { refreshChoices() } } }

    /// What's said beside Page Size: the page's size, and how large it's shown when that's smaller.
    static func sizeText(_ size: CGSize?, scale: CGFloat) -> String {
        guard let size else { return "" }
        let dimensions = PageSizes.dimensions(size)
        guard scale < 0.995 else { return dimensions }
        let percent = Int((scale * 100).rounded())
        return String(localized: "\(dimensions) at \(percent)%", comment: "Beside Page Size among the developer tools above the page, while a page larger than the window is shown smaller to fit: its size, then how large it's shown, like “1440 × 900 at 72%”.")
    }

    /// The size to say for a page of `chosen` size in `room`: the size it really is, which a small window cuts.
    static func shownSize(chosen: CGSize?, room: NSSize) -> CGSize? {
        guard let chosen else { return nil }
        guard room.width > 0, room.height > 0 else { return chosen }
        return CGSize(width: min(chosen.width, floor(room.width)), height: min(chosen.height, floor(room.height)))
    }

    /// Each button says its name, with its shortcut as the menu bar has it now.
    private func refreshTips() {
        for (part, button) in zip(Self.parts, buttons) {
            let tip = part.title ?? part.tools.first.map { Shortcuts.tooltip($0.title, for: $0.action) } ?? ""
            button.toolTip = tip
            button.setAccessibilityLabel(part.title ?? part.tools.first?.title)
        }
    }

    // MARK: Tools

    private var isPrivate: Bool { controller?.tabManager.isPrivate ?? false }

    private func run(_ tool: DeveloperTool) {
        guard let controller, tool.isOffered(for: tab, isPrivate: isPrivate) else { return }
        tool.run(in: controller)
    }

    /// `short`: under a heading that already says what it's about.
    private func entry(_ tool: DeveloperTool, short: Bool = false) -> MenuPanel.Entry {
        let title = tool == .site ? DeveloperTool.siteTitle(listed: DevelopmentSites.covers(tab?.url)) : short ? tool.shortTitle : tool.title
        let state = tab?.developerInEffect ?? DeveloperState()
        return .item(.init(title: title, symbol: tool.symbol, isChecked: tab?.isDevelopment == true && tool.isChecked(in: state),
                           isEnabled: tool.isOffered(for: tab, isPrivate: isPrivate) && tool.applies(in: state),
                           shortcut: Shortcuts.keys(for: tool.action)) { [weak self] in self?.run(tool) })
    }

    private func pressed(_ index: Int) {
        let part = Self.parts[index], button = buttons[index]
        guard part.tools.count > 1 else { part.tools.first.map(run); return }
        if let open = MenuPanel.current, open.anchor === button { open.close(); return }
        button.isSelected = true
        MenuPanel.show(entries(of: part), from: button) { [weak button] in button?.isSelected = false }
    }

    /// A button's menu: its tools in their groups, and for the page's size the listed sizes among them, the one the
    /// page has checked either way up.
    private func entries(of part: Part) -> [MenuPanel.Entry] {
        var groups = Self.grouped(part.tools).map { $0.map { entry($0, short: part.title != nil) } }
        if part.tools.contains(.sizeFill), !groups.isEmpty {
            let state = tab?.developerInEffect ?? DeveloperState()
            let now = PageSizes.named(state.size)
            groups[0] += PageSizes.all.map { size in
                .item(.init(title: PageSizes.menuTitle(size),
                            isChecked: size == now, isEnabled: tab?.isDevelopment == true) { [weak self] in self?.controller?.setPageSize(size.size) })
            }
        }
        return (part.title.map { [.header($0)] } ?? []) + groups.joined(separator: [.separator]).map { $0 }
    }

    /// Open In: the page in the other browsers on this Mac.
    private func openInEntries() -> [MenuPanel.Entry] {
        guard let url = tab?.url, tab?.isDevelopment == true else { return [] }
        let browsers = OtherBrowsers.all(for: url)
        guard !browsers.isEmpty else { return [] }
        let heading = String(localized: "Open In", comment: "Heading in the ⋯ menu of the developer tools above the page, over the other browsers on this Mac: opens the page in one of them.")
        return [.separator, .header(heading)] + browsers.map { browser in
            .item(.init(title: browser.name, image: NSWorkspace.shared.icon(forFile: browser.url.path)) { OtherBrowsers.open(url, in: browser) })
        }
    }

    /// A button's tools as its menu has them: the choices of one thing together, a line before what stands apart.
    static func grouped(_ tools: [DeveloperTool]) -> [[DeveloperTool]] {
        let choices = tools.filter(\.isChoice)
        let rest = tools.filter { !$0.isChoice }
        return [choices, rest].filter { !$0.isEmpty }
    }

    /// The device a size is nearest, either way up: a phone by its short side; then a tablet, squarer than a
    /// laptop's screen (an iPad is 4:3 to 3:2, a laptop 16:10 or wider) and no larger than the largest iPad.
    static func symbol(forSize size: CGSize) -> String {
        let short = min(size.width, size.height), long = max(size.width, size.height)
        if short < 500 { return "iphone" }
        return long / short < 1.55 && long < 1400 ? "ipad" : "laptopcomputer"
    }

    /// The symbol of a button that holds a choice says which is in effect: the sun, the moon, a printer.
    static func symbol(of part: Part, in state: DeveloperState) -> String {
        if part.tools.contains(.sizeFill) {
            guard let size = state.size else { return part.symbol }
            return symbol(forSize: size)
        }
        guard part.tools.contains(where: { $0.appearance != nil }) else { return part.symbol }
        if state.printStyles { return DeveloperTool.printStyles.symbol }
        return part.tools.first { $0.appearance == state.appearance }?.symbol ?? part.symbol
    }

    /// The tab's choices, shown on the buttons that hold them.
    private func refreshChoices() {
        let state = tab?.developerInEffect ?? DeveloperState()
        for (part, button) in zip(Self.parts, buttons) {
            let symbol = Self.symbol(of: part, in: state)
            if button.symbol != symbol { button.symbol = symbol }
            if part.tools.contains(.sizeFill) { button.setAccessibilityValue(state.size == nil ? nil : Self.sizeText(Self.shownSize(chosen: state.size, room: pageRoom), scale: pageScale)) }
        }
        let hidden = Self.hasHiddenChoice(state)
        let symbol = hidden ? "ellipsis.circle.fill" : "ellipsis"
        if more.symbol != symbol { more.symbol = symbol }
        hiddenChoiceValue = hidden ? String(localized: "Choices in effect", comment: "Spoken by VoiceOver after More Developer Tools while something chosen in its menu is in effect: JavaScript off, another user agent, or outlines.") : nil
        let size = Self.sizeText(Self.shownSize(chosen: state.size, room: pageRoom), scale: pageScale)
        if sizeLabel.stringValue != size {
            sizeLabel.stringValue = size
            needsLayout = true
            // The bar gives the tools the width they ask for: asked again.
            superview?.needsLayout = true
        }
    }

    /// The buttons there's no room for, then the tools that are always under ⋯.
    private func showMore() {
        if let open = MenuPanel.current, open.anchor === more { open.close(); return }
        var entries = Self.parts.dropFirst(shown).map(entries(of:)).joined(separator: [.separator]).map { $0 }
        for group in Self.moreGroups {
            if !entries.isEmpty { entries.append(.separator) }
            // The choices of one thing under its name.
            let heading = group.first?.group.flatMap { name in group.allSatisfy { $0.group == name } ? name.title : nil }
            if let heading { entries.append(.header(heading)) }
            entries += group.map { entry($0, short: heading != nil) }
            if group.contains(.userAgentZigzag) { entries += openInEntries() }
        }
        more.isSelected = true
        MenuPanel.show(entries, from: more) { [weak self] in self?.more.isSelected = false }
    }

    /// The words after Page Size's button while the page has a size of its own, with the gap before the next button.
    private var sizeWords: CGFloat { sizeLabel.stringValue.isEmpty ? 0 : ceil(sizeLabel.fittingSize.width) + Tokens.Space.x2 }
    private var sizeIndex: Int? { Self.parts.firstIndex { $0.tools.contains(.sizeFill) } }

    /// How many buttons show in `room`, and whether the page's size is said: it is where there's room for it and
    /// its button; the button gives way as any other.
    private func fitted(in room: CGFloat) -> (shown: Int, words: CGFloat) {
        let words = sizeWords
        let withWords = Self.fit(width: room - words, count: buttons.count)
        if words > 0, let sizeIndex, sizeIndex < withWords { return (withWords, words) }
        return (Self.fit(width: room, count: buttons.count), 0)
    }

    func width(fitting room: CGFloat) -> CGFloat {
        let b = Tokens.Sidebar.button
        guard room >= b else { return 0 }
        let fit = fitted(in: room)
        return Self.width(shown: fit.shown, words: fit.words)
    }

    override func layout() {
        super.layout()
        let b = Tokens.Sidebar.button
        let fit = fitted(in: bounds.width)
        shown = fit.shown
        sizeLabel.isHidden = fit.words == 0
        // At the trailing end of whatever room they were given: ⋯ last, the buttons before it.
        var x = bounds.width - Self.width(shown: shown, words: fit.words)
        let y = round((bounds.height - b) / 2)
        for (i, button) in buttons.enumerated() {
            button.isHidden = i >= shown
            guard i < shown else { continue }
            button.frame = NSRect(x: x, y: y, width: b, height: b)
            x += b
            if fit.words > 0, i == sizeIndex {
                let height = ceil(sizeLabel.fittingSize.height)
                sizeLabel.frame = NSRect(x: x, y: y + floor((b - height) / 2), width: fit.words - Tokens.Space.x2, height: height)
                x += fit.words
            }
        }
        more.frame = NSRect(x: x, y: y, width: b, height: b)
        // The count goes with the console's button, wherever that is now.
        refreshErrors()
    }

}
