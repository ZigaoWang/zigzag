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

    /// Whether a site may open links for another app (zoommtg:, wemeet:) without asking: yes once you've said Open.
    static func opensApp(host: String, scheme: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Bool])?["\(host)|app:\(scheme)"] == true
    }

    static func allowOpeningApp(host: String, scheme: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        all["\(host)|app:\(scheme)"] = true
        UserDefaults.standard.set(all, forKey: key)
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
    static func requestNotifications(host: String, window: NSWindow?, isPrivate: Bool, tab: Tab? = nil) async -> Bool? {
        if let known = notifications(host: host) { return known }
        guard let window, let controller = WindowManager.shared.controllers.first(where: { $0.window === window }) else { return nil }
        let answer = await PermissionPrompt.ask(host: host, what: "notifications", symbol: "bell.fill", isPrivate: isPrivate, in: controller, tab: tab,
                                                title: "Show notifications", alwaysTitle: nil,
                                                answered: { notifications(host: host).map { $0 ? .allow : .deny } })
        switch answer {
        case .allow, .allowOnce, .deny:
            if !isPrivate { setNotifications(answer == .allow, host: host) }
            return answer == .allow
        case .notNow:
            return nil
        }
    }

    /// Location, asked and remembered the same way as the camera.
    static func requestLocation(origin: WKSecurityOrigin, window: NSWindow?, isPrivate: Bool, tab: Tab? = nil) async -> WKPermissionDecision {
        let host = origin.host
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        if let known = all["\(host)|location"] { return known ? .grant : .deny }
        guard let window, let controller = WindowManager.shared.controllers.first(where: { $0.window === window }) else { return .deny }
        let answer = await PermissionPrompt.ask(host: host, what: "your location", symbol: "location.fill", isPrivate: isPrivate, in: controller, tab: tab,
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
        case .allowOnce:
            return .grant
        case .notNow:
            return .deny
        }
    }

    static func request(origin: WKSecurityOrigin, type: WKMediaCaptureType, window: NSWindow?, isPrivate: Bool,
                        tab: Tab? = nil) async -> WKPermissionDecision {
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
                                                isPrivate: isPrivate, in: controller, tab: tab,
                                                answered: { decision(host: host, type: type).map { $0 ? .allow : .deny } })
        // Only a clicked answer is remembered; Esc, or the window closing, is "not now".
        switch answer {
        case .allow:
            if !isPrivate { remember(true, host: host, type: type) }
            return .grant
        case .allowOnce:
            return .grant
        case .deny:
            if !isPrivate { remember(false, host: host, type: type) }
            return .deny
        case .notNow:
            return .deny
        }
    }
}

/// "Open Tencent Meeting?", asked on the page that asked, as Chrome does: what it wants as a question, the site
/// asking under it, and two answers. Allow goes last, filled; ticking "Always allow on this site" keeps the yes
/// for next time, and Don't Allow is kept as asked by each caller. Esc puts it off; Return is left to whatever
/// you're typing in. One question at a time per window: a second request waits for the first answer. It belongs
/// to the tab that asked: it steps aside while another tab is in front and comes back with that tab, and closing
/// that tab is "not now".
final class PermissionPrompt: FloatingPanelView {
    /// The app's own icon when it's an app that would open, else the request's symbol on a soft circle.
    private let picture = NSImageView()
    private let badge = ColorView(color: .clear)
    private let request = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let asker = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private var always: CheckBox?
    /// Don't Allow, then Allow at the far right, as macOS places them.
    private var buttons: [(button: InteractiveView, width: CGFloat)] = []
    private var answer: ((Answer) -> Void)?
    private var monitor: Any?
    /// The tab whose page asked, and the window it's in.
    private weak var askingTab: Tab?
    private weak var controller: BrowserWindowController?
    private var tabsToken: SignalToken?

    enum Answer { case allow, allowOnce, deny, notNow }

    private static var queue: [ObjectIdentifier: Task<Answer, Never>] = [:]
    /// The question on screen in each window, so it can follow the sidebar.
    private static var shown: [ObjectIdentifier: PermissionPrompt] = [:]

