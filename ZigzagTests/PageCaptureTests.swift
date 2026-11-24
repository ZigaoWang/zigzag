import Foundation
import JavaScriptCore
import Network
import os
import Testing
import WebKit
@testable import Zigzag

/// `chrome.pageCapture.saveAsMHTML` (#488): a tab as one MHTML file, from WebKit's web archive of it.
struct PageCaptureTests {
    // MARK: The archive's parts

    private static func resource(_ url: String, _ type: String, _ text: String, charset: String? = "UTF-8") -> [String: Any] {
        var resource: [String: Any] = ["WebResourceURL": url, "WebResourceMIMEType": type, "WebResourceData": Data(text.utf8)]
        if let charset { resource["WebResourceTextEncodingName"] = charset }
        return resource
    }

    private static func archive(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    /// The page first, then what it loaded, then each frame's page and what that loaded, in the page's order. Parts
    /// with no address or bytes, `data:` parts and a second part at an address already taken stay out.
    @Test func aWebArchiveReadsAsThePagesPartsInOrder() throws {
        let data = try Self.archive([
            "WebMainResource": Self.resource("https://a.example/", "text/html", "<html>page</html>"),
            "WebSubresources": [
                Self.resource("https://a.example/style.css", "text/css", "body{}"),
                Self.resource("data:image/png;base64,AAAA", "image/png", "x"),
                ["WebResourceURL": "https://a.example/no-bytes.png", "WebResourceMIMEType": "image/png"],
                Self.resource("https://a.example/style.css", "text/css", "again"),
            ],
            "WebSubframeArchives": [[
                "WebMainResource": Self.resource("https://a.example/frame", "text/html", "<p>frame</p>"),
                "WebSubresources": [Self.resource("https://a.example/frame.png", "image/png", "png", charset: nil)],
            ]],
        ])
        let parts = try #require(PageArchive.parts(ofWebArchive: data))
        #expect(parts.map(\.url) == ["https://a.example/", "https://a.example/style.css", "https://a.example/frame", "https://a.example/frame.png"])
        #expect(parts[1].data == Data("body{}".utf8), "the first at an address is kept")
        #expect(parts[0].type == "text/html" && parts[0].charset == "UTF-8")
        #expect(parts[3].charset == nil)
        #expect(PageArchive.parts(ofWebArchive: Data("not a plist".utf8)) == nil)
        #expect(PageArchive.parts(ofWebArchive: try Self.archive(["WebSubresources": []])) == nil, "no page")
    }

    /// A frame the caller says no to goes with everything in it, frames inside it too; the page's own parts stay.
    @Test func aFrameLeftOutTakesItsPartsWithIt() throws {
        let data = try Self.archive([
            "WebMainResource": Self.resource("https://a.example/", "text/html", "page"),
            "WebSubresources": [Self.resource("https://cdn.example/logo.png", "image/png", "logo", charset: nil)],
            "WebSubframeArchives": [
                [
                    "WebMainResource": Self.resource("https://bank.example/widget", "text/html", "balance"),
                    "WebSubresources": [Self.resource("https://bank.example/data.json", "application/json", "{}")],
                    "WebSubframeArchives": [["WebMainResource": Self.resource("https://a.example/inner", "text/html", "inner")]],
                ],
                ["WebMainResource": Self.resource("https://a.example/ok", "text/html", "ok")],
            ],
        ])
        let parts = try #require(PageArchive.parts(ofWebArchive: data) { !$0.contains("bank.example") })
        #expect(parts.map(\.url) == ["https://a.example/", "https://cdn.example/logo.png", "https://a.example/ok"])
    }

    /// Scripts stay out, as in Chrome's MHTML; so does a frame with no address of its own, with what's in it.
    /// `frameURLs` lists every frame, frames inside frames too.
    @Test func scriptsAndFramesWithNoAddressStayOut() throws {
        let data = try Self.archive([
            "WebMainResource": Self.resource("https://a.example/", "text/html", "page"),
            "WebSubresources": [
                Self.resource("https://mail.example/config.js", "text/javascript", "var token = 1"),
                Self.resource("https://a.example/app.js", "application/javascript", "run()"),
                Self.resource("https://a.example/style.css", "text/css", "p{}"),
            ],
            "WebSubframeArchives": [
                [
                    "WebMainResource": Self.resource("about:blank", "text/html", "written by script"),
                    "WebSubresources": [Self.resource("https://bank.example/logo.png", "image/png", "png", charset: nil)],
                ],
                [
                    "WebMainResource": Self.resource("https://a.example/frame", "text/html", "frame"),
                    "WebSubframeArchives": [["WebMainResource": Self.resource("https://deep.example/inner", "text/html", "inner")]],
                ],
            ],
        ])
        let parts = try #require(PageArchive.parts(ofWebArchive: data))
        #expect(parts.map(\.url) == ["https://a.example/", "https://a.example/style.css", "https://a.example/frame", "https://deep.example/inner"])
        #expect(PageArchive.frameURLs(ofWebArchive: data) == ["about:blank", "https://a.example/frame", "https://deep.example/inner"])
        #expect(PageArchive.isScript("text/javascript1.5") && PageArchive.isScript("text/x-ecmascript"))
        #expect(PageArchive.isScript("text/javascript") && PageArchive.isScript("application/ecmascript"))
        #expect(!PageArchive.isScript("text/css") && !PageArchive.isScript("application/json"))
    }

    /// Of what a page loaded, only pictures, stylesheets and fonts, from whichever site: the archive keeps what a
    /// server finally answered under the address the page asked for, so a tag (or a redirect) pointing at a router's
    /// page or a site's JSON brings nothing back. Only from the web: not from a file or one of Zigzag's own addresses.
    @Test func onlyPicturesStylesAndFontsGoIn() throws {
        let data = try Self.archive([
            "WebMainResource": Self.resource("https://a.example/", "text/html", "page"),
            "WebSubresources": [
                Self.resource("http://192.168.1.1/status.html", "text/html", "router admin"),
                Self.resource("https://files.corp.example/private.json", "application/json", "{\"salary\": 1}"),
                Self.resource("https://a.example/redirected.css", "text/html", "what a redirect brought back"),
                Self.resource("https://other.example/blob", "application/octet-stream", "bytes", charset: nil),
                Self.resource("https://cdn.example/logo.png", "image/png", "png", charset: nil),
                Self.resource("https://cdn.example/site.css", "text/css", "p{}"),
                Self.resource("https://cdn.example/face.woff2", "font/woff2", "font", charset: nil),
                Self.resource("https://cdn.example/old.woff", "application/font-woff", "font", charset: nil),
                Self.resource("https://a.example/data.json", "application/json", "{}"),
                Self.resource("https://a.example/lib.js", "text/javascript", "run()"),
                Self.resource("zigzag-favicon://a.example/icon.png", "image/png", "icon", charset: nil),
                Self.resource("file:///Users/someone/picture.png", "image/png", "file", charset: nil),
            ],
        ])
        let parts = try #require(PageArchive.parts(ofWebArchive: data))
        #expect(parts.map(\.url) == ["https://a.example/", "https://cdn.example/logo.png", "https://cdn.example/site.css",
                                     "https://cdn.example/face.woff2", "https://cdn.example/old.woff"])
    }

    /// What a page says of a part reaches the file only as a header takes it: a type that isn't one, or a charset
    /// with spaces or line breaks, goes.
    @Test func aPartsTypeAndCharsetAreHeaderTokensOrNothing() throws {
        #expect(PageArchive.mediaType("text/HTML") == "text/html")
        #expect(PageArchive.mediaType("image/svg+xml") == "image/svg+xml")
        for bad in ["text", "text/html\r\nX-Evil: 1", "text/html; charset=x", "/html", "text/", "a/b/c", ""] {
            #expect(PageArchive.mediaType(bad) == nil, "\(bad)")
        }
        #expect(PageArchive.token("UTF-8") == "UTF-8")
        #expect(PageArchive.token("utf-8\r\nX: y") == nil)
        #expect(PageArchive.token("utf 8") == nil)
        let data = try Self.archive([
            "WebMainResource": ["WebResourceURL": "https://a.example/", "WebResourceMIMEType": "text/html\r\nX-Evil: 1",
                                "WebResourceTextEncodingName": "utf-8\r\nX-Evil: 2", "WebResourceData": Data("page".utf8)],
        ])
        let part = try #require(PageArchive.parts(ofWebArchive: data)?.first)
        #expect(part.type == "application/octet-stream" && part.charset == nil)
    }

    // MARK: The MHTML

    /// An MHTML file as a reader sees it: its headers, and each part's headers and decoded bytes.
    private struct Read {
        var headers: [String: String] = [:]
        var parts: [(headers: [String: String], data: Data)] = []
    }

    private static func read(_ mhtml: Data) throws -> Read {
        let text = try #require(String(data: mhtml, encoding: .utf8))
        var read = Read()
        let top = try #require(text.range(of: "\r\n\r\n"))
        func headers(_ block: Substring) -> [String: String] {
            var out: [String: String] = [:]
            var last: String?
            for line in block.components(separatedBy: "\r\n") where !line.isEmpty {
                if line.first == "\t" || line.first == " ", let key = last { out[key, default: ""] += line; continue }
                guard let colon = line.firstIndex(of: ":") else { Issue.record("not a header: \(line)"); continue }
                let key = String(line[..<colon]).lowercased()
                out[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                last = key
            }
            return out
        }
        read.headers = headers(text[..<top.lowerBound])
        let type = read.headers["content-type"] ?? ""
        let boundary = try #require(type.components(separatedBy: "boundary=\"").last?.components(separatedBy: "\"").first)
        let body = text[top.upperBound...]
        let chunks = body.components(separatedBy: "--\(boundary)")
        #expect(chunks.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "--", "closes with the final boundary")
        for chunk in chunks.dropFirst().dropLast() {
            let chunk = chunk.drop { $0 == "\r" || $0 == "\n" }
            let split = try #require(chunk.range(of: "\r\n\r\n"))
            let partHeaders = headers(chunk[..<split.lowerBound])
            #expect(partHeaders["content-transfer-encoding"] == "base64")
            let encoded = chunk[split.upperBound...].replacingOccurrences(of: "\r\n", with: "")
            read.parts.append((partHeaders, try #require(Data(base64Encoded: encoded))))
        }
        return read
    }

    /// multipart/related, the page's type and address at the top, every part's bytes back as they were.
    @Test func theMHTMLHoldsEveryPartAsItWas() throws {
        let png = Data((0..<300).map { UInt8($0 % 256) })
        let parts = [
            PageArchive.Part(url: "https://a.example/", type: "text/html", charset: "UTF-8", data: Data("<html>é</html>".utf8)),
            PageArchive.Part(url: "https://a.example/logo.png", type: "image/png", charset: nil, data: png),
        ]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let read = try Self.read(PageArchive.mhtml(parts, title: "A page", date: date))
        #expect(read.headers["mime-version"] == "1.0")
        #expect(read.headers["snapshot-content-location"] == "https://a.example/")
        #expect(read.headers["subject"] == "A page")
        #expect(read.headers["date"] == "Tue, 14 Nov 2023 22:13:20 +0000")
        #expect(read.headers["content-type"]?.hasPrefix("multipart/related;") == true)
        #expect(read.headers["content-type"]?.contains("type=\"text/html\"") == true)
        #expect(read.parts.count == 2)
        #expect(read.parts[0].headers["content-type"] == "text/html; charset=UTF-8")
        #expect(read.parts[0].headers["content-location"] == "https://a.example/")
        #expect(read.parts[0].data == parts[0].data)
        #expect(read.parts[1].headers["content-type"] == "image/png")
        #expect(read.parts[1].data == png)
    }

    /// A page's title or an address can't add a header of its own; a title that isn't ASCII is an encoded word.
    @Test func thePageCannotWriteHeadersOfItsOwn() throws {
        let parts = [PageArchive.Part(url: "https://a.example/\r\nX-Evil: 1", type: "text/html", charset: nil, data: Data("p".utf8))]
        let read = try Self.read(PageArchive.mhtml(parts, title: "Hi\r\nX-Evil: 2\r\n\r\nbody"))
        #expect(read.headers["x-evil"] == nil)
        #expect(read.parts.first?.headers["x-evil"] == nil)
        #expect(read.headers["subject"]?.contains("\n") == false)
        let encoded = try Self.read(PageArchive.mhtml(parts, title: "Çay & 茶")).headers["subject"]
        #expect(encoded == "=?utf-8?B?\(Data("Çay & 茶".utf8).base64EncodedString())?=")
    }

    /// A real page WebKit archives, served over http: its stylesheet, picture and frame come out as parts, with
    /// their bytes; its script doesn't.
    @MainActor @Test func aRealPageComesOutWithItsStylesheetImageAndFrame() async throws {
        let css = "body { color: rgb(1, 2, 3); }"
        // A 1×1 PNG.
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg=="))
        let server = try PageServer([
            "/index.html": ("text/html; charset=utf-8", Data("""
            <!doctype html><meta charset="utf-8"><title>Çay</title>
            <link rel="stylesheet" href="style.css"><script src="app.js"></script><img src="dot.png">
            <iframe src="frame.html" onload="document.title = 'Çay, ready'"></iframe><p>page</p>
            """.utf8)),
            "/style.css": ("text/css", Data(css.utf8)),
            "/app.js": ("text/javascript", Data("window.ran = true;".utf8)),
            "/dot.png": ("image/png", png),
            "/frame.html": ("text/html", Data("<!doctype html><title>Frame</title><p>inside</p>".utf8)),
        ])
        defer { server.stop() }
        let base = try await server.start()
        let page = base.appendingPathComponent("index.html")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.load(URLRequest(url: page))
        // The frame has loaded once its page says so.
        #expect(await until { webView.title == "Çay, ready" && !webView.isLoading })
        let archive: Data = try await withCheckedThrowingContinuation { done in webView.createWebArchiveData { done.resume(with: $0) } }
        let parts = try #require(PageArchive.parts(ofWebArchive: archive))
        #expect(parts.first?.url == page.absoluteString)
        #expect(parts.first?.type == "text/html")
        let byURL = Dictionary(parts.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byURL[base.appendingPathComponent("style.css").absoluteString]?.data == Data(css.utf8))
        #expect(byURL[base.appendingPathComponent("dot.png").absoluteString]?.data == png)
        #expect(byURL[base.appendingPathComponent("frame.html").absoluteString] != nil)
        #expect(byURL[base.appendingPathComponent("app.js").absoluteString] == nil, "no script")
        #expect(PageArchive.frameURLs(ofWebArchive: archive) == [base.appendingPathComponent("frame.html").absoluteString])
        let read = try Self.read(PageArchive.mhtml(parts, title: webView.title ?? ""))
        #expect(read.parts.count == parts.count)
        #expect(String(data: read.parts[0].data, encoding: .utf8)?.contains("<p>page</p>") == true)
        // Without the frame's site, the frame isn't there; the rest is.
        let withoutFrame = try #require(PageArchive.parts(ofWebArchive: archive) { !$0.hasSuffix("frame.html") })
        #expect(!withoutFrame.contains { $0.url.hasSuffix("frame.html") })
        #expect(withoutFrame.contains { $0.url.hasSuffix("style.css") })
    }

    private func until(_ seconds: Double = 10, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }

    // MARK: Finding the tab

    private typealias Seen = BridgePageCapture.Seen

    /// The one window whose tabs read as the extension's window does, with the same page at that place.
    @Test func theTabIsFoundByWhatTheExtensionWasToldOfIt() {
        let windows: [[Seen]] = [
            [Seen(url: "https://a.example/", active: true), Seen(url: "https://b.example/", active: false)],
            [Seen(url: "https://b.example/", active: true)],
        ]
        func hint(_ url: String?, _ index: Int, active: Bool, urls: [String?]?) -> BridgePageCapture.Hint {
            BridgePageCapture.Hint(url: url, index: index, active: active, windowURLs: urls)
        }
        let place = BridgePageCapture.place
        #expect(place(hint("https://b.example/", 1, active: false, urls: ["https://a.example/", "https://b.example/"]), windows)! == (0, 1))
        #expect(place(hint("https://b.example/", 0, active: true, urls: ["https://b.example/"]), windows)! == (1, 0))
        // A tab the extension isn't told of reads as any address.
        #expect(place(hint("https://b.example/", 1, active: false, urls: [nil, "https://b.example/"]), windows)! == (0, 1))
        // Not there: another page, another place, another state, another window's tabs.
        #expect(place(hint("https://c.example/", 1, active: false, urls: nil), windows) == nil)
        #expect(place(hint("https://b.example/", 2, active: false, urls: nil), windows) == nil)
        #expect(place(hint("https://b.example/", 1, active: true, urls: nil), windows) == nil)
        #expect(place(hint("https://b.example/", 1, active: false, urls: ["https://x.example/", "https://b.example/"]), windows) == nil)
        #expect(place(hint("https://b.example/", 1, active: false, urls: ["https://b.example/"]), windows) == nil)
        // No address: the extension can't see the tab's site, so it isn't looked for.
        #expect(place(hint(nil, 0, active: true, urls: nil), windows) == nil)
        // A tab the extension can't save reads as nothing: asked for, it isn't found, and a guess at its address in
        // the window's list neither helps nor hurts, so the hint can't test one.
        let masked: [[Seen]] = [[Seen(url: "https://a.example/", active: true), Seen(url: nil, active: false)]]
        #expect(place(hint("https://secret.example/", 1, active: false, urls: nil), masked) == nil)
        #expect(place(hint("https://a.example/", 0, active: true, urls: ["https://a.example/", "https://right-guess.example/"]), masked)! == (0, 0))
        #expect(place(hint("https://a.example/", 0, active: true, urls: ["https://a.example/", "https://wrong-guess.example/"]), masked)! == (0, 0))
        // The same page in another window the extension can't save (activeTab gave it only this one): no clash.
        let one: [[Seen]] = [[Seen(url: nil, active: true)], [Seen(url: "https://a.example/", active: true)]]
        #expect(place(hint("https://a.example/", 0, active: true, urls: ["https://a.example/"]), one)! == (1, 0))
        // Two windows that read the same: neither is guessed.
        let twins: [[Seen]] = [[Seen(url: "https://a.example/", active: true)], [Seen(url: "https://a.example/", active: true)]]
        #expect(place(hint("https://a.example/", 0, active: true, urls: ["https://a.example/"]), twins) == nil)
        // What the extension's tabs.get and windows.get said, as bridge.js sends it.
        let sent = BridgePageCapture.Hint(["url": "https://a.example/", "index": 0, "active": true, "urls": ["https://a.example/", NSNull()]])
        #expect(sent == hint("https://a.example/", 0, active: true, urls: ["https://a.example/", nil]))
        // WebKit says "" for a tab on a site the extension can't access: no address, as for one it isn't told of.
        let blank = BridgePageCapture.Hint(["url": "", "index": 2, "active": true, "urls": ["https://a.example/", ""]])
        #expect(blank == hint(nil, 2, active: true, urls: ["https://a.example/", nil]))
        #expect(BridgePageCapture.Hint(["url": "https://a.example/"]) == nil, "no place")
        #expect(BridgePageCapture.Hint(["url": "https://a.example/", "index": -1]) == nil)
    }

    /// Only web pages on a site the extension has, where extensions aren't off: not a file (Zigzag has no switch
    /// for file access, which Chrome asks about separately), never Zigzag's own pages.
    @MainActor @Test func onlyWebPagesOnSitesItHasAreSaved() throws {
        let reaches = BridgePageCapture.reaches
        let page = try #require(URL(string: "https://news.example/today"))
        #expect(reaches(page, true, []))
        #expect(reaches(try #require(URL(string: "http://news.example/")), true, []))
        #expect(!reaches(page, false, []), "no access to the site")
        #expect(!reaches(page, true, ["news.example"]), "extensions off there")
        #expect(!reaches(try #require(URL(string: "https://www.news.example/")), true, ["news.example"]), "and on its subdomains")
        #expect(reaches(page, true, ["other.example"]))
        for other in ["file:///tmp/a.html", "zigzag://settings", "about:blank", "data:text/html,hi", "blob:https://a.example/1",
                      "webkit-extension://x/page.html"] {
            #expect(!reaches(try #require(URL(string: other)), true, []), "\(other)")
            #expect(!BridgePageCapture.isCapturable(try #require(URL(string: other))), "\(other)")
        }
    }

    // MARK: bridge.js

    /// A fake extension background for bridge.js: WebKit's tabs and windows say what they say of one tab, the bridge
    /// answers the capture with `answer` (or fails it), and what was sent is kept.
    private static func world(permissions: [String] = ["pageCapture"], tab: String = "{ id: 7, index: 1, url: 'https://a.example/', active: false, windowId: 3 }",
                              answer: String = "{ value: 'aGVsbG8=' }") -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in Issue.record("\(exception?.toString() ?? "")") }
        let list = "[" + permissions.map { "'\($0)'" }.joined(separator: ", ") + "]"
        context.evaluateScript("""
        var setTimeout = () => 0, clearTimeout = () => {}, setInterval = () => 0, clearInterval = () => {};
        var console = { log: () => {}, warn: () => {}, error: () => {} };
        var atob = (text) => { const table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'; let bits = 0, value = 0, out = '';
          for (const c of text.replace(/=+$/, '')) { value = (value << 6) | table.indexOf(c); bits += 6; if (bits >= 8) { bits -= 8; out += String.fromCharCode((value >> bits) & 255); } } return out; };
        class Blob { constructor(parts, options) { this.bytes = Array.from(parts[0]); this.type = options.type; } }
        const event = () => ({ addListener: () => {}, removeListener: () => {}, hasListener: () => false, hasListeners: () => false });
        var __sent = [];
        var chrome = {
          runtime: { id: 'x', getManifest: () => ({ manifest_version: 3, permissions: \(list) }),
                     sendNativeMessage: (host, message) => { __sent.push(message); return Promise.resolve(message.ns === 'pageCapture' ? \(answer) : {}); },
                     connectNative: () => ({ onMessage: event(), onDisconnect: event(), postMessage: () => {} }) },
          tabs: { get: (id) => (id === 7 ? Promise.resolve(\(tab)) : Promise.reject(new Error('No tab with id: ' + id))) },
          windows: { get: (id, options) => Promise.resolve({ id, tabs: [{ index: 0, url: 'https://z.example/' }, { index: 1 }, { index: 2, url: '' }] }) },
        };
        var browser = chrome;
        """)
        context.evaluateScript(ExtensionBridgeScript.source)
        return context
    }

    /// The tab's place and address go to Zigzag, with its window's addresses (one the extension isn't told of as
    /// null), and the page comes back as a Blob of its bytes: by promise, and by callback.
    @Test func saveAsMHTMLSendsWhatTheExtensionKnowsOfTheTabAndGivesABlob() {
        let context = Self.world()
        context.evaluateScript("var __got; chrome.pageCapture.saveAsMHTML({ tabId: 7 }).then((blob) => { __got = blob; });")
        #expect(context.evaluateScript("JSON.stringify(__sent.filter((m) => m.ns === 'pageCapture'))")?.toString()
            == #"[{"ns":"pageCapture","fn":"saveAsMHTML","args":[{"url":"https://a.example/","index":1,"active":false,"urls":["https://z.example/",null,null]}]}]"#)
        #expect(context.evaluateScript("__got && __got.type")?.toString() == "multipart/related")
        #expect(context.evaluateScript("__got && String.fromCharCode(...__got.bytes)")?.toString() == "hello")
        context.evaluateScript("var __called; chrome.pageCapture.saveAsMHTML({ tabId: 7 }, (blob) => { __called = blob; });")
        #expect(context.evaluateScript("__called && String.fromCharCode(...__called.bytes)")?.toString() == "hello")
        // A tab on a site the extension can't access: WebKit tells it "" for the address, which goes as none.
        let unreachable = Self.world(tab: "{ id: 7, index: 2, url: '', active: true, windowId: 3 }")
        unreachable.evaluateScript("chrome.pageCapture.saveAsMHTML({ tabId: 7 }).catch(() => {});")
        #expect(unreachable.evaluateScript("JSON.stringify(__sent.filter((m) => m.ns === 'pageCapture')[0].args[0].url)")?.toString() == "null")
    }

    /// A failure is the promise's, or the callback's runtime.lastError with undefined, as in Chrome; a tab the
    /// extension's tabs API doesn't know never reaches Zigzag.
    @Test func aFailureIsLastErrorForACallback() {
        let refused = Self.world(answer: "{ error: 'Extension manifest must request permission to access this host.' }")
        refused.evaluateScript("""
        var __error, __seen;
        chrome.pageCapture.saveAsMHTML({ tabId: 7 }).catch((e) => { __error = e.message; });
        chrome.pageCapture.saveAsMHTML({ tabId: 7 }, (blob) => { __seen = [blob, chrome.runtime.lastError && chrome.runtime.lastError.message]; });
        """)
        #expect(refused.evaluateScript("__error")?.toString() == "Extension manifest must request permission to access this host.")
        #expect(refused.evaluateScript("JSON.stringify(__seen)")?.toString() == #"[null,"Extension manifest must request permission to access this host."]"#)
        let unknown = Self.world()
        unknown.evaluateScript("var __why; chrome.pageCapture.saveAsMHTML({ tabId: 99 }).catch((e) => { __why = e.message; }); chrome.pageCapture.saveAsMHTML({}).catch(() => {});")
        #expect(unknown.evaluateScript("__why")?.toString() == "No tab with id: 99")
        #expect(unknown.evaluateScript("__sent.filter((m) => m.ns === 'pageCapture').length")?.toInt32() == 0)
    }

    /// Only for an extension that asks for pageCapture.
    @Test func onlyAnExtensionAskingForItGetsPageCapture() {
        #expect(Self.world(permissions: ["tabs"]).evaluateScript("typeof chrome.pageCapture")?.toString() == "undefined")
        #expect(Self.world().evaluateScript("typeof chrome.pageCapture.saveAsMHTML")?.toString() == "function")
    }
}

/// A local server for a test page: each path answers its type and bytes, anything else is not found.
nonisolated private final class PageServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "zigzag.tests.page-capture-server")

    init(_ files: [String: (type: String, data: Data)]) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receive(connection, bytes: Data(), files: files)
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

    func stop() { listener.cancel() }

    private static func receive(_ connection: NWConnection, bytes: Data, files: [String: (type: String, data: Data)]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var bytes = bytes
            if let data { bytes.append(data) }
            guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete && error == nil && bytes.count < 65536 { receive(connection, bytes: bytes, files: files) } else { connection.cancel() }
                return
            }
            let request = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
            let path = request.components(separatedBy: "\r\n").first?.components(separatedBy: " ").dropFirst().first ?? "/"
            let file = files[path]
            let body = file?.data ?? Data("not found".utf8)
            let head = "HTTP/1.1 \(file == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(file?.type ?? "text/plain")\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
