import AppKit
import Foundation
import WebKit

enum HandoffGate: Equatable {
    case handOff, browser, cancel, ask
}

/// How an Open URL firing will open: at a place, not at all, or by asking where.
enum OpenInDecision: Equatable {
    case place(OpenInZigzag.Place), refuse, ask
}

/// Runs the first rule that catches a link or a download: opens an app or a URL, runs a script, or calls a JSON-RPC or
/// XML-RPC service. The tab's own store supplies the cookies, so a logged-in download keeps its sign-in; nothing here
/// ever builds a shell line, so a URL with `&`, `;` or `$()` arrives as one argument.
@MainActor
enum DownloadHandoff {
    /// One handoff's occasion: the address, what the page said about it, and where its cookies live.
    struct Request {
        var url: URL
        var referrer: URL?
        var pageOrigin: String?
        var filename = ""
        var mime = ""
        var space = ""
        var dataStore: WKWebsiteDataStore?
        var isPrivate = false
        var window: NSWindow?
        /// The tab that asked, where one did: an Open URL rule opening a web address in Zigzag opens it in relation
        /// to this tab ("This Tab" is this one), and a question about it is asked where this tab's page is.
        var tab: Tab?
    }

    enum Outcome: Equatable {
        /// A rule ran. The navigation is cancelled, and any download WebKit made for it is.
        case handedOff
        /// No rule wanted it, or a download was refused at the handoff question, or an Open URL rule's question was put
        /// off: carry on in the browser, as if the rule had never matched.
        case noMatch
        /// A link was refused at the handoff question: cancel its navigation without running the rule.
        case cancelled
        case failed(String)
    }

    /// The rule that catches `url`, if any, and whether it wants a link (true) or a download (false).
    static func firstMatch(_ url: URL, appliesToLinks: Bool, isPrivate: Bool = false) -> DownloadRule? {
        DownloadRulesStore.shared.firstMatch(url: url, appliesToLinks: appliesToLinks, isPrivate: isPrivate)
    }

    /// A stored answer as a gate. A private window is not the site the answer was given to, so one kept **for the
    /// site** doesn't reach it; one kept **on the rule** belongs to the rule, not the session, and does.
    static func gate(stored: String?, scope: PermissionScope = .site, isPrivate: Bool) -> HandoffGate {
        if isPrivate, scope == .site { return .ask }
        return switch stored {
        case "handOff": .handOff
        case "browser": .browser
        case "deny": .cancel
        default: .ask
        }
    }

    /// The site that produced the handoff, never the destination when a page or referrer can name it instead.
    static func questionOrigin(for request: Request) -> String? {
        request.pageOrigin ?? SiteOrigin.of(request.referrer) ?? SiteOrigin.of(request.url)
    }

