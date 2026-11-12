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

/// Camera, microphone, location, notification, pop-up and open-an-app decisions, remembered per origin (see
/// `SiteOrigin`), stored as "origin|kind". Asked once, in a sheet, never as a surprise popup.
enum SitePermissions {
    private static let key = "SitePermissions"
    /// Where the answers are kept; tests use their own.
    static var defaults: UserDefaults = .standard

    private static var all: [String: Bool] {
        get { defaults.dictionary(forKey: key) as? [String: Bool] ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    private static func kind(_ type: WKMediaCaptureType) -> String {
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
        let before = all
        guard before.keys.contains(where: { !$0.contains("://") }) else { return }
        var after: [String: Bool] = [:]
        for (k, v) in before where k.contains("://") { after[k] = v }
        let denials: Set<String> = ["camera", "microphone", "cameraAndMicrophone", "location", "notifications"]
        for (k, v) in before where !k.contains("://") && !v {
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, denials.contains(parts[1]),
                  let origin = SiteOrigin.make(scheme: "https", host: parts[0], port: nil) else { continue }
            let migrated = "\(origin)|\(parts[1])"
            if after[migrated] == nil { after[migrated] = false }
        }
        all = after
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

    /// The keys for these kinds on a site's own page: its own answers and those of frames from elsewhere on it.
    private static func keys(_ kinds: [String], on origin: String) -> [String] {
        let suffixes = kinds.map { "|" + $0 }
        return all.keys.filter { k in
            kinds.contains { k == "\(origin)|\($0)" } || (k.hasPrefix(origin + "|embed:") && suffixes.contains { k.hasSuffix($0) })
        }
    }

    /// Camera and microphone answers given on a site's page: its own, and those of frames from elsewhere on it.
    static func mediaDecisions(origin: String) -> [Bool] {
        let now = all
        return keys(["camera", "microphone", "cameraAndMicrophone"], on: origin).compactMap { now[$0] }
    }

    /// Location answers given on a site's page, its frames' included.
    static func locationDecisions(origin: String) -> [Bool] {
        let now = all
        return keys(["location"], on: origin).compactMap { now[$0] }
    }

    /// A camera-only or microphone-only question takes the answer given to both at once (from a call, or chosen in
    /// Site Controls) when it has none of its own.
    static func decision(origin: String, type: WKMediaCaptureType) -> Bool? {
        let now = all
        return now["\(origin)|\(kind(type))"] ?? (type == .camera || type == .microphone ? now["\(origin)|cameraAndMicrophone"] : nil)
    }

    static func remember(_ allowed: Bool, origin: String, type: WKMediaCaptureType) { all["\(origin)|\(kind(type))"] = allowed }

    /// Every remembered answer for one site: kind ("camera", "location", "notifications"…) to allowed or not.
    static func choices(origin: String) -> [String: Bool] {
        var found: [String: Bool] = [:]
        for (k, v) in all where k.hasPrefix(origin + "|") { found[String(k.dropFirst(origin.count + 1))] = v }
        return found
    }

    /// Forgets everything about a site, notifications included.
    static func forgetEverything(origin: String) {
        var now = all
        for k in now.keys where k.hasPrefix(origin + "|") { now[k] = nil }
        all = now
    }

    /// Sites (origins) with a remembered choice of any kind.
    static var sites: Set<String> {
        Set(all.keys.compactMap { $0.split(separator: "|").first.map(String.init) })
    }

    static func forgetAll() { defaults.removeObject(forKey: key) }

    /// A site's answer about your location, if it ever asked.
    static func location(origin: String) -> Bool? { all["\(origin)|location"] }

    /// Frames from elsewhere on the site's page forget theirs too.
    static func forgetLocation(origin: String) {
        var now = all
        for k in keys(["location"], on: origin) { now[k] = nil }
        all = now
    }

    /// "Ask again" for the camera and microphone only: location, notifications and apps to open each have their own
    /// row, and stay as they are. Frames from elsewhere on the site's page forget theirs too.
    static func forget(origin: String) {
        var now = all
        for k in keys(["camera", "microphone", "cameraAndMicrophone"], on: origin) { now[k] = nil }
        all = now
    }

    /// Notifications: nil until the site has asked and you've answered.
    static func notifications(origin: String) -> Bool? { all["\(origin)|notifications"] }

    static func setNotifications(_ allowed: Bool?, origin: String) { all["\(origin)|notifications"] = allowed }

    /// Whether a site may open links for another app (zoommtg:, wemeet:) without asking: yes once you've said Open.
    static func opensApp(origin: String, scheme: String) -> Bool { all["\(origin)|app:\(scheme)"] == true }

    static func allowOpeningApp(origin: String, scheme: String) { all["\(origin)|app:\(scheme)"] = true }

    /// Pop-ups a site opens on its own: allowed once you've said Always Allow, blocked (nil) otherwise.
    static func popups(origin: String) -> Bool { all["\(origin)|popups"] == true }

    static func setPopups(_ allowed: Bool?, origin: String) { all["\(origin)|popups"] = allowed }

    /// Every site's notification choice by origin, for the page script: it knows the answer before the page asks.
    static var notificationDecisions: [String: Bool] {
        var out: [String: Bool] = [:]
        for (k, v) in all where k.hasSuffix("|notifications") { out[String(k.dropLast("|notifications".count))] = v }
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
    private static func keys(for permission: SitePermission, on origin: String) -> [String] {
        keys(permission.kinds, on: origin)
    }

    /// Whether anything is kept for `permission` on the site's page.
    static func hasDecision(_ permission: SitePermission, origin: String) -> Bool { !keys(for: permission, on: origin).isEmpty }

    /// What Site Controls shows for a permission: Ask with nothing kept, Allow when every answer kept says yes,
    /// otherwise Block. Pop-ups are blocked with a notice until allowed, so for them Ask is the start.
    static func choice(_ permission: SitePermission, origin: String) -> PermissionChoice {
        let now = all
        return PermissionChoice(answers: keys(for: permission, on: origin).compactMap { now[$0] })
    }

    /// Ask forgets every answer kept for it on the site's page, its frames' too. Allow or Block is kept for the site,
    /// for both camera and microphone at once, and for every frame from elsewhere that answered there before.
    static func setChoice(_ choice: PermissionChoice, for permission: SitePermission, origin: String) {
        var now = all
        let existing = keys(for: permission, on: origin)
        for k in existing { now[k] = nil }
        if let allowed = choice.allowed {
            // Frames from elsewhere keep a key of their own; the site's own answer is one key for the permission.
            for k in existing where k.hasPrefix(origin + "|embed:") { now[k] = allowed }
            now["\(origin)|\(permission.primaryKind)"] = allowed
        }
        all = now
        if permission == .notifications, choice != .allow { WebNotifications.shared.removeAll(origin: origin) }
    }

    /// The permissions Site Controls has a row for on this site: once it asked this session, or once something is
    /// kept for it. Notifications and pop-ups aren't offered in a private window, which never shows or allows them.
    static func shown(origin: String, isPrivate: Bool) -> [SitePermission] {
        SitePermission.allCases.filter { permission in
            if isPrivate, !permission.inPrivate { return false }
            return hasDecision(permission, origin: origin) || hasAsked(permission, origin: origin)
        }
    }

    /// Reset Permissions: the site back to how it started, as if it never asked. Every answer kept for it goes (its
    /// frames' and apps to open included), and its rows with them.
    static func reset(origin: String) {
        forgetEverything(origin: origin)
        asked = asked.filter { !$0.hasPrefix(origin + "|") }
        WebNotifications.shared.removeAll(origin: origin)
    }

    #if DEBUG
    /// For tests: forgets which sites asked this session.
    static func forgetAsked() { asked = [] }
    #endif

    /// What a question names the site as: its label, or "This page" for one with no origin.
    static func askerName(_ origin: String?) -> String {
        origin.map(SiteOrigin.label) ?? String(localized: "This page", comment: "Stands for the site in a question when the page has no host.")
    }

    /// Asked like the camera. A private window never remembers the answer, and never shows notifications anyway.
    static func requestNotifications(origin: String, window: NSWindow?, isPrivate: Bool, tab: Tab? = nil) async -> Bool? {
        if let known = notifications(origin: origin) { return known }
        guard let controller = WindowManager.shared.promptHost(for: window) else { return nil }
        let answer = await PermissionPrompt.ask(host: askerName(origin), origin: origin, what: "notifications", symbol: "bell.fill", in: controller, tab: tab,
                                                title: String(localized: "Show notifications", comment: "A site's permission question, without its question mark. The site wants to show notifications."),
                                                answered: { notifications(origin: origin).map { $0 ? .allow : .deny } })
        switch answer {
        case .allow, .deny:
            if !isPrivate { setNotifications(answer == .allow, origin: origin) }
            return answer == .allow
        case .notNow:
            return nil
        }
    }

    /// Location, asked and remembered the same way as the camera. A page with no origin to keep it under (file:)
    /// is asked every time.
    static func requestLocation(origin securityOrigin: WKSecurityOrigin, window: NSWindow?, isPrivate: Bool, tab: Tab? = nil) async -> WKPermissionDecision {
        let frame = SiteOrigin.of(securityOrigin), page = page(of: tab, frame: frame)
        let key = answerKey(frame: frame, page: page)
        if let key, let known = location(origin: key) { return known ? .grant : .deny }
        noteAsked(.location, origin: page, isPrivate: isPrivate)
        guard let controller = WindowManager.shared.promptHost(for: window) else { return .deny }
        let answer = await PermissionPrompt.ask(host: askerName(frame: frame, page: page), origin: page, what: "your location",
                                                symbol: "location.fill", in: controller, tab: tab,
                                                title: String(localized: "Use your location", comment: "A site's permission question, without its question mark."),
                                                answered: { key.flatMap { location(origin: $0) }.map { $0 ? .allow : .deny } })
        switch answer {
        case .allow, .deny:
            if !isPrivate, let key { all["\(key)|location"] = answer == .allow }
            return answer == .allow ? .grant : .deny
        case .notNow:
            return .deny
        }
    }

    static func request(origin securityOrigin: WKSecurityOrigin, type: WKMediaCaptureType, window: NSWindow?, isPrivate: Bool,
                        tab: Tab? = nil) async -> WKPermissionDecision {
        let frame = SiteOrigin.of(securityOrigin), page = page(of: tab, frame: frame)
        let key = answerKey(frame: frame, page: page)
        if let key, let known = decision(origin: key, type: type) { return known ? .grant : .deny }
        noteAsked(.cameraAndMicrophone, origin: page, isPrivate: isPrivate)
        let what: String, title: String
        switch type {
        case .camera: (what, title) = ("your camera", String(localized: "Use your camera", comment: "A site's permission question, without its question mark."))
        case .microphone: (what, title) = ("your microphone", String(localized: "Use your microphone", comment: "A site's permission question, without its question mark."))
        default: (what, title) = ("your camera and microphone", String(localized: "Use your camera and microphone", comment: "A site's permission question, without its question mark."))
        }
        guard let controller = WindowManager.shared.promptHost(for: window) else {
            // Nowhere to ask (a sign-in popup): say no this time, without remembering it.
            return .deny
        }
        // The question goes once the tab leaves the page it was asked on.
        let answer = await PermissionPrompt.ask(host: askerName(frame: frame, page: page), origin: page, what: what,
                                                symbol: type == .microphone ? "mic.fill" : "video.fill", in: controller, tab: tab, title: title,
                                                answered: { key.flatMap { decision(origin: $0, type: type) }.map { $0 ? .allow : .deny } })
        // Only a clicked answer is remembered; Esc, or the window closing, is "not now".
        switch answer {
        case .allow:
            if !isPrivate, let key { remember(true, origin: key, type: type) }
            return .grant
        case .deny:
            if !isPrivate, let key { remember(false, origin: key, type: type) }
            return .deny
        case .notNow:
            return .deny
        }
    }
}

/// What a site can ask for, as Site Controls has a row for each. Calls ask for the camera and microphone at once and
/// are answered as one.
enum SitePermission: String, CaseIterable {
    case cameraAndMicrophone, location, notifications, popups

    /// The kinds of answer kept for it.
    var kinds: [String] {
        switch self {
        case .cameraAndMicrophone: ["camera", "microphone", "cameraAndMicrophone"]
        case .location: ["location"]
        case .notifications: ["notifications"]
        case .popups: ["popups"]
        }
    }

    /// The one kind a choice made in Site Controls is kept as.
    var primaryKind: String { self == .cameraAndMicrophone ? "cameraAndMicrophone" : rawValue }

    /// A private window asks for the camera and location (and keeps nothing); it never shows notifications or opens
    /// pop-ups on its own.
    var inPrivate: Bool { self == .cameraAndMicrophone || self == .location }

    var title: String {
        switch self {
        case .cameraAndMicrophone: String(localized: "Camera and microphone", comment: "Row in the site panel's This Site group.")
        case .location: String(localized: "Location", comment: "Row in the site panel's This Site group.")
        case .notifications: String(localized: "Notifications", comment: "Row in the site panel's This Site group.")
        case .popups: String(localized: "Pop-ups", comment: "Row in the site panel's This Site group.")
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
/// under it, and two answers, Allow last and filled. The answer is kept for that site (never in a private window), and
/// can be changed in the site panel. Not answering is easy: the close button, Esc, or a click anywhere else puts
/// it off ("not now"), and so does the tab going to another site. One question at a time per window. It belongs
/// to the tab that asked: it steps aside while another tab is in front and comes back with that tab.
final class PermissionPrompt: FloatingPanelView {
    /// The app's own icon when it's an app that would open, else the request's symbol on a soft circle.
    private let picture = NSImageView()
    private let badge = ColorView(color: .clear)
    private let request = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    private let asker = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let closeButton = IconButton(symbol: "xmark", toolTip: String(localized: "Not Now", comment: "Tooltip of the × on a site's permission question."))
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
    /// Don't Allow, then Allow at the far right, as macOS places them.
    private var buttons: [(button: InteractiveView, width: CGFloat)] = []
    private var answer: ((Answer) -> Void)?
    private var monitor: Any?
    /// The tab whose page asked, and the window it's in.
    private weak var askingTab: Tab?
    private weak var controller: PromptHost?
    private var tabsToken: SignalToken?

    enum Answer { case allow, deny, notNow }

    private static var queue: [ObjectIdentifier: Task<Answer, Never>] = [:]
    /// The question on screen in each window, so it can follow the sidebar.
    private static var shown: [ObjectIdentifier: PermissionPrompt] = [:]

    /// A question is on screen in this window.
    static func isShowing(in controller: PromptHost) -> Bool {
        guard let prompt = shown[ObjectIdentifier(controller)] else { return false }
        return prompt.superview != nil && !prompt.isHidden
    }

    /// Puts the window's question back under the address after the sidebar or the window changed. It never jumps:
    /// riding a sidebar slide (`slide` is its duration) it moves with the sidebar, on the same curve; going between
    /// the address and the top of the page, it glides there.
    static func reposition(in controller: PromptHost, slide: TimeInterval? = nil) {
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
        move.duration = slide ?? 0.24
        move.timingFunction = slide == nil ? Tokens.Motion.easeInOut : Tokens.Motion.slide.timing
        move.fillMode = .backwards
        layer.add(move, forKey: "follow")
    }

    /// `title` is the request ("Use your camera" by default). Whether an answer is kept is the caller's choice:
    /// one Allow, changed later in the site panel. `icon` stands in for the symbol (an app's icon).
    /// `answered` is checked once it's this request's turn: the same question may have been answered meanwhile.
    /// `tab` is the tab whose page asked; without one, it's the tab in front when the question comes up.
    /// `host` is how the site is named in the question; `origin`, when given, is the site it's for (`SiteOrigin`).
    static func ask(host: String, origin: String? = nil, what: String, symbol: String, icon: NSImage? = nil,
                    in controller: PromptHost, tab: Tab? = nil, title: String? = nil, allowTitle: String = String(localized: "Allow", comment: "Button on a site's permission question."),
                    denyTitle: String = String(localized: "Don’t Allow", comment: "Button on a site's permission question."), answered: @escaping () -> Answer? = { nil }) async -> Answer {
        let key = ObjectIdentifier(controller)
        let before = queue[key]
        let task = Task { @MainActor in
            _ = await before?.value
            if let known = answered() { return known }
            return await show(host: host, request: title ?? String(localized: "Use \(what)", comment: "A site's permission question, without its question mark. Only for a request no caller words itself; the placeholder is in English."), symbol: symbol, icon: icon, allowTitle: allowTitle,
                              denyTitle: denyTitle, origin: origin, in: controller, tab: tab)
        }
        queue[key] = task
        let answer = await task.value
        Diagnostics.note("Asked: \(title ?? "Use \(what)")", site: host, answer == .allow ? "allowed" : answer == .deny ? "not allowed" : "put off",
                         isPrivate: controller.promptIsPrivate)
        if queue[key] == task { queue[key] = nil }
        return answer
    }

    private static func show(host: String, request: String, symbol: String, icon: NSImage?, allowTitle: String,
                             denyTitle: String, origin: String?, in controller: PromptHost, tab: Tab?) async -> Answer {
        // Never under What's New, where it couldn't be seen: it waits until the notes close.
        await withCheckedContinuation { continuation in
            WhatsNewSheet.afterClosing(in: controller.window) { continuation.resume() }
        }
        guard controller.window?.isVisible == true else { return .notNow }
        // The asking tab closed while an earlier question waited.
        if let tab, tab.isClosed { return .notNow }
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
            let deny = PillButton(title: denyTitle, style: .plain)
            deny.onClick = { [weak prompt] _ in prompt?.finish(.deny) }
            let allow = PillButton(title: allowTitle, style: .prominent)
            allow.tint = accent
            // Kept for the site (the caller keeps nothing in a private window).
            allow.onClick = { [weak prompt] _ in
                guard let prompt, prompt.acceptsAllow else { return }
                prompt.finish(.allow)
            }
            for button in [deny, allow] as [InteractiveView] { prompt.addSubview(button) }
            // Side by side at one width, as a Mac dialog sets its answers.
            let width = max(deny.fittingWidth, allow.fittingWidth, Tokens.Dialog.minButtonWidth)
            prompt.buttons = [(deny, width), (allow, width)]
            prompt.setAccessibilityLabel(String(localized: "\(host): \(request)?", comment: "VoiceOver label of a site's permission question: the site, then its request, like “zoom.us: Use your camera?”."))
            prompt.answer = { continuation.resume(returning: $0) }
            prompt.askingTab = asking
            prompt.controller = controller
            shown[ObjectIdentifier(controller)] = prompt
            controller.promptOverlay.addSubview(prompt)
            prompt.isHidden = true
            prompt.tabsToken = controller.observePromptTabs { [weak prompt] in prompt?.followTab() }
            // The tab went to another site: this question was that site's, so it's put off.
            prompt.urlToken = asking?.changed.observe { [weak prompt, weak asking] change in
                guard change == .url, let prompt, let url = asking?.url else { return }
                if let origin = prompt.askingOrigin {
                    if SiteOrigin.of(url) != origin { prompt.finish(.notNow) }
                } else if let now = url.host(), now != prompt.askingHost {
                    prompt.finish(.notNow)
                }
            }
            // A click anywhere else, outside it and the address it hangs from, puts it off too.
            prompt.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak prompt, weak controller] event in
                guard let prompt, !prompt.isHidden, event.window === prompt.window else { return event }
                // The command bar over it has its own clicks.
                if controller?.promptIsCovered == true { return event }
                let inside = prompt.bounds.contains(prompt.convert(event.locationInWindow, from: nil))
                let address = controller?.promptAnchor
                let onAddress = address.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
                if !inside && !onAddress { prompt.finish(.notNow) }
                return event
            }
            prompt.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak prompt, weak controller] event in
                guard let prompt, !prompt.isHidden, event.window === prompt.window else { return event }
                // Under notes or the command bar opened after it, Esc is theirs.
                if WhatsNewSheet.isShowing(in: prompt.window) || controller?.promptIsCovered == true { return event }
                // Esc puts it off. Return does nothing here: it belongs to whatever you're typing in.
                if event.keyCode == 53 { prompt.finish(.notNow); return nil }
                return event
            }
            // Last, once it listens: a tab already gone puts it off here, and that takes down what was just set up.
            prompt.followTab()
        }
    }

    /// Shown while the asking tab is in front (either side of a split counts), set aside while another tab is,
    /// and "not now" once it's closed or has gone to another window.
    private func followTab() {
        guard answer != nil, let controller else { return }
        guard let tab = askingTab, !tab.isClosed, controller.promptHolds(tab) else { finish(.notNow); return }
        let inFront = controller.promptShows(tab)
        if inFront, isHidden {
            controller.clearForPrompt()
            place(in: controller)
            isHidden = false
            slideIn()
        } else if !inFront, !isHidden {
            isHidden = true
        }
    }

    /// Always on the page that asked, at the top in the middle (over the pane that asked, in a split): the same
    /// place whether the sidebar is out or not, so it never moves away from the page it belongs to.
    private func place(in controller: PromptHost) {
        surfaceTint = nil
        tintStrength = nil
        isElevated = true
        radius = Tokens.Radius.panel
        let area = controller.focusedPaneFrame
        let width = min(Self.width, area.width - Tokens.Space.x6)
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
        closeButton.onClick = { [weak self] _ in self?.finish(.notNow) }
        [badge, picture, request, asker, closeButton].forEach { addSubview($0) }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func finish(_ choice: Answer) {
        stopListening()
        let answer = self.answer
        self.answer = nil
        answer?(choice)
        slideOut()
    }

    /// Taken away without an answer (its window closed): the page hears "not now" rather than waiting forever.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, answer != nil {
            stopListening()
            let answer = self.answer
            self.answer = nil
            answer?(.notNow)
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        tabsToken = nil
        urlToken = nil
        if let controller, Self.shown[ObjectIdentifier(controller)] === self { Self.shown[ObjectIdentifier(controller)] = nil }
    }

    #if DEBUG
    /// For the debug bridge: answers the question showing in `host`, as its buttons would. Allow still waits out its
    /// first half second.
    static func debugAnswer(_ answer: Answer, in host: PromptHost) {
        guard let prompt = shown[ObjectIdentifier(host)], !prompt.isHidden else { return }
        if answer == .allow, !prompt.acceptsAllow { return }
        prompt.finish(answer)
    }

    /// The question showing in `host`, as its words read.
    static func debugShowing(in host: PromptHost) -> String? {
        guard let prompt = shown[ObjectIdentifier(host)], prompt.superview != nil, !prompt.isHidden else { return nil }
        return prompt.request.stringValue + " " + prompt.asker.stringValue
    }
    #endif

    private static let width: CGFloat = 340
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
        let h = Self.pad + max(Self.iconSide, textHeight(for: width))
        return h + Tokens.Space.x4 + Self.buttonHeight + Self.pad
    }

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
        let y = pad + header + Tokens.Space.x4
        // The two answers share the row evenly when it's narrow (in the sidebar); otherwise they sit at the right.
        let total = buttons.reduce(0) { $0 + $1.width } + Self.buttonGap * CGFloat(max(0, buttons.count - 1))
        let even = total > w - pad * 2 || w < Self.width
        let each = (w - pad * 2 - Self.buttonGap * CGFloat(max(0, buttons.count - 1))) / CGFloat(max(1, buttons.count))
        var x = w - pad
        for (button, width) in buttons.reversed() {
            let bw = even ? each : width
            x -= bw
            button.frame = NSRect(x: x, y: y, width: bw, height: Self.buttonHeight)
            x -= Self.buttonGap
        }
    }
}
