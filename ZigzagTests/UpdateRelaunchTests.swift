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
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ZigzagLastSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func session(tabIDs: [UUID], space: UUID) -> SessionState {
        SessionState(windows: [SessionState.WindowState(
            frame: [], sidebarVisible: true, sidebarWidth: 240, currentSpaceID: space,
            spaces: [SessionState.SpaceTabs(spaceID: space, tabs: tabIDs.map { id in
                SessionState.TabState(id: id, url: URL(string: "https://kept.example/\(id)"), title: "Kept",
                                      lastActivated: Date(), createdAt: Date())
            }, selectedTabID: tabIDs.first)],
            bookmarkTabs: [])])
    }

    @Test func aFreshStartKeepsTheSessionItPassedOver() throws {
        let manager = WindowManager.shared
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = root.appendingPathComponent("Session.json")
        let kept = root.appendingPathComponent("SessionBeforeFreshStart.json")
        let tabStates = root.appendingPathComponent("TabState", isDirectory: true)
        let keptTabStates = root.appendingPathComponent("TabStateBeforeFreshStart", isDirectory: true)
        try FileManager.default.createDirectory(at: tabStates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keptTabStates, withIntermediateDirectories: true)
        manager.forgetKeptSessionForTesting()
        // Nothing saved: nothing to keep, and nothing to reopen.
        #expect(!manager.hasSessionToReopen(at: kept))
        let space = Library.shared.spaces[0].id
        let state = session(tabIDs: [UUID()], space: space)
        guard JSONStore.save(state, to: saved) else { return }
        manager.keepSessionForReopening(session: saved, kept: kept, tabStates: tabStates, keptTabStates: keptTabStates)
        // The copy is the session that was there, byte for byte.
        #expect(try Data(contentsOf: kept) == (try Data(contentsOf: saved)))
        #expect(manager.hasSessionToReopen(at: kept))
    }

    @Test func anEmptySessionNeverReplacesTheKeptOne() throws {
        let manager = WindowManager.shared
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = root.appendingPathComponent("Session.json")
        let kept = root.appendingPathComponent("SessionBeforeFreshStart.json")
        let tabStates = root.appendingPathComponent("TabState", isDirectory: true)
        let keptTabStates = root.appendingPathComponent("TabStateBeforeFreshStart", isDirectory: true)
        try FileManager.default.createDirectory(at: tabStates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keptTabStates, withIntermediateDirectories: true)
        let space = Library.shared.spaces[0].id
        let good = session(tabIDs: [UUID()], space: space)
        let empty = session(tabIDs: [], space: space)
        guard JSONStore.save(good, to: kept), JSONStore.save(empty, to: saved) else { return }
        manager.forgetKeptSessionForTesting()
        manager.keepSessionForReopening(session: saved, kept: kept, tabStates: tabStates, keptTabStates: keptTabStates)
        #expect(try JSONStore.load(SessionState.self, from: kept)?.windows.first?.spaces.first?.tabs.count == 1)
        #expect(manager.hasSessionToReopen(at: kept))
    }

    @Test func theKeptSessionKeepsItsBackAndForwardFiles() throws {
        let manager = WindowManager.shared
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = root.appendingPathComponent("Session.json")
        let kept = root.appendingPathComponent("SessionBeforeFreshStart.json")
        let tabStates = root.appendingPathComponent("TabState", isDirectory: true)
        let keptTabStates = root.appendingPathComponent("TabStateBeforeFreshStart", isDirectory: true)
        try FileManager.default.createDirectory(at: tabStates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keptTabStates, withIntermediateDirectories: true)
        let id = UUID()
        let history = Data([9, 8, 7])
        try history.write(to: tabStates.appendingPathComponent(id.uuidString))
        let state = session(tabIDs: [id], space: Library.shared.spaces[0].id)
        guard JSONStore.save(state, to: saved) else { return }
        manager.forgetKeptSessionForTesting()
        manager.keepSessionForReopening(session: saved, kept: kept, tabStates: tabStates, keptTabStates: keptTabStates)
        #expect(try Data(contentsOf: keptTabStates.appendingPathComponent(id.uuidString)) == history)
        // The fresh session's save removes the old tab's file; reopening puts the kept one back.
        try FileManager.default.removeItem(at: tabStates.appendingPathComponent(id.uuidString))
        WindowManager.restoreKeptTabStates(of: state, from: keptTabStates, to: tabStates)
        #expect(try Data(contentsOf: tabStates.appendingPathComponent(id.uuidString)) == history)
    }

    @Test func reopeningKeepsALiveTabsCurrentHistory() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let tabStates = root.appendingPathComponent("TabState", isDirectory: true)
        let keptTabStates = root.appendingPathComponent("TabStateBeforeFreshStart", isDirectory: true)
        try FileManager.default.createDirectory(at: tabStates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keptTabStates, withIntermediateDirectories: true)
        let id = UUID()
        let live = Data([4, 5, 6])
        try Data([1, 2, 3]).write(to: keptTabStates.appendingPathComponent(id.uuidString))
        try live.write(to: tabStates.appendingPathComponent(id.uuidString))
        let state = session(tabIDs: [id], space: Library.shared.spaces[0].id)
        WindowManager.restoreKeptTabStates(of: state, from: keptTabStates, to: tabStates)
        #expect(try Data(contentsOf: tabStates.appendingPathComponent(id.uuidString)) == live)
    }

    @Test func aKeptSessionWithNoTabsIsNotReopenable() throws {
        let manager = WindowManager.shared
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("SessionBeforeFreshStart.json")
        let space = Library.shared.spaces[0].id
        guard JSONStore.save(session(tabIDs: [], space: space), to: kept) else { return }
        #expect(!manager.hasSessionToReopen(at: kept))
    }
}

