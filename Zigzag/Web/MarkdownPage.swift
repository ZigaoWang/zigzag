import AppKit
import UniformTypeIdentifiers
import WebKit

/// A Markdown file as a page in a tab (#566): zigzag://markdown?url=<the file>, served by Zigzag's own pages' scheme
/// handler. A local .md file, or a web response that is Markdown, comes here instead of showing as plain text or
/// downloading (`Tab`'s response check). The address bar shows the file's own address.
///
/// The page runs nothing: its policy allows no scripts, frames, forms or fonts, and the HTML (`MarkdownHTML`) carries
/// none. Pictures from a local file come through `pictureHost`, only from the folder a file page could read
/// (`Tab.readAccess`). Preview and Source switch with a link to `#zigzag-source`, so each tab keeps its own choice
/// in its address and its Back and Forward.
@MainActor
enum MarkdownPage {
    nonisolated static let scheme = "zigzag"
    nonisolated static let host = "markdown"
    nonisolated static let pictureHost = "markdown-picture"
    nonisolated static let sourceAnchor = MarkdownHTML.reservedAnchor
    /// Past this, a file opens as it would without the viewer.
    nonisolated static let maxBytes = 16 << 20
    nonisolated static let maxPictureBytes = 32 << 20

    /// What the page may do: show itself, its styles and pictures. Nothing runs, loads into a frame or submits.
    nonisolated static let policy = "default-src 'none'; img-src http: https: data: \(scheme):; style-src 'unsafe-inline'; "
        + "script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; font-src 'none'; media-src 'none'; "
        + "connect-src 'none'; form-action 'none'; base-uri 'none'"

    // MARK: Addresses

    nonisolated static func isMarkdownName(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    /// Where the viewer shows a file: its address without its fragment, which becomes the page's own.
    nonisolated static func address(for source: URL) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        var bare = URLComponents(url: source, resolvingAgainstBaseURL: true)
        let fragment = bare?.percentEncodedFragment
        bare?.fragment = nil
        let text = bare?.string ?? source.absoluteString
        parts.percentEncodedQuery = "url=" + (text.addingPercentEncoding(withAllowedCharacters: queryValue) ?? "")
        parts.percentEncodedFragment = fragment
        return parts.url!
    }

