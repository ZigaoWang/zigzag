import AppKit
import WebKit

/// A site as permissions know it: its origin, scheme://host[:port], the way the web itself tells sites apart.
/// http://localhost:62699 and http://localhost:62700 are two sites, and so are http:// and https:// of one host,
/// so an answer given to one never carries over to the other. The host is lowercased (an IPv6 one in brackets), and
/// the port left out only when it's the scheme's own (443 for https, 80 for http). Pages without a host (file:,
/// data:, about:) have no origin to keep an answer under: they're asked every time.
enum SiteOrigin {
    nonisolated static func make(scheme: String, host: String, port: Int?) -> String? {
        let scheme = scheme.lowercased()
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !scheme.isEmpty, !host.isEmpty, !host.contains("|"), !host.contains("/"), !host.contains("[") else { return nil }
        if host.contains(":") { host = "[\(host)]" }
        let standard = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        guard let port, port > 0, port != standard else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    /// The origin of a page's address. A blob: address belongs to the page that made it.
    nonisolated static func of(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "blob" {
            return URL(string: String(url.absoluteString.dropFirst("blob:".count))).flatMap { $0.scheme?.lowercased() == "blob" ? nil : of($0) }
        }
        guard let host = url.host(percentEncoded: false) else { return nil }
        return make(scheme: scheme, host: host, port: url.port)
    }

    /// The origin WebKit says asked: the frame's own, which for a frame from elsewhere isn't the page's. WebKit
    /// gives port 0 for the scheme's own.
    static func of(_ origin: WKSecurityOrigin) -> String? {
        make(scheme: origin.protocol, host: origin.host, port: origin.port == 0 ? nil : origin.port)
    }

    /// How a site is named to you: its host for https on its own port, as always, and otherwise with whatever
    /// sets it apart, so two sites never read the same ("localhost:8443", "http://localhost:62700").
    static func label(_ origin: String) -> String {
        origin.hasPrefix("https://") ? String(origin.dropFirst("https://".count)) : origin
    }

    /// The origin a label from `label(_:)` stands for.
    static func origin(fromLabel label: String) -> String {
        label.contains("://") ? label : "https://" + label
    }
}

/// One-time answers, kept for the asking tab's page until it navigates or reloads (Ask, as in Safari). Allow and
/// Block are kept per site. Stored as action ids, since some questions have more than yes or no (a handoff's
/// "browser" or "handOff").
struct PagePermissionAnswers {
    private var answers: [String: String] = [:]

    /// `key` is what the answer is for (`SitePermissions.answerKey`), `kind` what was asked ("camera", "location"…).
    mutating func note(_ allowed: Bool, key: String, kind: String) { note(allowed ? "allow" : "deny", key: key, kind: kind) }

    /// Records an answer. `key` is from `SitePermissions.answerKey`, `kind` is "camera", "location", "handoff:<rule
    /// UUID>"…
    mutating func note(_ action: String, key: String, kind: String) { answers["\(key)|\(kind)"] = action }

    /// A combined camera-and-microphone answer from before the split counts as neither.
    func answer(key: String, kind: String) -> Bool? { answers["\(key)|\(kind)"].map { $0 == "allow" } }

    /// The raw action id.
    func action(key: String, kind: String) -> String? { answers["\(key)|\(kind)"] }

    mutating func forget() { answers = [:] }

    var isEmpty: Bool { answers.isEmpty }
}

/// Per-origin permission answers (see `SiteOrigin`), stored as an action id under "origin|subject". One-time answers
/// live in `PagePermissionAnswers`.
enum SitePermissions {
    /// Bool-only store, so older builds can still read it and won't wipe it on write.
    private static let key = "SitePermissions"
    /// Non-Bool answers (pop-up destination, handoff choice, screen picker), kept apart so old builds never read a
    /// string as a Bool.
    private static let actionsKey = "SitePermissionActions"
    /// Where the answers are kept; tests use their own.
    static var defaults: UserDefaults = .standard
    /// A site's kept answer changed, from Site Controls, a question or Settings.
    static let changed = Signal<Void>()

    private static var stored: [String: String] {
        get {
            var actions: [String: String] = [:]
            // Also reads a mixed store from builds that wrote actions beside Bools; the next write splits it.
            for (entry, value) in defaults.dictionary(forKey: key) ?? [:] {
                if let action = value as? String { actions[entry] = action }
                else if let allowed = value as? Bool { actions[entry] = allowed ? legacyYes(forKey: entry) : "deny" }
            }
            for (entry, value) in defaults.dictionary(forKey: actionsKey) ?? [:] {
                if let action = value as? String { actions[entry] = action }
            }
            return actions
        }
        set {
            // Yes/no goes in the Bool store, everything else in the actions store. Rebuilding both on every write
            // moves stray actions out and drops keys that changed kind.
            var simple: [String: Bool] = [:]
            var rich: [String: String] = [:]
            for (entry, action) in newValue {
                switch action {
                case "allow": simple[entry] = true
                case "deny": simple[entry] = false
                case "automatic" where entry.hasSuffix("|" + PermissionSubject.popups): simple[entry] = true
                default: rich[entry] = action
                }
            }
            defaults.set(simple, forKey: key)
            if rich.isEmpty { defaults.removeObject(forKey: actionsKey) }
            else { defaults.set(rich, forKey: actionsKey) }
            changed.send()
        }
    }

    /// Camera and microphone are separate permissions, asked in this order.
    static func mediaTypes(for type: WKMediaCaptureType) -> [WKMediaCaptureType] {
        switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
    }

    /// A legacy `true` maps to the subject's yes: "automatic" for pop-ups (their answers are destinations or "deny"),
    /// "allow" otherwise.
    private static func legacyYes(forKey key: String) -> String {
        key.hasSuffix("|" + PermissionSubject.popups) ? "automatic" : "allow"
    }

    /// Converts old Bool answers and the combined camera-and-microphone key. Idempotent; runs at launch.
    static func migrateAnswersToActions() {
        var now = stored
        for key in now.keys where key.hasSuffix("|cameraAndMicrophone") {
            let origin = String(key.dropLast("|cameraAndMicrophone".count))
            let action = now[key]
            for kind in ["camera", "microphone"] where now["\(origin)|\(kind)"] == nil {
                now["\(origin)|\(kind)"] = action
            }
            now[key] = nil
        }
        stored = now
    }
    static func action(_ subject: String, origin: String) -> String? {
        let now = stored
        if subject.hasPrefix("app:"), now["\(origin)|\(PermissionSubject.apps)"] == "deny" { return "deny" }
        return now["\(origin)|\(subject)"]
    }

    static func remember(_ action: String?, subject: String, origin: String) { stored["\(origin)|\(subject)"] = action }

    /// Questions whose Remember starts checked, as in Chrome, which keeps these answers for the site.
    static func remembersByDefault(_ subject: String) -> Bool {
        [PermissionSubject.notifications, PermissionSubject.location,
         PermissionSubject.media(.camera), PermissionSubject.media(.microphone)].contains(subject)
    }

    /// Records an answer: "Always" is kept for the site, anything else (and anything in a private window) for `tab`'s
    /// page only. Returns whether `action` allows.
    @discardableResult
    static func rememberAnswer(_ answer: PermissionAnswer, subject: String, origin: String, pageSubject: String? = nil,
                               tab: Tab?, isPrivate: Bool) -> Bool {
        // Don't trust callers to pass privacy; check the tab too.
        let keepsNothing = isPrivate || (tab?.isPrivate ?? false)
        if answer.remember, !keepsNothing {
            remember(answer.action, subject: subject, origin: origin)
        } else if let tab {
            tab.permissionAnswers.note(answer.action, key: origin, kind: pageSubject ?? subject)
        }
        return answer.action != "deny"
    }

    static func actions(origin: String) -> [String: String] {
        var found: [String: String] = [:]
        for (key, action) in stored where key.hasPrefix(origin + "|") {
            found[String(key.dropFirst(origin.count + 1))] = action
        }
        return found
    }

    /// Origins with an answer under `prefix` (e.g. "handoff:<rule UUID>"), sorted.
    static func sites(prefix: String) -> [String] { decisions(prefix: prefix).map(\.origin) }

    /// The same origins with their actions, sorted. Only place the key is split.
    static func decisions(prefix: String) -> [(origin: String, action: String)] {
        stored.compactMap { key, action in
            let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1].hasPrefix(prefix) else { return nil }
            return (String(parts[0]), action)
        }.sorted { $0.origin < $1.origin }
    }

