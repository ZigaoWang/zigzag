import Foundation
import Security
import UniformTypeIdentifiers
import WebKit

// MARK: - A rule

/// Where a rule that isn't a handoff puts the file: a folder, or the Mac's default app for its type. Never cancels
/// the download; applied when the download is made, not through `DownloadHandoff`.
nonisolated enum DownloadDestination: Equatable, Sendable {
    /// Empty means the default folder.
    case folder(String)
    /// Saves to Downloads, then opens it in the Mac's default app for its type.
    case open
}

/// File types a file-type Open never opens: each can run code, mount an installer, or hand over an archive or profile
/// that does. Saving them is still allowed.
nonisolated enum DownloadOpening {
    /// Lowercase, no leading dot. Scripts because the default app may run them; installers and disk images because
    /// opening mounts or runs them; archives because they can carry an app.
    static let refused: Set<String> = [
        // Apps and bundles.
        "app", "prefpane", "kext",
        // Installers and disk images.
        "pkg", "mpkg", "xip", "dmg", "iso", "img", "msi", "cab",
        // Archives.
        "zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "7z", "rar", "zst", "lz", "lzma", "jar",
        // Scripts and automation.
        "command", "terminal", "term", "tool", "sh", "bash", "zsh", "fish", "csh", "ksh", "py", "rb", "pl", "php",
        "js", "mjs", "jxa", "scpt", "scptd", "applescript", "workflow", "wflow", "action", "shortcut",
        // Plug-ins, helpers and code that loads into another app.
        "plugin", "bundle", "framework", "dylib", "so", "osax", "appex", "xpc", "saver", "qlgenerator", "mdimporter",
        "service", "systemextension", "driver", "inputplugin", "ibplugin", "menu", "help", "x11app", "nib", "xib",
        "qtz", "class", "jnlp", "ipa", "cin", "icp", "gcx", "ipg",
        // Locations and HTML: opening one sends the Mac to another address or runs a page from disk.
        "fileloc", "inetloc", "webloc", "url", "afploc", "ftploc", "mailloc", "newsloc",
        "html", "htm", "shtml", "xhtml", "xht", "mht", "mhtml", "svg", "svgz", "webarchive",
        // Office documents that carry macros.
        "docm", "dotm", "xlsm", "xltm", "xlam", "pptm", "potm", "ppsm", "ppam",
        // Configuration profiles.
        "mobileconfig"
    ]

    /// The Mac's risky type families (as in LSRiskCategory), for extensions the list above misses.
    private static let refusedTypes: [UTType] = [.executable, .application, .unixExecutable, .script, .shellScript,
                                                .archive, .diskImage, .internetLocation, .html]

    static func isRefused(_ type: String) -> Bool {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // No extension means no type to vouch for (could be a script or binary), so refused.
        guard !trimmed.isEmpty else { return true }
        // Refused when any part is: `tar.gz` is an archive, and a page-supplied `pdf,dmg` can't sneak `dmg` past.
        return trimmed.split(whereSeparator: { $0 == "." || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains(where: isRefusedPart)
    }

    private static func isRefusedPart(_ part: String) -> Bool {
        if refused.contains(part) { return true }
        guard let type = UTType(filenameExtension: part) else { return false }
        return refusedTypes.contains { type.conforms(to: $0) }
    }

    /// Whether a file-type pattern names any refused extension, e.g. from an older build or a hand-edited rules file.
    static func isRefused(pattern: String) -> Bool {
        let extensions = DownloadRule.Match.extensions(in: pattern)
        guard !extensions.isEmpty else { return true }
        return extensions.contains { isRefused($0) }
    }
}

/// Hands a matching link or download to another app. First match wins, top to bottom; unmatched downloads stay with
/// WebKit.
nonisolated struct DownloadRule: Codable, Identifiable, Equatable, Sendable {
    /// New rules catch downloads only, so adding one never changes how links open.
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

    /// What a handoff is given. `url` is the address, as before; `file` downloads it in Zigzag first and hands off the
    /// saved file. Links always use `url`, since they have no file.
    enum HandoffType: String, Codable, CaseIterable, Sendable {
        case url
        case file

        var title: String {
            switch self {
            case .url: String(localized: "URL", comment: "Choice of what a download rule hands off: the link or download's address, as before.")
            case .file: String(localized: "File", comment: "Choice of what a download rule hands off: Zigzag downloads it first, then hands off the saved file.")
            }
        }
    }

    /// `fileType` matches the file name's extension; every other kind matches the address. `any` is the catch-all.
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

        /// Comma-separated; whitespace and a leading dot are allowed. Multi-part extensions (`tar.gz`) count as one.
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
    /// What the action is given. `.file` downloads first and hands off the saved file; links still use `.url`.
    var handoffType: HandoffType = .url
    var match: Match = .contains
    var pattern = ""
    /// Applies to regex and text. Hosts are always case-insensitive.
    var isCaseSensitive = false
    /// Off by default: handing a private window's address or cookies to another app breaks its no-trace promise. When
    /// off, the rule is ignored there.
    var runsInPrivateWindows = false
    /// The rule's own answer for every site: "handOff", "browser" or "deny". Nil when answered only per site
    /// (`handoff:<id>` in `SitePermissions`) or not at all. Stored on the rule so it goes when the rule does.
    var handoffAnswer: String?
    var action: DownloadRuleAction

    /// A regex that doesn't compile never matches.
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
            // Type rules match file names, never a bare address; see `matches(_:filename:)`.
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

    /// Only `fileType` rules read the name; it matches when it ends in any listed extension.
    func matches(filename: String) -> Bool {
        guard match == .fileType, isEnabled, !filename.isEmpty else { return false }
        return Match.extensions(in: pattern).contains { filename.hasSuffix("." + $0, caseSensitive: isCaseSensitive) }
    }

    /// Address for every kind except `fileType`, which reads the name. Links pass an empty name.
    func matches(_ url: URL, filename: String) -> Bool {
        match == .fileType ? matches(filename: filename) : matches(url)
    }

    /// Only then is the cookie store read.
    var needsCookies: Bool {
        action.textFields.contains { $0.contains("{cookies}") || $0.contains("{cookie_header}") }
    }

    /// Whether the action wants a cookies.txt file rather than a header.
    var usesCookieFile: Bool {
        action.textFields.contains { $0.contains("{cookies}") }
    }

    var actionSummary: String { action.summary }

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

    /// Settings › Downloads row text, e.g. "Files ending in .torrent go to rTorrent". Ends with the target, not the
    /// rule's name, which the row already shows.
    var summarySentence: String {
        let goes = action.summary
        // A destination names the folder it saves into. A file-type handoff is sent somewhere, so it reads like every
        // other handoff, by the files it catches.
        if match == .fileType, action.kind.isDestination { return destinationSentence }
        if handoffType == .file { return savedFileSentence(goes: goes) }
        if match == .any {
            return applies == .downloads
                ? String(localized: "Everything you download goes to \(goes)",
                         comment: "A download rule in a sentence: it catches every address. The placeholder is where the rule's action puts things: an app, a folder or a service.")
                : String(localized: "Every link and download goes to \(goes)",
                         comment: "A download rule in a sentence: it catches every address. The placeholder is where the rule's action puts things: an app, a folder or a service.")
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
            // Links have no name, so a type rule catches downloads whatever “Applies to” says; it reads as Files.
            let types = Match.extensions(in: pattern).joined(separator: ", ")
            catches = String(localized: "Files of type \(types)", comment: "Part of a download rule's sentence: it catches files by their own extension, whatever their address. The placeholder lists the extensions, like torrent or pdf.")
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
            return String(localized: "\(catches) are saved to \(goes)", comment: "A download rule in a sentence: what it catches, then the folder its files are saved into. The placeholders are the two parts.")
        case .openFile:
            return String(localized: "\(catches) open in your Mac’s app", comment: "A download rule in a sentence: what it catches, then that the Mac's own app opens it.")
        }
    }

    /// A File handoff reads as the download being saved first, then the action. Only downloads wait: a link still
    /// hands off its address.
    private func savedFileSentence(goes: String) -> String {
        let catches: String
        switch match {
        case .any:
            catches = String(localized: "Downloads", comment: "Part of a download rule's sentence for a File handoff: everything it catches.")
        case .startsWith:
            catches = String(localized: "Downloads starting with \(pattern)", comment: "Part of a download rule's sentence for a File handoff: the files whose address begins this way. The placeholder is the beginning of the address.")
        case .contains:
            catches = String(localized: "Downloads whose address contains \(pattern)", comment: "Part of a download rule's sentence for a File handoff: the files whose address contains this text. The placeholder is the text looked for in the address.")
        case .endsWith:
            catches = String(localized: "Downloads ending in \(pattern)", comment: "Part of a download rule's sentence for a File handoff: the files whose address ends this way. The placeholder is the end of the address, such as .torrent.")
        case .regex:
            catches = String(localized: "Downloads matching \(pattern)", comment: "Part of a download rule's sentence for a File handoff: the files whose address matches this expression. The placeholder is the expression.")
        case .fileType:
            let types = Match.extensions(in: pattern).joined(separator: ", ")
            catches = String(localized: "Files of type \(types)", comment: "Part of a download rule's sentence: it catches files by their own extension, whatever their address. The placeholder lists the extensions, like torrent or pdf.")
        }
        switch action.kind {
        case .jsonRPC:
            return String(localized: "\(catches) are saved first, then go to \(goes)", comment: "A File handoff in a sentence: what it catches is downloaded first, then sent to the service. The placeholders are the two parts, as in “Downloads ending in .torrent” and “rTorrent”.")
        case .openApp, .openURL:
            return String(localized: "\(catches) are saved first, then open in \(goes)", comment: "A File handoff in a sentence: what it catches is downloaded first, then opened in the app. The placeholders are the two parts.")
        case .runScript:
            return String(localized: "\(catches) are saved first, then are handed to \(goes)", comment: "A File handoff in a sentence: what it catches is downloaded first, then given to the script. The placeholders are the two parts.")
        case .saveToFolder, .openFile:
            return goes
        }
    }

    init(name: String, applies: Applies = .downloads, match: Match = .contains, pattern: String = "",
         isCaseSensitive: Bool = false, action: DownloadRuleAction, handoffType: HandoffType = .url) {
        self.name = name
        self.applies = applies
        self.match = match
        self.pattern = pattern
        self.isCaseSensitive = isCaseSensitive
        self.action = action
        self.handoffType = handoffType
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, applies, handoffType, match, pattern, isCaseSensitive, runsInPrivateWindows, handoffAnswer, action
    }

    /// Missing keys use defaults, and an unknown kind (e.g. from another branch) decodes as the nearest known one, so
    /// a rule is never dropped.
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
        // Missing in rules saved before the choice existed; an unknown value is left at the address.
        handoffType = value(String.self, .handoffType).flatMap(HandoffType.init(rawValue:)) ?? .url
        if let rawMatch = value(String.self, .match) {
            if let known = Match(rawValue: rawMatch) { match = known } else { match = .contains; isEnabled = false }
        } else {
            // A `.contains` with no pattern would match everything.
            match = .contains
            if wasSet(.match) { isEnabled = false }
        }
        pattern = value(String.self, .pattern) ?? ""
        isCaseSensitive = value(Bool.self, .isCaseSensitive) ?? false
        runsInPrivateWindows = value(Bool.self, .runsInPrivateWindows) ?? false
        handoffAnswer = value(String.self, .handoffAnswer)
        action = value(DownloadRuleAction.self, .action) ?? DownloadRuleAction(kind: .openURL)
        // Kept but disabled when not an object, missing an action, or naming an unknown kind. Otherwise a `.contains`
        // rule with no action fields would match every address.
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

/// One flat shape with a `kind` instead of an enum with payloads: readable file, forward compatible, and one field
/// per editor control.
nonisolated struct DownloadRuleAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case openApp
        case openURL
        case runScript
        case jsonRPC
        /// Destination, not a handoff: saves into the rule's folder. Applied when WebKit makes the download
        /// (`DownloadDestination`).
        case saveToFolder
        /// Destination: saves to Downloads, then opens in the Mac's default app for the type. Choosing a specific app
        /// is a handoff instead.
        case openFile

        /// Destinations never cancel the download and are made from the per-extension panel, not Add Rule's Custom…
        /// menu.
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
            // Old name from when it opened the file in a tab; now reads as `openFile`.
            if raw == "showInZigzag" { self = .openFile; return }
            guard let kind = Kind(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown download rule action \(raw).")
            }
            self = kind
        }
    }

    /// rTorrent uses XML-RPC; aria2, Motrix and qBittorrent take JSON-RPC.
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
    /// Destination for `saveToFolder` and `openFile`; nil for the handoff kinds that `DownloadHandoff` runs.
    var destination: DownloadDestination? {
        switch kind {
        case .saveToFolder: .folder(folderPath)
        case .openFile: .open
        case .openApp, .openURL, .runScript, .jsonRPC: nil
        }
    }

    var appPath = ""
    var urlTemplate = ""
    /// Open URL: where a web address opens. Ask lets the hand-off card choose each time, and the "Where should this
    /// open" question's Always saves a place here. Rules from older files keep Default Browser. Non-web schemes
    /// (mpv://, magnet) ignore this.
    var openIn: OpenInZigzag.Choice = .ask
    var scriptPath = ""
    /// One argv value each. Tokens are substituted per argument, never joined into a shell line.
    var arguments: [String] = []
    /// Save to Folder: the destination. Tokens allowed (e.g. `{space}`).
    var folderPath = ""
    var rpcEndpoint = ""
    var rpcMethod = ""
    /// XML-RPC sends each as a string.
    var rpcParameters = "[]"
    var rpcStyle: RPCStyle = .json
    /// Set when the file named an unknown action kind; the rule is kept but disabled.
    var wasDecodedFromUnknownKind = false

    /// Fields that get token substitution. Paths, endpoints and methods are literal.
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
            // The place first, the method after it in brackets (#367).
            return host.isEmpty ? rpcMethod
                : String(localized: "\(host) (\(rpcMethod))", comment: "Where a download rule sends links: the service's address, then its method in parentheses, like “127.0.0.1 (load.start)”.")
        case .saveToFolder:
            let name = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath).lastPathComponent
            return name.isEmpty ? Kind.saveToFolder.title : name
        case .openFile:
            return Kind.openFile.title
        }
    }

    /// Requires a scheme: `URL(string:)` also accepts `bing.com` or a bare word, which can't be requested.
    var endpointIsUsable: Bool {
        guard let url = URL(string: rpcEndpoint), let scheme = url.scheme, !scheme.isEmpty else { return false }
        return true
    }

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
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            guard let container else { return nil }
            return try? container.decodeIfPresent(type, forKey: key)
        }
        if let rawKind = value(String.self, .kind) {
            if let known = Kind(rawValue: rawKind) { kind = known } else { kind = .openURL; wasDecodedFromUnknownKind = true }
        } else {
            kind = .openURL
            wasDecodedFromUnknownKind = true
        }
        appPath = value(String.self, .appPath) ?? ""
        urlTemplate = value(String.self, .urlTemplate) ?? ""
        openIn = value(OpenInZigzag.Choice.self, .openIn) ?? .defaultBrowser
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