/// Reopen Last Session brings back only the kept windows not open again, never a tab that's already open (#433).
@MainActor
struct ReopenLastSessionTests {
    private let space = UUID()

    private func window(_ ids: [UUID]) -> SessionState.WindowState {
        SessionState.WindowState(
            frame: [], sidebarVisible: true, sidebarWidth: 240, currentSpaceID: space,
            spaces: [SessionState.SpaceTabs(spaceID: space, tabs: ids.map { id in
                SessionState.TabState(id: id, url: URL(string: "https://kept.example/\(id)"), title: "Kept",
                                      lastActivated: Date(), createdAt: Date())
            }, selectedTabID: ids.first)],
            bookmarkTabs: [])
    }

    private func tabIDs(_ windows: [SessionState.WindowState]) -> [UUID] { windows.flatMap { $0.spaces.flatMap { $0.tabs.map(\.id) } } }

    @Test func sharedTabsWindowsAreBackWithTheWindowHoldingTheTabs() {
        let a = UUID(), b = UUID()
        let saved = SessionState(windows: [window([a, b]), window([]), window([])])
        #expect(WindowManager.windowsToReopen(saved, open: [], shares: true).count == 3)
        #expect(WindowManager.windowsToReopen(saved, open: [a], shares: true).isEmpty)
    }

    @Test func onlyWindowsNotOpenAgainComeBack() {
        let a = UUID(), b = UUID(), c = UUID()
        let saved = SessionState(windows: [window([a]), window([b, c])])
        #expect(WindowManager.windowsToReopen(saved, open: [], shares: false).count == 2)
        // One reopened window closed again: only it comes back, the open one isn't made twice.
        let again = WindowManager.windowsToReopen(saved, open: [b, c], shares: false)
        #expect(tabIDs(again) == [a])
        #expect(WindowManager.windowsToReopen(saved, open: [a, b], shares: false).isEmpty)
    }

    @Test func aSessionWithNoTabsHasNothingToReopen() {
        let saved = SessionState(windows: [window([]), window([])])
        #expect(WindowManager.windowsToReopen(saved, open: [], shares: true).isEmpty)
        #expect(WindowManager.windowsToReopen(saved, open: [], shares: false).isEmpty)
    }
}

/// What makes a fresh start count as used (#433): only a page in a browser window, never a private window, Zigzag
/// Mini, or one of Zigzag's own pages such as Settings.
@MainActor
struct SessionUseTests {
    @Test func onlyABrowserPageCountsAsBrowsing() {
        let page = URL(string: "https://example.com/")!
        #expect(Tab.countsAsBrowsingForSession(isPrivate: false, isInBrowserWindow: true, url: page))
        #expect(!Tab.countsAsBrowsingForSession(isPrivate: true, isInBrowserWindow: true, url: page))
        #expect(!Tab.countsAsBrowsingForSession(isPrivate: false, isInBrowserWindow: false, url: page))
        #expect(!Tab.countsAsBrowsingForSession(isPrivate: false, isInBrowserWindow: true, url: URL(string: "zigzag://settings")!))
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
