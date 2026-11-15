import Foundation
import Security
import WebKit

// MARK: - A rule

/// Where a file goes, for a rule whose destination is not another app: saved into a folder of its own, or shown by
/// Zigzag itself. A destination never cancels the download — it decides *where the file lands* — so it is read in the
/// response decision and honoured when the download is made, never run through `DownloadHandoff`.
nonisolated enum DownloadDestination: Equatable, Sendable {
    /// Save into this folder, as chosen in the panel. Empty asks for the default, which is nothing to decide.
    case folder(String)
    /// Save it where downloads go, then hand it to the Mac's own app for its type.
    case open
}

/// One thing Zigzag hands to another app: a link you click, or a download a page starts, whose address matches.
/// Rules are tried top to bottom and the first one that matches wins; a download no rule matches stays WebKit's.
nonisolated struct DownloadRule: Codable, Identifiable, Equatable, Sendable {
    /// What a rule may catch. A new rule catches downloads only, so adding one can never change how a link opens.
    enum Applies: String, Codable, CaseIterable, Sendable {
        case downloads
        case linksAndDownloads

        var title: String {
            switch self {
            case .downloads: String(localized: "Downloads only", comment: "Choice of what a download rule catches, in its editor.")
            case .linksAndDownloads: String(localized: "Links and downloads", comment: "Choice of what a download rule catches, in its editor: links you click, and files pages send.")
            }
        }
    }

    /// How a rule compares what it caught. Every kind but `fileType` reads the address; `fileType` reads the file's
    /// own name, which is how a per-extension destination is written (the file's type *is* its extension). `any` is
    /// the catch-all that sits at the bottom of the list.
    enum Match: String, Codable, CaseIterable, Sendable {
        case startsWith, contains, endsWith, regex, fileType, any

        var title: String {
            switch self {
            case .startsWith: String(localized: "Starts with", comment: "How a download rule matches an address, in its editor.")
            case .contains: String(localized: "Contains", comment: "How a download rule matches an address, in its editor.")
            case .endsWith: String(localized: "Ends with", comment: "How a download rule matches an address, in its editor.")
            case .regex: String(localized: "Regular Expression", comment: "How a download rule matches an address, in its editor.")
            case .fileType: String(localized: "File Extension", comment: "How a download rule matches a file, in its editor: by the extensions of its own name, such as pdf or epub.")
            case .any: String(localized: "Any address", comment: "How a download rule matches an address: the catch-all, for every address.")
            }
        }

        /// The extensions a `fileType` pattern names: comma-separated, whitespace and a leading dot tolerated. The
        /// extension is the part after the dot (`tar.gz` is one), so a name matches when it ends in `.<extension>`.
        static func extensions(in pattern: String) -> [String] {
            pattern.split(separator: ",").compactMap { part in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                return trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
            }
        }
    }

    var id = UUID()
    var name: String
    var isEnabled = true
    var applies: Applies = .downloads
    var match: Match = .contains
    var pattern = ""
    /// Regex and text both follow the case switch. A host is case-insensitive, so a rule for YouTube needn't say so.
    var isCaseSensitive = false
    /// When this rule takes a link, the page it was on goes no further: the tab doesn't load or follow the address
    /// it was going to. Off (the default) means the link carries on where the rule let it — in the browser, or
    /// nowhere at all where the rule handed it off. On is for a rule that catches a whole site's clicks, where the
    /// page's own loads and redirects would otherwise keep matching it.
    var stopsThePage = false
    /// Whether this rule runs in a private window. **Off by default**: a private window is a promise that what happens
    /// there leaves no trace, and a rule that hands a link to a script or another app is exactly the kind of thing that
    /// could break it. A destination is not a handoff, so this doesn't keep a private download from its own folder.
    var runsInPrivateWindows = false
    /// What this rule was told about handing off, for **every site**: "handOff", "browser" or "deny". Nil is a rule
    /// that has only been answered per site (kept under `handoff:<id>` in `SitePermissions`) or not at all. It is the
    /// third scope a question about a rule offers, and it belongs here because it is the rule's own answer: it travels
    /// with the rule and goes when the rule does.
    var handoffAnswer: String?
    var action: DownloadRuleAction

    /// A regex that doesn't compile is kept as typed but never matches, so a half-written rule can't catch anything.
    var isValidPattern: Bool {
        guard match == .regex, !pattern.isEmpty else { return true }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    /// Whether this rule catches `url`. Disabled, empty-pattern (except `any`) and broken-regex rules never do.
    func matches(_ url: URL) -> Bool {
        guard isEnabled, isValidPattern else { return false }
        let address = url.absoluteString
        switch match {
        case .any:
            return true
        case .fileType:
            // A file *type* is a file's own name, which an address on its own never is; `matches(_:filename:)` is what
            // the download path uses. A link has no name, so a type rule never catches one.
            return false
        case .startsWith:
            return address.hasPrefix(pattern, caseSensitive: isCaseSensitive)
        case .contains:
            return address.contains(pattern, caseSensitive: isCaseSensitive)
        case .endsWith:
            return address.hasSuffix(pattern, caseSensitive: isCaseSensitive)
        case .regex:
            guard !pattern.isEmpty,
                  let expression = try? NSRegularExpression(pattern: pattern,
                                                            options: isCaseSensitive ? [] : [.caseInsensitive]) else { return false }
            let range = NSRange(address.startIndex..<address.endIndex, in: address)
            return expression.firstMatch(in: address, options: [], range: range) != nil
        }
    }

    /// Whether this rule catches a download whose file is named `filename`. Only a `fileType` rule reads the name:
    /// its pattern is a comma-separated list of extensions, and the name matches when it ends in any of them.
    func matches(filename: String) -> Bool {
        guard match == .fileType, isEnabled, !filename.isEmpty else { return false }
        return Match.extensions(in: pattern).contains { filename.hasSuffix("." + $0, caseSensitive: isCaseSensitive) }
    }

    /// Whether this rule catches what was caught, in one call: the address for every kind but `fileType`, the file's
    /// own name for that one. A download passes both; a link passes an empty name.
    func matches(_ url: URL, filename: String) -> Bool {
        match == .fileType ? matches(filename: filename) : matches(url)
    }

    /// Whether the chosen action reads the tab's cookies. Only then is the cookie store asked.
    var needsCookies: Bool {
        action.textFields.contains { $0.contains("{cookies}") || $0.contains("{cookie_header}") }
    }

    /// Whether the action wants a cookies.txt file rather than a header.
    var usesCookieFile: Bool {
        action.textFields.contains { $0.contains("{cookies}") }
    }

    /// Whether this rule would send the site's cookies to a service another machine could be answering at. `{cookies}`
    /// and `{cookie_header}` carry the site's own sign-in, so a JSON-RPC endpoint that isn't on this Mac is worth
    /// saying out loud — but it's a thing you may mean (a NAS, a build box), so this only raises the warning; it
    /// doesn't refuse the rule.
    var sendsCookiesOffThisMac: Bool {
        action.kind == .jsonRPC && needsCookies && !action.endpointIsLocal
    }

    /// The rule in a sentence, as its row in Settings › Downloads says it: "Files ending in .torrent go to
    /// rTorrent". The name is your own, so a rule you named reads with it.
    var summarySentence: String {
        let goes = name.isEmpty ? action.summary : name
        if match == .any {
            return applies == .downloads
                ? String(localized: "Everything you download goes to \(goes)",
                         comment: "A download rule in a sentence: it catches every address. The placeholder is the rule's name — where the link goes.")
                : String(localized: "Every link and download goes to \(goes)",
                         comment: "A download rule in a sentence: it catches every address. The placeholder is the rule's name — where the link goes.")
        }
        let files = applies == .downloads
            ? String(localized: "Files", comment: "The subject of a download rule's sentence, for a rule that catches downloads but not links.")
            : String(localized: "Files and links", comment: "The subject of a download rule's sentence, for a rule that catches links as well as downloads.")
        let catches: String
        switch match {
        case .startsWith:
            catches = String(localized: "\(files) starting with \(pattern)", comment: "Part of a download rule's sentence: what it catches. The first placeholder is “Files” or “Files and links”, the second the beginning of the address.")
        case .contains:
            catches = String(localized: "\(files) whose address contains \(pattern)", comment: "Part of a download rule's sentence: what it catches. The first placeholder is “Files” or “Files and links”, the second the text looked for in the address.")
        case .endsWith:
            catches = String(localized: "\(files) ending in \(pattern)", comment: "Part of a download rule's sentence: what it catches. The first placeholder is “Files” or “Files and links”, the second the end of the address, such as .torrent.")
        case .regex:
            catches = String(localized: "\(files) matching \(pattern)", comment: "Part of a download rule's sentence: what it catches by regular expression. The first placeholder is “Files” or “Files and links”, the second the expression.")
        case .fileType:
            let types = DownloadRule.Match.extensions(in: pattern).joined(separator: ", ")
            catches = String(localized: "\(files) of type \(types)", comment: "Part of a download rule's sentence: what it catches by file extension. The first placeholder is “Files” or “Files and links”, the second the extensions, like “pdf, epub”.")
        case .any:
            catches = files
        }
        switch action.kind {
        case .jsonRPC:
            return String(localized: "\(catches) go to \(goes)", comment: "A download rule in a sentence: what it catches, then the service it sends it to. The placeholders are the two parts, as in “Files ending in .torrent” and “rTorrent”.")
        case .openApp, .openURL:
            return String(localized: "\(catches) open in \(goes)", comment: "A download rule in a sentence: what it catches, then the app it opens in. The placeholders are the two parts.")
        case .runScript:
            return String(localized: "\(catches) are handed to \(goes)", comment: "A download rule in a sentence: what it catches, then the script it is given to. The placeholders are the two parts.")
        case .saveToFolder:
            return String(localized: "\(catches) are saved to \(goes)", comment: "A download rule in a sentence: what it catches, then the folder it is saved into. The placeholders are the two parts, as in “Files of type pdf” and “Documents”.")
        case .openFile:
            return String(localized: "\(catches) open in your Mac’s app", comment: "A download rule in a sentence: what it catches, then that the Mac's own app for that type opens it. The placeholder is what it catches, like “Files of type pdf”.")
        }
    }

    /// A new rule with the action it was created with.
    init(name: String, applies: Applies = .downloads, match: Match = .contains, pattern: String = "",
         isCaseSensitive: Bool = false, action: DownloadRuleAction) {
        self.name = name
        self.applies = applies
        self.match = match
        self.pattern = pattern
        self.isCaseSensitive = isCaseSensitive
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, applies, match, pattern, isCaseSensitive, stopsThePage, runsInPrivateWindows,
             handoffAnswer, action
    }

    /// Older files may lack a key a newer Zigzag added: the defaults stand in, so one unreadable rule never throws
    /// away the whole list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        applies = try container.decodeIfPresent(Applies.self, forKey: .applies) ?? .downloads
        match = try container.decodeIfPresent(Match.self, forKey: .match) ?? .contains
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        isCaseSensitive = try container.decodeIfPresent(Bool.self, forKey: .isCaseSensitive) ?? false
        stopsThePage = try container.decodeIfPresent(Bool.self, forKey: .stopsThePage) ?? false
        runsInPrivateWindows = try container.decodeIfPresent(Bool.self, forKey: .runsInPrivateWindows) ?? false
        handoffAnswer = try container.decodeIfPresent(String.self, forKey: .handoffAnswer)
        action = try container.decodeIfPresent(DownloadRuleAction.self, forKey: .action) ?? DownloadRuleAction(kind: .openURL)
    }
}

