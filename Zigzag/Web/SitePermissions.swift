import AppKit
import WebKit

/// Camera, microphone, location and notification decisions, remembered per site. Asked once, in a sheet, never as
/// a surprise popup.
enum SitePermissions {
    private static let key = "SitePermissions"

    private static func storageKey(host: String, type: WKMediaCaptureType) -> String {
        let kind: String
        switch type {
        case .camera: kind = "camera"
        case .microphone: kind = "microphone"
        default: kind = "cameraAndMicrophone"
        }
        return "\(host)|\(kind)"
    }

    static func decision(host: String, type: WKMediaCaptureType) -> Bool? {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        return all[storageKey(host: host, type: type)]
    }

    static func remember(_ allowed: Bool, host: String, type: WKMediaCaptureType) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        all[storageKey(host: host, type: type)] = allowed
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Every remembered answer for one site: kind ("camera", "location", "notifications"…) to allowed or not.
    static func choices(host: String) -> [String: Bool] {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        var found: [String: Bool] = [:]
        for (k, v) in all where k.hasPrefix(host + "|") { found[String(k.dropFirst(host.count + 1))] = v }
        return found
    }

    /// Forgets everything about a site, notifications included.
    static func forgetEverything(host: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        for k in all.keys where k.hasPrefix(host + "|") { all[k] = nil }
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Sites with a remembered choice of any kind.
    static var sites: Set<String> {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        return Set(all.keys.compactMap { $0.split(separator: "|").first.map(String.init) })
    }

    static func forgetAll() { UserDefaults.standard.removeObject(forKey: key) }

    /// A site's answer about your location, if it ever asked.
    static func location(host: String) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Bool])?["\(host)|location"]
    }

    static func forgetLocation(host: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        all["\(host)|location"] = nil
        UserDefaults.standard.set(all, forKey: key)
    }

    /// "Ask again" for the camera, microphone and location. Notifications have their own switch and stay as they are.
    static func forget(host: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        for k in all.keys where k.hasPrefix(host + "|") && k != "\(host)|notifications" { all[k] = nil }
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Notifications: nil until the site has asked and you've answered.
    static func notifications(host: String) -> Bool? {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        return all["\(host)|notifications"]
    }

    static func setNotifications(_ allowed: Bool?, host: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        all["\(host)|notifications"] = allowed
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Every site's notification choice, for the page script: it knows the answer before the page asks.
    static var notificationDecisions: [String: Bool] {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        var out: [String: Bool] = [:]
        for (k, v) in all where k.hasSuffix("|notifications") { out[String(k.dropLast("|notifications".count))] = v }
        return out
    }

    /// Asked like the camera. A private window never remembers the answer, and never shows notifications anyway.
    static func requestNotifications(host: String, window: NSWindow?, isPrivate: Bool) async -> Bool? {
        if let known = notifications(host: host) { return known }
        guard let window, let controller = WindowManager.shared.controllers.first(where: { $0.window === window }) else { return nil }
        let answer = await PermissionPrompt.ask(host: host, what: "notifications", symbol: "bell.fill", isPrivate: isPrivate, in: controller,
                                                answered: { notifications(host: host).map { $0 ? .allow : .deny } })
        switch answer {
        case .allow, .deny:
            if !isPrivate { setNotifications(answer == .allow, host: host) }
            return answer == .allow
        case .notNow:
            return nil
        }
    }

    /// Location, asked and remembered the same way as the camera.
    static func requestLocation(origin: WKSecurityOrigin, window: NSWindow?, isPrivate: Bool) async -> WKPermissionDecision {
        let host = origin.host
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        if let known = all["\(host)|location"] { return known ? .grant : .deny }
        guard let window, let controller = WindowManager.shared.controllers.first(where: { $0.window === window }) else { return .deny }
        let answer = await PermissionPrompt.ask(host: host, what: "your location", symbol: "location.fill", isPrivate: isPrivate, in: controller,
                                                answered: {
                                                    let now = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
                                                    return now["\(host)|location"].map { $0 ? .allow : .deny }
                                                })
        switch answer {
        case .allow, .deny:
            if !isPrivate {
                all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
                all["\(host)|location"] = answer == .allow
                UserDefaults.standard.set(all, forKey: key)
            }
            return answer == .allow ? .grant : .deny
        case .notNow:
            return .deny
        }
    }

    static func request(origin: WKSecurityOrigin, type: WKMediaCaptureType, window: NSWindow?, isPrivate: Bool) async -> WKPermissionDecision {
        let host = origin.host
        if let known = decision(host: host, type: type) { return known ? .grant : .deny }
        let what: String
        switch type {
        case .camera: what = "your camera"
        case .microphone: what = "your microphone"
        default: what = "your camera and microphone"
        }
        guard let window, let controller = WindowManager.shared.controllers.first(where: { $0.window === window }) else {
            // Nowhere to ask (a popup window): say no this time, without remembering it.
            return .deny
        }
        let answer = await PermissionPrompt.ask(host: host, what: what, symbol: type == .microphone ? "mic.fill" : "video.fill",
                                                isPrivate: isPrivate, in: controller,
                                                answered: { decision(host: host, type: type).map { $0 ? .allow : .deny } })
        // Only a clicked answer is remembered; Esc, or the window closing, is "not now".
        switch answer {
        case .allow:
            if !isPrivate { remember(true, host: host, type: type) }
            return .grant
        case .deny:
            if !isPrivate { remember(false, host: host, type: type) }
            return .deny
        case .notNow:
            return .deny
        }
    }
}

/// "example.com wants to use your camera": a small Zigzag panel at the top of the page, with the site's icon and
/// two clear answers. Esc puts it off; Return is left to whatever you're typing in. One question at a time per
/// window: a second request waits for the first answer.
final class PermissionPrompt: FloatingPanelView {
    private let badge = ColorView(color: .clear)
    private let symbolView = NSImageView()
    private let title = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let line = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let allow = PrimaryButton(title: "Allow")
    private let deny = TextButton.form("Don’t Allow")
    private var answer: ((Answer) -> Void)?
    private var monitor: Any?

    enum Answer { case allow, deny, notNow }

    private static var queue: [ObjectIdentifier: Task<Answer, Never>] = [:]

    /// `answered` is checked once it's this request's turn: the same question may have been answered meanwhile.
    static func ask(host: String, what: String, symbol: String, isPrivate: Bool, in controller: BrowserWindowController,
                    answered: @escaping () -> Answer? = { nil }) async -> Answer {
        let key = ObjectIdentifier(controller)
        let before = queue[key]
        let task = Task { @MainActor in
            _ = await before?.value
            if let known = answered() { return known }
            return await show(host: host, what: what, symbol: symbol, isPrivate: isPrivate, in: controller)
        }
        queue[key] = task
        let answer = await task.value
        if queue[key] == task { queue[key] = nil }
        return answer
    }

    private static func show(host: String, what: String, symbol: String, isPrivate: Bool, in controller: BrowserWindowController) async -> Answer {
        guard controller.window?.isVisible == true else { return .notNow }
        return await withCheckedContinuation { continuation in
            let prompt = PermissionPrompt(frame: NSRect(x: 0, y: 0, width: 420, height: 72))
            // The question in big words, the site under it: short enough to never cut off.
            prompt.title.stringValue = "Use \(what)?"
            prompt.line.stringValue = isPrivate ? "\(host), for this private window only" : host
            prompt.symbolView.image = Tokens.Symbol.image(symbol, size: 16)
            prompt.answer = { continuation.resume(returning: $0) }
            let card = controller.root.cardFrame
            prompt.frame.origin = NSPoint(x: card.midX - 210, y: card.minY + Tokens.Space.x3)
            controller.closeFloatingPanels()
            Toast.hide(in: controller)
            controller.root.overlay.addSubview(prompt)
            prompt.growsFrom = CGPoint(x: 0.5, y: 0)
            prompt.present(arrival: .pop)
            prompt.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak prompt] event in
                guard let prompt, event.window === prompt.window else { return event }
                // Esc puts it off. Return does nothing here: it belongs to whatever you're typing in.
                if event.keyCode == 53 { prompt.finish(.notNow); return nil }
                return event
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        radius = Tokens.Radius.panel
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 10
        badge.color = Tokens.Color.accent.withAlphaComponent(0.14)
        symbolView.contentTintColor = Tokens.Color.accent
        badge.addSubview(symbolView)
        [badge, title, line, allow, deny].forEach { addSubview($0) }
        allow.onClick = { [weak self] _ in self?.finish(.allow) }
        deny.onClick = { [weak self] _ in self?.finish(.deny) }
        line.lineBreakMode = .byTruncatingMiddle
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func finish(_ choice: Answer) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let answer = self.answer
        self.answer = nil
        answer?(choice)
        dismiss()
    }

    /// Taken away without an answer (its window closed): the page hears "not now" rather than waiting forever.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, answer != nil {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            let answer = self.answer
            self.answer = nil
            answer?(.notNow)
        }
    }

    private func layoutContent() {
        let h = bounds.height, pad: CGFloat = 14
        badge.frame = NSRect(x: pad, y: (h - 36) / 2, width: 36, height: 36)
        symbolView.frame = badge.bounds.insetBy(dx: 9, dy: 9)
        let aw = max(allow.fittingWidth, 72), bh = Tokens.Space.x8
        allow.frame = NSRect(x: bounds.width - pad - aw, y: (h - bh) / 2, width: aw, height: bh)
        let dw = deny.fittingWidth
        deny.frame = NSRect(x: allow.frame.minX - Tokens.Space.x2 - dw, y: (h - bh) / 2, width: dw, height: bh)
        let x = badge.frame.maxX + 12, w = deny.frame.minX - x - 10
        let block = title.lineHeight + 1 + line.lineHeight
        title.frame = NSRect(x: x, y: (h - block) / 2, width: w, height: title.lineHeight)
        line.frame = NSRect(x: x, y: title.frame.maxY + 1, width: w, height: line.lineHeight)
    }
}
