import AppKit
import Testing
import WebKit
@testable import Zigzag

/// Settings as a tab: its address names the section, and the section comes back from the address.
@MainActor
struct SettingsPageTests {
    @Test func eachSectionHasAnAddress() {
        #expect(SettingsPage.url(for: .general).absoluteString == "zigzag://settings")
        #expect(SettingsPage.url(for: .privacy).absoluteString == "zigzag://settings/privacy")
        for pane in SettingsPane.allCases {
            #expect(SettingsPage.pane(for: SettingsPage.url(for: pane)) == pane)
        }
    }

    @Test func readsTheAddressAPageLeaves() {
        // What history.replaceState leaves for General, and an address typed by hand.
        #expect(SettingsPage.pane(for: URL(string: "zigzag://settings/")) == .general)
        #expect(SettingsPage.pane(for: URL(string: "zigzag://settings/nothing")) == .general)
        #expect(SettingsPage.pane(for: URL(string: "zigzag://settings/shortcuts")) == .shortcuts)
    }

    @Test func addressesFromBeforeTheNewSectionsStillOpen() {
        // A Settings tab kept with the session names its section, so every name it may have saved still opens it.
        let saved: [String: SettingsPane] = ["general": .general, "spaces": .spaces, "passwords": .passwords, "privacy": .privacy,
                                             "translation": .translation, "extensions": .extensions, "shortcuts": .shortcuts]
        for (name, pane) in saved {
            #expect(SettingsPage.pane(for: URL(string: "zigzag://settings/\(name)")) == pane)
        }
    }

    @Test func theNewSectionsHaveTheirOwnAddresses() {
        #expect(SettingsPage.pane(for: URL(string: "zigzag://settings/appearance")) == .appearance)
        #expect(SettingsPage.pane(for: URL(string: "zigzag://settings/tabs")) == .tabs)
        #expect(SettingsPage.pane(for: URL(string: "zigzag://settings/search")) == .search)
        #expect(SettingsPage.pane(for: URL(string: "zigzag://settings/mini")) == .mini)
        #expect(SettingsPage.url(for: .mini).absoluteString == "zigzag://settings/mini")
        #expect(SettingsPage.pane(for: URL(string: "zigzag://settings/automation")) == .automation)
        #expect(SettingsPage.pane(for: URL(string: "zigzag://settings/developer")) == .developer)
    }

    @Test func theColumnKeepsItsOrder() {
        #expect(SettingsPane.allCases == [.general, .downloads, .appearance, .tabs, .spaces, .profiles, .search, .mini, .translation, .passwords,
                                          .privacy, .websiteData, .extensions, .shortcuts, .automation, .developer])
    }

    @Test func theColumnIsInGroups() {
        let groups = SettingsPane.columnGroups(manyProfiles: false)
        #expect(groups.shared == [[.general, .downloads, .appearance, .tabs, .spaces, .profiles], [.search, .mini, .translation],
                                  [.passwords, .privacy], [.extensions, .shortcuts, .automation, .developer]])
        #expect(groups.profile.isEmpty)
        // A gap before each group but the first.
        #expect(SettingsPane.groupStarts(manyProfiles: false) == [.search, .passwords, .extensions])
    }

    @Test func withMoreProfilesExtensionsLeavesItsGroup() {
        let groups = SettingsPane.columnGroups(manyProfiles: true)
        #expect(groups.shared == [[.general, .downloads, .appearance, .tabs, .spaces, .profiles], [.search, .mini, .translation],
                                  [.passwords, .privacy], [.shortcuts, .automation, .developer]])
        #expect(groups.profile == [.extensions, .websiteData])
        #expect(SettingsPane.groupStarts(manyProfiles: true) == [.search, .passwords, .shortcuts])
    }

    @Test func eachGroupHasAHeading() {
        #expect(SettingsPane.headed(manyProfiles: false) == [.general, .search, .passwords, .extensions])
        #expect(SettingsPane.headed(manyProfiles: true) == [.general, .search, .passwords, .shortcuts])
        #expect(SettingsPane.groupTitle(startingAt: .extensions) == SettingsPane.groupTitle(startingAt: .shortcuts))
        #expect(SettingsPane.groupTitle(startingAt: .tabs) == nil)
    }

    @Test func withOneProfileTheColumnIsAsItWasBeforeProfiles() {
        let column = SettingsPane.column(manyProfiles: false)
        #expect(column.shared == [.general, .downloads, .appearance, .tabs, .spaces, .profiles, .search, .mini, .translation, .passwords, .privacy,
                                  .extensions, .shortcuts, .automation, .developer])
        #expect(column.profile.isEmpty)
        // What websites keep is in Privacy, and an address that names Website Data opens it there.
        #expect(SettingsPane.websiteData(manyProfiles: false) == .privacy)
        #expect(SettingsPane.websiteData.shown(manyProfiles: false) == .privacy)
        #expect(SettingsPane.privacy.shown(manyProfiles: false) == .privacy)
    }

    @Test func withMoreProfilesTheSectionsAboutOneStandApart() {
        let column = SettingsPane.column(manyProfiles: true)
        #expect(column.profile == [.extensions, .websiteData])
        #expect(column.shared == [.general, .downloads, .appearance, .tabs, .spaces, .profiles, .search, .mini, .translation, .passwords, .privacy,
                                  .shortcuts, .automation, .developer])
        // Every section is listed once.
        #expect(Set(column.shared + column.profile) == Set(SettingsPane.allCases))
        #expect(SettingsPane.websiteData(manyProfiles: true) == .websiteData)
        #expect(SettingsPane.websiteData.shown(manyProfiles: true) == .websiteData)
        #expect(SettingsPage.url(for: .websiteData).absoluteString == "zigzag://settings/website-data")
    }

    @Test func onlyItsOwnAddressIsSettings() {
        #expect(SettingsPage.isSettings(URL(string: "zigzag://settings/spaces")))
        #expect(!SettingsPage.isSettings(URL(string: "zigzag://history")))
        #expect(!SettingsPage.isSettings(URL(string: "https://settings.example.com")))
        #expect(!HistoryPage.isHistory(URL(string: "zigzag://settings")))
        #expect(HistoryPage.isInternal(URL(string: "zigzag://settings")))
    }
}

