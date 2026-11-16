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
        /// The tab that asked, where one did: its page keeps the answer for as long as it is on the page, and an Open
        /// URL rule opening a web address in Zigzag opens it in relation to this tab ("This Tab" is this one).
        var tab: Tab?
        /// Whether you clicked the link that led here. A click may send this page's cookies to the target; a page
        /// that starts a download or a navigation on its own may not.
        var wasClicked = false
        /// Whether a new question may be put at all. A pop-up has no page store of its own and its window can sit
        /// behind the browser's, so its links and downloads are always Zigzag's own rather than a question in another
        /// window. A page's kept answer is still read, where there is a page.
        var mayAsk = true
    }

    enum Outcome: Equatable {
        /// A rule ran. The navigation is cancelled, and any download WebKit made for it is.
        case handedOff
        /// No rule wanted it: carry on as if there were none. Also what an Open URL rule answers when its question was
        /// put off, so the link loads or the file saves as if the rule had never matched.
        case noMatch
        /// Refused at the handoff question: cancel it without running the rule. A link goes nowhere, and a download
        /// is not saved either.
        case cancelled
        case failed(String)
    }

    /// The rule that catches `url`, if any, and whether it wants a link (true) or a download (false).
    static func firstMatch(_ url: URL, appliesToLinks: Bool, filename: String = "", isPrivate: Bool = false) -> DownloadRule? {
        guard isHandoffable(url) else { return nil }
        return DownloadRulesStore.shared.firstHandoffMatch(url: url, filename: filename, appliesToLinks: appliesToLinks,
                                                           isPrivate: isPrivate)
    }

    /// Whether a rule may take this address at all. Zigzag's own pages and the certificate warning's proceed link are
    /// not links a page may hand to an app: a catch-all rule could otherwise turn "Visit this site anyway" into an
    /// app launch, or send a history page to a script.
    static func isHandoffable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        // Zigzag's own schemes, the certificate warning's proceed link and a web app's link are never a rule's.
        if scheme == HistoryPage.scheme || scheme == CertificateExceptions.scheme || scheme == "zigzag-webapp" { return false }
        if ["about", "data", "blob", "javascript", "file"].contains(scheme) { return false }
        if scheme.hasSuffix("-extension") { return false }
        return true
    }

    /// Whether a new question can be seen before it is put: the page in front (or no page named, for a window of its
    /// own), and the window visible and key. A kept page answer doesn't need this.
    static func questionCanShow(tabIsInFront: Bool?, windowIsVisible: Bool, windowIsKey: Bool) -> Bool {
        (tabIsInFront ?? true) && windowIsVisible && windowIsKey
    }

    /// Where a handoff stands: run the rule, leave it in the browser, or cancel the link.
    enum HandoffGate: Equatable { case handOff, browser, cancel }

    /// A stored answer as a gate. Nil and anything that isn't one of the three answers read as the browser, which is
    /// what a caller that only has an answer to pass has always meant.
    static func gate(stored: String?) -> HandoffGate {
        switch stored {
        case "handOff": .handOff
        case "browser": .browser
        case "deny": .cancel
        default: .browser
        }
    }

    /// A kept answer as a gate, or nil when there is no answer yet. Unlike `gate`, an unknown or missing answer is not
    /// the browser: it is the caller's sign that the question still has to be asked.
    private static func keptGate(_ stored: String?) -> HandoffGate? {
        switch stored {
        case "handOff": .handOff
        case "browser": .browser
        case "deny": .cancel
        default: nil
        }
    }

    /// The key a page answer is kept under: per rule, so two rules on one page keep their own answers.
    static func handoffKind(_ rule: DownloadRule) -> String { "handoff:\(rule.id.uuidString)" }

    /// The site that produced the handoff, never the destination when a page or referrer can name it instead.
    static func questionOrigin(for request: Request) -> String? {
        request.pageOrigin ?? SiteOrigin.of(request.referrer) ?? SiteOrigin.of(request.url)
    }

    /// The third duration a handoff question offers: the rule by name, or "this rule" where it has none. Kept on the
    /// rule itself, the answer travels with it, is exported with it, and goes when it does.
    static func alwaysFor(_ rule: DownloadRule) -> String {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? String(localized: "Always for this rule", comment: "Duration choice on a question a download rule asks: the answer is kept on the rule, for every site. The rule has no name.")
            : String(localized: "Always for “\(name)”", comment: "Duration choice on a question a download rule asks: the answer is kept on the rule, for every site. The placeholder is the rule's name.")
    }

    /// Asks where a handoff should go, unless this page, this site or the rule itself already answered. The question
    /// asks in the page's own window; with no window to ask in, nothing is handed off and the link or download stays as
    /// it is. A link that starts a download is one question, not two.
    static func decide(_ rule: DownloadRule, request: Request, tab: Tab? = nil, forDownload: Bool = false) async -> HandoffGate {
        // A private window runs no rule that hasn't been let in, even if a caller hands one over directly.
        guard !request.isPrivate || rule.runsInPrivateWindows else { return .browser }
        guard isHandoffable(request.url) else { return .browser }
        // The page's own site keys its answer: a page with no site (a file, a data URL) is asked every time, so the
        // target's site is not used in its place. The target is still what a prompt names when there is no page.
        let pageOrigin = request.pageOrigin ?? SiteOrigin.of(request.referrer)
        let origin = pageOrigin ?? SiteOrigin.of(request.url)
        let kind = handoffKind(rule)
        let subject = PermissionSubject.handoff(rule.id)
        // What this page already answered holds wherever the page is: it was given for this question, and asking again
        // from a background tab would only lose the answer.
        if let pageOrigin, let tab, let kept = tab.permissionAnswers.action(key: pageOrigin, kind: kind),
           let answered = keptGate(kept) {
            return answered
        }
        // Then the site's standing answer. A private window is not the site the answer was given to, so the answer
        // kept for it doesn't reach into one.
        if !request.isPrivate, let pageOrigin, let kept = SitePermissions.action(subject, origin: pageOrigin),
           let answered = keptGate(kept) {
            return answered
        }
        // The rule's own answer belongs to the rule, as its configured fields do, so a private window still reads it.
        if let kept = rule.handoffAnswer, let answered = keptGate(kept) { return answered }
        // Nothing new is asked for a pop-up: its links and downloads stay in Zigzag.
        guard request.mayAsk else { return .browser }
        guard let controller = tab.flatMap({ WindowManager.shared.promptHost(holding: $0) })
                ?? (request.window?.windowController as? PromptHost)
                ?? WindowManager.shared.promptHost(for: request.window)
                ?? WindowManager.shared.promptHost(for: NSApp?.keyWindow) else { return .browser }
        // A new question has to be able to show: a background tab, a window behind another, a pop-up's own window (not
        // a prompt host yet) or Zigzag in the background would hold it with nothing to see. The download or link
        // carries on as if no rule had matched.
        let inFront = tab.map { controller.promptShows($0) }
        guard questionCanShow(tabIsInFront: inFront, windowIsVisible: controller.window?.isVisible == true,
                              windowIsKey: controller.window?.isKeyWindow == true) else { return .browser }
        // This time, then the site where there is one, then the rule's own answer for every site. A private window
        // keeps nothing for the site, so that choice is not offered there; the rule's own is.
        let siteMayKeep = !request.isPrivate && !controller.promptIsPrivate && pageOrigin != nil
        var durations = [String(localized: "This time", comment: "Duration choice on a site's permission question: the answer holds for this page only.")]
        if siteMayKeep {
            durations.append(String(localized: "Always on this site", comment: "Duration choice on a site's permission question: the answer is remembered for this site."))
        }
        durations.append(alwaysFor(rule))
        let ruleScope = durations.count - 1
        let answer = await PermissionPrompt.ask(
            host: SitePermissions.askerName(origin), origin: origin, what: rule.name, symbol: "arrow.up.forward.app",
            in: controller, tab: tab,
            title: String(localized: "Hand Off \(rule.name)", comment: "A page's question before a download rule handles a link or download. The placeholder is the rule's name."),
            actions: [
                .deny,
                .alternate("browser", forDownload
                    ? String(localized: "Save in Zigzag", comment: "Button that saves a download in Zigzag instead of running a download rule.")
                    : String(localized: "Open in Browser", comment: "Button that lets a link stay in the browser instead of running a download rule.")),
                PermissionAction(id: "handOff", title: String(localized: "Hand Off", comment: "Button that runs the named download rule for a link or download."), isDeny: false, isProminent: true)
            ],
            durations: durations,
            canRemember: false,
            answered: {
                // Asked while another question was up: the page, the site or the rule may have answered this one in the
                // meantime.
                if let pageOrigin, let tab, let kept = tab.permissionAnswers.action(key: pageOrigin, kind: kind),
                   keptGate(kept) != nil {
                    return PermissionAnswer(action: kept, remember: false)
                }
                if !request.isPrivate, let pageOrigin, let kept = SitePermissions.action(subject, origin: pageOrigin),
                   keptGate(kept) != nil {
                    return PermissionAnswer(action: kept, remember: true, scopeIndex: 1)
                }
                if let kept = rule.handoffAnswer, keptGate(kept) != nil {
                    return PermissionAnswer(action: kept, remember: true, scopeIndex: ruleScope)
                }
                return nil
            })
        guard let answer else { return .browser }
        let action: String
        switch answer.action {
        case "handOff": action = "handOff"
        case "browser": action = "browser"
        default: action = "deny"
        }
        if answer.scopeIndex == ruleScope {
            var remembered = rule
            remembered.handoffAnswer = action
            DownloadRulesStore.shared.update(remembered)
        } else if answer.scopeIndex == 1, let pageOrigin, !request.isPrivate {
            SitePermissions.remember(action, subject: subject, origin: pageOrigin)
        } else if let pageOrigin, let tab {
            tab.permissionAnswers.note(action, key: pageOrigin, kind: kind)
        }
        return gate(stored: action)
    }

    /// Whether a rule may read this page's cookies for its target: only when the target is the page's own site, or
    /// when you clicked the link that led to it. A page that names another site on its own gets none of its cookies.
    static func maySendCookies(_ request: Request) -> Bool {
        request.wasClicked || (request.pageOrigin != nil && SiteOrigin.of(request.url) == request.pageOrigin)
    }

    /// Whether a service's endpoint is on this Mac. The cookies a site signs in with are not sent to a host off it,
    /// however the rule was written: a remote seedbox can be reached without handing it the site's sign-in.
    static func serviceIsOnThisMac(_ endpoint: String) -> Bool {
        guard let host = URL(string: endpoint)?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Whether a rule's target may carry the site's cookies. A script or an app runs here; an RPC service may be on
    /// another machine, since a NAS or a build box is a thing you may mean and the editor warns first. An Open URL
    /// may carry them only to a custom scheme (which this Mac's own handler takes) or an http(s) address on this Mac:
    /// a page that talks a rule into firing can't also choose somewhere off the Mac for the cookies to go.
    static func targetMayCarryCookies(_ action: DownloadRuleAction, values: HandoffValues) -> Bool {
        switch action.kind {
        case .openApp, .runScript, .jsonRPC:
            return true
        case .openURL:
            let text = DownloadTokens.expand(action.urlTemplate, with: values, query: true)
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
            return (scheme != "http" && scheme != "https") || serviceIsOnThisMac(text)
        case .saveToFolder, .openFile:
            // A destination is not a handoff: it is where the file lands, and it never carries cookies anywhere.
            return false
        }
    }

    /// Runs one rule. Cookies are read only when its action names one, and the files it makes are gone by the end.
    @discardableResult
    static func perform(_ rule: DownloadRule, request: Request) async -> Outcome {
        var values = HandoffValues(link: request.url, referrer: request.referrer, filename: request.filename,
                                   mime: request.mime, space: request.space)
        let secret = rule.action.kind == .jsonRPC ? (HandoffSecrets.secret(for: rule.id) ?? "") : ""
        var cookieFile: URL?
        // The site's sign-in may go to a target of its own, or to one you clicked through to. A service on another
        // machine is a thing you may mean — a NAS, a build box — so a JSON-RPC rule's remote endpoint is not refused
        // here; the editor warns before a rule starts sending cookies off this Mac. What doesn't move is the page: a
        // page that names another site on its own still gets none of its cookies, and an Open URL to a remote address
        // is still not given them.
        let cookiesMayLeave = maySendCookies(request) && targetMayCarryCookies(rule.action, values: values)
        if rule.needsCookies {
            // A rule that names the cookie file always gets one, empty where the cookies may not leave: a service or
            // a script that insists on a jar still runs, and no site's sign-in goes where it shouldn't.
            let cookies = cookiesMayLeave ? await cookies(from: request.dataStore, for: request.url) : []
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
            outcome = await openURL(rule.action, values: values, secret: secret, request: request, rule: rule)
            if let cookieFile { removeWhenTheOtherAppHasRead(cookieFile) }
        case .jsonRPC:
            outcome = await callService(rule.action, values: values, secret: secret)
            if let cookieFile { HandoffCookies.removeFile(cookieFile) }
        case .saveToFolder, .openFile:
            // A destination, not a handoff: where the file lands is decided when the download is made, and the
            // download is never cancelled for it — so there is nothing to do here but let it be saved.
            outcome = .noMatch
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
        Toast.show(String(localized: "Couldn’t hand off: \(reason)", comment: "Toast when a download rule's action fails for a link or a download. The placeholder is the reason, a few words."),
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

    /// An Open URL action. A web address is Zigzag's own: it opens where the rule says, and a rule that hasn't been
    /// told yet asks once — here, over the page — and keeps the answer on itself, since an automation that asked every
    /// time wouldn't be one. Any other address (mpv://, a magnet, a mail link) belongs to the app that handles it and
    /// is handed on exactly as it always was.
    private static func openURL(_ action: DownloadRuleAction, values: HandoffValues, secret: String,
                                request: Request, rule: DownloadRule) async -> Outcome {
        let text = DownloadTokens.expand(action.urlTemplate, with: values, secret: secret, query: true)
        guard let url = URL(string: text), url.scheme != nil else {
            return .failed(String(localized: "The URL isn’t valid.", comment: "Why a download rule failed: the URL it was told to open can't be made."))
        }
        guard OpenInZigzag.handles(url) else { return openWithTheSystem(url) }
        var place = action.openIn
        if place == nil { place = await askWhereToOpen(rule: rule, request: request) }
        // Put off, or nowhere to ask and nowhere to show it: the link or the file is left as if no rule had it.
        guard let place, let host = WindowManager.shared.promptHost(for: request.window) else { return .noMatch }
        OpenInZigzag.open(url, at: place, from: request.tab, in: host)
        return .handedOff
    }

    /// An address Zigzag doesn't own, handed to whatever on this Mac does.
    private static func openWithTheSystem(_ url: URL) -> Outcome {
        NSWorkspace.shared.open(url) ? .handedOff
            : .failed(String(localized: "No app opens that URL.", comment: "Why a download rule failed: nothing on this Mac handles the URL's scheme."))
    }

    /// Asks, once, where this rule's web addresses should open, and writes the answer down on the rule. The dropdown
    /// picks one of the places; the two buttons say whether it lasts — Once, or Always, which keeps it on the rule.
    private static func askWhereToOpen(rule: DownloadRule, request: Request) async -> OpenInZigzag.Place? {
        guard let host = WindowManager.shared.promptHost(for: request.window) else { return nil }
        // The site it's for, not the rule's name: the card names a site the way every other question does, and the
        // question goes when that site is left behind (never because the *rule's* name isn't the page's host).
        let origin = SiteOrigin.of(request.referrer) ?? SiteOrigin.of(request.url)
        let answer = await PermissionPrompt.ask(
            host: SitePermissions.askerName(origin), origin: origin,
            what: "", // `title` words the question; `what` is only ever its fallback's wording.
            symbol: "macwindow.badge.plus", in: host, tab: request.tab,
            title: String(localized: "Where should this open", comment: "A download rule's question the first time an Open URL rule fires on a web address: which of Zigzag's own places to open it in. The card adds the question mark."),
            actions: [.alternate("once", String(localized: "Once", comment: "Button on a download rule's question: open it where the dropdown says this one time, and ask again next time.")),
                      .alternate("always", String(localized: "Always", comment: "Button on a download rule's question: open it where the dropdown says, and keep that on the rule, which never asks again."))],
            chooser: OpenInZigzag.Place.allCases.map { .alternate($0.rawValue, $0.title) },
            canRemember: false)
        guard let answer, let place = OpenInZigzag.Place(rawValue: answer.choice ?? "") else { return nil }
        // "Once" opens it where it was asked for and asks again next time; "Always" writes it on the rule.
        if answer.action != "once" {
            var remembered = rule
            remembered.action.openIn = place
            DownloadRulesStore.shared.update(remembered)
        }
        return place
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
            // JSONSerialization hands back true and false as NSNumbers too: a boolean is a <boolean>, never <int>1.
            if let number = parameter as? NSNumber {
                value = CFGetTypeID(number) == CFBooleanGetTypeID()
                    ? "<boolean>\(number.boolValue ? 1 : 0)</boolean>"
                    : "<int>\(number.intValue)</int>"
            } else { value = "<string>\(escape(String(describing: parameter)))</string>" }
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
