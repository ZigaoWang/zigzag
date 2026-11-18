import Foundation

/// Questions held for a tab that can't show them yet (background tab, hidden window, pop-up, unfocused Mini). The
/// WebKit decision stays pending and the tab shows a marker. Nothing here answers or times out: a held question is
/// answered when the tab comes forward, closes or leaves the site.
@MainActor
enum PendingQuestions {
    struct Question: Identifiable, Equatable {
        let id: UUID
        let tabID: UUID
        let origin: String?
        let title: String
    }

    private static var waiting: [Question] = []
    /// Sends the tab's waiting count, or the total when no tab is named, for the tab dot and sidebar edge.
    static let changed = Signal<Int>()

    static func enqueue(_ question: Question) {
        guard !waiting.contains(where: { $0.id == question.id }) else { return }
        waiting.append(question)
        changed.send(waiting.count)
    }

    /// Answered or put off.
    static func answer(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index)
        changed.send(waiting.count)
    }

    static func pending(tabID: UUID) -> [Question] { waiting.filter { $0.tabID == tabID } }
    static func hasPending(tabID: UUID) -> Bool { waiting.contains { $0.tabID == tabID } }
    static func count(tabID: UUID) -> Int { pending(tabID: tabID).count }

    /// Only in a visible window with its tab in front.
    static func canShow(isFront: Bool, windowVisible: Bool) -> Bool { isFront && windowVisible }

    /// Waiting and not on screen (tab not in front or window hidden): the tab shows the dot, and the sidebar edge
    /// glows while the sidebar is hidden.
    static func waits(tabID: UUID, isFront: Bool, windowVisible: Bool) -> Bool {
        hasPending(tabID: tabID) && !canShow(isFront: isFront, windowVisible: windowVisible)
    }

    static var total: Int { waiting.count }

    #if DEBUG
    /// Tests.
    static func forgetAll() {
        waiting = []
        changed.send(0)
    }
    #endif
}
