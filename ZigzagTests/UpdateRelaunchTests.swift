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

/// An update relaunch brings back exactly what was open, whatever On launch says; it's not a fresh start (#433).
@MainActor
struct RelaunchIgnoresLaunchChoiceTests {
    @Test func anUpdateRelaunchResumesEvenWithStartFresh() throws {
        let suite = "ZigzagRelaunchChoiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let shared = LaunchChoice.defaults
        LaunchChoice.defaults = defaults
        defer {
            LaunchChoice.defaults = shared
            defaults.removePersistentDomain(forName: suite)
        }
        LaunchChoice.choice = .fresh
        let now = Date()
        let saved = UpdateRelaunch.Saved(at: now, browserWindowsOpen: true, minis: [])
        let plan = UpdateRelaunch.plan(relaunch: saved, now: now, needsOnboarding: false, miniOnly: false, webAppOnly: false)
        #expect(plan.restoresSession)
        // The launch's own rule: a relaunch keeps the session, so the setting doesn't turn it into a fresh start.
        #expect(UpdateRelaunch.resumes(plan: plan, relaunch: saved, choice: .fresh))
        #expect(!UpdateRelaunch.resumes(plan: UpdateRelaunch.plan(relaunch: nil, now: now, needsOnboarding: false,
                                                                  miniOnly: false, webAppOnly: false),
                                        relaunch: nil, choice: .fresh))
    }
}

/// A fresh start keeps the session it passed over where saving the new one can't reach it, and the copy is made
/// once per run, from the session that launch found (#433).
@MainActor
struct LastSessionKeptTests {
    @Test func aFreshStartKeepsTheSessionItPassedOver() throws {
        let manager = WindowManager.shared
        let saved = Paths.session, kept = Paths.previousSession
        let oldSession = try? Data(contentsOf: saved), oldKept = try? Data(contentsOf: kept)
        defer {
            try? FileManager.default.removeItem(at: kept)
            if let oldSession { try? oldSession.write(to: saved) } else { try? FileManager.default.removeItem(at: saved) }
            if let oldKept { try? oldKept.write(to: kept) }
        }
        try? FileManager.default.removeItem(at: kept)
        // Nothing saved: nothing to keep, and nothing to reopen.
        #expect(!manager.canReopenLastSession)
        let space = Library.shared.spaces[0].id
        let tab = SessionState.TabState(id: UUID(), url: URL(string: "https://kept.example"), title: "Kept",
                                        lastActivated: Date(), createdAt: Date())
        let state = SessionState(windows: [SessionState.WindowState(
            frame: [], sidebarVisible: true, sidebarWidth: 240, currentSpaceID: space,
            spaces: [SessionState.SpaceTabs(spaceID: space, tabs: [tab], selectedTabID: tab.id)],
            bookmarkTabs: [])])
        guard JSONStore.save(state, to: saved) else { return }
        manager.keepSessionForReopening()
        // The copy is the session that was there, byte for byte.
        #expect(try Data(contentsOf: kept) == (try Data(contentsOf: saved)))
        #expect(manager.canReopenLastSession)
    }
}

/// Settings › General › On launch (#433): reopening by default, and remembering the choice.
@MainActor
struct LaunchChoiceTests {
    @Test func launchesReopenTheSessionUnlessToldOtherwise() throws {
        let suite = "ZigzagLaunchChoiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let shared = LaunchChoice.defaults
        LaunchChoice.defaults = defaults
        defer {
            LaunchChoice.defaults = shared
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(LaunchChoice.choice == .resume)
        LaunchChoice.choice = .fresh
        #expect(LaunchChoice.choice == .fresh)
        // Nothing written, or written by something else: back to reopening.
        defaults.set("nonsense", forKey: LaunchChoice.key)
        #expect(LaunchChoice.choice == .resume)
    }
}
