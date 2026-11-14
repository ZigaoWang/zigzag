import AppKit
import Testing
@testable import Zigzag

/// VoiceOver over the controls Zigzag draws: each is one element with its role and its name, never an image named
/// after its symbol, and a view that only holds controls stays out of the way so they're reached one by one.
@MainActor
struct AccessibilityTests {
    /// Every element VoiceOver can reach under `root`, as it walks them: through each element's children.
    private func elements(under root: NSView) -> [NSObject] {
        var found: [NSObject] = []
        func walk(_ object: NSObject, depth: Int) {
            guard depth < 60 else { return }
            let children = (object as? NSView)?.accessibilityChildren() ?? (object as? NSAccessibilityElement)?.accessibilityChildren() ?? []
            for case let child as NSObject in children {
                found.append(child)
                walk(child, depth: depth + 1)
            }
        }
        if root.isAccessibilityElement() { found.append(root) }
        walk(root, depth: 0)
        return found
    }

    private func role(_ object: NSObject) -> NSAccessibility.Role? {
        (object as? NSView)?.accessibilityRole() ?? (object as? NSAccessibilityElement)?.accessibilityRole()
    }

    private func name(_ object: NSObject) -> String {
        let view = object as? NSView, element = object as? NSAccessibilityElement
        let label = view?.accessibilityLabel() ?? element?.accessibilityLabel() ?? ""
        let title = view?.accessibilityTitle() ?? element?.accessibilityTitle() ?? ""
        return label.isEmpty ? title : label
    }

    /// The problems VoiceOver would have under `root`: a control with no name, a name that's a symbol's, a picture
    /// read on its own inside a control.
    private func problems(under root: NSView) -> [String] {
        var problems: [String] = []
        let pressable: Set<NSAccessibility.Role> = [.button, .checkBox, .radioButton, .popUpButton, .menuButton, .disclosureTriangle, .row, .cell]
        for object in elements(under: root) {
            guard let role = role(object) else { continue }
            let said = name(object)
            if pressable.contains(role), said.isEmpty { problems.append("unnamed \(role.rawValue): \(type(of: object))") }
            if let button = object as? IconButton {
                let symbolName = Tokens.Symbol.image(button.symbol, size: button.symbolSize).accessibilityDescription
                if said == button.symbol || (symbolName != nil && said == symbolName && said != button.toolTip.map(IconButton.withoutShortcut)) {
                    problems.append("symbol name '\(said)' on \(button.symbol)")
                }
            }
            if let view = object as? InteractiveView, view.isAccessibilityControl {
                for child in view.accessibilityChildren() ?? [] where InteractiveView.isDecoration(child) {
                    problems.append("decoration read inside '\(said)': \(type(of: child))")
                }
            }
        }
        return problems
    }

    private func controls(under root: NSView) -> [NSObject] {
        elements(under: root).filter { role($0).map(InteractiveView.controlRoles.contains) ?? false }
    }

    @Test func anIconButtonIsOneNamedButton() {
        let button = IconButton(symbol: "rectangle.split.2x1", toolTip: "Split View (⌃⌘S)")
        #expect(button.isAccessibilityElement())
        #expect(button.accessibilityRole() == .button)
        #expect(button.accessibilityLabel() == "Split View")
        // Its symbol isn't read on its own.
        #expect(button.accessibilityChildren()?.isEmpty ?? true)
        // A translated tooltip names it, its shortcut left out.
        button.toolTip = "返回（⌘[）"
        #expect(button.accessibilityLabel() == "返回")
    }

    @Test func aPressReachesTheClick() {
        let button = TextButton(title: "Done")
        var pressed = 0
        button.onClick = { _ in pressed += 1 }
        #expect(button.isAccessibilityElement())
        #expect(button.accessibilityPerformPress())
        #expect(pressed == 1)
        button.isEnabled = false
        #expect(!button.accessibilityPerformPress())
        #expect(pressed == 1)
    }

    @Test func aSwitchSaysItsState() {
        let toggle = Toggle(isOn: true)
        #expect(toggle.isAccessibilityElement())
        #expect(toggle.accessibilityRole() == .checkBox)
        #expect(toggle.accessibilityValue() as? Int == 1)
        toggle.isOn = false
        #expect(toggle.accessibilityValue() as? Int == 0)
    }

