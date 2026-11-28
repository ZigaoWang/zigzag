import AppKit
import UniformTypeIdentifiers
import WebKit

/// A folder on your Mac as a list in a tab (#566): zigzag://folder?url=<the folder>, instead of WebKit's bare listing.
/// Name, kind, size and date, sorted by a click on a column's heading. Hidden files stay hidden until you show them.
///
/// The page runs nothing: sorting and showing hidden files are links to the same page with other choices in its
/// address, and its policy allows no scripts, frames or forms. It lists only the folder the tab was sent to, as
/// the Markdown viewer reads only its file. A click on a file opens it in the tab as any local file opens, a
/// folder's list, or Quick Look for a file nothing in a tab shows.
@MainActor
enum FolderPage {
    nonisolated static let host = "folder"
    nonisolated static let iconHost = "folder-icon"

    nonisolated static let policy = "default-src 'none'; img-src \(MarkdownPage.scheme):; style-src 'unsafe-inline'; "
        + "script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; font-src 'none'; media-src 'none'; "
        + "connect-src 'none'; form-action 'none'; base-uri 'none'"

    enum Sort: String, CaseIterable, Sendable { case name, kind, size, date }

    /// What the list shows: its order, and whether hidden files are in it.
    struct Choice: Equatable, Sendable {
        var sort: Sort = .name
        var descending = false
        var hidden = false
    }

    // MARK: Addresses

    nonisolated static func address(for folder: URL, _ choice: Choice = Choice()) -> URL {
        var extra: [(String, String)] = []
        if choice.sort != .name { extra.append(("sort", choice.sort.rawValue)) }
        if choice.descending { extra.append(("order", "desc")) }
        if choice.hidden { extra.append(("hidden", "1")) }
        return FilePages.address(host: host, for: asFolder(folder), extra: extra)
    }

    /// The folder a list's address shows, always with its closing slash.
    nonisolated static func source(of page: URL?) -> URL? {
        FilePages.source(of: page, host: host, schemes: ["file"]).map(asFolder)
    }

    nonisolated static func choice(of page: URL?) -> Choice {
        Choice(sort: FilePages.value("sort", in: page, host: host).flatMap(Sort.init(rawValue:)) ?? .name,
               descending: FilePages.value("order", in: page, host: host) == "desc",
               hidden: FilePages.value("hidden", in: page, host: host) == "1")
    }

    nonisolated static func asFolder(_ url: URL) -> URL {
        url.hasDirectoryPath ? url : URL(fileURLWithPath: url.path, isDirectory: true)
    }

