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

    /// Async variant.
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

    /// Reset all clears both stores, including destinations.
    @Test func forgetAllClearsBothStores() throws {
        try withDefaults { defaults in
            SitePermissions.remember("deny", subject: PermissionSubject.location, origin: "https://example.com")
            SitePermissions.remember("mini", subject: PermissionSubject.popups, origin: "https://example.com")
            SitePermissions.forgetAll()
            #expect(defaults.dictionary(forKey: "SitePermissions") == nil)
            #expect(defaults.dictionary(forKey: "SitePermissionActions") == nil)
            #expect(SitePermissions.action(PermissionSubject.location, origin: "https://example.com") == nil)
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == nil)
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

    /// "This time" holds for the asking page; private tabs keep nothing even if the caller doesn't say private.
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

    // MARK: Downloads: whether a site may save files at all

    /// Asking before downloads is off by default, like Chrome and Arc.
    @Test func askingBeforeADownloadIsOffByDefault() throws {
        #expect(!SitePermissions.asksBeforeDownloadsByDefault)
        try withDefaults { _ in
            #expect(!SitePermissions.asksBeforeDownloads)
        }
    }

    /// With asking off, unanswered sites download as before; a stored Block still wins, and turning asking on asks again.
    @Test func aTurnedOffSettingAnswersYesWithoutAsking() async throws {
        try await withDefaultsAsync {
            SitePermissions.asksBeforeDownloads = false
            #expect(SitePermissions.downloads(origin: "https://files.example") == nil)
            #expect(await SitePermissions.downloadsAllowed(origin: "https://files.example", window: nil, isPrivate: false, tab: nil))

            // Asking on asks again regardless of the default.
            SitePermissions.asksBeforeDownloads = true
            #expect(await !SitePermissions.downloadsAllowed(origin: "https://files.example", window: nil, isPrivate: false, tab: nil))
        }
    }

    /// A page without a site (about:blank popup) downloads as before with asking off; with it on it's refused. Local files always save.
    @Test func aPageWithoutASiteSavesAsBeforeWithAskingOff() throws {
        try withDefaults { _ in
            SitePermissions.asksBeforeDownloads = false
            #expect(SitePermissions.pageWithoutSiteMayDownload(isFile: false))
            #expect(SitePermissions.pageWithoutSiteMayDownload(isFile: true))
            SitePermissions.asksBeforeDownloads = true
            #expect(!SitePermissions.pageWithoutSiteMayDownload(isFile: false))
            #expect(SitePermissions.pageWithoutSiteMayDownload(isFile: true))
        }
    }

    /// Asking on: the first download asks and the Allow is kept, so the next one doesn't.
    @Test func askingOnceKeepsTheAnswerForTheSite() async throws {
        try await withDefaultsAsync {
            let origin = "https://files.example"
            SitePermissions.asksBeforeDownloads = true
            #expect(SitePermissions.asksBeforeDownloads)
            #expect(SitePermissions.downloads(origin: origin) == nil)
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "allow", remember: true),
                                               subject: PermissionSubject.downloads, origin: origin,
                                               tab: nil, isPrivate: false)
            #expect(SitePermissions.downloads(origin: origin) == true)
            #expect(await SitePermissions.downloadsAllowed(origin: origin, window: nil, isPrivate: false, tab: nil))
        }
    }

    /// A stored site Block, or a page "This time" block, refuses even with asking off.
    @Test func aStoredBlockWinsWithTheSettingOff() async throws {
        try await withDefaultsAsync {
            SitePermissions.asksBeforeDownloads = false
            SitePermissions.remember("deny", subject: PermissionSubject.downloads, origin: "https://files.example")
            #expect(await !SitePermissions.downloadsAllowed(origin: "https://files.example", window: nil, isPrivate: false, tab: nil))

            let tab = Tab(url: URL(string: "https://page.example"), spaceID: UUID())
            tab.permissionAnswers.note("deny", key: "https://page.example", kind: PermissionSubject.downloads)
            #expect(await !SitePermissions.downloadsAllowed(origin: "https://page.example", window: nil, isPrivate: false, tab: tab))
        }
    }

    /// Page-started downloads go through the flow policy, never the site question; the permission layer allows them without a card unless the site is blocked.
    @MainActor @Test func aPageStartedDownloadNeverAsks() async throws {
        try await withDefaultsAsync {
            for asking in [true, false] {
                SitePermissions.asksBeforeDownloads = asking
                let policy = DownloadPolicy()
                let now = Date()
                #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true, now: now) == .download)
                #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true,
                                      now: now.addingTimeInterval(1)) == .cancel)
            }

            let origin = "https://page.example"
            #expect(await SitePermissions.downloadsAllowed(origin: origin, window: nil, isPrivate: false, tab: nil,
                                                           asking: false))
            SitePermissions.remember("deny", subject: PermissionSubject.downloads, origin: origin)
            #expect(await !SitePermissions.downloadsAllowed(origin: origin, window: nil, isPrivate: false, tab: nil,
                                                            asking: false))
        }
    }

    /// A stored download answer is used without asking.
    @Test func aStoredDownloadAnswerIsUsedWithoutAskingAnything() async throws {
        try await withDefaultsAsync {
            // Asking on: unanswered sites would be refused, so stored answers decide.
            SitePermissions.asksBeforeDownloads = true
            SitePermissions.remember("allow", subject: PermissionSubject.downloads, origin: "https://files.example")
            #expect(SitePermissions.downloads(origin: "https://files.example") == true)
            #expect(await SitePermissions.downloadsAllowed(origin: "https://files.example", window: nil, isPrivate: false, tab: nil))

            SitePermissions.remember("deny", subject: PermissionSubject.downloads, origin: "https://files.example")
            #expect(SitePermissions.downloads(origin: "https://files.example") == false)
            #expect(await !SitePermissions.downloadsAllowed(origin: "https://files.example", window: nil, isPrivate: false, tab: nil))

            // Unanswered with nowhere to ask: refused, not saved silently.
            #expect(SitePermissions.downloads(origin: "https://other.example") == nil)
            #expect(await !SitePermissions.downloadsAllowed(origin: "https://other.example", window: nil, isPrivate: false, tab: nil))
        }
    }

    /// "This time" belongs to the page; another tab is asked.
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

    /// Allow Once on a blocked download's notice is kept for the page, like "This time", never for the site.
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

            // A blocked site stays blocked: one file at a time.
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: "deny", remember: true),
                                               subject: PermissionSubject.downloads, origin: "https://files.example",
                                               tab: nil, isPrivate: false)
            SitePermissions.allowThisDownload(origin: "https://files.example", tab: tab)
            #expect(SitePermissions.downloads(origin: "https://files.example", tab: tab) == false)

            // No page (tab gone): nothing written.
            SitePermissions.remember(nil, subject: PermissionSubject.downloads, origin: "https://files.example")
            SitePermissions.allowThisDownload(origin: "https://files.example", tab: nil)
            #expect(SitePermissions.downloads(origin: "https://files.example") == nil)
        }
    }

    /// "Always" keeps a deny for the site; private windows keep nothing.
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

    /// The question and the Site Controls row write the same answer.
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

    /// The row appears once the site has an answer, in private windows too, with the usual three choices.
    @Test func downloadsAreARowInSiteControlsOnceTheSiteHasAnAnswer() throws {
        #expect(SitePermission.downloads.kinds == ["downloads"])
        #expect(SitePermission.downloads.choices == PermissionChoice.allCases)
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

    /// Private windows ask but never store, even if told to.
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

    /// WebKit's three answers and how each is stored; no, display and window are all keepable now.
    @Test func screenSharingOffersThreeActionsAndKeepsThem() {
        #expect(DisplayCaptureChoice.actions.map(\.id) == ["deny", "screen", "allow"])
        #expect(DisplayCaptureChoice.actions.last?.isProminent == true)
        for choice in DisplayCaptureChoice.allCases {
            #expect(DisplayCaptureChoice(action: choice.action) == choice)
        }
        // A kept "allow" is Share Window… (the default button).
        #expect(DisplayCaptureChoice(action: "allow") == .window)
        #expect(DisplayCaptureChoice(action: "toast") == nil)
    }

    /// Screen-sharing buttons map to WebKit's three answers; nothing else is a yes.
    @Test func screenSharingMapsItsActions() {
        #expect(DisplayCaptureChoice(PermissionAnswer(action: "screen", remember: false)) == .screen)
        #expect(DisplayCaptureChoice(PermissionAnswer(action: "allow", remember: false)) == .window)
        #expect(DisplayCaptureChoice(PermissionAnswer(action: "deny", remember: false)) == .deny)
        #expect(DisplayCaptureChoice(nil) == .deny)
    }

    /// Page answers keep their action, not just yes/no, so a handoff's "browser" isn't asked twice.
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

        // A pre-split combined answer isn't read as either.
        page.note("deny", key: "https://a.com", kind: "cameraAndMicrophone")
        #expect(page.answer(key: "https://a.com", kind: "camera") == nil)
        #expect(page.answer(key: "https://a.com", kind: "microphone") == nil)

        page.forget()
        #expect(page.isEmpty)
        #expect(page.action(key: "https://a.com", kind: kind) == nil)
    }

    /// App answers are kept only for secure pages and never for cross-site frames.
    @Test func anHttpPageCannotRememberAnAppQuestion() {
        #expect(ExternalLinks.canRemember(url: URL(string: "http://example.com"), foreign: false) == false)
        #expect(ExternalLinks.canRemember(url: URL(string: "https://example.com"), foreign: false) == true)
        #expect(ExternalLinks.canRemember(url: URL(string: "https://example.com"), foreign: true) == false)
    }

    /// Stored answers are honored as is; whether one may be written is `saves`, so `verdict` never overrides an http Allow from Site Controls.
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

    /// Every popup value has a destination; unknown ones (an older "allow") use ordinary routing instead of opening nothing.
    @Test func everyPopupValueHasADestination() {
        #expect(PopupNotice.destination(for: "deny") == .deny)
        #expect(PopupNotice.destination(for: "thisTab") == .thisTab)
        #expect(PopupNotice.destination(for: "newTab") == .newTab)
        #expect(PopupNotice.destination(for: "mini") == .viewer)
        #expect(PopupNotice.destination(for: "automatic") == .automatic)
        #expect(PopupNotice.destination(for: "allow") == .automatic)
        #expect(PopupNotice.destination(for: "") == .viewer)
    }

    /// Mini keeps WebKit's offered popup so sign-ins can return results; This Tab and New Tab close it; the ordinary yes keeps it only for real popups.
    @Test func theOfferedPopUpIsKeptForMiniAndDroppedOtherwise() {
        #expect(PopupNotice.heldOutcome(for: "mini", sized: true) == .reveal)
        #expect(PopupNotice.heldOutcome(for: "mini", sized: false) == .reveal)
        #expect(PopupNotice.heldOutcome(for: "automatic", sized: true) == .reveal)
        #expect(PopupNotice.heldOutcome(for: "automatic", sized: false) == .discardAndOpen)
        #expect(PopupNotice.heldOutcome(for: "thisTab", sized: true) == .discardAndOpen)
        #expect(PopupNotice.heldOutcome(for: "newTab", sized: true) == .discardAndOpen)
        #expect(PopupNotice.heldOutcome(for: "deny", sized: true) == .discard)
    }

    /// The diagnostics line for an unclicked pop-up says where it was and whether you had just used a page.
    @Test func anUnclickedPopUpNotesWhereAndYourLastInput() {
        #expect(PopupNotice.unclickedNote(inMini: true, sinceInput: 0.34) == "in Zigzag Mini, a click or key in a page 0.3 s before")
        #expect(PopupNotice.unclickedNote(inMini: false, sinceInput: 12) == "in a window, no click or key in a page for 5 s")
        #expect(PopupNotice.unclickedNote(inMini: false, sinceInput: -1) == "in a window, no click or key in a page for 5 s")
    }

    /// A legacy popup `true` becomes "automatic", not the viewer; other subjects' `true` is "allow".
    @Test func aLegacyPopupYesKeepsTheOrdinaryRouting() throws {
        try withDefaults { defaults in
            defaults.set(["https://example.com|popups": true, "https://example.com|camera": true], forKey: "SitePermissions")
            SitePermissions.migrateAnswersToActions()
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://example.com") == "automatic")
            #expect(SitePermissions.action(PermissionSubject.media(.camera), origin: "https://example.com") == "allow")
        }
    }

    /// Allowing popups stores the routing, so nothing writes a bare "allow" that opens nothing.
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

    /// Site Controls on the unified store: Allow is the ordinary yes (ordinary routing for popups), Block is deny, Ask removes it.
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

    /// This Tab / New Tab popups open through the asking tab's host; Mini and web app windows aren't `BrowserWindowController`s, and casting to one lost their popups. "Don't Allow" opens nothing.
    @Test func aPopUpGoesThroughTheTabThatAskedNotABrowserWindow() {
        let host = QuestionHostStub()
        let recorder = RecordingTabHost()
        let tab = Tab(url: URL(string: "https://example.com/"), spaceID: UUID())
        tab.host = recorder
        let popup = URL(string: "https://example.com/pop-up")!

        PopupNotice.open(popup, action: "thisTab", from: tab, in: host)
        #expect(recorder.opened.first?.tab === tab, "the asking tab, not whichever pane is selected")
        #expect(recorder.opened.map { $0.url } == [popup.absoluteString])
        #expect(recorder.opened.map { $0.disposition } == ["currentTab"])

        recorder.opened.removeAll()
        PopupNotice.open(popup, action: "newTab", from: tab, in: host)
        #expect(recorder.opened.first?.tab === tab)
        #expect(recorder.opened.map { $0.disposition } == ["foregroundTab"])

        recorder.opened.removeAll()
        PopupNotice.open(popup, action: "deny", from: tab, in: host)
        #expect(recorder.opened.isEmpty, "a refused pop-up opens nowhere")
    }

    /// The answer the popup question writes is what the next ask reads, keyed by URL through the same path as `ask`.
    @Test func thePopUpAnswerAskWritesIsTheOneReadBack() {
        let origin = "https://example.com"
        let tab = Tab(url: URL(string: origin + "/"), spaceID: UUID())
        let popup = URL(string: origin + "/pop-up")!
        PopupNotice.remember(PermissionAnswer(action: "mini", remember: false), url: popup, key: origin,
                             tab: tab, isPrivate: false)
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: popup, isPrivate: false) == "mini")
        #expect(tab.permissionAnswers.action(key: origin, kind: PermissionSubject.popups) == nil,
                "the page answer is keyed by the request, not by the bare subject")
    }

    /// A page asking again for the same URL gets its "this time" answer; nothing is read in private windows or without a site.
    @Test func aPagesOwnThisTimePopUpAnswerIsReadBack() {
        let origin = "https://example.com"
        let tab = Tab(url: URL(string: origin + "/"), spaceID: UUID())
        let popup = URL(string: "https://example.com/pop-up")!
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: popup, isPrivate: false) == nil, "nothing answered yet")
        tab.permissionAnswers.note("mini", key: origin, kind: PopupNotice.requestKind(popup))
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: popup, isPrivate: false) == "mini")
        // Page-scoped: another site on it is asked separately.
        #expect(PopupNotice.pageAction(tab: tab, origin: "https://other.com", url: popup, isPrivate: false) == nil)
        // Private windows, pages without a site, or no tab: nothing kept.
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: popup, isPrivate: true) == nil)
        #expect(PopupNotice.pageAction(tab: tab, origin: nil, url: popup, isPrivate: false) == nil)
        #expect(PopupNotice.pageAction(tab: nil, origin: origin, url: popup, isPrivate: false) == nil)
    }

    /// "This time" covers one request; a popup to another URL is a new question.
    @Test func aThisTimePopUpAnswerCoversOneRequest() {
        let origin = "https://example.com"
        let tab = Tab(url: URL(string: origin + "/"), spaceID: UUID())
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!
        tab.permissionAnswers.note("newTab", key: origin, kind: PopupNotice.requestKind(first))
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: first, isPrivate: false) == "newTab")
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: second, isPrivate: false) == nil)
        // The same URL keeps its answer, so a retry doesn't ask.
        #expect(PopupNotice.pageAction(tab: tab, origin: origin, url: first, isPrivate: false) == "newTab")
    }

    /// Only main-frame popups to web URLs or about:blank are asked about; frame, data:, script, file and blob popups are blocked silently.
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

        // Kept destinations route the same: web URLs open, app links ask, the rest go nowhere.
        #expect(PopupNotice.route(URL(string: "https://example.com/x")!, from: nil) == .open)
        #expect(PopupNotice.route(URL(string: "about:blank")!, from: nil) == .open)
        #expect(PopupNotice.route(URL(string: "zoommtg://zoom.us/join")!, from: nil) == .app)
        #expect(PopupNotice.route(URL(string: "data:text/html,<p>hi</p>")!, from: nil) == .refuse)
        #expect(PopupNotice.route(URL(string: "file:///tmp/index.html")!, from: nil) == .refuse)
        #expect(PopupNotice.route(URL(string: "file:///tmp/index.html")!, from: URL(string: "file:///tmp/page.html")) == .open)
    }

    /// `window.open('')` reaches the delegate as a schemeless URL, not nil, so empty or schemeless is about:blank and opens for allowed sites.
    @Test func aBlankPopupIsTheBlankPageNotARefusal() {
        let blank = URL(string: "about:blank")!
        let empty = PopupNotice.popupTarget(nil)
        #expect(empty.url == blank)
        #expect(empty.isBlank)
        let schemeLess = PopupNotice.popupTarget(URL(string: "no-scheme"))
        #expect(schemeLess.url == blank)
        #expect(schemeLess.isBlank)
        let aboutBlank = PopupNotice.popupTarget(blank)
        #expect(aboutBlank.url == blank)
        #expect(aboutBlank.isBlank)

        let named = PopupNotice.popupTarget(URL(string: "https://example.com/x"))
        #expect(named.url == URL(string: "https://example.com/x")!)
        #expect(named.isBlank == false)
        #expect(PopupNotice.route(empty.url, from: nil) == .open)

        // An allowed site's blank popup may open; blank or frame popups can't use This Tab or New Tab, which would navigate without a click.
        #expect(PopupNotice.storedDestinationMayOpen(.automatic, forBlankOrFrame: true))
        #expect(PopupNotice.storedDestinationMayOpen(.viewer, forBlankOrFrame: true))
        #expect(PopupNotice.storedDestinationMayOpen(.thisTab, forBlankOrFrame: true) == false)
        #expect(PopupNotice.storedDestinationMayOpen(.newTab, forBlankOrFrame: true) == false)
        #expect(PopupNotice.storedDestinationMayOpen(.deny, forBlankOrFrame: true) == false)
        #expect(PopupNotice.storedDestinationMayOpen(.thisTab, forBlankOrFrame: false))
        #expect(PopupNotice.storedDestinationMayOpen(.newTab, forBlankOrFrame: false))
    }

    /// The old store stays [String: Bool] for older builds; destinations and handoff choices use a separate key.
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

            // Destinations and handoff choices keep their id under the separate key.
            SitePermissions.remember("mini", subject: PermissionSubject.popups, origin: "https://b.com")
            SitePermissions.remember("handOff", subject: "handoff:\(UUID().uuidString)", origin: "https://b.com")
            #expect(defaults.dictionary(forKey: "SitePermissions") as? [String: Bool] ==
                    ["https://a.com|camera": true, "https://a.com|location": false, "https://a.com|popups": true])
            let actions = try #require(defaults.dictionary(forKey: "SitePermissionActions"))
            #expect(actions["https://b.com|popups"] as? String == "mini")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://b.com") == "mini")
            #expect(SitePermissions.action(PermissionSubject.media(.camera), origin: "https://a.com") == "allow")
            #expect(SitePermissions.action(PermissionSubject.location, origin: "https://a.com") == "deny")
        }
    }

    /// Stores from the first card build, with actions mixed into the Bool store, are split at launch; every action is still read.
    @Test func aMixedStoreIsSplitForOlderBuilds() throws {
        try withDefaults { defaults in
            defaults.set(["https://a.com|camera": true,
                          "https://b.com|popups": "mini",
                          "https://c.com|handoff:1": "browser"], forKey: "SitePermissions")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://b.com") == "mini")
            SitePermissions.migrateAnswersToActions()
            #expect(defaults.dictionary(forKey: "SitePermissions") as? [String: Bool] ==
                    ["https://a.com|camera": true])
            let actions = try #require(defaults.dictionary(forKey: "SitePermissionActions"))
            #expect(actions["https://b.com|popups"] as? String == "mini")
            #expect(actions["https://c.com|handoff:1"] as? String == "browser")
            #expect(SitePermissions.action(PermissionSubject.popups, origin: "https://b.com") == "mini")
        }
    }

    /// A page's "this time" app answer covers one launch; scripted repeats are throttled like questions.
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
        // Other sites aren't throttled by this one.
        let elsewhere = asked.mayOpenAgain("https://meet.example|zoommtg", now: now.addingTimeInterval(1))
        #expect(elsewhere)
    }

    /// Popup questions use the same throttle: no second card right after one, and a dismissed one isn't shown again immediately.
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

    /// Settings › Downloads groups answered sites by answer, in the question's order, omitting empty groups.
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
            // Titles match the question's button labels.
            #expect(groups.map(\.title) == ["Hand Off", "Open in Browser", "Don’t Allow"])
            #expect(SettingsView.handoffAnswerGroups([]).isEmpty)
        }
    }

    /// A kept answer row is titled with the rule, with the answer and site in the detail.
    @Test func aKeptAnswersRowNamesItsRuleAndSite() {
        let row = SettingsView.handoffAnswerRow(ruleNamed: "YouTube", answer: "Hand Off", sites: "youtube.com")
        #expect(row.title == "YouTube")
        #expect(row.detail.contains("Hand Off"))
        #expect(row.detail.contains("youtube.com"))
        // Unnamed rules read as a rule, never an empty row.
        #expect(SettingsView.handoffAnswerRow(ruleNamed: "  ", answer: "Hand Off", sites: "youtube.com").title == "Untitled Rule")
    }
}

/// The tab that asked a popup question, recording what its host was told to open.
@MainActor
private final class RecordingTabHost: TabHost {
    var opened: [(tab: Tab, url: String, disposition: String, sender: Tab.LoadSender)] = []
    var hostWindow: NSWindow? { nil }
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition, by sender: Tab.LoadSender) {
        opened.append((tab, url.absoluteString, "\(disposition)", sender))
    }
    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
             features: WKWindowFeatures) -> WKWebView? { nil }
    func tabDidRequestClose(_ tab: Tab) {}
    func tabWantsToReturnToOpener(_ tab: Tab) {}
    func tab(_ tab: Tab, hoveringLink url: URL?) {}
    func tabWantsToBeShown(_ tab: Tab) {}
}

/// A non-browser window that can show questions; it's untouched for the two tab-routed destinations.
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