/// A group whose rows are read a moment after they're asked for is filled again only when what it lists changes.
struct GroupListingTests {
    @Test func theSameRowsAreNeverReadTwice() {
        var listing = GroupListing<[String]>()
        let answer1 = listing.needs(["a", "b"])
        #expect(answer1)
        // Asked again while they're being read: nothing more to do.
        let answer2 = listing.needs(["a", "b"])
        #expect(!answer2)
        let answer3 = listing.arrived(["a", "b"])
        #expect(answer3)
        #expect(listing.shown == ["a", "b"])
        // Asked again once they show: they stay as they are.
        let answer4 = listing.needs(["a", "b"])
        #expect(!answer4)
        // Something else: read.
        let answer5 = listing.needs(["a"])
        #expect(answer5)
    }

    @Test func rowsReadForSomethingNoLongerWantedAreDropped() {
        var listing = GroupListing<[String]>()
        let answer6 = listing.needs(["a"])
        #expect(answer6)
        let answer7 = listing.needs(["b"])
        #expect(answer7)
        // The first answer comes in after the second was asked for.
        let answer8 = listing.arrived(["a"])
        #expect(!answer8)
        #expect(listing.shown == nil)
        let answer9 = listing.arrived(["b"])
        #expect(answer9)
        #expect(listing.shown == ["b"])
    }

    @Test func aGroupShownAtOnceOrEmptiedStartsOver() {
        var listing = GroupListing<[String]>()
        let answer10 = listing.needs(["a"])
        #expect(answer10)
        // Nothing to list after all: shown empty at once, and the answer still coming is dropped.
        listing.show([])
        let answer11 = listing.arrived(["a"])
        #expect(!answer11)
        #expect(listing.shown == [])
        let answer12 = listing.needs([])
        #expect(!answer12)
        // Its rows taken out (another profile is shown): the same list has to be read again.
        let answer13 = listing.needs(["a"])
        #expect(answer13)
        let answer14 = listing.arrived(["a"])
        #expect(answer14)
        listing.forget()
        let answer15 = listing.needs(["a"])
        #expect(answer15)
    }

}

/// Settings' picture, taken for a tab's preview when you leave it.
@MainActor
struct SettingsSnapshotTests {
    /// The picture is taken with the shadows off, since drawing them on the CPU froze Zigzag on Developer, and every
    /// shadow is back as it was afterward.
    @Test func snapshotLeavesShadowsAsTheyWere() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 776), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        let settings = SettingsView(pane: .general)
        settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
        window.contentView?.addSubview(settings)
        settings.layoutSubtreeIfNeeded()

        let shadowed = SettingsView.shadowedLayers(in: settings)
        let before = shadowed.map(\.shadowOpacity)
        try #require(!shadowed.isEmpty, "General has switches, whose knobs have shadows")
        let image = try #require(settings.snapshot())
        #expect(image.size == settings.bounds.size)
        #expect(shadowed.map(\.shadowOpacity) == before)
    }
}

/// Find a setting, in Settings' header.
@MainActor
struct SettingsSearchTests {
    /// Find a setting knows the words people look for, and leads to the nearest row where there's no such setting.
    @Test func findsCommonWords() {
        let settings = SettingsView(pane: .general)
        let expected = ["startup": "On launch", "launch": "On launch", "quit": "Ask before quitting", "homepage": "New tabs open",
                        "home page": "New tabs open", "new tab": "New tabs open", "dark mode": "Dark pages",
                        "appearance": "Dark pages", "default app": "Default browser"]
        for (words, row) in expected {
            settings.debugFind(words)
            #expect(settings.debugFound.contains(row), "“\(words)” should find \(row)")
        }
    }

