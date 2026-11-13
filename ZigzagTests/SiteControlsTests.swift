import Foundation
import Security
import Testing
@testable import Zigzag

/// Site Controls (#174): a permission's Ask, Allow or Block, its row only once the site asked; the zoom stepper; the
/// certificate chain read from a trust; and which of This Site's rows show where.
@MainActor
@Suite(.serialized)
struct SiteControlsPermissionTests {
    private let site = "https://meet.example.com"

    private func withDefaults(_ body: () throws -> Void) throws {
        let suite = "zigzag-site-controls-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        SitePermissions.forgetAsked()
        defer {
            SitePermissions.defaults = before
            SitePermissions.forgetAsked()
            defaults.removePersistentDomain(forName: suite)
        }
        try body()
    }

    @Test func choiceFromTheAnswersKept() {
        #expect(PermissionChoice(answers: []) == .ask)
        #expect(PermissionChoice(answers: [true, true]) == .allow)
        #expect(PermissionChoice(answers: [false]) == .block)
        // One no among yeses: blocked, as a camera allowed with the microphone blocked can't take a call.
        #expect(PermissionChoice(answers: [true, false]) == .block)
        #expect(PermissionChoice.ask.allowed == nil)
        #expect(PermissionChoice.allow.allowed == true)
        #expect(PermissionChoice.block.allowed == false)
    }

    @Test func noRowUntilTheSiteAsks() throws {
        try withDefaults {
            #expect(SitePermissions.shown(origin: site, isPrivate: false).isEmpty)
            SitePermissions.noteAsked(.location, origin: site, isPrivate: false)
            #expect(SitePermissions.shown(origin: site, isPrivate: false) == [.location])
            // Asked and not answered: Ask.
            #expect(SitePermissions.choice(.location, origin: site) == .ask)
            // Another origin on the same host has its own.
            #expect(SitePermissions.shown(origin: "http://meet.example.com", isPrivate: false).isEmpty)
        }
    }

    @Test func aPrivateWindowNotesNothing() throws {
        try withDefaults {
            SitePermissions.noteAsked(.cameraAndMicrophone, origin: site, isPrivate: true)
            SitePermissions.noteAsked(.location, origin: nil, isPrivate: false)
            #expect(SitePermissions.shown(origin: site, isPrivate: false).isEmpty)
        }
    }

    @Test func aSavedAnswerHasARow() throws {
        try withDefaults {
            SitePermissions.setNotifications(true, origin: site)
            SitePermissions.remember(false, origin: site, type: .camera)
            #expect(SitePermissions.shown(origin: site, isPrivate: false) == [.cameraAndMicrophone, .notifications])
            #expect(SitePermissions.choice(.notifications, origin: site) == .allow)
            #expect(SitePermissions.choice(.cameraAndMicrophone, origin: site) == .block)
            // A private window has no notifications or pop-ups to offer.
            #expect(SitePermissions.shown(origin: site, isPrivate: true) == [.cameraAndMicrophone])
        }
    }

