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

    /// Each step is the keys, a few words, and one short line on why: a glance, nothing to read.
    static let tasks: [Task] = [
        Task(id: "newTab",
             title: String(localized: "Open a new tab", comment: "A step's title in the getting-started guide, a card in the window."),
             keys: ["⌘", "T"],
             note: String(localized: "Press these keys, then search YouTube", comment: "Under a step's title in the getting-started guide, a card in the window."),
             done: String(localized: "You searched YouTube from here", comment: "Said once a step is done in the getting-started guide, a card in the window."),
             doneNote: String(localized: "Type any site’s name, then Tab, to search it", comment: "Under what's said once a step is done, in the getting-started guide, a card in the window. Tab is the key.")),
        Task(id: "pin",
             title: String(localized: "Pin this page", comment: "A step's title in the getting-started guide, a card in the window."),
             keys: ["⌘", "D"],
             note: String(localized: "Pinned tabs stay, even after you quit", comment: "Under a step's title in the getting-started guide, a card in the window."),
             done: String(localized: "Pinned", comment: "Said once a step is done in the getting-started guide, a card in the window."),
             doneNote: String(localized: "It stays at the top of this space", comment: "Under what's said once a step is done, in the getting-started guide, a card in the window.")),
        Task(id: "peek",
             title: String(localized: "Shift-click a blue link", comment: "A step's title in the getting-started guide, a card in the window."),
             keys: ["⇧", String(localized: "Click", comment: "A key in the getting-started guide, after ⇧: click with the mouse or trackpad.")],
             note: String(localized: "Here’s an article to try it on", comment: "Under a step's title in the getting-started guide, a card in the window."),
             done: String(localized: "That’s Peek", comment: "Said once a step is done in the getting-started guide, a card in the window."),
             doneNote: String(localized: "A quick look, without losing your place", comment: "Under what's said once a step is done, in the getting-started guide, a card in the window. Peek is a Zigzag feature's name.")),
        Task(id: "split",
             title: String(localized: "Drag a tab onto the page", comment: "A step's title in the getting-started guide, a card in the window."),
             keys: [],
             note: String(localized: "Two pages, side by side", comment: "Under a step's title in the getting-started guide, a card in the window."),
             done: String(localized: "That’s Split View", comment: "Said once a step is done in the getting-started guide, a card in the window."),
             doneNote: String(localized: "To separate them, click the split button at the top right of either page", comment: "Under what's said once a step is done, in the getting-started guide, a card in the window.")),
        Task(id: "overview",
             title: String(localized: "See all your tabs", comment: "A step's title in the getting-started guide, a card in the window."),
             keys: ["⇧", "⌘", "\\"],
             note: String(localized: "Press these keys, then type to find a tab", comment: "Under a step's title in the getting-started guide, a card in the window."),
             done: String(localized: "Every tab, at a glance", comment: "Said once a step is done in the getting-started guide, a card in the window."),
             doneNote: String(localized: "Click one to go to it, or press Esc to go back", comment: "Under what's said once a step is done, in the getting-started guide, a card in the window.")),
        Task(id: "space",
             title: String(localized: "Make a space", comment: "A step's title in the getting-started guide, a card in the window."),
             keys: [],
             note: String(localized: "Click + at the bottom of the sidebar", comment: "Under a step's title in the getting-started guide, a card in the window."),
             done: String(localized: "Your new space", comment: "Said once a step is done in the getting-started guide, a card in the window."),
             doneNote: String(localized: "Its own tabs and pinned tabs, in its own color", comment: "Under what's said once a step is done, in the getting-started guide, a card in the window.")),
        Task(id: "switch",
             title: String(localized: "Go back to your first space", comment: "A step's title in the getting-started guide, a card in the window."),
             keys: [],
             note: String(localized: "Swipe two fingers across the sidebar, or click its dot", comment: "Under a step's title in the getting-started guide, a card in the window."),
             done: String(localized: "That’s switching spaces", comment: "Said once a step is done in the getting-started guide, a card in the window."),
             doneNote: String(localized: "Swipe or click a dot anytime, or press ⌥⌘← and ⌥⌘→", comment: "Under what's said once a step is done, in the getting-started guide, a card in the window.")),
    ]

    /// The step that was just skipped, so the guide moves on without saying it was done.
    @MainActor static var skipped: String?

    private static let key = "TutorialDone"
    static var done: Set<String> {
        get {
            var done = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            // Finished before Split View or the overview were steps: it doesn't come back to teach just those.
            if done.contains("space") { done.formUnion(["split", "overview"]) }
            return done
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }

    /// Finished the guide before "go back to your first space" was a step: once, on the first launch of the version
    /// that added it, that step counts as done too, so the guide doesn't come back to teach just that.
    static func migrate() {
        let flag = "TutorialSwitchStepAdded"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        if done.contains("space") { done.insert("switch") }
    }

    /// The step to do now: the first in order that isn't done.
    static var current: Task? { tasks.first { !done.contains($0.id) } }

    /// Ended with the guide's ×; Help › Getting Started starts it again.
    static var isHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "TutorialHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "TutorialHidden") }
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
    }
}
