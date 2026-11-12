import Foundation
import Testing
@testable import Zigzag

/// An update's restart brings back exactly what was open, whatever a plain launch would have chosen.
struct UpdateRelaunchTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func mini(_ url: String = "https://example.com/") -> UpdateRelaunch.Mini {
        UpdateRelaunch.Mini(url: URL(string: url)!, title: "Example", spaceID: UUID(), frame: [100, 100, 500, 600],
                            keepOnTop: true, interactionState: Data([1, 2, 3]))
    }

    private func saved(browsers: Bool, minis: [UpdateRelaunch.Mini], ago: TimeInterval = 5) -> UpdateRelaunch.Saved {
        UpdateRelaunch.Saved(at: now.addingTimeInterval(-ago), browserWindowsOpen: browsers, minis: minis)
    }

    @Test func aPlainLaunchRestoresTheSession() {
        let plan = UpdateRelaunch.plan(relaunch: nil, now: now, needsOnboarding: false, miniOnly: false, webAppOnly: false)
        #expect(plan == .init(restoresSession: true, sessionWaiting: false, restoresMinis: false))
    }

    @Test func aPlainLaunchForZigzagMiniOrAnAppLeavesTheWindowsWaiting() {
        #expect(UpdateRelaunch.plan(relaunch: nil, now: now, needsOnboarding: false, miniOnly: true, webAppOnly: false)
            == .init(restoresSession: false, sessionWaiting: true, restoresMinis: false))
        #expect(UpdateRelaunch.plan(relaunch: nil, now: now, needsOnboarding: false, miniOnly: false, webAppOnly: true)
            == .init(restoresSession: false, sessionWaiting: true, restoresMinis: false))
        #expect(UpdateRelaunch.plan(relaunch: nil, now: now, needsOnboarding: true, miniOnly: false, webAppOnly: false).restoresSession == false)
    }

    @Test func anUpdateRestartBringsBackWindowsAndMinis() {
        let plan = UpdateRelaunch.plan(relaunch: saved(browsers: true, minis: [mini()]), now: now, needsOnboarding: false, miniOnly: false, webAppOnly: false)
        #expect(plan == .init(restoresSession: true, sessionWaiting: false, restoresMinis: true))
    }

    @Test func anUpdateRestartRestoresTheSessionWhateverElseWouldDecide() {
        // Onboarding not marked done, or a link for Zigzag Mini arriving with the launch: the windows still come back.
        for (onboarding, miniOnly, webAppOnly) in [(true, false, false), (false, true, false), (false, false, true)] {
            let plan = UpdateRelaunch.plan(relaunch: saved(browsers: true, minis: []), now: now,
                                           needsOnboarding: onboarding, miniOnly: miniOnly, webAppOnly: webAppOnly)
            #expect(plan == .init(restoresSession: true, sessionWaiting: false, restoresMinis: false))
        }
    }

    @Test func onlyZigzagMiniOpenBringsBackOnlyZigzagMini() {
        let plan = UpdateRelaunch.plan(relaunch: saved(browsers: false, minis: [mini(), mini("https://example.org/")]), now: now,
                                       needsOnboarding: false, miniOnly: false, webAppOnly: false)
        #expect(plan == .init(restoresSession: false, sessionWaiting: true, restoresMinis: true))
    }

    @Test func nothingOpenRestoresTheSessionAsAnyLaunch() {
        let plan = UpdateRelaunch.plan(relaunch: saved(browsers: false, minis: []), now: now, needsOnboarding: false, miniOnly: false, webAppOnly: false)
        #expect(plan == .init(restoresSession: true, sessionWaiting: false, restoresMinis: false))
    }

    @Test func anOldNoteIsNotThisRestart() {
        let plan = UpdateRelaunch.plan(relaunch: saved(browsers: false, minis: [mini()], ago: UpdateRelaunch.freshFor + 1), now: now,
                                       needsOnboarding: false, miniOnly: true, webAppOnly: false)
        #expect(plan == .init(restoresSession: false, sessionWaiting: true, restoresMinis: false))
    }

    @Test func theNoteIsReadOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateRelaunch-\(UUID().uuidString).json")
        let note = saved(browsers: true, minis: [mini()])
        UpdateRelaunch.write(note, to: url)
        #expect(UpdateRelaunch.take(from: url) == note)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(UpdateRelaunch.take(from: url) == nil)
    }
}