    /// Ask means ask every time (#174): an answer given to the question holds for that page only, nothing is kept
    /// for the site, and the next page asks again.
    @Test func aQuestionsAnswerHoldsForThePageOnly() throws {
        try withDefaults {
            let tab = Tab(url: URL(string: site), title: "Meet", spaceID: UUID())
            tab.permissionAnswers.note(true, key: site, kind: "notifications")
            tab.permissionAnswers.note(true, key: site, kind: "cameraAndMicrophone")
            tab.permissionAnswers.note(false, key: site, kind: "location")
            #expect(SitePermissions.notifications(origin: site, tab: tab) == true)
            // A camera-only question takes the answer given to a call's camera and microphone.
            #expect(tab.permissionAnswers.answer(key: site, kind: "camera") == true)
            #expect(tab.permissionAnswers.answer(key: site, kind: "location") == false)
            // Nothing kept for the site: it's still Ask, and another tab on it asks.
            #expect(SitePermissions.choices(origin: site).isEmpty)
            for permission in SitePermission.allCases { #expect(SitePermissions.choice(permission, origin: site) == .ask) }
            let other = Tab(url: URL(string: site), title: "Meet", spaceID: UUID())
            #expect(SitePermissions.notifications(origin: site, tab: other) == nil)
            // Another origin's question on the same page has its own answer.
            #expect(tab.permissionAnswers.answer(key: "http://meet.example.com", kind: "camera") == nil)
            // The next page load forgets them.
            tab.permissionAnswers.forget()
            #expect(tab.permissionAnswers.isEmpty)
            #expect(SitePermissions.notifications(origin: site, tab: tab) == nil)
        }
    }

    /// Allow or Block kept for the site wins over an answer given on the page.
    @Test func aKeptChoiceComesBeforeThePagesAnswer() throws {
        try withDefaults {
            let tab = Tab(url: URL(string: site), title: "Meet", spaceID: UUID())
            tab.permissionAnswers.note(true, key: site, kind: "notifications")
            SitePermissions.setChoice(.block, for: .notifications, origin: site)
            #expect(SitePermissions.notifications(origin: site, tab: tab) == false)
            SitePermissions.setChoice(.ask, for: .notifications, origin: site)
            #expect(SitePermissions.notifications(origin: site, tab: tab) == true)
        }
    }

    @Test func allowAndBlockAreKeptAndAskForgets() throws {
        try withDefaults {
            for permission in SitePermission.allCases {
                SitePermissions.setChoice(.allow, for: permission, origin: site)
                #expect(SitePermissions.choice(permission, origin: site) == .allow)
                SitePermissions.setChoice(.block, for: permission, origin: site)
                #expect(SitePermissions.choice(permission, origin: site) == .block)
                SitePermissions.setChoice(.ask, for: permission, origin: site)
                #expect(SitePermissions.choice(permission, origin: site) == .ask)
                #expect(!SitePermissions.hasDecision(permission, origin: site))
            }
            #expect(SitePermissions.choices(origin: site).isEmpty)
        }
    }

    /// The existing questions read what Site Controls keeps: a camera-only question takes the answer chosen for both.
    @Test func cameraAndMicrophoneChoiceAnswersEachQuestion() throws {
        try withDefaults {
            SitePermissions.remember(false, origin: site, type: .microphone)
            SitePermissions.setChoice(.allow, for: .cameraAndMicrophone, origin: site)
            #expect(SitePermissions.decision(origin: site, type: .camera) == true)
            #expect(SitePermissions.decision(origin: site, type: .microphone) == true)
            #expect(SitePermissions.decision(origin: site, type: .cameraAndMicrophone) == true)
            // One key for the site's own answer, not three.
            #expect(SitePermissions.choices(origin: site) == ["cameraAndMicrophone": true])
            SitePermissions.setChoice(.block, for: .cameraAndMicrophone, origin: site)
            #expect(SitePermissions.decision(origin: site, type: .camera) == false)
            #expect(SitePermissions.mediaDecisions(origin: site) == [false])
        }
    }

    @Test func popupsAndNotificationsReadTheChoice() throws {
        try withDefaults {
            SitePermissions.setChoice(.allow, for: .popups, origin: site)
            #expect(SitePermissions.popups(origin: site))
            SitePermissions.setChoice(.block, for: .popups, origin: site)
            #expect(!SitePermissions.popups(origin: site))
            #expect(SitePermissions.choice(.popups, origin: site) == .block)
            SitePermissions.setChoice(.block, for: .notifications, origin: site)
            #expect(SitePermissions.notifications(origin: site) == false)
            #expect(SitePermissions.notificationDecisions[site] == false)
        }
    }

    /// A frame from elsewhere that answered on the page follows the page's choice, and stays its own key there.
    @Test func embeddedFramesFollowTheSitesChoice() throws {
        try withDefaults {
            let key = try #require(SitePermissions.answerKey(frame: "https://call.example.net", page: site))
            SitePermissions.remember(false, origin: key, type: .cameraAndMicrophone)
            #expect(SitePermissions.shown(origin: site, isPrivate: false) == [.cameraAndMicrophone])
            SitePermissions.setChoice(.allow, for: .cameraAndMicrophone, origin: site)
            #expect(SitePermissions.decision(origin: key, type: .cameraAndMicrophone) == true)
            SitePermissions.setChoice(.ask, for: .cameraAndMicrophone, origin: site)
            #expect(SitePermissions.decision(origin: key, type: .cameraAndMicrophone) == nil)
        }
    }

    /// Open apps is a permission like the others (#192): no row until the site asks, Always Open on its question
    /// lets in that one app, and Allow or Block chosen for the site covers every app.
    @Test func openAppsIsAPermission() throws {
        try withDefaults {
            #expect(SitePermissions.appDecision(origin: site, scheme: "itms-apps") == nil)
            SitePermissions.noteAsked(.apps, origin: site, isPrivate: false)
            #expect(SitePermissions.shown(origin: site, isPrivate: false) == [.apps])
            #expect(SitePermissions.choice(.apps, origin: site) == .ask)
            // A private window asks too, so it has the row.
            #expect(SitePermissions.shown(origin: site, isPrivate: true) == [.apps])

            SitePermissions.allowOpeningApp(origin: site, scheme: "zoommtg")
            #expect(SitePermissions.opensApp(origin: site, scheme: "zoommtg"))
            #expect(SitePermissions.appDecision(origin: site, scheme: "itms-apps") == nil)
            #expect(SitePermissions.choice(.apps, origin: site) == .allow)

            SitePermissions.setChoice(.block, for: .apps, origin: site)
            #expect(SitePermissions.appDecision(origin: site, scheme: "zoommtg") == false)
            #expect(SitePermissions.appDecision(origin: site, scheme: "itms-apps") == false)
            // One key for the site, the app it was told Always Open to gone.
            #expect(SitePermissions.choices(origin: site) == ["apps": false])

            SitePermissions.setChoice(.allow, for: .apps, origin: site)
            #expect(SitePermissions.opensApp(origin: site, scheme: "itms-apps"))
            SitePermissions.setChoice(.ask, for: .apps, origin: site)
            #expect(SitePermissions.appDecision(origin: site, scheme: "zoommtg") == nil)
            #expect(!SitePermissions.hasDecision(.apps, origin: site))
            // Another origin on the host has its own.
            SitePermissions.setChoice(.allow, for: .apps, origin: "http://meet.example.com")
            #expect(SitePermissions.appDecision(origin: site, scheme: "zoommtg") == nil)
        }
    }

    /// A frame from another site on the page is held back by the page's Block, and never let in by its Allow.
    @Test func aFrameFromElsewhereOnlyFollowsBlock() throws {
        try withDefaults {
            SitePermissions.setChoice(.allow, for: .apps, origin: site)
            #expect(ExternalLinks.decision(page: site, scheme: "zoommtg", foreign: false) == true)
            #expect(ExternalLinks.decision(page: site, scheme: "zoommtg", foreign: true) == nil)
            SitePermissions.setChoice(.block, for: .apps, origin: site)
            #expect(ExternalLinks.decision(page: site, scheme: "zoommtg", foreign: true) == false)
            #expect(ExternalLinks.decision(page: nil, scheme: "zoommtg", foreign: false) == nil)
        }
    }

    @Test func resetReturnsTheSiteToNoRows() throws {
        try withDefaults {
            let other = "https://other.example.com"
            SitePermissions.noteAsked(.popups, origin: site, isPrivate: false)
            SitePermissions.setChoice(.allow, for: .location, origin: site)
            SitePermissions.allowOpeningApp(origin: site, scheme: "zoommtg")
            SitePermissions.setChoice(.block, for: .location, origin: other)
            SitePermissions.noteAsked(.notifications, origin: other, isPrivate: false)
            SitePermissions.reset(origin: site)
            #expect(SitePermissions.shown(origin: site, isPrivate: false).isEmpty)
            #expect(SitePermissions.choices(origin: site).isEmpty)
            // Only that site.
            #expect(SitePermissions.shown(origin: other, isPrivate: false) == [.location, .notifications])
        }
    }
}

@MainActor
struct ZoomStepperTests {
    @Test func stepsInAndOutThroughTheLevels() {
        #expect(ZoomLevels.step(1, by: 1) == 1.1)
        #expect(ZoomLevels.step(1, by: -1) == 0.9)
        #expect(ZoomLevels.step(1.25, by: 1) == 1.5)
        #expect(ZoomLevels.step(0.67, by: -1) == 0.5)
    }

