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

    /// The same, for the tests that await the question itself.
    private func withDefaultsAsync(_ body: () async throws -> Void) async throws {
        let suite = "SitePermissionsPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: suite)
        }
        try await body()
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

    // MARK: Notifications: where a site's answer says they show

    /// A notification's yes is a place: each is kept under its own action, and what Zigzag saved before there were
    /// two places still reads as the Mac's.
    @Test func aNotificationsPlaceIsKeptAsItsAction() {
        #expect(NotificationPlace.blocked.action == "deny")
        #expect(NotificationPlace.inZigzag.action == "toast")
        #expect(NotificationPlace.everywhere.action == "everywhere")
        #expect(NotificationPlace.onTheMac.action == "system")
        #expect(NotificationPlace(action: "deny") == .blocked)
        #expect(NotificationPlace(action: "toast") == .inZigzag)
        #expect(NotificationPlace(action: "everywhere") == .everywhere)
        #expect(NotificationPlace(action: "system") == .onTheMac)
        // Allow is what Zigzag saved before there were two places, and it meant the Mac.
        #expect(NotificationPlace(action: "allow") == .onTheMac)
        #expect(NotificationPlace(action: nil) == nil)
        #expect(NotificationPlace(action: "something else") == nil)
        #expect(PermissionChoice.inZigzag.notificationPlace == .inZigzag)
        #expect(PermissionChoice.everywhere.notificationPlace == .everywhere)
        #expect(PermissionChoice.onTheMac.notificationPlace == .onTheMac)
        // Everywhere may show on the Mac when Zigzag is away; in-Zigzag never does.
        #expect(PermissionChoice.everywhere.showsOnTheMac)
        #expect(!PermissionChoice.inZigzag.showsOnTheMac)
        #expect(PermissionChoice.allow.notificationPlace == .onTheMac)
        #expect(PermissionChoice.block.notificationPlace == .blocked)
        #expect(PermissionChoice.ask.notificationPlace == nil)
    }

    // MARK: Downloads: whether a site may save files at all

    /// The downloads question is one answer kept like every other, and never asks once it has one.
    @Test func aStoredDownloadAnswerIsUsedWithoutAskingAnything() async throws {
        try await withDefaultsAsync {
            SitePermissions.remember("allow", subject: PermissionSubject.downloads, origin: "https://files.example")
            #expect(SitePermissions.downloads(origin: "https://files.example") == true)
            #expect(await SitePermissions.downloadsAllowed(origin: "https://files.example", window: nil, isPrivate: false, tab: nil))

            SitePermissions.remember("deny", subject: PermissionSubject.downloads, origin: "https://files.example")
            #expect(SitePermissions.downloads(origin: "https://files.example") == false)
            #expect(await !SitePermissions.downloadsAllowed(origin: "https://files.example", window: nil, isPrivate: false, tab: nil))

            // A site nobody has answered for has said nothing; with nowhere to ask, the file is refused rather than
            // saved unasked.
            #expect(SitePermissions.downloads(origin: "https://other.example") == nil)
            #expect(await !SitePermissions.downloadsAllowed(origin: "https://other.example", window: nil, isPrivate: false, tab: nil))
        }
    }

    /// "This time" is the page's answer, not the site's: another tab is asked.
    @Test func thisTimeDownloadAnswerHoldsForThePageNotTheSite() throws {
        try withDefaults { _ in
            let tab = Tab(url: URL(string: "https://files.example"), spaceID: UUID())
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "allow", remember: false),
                                               subject: PermissionSubject.downloads, origin: "https://files.example",
                                               tab: tab, isPrivate: false)
            #expect(SitePermissions.downloads(origin: "https://files.example", tab: tab) == true)
            #expect(SitePermissions.action(PermissionSubject.downloads, origin: "https://files.example") == nil)
            #expect(SitePermissions.downloads(origin: "https://files.example") == nil)
        }
    }

    /// Allow Once on a blocked download's notice: the answer is kept for the page, exactly as "This time" is, and
    /// never for the site.
    @Test func allowOnceOnANoticeHoldsForThePage() throws {
        try withDefaults { _ in
            let tab = Tab(url: URL(string: "https://files.example"), spaceID: UUID())
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "deny", remember: false),
                                               subject: PermissionSubject.downloads, origin: "https://files.example",
                                               tab: tab, isPrivate: false)
            #expect(SitePermissions.downloads(origin: "https://files.example", tab: tab) == false)

            SitePermissions.allowThisDownload(origin: "https://files.example", tab: tab)
            #expect(SitePermissions.downloads(origin: "https://files.example", tab: tab) == true)
            #expect(SitePermissions.action(PermissionSubject.downloads, origin: "https://files.example") == nil)

            // A site blocked outright stays blocked: the offer is one file at a time, so the next one is refused again.
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "deny", remember: true),
                                               subject: PermissionSubject.downloads, origin: "https://files.example",
                                               tab: nil, isPrivate: false)
            SitePermissions.allowThisDownload(origin: "https://files.example", tab: tab)
            #expect(SitePermissions.downloads(origin: "https://files.example", tab: tab) == false)

            // With no page to keep it on (a tab already gone) nothing is written, and nothing is said about the site.
            SitePermissions.remember(nil, subject: PermissionSubject.downloads, origin: "https://files.example")
            SitePermissions.allowThisDownload(origin: "https://files.example", tab: nil)
            #expect(SitePermissions.downloads(origin: "https://files.example") == nil)
        }
    }

    /// "Always" keeps a deny for the site, and a private window keeps nothing whatever the answer says.
    @Test func aDownloadDenyIsKeptForTheSiteAndAPrivateTabKeepsNothing() throws {
        try withDefaults { _ in
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "deny", remember: true),
                                               subject: PermissionSubject.downloads, origin: "https://files.example",
                                               tab: nil, isPrivate: false)
            #expect(SitePermissions.downloads(origin: "https://files.example") == false)

            let privateTab = Tab(url: URL(string: "https://files.example"), spaceID: UUID())
            privateTab.privateStore = WKWebsiteDataStore.nonPersistent()
            SitePermissions.remember(nil, subject: PermissionSubject.downloads, origin: "https://files.example")
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "allow", remember: true),
                                               subject: PermissionSubject.downloads, origin: "https://files.example",
                                               tab: privateTab, isPrivate: false)
            #expect(SitePermissions.action(PermissionSubject.downloads, origin: "https://files.example") == nil)
            #expect(privateTab.permissionAnswers.answer(key: "https://files.example", kind: "downloads") == true)
            #expect(SitePermissions.downloads(origin: "https://files.example", tab: privateTab) == true)
        }
    }

    /// One answer, in the two places it is chosen: the question and the site's own row. Allow, Block and Ask in Site
    /// Controls are the same decision the question makes, so neither can drift from the other.
    @Test func theSiteControlsDownloadRowIsTheSameAnswerAsTheQuestion() throws {
        try withDefaults { _ in
            SitePermissions.setChoice(.block, for: .downloads, origin: "https://files.example")
            #expect(SitePermissions.downloads(origin: "https://files.example") == false)
            SitePermissions.setChoice(.allow, for: .downloads, origin: "https://files.example")
            #expect(SitePermissions.downloads(origin: "https://files.example") == true)
            SitePermissions.setChoice(.ask, for: .downloads, origin: "https://files.example")
            #expect(SitePermissions.downloads(origin: "https://files.example") == nil)
        }
    }

    /// Its row is offered once the site has an answer, in a private window too (which asks and keeps nothing), and it
    /// offers the same three choices as every other row but notifications.
    @Test func downloadsAreARowInSiteControlsOnceTheSiteHasAnAnswer() throws {
        #expect(SitePermission.downloads.kinds == ["downloads"])
        #expect(SitePermission.downloads.choices == PermissionChoice.ordinary)
        #expect(SitePermission.downloads.inPrivate, "a private window still asks")
        try withDefaults { _ in
            SitePermissions.remember("deny", subject: PermissionSubject.downloads, origin: "https://files.example")
            #expect(SitePermissions.shown(origin: "https://files.example", isPrivate: false).contains(.downloads))
            #expect(SitePermissions.shown(origin: "https://files.example", isPrivate: true).contains(.downloads))
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

    /// A kept answer is honoured as it stands — the site's Allow opens, its Block stops, and nothing asks again.
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
        #expect(recorder.opened.map { $0.url } == [popup.absoluteString])
        #expect(recorder.opened.map { $0.disposition } == ["currentTab"])

        recorder.opened.removeAll()
        PopupNotice.open(popup, action: "newTab", from: tab, in: host)
        #expect(recorder.opened.map { $0.disposition } == ["foregroundTab"])

        recorder.opened.removeAll()
        PopupNotice.open(popup, action: "deny", from: tab, in: host)
        #expect(recorder.opened.isEmpty, "a refused pop-up opens nowhere")
    }

    /// A page that asks again on its own is held to the answer it already gave "this time" — no second question — and
    /// nothing is read back in a private window or with no site to key the answer to, where nothing is kept.
    @Test func aPagesOwnThisTimePopUpAnswerIsReadBack() {
        let origin = "https://example.com"
        let tab = Tab(url: URL(string: origin + "/"), spaceID: UUID())
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, isPrivate: false) == nil, "nothing answered yet")
        tab.permissionAnswers.note("mini", key: origin, kind: PermissionSubject.popups)
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, isPrivate: false) == "mini")
        // The answer is the page's own: another site on it is asked separately.
        #expect(PopupNotice.pageAction(tab: tab, origin: "https://other.com", isPrivate: false) == nil)
        // A private window keeps nothing, and neither does a page with no site or no tab.
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, isPrivate: true) == nil)
        #expect(PopupNotice.pageAction(tab: tab, origin: nil, isPrivate: false) == nil)
        #expect(PopupNotice.pageAction(tab: nil, origin: origin, isPrivate: false) == nil)
    }

    /// Settings › Downloads groups a rule's answered sites by what was answered, so a refused site does not read like
    /// a handed-off one; the groups come in the question's own order and only when they have sites.
    @Test func theDownloadsListGroupsSitesByTheirAnswer() throws {
        try withDefaults { _ in
            let rule = UUID()
            SitePermissions.remember("handOff", subject: PermissionSubject.handoff(rule), origin: "https://a.com")
            SitePermissions.remember("deny", subject: PermissionSubject.handoff(rule), origin: "https://b.com")
            SitePermissions.remember("handOff", subject: PermissionSubject.handoff(rule), origin: "https://c.com")
            SitePermissions.remember("browser", subject: PermissionSubject.handoff(rule), origin: "https://d.com")
            let decided = SitePermissions.decisions(prefix: PermissionSubject.handoff(rule))
            #expect(decided.map(\.origin) == ["https://a.com", "https://b.com", "https://c.com", "https://d.com"])
            let groups = SettingsView.handoffAnswerGroups(decided)
            #expect(groups.map(\.sites) == [["https://a.com", "https://c.com"], ["https://d.com"], ["https://b.com"]])
            // The row's title is the very word the question's button used.
            #expect(groups.map(\.title) == ["Hand Off", "Open in Browser", "Don’t Allow"])
            #expect(SettingsView.handoffAnswerGroups([]).isEmpty)
        }
    }
}

/// The tab that asked a pop-up's question, recording what its host was told to open.
@MainActor
private final class RecordingTabHost: TabHost {
    var opened: [(url: String, disposition: String, sender: Tab.LoadSender)] = []
    var hostWindow: NSWindow? { nil }
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition, by sender: Tab.LoadSender) {
        opened.append((url.absoluteString, "\(disposition)", sender))
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
