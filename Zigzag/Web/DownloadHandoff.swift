import AppKit
import Foundation
import WebKit

/// Runs the first matching rule: opens an app or URL, runs a script, or calls a JSON-RPC or XML-RPC service. Cookies
/// come from the tab's own store, so sign-ins carry over. Never builds a shell line, so `&`, `;` or `$()` in a URL
/// stays one argument.
@MainActor
enum DownloadHandoff {
    struct Request {
        var url: URL
        var referrer: URL?
        /// The asking page's site: keys the handoff question, and the only site whose cookies may go to its own
        /// target.
        var pageOrigin: String?
        var filename = ""
        var mime = ""
        var space = ""
        var dataStore: WKWebsiteDataStore?
        var isPrivate = false
        var window: NSWindow?
        /// The asking tab: keeps the page answer, and is "This Tab" for an Open URL rule opening in Zigzag.
        var tab: Tab?
        /// Place picked in the handoff card, for this handoff only. Only the separate question's Always saves one on
        /// the rule.
        var place: OpenInZigzag.Choice?
        /// A click may send this page's cookies to the target; a page-started download or navigation may not.
        var wasClicked = false
        /// False for pop-ups: no page store of their own and their window can sit behind the browser's, so they never
        /// ask. A kept page answer is still read.
        var mayAsk = true
    }

    enum Outcome: Equatable {
        /// The navigation, and any download WebKit made for it, is cancelled.
        case handedOff
        /// No rule matched, or an Open URL question was put off: carry on as normal.
        case noMatch
        /// Refused at the question: cancel without running the rule, and don't save the download.
        case cancelled
        case failed(String)
    }

    /// Whether this handoff waits for Zigzag to save the file first. Never for a link, which has no file.
    static func defersToSavedFile(_ rule: DownloadRule, forDownload: Bool) -> Bool {
        forDownload && rule.handoffType == .file
    }

    /// The matching rule, if any. `appliesToLinks` is true for links, false for downloads.
    static func firstMatch(_ url: URL, appliesToLinks: Bool, filename: String = "", isPrivate: Bool = false, in profile: Profile?) -> DownloadRule? {
        guard isHandoffable(url) else { return nil }
        return DownloadRulesStore.shared.firstHandoffMatch(url: url, filename: filename, appliesToLinks: appliesToLinks,
                                                           isPrivate: isPrivate, in: profile)
    }

