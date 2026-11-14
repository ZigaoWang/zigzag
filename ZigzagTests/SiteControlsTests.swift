import AppKit
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
            // WebRTC is never Ask: with nothing kept, it follows its setting.
            for permission in SitePermission.allCases where permission.choices.contains(.ask) { #expect(SitePermissions.choice(permission, origin: site) == .ask) }
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
                // WebRTC has no Ask: forgotten, it's what the setting says (off: allowed).
                #expect(SitePermissions.choice(permission, origin: site) == (permission == .webRTC ? .allow : .ask))
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

    /// The page tells the panel when its height changes: the details came, or another certificate of the chain was
    /// chosen, whose details can be longer (#220).
    @MainActor @Test func choosingAnotherCertificateResizesThePanel() throws {
        let page = CertificatePage()
        var resized = 0
        page.onResize = { resized += 1 }
        let empty = page.height(for: 300, pad: 16)
        page.details = CertificateDetails.from(try trust(anchored: true))
        #expect(resized == 1)
        let site = page.height(for: 300, pad: 16)
        #expect(site > empty)
        page.debugChoose(1)
        #expect(resized == 2)
        #expect((page.debugState["chain"] as? [String])?.last?.hasSuffix(" *") == true)
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
        // The connection is a line under the site's name (#221), not a row into a page.
        #expect(SitePanelRows.links(Context()).isEmpty)
    }

    /// Extensions are on the first page itself (#215), not behind a row; whether they run here is a switch of This
    /// Site, once there are some, on a web page outside a private window.
    @Test func extensionsSwitchOnceThereAreSome() {
        var c = Context()
        #expect(!SitePanelRows.rows(c).contains(.extensions))
        c.hasExtensions = true
        #expect(SitePanelRows.rows(c) == [.zoom, .adBlocking, .darkPage, .keepAwake, .extensions])
        var privately = c
        privately.isPrivate = true
        privately.extensionHost = false
        #expect(!SitePanelRows.rows(privately).contains(.extensions))
        var extensionPage = c
        extensionPage.isWeb = false
        #expect(!SitePanelRows.rows(extensionPage).contains(.extensions))
    }

    @Test func rowsThatApplyOnlySomewhere() {
        var c = Context()
        c.fullScreen = true
        c.foreignLanguage = true
        #expect(SitePanelRows.rows(c) == [.zoom, .adBlocking, .darkPage, .keepAwake, .fullScreenFills, .alwaysTranslate])
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

    /// Developer Mode (#198): only in the ⋯ menu, never a row of This Site, whatever else the page has.
    @Test func developerModeIsNoRow() {
        var c = Context()
        c.fullScreen = true
        c.foreignLanguage = true
        #expect(SitePanelRows.rows(c) == [.zoom, .adBlocking, .darkPage, .keepAwake, .fullScreenFills, .alwaysTranslate])
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
        #expect(SitePanelRows.links(c).isEmpty)
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
        #expect(SitePanelRows.links(c).isEmpty)
    }

    /// Dark page is one dropdown (#134): Automatic, On, Off and Force, in that order, and no row of its own for Force.
    @Test func darkPageIsOneDropdown() {
        #expect(DarkPages.SiteChoice.allCases == [.automatic, .on, .off, .force])
        #expect(DarkPages.SiteChoice.allCases.map(SitePanel.title(of:)) == ["Automatic", "On", "Off", "Force Dark"])
        #expect(SitePanelRows.rows(Context()).filter { $0 == .darkPage }.count == 1)
    }

    /// Under Dark page, what it does here now: Automatic says whether Settings has it on, Force that it's always
    /// dark, and On and Off nothing more, unless the site is dark on its own or the developer tools chose its look.
    @Test func darkPageSaysWhatItDoesNow() {
        typealias S = SitePanel.DarkStatus
        #expect(S.of(.automatic, wanted: true, native: false, developerLook: false) == .nowOn)
        #expect(S.of(.automatic, wanted: false, native: true, developerLook: false) == .nowOff)
        #expect(S.of(.automatic, wanted: true, native: true, developerLook: false) == .darkAlready)
        #expect(S.of(.on, wanted: true, native: false, developerLook: false) == .none)
        #expect(S.of(.on, wanted: true, native: true, developerLook: false) == .darkAlready)
        #expect(S.of(.off, wanted: false, native: true, developerLook: false) == .none)
        #expect(S.of(.force, wanted: true, native: true, developerLook: false) == .alwaysDark)
        #expect(S.of(.force, wanted: true, native: false, developerLook: true) == .developerTools)
        #expect(S.none.text == nil && S.nowOn.text == "Now on")
    }

    @Test func permissionsOnlyOnceAsked() {
        var c = Context()
        #expect(!SitePanelRows.links(c).contains(.permissions))
        c.hasPermissions = true
        #expect(SitePanelRows.links(c) == [.permissions])
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

/// How tall Site Controls gets, and when a page scrolls under its header (#220).
struct SitePanelSizingTests {
    @Test func aPageThatFitsDoesntScroll() {
        let fit = SitePanelSizing.fit(band: 52, body: 300, maxHeight: 700)
        #expect(fit.height == 352)
        #expect(fit.viewport == 300)
        #expect(!fit.scrolls)
    }

    /// The certificate's details past the window's bottom: the panel stops there, the header keeps its band, and the
    /// rest scrolls under it.
    @Test func aTallPageScrollsUnderItsHeader() {
        let fit = SitePanelSizing.fit(band: 52, body: 640, maxHeight: 500)
        #expect(fit.height == 500)
        #expect(fit.viewport == 448)
        #expect(fit.scrolls)
        // The first page has no header to keep: all of it scrolls.
        let main = SitePanelSizing.fit(band: 0, body: 640, maxHeight: 500)
        #expect(main.viewport == 500 && main.scrolls)
    }

    @Test func theRoomIsDownToTheWindowsBottom() {
        // A full-screen window, a small one, and one too short for anything: a few rows at least.
        #expect(SitePanelSizing.maxHeight(overlayHeight: 1_000, top: 90) == 1_000 - 90 - Tokens.Metric.cardInset)
        #expect(SitePanelSizing.maxHeight(overlayHeight: 500, top: 90) == 500 - 90 - Tokens.Metric.cardInset)
        #expect(SitePanelSizing.maxHeight(overlayHeight: 120, top: 90) == PanelLinkRow.height * 4)
        // A window made shorter while the panel is open gives it less room, never more than there is.
        let tall = SitePanelSizing.maxHeight(overlayHeight: 900, top: 90)
        let short = SitePanelSizing.maxHeight(overlayHeight: 600, top: 90)
        #expect(SitePanelSizing.fit(band: 52, body: 700, maxHeight: tall).height > SitePanelSizing.fit(band: 52, body: 700, maxHeight: short).height)
    }

    @Test func theHeaderKeepsItsBand() {
        #expect(SitePanelSizing.headerBand(pad: 16, header: 24) == 16 + 24 + Tokens.Space.x3)
    }
}

/// The connection under the site's name (#221): a small line, the way into the certificate only where there is one.
@MainActor
struct ConnectionLineTests {
    @Test func secureOpensTheCertificate() {
        var opened = false
        let line = ConnectionLine("Secure connection", warns: false, opens: true) { opened = true }
        #expect(line.isEnabled)
        #expect(line.accessibilityRole() == .button)
        #expect(line.accessibilityValue() as? String == "Secure connection")
        #expect(line.debugText == "Secure connection >")
        _ = line.accessibilityPerformPress()
        #expect(opened)
    }

    @Test func plainHTTPOnlySaysSo() {
        let line = ConnectionLine(SitePanel.notSecure, warns: true, opens: false) {}
        #expect(!line.isEnabled)
        #expect(line.accessibilityRole() == .staticText)
        #expect(line.debugText == "Not secure (warns)")
        // Narrower without its chevron: as wide as its words, never the whole header.
        let opening = ConnectionLine(SitePanel.notSecure, warns: true, opens: true) {}
        #expect(opening.fittingWidth > line.fittingWidth)
        #expect(line.fittingWidth < 120)
    }
}
