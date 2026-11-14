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
            let rule = UUID()
            let tab = Tab(url: URL(string: "https://a.com"), spaceID: UUID())
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "browser", remember: false),
                                               subject: PermissionSubject.handoff(rule), origin: "https://a.com",
                                               tab: tab, isPrivate: false)
            #expect(tab.permissionAnswers.action(key: "https://a.com", kind: "handoff:\(rule.uuidString)") == "browser")
            #expect(SitePermissions.action(PermissionSubject.handoff(rule), origin: "https://a.com") == nil)

            let privateTab = Tab(url: URL(string: "https://a.com"), spaceID: UUID())
            privateTab.privateStore = WKWebsiteDataStore.nonPersistent()
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "allow", remember: true),
                                               subject: PermissionSubject.location, origin: "https://a.com",
                                               tab: privateTab, isPrivate: false)
            #expect(SitePermissions.action(PermissionSubject.location, origin: "https://a.com") == nil)
            #expect(privateTab.permissionAnswers.answer(key: "https://a.com", kind: "location") == true)
        }
    }

    @Test func alwaysStoresADenyToo() throws {        try withDefaults { _ in
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

    @Test func screenSharingOffersThreeActionsAndKeepsNothing() {        #expect(DisplayCaptureChoice.actions.map(\.id) == ["deny", "screen", "allow"])
        #expect(DisplayCaptureChoice.actions.last?.isProminent == true)
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

        // One answer to camera and microphone at once answers either of them.
        page.note("deny", key: "https://a.com", kind: "cameraAndMicrophone")
        #expect(page.answer(key: "https://a.com", kind: "camera") == false)
        #expect(page.answer(key: "https://a.com", kind: "microphone") == false)

        page.forget()
        #expect(page.isEmpty)
        #expect(page.action(key: "https://a.com", kind: kind) == nil)
    }

    @Test func deletingARuleForgetsItsHandoffAnswers() throws {
        try withDefaults { _ in
            let rule = UUID()
            SitePermissions.remember("handOff", subject: PermissionSubject.handoff(rule), origin: "https://a.com")
            SitePermissions.remember("browser", subject: PermissionSubject.handoff(rule), origin: "https://b.com")
            SitePermissions.forgetActions(prefix: "handoff:\(rule.uuidString)")
            #expect(SitePermissions.actions(origin: "https://a.com").isEmpty)
            #expect(SitePermissions.actions(origin: "https://b.com").isEmpty)
        }
    }

    /// An app answer is kept only for a secure page, and never for a frame from another site.
    @Test func anHttpPageCannotRememberAnAppQuestion() {
        #expect(ExternalLinks.canRemember(url: URL(string: "http://example.com"), foreign: false) == false)
        #expect(ExternalLinks.canRemember(url: URL(string: "https://example.com"), foreign: false) == true)
        #expect(ExternalLinks.canRemember(url: URL(string: "https://example.com"), foreign: true) == false)
    }

    @Test func aStoredAllowSkipsTheQuestionAndABlockStopsIt() {
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "zoommtg", stored: "allow", canRemember: true) == .open)
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "zoommtg", stored: "deny", canRemember: true) == .block)
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "zoommtg", stored: nil, canRemember: true) == .ask)
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
    /// when Always Allow meant an everyday pop-up — reads as the viewer, the ordinary yes, rather than opening
    /// nothing at all and leaving the page's pop-up unseen.
    @Test func everyPopupValueHasADestination() {
        #expect(PopupNotice.destination(for: "deny") == .deny)
        #expect(PopupNotice.destination(for: "thisTab") == .thisTab)
        #expect(PopupNotice.destination(for: "newTab") == .newTab)
        #expect(PopupNotice.destination(for: "mini") == .viewer)
        #expect(PopupNotice.destination(for: "allow") == .viewer)
        #expect(PopupNotice.destination(for: "") == .viewer)
    }

    /// A legacy `true` for a site's pop-ups becomes the destination it means, the viewer — not a bare "allow", which
    /// is no destination and would have dropped every pop-up on a site the user had already allowed. Every other
    /// subject's `true` is a plain "allow".
    @Test func aLegacyPopupYesMeansTheViewer() throws {
        try withDefaults { defaults in
            defaults.set(["https://example.com|popups": true, "https://example.com|camera": true], forKey: "SitePermissions")
            SitePermissions.migrateAnswersToActions()
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "mini")
            #expect(SitePermissions.action(PermissionSubject.media(.camera), origin: "https://example.com") == "allow")
        }
    }

    /// Whether a site's pop-ups were allowed is kept as the destination it means, so neither Site Controls nor the
    /// debug bridge can write a bare "allow" that opens nothing.
    @Test func allowingPopupsKeepsTheViewer() throws {
        try withDefaults { _ in
            SitePermissions.setPopups(true, origin: "https://example.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "mini")
            #expect(SitePermissions.popups(origin: "https://example.com") == true)
            SitePermissions.setPopups(false, origin: "https://example.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "deny")
            SitePermissions.setPopups(nil, origin: "https://example.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == nil)
        }
    }

    /// Site Controls keeps working on the unified store: its Allow is the permission's own ordinary yes (Mini for
    /// pop-ups), its Block is a deny, and Ask removes the answer.
    @Test func siteControlsStillReadTheUnifiedAnswers() throws {
        try withDefaults { _ in
            SitePermissions.remember("newTab", subject: PermissionSubject.popups, origin: "https://a.com")
            #expect(SitePermissions.choice(.popups, origin: "https://a.com") == .allow)
            SitePermissions.setChoice(.block, for: .popups, origin: "https://a.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://a.com") == "deny")
            SitePermissions.setChoice(.allow, for: .popups, origin: "https://a.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://a.com") == "mini")
            SitePermissions.setChoice(.ask, for: .popups, origin: "https://a.com")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://a.com") == nil)
        }
    }

    /// Settings › Downloads lists the sites a rule was decided on, per rule.
    @Test func settingsListsTheSitesARuleWasDecidedOn() throws {
        try withDefaults { _ in
            let rule = UUID()
            SitePermissions.remember("handOff", subject: PermissionSubject.handoff(rule), origin: "https://b.com")
            SitePermissions.remember("browser", subject: PermissionSubject.handoff(rule), origin: "https://a.com")
            SitePermissions.remember("handOff", subject: PermissionSubject.handoff(UUID()), origin: "https://c.com")
            #expect(SitePermissions.sites(prefix: PermissionSubject.handoff(rule)) == ["https://a.com", "https://b.com"])
            #expect(SitePermissions.sites(prefix: "handoff:") == ["https://a.com", "https://b.com", "https://c.com"])
        }
    }
}
