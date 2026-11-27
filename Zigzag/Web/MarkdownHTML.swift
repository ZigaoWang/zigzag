import Foundation
import Markdown

/// Markdown as HTML for the file viewer (`MarkdownPage`), GitHub-flavored: tables, task lists, strikethrough and
/// fenced code. Every piece of the file's text is escaped. Raw HTML shows as text, apart from comments (dropped)
/// and a few plain inline tags with no attributes (`<br>`, `<kbd>`, `<sup>`…). Links go only to the web, mail,
/// phone numbers and, from a file on this Mac, other local files; pictures only to the web, `data:image/` and
/// what `localPicture` allows. Anything else keeps its words and loses its link or picture.
nonisolated struct MarkdownHTML {
    struct Rendered: Sendable, Equatable {
        /// What goes inside `<article>`.
        let body: String
        /// The first top-level heading's words, else the first heading's.
        let title: String?
    }

    /// The source view's anchor: no heading may take it.
    static let reservedAnchor = "zigzag-source"

    /// `base`: the file's address, for relative links and pictures. `localPicture`: the address a picture on this
    /// Mac is shown from, or nil where the page may not read it.
    static func render(_ text: String, base: URL, localPicture: @escaping (URL) -> URL? = { _ in nil }) -> Rendered {
        let document = Document(parsing: text, options: [.disableSmartOpts, .disableSourcePosOpts])
        var writer = Writer(base: base, localPicture: localPicture)
        writer.out.reserveCapacity(text.utf8.count + text.utf8.count / 2)
        writer.visit(document)
        return Rendered(body: writer.out, title: writer.firstH1 ?? writer.firstHeading)
    }

    // MARK: Escaping

    /// The text with `& < > " '` as entities: safe between tags and inside a double-quoted attribute.
    static func escape(_ text: some StringProtocol) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        escape(text, into: &out)
        return out
    }

    static func escape(_ text: some StringProtocol, into out: inout String) {
        let bytes = text.utf8
        var run = bytes.startIndex
        var i = run
        while i != bytes.endIndex {
            let entity: String? = switch bytes[i] {
            case UInt8(ascii: "&"): "&amp;"
            case UInt8(ascii: "<"): "&lt;"
            case UInt8(ascii: ">"): "&gt;"
            case UInt8(ascii: "\""): "&quot;"
            case UInt8(ascii: "'"): "&#39;"
            default: nil
            }
            if let entity {
                out += text[run..<i]
                out += entity
                run = bytes.index(after: i)
            }
            i = bytes.index(after: i)
        }
        out += text[run..<bytes.endIndex]
    }

    // MARK: Where links and pictures go

    /// A link's `href`, or nil to keep only its words. A link within the same file becomes its `#fragment`.
    static func linkTarget(_ destination: String?, base: URL) -> String? {
        guard let raw = destination?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") { return "#" + fragment(String(raw.dropFirst())) }
        guard let url = resolve(raw, against: base), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https", "file":
            // A local file links to other local files, as a file page can; a page from the web never does.
            if scheme == "file", !base.isFileURL || !isLocal(url) { return nil }
            if sameDocument(url, base), let target = url.fragment(percentEncoded: true) { return "#" + target }
            return url.absoluteString
        case "mailto", "tel":
            return url.absoluteString
        default:
            return nil
        }
    }

    /// A picture's `src`, or nil to show its words instead.
    static func pictureSource(_ source: String?, base: URL, localPicture: (URL) -> URL?) -> String? {
        guard let raw = source?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("data:image/") { return raw }
        guard let url = resolve(raw, against: base), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.absoluteString
        case "file": return base.isFileURL && isLocal(url) ? localPicture(url)?.absoluteString : nil
        default: return nil
        }
    }

    /// A file on this Mac, not one on another computer (`file://server/…`).
    private static func isLocal(_ url: URL) -> Bool {
        let host = url.host(percentEncoded: false) ?? ""
        return host.isEmpty || host.lowercased() == "localhost"
    }

    private static func resolve(_ raw: String, against base: URL) -> URL? {
        if let url = URL(string: raw, relativeTo: base) { return url.absoluteURL.standardized }
        // A path with spaces or other letters a URL can't hold as written (`<my notes.md>`).
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: "#?=&%")
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: encoded, relativeTo: base)?.absoluteURL.standardized
    }

    private static func sameDocument(_ url: URL, _ base: URL) -> Bool {
        func bare(_ u: URL) -> String? {
            guard var parts = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return nil }
            parts.fragment = nil
            return parts.string
        }
        return bare(url) != nil && bare(url) == bare(base)
    }

    private static func fragment(_ text: String) -> String {
        let decoded = text.removingPercentEncoding ?? text
        return decoded.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
    }

    /// A heading's anchor as GitHub makes it: lowercase, letters, digits, `-` and `_`, spaces as `-`.
    static func slug(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " { out += "-" }
            else if scalar == "-" || scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil { out.unicodeScalars.append(scalar) }
        }
        return out
    }

    // MARK: Writing

    /// Inline tags a file may use as they are: no attributes, nothing that loads or runs.
    static let plainTags: Set<String> = ["b", "i", "em", "strong", "u", "s", "del", "ins", "mark", "kbd", "sup", "sub", "small", "code"]

    private struct Writer: MarkupVisitor {
        let base: URL
        let localPicture: (URL) -> URL?
        var out = ""
        var firstH1: String?
        var firstHeading: String?
        private var anchors: [String: Int] = [MarkdownHTML.reservedAnchor: 1]
        /// Plain inline tags the file opened and hasn't closed yet; each block closes its own.
        private var openTags: [String] = []
        private var tableAlignments: [Table.ColumnAlignment?] = []
        private var tableColumn = 0
        private var inTableHead = false
        /// A task item's checkbox, waiting to go in front of the item's first words.
        private var pendingCheckbox: String?

        init(base: URL, localPicture: @escaping (URL) -> URL?) {
            self.base = base
            self.localPicture = localPicture
        }

        mutating func defaultVisit(_ markup: Markup) { descend(markup) }

        private mutating func descend(_ markup: Markup) {
            for child in markup.children { visit(child) }
        }

        private mutating func text(_ s: some StringProtocol) { MarkdownHTML.escape(s, into: &out) }

        /// Writes a block's inline content, then closes whatever plain tags it left open.
        private mutating func inline(_ markup: Markup) {
            let depth = openTags.count
            if let box = pendingCheckbox { out += box; pendingCheckbox = nil }
            descend(markup)
            while openTags.count > depth { out += "</\(openTags.removeLast())>" }
        }

        // Blocks

        mutating func visitDocument(_ document: Document) { descend(document) }

        mutating func visitParagraph(_ paragraph: Paragraph) {
            out += "<p>"
            inline(paragraph)
            out += "</p>\n"
        }

        mutating func visitHeading(_ heading: Heading) {
            let words = heading.plainText
            if heading.level == 1, firstH1 == nil { firstH1 = words }
            if firstHeading == nil { firstHeading = words }
            var anchor = MarkdownHTML.slug(words)
            if let used = anchors[anchor] {
                anchors[anchor] = used + 1
                anchor += "-\(used)"
            }
            anchors[anchor, default: 0] += 1
            let level = min(max(heading.level, 1), 6)
            out += "<h\(level) id=\""
            text(anchor)
            out += "\">"
            inline(heading)
            out += "</h\(level)>\n"
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            out += "<blockquote>\n"
            descend(blockQuote)
            out += "</blockquote>\n"
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            let language = (codeBlock.language ?? "").split(separator: " ").first.map(String.init) ?? ""
            let safe = String(language.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "+-_.#".unicodeScalars.contains($0) })
            out += safe.isEmpty ? "<pre><code>" : "<pre><code class=\"language-\(safe)\">"
            text(codeBlock.code)
            out += "</code></pre>\n"
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) {
            let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("<!--"), raw.hasSuffix("-->") { return }
            out += "<pre class=\"html\">"
            text(raw)
            out += "</pre>\n"
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) { out += "<hr>\n" }

        mutating func visitUnorderedList(_ list: UnorderedList) {
            out += list.listItems.contains(where: { $0.checkbox != nil }) ? "<ul class=\"tasks\">\n" : "<ul>\n"
            descend(list)
            out += "</ul>\n"
        }

        mutating func visitOrderedList(_ list: OrderedList) {
            out += list.startIndex == 1 ? "<ol>\n" : "<ol start=\"\(list.startIndex)\">\n"
            descend(list)
            out += "</ol>\n"
        }

        mutating func visitListItem(_ item: Markdown.ListItem) {
            if let checkbox = item.checkbox {
                out += "<li class=\"task\">"
                pendingCheckbox = checkbox == .checked ? "<input type=\"checkbox\" disabled checked> " : "<input type=\"checkbox\" disabled> "
                // An item with no words still shows its box.
                if !(item.child(at: 0) is Paragraph) { out += pendingCheckbox ?? ""; pendingCheckbox = nil }
            } else {
                out += "<li>"
            }
            descend(item)
            out += "</li>\n"
        }

        mutating func visitTable(_ table: Table) {
            tableAlignments = table.columnAlignments
            out += "<table>\n"
            descend(table)
            out += "</table>\n"
        }

        mutating func visitTableHead(_ head: Table.Head) {
            out += "<thead>\n<tr>"
            inTableHead = true
            tableColumn = 0
            descend(head)
            inTableHead = false
            out += "</tr>\n</thead>\n"
        }

        mutating func visitTableBody(_ body: Table.Body) {
            guard !body.isEmpty else { return }
            out += "<tbody>\n"
            descend(body)
            out += "</tbody>\n"
        }

        mutating func visitTableRow(_ row: Table.Row) {
            out += "<tr>"
            tableColumn = 0
            descend(row)
            out += "</tr>\n"
        }

        mutating func visitTableCell(_ cell: Table.Cell) {
            guard cell.colspan > 0, cell.rowspan > 0 else { return }
            let tag = inTableHead ? "th" : "td"
            out += "<\(tag)"
            if tableColumn < tableAlignments.count, let alignment = tableAlignments[tableColumn] {
                switch alignment {
                case .left: out += " class=\"left\""
                case .center: out += " class=\"center\""
                case .right: out += " class=\"right\""
                }
            }
            if cell.colspan > 1 { out += " colspan=\"\(cell.colspan)\"" }
            if cell.rowspan > 1 { out += " rowspan=\"\(cell.rowspan)\"" }
            out += ">"
            tableColumn += Int(cell.colspan)
            inline(cell)
            out += "</\(tag)>"
        }

        // Inlines

        mutating func visitText(_ t: Text) { text(t.string) }

        mutating func visitSoftBreak(_ softBreak: SoftBreak) { out += "\n" }

        mutating func visitLineBreak(_ lineBreak: LineBreak) { out += "<br>\n" }

        mutating func visitInlineCode(_ code: InlineCode) {
            out += "<code>"
            text(code.code)
            out += "</code>"
        }

        mutating func visitEmphasis(_ emphasis: Emphasis) { wrap("em", emphasis) }

        mutating func visitStrong(_ strong: Strong) { wrap("strong", strong) }

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) { wrap("del", strikethrough) }

        private mutating func wrap(_ tag: String, _ markup: Markup) {
            out += "<\(tag)>"
            descend(markup)
            out += "</\(tag)>"
        }

        mutating func visitLink(_ link: Link) {
            guard let href = MarkdownHTML.linkTarget(link.destination, base: base) else {
                descend(link)
                return
            }
            out += "<a href=\""
            text(href)
            out += "\""
            if let title = link.title, !title.isEmpty {
                out += " title=\""
                text(title)
                out += "\""
            }
            out += ">"
            descend(link)
            out += "</a>"
        }

        mutating func visitImage(_ image: Image) {
            let alt = image.plainText
            guard let src = MarkdownHTML.pictureSource(image.source, base: base, localPicture: localPicture) else {
                text(alt)
                return
            }
            out += "<img src=\""
            text(src)
            out += "\" alt=\""
            text(alt)
            out += "\""
            if let title = image.title, !title.isEmpty {
                out += " title=\""
                text(title)
                out += "\""
            }
            out += " loading=\"lazy\">"
        }

        mutating func visitInlineHTML(_ html: InlineHTML) {
            let raw = html.rawHTML
            if raw.hasPrefix("<!--") { return }
            guard let (closing, name) = MarkdownHTML.plainTag(raw) else {
                text(raw)
                return
            }
            if name == "br" {
                if !closing { out += "<br>" }
            } else if !closing {
                openTags.append(name)
                out += "<\(name)>"
            } else if openTags.last == name {
                openTags.removeLast()
                out += "</\(name)>"
            } else {
                text(raw)
            }
        }

        mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
            guard let destination = symbolLink.destination else { return }
            out += "<code>"
            text(destination)
            out += "</code>"
        }
    }

    /// `<b>`, `</kbd>`, `<br/>`: whether it closes, and the tag, when it's one of `plainTags` or `br` with nothing else in it.
    static func plainTag(_ raw: String) -> (closing: Bool, name: String)? {
        var body = Substring(raw)
        guard body.hasPrefix("<"), body.hasSuffix(">") else { return nil }
        body = body.dropFirst().dropLast()
        let closing = body.hasPrefix("/")
        if closing { body = body.dropFirst() }
        if body.hasSuffix("/") { body = body.dropLast() }
        let name = body.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, name.allSatisfy(\.isLetter) else { return nil }
        if name == "br" { return (closing, name) }
        return plainTags.contains(name) ? (closing, name) : nil
    }
}