    private nonisolated static let queryValue: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/:")
        return set
    }()

    /// The file a viewer address shows, with the page's fragment unless it's the Source switch's.
    nonisolated static func source(of page: URL?) -> URL? {
        guard let page, page.scheme?.lowercased() == scheme, page.host() == host,
              let parts = URLComponents(url: page, resolvingAgainstBaseURL: false),
              let text = parts.queryItems?.first(where: { $0.name == "url" })?.value,
              var source = URLComponents(string: text),
              ["file", "http", "https"].contains(source.scheme?.lowercased() ?? "") else { return nil }
        if let fragment = parts.percentEncodedFragment, fragment != sourceAnchor, !fragment.isEmpty { source.percentEncodedFragment = fragment }
        return source.url
    }

    nonisolated static func isMarkdown(_ page: URL?) -> Bool { source(of: page) != nil }

    /// Whether a page's response is Markdown for the viewer: a local .md file, or from the web text/markdown, or
    /// text/plain at a .md address. Never one sent as a download, past `maxBytes`, or anything but a whole reply.
    nonisolated static func shows(_ response: URLResponse, isGet: Bool) -> Bool {
        guard isGet, let url = response.url else { return false }
        if url.isFileURL { return isMarkdownName(url) && response.expectedContentLength <= Int64(maxBytes) }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if let http = response as? HTTPURLResponse {
            guard http.statusCode == 200 else { return false }
            let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            if disposition.hasPrefix("attachment") { return false }
        }
        if response.expectedContentLength > Int64(maxBytes) { return false }
        let mime = (response.mimeType ?? "").lowercased()
        return ["text/markdown", "text/x-markdown"].contains(mime) || (mime == "text/plain" && isMarkdownName(url))
    }

    /// Whether a page may send its tab to `target`, one of Zigzag's own pages: the viewer only within itself (its
    /// headings, the Source switch); Zigzag's other pages as before.
    nonisolated static func mayLink(fromHost sourceHost: String, current: URL?, to target: URL) -> Bool {
        guard sourceHost == host else { return true }
        return source(of: target).map(\.withoutFragment) == source(of: current).map(\.withoutFragment) && source(of: target) != nil
    }

    // MARK: Serving

    private static var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    static func stop(_ task: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    static func serve(_ task: any WKURLSchemeTask, in webView: WKWebView) {
        guard let url = task.request.url, let source = source(of: url)?.withoutFragment else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let access = source.isFileURL ? Tab.readAccess(for: source) : nil
        let labels = (preview: String(localized: "markdown.preview", defaultValue: "Preview", comment: "Switch at the top of a Markdown file shown in a tab: shows the file formatted."),
                      source: String(localized: "markdown.source", defaultValue: "Source", comment: "Switch at the top of a Markdown file shown in a tab: shows the file's plain text."),
                      group: String(localized: "markdown.view", defaultValue: "View", comment: "Accessibility label of the Preview and Source switch on a Markdown file shown in a tab."))
        let style = PageStyle.variables(theme: HistoryPage.theme(for: webView)) + css
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let userAgent = webView.customUserAgent
        let id = ObjectIdentifier(task)
        running[id] = Task { [weak webView] in
            var data: Data?
            if source.isFileURL {
                data = await Task.detached { readFile(source, limit: maxBytes) }.value
            } else if let webView {
                data = await PDFViewerView.fetch(source, from: webView, userAgent: userAgent, limit: maxBytes)
            }
            guard !Task.isCancelled, running[id] != nil else { return }
            guard let data else {
                running[id] = nil
                task.didFailWithError(URLError(source.isFileURL ? .fileDoesNotExist : .cannotLoadFromNetwork))
                return
            }
            let page = await Task.detached {
                html(for: text(of: data), source: source, access: access, labels: labels, style: style, language: language)
            }.value
            guard !Task.isCancelled, running.removeValue(forKey: id) != nil else { return }
            respond(task, url: url, type: "text/html; charset=utf-8", data: Data(page.utf8))
        }
    }

    /// A picture beside a local file the viewer shows, only from where that file's page could read.
    static func servePicture(_ task: any WKURLSchemeTask) {
        guard let url = task.request.url, let document = task.request.mainDocumentURL, let source = source(of: document), source.isFileURL,
              let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let file = URL(string: text), mayShowPicture(file, access: Tab.readAccess(for: source.withoutFragment)),
              let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image), let mime = type.preferredMIMEType else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let id = ObjectIdentifier(task)
        running[id] = Task {
            let data = await Task.detached { readFile(file, limit: maxPictureBytes) }.value
            guard !Task.isCancelled, running.removeValue(forKey: id) != nil else { return }
            guard let data else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
            respond(task, url: url, type: mime, data: data)
        }
    }

    private static func respond(_ task: any WKURLSchemeTask, url: URL, type: String, data: Data) {
        let headers = ["Content-Type": type, "Content-Length": String(data.count), "Content-Security-Policy": policy,
                       "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store"]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// Where a local file's picture is shown from.
    nonisolated static func pictureAddress(for file: URL) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = pictureHost
        parts.percentEncodedQuery = "url=" + (file.absoluteString.addingPercentEncoding(withAllowedCharacters: queryValue) ?? "")
        return parts.url!
    }

    /// A picture inside `access` (the file's folder, or only the file itself), its links followed first, so one
    /// pointing out of the folder is refused.
    nonisolated static func mayShowPicture(_ file: URL, access: URL) -> Bool {
        guard file.isFileURL, (file.host() ?? "").isEmpty else { return false }
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        let root = access.standardizedFileURL.resolvingSymlinksInPath().path
        guard access.hasDirectoryPath || (try? access.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    nonisolated private static func readFile(_ url: URL, limit: Int) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The file's text: UTF-8 (a byte-order mark dropped), else Windows Latin 1, as browsers read plain text.
    nonisolated static func text(of data: Data) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    // MARK: The page

    nonisolated static func html(for text: String, source: URL, access: URL?,
                                 labels: (preview: String, source: String, group: String), style: String, language: String) -> String {
        let rendered = MarkdownHTML.render(text, base: source) { file in
            guard let access, mayShowPicture(file, access: access) else { return nil }
            return pictureAddress(for: file)
        }
        let name = source.lastPathComponent.removingPercentEncoding ?? source.lastPathComponent
        let title = rendered.title.flatMap { $0.isEmpty ? nil : $0 } ?? name
        func escape(_ s: String) -> String { MarkdownHTML.escape(s) }
        var page = ""
        page.reserveCapacity(rendered.body.utf8.count + text.utf8.count * 2 + 16_000)
        page += "<!doctype html>\n<html lang=\"\(escape(language))\">\n<head>\n<meta charset=\"utf-8\">\n"
        page += "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">\n"
        page += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"referrer\" content=\"no-referrer\">\n"
        page += "<title>\(escape(title))</title>\n<style>\n\(style)</style>\n</head>\n<body>\n"
        page += "<div id=\"\(sourceAnchor)\"></div>\n<main>\n"
        page += "<nav class=\"view\" aria-label=\"\(escape(labels.group))\">"
        page += "<a class=\"preview\" href=\"#\">\(escape(labels.preview))</a><a class=\"code\" href=\"#\(sourceAnchor)\">\(escape(labels.source))</a></nav>\n"
        page += "<article class=\"rendered\">\n"
        page += rendered.body
        page += "</article>\n<pre class=\"source\">"
        MarkdownHTML.escape(text, into: &page)
        page += "</pre>\n</main>\n</body>\n</html>\n"
        return page
    }

    /// Reader's papers and inks and its rhythm, in the system's sans for documents full of code and tables.
    static let css = """
    :root { \(Reader.Palette.light.css)
            --sans: system-ui, -apple-system, "Helvetica Neue", sans-serif;
            --mono: ui-monospace, "SF Mono", Menlo, monospace;
            --leading: 1.6; --line: calc(var(--leading) * 1rem); --measure: 46rem;
            --page-gutter: clamp(\(Int(Tokens.Page.gutter))px, 6vw, 96px);
            font-size: 16px; }
    @media (prefers-color-scheme: dark) { :root { \(Reader.Palette.dark.css) } }
    :root:is(:lang(zh), :lang(ja), :lang(ko)) { --leading: 1.75; }

    * { box-sizing: border-box; }
    html { background: var(--paper); }
    ::selection { background: var(--select); }
    body { margin: 0; padding: 28px var(--page-gutter) 120px; color: var(--ink); font-family: var(--sans); font-size: 1rem;
           line-height: var(--leading); -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; overflow-wrap: break-word; }
    main { max-width: var(--measure); margin: 0 auto; }

    /* Preview and Source: the app's sliding switch, a soft track with the chosen word on a raised pill. */
    .view { display: flex; width: max-content; margin: 0 0 40px auto; padding: 3px; border-radius: 9px; background: var(--field);
            font: 500 \(Int(Tokens.TypeSize.body))px/1 var(--sans); -webkit-user-select: none; user-select: none; }
    .view a { display: block; min-width: 72px; padding: 5px 12px 6px; border-radius: 6px; text-align: center; color: var(--muted); text-decoration: none; cursor: default; }
    .view a:hover { color: var(--text); }
    .view .preview, #\(sourceAnchor):target ~ main .view .code { background: var(--control); color: var(--text);
                                                                  box-shadow: inset 0 0 0 1px var(--control-edge), 0 0.5px 1.5px var(--control-shadow); }
    #\(sourceAnchor):target ~ main .view .preview { background: none; color: var(--muted); box-shadow: none; }
    /* At the very top, so switching to Source shows the page from its start. */
    #\(sourceAnchor) { position: absolute; top: 0; }
    .source { display: none; }
    #\(sourceAnchor):target ~ main .rendered { display: none; }
    #\(sourceAnchor):target ~ main .source { display: block; }

    article > :first-child { margin-top: 0; }
    p, ul, ol, dl, table, blockquote, pre { margin: 0 0 calc(var(--line) * .75); }
    h1, h2, h3, h4, h5, h6 { margin: calc(var(--line) * 1.5) 0 calc(var(--line) * .5); line-height: 1.3; font-weight: 600; letter-spacing: -0.006em; text-wrap: balance; }
    h1 { font-size: 1.9em; letter-spacing: -0.012em; line-height: 1.2; }
    h2 { font-size: 1.45em; } h3 { font-size: 1.2em; } h4 { font-size: 1.05em; } h5, h6 { font-size: 1em; } h6 { color: var(--soft); }
    :is(h1, h2) { padding-bottom: .3em; border-bottom: 1px solid var(--rule); }
    :is(h1, h2, h3, h4) + :is(h2, h3, h4, h5) { margin-top: calc(var(--line) * .75); }
    p { text-wrap: pretty; }

    a { color: var(--link); text-decoration: underline 1px; text-underline-offset: .2em; text-decoration-color: color-mix(in srgb, var(--link) 40%, transparent); }
    a:hover { text-decoration-color: currentColor; }

    img { max-width: 100%; height: auto; border-radius: \(Int(Tokens.Radius.small))px; vertical-align: middle; }

    blockquote { padding: 0 0 0 1em; border-left: 3px solid var(--rule); color: var(--soft); }
    blockquote > :last-child { margin-bottom: 0; }

    code, kbd, pre { font-family: var(--mono); font-size: .875em; }
    code { padding: .12em .35em; border-radius: \(Int(Tokens.Radius.small))px; background: var(--code); }
    kbd { padding: .1em .4em; border-radius: \(Int(Tokens.Radius.small))px; border: 1px solid var(--rule); border-bottom-width: 2px; }
    pre { padding: 14px 16px; border-radius: \(Int(Tokens.Radius.field))px; background: var(--code); line-height: 1.5; overflow-x: auto; white-space: pre; tab-size: 4; }
    pre code { padding: 0; background: none; font-size: inherit; border-radius: 0; }
    pre.html { color: var(--soft); }
    .source { margin: 0; padding: 0; background: none; border-radius: 0; font-size: .875em; line-height: 1.6; white-space: pre-wrap; overflow-wrap: anywhere; }

    table { display: block; width: max-content; max-width: 100%; overflow-x: auto; border-collapse: collapse; font-size: .9375em; }
    th, td { padding: 6px 14px; border: 1px solid var(--rule); text-align: left; vertical-align: top; }
    th { font-weight: 600; }
    tr:nth-child(2n) td { background: color-mix(in srgb, var(--code) 60%, transparent); }
    .left { text-align: left; } .center { text-align: center; } .right { text-align: right; }

    ul, ol { padding-left: 1.6em; }
    li { margin: calc(var(--line) * .2) 0; } li > :is(p, ul, ol) { margin: calc(var(--line) * .2) 0; }
    li::marker { color: var(--soft); }
    ul.tasks > li.task { list-style: none; }
    ul.tasks > li.task > :is(p:first-child, input:first-child) { margin-left: -1.4em; }
    /* A drawn box, the same done or not: WebKit's own disabled checkbox is a faint tick with no box. */
    li.task input { -webkit-appearance: none; appearance: none; width: .95em; height: .95em; margin: 0 .45em 0 0; vertical-align: -.13em;
                    border: 1.5px solid var(--soft); border-radius: 4px; background: none; }
    li.task input:checked { border-color: var(--link); background: var(--link) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M3 6.2l2 2 4-4.4' fill='none' stroke='white' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / 100% no-repeat; }
    @media (prefers-color-scheme: dark) { li.task input:checked { background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M3 6.2l2 2 4-4.4' fill='none' stroke='%231E1E20' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E"); } }
    hr { height: 1px; margin: calc(var(--line) * 1.5) 0; border: 0; background: var(--rule); }
    del { color: var(--soft); }
    sup, sub { line-height: 0; font-size: .75em; }

    @page { margin: 18mm 20mm; }
    @media print {
      :root { \(Reader.Palette.light.css) --ink: #000; }
      html, body { background: #fff; }
      body { padding: 0; font-size: 11pt; }
      main { max-width: none; }
      .view { display: none; }
      pre, .source { white-space: pre-wrap; overflow: visible; }
      table { overflow: visible; }
      img, pre, blockquote, tr { break-inside: avoid; }
      h1, h2, h3, h4 { break-after: avoid; }
    }
    """
}

extension URL {
    /// The address without its `#fragment`.
    nonisolated var withoutFragment: URL {
        guard fragment != nil, var parts = URLComponents(url: self, resolvingAgainstBaseURL: true) else { return self }
        parts.fragment = nil
        return parts.url ?? self
    }
}