    /// A zoom between steps (a pinch, an old level) goes to the next step that way, never past it.
    @Test func betweenStepsGoesToTheNearestThatWay() {
        #expect(ZoomLevels.step(1.05, by: 1) == 1.1)
        #expect(ZoomLevels.step(1.05, by: -1) == 1)
        #expect(ZoomLevels.step(1.0004, by: 1) == 1.1)
    }

    @Test func staysAtEitherEnd() {
        #expect(ZoomLevels.step(3, by: 1) == 3)
        #expect(ZoomLevels.step(0.5, by: -1) == 0.5)
        #expect(!ZoomLevels.canStep(3, by: 1))
        #expect(!ZoomLevels.canStep(0.5, by: -1))
        #expect(ZoomLevels.canStep(3, by: -1))
        #expect(ZoomLevels.canStep(0.5, by: 1))
        #expect(ZoomLevels.canStep(4, by: -1))
    }

    @Test func readsAsAPercentage() {
        #expect(ZoomLevels.percent(1) == "100%")
        #expect(ZoomLevels.percent(0.67) == "67%")
        #expect(ZoomLevels.percent(1.25) == "125%")
    }

    @Test func percentageResetsTo100() {
        let stepper = ZoomStepper()
        var changes: [CGFloat] = []
        stepper.onChange = { changes.append($0) }
        stepper.zoom = 1.5
        stepper.debugPress("in")
        stepper.debugPress("out")
        stepper.debugPress("reset")
        // Already at 100%: nothing more to do.
        stepper.debugPress("reset")
        #expect(changes == [1.75, 1.5, 1])
        #expect(stepper.zoom == 1)
    }
}

/// A test root (EC P-256) and a site certificate it issued (RSA 2048) for test.zigzag.example, valid 1 Jan 2026 to
/// 25 Jan 2027, made with openssl for these tests only.
struct CertificateDetailsTests {
    private static let root = """
    MIIByDCCAW+gAwIBAgIUVqi6sNZQny5uK/LlDK+NoqyjT4owCgYIKoZIzj0EAwIwMjEZMBcGA1UEAwwQWmlnemFnIFRlc3QgUm9v\
    dDEVMBMGA1UECgwMWmlnemFnIFRlc3RzMB4XDTI2MTExMjExNDcxNloXDTQ2MTEwNzExNDcxNlowMjEZMBcGA1UEAwwQWmlnemFn\
    IFRlc3QgUm9vdDEVMBMGA1UECgwMWmlnemFnIFRlc3RzMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEQ/qouNpk5G0ruX0CTtlY\
    Zi9/ct1PUyZ54rPbqfMXjSbC7uXZf9vqx/+HWnXYFnmy3EvUAMjiLqvKovtiZBM5tKNjMGEwHQYDVR0OBBYEFJ51l1XFav0TH9Kx\
    asdr5O6X46GWMB8GA1UdIwQYMBaAFJ51l1XFav0TH9Kxasdr5O6X46GWMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEG\
    MAoGCCqGSM49BAMCA0cAMEQCIALjyqTgVKH86O/rjV24CTa5SII2q4nb3RngntNeke69AiApJsmOqXe83KaFTE7VpcZHi7QbrR0b\
    y7uSldNmk0ZfiQ==
    """

