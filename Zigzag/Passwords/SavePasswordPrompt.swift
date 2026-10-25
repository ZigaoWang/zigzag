import AppKit

/// "Save password for github.com?" A calm panel at the top of the page, under the address. The username can be
/// corrected before saving; Never for This Site is remembered (and synced) so it never asks there again.
final class SavePasswordPrompt: FloatingPanelView {
    enum Kind {
        case save(username: String)
        case update(Credential)
    }

    private static weak var current: SavePasswordPrompt?

    private let icon = FaviconView()
    private let titleLabel = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let siteLabel = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let usernameBox = ColorView(color: Tokens.Color.fieldFill)
    private let usernameField = PlainTextField(font: Tokens.Font.body(), placeholder: "Username")
    private let usernameText = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    private let isUpdate: Bool
    private let saveButton: PrimaryButton
    private let notNowButton = TextButton.form("Not Now")
    // The quiet choice, on its own at the left: the two answers on the right are the ones you see.
    private let neverButton = TextButton(title: "Never", font: Tokens.Font.body(.medium))
    private var hideWork: DispatchWorkItem?
    private var finish: (Bool) -> Void = { _ in }
    private var keyMonitor: Any?

    static let width: CGFloat = 320
    private let pad = Tokens.Space.x4
    private let headerHeight: CGFloat = 36
    private let fieldHeight: CGFloat = 36
    private let buttonHeight = Tokens.Space.x8

    private init(kind: Kind, origin: Origin) {
        isUpdate = { if case .update = kind { true } else { false } }()
        saveButton = PrimaryButton(title: isUpdate ? "Update" : "Save")
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        radius = Tokens.Radius.panel
        titleLabel.stringValue = isUpdate ? "Update password?" : "Save password?"
        // Exactly where this password goes, in full.
        siteLabel.stringValue = origin.displayName
        siteLabel.lineBreakMode = .byTruncatingMiddle
        siteLabel.toolTip = origin.displayName
        let site = URL(string: "\(origin.scheme)://\(origin.host)")
        icon.image = site.flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? Tokens.Symbol.image("key.fill", size: 14)
        usernameBox.wantsLayer = true
        usernameBox.layer?.cornerRadius = Tokens.Radius.control + 2
        usernameBox.layer?.cornerCurve = .continuous
        switch kind {
        case .save(let username):
            usernameField.stringValue = username
            usernameBox.addSubview(usernameField)
        case .update(let credential):
            usernameText.stringValue = credential.username.isEmpty ? "No username" : credential.username
            usernameBox.addSubview(usernameText)
        }
        [icon, titleLabel, siteLabel, usernameBox, neverButton, notNowButton, saveButton].forEach { addSubview($0) }
        neverButton.isHidden = isUpdate
        neverButton.textColor = Tokens.Color.textSecondary
        neverButton.toolTip = "Never offer to save on \(origin.displayName)"
        frame.size.height = measuredHeight
        onLayout = { [weak self] in self?.layoutContent() }
    }

