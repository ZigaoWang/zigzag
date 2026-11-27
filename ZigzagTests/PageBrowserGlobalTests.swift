import Foundation
import Network
import Testing
import WebKit
@testable import Zigzag

/// Web pages see no `browser` and no `chrome.runtime`, as in Chrome and Safari, unless an extension lists the site (#551).
@MainActor
struct PageBrowserGlobalTests {
    private static let probe = """
    const frame = frames[0];
    const made = document.body.appendChild(document.createElement('iframe')).contentWindow;
    return [typeof window.browser, typeof (window.chrome && window.chrome.runtime), window.chrome ? Object.keys(window.chrome.runtime).sort().join(',') : '',
            typeof frame.browser, typeof made.browser].join(' ');
    """

    /// `'browser' in window` for the page's first script, now, and the same in its frame.
    private static let named = """
    return [window.early, 'browser' in window, frames[0].early, 'browser' in frames[0]].join(' ');
    """

    @Test func anOrdinaryPageHasNoBrowserWithNoExtensions() async throws {
        let server = try PageTestServer()
        let site = try await server.start()
        defer { server.listener.cancel() }
        let page = try await open(site, controller: WKWebExtensionController(configuration: .nonPersistent()), patterns: [:])
        #expect(try await page.callAsyncJavaScript(Self.probe, contentWorld: .page) as? String == "undefined undefined  undefined undefined")
        #expect(try await page.callAsyncJavaScript(Self.named, contentWorld: .page) as? String == "false false false false")
    }

    @Test func aTabsPageHasNoBrowser() async throws {
        let server = try PageTestServer()
        let site = try await server.start()
        defer { server.listener.cancel() }
        let tab = Tab(url: site, spaceID: UUID())
        defer { tab.close() }
        let page = tab.ensureWebView()
        if page.url == nil { page.load(URLRequest(url: site)) }
        for _ in 0..<100 where page.isLoading || page.title != "page" { try await Task.sleep(for: .milliseconds(50)) }
        // A tab's page starts more worlds after it starts, and WebKit sets `browser` again for each.
        #expect(try await page.callAsyncJavaScript(Self.probe, contentWorld: .page) as? String == "undefined undefined  undefined undefined")
        // No name at all, as in Chrome and Safari: not for the page's first script, nor later, in a frame too.
        #expect(try await page.callAsyncJavaScript(Self.named, contentWorld: .page) as? String == "false false false false")
        // A page's own global of that name still works.
        #expect(try await page.callAsyncJavaScript("window.browser = { mine: 1 }; return window.browser.mine", contentWorld: .page) as? Int == 1)
    }

    @Test func onlyAListedSiteGetsChromesMessagingAndContentScriptsKeepTheirs() async throws {
        let server = try PageTestServer()
        let site = try await server.start()
        defer { server.listener.cancel() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"""
            {"manifest_version":3,"name":"Listed","description":"Listed","version":"1.0","host_permissions":["<all_urls>"],
             "externally_connectable":{"matches":["http://127.0.0.1/*"]},
             "content_scripts":[{"matches":["<all_urls>"],"js":["cs.js"],"run_at":"document_start","all_frames":true}]}
            """#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.cs = typeof browser.runtime.getURL + ' ' + typeof browser.i18n;".utf8)
            .write(to: folder.appendingPathComponent("cs.js"))
        try Data("<!doctype html><title>page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: ext)
        context.setPermissionStatus(.grantedExplicitly, for: .allURLs())
        try controller.load(context)
        defer { try? controller.unload(context) }
        let patterns = [context.uniqueIdentifier: ["http://127.0.0.1/*"]]

        // The listed site: Chrome's sendMessage and connect, and WebKit's own browser.runtime as in Safari.
        let listed = try await open(site, controller: controller, patterns: patterns)
        // A frame the page makes is about:blank, which no extension lists.
        #expect(try await listed.callAsyncJavaScript(Self.probe, contentWorld: .page) as? String
                == "object object connect,lastError,sendMessage object undefined")
        #expect(try await listed.evaluateJavaScript("document.documentElement.dataset.cs") as? String == "function object")
        // Another site: nothing, while the content script there keeps its whole API.
        let other = try #require(URL(string: site.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost")))
        let unlisted = try await open(other, controller: controller, patterns: patterns)
        #expect(try await unlisted.callAsyncJavaScript(Self.probe, contentWorld: .page) as? String == "undefined undefined  undefined undefined")
        #expect(try await unlisted.evaluateJavaScript("document.documentElement.dataset.cs") as? String == "function object")

        // The extension's own page keeps everything.
        let configuration = try #require(context.webViewConfiguration)
        configuration.userContentController.addUserScript(PageScripts.chromeRuntime(matching: patterns))
        let own = WKWebView(frame: .zero, configuration: configuration)
        own.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        for _ in 0..<100 where own.isLoading || own.title != "page" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try await own.evaluateJavaScript("typeof browser.runtime.getURL + ' ' + typeof browser.i18n") as? String == "function object")
    }

    @Test func aSharedSetKeepsOneCopyNamingTheCurrentSites() {
        let controller = WKUserContentController()
        let before = PageScripts.chromeRuntime(matching: [:])
        PageScripts.replaceChromeRuntime(with: before, in: controller)
        PageScripts.replaceChromeRuntime(with: before, in: controller)
        #expect(controller.userScripts.count == 1)
        let after = PageScripts.chromeRuntime(matching: ["abcdefghijklmnopabcdefghijklmnop": ["https://claude.ai/*"]])
        PageScripts.replaceChromeRuntime(with: after, in: controller)
        #expect(controller.userScripts.map(\.source) == [after.source])
    }

    private func open(_ url: URL, controller: WKWebExtensionController, patterns: [String: [String]]) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        configuration.webExtensionController = controller
        PageScripts.replaceChromeRuntime(with: PageScripts.chromeRuntime(matching: patterns), in: configuration.userContentController)
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.load(URLRequest(url: url))
        for _ in 0..<100 where page.isLoading || page.title != "page" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(page.title == "page")
        return page
    }
}

/// Serves a page with a frame on 127.0.0.1.
nonisolated private final class PageTestServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "zigzag.tests.page-browser")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request.components(separatedBy: " ").dropFirst().first ?? "/"
                // The first script of each notes whether it could see a `browser` before anything else ran.
                let early = "<script>window.early = 'browser' in window</script>"
                let body = Data((path == "/frame" ? "<!doctype html>\(early)<title>frame</title>" : "<!doctype html>\(early)<title>page</title><body><iframe src=\"/frame\"></iframe>").utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { done in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    done.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    done.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
}