    private static let leaf = """
    MIICtTCCAlygAwIBAgICA+kwCgYIKoZIzj0EAwIwMjEZMBcGA1UEAwwQWmlnemFnIFRlc3QgUm9vdDEVMBMGA1UECgwMWmlnemFn\
    IFRlc3RzMB4XDTI2MDEwMTAwMDAwMFoXDTI3MDEyNTAwMDAwMFowNTEcMBoGA1UEAwwTdGVzdC56aWd6YWcuZXhhbXBsZTEVMBMG\
    A1UECgwMWmlnemFnIFRlc3RzMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsb/tgFwExed8QFJN+mpiitHd/iF6UW2S\
    HYiOy4GN+s7jb9jL2Q/sZnD09gMlqKio7lfhfczq3uFgcnu8QY7jnszKQXFl4CZI3hd66G1feb3jkpgreEObNm0zLJNLLLoRW/xK\
    xNCVnDs4jNxo7VRIWY6vsg1BVNLyX7g/Qx50+pfS8lc4fH4LLUA8MqOKaxqJqF39BYJNC6TwPhp9UcqlDPpn9Du9ueI/QgaWrII1\
    5DWj88izYDAvOThyi2ycwZgDlDQ2q6an7sTcUMxqwUMxbXU7gZxyUQ2Hopd95kIK6rgk/16YmSl87044mvTXuJC1O3JGs6Ql/el+\
    3N9ed17jKQIDAQABo4GTMIGQMAkGA1UdEwQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMB4GA1UdEQQX\
    MBWCE3Rlc3QuemlnemFnLmV4YW1wbGUwHQYDVR0OBBYEFO7LINwl8pUz0bI4Vkb9R4p7fZdCMB8GA1UdIwQYMBaAFJ51l1XFav0T\
    H9Kxasdr5O6X46GWMAoGCCqGSM49BAMCA0cAMEQCIACN08T8xuHJ1xQniOy//UtYVTR1jY0ixzi3KYG5fsrnAiBcHK0tG5esjxVp\
    YV7+of499SMBj4oM9v+m7StoKzHEnQ==
    """

