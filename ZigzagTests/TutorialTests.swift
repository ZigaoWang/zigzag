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
        // The + in the bottom corner: a smaller ring, still round and centered on it, inside the window.
        let corner = Tutorial.ringRect(visible: NSRect(x: 770, y: 570, width: 28, height: 28), outset: 5, within: window, margin: 3)
        #expect(corner == NSRect(x: 771, y: 571, width: 26, height: 26))
        // Well inside: the full outset.
        let inside = Tutorial.ringRect(visible: NSRect(x: 100, y: 100, width: 200, height: 30), outset: 5, within: window, margin: 3)
        #expect(inside == NSRect(x: 95, y: 95, width: 210, height: 40))
        // A row hanging past the left edge (a sidebar sliding in) is ringed only where it shows, with no outset
        // past the edge.
        let left = Tutorial.ringRect(visible: NSRect(x: -50, y: 200, width: 200, height: 30), outset: 5, within: window, margin: 3)
        #expect(left == NSRect(x: 3, y: 200, width: 147, height: 30))
        // Every ring it makes is whole inside the window, less the margin.
        for rect in [corner, inside, left].compactMap({ $0 }) {
            #expect(window.insetBy(dx: 3, dy: 3).contains(rect))
        }
    }

    @Test func noKeysNoPressTheseKeys() {
        // A step whose shortcut was taken away in Settings says how to do it without keys.
        for task in Tutorial.tasks where task.keys.isEmpty {
            #expect(!task.note.contains("these keys"), "\(task.id): \(task.note)")
        }
    }

    @Test func lastStepFollowsWhereYouAre() {
        // Made in the sidebar, the new space opens: the step is to go back.
        #expect(Tutorial.switchGoesBack(currentSpaceIndex: 1))
        // Made in Settings, you're still in the first: the step is to go to the new one.
        #expect(!Tutorial.switchGoesBack(currentSpaceIndex: 0))
    }

    @Test func overviewPicturesOnlyUnseenLoadedPages() {
        #expect(Tab.needsPictureOutOfSight(hasWebView: true, onScreen: false, loaded: true, hasPicture: false))
        #expect(!Tab.needsPictureOutOfSight(hasWebView: true, onScreen: true, loaded: true, hasPicture: false))
        #expect(!Tab.needsPictureOutOfSight(hasWebView: true, onScreen: false, loaded: false, hasPicture: false))
        #expect(!Tab.needsPictureOutOfSight(hasWebView: true, onScreen: false, loaded: true, hasPicture: true))
        #expect(!Tab.needsPictureOutOfSight(hasWebView: false, onScreen: false, loaded: true, hasPicture: false))
    }

    @Test func draggedTabStaysInTheWindow() {
        let window = NSRect(x: 0, y: 0, width: 760, height: 560)
        let size = NSSize(width: 228, height: 30)
        let grab = CGPoint(x: 40, y: 15)
        // A narrow window: the middle of the drop is too near the edge for the whole tab.
        let narrow = TourDemo.dragEnd(drop: NSRect(x: 520, y: 0, width: 220, height: 560), grab: grab, size: size, within: window)
        #expect(narrow.x + size.width <= window.maxX)
        // A wide one: right over the middle of the drop.
        let wide = TourDemo.dragEnd(drop: NSRect(x: 400, y: 0, width: 360, height: 560), grab: grab, size: size, within: NSRect(x: 0, y: 0, width: 1400, height: 560))
        #expect(wide.x == CGFloat(540))
    }

    @Test func noRingForWhatYouCantSee() {
        let window = NSRect(x: 0, y: 0, width: 800, height: 600)
        #expect(Tutorial.ringRect(visible: nil, outset: 5, within: window, margin: 3) == nil)
        #expect(Tutorial.ringRect(visible: .zero, outset: 5, within: window, margin: 3) == nil)
        // Scrolled or slid fully out of the window.
        #expect(Tutorial.ringRect(visible: NSRect(x: 900, y: 100, width: 40, height: 20), outset: 5, within: window, margin: 3) == nil)
    }
}
