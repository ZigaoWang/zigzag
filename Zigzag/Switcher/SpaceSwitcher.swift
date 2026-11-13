import AppKit

/// Where the space switcher's choice is, and what a key does to it. Kept apart from the panel so it can be tested.
nonisolated struct SpaceChoice: Equatable {
    let count: Int
    private(set) var index: Int

    /// Starts on the space you're in.
    init(count: Int, current: Int) {
        self.count = count
        index = count == 0 ? 0 : min(max(current, 0), count - 1)
    }

    /// Moves the choice, running round past either end, as Command+Tab does.
    mutating func step(_ delta: Int) {
        guard count > 0 else { return }
        index = ((index + delta) % count + count) % count
    }

    /// 1 to 9: that space, as ⌃1 to ⌃9 count them. False when there's no such space.
    mutating func jump(to number: Int) -> Bool {
        guard (1...9).contains(number), number <= count else { return false }
        index = number - 1
        return true
    }

    enum Key: Equatable { case step(Int), choose, cancel, number(Int) }

    /// What a key pressed while the list is up means, or nil for one it leaves alone.
    static func key(code: UInt16, characters: String?, shift: Bool) -> Key? {
        switch code {
        case 53 /* esc */: return .cancel
        case 36, 76 /* return, enter */: return .choose
        case 125, 124 /* ↓, → */: return .step(1)
        case 126, 123 /* ↑, ← */: return .step(-1)
        case 48 /* tab */: return .step(shift ? -1 : 1)
        default:
            guard !shift, let characters, characters.count == 1, let n = Int(characters), (1...9).contains(n) else { return nil }
            return .number(n)
        }
    }
}

/// One space in the switcher: its icon, or a dot of its color, and its name; its profile's name once there's more
/// than one, quiet after it, as the sidebar's header shows it; its ⌃ number at the end.
final class SpaceChoiceRow: InteractiveView {
    private let iconView = NSImageView()
    private let dot = CALayer()
    private let name = Label("", font: Tokens.Font.row(), color: Tokens.Color.textPrimary)
    private let number = Label("", font: Tokens.Font.figures(Tokens.TypeSize.body), color: Tokens.Color.textTertiary)
    private let profile = Label("", font: Tokens.Font.row(), color: Tokens.Color.textTertiary)
    private var swatch: NSColor = .gray
    /// The space you're in, which VoiceOver says.
    var isCurrent = false { didSet { stateDidChange(animated: false) } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.row
        layer?.cornerCurve = .continuous
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        iconView.contentTintColor = Tokens.Color.icon
        layer?.addSublayer(dot)
        name.lineBreakMode = .byTruncatingTail
        number.alignment = .right
        profile.lineBreakMode = .byTruncatingTail
        [iconView, name, profile, number].forEach { addSubview($0) }
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ space: SpaceInfo, position: Int, profileName: String? = nil) {
        swatch = space.swatch
        iconView.image = space.icon.map { IconChoice.image($0, size: Tokens.Metric.favicon) }
        iconView.isHidden = space.icon == nil
        dot.isHidden = space.icon != nil
        name.stringValue = space.name
        number.stringValue = position <= 9 ? "\(position)" : ""
        profile.stringValue = profileName ?? ""
        profile.isHidden = profileName == nil
        setAccessibilityLabel(profileName.map { String(localized: "\(space.name), \($0)", comment: "What VoiceOver says for a space in the space switcher with more than one profile: the space's name, then its profile's.") } ?? space.name)
        needsLayout = true
    }

    /// How wide the row wants to be for its name to show whole.
    var fittingWidth: CGFloat {
        CommandRowView.titleX - Label.inset + name.textWidth + (profile.stringValue.isEmpty ? 0 : Tokens.Space.x3 + profile.textWidth)
            + Tokens.Space.x4 + number.textWidth + CardRow.inset
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateDidChange(animated: false)
    }