    private static func allowed(_ action: String?) -> Bool? { action.map { $0 != "deny" } }
    static func kind(_ type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        default: "cameraAndMicrophone"
        }
    }

    /// Answers kept before were under the host alone, so one given to http://localhost:62699 also let in
    /// http://localhost:62700 and https://localhost. Which origin was actually asked can't be known now, so every
    /// Allow (camera, microphone, location, notifications, pop-ups, apps to open) is dropped and the site asks
    /// again. A Don't Allow can't let anything in, so it's kept, for https on the host's own port only: that's the
    /// site it almost always was, and any other just asks. Runs at launch; a key with no "://" is an old one, so
    /// running again finds nothing to do. Nothing but this one entry is touched.
    static func migrateHostOnlyAnswers() {
        let before = stored
        guard before.keys.contains(where: { !$0.contains("://") }) else { return }
        var after: [String: String] = [:]
        for (k, v) in before where k.contains("://") { after[k] = v }
        let denials: Set<String> = ["camera", "microphone", "cameraAndMicrophone", "location", "notifications"]
        for (k, v) in before where !k.contains("://") && v == "deny" {
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, denials.contains(parts[1]),
                  let origin = SiteOrigin.make(scheme: "https", host: parts[0], port: nil) else { continue }
            let migrated = "\(origin)|\(parts[1])"
            if after[migrated] == nil { after[migrated] = "deny" }
        }
        stored = after
    }

    /// Splits a combined camera-and-microphone answer into one per kind; a kind's own answer wins. Runs after
    /// `migrateHostOnlyAnswers`.
    static func migrateMediaAnswers() {
        var now = stored
        let legacy = now.keys.filter { $0.hasSuffix("|cameraAndMicrophone") }
        guard !legacy.isEmpty else { return }
        for key in legacy {
            let origin = String(key.dropLast("|cameraAndMicrophone".count))
            let action = now[key]
            for kind in ["camera", "microphone"] where now["\(origin)|\(kind)"] == nil {
                now["\(origin)|\(kind)"] = action
            }
            now[key] = nil
        }
        stored = now
    }

    /// What an answer is kept under. A frame from the page's own origin asks as the page. One from elsewhere (a call
    /// embedded with allow="camera") asks as itself on that page only, kept under "page|embed:frame", so an answer
    /// it got on one site never lets it in on another, nor one the frame's own site got. With no page origin to keep
    /// that under (a file: page), nil: asked every time.
    static func answerKey(frame: String?, page: String?) -> String? {
        guard let frame, let page else { return nil }
        return frame == page ? frame : "\(page)|embed:\(frame)"
    }

    /// The page's origin for a question from `tab`'s page. Without a tab to say, the frame is taken as the page.
    private static func page(of tab: Tab?, frame: String?) -> String? {
        guard let tab else { return frame }
        return SiteOrigin.of(tab.url)
    }

    /// How a question names who asks: the site, or for an embedded frame, it and the page it's on.
    static func askerName(frame: String?, page: String?) -> String {
        guard let frame, frame != page else { return askerName(frame) }
        guard let page else {
            return String(localized: "Embedded content from \(SiteOrigin.label(frame))", comment: "Who asks, in a site's permission question, for a frame from another site on a page with no site. The placeholder is the frame's site.")
        }
        return String(localized: "Embedded content from \(SiteOrigin.label(frame)) on \(SiteOrigin.label(page))", comment: "Who asks, in a site's permission question, for a frame from another site: the frame's site, then the page's site it's on.")
    }

    private static func action(for allowed: Bool?) -> String? { allowed.map { $0 ? "allow" : "deny" } }

    /// A site's kept answer wins over a page's one-time answer.
    static func knownAnswer(site: Bool?, page: Bool?) -> PermissionAnswer? {
        if let site { return PermissionAnswer(action: site ? "allow" : "deny", remember: true) }
        return page.map { PermissionAnswer(action: $0 ? "allow" : "deny", remember: false) }
    }

    /// The keys for these kinds on a site's own page: its own answers and those of frames from elsewhere on it.
    private static func keys(_ kinds: [String], on origin: String) -> [String] {
        let suffixes = kinds.map { "|" + $0 }
        return stored.keys.filter { k in
            kinds.contains { k == "\(origin)|\($0)" } || (k.hasPrefix(origin + "|embed:") && suffixes.contains { k.hasSuffix($0) })
        }
    }

    /// Camera and microphone answers given on a site's page: its own, and those of frames from elsewhere on it.
    static func mediaDecisions(origin: String) -> [Bool] {
        let now = stored
        return keys(["camera", "microphone"], on: origin).sorted().compactMap { allowed(now[$0]) }
    }

    /// Location answers given on a site's page, its frames' included.
    static func locationDecisions(origin: String) -> [Bool] {
        let now = stored
        return keys(["location"], on: origin).compactMap { allowed(now[$0]) }
    }

    /// A combined camera-and-microphone request is answered only when both are kept; a no in either is a no.
    static func decision(origin: String, type: WKMediaCaptureType) -> Bool? {
        let now = stored
        let types = mediaTypes(for: type)
        let answers = types.compactMap { allowed(now["\(origin)|\(kind($0))"]) }
        guard answers.count == types.count else { return nil }
        return answers.allSatisfy { $0 }
    }

    static func remember(_ allowed: Bool, origin: String, type: WKMediaCaptureType) {
        var now = stored
        for type in mediaTypes(for: type) { now["\(origin)|\(kind(type))"] = action(for: allowed) }
        stored = now
    }

    /// Every remembered answer for one site: kind ("camera", "location", "notifications"…) to allowed or not.
    static func choices(origin: String) -> [String: Bool] {
        var found: [String: Bool] = [:]
        for (key, action) in actions(origin: origin) { found[key] = allowed(action) }
        return found
    }

    /// Forgets everything about a site, notifications included.
    static func forgetEverything(origin: String) {
        var now = stored
        for k in now.keys where k.hasPrefix(origin + "|") { now[k] = nil }
        stored = now
        asked = asked.filter { !$0.hasPrefix(origin + "|") }
    }

    /// Sites (origins) with a remembered choice of any kind.
    static var sites: Set<String> {
        Set(stored.keys.compactMap { $0.split(separator: "|").first.map(String.init) })
    }

    static func forgetAll() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: actionsKey)
        changed.send()
    }

    /// A site's answer about your location, if it ever asked.
    static func location(origin: String) -> Bool? { allowed(action(PermissionSubject.location, origin: origin)) }

    /// Frames from elsewhere on the site's page forget theirs too.
    static func forgetLocation(origin: String) {
        var now = stored
        for k in keys(["location"], on: origin) { now[k] = nil }
        stored = now
    }

    /// "Ask again" for the camera and microphone only: location, notifications and apps to open each have their own
    /// row, and stay as they are. Frames from elsewhere on the site's page forget theirs too.
    static func forget(origin: String) {
        var now = stored
        for k in keys(["camera", "microphone", "cameraAndMicrophone"], on: origin) { now[k] = nil }
        stored = now
    }

    /// Notifications: nil until the site has asked and you've answered.
    static func notifications(origin: String) -> Bool? { allowed(action(PermissionSubject.notifications, origin: origin)) }

    static func setNotifications(_ allowed: Bool?, origin: String) { remember(action(for: allowed), subject: PermissionSubject.notifications, origin: origin) }

    /// Default for asking before a site's first download. Off, as in Chrome, Arc and Edge.
    static let asksBeforeDownloadsByDefault = false

    static var asksBeforeDownloads: Bool {
        get { defaults.object(forKey: "SiteAsksBeforeDownloads") as? Bool ?? asksBeforeDownloadsByDefault }
        set { defaults.set(newValue, forKey: "SiteAsksBeforeDownloads") }
    }

    /// Whether a page with no site (about:blank, data:) may download. Local files always may; with asking on there is
    /// no site to ask about, so no.
    static func pageWithoutSiteMayDownload(isFile: Bool) -> Bool {
        isFile || !asksBeforeDownloads
    }

    /// Site's Allow or Block, else the page's one-time answer, else nil.
    static func downloads(origin: String, tab: Tab? = nil) -> Bool? {
        allowed(action(PermissionSubject.downloads, origin: origin))
            ?? tab?.permissionAnswers.answer(key: origin, kind: PermissionSubject.downloads)
    }

    /// Whether a site's own scripts may talk to a program listening on this Mac. There is no question to ask: the
    /// answer is the switch in Site Controls, and it counts only while the master setting is on (`LocalReceivers`).
    static func localReceivers(origin: String) -> Bool {
        action(PermissionSubject.localReceivers, origin: origin) == "allow"
    }

    /// Turns that on or off for one origin. Off forgets the answer, so the site is back where it started rather than
    /// carrying a block.
    static func setLocalReceivers(_ allowed: Bool, origin: String) {
        remember(allowed ? "allow" : nil, subject: PermissionSubject.localReceivers, origin: origin)
    }

    /// Allows one download from a blocked notice, for the page only. A site Block still wins, so each further file
    /// needs its own click.
    static func allowThisDownload(origin: String, tab: Tab?) {
        tab?.permissionAnswers.note("allow", key: origin, kind: PermissionSubject.downloads)
    }

    /// Whether this site may download, asking on its first one. Put off or no window means refused. With asking off
    /// in Settings, unanswered sites download freely; a kept Block still refuses. `asking` is false for page-started
    /// downloads, which never get a question.
    static func downloadsAllowed(origin: String, window: NSWindow?, isPrivate: Bool, tab: Tab? = nil,
                                 asking: Bool = true) async -> Bool {
        if let known = downloads(origin: origin, tab: tab) { return known }
        guard asking else { return true }
        // Asking off: same as before sites were asked. A kept Block above still wins.
        guard asksBeforeDownloads else { return true }
        noteAsked(.downloads, origin: origin, isPrivate: isPrivate)
        guard let controller = WindowManager.shared.promptHost(for: window) else { return false }
        let answer = await PermissionPrompt.ask(host: askerName(origin), origin: origin, what: "files",
                                                symbol: "arrow.down.circle", in: controller, tab: tab,
                                                title: String(localized: "Allow downloads from this site", comment: "A site's permission question, without its question mark. The site is sending a file."),
                                                actions: [.deny, .allow], canRemember: true,
                                                answered: {
                                                    knownAnswer(site: downloads(origin: origin),
                                                                page: tab?.permissionAnswers.answer(key: origin, kind: PermissionSubject.downloads))
                                                })
        guard let answer else { return false }
        return rememberAnswer(answer, subject: PermissionSubject.downloads, origin: origin, tab: tab, isPrivate: isPrivate)
    }

    /// Whether a site may open links for another app (zoommtg:, itms-apps:): Allow or Block kept for the site, chosen
    /// in Site Controls or Settings, comes first; else yes for an app it was told Always Open to on its question;
    /// else nil, asked each time.
    static func appDecision(origin: String, scheme: String) -> Bool? {
        let now = stored
        if let site = now["\(origin)|\(PermissionSubject.apps)"] { return allowed(site) }
        return allowed(now["\(origin)|\(PermissionSubject.app(scheme))"])
    }

    static func opensApp(origin: String, scheme: String) -> Bool { appDecision(origin: origin, scheme: scheme) == true }

    /// Always Open on a site's question: that one app, for that site.
    static func allowOpeningApp(origin: String, scheme: String) { remember("allow", subject: PermissionSubject.app(scheme), origin: origin) }

    /// Pop-ups are blocked unless Always Allow was chosen. The yes is kept as "automatic" (normal pop-up routing),
    /// not "allow".
    static func popups(origin: String) -> Bool { allowed(action(PermissionSubject.popups, origin: origin)) == true }

    static func setPopups(_ allowed: Bool?, origin: String) {
        remember(allowed.map { $0 ? "automatic" : "deny" }, subject: PermissionSubject.popups, origin: origin)
    }

    /// `WebRTCProtection`: the site's Allow or Block, nil to follow the setting.
    static func webRTC(origin: String) -> Bool? { allowed(stored["\(origin)|webRTC"]) }

    /// Every site's notification choice by origin, for the page script: it knows the answer before the page asks.
    static var notificationDecisions: [String: Bool] {
        var out: [String: Bool] = [:]
        for (key, action) in stored where key.hasSuffix("|notifications") {
            out[String(key.dropLast("|notifications".count))] = allowed(action)
        }
        return out
    }

    // MARK: Site Controls' rows

    /// Sites that asked for something this session, answered or not ("origin|kind"), so Site Controls shows the row
    /// even when the question went by unanswered. Never a private window's: it remembers nothing about a site.
    private static var asked: Set<String> = []

    /// The site at `origin` asked for `permission`: its row shows in Site Controls from now on, this session.
    static func noteAsked(_ permission: SitePermission, origin: String?, isPrivate: Bool) {
        guard let origin, !isPrivate else { return }
        asked.insert("\(origin)|\(permission.rawValue)")
    }

    static func hasAsked(_ permission: SitePermission, origin: String) -> Bool { asked.contains("\(origin)|\(permission.rawValue)") }

    /// The answers a permission is kept under on a site's page: its own, and those of frames from elsewhere on it.
    /// Apps to open also count the one app a site was told Always Open to ("origin|app:zoommtg").
    private static func keys(for permission: SitePermission, on origin: String) -> [String] {
        let own = keys(permission.kinds, on: origin)
        guard permission == .apps else { return own }
        return own + stored.keys.filter { $0.hasPrefix(origin + "|app:") }
    }

    /// Whether anything is kept for `permission` on the site's page.
    static func hasDecision(_ permission: SitePermission, origin: String) -> Bool { !keys(for: permission, on: origin).isEmpty }

    /// Site Controls state: Ask with nothing kept, Allow when every kept answer is yes, else Block. WebRTC is never
    /// Ask; with nothing kept it follows the setting.
    static func choice(_ permission: SitePermission, origin: String) -> PermissionChoice {
        if permission == .webRTC { return WebRTCProtection.choice(origin: origin, in: nil) }
        let now = stored
        return PermissionChoice(answers: keys(for: permission, on: origin).compactMap { allowed(now[$0]) })
    }

    /// Ask forgets every answer kept for it on the site's page, its frames' too. Allow or Block is kept for the site,
    /// for both camera and microphone at once, and for every frame from elsewhere that answered there before.
    static func setChoice(_ choice: PermissionChoice, for permission: SitePermission, origin: String) {
        var now = stored
        let existing = keys(for: permission, on: origin)
        for k in existing { now[k] = nil }
        if let allowed = choice.allowed {
            let action = allowed && permission == .popups ? "automatic" : action(for: allowed)
            // Frames from elsewhere keep a key of their own; the site's own answer is one key for the permission.
            for k in existing where k.hasPrefix(origin + "|embed:") { now[k] = action }
            now["\(origin)|\(permission.primaryKind)"] = action
        }
        stored = now
        if permission == .notifications, choice != .allow { WebNotifications.shared.removeAll(origin: origin) }
        if permission == .apps { ExternalLinks.forgetAnswers(origin: origin) }
    }

    /// Rows Site Controls shows for a site: anything asked this session or kept. No notifications or pop-ups in
    /// private windows. WebRTC always shows while protection is on (so calls can be allowed up front), unless WebKit
    /// has no switch for it.
    static func shown(origin: String, isPrivate: Bool) -> [SitePermission] {
        SitePermission.allCases.filter { permission in
            if isPrivate, !permission.inPrivate { return false }
            if permission == .webRTC {
                guard WebRTCProtection.isAvailable else { return false }
                if WebRTCProtection.isOn { return true }
            }
            return hasDecision(permission, origin: origin) || hasAsked(permission, origin: origin)
        }
    }

    /// Whether the site has its own answer for `permission` (kept, or asked this session) rather than following the
    /// setting. `here` is a private tab's WebRTC choice.
    static func isOwn(_ permission: SitePermission, origin: String, here: Bool? = nil) -> Bool {
        hasDecision(permission, origin: origin) || hasAsked(permission, origin: origin) || (permission == .webRTC && here != nil)
    }

    /// Reset Permissions: the site back to how it started, as if it never asked. Every answer kept for it goes (its
    /// frames' and apps to open included), and its rows with them.
    static func reset(origin: String) {
        forgetEverything(origin: origin)
        asked = asked.filter { !$0.hasPrefix(origin + "|") }
        WebNotifications.shared.removeAll(origin: origin)
        ExternalLinks.forgetAnswers(origin: origin)
    }

    #if DEBUG
    /// For tests: forgets which sites asked this session.
    static func forgetAsked() { asked = [] }
    #endif

    /// What a question names the site as: its label, or "This page" for one with no origin.
    static func askerName(_ origin: String?) -> String {
        origin.map(SiteOrigin.label) ?? String(localized: "This page", comment: "Stands for the site in a question when the page has no host.")
    }

    /// The site's notification answer on `tab`'s page: Allow or Block kept for the site, else the answer given on
    /// this page.
    static func notifications(origin: String, tab: Tab?) -> Bool? {
        kept(notifications(origin: origin), for: tab) ?? tab?.permissionAnswers.answer(key: origin, kind: "notifications")
    }

    /// What you kept for a site; none for AI apps' pages, which are asked and so refused.
    static func kept<Answer>(_ answer: @autoclosure () -> Answer?, for tab: Tab?) -> Answer? {
        tab?.profile.getsYourData == false ? nil : answer()
    }

    /// Asked like the camera, Remember checked to start. A private window never shows them anyway.
    static func requestNotifications(origin: String, window: NSWindow?, isPrivate: Bool, tab: Tab? = nil) async -> Bool? {
        if let known = notifications(origin: origin, tab: tab) { return known }
        guard let controller = WindowManager.shared.promptHost(for: window) else { tab?.noteUnanswered(.permission, "notifications"); return nil }
        let answer = await PermissionPrompt.ask(host: askerName(origin), origin: origin, answerKey: origin, what: "notifications", symbol: "bell.fill", in: controller, tab: tab,
                                                title: String(localized: "Show notifications", comment: "A site's permission question, without its question mark. The site wants to show notifications."),
                                                actions: [.deny, .allow], canRemember: true,
                                                remembersByDefault: remembersByDefault(PermissionSubject.notifications),
                                                answered: {
                                                    knownAnswer(site: kept(notifications(origin: origin), for: tab),
                                                                page: tab?.permissionAnswers.answer(key: origin, kind: "notifications"))
                                                })
        guard let answer else { return nil }
        return rememberAnswer(answer, subject: PermissionSubject.notifications, origin: origin, tab: tab, isPrivate: isPrivate)
    }

    /// The location answer for `key` on `tab`'s page: Allow or Block kept, else the answer given on this page.
    private static func location(key: String, tab: Tab?) -> Bool? {
        kept(location(origin: key), for: tab) ?? tab?.permissionAnswers.answer(key: key, kind: "location")
    }

    /// The camera or microphone answer for `key` on `tab`'s page: Allow or Block kept, else the answer given on
    /// this page.
    private static func decision(key: String, type: WKMediaCaptureType, tab: Tab?) -> Bool? {
        kept(decision(origin: key, type: type), for: tab) ?? tab?.permissionAnswers.answer(key: key, kind: kind(type))
    }

    /// Location, asked the same way as the camera. A page with no origin to keep it under (file:) is asked every time.
    static func requestLocation(origin securityOrigin: WKSecurityOrigin, window: NSWindow?, isPrivate: Bool, tab: Tab? = nil) async -> WKPermissionDecision {
        let frame = SiteOrigin.of(securityOrigin), page = page(of: tab, frame: frame)
        let key = answerKey(frame: frame, page: page)
        if let key, let known = location(key: key, tab: tab) { return known ? .grant : .deny }
        noteAsked(.location, origin: page, isPrivate: isPrivate)
        guard let controller = WindowManager.shared.promptHost(for: window) else { tab?.noteUnanswered(.permission, "location"); return .deny }
        let answer = await PermissionPrompt.ask(host: askerName(frame: frame, page: page), origin: page, answerKey: key, what: "your location",
                                                symbol: "location.fill", in: controller, tab: tab,
                                                title: String(localized: "Use your location", comment: "A site's permission question, without its question mark."),
                                                actions: [.deny, .allow], canRemember: key != nil,
                                                remembersByDefault: remembersByDefault(PermissionSubject.location),
                                                answered: {
                                                    key.flatMap { key in
                                                        knownAnswer(site: kept(location(origin: key), for: tab),
                                                                    page: tab?.permissionAnswers.answer(key: key, kind: "location"))
                                                    }
                                                })
        guard let answer else { return .deny }
        guard let key else { return answer.action == "deny" ? .deny : .grant }
        return rememberAnswer(answer, subject: PermissionSubject.location, origin: key, tab: tab, isPrivate: isPrivate) ? .grant : .deny
    }

    static func request(origin securityOrigin: WKSecurityOrigin, type: WKMediaCaptureType, window: NSWindow?, isPrivate: Bool,
                        tab: Tab? = nil) async -> WKPermissionDecision {
        let frame = SiteOrigin.of(securityOrigin), page = page(of: tab, frame: frame)
        let key = answerKey(frame: frame, page: page)
        let types = mediaTypes(for: type)
        // Every kind already answered: no question.
        if let key, types.allSatisfy({ decision(key: key, type: $0, tab: tab) != nil }) {
            return types.allSatisfy { decision(key: key, type: $0, tab: tab) == true } ? .grant : .deny
        }
        guard let controller = WindowManager.shared.promptHost(for: window) else {
            // Nowhere to ask (a sign-in popup): deny without keeping it, but note the ask so Site Controls shows a
            // row.
            for type in types where key.flatMap({ decision(key: $0, type: type, tab: tab) }) == nil {
                noteAsked(type == .microphone ? .microphone : .camera, origin: page, isPrivate: isPrivate)
            }
            // A page with no one there says so to the AI app using it.
            tab?.noteUnanswered(.permission, type == .camera ? "camera" : type == .microphone ? "microphone" : "camera and microphone")
            return .deny
        }
        // A no for either kind already settles it; don't ask about the other.
        if let key, types.contains(where: { decision(key: key, type: $0, tab: tab) == false }) { return .deny }
        var allowed = true
        for type in types {
            if let key, let known = decision(key: key, type: type, tab: tab) {
                allowed = allowed && known
                continue
            }
            noteAsked(type == .microphone ? .microphone : .camera, origin: page, isPrivate: isPrivate)
            let what: String, title: String
            switch type {
            case .camera: (what, title) = ("your camera", String(localized: "Use your camera", comment: "A site's permission question, without its question mark."))
            case .microphone: (what, title) = ("your microphone", String(localized: "Use your microphone", comment: "A site's permission question, without its question mark."))
            // A combined request is asked as the two questions above.
            case .cameraAndMicrophone: continue
            @unknown default: continue
            }
            // Asked in turn like any other question (`PageQuestions`).
            let answer = await PermissionPrompt.ask(host: askerName(frame: frame, page: page), origin: page, answerKey: key, what: what,
                                                    symbol: type == .microphone ? "mic.fill" : "video.fill", in: controller, tab: tab, title: title,
                                                    actions: [.deny, .allow], canRemember: key != nil,
                                                    remembersByDefault: remembersByDefault(PermissionSubject.media(type)),
                                                    answered: {
                                                        key.flatMap { key in
                                                            knownAnswer(site: kept(decision(origin: key, type: type), for: tab),
                                                                        page: tab?.permissionAnswers.answer(key: key, kind: kind(type)))
                                                        }
                                                    })
            // Esc or a closed window means "not now".
            guard let answer else { return .deny }
            let isAllowed = key.map { rememberAnswer(answer, subject: PermissionSubject.media(type), origin: $0, tab: tab, isPrivate: isPrivate) }
                ?? (answer.action != "deny")
            if !isAllowed { return .deny }
            allowed = allowed && isAllowed
        }
        return allowed ? .grant : .deny
    }

    /// Screen sharing (getDisplayMedia), offered as in Safari: Don't Allow, Share Screen…, Share Window…. Either
    /// share goes through macOS's ScreenCaptureKit picker, so a kept answer never captures without macOS asking.
    /// "Always" keeps the answer (a no too) for the site, "This time" for the page.
    static func requestDisplayCapture(origin securityOrigin: WKSecurityOrigin, window: NSWindow?, tab: Tab?) async -> DisplayCaptureChoice {
        let frame = SiteOrigin.of(securityOrigin), page = page(of: tab, frame: frame)
        // Same key as other questions: the page's site, or a cross-site frame scoped to that page.
        let key = answerKey(frame: frame, page: page)
        let isPrivate = tab?.isPrivate ?? false
        guard let controller = WindowManager.shared.promptHost(for: window) else {
            noteAsked(.screen, origin: page, isPrivate: isPrivate)
            tab?.noteUnanswered(.permission, "screen sharing")
            return .deny
        }
        if let key, let kept = screenAnswer(key: key, tab: tab) {
            return DisplayCaptureChoice(kept)
        }
        noteAsked(.screen, origin: page, isPrivate: isPrivate)
        // Only a secure top-level page keeps an answer; a cross-site frame may only answer this time.
        let canRemember = key != nil && frame == page && page?.hasPrefix("https://") == true
        let answer = await PermissionPrompt.ask(host: askerName(frame: frame, page: page), origin: page, answerKey: key, what: "your screen", symbol: "rectangle.on.rectangle",
                                                in: controller, tab: tab, title: DisplayCaptureChoice.title,
                                                actions: DisplayCaptureChoice.actions, canRemember: canRemember,
                                                answered: {
                                                    key.flatMap { screenAnswer(key: $0, tab: tab) }
                                                })
        guard let answer else { return .deny }
        let choice = DisplayCaptureChoice(answer)
        if let key {
            _ = SitePermissions.rememberAnswer(PermissionAnswer(action: choice.action, remember: answer.remember),
                                              subject: PermissionSubject.screen, origin: key, tab: tab,
                                              isPrivate: isPrivate)
        }
        return choice
    }

    /// The site's kept choice, then the page's.
    private static func screenAnswer(key: String, tab: Tab?) -> PermissionAnswer? {
        if let site = kept(DisplayCaptureChoice(action: SitePermissions.action(PermissionSubject.screen, origin: key)), for: tab) {
            return PermissionAnswer(action: site.action, remember: true)
        }
        if let page = tab?.permissionAnswers.action(key: key, kind: PermissionSubject.screen),
           let kept = DisplayCaptureChoice(action: page) {
            return PermissionAnswer(action: kept.action, remember: false)
        }
        return nil
    }
}