    /// Automation is found by the words people use for it, and its rows still are once they moved out of General.
    @Test func findsAutomation() {
        let settings = SettingsView(pane: .general)
        for words in ["mcp", "ai", "agent", "automation", "api"] {
            settings.debugFind(words)
            #expect(settings.debugFound.contains("Let AI apps use Zigzag"), "“\(words)” should find Let AI apps use Zigzag")
        }
        settings.debugFind("apple events")
        #expect(settings.debugFound.contains("Allow JavaScript from Apple Events"))
        settings.debugFind("applescript")
        #expect(settings.debugFound.contains("Allow JavaScript from Apple Events"))
        settings.debugFind("mcp guide")
        #expect(settings.debugFound.contains("How it works"))
    }

    /// Globe key shortcuts (Enter Full Screen) show the Globe first.
    @Test func globeKeyShowsInAShortcut() {
        let fullScreen = Shortcuts.Combo(key: "f", modifiers: NSEvent.ModifierFlags.function.rawValue)
        #expect(Shortcuts.caps(fullScreen) == [Shortcuts.globe, "F"])
        let both = Shortcuts.Combo(key: "f", modifiers: NSEvent.ModifierFlags([.function, .control, .command]).rawValue)
        #expect(Shortcuts.caps(both) == [Shortcuts.globe, "⌃", "⌘", "F"])
    }

    /// ⌃⌥⇧⌘ together summarize as the Hyper key.
    @Test func hyperKeyShowsInAShortcut() {
        let hyper = Shortcuts.Combo(key: "t", modifiers: Shortcuts.hyperFlags.rawValue)
        #expect(Shortcuts.caps(hyper) == [Shortcuts.hyper, "T"])
        let withGlobe = Shortcuts.Combo(key: "t", modifiers: Shortcuts.hyperFlags.union(.function).rawValue)
        #expect(Shortcuts.caps(withGlobe) == [Shortcuts.globe, Shortcuts.hyper, "T"])
        let row = ShortcutRow(title: "New Tab", keys: Shortcuts.caps(hyper))
        for query in ["hyper", "hypr", "command", "cmd", "shift", "option", "control", "✦T"] {
            #expect(row.searchText.localizedCaseInsensitiveContains(query), "“\(query)” should match \(row.searchText)")
        }
    }

    /// Close Tabs Below has no line in the menu bar and no keys, but Settings › Shortcuts lists it and it can take
    /// keys of yours, which work and aren't fixed ones; the other hidden aliases stay unlisted.
    @Test func closeTabsBelowCanHaveAShortcut() throws {
        let menu = MainMenu.build()
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { $0.submenu.map(items) ?? [$0] } }
        let below = try #require(items(menu).first { $0.action == #selector(BrowserWindowController.closeTabsBelow(_:)) })
        #expect(below.isHidden && below.keyEquivalent.isEmpty)
        #expect(Shortcuts.id(below) != nil)
        #expect(Shortcuts.isListed(below))
        below.keyEquivalent = "j"
        below.keyEquivalentModifierMask = [.command, .option]
        #expect(below.allowsKeyEquivalentWhenHidden)
        #expect(Shortcuts.reserved(Shortcuts.Combo(key: "j", modifiers: below.keyEquivalentModifierMask.rawValue), in: menu) == nil)
        let next = try #require(items(menu).first { $0.action == #selector(BrowserWindowController.selectNextTab(_:)) && $0.isHidden })
        #expect(Shortcuts.id(next) == nil)
        #expect(!Shortcuts.isListed(next))
    }
}

/// Settings reads a section's slow rows when it's first shown or searched, never all of them on opening (#357).
@MainActor
struct SettingsReadingTests {
    @Test func openingGeneralReadsNoOtherSection() {
        let settings = SettingsView(pane: .general)
        #expect(settings.debugReads.isEmpty)
        settings.debugReadNow()
        #expect(settings.debugReads["webApps"] == 1)
        #expect(settings.debugReads["siteData"] == nil)
        #expect(settings.debugReads["extensions"] == nil)
        #expect(settings.debugReads["orphans"] == nil)
        #expect(settings.debugReads["privacy"] == nil)
    }

    /// Typing in the search bar keeps the shortcut rows, made again only after shortcut changes.
    @Test func shortcutsAreReadOnlyWhenChanged() throws {
        let settings = SettingsView(pane: .general)
        settings.debugFind("d")
        settings.debugFind("do")
        #expect(settings.debugReads["shortcuts"] == 1)

        let item = try #require(Shortcuts.allItems.first { !$0.keyEquivalent.isEmpty })
        let mask = item.keyEquivalentModifierMask
        defer { item.keyEquivalentModifierMask = mask }
        item.keyEquivalentModifierMask = mask.symmetricDifference(.option)
        settings.debugFind("dow")
        #expect(settings.debugReads["shortcuts"] == 2)
    }

    @Test func websiteDataIsReadWhenShown() {
        let settings = SettingsView(pane: .general)
        settings.show(SettingsPane.websiteData(manyProfiles: Library.shared.hasManyProfiles))
        // Read once the page has drawn, not while it's asked for.
        #expect(settings.debugReads["siteData"] == nil)
        settings.debugReadNow()
        #expect(settings.debugReads["siteData"] == 1)
        #expect(settings.debugReads["privacy"] == 1)
        #expect(settings.debugReads["extensions"] == nil)
        #expect(settings.debugReads["orphans"] == nil)
    }