nonisolated private extension String {
    func hasPrefix(_ prefix: String, caseSensitive: Bool) -> Bool {
        caseSensitive ? hasPrefix(prefix) : range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
    }

    func hasSuffix(_ suffix: String, caseSensitive: Bool) -> Bool {
        caseSensitive ? hasSuffix(suffix) : range(of: suffix, options: [.anchored, .backwards, .caseInsensitive]) != nil
    }

    func contains(_ other: String, caseSensitive: Bool) -> Bool {
        caseSensitive ? contains(other) : range(of: other, options: .caseInsensitive) != nil
    }
}

// MARK: - What a rule does

/// What an Open URL rule was told about where a web address opens: one of Zigzag's own places, or nowhere at all — the
/// answer "Always for this rule" and Don't Allow keeps. One value rather than a place and a flag, so "Mini" and "don't
/// open" can never both be true. **Nil on the action** is a rule that hasn't been told yet, which is where the
/// question comes from; it is kept out of the enum so an untold rule still saves no `openIn` key, as it always did.
nonisolated enum OpenInAnswer: Equatable, Sendable {
    case place(OpenInZigzag.Place)
    case never

    /// The place to open, where there is one; nil for the answer that opens nothing.
    var place: OpenInZigzag.Place? {
        if case .place(let place) = self { return place }
        return nil
    }

    /// What the answer that opens nothing is called, where it is chosen and where it is listed.
    static var neverTitle: String {
        String(localized: "Don’t Open", comment: "Choice in an Open URL download rule's Open in dropdown: the rule does not open anything, for any site. It is the answer “Always for this rule” and Don’t Allow keeps.")
    }
}

