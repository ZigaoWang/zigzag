import Foundation

/// Questions waiting for a tab that cannot show them yet: a page that asked while it was in a background tab, a hidden
/// window, a pop-up, or Zigzag Mini without focus. The request itself keeps waiting — the tab's WebKit decision is not
/// answered — and the tab wears a marker so the question is not silently forgotten. Nothing here answers anything, and
/// nothing times out: a held question is answered when you bring the tab forward, or when the tab closes or goes to
/// another site.
@MainActor
enum PendingQuestions {
    struct Question: Identifiable, Equatable {
        let id: UUID
        let tabID: UUID
        let origin: String?
        let title: String
    }

    private static var waiting: [Question] = []
    /// Sent whenever the list changes, so a tab's dot and the sidebar's edge follow along. The value is how many
    /// questions are waiting for the tab in question, or the total when no tab is named.
    static let changed = Signal<Int>()

    static func enqueue(_ question: Question) {
        guard !waiting.contains(where: { $0.id == question.id }) else { return }
        waiting.append(question)
        changed.send(waiting.count)
    }

    /// The question was answered, or put off: it is no longer waiting.
    static func answer(_ id: UUID, _ answer: PermissionAnswer?) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index)
        changed.send(waiting.count)
    }

    static func pending(tabID: UUID) -> [Question] { waiting.filter { $0.tabID == tabID } }
    static func hasPending(tabID: UUID) -> Bool { waiting.contains { $0.tabID == tabID } }
    static func count(tabID: UUID) -> Int { pending(tabID: tabID).count }

    /// A question can go on screen only in a window that is visible with its tab in front; anything else is held.
    static func canShow(isFront: Bool, windowVisible: Bool) -> Bool { isFront && windowVisible }

    /// A question is waiting for this tab and nothing is showing it: it isn't the tab in front, or its window is
    /// hidden. That is when the tab wears the dot, and the sidebar's edge glows while the sidebar is out of sight.
    static func waits(tabID: UUID, isFront: Bool, windowVisible: Bool) -> Bool {
        hasPending(tabID: tabID) && !canShow(isFront: isFront, windowVisible: windowVisible)
    }

    /// The tab closed, or left for another site: nothing is waiting for it any more.
    static func forget(tabID: UUID) {
        let left = waiting.filter { $0.tabID == tabID }
        guard !left.isEmpty else { return }
        waiting.removeAll { $0.tabID == tabID }
        changed.send(waiting.count)
    }

    static var total: Int { waiting.count }

    #if DEBUG
    /// For tests: nothing is waiting.
    static func forgetAll() {
        waiting = []
        changed.send(0)
    }
    #endif
}