    @Test func extensionsAreReadWhenShown() {
        let settings = SettingsView(pane: .extensions)
        #expect(settings.debugReads["extensions"] == nil)
        settings.debugReadNow()
        #expect(settings.debugReads["extensions"] == 1)
        #expect(settings.debugReads["siteData"] == nil)
        #expect(settings.debugReads["orphans"] == nil)
    }

    @Test func searchFindsRowsInSectionsNotShownYet() throws {
        let settings = SettingsView(pane: .general)
        let name = try #require(Library.shared.profiles.first?.displayName)
        #expect(!settings.debugFound.contains(name))
        settings.debugFind(name)
        #expect(settings.debugFound.contains(name))
        #expect(settings.debugReads["orphans"] == 1)
    }
}

/// Settings › Privacy › Site Permissions lists what Site Controls keeps, and a change in either shows in the other
/// (#420).
@MainActor
struct SettingsSitePermissionsTests {
    private func withStore(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "SettingsSitePermissionsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: name)
        }
        try body(defaults)
    }

    private func privacy() -> SettingsView {
        let settings = SettingsView(pane: .privacy)
        settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
        settings.debugReadNow()
        return settings
    }

    @Test func eachSectionIsLaidOutOnceWithItsRowsUnderIt() throws {
        try withStore { _ in
            SitePermissions.setChoice(.allow, for: .camera, origin: "https://example.com")
            let settings = privacy()
            let headings = settings.debugHeadings
            #expect(headings.filter { $0 == "Site Permissions" }.count == 1)
            #expect(headings.contains("Apps on This Mac"))
            // The rows start right under their heading, not a section's height further down.
            let gap = try #require(settings.debugSitesGap)
            #expect(gap >= 0 && gap < Tokens.Metric.sectionLabelHeight)
        }
    }

    @Test func listsWhatSiteControlsKeeps() {
        withStore { _ in
            SitePermissions.setChoice(.allow, for: .camera, origin: "https://example.com")
            SitePermissions.setChoice(.block, for: .notifications, origin: "https://example.org")
            let rows = privacy().debugSiteRows
            #expect(rows.contains("example.com"))
            #expect(rows.contains("Camera: Allow"))
            #expect(rows.contains("example.org"))
            #expect(rows.contains("Notifications: Block"))
        }
    }

    /// Answers kept by beta 5 and earlier, Bools in the old store, list and still apply.
    @Test func listsAnswersKeptByEarlierBuilds() {
        withStore { defaults in
            defaults.set(["https://example.com|camera": true, "https://example.com|location": false], forKey: "SitePermissions")
            let rows = privacy().debugSiteRows
            #expect(rows.contains("example.com"))
            #expect(rows.contains("Camera: Allow"))
            #expect(rows.contains("Location: Block"))
            #expect(SitePermissions.choice(.camera, origin: "https://example.com") == .allow)
            #expect(SitePermissions.location(origin: "https://example.com") == false)
        }
    }

    @Test func aChangeInEitherShowsInTheOther() {
        withStore { _ in
            let origin = "https://example.com"
            SitePermissions.setChoice(.allow, for: .camera, origin: origin)
            let settings = privacy()

            // Site Controls, while Settings shows: its row follows without Settings being opened again.
            SitePermissions.setChoice(.block, for: .camera, origin: origin)
            #expect(settings.debugSiteRows.contains("Camera: Block"))

            // Settings: Site Controls reads the same choice.
            settings.debugChooseSitePermission("Camera", "Allow")
            #expect(SitePermissions.choice(.camera, origin: origin) == .allow)
            #expect(settings.debugSiteRows.contains("Camera: Allow"))
        }
    }
}

/// A box that folds (#368): one per site, extension or site's stored data, headed by its row with a chevron.
@MainActor
struct FoldBoxTests {
    private func row(_ title: String, keywords: String = "") -> FormRow {
        let row = FormRow(title: title, control: Toggle(isOn: true))
        row.keywords = keywords
        return row
    }

    private func box(_ name: String = "example.com", open: Bool = false) -> FoldBox {
        let header = FormRow(title: name, detail: FoldStyle.settingsSummary(2), icon: SettingsIcon.symbol("globe"), control: PillButton(title: "Forget"))
        let box = FoldBox(key: "site \(name)", header: header, rows: [row("Camera", keywords: name), row("Zoom", keywords: name)], isOpen: open)
        box.frame = NSRect(x: 0, y: 0, width: 600, height: box.height(for: 600))
        box.onToggle = { box, open in box.isOpen = open }
        return box
    }

    @Test func shortListsOpenAndLongOnesStartFolded() {
        #expect(FoldStyle.opensByDefault(count: 1))
        #expect(FoldStyle.opensByDefault(count: FoldStyle.openUpTo))
        #expect(!FoldStyle.opensByDefault(count: FoldStyle.openUpTo + 1))
    }