extension OpenInAnswer: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        if text == "never" {
            self = .never
        } else if let place = OpenInZigzag.Place(rawValue: text) {
            self = .place(place)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an Open URL answer: \(text)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .never: try container.encode("never")
        case .place(let place): try container.encode(place.rawValue)
        }
    }
}

/// The action behind a rule. One flat shape with a `kind`, rather than an enum with a payload each, so the file stays
/// readable, a field a newer Zigzag adds doesn't break an older one, and the editor's fields map one to one.
nonisolated struct DownloadRuleAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case openApp
        case openURL
        case runScript
        case jsonRPC
        /// A per-extension destination, not a handoff: the file is saved as it always was, into a folder of its own.
        /// It is decided when WebKit makes the download (`DownloadDestination`), never run from the handoff path.
        case saveToFolder
        /// The other per-extension destination: the file is saved where downloads go and then handed to the Mac's own
        /// app for its type — the one a double-click in Finder would open. Never a chosen app: choosing one is a
        /// handoff, and a handoff is a different question.
        case openFile

        /// Whether this kind is a destination rather than a handoff action: it never cancels the download, so it is
        /// made from the per-extension panel, not from Add Rule's Custom… menu.
        var isDestination: Bool { self == .saveToFolder || self == .openFile }

        /// Why a script's own output may not name this kind, or nil when it may. **One level only:** a script that
        /// could name another script would be a way to make one script run another, and a rule shouldn't be able to
        /// write a loop. A destination is the other refusal, for a different reason: it says where a file *lands*,
        /// which is decided where WebKit makes the download, and it is never run as an action at all.
        var refusesScripts: String? {
            switch self {
            case .openApp, .openURL, .jsonRPC: nil
            case .runScript: String(localized: "A script can’t name another script.", comment: "Why a download rule failed: the script's own output named another script to run, which a script may not name, so nothing ran.")
            case .saveToFolder, .openFile: String(localized: "A script can’t choose where a download is saved.", comment: "Why a download rule failed: the script's own output named a save destination, which is decided where the download is made, so nothing ran.")
            }
        }

        var title: String {
            switch self {
            case .openApp: String(localized: "Open App", comment: "An action a download rule can take, in its editor: hand the link to an app.")
            case .openURL: String(localized: "Open URL", comment: "An action a download rule can take, in its editor: open a URL, which may point at another app.")
            case .runScript: String(localized: "Run Script", comment: "An action a download rule can take, in its editor: run an executable with the link as an argument.")
            case .jsonRPC: String(localized: "JSON-RPC", comment: "An action a download rule can take, in its editor: send the link to a service such as aria2 or rTorrent.")
            case .saveToFolder: String(localized: "Save", comment: "A destination a file of a given type can have: saved into a folder, which starts as the one downloads already go to.")
            case .openFile: String(localized: "Open", comment: "A destination a file of a given type can have: saved where downloads go, then opened in the Mac's own app for that type.")
            }
        }

        var symbol: String {
            switch self {
            case .openApp: "arrow.up.forward.app"
            case .openURL: "link"
            case .runScript: "terminal"
            case .jsonRPC: "network"
            case .saveToFolder: "folder"
            case .openFile: "arrow.up.forward.app"
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            // "showInZigzag" was this case while it opened the file in a tab. It opens the Mac's app instead now, and
            // a rule saved then still reads as the nearest thing: open it, not save it and say nothing.
            if raw == "showInZigzag" { self = .openFile; return }
            guard let kind = Kind(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown download rule action \(raw).")
            }
            self = kind
        }
    }

    /// How a JSON-RPC action speaks. rTorrent's own API is XML-RPC; aria2, Motrix and qBittorrent take JSON.
    enum RPCStyle: String, Codable, CaseIterable, Sendable {
        case json
        case xmlrpc

        var title: String {
            switch self {
            case .json: String(localized: "JSON-RPC", comment: "Choice of how a rule talks to a service, in its editor: the JSON-RPC protocol.")
            case .xmlrpc: String(localized: "XML-RPC", comment: "Choice of how a rule talks to a service, in its editor: the XML-RPC protocol, which rTorrent uses.")
            }
        }
    }

    var kind: Kind = .openURL
    /// Where this action sends the file, for the two destination kinds that don't hand it to another app: a folder of
    /// its own, or Zigzag showing it. Nil for the four handoff actions, which `DownloadHandoff` runs.
    var destination: DownloadDestination? {
        switch kind {
        case .saveToFolder: .folder(folderPath)
        case .openFile: .open
        case .openApp, .openURL, .runScript, .jsonRPC: nil
        }
    }

    /// Open App: the app's path, as chosen in the open panel.
    var appPath = ""
    /// Open URL: the URL to open, with tokens such as `{encoded_link}`.
    var urlTemplate = ""
    /// Open URL: where a *web* address opens in Zigzag itself. Nil is a rule that has not been told yet — Zigzag asks
    /// the first time the rule fires and keeps the answer here, so it asks once rather than every time. `.never` is
    /// the other answer it can be given: "Always for this rule" and Don't Allow. An address that isn't the web's
    /// (mpv://, a magnet) belongs to the app that handles it and ignores this.
    var openIn: OpenInAnswer?
    /// Run Script: the executable, or a `.sh` file run by `/bin/sh`.
    var scriptPath = ""
    /// Run Script: one argv value each. A token is substituted into its own argument, never joined into a shell line.
    var arguments: [String] = []
    /// Save to Folder: the folder a file of this rule's type lands in, as chosen in the panel. Tokens are allowed, so
    /// a rule can be pointed at `{space}` if it likes.
    var folderPath = ""
    /// JSON-RPC: the endpoint, the method, and a JSON array of parameters (tokens allowed inside strings).
    var rpcEndpoint = ""
    var rpcMethod = ""
    /// A JSON array of parameters. For XML-RPC each is sent as a string.
    var rpcParameters = "[]"
    var rpcStyle: RPCStyle = .json

    /// Every string the action substitutes tokens into.
    var textFields: [String] {
        switch kind {
        case .openApp: [appPath]
        case .openURL: [urlTemplate]
        case .runScript: [scriptPath] + arguments
        case .jsonRPC: [rpcEndpoint, rpcMethod, rpcParameters]
        case .saveToFolder: [folderPath]
        case .openFile: []
        }
    }

    /// Whether the service answers on this Mac. Any other host — a name, an address on the network — is a machine
    /// that is not this one, whatever it's called, so only these three count.
    var endpointIsLocal: Bool {
        guard let host = URL(string: rpcEndpoint)?.host()?.lowercased(), !host.isEmpty else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    var summary: String {
        switch kind {
        case .openApp:
            let name = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            return name.isEmpty ? Kind.openApp.title : name
        case .openURL:
            return urlTemplate.isEmpty ? Kind.openURL.title : urlTemplate
        case .runScript:
            let name = URL(fileURLWithPath: scriptPath).lastPathComponent
            return name.isEmpty ? Kind.runScript.title : name
        case .jsonRPC:
            if rpcMethod.isEmpty { return Kind.jsonRPC.title }
            let host = URL(string: rpcEndpoint)?.host() ?? rpcEndpoint
            return host.isEmpty ? rpcMethod : "\(rpcMethod) · \(host)"
        case .saveToFolder:
            let name = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath).lastPathComponent
            return name.isEmpty ? Kind.saveToFolder.title : name
        case .openFile:
            return Kind.openFile.title
        }
    }

    /// Whether the service's endpoint is an address it could be reached at: it needs a scheme. `URL(string:)` is
    /// forgiving — it parses `bing.com`, and a bare word — so scheme-less text is not an address a request could go
    /// to, and a rule that couldn't work is never saved quietly.
    var endpointIsUsable: Bool {
        guard let url = URL(string: rpcEndpoint), let scheme = url.scheme, !scheme.isEmpty else { return false }
        return true
    }

    /// Whether the action has what it needs to run.
    var isComplete: Bool {
        switch kind {
        case .openApp:
            return !appPath.isEmpty
        case .openURL:
            guard !urlTemplate.isEmpty, let sample = URL(string: "https://example.com/a?b=c") else { return false }
            let expanded = DownloadTokens.expand(urlTemplate, with: HandoffValues(link: sample, referrer: sample, filename: "file.txt", space: "Work"))
            return URL(string: expanded)?.scheme != nil
        case .runScript:
            return !scriptPath.isEmpty
        case .jsonRPC:
            return endpointIsUsable && !rpcMethod.isEmpty
        case .saveToFolder:
            return !folderPath.isEmpty
        case .openFile:
            return true
        }
    }

    init(kind: Kind) { self.kind = kind }

    private enum CodingKeys: String, CodingKey {
        case kind, appPath, urlTemplate, openIn, scriptPath, arguments, rpcEndpoint, rpcMethod, rpcParameters, rpcStyle, folderPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .openURL
        appPath = try container.decodeIfPresent(String.self, forKey: .appPath) ?? ""
        urlTemplate = try container.decodeIfPresent(String.self, forKey: .urlTemplate) ?? ""
        openIn = try container.decodeIfPresent(OpenInAnswer.self, forKey: .openIn)
        scriptPath = try container.decodeIfPresent(String.self, forKey: .scriptPath) ?? ""
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        rpcEndpoint = try container.decodeIfPresent(String.self, forKey: .rpcEndpoint) ?? ""
        rpcMethod = try container.decodeIfPresent(String.self, forKey: .rpcMethod) ?? ""
        rpcParameters = try container.decodeIfPresent(String.self, forKey: .rpcParameters) ?? "[]"
        rpcStyle = try container.decodeIfPresent(RPCStyle.self, forKey: .rpcStyle) ?? .json
        folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath) ?? ""
    }
}

