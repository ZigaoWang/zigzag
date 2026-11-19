import Foundation
import Testing
@testable import Zigzag

/// A question for a tab that can't show it yet: it waits, the tab is marked, nothing is auto-answered.
@MainActor @Suite(.serialized) struct PendingQuestionsTests {
    /// A tab is marked exactly while its question waits and can't be shown. Tests `PendingQuestions.waits`, used by the sidebar row and edge glow.
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

    /// Hidden windows and background tabs hold the question; the front tab of a visible window shows it.
    @Test func onlyAVisibleWindowWithItsTabInFrontShowsAQuestion() {
        #expect(PendingQuestions.canShow(isFront: true, windowVisible: true) == true)
        #expect(PendingQuestions.canShow(isFront: true, windowVisible: false) == false)
        #expect(PendingQuestions.canShow(isFront: false, windowVisible: true) == false)
    }

    /// A question is counted once however often it's reported.
    @Test func aQuestionIsCountedOnce() {
        PendingQuestions.forgetAll()
        let tabID = UUID(), id = UUID()
        let question = PendingQuestions.Question(id: id, tabID: tabID, origin: "https://a.com", title: "Open mpv")
        PendingQuestions.enqueue(question)
        PendingQuestions.enqueue(question)
        #expect(PendingQuestions.count(tabID: tabID) == 1)
    }

    /// Windows without a sidebar (Mini, web apps) glow on the window edge on the `sidebarOnRight` side, full page height.
    @Test func theEdgeGlowSitsOnTheWindowEdgeTheSidebarIsOn() {
        let page = NSRect(x: 0, y: 20, width: 800, height: 600)
        let left = AttentionEdge.frame(forPage: page, sidebarOnRight: false)
        let right = AttentionEdge.frame(forPage: page, sidebarOnRight: true)
        #expect(left.minX - page.minX <= Tokens.Metric.hairline, "the hairline is on the window's leading edge")
        #expect(page.maxX - right.minX <= Tokens.Metric.hairline, "or on its trailing edge, with the sidebar there")
        #expect(left.minX < page.midX && right.minX > page.midX, "the two sides are opposite ones")
        #expect(left.minY == page.minY && left.height == page.height, "the page's whole height, either way")
    }

    /// A browser window with its sidebar hidden glows on its edge, not at the hidden sidebar's width.
    @Test func aBrowserWindowGlowsOnItsEdgeNotInsideThePage() {
        let bounds = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let left = BrowserRootView.attentionEdgeFrame(in: bounds, onRight: false)
        let right = BrowserRootView.attentionEdgeFrame(in: bounds, onRight: true)
        #expect(left.minX == bounds.minX)
        #expect(right.minX >= bounds.maxX - Tokens.Metric.hairline)
        #expect(left.maxX < Tokens.Metric.sidebarWidth / 2, "nowhere near where the sidebar's edge would be")
    }
}
