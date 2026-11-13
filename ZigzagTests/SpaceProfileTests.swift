import Foundation
import Testing
@testable import Zigzag

/// A space's profile where spaces are made and edited (#201): New Profile in one step, and the profile's name shown
/// beside a space only once there's more than one profile.
@MainActor
struct SpaceProfileTests {
    private let work = UUID(), play = UUID()

    @Test func aNewProfileForASpaceIsNamedAfterItAndHoldsIt() {
        var directory = ProfileDirectory()
        let made = directory.addOwn(for: work, named: "Work", taken: ["Default"], color: .sage)
        #expect(made.name == "Work" && made.color == .sage)
        #expect(directory.profileID(ofSpace: work) == made.id)
        // Only that space moves: the others stay on the profile they were on.
        #expect(directory.profileID(ofSpace: play) == Profile.defaultID)
        #expect(directory.all.map(\.id) == [Profile.defaultID, made.id])
    }

    @Test func twoProfilesNeverReadAlike() {
        #expect(ProfileDirectory.freshName("Work", taken: ["Default"]) == "Work")
        #expect(ProfileDirectory.freshName("Work", taken: ["Default", "work"]) == "Work 2")
        #expect(ProfileDirectory.freshName("Work", taken: ["Work", "Work 2"]) == "Work 3")
        #expect(ProfileDirectory.freshName("  Work ", taken: []) == "Work")
        var directory = ProfileDirectory()
        let first = directory.addOwn(for: work, named: "Work", taken: ["Default"])
        let second = directory.addOwn(for: play, named: "Work", taken: directory.all.map(\.displayName))
        #expect(first.name == "Work" && second.name == "Work 2")
    }

    @Test func withOneProfileNothingNamesIt() {
        var directory = ProfileDirectory()
        #expect(directory.shownName(ofSpace: work) == nil)
        let made = directory.addOwn(for: work, named: "Work", taken: ["Default"])
        // Once there are two, every space says which it's on, the first profile's spaces too.
        #expect(directory.shownName(ofSpace: work) == "Work")
        #expect(directory.shownName(ofSpace: play) == directory.all[0].displayName)
        _ = directory.remove(made.id)
        #expect(directory.shownName(ofSpace: work) == nil)
    }

    @Test func theEditorSaysWhatAProfileKeepsApart() {
        // One line under the Profile row, whatever the profiles: with one, it's the only place that says so.
        #expect(!ProfileChoice.spaceNote.isEmpty)
        // New Profile asks nothing more, so no ellipsis.
        #expect(!ProfileChoice.newForSpace.hasSuffix("…"))
    }
}
