import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Which profiles there are and which space is on which, as Profiles.json keeps it.
@MainActor
struct ProfileDirectoryTests {
    private let work = UUID(), play = UUID(), study = UUID()

    @Test func aNewDirectoryHasOnlyTheFirstProfile() {
        let directory = ProfileDirectory()
        #expect(directory.all.map(\.id) == [Profile.defaultID])
        #expect(directory.all[0].isDefault && directory.all[0].name == nil)
        #expect(directory.profileID(ofSpace: work) == Profile.defaultID)
    }

    @Test func aSpaceGoesOnAProfileAndBack() {
        var directory = ProfileDirectory()
        let crypto = directory.add(name: "Crypto")
        directory.assign(space: work, to: crypto.id)
        #expect(directory.profileID(ofSpace: work) == crypto.id)
        #expect(directory.profileID(ofSpace: play) == Profile.defaultID)
        directory.assign(space: work, to: Profile.defaultID)
        #expect(directory.profileID(ofSpace: work) == Profile.defaultID)
        #expect(directory.assignments.isEmpty)
    }

    @Test func aSpaceCantGoOnAProfileThatIsntThere() {
        var directory = ProfileDirectory()
        directory.assign(space: work, to: UUID())
        #expect(directory.profileID(ofSpace: work) == Profile.defaultID)
        #expect(directory.assignments.isEmpty)
    }

    @Test func removingAProfileMovesItsSpacesAndNotesItForErasing() {
        var directory = ProfileDirectory()
        let crypto = directory.add(name: "Crypto"), school = directory.add(name: "School")
        directory.assign(space: work, to: crypto.id)
        directory.assign(space: play, to: crypto.id)
        directory.assign(space: study, to: school.id)
        #expect(Set(directory.remove(crypto.id)) == [work, play])
        #expect(directory.all.map(\.id) == [Profile.defaultID, school.id])
        #expect(directory.deleting.map(\.id) == [crypto.id])
        #expect(directory.profileID(ofSpace: work) == Profile.defaultID)
        #expect(directory.profileID(ofSpace: study) == school.id)
        directory.finishedDeleting(crypto.id)
        #expect(directory.deleting.isEmpty)
    }

    @Test func theFirstProfileCantBeRemovedButCanBeNamed() {
        var directory = ProfileDirectory()
        #expect(directory.remove(Profile.defaultID).isEmpty)
        #expect(directory.all.count == 1 && directory.deleting.isEmpty)
        directory.update(Profile.defaultID, name: "Home", color: .sage)
        #expect(directory.all[0].name == "Home" && directory.all[0].color == .sage && directory.all[0].isDefault)
    }

    @Test func undoPutsSpacesBackButNotARemovedProfile() {
        var directory = ProfileDirectory()
        let crypto = directory.add(name: "Crypto"), school = directory.add(name: "School")
        directory.assign(space: work, to: crypto.id)
        directory.assign(space: study, to: school.id)
        let before = directory.assignments
        directory.assign(space: study, to: Profile.defaultID)
        directory.remove(crypto.id)
        directory.restore(assignments: before)
        #expect(directory.profileID(ofSpace: study) == school.id)
        #expect(directory.profileID(ofSpace: work) == Profile.defaultID)
    }

    @Test func spacesThatAreGoneAreForgottenOnlyWhenAsked() {
        var directory = ProfileDirectory()
        let crypto = directory.add(name: "Crypto")
        directory.assign(space: work, to: crypto.id)
        directory.assign(space: play, to: crypto.id)
        directory.prune(keeping: [work], favorites: [])
        #expect(directory.assignments.spaces.keys.sorted() == [work.uuidString])
    }

    @Test func aFavoriteIsTheFirstProfilesUntilItsGivenToAnother() {
        var directory = ProfileDirectory()
        let crypto = directory.add(name: "Crypto")
        #expect(directory.profileID(ofFavorite: work) == Profile.defaultID)
        directory.assign(favorite: work, to: crypto.id)
        #expect(directory.profileID(ofFavorite: work) == crypto.id)
        // A space and a favorite are told apart, whatever their ids.
        #expect(directory.profileID(ofSpace: work) == Profile.defaultID)
        directory.assign(favorite: work, to: Profile.defaultID)
        #expect(directory.assignments.isEmpty)
    }

    @Test func aRemovedProfilesFavoritesArentKeptAndUndoDoesntBringThemBack() {
        var directory = ProfileDirectory()
        let crypto = directory.add(name: "Crypto"), school = directory.add(name: "School")
        directory.assign(favorite: work, to: crypto.id)
        directory.assign(favorite: study, to: school.id)
        let before = directory.assignments
        directory.remove(crypto.id)
        #expect(directory.assignments.favorites == [study.uuidString: school.id])
        directory.restore(assignments: before)
        #expect(directory.profileID(ofFavorite: work) == Profile.defaultID)
        #expect(directory.profileID(ofFavorite: study) == school.id)
    }

    @Test func favoritesThatAreGoneAreForgottenOnlyWhenAsked() {
        var directory = ProfileDirectory()
        let crypto = directory.add(name: "Crypto")
        directory.assign(favorite: work, to: crypto.id)
        directory.assign(favorite: play, to: crypto.id)
        directory.prune(keeping: [], favorites: [play])
        #expect(directory.assignments.favorites.keys.sorted() == [play.uuidString])
    }

    @Test func storesWithNoProfileAreOrphansButOnesBeingRemovedArent() {
        var directory = ProfileDirectory()
        let crypto = directory.add(name: "Crypto"), school = directory.add(name: "School")
        directory.remove(school.id)
        let stray = UUID()
        #expect(directory.orphans(amongStores: [crypto.id, school.id, stray]) == [stray])
    }

