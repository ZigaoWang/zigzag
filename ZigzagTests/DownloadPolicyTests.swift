import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A site's name for a file never reads as another kind of file once saved.
struct DownloadNameTests {
    @Test func invisibleMarksAreTakenOut() {
        // A right-to-left override would show "invoice\u{202E}fdp.exe" as "invoiceexe.pdf".
        #expect(DownloadManager.safeFilename("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        #expect(DownloadManager.safeFilename("re\u{200B}port\u{2066}.pdf\u{2069}\u{FEFF}") == "report.pdf")
        #expect(DownloadManager.safeFilename("a\u{200F}b\u{061C}c\u{200E}.txt") == "abc.txt")
        #expect(DownloadManager.safeFilename("two\nlines\t.txt") == "twolines.txt")
        // Separators, a leading dot that would hide it, and nothing left at all.
        #expect(DownloadManager.safeFilename("../etc/passwd") == "-etc-passwd")
        #expect(DownloadManager.safeFilename("a:b.txt") == "a-b.txt")
        #expect(DownloadManager.safeFilename(".hidden") == "hidden")
        #expect(DownloadManager.safeFilename("\u{202E}") == "Download")
        // Names in any language stay as they are.
        #expect(DownloadManager.safeFilename("报告 2026.pdf") == "报告 2026.pdf")
        #expect(DownloadManager.safeFilename("café.png") == "café.png")
        #expect(DownloadManager.uniqueDestination(for: "x\u{202E}gpj.exe").lastPathComponent.hasPrefix("xgpj"))
    }
}

/// One policy for what tabs and pop-up windows show or save: an attachment is saved, never shown as the site's page,
/// and downloads nobody clicked for can't come in a stream.
@MainActor
struct DownloadPolicyTests {
    @Test func anAttachmentIsSavedNotShown() {
        let policy = DownloadPolicy()
        _ = policy.decide(shouldDownload: false, clicked: true, isMainFrame: true)
        // An upload a site serves as a page, sent as an attachment with its name: saved, in a pop-up as in a tab.
        #expect(policy.decide(mimeType: "text/html", contentDisposition: "attachment; filename=\"page.html\"", canShowMIMEType: true, isMainFrame: true) == .download)
        // Without a name too: never shown as the site's own page.
        #expect(policy.decide(mimeType: "text/html", contentDisposition: "attachment", canShowMIMEType: true, isMainFrame: true) == .download)
        #expect(DownloadPolicy.downloads(mimeType: "text/html", contentDisposition: " Attachment ", canShowMIMEType: true))
        #expect(policy.decide(mimeType: "image/svg+xml", contentDisposition: "Attachment", canShowMIMEType: true, isMainFrame: true) == .download)
        // A page is shown, and so is anything WebKit can show that isn't an attachment.
        #expect(policy.decide(mimeType: "text/html", contentDisposition: nil, canShowMIMEType: true, isMainFrame: true) == .allow)
        #expect(policy.decide(mimeType: "text/html", contentDisposition: "inline", canShowMIMEType: true, isMainFrame: true) == .allow)
        #expect(policy.decide(mimeType: "text/html", contentDisposition: nil, canShowMIMEType: false, isMainFrame: true) == .allow)
        #expect(policy.decide(mimeType: "image/png", contentDisposition: nil, canShowMIMEType: true, isMainFrame: true) == .allow)
        // What WebKit can't show is saved.
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
        // A script's download: once, then not again for half a minute.
        #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true, now: now) == .download)
        #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true, now: now.addingTimeInterval(1)) == .cancel)
        // A response that downloads because it can't be shown counts the same, when nobody clicked for it.
        #expect(policy.decide(mimeType: "application/zip", contentDisposition: nil, canShowMIMEType: false, isMainFrame: true, now: now.addingTimeInterval(2)) == .cancel)
        // A click always saves.
        #expect(policy.decide(shouldDownload: true, clicked: true, isMainFrame: true, now: now.addingTimeInterval(3)) == .download)
        #expect(policy.decide(mimeType: "application/zip", contentDisposition: nil, canShowMIMEType: false, isMainFrame: true, now: now.addingTimeInterval(3)) == .download)
        // Not a download at all: decided as usual.
        #expect(policy.decide(shouldDownload: false, clicked: false, isMainFrame: true, now: now.addingTimeInterval(4)) == nil)
        #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true, now: now.addingTimeInterval(DownloadPolicy.scriptDownloadGap + 2)) == .download)
    }

    /// A file the page goes to because you sent it there saves, however soon after another: the address you pasted
    /// that redirects to a CDN, the "your download starts in 5 seconds" page you clicked through to.
    @Test func whereYouSentThePageAlwaysSaves() {
        let policy = DownloadPolicy()
        let now = Date()
        let zip = { (at: TimeInterval) in
            policy.decide(mimeType: "application/zip", contentDisposition: nil, canShowMIMEType: false, isMainFrame: true, now: now.addingTimeInterval(at))
        }
        // A script's download a moment ago.
        #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true, now: now) == .download)
        // Your pasted address, and the redirect on its way (WebKit's decision for it isn't a click).
        _ = policy.decide(shouldDownload: false, clicked: true, isMainFrame: true, now: now.addingTimeInterval(1))
        _ = policy.decide(shouldDownload: false, clicked: false, isMainFrame: true, now: now.addingTimeInterval(1.2))
        #expect(zip(1.5) == .download)
        // You clicked a download link; its page sends itself to the file a few seconds later, on its own.
        _ = policy.decide(shouldDownload: false, clicked: true, isMainFrame: true, now: now.addingTimeInterval(2))
        _ = policy.decide(shouldDownload: false, clicked: false, isMainFrame: true, now: now.addingTimeInterval(7))
        #expect(zip(7.5) == .download)
        // Again for the next file.
        _ = policy.decide(shouldDownload: false, clicked: true, isMainFrame: true, now: now.addingTimeInterval(9))
        _ = policy.decide(shouldDownload: false, clicked: false, isMainFrame: true, now: now.addingTimeInterval(14))
        #expect(zip(14.5) == .download)
        // With nothing from you in between, the page going to file after file is held back.
        _ = policy.decide(shouldDownload: false, clicked: false, isMainFrame: true, now: now.addingTimeInterval(16))
        #expect(zip(16.5) == .cancel)
        #expect(policy.decide(shouldDownload: true, clicked: false, isMainFrame: true, now: now.addingTimeInterval(17)) == .cancel)
    }

    /// The first download a pop-up's page starts on its own, straight to a file, saves.
    @Test func aPopUpGoingStraightToAFileSaves() {
        let policy = DownloadPolicy()
        _ = policy.decide(shouldDownload: false, clicked: false, isMainFrame: true)
        #expect(policy.decide(mimeType: "application/octet-stream", contentDisposition: "attachment; filename=a.dmg", canShowMIMEType: false, isMainFrame: true) == .download)
    }

    /// A refused download's notice offers to ask for the file again only where it can be asked for: a plain GET. A
    /// file a form sent can't be re-made from here — the page would have to send it again — so that notice just says
    /// what happened, and nothing to ask with is nothing to offer.
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
}