    /// Whether a local address is a folder to list: a directory that isn't a document Quick Look shows (a Pages
    /// file can be a package).
    nonisolated static func lists(_ url: URL) -> Bool {
        guard url.isFileURL, !QuickLookPage.showsFile(url) else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// A list may send its tab only to itself in another order or opening a file in it, to the list of a folder in
    /// it or of the one it's in, or to Quick Look for a file in it.
    nonisolated static func mayLink(current: URL?, to target: URL) -> Bool {
        guard let folder = source(of: current)?.standardizedFileURL else { return false }
        if let other = source(of: target)?.standardizedFileURL {
            if FilePages.value("open", in: target, host: host) != nil { return opening(target).map { isInside($0, folder) } ?? false }
            return other == folder || isInside(other, folder) || isInside(folder, other)
        }
        if let file = QuickLookPage.source(of: target), file.isFileURL { return isInside(file, folder) }
        return false
    }

    /// Whether `item` is directly inside `folder`.
    nonisolated static func isInside(_ item: URL, _ folder: URL) -> Bool {
        asFolder(item.standardizedFileURL.deletingLastPathComponent()).standardizedFileURL == asFolder(folder).standardizedFileURL
            && item.standardizedFileURL.path != folder.standardizedFileURL.path
    }

    /// A list's link to a file in it: WebKit won't follow one of Zigzag's pages to a file, so the list links to
    /// itself with the file to open, and the tab opens it as a local page's link would.
    nonisolated static func address(for folder: URL, opening file: URL) -> URL {
        FilePages.address(host: host, for: asFolder(folder), extra: [("open", file.absoluteString)])
    }

    /// The file such a link opens, only one in the listed folder.
    nonisolated static func opening(_ page: URL?) -> URL? {
        guard let folder = source(of: page), let text = FilePages.value("open", in: page, host: host),
              let file = URL(string: text), file.isFileURL, (file.host() ?? "").isEmpty, isInside(file, folder) else { return nil }
        return file
    }

    /// Whether a tab shows this kind of file itself (a page, a picture, a PDF, text WebKit reads, a film), so a
    /// click opens it there; anything else opens in Quick Look.
    nonisolated static func opensInTab(_ type: UTType) -> Bool {
        if QuickLookPage.documentType(type) || type.conforms(to: .directory) { return true }
        if [UTType.html, .pdf, .image, .audiovisualContent, .webArchive].contains(where: type.conforms(to:)) { return true }
        guard type.conforms(to: .text), let mime = type.preferredMIMEType else { return false }
        return mime.hasPrefix("text/") || ["application/json", "application/xml"].contains(mime)
    }

    // MARK: Reading the folder

    struct Entry: Sendable {
        let url: URL
        let name: String
        let kind: String
        let type: String
        let isFolder: Bool
        let isApp: Bool
        let size: Int64?
        let date: Date?
        let opensInTab: Bool
    }

    nonisolated static func entries(of folder: URL, hidden: Bool) -> [Entry]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                      .localizedTypeDescriptionKey, .contentTypeKey, .localizedNameKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                      options: hidden ? [] : [.skipsHiddenFiles]) else { return nil }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let type = values?.contentType ?? (values?.isDirectory == true ? .folder : .data)
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            return Entry(url: url, name: url.lastPathComponent, kind: values?.localizedTypeDescription ?? "",
                         type: type.identifier, isFolder: isFolder, isApp: type.conforms(to: .application),
                         size: isFolder ? nil : (values?.fileSize).map(Int64.init), date: values?.contentModificationDate,
                         opensInTab: isFolder || opensInTab(type))
        }
    }

    nonisolated static func sorted(_ entries: [Entry], by choice: Choice) -> [Entry] {
        func byName(_ a: Entry, _ b: Entry) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        let ascending: [Entry]
        switch choice.sort {
        case .name: ascending = entries.sorted(by: byName)
        case .kind: ascending = entries.sorted { a, b in
            let order = a.kind.localizedStandardCompare(b.kind)
            return order == .orderedSame ? byName(a, b) : order == .orderedAscending
        }
        // Folders have no size, and go first, as in Finder.
        case .size: ascending = entries.sorted { a, b in
            (a.size ?? -1) == (b.size ?? -1) ? byName(a, b) : (a.size ?? -1) < (b.size ?? -1)
        }
        case .date: ascending = entries.sorted { a, b in
            (a.date ?? .distantPast) == (b.date ?? .distantPast) ? byName(a, b) : (a.date ?? .distantPast) < (b.date ?? .distantPast)
        }
        }
        return choice.descending ? ascending.reversed() : ascending
    }

    // MARK: Serving

    private static var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    static func stop(_ task: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    struct Labels: Sendable {
        var name = String(localized: "Name", comment: "Column heading in a folder's list of files, shown in a tab.")
        var kind = String(localized: "Kind", comment: "Column heading in a folder's list of files, shown in a tab: the kind of file, like “PDF document”.")
        var size = String(localized: "Size", comment: "Column heading in a folder's list of files, shown in a tab.")
        var date = String(localized: "Date Modified", comment: "Column heading in a folder's list of files, shown in a tab.")
        var showHidden = String(localized: "Show Hidden Files", comment: "Button at the top of a folder's list of files, shown in a tab.")
        var hideHidden = String(localized: "Hide Hidden Files", comment: "Button at the top of a folder's list of files, shown in a tab, while hidden files show.")
        var enclosing = String(localized: "Enclosing Folder", comment: "Button at the top of a folder's list of files, shown in a tab: goes to the folder it's in.")
        var empty = String(localized: "This folder is empty.", comment: "Shown in place of a folder's list of files when it has none.")
        var unreadable = String(localized: "Zigzag can’t read this folder.", comment: "Shown in place of a folder's list of files when it can't be read, as with a folder macOS keeps private.")
    }

    static func serve(_ task: any WKURLSchemeTask, in webView: WKWebView) {
        guard let url = task.request.url, let folder = source(of: url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let choice = choice(of: url)
        let labels = Labels()
        let style = PageStyle.css(theme: HistoryPage.theme(for: webView)) + css
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let id = ObjectIdentifier(task)
        running[id] = Task {
            let page = await Task.detached {
                html(folder: folder, entries: entries(of: folder, hidden: choice.hidden).map { sorted($0, by: choice) },
                     choice: choice, labels: labels, style: style, language: language)
            }.value
            guard !Task.isCancelled, running.removeValue(forKey: id) != nil else { return }
            respond(task, url: url, type: "text/html; charset=utf-8", data: Data(page.utf8))
        }
    }

    private static var icons: [String: Data] = [:]

    /// A file's icon in the list: its kind's, as Finder draws it, or an app's own, only for an app in the folder
    /// the page lists.
    static func serveIcon(_ task: any WKURLSchemeTask) {
        guard let url = task.request.url, let folder = source(of: task.request.mainDocumentURL)?.standardizedFileURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let query = parts.queryItems ?? []
        let image: NSImage
        let key: String
        if let text = query.first(where: { $0.name == "app" })?.value, let app = URL(string: text), app.isFileURL,
           asFolder(app.deletingLastPathComponent()).standardizedFileURL == folder,
           (try? app.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .application) == true {
            key = app.standardizedFileURL.path
            image = NSWorkspace.shared.icon(forFile: app.path)
        } else if let identifier = query.first(where: { $0.name == "type" })?.value, let type = UTType(identifier) {
            key = identifier
            image = NSWorkspace.shared.icon(for: type)
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let data: Data
        if let kept = icons[key] {
            data = kept
        } else {
            guard let png = png(image, side: 32) else { task.didFailWithError(URLError(.cannotDecodeContentData)); return }
            if icons.count > 400 { icons.removeAll() }
            icons[key] = png
            data = png
        }
        respond(task, url: url, type: "image/png", data: data)
    }

    private static func png(_ image: NSImage, side: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
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

    // MARK: The page

    nonisolated static func html(folder: URL, entries: [Entry]?, choice: Choice, labels: Labels, style: String, language: String) -> String {
        func escape(_ s: String) -> String { MarkdownHTML.escape(s) }
        let name = folder.path == "/" ? "/" : FileManager.default.displayName(atPath: folder.path)
        var page = "<!doctype html>\n<html lang=\"\(escape(language))\">\n<head>\n<meta charset=\"utf-8\">\n"
        page += "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">\n"
        page += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"referrer\" content=\"no-referrer\">\n"
        page += "<title>\(escape(name))</title>\n<style>\n\(style)</style>\n</head>\n<body>\n"
        page += "<header class=\"page-header\"><div class=\"inner\"><div class=\"page-title\"><h1>\(escape(name))</h1></div>"
        let parent = folder.deletingLastPathComponent()
        if folder.path != "/", parent.path != folder.path {
            page += "<a class=\"button quiet\" href=\"\(escape(address(for: parent).absoluteString))\">\(escape(labels.enclosing))</a>"
        }
        var flipped = choice
        flipped.hidden.toggle()
        page += "<a class=\"button\" href=\"\(escape(address(for: folder, flipped).absoluteString))\">\(escape(choice.hidden ? labels.hideHidden : labels.showHidden))</a>"
        page += "</div></header>\n<main>\n"
        guard let entries else {
            page += "<p class=\"note\">\(escape(labels.unreadable))</p>\n</main>\n</body>\n</html>\n"
            return page
        }
        page += "<div class=\"list\" role=\"table\" aria-label=\"\(escape(name))\">\n<div class=\"head\" role=\"row\">"
        for (sort, title) in [(Sort.name, labels.name), (.kind, labels.kind), (.size, labels.size), (.date, labels.date)] {
            var next = choice
            next.sort = sort
            // A click on the column it's sorted by turns the order around; another column starts from its top.
            next.descending = choice.sort == sort ? !choice.descending : sort == .date || sort == .size
            let shown = choice.sort == sort
            page += "<a class=\"\(sort.rawValue)\(shown ? " sorted" : "")\" role=\"columnheader\""
            if shown { page += " aria-sort=\"\(choice.descending ? "descending" : "ascending")\"" }
            page += " href=\"\(escape(address(for: folder, next).absoluteString))\">\(escape(title))"
            if shown { page += choice.descending ? chevronDown : chevronUp }
            page += "</a>"
        }
        page += "</div>\n"
        let sizes = ByteCountFormatter()
        sizes.countStyle = .file
        let dates = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Words.locale)
        for entry in entries {
            let icon = entry.isApp
                ? "\(MarkdownPage.scheme)://\(iconHost)?app=" + (entry.url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))) ?? "")
                : "\(MarkdownPage.scheme)://\(iconHost)?type=" + (entry.type.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-"))) ?? "")
            // A folder opens its list, a file the tab shows opens there, any other in Quick Look, as Finder shows it.
            let target = entry.isFolder ? address(for: entry.url) : entry.opensInTab ? address(for: folder, opening: entry.url) : QuickLookPage.address(for: entry.url)
            page += "<a class=\"row\" role=\"row\" href=\"\(escape(target.absoluteString))\">"
            page += "<span class=\"name\" role=\"cell\"><img src=\"\(escape(icon))\" alt=\"\" width=\"16\" height=\"16\"><span>\(escape(entry.name))</span></span>"
            page += "<span class=\"kind\" role=\"cell\">\(escape(entry.kind))</span>"
            page += "<span class=\"size\" role=\"cell\">\(entry.size.map { escape(sizes.string(fromByteCount: $0)) } ?? "--")</span>"
            page += "<span class=\"date\" role=\"cell\">\(entry.date.map { escape($0.formatted(dates)) } ?? "")</span></a>\n"
        }
        page += "</div>\n"
        if entries.isEmpty { page += "<p class=\"note\">\(escape(labels.empty))</p>\n" }
        page += "</main>\n</body>\n</html>\n"
        return page
    }

    private nonisolated static let chevronUp = #"<svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><path d="M2 6.5L5 3.5L8 6.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>"#
    private nonisolated static let chevronDown = #"<svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><path d="M2 3.5L5 6.5L8 3.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>"#

    /// History's rows and header: the page's gutter, rows the sidebar's height with the hover fill.
    nonisolated static let css = """
    main { max-width: calc(var(--max) + 2 * var(--gutter)); margin: 0 auto; padding: 0 var(--gutter) var(--space-8); }
    .page-header .button { flex: none; }
    .list { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 22%) 88px minmax(0, 24%); column-gap: var(--space-4);
            margin: 0 calc(-1 * var(--row-inset)); }
    .head, .row { display: grid; grid-column: 1 / -1; grid-template-columns: subgrid; align-items: center; padding: 0 var(--row-inset); }
    .head { height: var(--control-height); margin-bottom: var(--space-1); border-bottom: 1px solid var(--line); font-size: var(--small); }
    .head a { display: flex; align-items: center; gap: var(--space-1); color: var(--muted); text-decoration: none; height: 100%; min-width: 0;
              white-space: nowrap; overflow: hidden; }
    .head a:hover { color: var(--text); }
    .head a.sorted { color: var(--text); font-weight: 500; }
    .head svg { flex: none; }
    .head .size { justify-content: flex-end; }
    .row { height: var(--row); border-radius: var(--radius-row); color: var(--text); text-decoration: none; font-size: var(--row-text); }
    .row:hover { background: var(--hover); }
    .row:active { background: var(--pressed); }
    .row:focus-visible { outline-offset: -2px; }
    .row > span { min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .name { display: flex; align-items: center; gap: var(--space-2); }
    .name img { flex: none; width: 16px; height: 16px; }
    .name span { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
    .kind, .date { color: var(--muted); }
    .size { color: var(--muted); text-align: right; font-variant-numeric: tabular-nums; }
    .note { margin: var(--space-8) 0; text-align: center; color: var(--faint); }
    @media (max-width: 720px) { .list { grid-template-columns: minmax(0, 1fr) 88px minmax(0, 36%); } .list :is(.head, .row) > .kind { display: none; } }
    @media (max-width: 420px) { .list { grid-template-columns: minmax(0, 1fr) 88px; } .list :is(.head, .row) > .date { display: none; } }
    """
}
