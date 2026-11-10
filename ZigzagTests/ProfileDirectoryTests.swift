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