    /// Data under an ID that's no profile's can be written down for erasing; a profile's own, the first's above
    /// all, never can.
    @Test func onlyWhatIsNoProfilesCanBeMarkedForErasing() {
        var directory = ProfileDirectory()
        let crypto = directory.add(name: "Crypto")
        let stray = UUID()
        directory.markForErasing(Profile.defaultID)
        directory.markForErasing(crypto.id)
        #expect(directory.deleting.isEmpty)
        directory.markForErasing(stray)
        directory.markForErasing(stray)
        #expect(directory.deleting.map(\.id) == [stray])
        #expect(directory.all.map(\.id) == [Profile.defaultID, crypto.id])
    }

    @Test func whatIsOnDiskIsListedOnceAndNeverTheFirstProfiles() {
        var directory = ProfileDirectory()
        let crypto = directory.add(name: "Crypto")
        let stray = UUID()
        // A store and a folder under the same ID are one thing to ask about.
        #expect(directory.orphans(amongStores: [stray, crypto.id, Profile.defaultID, stray]) == [stray])
    }

    @Test func itSurvivesTheFile() throws {
        var directory = ProfileDirectory()
        let crypto = directory.add(name: "Crypto", color: .mint)
        directory.update(Profile.defaultID, name: "Home", color: nil)
        directory.assign(space: work, to: crypto.id)
        directory.assign(favorite: play, to: crypto.id)
        directory.remove(directory.add(name: "Gone").id)
        let read = try JSONDecoder().decode(ProfileDirectory.self, from: JSONEncoder().encode(directory))
        #expect(read == directory)
    }

    /// A file that lists the first profile as being removed (damaged, or edited by hand) is read without it: what
    /// finishes removals would otherwise erase the first profile's passwords and extensions.
    @Test func theFirstProfileIsNeverReadAsBeingRemoved() throws {
        let json = #"{"deleting":[{"id":"\#(Profile.defaultID.uuidString)","name":"Oops"},{"id":"\#(work.uuidString)","name":"Gone"}]}"#
        let read = try JSONDecoder().decode(ProfileDirectory.self, from: Data(json.utf8))
        #expect(read.deleting.map(\.id) == [work])
    }

