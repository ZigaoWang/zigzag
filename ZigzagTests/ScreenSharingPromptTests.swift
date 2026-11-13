import Foundation
import Testing
@testable import Zigzag

/// Screen sharing (#211): the question offers a window or a screen, as Safari does, and each answer is the number
/// WebKit's `WKDisplayCapturePermissionDecision` takes (Deny 0, ScreenPrompt 1, WindowPrompt 2).
@MainActor
struct ScreenSharingPromptTests {
    @Test func answersAreWebKitsDecisions() {
        #expect(DisplayCaptureChoice.deny.rawValue == 0)
        #expect(DisplayCaptureChoice.screen.rawValue == 1)
        #expect(DisplayCaptureChoice.window.rawValue == 2)
    }

    @Test func promptAnswersMapToChoices() {
        // The filled answer shares a window; the one beside it, a screen.
        #expect(DisplayCaptureChoice(.allow) == .window)
        #expect(DisplayCaptureChoice(.alternate) == .screen)
        // Don't Allow, and putting it off (Esc, ×, a click elsewhere, the tab moving on), are no.
        #expect(DisplayCaptureChoice(.deny) == .deny)
        #expect(DisplayCaptureChoice(.notNow) == .deny)
        // The question never offers Always: screen sharing is asked every time.
        #expect(DisplayCaptureChoice(.always) == .deny)
    }

    @Test func promptOffersWindowScreenAndNo() {
        #expect(DisplayCaptureChoice.window.buttonTitle == "Share Window…")
        #expect(DisplayCaptureChoice.screen.buttonTitle == "Share Screen…")
        #expect(DisplayCaptureChoice.deny.buttonTitle == "Don’t Allow")
        #expect(DisplayCaptureChoice.title == "Share your screen")
    }

    @Test func tabAnswersWebKitsQuestion() {
        // A near miss in the selector and WebKit would show its own picker without asking.
        let selector = NSSelectorFromString("_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:")
        #expect(Tab.instancesRespond(to: selector))
    }
}
