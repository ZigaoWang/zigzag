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
        #expect(directory.shownName(among: [work, play], ofSpace: work, spaceName: "Office") == nil)
        let made = directory.addOwn(for: work, named: "Work", taken: ["Default"])
        // Once there are two, every space says which it's on, the first profile's spaces too.
        #expect(directory.shownName(among: [work, play], ofSpace: work, spaceName: "Office") == "Work")
        #expect(directory.shownName(among: [work, play], ofSpace: play, spaceName: "Play") == directory.all[0].displayName)
        _ = directory.remove(made.id)
        #expect(directory.shownName(among: [work, play], ofSpace: work, spaceName: "Office") == nil)
    }

    /// A profile no space is on any more (its space was deleted) says nothing: names show only while the spaces
    /// there are use more than one profile (#578).
    @Test func aProfileNoSpaceIsOnNamesNothing() {
        var directory = ProfileDirectory()
        directory.addOwn(for: work, named: "Work", taken: ["Default"])
        #expect(directory.shownName(among: [work, play], ofSpace: play, spaceName: "Play") == directory.all[0].displayName)
        // The Work space deleted: Default is the only profile in use, so nothing names it.
        #expect(directory.all.count == 2)
        #expect(directory.shownName(among: [play], ofSpace: play, spaceName: "Play") == nil)
    }

    @Test func aProfileCalledWhatItsSpaceIsIsntNamedTwice() {
        var directory = ProfileDirectory()
        directory.addOwn(for: work, named: "Work", taken: ["Default"])
        #expect(directory.shownName(among: [work, play], ofSpace: work, spaceName: "Work") == nil)
        // Case and spaces at the ends don't make it another name.
        #expect(directory.shownName(among: [work, play], ofSpace: work, spaceName: " work ") == nil)
        #expect(directory.shownName(among: [work, play], ofSpace: work, spaceName: "Work 2") == "Work")
        // The other spaces still say theirs.
        #expect(directory.shownName(among: [work, play], ofSpace: play, spaceName: "Play") == directory.all[0].displayName)
    }

    /// Give new spaces their own profile (#291): a new space gets a profile with its name and color; off, it stays on the current profile.
    @Test func aNewSpaceCanComeWithItsOwnProfile() {
        var directory = ProfileDirectory()
        let other = directory.add(name: "Other", color: .rose)
        let space = SpaceInfo(name: "Work", color: .sage)
        let made = directory.place(newSpace: space, on: other.id, ownProfile: true, usedColors: [.sky, .rose])
        #expect(made?.name == "Work" && made?.color == .sage)
        #expect(directory.profileID(ofSpace: space.id) == made?.id)
        #expect(directory.all.count == 3)

        let plain = SpaceInfo(name: "Play", color: .sky)
        #expect(directory.place(newSpace: plain, on: other.id, ownProfile: false, usedColors: []) == nil)
        #expect(directory.profileID(ofSpace: plain.id) == other.id)
        #expect(directory.all.count == 3)
    }

    @Test func aNewSpacesProfileTakesAFreeName() {
        var directory = ProfileDirectory()
        directory.add(name: "Work")
        let first = directory.place(newSpace: SpaceInfo(name: "work", color: .sky), on: Profile.defaultID, ownProfile: true, usedColors: [])
        let second = directory.place(newSpace: SpaceInfo(name: "Work", color: .sky), on: Profile.defaultID, ownProfile: true, usedColors: [])
        #expect(first?.name == "work 2" && second?.name == "Work 3")
        // The first profile's name (Default until renamed) counts as taken too.
        let named = directory.place(newSpace: SpaceInfo(name: directory.all[0].displayName, color: .sky), on: Profile.defaultID,
                                    ownProfile: true, usedColors: [])
        #expect(named?.name == directory.all[0].displayName + " 2")
    }

    @Test func aNewSpacesProfileTakesAColorNoProfileHas() {
        // The space's color unless taken or gray/white/black; then the next free one.
        #expect(ProfileDirectory.ownColor(for: .sage, used: [.sky]) == .sage)
        let taken = ProfileDirectory.ownColor(for: .sky, used: [.sky])
        #expect(taken != .sky && !taken.isNeutral)
        #expect(!ProfileDirectory.ownColor(for: .graphite, used: [.sky]).isNeutral)
    }

    @Test func theEditorSaysWhatAProfileKeepsApart() {
        // One line under the Profile row, whatever the profiles: with one, it's the only place that says so.
        #expect(!ProfileChoice.spaceNote.isEmpty)
        // New Profile asks nothing more, so no ellipsis.
        #expect(!ProfileChoice.newForSpace.hasSuffix("…"))
    }
}
