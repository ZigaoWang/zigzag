import AppKit
import WebKit

/// Camera and microphone decisions, remembered per site. Asked once, in a sheet, never as a surprise popup.
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

    /// Sites with a remembered camera or microphone choice.
    static var sites: Set<String> {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        return Set(all.keys.compactMap { $0.split(separator: "|").first.map(String.init) })
    }

    static func forgetAll() { UserDefaults.standard.removeObject(forKey: key) }

    static func forget(host: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        for k in all.keys where k.hasPrefix(host + "|") { all[k] = nil }
        UserDefaults.standard.set(all, forKey: key)
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
                                                isPrivate: isPrivate, in: controller)
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
/// two clear answers. Answering by pressing Return allows; Esc doesn't.
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

    static func ask(host: String, what: String, symbol: String, isPrivate: Bool, in controller: BrowserWindowController) async -> Answer {
        await withCheckedContinuation { continuation in
            let prompt = PermissionPrompt(frame: NSRect(x: 0, y: 0, width: 420, height: 72))
            // The question in big words, the site under it: short enough to never cut off.
            prompt.title.stringValue = "Use \(what)?"
            prompt.line.stringValue = host + (isPrivate ? " · this private window only" : "")
            prompt.symbolView.image = Tokens.Symbol.image(symbol, size: 16)
            prompt.answer = { continuation.resume(returning: $0) }
            let card = controller.root.cardFrame
            prompt.frame.origin = NSPoint(x: card.midX - 210, y: card.minY + Tokens.Space.x4)
            controller.closeFloatingPanels()
            Toast.hide(in: controller)
            controller.root.overlay.addSubview(prompt)
            prompt.present(arrival: .drop)
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