    @Test func aBoxOpensToItsRowsAndFoldsToItsHeader() throws {
        let box = box()
        let header = box.height(for: 600)
        #expect(header == box.headerRow.height(for: 600 - FoldStyle.chevronRoom))
        #expect(box.shownRows.isEmpty)
        // A click on the header, as VoiceOver's press does.
        #expect(box.header.accessibilityPerformPress())
        #expect(box.isOpen)
        #expect(box.height(for: 600) == header + box.rows.map { $0.height(for: 600 - FoldStyle.chevronRoom) }.reduce(0, +))
        #expect(box.shownRows.map(\.debugTitle) == ["Camera", "Zoom"])
        // Its rows' text starts where the name's does, past the picture.
        #expect(box.rows.allSatisfy { $0.textInset == box.headerRow.textInset })
    }

    @Test func voiceOverReadsADisclosureTriangleOpenOrNot() {
        let box = box()
        #expect(box.header.accessibilityRole() == .disclosureTriangle)
        #expect(box.header.accessibilityLabel() == "example.com")
        #expect(box.header.isAccessibilityExpanded() == false)
        #expect(box.header.accessibilityValue() as? Int == 0)
        box.isOpen = true
        #expect(box.header.isAccessibilityExpanded())
        #expect(box.header.accessibilityValue() as? Int == 1)
        box.layoutSubtreeIfNeeded()
        // The box lists the triangle, the header's button, then its rows.
        let children = box.accessibilityChildren() ?? []
        #expect((children.first as? NSView) === box.header)
        #expect(children.contains { ($0 as? PillButton)?.title == "Forget" })
    }

    @Test func foldingKeepsItsRowsUntilTheBoxHasClosed() {
        let box = box(open: true)
        box.layoutSubtreeIfNeeded()
        #expect(box.rows.allSatisfy { !$0.isHidden })
        box.isOpen = false
        box.layoutSubtreeIfNeeded()
        // Still there while the box closes over them, then gone from Tab and VoiceOver.
        #expect(box.rows.allSatisfy { !$0.isHidden })
        box.settle()
        box.layoutSubtreeIfNeeded()
        #expect(box.rows.allSatisfy { $0.isHidden })
    }

    @Test func aSearchOpensTheBoxToTheRowsThatMatch() {
        let box = box()
        #expect(box.find(["camera"]))
        #expect(box.showsOpen && !box.isOpen)
        #expect(box.shownRows.map(\.debugTitle) == ["Camera"])
        // Its own name found: the whole box, folded as it was.
        #expect(box.find(["example"]))
        #expect(!box.showsOpen)
        #expect(!box.find(["microphone"]))
        // The search gone, it's as you left it.
        #expect(box.find([]))
        #expect(!box.showsOpen)
    }

    @Test func keysOpenFoldAndMoveBetweenBoxes() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let group = FormGroup(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let first = box("a.example"), second = box("b.example")
        group.add(first)
        group.add(second)
        window.contentView = group
        group.layoutSubtreeIfNeeded()
        InteractiveView.debugKeyboardAccess = true
        defer { InteractiveView.debugKeyboardAccess = false }
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        #expect(window.makeFirstResponder(first.header))
        first.header.keyDown(with: key(124))
        #expect(first.isOpen)
        first.header.keyDown(with: key(123))
        #expect(!first.isOpen)
        // Space presses it, as every drawn control.
        first.header.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!)
        #expect(first.isOpen)
        group.layoutSubtreeIfNeeded()
        first.header.keyDown(with: key(125))
        #expect(window.firstResponder === second.header)
        second.header.keyDown(with: key(126))
        #expect(window.firstResponder === first.header)
    }

    @Test func aFoldedBoxMakesNothingUntilOpenedOrSearched() {
        var made = 0
        let header = FormRow(title: "View", detail: "2 shortcuts", control: NSView())
        let box = FoldBox(key: "shortcuts View", header: header, contents: "Reload Page Zoom In", isOpen: false) {
            made += 1
            return [self.row("Reload Page"), self.row("Zoom In")]
        }
        box.frame = NSRect(x: 0, y: 0, width: 600, height: box.height(for: 600))
        box.layoutSubtreeIfNeeded()
        #expect(made == 0 && !box.isBuilt)
        // Words none of its rows have: passed over, still unmade.
        #expect(!box.find(["camera"]))
        #expect(made == 0)
        // Words one has: made, and open to it.
        #expect(box.find(["zoom"]))
        #expect(made == 1 && box.isBuilt)
        #expect(box.shownRows.map(\.debugTitle) == ["Zoom In"])
        // Opened, another box makes its rows once.
        var other = 0
        let second = FoldBox(key: "shortcuts Edit", header: FormRow(title: "Edit", control: NSView()), contents: nil, isOpen: false) {
            other += 1
            return [self.row("Copy")]
        }
        #expect(other == 0)
        second.isOpen = true
        second.isOpen = false
        second.isOpen = true
        #expect(other == 1 && second.shownRows.map(\.debugTitle) == ["Copy"])
        // Nothing inside: a card with no chevron, which isn't a disclosure triangle.
        let card = FoldBox(key: "type pdf", header: FormRow(title: "pdf", control: NSView()), contents: nil, isOpen: false, build: nil)
        #expect(card.header.isLeaf && !card.header.isAccessibilityElement())
    }

    @Test func boxesKeepAGapWhereRowsHaveAHairline() {
        let group = FormGroup(frame: NSRect(x: 0, y: 0, width: 600, height: 0))
        let plain = row("Ask before a site downloads files")
        let first = box("a.example"), second = box("b.example")
        [plain, first, second].forEach(group.add)
        let rows = plain.height(for: 600) + first.height(for: 600) + second.height(for: 600)
        #expect(group.fittingHeight(for: 600) == rows + FoldStyle.gap * 2)
        group.frame.size.height = group.fittingHeight(for: 600)
        group.layoutSubtreeIfNeeded()
        #expect(second.frame.minY == first.frame.maxY + FoldStyle.gap)
        // No hairline beside a box: its edge does that.
        let lines = group.subviews.compactMap { $0 as? ColorView }.filter { !$0.isHidden && $0.frame.height == Tokens.Metric.hairline }
        #expect(lines.isEmpty)
    }

    @Test func aListsOwnSearchNarrowsOnlyItsBoxes() {
        let group = FormGroup(frame: NSRect(x: 0, y: 0, width: 600, height: 0))
        let plain = row("Ask before a site downloads files")
        let alpha = box("alpha.example"), beta = box("beta.example")
        [plain, alpha, beta].forEach(group.add)
        group.boxFilter = ["alpha"]
        #expect(group.filter([]) == 2)
        #expect(!plain.isHidden && !alpha.isHidden && beta.isHidden)
        // A choice inside a box finds it too, opened to that row.
        group.boxFilter = ["beta", "zoom"]
        group.filter([])
        #expect(alpha.isHidden && !beta.isHidden)
        #expect(beta.shownRows.map(\.debugTitle) == ["Zoom"])
        group.boxFilter = []
        #expect(group.filter([]) == 3)
    }
}

