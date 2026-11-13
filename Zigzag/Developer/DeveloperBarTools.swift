import AppKit

/// The developer tools' bar (#141), above a page in Developer Mode (`TopBarView.accessory`), as Arc's: with the
/// address kept in the sidebar, the page's whole address from the page's left edge (`DeveloperAddressView`), in
/// monospaced figures, taking the room there is, and Copy Link beside it; then, at the trailing end, the tools in
/// groups a thin line apart: Console and Inspect Element; the page's look and size, the size to type into while it
/// has one; reload's choices and ⋯ with the rest. With the address in the bar already, the tools alone, after it.
/// In a narrow window the address gives up its room first, then the buttons give way into ⋯, the last first.
/// They're the bar's own kind of button, so they wear its ink and its fills.
///
/// Everything here is its own tab's (`show(_:in:)`): its buttons act on that page.
final class DeveloperBarTools: NSView, TopBarAccessory {

    /// One of the buttons: one tool, which it runs, or several, which it offers in a menu.
    struct Part {
        var symbol: String
        var tools: [DeveloperTool]
        /// Its name when it holds several tools; a single tool's is its own.
        var title: String?
        /// The group it's in: a thin line sets each group apart from the next.
        var group: Int
    }

    /// The buttons, leading to trailing. The last gives way first.
    static let parts: [Part] = [
        Part(symbol: DeveloperTool.console.symbol, tools: [.console], group: 1),
        Part(symbol: DeveloperTool.inspect.symbol, tools: [.inspect], group: 1),
        Part(symbol: DeveloperTool.appearanceFollowsMac.symbol, tools: [.appearanceFollowsMac, .appearanceLight, .appearanceDark, .printStyles],
             title: DeveloperTool.Group.appearance.title, group: 2),
        Part(symbol: DeveloperTool.sizeFill.symbol, tools: [.sizeFill, .sizeCustom, .rotate, .sizeToggle],
             title: DeveloperTool.Group.size.title, group: 2),
        Part(symbol: "arrow.clockwise", tools: [.reloadIgnoringCache, .clearCache, .clearCookies],
             title: String(localized: "Reload Options", comment: "Tooltip of a button among the developer tools above a development site's page: opens a menu to reload ignoring the cache, or clear this site's cache or cookies."), group: 3),
    ]
    /// The address and Copy Link's group, and ⋯'s, which goes with reload's.
    private static let addressGroup = 0, moreGroup = 3
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

    /// Where everything goes in a bar `width` wide: the address and Copy Link when `address` (the address is in
    /// the sidebar), as many buttons as fit and ⋯, the lines between groups, and the page's size after its button,
    /// `readout` wide with its name and without (nil: the page has no size of its own).
    struct Layout: Equatable {
        var address: NSRect?
        var copy: NSRect?
        var buttons: [NSRect] = []
        var readout: NSRect?
        var readoutNamed = false
        var more: NSRect
        var lines: [NSRect] = []
        /// How many of `parts` show; the rest are under ⋯.
        var shown: Int { buttons.count }
        /// The width the tools take from the trailing end: all of it with the address.
        var width: CGFloat
    }

    /// The least the address keeps before the buttons give way.
    static let addressMinWidth: CGFloat = 160
    /// The room a line between two groups takes, the line in its middle.
    static let lineRoom = Tokens.Space.x3