    @Test func aClickableViewWithNoRoleIsANamedButton() {
        let view = InteractiveView()
        let label = Label("Open Folder")
        view.addSubview(label)
        #expect(!view.isAccessibilityElement())
        view.onClick = { _ in }
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .button)
        #expect(view.accessibilityLabel() == "Open Folder")
        #expect(view.accessibilityChildren()?.contains { ($0 as? NSView) === label } != true)
    }

    @Test func aPanelOfControlsIsNotOneElement() {
        let panel = InteractiveView()
        panel.setAccessibilityRole(.group)
        let a = IconButton(symbol: "chevron.left", toolTip: "Back"), b = IconButton(symbol: "chevron.right", toolTip: "Forward")
        [a, b].forEach(panel.addSubview)
        #expect(!panel.isAccessibilityElement())
        let reached = controls(under: panel).compactMap { $0 as? IconButton }
        #expect(reached.count == 2)
        // Named, a group is one VoiceOver steps into: its controls are still each their own.
        panel.setAccessibilityLabel("Navigation")
        #expect(panel.isAccessibilityElement())
        #expect(controls(under: panel).count == 2)
        // Told outright, it isn't.
        let quiet = InteractiveView()
        quiet.onClick = { _ in }
        quiet.setAccessibilityElement(false)
        #expect(!quiet.isAccessibilityElement())
    }

    @Test func theSidebarsControlsAreNamed() {
        let sidebar = SidebarView()
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        #expect(problems(under: sidebar) == [])
        let named = Set(controls(under: sidebar).map(name))
        #expect(named.contains(String(localized: "Downloads", comment: "Tooltip of the sidebar's downloads button.")))
        #expect(named.contains(IconButton.withoutShortcut(SidebarView.addTip)))
        #expect(named.contains(String(localized: "Back", comment: "Tooltip of the sidebar's back button.")))
    }

    @Test func aTabRowIsItsTitleAndSaysWhenItsCurrent() {
        let tab = Tab(url: URL(string: "https://example.com")!, title: "Example Domain", spaceID: UUID())
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 220, height: Tokens.Sidebar.rowHeight))
        row.configure(tab: tab)
        row.isSelected = true
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        #expect(row.isAccessibilityElement())
        #expect(row.accessibilityRole() == .button)
        #expect(row.accessibilityLabel() == "Example Domain")
        #expect(row.isAccessibilitySelected())
        // Its title isn't read a second time on its own; its close button is a button of its own, named.
        let children = row.accessibilityChildren() ?? []
        #expect(!children.contains { $0 is Label })
        #expect(children.contains { ($0 as? NSView) === row.closeButton })
        #expect(row.closeButton.accessibilityLabel() == String(localized: "Close Tab", comment: "Tooltip of a button on a tab's row in the sidebar."))
        #expect(problems(under: row) == [])
        row.isSelected = false
        #expect(!row.isAccessibilitySelected())
    }

    @Test func theTopBarsControlsAreNamed() {
        let sidebar = SidebarView()
        let root = BrowserRootView(sidebar: sidebar)
        root.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        sidebar.holdsAddress = false
        root.topBar.hold(buttons: sidebar.addressButtons, address: sidebar.address)
        root.showsTopBar = true
        root.layoutSubtreeIfNeeded()
        #expect(problems(under: root.topBar) == [])
        let tools = DeveloperBarTools()
        tools.frame = NSRect(x: 0, y: 0, width: 900, height: TopBarView.height)
        tools.layoutSubtreeIfNeeded()
        #expect(problems(under: tools) == [])
        #expect(controls(under: tools).count >= DeveloperBarTools.parts.count)
    }

    @Test func thePaneStripsControlsAreNamed() {
        let header = PaneHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: PaneHeaderView.height))
        header.layoutSubtreeIfNeeded()
        #expect(problems(under: header) == [])
        #expect(controls(under: header).contains { name($0) == String(localized: "Swap Sides", comment: "Tooltip of a button in the strip on top of each page of a split view: swaps the two pages.") })
    }

    @Test func siteControlsAreNamed() throws {
        let tab = Tab(url: URL(string: "https://example.com/page")!, title: "Example", spaceID: UUID())
        let panel = try #require(SitePanel.forTesting(tab: tab))
        panel.frame = NSRect(x: 0, y: 0, width: SitePanel.width, height: 600)
        panel.layoutSubtreeIfNeeded()
        #expect(problems(under: panel) == [])
        #expect(!controls(under: panel).isEmpty)
    }

    @Test func aSettingsPanesControlsAreNamed() {
        for pane in [SettingsPane.general, .appearance] {
            let settings = SettingsView(pane: pane)
            settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
            settings.layoutSubtreeIfNeeded()
            #expect(problems(under: settings) == [], "\(pane)")
            #expect(controls(under: settings).contains { role($0) == .checkBox || role($0) == .popUpButton }, "\(pane)")
        }
    }
}