    /// Resolves a rule's standing answer, or asks in the page's window. No action or cookie read happens here.
    static func decide(_ rule: DownloadRule, request: Request, tab: Tab? = nil) async -> HandoffGate {
        // A rule kept out of private windows never runs there, whatever a caller hands us: selection already skips it,
        // and this is the last line that keeps the promise.
        guard !request.isPrivate || rule.runsInPrivateWindows else { return .browser }
        let origin = questionOrigin(for: request)
        let subject = PermissionSubject.handoff(rule.id)
        // The more specific answer first: this site's, then the rule's own for every site. A private window neither
        // reads nor keeps the site's — that answer is about the site this session is on — but the rule's own answer
        // travels with the rule, which private browsing doesn't put away, so it stands there as it does anywhere.
        let storedAnswer: () -> PermissionAnswer? = {
            if !request.isPrivate, let origin, let action = SitePermissions.action(subject, origin: origin) {
                return Self.known(action, scope: .site)
            }
            return rule.handoffAnswer.flatMap { Self.known($0, scope: .rule) }
        }
        let kept = storedAnswer()
        let standing = gate(stored: kept?.action, scope: kept?.scope ?? .site, isPrivate: request.isPrivate)
        guard standing == .ask else { return standing }
        // What this page already answered for this rule, "this time": a link and the download it starts are one
        // question, not two. A private window keeps its own answers in its tab like any other.
        let pageKind = handoffKind(rule)
        if let origin, let page = tab?.permissionAnswers.action(key: origin, kind: pageKind) {
            let answered = gate(stored: page, isPrivate: false)
            if answered != .ask { return answered }
        }
        // With no host of its own to ask in — a pop-up a pop-up opened has no window controller that is one — the
        // question goes in the window in front, as opening a stray link does, so it is put rather than the rule
        // quietly not running. That window's edge glows if it cannot show the question there.
        let controller = tab.flatMap { WindowManager.shared.promptHost(holding: $0) }
            ?? (request.window?.windowController as? PromptHost)
            ?? WindowManager.shared.promptHost(for: request.window)
            ?? WindowManager.shared.promptHost(for: NSApplication.shared.keyWindow)
            ?? WindowManager.shared.keyController
        // With no window open at all to ask in, the rule simply does not run: nothing may happen unseen.
        guard let controller else { return .browser }
        let answer = await PermissionPrompt.ask(
            host: SitePermissions.askerName(origin), origin: origin, what: rule.name, symbol: "arrow.up.forward.app",
            in: controller, tab: tab,
            title: String(localized: "Hand Off \(rule.name)", comment: "A page's question before a download rule handles a link or download. The placeholder is the rule's name."),
            actions: [.deny,
                      .alternate("browser", String(localized: "Open in Browser", comment: "Button that lets a link or download stay in the browser instead of running a download rule.")),
                      .alternate("handOff", String(localized: "Hand Off", comment: "Button that runs the named download rule for a link or download."))],
            canRemember: !request.isPrivate,
            ruleScope: Self.alwaysFor(rule),
            answered: storedAnswer
        )
        guard let answer else { return .browser }
        _ = SitePermissions.rememberAnswer(answer, subject: subject, origin: origin, tab: tab, isPrivate: request.isPrivate,
                                           onRule: { action in
            var remembered = rule
            remembered.handoffAnswer = action
            DownloadRulesStore.shared.update(remembered)
        })
        return switch answer.action {
        case "handOff": .handOff
        case "deny": .cancel
        default: .browser
        }
    }

    /// A stored handoff answer, where it is one of the three the gate understands.
    private static func known(_ action: String, scope: PermissionScope) -> PermissionAnswer? {
        switch action {
        case "handOff", "browser", "deny": PermissionAnswer(action: action, scope: scope)
        default: nil
        }
    }

    /// The third duration choice on a question a rule asks: the rule by name, or "this rule" where it has none.
    static func alwaysFor(_ rule: DownloadRule) -> String {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? String(localized: "Always for this rule", comment: "Duration choice on a question a download rule asks: the answer is kept on the rule, for every site. The rule has no name.")
            : String(localized: "Always for “\(name)”", comment: "Duration choice on a question a download rule asks: the answer is kept on the rule, for every site. The placeholder is the rule's name.")
    }

    /// The key a rule's page answer is kept under: per rule, so two rules on one page keep their own answers.
    static func handoffKind(_ rule: DownloadRule) -> String { "handoff:\(rule.id.uuidString)" }

    /// Where an Open URL firing opens, from the most specific answer to the least: this site's about this rule, the
    /// rule's own, what this page answered "this time", and then asking. A private window skips the site's — that
    /// answer is about the site the session is on — and reads the rule's, which belongs to the rule.
    static func openInDecision(_ action: DownloadRuleAction, rule: DownloadRule?, request: Request) -> OpenInDecision {
        let origin = questionOrigin(for: request)
        let kind = rule.map { PermissionSubject.openIn($0.id) } ?? "openIn"
        if !request.isPrivate, let origin, let rule,
           let kept = SitePermissions.action(PermissionSubject.openIn(rule.id), origin: origin) {
            return decision(kept)
        }
        switch action.openInAnswer(askingOn: rule) {
        case .place(let place)?: return .place(place)
        case .never?: return .refuse
        case nil: break
        }
        // A link and the download it starts are one question, not two: what this page answered holds for both.
        if let origin, let kept = request.tab?.permissionAnswers.action(key: origin, kind: kind) {
            return decision(kept)
        }
        return .ask
    }

