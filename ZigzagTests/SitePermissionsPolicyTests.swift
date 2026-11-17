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

    /// Resetting every site clears both halves of the store: a destination kept beside the yeses and nos goes too.
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

    // MARK: Downloads: whether a site may save files at all

    /// Asking is off by default, as Chrome and Arc leave a site's first download alone, and the one place the factory
    /// answer lives says so.
    @Test func askingBeforeADownloadIsOffByDefault() throws {
        #expect(!SitePermissions.asksBeforeDownloadsByDefault)
        try withDefaults { _ in
            #expect(!SitePermissions.asksBeforeDownloads)
        }
    }

    /// Turned off in Settings, a site nobody has answered for saves files as it always did: no card, no refusal. A
    /// stored Block still wins, and asking back on asks again.
    @Test func aTurnedOffSettingAnswersYesWithoutAsking() async throws {
        try await withDefaultsAsync {
            SitePermissions.asksBeforeDownloads = false
            #expect(SitePermissions.downloads(origin: "https://files.example") == nil)
            #expect(await SitePermissions.downloadsAllowed(origin: "https://files.example", window: nil, isPrivate: false, tab: nil))

            // Asking back on asks again, whatever the factory answer is.
            SitePermissions.asksBeforeDownloads = true
            #expect(await !SitePermissions.downloadsAllowed(origin: "https://files.example", window: nil, isPrivate: false, tab: nil))
        }
    }

    /// A page with no site of its own (an about:blank pop-up a site wrote a file into) saves as it always did while
    /// asking is off; only with asking on is it refused, having no site to ask about. A local file always saves.
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

    /// Asking on: the first download asks, and the site's Allow is kept, so the next file is decided without a card.
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

    /// A Block kept for the site still refuses with asking off, and a page's own "This time" block does too.
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

    /// A page-started download is the flow policy's, never the site question's: asking on or off, the first one goes
    /// through and a stream is held back exactly as before. At the permission layer it is allowed without a card, and
    /// a Block kept for the site still refuses it.
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

    /// The downloads question is one answer kept like every other, and never asks once it has one.
    @Test func aStoredDownloadAnswerIsUsedWithoutAskingAnything() async throws {
        try await withDefaultsAsync {
            // Asking on: a site with no answer would be refused, so the stored answers are what decide these.
            SitePermissions.asksBeforeDownloads = true
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
    /// offers the same three choices as every other row.
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

    /// The answer the pop-up question writes is the answer the next ask reads: This time is keyed by the one
    /// address, through the same path `ask` uses, not by a key a test wrote by hand.
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

    /// `window.open('')` reaches the delegate as an address with no scheme, not as nil, so an empty or scheme-less
    /// address is the blank page. An allowed site's blank pop-up is then a web address like any other and opens.
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

        // An allowed site's blank pop-up may open; a frame's or a blank one may not use This Tab or New Tab, since
        // either would move the page without a click.
        #expect(PopupNotice.storedDestinationMayOpen(.automatic, forBlankOrFrame: true))
        #expect(PopupNotice.storedDestinationMayOpen(.viewer, forBlankOrFrame: true))
        #expect(PopupNotice.storedDestinationMayOpen(.thisTab, forBlankOrFrame: true) == false)
        #expect(PopupNotice.storedDestinationMayOpen(.newTab, forBlankOrFrame: true) == false)
        #expect(PopupNotice.storedDestinationMayOpen(.deny, forBlankOrFrame: true) == false)
        #expect(PopupNotice.storedDestinationMayOpen(.thisTab, forBlankOrFrame: false))
        #expect(PopupNotice.storedDestinationMayOpen(.newTab, forBlankOrFrame: false))
    }

    /// The old store stays exactly what an older build reads: a [String: Bool] of plain yeses and nos. A destination
    /// or a handoff's choice keeps its own key beside it, so an action id never makes the Bool store unreadable.
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

            // A destination or a handoff's choice is not a yes or no: it keeps its id, under its own key.
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

    /// A store from the first card build, with action strings mixed into the Bool store, is split on the launch
    /// migration: the old key becomes pure Bool again, and every action is still read.
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

    /// A kept answer's row takes the rule as its subject, as the rule's own row does, and keeps the answer and the site
    /// it was given on in the detail beneath it.
    @Test func aKeptAnswersRowNamesItsRuleAndSite() {
        let row = SettingsView.handoffAnswerRow(ruleNamed: "YouTube", answer: "Hand Off", sites: "youtube.com")
        #expect(row.title == "YouTube")
        #expect(row.detail.contains("Hand Off"))
        #expect(row.detail.contains("youtube.com"))
        // A rule with no name still reads as a rule, never as an empty row.
        #expect(SettingsView.handoffAnswerRow(ruleNamed: "  ", answer: "Hand Off", sites: "youtube.com").title == "Untitled Rule")
    }
}

/// The tab that asked a pop-up's question, recording what its host was told to open.
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