    static func layout(width: CGFloat, height: CGFloat = TopBarView.height, address: Bool, readout: (named: CGFloat, bare: CGFloat)? = nil) -> Layout {
        let b = Tokens.Sidebar.button, y = round((height - b) / 2)
        let sizeIndex = parts.firstIndex { $0.tools.contains(.sizeFill) }
        // The tools' width with `count` buttons and the size at `words` (0: not said).
        func toolsWidth(_ count: Int, words: CGFloat) -> CGFloat {
            var groups = parts.prefix(count).map(\.group) + [moreGroup]
            if address { groups.insert(addressGroup, at: 0) }
            let lines = zip(groups, groups.dropFirst()).filter { $0 != $1 }.count
            return CGFloat(count + 1 + (address ? 1 : 0)) * b + CGFloat(lines) * lineRoom + words
        }
        let leading = address ? addressMinWidth + Tokens.Space.x1 : 0
        // The most buttons that fit, the size said in full, then without its name, then not at all.
        var choice: (count: Int, words: CGFloat, named: Bool) = (0, 0, false)
        search: for count in stride(from: parts.count, through: 0, by: -1) {
            var options: [(CGFloat, Bool)] = [(0, false)]
            if let readout, let sizeIndex, sizeIndex < count { options = [(readout.named, true), (readout.bare, false), (0, false)] }
            for (words, named) in options where toolsWidth(count, words: words) + leading <= width {
                choice = (count, words, named)
                break search
            }
        }
        let tools = toolsWidth(choice.count, words: choice.words)
        guard address || tools <= width else { return Layout(more: .zero, width: 0) }
        var layout = Layout(more: .zero, width: address ? width : tools)
        var x = width - tools
        var group = address ? addressGroup : parts.first?.group ?? 0
        func line(before next: Int) {
            guard next != group else { return }
            let h = Tokens.Space.x4
            layout.lines.append(NSRect(x: round(x + lineRoom / 2), y: round((height - h) / 2), width: Tokens.Metric.hairline, height: h))
            x += lineRoom
            group = next
        }
        if address {
            layout.address = NSRect(x: 0, y: y, width: max(0, x - Tokens.Space.x1), height: b)
            layout.copy = NSRect(x: x, y: y, width: b, height: b)
            x += b
        }
        for (i, part) in parts.prefix(choice.count).enumerated() {
            line(before: part.group)
            layout.buttons.append(NSRect(x: x, y: y, width: b, height: b))
            x += b
            if i == sizeIndex, choice.words > 0 {
                layout.readout = NSRect(x: x, y: y, width: choice.words, height: b)
                layout.readoutNamed = choice.named
                x += choice.words
            }
        }
        line(before: moreGroup)
        layout.more = NSRect(x: x, y: y, width: b, height: b)
        return layout
    }

    private let buttons: [IconButton]
    private let address = DeveloperAddressView()
    private let copyButton = SidebarView.chromeButton("link", toolTip: "")
    private let lines = (0..<4).map { _ in ColorView(color: Tokens.Color.separator) }
    /// The page's own size beside its button while it has one: its name, and its width and height to type into.
    private let sizeReadout = PageSizeReadout()
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
        address.onClick = { [weak self] _ in
            guard let self, let tab = self.tab else { return }
            self.controller?.editAddress(of: tab, from: self.address)
        }
        address.onRightClick = { [weak self] _ in self?.addressMenu() }
        copyButton.onClick = { [weak self] _ in self?.controller?.copyPageURL(nil) }
        [address, copyButton].forEach { $0.isHidden = true; addSubview($0) }
        lines.forEach { $0.isHidden = true; addSubview($0) }
        sizeReadout.isHidden = true
        sizeReadout.onSize = { [weak self] size in self?.controller?.setPageSize(size) }
        sizeReadout.onMenu = { [weak self] in self?.showSizeMenu() }
        addSubview(sizeReadout)
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
    var isOnPage = false {
        didSet {
            (buttons + [more, copyButton]).forEach { $0.isOnPage = isOnPage }
            sizeReadout.isOnPage = isOnPage
            address.isOnPage = isOnPage
        }
    }