/// How a screen-sharing question is answered, as WebKit takes it (`WKDisplayCapturePermissionDecision` in
/// WKUIDelegatePrivate.h): no, macOS's picker for a display, or its picker for a window. WebKit has no answer for one
/// picker with both, short of asking nothing first.
enum DisplayCaptureChoice: Int, CaseIterable {
    case deny = 0, screen = 1, window = 2

    /// Allow is the filled button (Share Window…).
    init(_ answer: PermissionAnswer?) {
        switch answer?.action {
        case "allow": self = .window
        case "screen": self = .screen
        default: self = .deny
        }
    }

    /// "allow" means Share Window…, matching the filled button.
    var action: String {
        switch self {
        case .deny: "deny"
        case .screen: "screen"
        case .window: "allow"
        }
    }

    init?(action: String?) {
        switch action {
        case "deny": self = .deny
        case "screen": self = .screen
        case "allow", "window": self = .window
        default: return nil
        }
    }

    static var title: String { String(localized: "Share your screen", comment: "Title of the prompt when a site asks to share the screen.") }

    /// As Safari offers them.
    static var actions: [PermissionAction] {
        [.deny,
         .alternate("screen", screen.buttonTitle),
         PermissionAction(id: "allow", title: window.buttonTitle, isDeny: false, isProminent: true)]
    }