extension DownloadRuleAction {
    /// What this action itself was told, before any answer a site or a page gave: nil for a rule that hasn't been told
    /// (which is where the question comes from), and `.never` for one told not to open. A script's own answer has no
    /// rule to ask on, so its web addresses open in a new tab unless the answer itself names a place.
    ///
    /// **One resolver, two callers**: `DownloadHandoff` opens it here and `HandoffNotice` says what it is about to do
    /// from the same decision, so what a rule says can never drift from what it does. Only an Open URL has anywhere to
    /// decide; every other kind ignores this.
    func openInAnswer(askingOn rule: DownloadRule?) -> OpenInAnswer? {
        openIn ?? (rule == nil ? .place(.newTab) : nil)
    }
}

// MARK: - What a script says back

/// What a script's own output says for Zigzag to do next. A script is authoritative for everything that isn't the
/// browser's own business — it has every token as argv and the link in its environment, and needs nothing else to open
/// an app or call a service of its own. Where the next thing *is* the browser's (opening one of Zigzag's own places,
/// handing an address on, calling a service with the site's cookies, which only the browser holds), its output names
/// one of the actions the handler already has and Zigzag runs it in the rule's place.
nonisolated enum ScriptSays: Equatable {
    /// One action to run, written as the rule's own action JSON: `{"kind":"openURL","urlTemplate":"…"}`.
    case action(DownloadRuleAction)
    /// A line naming something a script may not name, and why. Said out loud rather than passed over: a script told
    /// to do something it can't must not look like one that did it.
    case refused(String)
    /// Nothing to act on, which is the answer to every script that says nothing.
    case nothing

    /// Reads the first line of `output` that names an action the handler knows. A line that isn't JSON, or that has
    /// no `kind`, or whose `kind` the handler doesn't know, is passed over — a script may log whatever it likes — and
    /// the first line that does name one decides, refused or not, so nothing can slip past a refusal on a later line.
    static func named(in output: String) -> ScriptSays {
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("{"), let data = text.data(using: .utf8) else { continue }
            // The `kind` is looked for twice on purpose: `DownloadRuleAction`'s own decoding answers a missing or
            // unknown `kind` with a default, which would make any JSON object the script printed look like an answer.
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["kind"] is String,
                  let action = try? JSONDecoder().decode(DownloadRuleAction.self, from: data) else { continue }
            if let why = action.kind.refusesScripts { return .refused(why) }
            return .action(action)
        }
        return .nothing
    }
}