/// Settings' long lists as boxes that fold (#368): Site Permissions' sites and Installed's extensions.
@MainActor
struct SettingsFoldingTests {
    private func withSites(_ count: Int, _ body: ([String]) throws -> Void) rethrows {
        let name = "SettingsFoldingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: name)
        }
        let sites = (0..<count).map { "fold-\($0).example" }
        for site in sites { SitePermissions.setChoice(.allow, for: .camera, origin: "https://\(site)") }
        SitePermissions.setChoice(.block, for: .notifications, origin: "https://\(sites[0])")
        try body(sites)
    }

    private func privacy() -> SettingsView {
        let settings = SettingsView(pane: .privacy)
        settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
        settings.debugReadNow()
        return settings
    }

    private func box(_ site: String, in settings: SettingsView) throws -> FoldBox {
        try #require(settings.debugSiteBoxes.first { $0.headerRow.debugTitle == site })
    }

    @Test func eachSiteIsABoxHeadedByItsNameAndHowManyChoices() throws {
        try withSites(5) { sites in
            let settings = privacy()
            let first = try box(sites[0], in: settings)
            #expect(first.headerRow.debugDetail.stringValue == FoldStyle.settingsSummary(2))
            let second = try box(sites[1], in: settings)
            #expect(second.headerRow.debugDetail.stringValue == FoldStyle.settingsSummary(1))
            #expect(first.rows.map(\.debugTitle) == ["Camera", "Notifications"])
            // Forget stays on the header.
            #expect((first.headerRow.control as? PillButton)?.title == "Forget")
            // A long list starts folded.
            #expect(settings.debugSiteBoxes.count >= 5)
            #expect(settings.debugSiteBoxes.allSatisfy { !$0.isOpen })
        }
    }

    @Test func aFoldIsKeptWhileSettingsStaysOpen() throws {
        try withSites(5) { sites in
            let settings = privacy()
            let first = try box(sites[0], in: settings)
            #expect(first.header.accessibilityPerformPress())
            #expect(first.isOpen)
            // A choice changed rebuilds the list: the box stays open.
            settings.debugChooseSitePermission("Notifications", "Allow")
            let rebuilt = try box(sites[0], in: settings), second = try box(sites[1], in: settings)
            #expect(rebuilt !== first && rebuilt.isOpen)
            #expect(!second.isOpen)
            // Settings opened again starts as long lists do.
            let again = try box(sites[0], in: privacy())
            #expect(!again.isOpen)
        }
    }

    @Test func findASettingOpensTheBoxAMatchIsIn() throws {
        try withSites(5) { sites in
            let settings = privacy()
            settings.debugFind("notifications \(sites[0])")
            let first = try box(sites[0], in: settings)
            #expect(!first.isHidden && first.showsOpen)
            #expect(first.shownRows.map(\.debugTitle) == ["Notifications"])
            #expect(settings.debugFound.contains("Notifications"))
            settings.debugFind("")
            #expect(!first.showsOpen)
        }
    }

    @Test func manySitesGetASearchOfTheirOwn() throws {
        try withSites(FoldStyle.searchFrom) { sites in
            let settings = privacy()
            #expect(settings.debugSitesSearchShows)
            settings.debugSearchSites("fold-3")
            let shown = settings.debugSiteBoxes.filter { !$0.isHidden }.map(\.headerRow.debugTitle)
            #expect(shown == ["fold-3.example"])
            settings.debugSearchSites("")
            #expect(settings.debugSiteBoxes.filter { !$0.isHidden }.count >= sites.count)
        }
    }

    @available(macOS 15.4, *)
    private func fixture(_ name: String) async throws -> WKWebExtension {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version": 3, "name": "\#(name)", "version": "1.2", "host_permissions": ["<all_urls>"]}"#
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return try await WKWebExtension(resourceBaseURL: folder)
    }

    @Test func eachExtensionIsABoxWithItsSettingsInside() async throws {
        guard #available(macOS 15.4, *) else { return }
        let ext = try await fixture("Fold Test")
        let settings = SettingsView(pane: .extensions)
        let box = settings.debugExtensionFold(id: "fold-test", ext: ext, in: 5)
        #expect(box.headerRow.debugTitle == "Fold Test")
        #expect(box.headerRow.debugDetail.stringValue.contains("1.2"))
        #expect(box.rows.map(\.debugTitle).contains("Site access"))
        #expect(box.rows.last?.debugTitle == "Allow in private windows")
        #expect(!box.isOpen)
        // A short list opens.
        #expect(settings.debugExtensionFold(id: "fold-test", ext: ext, in: 2).isOpen)
        // Find a setting opens it to what matches.
        #expect(box.find(["private"]))
        #expect(box.shownRows.map(\.debugTitle) == ["Allow in private windows"])
        // Its own search narrows to the extensions named.
        let group = FormGroup()
        let other = settings.debugExtensionFold(id: "other", ext: try await fixture("Another"), in: 5)
        [box, other].forEach(group.add)
        group.boxFilter = ["another"]
        group.filter([])
        #expect(box.isHidden && !other.isHidden)
    }

    /// The sites shown by the list's own search, each with the titles of the rows open in it.
    private func found(_ settings: SettingsView, _ text: String) -> [String: [String]] {
        settings.debugSearchSites(text)
        return Dictionary(uniqueKeysWithValues: settings.debugSiteBoxes.filter { !$0.isHidden }.map { ($0.headerRow.debugTitle, $0.shownRows.map(\.debugTitle)) })
    }

    @Test func aPermissionsNameFindsItsSites() throws {
        try withSites(FoldStyle.searchFrom) { sites in
            let settings = privacy()
            // Every site with a camera choice, each under its own name, opened to that row alone.
            let camera = found(settings, "camera")
            #expect(camera.count == sites.count && camera.values.allSatisfy { $0 == ["Camera"] })
            // A choice finds the permissions that have it.
            #expect(found(settings, "notifications") == [sites[0]: ["Notifications"]])
            #expect(found(settings, "block") == [sites[0]: ["Notifications"]])
            #expect(found(settings, "blocked") == [sites[0]: ["Notifications"]])
            #expect(found(settings, "camera allow").count == sites.count)
            #expect(found(settings, "camera block").isEmpty)
            // A site's name still finds its whole box, folded as it was.
            #expect(found(settings, sites[3]) == [sites[3]: []])
        }
    }

    @Test func aPermissionsNameFindsItsSitesInItsLanguage() throws {
        PseudoLocale.install()
        try PseudoLocale.$speaking.withValue("de") {
            try withSites(FoldStyle.searchFrom) { sites in
                let settings = privacy()
                let camera = SitePermission.camera.title, notifications = SitePermission.notifications.title
                #expect(camera == "Kamera")
                let byName = found(settings, camera)
                #expect(byName.count == sites.count && byName.values.allSatisfy { $0 == [camera] })
                #expect(found(settings, PermissionChoice.block.title) == [sites[0]: [notifications]])
                // The English name isn't what the rows say.
                #expect(found(settings, "camera").isEmpty)
            }
        }
    }

    @Test func findASettingReachesAFoldedRowAndOpensItsBox() throws {
        let name = "SettingsFoldingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let before = DeveloperTools.defaults
        DeveloperTools.defaults = defaults
        defer {
            DeveloperTools.defaults = before
            defaults.removePersistentDomain(forName: name)
        }
        let sites = (0..<5).map { "fold-dev-\($0).example" }
        DevelopmentSites.sites = sites
        let settings = SettingsView(pane: .general)
        settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
        settings.show(.developer)
        // More than three: one box headed by how many, folded, its rows not made.
        let box = try #require(settings.debugDeveloperSitesBox)
        #expect(box.headerRow.debugTitle == "5 sites")
        #expect(!box.isOpen && !box.isBuilt)
        settings.debugFind("fold-dev-3")
        #expect(box.isBuilt && box.showsOpen && !box.isOpen)
        #expect(box.shownRows.map(\.debugTitle) == ["fold-dev-3.example"])
        #expect(settings.debugFound.contains("fold-dev-3.example"))
        settings.debugFind("")
        #expect(!box.showsOpen)
    }
}