    var buttonTitle: String {
        switch self {
        case .deny: String(localized: "Don’t Allow", comment: "Button on a site's permission question.")
        case .screen: String(localized: "Share Screen…", comment: "Button on a site's question to share the screen: macOS's picker comes up to choose a display.")
        case .window: String(localized: "Share Window…", comment: "Button on a site's question to share the screen: macOS's picker comes up to choose a window.")
        }
    }
}

/// Site Controls rows. Camera and microphone are separate.
enum SitePermission: String, CaseIterable {
    case camera, microphone, location, notifications, popups, downloads, apps, webRTC, screen
    /// The kinds of answer kept for it.
    var kinds: [String] {
        switch self {
        case .camera: ["camera"]
        case .microphone: ["microphone"]
        case .location: ["location"]
        case .notifications: ["notifications"]
        case .popups: ["popups"]
        case .downloads: ["downloads"]
        case .apps: ["apps"]
        case .webRTC: ["webRTC"]
        case .screen: ["screen"]
        }
    }

    /// WebRTC can't be asked about (a page has it at load or not), so only Allow or Block.
    var choices: [PermissionChoice] { self == .webRTC ? [.allow, .block] : PermissionChoice.allCases }

    /// The one kind a choice made in Site Controls is kept as.
    var primaryKind: String { rawValue }

    /// Allowed in private windows (nothing kept). WebRTC there follows the setting, per tab.
    var inPrivate: Bool { self == .camera || self == .microphone || self == .location || self == .apps || self == .downloads || self == .webRTC || self == .screen }

    var title: String {
        switch self {
        case .camera: String(localized: "Camera", comment: "Row in the site panel's This Site group.")
        case .microphone: String(localized: "Microphone", comment: "Row in the site panel's This Site group.")
        case .location: String(localized: "Location", comment: "Row in the site panel's This Site group.")
        case .notifications: String(localized: "Notifications", comment: "Row in the site panel's This Site group.")
        case .popups: String(localized: "Pop-ups", comment: "Row in the site panel's This Site group.")
        case .downloads: String(localized: "Downloads", comment: "Row in the site panel's This Site group: whether the site may save files.")
        case .apps: String(localized: "Open apps", comment: "Row in the site panel's This Site group: whether the site's links may open apps on this Mac, like Zoom or the App Store.")
        case .webRTC: String(localized: "WebRTC", comment: "Row in the site panel's This Site group: whether the site may use WebRTC, which calls need, and which can show sites your real IP address. A name: keep it as it is.")
        case .screen: String(localized: "Screen sharing", comment: "Row in the site panel's This Site group: whether the site may share the screen. macOS still asks which window or display.")
        }
    }
}

/// A site's answer for one permission, as Site Controls' dropdown offers it: ask each time (nothing kept), allow, or
/// block.
enum PermissionChoice: CaseIterable {
    case ask, allow, block

    /// From the answers kept: none is Ask, all yes is Allow, and any no is Block.
    init(answers: [Bool]) {
        self = answers.isEmpty ? .ask : answers.allSatisfy { $0 } ? .allow : .block
    }

    /// What's kept for it: nothing for Ask.
    var allowed: Bool? {
        switch self {
        case .ask: nil
        case .allow: true
        case .block: false
        }
    }

