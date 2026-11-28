import AppKit
import WebKit

/// An extension's address bar keyword (`"omnibox": {"keyword": "rd"}`): in the command bar, the keyword and a space
/// (or Tab) hand what you type next to the extension, as in Chrome.
nonisolated struct OmniboxKeyword: Equatable, Sendable {
    let extensionID: String
    /// As the manifest gives it; matched without regard to case.
    let keyword: String
    let name: String

    /// The keyword a manifest declares, if it's one you could type: not empty, no spaces.
    static func keyword(in manifest: [String: Any]) -> String? {
        guard let omnibox = manifest["omnibox"] as? [String: Any], let keyword = omnibox["keyword"] as? String else { return nil }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        return trimmed
    }

    /// One keyword per word: when two extensions declare the same one, the first in the list keeps it, as in Chrome.
    static func unique(_ keywords: [OmniboxKeyword]) -> [OmniboxKeyword] {
        var seen = Set<String>()
        return keywords.filter { seen.insert($0.keyword.lowercased()).inserted }
    }

    /// Leaves out a keyword one of Zigzag's site searches already answers to ("yt", "gh"): what you typed before
    /// the extension came keeps meaning that site.
    static func usable(_ keywords: [OmniboxKeyword], siteSearchKeys: Set<String>) -> [OmniboxKeyword] {
        keywords.filter { !siteSearchKeys.contains($0.keyword.lowercased()) }
    }

    /// The keyword the text is exactly, ignoring case: the bar offers Tab for it.
    static func named(_ text: String, among keywords: [OmniboxKeyword]) -> OmniboxKeyword? {
        let lower = text.lowercased()
        return keywords.first { $0.keyword.lowercased() == lower }
    }

    /// Text that starts with a keyword and a space ("rd " or a pasted "rd cats"): that keyword and what follows it.
    /// Anything else, a URL or a search that only begins with the same letters, is left alone.
    static func entered(_ text: String, among keywords: [OmniboxKeyword]) -> (keyword: OmniboxKeyword, rest: String)? {
        guard let space = text.firstIndex(of: " ") else { return nil }
        guard let keyword = named(String(text[..<space]), among: keywords) else { return nil }
        return (keyword, String(text[text.index(after: space)...]))
    }

    /// Chrome's dispositions for onInputEntered. A new tab bar has no page of its own to open in, so Return there
    /// opens a new tab; ⌘ opens one behind, ⌘⇧ or ⌥ one in front, as Chrome does on a Mac.
    static func disposition(modifiers: NSEvent.ModifierFlags, inNewTab: Bool) -> String {
        let keys = modifiers.intersection([.command, .shift, .option])
        if keys.contains(.command) { return keys.contains(.shift) ? "newForegroundTab" : "newBackgroundTab" }
        if keys.contains(.option) || inNewTab { return "newForegroundTab" }
        return "currentTab"
    }
}

/// Chrome's suggestion markup (`<match>`, `<dim>`, `<url>` and XML entities) as plain text with the stretches each
/// style covers. Any other tag is dropped; nothing is ever rendered as HTML.
nonisolated enum OmniboxText {
    enum Style: String, Equatable, Sendable { case match, dim, url }

    struct Run: Equatable, Sendable {
        /// In the plain text, in UTF-16 units.
        var range: NSRange
        var styles: Set<Style>
    }

    struct Styled: Equatable, Sendable {
        var text: String
        var runs: [Run]
    }

    /// Longer descriptions are cut, so one row stays one row.
    static let limit = 300

    static func parse(_ markup: String) -> Styled {
        var text = ""
        var runs: [Run] = []
        var open: [Style: Int] = [:]
        var length = 0
        func append(_ piece: String) {
            // Line breaks and tabs read as spaces, and runs of spaces as one, as Chrome shows them.
            var kept = ""
            var units = 0
            for character in piece {
                let space = character.isWhitespace
                if space, kept.last == " " || (kept.isEmpty && (text.isEmpty || text.last == " ")) { continue }
                let next = space ? " " : character
                guard length + units + next.utf16.count <= limit else { break }
                kept.append(next)
                units += next.utf16.count
            }
            guard !kept.isEmpty else { return }
            let styles = Set(open.filter { $0.value > 0 }.map(\.key))
            let range = NSRange(location: length, length: units)
            if !styles.isEmpty {
                if let last = runs.last, last.styles == styles, NSMaxRange(last.range) == range.location {
                    runs[runs.count - 1].range.length += range.length
                } else {
                    runs.append(Run(range: range, styles: styles))
                }
            }
            text += kept
            length += units
        }
        var rest = Substring(markup)
        while let lt = rest.firstIndex(of: "<") {
            append(decode(rest[..<lt]))
            guard let gt = rest[lt...].firstIndex(of: ">") else {
                // An unclosed "<" is only a letter.
                append(decode(rest[lt...]))
                rest = ""
                break
            }
            var tag = rest[rest.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces)
            let closing = tag.hasPrefix("/")
            if closing { tag.removeFirst() }
            let selfClosing = tag.hasSuffix("/")
            let name = tag.prefix { $0.isLetter }.lowercased()
            if let style = Style(rawValue: name), !selfClosing {
                open[style, default: 0] += closing ? -1 : 1
                if open[style, default: 0] < 0 { open[style] = 0 }
            }
            rest = rest[rest.index(after: gt)...]
        }
        append(decode(rest))
        // No space left at the end where a tag stood.
        while text.hasSuffix(" ") {
            text.removeLast()
            length -= 1
            runs = runs.compactMap { run in
                var run = run
                run.range.length = min(run.range.length, length - run.range.location)
                return run.range.length > 0 ? run : nil
            }
        }
        return Styled(text: text, runs: runs)
    }

    /// The five XML entities and numbered characters; anything else stays as written.
    static func decode(_ piece: Substring) -> String {
        guard piece.contains("&") else { return String(piece) }
        var out = ""
        var rest = piece
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[amp...]
            guard let semi = after.prefix(12).firstIndex(of: ";") else {
                out += "&"
                rest = rest[rest.index(after: amp)...]
                continue
            }
            let name = String(after[after.index(after: amp)..<semi])
            let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
            var value: String?
            if let known = named[name] {
                value = known
            } else if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let number = digits.hasPrefix("x") || digits.hasPrefix("X") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let number, number >= 0x20, let scalar = Unicode.Scalar(number) { value = String(Character(scalar)) }
            }
            if let value {
                out += value
                rest = rest[rest.index(after: semi)...]
            } else {
                out += "&"
                rest = rest[rest.index(after: amp)...]
            }
        }
        return out + rest
    }

    /// Text put into markup as itself: typed "<b>" is shown as typed, never read as a tag.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The default suggestion's description, with `%s` standing for what's typed, as in Chrome.
    static func defaultSuggestion(_ markup: String, typed: String) -> Styled {
        guard let range = markup.range(of: "%s") else { return parse(markup) }
        return parse(markup.replacingCharacters(in: range, with: escape(typed)))
    }
}

