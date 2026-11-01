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

    /// "Ask again" for the camera and microphone only: location, notifications and apps to open each have their own
    /// row, and stay as they are.
    static func forget(host: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        for kind in ["camera", "microphone", "cameraAndMicrophone"] { all["\(host)|\(kind)"] = nil }
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

/// "Use your location?", at the top of the page that asked, sliding down from its top edge: the question, the site
/// under it, and two answers, Allow last and filled. The answer is kept for that site (never in a private window), and
/// can be changed in the site panel. Not answering is easy: the close button, Esc, or a click anywhere else puts
/// it off ("not now"), and so does the tab going to another site. One question at a time per window. It belongs
/// to the tab that asked: it steps aside while another tab is in front and comes back with that tab.
final class PermissionPrompt: FloatingPanelView {
    /// The app's own icon when it's an app that would open, else the request's symbol on a soft circle.
    private let picture = NSImageView()
    private let badge = ColorView(color: .clear)
    private let request = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let asker = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let closeButton = IconButton(symbol: "xmark", size: Tokens.Space.x6, symbolSize: Tokens.TypeSize.small, toolTip: "Not Now")
    /// The site that asked: when the tab goes elsewhere, the question no longer applies.
    private var askingHost = ""
    private var urlToken: SignalToken?
    private var clickMonitor: Any?
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

    /// Puts the window's question back under the address after the sidebar or the window changed. It never jumps:
    /// riding a sidebar slide (`slide` is its duration) it moves with the sidebar, on the same curve; going between
    /// the address and the top of the page, it glides there.
    static func reposition(in controller: BrowserWindowController, slide: TimeInterval? = nil) {
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
        // Never under What's New, where it couldn't be seen: it waits until the notes close.
        await withCheckedContinuation { continuation in
            WhatsNewSheet.afterClosing(in: controller.window) { continuation.resume() }
        }
        guard controller.window?.isVisible == true else { return .notNow }
        // The asking tab closed while an earlier question waited.
        if let tab, tab.isClosed { return .notNow }
        let asking = tab ?? controller.tabManager.selectedTab
        // In the space's own color, like every other button in the window.
        let accent = Brand.Theme.of(controller.tabManager.currentSpace).accent
        return await withCheckedContinuation { continuation in
            let prompt = PermissionPrompt(frame: .zero)
            prompt.request.stringValue = "\(request)?"
            prompt.asker.stringValue = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            prompt.askingHost = host
            if let icon {
                prompt.picture.image = icon
                prompt.badge.isHidden = true
            } else {
                prompt.picture.image = Tokens.Symbol.image(symbol, size: 15)
                prompt.picture.imageScaling = .scaleNone
                prompt.picture.contentTintColor = accent
                prompt.badge.color = accent.withAlphaComponent(0.16)
            }
            let deny = TextButton.form(denyTitle)
            deny.onClick = { [weak prompt] _ in prompt?.finish(.deny) }
            let allow = PrimaryButton(title: allowTitle)
            // Kept for the site (the caller keeps nothing in a private window).
            allow.onClick = { [weak prompt] _ in prompt?.finish(.allow) }
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
            prompt.isHidden = true
            prompt.followTab()
            prompt.tabsToken = controller.tabManager.changed.observe { [weak prompt] change in
                guard change == .selection || change == .structure || change == .space else { return }
                prompt?.followTab()
            }
            // The tab went to another site: this question was that site's, so it's put off.
            prompt.urlToken = asking?.changed.observe { [weak prompt, weak asking] change in
                guard change == .url, let prompt, let now = asking?.url?.host() else { return }
                if now != prompt.askingHost { prompt.finish(.notNow) }
            }
            // A click anywhere else, outside it and the address it hangs from, puts it off too.
            prompt.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak prompt, weak controller] event in
                guard let prompt, !prompt.isHidden, event.window === prompt.window else { return event }
                // The command bar over it has its own clicks.
                if controller?.commandBar.isVisible == true { return event }
                let inside = prompt.bounds.contains(prompt.convert(event.locationInWindow, from: nil))
                let address = controller?.sidebar.address
                let onAddress = address.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
                if !inside && !onAddress { prompt.finish(.notNow) }
                return event
            }
            prompt.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak prompt, weak controller] event in
                guard let prompt, !prompt.isHidden, event.window === prompt.window else { return event }
                // Under notes or the command bar opened after it, Esc is theirs.
                if WhatsNewSheet.isShowing(in: prompt.window) || controller?.commandBar.isVisible == true { return event }
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
            slideIn()
        } else if !inFront, !isHidden {
            isHidden = true
        }
    }

    /// Always on the page that asked, at the top in the middle (over the pane that asked, in a split): the same
    /// place whether the sidebar is out or not, so it never moves away from the page it belongs to.
    private func place(in controller: BrowserWindowController) {
        surfaceTint = nil
        tintStrength = nil
        isElevated = true
        radius = Tokens.Radius.panel
        let area = controller.focusedPaneFrame
        let width = min(Self.width, area.width - Tokens.Space.x6)
        frame = NSRect(x: round(area.midX - width / 2), y: area.minY + Tokens.Space.x3, width: width, height: height(for: width))
    }

    /// How far above its place it starts and leaves to: fully above the window's top edge, so it comes in from
    /// outside and goes back out, never fading up out of the page.
    private var offstage: CGFloat { frame.maxY + 12 }

    /// In from above the page's top edge, eased to a stop: something new arriving, seen now and then, not a key.
    private func slideIn() {
        guard let layer, !Tokens.Motion.reduceMotion else { present(arrival: .fade); return }
        let drop = CABasicAnimation(keyPath: "transform")
        drop.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -offstage, 0))
        drop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        drop.duration = 0.32
        drop.timingFunction = Tokens.Motion.easeOut
        drop.fillMode = .backwards
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        layer.add(drop, forKey: "slideIn")
        layer.add(fade, forKey: "fadeIn")
    }

    /// Back up the way it came, then gone.
    private func slideOut() {
        guard let layer, !Tokens.Motion.reduceMotion else { dismiss(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        let rise = CABasicAnimation(keyPath: "transform")
        rise.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
        rise.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -offstage, 0))
        rise.duration = 0.2
        rise.timingFunction = Tokens.Motion.easeOut
        rise.fillMode = .forwards
        rise.isRemovedOnCompletion = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 0.08
        fade.duration = 0.12
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(rise, forKey: "slideOut")
        layer.add(fade, forKey: "fadeOut")
        CATransaction.commit()
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

    private static let width: CGFloat = 340
    private static let pad: CGFloat = 16
    private static let iconSide: CGFloat = 32
    private static let buttonHeight = Tokens.Space.x7Height
    private static let buttonGap: CGFloat = 8

    private var textX: CGFloat { Self.pad + Self.iconSide + Tokens.Space.x3 }
    /// Room kept at the right of the text for the close button.
    private var closeRoom: CGFloat { Tokens.Space.x6 }

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