// MARK: - Presets

/// The arrangements most people want, so a rule for aria2 or mpv is a menu choice and a look at the fields rather
/// than a JSON lesson.
nonisolated enum DownloadPreset: String, CaseIterable, Sendable {
    case aria2, motrix, torrents, ytdlp, mpv, iina

    /// What a torrent preset starts with: a magnet link, or an address that carries a `.torrent` file. One rule can
    /// only read one of the two, and this reads the address, which both a magnet link and a torrent's URL have.
    static let torrentPattern = #"^magnet:|\.torrent"#

    var title: String { ruleName }

    /// The name the rule it makes carries: the service or the app itself, so the rule reads as a sentence —
    /// "Files matching … go to rTorrent".
    var ruleName: String {
        switch self {
        case .aria2: "aria2"
        case .motrix: "Motrix"
        case .torrents: TorrentService.rTorrent.ruleName
        case .ytdlp: "yt-dlp"
        case .mpv: "mpv"
        case .iina: "IINA"
        }
    }

    /// The rule a preset starts from: a media site for the players, a magnet or link for the downloaders. Torrents
    /// starts on rTorrent; the sheet's Service dropdown points it at another one.
    var rule: DownloadRule {
        switch self {
        case .aria2, .motrix:
            var action = DownloadRuleAction(kind: .jsonRPC)
            action.rpcEndpoint = self == .aria2 ? "http://127.0.0.1:6800/jsonrpc" : "http://127.0.0.1:16800/jsonrpc"
            action.rpcMethod = "aria2.addUri"
            action.rpcParameters = """
            [["{link}"], {"header": ["Cookie: {cookie_header}", "Referer: {referrer}"], "out": "{filename}"}]
            """
            return DownloadRule(name: ruleName, applies: .linksAndDownloads, match: .any, action: action)
        case .torrents:
            let service = TorrentService.rTorrent
            var action = DownloadRuleAction(kind: .jsonRPC)
            action.rpcEndpoint = service.endpoint
            action.rpcMethod = service.method
            action.rpcParameters = service.parameters
            action.rpcStyle = service.style
            return DownloadRule(name: ruleName, applies: .linksAndDownloads, match: .regex, pattern: Self.torrentPattern, action: action)
        case .ytdlp:
            var action = DownloadRuleAction(kind: .runScript)
            // Through env, so it's found under either Homebrew prefix, and anywhere else on PATH.
            action.scriptPath = "/usr/bin/env"
            action.arguments = ["yt-dlp", "--no-playlist", "--cookies", "{cookies}", "{link}"]
            return DownloadRule(name: ruleName, applies: .linksAndDownloads, match: .any, action: action)
        case .mpv:
            var action = DownloadRuleAction(kind: .openURL)
            action.urlTemplate = "mpv://{encoded_link}"
            return DownloadRule(name: ruleName, applies: .linksAndDownloads, match: .contains, pattern: "youtube.com/watch", action: action)
        case .iina:
            var action = DownloadRuleAction(kind: .openURL)
            action.urlTemplate = "iina://weblink?url={encoded_link}"
            return DownloadRule(name: ruleName, applies: .linksAndDownloads, match: .contains, pattern: "youtube.com/watch", action: action)
        }
    }
}