    private func certificate(_ base64: String) throws -> SecCertificate {
        let der = try #require(Data(base64Encoded: base64))
        return try #require(SecCertificateCreateWithData(nil, der as CFData))
    }

    private func trust(anchored: Bool) throws -> SecTrust {
        let certificates = [try certificate(Self.leaf), try certificate(Self.root)]
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, "test.zigzag.example" as CFString)
        #expect(SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess)
        let made = try #require(trust)
        // Inside both certificates' dates, whenever the tests run.
        SecTrustSetVerifyDate(made, Date(timeIntervalSince1970: 1_796_000_000) as CFDate)
        SecTrustSetNetworkFetchAllowed(made, false)
        if anchored {
            SecTrustSetAnchorCertificates(made, [try certificate(Self.root)] as CFArray)
            SecTrustSetAnchorCertificatesOnly(made, true)
        }
        return made
    }

    @Test func summarizesTheSiteCertificate() throws {
        let leaf = CertificateDetails.summary(try certificate(Self.leaf))
        #expect(leaf.name == "test.zigzag.example")
        #expect(leaf.organization == "Zigzag Tests")
        #expect(leaf.issuer == "Zigzag Test Root")
        #expect(leaf.keyType == "RSA")
        #expect(leaf.keyBits == 2048)
        #expect(!leaf.isSelfSigned)
        #expect(leaf.sha256 == "AB:92:2E:68:C3:72:58:F9:3E:68:53:62:93:93:A9:92:AA:F3:61:92:10:6B:20:F5:80:35:81:5E:9F:E5:19:80")
        #expect(leaf.validFrom == ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        #expect(leaf.validUntil == ISO8601DateFormatter().date(from: "2027-01-25T00:00:00Z"))
    }

    @Test func summarizesTheRoot() throws {
        let root = CertificateDetails.summary(try certificate(Self.root))
        #expect(root.name == "Zigzag Test Root")
        #expect(root.issuer == "Zigzag Test Root")
        #expect(root.keyType == "EC")
        #expect(root.keyBits == 256)
        #expect(root.isSelfSigned)
    }

    @Test func readsTheChainFromATrust() throws {
        let details = CertificateDetails.from(try trust(anchored: true))
        #expect(details.isTrusted)
        #expect(details.failure == nil)
        #expect(details.chain.map(\.name) == ["test.zigzag.example", "Zigzag Test Root"])
        #expect(details.role(at: 0) == .site)
        #expect(details.role(at: 1) == .root)
    }

    @Test func anUntrustedChainSaysWhy() throws {
        let details = CertificateDetails.from(try trust(anchored: false))
        #expect(!details.isTrusted)
        #expect(details.failure?.isEmpty == false)
    }

