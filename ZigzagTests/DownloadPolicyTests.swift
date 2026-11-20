import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Download names can't disguise their file type.
struct DownloadNameTests {
    @Test func invisibleMarksAreTakenOut() {
        // An RTL override would show "invoice\u{202E}fdp.exe" as "invoiceexe.pdf".
        #expect(DownloadManager.safeFilename("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        #expect(DownloadManager.safeFilename("re\u{200B}port\u{2066}.pdf\u{2069}\u{FEFF}") == "report.pdf")
        #expect(DownloadManager.safeFilename("a\u{200F}b\u{061C}c\u{200E}.txt") == "abc.txt")
        #expect(DownloadManager.safeFilename("two\nlines\t.txt") == "twolines.txt")
        // Separators, hiding leading dots, empty names.
        #expect(DownloadManager.safeFilename("../etc/passwd") == "-etc-passwd")
        #expect(DownloadManager.safeFilename("a:b.txt") == "a-b.txt")
        #expect(DownloadManager.safeFilename(".hidden") == "hidden")
        #expect(DownloadManager.safeFilename("\u{202E}") == "Download")
        // Non-Latin names are kept.
        #expect(DownloadManager.safeFilename("报告 2026.pdf") == "报告 2026.pdf")
        #expect(DownloadManager.safeFilename("café.png") == "café.png")
        #expect(DownloadManager.uniqueDestination(for: "x\u{202E}gpj.exe").lastPathComponent.hasPrefix("xgpj"))
    }
}

/// Tab and popup download policy: attachments are saved, never shown; unrequested downloads can't stream in.
@MainActor
struct DownloadPolicyTests {
    @Test func anAttachmentIsSavedNotShown() {
        let policy = DownloadPolicy()
        _ = policy.decide(shouldDownload: false, clicked: true, isMainFrame: true)
        // An HTML attachment with a filename is saved, in popups and tabs.
        #expect(policy.decide(mimeType: "text/html", contentDisposition: "attachment; filename=\"page.html\"", canShowMIMEType: true, isMainFrame: true) == .download)
        // Without a filename too.
        #expect(policy.decide(mimeType: "text/html", contentDisposition: "attachment", canShowMIMEType: true, isMainFrame: true) == .download)
        #expect(DownloadPolicy.downloads(mimeType: "text/html", contentDisposition: " Attachment ", canShowMIMEType: true))
        #expect(policy.decide(mimeType: "image/svg+xml", contentDisposition: "Attachment", canShowMIMEType: true, isMainFrame: true) == .download)
        // Pages, and anything else WebKit can show without an attachment header, are shown.
        #expect(policy.decide(mimeType: "text/html", contentDisposition: nil, canShowMIMEType: true, isMainFrame: true) == .allow)
        #expect(policy.decide(mimeType: "text/html", contentDisposition: "inline", canShowMIMEType: true, isMainFrame: true) == .allow)
        #expect(policy.decide(mimeType: "text/html", contentDisposition: nil, canShowMIMEType: false, isMainFrame: true) == .allow)
        #expect(policy.decide(mimeType: "image/png", contentDisposition: nil, canShowMIMEType: true, isMainFrame: true) == .allow)
        // Unshowable types are saved.
        #expect(policy.decide(mimeType: "application/zip", contentDisposition: nil, canShowMIMEType: false, isMainFrame: true) == .download)
    }

