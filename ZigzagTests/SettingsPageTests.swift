import AppKit
import Testing
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
