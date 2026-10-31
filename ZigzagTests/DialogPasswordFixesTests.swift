import AppKit
import Testing
import WebKit
@testable import Zigzag

/// The rules behind page dialogs, confirmations and the save-password offer: a dialog stays on the page that asked,
/// a destructive confirmation never goes ahead on Return, and a login is only offered once the site took it.
@MainActor
struct DialogPasswordFixesTests {
    // MARK: Saving a password only after the sign-in worked

    private func page(_ host: String?, form: Bool, filled: Bool = false) -> PasswordCapture.PageAfterLogin {
        PasswordCapture.PageAfterLogin(host: host, hasPasswordField: form, passwordFilled: filled)
    }

    @Test func signInThatWorkedIsOffered() {
        // On to a page without the form: signed in.
        #expect(PasswordCapture.verdict(loginHost: "github.com", page: page("github.com", form: false)) == .offer)
        // On to another site entirely (the app behind a sign-in service), even one with a password field.
        #expect(PasswordCapture.verdict(loginHost: "login.example.com", page: page("app.other.org", form: true)) == .offer)
        // Another host of the same site with no form, as sign-ins often hop from accounts. to www.
        #expect(PasswordCapture.verdict(loginHost: "accounts.example.com", page: page("www.example.com", form: false)) == .offer)
    }

    @Test func failedSignInIsDropped() {
        // The same form back, its password empty: the password was wrong.
        #expect(PasswordCapture.verdict(loginHost: "github.com", page: page("github.com", form: true)) == .drop)
        // Another host of the same site showing the form again is still a failed try, not another site.
        #expect(PasswordCapture.verdict(loginHost: "example.com", page: page("www.example.com", form: true)) == .drop)
    }

    @Test func unansweredSignInWaits() {
        // The password still typed in: the site hasn't answered yet.
        #expect(PasswordCapture.verdict(loginHost: "github.com", page: page("github.com", form: true, filled: true)) == .wait)
        // A page whose address isn't known yet judges by the form alone.
        #expect(PasswordCapture.verdict(loginHost: "github.com", page: page(nil, form: true, filled: true)) == .wait)
        #expect(PasswordCapture.verdict(loginHost: "github.com", page: page(nil, form: true)) == .drop)
    }

    // MARK: Confirmations

    private func action(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], characters: String? = nil, destructive: Bool,
                        buttonFocused: Bool = false, confirmFocused: Bool = false) -> ConfirmSheet.KeyAction {
        ConfirmSheet.keyAction(keyCode: keyCode, modifiers: modifiers, characters: characters, destructive: destructive,
                               buttonFocused: buttonFocused, confirmFocused: confirmFocused)
    }

    @Test func returnNeverConfirmsSomethingDestructive() {
        #expect(action(36, destructive: true) == .swallow)
        #expect(action(76, destructive: true) == .swallow)
        // Not even with the destructive button focused by Tab: that takes Space.
        #expect(action(36, destructive: true, buttonFocused: true, confirmFocused: true) == .swallow)
        #expect(action(49, destructive: true, buttonFocused: true, confirmFocused: true) == .press)
        // Return on Cancel, reached with Tab, presses Cancel.
        #expect(action(36, destructive: true, buttonFocused: true, confirmFocused: false) == .press)
        // Escape always cancels.
        #expect(action(53, destructive: true) == .cancel)
    }

    @Test func returnConfirmsAnOrdinaryQuestion() {
        #expect(action(36, destructive: false) == .confirm)
        #expect(action(76, destructive: false) == .confirm)
        #expect(action(53, destructive: false) == .cancel)
    }

    @Test func nothingElseGetsPastTheSheet() {
        // ⌘W would close the tab behind it; typing would go into the page.
        #expect(action(13, .command, characters: "w", destructive: true) == .swallow)
        #expect(action(0, characters: "a", destructive: false) == .swallow)
        #expect(action(36, .command, destructive: false) == .swallow)
        // Space with nothing focused does nothing.
        #expect(action(49, destructive: false) == .swallow)
        // Tab moves between the sheet's buttons; ⌘Q still quits.
        #expect(action(48, destructive: true) == .moveFocus(backward: false))
        #expect(action(48, .shift, destructive: true) == .moveFocus(backward: true))
        #expect(action(12, .command, characters: "q", destructive: true) == .pass)
    }

    // MARK: Page dialogs

    @Test func pageDialogWaitsOnItsOwnPageAndGoesWithIt() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // A page whose tab isn't in front: not in any window.
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let asking = Task { await PageDialogSheet.ask(in: window, title: "example.com says", message: "Hello", showsCancel: true,
                                                      offersBlock: false, page: page) }
        for _ in 0..<50 where !page.subviews.contains(where: { $0 is PageDialogSheet }) { await Task.yield() }
        // It sits on its page, not over the window (and so never over the sidebar or another tab's page).
        #expect(page.subviews.contains { $0 is PageDialogSheet })
        #expect(window.contentView?.subviews.contains { $0 is PageDialogSheet } != true)
        // Its tab closing answers it "cancel".
        PageDialogSheet.cancel(for: page)
        let result = await asking.value
        if case .cancelled = result {} else { Issue.record("expected cancelled, got \(result)") }
        #expect(!page.subviews.contains { $0 is PageDialogSheet })
    }
}
