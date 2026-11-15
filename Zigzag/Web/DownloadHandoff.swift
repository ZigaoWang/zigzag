import AppKit
import Foundation
import WebKit

/// Runs the first rule that catches a link or a download: opens an app or a URL, runs a script, or calls a JSON-RPC or
/// XML-RPC service. The tab's own store supplies the cookies, so a logged-in download keeps its sign-in; nothing here
/// ever builds a shell line, so a URL with `&`, `;` or `$()` arrives as one argument.
@MainActor
enum DownloadHandoff {
    /// One handoff's occasion: the address, what the page said about it, and where its cookies live.
    struct Request {
        var url: URL
        var referrer: URL?
        /// The site the page that asked is on, when there is one: what a handoff question is keyed to, and the only
        /// site whose cookies may go to a target of its own.
        var pageOrigin: String?
        var filename = ""
        var mime = ""
        var space = ""
        var dataStore: WKWebsiteDataStore?
        var isPrivate = false
        var window: NSWindow?
        /// The tab that asked, where one did: its page keeps the answer for as long as it is on the page.
        var tab: Tab?
        /// Whether you clicked the link that led here. A click may send this page's cookies to the target; a page
        /// that starts a download or a navigation on its own may not.
        var wasClicked = false
    }

    enum Outcome: Equatable {
        /// A rule ran. The navigation is cancelled, and any download WebKit made for it is.
        case handedOff
        /// No rule wanted it: carry on as if there were none.
        case noMatch
        /// A link was refused at the handoff question: cancel its navigation without running the rule. A download
        /// has nowhere to go on to, so a refusal there leaves it to be saved as usual.
        case cancelled
        case failed(String)
    }

    /// The rule that catches `url`, if any, and whether it wants a link (true) or a download (false).
    static func firstMatch(_ url: URL, appliesToLinks: Bool, isPrivate: Bool = false) -> DownloadRule? {
        DownloadRulesStore.shared.firstMatch(url: url, appliesToLinks: appliesToLinks, isPrivate: isPrivate)
    }

    /// Where a handoff stands: run the rule, leave it in the browser, or cancel the link.
    enum HandoffGate: Equatable { case handOff, browser, cancel }

    static func gate(stored: String?) -> HandoffGate {
        switch stored {
        case "handOff": .handOff
        case "browser": .browser
        case "deny": .cancel
        default: .browser
        }
    }

    /// The key a page answer is kept under: per rule, so two rules on one page keep their own answers.
    static func handoffKind(_ rule: DownloadRule) -> String { "handoff:\(rule.id.uuidString)" }

    /// Asks where a handoff should go, unless this page already answered for this rule. The question asks in the
    /// page's own window; with no window to ask in, nothing is handed off and the link or download stays as it is.
    /// The answer holds for the page: a link that starts a download is one question, not two.
    static func decide(_ rule: DownloadRule, request: Request, tab: Tab? = nil) async -> HandoffGate {
        // A private window runs no rule that hasn't been let in, even if a caller hands one over directly.
        guard !request.isPrivate || rule.runsInPrivateWindows else { return .browser }
        let origin = request.pageOrigin ?? SiteOrigin.of(request.referrer) ?? SiteOrigin.of(request.url)
        let kind = handoffKind(rule)
        if let origin, let tab, let kept = tab.permissionAnswers.action(key: origin, kind: kind) {
            return gate(stored: kept)
        }
        guard let controller = tab.flatMap({ WindowManager.shared.promptHost(holding: $0) })
                ?? WindowManager.shared.promptHost(for: request.window)
                ?? WindowManager.shared.promptHost(for: NSApp.keyWindow) else { return .browser }
        let answer = await PermissionPrompt.ask(
            host: SitePermissions.askerName(origin), origin: origin, what: rule.name, symbol: "arrow.up.forward.app",
            in: controller, tab: tab,
            title: String(localized: "Hand Off \(rule.name)", comment: "A page's question before a download rule handles a link or download. The placeholder is the rule's name."),
            allowTitle: String(localized: "Hand Off", comment: "Button that runs the named download rule for a link or download."),
            alternateTitle: String(localized: "Open in Browser", comment: "Button that lets a link or download stay in the browser instead of running a download rule."),
            denyTitle: String(localized: "Don’t Allow", comment: "Button that refuses a download rule's handoff."))
        let action: String
        switch answer {
        case .allow, .always: action = "handOff"
        case .alternate: action = "browser"
        case .deny: action = "deny"
        case .notNow: return .browser
        }
        if let origin, let tab { tab.permissionAnswers.note(action, key: origin, kind: kind) }
        return gate(stored: action)
    }

