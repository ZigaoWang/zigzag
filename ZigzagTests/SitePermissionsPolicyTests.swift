import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

@Suite(.serialized) struct SitePermissionsPolicyTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "SitePermissionsPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: suite)
        }
        try body(defaults)
    }

    @Test func remembersAnActionPerSubjectAndOrigin() throws {
        try withDefaults { _ in
            SitePermissions.remember("mini", subject: PermissionSubject.popups, origin: "https://example.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "mini")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://other.com") == nil)
        }
    }

    @Test func forgetForgetsOnlyThatSubject() throws {
        try withDefaults { _ in
            SitePermissions.remember("deny", subject: PermissionSubject.location, origin: "https://example.com")
            SitePermissions.remember("allow", subject: PermissionSubject.notifications, origin: "https://example.com")
            SitePermissions.remember(nil, subject: PermissionSubject.location, origin: "https://example.com")
            #expect(SitePermissions.action(PermissionSubject.location, origin: "https://example.com") == nil)
            #expect(SitePermissions.action(PermissionSubject.notifications, origin: "https://example.com") == "allow")
        }
    }

    @Test func migratesOldBoolsOnce() throws {
        try withDefaults { defaults in
            defaults.set(["https://example.com|camera": true, "https://example.com|popups": false,
                          "https://example.com|app:zoommtg": true], forKey: "SitePermissions")
            SitePermissions.migrateAnswersToActions()
            #expect(SitePermissions.action(PermissionSubject.media(.camera), origin: "https://example.com") == "allow")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "deny")
            #expect(SitePermissions.action(PermissionSubject.app("zoommtg"), origin: "https://example.com") == "allow")
        }
    }

    @Test func siteWideAppDenyWinsOverAPerAppAllow() throws {
        try withDefaults { _ in
            SitePermissions.remember("allow", subject: PermissionSubject.app("zoommtg"), origin: "https://example.com")
            SitePermissions.remember("deny", subject: PermissionSubject.apps, origin: "https://example.com")
            #expect(SitePermissions.action(PermissionSubject.app("zoommtg"), origin: "https://example.com") == "deny")
        }
    }

    @Test func aPerAppDenyBlocksOnlyThatApp() throws {
        try withDefaults { _ in
            SitePermissions.remember("deny", subject: PermissionSubject.app("zoommtg"), origin: "https://example.com")
            #expect(SitePermissions.appDecision(origin: "https://example.com", scheme: "zoommtg") == false)
            #expect(SitePermissions.appDecision(origin: "https://example.com", scheme: "itms-apps") == nil)
        }
    }

    @Test func alwaysStoresAndThisTimeDoesNot() throws {
        try withDefaults { _ in
            let remember = SitePermissions.rememberAnswer(PermissionAnswer(action: "allow", remember: true),
                                                          subject: PermissionSubject.location, origin: "https://a.com",
                                                          tab: nil, isPrivate: false)
            #expect(remember == true)
            #expect(SitePermissions.action(PermissionSubject.location, origin: "https://a.com") == "allow")
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "deny", remember: false),
                                               subject: PermissionSubject.notifications, origin: "https://b.com",
                                               tab: nil, isPrivate: false)
            #expect(SitePermissions.action(PermissionSubject.notifications, origin: "https://b.com") == nil)
        }
    }

    /// "This time" holds for the page that asked, and a private tab keeps nothing even when its caller forgets to say
    /// it is private.
    @Test func thisTimeHoldsForThePageAndAPrivateTabKeepsNothing() throws {
        try withDefaults { _ in
            let tab = Tab(url: URL(string: "https://a.com"), spaceID: UUID())
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "screen", remember: false),
                                               subject: PermissionSubject.screen, origin: "https://a.com",
                                               tab: tab, isPrivate: false)
            #expect(tab.permissionAnswers.action(key: "https://a.com", kind: PermissionSubject.screen) == "screen")
            #expect(SitePermissions.action(PermissionSubject.screen, origin: "https://a.com") == nil)

            let privateTab = Tab(url: URL(string: "https://a.com"), spaceID: UUID())
            privateTab.privateStore = WKWebsiteDataStore.nonPersistent()
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "allow", remember: true),
                                               subject: PermissionSubject.location, origin: "https://a.com",
                                               tab: privateTab, isPrivate: false)
            #expect(SitePermissions.action(PermissionSubject.location, origin: "https://a.com") == nil)
            #expect(privateTab.permissionAnswers.answer(key: "https://a.com", kind: "location") == true)
        }
    }

    @Test func alwaysStoresADenyToo() throws {
        try withDefaults { _ in
            let remembers = SitePermissions.rememberAnswer(PermissionAnswer(action: "deny", remember: true),
                                                           subject: PermissionSubject.media(.camera), origin: "https://a.com",
                                                           tab: nil, isPrivate: false)
            #expect(remembers == false)
            #expect(SitePermissions.action(PermissionSubject.media(.camera), origin: "https://a.com") == "deny")
        }
    }

    /// A private window asks, but writes nothing down, even if an answer says it should be kept.
    @Test func aPrivateWindowKeepsNothing() throws {
        try withDefaults { _ in
            let allowed = SitePermissions.rememberAnswer(PermissionAnswer(action: "allow", remember: true),
                                                         subject: PermissionSubject.location, origin: "https://a.com",
                                                         tab: nil, isPrivate: true)
            #expect(allowed == true)
            #expect(SitePermissions.action(PermissionSubject.location, origin: "https://a.com") == nil)
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "deny", remember: true),
                                               subject: PermissionSubject.notifications, origin: "https://a.com",
                                               tab: nil, isPrivate: true)
            #expect(SitePermissions.action(PermissionSubject.notifications, origin: "https://a.com") == nil)
        }
    }

    /// The three ways WebKit can answer, and the answer each is kept as — so a kept one can be read back as the same
    /// choice. It used to be the one question that kept nothing; now a no, a display and a window are all keepable.
    @Test func screenSharingOffersThreeActionsAndKeepsThem() {
        #expect(DisplayCaptureChoice.actions.map(\.id) == ["deny", "screen", "allow"])
        #expect(DisplayCaptureChoice.actions.last?.isProminent == true)
        for choice in DisplayCaptureChoice.allCases {
            #expect(DisplayCaptureChoice(action: choice.action) == choice)
        }
        // A kept "allow" is Share Window…, the action the filled button has, and nothing else is a choice.
        #expect(DisplayCaptureChoice(action: "allow") == .window)
        #expect(DisplayCaptureChoice(action: "toast") == nil)
    }

    /// The screen-sharing buttons reach the three ways WebKit can answer, and nothing else is a yes.
    @Test func screenSharingMapsItsActions() {
        #expect(DisplayCaptureChoice(PermissionAnswer(action: "screen", remember: false)) == .screen)
        #expect(DisplayCaptureChoice(PermissionAnswer(action: "allow", remember: false)) == .window)
        #expect(DisplayCaptureChoice(PermissionAnswer(action: "deny", remember: false)) == .deny)
        #expect(DisplayCaptureChoice(nil) == .deny)
    }

    /// A page answer keeps the action it was given, not just yes or no: a handoff rule's "browser" has to survive
    /// so the same page is not asked twice.
    @Test func aPageAnswerKeepsItsActionAndItsYesOrNo() {
        var page = PagePermissionAnswers()
        let kind = "handoff:\(UUID().uuidString)"
        page.note("browser", key: "https://a.com", kind: kind)
        #expect(page.action(key: "https://a.com", kind: kind) == "browser")
        #expect(page.answer(key: "https://a.com", kind: kind) == false)
        #expect(page.action(key: "https://a.com", kind: "handoff:other") == nil)

        page.note(true, key: "https://a.com", kind: "location")
        #expect(page.action(key: "https://a.com", kind: "location") == "allow")
        #expect(page.answer(key: "https://a.com", kind: "location") == true)

        // An answer given to both at once, from before the split, is not read as either.
        page.note("deny", key: "https://a.com", kind: "cameraAndMicrophone")
        #expect(page.answer(key: "https://a.com", kind: "camera") == nil)
        #expect(page.answer(key: "https://a.com", kind: "microphone") == nil)

        page.forget()
        #expect(page.isEmpty)
        #expect(page.action(key: "https://a.com", kind: kind) == nil)
    }

    /// An app answer is kept only for a secure page, and never for a frame from another site.
    @Test func anHttpPageCannotRememberAnAppQuestion() {
        #expect(ExternalLinks.canRemember(url: URL(string: "http://example.com"), foreign: false) == false)
        #expect(ExternalLinks.canRemember(url: URL(string: "https://example.com"), foreign: false) == true)
        #expect(ExternalLinks.canRemember(url: URL(string: "https://example.com"), foreign: true) == false)
    }

    /// A kept answer is honored as it stands — the site's Allow opens, its Block stops, and nothing asks again.
    /// Whether an answer *may* be written is a separate gate (`saves`), so `verdict` never second-guesses a stored
    /// Allow: an http origin's Allow can only have been chosen in Site Controls, and it must be respected.
    @Test func aStoredAllowSkipsTheQuestionAndABlockStopsIt() {
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "zoommtg", stored: "allow") == .open)
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "zoommtg", stored: "deny") == .block)
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "zoommtg", stored: nil) == .ask)
    }

    @Test func aForeignFrameNeverSeesThePagesAllow() {
        #expect(ExternalLinks.decision(page: "https://zoom.us", foreign: true, stored: "allow") == nil)
        #expect(ExternalLinks.decision(page: "https://zoom.us", foreign: true, stored: "deny") == "deny")
    }

    @Test func aStoredPopupDestinationIsUsedWithoutAsking() throws {
        try withDefaults { _ in
            SitePermissions.remember("newTab", subject: PermissionSubject.popups, origin: "https://example.com")
            #expect(PopupNotice.storedAction(origin: "https://example.com") == "newTab")
            #expect(PopupNotice.storedAction(origin: nil) == nil)
            #expect(PopupNotice.storedAction(origin: "https://other.example") == nil)
        }
    }

    @Test func everyPopupActionIsADistinctStandingAnswer() throws {
        try withDefaults { _ in
            for action in ["mini", "thisTab", "newTab", "deny"] {
                SitePermissions.remember(action, subject: PermissionSubject.popups, origin: "https://example.com")
                #expect(PopupNotice.storedAction(origin: "https://example.com") == action)
            }
        }
    }

    /// Every stored or answered pop-up value has a destination, and an unknown one — an older build's "allow", from
    /// when Always Allow meant an everyday pop-up — reads as the ordinary routing, rather than opening nothing at all
    /// and leaving the page's pop-up unseen.
    @Test func everyPopupValueHasADestination() {
        #expect(PopupNotice.destination(for: "deny") == .deny)
        #expect(PopupNotice.destination(for: "thisTab") == .thisTab)
        #expect(PopupNotice.destination(for: "newTab") == .newTab)
        #expect(PopupNotice.destination(for: "mini") == .viewer)
        #expect(PopupNotice.destination(for: "automatic") == .automatic)
        #expect(PopupNotice.destination(for: "allow") == .automatic)
        #expect(PopupNotice.destination(for: "") == .viewer)
    }

    /// What happens to the pop-up WebKit offered once the answer is in. Mini keeps that very window, so a sign-in
    /// can hand its result back; This Tab and New Tab close it and open their own; the ordinary yes keeps it only
    /// where it is a real pop-up anyway — a plain window.open still opens a tab, as it did before the card.
    @Test func theOfferedPopUpIsKeptForMiniAndDroppedOtherwise() {
        #expect(PopupNotice.heldOutcome(for: "mini", sized: true) == .reveal)
        #expect(PopupNotice.heldOutcome(for: "mini", sized: false) == .reveal)
        #expect(PopupNotice.heldOutcome(for: "automatic", sized: true) == .reveal)
        #expect(PopupNotice.heldOutcome(for: "automatic", sized: false) == .discardAndOpen)
        #expect(PopupNotice.heldOutcome(for: "thisTab", sized: true) == .discardAndOpen)
        #expect(PopupNotice.heldOutcome(for: "newTab", sized: true) == .discardAndOpen)
        #expect(PopupNotice.heldOutcome(for: "deny", sized: true) == .discard)
    }

    /// A legacy `true` for a site's pop-ups meant the routing it had before the card — a plain window.open opened a
    /// real tab, a sized one a real pop-up — so it becomes "automatic", not the viewer, which would have made every
    /// pop-up a small window. Every other subject's `true` is a plain "allow".
    @Test func aLegacyPopupYesKeepsTheOrdinaryRouting() throws {
        try withDefaults { defaults in
            defaults.set(["https://example.com|popups": true, "https://example.com|camera": true], forKey: "SitePermissions")
            SitePermissions.migrateAnswersToActions()
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "automatic")
            #expect(SitePermissions.action(PermissionSubject.media(.camera), origin: "https://example.com") == "allow")
        }
    }

    /// Whether a site's pop-ups were allowed is kept as the routing it means, so neither Site Controls nor the debug
    /// bridge can write a bare "allow" that opens nothing.
    @Test func allowingPopupsKeepsTheOrdinaryRouting() throws {
        try withDefaults { _ in
            SitePermissions.setPopups(true, origin: "https://example.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "automatic")
            #expect(SitePermissions.popups(origin: "https://example.com") == true)
            SitePermissions.setPopups(false, origin: "https://example.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "deny")
            SitePermissions.setPopups(nil, origin: "https://example.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == nil)
        }
    }

    /// Site Controls keeps working on the unified store: its Allow is the permission's own ordinary yes (the ordinary
    /// pop-up routing for pop-ups), its Block is a deny, and Ask removes the answer.
    @Test func siteControlsStillReadTheUnifiedAnswers() throws {
        try withDefaults { _ in
            SitePermissions.remember("newTab", subject: PermissionSubject.popups, origin: "https://a.com")
            #expect(SitePermissions.choice(.popups, origin: "https://a.com") == .allow)
            SitePermissions.setChoice(.block, for: .popups, origin: "https://a.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://a.com") == "deny")
            SitePermissions.setChoice(.allow, for: .popups, origin: "https://a.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://a.com") == "automatic")
            SitePermissions.setChoice(.ask, for: .popups, origin: "https://a.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://a.com") == nil)
        }
    }

    /// A page's own pop-up answered "This Tab" or "New Tab" is opened by the tab that asked, through that tab's own
    /// host: Zigzag Mini's and an installed app's windows are not `BrowserWindowController`s, and casting to one was
    /// how their pop-ups used to vanish. A host that is not a browser window still routes correctly, and "Don't
    /// Allow" opens nothing at all.
    @Test func aPopUpGoesThroughTheTabThatAskedNotABrowserWindow() {
        let host = QuestionHostStub()
        let recorder = RecordingTabHost()
        let tab = Tab(url: URL(string: "https://example.com/"), spaceID: UUID())
        tab.host = recorder
        let popup = URL(string: "https://example.com/pop-up")!

        PopupNotice.open(popup, action: "thisTab", from: tab, in: host)
        #expect(recorder.opened.isEmpty, "the asking tab loads it, not the window's selected tab")
        #expect(tab.url == popup)

        recorder.opened.removeAll()
        PopupNotice.open(popup, action: "newTab", from: tab, in: host)
        #expect(recorder.opened.map { $0.disposition } == ["foregroundTab"])

        recorder.opened.removeAll()
        PopupNotice.open(popup, action: "deny", from: tab, in: host)
        #expect(recorder.opened.isEmpty, "a refused pop-up opens nowhere")
    }

    /// A page that asks again on its own for the same address is held to the answer it already gave "this time" — no
    /// second question — and nothing is read back in a private window or with no site to key the answer to, where
    /// nothing is kept.
    @Test func aPagesOwnThisTimePopUpAnswerIsReadBack() {
        let origin = "https://example.com"
        let tab = Tab(url: URL(string: origin + "/"), spaceID: UUID())
        let popup = URL(string: "https://example.com/pop-up")!
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: popup, isPrivate: false) == nil, "nothing answered yet")
        tab.permissionAnswers.note("mini", key: origin, kind: PopupNotice.requestKind(popup))
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: popup, isPrivate: false) == "mini")
        // The answer is the page's own: another site on it is asked separately.
        #expect(PopupNotice.pageAction(tab: tab, origin: "https://other.com", url: popup, isPrivate: false) == nil)
        // A private window keeps nothing, and neither does a page with no site or no tab.
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: popup, isPrivate: true) == nil)
        #expect(PopupNotice.pageAction(tab: tab, origin: nil, url: popup, isPrivate: false) == nil)
        #expect(PopupNotice.pageAction(tab: nil, origin: origin, url: popup, isPrivate: false) == nil)
    }

    /// "This time" answers the request it was given for, not the whole page: after one window.open is answered, a
    /// pop-up to another address is its own question rather than opening unseen.
    @Test func aThisTimePopUpAnswerCoversOneRequest() {
        let origin = "https://example.com"
        let tab = Tab(url: URL(string: origin + "/"), spaceID: UUID())
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!
        tab.permissionAnswers.note("newTab", key: origin, kind: PopupNotice.requestKind(first))
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: first, isPrivate: false) == "newTab")
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: second, isPrivate: false) == nil)
        // The same address still has its answer later, so a retry need not ask again.
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: first, isPrivate: false) == "newTab")
    }

    /// A page's own pop-up may be asked about only from its main frame and only for a web address or about:blank.
    /// A frame's pop-up is blocked quietly, and so is a data: page, a script, a file or a blob.
    @Test func onlyThePagesOwnWebPopupIsAskedAbout() {
        #expect(PopupNotice.mayAsk(url: URL(string: "https://example.com/x"), fromMainFrame: true))
        #expect(PopupNotice.mayAsk(url: URL(string: "http://example.com/x"), fromMainFrame: true))
        #expect(PopupNotice.mayAsk(url: URL(string: "about:blank"), fromMainFrame: true))
        #expect(PopupNotice.mayAsk(url: URL(string: "https://example.com/x"), fromMainFrame: false) == false)
        #expect(PopupNotice.mayAsk(url: URL(string: "about:blank"), fromMainFrame: false) == false)
        #expect(PopupNotice.mayAsk(url: URL(string: "data:text/html,<p>hi</p>"), fromMainFrame: true) == false)
        #expect(PopupNotice.mayAsk(url: URL(string: "javascript:alert(1)"), fromMainFrame: true) == false)
        #expect(PopupNotice.mayAsk(url: URL(string: "file:///tmp/index.html"), fromMainFrame: true) == false)
        #expect(PopupNotice.mayAsk(url: URL(string: "blob:https://example.com/abc"), fromMainFrame: true) == false)
        #expect(PopupNotice.mayAsk(url: nil, fromMainFrame: true) == false)

        // The routing a kept destination is held to is the same: a web address opens, an app's asks, the rest goes
        // nowhere.
        #expect(PopupNotice.route(URL(string: "https://example.com/x")!, from: nil) == .open)
        #expect(PopupNotice.route(URL(string: "about:blank")!, from: nil) == .open)
        #expect(PopupNotice.route(URL(string: "zoommtg://zoom.us/join")!, from: nil) == .app)
        #expect(PopupNotice.route(URL(string: "data:text/html,<p>hi</p>")!, from: nil) == .refuse)
        #expect(PopupNotice.route(URL(string: "file:///tmp/index.html")!, from: nil) == .refuse)
        #expect(PopupNotice.route(URL(string: "file:///tmp/index.html")!, from: URL(string: "file:///tmp/page.html")) == .open)
    }

    /// A plain yes or no is written as the Bool an older build reads, so going back to one keeps every permission;
    /// an action id only this build understands stays a string. A store of nothing but yeses and nos is a
    /// [String: Bool] whole, which is exactly what the old build casts the entry to.
    @Test func simpleAnswersStayReadableToAnOlderBuild() throws {
        try withDefaults { defaults in
            SitePermissions.remember("allow", subject: PermissionSubject.media(.camera), origin: "https://a.com")
            SitePermissions.remember("deny", subject: PermissionSubject.location, origin: "https://a.com")
            SitePermissions.setPopups(true, origin: "https://a.com")
            let raw = try #require(defaults.dictionary(forKey: "SitePermissions"))
            #expect(raw["https://a.com|camera"] as? Bool == true)
            #expect(raw["https://a.com|location"] as? Bool == false)
            #expect(raw["https://a.com|popups"] as? Bool == true)
            #expect(defaults.dictionary(forKey: "SitePermissions") as? [String: Bool] ==
                    ["https://a.com|camera": true, "https://a.com|location": false, "https://a.com|popups": true])

            // A destination or a handoff's choice is not a yes or no: it keeps its id.
            SitePermissions.remember("mini", subject: PermissionSubject.popups, origin: "https://b.com")
            SitePermissions.remember("handOff", subject: "handoff:\(UUID().uuidString)", origin: "https://b.com")
            let mixed = try #require(defaults.dictionary(forKey: "SitePermissions"))
            #expect(mixed["https://b.com|popups"] as? String == "mini")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://b.com") == "mini")
            #expect(SitePermissions.action(PermissionSubject.media(.camera), origin: "https://a.com") == "allow")
            #expect(SitePermissions.action(PermissionSubject.location, origin: "https://a.com") == "deny")
        }
    }

    /// A page's own "this time" app answer covers one launch: a script firing the same link again a moment later is
    /// held to the same few seconds a question is, rather than setting the app going over and over.
    @Test func aPagesAppAnswerSpeedsNoRunOfLaunches() {
        var asked = ExternalLinks.Asked()
        let key = "https://zoom.us|zoommtg"
        let now = Date()
        let first = asked.mayOpenAgain(key, now: now)
        #expect(first)
        let secondsLater = asked.mayOpenAgain(key, now: now.addingTimeInterval(1))
        #expect(secondsLater == false)
        let justBefore = asked.mayOpenAgain(key, now: now.addingTimeInterval(ExternalLinks.Asked.repeatGap - 1))
        #expect(justBefore == false)
        let afterTheGap = asked.mayOpenAgain(key, now: now.addingTimeInterval(ExternalLinks.Asked.repeatGap))
        #expect(afterTheGap)
        // Another site's launch isn't held up by this one.
        let elsewhere = asked.mayOpenAgain("https://meet.example|zoommtg", now: now.addingTimeInterval(1))
        #expect(elsewhere)
    }

    /// A page's pop-up questions keep the same few seconds: a page that asks again on its own right after a question
    /// went up doesn't get a second card, and a question put off isn't put straight back.
    @Test func aPageAskingAgainIsHeldToItsFewSeconds() {
        let origin = "https://example.com"
        let now = Date()
        PopupNotice.forgetAnswers(origin: origin)
        #expect(PopupNotice.mayAsk(origin: origin, now: now))
        PopupNotice.noteAsked(origin: origin, now: now)
        #expect(PopupNotice.mayAsk(origin: origin, now: now.addingTimeInterval(1)) == false)
        #expect(PopupNotice.mayAsk(origin: origin, now: now.addingTimeInterval(PopupNotice.unaskedGap)))
        PopupNotice.noteSetAside(origin: origin, now: now)
        #expect(PopupNotice.mayAsk(origin: origin, now: now.addingTimeInterval(PopupNotice.unaskedGap)) == false)
        #expect(PopupNotice.mayAsk(origin: origin, now: now.addingTimeInterval(PopupNotice.putOffGap)))
        PopupNotice.forgetAnswers(origin: origin)
    }
}