    @Test func aFileThatLeavesThingsOutStillReads() throws {
        let empty = try JSONDecoder().decode(ProfileDirectory.self, from: Data("{}".utf8))
        #expect(empty == ProfileDirectory())
        let id = UUID()
        let partial = try JSONDecoder().decode(ProfileDirectory.self, from: Data(#"{"others":[{"id":"\#(id.uuidString)","name":"Crypto"}]}"#.utf8))
        #expect(partial.all.map(\.id) == [Profile.defaultID, id] && partial.all[1].name == "Crypto")
    }

    @Test func theFirstProfileIsNeverListedTwice() throws {
        let json = #"{"others":[{"id":"\#(Profile.defaultID.uuidString)","name":"Twice"}]}"#
        #expect(try JSONDecoder().decode(ProfileDirectory.self, from: Data(json.utf8)).all.count == 1)
    }
}

/// What a profile chooses for itself in the preferences, and when Zigzag's own passwords step aside for a
/// password manager.
@MainActor
struct ProfileChoiceTests {
    @Test func theFirstProfileKeepsThePlainNamesAndOthersGetTheirOwn() {
        let work = UUID()
        #expect(ProfileKey.offersToSavePasswords.name(in: Profile.defaultID) == "PasswordsOfferToSave")
        #expect(ProfileKey.fillsPasswords.name(in: Profile.defaultID) == "PasswordsAutofill")
        #expect(ProfileKey.extensionsPinned.name(in: Profile.defaultID) == "ExtensionsPinned")
        #expect(ProfileKey.extensionsPinned.name(in: work) == "ExtensionsPinned.\(work.uuidString)")
        // Extension site settings are per profile too.
        #expect(ProfileKey.extensionsOffSites.name(in: Profile.defaultID) == "ExtensionsOffSites")
        #expect(ProfileKey.extensionsOffSites.name(in: work) == "ExtensionsOffSites.\(work.uuidString)")
    }

    @Test func aRemovedProfileLeavesNoChoiceBehindAndTheFirstKeepsIts() throws {
        let suite = "ProfileChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = UUID()
        for key in ProfileKey.allCases {
            defaults.set(true, forKey: key.name(in: work))
            defaults.set(true, forKey: key.name(in: Profile.defaultID))
        }
        #expect(ProfileKey.offersToSavePasswords.choice(in: work, defaults: defaults) == true)
        ProfileKey.forget(work, in: defaults)
        ProfileKey.forget(Profile.defaultID, in: defaults)
        for key in ProfileKey.allCases {
            #expect(defaults.object(forKey: key.name(in: work)) == nil)
            #expect(defaults.object(forKey: key.name(in: Profile.defaultID)) != nil)
        }
        #expect(ProfileKey.offersToSavePasswords.choice(in: work, defaults: defaults) == nil)
    }

    @Test func zigzagStepsAsideForAPasswordManagerUntilYouChoose() {
        // Nothing chosen: on, unless a manager is on in that profile.
        #expect(PasswordManagers.zigzagHandles(chosen: nil, managerOn: false))
        #expect(!PasswordManagers.zigzagHandles(chosen: nil, managerOn: true))
        // Passwords brought over from another browser are there to be filled even so.
        #expect(PasswordManagers.zigzagHandles(chosen: nil, managerOn: true, imported: true))
        // What you chose stands, either way.
        #expect(PasswordManagers.zigzagHandles(chosen: true, managerOn: true))
        #expect(!PasswordManagers.zigzagHandles(chosen: false, managerOn: false, imported: true))
    }

    @Test func iCloudPasswordsTurnsZigzagOffAndZigzagComesBackAsItWas() throws {
        let suite = "ProfileChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = UUID(), home = Profile.defaultID
        #expect(PasswordFiller.chosen(in: work, defaults: defaults) == nil)
        // Work saved but didn't fill; home did both.
        PasswordFiller.useICloud(in: work, saves: true, fills: false, defaults: defaults)
        PasswordFiller.useICloud(in: home, saves: true, fills: true, defaults: defaults)
        for profile in [work, home] {
            #expect(PasswordFiller.chosen(in: profile, defaults: defaults) == .iCloud)
            #expect(ProfileKey.offersToSavePasswords.choice(in: profile, defaults: defaults) == false)
            #expect(ProfileKey.fillsPasswords.choice(in: profile, defaults: defaults) == false)
        }
        // Chosen again: restores Zigzag's previous state, not the current off.
        PasswordFiller.useICloud(in: work, saves: false, fills: false, defaults: defaults)
        PasswordFiller.useZigzag(in: work, defaults: defaults)
        #expect(PasswordFiller.chosen(in: work, defaults: defaults) == .zigzag)
        #expect(ProfileKey.offersToSavePasswords.choice(in: work, defaults: defaults) == true)
        #expect(ProfileKey.fillsPasswords.choice(in: work, defaults: defaults) == false)
        // The other profile still uses iCloud.
        #expect(PasswordFiller.chosen(in: home, defaults: defaults) == .iCloud)
        PasswordFiller.useZigzag(in: home, defaults: defaults)
        #expect(ProfileKey.offersToSavePasswords.choice(in: home, defaults: defaults) == true)
        #expect(ProfileKey.fillsPasswords.choice(in: home, defaults: defaults) == true)
        // Both off before: choosing Zigzag turns both on.
        let other = UUID()
        PasswordFiller.useICloud(in: other, saves: false, fills: false, defaults: defaults)
        PasswordFiller.useZigzag(in: other, defaults: defaults)
        #expect(ProfileKey.offersToSavePasswords.choice(in: other, defaults: defaults) == true)
        #expect(ProfileKey.fillsPasswords.choice(in: other, defaults: defaults) == true)
        // Removing a profile removes its choice.
        ProfileKey.forget(work, in: defaults)
        #expect(PasswordFiller.chosen(in: work, defaults: defaults) == nil)
    }

    @Test func theChoiceShowsWhoFillsUntilOneIsMade() {
        // Nothing chosen: iCloud only when its extension is on and Zigzag stepped aside.
        #expect(PasswordFiller.current(chosen: nil, iCloudOn: false, zigzagSaves: true, zigzagFills: true) == .zigzag)
        #expect(PasswordFiller.current(chosen: nil, iCloudOn: true, zigzagSaves: false, zigzagFills: false) == .iCloud)
        // Passwords imported from another browser are still filled by Zigzag.
        #expect(PasswordFiller.current(chosen: nil, iCloudOn: true, zigzagSaves: false, zigzagFills: true) == .zigzag)
        #expect(PasswordFiller.current(chosen: .zigzag, iCloudOn: true, zigzagSaves: false, zigzagFills: false) == .zigzag)
        #expect(PasswordFiller.current(chosen: .iCloud, iCloudOn: false, zigzagSaves: false, zigzagFills: false) == .iCloud)
    }

    @Test func iCloudPasswordsIsAddedOrTurnedOnOnlyWhenItNeedsTo() {
        #expect(PasswordFiller.need(installed: false, enabled: false) == .install)
        #expect(PasswordFiller.need(installed: false, enabled: true) == .install)
        #expect(PasswordFiller.need(installed: true, enabled: false) == .turnOn)
        #expect(PasswordFiller.need(installed: true, enabled: true) == .nothing)
        #expect(PasswordManagers.known[PasswordFiller.iCloudExtensionID] == "iCloud Passwords")
    }

    @Test func addingICloudPasswordsByHandOffersItOnce() {
        #expect(PasswordFiller.offersSwitch(chosen: nil, zigzagHandles: true, offered: false))
        #expect(!PasswordFiller.offersSwitch(chosen: nil, zigzagHandles: true, offered: true))
        // Zigzag already stepped aside, or a choice was made: nothing to ask.
        #expect(!PasswordFiller.offersSwitch(chosen: nil, zigzagHandles: false, offered: false))
        #expect(!PasswordFiller.offersSwitch(chosen: .zigzag, zigzagHandles: true, offered: false))
        #expect(!PasswordFiller.offersSwitch(chosen: .iCloud, zigzagHandles: true, offered: false))
    }

    @Test func thePasswordManagerIsNamedFromWhatIsInstalled() {
        #expect(PasswordManagers.active(among: []) == nil)
        #expect(PasswordManagers.active(among: ["not-a-password-manager"]) == nil)
        #expect(PasswordManagers.active(among: ["nngceckbapebfimnlniiiahkandclblb"]) == "Bitwarden")
        #expect(PasswordManagers.active(among: ["mnilpkfepdibngheginihjpknnopchbn"]) == "Strongbox")
        // Several on: always the same one.
        #expect(PasswordManagers.active(among: ["nngceckbapebfimnlniiiahkandclblb", "aeblfdkhhhdcdjpifhhbdiojplfjncoa"]) == "1Password")
    }

    @Test func passwordManagerExtensionsAreListedAfterICloudByName() {
        let bitwarden = "nngceckbapebfimnlniiiahkandclblb", onePassword = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        // Unknown ones and iCloud (its own choice) aren't listed again.
        let listed = PasswordManagers.listed(among: ["not-a-password-manager", bitwarden, PasswordFiller.iCloudExtensionID, onePassword])
        #expect(listed == [onePassword, bitwarden])
        #expect(PasswordManagerChoice.all(listed: listed) == [.zigzag, .iCloud, .manager(onePassword), .manager(bitwarden)])
        #expect(PasswordManagerChoice.all(listed: []) == [.zigzag, .iCloud])
    }

    @Test func aPasswordManagerShowsCheckedWhileZigzagStepsAside() {
        let bitwarden = "nngceckbapebfimnlniiiahkandclblb", onePassword = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        func current(_ filler: PasswordFiller = .zigzag, chosen: String? = nil, listed: [String], saves: Bool, fills: Bool) -> PasswordManagerChoice {
            PasswordManagerChoice.current(filler: filler, chosenManager: chosen, listed: listed, zigzagSaves: saves, zigzagFills: fills)
        }
        // None on: Zigzag.
        #expect(current(listed: [], saves: false, fills: false) == .zigzag)
        #expect(current(listed: [], saves: true, fills: true) == .zigzag)
        // Bitwarden on and Zigzag off: Bitwarden, not Zigzag.
        #expect(current(listed: [bitwarden], saves: false, fills: false) == .manager(bitwarden))
        // Zigzag saving or filling too: Zigzag.
        #expect(current(listed: [bitwarden], saves: true, fills: false) == .zigzag)
        #expect(current(listed: [bitwarden], saves: false, fills: true) == .zigzag)
        // Several on: the one chosen, else the first listed.
        #expect(current(listed: [onePassword, bitwarden], saves: false, fills: false) == .manager(onePassword))
        #expect(current(chosen: bitwarden, listed: [onePassword, bitwarden], saves: false, fills: false) == .manager(bitwarden))
        // Chosen, then turned off or removed: not checked.
        #expect(current(chosen: bitwarden, listed: [], saves: false, fills: false) == .zigzag)
        #expect(current(chosen: bitwarden, listed: [onePassword], saves: false, fills: false) == .manager(onePassword))
        // iCloud chosen: iCloud.
        #expect(current(.iCloud, listed: [bitwarden], saves: false, fills: false) == .iCloud)
    }

    @Test func choosingAPasswordManagerTurnsZigzagOffAndZigzagComesBackOn() throws {
        let suite = "ProfileChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bitwarden = "nngceckbapebfimnlniiiahkandclblb", onePassword = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        let work = UUID()
        func saves() -> Bool? { ProfileKey.offersToSavePasswords.choice(in: work, defaults: defaults) }
        func fills() -> Bool? { ProfileKey.fillsPasswords.choice(in: work, defaults: defaults) }
        // Zigzag saved but didn't fill.
        PasswordFiller.useManager(bitwarden, in: work, saves: true, fills: false, defaults: defaults)
        #expect(PasswordFiller.chosenManager(in: work, defaults: defaults) == bitwarden)
        #expect(PasswordFiller.chosen(in: work, defaults: defaults) == .zigzag)
        #expect(saves() == false && fills() == false)
        // Another one after it keeps what Zigzag did before the first.
        PasswordFiller.useManager(onePassword, in: work, saves: false, fills: false, defaults: defaults)
        #expect(PasswordFiller.chosenManager(in: work, defaults: defaults) == onePassword)
        PasswordFiller.useZigzag(in: work, defaults: defaults)
        #expect(PasswordFiller.chosenManager(in: work, defaults: defaults) == nil)
        #expect(saves() == true && fills() == false)
        // Stepped aside before anything was chosen: both come back on.
        PasswordFiller.useManager(bitwarden, in: work, saves: false, fills: false, defaults: defaults)
        PasswordFiller.useZigzag(in: work, defaults: defaults)
        #expect(saves() == true && fills() == true)
        // To iCloud from one: iCloud, and Zigzag comes back as it was before either.
        PasswordFiller.useManager(bitwarden, in: work, saves: false, fills: true, defaults: defaults)
        PasswordFiller.useICloud(in: work, saves: false, fills: false, defaults: defaults)
        #expect(PasswordFiller.chosen(in: work, defaults: defaults) == .iCloud)
        #expect(PasswordFiller.chosenManager(in: work, defaults: defaults) == nil)
        PasswordFiller.useManager(bitwarden, in: work, saves: false, fills: false, defaults: defaults)
        #expect(PasswordFiller.chosen(in: work, defaults: defaults) == .zigzag)
        PasswordFiller.useZigzag(in: work, defaults: defaults)
        #expect(saves() == false && fills() == true)
        // Removing a profile removes its choice.
        PasswordFiller.useManager(bitwarden, in: work, saves: true, fills: true, defaults: defaults)
        ProfileKey.forget(work, in: defaults)
        #expect(PasswordFiller.chosenManager(in: work, defaults: defaults) == nil)
    }

    @Test func aChosenExtensionZigzagDoesntKnowCountsAsOn() {
        let litewarden = "ieaiaclmomgdnlelnfnhonjajpofjomn", bitwarden = "nngceckbapebfimnlniiiahkandclblb"
        var on: Set<String> = [litewarden]
        func active(_ chosen: String?) -> String? {
            PasswordManagers.active(chosen: chosen, claimed: [], isOn: { on.contains($0) }, name: { $0 == litewarden ? "Litewarden" : $0 })
        }
        // Not chosen: an extension Zigzag doesn't know is nothing to step aside for.
        #expect(active(nil) == nil)
        // Chosen and on: it's the one, by its own name.
        #expect(active(litewarden) == "Litewarden")
        let managerOn = active(litewarden) != nil
        #expect(!PasswordManagers.zigzagHandles(chosen: nil, managerOn: managerOn))
        if #available(macOS 27, *) { #expect(!AutofillKeyIcon.shows(fills: true, managerOn: managerOn, panelAvailable: true)) }
        // Chosen over a known one that's on too.
        on.insert(bitwarden)
        #expect(active(litewarden) == "Litewarden")
        // Turned off: the known ones as before.
        on.remove(litewarden)
        #expect(active(litewarden) == "Bitwarden")
        #expect(active(nil) == "Bitwarden")
        on.remove(bitwarden)
        #expect(active(litewarden) == nil)
    }

    @Test func anExtensionThatTurnsSavingOffIsAPasswordManager() throws {
        let suite = "ProfileChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = UUID(), vault = "vault-extension", other = "some-extension", bitwarden = "nngceckbapebfimnlniiiahkandclblb"
        let names = [vault: "Vault", other: "Other"]
        func claimed() -> [String] { PasswordSavingClaims.claimants(in: work, defaults: defaults) }
        func listed() -> [String] { PasswordManagers.listed(among: [vault, other, bitwarden], claimed: claimed(), chosen: nil, name: { names[$0] ?? $0 }) }
        func active() -> String? { PasswordManagers.active(chosen: nil, claimed: claimed(), isOn: { [vault, bitwarden].contains($0) }, name: { names[$0] ?? $0 }) }
        // Nothing set: only the known one.
        #expect(listed() == [bitwarden])
        PasswordSavingClaims.set(false, by: vault, in: work, defaults: defaults)
        #expect(claimed() == [vault])
        #expect(listed() == [bitwarden, vault])
        #expect(active() == "Bitwarden")
        #expect(PasswordManagers.active(chosen: nil, claimed: claimed(), isOn: { $0 == vault }, name: { names[$0] ?? $0 }) == "Vault")
        // Only in the profile it was set in.
        #expect(PasswordSavingClaims.claimants(in: UUID(), defaults: defaults).isEmpty)
        // Turned back on: not a claim.
        PasswordSavingClaims.set(true, by: vault, in: work, defaults: defaults)
        #expect(claimed().isEmpty)
        #expect(listed() == [bitwarden])
        // clear() undoes it.
        PasswordSavingClaims.set(false, by: vault, in: work, defaults: defaults)
        #expect(PasswordSavingClaims.clear(by: vault, in: work, defaults: defaults))
        #expect(!PasswordSavingClaims.clear(by: vault, in: work, defaults: defaults))
        #expect(claimed().isEmpty)
        #expect(PasswordSavingClaims.all(in: work, defaults: defaults).isEmpty)
        // The one chosen stays listed.
        #expect(PasswordManagers.listed(among: [vault, other], claimed: [], chosen: other, name: { names[$0] ?? $0 }) == [other])
        // A removed profile leaves none behind.
        PasswordSavingClaims.set(false, by: vault, in: work, defaults: defaults)
        ProfileKey.forget(work, in: defaults)
        #expect(claimed().isEmpty)
    }

    @Test func passwordSavingReadsWhoControlsIt() throws {
        let suite = "ProfileChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = UUID()
        func answer(_ id: String) -> PasswordSavingClaims.Answer { PasswordSavingClaims.answer(for: id, in: work, defaults: defaults) }
        #expect(answer("a") == .init(value: true, levelOfControl: "controllable_by_this_extension"))
        PasswordSavingClaims.set(false, by: "a", in: work, defaults: defaults)
        #expect(answer("a") == .init(value: false, levelOfControl: "controlled_by_this_extension"))
        #expect(answer("b") == .init(value: false, levelOfControl: "controlled_by_other_extensions"))
        #expect(answer("a").dictionary["levelOfControl"] as? String == "controlled_by_this_extension")
        PasswordSavingClaims.clear(by: "a", in: work, defaults: defaults)
        #expect(answer("b") == .init(value: true, levelOfControl: "controllable_by_this_extension"))
    }

    @Test func turningOffOrRemovingAnExtensionForgetsWhatItSet() {
        let library = Library.shared
        let info = library.addProfile(name: "Password saving test")
        let profile = Profiles.shared.profile(info.id), id = "password-saving-test"
        defer {
            profile.installs.remove(id)
            library.removeProfile(info.id)
            library.finishedRemovingProfile(info.id)
        }
        profile.installs.save(ExtensionInstalls.State(), for: id)
        PasswordSavingClaims.set(false, by: id, in: profile.id)
        #expect(PasswordSavingClaims.claimants(in: profile.id) == [id])
        profile.installs.setEnabled(id, false)
        #expect(PasswordSavingClaims.claimants(in: profile.id).isEmpty)
        PasswordSavingClaims.set(false, by: id, in: profile.id)
        profile.installs.remove(id)
        #expect(PasswordSavingClaims.claimants(in: profile.id).isEmpty)
    }
}

/// Which profiles may be removed.
@MainActor
struct ProfileRemovalRuleTests {
    @Test func theFirstAnUnlistedAndOneInUseAreNotRemoved() {
        var directory = ProfileDirectory()
        let work = directory.add(name: "Work", color: nil)
        #expect(directory.removalBlock(Profile.defaultID) == .first)
        #expect(directory.removalBlock(UUID()) == .unlisted)
        #expect(directory.removalBlock(work.id) == nil)
        // Something is writing into it (an import): not until that's done.
        #expect(directory.removalBlock(work.id, inUse: [work.id]) == .inUse)
        #expect(directory.removalBlock(work.id, inUse: [UUID()]) == nil)
        // The first profile is never removed, in use or not.
        #expect(directory.removalBlock(Profile.defaultID, inUse: [Profile.defaultID]) == .first)
    }
}

/// Which profile a page belongs in, and when moving one rebuilds it.
@MainActor
struct PageProfileTests {
    @Test func aPageIsItsSpacesAndAFavoritesPageIsTheFavorites() {
        var directory = ProfileDirectory()
        let work = directory.add(name: "Work"), play = directory.add(name: "Play")
        let office = UUID(), home = UUID(), favorite = UUID()
        directory.assign(space: office, to: work.id)
        // A page in a space is that space's profile's; a space on no other profile is the first's.
        #expect(directory.profileID(ofPageIn: office) == work.id)
        #expect(directory.profileID(ofPageIn: home) == Profile.defaultID)
        // A favorite's page is the favorite's profile's, whichever space it's open in.
        directory.assign(favorite: favorite, to: play.id)
        #expect(directory.profileID(ofPageIn: office, favorite: favorite) == play.id)
        #expect(directory.profileID(ofPageIn: home, favorite: favorite) == play.id)
        // A favorite that was never given to another profile is the first's, also when open in a space on Work.
        #expect(directory.profileID(ofPageIn: office, favorite: UUID()) == Profile.defaultID)
    }

    @Test func onlyALoadedPageMovingToAnotherProfileIsRebuilt() {
        let work = UUID(), play = UUID()
        #expect(ProfileSheets.isRebuilt(isPrivate: false, isLoaded: true, in: work, movingTo: play))
        // Within a profile nothing changes for the page.
        #expect(!ProfileSheets.isRebuilt(isPrivate: false, isLoaded: true, in: work, movingTo: work))
        // A page that isn't loaded has nothing to lose, and a private one keeps its window's store.
        #expect(!ProfileSheets.isRebuilt(isPrivate: false, isLoaded: false, in: work, movingTo: play))
        #expect(!ProfileSheets.isRebuilt(isPrivate: true, isLoaded: true, in: work, movingTo: play))
    }
}

/// A profile you chose (to add an extension to, to import into) that's gone since is refused, never swapped for the
/// first; a profile that isn't chosen falls back to the first as before.
@MainActor
struct ListedProfileTests {
    @Test func aGoneProfileIsNotListedAndCantBeHeld() {
        let gone = UUID()
        #expect(Profiles.shared.listed(gone) == nil)
        #expect(Profiles.shared.profile(gone) === Profiles.shared.default)
        #expect(!Profiles.shared.hold(gone))
        #expect(!Profiles.shared.inUse.contains(gone))
    }

    @Test func theFirstProfileIsAlwaysListed() {
        #expect(Profiles.shared.listed(Profile.defaultID) === Profiles.shared.default)
    }
}

/// The AI Apps profile, where AI apps work in the background: made when needed, never twice, with a fixed name,
/// and made anew after removal.
@MainActor
struct HeadlessProfileTests {
    @Test func itsMadeOnceAndKnownByWhatItsFor() {
        var directory = ProfileDirectory()
        #expect(directory.headless == nil)
        let made = directory.addHeadless(name: "AI Apps")
        #expect(made.isHeadless && !made.isDefault && directory.headless == made)
        // Asked again, it's the same one.
        #expect(directory.addHeadless(name: "AI Apps") == made && directory.others.count == 1)
        // A profile you make is never it.
        #expect(!directory.add(name: "AI Apps").isHeadless && directory.headless == made)
    }

    @Test func itsNameStays() {
        var directory = ProfileDirectory()
        let made = directory.addHeadless(name: "AI Apps", color: .mint)
        directory.update(made.id, name: "Mine now", color: .sky)
        #expect(directory.headless?.name == "AI Apps" && directory.headless?.color == .sky)
        // Shown in your language, whatever was stored.
        #expect(directory.headless?.displayName == String(localized: "AI Apps", comment: "The name of the profile AI apps use in the background. It can't be changed."))
    }

    @Test func afterItsRemovedANewOneIsMade() {
        var directory = ProfileDirectory()
        let first = directory.addHeadless(name: "AI Apps")
        directory.remove(first.id)
        #expect(directory.headless == nil)
        let second = directory.addHeadless(name: "AI Apps")
        #expect(second.id != first.id && directory.headless == second)
    }

    @Test func itSurvivesTheFileAndOldFilesStillRead() throws {
        var directory = ProfileDirectory()
        let made = directory.addHeadless(name: "AI Apps")
        let read = try JSONDecoder().decode(ProfileDirectory.self, from: JSONEncoder().encode(directory))
        #expect(read.headless == made)
        // A file from before roles, or with a role from a later Zigzag, still reads: neither is Headless.
        let id = UUID(), later = UUID()
        let json = #"{"others":[{"id":"\#(id.uuidString)","name":"Crypto"},{"id":"\#(later.uuidString)","name":"Other","role":"somethingNew"}]}"#
        let old = try JSONDecoder().decode(ProfileDirectory.self, from: Data(json.utf8))
        #expect(old.all.count == 3 && old.headless == nil)
    }

    @Test func itsNotRemovedWhileAIAppsUseIt() {
        var directory = ProfileDirectory()
        let made = directory.addHeadless(name: "AI Apps")
        #expect(directory.removalBlock(made.id) == nil)
        #expect(directory.removalBlock(made.id, inUse: [made.id]) == .inUse)
    }
}

/// The AI Apps profile's space, through the library: made once with it, its name can't follow a space's, and
/// removed with it instead of moving to your first profile.
@MainActor
struct HeadlessSpaceTests {
    @Test func madeOnceAndGoneWithItsProfile() throws {
        let library = Library.shared
        let before = library.spaces.count
        let space = library.headlessSpace()
        let profile = try #require(library.directory.headless)
        #expect(library.profileID(ofSpace: space.id) == profile.id)
        // Asked again, it's the same one, and nothing is saved or announced: every tab an AI app opens asks.
        var told = 0
        let token = library.changed.observe { told += 1 }
        #expect(library.headlessSpace().id == space.id && library.spaces.count == before + 1)
        #expect(told == 0)
        token.cancel()
        library.renameProfile(profile.id, after: "Mine now")
        #expect(library.directory.headless?.name == "AI Apps")
        // A route to its space goes with the space, as removeSpace takes one.
        let route = SiteRoutes.Route(site: "zz-\(UUID().uuidString.lowercased()).example", spaceID: space.id)
        library.saveRoute(route)
        #expect(library.siteRoutes.contains { $0.id == route.id })
        #expect(library.removeProfile(profile.id))
        #expect(library.space(space.id) == nil && library.spaces.count == before)
        #expect(!library.siteRoutes.contains { $0.id == route.id })
        library.finishedRemovingProfile(profile.id)
    }
}

/// AI apps' profile is given nothing of yours (`Profile.isHeadless`): each thing Zigzag keeps for you, not for a
/// profile, is still given in your profiles and withheld in theirs, whichever window the page is in.
@MainActor
struct NothingOfYoursTests {
    /// A tab of theirs, and one of yours, each in no window; `check` runs while their profile is there.
    private func withTabs(_ check: (_ theirs: Tab, _ yours: Tab) async throws -> Void) async throws {
        let library = Library.shared
        let space = library.headlessSpace()
        let profile = try #require(library.directory.headless)
        defer {
            _ = library.removeProfile(profile.id)
            library.finishedRemovingProfile(profile.id)
        }
        let theirs = Tab(url: nil, spaceID: space.id), yours = Tab(url: nil, spaceID: library.spaces[0].id)
        #expect(theirs.profile.isHeadless && !yours.profile.isHeadless)
        try await check(theirs, yours)
    }

    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func challenge(_ space: URLProtectionSpace) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
                                   error: nil, sender: Sender())
    }