    override func layout() {
        super.layout()
        let inset = CardRow.inset
        let side = Tokens.Metric.favicon
        iconView.frame = NSRect(x: inset, y: (bounds.height - side) / 2, width: side, height: side)
        // The dot the space menus draw for a space, centered where an icon would be.
        let d = Tokens.Space.x3 - 2
        Tokens.Motion.withoutAnimation {
            dot.frame = CGRect(x: iconView.frame.midX - d / 2, y: (bounds.height - d) / 2, width: d, height: d)
            dot.cornerRadius = d / 2
        }
        let nw = number.textWidth
        number.frame = NSRect(x: bounds.width - inset - nw + Label.inset, y: (bounds.height - number.lineHeight) / 2, width: nw, height: number.lineHeight)
        let x = CommandRowView.titleX - Label.inset
        let right = number.stringValue.isEmpty ? bounds.width - inset : number.frame.minX - Tokens.Space.x2
        // The name first; the profile's after it in what room is left, cut short before the name is.
        let room = right - x
        let profileWidth = profile.stringValue.isEmpty ? 0 : min(profile.textWidth, max(0, room - name.textWidth - Tokens.Space.x3))
        let nameWidth = max(0, min(name.textWidth, room - (profileWidth > 0 ? profileWidth + Tokens.Space.x3 : 0)))
        name.frame = NSRect(x: x, y: round((bounds.height - name.lineHeight) / 2), width: nameWidth, height: name.lineHeight)
        profile.frame = NSRect(x: name.frame.maxX + Tokens.Space.x3, y: name.frame.minY, width: profileWidth, height: profile.lineHeight)
        profile.isHidden = profile.stringValue.isEmpty || profileWidth < SpaceHeaderView.profileRoom
    }

    override func stateDidChange(animated: Bool) {
        // VoiceOver says which space you're in, as the sidebar's space buttons do.
        setAccessibilityValue(isCurrent ? String(localized: "current space", comment: "Spoken by VoiceOver after a space's button at the bottom of the sidebar: it's the space you're in.") : nil)
        setAccessibilitySelected(isSelected)
        // The choice in the soft card Control+Tab gives its chosen tab. The space you're in has no mark of its own:
        // the list starts on it, and the sidebar names it. Hover moves the choice, so it has no fill of its own.
        let fill: NSColor? = isSelected ? (isPressed ? Tokens.Color.selectedHoverFill : Tokens.Color.selectedFill) : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: false)
        setLifted(isSelected)
        Tokens.Motion.withoutAnimation { dot.backgroundColor = cgColor(swatch) }
    }
}

/// ⌥⌘S: the spaces in a list over the page, in the sidebar's order, the one you're in chosen to start. The arrows
/// or Tab move, Return goes there, a number goes straight to that space, Esc or a click elsewhere leaves it be.
/// Pressed again while it's up, the shortcut moves on to the next, as Command+Tab does.
final class SpaceSwitcher {
    private weak var controller: BrowserWindowController?
    private let panel = FloatingPanelView()
    private var rows: [SpaceChoiceRow] = []
    private var spaces: [UUID] = []
    private var choice = SpaceChoice(count: 0, current: 0)
    private(set) var isActive = false
    private var mouseAtOpen: NSPoint = .zero

