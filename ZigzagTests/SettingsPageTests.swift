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
    }

    @Test func theColumnKeepsItsOrder() {
        #expect(SettingsPane.allCases == [.general, .appearance, .tabs, .spaces, .profiles, .search, .mini, .passwords, .privacy,
                                          .translation, .extensions, .websiteData, .shortcuts])
    }

    @Test func withOneProfileTheColumnIsAsItWasBeforeProfiles() {
        let column = SettingsPane.column(manyProfiles: false)
        #expect(column.shared == [.general, .appearance, .tabs, .spaces, .profiles, .search, .mini, .passwords, .privacy,
                                  .translation, .extensions, .shortcuts])
        #expect(column.profile.isEmpty)
        // What websites keep is in Privacy, and an address that names Website Data opens it there.
        #expect(SettingsPane.websiteData(manyProfiles: false) == .privacy)
        #expect(SettingsPane.websiteData.shown(manyProfiles: false) == .privacy)
        #expect(SettingsPane.privacy.shown(manyProfiles: false) == .privacy)
    }

    @Test func withMoreProfilesTheSectionsAboutOneStandApart() {
        let column = SettingsPane.column(manyProfiles: true)
        #expect(column.profile == [.extensions, .websiteData])
        #expect(column.shared == [.general, .appearance, .tabs, .spaces, .profiles, .search, .mini, .passwords, .privacy,
                                  .translation, .shortcuts])
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