/// The tab that asked a pop-up's question, recording what its host was told to open.
@MainActor
private final class RecordingTabHost: TabHost {
    var opened: [(url: String, disposition: String)] = []
    var hostWindow: NSWindow? { nil }
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition) {
        opened.append((url.absoluteString, "\(disposition)"))
    }
    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
             features: WKWindowFeatures) -> WKWebView? { nil }
    func tabDidRequestClose(_ tab: Tab) {}
    func tabWantsToReturnToOpener(_ tab: Tab) {}
    func tab(_ tab: Tab, hoveringLink url: URL?) {}
    func tabWantsToBeShown(_ tab: Tab) {}
}

/// A window that can show a question but is no browser window; nothing here is touched for the two destinations
/// that go through the tab, which is the point.
@MainActor
private final class QuestionHostStub: PromptHost {
    var window: NSWindow? { nil }
    var promptOverlay: NSView { NSView() }
    func pageFrame(showing tab: Tab) -> NSRect? { nil }
    var focusedPaneFrame: NSRect { .zero }
    var promptFrontTab: Tab? { nil }
    func promptHolds(_ tab: Tab) -> Bool { false }
    func promptShows(_ tab: Tab) -> Bool { false }
    var promptIsPrivate: Bool { false }
    var promptAccent: NSColor { .controlAccentColor }
    func observePromptTabs(_ body: @escaping () -> Void) -> SignalToken? { nil }
    var promptPageViews: [NSView] { [] }
    func clearForPrompt() {}
    var promptIsCovered: Bool { false }
    var promptAnchor: NSView? { nil }
    func promptToast(_ text: String, symbol: String, duration: TimeInterval) {}
}
