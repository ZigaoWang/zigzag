import Foundation
import Security
import WebKit

// MARK: - A rule

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

    /// How a rule compares the address. `any` is the catch-all that sits at the bottom of the list.
    enum Match: String, Codable, CaseIterable, Sendable {
        case startsWith, contains, endsWith, regex, any

        var title: String {
            switch self {
            case .startsWith: String(localized: "Starts with", comment: "How a download rule matches an address, in its editor.")
            case .contains: String(localized: "Contains", comment: "How a download rule matches an address, in its editor.")
            case .endsWith: String(localized: "Ends with", comment: "How a download rule matches an address, in its editor.")
            case .regex: String(localized: "Regular Expression", comment: "How a download rule matches an address, in its editor.")
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
            case .any: String(localized: "any address", comment: "A rule's kind, in its row in Settings › Downloads: the catch-all.")
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

    /// What the row says it catches.
    var matchSummary: String {
        switch match {
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
        case id, name, isEnabled, applies, match, pattern, isCaseSensitive, action
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

/// The action behind a rule. One flat shape with a `kind`, rather than an enum with a payload each, so the file stays
/// readable, a field a newer Zigzag adds doesn't break an older one, and the editor's fields map one to one.
nonisolated struct DownloadRuleAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case openApp
        case openURL
        case runScript
        case jsonRPC

        var title: String {
            switch self {
            case .openApp: String(localized: "Open App", comment: "An action a download rule can take, in its editor: hand the link to an app.")
            case .openURL: String(localized: "Open URL", comment: "An action a download rule can take, in its editor: open a URL, which may point at another app.")
            case .runScript: String(localized: "Run Script", comment: "An action a download rule can take, in its editor: run an executable with the link as an argument.")
            case .jsonRPC: String(localized: "JSON-RPC", comment: "An action a download rule can take, in its editor: send the link to a service such as aria2 or rTorrent.")
            }
        }

        var symbol: String {
            switch self {
            case .openApp: "arrow.up.forward.app"
            case .openURL: "link"
            case .runScript: "terminal"
            case .jsonRPC: "network"
            }
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
    /// Open App: the app's path, as chosen in the open panel.
    var appPath = ""
    /// Open URL: the URL to open, with tokens such as `{encoded_link}`.
    var urlTemplate = ""
    /// Run Script: the executable, or a `.sh` file run by `/bin/sh`.
    var scriptPath = ""
    /// Run Script: one argv value each. A token is substituted into its own argument, never joined into a shell line.
    var arguments: [String] = []
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
        }
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
            return !rpcEndpoint.isEmpty && URL(string: rpcEndpoint) != nil && !rpcMethod.isEmpty
        }
    }

    init(kind: Kind) { self.kind = kind }

    private enum CodingKeys: String, CodingKey {
        case kind, appPath, urlTemplate, scriptPath, arguments, rpcEndpoint, rpcMethod, rpcParameters, rpcStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .openURL
        appPath = try container.decodeIfPresent(String.self, forKey: .appPath) ?? ""
        urlTemplate = try container.decodeIfPresent(String.self, forKey: .urlTemplate) ?? ""
        scriptPath = try container.decodeIfPresent(String.self, forKey: .scriptPath) ?? ""
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        rpcEndpoint = try container.decodeIfPresent(String.self, forKey: .rpcEndpoint) ?? ""
        rpcMethod = try container.decodeIfPresent(String.self, forKey: .rpcMethod) ?? ""
        rpcParameters = try container.decodeIfPresent(String.self, forKey: .rpcParameters) ?? "[]"
        rpcStyle = try container.decodeIfPresent(RPCStyle.self, forKey: .rpcStyle) ?? .json
    }
}

// MARK: - Presets

/// The arrangements most people want, so a rule for aria2 or mpv is a menu choice and a look at the fields rather
/// than a JSON lesson.
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

    /// The rule a preset starts from: a media site for the players, a magnet or link for the downloaders.
    var rule: DownloadRule {
        switch self {
        case .aria2, .motrix:
            var action = DownloadRuleAction(kind: .jsonRPC)
            action.rpcEndpoint = self == .aria2 ? "http://127.0.0.1:6800/jsonrpc" : "http://127.0.0.1:16800/jsonrpc"
            action.rpcMethod = "aria2.addUri"
            action.rpcParameters = """
            [["{link}"], {"header": ["Cookie: {cookie_header}", "Referer: {referrer}"], "out": "{filename}"}]
            """
            return DownloadRule(name: title, applies: .linksAndDownloads, match: .any, action: action)
        case .rTorrent:
            var action = DownloadRuleAction(kind: .jsonRPC)
            action.rpcEndpoint = "http://127.0.0.1:8080/RPC2"
            action.rpcMethod = "load.start"
            action.rpcParameters = """
            ["", "{link}"]
            """
            action.rpcStyle = .xmlrpc
            return DownloadRule(name: title, applies: .linksAndDownloads, match: .any, action: action)
        case .ytdlp:
            var action = DownloadRuleAction(kind: .runScript)
            // Through env, so it's found under either Homebrew prefix, and anywhere else on PATH.
            action.scriptPath = "/usr/bin/env"
            action.arguments = ["yt-dlp", "--no-playlist", "--cookies", "{cookies}", "{link}"]
            return DownloadRule(name: title, applies: .linksAndDownloads, match: .any, action: action)
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

    /// The first rule that catches `url`, or none. `appliesToLinks` is false for a download.
    func firstMatch(url: URL, appliesToLinks: Bool) -> DownloadRule? {
        Self.firstMatch(in: rules, url: url, appliesToLinks: appliesToLinks)
    }

    /// The same order, apart from the file, for a list being tested or previewed.
    nonisolated static func firstMatch(in rules: [DownloadRule], url: URL, appliesToLinks: Bool) -> DownloadRule? {
        rules.first { rule in
            guard rule.applies == .linksAndDownloads || !appliesToLinks else { return false }
            return rule.matches(url)
        }
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

    func move(from: Int, to: Int) {
        guard rules.indices.contains(from), to >= 0, to < rules.count, from != to else { return }
        let rule = rules.remove(at: from)
        rules.insert(rule, at: to)
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