    @Test func aFrameSavesOnlyJustAfterAClick() {
        let policy = DownloadPolicy()
        let now = Date()
        #expect(policy.decide(mimeType: "application/zip", contentDisposition: nil, canShowMIMEType: false, isMainFrame: false, now: now) == .cancel)
        _ = policy.decide(shouldDownload: false, clicked: true, isMainFrame: false, now: now)
        #expect(policy.decide(mimeType: "application/zip", contentDisposition: nil, canShowMIMEType: false, isMainFrame: false, now: now.addingTimeInterval(2)) == .download)
        #expect(policy.decide(mimeType: "application/zip", contentDisposition: nil, canShowMIMEType: false, isMainFrame: false,
                              now: now.addingTimeInterval(DownloadPolicy.frameClickWindow + 1)) == .cancel)
    }

    @Test func downloadsNobodyClickedForDontComeInAStream() {
        let policy = DownloadPolicy()
        let now = Date()
        // An unclicked script download: once, then blocked for 30 seconds.
        #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true, now: now) == .download)
        #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true, now: now.addingTimeInterval(1)) == .cancel)
        // An unshowable response without a click counts the same.
        #expect(policy.decide(mimeType: "application/zip", contentDisposition: nil, canShowMIMEType: false, isMainFrame: true, now: now.addingTimeInterval(2)) == .cancel)
        #expect(policy.decide(shouldDownload: true, clicked: true, isMainFrame: true, now: now.addingTimeInterval(3)) == .download)
        #expect(policy.decide(mimeType: "application/zip", contentDisposition: nil, canShowMIMEType: false, isMainFrame: true, now: now.addingTimeInterval(3)) == .download)
        // Not a download: decided as usual.
        #expect(policy.decide(shouldDownload: false, clicked: false, isMainFrame: true, now: now.addingTimeInterval(4)) == nil)
        #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true, now: now.addingTimeInterval(DownloadPolicy.scriptDownloadGap + 2)) == .download)
    }

    /// Navigations you started always save, even right after another (a pasted URL redirecting to a CDN, a "download starts in 5 seconds" page).
    @Test func whereYouSentThePageAlwaysSaves() {
        let policy = DownloadPolicy()
        let now = Date()
        let zip = { (at: TimeInterval) in
            policy.decide(mimeType: "application/zip", contentDisposition: nil, canShowMIMEType: false, isMainFrame: true, now: now.addingTimeInterval(at))
        }
        // An unclicked script download just before.
        #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true, now: now) == .download)
        // The pasted address and its redirect (WebKit doesn't mark the redirect as a click).
        _ = policy.decide(shouldDownload: false, clicked: true, isMainFrame: true, now: now.addingTimeInterval(1))
        _ = policy.decide(shouldDownload: false, clicked: false, isMainFrame: true, now: now.addingTimeInterval(1.2))
        #expect(zip(1.5) == .download)
        // A clicked download page that navigates to the file a few seconds later.
        _ = policy.decide(shouldDownload: false, clicked: true, isMainFrame: true, now: now.addingTimeInterval(2))
        _ = policy.decide(shouldDownload: false, clicked: false, isMainFrame: true, now: now.addingTimeInterval(7))
        #expect(zip(7.5) == .download)
        _ = policy.decide(shouldDownload: false, clicked: true, isMainFrame: true, now: now.addingTimeInterval(9))
        _ = policy.decide(shouldDownload: false, clicked: false, isMainFrame: true, now: now.addingTimeInterval(14))
        #expect(zip(14.5) == .download)
        // Without user input in between, repeated file navigations are held back.
        _ = policy.decide(shouldDownload: false, clicked: false, isMainFrame: true, now: now.addingTimeInterval(16))
        #expect(zip(16.5) == .cancel)
        #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true, now: now.addingTimeInterval(17)) == .cancel)
    }

    /// A popup's first unprompted download saves.
    @Test func aPopUpGoingStraightToAFileSaves() {
        let policy = DownloadPolicy()
        _ = policy.decide(shouldDownload: false, clicked: false, isMainFrame: true)
        #expect(policy.decide(mimeType: "application/octet-stream", contentDisposition: "attachment; filename=a.dmg", canShowMIMEType: false, isMainFrame: true) == .download)
    }

    /// A refused download offers retry only for a plain GET; a form POST can't be resent from here.
    @Test func onlyAPlainGETIsAskedForAgain() {
        #expect(DownloadPolicy.canBeAskedAgain(URLRequest(url: URL(string: "https://files.example/a.dmg")!)))
        var get = URLRequest(url: URL(string: "https://files.example/a.dmg")!)
        get.httpMethod = "GET"
        #expect(DownloadPolicy.canBeAskedAgain(get))

        var posted = URLRequest(url: URL(string: "https://files.example/report")!)
        posted.httpMethod = "POST"
        posted.httpBody = Data("kind=zip".utf8)
        #expect(!DownloadPolicy.canBeAskedAgain(posted))
        var postWithNoBody = URLRequest(url: URL(string: "https://files.example/report")!)
        postWithNoBody.httpMethod = "POST"
        #expect(!DownloadPolicy.canBeAskedAgain(postWithNoBody))

        #expect(!DownloadPolicy.canBeAskedAgain(nil))
    }
    /// Firefox's Add to Firefox hands over an `.xpi`: an install, not a file to keep.
    @Test func firefoxPackagesAreInstalledNotSaved() {
        // AMO's own type, with or without a filename that says so.
        #expect(DownloadPolicy.isExtensionPackage(mimeType: "application/x-xpinstall", filename: "addon.xpi"))
        #expect(DownloadPolicy.isExtensionPackage(mimeType: "application/x-xpinstall; charset=binary", filename: "download"))
        #expect(DownloadPolicy.isExtensionPackage(mimeType: "Application/X-XPInstall", filename: "Download"))
        // A package served as a plain file still names itself.
        #expect(DownloadPolicy.isExtensionPackage(mimeType: "application/octet-stream", filename: "ublock_origin-1.60.0.xpi"))
        #expect(DownloadPolicy.isExtensionPackage(mimeType: nil, filename: "ADDON.XPI"))
        // A zip that happens to mention .xpi, a page, and a normal download are not packages.
        #expect(!DownloadPolicy.isExtensionPackage(mimeType: "application/zip", filename: "addon.xpi.zip"))
        #expect(!DownloadPolicy.isExtensionPackage(mimeType: "text/html", filename: "xpi.html"))
        #expect(!DownloadPolicy.isExtensionPackage(mimeType: nil, filename: "Download"))
        #expect(!DownloadPolicy.isExtensionPackage(mimeType: "application/x-xpinstall-backup", filename: "notes.txt"))
    }

}
