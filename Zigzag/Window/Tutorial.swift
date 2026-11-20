import AppKit

/// Getting started: seven things to do once, in order, each building on the last, on real pages. The guide in the window
/// (GuidedTour) shows them one at a time; each ticks off when you actually do it.
enum Tutorial {
    struct Task {
        let id: String
        let title: String
        let keys: [String]
        /// Why it's worth doing, in one short line under the title.
        let note: String
        /// Said for a moment once it's done, pointing at what changed, so you see what happened.
        let done: String
        /// What to do with it next, under that.
        let doneNote: String
    }

    /// Each step is the keys, a few words, and one short line on why: a glance, nothing to read. Made fresh each time,
    /// so the keys are the ones set in Settings › Shortcuts now.
    static var tasks: [Task] {
        let newTabKeys = Shortcuts.caps(for: #selector(BrowserWindowController.newTab(_:)))
        let pinKeys = Shortcuts.caps(for: #selector(BrowserWindowController.toggleBookmark(_:)))
        let overviewKeys = Shortcuts.caps(for: #selector(BrowserWindowController.toggleDeskView(_:)))
        let separateKeys = Shortcuts.keys(for: #selector(BrowserWindowController.closeSplitView(_:)))
        let newSpaceKeys = Shortcuts.caps(for: #selector(BrowserWindowController.newSpace(_:)))
        let previousSpaceKeys = Shortcuts.keys(for: #selector(BrowserWindowController.previousSpace(_:)))
        let nextSpaceKeys = Shortcuts.keys(for: #selector(BrowserWindowController.nextSpace(_:)))
        return [
            Task(id: "newTab",
                 title: String(localized: "Open a new tab", comment: "A step's title in the getting-started guide, a card in the window."),
                 keys: newTabKeys,
                 note: newTabKeys.isEmpty
                    ? String(localized: "Click New Tab in the sidebar, then search YouTube", comment: "Under the new tab step's title in the getting-started guide, a card in the window, when New Tab has no shortcut. New Tab is a row in the sidebar.")
                    : String(localized: "Press these keys, then search YouTube", comment: "Under a step's title in the getting-started guide, a card in the window."),
                 done: String(localized: "You searched YouTube from here", comment: "Said once a step is done in the getting-started guide, a card in the window."),
                 doneNote: String(localized: "Type any site’s name, then Tab, to search it", comment: "Under what's said once a step is done, in the getting-started guide, a card in the window. Tab is the key.")),
            Task(id: "pin",
                 title: String(localized: "Pin this page", comment: "A step's title in the getting-started guide, a card in the window."),
                 keys: pinKeys,
                 note: pinKeys.isEmpty
                    ? String(localized: "Right-click its tab, then Pin Tab", comment: "Under the pin step's title in the getting-started guide, a card in the window, when Pin Tab has no shortcut. Pin Tab is an item in a tab's menu in the sidebar.")
                    : String(localized: "Pinned tabs stay, even after you quit", comment: "Under a step's title in the getting-started guide, a card in the window."),
                 done: String(localized: "Pinned", comment: "Said once a step is done in the getting-started guide, a card in the window."),
                 doneNote: String(localized: "It stays at the top of this space", comment: "Under what's said once a step is done, in the getting-started guide, a card in the window.")),
            Task(id: "peek",
                 title: String(localized: "Shift-click a blue link", comment: "A step's title in the getting-started guide, a card in the window."),
                 keys: ["⇧", String(localized: "Click", comment: "A key in the getting-started guide, after ⇧: click with the mouse or trackpad.")],
                 note: String(localized: "Here’s an article to try it on", comment: "Under a step's title in the getting-started guide, a card in the window."),
                 done: String(localized: "That’s Peek", comment: "Said once a step is done in the getting-started guide, a card in the window."),
                 doneNote: String(localized: "A quick look, without losing your place", comment: "Under what's said once a step is done, in the getting-started guide, a card in the window. Peek is a Zigzag feature's name.")),
            Task(id: "overview",
                 title: String(localized: "See all your tabs", comment: "A step's title in the getting-started guide, a card in the window."),
                 keys: overviewKeys,
                 note: overviewKeys.isEmpty
                    ? String(localized: "Choose View › Show All Tabs", comment: "Under the tab overview step's title in the getting-started guide, a card in the window, when Show All Tabs has no shortcut. View is the menu, Show All Tabs its item.")
                    : String(localized: "Press these keys to see every tab at once", comment: "Under the tab overview step's title in the getting-started guide, a card in the window."),
                 done: String(localized: "Every tab, at a glance", comment: "Said once a step is done in the getting-started guide, a card in the window."),
                 doneNote: overviewKeys.isEmpty
                    ? String(localized: "It’s Show All Tabs, in the View menu", comment: "Under what's said once the tab overview step is done, in the getting-started guide, a card in the window.")
                    : String(localized: "Press \(overviewKeys.joined()) anytime to find a tab", comment: "Under what's said once the tab overview step is done, in the getting-started guide, a card in the window. The keys are a shortcut, like ⇧⌘\\.")),
            Task(id: "split",
                 title: String(localized: "Drag a tab onto the page", comment: "A step's title in the getting-started guide, a card in the window."),
                 keys: [],
                 note: String(localized: "Two pages, side by side", comment: "Under a step's title in the getting-started guide, a card in the window."),
                 done: String(localized: "That’s Split View", comment: "Said once a step is done in the getting-started guide, a card in the window."),
                 doneNote: separateKeys.isEmpty
                    ? String(localized: "To separate them, use the buttons above either page", comment: "Under what's said once the split view step is done, in the getting-started guide, a card in the window.")
                    : String(localized: "To separate them, press \(separateKeys)", comment: "Under what's said once the split view step is done, in the getting-started guide, a card in the window. The keys are a shortcut, like ⌥⌘\\.")),
            Task(id: "space",
                 title: String(localized: "Make a space", comment: "A step's title in the getting-started guide, a card in the window."),
                 keys: newSpaceKeys,
                 note: newSpaceKeys.isEmpty
                    ? String(localized: "Click + in the sidebar, then New Space", comment: "Under the new space step's title in the getting-started guide, a card in the window. New Space is an item in the menu of the sidebar's +.")
                    : String(localized: "Or click + in the sidebar, then New Space", comment: "Under the new space step's title in the getting-started guide, a card in the window, after the keys that make a space. New Space is an item in the menu of the sidebar's +."),
                 done: String(localized: "Your new space", comment: "Said once a step is done in the getting-started guide, a card in the window."),
                 doneNote: String(localized: "Its own tabs and pinned tabs, in its own color", comment: "Under what's said once a step is done, in the getting-started guide, a card in the window.")),
            Task(id: "switch",
                 title: String(localized: "Go back to your first space", comment: "A step's title in the getting-started guide, a card in the window."),
                 keys: [],
                 note: String(localized: "Swipe two fingers across the sidebar, or click its dot", comment: "Under a step's title in the getting-started guide, a card in the window."),
                 done: String(localized: "That’s switching spaces", comment: "Said once a step is done in the getting-started guide, a card in the window."),
                 doneNote: previousSpaceKeys.isEmpty || nextSpaceKeys.isEmpty
                    ? String(localized: "Swipe or click a dot anytime", comment: "Under what's said once the switching spaces step is done, in the getting-started guide, a card in the window.")
                    : String(localized: "Swipe or click a dot anytime, or press \(previousSpaceKeys) and \(nextSpaceKeys)", comment: "Under what's said once the switching spaces step is done, in the getting-started guide, a card in the window. The keys are shortcuts, like ⌥⌘← and ⌥⌘→.")),
        ]
    }

    /// The step that was just skipped, so the guide moves on without saying it was done.
    @MainActor static var skipped: String?

    /// Where it's kept: the app's defaults, or a scratch suite in tests.
    static var store: UserDefaults = .standard

    private static let key = "TutorialDone"
    static var done: Set<String> {
        get {
            var done = Set(store.stringArray(forKey: key) ?? [])
            // Finished before Split View or the overview were steps: it doesn't come back to teach just those.
            if done.contains("space") { done.formUnion(["split", "overview"]) }
            return done
        }
        set { store.set(Array(newValue), forKey: key) }
    }

    /// Finished the guide before "go back to your first space" was a step: once, on the first launch of the version
    /// that added it, that step counts as done too, so the guide doesn't come back to teach just that.
    static func migrate() {
        let flag = "TutorialSwitchStepAdded"
        guard !store.bool(forKey: flag) else { return }
        store.set(true, forKey: flag)
        if done.contains("space") { done.insert("switch") }
    }

    /// The step to do now: the first in order that isn't done.
    static var current: Task? { tasks.first { !done.contains($0.id) } }

    /// Ended with the guide's ×; Help › Getting Started starts it again.
    static var isHidden: Bool {
        get { store.bool(forKey: "TutorialHidden") }
        set { store.set(newValue, forKey: "TutorialHidden") }
    }

    /// Sent when a step is done or skipped.
    @MainActor static let changed = Signal<Void>()

    /// You did one. Only the step you're on counts, so doing step 3 early doesn't jump the guide ahead.
    @MainActor static func complete(_ id: String) {
        guard current?.id == id else { return }
        done.insert(id)
        changed.send(())
    }

    /// Takes back a step that was just done (a new space, cancelled while naming it), if it's the last one done.
    @MainActor static func undo(_ id: String) {
        guard done.contains(id), let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        // Only while the guide is on the step right after it (or finished just by it).
        let next = index + 1 < tasks.count ? tasks[index + 1].id : nil
        guard current?.id == next else { return }
        done.remove(id)
        changed.send(())
    }

    /// The overview opened while it's the step. It counts once you leave it again, by a card, Esc or the keys, so
    /// the step is seeing it and getting back, not just opening it.
    @MainActor private(set) static var inOverview = false

    @MainActor static func overviewOpened() {
        inOverview = current?.id == "overview"
    }

    @MainActor static func overviewClosed() {
        guard inOverview else { return }
        inOverview = false
        complete("overview")
    }

    @MainActor static func skip() {
        guard let current else { return }
        skipped = current.id
        done.insert(current.id)
        changed.send(())
    }

    /// Help › Getting Started: from the top.
    @MainActor static func restart() {
        done = []
        isHidden = false
        inOverview = false
    }

    /// Where the ring around what to click goes: the part of it you can see (`visible`, nil when it's off screen or
    /// scrolled away), grown by `outset`, and kept `margin` inside `bounds` (the window), so the ring never runs off
    /// an edge. Nil when too little of it shows to point at.
    static func ringRect(visible: NSRect?, outset: CGFloat, within bounds: NSRect, margin: CGFloat, roundBelow: CGFloat = 44) -> NSRect? {
        guard let visible, visible.width >= 4, visible.height >= 4 else { return nil }
        let area = bounds.insetBy(dx: margin, dy: margin)
        // Something small at an edge (the + in the bottom corner): a smaller ring, still whole and centered on it,
        // rather than one cut flat by the edge.
        if max(visible.width, visible.height) < roundBelow {
            let center = CGPoint(x: visible.midX, y: visible.midY)
            guard area.contains(center) else { return nil }
            let room = min(center.x - area.minX, area.maxX - center.x, center.y - area.minY, area.maxY - center.y)
            let halfWidth = min(visible.width / 2 + outset, room), halfHeight = min(visible.height / 2 + outset, room)
            guard halfWidth >= 2, halfHeight >= 2 else { return nil }
            return NSRect(x: center.x - halfWidth, y: center.y - halfHeight, width: halfWidth * 2, height: halfHeight * 2)
        }
        // Anything bigger: only the part that shows, grown alike on every side as far as there's room.
        let seen = visible.intersection(area)
        guard !seen.isNull, seen.width >= 4, seen.height >= 4 else { return nil }
        let room = min(seen.minX - area.minX, area.maxX - seen.maxX, seen.minY - area.minY, area.maxY - seen.maxY)
        let grow = max(0, min(outset, room))
        return seen.insetBy(dx: -grow, dy: -grow)
    }

    /// The last step, said for where you are: in the space you started in (the new one was made in Settings, or
    /// you've gone back already), it's to go to the new one; anywhere else, back to the first.
    static func switchGoesBack(currentSpaceIndex: Int) -> Bool { currentSpaceIndex != 0 }
}
