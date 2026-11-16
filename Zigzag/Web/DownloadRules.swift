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

/// The file types a file-type **Open** never offers or performs. Each can run code, mount an installer, or hand the
/// Mac's app an archive or a configuration profile that does: opening one from a download is a double-click you did
/// not make. A type may still be **saved**; the clamp is on Open only.
nonisolated enum DownloadOpening {
    /// Lowercase extensions, without a leading dot. Scripts are included because the Mac's default app for one may
    /// run it, and archives because opening one can hand out an app the archive carries.
    static let refused: Set<String> = [
        "app", "pkg", "dmg", "zip", "mobileconfig",
        "command", "terminal", "sh", "bash", "zsh", "fish", "csh", "ksh",
        "py", "rb", "pl", "php", "jar", "scpt", "applescript", "workflow"
    ]

    static func isRefused(_ type: String) -> Bool {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // No extension is no type to vouch for: an extensionless file can be a script or a binary, and Open is for a
        // type, not for "whatever this is". It is saved like any other download.
        guard !trimmed.isEmpty else { return true }
        return refused.contains(trimmed)
    }

    /// Whether any extension a file-type pattern names is one an Open must refuse. An Open rule for one of them could
    /// otherwise arrive from an older build or a hand-edited rules file.
    static func isRefused(pattern: String) -> Bool {
        DownloadRule.Match.extensions(in: pattern).contains { isRefused($0) }
    }
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

        /// The short form a rule's row shows beside its name.
        var shortTitle: String {
            switch self {
            case .startsWith: String(localized: "starts with", comment: "A rule's kind, in its row in Settings › Downloads.")
            case .contains: String(localized: "contains", comment: "A rule's kind, in its row in Settings › Downloads.")
            case .endsWith: String(localized: "ends with", comment: "A rule's kind, in its row in Settings › Downloads.")
            case .regex: String(localized: "matches", comment: "A rule's kind, in its row in Settings › Downloads, before a regular expression.")
            case .fileType: String(localized: "file type", comment: "A rule's kind, in its row in Settings › Downloads: it catches a file by its extension.")
            case .any: String(localized: "any address", comment: "A rule's kind, in its row in Settings › Downloads: the catch-all.")
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
    /// **Off by default**: a private window promises that what happens there leaves no trace, and handing its address,
    /// or its cookies, to another app or script is exactly what could break that promise. A private window runs no
    /// rule that hasn't been let in, and the link or download carries on as if no rule had matched.
    var runsInPrivateWindows = false
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

    /// What the row says it does, in a few words.
    var actionSummary: String { action.summary }

    /// What a file-type destination's row says it does: the types it names, and where they go.
    var destinationSentence: String {
        let types = Match.extensions(in: pattern).joined(separator: ", ")
        switch action.kind {
        case .saveToFolder:
            return String(localized: "Files of type \(types) are saved to \(action.summary)", comment: "A file-type destination in a sentence: the extensions it names, then the folder they are saved into.")
        case .openFile:
            return String(localized: "Files of type \(types) open in your Mac’s app", comment: "A file-type destination in a sentence: the extensions it names, then that the Mac's own app opens them.")
        default:
            return action.summary
        }
    }

    /// What the row says it catches.
    var matchSummary: String {
        switch match {
        case .fileType: return DownloadRule.Match.extensions(in: pattern).joined(separator: ", ")
        case .any: return Match.any.shortTitle
        case .regex: return "\(Match.regex.shortTitle) \(pattern)"
        default: return "\(match.shortTitle) \(pattern)"
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
        case id, name, isEnabled, applies, match, pattern, isCaseSensitive, runsInPrivateWindows, action
    }

    /// Older files may lack a key a newer Zigzag added, and a kind this build doesn't know (a file-type rule from
    /// another branch) decodes as the nearest ordinary one. A rule is never thrown away for one unknown value.
    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            guard let container else { return nil }
            return try? container.decodeIfPresent(type, forKey: key)
        }
        func wasSet(_ key: CodingKeys) -> Bool { container?.contains(key) ?? false }
        id = value(UUID.self, .id) ?? UUID()
        name = value(String.self, .name) ?? ""
        isEnabled = value(Bool.self, .isEnabled) ?? true
        applies = value(String.self, .applies).flatMap(Applies.init(rawValue:)) ?? .downloads
        if let rawMatch = value(String.self, .match) {
            if let known = Match(rawValue: rawMatch) { match = known } else { match = .contains; isEnabled = false }
        } else {
            // A value of another type is not a match either: a `.contains` with no pattern would catch everything.
            match = .contains
            if wasSet(.match) { isEnabled = false }
        }
        pattern = value(String.self, .pattern) ?? ""
        isCaseSensitive = value(Bool.self, .isCaseSensitive) ?? false
        runsInPrivateWindows = value(Bool.self, .runsInPrivateWindows) ?? false
        action = value(DownloadRuleAction.self, .action) ?? DownloadRuleAction(kind: .openURL)
        // A rule that isn't an object, has no action, or names a kind this build doesn't know is kept, but not run:
        // it could not do what it says, and a prompt for it would be a question with no true answer. A `.contains`
        // rule with no action fields would otherwise catch every address.
        if container == nil || !wasSet(.action) || (wasSet(.action) && value(DownloadRuleAction.self, .action) == nil) {
            isEnabled = false
        }
        if action.wasDecodedFromUnknownKind { isEnabled = false }
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
    /// True when a file named an action kind this build doesn't know; the rule is kept but disabled.
    var wasDecodedFromUnknownKind = false

    /// Every string the action substitutes tokens into. A path, an endpoint and a method are literal, so a token in
    /// one of them is text, not a value.
    var textFields: [String] {
        switch kind {
        case .openApp: []
        case .openURL: [urlTemplate]
        case .runScript: arguments
        case .jsonRPC: [rpcParameters]
        case .saveToFolder: []
        case .openFile: []
        }
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

    /// Whether the action has what it needs to run.
    var isComplete: Bool {
        switch kind {
        case .openApp:
            return !appPath.isEmpty
        case .openURL:
            guard !urlTemplate.isEmpty, let sample = URL(string: "https://example.com/a?b=c") else { return false }
            let expanded = DownloadTokens.expand(urlTemplate, with: HandoffValues(link: sample, referrer: sample, filename: "file.txt", space: "Work"), query: true)
            return URL(string: expanded)?.scheme != nil
        case .runScript:
            return !scriptPath.isEmpty
        case .jsonRPC:
            return !rpcEndpoint.isEmpty && URL(string: rpcEndpoint) != nil && !rpcMethod.isEmpty
        case .saveToFolder:
            return !folderPath.isEmpty
        case .openFile:
            return true
        }
    }

    init(kind: Kind) { self.kind = kind }

    private enum CodingKeys: String, CodingKey {
        case kind, appPath, urlTemplate, scriptPath, arguments, rpcEndpoint, rpcMethod, rpcParameters, rpcStyle, folderPath
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            guard let container else { return nil }
            return try? container.decodeIfPresent(type, forKey: key)
        }
        func wasSet(_ key: CodingKeys) -> Bool { container?.contains(key) ?? false }
        if let rawKind = value(String.self, .kind) {
            if let known = Kind(rawValue: rawKind) { kind = known } else { kind = .openURL; wasDecodedFromUnknownKind = true }
        } else {
            kind = .openURL
            // No kind at all is as unreadable as one this build doesn't know.
            wasDecodedFromUnknownKind = true
        }
        appPath = value(String.self, .appPath) ?? ""
        urlTemplate = value(String.self, .urlTemplate) ?? ""
        scriptPath = value(String.self, .scriptPath) ?? ""
        arguments = value([String].self, .arguments) ?? []
        rpcEndpoint = value(String.self, .rpcEndpoint) ?? ""
        rpcMethod = value(String.self, .rpcMethod) ?? ""
        rpcParameters = value(String.self, .rpcParameters) ?? "[]"
        rpcStyle = value(String.self, .rpcStyle).flatMap(RPCStyle.init(rawValue:)) ?? .json
        folderPath = value(String.self, .folderPath) ?? ""
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
            // A download manager takes downloads only: a link you click stays a link unless it is itself a file.
            return DownloadRule(name: title, applies: .downloads, match: .any, action: action)
        case .torrents:
            let service = TorrentService.rTorrent
            var action = DownloadRuleAction(kind: .jsonRPC)
            action.rpcEndpoint = service.endpoint
            action.rpcMethod = service.method
            action.rpcParameters = service.parameters
            action.rpcStyle = service.style
            // A download service catches files, not links: a magnet is left to the browser unless it arrives as one.
            return DownloadRule(name: title, applies: .downloads, match: .regex, pattern: Self.torrentPattern, action: action)
        case .ytdlp:
            var action = DownloadRuleAction(kind: .runScript)
            // Through env, so it's found under either Homebrew prefix, and anywhere else on PATH.
            action.scriptPath = "/usr/bin/env"
            action.arguments = ["yt-dlp", "--no-playlist", "--cookies", "{cookies}", "{link}"]
            return DownloadRule(name: title, applies: .downloads, match: .any, action: action)
        case .mpv:
            var action = DownloadRuleAction(kind: .openURL)
            action.urlTemplate = "mpv://{encoded_link}"
            return DownloadRule(name: title, applies: .linksAndDownloads, match: .contains, pattern: "youtube.com/watch", action: action)
        case .iina:
            var action = DownloadRuleAction(kind: .openURL)
            action.urlTemplate = "iina://weblink?url={encoded_link}"
            return DownloadRule(name: title, applies: .linksAndDownloads, match: .contains, pattern: "youtube.com/watch", action: action)
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

    /// A value as one query value: `&`, `+`, `=` and `#` in it become part of the value, not of the query around it.
    static func queryValue(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The URL as one query value.
    static func encoded(_ url: URL) -> String { queryValue(url.absoluteString) }

    /// The characters a name may keep: no control, format (bidi included), line or paragraph separators, surrogates
    /// or unassigned scalars, and no folder separators or colons. Shared with the download manager, so a name shown
    /// in a rule and a name written to disk follow one policy.
    static func safeName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned: continue
            default: break
            }
            scalars.append(scalar == "/" || scalar == "\\" || scalar == ":" ? "-" : scalar)
        }
        var trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A name safe to write in Downloads, a header, or an argument: no folder separators, no control characters,
    /// no leading dot, and no leading dash that a script would read as an option.
    static func filename(for url: URL, suggested: String) -> String {
        var name = suggested
        if name.isEmpty {
            name = url.lastPathComponent
            if name.isEmpty || name == "/" { name = url.host() ?? "download" }
        }
        name = safeName(name.removingPercentEncoding ?? name)
        if name.isEmpty { name = safeName(url.lastPathComponent) }
        if name.isEmpty { name = "download" }
        if name.hasPrefix("-") { name = "_" + name }
        return name
    }

    /// A value as the inside of a JSON string, without the quotes.
    static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return value }
        return String(text.dropFirst().dropLast())
    }

    /// Fills every token in `template`, in one pass. A value is never scanned again, so a filename or a title that
    /// happens to read `{secret}` or `{link}` is passed as it is, not turned into another value.
    /// `query`: every value is one query value, so a filename or a title with `&`, `=` or `#` in it can't add a
    /// parameter of its own to an Open URL template. `{path}`, `{query}` and `{encoded_link}` are the address's own
    /// already-encoded parts and are not encoded twice.
    /// `json`: every value is the inside of a JSON string.
    static func expand(_ template: String, with values: HandoffValues, secret: String = "", json: Bool = false,
                       query: Bool = false) -> String {
        func value(_ text: String) -> String {
            if json { return jsonEscaped(text) }
            if query { return queryValue(text) }
            return text
        }
        // Already encoded for where it goes: escaped for JSON if asked, but never percent-encoded again.
        func part(_ text: String) -> String { json ? jsonEscaped(text) : text }
        // A server's MIME type is not an option: one that starts with `-` must not be read as one by aria2 or yt-dlp.
        let mime = values.mime.hasPrefix("-") ? "_" + values.mime : values.mime
        let replacements: [String: String] = [
            "{encoded_link}": part(encoded(values.link)),
            "{cookie_header}": value(values.cookieHeader),
            "{cookies}": value(values.cookieFile),
            "{referrer}": value(values.referrer?.absoluteString ?? ""),
            "{filename}": value(values.filename),
            "{mime}": value(mime),
            "{space}": value(values.space),
            "{secret}": value(secret),
            // The link's own parts, so a rule can send an address somewhere else: `https://bing.com{path}` takes a
            // match on google.com to the same page on bing.com. Both are the address's own, percent-encoded, so what
            // is put back together is still one valid URL.
            "{host}": value(values.link.host() ?? ""),
            "{path}": part(values.link.path(percentEncoded: true)),
            "{query}": part(values.link.query(percentEncoded: true) ?? ""),
            "{link}": value(values.link.absoluteString),
        ]
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let close = template[index...].firstIndex(of: "}") {
                let token = String(template[index...close])
                if let replacement = replacements[token] {
                    result += replacement
                    index = template.index(after: close)
                    continue
                }
            }
            result.append(template[index])
            index = template.index(after: index)
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

    /// A cookie with no leading dot belongs to the exact host and no subdomain; one with a dot is for the domain.
    var isHostOnly: Bool { !domain.hasPrefix(".") }

    /// Whether this cookie would be sent with a request for `url`: its domain and path cover it, it hasn't expired,
    /// and a secure cookie only goes over https.
    func applies(to url: URL, now: Date = Date()) -> Bool {
        if let expires, expires <= now { return false }
        guard let host = url.host()?.lowercased() else { return false }
        let cookieDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cookieDomain.isEmpty else { return false }
        let domainMatches = isHostOnly ? host == cookieDomain
            : (host == cookieDomain || host.hasSuffix("." + cookieDomain))
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
            // The leading dot and the include-subdomains flag say the same thing, and yt-dlp's loader refuses a
            // file where they disagree: a host-only cookie is `example.com` with FALSE, a domain cookie `.example.com`
            // with TRUE.
            let domain = cookie.domain
            let includeSubdomains = cookie.isHostOnly ? "FALSE" : "TRUE"
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
    /// download's own name, for a rule that matches a file's type; a link passes none.
    func firstMatch(url: URL, filename: String = "", appliesToLinks: Bool, isPrivate: Bool = false) -> DownloadRule? {
        Self.firstMatch(in: rules, url: url, filename: filename, appliesToLinks: appliesToLinks, isPrivate: isPrivate)
    }

    /// The same order, apart from the file, for a list being tested or previewed. A rule not let into private windows
    /// is left out there, so a private window never even asks about it.
    nonisolated static func firstMatch(in rules: [DownloadRule], url: URL, filename: String = "",
                                       appliesToLinks: Bool, isPrivate: Bool = false) -> DownloadRule? {
        rules.first { rule in
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
            // An Open for an app, a script, an installer or an archive is never performed, even if one was saved by an
            // older build: the file is saved as if this rule had not matched, and a later Save rule may still take it.
            if destination == .open, DownloadOpening.isRefused((filename as NSString).pathExtension) { continue }
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
        save()
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

    /// Moves the rule at one place in the list to another, as the Up and Down buttons do.
    func move(from: Int, to: Int) {
        guard rules.indices.contains(from), rules.indices.contains(to), from != to else { return }
        let rule = rules.remove(at: from)
        rules.insert(rule, at: to)
        save()
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