/// Common setups, so an aria2 or mpv rule is a menu choice instead of hand-written JSON.
nonisolated enum DownloadPreset: String, CaseIterable, Sendable {
    case aria2, motrix, rTorrent, ytdlp, mpv, iina

    var title: String {
        switch self {
        case .aria2: String(localized: "Send to aria2", comment: "A preset rule in Settings › Downloads, for the aria2 download manager.")
        case .motrix: String(localized: "Send to Motrix", comment: "A preset rule in Settings › Downloads, for the Motrix download manager.")
        case .rTorrent: String(localized: "Send to rTorrent", comment: "A preset rule in Settings › Downloads, for rTorrent.")
        case .ytdlp: String(localized: "Send to yt-dlp", comment: "A preset rule in Settings › Downloads, for the yt-dlp downloader.")
        case .mpv: String(localized: "Play in mpv", comment: "A preset rule in Settings › Downloads, for the mpv video player.")
        case .iina: String(localized: "Play in IINA", comment: "A preset rule in Settings › Downloads, for the IINA video player.")
        }
    }

    /// The service or app name, so the row reads "Files ending in .torrent go to rTorrent". The menu entry says "Send
    /// to rTorrent".
    var ruleName: String {
        switch self {
        case .aria2: "aria2"
        case .motrix: "Motrix"
        case .rTorrent: "rTorrent"
        case .ytdlp: "yt-dlp"
        case .mpv: "mpv"
        case .iina: "IINA"
        }
    }

    /// Media sites for players, magnets or links for downloaders.
    var rule: DownloadRule {
        switch self {
        case .aria2, .motrix:
            var action = DownloadRuleAction(kind: .jsonRPC)
            action.rpcEndpoint = self == .aria2 ? "http://127.0.0.1:6800/jsonrpc" : "http://127.0.0.1:16800/jsonrpc"
            action.rpcMethod = "aria2.addUri"
            action.rpcParameters = """
            [["{link}"], {"header": ["Cookie: {cookie_header}", "Referer: {referrer}"], "out": "{filename}"}]
            """
            return DownloadRule(name: ruleName, applies: .downloads, match: .any, action: action)
        case .rTorrent:
            var action = DownloadRuleAction(kind: .jsonRPC)
            action.rpcEndpoint = "http://127.0.0.1:8080/RPC2"
            action.rpcMethod = "load.start"
            action.rpcParameters = """
            ["", "{link}"]
            """
            action.rpcStyle = .xmlrpc
            return DownloadRule(name: ruleName, applies: .downloads, match: .any, action: action)
        case .ytdlp:
            var action = DownloadRuleAction(kind: .runScript)
            // Via env, so it's found under either Homebrew prefix or anywhere on PATH.
            action.scriptPath = "/usr/bin/env"
            action.arguments = ["yt-dlp", "--no-playlist", "--cookies", "{cookies}", "{link}"]
            return DownloadRule(name: ruleName, applies: .downloads, match: .any, action: action)
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

// MARK: - Values a token stands for

/// Token values for one handoff. Cookies are filled only when a rule needs them, since reading the store is slow.
nonisolated struct HandoffValues: Equatable, Sendable {
    var link: URL
    /// The saved file, only when a File handoff has finished downloading one.
    var file: URL?
    var referrer: URL?
    var filename: String
    var mime: String
    var space: String
    var cookieHeader = ""
    var cookieFile = ""

    init(link: URL, file: URL? = nil, referrer: URL? = nil, filename: String = "", mime: String = "", space: String = "",
         cookieHeader: String = "", cookieFile: String = "") {
        self.link = link
        self.file = file
        self.referrer = referrer
        self.filename = filename.isEmpty
            ? DownloadTokens.filename(for: file ?? link, suggested: "")
            : filename
        self.mime = mime
        self.space = space
        self.cookieHeader = cookieHeader
        self.cookieFile = cookieFile
    }
}

// MARK: - Tokens

nonisolated enum DownloadTokens {
    /// All tokens, for the editor's note.
    static let names = ["{link}", "{encoded_link}", "{referrer}", "{cookies}", "{cookie_header}", "{filename}", "{mime}",
                        "{space}", "{file}", "{file_url}"]

    /// Encodes `&`, `+`, `=` and `#` so they stay inside the value.
    static func queryValue(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func encoded(_ url: URL) -> String { queryValue(url.absoluteString) }

    /// Strips control, format (incl. bidi), line/paragraph separators, surrogates, unassigned scalars, folder
    /// separators and colons. Shared with the download manager.
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

    /// Safe for Downloads, a header or an argument: no folder separators, control characters, leading dot, or leading
    /// dash a script would read as an option.
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

    /// JSON string contents, without the quotes.
    static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return value }
        return String(text.dropFirst().dropLast())
    }

    /// Fills tokens in one pass, so a value that contains `{link}` or `{secret}` isn't expanded again. `query`
    /// encodes each value as one query value so a filename can't add parameters. `{path}`, `{query}` and
    /// `{encoded_link}` are already encoded and aren't encoded twice. `json` escapes each value for a JSON string.
    static func expand(_ template: String, with values: HandoffValues, secret: String = "", json: Bool = false,
                       query: Bool = false) -> String {
        func value(_ text: String) -> String {
            if json { return jsonEscaped(text) }
            if query { return queryValue(text) }
            return text
        }
        // Already encoded: JSON-escaped if needed, never percent-encoded again.
        func part(_ text: String) -> String { json ? jsonEscaped(text) : text }
        // So aria2 or yt-dlp don't read a MIME type starting with `-` as an option.
        let mime = values.mime.hasPrefix("-") ? "_" + values.mime : values.mime
        let replacements: [String: String] = [
            "{encoded_link}": part(encoded(values.link)),
            "{cookie_header}": value(values.cookieHeader),
            "{cookies}": value(values.cookieFile),
            "{referrer}": value(values.referrer?.absoluteString ?? ""),
            "{filename}": value(values.filename),
            "{mime}": value(mime),
            "{space}": value(values.space),
            // Only a File handoff has one; a URL handoff leaves both empty.
            "{file}": value(values.file?.path ?? ""),
            "{file_url}": value(values.file?.absoluteString ?? ""),
            "{secret}": value(secret),
            // Address parts, e.g. `https://bing.com{path}` sends a google.com match to the same page on bing.com.
            // Already percent-encoded.
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

/// A cookie outside WebKit, so matching and the file can be tested without a web view.
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

    /// No leading dot means host-only.
    var isHostOnly: Bool { !domain.hasPrefix(".") }

    /// Domain and path match, not expired, and secure cookies only over https.
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

    /// HTTP-only cookies included: the receiving program makes the request itself.
    var headerField: String { "\(name)=\(value)" }
}

nonisolated enum HandoffCookies {
    /// Sorted, with their Cookie header.
    static func matching(_ cookies: [HandoffCookie], for url: URL, now: Date = Date()) -> [HandoffCookie] {
        cookies.filter { $0.applies(to: url, now: now) }
            .sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
    }

    static func header(_ cookies: [HandoffCookie]) -> String {
        cookies.map(\.headerField).joined(separator: "; ")
    }

    /// Netscape cookies.txt for yt-dlp and aria2. HTTP-only cookies get `#HttpOnly_`, as curl and yt-dlp write them.
    static func netscape(_ cookies: [HandoffCookie]) -> String {
        var lines = ["# Netscape HTTP Cookie File", "# Written by Zigzag for one handoff.", ""]
        for cookie in cookies {
            // yt-dlp refuses a file where the leading dot and the subdomains flag disagree: host-only is
            // `example.com` FALSE, domain is `.example.com` TRUE.
            let domain = cookie.domain
            let includeSubdomains = cookie.isHostOnly ? "FALSE" : "TRUE"
            let secure = cookie.isSecure ? "TRUE" : "FALSE"
            let expiry = cookie.expires.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            let prefix = cookie.isHTTPOnly ? "#HttpOnly_" : ""
            lines.append("\(prefix)\(domain)\t\(includeSubdomains)\t\(cookie.path)\t\(secure)\t\(expiry)\t\(cookie.name)\t\(cookie.value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes to a temp folder, owner-readable only, and returns the path.
    static func writeFile(_ cookies: [HandoffCookie]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ZigzagHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("cookies.txt")
        try Data(netscape(cookies).utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    static func removeFile(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

// MARK: - The list

/// Rules in order, stored in DownloadRules.json and shared by all profiles. Cookies and space come from the
/// triggering tab.
@MainActor
final class DownloadRulesStore {
    static let shared = DownloadRulesStore()

    private(set) var rules: [DownloadRule]
    let changed = Signal<Void>()
    /// Tests pass their own file.
    private let file: URL

    init(file: URL = Paths.downloadRules) {
        self.file = file
        rules = JSONStore.load([DownloadRule].self, from: file) ?? []
    }

    /// First rule that matches. `appliesToLinks` is false for downloads; `filename` is the download's name (links
    /// pass none).
    func firstMatch(url: URL, filename: String = "", appliesToLinks: Bool, isPrivate: Bool = false) -> DownloadRule? {
        Self.firstMatch(in: rules, url: url, filename: filename, appliesToLinks: appliesToLinks, isPrivate: isPrivate)
    }

    /// Static version for testing or previews. Rules not allowed in private windows are skipped there.
    nonisolated static func firstMatch(in rules: [DownloadRule], url: URL, filename: String = "",
                                       appliesToLinks: Bool, isPrivate: Bool = false) -> DownloadRule? {
        rules.first { rule in
            guard rule.applies == .linksAndDownloads || !appliesToLinks else { return false }
            guard !isPrivate || rule.runsInPrivateWindows else { return false }
            return rule.matches(url, filename: filename)
        }
    }

    /// First handoff rule for a download, unless an earlier destination rule claims it first (a later catch-all
    /// handoff can't take a file a type rule claimed). An Open refused by `DownloadOpening` counts as no match.
    /// `profile`: the page's. None of your rules apply to AI apps'.
    func firstHandoffMatch(url: URL, filename: String, appliesToLinks: Bool, isPrivate: Bool = false, in profile: Profile?) -> DownloadRule? {
        guard profile?.getsYourData != false else { return nil }
        return Self.firstHandoffMatch(in: rules, url: url, filename: filename, appliesToLinks: appliesToLinks, isPrivate: isPrivate)
    }

    nonisolated static func firstHandoffMatch(in rules: [DownloadRule], url: URL, filename: String = "",
                                              appliesToLinks: Bool, isPrivate: Bool = false) -> DownloadRule? {
        for rule in rules {
            guard rule.applies == .linksAndDownloads || !appliesToLinks else { continue }
            guard rule.matches(url, filename: filename) else { continue }
            if let destination = rule.action.destination {
                // Destinations only apply to downloads, as in `destination(in:)`.
                guard rule.applies == .downloads else { continue }
                // Save still applies in private windows; Open needs the rule's private-window switch.
                if isPrivate, !rule.runsInPrivateWindows, destination == .open { continue }
                if destination == .open, DownloadOpening.isRefused((filename as NSString).pathExtension) { continue }
                return nil
            }
            guard !isPrivate || rule.runsInPrivateWindows else { continue }
            return rule
        }
        return nil
    }

    /// First destination rule (`saveToFolder`, `openFile`) for this download; handoff rules are left to the handoff
    /// path. First match wins. `profile`: the downloading page's; none apply in AI apps' profile, as for hand-offs.
    func destination(for url: URL, filename: String, in profile: Profile?) -> (rule: DownloadRule, destination: DownloadDestination)? {
        guard profile?.getsYourData != false else { return nil }
        return Self.destination(in: rules, url: url, filename: filename)
    }

    /// Static version for testing or previews.
    nonisolated static func destination(in rules: [DownloadRule], url: URL, filename: String)
        -> (rule: DownloadRule, destination: DownloadDestination)? {
        for rule in rules {
            guard rule.applies == .downloads, rule.isEnabled, let destination = rule.action.destination,
                  rule.matches(url, filename: filename) else { continue }
            // A refused Open (app, script, installer, archive) is skipped, even from an older build, so a later Save
            // rule can still take the file.
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
        let old = rules[index]
        // Answers were given for the old behavior; a new script, URL or handoff type clears them. Changing the name or
        // other fields doesn't.
        var saved = rule
        if old.action.scriptPath != rule.action.scriptPath || old.action.urlTemplate != rule.action.urlTemplate
            || old.handoffType != rule.handoffType {
            saved.handoffAnswer = nil
            Self.forgetHandoffAnswers(for: rule.id)
        }
        rules[index] = saved
        save()
    }

    /// New file types go after existing ones and before the first handoff rule, matching Settings' order. At the end
    /// they'd sit behind a catch-all handoff and never match.
    nonisolated static func placeForNewFileType(in rules: [DownloadRule]) -> Int {
        rules.firstIndex { !$0.action.kind.isDestination } ?? rules.count
    }

    func add(_ rule: DownloadRule, at index: Int? = nil) {
        let place = min(max(0, index ?? rules.count), rules.count)
        rules.insert(rule, at: place)
        save()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        HandoffSecrets.removeSecret(for: id)
        // Only this rule could read its answers.
        Self.forgetHandoffAnswers(for: id)
        save()
    }

    /// Forgets the `handoff:<id>` answers, which applied to the rule's old behavior.
    private static func forgetHandoffAnswers(for id: UUID) {
        let subject = PermissionSubject.handoff(id)
        for site in SitePermissions.sites(prefix: subject) { SitePermissions.remember(nil, subject: subject, origin: site) }
    }

    /// Moves rule `id` before `beforeID` (`nil` puts it last). Static so a drag's result can be tested; a filtered
    /// list names the drop row rather than an index.
    nonisolated static func moved(_ rules: [DownloadRule], id: UUID, before beforeID: UUID?) -> [DownloadRule] {
        guard let from = rules.firstIndex(where: { $0.id == id }) else { return rules }
        var without = rules
        let rule = without.remove(at: from)
        let to = beforeID.flatMap { before in without.firstIndex(where: { $0.id == before }) } ?? without.count
        guard to != from else { return rules }
        without.insert(rule, at: min(to, without.count))
        return without
    }

    /// As the Up and Down buttons do.
    func move(from: Int, to: Int) {
        guard rules.indices.contains(from), rules.indices.contains(to), from != to else { return }
        let rule = rules.remove(at: from)
        rules.insert(rule, at: to)
        save()
    }

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
        JSONStore.save(rules, to: file)
        changed.send()
    }
}

// MARK: - Secrets

/// aria2 or rTorrent tokens, stored in the Keychain by rule id, never in the rules file.
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