    @Test func rolesAlongTheChain() {
        #expect(CertificateDetails.role(at: 0, count: 3, selfSigned: false) == .site)
        #expect(CertificateDetails.role(at: 1, count: 3, selfSigned: false) == .intermediate)
        #expect(CertificateDetails.role(at: 2, count: 3, selfSigned: true) == .root)
        // A chain that stops short of its root ends on an intermediate.
        #expect(CertificateDetails.role(at: 1, count: 2, selfSigned: false) == .intermediate)
        // A site that signed its own certificate is still the site.
        #expect(CertificateDetails.role(at: 0, count: 1, selfSigned: true) == .site)
    }
}

@MainActor
struct SitePanelRowsTests {
    private typealias Context = SitePanelRows.Context

    @Test func anOrdinaryPage() {
        #expect(SitePanelRows.rows(Context()) == [.zoom, .adBlocking, .darkPage, .keepAwake])
        #expect(SitePanelRows.links(Context()) == [.connection, .extensions])
    }

    @Test func rowsThatApplyOnlySomewhere() {
        var c = Context()
        c.forceDarkOffered = true
        c.fullScreen = true
        c.foreignLanguage = true
        #expect(SitePanelRows.rows(c) == [.zoom, .adBlocking, .darkPage, .forceDark, .keepAwake, .fullScreenFills, .alwaysTranslate])
    }

    /// Cookie banners (#175): there once a pop-up was found or a choice kept, under Ad blocking; never in a private
    /// window, nor on an extension's own page.
    @Test func cookieBannersOnceFoundOrChosen() {
        var c = Context()
        #expect(!SitePanelRows.rows(c).contains(.cookieBanners))
        c.cookieBanners = true
        #expect(SitePanelRows.rows(c) == [.zoom, .adBlocking, .cookieBanners, .darkPage, .keepAwake])
        // Apart from ad blocking: there with ad blocking off too.
        c.adBlocking = false
        #expect(SitePanelRows.rows(c) == [.zoom, .cookieBanners, .darkPage, .keepAwake])
        var privately = c
        privately.isPrivate = true
        #expect(!SitePanelRows.rows(privately).contains(.cookieBanners))
        var extensionPage = c
        extensionPage.isWeb = false
        #expect(!SitePanelRows.rows(extensionPage).contains(.cookieBanners))
    }

    @Test func noZoomOverReaderOrAPDF() {
        var c = Context()
        c.coveredPage = true
        #expect(!SitePanelRows.rows(c).contains(.zoom))
    }

    @Test func aPrivateWindowKeepsNothingForTheSite() {
        var c = Context()
        c.isPrivate = true
        c.siteChoices = false
        c.extensionHost = false
        #expect(SitePanelRows.rows(c) == [.zoom])
        #expect(SitePanelRows.links(c) == [.connection])
    }

    @Test func adBlockingOffInSettings() {
        var c = Context()
        c.adBlocking = false
        #expect(!SitePanelRows.rows(c).contains(.adBlocking))
    }

    @Test func anExtensionsOwnPage() {
        var c = Context()
        c.isWeb = false
        c.siteChoices = false
        #expect(SitePanelRows.rows(c).isEmpty)
        // No connection to judge.
        #expect(SitePanelRows.links(c) == [.extensions])
    }

    /// Force dark sits under Dark page, and only with it.
    @Test func forceDarkOnlyWithDarkPage() {
        var c = Context()
        c.siteChoices = false
        c.forceDarkOffered = true
        #expect(!SitePanelRows.rows(c).contains(.forceDark))
    }

    @Test func permissionsOnlyOnceAsked() {
        var c = Context()
        #expect(!SitePanelRows.links(c).contains(.permissions))
        c.hasPermissions = true
        #expect(SitePanelRows.links(c) == [.connection, .permissions, .extensions])
    }

    @Test func permissionsSayWhatWasChosen() {
        #expect(PermissionChoice.summary([.allow, .allow]) == "2 allowed")
        #expect(PermissionChoice.summary([.block]) == "1 blocked")
        #expect(PermissionChoice.summary([.allow, .block, .ask]) == "1 allowed, 1 blocked")
        #expect(PermissionChoice.summary([.ask]) == "Ask")
        #expect(PermissionChoice.shortSummary([.allow, .block, .ask]) == "2 set")
        #expect(PermissionChoice.shortSummary([.ask]) == "Ask")
    }
}