/// Settings makes a pane's rows the first time it's shown or searched, and a box's when it opens (#536).
@MainActor
struct SettingsLazyBuildTests {
    private func settings(_ pane: SettingsPane) -> SettingsView {
        let settings = SettingsView(pane: pane)
        settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
        settings.layoutSubtreeIfNeeded()
        settings.debugReadNow()
        return settings
    }

    @Test func openingOnGeneralMakesNoRowsForTheOtherPanes() {
        let settings = settings(.general)
        #expect(settings.debugBuiltPanes == [.general])
        #expect(settings.debugRowCount(.general) > 0)
        for pane in SettingsPane.allCases where pane != .general {
            #expect(settings.debugRowCount(pane) == 0, "\(pane)")
        }
        // Shown, a pane is made; a deep link to one is made the same way.
        settings.show(.downloads)
        #expect(settings.debugRowCount(.downloads) > 0)
        #expect(self.settings(.developer).debugRowCount(.developer) > 0)
        #expect(settings.debugRowCount(.shortcuts) == 0)
    }

    @Test func eachDownloadRuleIsABoxWithItsAnswersInside() throws {
        let name = "SettingsLazyBuildTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        let store = DownloadRulesStore.shared
        let kept = store.rules
        defer {
            store.replace(kept)
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: name)
        }
        let answered = DownloadRule(name: "Answered", pattern: "answered.example", action: DownloadRuleAction(kind: .openURL))
        let plain = DownloadRule(name: "Plain", pattern: "plain.example", action: DownloadRuleAction(kind: .openURL))
        store.replace([answered, plain])
        SitePermissions.remember("handOff", subject: PermissionSubject.handoff(answered.id), origin: "https://answered.example")
        let boxes = settings(.downloads).debugRuleBoxes
        #expect(boxes.map(\.headerRow.debugTitle) == ["Answered", "Plain"])
        // Its saved answer inside, under the rule's own row.
        let answer = try #require(boxes.first?.rows.first)
        #expect(answer.debugDetail.stringValue.contains("answered.example"))
        // Nothing saved: a card with no chevron.
        #expect(boxes.last?.header.isLeaf == true)
        // Each is dragged by its header to change the order.
        #expect(boxes.allSatisfy { $0.header.onDragStart != nil })
    }

    @Test func shortcutsAreABoxForEachMenu() throws {
        let settings = settings(.shortcuts)
        let boxes = settings.debugShortcutBoxes
        let menus = (NSApp.mainMenu?.items ?? []).filter { top in top.submenu?.items.contains(where: Shortcuts.isListed) == true }
        #expect(boxes.count >= menus.count && boxes.count > FoldStyle.openUpTo)
        // A long list starts folded, and nothing in it is made.
        #expect(boxes.allSatisfy { !$0.isOpen && !$0.isBuilt })
        let first = try #require(boxes.first)
        #expect(first.headerRow.debugDetail.stringValue == SettingsView.shortcutsSummary(first.content.count))
    }

    @Test func findASettingOpensTheMenuAShortcutIsIn() throws {
        let settings = settings(.general)
        // The longest name of a shortcut straight in a menu, so few other menus have every word of it.
        let items = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu).flatMap(\.items).filter(Shortcuts.isListed)
        let item = try #require(items.max { $0.title.count < $1.title.count })
        let title = item.title.hasSuffix("…") ? String(item.title.dropLast()) : item.title
        settings.debugFind(title)
        let box = try #require(settings.debugShortcutBoxes.first { $0.isBuilt && $0.shownContent.contains { ($0 as? ShortcutRow)?.debugTitle == title } })
        #expect(!box.isHidden && box.showsOpen && !box.isOpen)
        // Menus without those words stay unmade.
        #expect(settings.debugShortcutBoxes.contains { !$0.isBuilt })
    }
}