    /// A site's sign-in with a login saved for it: given in your profile, never in theirs.
    @Test func noSavedSignIn() async throws {
        try await withTabs { theirs, yours in
            let space = URLProtectionSpace(host: "zz-\(UUID().uuidString.lowercased()).example", port: 443, protocol: "https", realm: "Test",
                                           authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
            let saved = URLCredential(user: "me", password: "secret", persistence: .forSession)
            URLCredentialStorage.shared.setDefaultCredential(saved, for: space)
            defer { URLCredentialStorage.shared.remove(saved, for: space) }
            for (tab, gives) in [(yours, true), (theirs, false)] {
                let page = tab.ensureWebView()
                let answer = await AuthenticationPrompt.respond(to: challenge(space), window: nil, store: page.configuration.websiteDataStore, page: page)
                #expect((answer.0 == .useCredential && answer.1?.user == "me") == gives, "\(tab.profile.isHeadless) \(answer.0.rawValue)")
            }
        }
    }

    /// A site asking for a certificate there goes on without one, before the Keychain or a kept choice is read.
    @Test func noCertificate() async throws {
        try await withTabs { theirs, _ in
            let space = URLProtectionSpace(host: "zz-\(UUID().uuidString.lowercased()).example", port: 443, protocol: "https", realm: nil,
                                           authenticationMethod: NSURLAuthenticationMethodClientCertificate)
            let page = theirs.ensureWebView()
            let answer = await ClientCertificates.respond(to: challenge(space), window: nil, store: page.configuration.websiteDataStore, page: page)
            #expect(answer.0 == .rejectProtectionSpace && answer.1 == nil)
        }
    }

    /// Zigzag saves and fills no password there, and fills no form from your card, whatever was chosen.
    @Test func noPasswordsOrCard() async throws {
        try await withTabs { theirs, yours in
            Autofill.setOn(true, in: theirs.profile)
            PasswordCapture.setOffersToSave(true, in: theirs.profile)
            #expect(!Autofill.isOn(in: theirs.profile) && !PasswordCapture.offersToSave(in: theirs.profile))
            let card = ContactCard.isOn
            ContactCard.isOn = true
            defer { ContactCard.isOn = card }
            #expect(Autofill.fillsForms(in: yours) && !Autofill.fillsForms(in: theirs))
        }
    }

    /// A passkey needs you there to confirm it: their pages are told there are none, with Apple's entitlement or not,
    /// a password manager on or not. Yours are left alone with the entitlement, as before.
    @Test func noPasskeys() {
        for available in [true, false] {
            for managerOn in [true, false] {
                #expect(Passkeys.isShimmed(available: available, isPrivate: false, forAIApps: true, managerOn: managerOn))
            }
        }
        #expect(!Passkeys.isShimmed(available: true, isPrivate: false, forAIApps: false, managerOn: false))
        #expect(!Passkeys.isShimmed(available: false, isPrivate: false, forAIApps: false, managerOn: true))
        #expect(Passkeys.isShimmed(available: false, isPrivate: false, forAIApps: false, managerOn: false))
        #expect(Passkeys.isShimmed(available: false, isPrivate: true, forAIApps: false, managerOn: true))
    }

    /// What you allowed a site (notifications here, as the camera and location are kept alike) isn't given to it
    /// there: it's asked, and with no one there to answer, refused.
    @Test func noPermissionsYouGave() async throws {
        let suite = "zigzag-nothing-of-yours-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: suite)
        }
        try await withTabs { theirs, yours in
            let origin = "https://news.example"
            SitePermissions.remember("allow", subject: PermissionSubject.notifications, origin: origin)
            #expect(await SitePermissions.requestNotifications(origin: origin, window: nil, isPrivate: false, tab: yours) == true)
            #expect(SitePermissions.notifications(origin: origin, tab: theirs) == nil)
            // Notifications from their pages would land on your screen: never shown there, as in a private window.
            #expect(!WebNotifications.alwaysDenies(yours) && WebNotifications.alwaysDenies(theirs))
            yours.load(URL(string: origin)!)
            theirs.load(URL(string: origin)!)
            #expect(yours.notifiesUser && !theirs.notifiesUser)
        }
    }

