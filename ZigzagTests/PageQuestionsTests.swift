import AppKit
import Testing
@testable import Zigzag

/// The top of a page holds one thing at a time: a page's questions take turns, and a toast goes under the one up.
@MainActor
struct PageQuestionsTests {
    @Test func questionsTakeTurns() {
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let camera = PermissionPrompt(frame: NSRect(x: 330, y: 12, width: 340, height: 120))
        let next = PermissionPrompt(frame: NSRect(x: 330, y: 12, width: 340, height: 120))
        overlay.addSubview(camera)
        overlay.addSubview(next)
        next.isHidden = true
        // One is showing: the other waits.
        #expect(PageQuestions.showing(in: overlay) === camera)
        #expect(!PageQuestions.mayShow(next, in: overlay))
        // The one showing may stay.
        #expect(PageQuestions.mayShow(camera, in: overlay))
        // Set aside (its tab went behind) or gone: the next one's turn.
        camera.isHidden = true
        #expect(PageQuestions.mayShow(next, in: overlay))
        camera.isHidden = false
        camera.removeFromSuperview()
        #expect(PageQuestions.mayShow(next, in: overlay))
        // Anything else floating there (a toast) isn't a question and never holds one up.
        let toast = ToastView(frame: NSRect(x: 400, y: 12, width: 200, height: 36))
        overlay.addSubview(toast)
        #expect(PageQuestions.mayShow(next, in: overlay))
    }

    /// In a split, each pane's top is its own: a question on one pane doesn't hold up a camera question on another.
    @Test func questionsOnOtherPanesShowTogether() {
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let left = PermissionPrompt(frame: NSRect(x: 130, y: 12, width: 340, height: 120))
        let camera = PermissionPrompt(frame: NSRect(x: 730, y: 12, width: 340, height: 120))
        overlay.addSubview(left)
        overlay.addSubview(camera)
        camera.isHidden = true
        #expect(PageQuestions.mayShow(camera, in: overlay))
        // On the same pane, where they'd cover each other, it waits.
        camera.frame.origin.x = 300
        #expect(!PageQuestions.mayShow(camera, in: overlay))
    }

    @Test func aToastGoesUnderWhatsAtTheTop() {
        let page = NSRect(x: 300, y: 40, width: 900, height: 700)
        // Nothing there: the whole page.
        #expect(PageQuestions.area(page, below: nil) == page)
        // A question at the top of the page: the toast's area starts under it, down to the page's bottom.
        let question = NSRect(x: 580, y: 52, width: 340, height: 120)
        let under = PageQuestions.area(page, below: question)
        #expect(under.minY == question.maxY)
        #expect(under.maxY == page.maxY)
        #expect(under.minX == page.minX && under.width == page.width)
        // Something elsewhere in the window (over another page) leaves this one be.
        #expect(PageQuestions.area(page, below: NSRect(x: 0, y: 52, width: 200, height: 120)) == page)
    }
}
