import AppKit

/// Getting started: four things to do once, in order, each building on the last. The guide in the window
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
        Task(id: "newTab", title: "Open a new tab", keys: ["⌘", "T"], note: "Type a site or a search",
             done: "It opened as a tab", doneNote: "Your tabs live here, in the sidebar"),
        Task(id: "pin", title: "Pin this page", keys: ["⌘", "D"], note: "Pinned pages stay, even after you quit",
             done: "Pinned", doneNote: "It stays at the top of this space"),
        Task(id: "peek", title: "Shift-click any link", keys: ["⇧", "Click"], note: "It opens on top, so you keep your place",
             done: "That’s Peek", doneNote: "A quick look without leaving the page"),
        Task(id: "space", title: "Make a space", keys: ["+"], note: "Keep work, school and play apart",
             done: "Your new space", doneNote: "Click a dot to switch between spaces"),
    ]

    /// The step that was just skipped, so the guide moves on without saying it was done.
    @MainActor static var skipped: String?

    private static let key = "TutorialDone"
    static var done: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
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