/// The services a torrent rule can be pointed at. The protocol is the only thing that differs, so the Torrents
/// preset offers them as one dropdown and fills the rule's fields in.
nonisolated enum TorrentService: String, CaseIterable, Sendable {
    case rTorrent, aria2, motrix, custom

    var title: String {
        switch self {
        case .rTorrent: "rTorrent"
        case .aria2: "aria2"
        case .motrix: "Motrix"
        case .custom: String(localized: "Custom…", comment: "A choice of torrent service in the Torrents preset's sheet: fill the endpoint and method in by hand.")
        }
    }

    var ruleName: String {
        switch self {
        case .rTorrent: "rTorrent"
        case .aria2: "aria2"
        case .motrix: "Motrix"
        case .custom: String(localized: "Torrents", comment: "The rule name a Torrents preset starts with when its service is left to be filled in by hand.")
        }
    }

    var endpoint: String {
        switch self {
        case .rTorrent: "http://127.0.0.1:8080/RPC2"
        case .aria2: "http://127.0.0.1:6800/jsonrpc"
        case .motrix: "http://127.0.0.1:16800/jsonrpc"
        case .custom: ""
        }
    }

    var method: String {
        switch self {
        case .rTorrent: "load.start"
        case .aria2, .motrix: "aria2.addUri"
        case .custom: ""
        }
    }

    var parameters: String {
        switch self {
        case .rTorrent: """
        ["", "{link}"]
        """
        case .aria2, .motrix: """
        [["{link}"], {"header": ["Cookie: {cookie_header}", "Referer: {referrer}"], "out": "{filename}"}]
        """
        case .custom: "[]"
        }
    }

    var style: DownloadRuleAction.RPCStyle {
        self == .rTorrent ? .xmlrpc : .json
    }
}

// MARK: - Values a token stands for

/// What `{link}`, `{filename}` and the rest become for one handoff. Cookies are filled in only when a rule asks for
/// them, since reading the cookie store takes a moment.
nonisolated struct HandoffValues: Equatable, Sendable {
    var link: URL
    var referrer: URL?
    var filename: String
    var mime: String
    var space: String
    var cookieHeader = ""
    var cookieFile = ""

    init(link: URL, referrer: URL? = nil, filename: String = "", mime: String = "", space: String = "",
         cookieHeader: String = "", cookieFile: String = "") {
        self.link = link
        self.referrer = referrer
        self.filename = filename.isEmpty ? DownloadTokens.filename(for: link, suggested: "") : filename
        self.mime = mime
        self.space = space
        self.cookieHeader = cookieHeader
        self.cookieFile = cookieFile
    }
}

// MARK: - Tokens

