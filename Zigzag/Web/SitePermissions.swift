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

/// Answers given to a site's question, kept for the page that asked only: its tab, until it loads another page or
/// reloads. That's what Ask means, as in Safari: asked again on every visit, never "asked once, then allowed for good".
/// Allow and Block are what's kept for the site, chosen in Site Controls or Settings › Privacy. Kept as action ids, so
/// a question whose answers aren't just yes or no (a handoff rule's "browser" or "handOff") holds for the page too.
struct PagePermissionAnswers {
    private var answers: [String: String] = [:]

    /// `key` is what the answer is for (`SitePermissions.answerKey`), `kind` what was asked ("camera", "location"…).
    mutating func note(_ allowed: Bool, key: String, kind: String) { note(allowed ? "allow" : "deny", key: key, kind: kind) }

    /// The action chosen, as its own id. `key` is what the answer is for (`SitePermissions.answerKey`), `kind` what was
    /// asked ("camera", "location", "handoff:<rule UUID>"…).
    mutating func note(_ action: String, key: String, kind: String) { answers["\(key)|\(kind)"] = action }

    /// The answer given for `kind` on this page, if any. The camera and the microphone are separate permissions: an
    /// answer given to both at once, from before the split, is not read as either.
    func answer(key: String, kind: String) -> Bool? { answers["\(key)|\(kind)"].map { $0 == "allow" } }

    /// The action chosen, as its own id: a handoff's target, or an allow or deny.
    func action(key: String, kind: String) -> String? { answers["\(key)|\(kind)"] }

    mutating func forget() { answers = [:] }

    var isEmpty: Bool { answers.isEmpty }
}

/// Camera, microphone, location, notification, pop-up and open-an-app decisions, remembered per origin (see
/// `SiteOrigin`), stored as an action id under "origin|subject". Site Controls and Settings still expose Allow and
/// Block; a question's one-time answer holds for the page that asked (`PagePermissionAnswers`). Asked in a sheet,
/// never as a surprise popup.
enum SitePermissions {
    private static let key = "SitePermissions"
    /// Where the answers are kept; tests use their own.
    static var defaults: UserDefaults = .standard

    private static var stored: [String: String] {
        get {
            var actions: [String: String] = [:]
            for (key, value) in defaults.dictionary(forKey: key) ?? [:] {
                if let action = value as? String { actions[key] = action }
                else if let allowed = value as? Bool { actions[key] = allowed ? legacyYes(forKey: key) : "deny" }
            }
            return actions
        }
        set {
            // A plain yes or no is written the way builds before the card read it, a Bool, so going back to one
            // loses no permission. Every other answer is an action id that only this build understands, and stays
            // a string. A store of nothing but yeses and nos is therefore a [String: Bool] an older build reads whole.
            var values: [String: Any] = [:]
            for (key, action) in newValue {
                switch action {
                case "allow": values[key] = true
                case "deny": values[key] = false
                case "automatic" where key.hasSuffix("|" + PermissionSubject.popups): values[key] = true
                default: values[key] = action
                }
            }
            defaults.set(values, forKey: key)
        }
    }

    /// The kinds a request is kept under, in the order they are asked: a call's camera and microphone is two
    /// permissions now, so it is two questions.
    static func mediaTypes(for type: WKMediaCaptureType) -> [WKMediaCaptureType] {
        switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
    }

    /// A legacy `true` becomes the subject's ordinary yes, which is not "allow" for every subject: the answer a site's
    /// pop-ups are kept under is a destination ("automatic", "mini", "thisTab", "newTab") or "deny", never "allow".
    /// An old `true` there meant pop-ups opened as they always had, a real tab for a plain `window.open` and a real
    /// pop-up for a sized one, which is "automatic". Everywhere else a yes is "allow".
    private static func legacyYes(forKey key: String) -> String {
        key.hasSuffix("|" + PermissionSubject.popups) ? "automatic" : "allow"
    }

    /// Converts any answers written by the old Bool store in place, and the old combined camera-and-microphone key
    /// into the two questions the split asks. Reading also understands them, so this is safe to run once at launch
    /// and harmless to run again.
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