    /// Your download and link rules (hand a file to an app, run a script, open it when done) never act on theirs.
    @Test func noRulesOfYours() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-rules-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = DownloadRulesStore(file: file)
        var script = DownloadRule(name: "Zips", applies: .linksAndDownloads, match: .contains, pattern: ".zip",
                                  action: DownloadRuleAction(kind: .runScript))
        script.action.scriptPath = "/usr/bin/true"
        store.add(script)
        store.add(DownloadRule(name: "PDFs", applies: .downloads, match: .contains, pattern: ".pdf", action: DownloadRuleAction(kind: .openFile)))
        let zip = URL(string: "https://files.example/a.zip")!, pdf = URL(string: "https://files.example/a.pdf")!
        try await withTabs { theirs, yours in
            #expect(store.firstHandoffMatch(url: zip, filename: "a.zip", appliesToLinks: false, in: yours.profile)?.id == script.id)
            #expect(store.firstHandoffMatch(url: zip, filename: "a.zip", appliesToLinks: false, in: theirs.profile) == nil)
            #expect(store.destination(for: pdf, filename: "a.pdf", in: yours.profile)?.destination == .open)
            #expect(store.destination(for: pdf, filename: "a.pdf", in: theirs.profile) == nil)
        }
    }

    /// Only theirs isn't given your data; the role and the policy are known without asking the directory again.
    @Test func onlyTheirsIsNotGivenYourData() async throws {
        try await withTabs { theirs, yours in
            #expect(!theirs.profile.getsYourData && yours.profile.getsYourData)
            #expect(Profiles.shared.default.getsYourData)
        }
    }

    /// Your site routes don't send their pages out, whether in their window or with their space open in yours.
    @Test func noRoutesOfYours() async throws {
        try await withTabs { theirs, yours in
            let window = TabManager(spaceID: yours.spaceID)
            defer { window.invalidate() }
            #expect(SiteRoutes.place(from: yours, in: window) == .browser)
            #expect(SiteRoutes.place(from: theirs, in: window) == .withoutYourData)
            // A page typed in with their space in front: the space's profile decides.
            let onTheirs = TabManager(spaceID: theirs.spaceID)
            defer { onTheirs.invalidate() }
            #expect(SiteRoutes.place(from: nil, in: onTheirs) == .withoutYourData)
            #expect(SiteRoutes.place(from: nil, in: window) == .browser)
        }
    }

    /// Your Archive is yours: a tab of theirs gone unseen past the setting stays where it is, and isn't counted
    /// toward the offer to turn archiving on. One of yours is archived, as ever.
    @Test func noPlaceInYourArchive() async throws {
        let key = "ArchiveTabsAfter", before = UserDefaults.standard.string(forKey: key)
        TabArchive.after = .day
        defer { UserDefaults.standard.set(before, forKey: key) }
        try await withTabs { theirs, yours in
            let window = TabManager(spaceID: yours.spaceID)
            defer { window.invalidate() }
            let old = Date().addingTimeInterval(-3 * 24 * 3600)
            var stale: [Tab] = []
            for space in [yours.spaceID, theirs.spaceID] {
                window.newTab(url: URL(string: "https://front.example/\(space)")!, spaceID: space, select: true)
                let tab = window.newTab(url: URL(string: "https://stale.example/\(space)")!, spaceID: space, select: false)
                tab.lastActivated = old
                stale.append(tab)
            }
            window.switchToSpace(yours.spaceID)
            let mine = stale[0], notMine = stale[1]
            let counted = window.archivableTabs.flatMap { $0 }
            #expect(counted.contains { $0 === mine } && !counted.contains { $0 === notMine })
            window.sleepIdleTabs()
            #expect(mine.isClosed && !notMine.isClosed)
            let archived = TabArchive.shared.entries.map(\.url)
            let mineURL = try #require(mine.url), notMineURL = try #require(notMine.url)
            #expect(archived.contains(mineURL) && !archived.contains(notMineURL))
            TabArchive.shared.remove(url: mineURL)
        }
    }

    /// Their tabs start muted, and stay as you set them.
    @Test func theirTabsStartMuted() async throws {
        try await withTabs { theirs, yours in
            #expect(theirs.isMuted && !yours.isMuted)
            theirs.ensureWebView()
            #expect(theirs.isMuted)
            theirs.setMuted(false)
            #expect(!theirs.isMuted)
        }
    }
}