nonisolated enum DownloadTokens {
    /// The tokens a template may use, and what each becomes, for the editor's note.
    static let names = ["{link}", "{encoded_link}", "{referrer}", "{cookies}", "{cookie_header}", "{filename}", "{mime}", "{space}"]

    /// The URL as one query value: `&`, `+`, `=` and `#` in it become part of the value, not of the query around it.
    static func encoded(_ url: URL) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return url.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.absoluteString
    }

    /// A name safe to write in Downloads, a header, or an argument: no folder separators, no control characters,
    /// no leading dot.
    static func filename(for url: URL, suggested: String) -> String {
        var name = suggested
        if name.isEmpty {
            name = url.lastPathComponent
            if name.isEmpty || name == "/" { name = url.host() ?? "download" }
        }
        name = name.removingPercentEncoding ?? name
        name = String(name.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) ? "-" : Character(scalar)
        })
        while name.hasPrefix(".") { name.removeFirst() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "download" : trimmed
    }

    /// A value as the inside of a JSON string, without the quotes.
    static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return value }
        return String(text.dropFirst().dropLast())
    }

    /// Fills every token in `template`. For JSON-RPC `json` is true: each value is escaped so a quote or backslash in a
    /// URL, a filename or a cookie can't break the body.
    static func expand(_ template: String, with values: HandoffValues, secret: String = "", json: Bool = false) -> String {
        func value(_ text: String) -> String { json ? jsonEscaped(text) : text }
        var result = template
        let replacements: [(String, String)] = [
            ("{encoded_link}", value(encoded(values.link))),
            ("{cookie_header}", value(values.cookieHeader)),
            ("{cookies}", value(values.cookieFile)),
            ("{referrer}", value(values.referrer?.absoluteString ?? "")),
            ("{filename}", value(values.filename)),
            ("{mime}", value(values.mime)),
            ("{space}", value(values.space)),
            ("{secret}", value(secret)),
            // The parts of the link on their own, so a rule can send an address somewhere else: `https://bing.com{path}`
            // takes a match on google.com to the same page on bing.com. Both are the address's own, percent-encoded, so
            // what is put back together is still one valid URL.
            ("{host}", value(values.link.host() ?? "")),
            ("{path}", value(values.link.path(percentEncoded: true))),
            ("{query}", value(values.link.query(percentEncoded: true) ?? "")),
            ("{link}", value(values.link.absoluteString)),
        ]
        for (token, replacement) in replacements {
            result = result.replacingOccurrences(of: token, with: replacement)
        }
        return result
    }
}

// MARK: - Cookies

/// One cookie, apart from WebKit, so the matching and the file can be tested without a web view.
nonisolated struct HandoffCookie: Equatable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var isSecure: Bool
    var isHTTPOnly: Bool
    var expires: Date?

    init(name: String, value: String, domain: String, path: String = "/", isSecure: Bool = false,
         isHTTPOnly: Bool = false, expires: Date? = nil) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path.isEmpty ? "/" : path
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.expires = expires
    }

    init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                  isSecure: cookie.isSecure, isHTTPOnly: cookie.isHTTPOnly, expires: cookie.expiresDate)
    }

    /// Whether this cookie would be sent with a request for `url`: its domain and path cover it, it hasn't expired,
    /// and a secure cookie only goes over https.
    func applies(to url: URL, now: Date = Date()) -> Bool {
        if let expires, expires <= now { return false }
        guard let host = url.host()?.lowercased() else { return false }
        let cookieDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cookieDomain.isEmpty else { return false }
        let domainMatches = host == cookieDomain || host.hasSuffix("." + cookieDomain)
        guard domainMatches else { return false }
        if isSecure && url.scheme?.lowercased() != "https" { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = path.isEmpty ? "/" : path
        return requestPath == cookiePath || requestPath.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
            || cookiePath == "/"
    }

    /// `name=value`, for a Cookie header. HTTP-only cookies go in too: the header is for a program that makes the
    /// request itself, where the page's JavaScript couldn't reach them anyway.
    var headerField: String { "\(name)=\(value)" }
}

