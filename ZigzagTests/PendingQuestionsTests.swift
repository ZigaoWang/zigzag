import Foundation
import Testing
@testable import Zigzag

/// A question for a tab that cannot show it yet: it waits, the tab is marked, and nothing is answered for you.
@MainActor @Suite(.serialized) struct PendingQuestionsTests {
    @Test func aBackgroundTabHoldsItsQuestion() {
        PendingQuestions.forgetAll()
        let tabID = UUID()
        PendingQuestions.enqueue(.init(id: UUID(), tabID: tabID, origin: "https://a.com", title: "Open mpv"))
        #expect(PendingQuestions.canShow(isFront: false, windowVisible: true) == false)
        #expect(PendingQuestions.pending(tabID: tabID).count == 1)
    }

    @Test func answeringClearsTheMarker() {
        PendingQuestions.forgetAll()
        let tabID = UUID(), id = UUID()
        PendingQuestions.enqueue(.init(id: id, tabID: tabID, origin: "https://a.com", title: "Open mpv"))
        PendingQuestions.answer(id, .init(action: "deny", remember: false))
        #expect(PendingQuestions.hasPending(tabID: tabID) == false)
        #expect(PendingQuestions.total == 0)
    }

    @Test func oneDotPerTabHoweverManyQuestions() {
        PendingQuestions.forgetAll()
        let tabID = UUID()
        for _ in 0..<3 { PendingQuestions.enqueue(.init(id: UUID(), tabID: tabID, origin: "https://a.com", title: "Open mpv")) }
        #expect(PendingQuestions.hasPending(tabID: tabID) == true)
        #expect(PendingQuestions.count(tabID: tabID) == 3)
    }

    /// A hidden window and a tab that isn't in front both hold the question; a visible window with the tab in front
    /// can show it.
    @Test func onlyAVisibleWindowWithItsTabInFrontShowsAQuestion() {
        #expect(PendingQuestions.canShow(isFront: true, windowVisible: true) == true)
        #expect(PendingQuestions.canShow(isFront: true, windowVisible: false) == false)
        #expect(PendingQuestions.canShow(isFront: false, windowVisible: true) == false)
    }

    /// A tab that closes leaves nothing waiting for it, and another tab's question is untouched.
    @Test func aClosedTabLeavesNothingWaiting() {
        PendingQuestions.forgetAll()
        let closed = UUID(), other = UUID()
        PendingQuestions.enqueue(.init(id: UUID(), tabID: closed, origin: "https://a.com", title: "Open mpv"))
        PendingQuestions.enqueue(.init(id: UUID(), tabID: other, origin: "https://b.com", title: "Use your camera"))
        PendingQuestions.forget(tabID: closed)
        #expect(PendingQuestions.hasPending(tabID: closed) == false)
        #expect(PendingQuestions.pending(tabID: other).count == 1)
    }

    /// The same question is never counted twice, however often the prompt machinery reports it.
    @Test func aQuestionIsCountedOnce() {
        PendingQuestions.forgetAll()
        let tabID = UUID(), id = UUID()
        let question = PendingQuestions.Question(id: id, tabID: tabID, origin: "https://a.com", title: "Open mpv")
        PendingQuestions.enqueue(question)
        PendingQuestions.enqueue(question)
        #expect(PendingQuestions.count(tabID: tabID) == 1)
    }
}