    /// What a kept Open URL answer says: a place, a refusal, or nothing this code understands (ask again).
    private static func decision(_ kept: String) -> OpenInDecision {
        if kept == "deny" { return .refuse }
        return OpenInZigzag.Place(rawValue: kept).map(OpenInDecision.place) ?? .ask
    }

    @discardableResult
    static func route(_ url: URL, appliesToLinks: Bool, request: Request) async -> Outcome {
        guard let rule = firstMatch(url, appliesToLinks: appliesToLinks, isPrivate: request.isPrivate) else { return .noMatch }
        return switch await decide(rule, request: request) {
        case .handOff: await perform(rule, request: request)
        case .browser, .ask: .noMatch
        case .cancel: appliesToLinks ? .cancelled : .noMatch
        }
    }

    /// Runs one rule. Cookies are read only when its action names one, and the files it makes are gone by the end.
    @discardableResult
    static func perform(_ rule: DownloadRule, request: Request) async -> Outcome {
        var values = HandoffValues(link: request.url, referrer: request.referrer, filename: request.filename,
                                   mime: request.mime, space: request.space)
        let secret = rule.action.kind == .jsonRPC ? (HandoffSecrets.secret(for: rule.id) ?? "") : ""
        var cookieFile: URL?
        // The site's own sign-in goes wherever the rule says, a service on another machine included: the endpoint is
        // yours to write, and the editor warns when a rule would send cookies off this Mac. Blocking it here would put
        // a boundary on something you may well mean — a NAS, a build box — where the only real boundary is the one
        // that keeps a page from turning a URL into a command line.
        if rule.needsCookies {
            let cookies = await cookies(from: request.dataStore, for: request.url)
            values.cookieHeader = HandoffCookies.header(cookies)
            if rule.usesCookieFile, let file = try? HandoffCookies.writeFile(cookies) {
                values.cookieFile = file.path
                cookieFile = file
            }
        }
        announce(rule, askingOn: rule, action: rule.action, values: values, secret: secret, request: request)
        return await run(rule.action, values: values, secret: secret, request: request, rule: rule, cookieFile: cookieFile)
    }

    /// Says what a rule is about to do, where its tab is — in the window holding it, so a rule that fires in a
    /// background tab says so there rather than in the one you are looking at. Before the action runs, because what
    /// the notice needs to know is what is *about* to happen, and because a slow action shouldn't hold the notice back.
    /// Nothing is said where the firing shows something of its own (see `HandoffNotice.line`).
    ///
    /// `named` is the rule the notice puts a name to; `askingOn` is the rule an Open URL would keep a chosen place on,
    /// which is the same rule for a rule's own firing and **nil** for a script's answer. They part company exactly
    /// there, and it matters: an answer's Open URL with no place opens in a new tab and must be announced, where a
    /// rule's would ask, and the question is then the sighting.
    private static func announce(_ named: DownloadRule?, askingOn rule: DownloadRule?, action: DownloadRuleAction,
                                values: HandoffValues, secret: String, request: Request) {
        guard let line = HandoffNotice.line(for: named, askingOn: rule, action: action, values: values, secret: secret,
                                            request: request),
              let host = handoffHost(for: request) else { return }
        host.promptAutomation(line, symbol: action.kind.symbol)
    }