/// `chrome.omnibox`, which WebKit doesn't have: the command bar's keyword mode tells the extension what's typed and
/// shows what it suggests (bridge.js turns its `suggest` callback into calls here). Typing a keyword is something you
/// do, so Site Access doesn't apply; private windows offer only extensions allowed in them.
@available(macOS 15.4, *)
@MainActor
final class BridgeOmnibox: BridgeNamespace {
    static let name = "omnibox"
    static let permission = ""
    static let events = ["omnibox.onInputStarted", "omnibox.onInputChanged", "omnibox.onInputEntered", "omnibox.onInputCancelled"]
    /// The extensions it answers: one profile's.
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }

    struct Suggestion: Equatable {
        /// What's sent back when it's picked.
        let content: String
        let description: OmniboxText.Styled
    }

    /// Each extension's setDefaultSuggestion, as markup.
    private var defaults: [String: String] = [:]
    /// The keyword being typed for each extension, while the bar is in its keyword mode.
    private var inputs: [String: OmniboxInput] = [:]
    private var lastRequest = 0
    /// Events for a background that's asleep, sent once it listens again.
    private var queued: [String: [(event: String, args: [Any], isPrivate: Bool, at: Date)]] = [:]
    private var flushWork: DispatchWorkItem?

    /// How an event reaches an extension; tests stand in for the bridge's port.
    lazy var send: (String, String, [Any], Bool) -> Void = { [unowned self] id, event, args, isPrivate in
        host.bridge.emit(event, args, to: id, isPrivate: isPrivate)
    }
    lazy var isListening: (String, String) -> Bool = { [unowned self] id, event in host.bridge.isListened(event, by: id) }
    lazy var wake: (String) -> Void = { [unowned self] id in
        guard let context = host.context(for: id), context.webExtension.hasBackgroundContent else { return }
        Task { try? await context.loadBackgroundContent() }
    }

    /// The keywords of the extensions that are on, in the order they load; in a private window, only those allowed there.
    func keywords(isPrivate: Bool) -> [OmniboxKeyword] {
        OmniboxKeyword.usable(OmniboxKeyword.unique(host.contexts.compactMap { context in
            guard PrivateAccess.sees(isPrivate: isPrivate, allowed: context.hasAccessToPrivateData),
                  let keyword = OmniboxKeyword.keyword(in: context.webExtension.manifest) else { return nil }
            return OmniboxKeyword(extensionID: context.uniqueIdentifier, keyword: keyword, name: context.webExtension.displayName ?? keyword)
        }), siteSearchKeys: Self.siteSearchKeys)
    }

    private static var siteSearchKeys: Set<String> { Set(SiteSearch.all.flatMap(\.keys)) }

    func icon(for extensionID: String) -> NSImage? {
        host.context(for: extensionID)?.webExtension.icon(for: NSSize(width: Tokens.Metric.favicon, height: Tokens.Metric.favicon))
    }

    func defaultSuggestion(for extensionID: String) -> String? { defaults[extensionID] }

    func call(_ fn: String, args: [Any], extensionID: String) async throws -> Any? {
        switch fn {
        case "setDefaultSuggestion":
            guard let description = args.object(0).string("description") else { throw BridgeError("omnibox.setDefaultSuggestion needs a description") }
            defaults[extensionID] = String(description.prefix(2000))
            inputs[extensionID]?.onChange?()
            return nil
        case "suggest":
            // Only the answer for what's typed now; a late one for earlier text is dropped.
            guard let request = args.number(0).map({ Int(saturating: $0) }), let input = inputs[extensionID], input.request == request else { return nil }
            let list = (args.indices.contains(1) ? args[1] as? [Any] : nil) ?? []
            input.suggestions = Self.suggestions(from: list)
            input.onChange?()
            return nil
        default:
            throw BridgeError.unsupported(Self.name, fn)
        }
    }

    /// What `suggest` was given, as rows: each needs content and a description; a few at most.
    static func suggestions(from list: [Any]) -> [Suggestion] {
        list.prefix(12).compactMap { item in
            guard let item = item as? [String: Any], let content = item.string("content"), !content.isEmpty,
                  let description = item.string("description") else { return nil }
            return Suggestion(content: String(content.prefix(2000)), description: OmniboxText.parse(String(description.prefix(2000))))
        }
    }

    // MARK: Input

    /// The keyword was entered: onInputStarted.
    func start(_ keyword: OmniboxKeyword, isPrivate: Bool) -> OmniboxInput {
        inputs[keyword.extensionID]?.isOpen = false
        let input = OmniboxInput(keyword: keyword, isPrivate: isPrivate, omnibox: self)
        inputs[keyword.extensionID] = input
        tell(keyword.extensionID, "omnibox.onInputStarted", [], isPrivate: isPrivate)
        return input
    }

    fileprivate func change(_ input: OmniboxInput, _ text: String) {
        guard input.isOpen, inputs[input.keyword.extensionID] === input else { return }
        lastRequest += 1
        input.request = lastRequest
        tell(input.keyword.extensionID, "omnibox.onInputChanged", [text, lastRequest], isPrivate: input.isPrivate)
    }

    fileprivate func finish(_ input: OmniboxInput, entered: (text: String, disposition: String)?) {
        guard input.isOpen else { return }
        input.isOpen = false
        if inputs[input.keyword.extensionID] === input { inputs[input.keyword.extensionID] = nil }
        if let entered {
            tell(input.keyword.extensionID, "omnibox.onInputEntered", [entered.text, entered.disposition], isPrivate: input.isPrivate)
        } else {
            tell(input.keyword.extensionID, "omnibox.onInputCancelled", [], isPrivate: input.isPrivate)
        }
    }

    /// An event for the extension now, or once its background, asleep, is woken and listening again.
    private func tell(_ id: String, _ event: String, _ args: [Any], isPrivate: Bool) {
        if Self.events.contains(where: { isListening(id, $0) }) {
            if isListening(id, event) { send(id, event, args, isPrivate) }
            return
        }
        let now = Date()
        let waiting = (queued[id] ?? []).filter { now.timeIntervalSince($0.at) < 15 }.suffix(20)
        queued[id] = Array(waiting) + [(event, args, isPrivate, now)]
        if waiting.isEmpty { wake(id) }
    }

    /// Something started listening: once a woken background has added its listeners, it gets what it missed.
    func startEvents() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func flush(now: Date = Date()) {
        for (id, events) in queued {
            let fresh = events.filter { now.timeIntervalSince($0.at) < 15 }
            guard !fresh.isEmpty else { queued[id] = nil; continue }
            guard Self.events.contains(where: { isListening(id, $0) }) else { queued[id] = fresh; continue }
            queued[id] = nil
            for event in fresh where isListening(id, event.event) { send(id, event.event, event.args, event.isPrivate) }
        }
    }

    func release(_ extensionID: String) {
        defaults[extensionID] = nil
        inputs[extensionID]?.isOpen = false
        inputs[extensionID] = nil
        queued[extensionID] = nil
    }
}

/// What's typed after one keyword, from the moment it's entered until Return or leaving it.
@available(macOS 15.4, *)
@MainActor
final class OmniboxInput {
    let keyword: OmniboxKeyword
    let isPrivate: Bool
    private weak var omnibox: BridgeOmnibox?
    fileprivate(set) var isOpen = true
    /// The latest onInputChanged, which its suggestions answer.
    fileprivate(set) var request = 0
    /// What the extension last suggested.
    fileprivate(set) var suggestions: [BridgeOmnibox.Suggestion] = []
    /// Suggestions or the default suggestion changed.
    var onChange: (() -> Void)?

    fileprivate init(keyword: OmniboxKeyword, isPrivate: Bool, omnibox: BridgeOmnibox) {
        self.keyword = keyword
        self.isPrivate = isPrivate
        self.omnibox = omnibox
    }

    var defaultSuggestion: String? { omnibox?.defaultSuggestion(for: keyword.extensionID) }
    var icon: NSImage? { omnibox?.icon(for: keyword.extensionID) }

    func change(_ text: String) { omnibox?.change(self, text) }
    func enter(_ text: String, disposition: String) { omnibox?.finish(self, entered: (text, disposition)) }
    func cancel() { omnibox?.finish(self, entered: nil) }
}
