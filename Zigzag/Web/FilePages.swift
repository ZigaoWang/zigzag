import Foundation

/// What Zigzag's file viewers have in common (#566): each shows a file at zigzag://<viewer>?url=<the file>, and the
/// address bar, history and copied links use the file's own address.
enum FilePages {
    /// The file any viewer shows: a Markdown file, a Quick Look document or a folder.
    nonisolated static func source(of page: URL?) -> URL? {
        MarkdownPage.source(of: page) ?? QuickLookPage.source(of: page) ?? FolderPage.source(of: page)
    }

    /// A viewer's address for `source`, without its fragment, with `extra` after it.
    nonisolated static func address(host: String, for source: URL, extra: [(String, String)] = []) -> URL {
        var parts = URLComponents()
        parts.scheme = MarkdownPage.scheme
        parts.host = host
        var bare = URLComponents(url: source, resolvingAgainstBaseURL: true)
        bare?.fragment = nil
        let text = bare?.string ?? source.absoluteString
        parts.percentEncodedQuery = ([("url", text)] + extra).map { "\($0.0)=" + ($0.1.addingPercentEncoding(withAllowedCharacters: queryValue) ?? "") }
            .joined(separator: "&")
        return parts.url!
    }

    /// A viewer's query value, read back.
    nonisolated static func value(_ name: String, in page: URL?, host: String) -> String? {
        guard let page, page.scheme?.lowercased() == MarkdownPage.scheme, page.host() == host,
              let parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        return parts.queryItems?.first(where: { $0.name == name })?.value
    }

    /// The file a viewer's address names, if its scheme is one of `schemes`.
    nonisolated static func source(of page: URL?, host: String, schemes: Set<String>) -> URL? {
        guard let text = value("url", in: page, host: host), let source = URL(string: text),
              schemes.contains(source.scheme?.lowercased() ?? ""), source.fragment == nil else { return nil }
        if source.isFileURL, !(source.host() ?? "").isEmpty { return nil }
        return source
    }

    private nonisolated static let queryValue: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/:")
        return set
    }()
}

extension FilePages {
    /// Whether a viewer's page may send its tab to `target`, one of Zigzag's own pages: a Markdown file only within
    /// itself, a folder's list to itself sorted another way or to Quick Look for a file in it, Quick Look's blank
    /// nowhere. Zigzag's other pages as before.
    nonisolated static func mayLink(fromHost sourceHost: String, current: URL?, to target: URL) -> Bool {
        switch sourceHost {
        case MarkdownPage.host: MarkdownPage.mayLink(fromHost: sourceHost, current: current, to: target)
        case FolderPage.host: FolderPage.mayLink(current: current, to: target)
        case QuickLookPage.host: false
        default: true
        }
    }

    /// Where a tab going to a local file shows it instead: a folder's list, or Quick Look for a document.
    nonisolated static func viewer(forLocal url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        if QuickLookPage.showsFile(url) { return QuickLookPage.address(for: url) }
        if FolderPage.lists(url) { return FolderPage.address(for: url) }
        return nil
    }
}