    /// Runs one action with the values at hand: what `perform` does for a rule, and what a script's own answer is run
    /// through — the same actions, the same tokens, the same fate for a cookie file. `rule` is the rule the action acts
    /// **for**, which is what an Open URL action may keep a chosen place on; it is nil for a script's answer, which has
    /// no rule of its own to keep one on. `cookieFile` is the file this run made, if any, which the action's kind
    /// decides the life of. Only `perform` and the answer path come through here, and the answer path can never reach
    /// `runScript` — `ScriptSays` refuses it — so nothing here can set a script running another.
    private static func run(_ action: DownloadRuleAction, values: HandoffValues, secret: String, request: Request,
                            rule: DownloadRule?, cookieFile: URL?) async -> Outcome {
        switch action.kind {
        case .runScript:
            let outcome = runScript(action, values: values, secret: secret, request: request, rule: rule)
            // A script keeps the file until it exits; one that never started has no use for it.
            if outcome != .handedOff, let cookieFile { HandoffCookies.removeFile(cookieFile) }
            return outcome
        case .openApp:
            let outcome = await openApp(action, values: values, secret: secret)
            if let cookieFile { removeWhenTheOtherAppHasRead(cookieFile) }
            return outcome
        case .openURL:
            let outcome = await openURL(action, values: values, secret: secret, request: request, rememberingOn: rule)
            if let cookieFile { removeWhenTheOtherAppHasRead(cookieFile) }
            return outcome
        case .jsonRPC:
            let outcome = await callService(action, values: values, secret: secret)
            if let cookieFile { HandoffCookies.removeFile(cookieFile) }
            return outcome
        case .saveToFolder, .openFile:
            // A destination, not a handoff: where the file lands is decided when the download is made, and the
            // download is never cancelled for it — so there is nothing to do here but let it be saved.
            return .noMatch
        }
    }