    /// Puts the window's question back under the address after the sidebar or the window changed.
    static func reposition(in controller: BrowserWindowController) {
        guard let prompt = shown[ObjectIdentifier(controller)], prompt.superview != nil, !prompt.isHidden else { return }
        prompt.place(in: controller)
    }

    /// `title` is the request ("Use your camera" by default). `alwaysTitle` is the box that keeps a yes: ticked,
    /// Allow answers `.allow`, else `.allowOnce`. Nil leaves it out, for things that only make sense kept
    /// (notifications) or are asked every time anyway (sharing your screen), and Allow is `.allow`.
    /// A private window keeps nothing, so it has no box either. `icon` stands in for the symbol (an app's icon).
    /// `answered` is checked once it's this request's turn: the same question may have been answered meanwhile.
    /// `tab` is the tab whose page asked; without one, it's the tab in front when the question comes up.
    static func ask(host: String, what: String, symbol: String, icon: NSImage? = nil, isPrivate: Bool,
                    in controller: BrowserWindowController, tab: Tab? = nil, title: String? = nil, allowTitle: String = "Allow",
                    alwaysTitle: String? = "Always allow on this site", denyTitle: String = "Don’t Allow",
                    answered: @escaping () -> Answer? = { nil }) async -> Answer {
        let alwaysTitle = isPrivate ? nil : alwaysTitle
        let key = ObjectIdentifier(controller)
        let before = queue[key]
        let task = Task { @MainActor in
            _ = await before?.value
            if let known = answered() { return known }
            return await show(host: host, request: title ?? "Use \(what)", symbol: symbol, icon: icon, allowTitle: allowTitle,
                              alwaysTitle: alwaysTitle, denyTitle: denyTitle, in: controller, tab: tab)
        }
        queue[key] = task
        let answer = await task.value
        if queue[key] == task { queue[key] = nil }
        return answer
    }

