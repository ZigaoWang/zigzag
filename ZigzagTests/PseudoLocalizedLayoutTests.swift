import AppKit
import Testing
@testable import Zigzag

/// The main surfaces laid out with pseudo-localized strings, about 40% longer than English: no word of Zigzag's is cut
/// off where it isn't meant to be. scripts/test.sh runs this suite in a process of its own with every string pseudo
/// from launch (ZIGZAG_PSEUDO_LOCALIZE); run elsewhere, it turns pseudo strings on for what it builds. With
/// ZIGZAG_TEST_LANGUAGE (de, ru) it lays the same surfaces out in that language instead, and with ZIGZAG_LAYOUT_SHOTS
/// it saves each surface as a PNG in that folder.
@MainActor @Suite(.serialized) struct PseudoLocalizedLayoutTests {
    /// Text that's meant to end in a fade or "…": names and addresses people choose, which can be any length.
    private static let deliberatelyShortened: [AnyClass] = [TabRowView.self]

    /// Words on screen that aren't Zigzag's to translate: brands, what the tests typed and opened, and what macOS and
    /// WebKit name themselves (the Downloads folder, Edit › Emoji & Symbols, WebKit's feature flags).
    private static let notOurs: Set<String> = ["Zigzag", "Google", "GitHub", "Downloads", "Emoji & Symbols", "Example", "example.com",
                                               "split", "copy", "settings", "e"]

    /// Runs `body` with pseudo strings on, unless the whole process already has them or speaks a real language.
    private func pseudo<T>(_ body: () throws -> T) rethrows -> T {
        if PseudoLocale.language != nil { return try body() }
        PseudoLocale.install()
        return try PseudoLocale.$on.withValue(true, operation: body)
    }