    /// Runs what a script's own output named, in the rule's place. The values the script was handed are the values its
    /// answer's tokens mean, so `{link}` in an answer is the link the script was given. A refusal is said the way a
    /// rule's failure is said, so a script told to do something it can't is never quiet about it.
    private static func actOnScriptsAnswer(_ named: ScriptSays, request: Request, values: HandoffValues,
                                           secret: String, rule: DownloadRule?) async {
        switch named {
        case .nothing:
            return
        case .refused(let why):
            report(.failed(why), rule: rule, url: values.link, isPrivate: request.isPrivate, window: request.window)
        case .action(let action):
            // An answer is a firing like any other, and announced the same way — the rule named is the script's, since
            // that is the rule that acted. It has no rule to remember a place on (`askingOn: nil`, and `rule: nil` to
            // `run`): a script's answer can't keep a choice on a rule that didn't make it, so an Open URL in it opens
            // in a new tab unless its own JSON names a place.
            announce(rule, askingOn: nil, action: action, values: values, secret: secret, request: request)
            let outcome = await run(action, values: values, secret: secret, request: request, rule: nil, cookieFile: nil)
            report(outcome, rule: rule, request: request)
        }
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
        let path = (DownloadTokens.expand(action.appPath, with: values, secret: secret) as NSString).expandingTildeInPath
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
    ///
    /// `rememberingOn` is the rule an Open URL action keeps a chosen place on, and is nil when there is none — a
    /// script's own answer, whose web addresses open in a new tab unless the answer's own JSON names a place
    /// (`"openIn":"mini"`). A rule that hasn't been told yet asks where to open and writes the answer on itself.
    private static func openURL(_ action: DownloadRuleAction, values: HandoffValues, secret: String,
                                request: Request, rememberingOn rule: DownloadRule?) async -> Outcome {
        let text = DownloadTokens.expand(action.urlTemplate, with: values, secret: secret)
        guard let url = URL(string: text), url.scheme != nil else {
            return .failed(String(localized: "The URL isn’t valid.", comment: "Why a download rule failed: the URL it was told to open can't be made."))
        }
        guard OpenInZigzag.handles(url) else { return openWithTheSystem(url) }
        var place: OpenInZigzag.Place?
        switch openInDecision(action, rule: rule, request: request) {
        case .place(let decided): place = decided
        // Told not to open, for this site or for the rule: the link or the file is left as if no rule had it.
        case .refuse: return .noMatch
        case .ask:
            // Only a rule can be asked, and only a rule can keep the answer.
            guard let rule else { return .noMatch }
            place = await askWhereToOpen(rule: rule, request: request)
        }
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

    /// Asks, once, where this rule's web addresses should open, and writes the answer down where it lasts: this page,
    /// this site (for this rule), or the rule itself. The dropdown picks one of the places; Allow and Don't Allow say
    /// whether to open at all; the duration says how long the answer holds — the same shape as every other question.
    private static func askWhereToOpen(rule: DownloadRule, request: Request) async -> OpenInZigzag.Place? {
        guard let host = WindowManager.shared.promptHost(for: request.window) else { return nil }
        // The site it's for, not the rule's name: the card names a site the way every other question does, and the
        // question goes when that site is left behind (never because the *rule's* name isn't the page's host).
        let origin = questionOrigin(for: request)
        let answer = await PermissionPrompt.ask(
            host: SitePermissions.askerName(origin), origin: origin,
            what: "", // `title` words the question; `what` is only ever its fallback's wording.
            symbol: "macwindow.badge.plus", in: host, tab: request.tab,
            title: String(localized: "Where should this open", comment: "A download rule's question the first time an Open URL rule fires on a web address: which of Zigzag's own places to open it in. The card adds the question mark."),
            actions: [.deny, .allow],
            chooser: OpenInZigzag.Place.allCases.map { .alternate($0.rawValue, $0.title) },
            canRemember: !request.isPrivate,
            ruleScope: alwaysFor(rule))
        guard let answer else { return nil }
        // The buttons say whether to open; the dropdown says where. Nothing picked (a debug answer) falls back to the
        // rule's own place, then to the dropdown's first entry, so an Allow is never quietly a no.
        let place = answer.action == "deny"
            ? nil
            : (OpenInZigzag.Place(rawValue: answer.choice ?? "") ?? rule.action.openIn?.place ?? .thisTab)
        // Kept as the answer itself — a place's id, or "deny" — so reading it back needs no special case.
        let kept = place?.rawValue ?? "deny"
        _ = SitePermissions.rememberAnswer(
            PermissionAnswer(action: kept, scope: answer.scope), subject: PermissionSubject.openIn(rule.id),
            origin: origin, tab: request.tab, isPrivate: request.isPrivate,
            onRule: { value in
                var remembered = rule
                remembered.action.openIn = OpenInZigzag.Place(rawValue: value).map(OpenInAnswer.place) ?? .never
                DownloadRulesStore.shared.update(remembered)
            })
        return place
    }

    /// How long a script's own answer is still taken for. It is read the moment it is written, so this only bounds a
    /// script that says nothing for a long time and then names something: that answer comes too late to act on, and
    /// the run itself is unaffected — a downloader may take as long as it likes.
    private static let answerWithin: TimeInterval = 60

    /// Runs the script with every token as its own argument or environment value. A `.sh` file is run by `/bin/sh`;
    /// anything else must be executable. Never `/bin/sh -c`, and never a joined command line.
    private static func runScript(_ action: DownloadRuleAction, values: HandoffValues, secret: String,
                                  request: Request, rule: DownloadRule?) -> Outcome {
        // A rule names its script, and a name alone means the scripts folder in your Documents: one place for them,
        // and a path still works for a script kept somewhere else.
        let path = Paths.script(named: DownloadTokens.expand(action.scriptPath, with: values, secret: secret)).path
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
        // Its output is read as it is written, not waited for: a script that says what to do next and then works for
        // ten minutes still gets its answer at once. Its errors go on being kept for the report at the end.
        let output = ScriptOutput { named in
            Task { await actOnScriptsAnswer(named, request: request, values: values, secret: secret, rule: rule) }
        }
        let answerPipe = Pipe()
        process.standardOutput = answerPipe
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let errors = ScriptErrors()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errors.append(handle.availableData)
        }
        answerPipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        // An answer that arrives after the wait is not run: a script may work for as long as it likes, but what it
        // names is taken while it is still the thing that just happened. Held weakly, so a run that is over lets go of
        // the request it was handed — and its tab — at once rather than when this comes round.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerWithin) { [weak output] in output?.stop() }
        let cookieFile = values.cookieFile
        let link = values.link
        let isPrivate = request.isPrivate
        // While it runs, and how it went: a card over the page it was handed, in the window its tab is in. A run that
        // comes and goes in a moment never flashes "running" — the card appears with how it ended instead.
        let script = ScriptNotice(script: (path as NSString).lastPathComponent, state: .running)
        let card = handoffHost(for: request).map { NoticeCard.show(script, tab: request.tab, in: $0) }
        process.terminationHandler = { finished in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            errors.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            answerPipe.fileHandleForReading.readabilityHandler = nil
            // Whatever it printed as it went is still read first: an answer written just as it exited is an answer.
            output.append(answerPipe.fileHandleForReading.readDataToEndOfFile())
            output.stop()
            if !cookieFile.isEmpty { HandoffCookies.removeFile(URL(fileURLWithPath: cookieFile)) }
            let said = errors.text
            let status = finished.terminationStatus
            Task { @MainActor in
                // The card says how it went, where there is one and it hasn't been put away. Anything else falls back
                // to the notice below, so a script that fails is never silent.
                let ended: ScriptNotice.State = status == 0 ? .ran : .failed(said)
                if card?.say(ScriptNotice(script: script.script, state: ended)) == true || status == 0 { return }
                let reason = said.isEmpty
                    ? String(localized: "The script exited with status \(status).", comment: "Why a download rule failed: the script finished with an error code. The placeholder is a number, like 1.")
                    : String(localized: "The script failed: \(said)", comment: "Why a download rule failed: the script exited with an error code and printed this. The placeholder is the script's own last line of error text.")
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

    /// The window a rule's notice belongs in: the one holding the tab it was handed (a rule in a background window
    /// says so there), else the window the request came from.
    private static func handoffHost(for request: Request) -> PromptHost? {
        if let tab = request.tab, let host = WindowManager.shared.promptHost(holding: tab) { return host }
        return WindowManager.shared.promptHost(for: request.window)
    }

    // MARK: JSON-RPC and XML-RPC

    private static func callService(_ action: DownloadRuleAction, values: HandoffValues, secret: String) async -> Outcome {
        let endpointText = DownloadTokens.expand(action.rpcEndpoint, with: values, secret: secret)
        guard let endpoint = URL(string: endpointText) else {
            return .failed(String(localized: "The service’s address isn’t valid.", comment: "Why a download rule failed: the JSON-RPC endpoint can't be made into a URL."))
        }
        let method = DownloadTokens.expand(action.rpcMethod, with: values, secret: secret)
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

/// A script's own output on its way back to the browser. The pipe is read off the main actor; what the script names
/// is handed to `act` where the request lives, once — the first answer it names is the one that counts, and after
/// `stop` nothing it says is taken at all. Only the buffer and that one flag are shared, and both are under the lock.
private nonisolated final class ScriptOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var taken = false
    /// Room for a line's worth of answer, and no more: a script that prints without end must not grow this without end.
    private let limit = 4_000
    private let act: @MainActor (ScriptSays) -> Void

    init(act: @escaping @MainActor (ScriptSays) -> Void) { self.act = act }

    /// Everything the script has printed so far, and what it names. Read on each chunk rather than at the end, so an
    /// answer arrives when it is written.
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > limit { data = Data(data.suffix(limit)) }
        guard !taken else { lock.unlock(); return }
        let named = ScriptSays.named(in: String(decoding: data, as: UTF8.self))
        guard named != .nothing else { lock.unlock(); return }
        taken = true
        lock.unlock()
        let act = self.act
        Task { @MainActor in act(named) }
    }

    /// No more answers are taken: the script has exited, or the wait for its answer is over.
    func stop() {
        lock.lock()
        taken = true
        lock.unlock()
    }
}
