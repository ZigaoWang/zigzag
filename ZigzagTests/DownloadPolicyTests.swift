import Foundation
import Testing
import WebKit
@testable import Zigzag

/// One policy for what tabs and pop-up windows show or save: an attachment is saved, never shown as the site's page,
/// and downloads nobody clicked for can't come in a stream.
@MainActor
struct DownloadPolicyTests {
    @Test func anAttachmentIsSavedNotShown() {
        let policy = DownloadPolicy()
        _ = policy.decide(shouldDownload: false, clicked: true, isMainFrame: true)
        // An upload a site serves as a page, sent as an attachment with its name: saved, in a pop-up as in a tab.
        #expect(policy.decide(mimeType: "text/html", contentDisposition: "attachment; filename=\"page.html\"", canShowMIMEType: true, isMainFrame: true) == .download)
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
}