    /// Whether a rule may read this page's cookies for its target: only when the target is the page's own site, or
    /// when you clicked the link that led to it. A page that names another site on its own gets none of its cookies.
    static func maySendCookies(_ request: Request) -> Bool {
        request.wasClicked || (request.pageOrigin != nil && SiteOrigin.of(request.url) == request.pageOrigin)
    }

    @discardableResult
    static func route(_ url: URL, appliesToLinks: Bool, request: Request, tab: Tab? = nil) async -> Outcome {
        guard let rule = firstMatch(url, appliesToLinks: appliesToLinks) else { return .noMatch }
        switch await decide(rule, request: request, tab: tab ?? request.tab) {
        case .handOff: return await perform(rule, request: request)
        case .browser: return .noMatch
        case .cancel: return appliesToLinks ? .cancelled : .noMatch
        }
    }

    /// Runs one rule. Cookies are read only when its action names one, and the files it makes are gone by the end.
    @discardableResult
    static func perform(_ rule: DownloadRule, request: Request) async -> Outcome {
        var values = HandoffValues(link: request.url, referrer: request.referrer, filename: request.filename,
                                   mime: request.mime, space: request.space)
        let secret = rule.action.kind == .jsonRPC ? (HandoffSecrets.secret(for: rule.id) ?? "") : ""
        var cookieFile: URL?
        // The site's sign-in may go to a target of its own, or to one you clicked through to. A page that names
        // another site on its own gets none of this site's cookies, whichever rule it names.
        if rule.needsCookies, maySendCookies(request) {
            let cookies = await cookies(from: request.dataStore, for: request.url)
            values.cookieHeader = HandoffCookies.header(cookies)
            if rule.usesCookieFile, let file = try? HandoffCookies.writeFile(cookies) {
                values.cookieFile = file.path
                cookieFile = file
            }
        }
        let outcome: Outcome
        switch rule.action.kind {
        case .runScript:
            outcome = runScript(rule.action, values: values, secret: secret, request: request, rule: rule)
            // A script keeps the file until it exits; one that never started has no use for it.
            if outcome != .handedOff, let cookieFile { HandoffCookies.removeFile(cookieFile) }
        case .openApp:
            outcome = await openApp(rule.action, values: values, secret: secret)
            if let cookieFile { removeWhenTheOtherAppHasRead(cookieFile) }
        case .openURL:
            outcome = openURL(rule.action, values: values, secret: secret)
            if let cookieFile { removeWhenTheOtherAppHasRead(cookieFile) }
        case .jsonRPC:
            outcome = await callService(rule.action, values: values, secret: secret)
            if let cookieFile { HandoffCookies.removeFile(cookieFile) }
        }
        return outcome
    }

    /// A rule that ran, but not: said over the page, and noted without the link, the cookies or the secret.
    static func report(_ outcome: Outcome, rule: DownloadRule?, request: Request) {
        report(outcome, rule: rule, url: request.url, isPrivate: request.isPrivate, window: request.window)
    }

    /// The same, for a failure that arrives after the tab has moved on (a script that exits non-zero).
    static func report(_ outcome: Outcome, rule: DownloadRule?, url: URL, isPrivate: Bool, window: NSWindow? = nil) {
        guard case .failed(let reason) = outcome else { return }
        Diagnostics.note("Handoff failed", site: url.host(), "\(rule?.name ?? "Rule"): \(reason)", isPrivate: isPrivate)
        guard let controller = WindowManager.shared.controller(for: window) ?? WindowManager.shared.keyController else { return }
        Toast.show(String(localized: "Couldn’t hand off the link: \(reason)", comment: "Toast when a download rule's action fails. The placeholder is the reason, a few words."),
                   symbol: "exclamationmark.triangle", duration: 4, in: controller)
    }

