import AppKit

/// "Save password for github.com?" A calm panel at the top of the page, under the address. The username can be
/// corrected before saving; Never for This Site is remembered (and synced) so it never asks there again.
final class SavePasswordPrompt: FloatingPanelView {
    enum Kind {
        case save(username: String)
        case update(Credential)
    }

    private static weak var current: SavePasswordPrompt?

    private let icon = NSImageView()
    private let titleLabel: Label
    private let usernameField = FilledField(placeholder: "Username")
    private let usernameText = Label("", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    private let isUpdate: Bool
    private let saveButton: PrimaryButton
    private let notNowButton = TextButton(title: "Not Now", font: Tokens.Font.body(.medium))
    private let neverButton = TextButton(title: "Never for This Site", font: Tokens.Font.body(.medium))
    private var hideWork: DispatchWorkItem?
    private var finish: (Bool) -> Void = { _ in }

    static let width: CGFloat = 340

    /// The username is a field to correct when saving, and plain text when updating.
    private var fieldHeight: CGFloat { isUpdate ? Tokens.Space.x5 : Tokens.Space.x8 }

    private init(kind: Kind, origin: Origin) {
        switch kind {
        case .save: titleLabel = Label("Save password for \(origin.displayName)?", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
        case .update: titleLabel = Label("Update password for \(origin.displayName)?", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
        }
        isUpdate = { if case .update = kind { true } else { false } }()
        saveButton = PrimaryButton(title: { if case .update = kind { "Update" } else { "Save" } }())
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        icon.image = origin.url.flatMap { FaviconStore.shared.cachedIcon(for: $0) } ?? Tokens.Symbol.image("key.fill")
        icon.imageScaling = .scaleProportionallyUpOrDown
        switch kind {
        case .save(let username):
            usernameField.stringValue = username
            addSubview(usernameField)
        case .update(let credential):
            usernameText.stringValue = credential.username.isEmpty ? "No username" : credential.username
            addSubview(usernameText)
        }
        [icon, titleLabel, neverButton, notNowButton, saveButton].forEach { addSubview($0) }
        neverButton.isHidden = { if case .update = kind { true } else { false } }()
        frame.size.height = Tokens.Space.x4 * 2 + Tokens.Space.x6 + Tokens.Space.x3 + fieldHeight + Tokens.Space.x3 + Tokens.Space.x8
        onLayout = { [weak self] in self?.layoutContent() }
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
    }

    /// Goes away on its own after a while, unless the pointer is on it.
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.superview != nil else { return }
                if let window = self.window, self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) || window.firstResponder === self.usernameField.field.currentEditor() {
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
        if Self.current === self { Self.current = nil }
        let finish = self.finish
        self.finish = { _ in }
        finish(saved)
        dismiss(always: true)
    }

    private func layoutContent() {
        let pad = Tokens.Space.x4
        let iconSize = Tokens.Space.x6
        icon.frame = NSRect(x: pad, y: pad, width: iconSize, height: iconSize)
        let textX = icon.frame.maxX + Tokens.Space.x3
        titleLabel.frame = NSRect(x: textX, y: pad + (iconSize - titleLabel.lineHeight) / 2, width: bounds.width - textX - pad, height: titleLabel.lineHeight)
        let fieldY = icon.frame.maxY + Tokens.Space.x3
        if isUpdate {
            usernameText.frame = NSRect(x: textX, y: fieldY - Tokens.Space.x1, width: bounds.width - textX - pad, height: fieldHeight)
        } else {
            usernameField.frame = NSRect(x: textX, y: fieldY, width: bounds.width - textX - pad, height: fieldHeight)
        }
        let buttonY = fieldY + fieldHeight + Tokens.Space.x3
        let h = Tokens.Space.x8
        let saveWidth = max(saveButton.fittingWidth, 72)
        saveButton.frame = NSRect(x: bounds.width - pad - saveWidth, y: buttonY, width: saveWidth, height: h)
        let notNowWidth = notNowButton.fittingWidth
        notNowButton.frame = NSRect(x: saveButton.frame.minX - Tokens.Space.x2 - notNowWidth, y: buttonY, width: notNowWidth, height: h)
        neverButton.frame = NSRect(x: pad - Tokens.Space.x2, y: buttonY, width: neverButton.fittingWidth, height: h)
    }
}