    /// A site's permissions in a few words, for the Permissions row: "2 allowed", "1 blocked", "2 allowed, 1 blocked",
    /// or Ask when nothing's decided.
    static func summary(_ choices: [PermissionChoice]) -> String {
        let allowed = choices.filter { $0 == .allow }.count, blocked = choices.filter { $0 == .block }.count
        let allowedText = String(localized: "\(allowed) allowed", comment: "On the Permissions row of the site panel: how many permissions the site has been allowed.")
        let blockedText = String(localized: "\(blocked) blocked", comment: "On the Permissions row of the site panel: how many permissions the site has been blocked from.")
        switch (allowed > 0, blocked > 0) {
        case (true, true): return String(localized: "\(allowedText), \(blockedText)", comment: "On the Permissions row of the site panel: how many allowed, then how many blocked, like “2 allowed, 1 blocked”.")
        case (true, false): return allowedText
        case (false, true): return blockedText
        case (false, false): return PermissionChoice.ask.title
        }
    }

    /// The summary for a narrow panel: how many are decided, either way ("2 set"), or Ask.
    static func shortSummary(_ choices: [PermissionChoice]) -> String {
        let decided = choices.filter { $0 != .ask }.count
        return decided == 0 ? PermissionChoice.ask.title
            : String(localized: "\(decided) set", comment: "On the Permissions row of a narrow site panel: how many permissions have an answer, allowed or blocked.")
    }

    var title: String {
        switch self {
        case .ask: String(localized: "Ask", comment: "A choice in a permission's dropdown in Site Controls: the site asks each time.")
        case .allow: String(localized: "Allow", comment: "A choice in a permission's dropdown in Site Controls: the site may use it.")
        case .block: String(localized: "Block", comment: "A choice in a permission's dropdown in Site Controls: the site may not use it, and isn't asked about.")
        }
    }
}

/// Ends a question whose subject is gone (a held pop-up the page closed). A queued question never shows; one on
/// screen goes as if Esc was pressed.
@MainActor
final class QuestionCancellation {
    private(set) var isCancelled = false
    let changed = Signal<Void>()

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        changed.send()
    }
}

/// "Use your location?", at the top of the page that asked, sliding down from its top edge: the question, the site
/// under it, a Remember checkbox under that, and the answers at the trailing edge, the filled one last. The answer
/// holds for the page that asked unless Remember is checked; Allow or Block for good is also chosen in the site panel
/// or Settings › Privacy. Not answering is easy: the close button (or Cancel, where the question has one), Esc, or a
/// click anywhere else puts it off ("not now"), and so does the tab going to another site. One question at a time per
/// window. It belongs to the tab that asked: it steps aside while another tab is in front and comes back with that
/// tab.
final class PermissionPrompt: FloatingPanelView {
    /// The app's own icon when it's an app that would open, else the request's symbol on a soft circle.
    private let picture = NSImageView()
    private let badge = ColorView(color: .clear)
    private let request = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    private let asker = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    /// Keeps the answer for the site; hidden where nothing can be kept.
    private let remember = Checkbox()
    private var remembers = false
    private let closeButton = IconButton(symbol: "xmark", toolTip: String(localized: "Not Now", comment: "Tooltip of the × on a site's permission question."))
    /// Only for a caller's own durations (a download rule's): one dropdown under the question.
    private let duration = DropdownButton()
    /// The pick-only dropdown (where a web address opens).
    private let answerMenu = DropdownButton()
    /// Answers of one kind (where a pop-up opens) as the filled answer: the shown one in one click, the rest from its
    /// chevron's menu.
    private let answerSplit = SplitPillButton()
    private var menuChoices: [PermissionAction] = []
    /// Whether the dropdown only picks (where a web address opens) instead of answering.
    private var hasChooser = false
    /// The site that asked: when the tab goes elsewhere, the question no longer applies.
    private var askingHost = ""
    /// The origin that asked, when there is one: the question goes once the tab is on another origin, even one
    /// on the same host.
    private var askingOrigin: String?
    /// When it came up. Allow takes no click for the first half second, so a page can't ask just as you click
    /// (a "click fast" game) and catch that click on Allow.
    private var shownAt = Date.distantFuture
    var acceptsAllow: Bool { Date().timeIntervalSince(shownAt) > 0.5 }
    private var urlToken: SignalToken?
    private var clickMonitor: Any?
    /// Deny first, alternatives in the middle, the prominent answer last.
    private var buttons: [(button: InteractiveView, width: CGFloat)] = []
    private var answer: ((PermissionAnswer?) -> Void)?
    private var monitor: Any?
    /// The tab whose page asked, and the window it's in.
    private weak var askingTab: Tab?
    /// Checked again just before showing, in case the page was answered while this waited.
    var recheck: (() -> PermissionAnswer?)?
    private weak var controller: PromptHost?
    private var tabsToken: SignalToken?
    private var waitingToken: SignalToken?
    var cancelToken: SignalToken?
    /// Count of other waiting questions, hidden when there are none.
    private let moreWaiting = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private var questionsWaiting = 1

    /// Other questions in this window, or nil when this is the only one.
    static func waitingBehind(questionsWaiting: Int) -> Int? {
        questionsWaiting > 1 ? questionsWaiting - 1 : nil
    }

    /// "Other" rather than "behind": each pane of a split can show a card.
    static func waitingLine(questionsWaiting: Int) -> String? {
        guard let behind = waitingBehind(questionsWaiting: questionsWaiting) else { return nil }
        return String(localized: "Other questions in this window: \(behind)", comment: "A line on a site's permission question when another question is also about in the same window, on this page or another pane of a split.")
    }

    /// The question on screen in each window, so it can follow the sidebar.
    private static var shown: [ObjectIdentifier: PermissionPrompt] = [:]
    /// Questions in flight by page and request, so a repeat waits for the first answer.
    private static var inFlight: [String: (id: UUID, task: Task<PermissionAnswer?, Never>)] = [:]
    /// Unanswered questions per window. One shows at a time (see `ask`), and the card shows the count.
    private static var waiting: [ObjectIdentifier: Int] = [:]
    static let waitingChanged = Signal<Void>()

    /// Includes the one on screen.
    static func questionsWaiting(in controller: PromptHost) -> Int { waiting[ObjectIdentifier(controller)] ?? 0 }

    private static func setWaiting(_ count: Int, in controller: PromptHost) {
        let key = ObjectIdentifier(controller)
        if count > 0 { waiting[key] = count } else { waiting[key] = nil }
        waitingChanged.send()
    }

    /// A question is on screen in this window.
    static func isShowing(in controller: PromptHost) -> Bool {
        guard let prompt = shown[ObjectIdentifier(controller)] else { return false }
        return prompt.superview != nil && !prompt.isHidden
    }

    /// Puts the window's question back under the address after the sidebar or the window changed. It never jumps:
    /// riding a sidebar slide (`slide` is its duration, `timing` its curve) it moves with the sidebar, on the same curve; going between
    /// the address and the top of the page, it glides there.
    static func reposition(in controller: PromptHost, slide: TimeInterval? = nil, timing: CAMediaTimingFunction = Tokens.Motion.drawer) {
        guard let prompt = shown[ObjectIdentifier(controller)], prompt.superview != nil, !prompt.isHidden else { return }
        prompt.rePlace(slide: slide, timing: timing) { prompt.place(in: controller) }
    }

    /// Deny first, alternatives in order, the main affirmative last.
    static func actions(for actions: [PermissionAction]) -> [PermissionAction] {
        let ordered = actions.filter(\.isDeny) + actions.filter { !$0.isDeny && !$0.isProminent } + actions.filter { !$0.isDeny && $0.isProminent }
        return ordered.enumerated().map { index, action in
            PermissionAction(id: action.id, title: action.title, isDeny: action.isDeny,
                             isProminent: !action.isDeny && index == ordered.count - 1)
        }
    }

    /// `host` names the site in the question; `origin` is the site it's for (`SiteOrigin`); `answerKey` is the
    /// frame-and-page key from `SitePermissions.answerKey`. `answered` is checked when it's this question's turn.
    /// `tab` defaults to the front tab. `menu`: answers of one kind as a dropdown that answers (and acts as the
    /// filled answer). `chooser`: a dropdown that only picks, returned as `choice`, with no duration. The Remember
    /// checkbox (`rememberTitle`, else "Remember for this site") shows only when `canRemember`, checked to start when
    /// `remembersByDefault`. `detail` replaces the
    /// site line with a sentence. A `.cancel` action takes the close button's place. Nil means Not Now.
    static func ask(host: String, origin: String? = nil, answerKey: String? = nil, what: String, symbol: String, icon: NSImage? = nil,
                    in controller: PromptHost, tab: Tab? = nil, title: String? = nil,
                    actions: [PermissionAction] = [.deny, .allow], menu: [PermissionAction] = [],
                    chooser: [PermissionAction] = [],
                    durations: [String]? = nil,
                    canRemember: Bool = true, remembersByDefault: Bool = false, rememberTitle: String? = nil, detail: String? = nil,
                    cancellation: QuestionCancellation? = nil,
                    answered: @escaping () -> PermissionAnswer? = { nil }) async -> PermissionAnswer? {
        let remembers = canRemember && !controller.promptIsPrivate
        if let known = answered() {
            return PermissionAnswer(action: known.action, remember: known.remember && remembers, scopeIndex: known.scopeIndex, choice: known.choice)
        }
        let request = title ?? String(localized: "Use \(what)", comment: "A site's permission question, without its question mark. Only for a request no caller words itself; the placeholder is in English.")
        let asking = tab ?? controller.promptFrontTab
        // The same question while its card is up waits for that answer. Only for the same tab, frame and privacy.
        let sharedKey = Self.questionKey(origin: origin, answerKey: answerKey, tabID: asking?.id,
                                         isPrivate: tab?.isPrivate ?? controller.promptIsPrivate,
                                         window: ObjectIdentifier(controller), request: request)
        if let before = inFlight[sharedKey] {
            let known = await before.task.value
            guard cancellation?.isCancelled != true else { return nil }
            return known.map { PermissionAnswer(action: $0.action, remember: $0.remember && remembers, scopeIndex: $0.scopeIndex, choice: $0.choice) }
        }
        // Counts as waiting from the moment it's asked, so the tab marker and the card's count include it. Cards take
        // turns in `PageQuestions`.
        let token = UUID()
        let task = Task<PermissionAnswer?, Never> { @MainActor in
            let questionID = UUID()
            if let asking {
                PendingQuestions.enqueue(.init(id: questionID, tabID: asking.id, origin: origin, title: request))
            }
            setWaiting(questionsWaiting(in: controller) + 1, in: controller)
            let answer = await show(host: host, request: request,
                                  symbol: symbol, icon: icon, actions: actions, menu: menu, chooser: chooser,
                                  canRemember: remembers, remembersByDefault: remembersByDefault, rememberTitle: rememberTitle, detail: detail,
                                  durations: durations,
                                  origin: origin, in: controller, tab: tab, cancellation: cancellation, answered: answered)
            PendingQuestions.answer(questionID)
            setWaiting(max(0, questionsWaiting(in: controller) - 1), in: controller)
            return answer
        }
        inFlight[sharedKey] = (token, task)
        let answer = await task.value
        if inFlight[sharedKey]?.id == token { inFlight[sharedKey] = nil }
        let said = if let answer {
            answer.action == "deny" ? "not allowed" : answer.remember ? "always allowed" : answer.action == "allow" ? "allowed" : "allowed the other way"
        } else { "put off" }
        Diagnostics.note("Asked: \(title ?? "Use \(what)")", site: host, said, isPrivate: controller.promptIsPrivate)
        return answer
    }