    /// An app handed a `{cookies}` path may read it a moment later than the open call returns. The file waits a few
    /// minutes in the temporary folder, readable by its owner only, then goes.
    private static func removeWhenTheOtherAppHasRead(_ file: URL) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(300))
            HandoffCookies.removeFile(file)
        }
    }

    // MARK: Cookies

    /// The tab's cookies that a request for `url` would carry, from its own store, never another profile's.
    static func cookies(from store: WKWebsiteDataStore?, for url: URL) async -> [HandoffCookie] {
        guard let store else { return [] }
        let all: [HandoffCookie] = await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.map(HandoffCookie.init))
            }
        }
        return HandoffCookies.matching(all, for: url)
    }

    // MARK: Actions

    private static func openApp(_ action: DownloadRuleAction, values: HandoffValues, secret: String) async -> Outcome {
        // A path is literal: what a page says in a link may become an argument, never the program that runs.
        let path = (action.appPath as NSString).expandingTildeInPath
        let app = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.path) else {
            return .failed(String(localized: "The app is no longer there.", comment: "Why a download rule failed: the app it was told to open is gone."))
        }
        let configuration = NSWorkspace.OpenConfiguration()
        let error: Error? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([values.link], withApplicationAt: app, configuration: configuration) { _, error in
                continuation.resume(returning: error)
            }
        }
        if let error { return .failed(error.localizedDescription) }
        return .handedOff
    }

    private static func openURL(_ action: DownloadRuleAction, values: HandoffValues, secret: String) -> Outcome {
        let text = DownloadTokens.expand(action.urlTemplate, with: values, secret: secret)
        guard let url = URL(string: text), url.scheme != nil else {
            return .failed(String(localized: "The URL isn’t valid.", comment: "Why a download rule failed: the URL it was told to open can't be made."))
        }
        return NSWorkspace.shared.open(url) ? .handedOff
            : .failed(String(localized: "No app opens that URL.", comment: "Why a download rule failed: nothing on this Mac handles the URL's scheme."))
    }

    /// Runs the script with every token as its own argument or environment value. A `.sh` file is run by `/bin/sh`;
    /// anything else must be executable. Never `/bin/sh -c`, and never a joined command line.
    private static func runScript(_ action: DownloadRuleAction, values: HandoffValues, secret: String,
                                  request: Request, rule: DownloadRule?) -> Outcome {
        // Literal, as an app's path is: a link may fill an argument, never choose the script.
        let path = (action.scriptPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return .failed(String(localized: "The script is no longer there.", comment: "Why a download rule failed: the script it was told to run is gone."))
        }
        let process = Process()
        if path.lowercased().hasSuffix(".sh") {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [path] + action.arguments.map { DownloadTokens.expand($0, with: values, secret: secret) }
        } else {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = action.arguments.map { DownloadTokens.expand($0, with: values, secret: secret) }
        }
        var environment = ProcessInfo.processInfo.environment
        // An app opened from the Finder inherits a bare `PATH`, so `yt-dlp` and friends installed by Homebrew or a
        // hand-installed tool in /usr/local/bin wouldn't be found. Those two come first; the user's own `PATH` stays.
        let inherited = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + inherited
        environment["ZIGZAG_LINK"] = values.link.absoluteString
        environment["ZIGZAG_REFERRER"] = values.referrer?.absoluteString ?? ""
        environment["ZIGZAG_FILENAME"] = values.filename
        environment["ZIGZAG_MIME"] = values.mime
        environment["ZIGZAG_SPACE"] = values.space
        if !values.cookieFile.isEmpty { environment["ZIGZAG_COOKIES"] = values.cookieFile }
        if !values.cookieHeader.isEmpty { environment["ZIGZAG_COOKIE_HEADER"] = values.cookieHeader }
        if !secret.isEmpty { environment["ZIGZAG_SECRET"] = secret }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let errors = ScriptErrors()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errors.append(handle.availableData)
        }
        let cookieFile = values.cookieFile
        let link = values.link
        let isPrivate = request.isPrivate
        process.terminationHandler = { finished in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            errors.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            if !cookieFile.isEmpty { HandoffCookies.removeFile(URL(fileURLWithPath: cookieFile)) }
            guard finished.terminationStatus != 0 else { return }
            // The script ran and failed. Say so: a silent failure looks like a download that never happened.
            let said = errors.text
            let reason = said.isEmpty
                ? String(localized: "The script exited with status \(finished.terminationStatus).", comment: "Why a download rule failed: the script finished with an error code. The placeholder is a number, like 1.")
                : String(localized: "The script failed: \(said)", comment: "Why a download rule failed: the script exited with an error code and printed this. The placeholder is the script's own last line of error text.")
            Task { @MainActor in
                report(.failed(reason), rule: rule, url: link, isPrivate: isPrivate)
            }
        }
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        return .handedOff
    }

    // MARK: JSON-RPC and XML-RPC

    private static func callService(_ action: DownloadRuleAction, values: HandoffValues, secret: String) async -> Outcome {
        // The service and its method are literal too: a page can fill the parameters, not pick where they are sent.
        guard let endpoint = URL(string: action.rpcEndpoint) else {
            return .failed(String(localized: "The service’s address isn’t valid.", comment: "Why a download rule failed: the JSON-RPC endpoint can't be made into a URL."))
        }
        let method = action.rpcMethod
        guard let parameters = parameters(action.rpcParameters, values: values, secret: secret) else {
            return .failed(String(localized: "The parameters aren’t valid JSON.", comment: "Why a download rule failed: the JSON-RPC parameters don't parse."))
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        if action.rpcStyle == .xmlrpc {
            request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(xmlRPC(method: method, parameters: parameters).utf8)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var call: [String: Any] = ["jsonrpc": "2.0", "id": "zigzag", "method": method, "params": jsonParameters(parameters, method: method, secret: secret)]
            if call["params"] == nil { call["params"] = [] }
            guard let body = try? JSONSerialization.data(withJSONObject: call) else {
                return .failed(String(localized: "The request couldn’t be built.", comment: "Why a download rule failed: its JSON-RPC body can't be made."))
            }
            request.httpBody = body
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failed(String(localized: "The service answered \(http.statusCode).", comment: "Why a download rule failed: the service's HTTP status. The placeholder is a number, like 401."))
            }
            if let message = serviceError(in: data, style: action.rpcStyle) { return .failed(message) }
            return .handedOff
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The parameter array, parsed from the rule's JSON. aria2 and rTorrent want their token as the first parameter;
    /// it's put there only when a secret is kept and the template hasn't placed it itself.
    static func parameters(_ template: String, values: HandoffValues, secret: String) -> [Any]? {
        let text = DownloadTokens.expand(template, with: values, secret: secret, json: true)
        let data = Data(text.utf8)
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return parsed
    }

    static func jsonParameters(_ parameters: [Any], method: String, secret: String) -> [Any] {
        guard !secret.isEmpty, method.hasPrefix("aria2.") || method.hasPrefix("system.") || method.hasPrefix("torrent.") else { return parameters }
        // A template that already put a token first is left as it is.
        if let first = parameters.first as? String, first.hasPrefix("token:") { return parameters }
        return ["token:\(secret)"] + parameters
    }

    static func xmlRPC(method: String, parameters: [Any]) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }
        let params = parameters.map { parameter -> String in
            let value: String
            if let number = parameter as? NSNumber { value = "<int>\(number.intValue)</int>" }
            else if let flag = parameter as? Bool { value = "<boolean>\(flag ? 1 : 0)</boolean>" }
            else { value = "<string>\(escape(String(describing: parameter)))</string>" }
            return "<param><value>\(value)</value></param>"
        }.joined()
        return "<?xml version=\"1.0\"?><methodCall><methodName>\(escape(method))</methodName><params>\(params)</params></methodCall>"
    }

    /// What a service said went wrong, in its own words when it gave any.
    static func serviceError(in data: Data, style: DownloadRuleAction.RPCStyle) -> String? {
        if style == .xmlrpc {
            let text = String(decoding: data, as: UTF8.self)
            guard let range = text.range(of: "<name>faultString</name>") else { return nil }
            let rest = text[range.upperBound...]
            guard let start = rest.range(of: "<string>"), let end = rest.range(of: "</string>", range: start.upperBound..<rest.endIndex) else { return nil }
            return String(rest[start.upperBound..<end.lowerBound])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

/// The tail of what a script wrote to standard error, so a failure can say what the script itself said. A pipe read on
/// a background queue and a toast on the main one share it, hence the lock.
private nonisolated final class ScriptErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 2_000

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data = Data(data.suffix(limit)) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        let last = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return last.map { String($0.prefix(300)) } ?? ""
    }
}
