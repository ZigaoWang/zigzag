import AppKit

/// Getting started: six things to do once, in order, each building on the last, on real pages. The guide in the window
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
        Task(id: "newTab", title: "Search YouTube", keys: ["⌘", "T"], note: "Open a new tab to start",
             done: "You searched YouTube from here", doneNote: "Type any site’s name, then Tab, to search it"),
        Task(id: "pin", title: "Pin this page", keys: ["⌘", "D"], note: "Pinned pages stay, even after you quit",
             done: "Pinned", doneNote: "It stays at the top of this space"),
        Task(id: "peek", title: "Shift-click a blue link", keys: ["⇧", "Click"], note: "Here’s an article to try it on",
             done: "That’s Peek", doneNote: "A quick look, without losing your place"),
        Task(id: "split", title: "Drag the lit tab onto the page", keys: ["Drag"], note: "Two pages, side by side",
             done: "That’s Split View", doneNote: "To part them, use the button at the top right of either page"),
        Task(id: "space", title: "Make a space", keys: ["+"], note: "One for work, one for fun, each with its own color",
             done: "Your new space", doneNote: "Its own tabs and pins, in its own color"),
        Task(id: "switch", title: "Go back to your first space", keys: ["Swipe"], note: "Two fingers across the sidebar, or click its dot",
             done: "That’s switching spaces", doneNote: "Swipe or click a dot anytime, or press ⌥⌘← and ⌥⌘→"),
    ]

    /// The step that was just skipped, so the guide moves on without saying it was done.
    @MainActor static var skipped: String?

    private static let key = "TutorialDone"
    static var done: Set<String> {
        get {
            var done = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            // Finished before Split View was a step: it doesn't come back to teach just that.
            if done.contains("space") { done.insert("split") }
            return done
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
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