/// Settings › Profiles with data on this Mac from many profiles in no list.
@MainActor
struct SettingsUnlistedTests {
    private func settings() -> (SettingsView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 776), styleMask: [.borderless], backing: .buffered, defer: false)
        let settings = SettingsView(pane: .profiles)
        settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
        window.contentView?.addSubview(settings)
        settings.layoutSubtreeIfNeeded()
        settings.debugReadNow()
        return (settings, window)
    }

    /// Thousands of rows froze Settings for over a minute in Auto Layout as the group joined the page.
    @Test func manyUnlistedProfilesFoldIntoOneBoxAndShowAtOnce() throws {
        let (settings, window) = settings()
        let start = Date()
        settings.debugShowUnlisted((0..<2000).map { _ in UUID() })
        settings.layoutSubtreeIfNeeded()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        #expect(ms < 300, "\(ms) ms")
        let box = try #require(settings.debugUnlistedRows.first as? FoldBox)
        #expect(settings.debugUnlistedRows.count == 1)
        #expect(!box.isOpen && !box.isBuilt)
        #expect(box.headerRow.debugTitle.contains(2000.formatted()))
        _ = window
    }

    @Test func upToThreeAreRowsAndMoreAreABoxThatOpensToThem() throws {
        let (settings, window) = settings()
        settings.debugShowUnlisted([UUID(), UUID(), UUID()])
        #expect(settings.debugUnlistedRows.count == 3)
        #expect(settings.debugUnlistedRows.allSatisfy { $0 is FormRow })
        settings.debugShowUnlisted((0..<5).map { _ in UUID() })
        let box = try #require(settings.debugUnlistedRows.first as? FoldBox)
        settings.debugFold("open \(box.headerRow.debugTitle)")
        #expect(box.isOpen && box.rows.count == 5)
        _ = window
    }
}
