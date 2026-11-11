import AppKit
import Testing
@testable import Zigzag

/// The getting-started guide: its steps in order, what moves it on, and where its ring may go.
@MainActor @Suite(.serialized)
struct TutorialTests {
    /// Each test keeps the guide's progress in a scratch suite, never the app's own defaults.
    private func withScratchStore(_ body: () -> Void) {
        let name = "TutorialTests.\(UUID().uuidString)"
        let saved = Tutorial.store
        Tutorial.store = UserDefaults(suiteName: name)!
        Tutorial.restart()
        body()
        Tutorial.store.removePersistentDomain(forName: name)
        Tutorial.store = saved
    }

    @Test func stepsComeInOrder() {
        // The overview comes before Split View: its two pages are two cards there, then the pair to put side by side.
        #expect(Tutorial.tasks.map(\.id) == ["newTab", "pin", "peek", "overview", "split", "space", "switch"])
    }

    @Test func onlyTheCurrentStepCounts() {
        withScratchStore {
            #expect(Tutorial.current?.id == "newTab")
            Tutorial.complete("pin")
            #expect(!Tutorial.done.contains("pin"))
            Tutorial.complete("newTab")
            #expect(Tutorial.current?.id == "pin")
        }
    }

    @Test func overviewCountsOnceYouLeaveIt() {
        withScratchStore {
            Tutorial.done = ["newTab", "pin", "peek"]
            #expect(Tutorial.current?.id == "overview")
            // Leaving without having opened it: nothing.
            Tutorial.overviewClosed()
            #expect(Tutorial.current?.id == "overview")
            // Opening it isn't the step yet.
            Tutorial.overviewOpened()
            #expect(Tutorial.current?.id == "overview")
            // Back on a tab: done.
            Tutorial.overviewClosed()
            #expect(Tutorial.current?.id == "split")
        }
    }

    @Test func overviewOpenedEarlyDoesntCountLater() {
        withScratchStore {
            Tutorial.done = ["newTab"]
            // Opened during another step, then that step's done while it's open: leaving it doesn't skip ahead.
            Tutorial.overviewOpened()
            Tutorial.done = ["newTab", "pin", "peek"]
            Tutorial.overviewClosed()
            #expect(Tutorial.current?.id == "overview")
        }
    }

    @Test func aSpaceFromAnywhereCountsAndCanBeTakenBack() {
        withScratchStore {
            Tutorial.done = ["newTab", "pin", "peek", "overview", "split"]
            #expect(Tutorial.current?.id == "space")
            Tutorial.complete("space")
            #expect(Tutorial.current?.id == "switch")
            // Cancelled while naming it: the guide asks again.
            Tutorial.undo("space")
            #expect(Tutorial.current?.id == "space")
        }
    }

    @Test func finishedBeforeNewStepsStaysFinished() {
        withScratchStore {
            Tutorial.done = ["newTab", "pin", "peek", "space"]
            Tutorial.migrate()
            #expect(Tutorial.current == nil)
        }
    }

    @Test func ringStaysInsideTheWindow() {
        let window = NSRect(x: 0, y: 0, width: 800, height: 600)
        // The + in the bottom corner: the ring's outset is cut back at the window's edges.
        let corner = Tutorial.ringRect(visible: NSRect(x: 770, y: 570, width: 28, height: 28), outset: 5, within: window, margin: 3)
        #expect(corner == NSRect(x: 765, y: 565, width: 32, height: 32))
        // Well inside: the full outset.
        let inside = Tutorial.ringRect(visible: NSRect(x: 100, y: 100, width: 200, height: 30), outset: 5, within: window, margin: 3)
        #expect(inside == NSRect(x: 95, y: 95, width: 210, height: 40))
        // A row hanging past the left edge (a sidebar sliding in) is ringed only where it shows.
        let left = Tutorial.ringRect(visible: NSRect(x: -50, y: 200, width: 200, height: 30), outset: 5, within: window, margin: 3)
        #expect(left == NSRect(x: 3, y: 195, width: 152, height: 40))
    }

    @Test func noRingForWhatYouCantSee() {
        let window = NSRect(x: 0, y: 0, width: 800, height: 600)
        #expect(Tutorial.ringRect(visible: nil, outset: 5, within: window, margin: 3) == nil)
        #expect(Tutorial.ringRect(visible: .zero, outset: 5, within: window, margin: 3) == nil)
        // Scrolled or slid fully out of the window.
        #expect(Tutorial.ringRect(visible: NSRect(x: 900, y: 100, width: 40, height: 20), outset: 5, within: window, margin: 3) == nil)
    }
}