    /// The tab whose page it sits on, and the window that runs its tools.
    func show(_ tab: Tab?, in controller: BrowserWindowController?) {
        self.controller = controller
        if tab !== self.tab || token == nil {
            self.tab = tab
            token = tab?.changed.observe { [weak self, weak tab] change in
                guard let self, let tab, tab === self.tab else { return }
                if change == .pageErrors { self.refreshErrors() }
                if change == .url || change == .navigation { self.address.show(tab.url, notSecure: tab.isNotSecure) }
            }
        }
        address.show(tab?.url, notSecure: tab?.isNotSecure ?? false)
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
        let holder: IconButton = console.flatMap { $0 < shown ? buttons[$0] : nil } ?? more
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
        copyButton.toolTip = Shortcuts.tooltip(Self.copyTitle, for: #selector(BrowserWindowController.copyPageURL(_:)))
        copyButton.setAccessibilityLabel(Self.copyTitle)
        for (part, button) in zip(Self.parts, buttons) {
            let tip = part.title ?? part.tools.first.map { Shortcuts.tooltip($0.title, for: $0.action) } ?? ""
            button.toolTip = tip
            button.setAccessibilityLabel(part.title ?? part.tools.first?.title)
        }
    }

    // MARK: Tools

    private static var copyTitle: String { String(localized: "Copy Link", comment: "Edit menu item.") }

    /// The address's own menu: copy it, or edit it.
    private func addressMenu() -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: Self.copyTitle, action: #selector(BrowserWindowController.copyPageURL(_:)), keyEquivalent: "")
        copy.target = controller
        menu.addItem(copy)
        let edit = NSMenuItem(title: String(localized: "Edit Address", comment: "Item in the menu of the page's whole address in the developer tools' bar: opens it for editing, as clicking it does."), action: #selector(BrowserWindowController.openLocation(_:)), keyEquivalent: "")
        edit.target = controller
        menu.addItem(edit)
        return menu
    }

    /// Whether the bar shows the page's whole address: the address itself is in the sidebar.
    private var showsAddress: Bool { (superview as? TopBarView).map { !$0.holdsAddress } ?? false }

    private var isPrivate: Bool { controller?.tabManager.isPrivate ?? false }

    private func run(_ tool: DeveloperTool) {
        guard let controller, tool.isOffered(for: tab, isPrivate: isPrivate) else { return }
        tool.run(in: controller)
    }

    /// `short`: under a heading that already says what it's about.
    private func entry(_ tool: DeveloperTool, short: Bool = false) -> MenuPanel.Entry {
        let title = tool == .site ? DeveloperTool.siteShortTitle(listed: DevelopmentSites.covers(tab?.url)) : short ? tool.shortTitle : tool.title
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

    /// Page Size's menu from the size beside its button, pressed off its fields.
    private func showSizeMenu() {
        guard let sizeIndex else { return }
        if let open = MenuPanel.current, open.anchor === sizeReadout { open.close(); return }
        sizeReadout.isSelected = true
        MenuPanel.show(entries(of: Self.parts[sizeIndex]), from: sizeReadout) { [weak self] in self?.sizeReadout.isSelected = false }
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
        let before = sizeReadout.width(withName: true)
        sizeReadout.show(size: Self.shownSize(chosen: state.size, room: pageRoom), name: PageSizes.named(state.size)?.name, scale: pageScale)
        if sizeReadout.width(withName: true) != before {
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

    private var sizeIndex: Int? { Self.parts.firstIndex { $0.tools.contains(.sizeFill) } }

    private func currentLayout(width: CGFloat) -> Layout {
        let readout = sizeReadout.size == nil ? nil : (named: sizeReadout.width(withName: true), bare: sizeReadout.width(withName: false))
        return Self.layout(width: width, height: bounds.height > 0 ? bounds.height : TopBarView.height, address: showsAddress, readout: readout)
    }

    func width(fitting room: CGFloat) -> CGFloat { currentLayout(width: room).width }

    override func layout() {
        super.layout()
        let layout = currentLayout(width: bounds.width)
        shown = layout.shown
        address.isHidden = layout.address == nil
        copyButton.isHidden = layout.copy == nil
        if let rect = layout.address { address.frame = rect }
        if let rect = layout.copy { copyButton.frame = rect }
        for (i, button) in buttons.enumerated() {
            button.isHidden = i >= layout.shown
            if i < layout.shown { button.frame = layout.buttons[i] }
        }
        sizeReadout.isHidden = layout.readout == nil
        if let rect = layout.readout {
            sizeReadout.showsName = layout.readoutNamed
            sizeReadout.frame = rect
        }
        for (i, line) in lines.enumerated() {
            line.isHidden = i >= layout.lines.count
            if i < layout.lines.count { line.frame = layout.lines[i] }
        }
        more.frame = layout.more
        more.isHidden = layout.width == 0
        // The count goes with the console's button, wherever that is now.
        refreshErrors()
    }
}