    private var measuredHeight: CGFloat {
        pad + headerHeight + Tokens.Space.x3 + fieldHeight + Tokens.Space.x3 + buttonHeight + pad
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the prompt for a captured login in its tab's window.
    @MainActor static func show(_ kind: Kind, origin: Origin, password: SecretString, in tab: Tab) {
        guard let controller = WindowManager.shared.controllers.first(where: { $0.tabManager.allTabs.contains { $0 === tab } }) else { return }
        current?.close(saved: false)
        let prompt = SavePasswordPrompt(kind: kind, origin: origin)
        prompt.finish = { saved in
            guard saved else { return }
            Task { @MainActor in
                let store = PasswordStore.shared
                let username = prompt.usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                do {
                    switch kind {
                    case .save: try await store.save(origin: origin, username: username, password: password)
                    case .update(let credential): try await store.update(credential, password: password)
                    }
                    Toast.show("Password saved", symbol: "key.fill", duration: 1.6, in: controller)
                } catch {
                    Toast.show("Couldn’t save the password. Try again from the Passwords window.", symbol: "exclamationmark.triangle", duration: 3, in: controller)
                }
            }
        }
        prompt.neverButton.onClick = { [weak prompt] _ in
            Task { await PasswordStore.shared.setNeverSave(true, on: origin) }
            prompt?.close(saved: false)
        }
        prompt.notNowButton.onClick = { [weak prompt] _ in prompt?.close(saved: false) }
        prompt.saveButton.onClick = { [weak prompt] _ in prompt?.close(saved: true) }
        let card = controller.root.cardFrame
        prompt.frame.origin = NSPoint(x: card.minX + Tokens.Space.x3, y: card.minY + Tokens.Space.x3)
        controller.root.overlay.addSubview(prompt)
        prompt.needsLayout = true
        prompt.present(always: true)
        Tokens.Motion.slideVertically(prompt, fromOffsetY: -Tokens.Space.x2)
        current = prompt
        prompt.scheduleHide()
        // You just signed in, so the prompt takes the keyboard: Return saves, Esc says Not Now. Clicking the page
        // gives the keyboard back and the keys stop meaning anything here.
        controller.window?.makeFirstResponder(prompt.usernameField)
        if let editor = prompt.usernameField.currentEditor() { editor.selectedRange = NSRange(location: prompt.usernameField.stringValue.count, length: 0) }
        prompt.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak prompt] event in
            guard let prompt, prompt.superview != nil, let window = prompt.window, event.window === window else { return event }
            let focused = (window.firstResponder as? NSView).map { $0 === prompt || $0.isDescendant(of: prompt) } ?? false
            guard focused else { return event }
            switch event.keyCode {
            case 36, 76: prompt.close(saved: true); return nil
            case 53: prompt.close(saved: false); return nil
            default: return event
            }
        }
    }

    #if DEBUG
    /// A look at the prompt that saves nothing: every button only closes it.
    static func debugPreview(in controller: BrowserWindowController) {
        guard let origin = Origin(URL(string: "https://powerschool.ykpaoschool.cn")) else { return }
        current?.close(saved: false)
        let prompt = SavePasswordPrompt(kind: .save(username: "student"), origin: origin)
        [prompt.neverButton, prompt.notNowButton, prompt.saveButton].forEach { $0.onClick = { [weak prompt] _ in prompt?.close(saved: false) } }
        let card = controller.root.cardFrame
        prompt.frame.origin = NSPoint(x: card.minX + Tokens.Space.x3, y: card.minY + Tokens.Space.x3)
        controller.root.overlay.addSubview(prompt)
        prompt.present(always: true)
        current = prompt
    }

    static func debugClose() { current?.close(saved: false) }
    #endif

    /// Goes away on its own after a while, unless the pointer is on it.
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.superview != nil else { return }
                if let window = self.window, self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) || window.firstResponder === self.usernameField.currentEditor() {
                    self.scheduleHide()
                } else {
                    self.close(saved: false)
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func close(saved: Bool) {
        hideWork?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) {
            window.makeFirstResponder(BrowserWindowController.undoTarget?.selectedWebView)
        }
        if Self.current === self { Self.current = nil }
        let finish = self.finish
        self.finish = { _ in }
        finish(saved)
        dismiss(always: true)
    }

    private func layoutContent() {
        let w = bounds.width, inner = w - pad * 2
        // The site's icon, then what's being asked and where.
        let iconSide: CGFloat = 20
        icon.frame = NSRect(x: pad, y: pad + (headerHeight - iconSide) / 2, width: iconSide, height: iconSide)
        let textX = icon.frame.maxX + Tokens.Space.x3
        let block = titleLabel.lineHeight + siteLabel.lineHeight
        titleLabel.frame = NSRect(x: textX, y: pad + (headerHeight - block) / 2, width: w - textX - pad, height: titleLabel.lineHeight)
        siteLabel.frame = NSRect(x: textX, y: titleLabel.frame.maxY, width: w - textX - pad, height: siteLabel.lineHeight)
        // The username, editable before saving.
        usernameBox.frame = NSRect(x: pad, y: pad + headerHeight + Tokens.Space.x3, width: inner, height: fieldHeight)
        let fh = ceil(usernameField.intrinsicContentSize.height)
        usernameField.frame = NSRect(x: Tokens.Space.x3, y: (fieldHeight - fh) / 2, width: inner - Tokens.Space.x3 * 2, height: fh)
        usernameText.frame = NSRect(x: Tokens.Space.x3, y: (fieldHeight - usernameText.lineHeight) / 2, width: inner - Tokens.Space.x3 * 2, height: usernameText.lineHeight)
        // Never at the left; Not Now and Save at the right.
        let y = usernameBox.frame.maxY + Tokens.Space.x3
        let saveWidth = max(saveButton.fittingWidth, 76)
        saveButton.frame = NSRect(x: w - pad - saveWidth, y: y, width: saveWidth, height: buttonHeight)
        let notNowWidth = notNowButton.fittingWidth + Tokens.Space.x2
        notNowButton.frame = NSRect(x: saveButton.frame.minX - Tokens.Space.x2 - notNowWidth, y: y, width: notNowWidth, height: buttonHeight)
        neverButton.frame = NSRect(x: pad - Tokens.Space.x2, y: y, width: neverButton.fittingWidth, height: buttonHeight)
    }
}

/// A small keycap on a button, saying which key does the same thing.
final class KeyHint: NSView {
    static let height: CGFloat = 20
    private let label: Label
    var onAccent = false { didSet { refresh() } }

    init(_ key: String) {
        label = Label(key, font: .systemFont(ofSize: 11, weight: .semibold), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        label.alignment = .center
        addSubview(label)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    // Clicks go to the button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var width: CGFloat { max(Self.height + 4, label.inkWidth + Tokens.Space.x3) }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: Self.height) }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - label.lineHeight) / 2, width: bounds.width, height: label.lineHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        let ink = onAccent ? Brand.Theme.current.onAccent : Tokens.Color.textSecondary
        label.textColor = ink
        layer?.backgroundColor = cgColor(onAccent ? ink.withAlphaComponent(0.18) : Tokens.Color.fieldFill)
    }
}
