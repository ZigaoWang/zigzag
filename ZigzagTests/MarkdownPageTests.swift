import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Markdown files in a tab (#566): what the HTML holds, what it leaves out, and the page in a real tab.
@MainActor
struct MarkdownPageTests {
    private let fileBase = URL(fileURLWithPath: "/tmp/notes/README.md")
    private let webBase = URL(string: "https://example.com/repo/README.md")!

    private func html(_ text: String, base: URL? = nil, pictures: Bool = true) -> String {
        MarkdownHTML.render(text, base: base ?? fileBase) { pictures ? MarkdownPage.pictureAddress(for: $0) : nil }.body
    }

    // MARK: Rendering

    @Test func rendersGitHubTablesTaskListsAndFencedCode() {
        let body = html("""
        # Title

        | Left | Middle | Right |
        |:-----|:------:|------:|
        | a    | b      | c     |

        - [x] done
        - [ ] to do

        ```swift
        let x = 1 < 2
        ```

        ~~gone~~ and `code` and **bold**
        """)
        #expect(body.contains(#"<h1 id="title">Title</h1>"#))
        #expect(body.contains(#"<th class="left">Left</th><th class="center">Middle</th><th class="right">Right</th>"#))
        #expect(body.contains(#"<td class="center">b</td>"#))
        #expect(body.contains(#"<ul class="tasks">"#))
        #expect(body.contains(#"<li class="task"><p><input type="checkbox" disabled checked> done</p>"#))
        #expect(body.contains(#"<input type="checkbox" disabled> to do"#))
        #expect(body.contains(#"<pre><code class="language-swift">let x = 1 &lt; 2"#))
        #expect(body.contains("<del>gone</del>"))
        #expect(body.contains("<code>code</code>"))
        #expect(body.contains("<strong>bold</strong>"))
        #expect(MarkdownHTML.render("Intro\n\n## Second\n\n# First", base: fileBase).title == "First")
    }

    @Test func headingsGetGitHubAnchorsAndNeverTakeTheSourceAnchor() {
        let body = html("## Install it!\n\n## Install it!\n\n## Zigzag source\n\n## 安装")
        #expect(body.contains(#"<h2 id="install-it">"#))
        #expect(body.contains(#"<h2 id="install-it-1">"#))
        #expect(body.contains(#"<h2 id="zigzag-source-1">"#))
        #expect(body.contains(#"<h2 id="安装">"#))
    }

    // MARK: Escaping and scripts

    @Test func rawHTMLAndScriptsShowAsTextAndNeverRun() {
        let body = html("""
        <script>alert(1)</script>

        <div onclick="alert(1)">block</div>

        Inline <img src=x onerror=alert(1)> and <a href="javascript:alert(1)">a</a> and <b onclick="x()">b</b>.

        Kept: <kbd>⌘</kbd> <sup>2</sup> line<br>break, a stray </kbd> and <!-- a comment -->.

        <!-- a block comment -->

        ```html
        </code></pre><script>alert(1)</script>
        ```

        [title](https://example.com "a \\" onmouseover=\\"alert(1)")
        """)
        for unsafe in ["<script", "<img src=x", "<div", "<a href=\"javascript", "<b onclick"] {
            #expect(!body.contains(unsafe), "\(unsafe)")
        }
        #expect(body.contains(#"<pre class="html">&lt;script&gt;alert(1)&lt;/script&gt;</pre>"#))
        #expect(body.contains("&lt;img src=x onerror=alert(1)&gt;"))
        #expect(body.contains("<kbd>⌘</kbd> <sup>2</sup> line<br>"))
        #expect(body.contains("a stray &lt;/kbd&gt;"))
        #expect(!body.contains("comment"))
        #expect(body.contains("&lt;/code&gt;&lt;/pre&gt;&lt;script&gt;"))
        #expect(body.contains(#"title="a &quot; onmouseover=&quot;alert(1)""#))
    }

    @Test func linksAndPicturesGoOnlyWhereAPageCould() {
        let body = html("""
        [js](javascript:alert(1)) [JS](  JaVaScRiPt:alert(1)) [entity](&#106;avascript:alert(1)) [data](data:text/html,<script>alert(1)</script>)
        [vb](vbscript:msgbox) [own](zigzag://settings) [ext](chrome-extension://abc/page.html) [mail](mailto:a@example.com)
        ![bad](javascript:alert(1)) ![svg](data:image/png;base64,iVBORw0KGgo=) ![own](zigzag://icon?url=https://a.com)
        <javascript:alert(1)>
        """)
        let lower = body.lowercased()
        #expect(!lower.contains("href=\"javascript") && !lower.contains("src=\"javascript"))
        #expect(!body.contains("vbscript:"))
        #expect(!body.contains("zigzag://settings"))
        #expect(!body.contains("zigzag://icon"))
        #expect(!body.contains("chrome-extension:"))
        #expect(!body.contains("href=\"data:"))
        #expect(!body.contains("<script"))
        #expect(body.contains(#"<a href="mailto:a@example.com">mail</a>"#))
        #expect(body.contains(#"<img src="data:image/png;base64,iVBORw0KGgo=" alt="svg""#))
        // Their words stay.
        #expect(body.contains("<p>js JS entity"))
        #expect(body.contains("bad"))
    }

    // MARK: Relative links and pictures

    @Test func relativeLinksAndPicturesResolveAgainstTheFile() {
        let local = html("[next](other.md) [up](../up.md) [here](#install) [self](README.md#usage) [space](<my notes.md>) ![pic](img/a.png) [remote](//server/share.md)")
        #expect(local.contains(#"href="file:///tmp/notes/other.md""#))
        #expect(local.contains(#"href="file:///tmp/up.md""#))
        #expect(local.contains(##"href="#install""##))
        #expect(local.contains(##"href="#usage""##))
        #expect(local.contains(#"href="file:///tmp/notes/my%20notes.md""#))
        #expect(local.contains(#"src="zigzag://markdown-picture?url=file:///tmp/notes/img/a.png""#))
        #expect(!local.contains("server"))
        // A picture the file's page couldn't read shows its words.
        #expect(html("![pic](img/a.png)", pictures: false).contains("<p>pic</p>"))

        let web = html("[docs](docs/x.md) [file](file:///etc/hosts) ![pic](a.png) ![abs](https://cdn.example.com/b.png) [top](#top)", base: webBase)
        #expect(web.contains(#"href="https://example.com/repo/docs/x.md""#))
        #expect(!web.contains("file:"))
        #expect(web.contains(#"src="https://example.com/repo/a.png""#))
        #expect(web.contains(#"src="https://cdn.example.com/b.png""#))
        #expect(web.contains(##"href="#top""##))
    }

    @Test func picturesBesideAFileStayInsideItsFolder() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = try scratch()
        defer { try? FileManager.default.removeItem(at: outside) }
        let inner = folder.appendingPathComponent("img", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try png().write(to: inner.appendingPathComponent("a.png"))
        try png().write(to: outside.appendingPathComponent("secret.png"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
        let access = folder
        #expect(MarkdownPage.mayShowPicture(inner.appendingPathComponent("a.png"), access: access))
        #expect(!MarkdownPage.mayShowPicture(folder.appendingPathComponent("../\(outside.lastPathComponent)/secret.png"), access: access))
        #expect(!MarkdownPage.mayShowPicture(outside.appendingPathComponent("secret.png"), access: access))
        #expect(!MarkdownPage.mayShowPicture(folder.appendingPathComponent("link.png"), access: access))
        // Read access that is only the file itself (one loose in Downloads) reads no pictures.
        #expect(!MarkdownPage.mayShowPicture(inner.appendingPathComponent("a.png"), access: folder.appendingPathComponent("README.md")))
    }

    // MARK: Which responses

    @Test func markdownResponsesAreTheOnesShown() {
        func http(_ path: String, _ mime: String, status: Int = 200, headers: [String: String] = [:]) -> URLResponse {
            HTTPURLResponse(url: URL(string: "https://example.com" + path)!, statusCode: status, httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": mime].merging(headers) { $1 })!
        }
        #expect(MarkdownPage.shows(http("/a", "text/markdown"), isGet: true))
        #expect(MarkdownPage.shows(http("/a", "text/x-markdown; charset=utf-8"), isGet: true))
        #expect(MarkdownPage.shows(http("/README.md", "text/plain"), isGet: true))
        #expect(MarkdownPage.shows(http("/notes.MARKDOWN", "text/plain"), isGet: true))
        #expect(!MarkdownPage.shows(http("/notes.txt", "text/plain"), isGet: true))
        #expect(!MarkdownPage.shows(http("/README.md", "text/html"), isGet: true))
        #expect(!MarkdownPage.shows(http("/README.md", "text/plain", status: 404), isGet: true))
        #expect(!MarkdownPage.shows(http("/README.md", "text/markdown", headers: ["Content-Disposition": "attachment; filename=README.md"]), isGet: true))
        #expect(!MarkdownPage.shows(http("/README.md", "text/markdown"), isGet: false))
        let file = URLResponse(url: URL(fileURLWithPath: "/tmp/a.md"), mimeType: "text/markdown", expectedContentLength: 10, textEncodingName: nil)
        #expect(MarkdownPage.shows(file, isGet: true))
        let big = URLResponse(url: URL(fileURLWithPath: "/tmp/a.md"), mimeType: nil, expectedContentLength: Int(MarkdownPage.maxBytes) + 1, textEncodingName: nil)
        #expect(!MarkdownPage.shows(big, isGet: true))
        #expect(!MarkdownPage.shows(URLResponse(url: URL(fileURLWithPath: "/tmp/a.txt"), mimeType: "text/plain", expectedContentLength: 10, textEncodingName: nil), isGet: true))
    }

    @Test func theViewerKeepsTheFilesAddressAndSendsATabNowhereElseOfZigzags() {
        let source = URL(string: "https://example.com/a%20b/README.md?x=1&y=2#usage")!
        let page = MarkdownPage.address(for: source)
        #expect(page.scheme == "zigzag" && page.host() == "markdown")
        #expect(MarkdownPage.source(of: page) == source)
        #expect(page.fragment == "usage")
        let toggled = URL(string: page.absoluteString.replacingOccurrences(of: "#usage", with: "#zigzag-source"))!
        #expect(MarkdownPage.source(of: toggled) == source.withoutFragment)
        #expect(AddressView.name(of: page) == "example.com")
        #expect(AddressView.name(of: MarkdownPage.address(for: fileBase)) == "README.md")
        #expect(MarkdownPage.source(of: URL(string: "zigzag://markdown?url=javascript:alert(1)")!) == nil)
        // From a Markdown page: only within itself.
        #expect(MarkdownPage.mayLink(fromHost: "markdown", current: page, to: toggled))
        #expect(!MarkdownPage.mayLink(fromHost: "markdown", current: page, to: URL(string: "zigzag://settings")!))
        #expect(!MarkdownPage.mayLink(fromHost: "markdown", current: page, to: MarkdownPage.address(for: fileBase)))
        #expect(MarkdownPage.mayLink(fromHost: "history", current: URL(string: "zigzag://history")!, to: URL(string: "zigzag://settings")!))
    }

    @Test func thePageRunsNothing() {
        let page = MarkdownPage.html(for: "# Hi\n\n<script>alert(1)</script>", source: fileBase, access: nil,
                                     labels: ("Preview", "Source", "View"), style: "", language: "en")
        #expect(!page.contains("<script"))
        #expect(page.contains(#"<meta http-equiv="Content-Security-Policy" content="default-src 'none';"#))
        #expect(MarkdownPage.policy.contains("script-src 'none'"))
        #expect(MarkdownPage.policy.contains("frame-src 'none'"))
        #expect(MarkdownPage.policy.contains("form-action 'none'"))
        #expect(page.contains(#"<pre class="source"># Hi"#))
        #expect(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;</pre>"))
    }

    // MARK: In a tab

    @Test func aLocalFileOpensFormattedWithItsPicturesAndNoScripts() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try png().write(to: folder.appendingPathComponent("pic.png"))
        let file = folder.appendingPathComponent("README.md")
        try """
        # Notes

        ![pic](pic.png) [next](other.md)

        <script>document.title = 'ran'</script>

        <img src=x onerror="document.title = 'ran'">
        """.write(to: file, atomically: true, encoding: .utf8)
        let tab = Tab(url: nil, spaceID: UUID())
        defer { tab.close() }
        tab.load(file)
        let page = try await shown(in: tab, title: "Notes")
        #expect(MarkdownPage.source(of: tab.url) == file)
        #expect(tab.shownURL == file)
        #expect(try await ask(page, "document.querySelector('article h1').textContent") as? String == "Notes")
        #expect(try await ask(page, "document.scripts.length") as? Int == 0)
        #expect(try await ask(page, "document.querySelector('article a[href]').href") as? String == folder.appendingPathComponent("other.md").absoluteString)
        var width = 0
        for _ in 0..<60 {
            width = try await ask(page, "document.querySelector('article img').naturalWidth") as? Int ?? 0
            if width > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(width == 4)
        try await Task.sleep(for: .milliseconds(200))
        #expect(page.title == "Notes")
    }

    @Test func aTextPlainMarkdownFileFromALocalServerOpensFormatted() async throws {
        let server = try LocalPageServer { _, path in
            switch path {
            case "/docs/notes.md": return .init(headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("# Served\n\n![p](p.png)\n\n[up](../index.md)".utf8))
            case "/docs/p.png": return .init(headers: ["Content-Type": "image/png"], body: MarkdownPageTests.pngData)
            case "/plain.txt": return .init(headers: ["Content-Type": "text/plain"], body: Data("# Not Markdown".utf8))
            default: return .init(status: "404 Not Found", body: Data())
            }
        }
        let site = try await server.start()
        defer { server.stop() }
        let tab = Tab(url: nil, spaceID: UUID())
        defer { tab.close() }
        let address = site.appendingPathComponent("docs/notes.md")
        tab.load(address)
        let page = try await shown(in: tab, title: "Served")
        #expect(MarkdownPage.source(of: tab.url) == address)
        #expect(try await ask(page, "document.querySelector('article a[href]').href") as? String == site.appendingPathComponent("index.md").absoluteString)
        var width = 0
        for _ in 0..<60 {
            width = try await ask(page, "document.querySelector('article img').naturalWidth") as? Int ?? 0
            if width > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(width == 4)

        // Plain text that isn't at a .md address stays plain text.
        let plain = site.appendingPathComponent("plain.txt")
        tab.load(plain)
        for _ in 0..<100 where page.isLoading || page.url != plain { try await Task.sleep(for: .milliseconds(50)) }
        #expect(page.url == plain)
        #expect(!MarkdownPage.isMarkdown(tab.url))
    }

    @Test func sourceSwitchShowsTheTextAndIsKeptPerTab() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.md")
        try "# Switch\n\nSome **bold** words.".write(to: file, atomically: true, encoding: .utf8)
        let tab = Tab(url: nil, spaceID: UUID())
        defer { tab.close() }
        let other = Tab(url: nil, spaceID: UUID())
        defer { other.close() }
        tab.load(file)
        other.load(file)
        let page = try await shown(in: tab, title: "Switch")
        let otherPage = try await shown(in: other, title: "Switch")
        let visible = "[getComputedStyle(document.querySelector('article')).display, getComputedStyle(document.querySelector('pre.source')).display]"
        #expect(try await ask(page, visible) as? [String] == ["block", "none"])
        _ = try await ask(page, "document.querySelector('.view .code').click()")
        for _ in 0..<40 where tab.url?.fragment != MarkdownPage.sourceAnchor { try await Task.sleep(for: .milliseconds(50)) }
        #expect(tab.url?.fragment == MarkdownPage.sourceAnchor)
        #expect(try await ask(page, visible) as? [String] == ["none", "block"])
        #expect(try await ask(page, "document.querySelector('pre.source').textContent") as? String == "# Switch\n\nSome **bold** words.")
        // The other tab on the same file still shows it formatted.
        #expect(try await ask(otherPage, visible) as? [String] == ["block", "none"])
        // Kept across a reload, and Back goes to the formatted file.
        tab.reload()
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<100 where page.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try await ask(page, visible) as? [String] == ["none", "block"])
        tab.goBack()
        for _ in 0..<40 where tab.url?.fragment == MarkdownPage.sourceAnchor { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try await ask(page, visible) as? [String] == ["block", "none"])
    }

    // MARK: Big files

    @Test func aBigFileRendersQuicklyAndOffTheMainThread() async throws {
        var text = ""
        var n = 0
        while text.utf8.count < 5_000_000 {
            n += 1
            text += "## Section \(n)\n\nSome *words* with `code`, a [link](https://example.com/\(n)) and <b>tags</b>.\n\n| a | b |\n|---|---|\n| \(n) | x |\n\n- [ ] task\n- item\n\n```\nlet x = \(n)\n```\n\n"
        }
        // CPU time on this thread, so other builds sharing the Mac don't make it look slow.
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let rendered = MarkdownHTML.render(text, base: fileBase)
        let seconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
        #expect(rendered.body.contains("Section \(n)"))
        #expect(seconds < 15, "\(seconds)s of CPU")   // a sanity bound; the main-thread check below is the real one

        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("big.md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let tab = Tab(url: nil, spaceID: UUID())
        defer { tab.close() }
        // The longest the main thread goes without a turn while the file is read and set.
        var longest: TimeInterval = 0
        var last = Date()
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                longest = max(longest, Date().timeIntervalSince(last))
                last = Date()
            }
        }
        defer { ticker.invalidate() }
        tab.load(file)
        _ = try await shown(in: tab, title: "Section 1", seconds: 30)
        #expect(longest < 0.5, "\(longest)s")
    }

    // MARK: Helpers

    /// The tab's page once the viewer shows it with `title`.
    private func shown(in tab: Tab, title: String, seconds: Double = 10) async throws -> WKWebView {
        let page = tab.ensureWebView()
        for _ in 0..<Int(seconds * 20) where page.isLoading || page.title != title || !MarkdownPage.isMarkdown(page.url) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(page.title == title)
        #expect(MarkdownPage.isMarkdown(page.url))
        return page
    }

    private func ask(_ page: WKWebView, _ script: String) async throws -> Any? {
        try await page.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Markdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.resolvingSymlinksInPath()
    }

    private func png() -> Data { Self.pngData }

    /// A 4×4 picture.
    nonisolated static let pngData: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }()
}
