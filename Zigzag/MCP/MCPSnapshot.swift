import Foundation

/// A page as snapshot gives it to an AI app: its landmarks, headings and text, and each element the app can use, with
/// a ref that click, type, scroll and press_key take. The page script collects it (`snapshot` in MCPPageScript);
/// this reads that and writes it out the way Playwright's snapshots read, which agents know. Plain data, so it's the
/// same on any queue and tested on its own.
///
/// Everything the page wrote (a name, a value, some text, an address) is quoted, so a page can't start a line of
/// its own or pass something off as Zigzag's; the whole of it is then set apart as page content, as every tool's
/// answer is (`markedAsPageContent`).
nonisolated struct MCPSnapshot: Equatable, Sendable {
    enum Filter: String, CaseIterable, Sendable {
        /// The page as it's laid out: landmarks, headings, lists and text, with what can be used among them.
        case all
        /// Only what can be used, one per line.
        case interactive
    }

    enum Value: Equatable, Sendable {
        case text(String)
        /// A detail the person's saved data filled in: only how long it is.
        case filled(Int)
        case password, secret
    }

    struct Node: Equatable, Sendable {
        var role: String
        var name: String?
        var ref: String?
        /// In the order they're written: `checked`, `level=2`.
        var states: [String] = []
        var value: Value?
        var url: String?
        var text: String?
        var flags: [String] = []
        /// Options a list has beyond those given.
        var more: Int?
        var children: [Node] = []
    }

    let title: String
    let url: String
    let nodes: [Node]
    /// How many elements were given a ref.
    let refs: Int
    /// The page was too large to read in full.
    let cut: Bool
    /// A dialog is open, and only it was read.
    let modal: Bool

    init(title: String, url: String, nodes: [Node], refs: Int = 0, cut: Bool = false, modal: Bool = false) {
        self.title = title
        self.url = url
        self.nodes = nodes
        self.refs = refs
        self.cut = cut
        self.modal = modal
    }

    // MARK: Reading the page script's answer

    /// Nil when it isn't a snapshot. Read as JSON, so true and 1 stay apart; anything unexpected is left out rather
    /// than trusted.
    init?(_ answer: JSON) {
        guard let nodes = answer["nodes"]?.array else { return nil }
        // Nested deeper than is read: what's under that is left out, and the snapshot says it's cut.
        var tooDeep = false
        let read = Self.nodes(nodes, depth: 0, tooDeep: &tooDeep)
        self.init(title: answer["title"]?.string ?? "", url: answer["url"]?.string ?? "", nodes: read,
                  refs: answer["refs"]?.int ?? 0, cut: (answer["cut"]?.bool ?? false) || tooDeep, modal: answer["modal"]?.bool ?? false)
    }

    /// The states written, in this order, and the flags.
    private static let stateOrder = ["checked", "disabled", "expanded", "selected", "pressed", "level", "required", "active", "scrollable"]
    private static let knownFlags = ["new", "pointer", "labelDiffers", "mixedScripts", "shortened"]

    private static func nodes(_ list: [JSON], depth: Int, tooDeep: inout Bool) -> [Node] {
        guard depth < 200 else {
            if !list.isEmpty { tooDeep = true }
            return []
        }
        var read: [Node] = []
        for object in list { if let node = node(object, depth: depth, tooDeep: &tooDeep) { read.append(node) } }
        return read
    }

    private static func node(_ object: JSON, depth: Int, tooDeep: inout Bool) -> Node? {
        guard let role = object["role"]?.string, role.range(of: #"^[a-z]{1,40}$"#, options: .regularExpression) != nil else { return nil }
        var node = Node(role: role)
        node.name = object["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        node.ref = object["ref"]?.string.flatMap { $0.range(of: MCPTarget.refPattern, options: .regularExpression) != nil ? $0 : nil }
        if let states = object["states"]?.object {
            node.states = stateOrder.compactMap { key in
                switch states[key] ?? .null {
                case .bool(true): key
                case .int(let number): key == "scrollable" ? (number > 0 ? "scrollable below=\(number)" : "scrollable") : "\(key)=\(number)"
                case .string("mixed"): "\(key)=mixed"
                default: nil
                }
            }
        }
        if object["password"]?.bool == true { node.value = .password }
        else if object["secret"]?.bool == true { node.value = .secret }
        else if let filled = object["filled"]?.int { node.value = .filled(filled) }
        else if let value = object["value"]?.string { node.value = .text(value) }
        node.url = object["url"]?.string
        node.text = object["text"]?.string
        node.flags = (object["flags"]?.array ?? []).compactMap(\.string).filter(knownFlags.contains)
        node.more = object["more"]?.int
        node.children = nodes(object["children"]?.array ?? [], depth: depth + 1, tooDeep: &tooDeep)
        return node
    }

    // MARK: Writing it out

    /// The snapshot as an app reads it, and whether `maxChars` cut it.
    func text(filter: Filter = .all, depth: Int? = nil, maxChars: Int = .max) -> (text: String, truncated: Bool) {
        // The header's title and address are shorter still, so even the smallest snapshot has room for the page.
        var head = ["Page \(Self.quote(Self.clipped(title, to: 120))) at \(Self.quote(Self.clipped(Self.withoutFragment(url), to: 120)))"]
        if modal { head.append("A dialog is open: the rest of the page is behind it, and only the dialog is listed.") }
        head.append("")
        var lines = self.lines(filter: filter, depth: depth)

        let whole = (head + lines).joined(separator: "\n")
        guard whole.count > maxChars else { return (whole, false) }
        // Too long: the start, and the end too, where a dialog's buttons and a page's last links usually are. The room
        // left once the header and the note (at its longest) are counted, with a line break each.
        let headText = head.joined(separator: "\n")
        let room = max(0, maxChars - headText.count - Self.cutNote(lines.count).count - 2)
        // Written again with what the page wrote kept short: a long paragraph first would otherwise leave room for
        // nothing else. Only its words are cut, inside their quotes: a line keeps its ref and its marks.
        // An eighth of the room each: a line holds two at most (a name and a value), so with what else is on it, it
        // fits either part, the smaller one too. Each part is lines in a row, with no gaps: a line under another
        // belongs to it.
        lines = self.lines(filter: filter, depth: depth, most: max(20, room / 8))
        var top: [String] = [], bottom: [String] = []
        var used = 0
        for line in lines {
            guard used + line.count + 1 <= room * 4 / 5 else { break }
            top.append(line)
            used += line.count + 1
        }
        used = 0
        for line in lines.dropFirst(top.count).reversed() {
            guard used + line.count + 1 <= room / 5 else { break }
            bottom.insert(line, at: 0)
            used += line.count + 1
        }
        let left = lines.count - top.count - bottom.count
        let text = (head + top + [Self.cutNote(left)] + bottom).joined(separator: "\n")
        guard text.count > maxChars else { return (text, true) }
        // Only a limit smaller than the header itself gets here: whole lines, as many as fit.
        var fitting = ""
        for line in text.components(separatedBy: "\n") {
            let next = fitting.isEmpty ? line : fitting + "\n" + line
            guard next.count <= maxChars else { break }
            fitting = next
        }
        return (fitting, true)
    }

    /// Its lines. `most`: how long anything the page wrote (a name, some text, a value, an address) may be in them.
    private func lines(filter: Filter, depth: Int?, most: Int = .max) -> [String] {
        var lines: [String] = []
        switch filter {
        case .all: for node in nodes { write(node, indent: 0, depth: depth, most: most, into: &lines) }
        case .interactive: for node in Self.usable(nodes) { lines.append(line(node, children: false, most: most)) }
        }
        if lines.isEmpty { lines.append(filter == .interactive ? "(Nothing on the page can be used.)" : "(The page shows nothing.)") }
        if cut { lines.append("The page is very large: this is its first part.") }
        return lines
    }

    /// Something the page wrote, in quotes, at most about `most` long as written: quoting doubles a string full of
    /// quotes, so it's what's written that is measured, and the string cut shorter until that fits.
    private static func said(_ string: String, most: Int) -> String {
        var written = quote(clipped(string, to: most))
        // With no limit there's nothing to fit (and nothing to add to it: `most` may be the largest number there is).
        guard most < string.count * 2 + 2 else { return written }
        var keep = min(most, string.count)
        // The two quotes around it, and the mark that it was cut, come on top of what's kept.
        while written.count - 3 > most, keep > 1 {
            keep = keep * 3 / 4
            written = quote(clipped(string, to: keep))
        }
        return written
    }

    private static func cutNote(_ left: Int) -> String {
        "… \(left) lines left out. Narrow it with ref, depth or filter: \"interactive\"."
    }

    private func write(_ node: Node, indent: Int, depth: Int?, most: Int, into lines: inout [String]) {
        // A list item holding one thing is that thing: a line less for each entry of a menu.
        if node.role == "listitem", node.name == nil, node.ref == nil, node.states.isEmpty, node.children.count == 1,
           let only = node.children.first, only.role != "text" {
            write(only, indent: indent, depth: depth, most: most, into: &lines)
            return
        }
        let pad = String(repeating: "  ", count: indent)
        let deeper = depth.map { indent + 1 < $0 } ?? true
        // A node holding one piece of text and nothing else says it on its own line.
        if deeper, node.value == nil, node.url == nil, node.more == nil, node.children.count == 1,
           let only = node.children.first, only.role == "text", let text = only.text, only.flags.isEmpty {
            lines.append(pad + line(node, children: false, most: most) + ": " + Self.said(text, most: most))
            return
        }
        let shown = deeper ? node.children : []
        // A frame's origin is on its own line already.
        let url = node.role == "iframe" ? nil : node.url
        lines.append(pad + line(node, children: !shown.isEmpty || url != nil || node.more != nil, most: most))
        if let url { lines.append(pad + "  - /url: " + Self.said(shownURL(url), most: most)) }
        for child in shown { write(child, indent: indent + 1, depth: depth, most: most, into: &lines) }
        if let more = node.more { lines.append(pad + "  - (\(more) more options)") }
    }

    /// One node's line: role, name, states, ref, flags, value. `children`: lines follow under it.
    private func line(_ node: Node, children: Bool, most: Int) -> String {
        if node.role == "text" { return "- text: " + Self.said(node.text ?? "", most: most) + Self.flags(node.flags) }
        var line = "- " + node.role
        if let name = node.name { line += " " + Self.said(name, most: most) }
        if node.role == "iframe" { return line + " (not read)" + (node.url.map { ": " + Self.said($0, most: most) } ?? "") }
        for state in node.states { line += " [\(state)]" }
        if let ref = node.ref { line += " [ref=\(ref)]" }
        if node.role == "link", let url = node.url, otherSite(url) { line += " [other site]" }
        line += Self.flags(node.flags)
        switch node.value {
        // An empty field says nothing more.
        case .text(let value): line += value.isEmpty ? (children ? ":" : "") : ": " + Self.said(value, most: most)
        case .filled(let length): line += " [filled, \(length) characters]"
        case .password: line += " [password]"
        case .secret: line += " [secret]"
        case nil: if children { line += ":" }
        }
        return line
    }

    private static func flags(_ flags: [String]) -> String {
        flags.map { flag in
            switch flag {
            case "pointer": " [cursor=pointer]"
            case "labelDiffers": " [label differs]"
            case "mixedScripts": " [mixed scripts]"
            default: " [\(flag)]"
            }
        }.joined()
    }

    /// Every node with a ref, in page order.
    private static func usable(_ nodes: [Node]) -> [Node] {
        nodes.flatMap { node -> [Node] in
            var flat = node
            flat.children = []
            return (node.ref != nil ? [flat] : []) + usable(node.children)
        }
    }

    /// A string from the page, quoted and escaped as JSON does it.
    static func quote(_ string: String) -> String { JSON.string(string).text }

    /// A page's address without its #fragment, where words can ride along unseen.
    static func withoutFragment(_ address: String) -> String {
        guard let hash = address.firstIndex(of: "#") else { return address }
        return String(address[..<hash])
    }

    /// A link to another site than the page's, by registrable domain: docs.github.com is still GitHub's own, and a
    /// lookalike (xn--…) never is. A mailto: or tel: link has no site.
    private func otherSite(_ link: String) -> Bool {
        guard let other = URL(string: link)?.host()?.lowercased() else { return false }
        guard let page = URL(string: url)?.host()?.lowercased() else { return true }
        return (HostText.registrableDomain(of: page) ?? page) != (HostText.registrableDomain(of: other) ?? other)
    }

    /// A link to the page's own origin as its path and query; anywhere else in full, so its host is always seen, and
    /// without a "user:pass@" that could put another site's name first (AddressText). At most 200 characters: the
    /// host and path are at the start, where they're read.
    private func shownURL(_ link: String) -> String {
        let shown: String
        if let parsed = URL(string: link), parsed.user != nil || parsed.password != nil {
            shown = Self.withoutFragment(AddressText.withoutUserInfo(parsed).absoluteString)
        } else if let target = URL(string: link), let page = URL(string: url), target.host() != nil,
           target.scheme == page.scheme, target.host()?.lowercased() == page.host()?.lowercased(), target.port == page.port {
            let path = target.path(percentEncoded: true)
            shown = (path.isEmpty ? "/" : path) + (target.query(percentEncoded: true).map { "?" + $0 } ?? "")
        } else {
            shown = Self.withoutFragment(link)
        }
        return Self.clipped(shown)
    }

    /// At most `limit` characters of something the page wrote: what matters (a host and path, a title's start) is first.
    static func clipped(_ string: String, to limit: Int = 200) -> String {
        string.count > limit ? String(string.prefix(limit)) + "…" : string
    }
}
