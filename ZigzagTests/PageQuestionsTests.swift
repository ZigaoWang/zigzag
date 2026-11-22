import AppKit
import Testing
@testable import Zigzag

/// One item at a time at the top of a page: questions take turns, toasts go below.
@MainActor
struct PageQuestionsTests {
    @Test func questionsTakeTurns() {
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let camera = PermissionPrompt(frame: NSRect(x: 330, y: 12, width: 340, height: 120))
        let next = PermissionPrompt(frame: NSRect(x: 330, y: 12, width: 340, height: 120))
        overlay.addSubview(camera)
        overlay.addSubview(next)
        next.isHidden = true
        // One shows, the other waits.
        #expect(PageQuestions.showing(in: overlay) === camera)
        #expect(!PageQuestions.mayShow(next, in: overlay))
        // The one showing may stay.
        #expect(PageQuestions.mayShow(camera, in: overlay))
        // Hidden (tab went behind) or removed: next one's turn.
        camera.isHidden = true
        #expect(PageQuestions.mayShow(next, in: overlay))
        camera.isHidden = false
        camera.removeFromSuperview()
        #expect(PageQuestions.mayShow(next, in: overlay))
        // Toasts aren't questions and never block one.
        let toast = ToastView(frame: NSRect(x: 400, y: 12, width: 200, height: 36))
        overlay.addSubview(toast)
        #expect(PageQuestions.mayShow(next, in: overlay))
    }

    /// In a split each pane has its own top, so questions on different panes show together.
    @Test func questionsOnOtherPanesShowTogether() {
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let left = PermissionPrompt(frame: NSRect(x: 130, y: 12, width: 340, height: 120))
        let camera = PermissionPrompt(frame: NSRect(x: 730, y: 12, width: 340, height: 120))
        overlay.addSubview(left)
        overlay.addSubview(camera)
        camera.isHidden = true
        #expect(PageQuestions.mayShow(camera, in: overlay))
        // On the same pane they'd overlap, so it waits.
        camera.frame.origin.x = 300
        #expect(!PageQuestions.mayShow(camera, in: overlay))
    }

    @Test func aToastGoesUnderWhatsAtTheTop() {
        let page = NSRect(x: 300, y: 40, width: 900, height: 700)
        // Nothing there: the whole page.
        #expect(PageQuestions.area(page, below: nil) == page)
        // A question at the top: the toast area starts below it.
        let question = NSRect(x: 580, y: 52, width: 340, height: 120)
        let under = PageQuestions.area(page, below: question)
        #expect(under.minY == question.maxY)
        #expect(under.maxY == page.maxY)
        #expect(under.minX == page.minX && under.width == page.width)
        // Something over another page leaves this one alone.
        #expect(PageQuestions.area(page, below: NSRect(x: 0, y: 52, width: 200, height: 120)) == page)
    }

    @Test func toastsStayLongEnoughToReadAndReach() {
        // Undo toasts for closed tabs or removed pins last several seconds, longer under the pointer.
        #expect((6...8).contains(Toast.undoDuration))
        // "Password saved" outlasts the prompt sliding away.
        #expect(Toast.confirmationDuration >= 2.5)
    }

    /// A toast's words end as far from its edge as its symbol's ink starts.
    @Test func aToastWithAnIconIsInsetEvenly() {
        let toast = ToastView(frame: .zero)
        toast.label.stringValue = "110%"
        toast.icon.image = Tokens.Symbol.image("plus.magnifyingglass", size: Tokens.Symbol.row)
        let symbolInk = Tokens.Space.x3 + (Tokens.Metric.favicon - Tokens.Symbol.row) / 2
        let trailing = toast.fittingWidth - toast.label.inkWidth - (Tokens.Space.x3 + Tokens.Metric.favicon + Tokens.Space.x2)
        #expect(trailing == symbolInk)
        toast.icon.image = nil
        #expect(toast.fittingWidth - toast.label.inkWidth == Tokens.Space.x4 * 2)
    }
}