nonisolated enum HandoffCookies {
    /// The cookies for `url`, in a stable order, and their Cookie header.
    static func matching(_ cookies: [HandoffCookie], for url: URL, now: Date = Date()) -> [HandoffCookie] {
        cookies.filter { $0.applies(to: url, now: now) }
            .sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
    }

    static func header(_ cookies: [HandoffCookie]) -> String {
        cookies.map(\.headerField).joined(separator: "; ")
    }

    /// A Netscape cookies.txt, the file yt-dlp and aria2 read. HTTP-only cookies are marked `#HttpOnly_`, as curl and
    /// yt-dlp write them.
    static func netscape(_ cookies: [HandoffCookie]) -> String {
        var lines = ["# Netscape HTTP Cookie File", "# Written by Zigzag for one handoff.", ""]
        for cookie in cookies {
            let domain = cookie.domain.hasPrefix(".") ? cookie.domain : "." + cookie.domain
            let includeSubdomains = cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let secure = cookie.isSecure ? "TRUE" : "FALSE"
            let expiry = cookie.expires.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            let prefix = cookie.isHTTPOnly ? "#HttpOnly_" : ""
            lines.append("\(prefix)\(domain)\t\(includeSubdomains)\t\(cookie.path)\t\(secure)\t\(expiry)\t\(cookie.name)\t\(cookie.value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the file in the handoff's own temporary folder, readable by its owner only, and returns its path.
    static func writeFile(_ cookies: [HandoffCookie]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ZigzagHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("cookies.txt")
        try Data(netscape(cookies).utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// Removes a file `writeFile` made, and its folder.
    static func removeFile(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

// MARK: - The list

/// The rules, in order, kept in DownloadRules.json. The same list serves every profile; the cookies and the space a
/// rule sees come from the tab that triggered it.
@MainActor
final class DownloadRulesStore {
    static let shared = DownloadRulesStore()

    private(set) var rules: [DownloadRule]
    let changed = Signal<Void>()

    init() {
        rules = JSONStore.load([DownloadRule].self, from: Paths.downloadRules) ?? []
    }

    /// The first rule that catches `url`, or none. `appliesToLinks` is false for a download. `filename` is the
    /// download's own name, for a rule that matches a file's type; a link passes none. `isPrivate` leaves out the rules
    /// that haven't been allowed into a private window.
    func firstMatch(url: URL, filename: String = "", appliesToLinks: Bool, isPrivate: Bool = false) -> DownloadRule? {
        Self.firstMatch(in: rules, url: url, filename: filename, appliesToLinks: appliesToLinks, isPrivate: isPrivate)
    }

    /// The same order, apart from the file, for a list being tested or previewed. A destination is never a handoff —
    /// it decides where a file lands, and `destination(for:)` is what reads it — and a rule that hasn't been allowed
    /// into private windows is left out there.
    nonisolated static func firstMatch(in rules: [DownloadRule], url: URL, filename: String = "",
                                       appliesToLinks: Bool, isPrivate: Bool = false) -> DownloadRule? {
        rules.first { rule in
            guard !rule.action.kind.isDestination else { return false }
            guard rule.applies == .linksAndDownloads || !appliesToLinks else { return false }
            guard !isPrivate || rule.runsInPrivateWindows else { return false }
            return rule.matches(url, filename: filename)
        }
    }

    /// The first rule whose destination is this download's, if any: the entry that decides where the file lands. Only
    /// a rule that *is* a destination (`saveToFolder`, `openFile`) is looked at, so a handoff rule for the same
    /// name is left for the handoff path to run. First match wins, exactly as it does for handoffs.
    func destination(for url: URL, filename: String) -> (rule: DownloadRule, destination: DownloadDestination)? {
        Self.destination(in: rules, url: url, filename: filename)
    }

    /// The same, apart from the file, for a list being tested or previewed.
    nonisolated static func destination(in rules: [DownloadRule], url: URL, filename: String)
        -> (rule: DownloadRule, destination: DownloadDestination)? {
        for rule in rules {
            guard rule.applies == .downloads, rule.isEnabled, let destination = rule.action.destination,
                  rule.matches(url, filename: filename) else { continue }
            return (rule, destination)
        }
        return nil
    }

    func replace(_ rules: [DownloadRule]) {
        self.rules = rules
        save()
    }

    func update(_ rule: DownloadRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    func add(_ rule: DownloadRule, at index: Int? = nil) {
        let place = min(max(0, index ?? rules.count), rules.count)
        rules.insert(rule, at: place)
        save()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        HandoffSecrets.removeSecret(for: id)
        // The sites the rule was decided on keep nothing about it once it is gone.
        Self.forgetSiteAnswers(for: id)
        save()
    }

    /// What a rule kept for individual sites, forgotten: both kinds of answer it can keep — its handoff and where its
    /// web addresses open. Kept apart from `remove` so a test can prove both are forgotten without a store's file.
    static func forgetSiteAnswers(for id: UUID) {
        SitePermissions.forgetActions(prefix: PermissionSubject.handoff(id))
        SitePermissions.forgetActions(prefix: PermissionSubject.openIn(id))
    }

    /// The rules with the one whose `id` this is moved to just before `before` (`nil` puts it last). Kept apart from
    /// the store so the order a drag produces can be read without one: a list that shows only some of the rules can't
    /// number a place in the store, so it names the row it was dropped on instead.
    nonisolated static func moved(_ rules: [DownloadRule], id: UUID, before beforeID: UUID?) -> [DownloadRule] {
        guard let from = rules.firstIndex(where: { $0.id == id }) else { return rules }
        var without = rules
        let rule = without.remove(at: from)
        let to = beforeID.flatMap { before in without.firstIndex(where: { $0.id == before }) } ?? without.count
        guard to != from else { return rules }
        without.insert(rule, at: min(to, without.count))
        return without
    }

    /// Moves the rule with `id` to just before the rule with `before` (`nil` puts it last).
    func move(_ id: UUID, before beforeID: UUID?) {
        let moved = Self.moved(rules, id: id, before: beforeID)
        guard moved != rules else { return }
        rules = moved
        save()
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = isEnabled
        save()
    }

    private func save() {
        JSONStore.save(rules, to: Paths.downloadRules)
        changed.send()
    }
}

// MARK: - Secrets

/// The token an aria2 or rTorrent endpoint asks for, kept in the Keychain by the rule's id, never in the rules file.
nonisolated enum HandoffSecrets {
    private static var service: String { "\(Bundle.main.bundleIdentifier ?? "app.zigzag").download-rules" }

    private static func query(for rule: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: rule.uuidString]
    }

    static func secret(for rule: UUID) -> String? {
        var query = query(for: rule)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setSecret(_ secret: String, for rule: UUID) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return removeSecret(for: rule) }
        let data = Data(trimmed.utf8)
        var query = query(for: rule)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData] = data
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func removeSecret(for rule: UUID) {
        SecItemDelete(query(for: rule) as CFDictionary)
    }
}
