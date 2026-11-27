import Foundation
import Testing
import WebKit
@testable import Zigzag

/// The ways a web app hands over a file it made or asked its server for, each loaded in a real tab and saved to a
/// folder of the test's own (#535). Chrome and Safari save every one of these, under the name the page gave.
@MainActor
@Suite(.serialized)
struct PageDownloadsTests {
    nonisolated private static let docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    nonisolated private static let page = """
    <!doctype html><title>page</title><body><script>
    const docx = '\(docx)';
    function anchor(href, name) { const a = document.createElement('a'); a.href = href; a.download = name; return a; }
    function wait(ms) { return new Promise(done => setTimeout(done, ms)); }
    const cases = {
      revokedBlob() {
        const url = URL.createObjectURL(new Blob(['revoked'], { type: docx }));
        const a = anchor(url, 'revoked.docx');
        document.body.append(a); a.click(); URL.revokeObjectURL(url); a.remove();
      },
      dataURL() {
        const a = anchor('data:text/csv;base64,' + btoa('data'), 'data.csv');
        document.body.append(a); a.click(); a.remove();
      },
      detachedAnchor() {
        const url = URL.createObjectURL(new Blob(['detached'], { type: 'text/plain' }));
        anchor(url, 'detached.txt').click();
        setTimeout(() => URL.revokeObjectURL(url), 40000);
      },
      openBlob() {
        window.open(URL.createObjectURL(new Blob(['opened'], { type: 'application/octet-stream' })));
      },
      async frameAfterExport(origin) {
        await wait(1500);
        const frame = document.createElement('iframe');
        frame.style = 'width:0;height:0;border:0';
        frame.src = origin + '/attachment/export.docx';
        document.body.append(frame);
      },
      async fetchedBlob() {
        await wait(1500);
        const blob = await (await fetch('/bytes')).blob();
        const url = URL.createObjectURL(blob);
        const a = anchor(url, 'fetched.docx');
        document.body.append(a); a.click(); URL.revokeObjectURL(url);
      },
      formPost() {
        const form = document.createElement('form');
        form.method = 'post'; form.action = '/attachment/posted.docx';
        document.body.append(form); form.submit();
      },
      crossOrigin(origin) {
        const a = anchor(origin + '/plain', 'cross.txt');
        document.body.append(a); a.click();
      },
    };
    const run = new URLSearchParams(location.search).get('run');
    if (run) addEventListener('load', () => setTimeout(() => cases[run](new URLSearchParams(location.search).get('origin')), 1200));
    </script>
    """

    nonisolated private static func respond(method: String, path: String) -> LocalPageServer.Reply? {
        if path.hasPrefix("/attachment/") {
            let name = String(path.dropFirst("/attachment/".count))
            return LocalPageServer.Reply(headers: ["Content-Type": docx, "Content-Disposition": "attachment; filename=\"\(name)\""],
                                         body: Data("attachment \(name)".utf8))
        }
        switch path {
        case "/bytes": return LocalPageServer.Reply(headers: ["Content-Type": docx], body: Data("fetched".utf8))
        case "/plain": return LocalPageServer.Reply(headers: ["Content-Type": "text/plain"], body: Data("plain".utf8))
        default: return .html(page)
        }
    }

    /// A tab on the test page with its downloads going to a folder of this test's own, never Downloads.
    private final class Setup {
        let server: LocalPageServer
        let site: URL
        /// The same server on another origin.
        let otherSite: URL
        let folder: URL
        let host = WindowlessHost()