    /// Zigzag's own pages and the certificate warning's proceed link are never handed off; a catch-all rule could
    /// otherwise turn "Visit this site anyway" into an app launch.
    static func isHandoffable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == HistoryPage.scheme || scheme == CertificateExceptions.scheme || scheme == "zigzag-webapp" { return false }
        if ["about", "data", "blob", "javascript", "file"].contains(scheme) { return false }
        if scheme.hasSuffix("-extension") { return false }
        return true
    }

    /// Whether a new question would be seen: tab in front (or none named), window visible and key. Not needed for a
    /// kept page answer.
    static func questionCanShow(tabIsInFront: Bool?, windowIsVisible: Bool, windowIsKey: Bool) -> Bool {
        (tabIsInFront ?? true) && windowIsVisible && windowIsKey
    }

    enum HandoffGate: Equatable { case handOff, browser, cancel }

    /// The answer, plus the place picked in the card (when offered). The place applies to this handoff only and is
    /// never saved on the rule.
    struct Decision {
        let gate: HandoffGate
        var place: OpenInZigzag.Choice? = nil
        /// Put off rather than answered: carries on, but the same download isn't offered to the rule again.
        var declined = false
    }

    /// Unknown or nil reads as the browser.
    static func gate(stored: String?) -> HandoffGate {
        switch stored {
        case "handOff": .handOff
        case "browser": .browser
        case "deny": .cancel
        default: .browser
        }
    }

    /// Like `gate`, but nil when there's no valid answer yet, meaning ask.
    private static func keptGate(_ stored: String?) -> HandoffGate? {
        switch stored {
        case "handOff": .handOff
        case "browser": .browser
        case "deny": .cancel
        default: nil
        }
    }

    /// Per rule, so two rules on one page keep their own answers.
    static func handoffKind(_ rule: DownloadRule) -> String { "handoff:\(rule.id.uuidString)" }

    /// This Tab first, since Hand Off uses the first entry without the dropdown being touched. The rule's own
    /// question and sheet use `Choice.destinations`' order, browser first.
    static let cardPlaces: [OpenInZigzag.Choice] = [.thisTab] + OpenInZigzag.Choice.destinations.filter { $0 != .thisTab }

    /// The source site, preferring the page or referrer over the destination.
    static func questionOrigin(for request: Request) -> String? {
        request.pageOrigin ?? SiteOrigin.of(request.referrer) ?? SiteOrigin.of(request.url)
    }

    /// The third duration: the rule by name, or "this rule". Saved on the rule, so it's exported and removed with it.
    static func alwaysFor(_ rule: DownloadRule) -> String {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? String(localized: "Always for this rule", comment: "Duration choice on a question a download rule asks: the answer is kept on the rule, for every site. The rule has no name.")
            : String(localized: "Always for “\(name)”", comment: "Duration choice on a question a download rule asks: the answer is kept on the rule, for every site. The placeholder is the rule's name.")
    }

    /// Asks where a handoff goes unless the page, site or rule already answered. Asked in the page's window; with no
    /// window, nothing is handed off. A link that starts a download asks once.
    static func decide(_ rule: DownloadRule, request: Request, tab: Tab? = nil, forDownload: Bool = false) async -> Decision {
        // Guards callers that pass a rule directly.
        guard !request.isPrivate || rule.runsInPrivateWindows else { return Decision(gate: .browser) }
        guard isHandoffable(request.url) else { return Decision(gate: .browser) }
        // Keyed by the page's site. A page with no site (file, data URL) asks every time rather than falling back to
        // the target's site; the target is only used to name the prompt.
        let pageOrigin = request.pageOrigin ?? SiteOrigin.of(request.referrer)
        let origin = pageOrigin ?? SiteOrigin.of(request.url)
        let kind = handoffKind(rule)
        let subject = PermissionSubject.handoff(rule.id)
        // The page's answer holds even in a background tab.
        if let pageOrigin, let tab, let kept = tab.permissionAnswers.action(key: pageOrigin, kind: kind),
           let answered = keptGate(kept) {
            return Decision(gate: answered)
        }
        // The site's kept answer doesn't apply in a private window.
        if !request.isPrivate, let pageOrigin, let kept = SitePermissions.action(subject, origin: pageOrigin),
           let answered = keptGate(kept) {
            return Decision(gate: answered)
        }
        // The rule's own answer applies in private windows that allow the rule.
        if let kept = rule.handoffAnswer, let answered = keptGate(kept) { return Decision(gate: answered) }
        // Pop-ups never ask; their links and downloads stay in Zigzag.
        guard request.mayAsk else { return Decision(gate: .browser) }
        guard let controller = tab.flatMap({ WindowManager.shared.promptHost(holding: $0) })
                ?? (request.window?.windowController as? PromptHost)
                ?? WindowManager.shared.promptHost(for: request.window)
                ?? WindowManager.shared.promptHost(for: NSApp?.keyWindow) else { return Decision(gate: .browser) }
        // Only ask where it can be seen: not a background tab, a covered window, a pop-up's window (not a prompt host
        // yet) or Zigzag in the background. Otherwise carry on as if no rule matched.
        let inFront = tab.map { controller.promptShows($0) }
        guard questionCanShow(tabIsInFront: inFront, windowIsVisible: controller.window?.isVisible == true,
                              windowIsKey: controller.window?.isKeyWindow == true) else { return Decision(gate: .browser) }
        // An Open URL rule with no place yet asks for it in the same card, not a second one.
        let asksPlace = asksWhereToOpen(rule, request: request)
        // This time, the site (when there is one), then the rule. A private window can't keep a site answer, so only
        // the rule's is offered there.
        let siteMayKeep = !request.isPrivate && !controller.promptIsPrivate && pageOrigin != nil
        var durations = [String(localized: "This time", comment: "Duration choice on a site's permission question: the answer holds for this page only.")]
        if siteMayKeep {
            durations.append(String(localized: "Always on this site", comment: "Duration choice on a site's permission question: the answer is remembered for this site."))
        }
        durations.append(alwaysFor(rule))
        let ruleScope = durations.count - 1
        let answer = await PermissionPrompt.ask(
            host: SitePermissions.askerName(origin), origin: origin, answerKey: pageOrigin, what: rule.name, symbol: "arrow.up.forward.app",
            in: controller, tab: tab,
            title: String(localized: "Hand Off \(rule.name)", comment: "A page's question before a download rule handles a link or download. The placeholder is the rule's name."),
            actions: [
                .deny,
                .alternate("browser", forDownload
                    ? String(localized: "Save in Zigzag", comment: "Button that saves a download in Zigzag instead of running a download rule.")
                    : String(localized: "Open in Browser", comment: "Button that lets a link stay in the browser instead of running a download rule.")),
                PermissionAction(id: "handOff", title: String(localized: "Hand Off", comment: "Button that runs the named download rule for a link or download."), isDeny: false, isProminent: true)
            ],
            chooser: asksPlace ? cardPlaces.map { .alternate($0.rawValue, $0.title) } : [],
            durations: durations,
            canRemember: false,
            answered: {
                // May have been answered while another question was up.
                if let pageOrigin, let tab, let kept = tab.permissionAnswers.action(key: pageOrigin, kind: kind),
                   keptGate(kept) != nil {
                    return PermissionAnswer(action: kept, remember: false)
                }
                if siteMayKeep, let pageOrigin, let kept = SitePermissions.action(subject, origin: pageOrigin),
                   keptGate(kept) != nil {
                    return PermissionAnswer(action: kept, remember: true, scopeIndex: 1)
                }
                if let kept = rule.handoffAnswer, keptGate(kept) != nil {
                    return PermissionAnswer(action: kept, remember: true, scopeIndex: ruleScope)
                }
                return nil
            })
        guard let answer else { return Decision(gate: .browser, declined: true) }
        let action: String
        switch answer.action {
        case "handOff": action = "handOff"
        case "browser": action = "browser"
        default: action = "deny"
        }
        if answer.scopeIndex == ruleScope {
            var remembered = DownloadRulesStore.shared.rules.first { $0.id == rule.id } ?? rule
            remembered.handoffAnswer = action
            DownloadRulesStore.shared.update(remembered)
        } else if answer.scopeIndex == 1, siteMayKeep, let pageOrigin, !request.isPrivate {
            SitePermissions.remember(action, subject: subject, origin: pageOrigin)
        } else if let pageOrigin, let tab {
            tab.permissionAnswers.note(action, key: pageOrigin, kind: kind)
        }
        let place = action == "handOff" && asksPlace ? answer.choice.flatMap(OpenInZigzag.Choice.init(rawValue:)) : nil
        return Decision(gate: gate(stored: action), place: place)
    }

    /// Only for an Open URL rule with no place and a web target; other schemes (mpv://, magnet) go to their app.
    private static func asksWhereToOpen(_ rule: DownloadRule, request: Request) -> Bool {
        guard rule.action.kind == .openURL, rule.action.openIn == .ask else { return false }
        let values = HandoffValues(link: request.url, referrer: request.referrer, filename: request.filename,
                                   mime: request.mime, space: request.space)
        let text = DownloadTokens.expand(rule.action.urlTemplate, with: values, secret: "", query: true)
        guard let url = URL(string: text) else { return false }
        return OpenInZigzag.handles(url)
    }

    /// Cookies may go only to the page's own site or to a link you clicked.
    static func maySendCookies(_ request: Request) -> Bool {
        request.wasClicked || (request.pageOrigin != nil && SiteOrigin.of(request.url) == request.pageOrigin)
    }

    /// Whether an endpoint is local. Cookies never go to a remote host, so a remote seedbox gets no site sign-in.
    static func serviceIsOnThisMac(_ endpoint: String) -> Bool {
        guard let host = URL(string: endpoint)?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Scripts and apps run locally; RPC services must be local; Open URL may carry cookies only to a custom scheme
    /// or a local http(s) address. A page that triggers a rule can't send cookies off the Mac.
    static func targetIsOnThisMac(_ action: DownloadRuleAction, values: HandoffValues) -> Bool {
        switch action.kind {
        case .openApp, .runScript:
            return true
        case .jsonRPC:
            return serviceIsOnThisMac(action.rpcEndpoint)
        case .openURL:
            let text = DownloadTokens.expand(action.urlTemplate, with: values, query: true)
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
            return (scheme != "http" && scheme != "https") || serviceIsOnThisMac(text)
        case .saveToFolder, .openFile:
            // Destinations never carry cookies.
            return false
        }
    }

    /// Cookies are read only when the action uses them; temporary files are removed afterwards. `file` is the saved
    /// download for a File handoff, nil for a link or a URL handoff.
    @discardableResult
    static func perform(_ rule: DownloadRule, request: Request, file: URL? = nil) async -> Outcome {
        var values = HandoffValues(link: request.url, file: file, referrer: request.referrer, filename: request.filename,
                                   mime: request.mime, space: request.space)
        // The file's real name may have gained a number to avoid another download.
        if let file { values.filename = file.lastPathComponent }
        let secret = rule.action.kind == .jsonRPC ? (HandoffSecrets.secret(for: rule.id) ?? "") : ""
        var cookieFile: URL?
        let cookiesMayLeave = maySendCookies(request) && targetIsOnThisMac(rule.action, values: values)
        if rule.needsCookies {
            // A rule using the cookie file always gets one, empty when cookies can't be sent, so it still runs.
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
            // A running script keeps the file until it exits.
            if outcome != .handedOff, let cookieFile { HandoffCookies.removeFile(cookieFile) }
        case .openApp:
            outcome = await openApp(rule.action, values: values, secret: secret)
            if let cookieFile { removeWhenTheOtherAppHasRead(cookieFile) }
        case .openURL:
            outcome = await openURL(rule.action, values: values, secret: secret, request: request, rule: rule)
            if let cookieFile { removeWhenTheOtherAppHasRead(cookieFile) }
        case .jsonRPC:
            outcome = await callService(rule.action, values: values, secret: secret, ruleID: rule.id)
            if let cookieFile { HandoffCookies.removeFile(cookieFile) }
        case .saveToFolder, .openFile:
            // Destinations are applied when the download is made and never cancel it.
            outcome = .noMatch
        }
        // Failures show their own message.
        if outcome == .handedOff { announce(rule, request: request, values: values, secret: secret) }
        return outcome
    }

    /// Announces in the window holding the tab, so a background tab's rule says so there. Only for handoffs that
    /// leave Zigzag, once per session (see `HandoffNotice.takeLine`).
    private static func announce(_ rule: DownloadRule, request: Request, values: HandoffValues, secret: String) {
        let choice = opening(rule, at: request.place)
        guard let host = handoffHost(for: request),
              let line = HandoffNotice.takeLine(for: rule, elsewhere: elsewhere(of: rule.action, at: choice, values: values, secret: secret),
                                                file: values.file != nil)
        else { return }
        host.promptToast(line, symbol: rule.action.kind.symbol, duration: 4)
    }

    /// A rule failed: shown over the page and logged without the link, cookies or secret.
    static func report(_ outcome: Outcome, rule: DownloadRule?, request: Request) {
        report(outcome, rule: rule, url: request.url, isPrivate: request.isPrivate, window: request.window)
    }

    /// For a failure that arrives after the tab moved on (a script exiting non-zero).
    static func report(_ outcome: Outcome, rule: DownloadRule?, url: URL, isPrivate: Bool, window: NSWindow? = nil) {
        guard case .failed(let reason) = outcome else { return }
        Diagnostics.note("Handoff failed", site: url.host(), "\(rule?.name ?? "Rule"): \(reason)", isPrivate: isPrivate)
        guard let controller = WindowManager.shared.controller(for: window) ?? WindowManager.shared.keyController else { return }
        Toast.show(String(localized: "Couldn’t hand off: \(reason)", comment: "Toast when a download rule's action fails for a link or a download. The placeholder is the reason, a few words."),
                   symbol: "exclamationmark.triangle", duration: 4, in: controller)
    }

    /// Where a handoff went when Zigzag shows nothing for it: an app or a service. Nil for tabs, Mini, script cards
    /// and downloads.
    private static func elsewhere(of action: DownloadRuleAction, at choice: OpenInZigzag.Choice,
                                  values: HandoffValues, secret: String) -> HandoffNotice.Elsewhere? {
        switch action.kind {
        case .openApp:
            return .app(action.summary)
        case .jsonRPC:
            return .service(action.summary)
        case .openURL:
            // Non-web addresses open in their app; web addresses are announced only when sent to another browser.
            guard let url = URL(string: DownloadTokens.expand(action.urlTemplate, with: values, secret: secret, query: true)),
                  let scheme = url.scheme else { return nil }
            if !OpenInZigzag.handles(url) { return .app(ExternalLinks.appName(forScheme: scheme)) }
            // If Zigzag is the default browser, the link opens in a tab here.
            guard choice == .defaultBrowser, !DefaultBrowser.isDefault else { return nil }
            return .app(ExternalLinks.appName(forScheme: "https"))
        case .runScript, .saveToFolder, .openFile:
            return nil
        }
    }

    /// An app given a `{cookies}` path may read it after open returns, so the owner-only temp file stays a few
    /// minutes.
    private static func removeWhenTheOtherAppHasRead(_ file: URL) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(300))
            HandoffCookies.removeFile(file)
        }
    }

    // MARK: Cookies

    /// From the tab's own store, never another profile's.
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

    /// An app gets the saved file for a File handoff, and the address otherwise.
    static func appTarget(_ values: HandoffValues) -> URL { values.file ?? values.link }

    private static func openApp(_ action: DownloadRuleAction, values: HandoffValues, secret: String) async -> Outcome {
        // Literal: a link can fill an argument but never pick the program.
        let path = (action.appPath as NSString).expandingTildeInPath
        let app = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.path) else {
            return .failed(String(localized: "The app is no longer there.", comment: "Why a download rule failed: the app it was told to open is gone."))
        }
        let configuration = NSWorkspace.OpenConfiguration()
        let error: Error? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([appTarget(values)], withApplicationAt: app, configuration: configuration) { _, error in
                continuation.resume(returning: error)
            }
        }
        if let error { return .failed(error.localizedDescription) }
        return .handedOff
    }

    /// Web addresses open where the rule says; a rule with no place asks in the card, or in the separate question
    /// when there was no card. Only the separate question's Always saves a place. Other schemes (mpv://, magnet,
    /// mailto) go to their handler.
    private static func openURL(_ action: DownloadRuleAction, values: HandoffValues, secret: String,
                                request: Request, rule: DownloadRule) async -> Outcome {
        let text = DownloadTokens.expand(action.urlTemplate, with: values, secret: secret, query: true)
        guard let url = URL(string: text), url.scheme != nil else {
            return .failed(String(localized: "The URL isn’t valid.", comment: "Why a download rule failed: the URL it was told to open can't be made."))
        }
        guard OpenInZigzag.handles(url) else { return openWithTheSystem(url) }
        // The card's place is never saved, so the rule asks again next time.
        var choice = opening(rule, at: request.place)
        if choice == .ask { choice = await askWhereToOpen(rule: rule, request: request) ?? .ask }
        switch choice {
        case .defaultBrowser:
            return openWithTheSystem(url)
        case .thisTab, .newTab, .mini:
            // Put off or nowhere to show: carry on as if no rule matched.
            guard let place = choice.place, let host = WindowManager.shared.promptHost(for: request.window) else { return .noMatch }
            OpenInZigzag.open(url, at: place, from: request.tab, in: host)
            return .handedOff
        case .ask:
            return .noMatch
        }
    }

    /// The card's place for this time, else the rule's. Never saved from the card; the rule's place comes from its
    /// sheet or the separate question's Always.
    static func opening(_ rule: DownloadRule, at cardPlace: OpenInZigzag.Choice?) -> OpenInZigzag.Choice {
        cardPlace ?? rule.action.openIn
    }

    /// Always saves the picked place; Once leaves the rule asking. Nil means save nothing.
    static func ruleToKeep(_ rule: DownloadRule, choice: OpenInZigzag.Choice, always: Bool) -> DownloadRule? {
        guard always else { return nil }
        var kept = rule
        kept.action.openIn = choice
        return kept
    }

    /// Hands a non-Zigzag address to its system handler.
    private static func openWithTheSystem(_ url: URL) -> Outcome {
        NSWorkspace.shared.open(url) ? .handedOff
            : .failed(String(localized: "No app opens that URL.", comment: "Why a download rule failed: nothing on this Mac handles the URL's scheme."))
    }

    /// Asks where this rule's web addresses open. The dropdown picks a place; Once or Always says whether it's saved
    /// on the rule.
    private static func askWhereToOpen(rule: DownloadRule, request: Request) async -> OpenInZigzag.Choice? {
        guard let host = WindowManager.shared.promptHost(for: request.window) else { return nil }
        // Named by site, like other questions, and dismissed when you leave that site.
        let origin = SiteOrigin.of(request.referrer) ?? SiteOrigin.of(request.url)
        let answer = await PermissionPrompt.ask(
            host: SitePermissions.askerName(origin), origin: origin,
            what: "", // `title` words the question; `what` is only ever its fallback's wording.
            symbol: "macwindow.badge.plus", in: host, tab: request.tab,
            title: String(localized: "Where should this open", comment: "A download rule's question the first time an Open URL rule fires on a web address: which place to open it in. The card adds the question mark."),
            actions: [.alternate("once", String(localized: "Once", comment: "Button on a download rule's question: open it where the dropdown says this one time, and ask again next time.")),
                      .alternate("always", String(localized: "Always", comment: "Button on a download rule's question: open it where the dropdown says, and keep that on the rule, which never asks again."))],
            chooser: OpenInZigzag.Choice.destinations.map { .alternate($0.rawValue, $0.title) },
            canRemember: false)
        guard let answer, let choice = OpenInZigzag.Choice(rawValue: answer.choice ?? "") else { return nil }
        // Re-read the rule: its question may have just saved an answer.
        let current = DownloadRulesStore.shared.rules.first { $0.id == rule.id } ?? rule
        if let kept = ruleToKeep(current, choice: choice, always: answer.action != "once") {
            DownloadRulesStore.shared.update(kept)
        }
        return choice
    }

    /// Every token is its own argument or environment value. `.sh` files run via `/bin/sh`, anything else must be
    /// executable. Never `/bin/sh -c` or a joined command line.
    private static func runScript(_ action: DownloadRuleAction, values: HandoffValues, secret: String,
                                  request: Request, rule: DownloadRule?) -> Outcome {
        // A bare name is in the scripts folder; a path is used as is. Literal, so a link can't pick the script.
        let path = Paths.script(named: action.scriptPath).path
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
        // Apps launched from Finder get a bare `PATH`, so prepend Homebrew and /usr/local/bin for tools like
        // `yt-dlp`.
        let inherited = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + inherited
        environment["ZIGZAG_LINK"] = values.link.absoluteString
        if let file = values.file {
            environment["ZIGZAG_FILE"] = file.path
            environment["ZIGZAG_FILE_URL"] = file.absoluteString
        }
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
        // Card over the page in the tab's window. Quick runs skip "running" and show only the result.
        let script = ScriptNotice(script: (path as NSString).lastPathComponent, state: .running)
        let card = handoffHost(for: request).map { NoticeCard.show(script, tab: request.tab, in: $0) }
        process.terminationHandler = { finished in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            errors.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            if !cookieFile.isEmpty { HandoffCookies.removeFile(URL(fileURLWithPath: cookieFile)) }
            let said = errors.text
            let status = finished.terminationStatus
            Task { @MainActor in
                // Falls back to the notice below if the card is gone, so failures are never silent.
                let ended: ScriptNotice.State = status == 0 ? .ran : .failed(said)
                let onCard = card?.say(ScriptNotice(script: script.script, state: ended)) == true
                guard status != 0 else { return }
                let reason = said.isEmpty
                    ? String(localized: "The script exited with status \(status).", comment: "Why a download rule failed: the script finished with an error code. The placeholder is a number, like 1.")
                    : String(localized: "The script failed: \(said)", comment: "Why a download rule failed: the script exited with an error code and printed this. The placeholder is the script's own last line of error text.")
                // Still logged, as every failed handoff is.
                if onCard {
                    Diagnostics.note("Handoff failed", site: link.host(), "\(rule?.name ?? "Rule"): \(reason)", isPrivate: isPrivate)
                } else {
                    report(.failed(reason), rule: rule, url: link, isPrivate: isPrivate)
                }
            }
        }
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        return .handedOff
    }

    /// The window holding the handed tab, else the request's window.
    private static func handoffHost(for request: Request) -> PromptHost? {
        if let tab = request.tab, let host = WindowManager.shared.promptHost(holding: tab) { return host }
        return WindowManager.shared.promptHost(for: request.window)
    }

    // MARK: JSON-RPC and XML-RPC

    private static func callService(_ action: DownloadRuleAction, values: HandoffValues, secret: String,
                                    ruleID: UUID) async -> Outcome {
        // Endpoint and method are literal; a page fills parameters only.
        guard let endpoint = URL(string: action.rpcEndpoint) else {
            return .failed(String(localized: "The service’s address isn’t valid.", comment: "Why a download rule failed: the JSON-RPC endpoint can't be made into a URL."))
        }
        let method = action.rpcMethod
        guard let parameters = parameters(action.rpcParameters, values: values, secret: secret) else {
            return .failed(String(localized: "The parameters aren’t valid JSON.", comment: "Why a download rule failed: the JSON-RPC parameters don't parse."))
        }
        // A rule that sends the file itself, asked to for a handoff that has no file: say so rather than send nothing,
        // which the service would refuse with something far less clear.
        if let raw = firstFileRaw(in: parameters), let problem = raw.problem {
            return .failed(message(for: problem))
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        // An endpoint that used to carry `user:pass@` sends it as a header now, out of the rules file.
        if let authorization = HandoffSecrets.endpointAuthorization(for: ruleID, endpoint: action.rpcEndpoint) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        if action.rpcStyle == .xmlrpc {
            request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(xmlRPC(method: method, parameters: parameters).utf8)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let ready = jsonReady(parameters) as? [Any] ?? parameters
            var call: [String: Any] = ["jsonrpc": "2.0", "id": "zigzag", "method": method,
                                       "params": jsonParameters(ready, method: method, secret: secret)]
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

    /// The first `{file_raw}` in a rule's parameters, wherever it sits.
    private static func firstFileRaw(in parameters: [Any]) -> FileRaw? {
        for parameter in parameters {
            if let raw = parameter as? FileRaw { return raw }
            if let list = parameter as? [Any], let raw = firstFileRaw(in: list) { return raw }
            if let map = parameter as? [String: Any] {
                for value in map.values {
                    if let raw = firstFileRaw(in: [value]) { return raw }
                }
            }
        }
        return nil
    }

    /// What to tell someone whose rule asked for bytes it doesn't have.
    private static func message(for problem: FileRaw.Problem) -> String {
        switch problem {
        case .noFile:
            String(localized: "This rule sends the file itself, but there was no file to send. Set Hand off to File, and let the download finish first.",
                   comment: "Why a download rule failed: its parameters use {file_raw}, which needs the saved file, but no file was handed off.")
        case .tooLarge(let size):
            String(localized: "This file is too large to send that way (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))).",
                   comment: "Why a download rule failed: the file is bigger than a rule can send as {file_raw}. The placeholder is a size, like 40 MB.")
        case .unreadable:
            String(localized: "The saved file couldn’t be read.", comment: "Why a download rule failed: its {file_raw} couldn't be read from disk.")
        }
    }

    /// Parameters with every `FileRaw` as text, for a body that has no binary type of its own.
    static func jsonReady(_ node: Any) -> Any {
        if let raw = node as? FileRaw { return raw.base64 ?? "" }
        if let list = node as? [Any] { return list.map(jsonReady) }
        if let map = node as? [String: Any] { return map.mapValues(jsonReady) }
        return node
    }

    /// Parsed from the rule's JSON. aria2 and rTorrent want the token first; added only when a secret is kept and the
    /// template hasn't placed it.
    /// A rule's parameters, parsed once and then filled in: the template is JSON, so it is read as JSON first and
    /// each string in it is substituted after. Substituting first and parsing after would mean every token had to be
    /// escaped for the body, and `{file_raw}` could only ever be text.
    static func parameters(_ template: String, values: HandoffValues, secret: String) -> [Any]? {
        let data = Data(template.utf8)
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return filled(parsed, values: values, secret: secret) as? [Any]
    }

    /// The same structure with every token replaced. A string that is exactly a token with a value of its own keeps
    /// that value, so `{file_raw}` reaches the body as the file's bytes rather than as a string.
    private static func filled(_ node: Any, values: HandoffValues, secret: String) -> Any {
        if let text = node as? String {
            return DownloadTokens.substitute(text, with: values, secret: secret)
        }
        if let list = node as? [Any] {
            return list.map { filled($0, values: values, secret: secret) }
        }
        if let map = node as? [String: Any] {
            return map.mapValues { filled($0, values: values, secret: secret) }
        }
        return node
    }

    static func jsonParameters(_ parameters: [Any], method: String, secret: String) -> [Any] {
        guard !secret.isEmpty, method.hasPrefix("aria2.") || method.hasPrefix("system.") || method.hasPrefix("torrent.") else { return parameters }
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
            // JSONSerialization returns booleans as NSNumber too; send them as <boolean>, not <int>1.
            if let raw = parameter as? FileRaw {
                // rTorrent reads these as the XML-RPC binary type; as a string it would be a path it can't open.
                value = "<base64>\(raw.base64 ?? "")</base64>"
            } else if let number = parameter as? NSNumber {
                value = CFGetTypeID(number) == CFBooleanGetTypeID()
                    ? "<boolean>\(number.boolValue ? 1 : 0)</boolean>"
                    : "<int>\(number.intValue)</int>"
            } else { value = "<string>\(escape(String(describing: parameter)))</string>" }
            return "<param><value>\(value)</value></param>"
        }.joined()
        return "<?xml version=\"1.0\"?><methodCall><methodName>\(escape(method))</methodName><params>\(params)</params></methodCall>"
    }

    /// The service's own error message, if any.
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

/// Tail of a script's stderr for its failure message. Locked: written on a background queue, read on main.
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