    /// Writes down what a question was answered. "Always" is kept for the site, under `origin` and `subject`; anything
    /// else, and everything a private window answers, holds for `tab`'s page only. A private window keeps nothing at
    /// all, whatever the answer says, which is why it must say so here rather than be trusted to have masked it.
    /// Returns whether the answer allows what was asked (`action` other than "deny").
    @discardableResult
    static func rememberAnswer(_ answer: PermissionAnswer, subject: String, origin: String, tab: Tab?, isPrivate: Bool) -> Bool {
        // The tab knows best: a caller that forgets to pass its own privacy is still not allowed to store.
        let keepsNothing = isPrivate || (tab?.isPrivate ?? false)
        if answer.remember, !keepsNothing {
            remember(answer.action, subject: subject, origin: origin)
        } else if let tab {
            tab.permissionAnswers.note(answer.action, key: origin, kind: subject)
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

    /// One answer kept for the camera and the microphone together becomes one for each: the same answer for both,
    /// never the other way round, and a kind's own answer wins. Runs at launch after `migrateHostOnlyAnswers`;
    /// running again on a key that somehow survives finds nothing to do.
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

    /// An answer found while a question waited: a site's persistent answer wins; a page's answer is only this time.
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
        // Sorted, so the camera comes before the microphone whatever order the store returns.
        return keys(["camera", "microphone"], on: origin).sorted().compactMap { allowed(now[$0]) }
    }

    /// Location answers given on a site's page, its frames' included.
    static func locationDecisions(origin: String) -> [Bool] {
        let now = stored
        return keys(["location"], on: origin).compactMap { allowed(now[$0]) }
    }

    /// What is kept for `type`: its own answer. A request for the camera and the microphone together is answered only
    /// when both are kept, and a no in either is a no.
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

    static func forgetAll() { defaults.removeObject(forKey: key) }

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

    /// Pop-ups a site opens on its own: allowed once you've said Always Allow, blocked (nil or false) otherwise. The
    /// yes is kept as the destination it means — "automatic", the ordinary pop-up routing of a real tab or a real
    /// window — not as a bare "allow", which is no destination. The card's own answers name This Tab, New Tab or Mini.
    static func popups(origin: String) -> Bool { allowed(action(PermissionSubject.popups, origin: origin)) == true }

    static func setPopups(_ allowed: Bool?, origin: String) {
        remember(allowed.map { $0 ? "automatic" : "deny" }, subject: PermissionSubject.popups, origin: origin)
    }

    /// WebRTC (`WebRTCProtection`): Allow or Block kept for the site, nil to follow the setting.
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

    /// What Site Controls shows for a permission: Ask with nothing kept, Allow when every answer kept says yes,
    /// otherwise Block. Pop-ups are blocked with a notice until allowed, so for them Ask is the start.
    /// WebRTC is never Ask: with nothing kept it's what the setting says (`WebRTCProtection`).
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

    /// The permissions Site Controls has a row for on this site: once it asked this session, or once something is
    /// kept for it. Notifications and pop-ups aren't offered in a private window, which never shows or allows them.
    /// WebRTC has its row on every site while Settings › Privacy keeps it off, so a site that needs it for calls can
    /// be allowed before it tries; and none where WebKit has no switch for it.
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

    /// Whether the site has an answer of its own for `permission`, kept or asked for this session (`here`: a private
    /// tab's own WebRTC choice), rather than only the setting every site follows. With the protection on, WebRTC's row
    /// shows for every site so you can allow it before a call, but it's the site's only once chosen there or asked.
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

    /// Why a question's duration control is dimmed when there is no site to keep an answer under.
    private static var noSiteNote: String {
        String(localized: "This page has no site to remember the answer for.", comment: "Tooltip of the disabled duration dropdown on a permission question asked by a page with no site, like a local file.")
    }

    /// The site's notification answer on `tab`'s page: Allow or Block kept for the site, else the answer given on
    /// this page.
    static func notifications(origin: String, tab: Tab?) -> Bool? {
        notifications(origin: origin) ?? tab?.permissionAnswers.answer(key: origin, kind: "notifications")
    }

    /// Asked like the camera, the answer kept for the page that asked. A private window never shows them anyway.
    static func requestNotifications(origin: String, window: NSWindow?, isPrivate: Bool, tab: Tab? = nil) async -> Bool? {
        if let known = notifications(origin: origin, tab: tab) { return known }
        guard let controller = WindowManager.shared.promptHost(for: window) else { return nil }
        let answer = await PermissionPrompt.ask(host: askerName(origin), origin: origin, answerKey: origin, what: "notifications", symbol: "bell.fill", in: controller, tab: tab,
                                                title: String(localized: "Show notifications", comment: "A site's permission question, without its question mark. The site wants to show notifications."),
                                                actions: [.deny, .allow], canRemember: true,
                                                answered: {
                                                    knownAnswer(site: notifications(origin: origin),
                                                                page: tab?.permissionAnswers.answer(key: origin, kind: "notifications"))
                                                })
        guard let answer else { return nil }
        return rememberAnswer(answer, subject: PermissionSubject.notifications, origin: origin, tab: tab, isPrivate: isPrivate)
    }

    /// The location answer for `key` on `tab`'s page: Allow or Block kept, else the answer given on this page.
    private static func location(key: String, tab: Tab?) -> Bool? {
        location(origin: key) ?? tab?.permissionAnswers.answer(key: key, kind: "location")
    }

    /// The camera or microphone answer for `key` on `tab`'s page: Allow or Block kept, else the answer given on
    /// this page.
    private static func decision(key: String, type: WKMediaCaptureType, tab: Tab?) -> Bool? {
        decision(origin: key, type: type) ?? tab?.permissionAnswers.answer(key: key, kind: kind(type))
    }

    /// Location, asked the same way as the camera. A page with no origin to keep it under (file:) is asked every time.
    static func requestLocation(origin securityOrigin: WKSecurityOrigin, window: NSWindow?, isPrivate: Bool, tab: Tab? = nil) async -> WKPermissionDecision {
        let frame = SiteOrigin.of(securityOrigin), page = page(of: tab, frame: frame)
        let key = answerKey(frame: frame, page: page)
        if let key, let known = location(key: key, tab: tab) { return known ? .grant : .deny }
        noteAsked(.location, origin: page, isPrivate: isPrivate)
        guard let controller = WindowManager.shared.promptHost(for: window) else { return .deny }
        let answer = await PermissionPrompt.ask(host: askerName(frame: frame, page: page), origin: page, answerKey: key, what: "your location",
                                                symbol: "location.fill", in: controller, tab: tab,
                                                title: String(localized: "Use your location", comment: "A site's permission question, without its question mark."),
                                                actions: [.deny, .allow], canRemember: key != nil, rememberNote: key == nil ? noSiteNote : nil,
                                                answered: {
                                                    key.flatMap { key in
                                                        knownAnswer(site: location(origin: key),
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
        // Every kind already answered for the site or this page: no question.
        if let key, types.allSatisfy({ decision(key: key, type: $0, tab: tab) != nil }) {
            return types.allSatisfy { decision(key: key, type: $0, tab: tab) == true } ? .grant : .deny
        }
        guard let controller = WindowManager.shared.promptHost(for: window) else {
            // Nowhere to ask (a sign-in popup): say no this time, without remembering it, but the site did ask, so
            // Site Controls has a row to allow it from.
            for type in types where key.flatMap({ decision(key: $0, type: type, tab: tab) }) == nil {
                noteAsked(type == .microphone ? .microphone : .camera, origin: page, isPrivate: isPrivate)
            }
            return .deny
        }
        // A no already kept for either kind (Blocked in Site Controls, or answered on this page) settles it: the call
        // can't go ahead, so the other isn't asked about for nothing.
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
            // Never in `types`: a request for both is the two questions above, in turn.
            case .cameraAndMicrophone: continue
            @unknown default: continue
            }
            // The two questions in a row take their turns like any others (`PageQuestions`): the second comes up only
            // after the first has gone.
            let answer = await PermissionPrompt.ask(host: askerName(frame: frame, page: page), origin: page, answerKey: key, what: what,
                                                    symbol: type == .microphone ? "mic.fill" : "video.fill", in: controller, tab: tab, title: title,
                                                    actions: [.deny, .allow], canRemember: key != nil, rememberNote: key == nil ? noSiteNote : nil,
                                                    answered: {
                                                        key.flatMap { key in
                                                            knownAnswer(site: decision(origin: key, type: type),
                                                                        page: tab?.permissionAnswers.answer(key: key, kind: kind(type)))
                                                        }
                                                    })
            // Only a clicked answer holds for the page; Esc, or the window closing, is "not now".
            guard let answer else { return .deny }
            let isAllowed = key.map { rememberAnswer(answer, subject: PermissionSubject.media(type), origin: $0, tab: tab, isPrivate: isPrivate) }
                ?? (answer.action != "deny")
            // No to one is no to the call: the other isn't asked.
            if !isAllowed { return .deny }
            allowed = allowed && isAllowed
        }
        return allowed ? .grant : .deny
    }

    /// Screen sharing (getDisplayMedia): Don't Allow, Share Screen…, then Share Window… filled, as Safari offers them;
    /// either share hands over to macOS's own picker (ScreenCaptureKit's) for a window or a display, where you pick
    /// which — so even an answer kept for the site does not capture anything without macOS asking.
    ///
    /// Answered like every other question: **"Always" keeps it for the site, a no included, and "This time" holds for
    /// the page.** It used to be asked every single time with nothing kept, which made it the one card where the same
    /// two answers meant something different from every other card's.
    static func requestDisplayCapture(origin securityOrigin: WKSecurityOrigin, window: NSWindow?, tab: Tab?) async -> DisplayCaptureChoice {
        let frame = SiteOrigin.of(securityOrigin), page = page(of: tab, frame: frame)
        // Kept under the same key every other question uses: the page's own site, or a frame from another site
        // scoped to that page — never the frame's origin on its own, which would follow it to every page.
        let key = answerKey(frame: frame, page: page)
        let isPrivate = tab?.isPrivate ?? false
        guard let controller = WindowManager.shared.promptHost(for: window) else {
            noteAsked(.screen, origin: page, isPrivate: isPrivate)
            return .deny
        }
        // Already answered for the site, or for this frame on this page: go the same way without asking again.
        if let key, let kept = screenAnswer(key: key, tab: tab) {
            return DisplayCaptureChoice(kept)
        }
        noteAsked(.screen, origin: page, isPrivate: isPrivate)
        // Only a secure page can keep an answer, and only its own origin: a frame from another site may ask this
        // time, but where its page's screen sharing goes is the page's to keep, not the frame's.
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

    /// A screen-sharing answer already given, for a question to skip itself: the site's kept choice, then the page's.
    private static func screenAnswer(key: String, tab: Tab?) -> PermissionAnswer? {
        if let kept = DisplayCaptureChoice(action: SitePermissions.action(PermissionSubject.screen, origin: key)) {
            return PermissionAnswer(action: kept.action, remember: true)
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

    /// From the prompt: Allow is its filled answer, Share Screen… the other way, anything else is no.
    init(_ answer: PermissionAnswer?) {
        switch answer?.action {
        case "allow": self = .window
        case "screen": self = .screen
        default: self = .deny
        }
    }

    /// What it's kept as, in the same place every other permission answer is kept. "allow" is the filled answer's id,
    /// which means Share Window…, so a kept window is the same answer the button gives.
    var action: String {
        switch self {
        case .deny: "deny"
        case .screen: "screen"
        case .window: "allow"
        }
    }

    /// The answer this was kept as, or nil where nothing has been kept.
    init?(action: String?) {
        switch action {
        case "deny": self = .deny
        case "screen": self = .screen
        case "allow", "window": self = .window
        default: return nil
        }
    }

    static var title: String { String(localized: "Share your screen", comment: "Title of the prompt when a site asks to share the screen.") }

    /// Don't Allow, Share Screen…, then Share Window… filled, as Safari offers them.
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

/// What a site can ask for, as Site Controls has a row for each. The camera and the microphone are separate
/// permissions, so a call asks for each and can have a row for each.
enum SitePermission: String, CaseIterable {
    case camera, microphone, location, notifications, popups, apps, webRTC, screen
    /// The kinds of answer kept for it.
    var kinds: [String] {
        switch self {
        case .camera: ["camera"]
        case .microphone: ["microphone"]
        case .location: ["location"]
        case .notifications: ["notifications"]
        case .popups: ["popups"]
        case .apps: ["apps"]
        case .webRTC: ["webRTC"]
        case .screen: ["screen"]
        }
    }

    /// What its dropdown offers. WebRTC is never asked about first: a page has it as it loads or not at all, so it's
    /// Allow or Block, and with nothing chosen, what the setting says.
    var choices: [PermissionChoice] { self == .webRTC ? [.allow, .block] : PermissionChoice.allCases }

    /// The one kind a choice made in Site Controls is kept as.
    var primaryKind: String { rawValue }

    /// A private window asks for the camera and the microphone, location and apps to open (and keeps nothing); it
    /// never shows notifications or opens pop-ups on its own. WebRTC follows the setting there, chosen for the tab
    /// alone.
    var inPrivate: Bool { self == .camera || self == .microphone || self == .location || self == .apps || self == .webRTC || self == .screen }

    var title: String {
        switch self {
        case .camera: String(localized: "Camera", comment: "Row in the site panel's This Site group.")
        case .microphone: String(localized: "Microphone", comment: "Row in the site panel's This Site group.")
        case .location: String(localized: "Location", comment: "Row in the site panel's This Site group.")
        case .notifications: String(localized: "Notifications", comment: "Row in the site panel's This Site group.")
        case .popups: String(localized: "Pop-ups", comment: "Row in the site panel's This Site group.")
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

/// "Use your location?", at the top of the page that asked, sliding down from its top edge: the question, the site
/// under it, and two answers, Allow last and filled. The answer holds for the page that asked; Allow or Block for good
/// is chosen in the site panel or Settings › Privacy. Not answering is easy: the close button, Esc, or a click anywhere else puts
/// it off ("not now"), and so does the tab going to another site. One question at a time per window. It belongs
/// to the tab that asked: it steps aside while another tab is in front and comes back with that tab.
final class PermissionPrompt: FloatingPanelView {
    /// The app's own icon when it's an app that would open, else the request's symbol on a soft circle.
    private let picture = NSImageView()
    private let badge = ColorView(color: .clear)
    private let request = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    private let asker = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let closeButton = IconButton(symbol: "xmark", toolTip: String(localized: "Not Now", comment: "Tooltip of the × on a site's permission question."))
    private let duration = DropdownButton()
    /// Answers of the same kind, offered as one dropdown rather than a button each (where a pop-up opens): choosing
    /// one answers the question, so the card stays a line.
    private let answerMenu = DropdownButton()
    private var menuChoices: [PermissionAction] = []
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
    /// Deny first, alternatives in the middle, and the prominent answer last.
    private var buttons: [(button: InteractiveView, width: CGFloat)] = []
    private var answer: ((PermissionAnswer?) -> Void)?
    private var monitor: Any?
    /// The tab whose page asked, and the window it's in.
    private weak var askingTab: Tab?
    /// Asked once more just before the card comes up: while it waited behind another, the page may have been answered,
    /// and an answer already given is not asked for twice.
    var recheck: (() -> PermissionAnswer?)?
    private weak var controller: PromptHost?
    private var tabsToken: SignalToken?
    private var waitingToken: SignalToken?
    /// Others waiting their turn in this window, under the answers: there only while there are any.
    private let moreWaiting = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    /// How many questions are waiting in this window, this one counted, as last read.
    private var questionsWaiting = 1

    /// How many other questions are about in this window, or nothing when this is the only one.
    static func waitingBehind(questionsWaiting: Int) -> Int? {
        questionsWaiting > 1 ? questionsWaiting - 1 : nil
    }

    /// What the card says under its answers while other questions are about in the same window. "Other" rather than
    /// "behind": two panes of a split can show a card each, and neither is waiting behind the other.
    static func waitingLine(questionsWaiting: Int) -> String? {
        guard let behind = waitingBehind(questionsWaiting: questionsWaiting) else { return nil }
        return String(localized: "Other questions in this window: \(behind)", comment: "A line on a site's permission question when another question is also about in the same window, on this page or another pane of a split.")
    }

    /// The question on screen in each window, so it can follow the sidebar.
    private static var shown: [ObjectIdentifier: PermissionPrompt] = [:]
    /// Questions being asked right now, by page and request, so the same one asked twice waits for the first answer.
    private static var inFlight: [String: (id: UUID, task: Task<PermissionAnswer?, Never>)] = [:]
    /// Questions asked in each window that have not been answered yet: one is on screen, the rest wait their turn.
    /// A question is asked one at a time in a window (see `ask`'s chain), so the card that is up can say how many
    /// are behind it instead of stacking a card each.
    private static var waiting: [ObjectIdentifier: Int] = [:]
    /// Sent whenever a window's count changes, so a card on screen can say what is behind it.
    static let waitingChanged = Signal<Void>()

    /// Questions waiting their turn in this window, the one on screen included.
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
        let old = prompt.frame
        prompt.place(in: controller)
        let dx = old.minX - prompt.frame.minX, dy = old.minY - prompt.frame.minY
        // Dragging the window's edge, it simply stays with the page; gliding there would trail behind.
        guard abs(dx) > 0.5 || abs(dy) > 0.5, !Tokens.Motion.reduceMotion, controller.window?.inLiveResize != true,
              let layer = prompt.layer else { return }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(dx, dy, 0))
        move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        move.duration = slide ?? Tokens.Motion.standard
        move.timingFunction = slide == nil ? Tokens.Motion.drawer : timing
        move.fillMode = .backwards
        layer.add(move, forKey: "follow")
    }

    /// Deny leads, plain alternatives keep their order, and the ordinary affirmative is last and prominent.
    static func actions(for actions: [PermissionAction]) -> [PermissionAction] {
        let ordered = actions.filter(\.isDeny) + actions.filter { !$0.isDeny && !$0.isProminent } + actions.filter { !$0.isDeny && $0.isProminent }
        return ordered.enumerated().map { index, action in
            PermissionAction(id: action.id, title: action.title, isDeny: action.isDeny,
                             isProminent: !action.isDeny && index == ordered.count - 1)
        }
    }

    /// `title` is the request ("Use your camera" by default). `icon` stands in for the symbol (an app's icon).
    /// `answered` is checked once it's this request's turn: the same question may have been answered meanwhile.
    /// `tab` is the tab whose page asked; without one, it's the tab in front when the question comes up.
    /// `host` is how the site is named in the question; `origin`, when given, is the site it's for (`SiteOrigin`).
    /// `answerKey`, when the asker has one, is the frame-and-page key its answer is kept under (`SitePermissions.answerKey`):
    /// two frames on one page are two askers.
    /// `menu` is answers of one kind offered as a single dropdown after the buttons (where a pop-up opens); choosing
    /// one answers the question, and it stands in as the question's own filled answer.
    /// The duration choice is This time unless `canRemember` offers Always on this site. A disabled choice keeps
    /// `rememberNote` as its explanation. Nil means Not Now.
    static func ask(host: String, origin: String? = nil, answerKey: String? = nil, what: String, symbol: String, icon: NSImage? = nil,
                    in controller: PromptHost, tab: Tab? = nil, title: String? = nil,
                    actions: [PermissionAction] = [.deny, .allow], menu: [PermissionAction] = [],
                    canRemember: Bool = true, rememberNote: String? = nil,
                    answered: @escaping () -> PermissionAnswer? = { nil }) async -> PermissionAnswer? {
        // A private window never offers or returns Always.
        let remembers = canRemember && !controller.promptIsPrivate
        // Answered already: nothing to show, and nothing to mark.
        if let known = answered() {
            return PermissionAnswer(action: known.action, remember: known.remember && remembers)
        }
        let request = title ?? String(localized: "Use \(what)", comment: "A site's permission question, without its question mark. Only for a request no caller words itself; the placeholder is in English.")
        let asking = tab ?? controller.promptFrontTab
        // The same question, asked again while its card is up: wait for that one answer instead of stacking a second
        // card. Only the same tab and frame's, though: another tab of the site, a frame from elsewhere on the page,
        // or a private window asks for itself rather than taking an answer meant for someone else.
        let sharedKey = Self.questionKey(origin: origin, answerKey: answerKey, tabID: asking?.id,
                                         isPrivate: tab?.isPrivate ?? controller.promptIsPrivate,
                                         window: ObjectIdentifier(controller), request: request)
        if let before = inFlight[sharedKey] {
            let known = await before.task.value
            return known.map { PermissionAnswer(action: $0.action, remember: $0.remember && remembers) }
        }
        // One of the window's waiting questions from the moment it is asked, even if it cannot be shown yet: the tab
        // wears the marker, the card that is up counts it, and another tab's question is not held behind this one.
        // The cards themselves take turns where they would be seen (`PageQuestions`), so no second queue is needed.
        let token = UUID()
        let task = Task<PermissionAnswer?, Never> { @MainActor in
            let questionID = UUID()
            if let asking {
                PendingQuestions.enqueue(.init(id: questionID, tabID: asking.id, origin: origin, title: request))
            }
            setWaiting(questionsWaiting(in: controller) + 1, in: controller)
            let answer = await show(host: host, request: request,
                                  symbol: symbol, icon: icon, actions: actions, menu: menu, canRemember: remembers, rememberNote: rememberNote,
                                  origin: origin, in: controller, tab: tab, answered: answered)
            // Answered or put off: it is no longer one of the window's waiting questions.
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

    /// What makes two questions the same one. The window and the tab keep one tab's question from answering another's;
    /// the frame's own answer key keeps two frames on a page, or two sites in one tab, apart; privacy keeps a private
    /// window's question its own. The request itself is last, so two different questions in one frame still stack.
    static func questionKey(origin: String?, answerKey: String?, tabID: UUID?, isPrivate: Bool,
                            window: ObjectIdentifier, request: String) -> String {
        "\(window)|\(tabID?.uuidString ?? "no tab")|\(isPrivate ? "private" : "shared")|\(answerKey ?? origin ?? "no site")|\(request)"
    }

    private static func show(host: String, request: String, symbol: String, icon: NSImage?, actions: [PermissionAction],
                             menu: [PermissionAction], canRemember: Bool, rememberNote: String?, origin: String?, in controller: PromptHost, tab: Tab?,
                             answered: @escaping () -> PermissionAnswer? = { nil }) async -> PermissionAnswer? {
        // Never under What's New, where it couldn't be seen: it waits until the notes close.
        await withCheckedContinuation { continuation in
            WhatsNewSheet.afterClosing(in: controller.window) { continuation.resume() }
        }
        // The window is gone (its tab with it): there is nowhere this question could ever be shown. A window that is
        // only hidden, minimized or on another Space still holds its question: the card is put up there, and is
        // waiting when the window comes back. Nothing is denied just because it could not be seen this second.
        guard controller.window != nil else { return nil }
        // The asking tab closed while an earlier question waited.
        if let tab, tab.isClosed { return nil }
        let asking = tab ?? controller.promptFrontTab
        // In the space's own color, like every other button in the window.
        let accent = controller.promptAccent
        return await withCheckedContinuation { continuation in
            let prompt = PermissionPrompt(frame: .zero)
            prompt.request.stringValue = String(localized: "\(request)?", comment: "A site's permission question: the request, then a question mark, like “Use your camera?”.")
            prompt.asker.stringValue = host.withoutWWW
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
            prompt.duration.isEnabled = canRemember
            if !canRemember {
                prompt.duration.toolTip = rememberNote ?? (controller.promptIsPrivate
                    ? String(localized: "Private windows don’t remember answers.", comment: "Tooltip of the disabled duration dropdown on a permission question in a private window.")
                    : String(localized: "This site can’t remember this answer.", comment: "Tooltip of the disabled duration dropdown on a permission question whose answer cannot be kept."))
            }
            let row = Self.actions(for: actions).map { action -> PillButton in
                let button = PillButton(title: action.title, style: action.isProminent ? .prominent : .plain)
                if action.isProminent { button.tint = accent }
                button.onClick = { [weak prompt] _ in
                    guard let prompt, action.isDeny || prompt.acceptsAllow else { return }
                    prompt.finish(PermissionAnswer(action: action.id, remember: canRemember && prompt.duration.selectedIndex == 1))
                }
                return button
            }
            for button in row { prompt.addSubview(button) }
            prompt.addSubview(prompt.moreWaiting)
            // Side by side at one width, as a Mac dialog sets its answers.
            let width = max(row.map(\.fittingWidth).max() ?? 0, Tokens.Dialog.minButtonWidth)
            prompt.buttons = row.map { ($0 as InteractiveView, width) }
            // Answers of one kind (where a pop-up opens), one dropdown instead of a button each: it stands in as the
            // question's own filled answer, and choosing from it answers, as clicking a button does.
            if !menu.isEmpty {
                prompt.menuChoices = menu
                prompt.answerMenu.options = menu.map { DropdownButton.Option(title: $0.title) }
                prompt.answerMenu.look = .primary
                prompt.answerMenu.tint = accent
                prompt.answerMenu.onSelect = { [weak prompt] index in
                    guard let prompt, prompt.acceptsAllow, menu.indices.contains(index) else { return }
                    prompt.finish(PermissionAnswer(action: menu[index].id, remember: canRemember && prompt.duration.selectedIndex == 1))
                }
                prompt.addSubview(prompt.answerMenu)
            }
            prompt.setAccessibilityLabel(String(localized: "\(host): \(request)?", comment: "VoiceOver label of a site's permission question: the site, then its request, like “zoom.us: Use your camera?”."))
            prompt.answer = { response in
                continuation.resume(returning: response)
            }
            prompt.askingTab = asking
            prompt.recheck = answered
            prompt.controller = controller
            // How many are waiting in this window, and told again whenever that changes: a question asked while this
            // one is up waits its turn behind it, and the card says so rather than stacking a card of its own.
            prompt.questionsWaiting = Self.questionsWaiting(in: controller)
            prompt.waitingToken = Self.waitingChanged.observe { [weak prompt] in prompt?.refreshWaiting() }
            controller.promptOverlay.addSubview(prompt)
            prompt.isHidden = true
            prompt.tabsToken = controller.observePromptTabs { [weak prompt] in prompt?.followTab() }
            // The tab went to another site: this question was that site's, so it's put off.
            prompt.urlToken = asking?.changed.observe { [weak prompt, weak asking] change in
                guard change == .url, let prompt, let url = asking?.url else { return }
                if let origin = prompt.askingOrigin {
                    if SiteOrigin.of(url) != origin { prompt.finish(nil) }
                } else if let now = url.host(), now != prompt.askingHost {
                    prompt.finish(nil)
                }
            }
            // A click anywhere else, outside it and the address it hangs from, puts it off too.
            prompt.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak prompt, weak controller] event in
                guard let prompt, !prompt.isHidden, event.window === prompt.window else { return event }
                // The command bar over it has its own clicks.
                if controller?.promptIsCovered == true { return event }
                // The card's own dropdown is a menu panel in this window, drawn over the page and usually past the
                // card's lower edge: a click on it is a click on the card, never a click away (which would put the
                // question off instead of answering it).
                if let menu = MenuPanel.current, menu.window === prompt.window,
                   menu.bounds.contains(menu.convert(event.locationInWindow, from: nil)) { return event }
                let inside = prompt.bounds.contains(prompt.convert(event.locationInWindow, from: nil))
                let address = controller?.promptAnchor
                let onAddress = address.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
                if !inside && !onAddress { prompt.finish(nil) }
                return event
            }
            prompt.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak prompt, weak controller] event in
                guard let prompt, !prompt.isHidden, event.window === prompt.window else { return event }
                // Under notes or the command bar opened after it, Esc is theirs.
                if WhatsNewSheet.isShowing(in: prompt.window) || controller?.promptIsCovered == true { return event }
                // Esc puts it off. Return does nothing here: it belongs to whatever you're typing in.
                if event.keyCode == 53 { prompt.finish(nil); return nil }
                return event
            }
            // Last, once it listens: a tab already gone puts it off here, and that takes down what was just set up.
            prompt.followTab()
        }
    }

    /// Says how many others are waiting in this window, and takes the card's height with it — asked whenever a
    /// question is asked or answered while this one is up, so the card never says a count it no longer has.
    private func refreshWaiting() {
        guard let controller else { return }
        questionsWaiting = Self.questionsWaiting(in: controller)
        guard superview != nil, !isHidden else { return }
        place(in: controller)
        needsLayout = true
    }

    /// Shown while the asking tab is in front (either side of a split counts), set aside while another tab is,
    /// and "not now" once it's closed or has gone to another window.
    /// One question at a time at the top of the page (`PageQuestions`): in front while Save password? is up, it
    /// waits for that to go.
    func followTab() {
        guard answer != nil, let controller else { return }
        guard let tab = askingTab, !tab.isClosed, controller.promptHolds(tab) else { finish(nil); return }
        let inFront = controller.promptShows(tab)
        if inFront, isHidden {
            // While it waited, the page may have been answered another way: an answer already given is not asked
            // for twice.
            if let known = recheck?() { finish(known); return }
            // Placed first, hidden still: a question over another pane of a split doesn't hold it up (`PageQuestions`).
            place(in: controller)
            guard PageQuestions.mayShow(self, in: controller.promptOverlay) else { return }
            controller.clearForPrompt()
            isHidden = false
            // The question the window is showing, for anything that asks it (`isShowing`, the debug bridge).
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
        surfaceTint = nil
        tintStrength = nil
        isElevated = true
        radius = Tokens.Radius.panel
        let area = askingTab.flatMap { controller.pageFrame(showing: $0) } ?? controller.focusedPaneFrame
        // Wide enough for the buttons, the menu and the duration on one line, within the page's own measure.
        let measured = answersWidth + Self.pad * 2
        let width = min(max(Self.width, measured), min(Self.maxWidth, area.width - Tokens.Space.x6))
        frame = NSRect(x: round(area.midX - width / 2), y: area.minY + Tokens.Space.x3, width: width, height: height(for: width))
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
        duration.options = [
            DropdownButton.Option(title: String(localized: "This time", comment: "Duration choice on a site's permission question: the answer applies only to this page.")),
            DropdownButton.Option(title: String(localized: "Always on this site", comment: "Duration choice on a site's permission question: the answer is remembered for this site."))
        ]
        duration.selectedIndex = 0
        [badge, picture, request, asker, closeButton, duration].forEach { addSubview($0) }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func finish(_ choice: PermissionAnswer?) {
        // The disabled duration control also guards debug answers: a private or one-time question never returns Always.
        let choice = choice.map { PermissionAnswer(action: $0.action, remember: $0.remember && duration.isEnabled) }
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
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        tabsToken = nil
        urlToken = nil
        if let controller, Self.shown[ObjectIdentifier(controller)] === self {
            // Another question may still be up in this window: the slot names the one that is, not the one that went.
            Self.shown[ObjectIdentifier(controller)] = controller.promptOverlay.subviews
                .compactMap { $0 as? PermissionPrompt }
                .first { !$0.isHidden && $0 !== self }
        }
    }

    #if DEBUG
    /// For the debug bridge: answers the question showing in `host`, as its buttons would. Allow still waits out its
    /// first half second. Nil puts the question off.
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
    #endif

    private static let width: CGFloat = 420
    /// The widest a question is allowed to get: enough for the answers, the menu and the duration on one line.
    private static let maxWidth: CGFloat = 720
    private static let pad: CGFloat = 16
    private static let iconSide = Tokens.Dialog.iconSide
    private static let buttonHeight = DialogButtons.height
    private static let buttonGap = Tokens.Dialog.buttonGap

    private var textX: CGFloat { Self.pad + Self.iconSide + Tokens.Space.x3 }
    /// Room kept at the right of the text for the close button.
    private var closeRoom: CGFloat { Tokens.Metric.iconButton }

    private func requestHeight(for width: CGFloat) -> CGFloat {
        let textWidth = width - textX - Self.pad - closeRoom
        return ceil(request.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 200)).height ?? request.lineHeight)
    }

    private func textHeight(for width: CGFloat) -> CGFloat { requestHeight(for: width) + 2 + asker.lineHeight }

    private func height(for width: CGFloat) -> CGFloat {
        let header = Self.pad + max(Self.iconSide, textHeight(for: width))
        // One line of answers, or, where they don't fit, the duration on a row of its own above them.
        let answers = answersFit(in: width) ? Self.buttonHeight
                                             : Tokens.Page.controlHeight + Tokens.Space.x2 + Self.buttonHeight
        // A line under them while other questions wait their turn in this window.
        let waiting = Self.waitingLine(questionsWaiting: questionsWaiting) == nil ? 0
                                                                                 : moreWaiting.lineHeight + Tokens.Space.x2
        return header + Tokens.Space.x4 + answers + waiting + Self.pad
    }

    /// The answers side by side at one width, with the gaps between.
    private var buttonsWidth: CGFloat {
        buttons.reduce(0) { $0 + $1.width } + Self.buttonGap * CGFloat(max(0, buttons.count - 1))
    }

    /// The control after the buttons, where the question offers one: the answers of one kind, as a dropdown.
    private var menuWidth: CGFloat { menuChoices.isEmpty ? 0 : answerMenu.intrinsicContentSize.width + Self.buttonGap }

    /// ... then the duration, which every question offers (disabled where the answer can't be kept).
    private var durationWidth: CGFloat { duration.isHidden ? 0 : duration.intrinsicContentSize.width + Self.buttonGap }

    /// Everything on the answers' row, one line wide: the buttons, the menu and the duration.
    private var answersWidth: CGFloat { buttonsWidth + menuWidth + durationWidth }

    /// Whether they fit on the card's one line at `width`. Where they don't (Zigzag Mini, a narrow pane, longer
    /// translations), the duration takes the row above the buttons.
    private func answersFit(in width: CGFloat) -> Bool { answersWidth <= width - Self.pad * 2 }

    private func layoutContent() {
        let pad = Self.pad, w = bounds.width
        let textWidth = w - textX - pad - closeRoom
        let th = textHeight(for: w)
        let cs = closeButton.frame.size
        closeButton.frame.origin = NSPoint(x: w - Tokens.Space.x2 - cs.width, y: Tokens.Space.x2)
        let header = max(Self.iconSide, th)
        badge.frame = NSRect(x: pad, y: pad + (header - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide)
        picture.frame = badge.frame
        let top = pad + (header - th) / 2
        request.frame = NSRect(x: textX - Label.inset, y: top, width: textWidth + Label.inset * 2, height: requestHeight(for: w))
        asker.frame = NSRect(x: textX - Label.inset, y: request.frame.maxY + 2, width: textWidth + Label.inset * 2, height: asker.lineHeight)
        var y = pad + header + Tokens.Space.x4
        // One line, at the trailing edge: the buttons, then the menu, then the duration, as a Mac dialog sets its
        // answers. Where they don't fit, the duration takes the row above and the rest share the row below it.
        let oneLine = answersFit(in: w)
        if !oneLine, !duration.isHidden {
            let size = duration.intrinsicContentSize
            duration.frame = NSRect(x: w - pad - size.width, y: y, width: size.width, height: Tokens.Page.controlHeight)
            y = duration.frame.maxY + Tokens.Space.x2
        }
        let available = w - pad * 2
        // The buttons share what's left of the row after the menu, all the same width.
        let each = max(Tokens.Dialog.minButtonWidth,
                       (available - menuWidth - Self.buttonGap * CGFloat(max(0, buttons.count - 1))) / CGFloat(max(1, buttons.count)))
        var x = w - pad
        if oneLine {
            let size = duration.intrinsicContentSize
            x -= size.width
            duration.frame = NSRect(x: x, y: y, width: size.width, height: Tokens.Page.controlHeight)
            x -= Self.buttonGap
        }
        if !menuChoices.isEmpty {
            let size = answerMenu.intrinsicContentSize
            x -= size.width
            answerMenu.frame = NSRect(x: x, y: y, width: size.width, height: Tokens.Page.controlHeight)
            x -= Self.buttonGap
        }
        // More answers than the row holds: each takes an equal share of it.
        let even = !oneLine || buttonsWidth > available
        for (button, width) in buttons.reversed() {
            let bw = even ? each : width
            x -= bw
            button.frame = NSRect(x: x, y: y, width: bw, height: Self.buttonHeight)
            x -= Self.buttonGap
        }
        // What is waiting behind this one, under the answers: the card is a line taller while there is any.
        let waiting = Self.waitingLine(questionsWaiting: questionsWaiting)
        moreWaiting.isHidden = waiting == nil
        if let waiting {
            moreWaiting.stringValue = waiting
            moreWaiting.frame = NSRect(x: pad, y: y + Self.buttonHeight + Tokens.Space.x2,
                                       width: available, height: moreWaiting.lineHeight)
        }
    }
}