    /// Same window, tab, answer key and privacy make the same question; the request last, so different questions from
    /// one frame still stack.
    static func questionKey(origin: String?, answerKey: String?, tabID: UUID?, isPrivate: Bool,
                            window: ObjectIdentifier, request: String) -> String {
        "\(window)|\(tabID?.uuidString ?? "no tab")|\(isPrivate ? "private" : "shared")|\(answerKey ?? origin ?? "no site")|\(request)"
    }

    private static func show(host: String, request: String, symbol: String, icon: NSImage?, actions: [PermissionAction],
                             menu: [PermissionAction], chooser: [PermissionAction], canRemember: Bool, remembersByDefault: Bool = false,
                             rememberTitle: String?, detail: String?,
                             durations: [String]? = nil,
                             origin: String?, in controller: PromptHost, tab: Tab?,
                             cancellation: QuestionCancellation? = nil,
                             answered: @escaping () -> PermissionAnswer? = { nil }) async -> PermissionAnswer? {
        // The held pop-up is gone.
        guard cancellation?.isCancelled != true else { return nil }
        // Never under What's New, where it couldn't be seen: it waits until the notes close.
        await withCheckedContinuation { continuation in
            WhatsNewSheet.afterClosing(in: controller.window) { continuation.resume() }
        }
        guard cancellation?.isCancelled != true else { return nil }
        // Only a closed window gives up. A hidden, minimized or other-Space window keeps the card for when it comes
        // back.
        guard controller.window != nil else { return nil }
        // The asking tab closed while an earlier question waited.
        if let tab, tab.isClosed { return nil }
        let asking = tab ?? controller.promptFrontTab
        // In the space's own color, like every other button in the window.
        let accent = controller.promptAccent
        return await withCheckedContinuation { continuation in
            let prompt = PermissionPrompt(frame: .zero)
            prompt.cancelToken = cancellation?.changed.observe { [weak prompt] in prompt?.finish(nil) }
            prompt.request.stringValue = String(localized: "\(request)?", comment: "A site's permission question: the request, then a question mark, like “Use your camera?”.")
            prompt.asker.stringValue = detail ?? host.withoutWWW
            if detail != nil {
                // A sentence wraps; a bare host keeps its end.
                prompt.asker.lineBreakMode = .byWordWrapping
                prompt.asker.usesSingleLineMode = false
                prompt.asker.maximumNumberOfLines = 2
            }
            prompt.askingHost = host
            prompt.askingOrigin = origin
            if let icon {
                prompt.picture.image = icon
                prompt.badge.isHidden = true
            } else {
                // A thin line drawing of what's asked for, in the text's own ink, with nothing behind it: the same
                // glyphs as the rest of the app, not a filled badge.
                let line = symbol.replacingOccurrences(of: ".fill", with: "")
                prompt.picture.image = Tokens.Symbol.image(line, size: Tokens.TypeSize.heading)
                prompt.picture.imageScaling = .scaleNone
                prompt.picture.contentTintColor = Tokens.Color.textPrimary
                prompt.badge.color = .clear
            }
            prompt.remembers = canRemember && durations == nil
            prompt.remember.isHidden = !prompt.remembers
            prompt.remember.isOn = prompt.remembers && remembersByDefault
            prompt.remember.title = rememberTitle ?? String(localized: "Remember for this site", comment: "Checkbox on a site's permission question: keeps the answer for the site instead of only this page.")
            prompt.remember.tint = accent
            if let durations {
                prompt.duration.options = durations.map { DropdownButton.Option(title: $0) }
                prompt.duration.selectedIndex = 0
                prompt.duration.isHidden = false
            }
            let ordered = Self.actions(for: actions)
            // Cancel says what the close button would.
            prompt.closeButton.isHidden = ordered.contains(where: \.isCancel)
            let row = ordered.map { action -> PillButton in
                let button = PillButton(title: action.title, style: action.isProminent ? .prominent : .plain)
                if action.isProminent { button.tint = accent }
                button.onClick = { [weak prompt] _ in prompt?.press(action) }
                return button
            }
            prompt.orderedActions = ordered
            for button in row { prompt.addSubview(button) }
            prompt.addSubview(prompt.moreWaiting)
            prompt.buttons = row.map { ($0 as InteractiveView, max($0.fittingWidth, Tokens.Dialog.minButtonWidth)) }
            // Split button that answers (where a pop-up opens); acts as the filled answer.
            if !menu.isEmpty {
                prompt.menuChoices = menu
                prompt.answerSplit.choices = menu.map(\.title)
                prompt.answerSplit.tint = accent
                prompt.answerSplit.accepts = { [weak prompt] in prompt?.acceptsAllow ?? false }
                prompt.answerSplit.onChoose = { [weak prompt] index in
                    guard let prompt, let answer = Self.menuAnswer(menu, index: index, accepts: prompt.acceptsAllow,
                                                                   remember: prompt.remembers && prompt.remember.isOn,
                                                                   scopeIndex: prompt.duration.isHidden ? 0 : prompt.duration.selectedIndex)
                    else { return }
                    prompt.finish(answer)
                }
                prompt.addSubview(prompt.answerSplit)
            }
            // Dropdown that only picks (where a web address opens), under the text. `chosenChoice` is read when a button
            // is pressed.
            if !chooser.isEmpty {
                prompt.hasChooser = true
                prompt.menuChoices = chooser
                prompt.answerMenu.options = chooser.map { DropdownButton.Option(title: $0.title) }
                prompt.addSubview(prompt.answerMenu)
            }
            prompt.setAccessibilityLabel(String(localized: "\(host): \(request)?", comment: "VoiceOver label of a site's permission question: the site, then its request, like “zoom.us: Use your camera?”."))
            prompt.answer = { response in
                continuation.resume(returning: response)
            }
            prompt.askingTab = asking
            prompt.recheck = answered
            prompt.controller = controller
            // Kept current so the card shows how many wait behind it.
            prompt.questionsWaiting = Self.questionsWaiting(in: controller)
            prompt.waitingToken = Self.waitingChanged.observe { [weak prompt] in prompt?.refreshWaiting() }
            controller.promptOverlay.addSubview(prompt)
            prompt.isHidden = true
            prompt.tabsToken = controller.observePromptTabs { [weak prompt] in prompt?.followTab() }
            // The tab went to another site: this question was that site's, so it's put off.
            prompt.urlToken = asking?.changed.observe { [weak prompt, weak asking] change in
                // Follows the page's light or dark look.
                if [.themeColor, .darkPage, .pdf, .settings, .webView].contains(change) { prompt?.matchPage() }
                guard change == .url, let prompt, let url = asking?.url else { return }
                if let origin = prompt.askingOrigin {
                    if SiteOrigin.of(url) != origin { prompt.finish(nil) }
                } else if let now = url.host(), now != prompt.askingHost {
                    prompt.finish(nil)
                }
            }
            // A click anywhere else, outside it and the address it hangs from, puts it off too.
            prompt.clickMonitor = TouchPress.addMonitor(matching: [.leftMouseDown, .rightMouseDown]) { [weak prompt, weak controller] event in
                guard let prompt, !prompt.isHidden, event.window === prompt.window else { return event }
                // The command bar over it has its own clicks.
                if controller?.promptIsCovered == true { return event }
                // The card's dropdown menu draws past the card; clicks on it aren't clicks away.
                if let menu = MenuPanel.current, menu.window === prompt.window,
                   menu.bounds.contains(menu.convert(event.locationInWindow, from: nil)) { return event }
                let inside = prompt.bounds.contains(prompt.convert(event.locationInWindow, from: nil))
                let address = controller?.promptAnchor
                let onAddress = address.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
                if !inside && !onAddress { prompt.finish(nil) }
                // A click in the card gives it the keyboard, so Return answers.
                if inside, !prompt.hasFocus {
                    DispatchQueue.main.async { [weak prompt] in
                        guard let prompt, prompt.answer != nil, !prompt.hasFocus else { return }
                        prompt.window?.makeFirstResponder(prompt)
                    }
                }
                return event
            }
            prompt.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak prompt, weak controller] event in
                guard let prompt, !prompt.isHidden, event.window === prompt.window else { return event }
                // Under notes or the command bar opened after it, Esc is theirs.
                if WhatsNewSheet.isShowing(in: prompt.window) || controller?.promptIsCovered == true { return event }
                let modified = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                switch Self.keyAction(keyCode: event.keyCode, modified: modified, focused: prompt.hasFocus, shift: event.modifierFlags.contains(.shift)) {
                case .cancel: prompt.finish(nil); return nil
                case .primary: prompt.pressPrimary(); return nil
                case .next(let back): prompt.moveFocus(back: back); return nil
                case .pass: return event
                }
            }
            if cancellation?.isCancelled == true { prompt.finish(nil); return }
            // Last, once it listens: a tab already gone puts it off here, and that takes down what was just set up.
            prompt.followTab()
        }
    }

    /// Updates the waiting count and the card's height.
    private func refreshWaiting() {
        guard let controller else { return }
        questionsWaiting = Self.questionsWaiting(in: controller)
        guard superview != nil, !isHidden else { return }
        place(in: controller)
        needsLayout = true
    }

    /// Shown while the asking tab is in front (either split side), hidden otherwise, "not now" once the tab closes or
    /// moves window. Waits behind Save password? (`PageQuestions`).
    func followTab() {
        guard answer != nil, let controller else { return }
        guard let tab = askingTab, !tab.isClosed, controller.promptHolds(tab) else { finish(nil); return }
        let inFront = controller.promptShows(tab)
        if inFront, isHidden {
            if let known = recheck?() { finish(known); return }
            // Placed hidden so a card over another split pane doesn't block it (`PageQuestions`).
            place(in: controller)
            guard PageQuestions.mayShow(self, in: controller.promptOverlay) else { return }
            controller.clearForPrompt()
            isHidden = false
            // For `isShowing` and the debug bridge.
            Self.shown[ObjectIdentifier(controller)] = self
            slideIn()
            PageQuestions.cameUp(in: controller)
        } else if !inFront, !isHidden {
            isHidden = true
            PageQuestions.turnFreed(in: controller)
        }
    }

    /// Always on the page that asked, at the top in the middle (over the pane that asked, in a split): the same
    /// place whether the sidebar is out or not, so it never moves away from the page it belongs to.
    private func place(in controller: PromptHost) {
        matchPage()
        surfaceTint = nil
        tintStrength = nil
        isElevated = true
        radius = Tokens.Radius.panel
        let area = askingTab.flatMap { controller.pageFrame(showing: $0) } ?? controller.focusedPaneFrame
        let measured = answersWidth + Self.pad * 2
        let width = CardOverThePage.width(measured: measured, in: area)
        frame = NSRect(x: round(area.midX - width / 2), y: area.minY + Tokens.Space.x3, width: width, height: height(for: width))
    }

    /// Matches the page's light or dark look, like `PageBar.inkAppearance` (#300): the page's color, else its web
    /// view's appearance, else nil for the window's.
    static func look(pageColor: NSColor?, pageLook: NSAppearance.Name?) -> NSAppearance.Name? {
        PageBar.inkAppearance(on: pageColor) ?? pageLook.map { NSAppearance(named: $0)?.isDark == true ? .darkAqua : .aqua }
    }

    private func matchPage() {
        let name = Self.look(pageColor: askingTab?.pageColor, pageLook: askingTab?.webView?.appearance?.name)
        if appearance?.name != name { appearance = name.flatMap(NSAppearance.init(named:)) }
    }

    /// In from above the page's top edge, eased to a stop, as every notice comes (`slidesFromTop`): something new
    /// arriving, seen now and then, not a key. It never fades up out of the page.
    private func slideIn() {
        shownAt = Date()
        slidesFromTop = true
        present()
    }

    /// Back up the way it came, then gone.
    private func slideOut() {
        dismiss()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = Self.iconSide / 2
        // A long host loses its middle, not its end: the part that says whose site it is stays.
        asker.lineBreakMode = .byTruncatingMiddle
        request.lineBreakMode = .byWordWrapping
        request.usesSingleLineMode = false
        request.maximumNumberOfLines = 2
        closeButton.onClick = { [weak self] _ in self?.finish(nil) }
        duration.isHidden = true
        duration.menuTakesOwnLook = true
        answerMenu.menuTakesOwnLook = true
        answerSplit.menuTakesOwnLook = true
        [badge, picture, request, asker, closeButton, remember, duration].forEach { addSubview($0) }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Takes the keyboard from a click inside it, so Return and Tab are its own.
    override var acceptsFirstResponder: Bool { answer != nil }

    /// The card or one of its controls has the keyboard.
    private var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// The answers in order, `buttons` beside them.
    private var orderedActions: [PermissionAction] = []

    /// What a button's press answers: nil for Cancel (put off), else the action, kept for the site only when Remember
    /// is shown and checked.
    static func answer(for action: PermissionAction, rememberChecked: Bool, canRemember: Bool,
                       scopeIndex: Int = 0, choice: String? = nil) -> PermissionAnswer? {
        guard !action.isCancel else { return nil }
        return PermissionAnswer(action: action.id, remember: canRemember && rememberChecked, scopeIndex: scopeIndex, choice: choice)
    }

    enum KeyAction: Equatable {
        case cancel, primary, pass
        /// Tab or Shift-Tab between its controls.
        case next(back: Bool)
    }

    /// Esc always cancels. Return or Enter press the filled answer, and Tab moves, only while the card has the
    /// keyboard: a question that comes up while you type never takes your Return.
    static func keyAction(keyCode: UInt16, modified: Bool, focused: Bool, shift: Bool = false) -> KeyAction {
        if keyCode == 53 { return .cancel }
        guard focused, !modified else { return .pass }
        switch keyCode {
        case 36, 76: return .primary
        case 48: return .next(back: shift)
        default: return .pass
        }
    }

    private func press(_ action: PermissionAction) {
        guard action.isDeny || acceptsAllow else { return }
        finish(Self.answer(for: action, rememberChecked: remember.isOn, canRemember: remembers,
                           scopeIndex: duration.isHidden ? 0 : duration.selectedIndex, choice: chosenChoice))
    }

    /// What choice `index` of the answering split says: nil in the first half second or for no such choice.
    static func menuAnswer(_ choices: [PermissionAction], index: Int, accepts: Bool, remember: Bool, scopeIndex: Int) -> PermissionAnswer? {
        guard accepts, choices.indices.contains(index) else { return nil }
        return PermissionAnswer(action: choices[index].id, remember: remember, scopeIndex: scopeIndex)
    }

    /// Return: the filled answer, after its first half second like a click.
    private func pressPrimary() {
        if answersMenu { answerSplit.chooseShown(); return }
        if let index = orderedActions.lastIndex(where: \.isProminent) {
            press(orderedActions[index])
        }
    }

    /// Tab order: Remember, the duration, the answers, the menu (the split's two parts).
    private var focusable: [InteractiveView] {
        ([remember, duration] + buttons.map(\.button) + (menuChoices.isEmpty ? [] : answersMenu ? [answerSplit.main, answerSplit.more] : [answerMenu]))
            .filter { !$0.isHidden && $0.isDescendant(of: self) }
    }

    private func moveFocus(back: Bool) {
        let views = focusable
        guard !views.isEmpty, let window else { return }
        let current = views.firstIndex { window.firstResponder === $0 }
        let next = current.map { (back ? $0 - 1 + views.count : $0 + 1) % views.count } ?? (back ? views.count - 1 : 0)
        window.makeFirstResponder(views[next])
    }

    /// The pick-only dropdown's entry; nil when there isn't one.
    private var chosenChoice: String? {
        guard hasChooser, !menuChoices.isEmpty else { return nil }
        return menuChoices[min(max(0, answerMenu.selectedIndex), menuChoices.count - 1)].id
    }

    private func finish(_ choice: PermissionAnswer?) {
        // A private or one-time question never returns Always, debug answers included.
        let choice = choice.map { PermissionAnswer(action: $0.action, remember: $0.remember && (remembers || !duration.isHidden),
                                                   scopeIndex: $0.scopeIndex, choice: $0.choice) }
        // The keyboard goes back to the page.
        if hasFocus, let window { window.makeFirstResponder(askingTab?.webView ?? controller?.promptFrontTab?.webView) }
        stopListening()
        let answer = self.answer
        self.answer = nil
        answer?(choice)
        slideOut()
        if let controller { PageQuestions.turnFreed(in: controller) }
    }

    /// Taken away without an answer (its window closed): the page hears "not now" rather than waiting forever.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, answer != nil {
            stopListening()
            let answer = self.answer
            self.answer = nil
            answer?(nil)
        }
    }

    private func stopListening() {
        if let monitor { TouchPress.removeMonitor(monitor) }
        monitor = nil
        if let clickMonitor { TouchPress.removeMonitor(clickMonitor) }
        clickMonitor = nil
        tabsToken = nil
        urlToken = nil
        cancelToken = nil
        if let controller, Self.shown[ObjectIdentifier(controller)] === self {
            // Point at whichever card is still up, if any.
            Self.shown[ObjectIdentifier(controller)] = controller.promptOverlay.subviews
                .compactMap { $0 as? PermissionPrompt }
                .first { !$0.isHidden && $0 !== self }
        }
    }

    #if DEBUG
    /// Debug bridge: answers the showing question like its buttons. Allow still waits out its first half second. Nil
    /// puts it off.
    static func debugAnswer(_ answer: PermissionAnswer?, in host: PromptHost) {
        guard let prompt = shown[ObjectIdentifier(host)], !prompt.isHidden else { return }
        if let answer, answer.action != "deny", !prompt.acceptsAllow { return }
        prompt.finish(answer)
    }

    /// The question showing in `host`, as its words read.
    static func debugShowing(in host: PromptHost) -> String? {
        guard let prompt = shown[ObjectIdentifier(host)], prompt.superview != nil, !prompt.isHidden else { return nil }
        return prompt.request.stringValue + " " + prompt.asker.stringValue
    }

    /// The answers on the question showing in `host`, left to right.
    static func debugButtons(in host: PromptHost) -> [String] {
        guard let prompt = shown[ObjectIdentifier(host)], prompt.superview != nil, !prompt.isHidden else { return [] }
        return prompt.buttons.compactMap { ($0.button as? PillButton)?.title }
    }

    /// Debug bridge: checks or clears Remember, as a click would.
    static func debugRemember(_ on: Bool, in host: PromptHost) {
        guard let prompt = shown[ObjectIdentifier(host)], !prompt.isHidden, !prompt.remember.isHidden else { return }
        prompt.remember.isOn = on
    }

    /// Debug bridge: a key as the card's key monitor takes it (`focused`: as after a click in it).
    static func debugKey(_ keyCode: UInt16, focused: Bool, in host: PromptHost) {
        guard let prompt = shown[ObjectIdentifier(host)], !prompt.isHidden else { return }
        if focused { prompt.window?.makeFirstResponder(prompt) }
        switch keyAction(keyCode: keyCode, modified: false, focused: prompt.hasFocus) {
        case .cancel: prompt.finish(nil)
        case .primary: prompt.pressPrimary()
        case .next(let back): prompt.moveFocus(back: back)
        case .pass: break
        }
    }

    /// The card's frame and its parts', in the card's own flipped coordinates.
    static func debugFrames(in host: PromptHost) -> [String: String] {
        guard let prompt = shown[ObjectIdentifier(host)], !prompt.isHidden else { return [:] }
        var out = ["card": NSStringFromRect(prompt.frame), "remember": NSStringFromRect(prompt.remember.frame),
                   "close": prompt.closeButton.isHidden ? "hidden" : NSStringFromRect(prompt.closeButton.frame),
                   "title": NSStringFromRect(prompt.request.frame), "detail": NSStringFromRect(prompt.asker.frame)]
        for (i, b) in prompt.buttons.enumerated() { out["button\(i)"] = NSStringFromRect(b.button.frame) }
        if prompt.answersMenu { out["answer"] = NSStringFromRect(prompt.answerSplit.pillFrame) }
        return out
    }

    /// Debug bridge: the answering split's chevron, as a click on it.
    static func debugOpenAnswerMenu(in host: PromptHost) {
        guard let prompt = shown[ObjectIdentifier(host)], !prompt.isHidden, prompt.answersMenu else { return }
        prompt.answerSplit.openMenu()
    }
    #endif

    private static let pad = CardOverThePage.pad
    private static let iconSide = CardOverThePage.iconSide
    private static let buttonHeight = DialogButtons.height
    private static let buttonGap = Tokens.Dialog.buttonGap
    /// Text to the Remember row.
    private static let optionGap = Tokens.Space.x3
    /// What's above to the answers.
    private static let answersGap = Tokens.Space.x4

    private var textX: CGFloat { Self.pad + Self.iconSide + Tokens.Space.x3 }
    /// Room kept at the right of the text for the close button; none when Cancel stands in for it.
    private var closeRoom: CGFloat { closeButton.isHidden ? 0 : Tokens.Metric.iconButton }
    private func textWidth(for width: CGFloat) -> CGFloat { width - textX - Self.pad - closeRoom }

    private func wrappedHeight(_ label: Label, width: CGFloat) -> CGFloat {
        guard label.maximumNumberOfLines != 1 else { return label.lineHeight }
        return ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width + Label.inset * 2, height: 200)).height ?? label.lineHeight)
    }

    private func textHeight(for width: CGFloat) -> CGFloat {
        wrappedHeight(request, width: textWidth(for: width)) + 2 + wrappedHeight(asker, width: textWidth(for: width))
    }

    /// Under the text, at its edge: Remember, or the pick-only dropdown and the caller's durations.
    private var pickers: [InteractiveView] {
        [hasChooser ? answerMenu : nil, duration.isHidden ? nil : duration].compactMap { $0 }
    }

    private func optionWidth(for width: CGFloat) -> CGFloat { width - textX - Self.pad }

    private var pickersWidth: CGFloat {
        pickers.reduce(0) { $0 + $1.intrinsicContentSize.width } + Self.buttonGap * CGFloat(max(0, pickers.count - 1))
    }

    private func optionHeight(for width: CGFloat) -> CGFloat {
        if !remember.isHidden { return Self.optionGap + remember.height(for: optionWidth(for: width)) }
        guard !pickers.isEmpty else { return 0 }
        let rows = pickersWidth <= optionWidth(for: width) ? 1 : CGFloat(pickers.count)
        return Self.optionGap + rows * Tokens.Page.controlHeight + (rows - 1) * Self.buttonGap
    }

    private var answersMenu: Bool { !menuChoices.isEmpty && !hasChooser }

    /// The answers left to right at the widths `layout` gives them: the buttons, then the dropdown that answers.
    private func answerViews(_ layout: AnswerLayout) -> [(view: NSView, width: CGFloat)] {
        let shared = buttons.map(\.width).max() ?? 0
        return buttons.map { ($0.button as NSView, layout == .shared ? shared : $0.width) }
            + (answersMenu ? [(answerSplit as NSView, answerSplit.intrinsicContentSize.width)] : [])
    }

    enum AnswerLayout: Equatable {
        /// Side by side at one width, as a Mac dialog sets its answers, at the trailing edge.
        case shared
        /// Side by side at their own widths, when one width doesn't fit.
        case own
        /// One per row, full width, the filled one on top, as a narrow Mac alert stacks them.
        case stacked
    }

    /// One width when that fits, their own widths when those fit, else stacked: never a clipped title. `widths` are
    /// the buttons' own; `menu` is the answering dropdown's, which keeps its width.
    static func answerLayout(widths: [CGFloat], menu: CGFloat? = nil, available: CGFloat, gap: CGFloat) -> AnswerLayout {
        let count = CGFloat(widths.count + (menu == nil ? 0 : 1))
        guard count > 1 else { return .shared }
        let rest = gap * (count - 1) + (menu ?? 0)
        if CGFloat(widths.count) * (widths.max() ?? 0) + rest <= available { return .shared }
        return widths.reduce(0, +) + rest <= available ? .own : .stacked
    }

    private func answersLayout(for width: CGFloat) -> AnswerLayout {
        Self.answerLayout(widths: buttons.map(\.width), menu: answersMenu ? answerSplit.intrinsicContentSize.width : nil,
                          available: width - Self.pad * 2, gap: Self.buttonGap)
    }

    private func answersHeight(for width: CGFloat) -> CGFloat {
        guard answersLayout(for: width) == .stacked else { return Self.buttonHeight }
        let count = CGFloat(buttons.count + (answersMenu ? 1 : 0))
        return count * Self.buttonHeight + (count - 1) * Self.buttonGap
    }

    /// The width it asks for: the answers side by side, or the Remember row on one line.
    private var answersWidth: CGFloat {
        let views = answerViews(.shared)
        let answers = views.reduce(0) { $0 + $1.width } + Self.buttonGap * CGFloat(max(0, views.count - 1))
        let option = remember.isHidden ? pickersWidth : remember.fittingWidth
        return max(answers, textX - Self.pad + option)
    }

    private func height(for width: CGFloat) -> CGFloat {
        let header = Self.pad + max(Self.iconSide, textHeight(for: width))
        let waiting = Self.waitingLine(questionsWaiting: questionsWaiting) == nil ? 0
                                                                                 : moreWaiting.lineHeight + Tokens.Space.x2
        return header + optionHeight(for: width) + Self.answersGap + answersHeight(for: width) + waiting + Self.pad
    }

    /// The split button's frame reaches past its pill, for a finger.
    private func place(_ view: NSView, _ rect: NSRect) {
        if let split = view as? SplitPillButton { split.pillFrame = rect } else { view.frame = rect }
    }

    private func layoutContent() {
        let pad = Self.pad, w = bounds.width
        let textWidth = textWidth(for: w)
        let th = textHeight(for: w)
        let cs = closeButton.frame.size
        closeButton.frame.origin = NSPoint(x: w - Tokens.Space.x2 - cs.width, y: Tokens.Space.x2)
        let header = max(Self.iconSide, th)
        badge.frame = NSRect(x: pad, y: pad + (header - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide)
        picture.frame = badge.frame
        let top = pad + (header - th) / 2
        request.frame = NSRect(x: textX - Label.inset, y: top, width: textWidth + Label.inset * 2, height: wrappedHeight(request, width: textWidth))
        asker.frame = NSRect(x: textX - Label.inset, y: request.frame.maxY + 2, width: textWidth + Label.inset * 2, height: wrappedHeight(asker, width: textWidth))
        var y = pad + header
        let optionWidth = optionWidth(for: w)
        if !remember.isHidden {
            y += Self.optionGap
            let h = remember.height(for: optionWidth)
            remember.frame = NSRect(x: textX, y: y, width: min(optionWidth, remember.fittingWidth), height: h)
            y += h
        } else if !pickers.isEmpty {
            y += Self.optionGap
            let oneRow = pickersWidth <= optionWidth
            var x = textX
            for (i, picker) in pickers.enumerated() {
                let size = picker.intrinsicContentSize
                if !oneRow, i > 0 { x = textX; y += Tokens.Page.controlHeight + Self.buttonGap }
                picker.frame = NSRect(x: x, y: y, width: min(size.width, optionWidth), height: Tokens.Page.controlHeight)
                x += size.width + Self.buttonGap
            }
            y += Tokens.Page.controlHeight
        }
        y += Self.answersGap
        let available = w - pad * 2
        let layout = answersLayout(for: w)
        let views = answerViews(layout)
        switch layout {
        case .shared, .own:
            var x = w - pad
            for (view, width) in views.reversed() {
                // A lone answer wider than the card takes the row.
                let bw = min(width, available)
                x -= bw
                place(view, NSRect(x: x, y: y, width: bw, height: Self.buttonHeight))
                x -= Self.buttonGap
            }
        case .stacked:
            var row = y
            for (view, _) in views.reversed() {
                place(view, NSRect(x: pad, y: row, width: available, height: Self.buttonHeight))
                row += Self.buttonHeight + Self.buttonGap
            }
        }
        y += answersHeight(for: w)
        let waiting = Self.waitingLine(questionsWaiting: questionsWaiting)
        moreWaiting.isHidden = waiting == nil
        if let waiting {
            moreWaiting.stringValue = waiting
            moreWaiting.frame = NSRect(x: pad, y: y + Tokens.Space.x2, width: available, height: moreWaiting.lineHeight)
        }
    }
}