        init() async throws {
            server = try LocalPageServer(PageDownloadsTests.respond)
            site = try await server.start()
            otherSite = URL(string: site.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"))!
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("PageDownloads-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            DownloadManager.folder = folder
            DownloadManager.asksWhereToSave = false
        }

        func tab(_ query: String = "") async throws -> Tab {
            let tab = Tab(url: nil, spaceID: UUID())
            tab.host = host
            host.tabs.append(tab)
            let address = URL(string: site.absoluteString + "/page" + query)!
            tab.load(address)
            let page = tab.ensureWebView()
            for _ in 0..<100 where page.isLoading || page.title != "page" { try await Task.sleep(for: .milliseconds(50)) }
            #expect(page.title == "page")
            return tab
        }

        /// Runs a case as if clicked: WebKit counts a script Zigzag runs as the person's gesture.
        func click(_ name: String, in tab: Tab) async throws {
            _ = try await tab.ensureWebView().callAsyncJavaScript("await cases[name](origin)", arguments: ["name": name, "origin": otherSite.absoluteString],
                                                                  contentWorld: .page)
        }

        /// The file's contents once it's saved, or nil after a while.
        func saved(_ name: String, seconds: Double = 8) async throws -> String? {
            let file = folder.appendingPathComponent(name)
            for _ in 0..<Int(seconds * 20) {
                if let data = try? Data(contentsOf: file), !data.isEmpty { return String(decoding: data, as: UTF8.self) }
                try await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }

        var savedNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }

        func end() {
            host.tabs.forEach { $0.close() }
            server.stop()
            DownloadManager.folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func aBlobRevokedRightAfterItsClickSaves() async throws {
        let setup = try await Setup()
        defer { setup.end() }
        try await setup.click("revokedBlob", in: setup.tab())
        #expect(try await setup.saved("revoked.docx") == "revoked")
    }

    @Test func aDataAddressSavesUnderItsName() async throws {
        let setup = try await Setup()
        defer { setup.end() }
        try await setup.click("dataURL", in: setup.tab())
        #expect(try await setup.saved("data.csv") == "data")
    }

    @Test func anAnchorNeverAddedToThePageSaves() async throws {
        let setup = try await Setup()
        defer { setup.end() }
        try await setup.click("detachedAnchor", in: setup.tab())
        #expect(try await setup.saved("detached.txt") == "detached")
    }

    @Test func aBlobOpenedInANewWindowSaves() async throws {
        let setup = try await Setup()
        defer { setup.end() }
        try await setup.click("openBlob", in: setup.tab())
        for _ in 0..<160 where setup.savedNames.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let names = setup.savedNames
        #expect(names.count == 1)
        if let name = names.first { #expect(try await setup.saved(name) == "opened") }
    }

    /// Feishu's export: Export is clicked, the file is made on the server, then a hidden frame on another of the
    /// site's origins is pointed at it, long after the click.
    @Test func aHiddenFrameHandingOverAnExportSaves() async throws {
        let setup = try await Setup()
        defer { setup.end() }
        try await setup.click("frameAfterExport", in: setup.tab())
        #expect(try await setup.saved("export.docx") == "attachment export.docx")
    }

    /// One export with no click at all saves; the next waits for a click or key in the page, which a second export
    /// from the menu has.
    @Test func aHiddenFrameNobodyClickedForSavesOnceThenAfterAClick() async throws {
        let setup = try await Setup()
        defer { setup.end() }
        let tab = try await setup.tab("?run=frameAfterExport&origin=\(setup.otherSite.absoluteString)")
        #expect(try await setup.saved("export.docx") == "attachment export.docx")
        try await setup.click("frameAfterExport", in: tab)
        #expect(try await setup.saved("export 2.docx", seconds: 3) == nil)
        PopupNotice.noteInput(in: tab.ensureWebView())
        try await setup.click("frameAfterExport", in: tab)
        #expect(try await setup.saved("export 2.docx") == "attachment export.docx")
    }

    /// Site answers in a suite of the test's own, with Ask before a site downloads files set to `asking`.
    private func withSiteAnswers(asking: Bool, _ body: () async throws -> Void) async throws {
        let suite = "PageDownloadsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removeScratchSuite(suite)
        }
        SitePermissions.asksBeforeDownloads = asking
        try await body()
    }

    /// With Ask before a site downloads files on and nobody's answer kept, a hidden frame's export asks, naming the
    /// page's site, instead of saving unasked. With no window to ask in, it isn't saved.
    @Test func aHiddenFrameAsksWhenAskingIsOn() async throws {
        try await withSiteAnswers(asking: true) {
            let setup = try await Setup()
            defer { setup.end() }
            let page = try #require(SiteOrigin.of(setup.site)), frame = try #require(SiteOrigin.of(setup.otherSite))
            try await setup.click("frameAfterExport", in: setup.tab())
            #expect(try await setup.saved("export.docx", seconds: 4) == nil)
            #expect(SitePermissions.hasAsked(.downloads, origin: page))
            #expect(!SitePermissions.hasAsked(.downloads, origin: frame))
            // The page's site allowed: the export saves.
            SitePermissions.remember("allow", subject: PermissionSubject.downloads, origin: page)
            try await setup.click("frameAfterExport", in: setup.tab())
            #expect(try await setup.saved("export.docx") == "attachment export.docx")
        }
    }

    /// A Block kept for the frame's site or for the page's refuses a frame's file, with asking off too.
    @Test func aBlockForTheFramesSiteOrThePagesStopsAFramesFile() async throws {
        for asking in [false, true] {
            try await withSiteAnswers(asking: asking) {
                let setup = try await Setup()
                defer { setup.end() }
                let page = try #require(SiteOrigin.of(setup.site)), frame = try #require(SiteOrigin.of(setup.otherSite))
                SitePermissions.remember("allow", subject: PermissionSubject.downloads, origin: page)
                SitePermissions.remember("deny", subject: PermissionSubject.downloads, origin: frame)
                try await setup.click("frameAfterExport", in: setup.tab())
                #expect(try await setup.saved("export.docx", seconds: 4) == nil, "frame's site blocked, asking \(asking)")
                SitePermissions.remember(nil, subject: PermissionSubject.downloads, origin: frame)
                SitePermissions.remember("deny", subject: PermissionSubject.downloads, origin: page)
                try await setup.click("frameAfterExport", in: setup.tab())
                #expect(try await setup.saved("export.docx", seconds: 4) == nil, "page's site blocked, asking \(asking)")
                #expect(setup.savedNames.isEmpty)
            }
        }
    }

    @Test func aFetchedBlobClickedAfterAnAwaitSaves() async throws {
        let setup = try await Setup()
        defer { setup.end() }
        _ = try await setup.tab("?run=fetchedBlob")
        #expect(try await setup.saved("fetched.docx") == "fetched")
    }

    @Test func aFormPostAnsweredWithAnAttachmentSaves() async throws {
        let setup = try await Setup()
        defer { setup.end() }
        try await setup.click("formPost", in: setup.tab())
        #expect(try await setup.saved("posted.docx") == "attachment posted.docx")
    }

    /// The download attribute only names same-origin files; another origin's link opens, as in Chrome and Safari.
    @Test func anotherOriginsDownloadLinkOpens() async throws {
        let setup = try await Setup()
        defer { setup.end() }
        let tab = try await setup.tab()
        try await setup.click("crossOrigin", in: tab)
        let page = tab.ensureWebView()
        for _ in 0..<100 where page.url?.path != "/plain" || page.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        #expect(page.url?.host() == "localhost")
        #expect(page.url?.path == "/plain")
        #expect(setup.savedNames.isEmpty)
    }
}

/// A browser window with no window: a page's new window becomes a tab of its own, as a click would make one.
@MainActor
private final class WindowlessHost: TabHost {
    var tabs: [Tab] = []
    var hostWindow: NSWindow? { nil }
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition, by sender: Tab.LoadSender) {}
    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
             features: WKWindowFeatures) -> WKWebView? {
        let made = Tab(url: nil, spaceID: tab.spaceID, configuration: configuration)
        made.host = self
        tabs.append(made)
        return made.ensureWebView()
    }
    func tabDidRequestClose(_ tab: Tab) {}
    func tabWantsToReturnToOpener(_ tab: Tab) {}
    func tab(_ tab: Tab, hoveringLink url: URL?) {}
    func tabWantsToBeShown(_ tab: Tab) {}
}