    private static func show(host: String, request: String, symbol: String, icon: NSImage?, allowTitle: String,
                             alwaysTitle: String?, denyTitle: String, in controller: BrowserWindowController, tab: Tab?) async -> Answer {
        guard controller.window?.isVisible == true else { return .notNow }
        // The asking tab closed while an earlier question waited.
        if let tab, tab.isClosed { return .notNow }
        let asking = tab ?? controller.tabManager.selectedTab
        // In the space's own color, like every other button in the window.
        let accent = Brand.Theme.of(controller.tabManager.currentSpace).accent
        return await withCheckedContinuation { continuation in
            let prompt = PermissionPrompt(frame: .zero)
            prompt.request.stringValue = "\(request)?"
            prompt.asker.stringValue = "Asked by \(host)"
            if let icon {
                prompt.picture.image = icon
                prompt.badge.isHidden = true
            } else {
                prompt.picture.image = Tokens.Symbol.image(symbol, size: 15)
                prompt.picture.imageScaling = .scaleNone
                prompt.picture.contentTintColor = accent
                prompt.badge.color = accent.withAlphaComponent(0.16)
            }
            if let alwaysTitle {
                let box = CheckBox(title: alwaysTitle)
                prompt.addSubview(box)
                prompt.always = box
            }
            let deny = TextButton.form(denyTitle)
            deny.onClick = { [weak prompt] _ in prompt?.finish(.deny) }
            let allow = PrimaryButton(title: allowTitle)
            allow.onClick = { [weak prompt] _ in
                guard let prompt else { return }
                prompt.finish(prompt.always.map { $0.isOn ? .allow : .allowOnce } ?? .allow)
            }
            for button in [deny, allow] as [InteractiveView] { prompt.addSubview(button) }
            // Side by side at one width, as a Mac dialog sets its answers.
            let width = max(deny.fittingWidth + Tokens.Space.x3, allow.fittingWidth, 84)
            prompt.buttons = [(deny, width), (allow, width)]
            prompt.setAccessibilityLabel("\(host): \(request)?")
            prompt.answer = { continuation.resume(returning: $0) }
            prompt.askingTab = asking
            prompt.controller = controller
            shown[ObjectIdentifier(controller)] = prompt
            controller.root.overlay.addSubview(prompt)
            prompt.growsFrom = CGPoint(x: 0.2, y: 0)
            prompt.isHidden = true
            prompt.followTab()
            prompt.tabsToken = controller.tabManager.changed.observe { [weak prompt] change in
                guard change == .selection || change == .structure || change == .space else { return }
                prompt?.followTab()
            }
            prompt.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak prompt] event in
                guard let prompt, !prompt.isHidden, event.window === prompt.window else { return event }
                // Esc puts it off. Return does nothing here: it belongs to whatever you're typing in.
                if event.keyCode == 53 { prompt.finish(.notNow); return nil }
                return event
            }
        }
    }

    /// Shown while the asking tab is in front (either side of a split counts), set aside while another tab is,
    /// and "not now" once it's closed or has gone to another window.
    private func followTab() {
        guard answer != nil, let controller else { return }
        let manager = controller.tabManager
        guard let tab = askingTab, !tab.isClosed, manager.allTabs.contains(where: { $0 === tab }) else { finish(.notNow); return }
        let front = manager.selectedTab
        let inFront = front === tab || front.map { manager.partner(of: $0) === tab } == true
        if inFront, isHidden {
            controller.closeFloatingPanels()
            Toast.hide(in: controller)
            place(in: controller)
            isHidden = false
            present(arrival: .pop)
        } else if !inFront, !isHidden {
            isHidden = true
        }
    }

    /// A raised card at the top left of the page that asked, where you're looking, not in the sidebar's color
    /// beside it. In split view, over the pane that asked.
    private func place(in controller: BrowserWindowController) {
        surfaceTint = nil
        tintStrength = nil
        isElevated = true
        radius = Tokens.Radius.panel
        let area = controller.focusedPaneFrame
        let width = min(Self.width, area.width - Tokens.Space.x6)
        frame = NSRect(x: area.minX + Tokens.Space.x3, y: area.minY + Tokens.Space.x3, width: width, height: height(for: width))
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
        [badge, picture, request, asker].forEach { addSubview($0) }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func finish(_ choice: Answer) {
        stopListening()
        let answer = self.answer
        self.answer = nil
        answer?(choice)
        dismiss()
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
        tabsToken = nil
        if let controller, Self.shown[ObjectIdentifier(controller)] === self { Self.shown[ObjectIdentifier(controller)] = nil }
    }

    private static let width: CGFloat = 340
    private static let pad: CGFloat = 16
    private static let iconSide: CGFloat = 32
    private static let buttonHeight = Tokens.Space.x7Height
    private static let buttonGap: CGFloat = 8

    private var textX: CGFloat { Self.pad + Self.iconSide + Tokens.Space.x3 }

    private func requestHeight(for width: CGFloat) -> CGFloat {
        let textWidth = width - textX - Self.pad
        return ceil(request.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 200)).height ?? request.lineHeight)
    }

    private func textHeight(for width: CGFloat) -> CGFloat { requestHeight(for: width) + 2 + asker.lineHeight }

    private func height(for width: CGFloat) -> CGFloat {
        var h = Self.pad + max(Self.iconSide, textHeight(for: width))
        if let always { h += Tokens.Space.x3 + always.intrinsicContentSize.height }
        return h + Tokens.Space.x4 + Self.buttonHeight + Self.pad
    }

    private func layoutContent() {
        let pad = Self.pad, w = bounds.width
        let textWidth = w - textX - pad
        let th = textHeight(for: w)
        let header = max(Self.iconSide, th)
        badge.frame = NSRect(x: pad, y: pad + (header - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide)
        picture.frame = badge.frame
        let top = pad + (header - th) / 2
        request.frame = NSRect(x: textX - Label.inset, y: top, width: textWidth + Label.inset * 2, height: requestHeight(for: w))
        asker.frame = NSRect(x: textX - Label.inset, y: request.frame.maxY + 2, width: textWidth + Label.inset * 2, height: asker.lineHeight)
        var y = pad + header
        if let always {
            let size = always.intrinsicContentSize
            always.frame = NSRect(x: textX, y: y + Tokens.Space.x3, width: min(size.width, textWidth), height: size.height)
            y = always.frame.maxY
        }
        y += Tokens.Space.x4
        var x = w - pad
        for (button, width) in buttons.reversed() {
            x -= width
            button.frame = NSRect(x: x, y: y, width: width, height: Self.buttonHeight)
            x -= Self.buttonGap
        }
    }
}
