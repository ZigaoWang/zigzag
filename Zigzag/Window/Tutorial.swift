import AppKit

/// Getting started: four things to do once, in order, each building on the last. The guide in the window
/// (GuidedTour) shows them one at a time; each ticks off when you actually do it.
enum Tutorial {
    struct Task {
        let id: String
        let title: String
        let keys: [String]
        /// Said for a moment once it's done, pointing at what changed, so you see what happened.
        let done: String
    }

    /// Each step is the keys and three words: nothing to read.
    static let tasks: [Task] = [
        Task(id: "newTab", title: "Open a website", keys: ["⌘", "T"], done: "It opened as a tab, here."),
        Task(id: "pin", title: "Pin this page", keys: ["⌘", "D"], done: "Pinned. It stays up here."),
        Task(id: "peek", title: "Shift-click a link", keys: ["⇧", "Click"], done: "That’s Peek: a look without leaving."),
        Task(id: "space", title: "Make a space", keys: ["+"], done: "A new space. The dots switch spaces."),
    ]

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
        done.insert(current.id)
        changed.send(())
    }

    /// Help › Getting Started: from the top.
    @MainActor static func restart() {
        done = []
        isHidden = false
    }
}
