import Foundation
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
    }

    @Test func theColumnKeepsItsOrder() {
        #expect(SettingsPane.allCases == [.general, .appearance, .tabs, .spaces, .profiles, .search, .mini, .translation, .passwords,
                                          .privacy, .websiteData, .extensions, .shortcuts, .automation])
    }

    @Test func theColumnIsInGroups() {
        let groups = SettingsPane.columnGroups(manyProfiles: false)
        #expect(groups.shared == [[.general, .appearance, .tabs, .spaces, .profiles], [.search, .mini, .translation],
                                  [.passwords, .privacy], [.extensions, .shortcuts, .automation]])
        #expect(groups.profile.isEmpty)
        // A gap before each group but the first.
        #expect(SettingsPane.groupStarts(manyProfiles: false) == [.search, .passwords, .extensions])
    }

    @Test func withMoreProfilesExtensionsLeavesItsGroup() {
        let groups = SettingsPane.columnGroups(manyProfiles: true)
        #expect(groups.shared == [[.general, .appearance, .tabs, .spaces, .profiles], [.search, .mini, .translation],
                                  [.passwords, .privacy], [.shortcuts, .automation]])
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
        #expect(column.shared == [.general, .appearance, .tabs, .spaces, .profiles, .search, .mini, .translation, .passwords, .privacy,
                                  .extensions, .shortcuts, .automation])
        #expect(column.profile.isEmpty)
        // What websites keep is in Privacy, and an address that names Website Data opens it there.
        #expect(SettingsPane.websiteData(manyProfiles: false) == .privacy)
        #expect(SettingsPane.websiteData.shown(manyProfiles: false) == .privacy)
        #expect(SettingsPane.privacy.shown(manyProfiles: false) == .privacy)
    }

    @Test func withMoreProfilesTheSectionsAboutOneStandApart() {
        let column = SettingsPane.column(manyProfiles: true)
        #expect(column.profile == [.extensions, .websiteData])
        #expect(column.shared == [.general, .appearance, .tabs, .spaces, .profiles, .search, .mini, .translation, .passwords, .privacy,
                                  .shortcuts, .automation])
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

/// Find a setting, in Settings' header.
@MainActor
struct SettingsSearchTests {
    /// Find a setting knows the words people look for, and leads to the nearest row where there's no such setting.
    @Test func findsCommonWords() {
        let settings = SettingsView(pane: .general)
        let expected = ["startup": "Ask before quitting", "launch": "Ask before quitting", "homepage": "New tabs open",
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
}