    init(controller: BrowserWindowController) {
        self.controller = controller
        // The rows' corners plus the step between them and the panel's edge.
        panel.radius = Tokens.Radius.row + Self.listInset
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.list)
        panel.setAccessibilityLabel(String(localized: "Spaces", comment: "VoiceOver name of the space switcher: the list of spaces to pick one from with the keyboard."))
        // Another menu command while the list is up (⌘T, ⌘W): the list goes first, and the command does what it does.
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: nil) { [weak self] note in
            let action = (note.userInfo?["MenuItem"] as? NSMenuItem)?.action
            MainActor.assumeIsolated {
                guard let self, self.isActive, action != #selector(BrowserWindowController.showSpaceSwitcher(_:)) else { return }
                self.cancel()
            }
        }
    }

    private var menuObserver: NSObjectProtocol?

    isolated deinit { menuObserver.map(NotificationCenter.default.removeObserver) }

    private static let listInset = Tokens.Space.x1

    /// The menu item's action: opens the list, or with it open, moves to the next space.
    func toggle() {
        if isActive { step(1) } else { begin() }
    }

    /// Returns true if the event was handled.
    func handle(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // The switcher's own shortcut again, or with ⇧ added, back the other way.
            if let combo = Self.shortcut, !combo.key.isEmpty, flags.subtracting(.shift) == combo.flags.subtracting(.shift),
               event.charactersIgnoringModifiers?.lowercased() == combo.key.lowercased() {
                step(flags.contains(.shift) && !combo.flags.contains(.shift) ? -1 : 1)
                return true
            }
            // Anything else with ⌘ the menus didn't take: the list goes, and the key is yours.
            if flags.contains(.command) { cancel(); return false }
            switch SpaceChoice.key(code: event.keyCode, characters: event.charactersIgnoringModifiers, shift: flags.contains(.shift)) {
            case .cancel: cancel()
            case .choose: commit()
            case .step(let delta): step(delta)
            case .number(let n): if choice.jump(to: n) { commit() } else { NSSound.beep() }
            case nil: break
            }
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click on a row is the row's; anywhere else puts the list away, and does nothing more.
            let point = panel.convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseDown, panel.bounds.contains(point) { return false }
            cancel()
            return true
        case .scrollWheel:
            return true
        default:
            return false
        }
    }

    /// The menu item's keys as they are now, set in Settings › Shortcuts or as shipped.
    private static var shortcut: Shortcuts.Combo? {
        Shortcuts.allItems.first { $0.action == #selector(BrowserWindowController.showSpaceSwitcher(_:)) }
            .map { Shortcuts.Combo(key: $0.keyEquivalent, modifiers: $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue) }
    }

    private func begin() {
        guard let controller, !controller.tabManager.isPrivate else { return }
        let all = Library.shared.spaces
        guard all.count > 1 else { return }
        if controller.commandBar.isVisible { controller.commandBar.dismiss(restoringFocus: false) }
        spaces = all.map(\.id)
        let current = all.firstIndex { $0.id == controller.tabManager.currentSpaceID } ?? 0
        choice = SpaceChoice(count: all.count, current: current)
        isActive = true
        mouseAtOpen = NSEvent.mouseLocation
        rows.forEach { $0.removeFromSuperview() }
        rows = all.enumerated().map { i, space in
            let row = SpaceChoiceRow()
            row.configure(space, position: i + 1, profileName: Library.shared.directory.shownName(ofSpace: space.id, spaceName: space.name))
            row.isCurrent = i == current
            row.onClick = { [weak self] _ in
                guard let self else { return }
                self.choice.step(i - self.choice.index)
                self.commit()
            }
            row.hoverChanged = { [weak self] hovering in
                // Only a mouse that actually moved picks a row; a resting cursor must not steal the choice.
                guard let self, hovering, NSEvent.mouseLocation != self.mouseAtOpen else { return }
                self.step(i - self.choice.index)
            }
            panel.addSubview(row)
            return row
        }
        // Centered on the whole window, as Control+Tab is.
        let area = controller.root.overlay.bounds
        let inset = Self.listInset
        let fitting = rows.map(\.fittingWidth).max() ?? 0
        let width = round(min(max(fitting + inset * 2, Tokens.Metric.switcherThumbWidth + Tokens.Space.x8), min(Tokens.Metric.previewWidth + Tokens.Space.x16, area.width - Tokens.Space.x16)))
        // Taller than the page has room for, the rows take the sidebar's size.
        let room = area.height - Tokens.Space.x16 - inset * 2
        let rowHeight = CGFloat(rows.count) * Tokens.Metric.commandBarRowHeight <= room ? Tokens.Metric.commandBarRowHeight : Tokens.Sidebar.rowHeight
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: inset, y: inset + CGFloat(i) * rowHeight, width: width - inset * 2, height: rowHeight)
        }
        let height = min(inset * 2 + CGFloat(rows.count) * rowHeight, area.height - Tokens.Space.x8)
        panel.frame = NSRect(x: round(area.midX - width / 2), y: round(area.midY - height / 2), width: width, height: height)
        controller.root.overlay.addSubview(panel)
        // Summoned and stepped through with keys: simply there.
        panel.present(arrival: .instant)
        updateSelection()
    }

    private func step(_ delta: Int) {
        guard isActive else { return }
        choice.step(delta)
        updateSelection()
    }

    private func updateSelection() {
        for (i, row) in rows.enumerated() { row.isSelected = i == choice.index }
        if rows.indices.contains(choice.index) {
            let row = rows[choice.index]
            Announcement.post(row.isCurrent
                ? String(localized: "\(row.accessibilityLabel() ?? ""), current space", comment: "Spoken by VoiceOver as the space switcher's choice moves to the space you're in. The placeholder is its name.")
                : row.accessibilityLabel() ?? "", priority: .high)
        }
    }

    private func commit() {
        guard isActive else { return }
        let target = spaces.indices.contains(choice.index) ? spaces[choice.index] : nil
        finish()
        // Deleted while the list was up (another window): nowhere to go.
        if let target, Library.shared.space(target) != nil { controller?.tabManager.switchToSpace(target) }
    }

    private func cancel() { finish() }

    /// The window lost focus while the list was up: put it away, staying where you are.
    func windowResignedKey() { if isActive { cancel() } }

    private func finish() {
        isActive = false
        panel.dismiss(instantly: true)
    }

    #if DEBUG
    /// debug: the rows as drawn, and which is chosen.
    var debugState: String {
        rows.enumerated().map { i, row in "\(i == choice.index ? ">" : " ")\(row.isCurrent ? "*" : " ")\(row.accessibilityLabel() ?? "")" }.joined(separator: "\n")
    }
    #endif
}