    /// Every word under `root` that doesn't fit where it's drawn: wider than its frame on one line, taller than its
    /// frame when it wraps, or outside the view that holds it.
    /// With every string pseudo from launch, words that aren't are words that skipped the catalog.
    static func cutOff(under root: NSView, _ surface: String, expectsWords: Bool = true, othersWords: Bool = false) -> [String] {
        var found: [String] = [], checked = 0
        // In a real language every word is checked, not only pseudo ones.
        let real = PseudoLocale.language != nil
        if let folder = ProcessInfo.processInfo.environment["ZIGZAG_LAYOUT_SHOTS"], !folder.isEmpty { save(root, surface, in: folder) }
        func shown(_ view: NSView) -> Bool {
            var view: NSView? = view
            while let current = view, current !== root.superview {
                if current.isHidden || current.alphaValue == 0 { return false }
                view = current.superview
            }
            return true
        }
        func deliberate(_ view: NSView) -> Bool {
            var view: NSView? = view
            while let current = view {
                if deliberatelyShortened.contains(where: { current.isKind(of: $0) }) { return true }
                view = current.superview
            }
            return false
        }
        for field in root.selfAndDescendants(of: NSTextField.self) where shown(field) && !field.isEditable && !deliberate(field) {
            let text = field.stringValue
            if PseudoLocale.forTheRun, !othersWords, !PseudoLocale.isPseudo(text), !notOurs.contains(text),
               text.filter(\.isLetter).count > 1, !text.contains(where: { "⌘⌃⌥⇧".contains($0) }) {
                found.append("\(surface): “\(text)” in \(type(of: field.superview ?? field)) isn't localized")
            }
            guard !text.isEmpty, real || PseudoLocale.isPseudo(text), let cell = field.cell else { continue }
            checked += 1
            if let label = field as? Label, label.fadesTail { continue }
            // Cut short on purpose, and whole in the tooltip of what holds it (a menu's long choice, #189).
            if field.superview?.toolTip == text { continue }
            let name = "\(surface): “\(text)” in \(type(of: field.superview ?? field))"
            let frame = field.frame
            if frame.width <= 0 || frame.height <= 0 { found.append("\(name) has no room"); continue }
            let oneLine = field.maximumNumberOfLines == 1 || field.usesSingleLineMode || !cell.wraps
            if oneLine {
                // A label measures its own text as drawn, tracking included; other fields by their cell.
                let needs = (field as? Label).map { $0.inkWidth + Label.inset * 2 } ?? ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: frame.height)).width)
                if needs > frame.width + 1 { found.append("\(name): needs \(needs), given \(frame.width)") }
            } else {
                let needs = ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: frame.width, height: 100_000)).height)
                if needs > frame.height + 1 { found.append("\(name): needs \(needs) tall, given \(frame.height)") }
            }
            if let holder = field.superview, !(holder is NSClipView), holder.bounds.width > 0 {
                // A label sits its inset outside where its text starts and ends.
                let slack = Label.inset + 1
                if frame.maxX > holder.bounds.maxX + slack || frame.minX < holder.bounds.minX - slack {
                    found.append("\(name): runs past its \(type(of: holder)) (\(frame.minX)–\(frame.maxX) of \(holder.bounds.width))")
                }
            }
        }
        if checked == 0, expectsWords { found.append("\(surface): no localized words to check") }
        return found
    }

    /// The surface as drawn, for looking at a language's layout by eye.
    private static func save(_ view: NSView, _ surface: String, in folder: String) {
        guard view.bounds.width > 0, view.bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let name = (PseudoLocale.language ?? "pseudo") + "-" + surface.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }

    /// A browser window at its narrowest, with a tab of its own.
    private func window(width: CGFloat = Tokens.Metric.windowMinSize.width, _ body: (BrowserWindowController) throws -> Void) rethrows {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let tab = Tab(url: URL(string: "https://example.com/")!, title: "Example", spaceID: space)
        manager.adopt([tab], in: space)
        manager.select(tab)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: width, height: 640))
        defer { controller.window?.close() }
        controller.root.sidebarWidth = Tokens.Metric.sidebarMinWidth
        controller.root.layoutSubtreeIfNeeded()
        try body(controller)
    }

    @Test(.enabled(if: PseudoLocale.language == nil)) func pseudoStringsAreLongerAccentedAndBracketed() {
        #expect(PseudoLocale.transform("Settings") == "[Šéţţîñĝš ~~~~]")
        #expect(PseudoLocale.transform("Close %lld Tabs") == "[Çļöšé %lld Ţáƀš ~~~~]")
        #expect(PseudoLocale.transform("%1$@ in %2$@") == "[%1$@ îñ %2$@ ~]")
        #expect(PseudoLocale.transform("") == "")
        let (one, many) = pseudo {
            (String(localized: "Close \(1) Tabs", comment: "Item in a tab's menu in the sidebar: closes the tabs selected."),
             String(localized: "Close \(3) Tabs", comment: "Item in a tab's menu in the sidebar: closes the tabs selected."))
        }
        // A plural keeps its forms, each made pseudo.
        #expect(one == "[Çļöšé Ţáƀ ~~~~]", "\(one)")
        #expect(many == "[Çļöšé 3 Ţáƀš ~~~~]", "\(many)")
        #expect(PseudoLocale.isPseudo(many) && !PseudoLocale.isPseudo("Close 3 Tabs"))
    }

    @Test func theSidebarAndTopBarFit() {
        pseudo {
            window { controller in
                var found = Self.cutOff(under: controller.sidebar, "sidebar")
                controller.root.showsTopBar = true
                controller.root.layoutSubtreeIfNeeded()
                found += Self.cutOff(under: controller.root.topBar, "top bar", expectsWords: false)
                #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
            }
        }
    }

    @Test func theCommandBarFits() {
        pseudo {
            window(width: 900) { controller in
                controller.commandBar.show(mode: .newTab)
                defer { controller.commandBar.dismiss(restoringFocus: false) }
                var found: [String] = []
                // Commands, then tabs and suggestions.
                for typed in ["split", "copy", "settings", "e"] {
                    controller.commandBar.debugType(typed)
                    controller.commandBar.panelView.layoutSubtreeIfNeeded()
                    found += Self.cutOff(under: controller.commandBar.panelView, "command bar “\(typed)”", expectsWords: typed != "e")
                }
                #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
            }
        }
    }

    @Test func siteControlsFit() throws {
        try pseudo {
            let tab = Tab(url: try #require(URL(string: "https://example.com/page")), title: "Example", spaceID: UUID())
            let panel = try #require(SitePanel.forTesting(tab: tab))
            panel.frame = NSRect(x: 0, y: 0, width: SitePanel.width, height: 700)
            panel.layoutSubtreeIfNeeded()
            let found = Self.cutOff(under: panel, "site panel")
            #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
        }
    }

    /// With compatibility mode on (#497), the rows it sets aside say so under their names.
    @Test func siteControlsFitInCompatibilityMode() throws {
        let suite = "zigzag-layout-compat-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let boosts = SiteBoosts.defaults, banners = CookieBanners.defaults
        SiteBoosts.defaults = defaults
        CookieBanners.defaults = defaults
        defer {
            SiteBoosts.defaults = boosts
            CookieBanners.defaults = banners
            defaults.removePersistentDomain(forName: suite)
        }
        let url = try #require(URL(string: "https://example.com/page"))
        CookieBanners.setChoice(false, for: url)
        SiteBoosts.zap("#promo", forSite: "example.com")
        SiteCompatibility.set(true, for: url)
        try pseudo {
            let tab = Tab(url: url, title: "Example", spaceID: UUID())
            let panel = try #require(SitePanel.forTesting(tab: tab))
            panel.frame = NSRect(x: 0, y: 0, width: SitePanel.width, height: 700)
            panel.layoutSubtreeIfNeeded()
            let found = Self.cutOff(under: panel, "site panel compatibility mode")
            #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
        }
    }

    /// Each pane at a roomy page and at a narrow one.
    @Test(arguments: SettingsPane.allCases, [1040, 720]) func settingsFits(_ pane: SettingsPane, width: CGFloat) {
        pseudo {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 776), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let settings = SettingsView(pane: pane)
            settings.frame = NSRect(x: 0, y: 0, width: width, height: 776)
            window.contentView?.addSubview(settings)
            settings.layoutSubtreeIfNeeded()
            let found = Self.cutOff(under: settings, "Settings › \(pane) at \(Int(width))", othersWords: pane == .developer)
            #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
        }
    }

    /// Sync with iCloud's row in every status it can show.
    @Test(arguments: [1040, 560] as [CGFloat]) func syncWithICloudFits(width: CGFloat) {
        pseudo {
            var found: [String] = []
            for (name, status, isOn, hasCopy) in SyncSettingsRows.everyStatus {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let rows = SyncSettingsRows()
                rows.show(status, isOn: isOn, hasCopy: hasCopy)
                let group = FormGroup()
                group.add(rows.row)
                group.add(rows.statusRow)
                group.frame = NSRect(x: 0, y: 0, width: width, height: group.fittingHeight(for: width))
                window.contentView?.addSubview(group)
                group.layoutSubtreeIfNeeded()
                found += Self.cutOff(under: group, "Sync with iCloud \(name) at \(Int(width))")
            }
            #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
        }
    }

    /// The sheet that turns it on, and the one behind Remove from iCloud….
    @Test func syncWithICloudSheetsFit() {
        pseudo {
            window(width: 900) { controller in
                guard let host = controller.window?.contentView else { Issue.record("no content view"); return }
                var found: [String] = []
                for (name, sheet) in SyncSettingsRows.sheets {
                    ConfirmSheet.show(in: host, title: sheet.title, message: sheet.message, confirmTitle: sheet.confirm) { _ in }
                    for shown in host.subviews.compactMap({ $0 as? ConfirmSheet }) {
                        shown.layoutSubtreeIfNeeded()
                        found += Self.cutOff(under: shown, "Sync with iCloud \(name) sheet")
                        shown.removeFromSuperview()
                    }
                }
                #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
            }
        }
    }

    @Test func theSheetsFit() {
        pseudo {
            window(width: 900) { controller in
                guard let host = controller.window?.contentView else { Issue.record("no content view"); return }
                var found: [String] = []
                // Each sheet as it opens, taken away at once rather than faded out under the next.
                @MainActor func check(_ name: String, _ open: () -> Void) {
                    let before = Set(host.subviews.map(ObjectIdentifier.init))
                    open()
                    let opened = host.subviews.compactMap { $0 as? FormSheet }.filter { !before.contains(ObjectIdentifier($0)) }
                    if opened.isEmpty { found.append("\(name): no sheet opened") }
                    for sheet in opened {
                        sheet.layoutSubtreeIfNeeded()
                        found += Self.cutOff(under: sheet, name)
                        sheet.close()
                        sheet.removeFromSuperview()
                    }
                }
                check("live folder") { LiveFolderSheet.show(in: controller) }
                for kind in DownloadRuleAction.Kind.allCases {
                    check("download rule \(kind)") { DownloadRuleSheet.show(in: host, kind: kind) }
                }
                let editor = SpaceEditorPanel(spaceID: controller.tabManager.currentSpaceID, controller: controller)
                editor.show()
                editor.layoutSubtreeIfNeeded()
                found += Self.cutOff(under: editor, "space editor")
                editor.close()
                #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
            }
        }
    }

    @Test func menusFit() {
        pseudo {
            window(width: 900) { controller in
                guard let host = controller.window?.contentView else { Issue.record("no content view"); return }
                let anchor = NSView(frame: NSRect(x: 300, y: 300, width: 20, height: 20))
                host.addSubview(anchor)
                defer { anchor.removeFromSuperview() }
                var menus: [(String, NSMenu)] = MainMenu.build().items.compactMap { item in item.submenu.map { (item.title, $0) } }
                if let tab = controller.tabManager.selectedTab {
                    menus.append(("tab", SidebarMenus.tabMenu(for: tab, controller: controller)))
                }
                menus.append(("space", SidebarMenus.spaceMenu(for: controller.tabManager.currentSpaceID, controller: controller)))
                var found: [String] = []
                for (name, menu) in menus {
                    guard let panel = MenuPanel.show(MenuPanel.entries(from: menu), from: anchor) else { continue }
                    panel.layoutSubtreeIfNeeded()
                    found += Self.cutOff(under: panel, "menu \(name)")
                    panel.close(animated: false)
                }
                #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
            }
        }
    }
}
