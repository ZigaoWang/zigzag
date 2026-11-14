import Foundation
import Testing
@testable import Zigzag

/// A question for a tab that cannot show it yet: it waits, the tab is marked, and nothing is answered for you.
@MainActor @Suite(.serialized) struct PendingQuestionsTests {
    /// A tab wears its marker exactly while a question is waiting for it and cannot be shown yet: not before it was
    /// asked, and not while it is the tab in front of a visible window. This is the very predicate the sidebar row
    /// and the sidebar's edge glow call (`PendingQuestions.waits`), so inverting it would light up a tab that has
    /// nothing to answer, or hide one that does.
    @Test func aTabWearsTheMarkerOnlyWhileItsQuestionCannotBeShown() {
        PendingQuestions.forgetAll()
        let tabID = UUID()
        #expect(PendingQuestions.waits(tabID: tabID, isFront: false, windowVisible: true) == false, "nothing asked yet")
        PendingQuestions.enqueue(.init(id: UUID(), tabID: tabID, origin: "https://a.com", title: "Open mpv"))
        #expect(PendingQuestions.waits(tabID: tabID, isFront: false, windowVisible: true) == true, "a background tab")
        #expect(PendingQuestions.waits(tabID: tabID, isFront: true, windowVisible: false) == true, "a hidden window")
        #expect(PendingQuestions.waits(tabID: tabID, isFront: true, windowVisible: true) == false, "there, able to be shown")
        #expect(PendingQuestions.waits(tabID: UUID(), isFront: false, windowVisible: true) == false, "another tab")
    }

    @Test func answeringClearsTheMarker() {
        PendingQuestions.forgetAll()
        let tabID = UUID(), id = UUID()
        PendingQuestions.enqueue(.init(id: id, tabID: tabID, origin: "https://a.com", title: "Open mpv"))
        PendingQuestions.answer(id)
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

    /// The same question is never counted twice, however often the prompt machinery reports it.
    @Test func aQuestionIsCountedOnce() {
        PendingQuestions.forgetAll()
        let tabID = UUID(), id = UUID()
        let question = PendingQuestions.Question(id: id, tabID: tabID, origin: "https://a.com", title: "Open mpv")
        PendingQuestions.enqueue(question)
        PendingQuestions.enqueue(question)
        #expect(PendingQuestions.count(tabID: tabID) == 1)
    }

    /// A window that shows one page and has no sidebar (Zigzag Mini, a web app) hangs the glow on its own edge, on the
    /// side `sidebarOnRight` puts the sidebar, and runs it the page's whole height — where the sidebar's dot would be.
    @Test func theEdgeGlowSitsOnTheWindowEdgeTheSidebarIsOn() {
        let page = NSRect(x: 0, y: 20, width: 800, height: 600)
        let left = AttentionEdge.frame(forPage: page, sidebarOnRight: false)
        let right = AttentionEdge.frame(forPage: page, sidebarOnRight: true)
        #expect(left.minX - page.minX <= Tokens.Metric.hairline, "the hairline is on the window's leading edge")
        #expect(page.maxX - right.minX <= Tokens.Metric.hairline, "or on its trailing edge, with the sidebar there")
        #expect(left.minX < page.midX && right.minX > page.midX, "the two sides are opposite ones")
        #expect(left.minY == page.minY && left.height == page.height, "the page's whole height, either way")
    }
}
