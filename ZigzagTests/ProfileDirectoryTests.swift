import Foundation
import Testing
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

    @Test func thePasswordManagerIsNamedFromWhatIsInstalled() {
        #expect(PasswordManagers.active(among: []) == nil)
        #expect(PasswordManagers.active(among: ["not-a-password-manager"]) == nil)
        #expect(PasswordManagers.active(among: ["nngceckbapebfimnlniiiahkandclblb"]) == "Bitwarden")
        // Several on: always the same one.
        #expect(PasswordManagers.active(among: ["nngceckbapebfimnlniiiahkandclblb", "aeblfdkhhhdcdjpifhhbdiojplfjncoa"]) == "1Password")
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
