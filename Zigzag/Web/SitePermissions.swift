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
                                                title: "Show notifications", allowTitle: "Allow", onceTitle: nil,
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

/// "example.com wants to / Use your camera", as Chrome asks it: hanging from the address, so it's plain which site
/// is asking, with whole answers stacked one per line. Allow While Visiting is remembered, Allow This Time isn't,
/// Don't Allow is. Esc puts it off; Return is left to whatever you're typing in. One question at a time per window:
/// a second request waits for the first answer. It belongs to the tab that asked: it steps aside while another tab
/// is in front and comes back with that tab, and closing that tab is "not now".
final class PermissionPrompt: FloatingPanelView {
    private let badge = ColorView(color: .clear)
    private let symbolView = NSImageView()
    private let asker = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let request = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private var buttons: [(TextButton, Answer)] = []
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

    /// `title` is the request ("Use your camera" by default); `onceTitle` nil leaves out Allow This Time, for things
    /// that only make sense kept (notifications) or are asked every time anyway (sharing your screen).
    /// `answered` is checked once it's this request's turn: the same question may have been answered meanwhile.
    /// `tab` is the tab whose page asked; without one, it's the tab in front when the question comes up.
    static func ask(host: String, what: String, symbol: String, isPrivate: Bool, in controller: BrowserWindowController,
                    tab: Tab? = nil, title: String? = nil, allowTitle: String = "Allow While Visiting",
                    onceTitle: String? = "Allow This Time", denyTitle: String = "Don’t Allow",
                    answered: @escaping () -> Answer? = { nil }) async -> Answer {
        let key = ObjectIdentifier(controller)
        let before = queue[key]
        let task = Task { @MainActor in
            _ = await before?.value
            if let known = answered() { return known }
            var choices: [(String, Answer)] = [(allowTitle, .allow)]
            if let onceTitle { choices.append((onceTitle, .allowOnce)) }
            choices.append((denyTitle, .deny))
            return await show(host: host, request: title ?? "Use \(what)", symbol: symbol, choices: choices, in: controller, tab: tab)
        }
        queue[key] = task
        let answer = await task.value
        if queue[key] == task { queue[key] = nil }
        return answer
    }

    private static func show(host: String, request: String, symbol: String, choices: [(String, Answer)],
                             in controller: BrowserWindowController, tab: Tab?) async -> Answer {
        guard controller.window?.isVisible == true else { return .notNow }
        // The asking tab closed while an earlier question waited.
        if let tab, tab.isClosed { return .notNow }
        let asking = tab ?? controller.tabManager.selectedTab
        return await withCheckedContinuation { continuation in
            let prompt = PermissionPrompt(frame: .zero)
            prompt.asker.stringValue = "\(host) wants to"
            prompt.request.stringValue = request
            prompt.symbolView.image = Tokens.Symbol.image(symbol, size: 14)
            prompt.buttons = choices.map { title, answer in
                let button = TextButton.form(title)
                button.onClick = { [weak prompt] _ in prompt?.finish(answer) }
                prompt.addSubview(button)
                return (button, answer)
            }
            prompt.setAccessibilityLabel("\(host) wants to \(request.lowercased())")
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

    /// Under the address in the sidebar, in its color, like the site panel; at the top left of the page when the
    /// sidebar is hidden.
    private func place(in controller: BrowserWindowController) {
        let overlay = controller.root.overlay
        let address = controller.sidebar.address
        if controller.root.sidebarVisible, !controller.root.isSidebarFloatingVisible {
            let anchor = address.convert(address.bounds, to: overlay)
            surfaceTint = controller.tabManager.isPrivate ? SpaceColor.graphite.background : controller.tabManager.currentSpace.background
            tintStrength = 0.82
            isElevated = false
            radius = address.layer?.cornerRadius ?? Tokens.Radius.panel
            frame = NSRect(x: anchor.minX, y: anchor.maxY + 4, width: anchor.width, height: height(for: anchor.width))
        } else {
            radius = Tokens.Radius.panel
            let card = controller.root.cardFrame, width: CGFloat = 300
            frame = NSRect(x: card.minX + Tokens.Space.x3, y: card.minY + Tokens.Space.x3, width: width, height: height(for: width))
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.color = Tokens.Color.accent.withAlphaComponent(0.14)
        symbolView.contentTintColor = Tokens.Color.accent
        badge.addSubview(symbolView)
        // A long host loses its middle, not its end: the part that says whose site it is stays.
        asker.lineBreakMode = .byTruncatingMiddle
        request.lineBreakMode = .byWordWrapping
        request.maximumNumberOfLines = 2
        [badge, asker, request].forEach { addSubview($0) }
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

    private static let pad: CGFloat = 14
    private static let buttonHeight = Tokens.Space.x8
    private static let buttonGap: CGFloat = 6

    private func requestHeight(for width: CGFloat) -> CGFloat {
        let textWidth = width - Self.pad * 2 - 28 - 10
        return ceil(request.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 200)).height ?? request.lineHeight)
    }

    private func height(for width: CGFloat) -> CGFloat {
        let header = max(28, asker.lineHeight + 1 + requestHeight(for: width))
        let stack = CGFloat(buttons.count) * Self.buttonHeight + CGFloat(max(buttons.count - 1, 0)) * Self.buttonGap
        return Self.pad + header + Tokens.Space.x3 + stack + Self.pad
    }

    private func layoutContent() {
        let pad = Self.pad, w = bounds.width
        let textX = pad + 28 + 10, textWidth = w - textX - pad
        let rh = requestHeight(for: w)
        let header = max(28, asker.lineHeight + 1 + rh)
        badge.frame = NSRect(x: pad, y: pad + (header - 28) / 2, width: 28, height: 28)
        symbolView.frame = badge.bounds.insetBy(dx: 7, dy: 7)
        let top = pad + (header - asker.lineHeight - 1 - rh) / 2
        asker.frame = NSRect(x: textX, y: top, width: textWidth, height: asker.lineHeight)
        request.frame = NSRect(x: textX, y: asker.frame.maxY + 1, width: textWidth, height: rh)
        var y = pad + header + Tokens.Space.x3
        for (button, _) in buttons {
            button.frame = NSRect(x: pad, y: y, width: w - pad * 2, height: Self.buttonHeight)
            y += Self.buttonHeight + Self.buttonGap
        }
    }
}
