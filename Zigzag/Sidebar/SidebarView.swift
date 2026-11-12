import AppKit

protocol SidebarDelegate: SidebarListDelegate {
    func sidebarOpenCommandBar()
    func sidebarSwitchSpace(_ id: UUID)
    /// The + at the bottom: what it can add.
    func sidebarAddMenu() -> [MenuPanel.Entry]
    /// Right-click on the sidebar where there's no row or button of its own.
    func sidebarBlankMenu() -> [MenuPanel.Entry]
    func sidebarShowDownloads(from view: NSView)
    func sidebarSpaceMenu(for id: UUID) -> NSMenu?
}

/// The address at the top of the sidebar. Shows only the domain; clicking opens the command bar.
final class AddressView: InteractiveView {
    /// In the bar above the page, on the page's own color: a page's neutral field rather than the frame's wash.
    var isOnPage = false { didSet { if isOnPage != oldValue { stateDidChange(animated: false) } } }
    private let label = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textSecondary)
    private let lock = NSImageView()
    /// Shows while the page uses the camera or microphone; click for options.
    /// Buttons inside the field: the same size, the same gap all round, corners that follow the field's.
    static let buttonSide: CGFloat = Tokens.Sidebar.addressButton
    static let buttonInset: CGFloat = (Tokens.Sidebar.addressHeight - buttonSide) / 2
    static func button(_ symbol: String, toolTip: String) -> IconButton {
        IconButton(symbol: symbol, size: buttonSide, symbolSize: Tokens.Sidebar.addressGlyph, toolTip: toolTip)
    }
    let captureButton = AddressView.button("video.fill", toolTip: String(localized: "Camera and Microphone", comment: "Tooltip of the address bar's button that shows while a page uses the camera or microphone."))
    /// Shown on articles: opens Reader.
    let readerButton = AddressView.button("doc.plaintext", toolTip: String(localized: "Show Reader", comment: "Tooltip of the address bar's Reader button."))

    func setCapture(camera: Bool, microphone: Bool) {
        wantsCapture = camera || microphone
        captureButton.symbol = camera ? "video.fill" : "mic.fill"
        captureButton.tint = .systemOrange
        captureButton.toolTip = camera && microphone ? String(localized: "Using your camera and microphone", comment: "Tooltip of the address bar's capture button: the page uses both.")
            : camera ? String(localized: "Using your camera", comment: "Tooltip of the address bar's capture button: the page uses the camera.") : String(localized: "Using your microphone", comment: "Tooltip of the address bar's capture button: the page uses the microphone.")
        reflow(animated: true)
    }

    /// Everything about this page, at the field's right end: always there, even on a new tab.
    let siteControlsButton = AddressView.button("slider.horizontal.3", toolTip: String(localized: "Site Controls", comment: "Name of the button by the address that opens the site panel: its tooltip and VoiceOver name."))
    private var siteControlsBadge: BadgeView?

    /// The dot on Site Controls while an extension can't work until you do something.
    func setSiteControls(needsAttention: Bool) {
        guard needsAttention != (siteControlsBadge != nil) else { return }
        siteControlsBadge?.removeFromSuperview()
        siteControlsBadge = nil
        guard needsAttention else { return }
        let badge = BadgeView(text: "!", attention: true)
        siteControlsButton.addSubview(badge)
        siteControlsBadge = badge
    }

    /// An extension pinned to the address, as its button should look now.
    struct Pin {
        let id: String
        var image: NSImage?
        var label: String
        /// A short count or word in the corner.
        var badge = ""
        var needsAttention = false
        /// Its popup is open in this window.
        var isActive = false
        var action: (IconButton) -> Void
        var menu: () -> NSMenu?
    }

    /// A pin's button lives as long as the pin: updates change it in place, so nothing flickers and a popup opened
    /// from it stays where it is.
    private final class PinEntry {
        let button: IconButton
        var badge: BadgeView?
        var pin: Pin
        init(pin: Pin, button: IconButton) {
            self.pin = pin
            self.button = button
        }
    }
    private var pinEntries: [PinEntry] = []
    /// The pins showing now, left to right. Those that don't fit wait in Site Controls.
    private(set) var visiblePinIDs: [String] = []

    /// Pinned buttons moved, or some started or stopped showing.
    var onPinsMoved: (() -> Void)?

    func pinButton(for id: String) -> IconButton? { pinEntries.first { $0.pin.id == id }?.button }

    /// The pins as they are now, left to right.
    func setPins(_ pins: [Pin], animated: Bool) {
        // Mid-drag, what a button says still changes at once; which buttons there are waits for the drop.
        if pinDrag != nil {
            for pin in pins { if let entry = pinEntries.first(where: { $0.pin.id == pin.id }) { update(entry, to: pin) } }
            pendingPins = (pins, animated)
            return
        }
        let kept = Set(pins.map(\.id))
        for gone in pinEntries where !kept.contains(gone.pin.id) { takeAway(gone.button, animated: animated, removing: true) }
        let existing = Dictionary(uniqueKeysWithValues: pinEntries.map { ($0.pin.id, $0) })
        pinEntries = pins.map { pin in
            let entry = existing[pin.id] ?? makeEntry(pin)
            update(entry, to: pin)
            return entry
        }
        reflow(animated: animated)
    }

    private func makeEntry(_ pin: Pin) -> PinEntry {
        let button = AddressView.button("puzzlepiece.extension", toolTip: pin.label)
        button.isHidden = true
        let entry = PinEntry(pin: pin, button: button)
        button.onClick = { [weak entry, weak button] _ in if let entry, let button { entry.pin.action(button) } }
        button.onRightClick = { [weak entry] _ in entry?.pin.menu() }
        button.dragsHorizontally = true
        // A site's icon's size, in the middle, so it reads as big as Reader's and Site Controls' glyphs beside it.
        button.imageSide = Tokens.Sidebar.addressIcon
        addSubview(button)
        return entry
    }

    private func update(_ entry: PinEntry, to pin: Pin) {
        entry.pin = pin
        let button = entry.button
        button.image = pin.image
        button.isSelected = pin.isActive
        button.toolTip = pin.needsAttention ? String(localized: "\(pin.label): needs attention", comment: "Tooltip of an extension's button in the site panel when the extension asks for attention. The name is the extension's.") : pin.label
        // VoiceOver reads the extension's name, then what its badge says.
        button.setAccessibilityLabel(pin.label)
        button.setAccessibilityValue(pin.needsAttention ? String(localized: "Needs attention", comment: "VoiceOver value of an extension's button in the site panel when the extension asks for attention.") : pin.badge.isEmpty ? nil : pin.badge)
        let text = pin.needsAttention ? "!" : pin.badge
        if text.isEmpty {
            entry.badge?.removeFromSuperview()
            entry.badge = nil
        } else if let badge = entry.badge {
            badge.update(text: text, attention: pin.needsAttention)
        } else {
            // The count in the button's bottom-right corner, over the icon's, inside the button.
            let badge = BadgeView(text: text, attention: pin.needsAttention)
            button.addSubview(badge)
            entry.badge = badge
        }
    }

    /// How many of `count` pins can show when `otherButtons` share the end of a field with `room` for text and
    /// buttons: the site's name keeps its minimum, and every button takes its width and a gap.
    /// `text`: the width of the site's name, or the prompt, in full: pins give way before it's cut short.
    static func pinsThatFit(count: Int, otherButtons: Int, room: CGFloat, text: CGFloat = 0) -> Int {
        let spare = room - max(Tokens.Sidebar.addressMinText, ceil(text)) - CGFloat(otherButtons) * pinStep
        return max(0, min(count, Int(floor(spare / pinStep))))
    }

    /// From one button in the field to the next.
    private static let pinStep = buttonSide + 2

    // MARK: Reordering pins

    /// The showing pins in the order they were dropped in.
    var onPinsReordered: (([String]) -> Void)?
    /// A pinned button was picked up.
    var onPinDragBegan: (() -> Void)?

    /// A pin being carried along the field: the showing pins when it was picked up, its copy (none outside a window),
    /// and the gap it would drop into (nil: off the field).
    private struct PinDrag {
        let entry: PinEntry
        let order: [PinEntry]
        let from: Int
        let copy: CarriedCopy?
        var slot: Int?
    }
    private var pinDrag: PinDrag?
    private var pendingPins: (pins: [Pin], animated: Bool)?
    /// Where a carried pin would go, between two others: the space icons' line, at the field's buttons' size.
    private let pinDropLine: ColorView = {
        let line = ColorView(color: Tokens.Color.accent)
        line.wantsLayer = true
        line.layer?.cornerRadius = 1
        line.isHidden = true
        return line
    }()

    private var showingEntries: [PinEntry] { Array(pinEntries.suffix(visiblePinIDs.count)) }

    /// Picks a pin up, as a space icon is: it stays in its place, faint, a see-through copy follows the pointer, and a
    /// line between two pins shows where it would go. Let go on the field, it moves there; off it, or with Esc, it
    /// goes back.
    private func dragPin(_ entry: PinEntry, event: NSEvent) -> Bool {
        guard let window, beginPinDrag(entry.pin.id, at: event.locationInWindow) else { return false }
        let released = CarriedCopy.track(in: window) { self.movePinDrag(to: $0.locationInWindow) }
        endPinDrag(drop: released != nil)
        return true
    }

    /// Picks up a showing pin, the pointer at `point` in the window.
    @discardableResult
    func beginPinDrag(_ id: String, at point: NSPoint) -> Bool {
        let order = showingEntries
        guard pinDrag == nil, order.count > 1, let from = order.firstIndex(where: { $0.pin.id == id }) else { return false }
        let entry = order[from]
        onPinDragBegan?()
        let button = entry.button
        var copy: CarriedCopy?
        if let window {
            copy = CarriedCopy(of: button, picture: CarriedCopy.picture(of: button), grabbedAt: window.convertPoint(toScreen: point),
                               ground: Tokens.Color.panelBackground, radius: button.radius)
        }
        button.isPressed = false
        button.isHovered = false
        button.alphaValue = CarriedCopy.faint
        copy?.lift()
        pinDrag = PinDrag(entry: entry, order: order, from: from, copy: copy, slot: nil)
        return true
    }

    /// Whether a pointer at this window point is on the field: anywhere along it, a little above and below it too;
    /// past either end of the pins is the first or last place.
    private func isOnField(_ point: NSPoint) -> Bool {
        bounds.insetBy(dx: 0, dy: -Tokens.Space.x2).contains(convert(point, from: nil))
    }

    /// The copy follows the pointer; nothing in the field moves, only the line shows where the pin would go.
    func movePinDrag(to point: NSPoint) {
        guard var drag = pinDrag else { return }
        if let window { drag.copy?.follow(window.convertPoint(toScreen: point)) }
        drag.slot = isOnField(point) ? SpaceReorder.slot(at: convert(point, from: nil).x, middles: drag.order.map(\.button.frame.midX)) : nil
        pinDrag = drag
        let from = drag.from
        placePinDropLine(drag.slot.flatMap { SpaceReorder.destination(slot: $0, from: from) == nil ? nil : $0 }, among: drag.order)
    }

    /// Where the drag would drop the pin now; nil where it would stay.
    var pinDropDestination: Int? {
        guard let drag = pinDrag, let slot = drag.slot else { return nil }
        return SpaceReorder.destination(slot: slot, from: drag.from)
    }

    /// The line in the gap before pin `slot` (after the last for the end); nil hides it.
    private func placePinDropLine(_ slot: Int?, among order: [PinEntry]) {
        guard let slot, let first = order.first?.button, let last = order.last?.button else { pinDropLine.isHidden = true; return }
        // The middle of the gap between two buttons.
        let x = slot < order.count ? order[slot].button.frame.minX - 1 : last.frame.maxX + 1
        let width: CGFloat = 2, height = max(Tokens.Space.x2, first.frame.height - 12)
        if pinDropLine.superview == nil { addSubview(pinDropLine) }
        Tokens.Motion.withoutAnimation {
            pinDropLine.frame = NSRect(x: x - width / 2, y: first.frame.midY - height / 2, width: width, height: height)
        }
        pinDropLine.isHidden = false
    }

    /// Lets go: dropped on the field (`drop`) the pin moves to the gap the line showed and the copy lands in its new
    /// place; called off, it lands back where it was.
    func endPinDrag(drop: Bool) {
        guard let drag = pinDrag else { return }
        let to = drop ? pinDropDestination : nil
        pinDrag = nil
        placePinDropLine(nil, among: [])
        var order = drag.order
        if let to {
            order.remove(at: drag.from)
            order.insert(drag.entry, at: to)
            pinEntries = pinEntries.dropLast(order.count) + order
        }
        let dropped = order.map(\.pin.id)
        // What waited for the drop lands now, in the dropped order, whatever the store goes on to say.
        if let pending = pendingPins {
            pendingPins = nil
            let ids = ExtensionPins(ids: pending.pins.map(\.id)).reordered(visible: dropped).ids
            setPins(ids.compactMap { id in pending.pins.first { $0.id == id } }, animated: pending.animated)
        }
        if to != nil { onPinsReordered?(dropped) }
        reflow(animated: true)
        let button = drag.entry.button
        button.alphaValue = 1
        if let copy = drag.copy {
            copy.land(on: button.superview === self && !button.isHidden ? button : nil)
        }
    }

    #if DEBUG
    /// pindump <path>: every view in the field, one a line, to check that each pin has one button and nothing is left over.
    func debugDump(to path: String) {
        let pins = Dictionary(uniqueKeysWithValues: pinEntries.map { (ObjectIdentifier($0.button), $0.pin.id) })
        var lines = ["visible \(visiblePinIDs.joined(separator: ",")) entries \(pinEntries.count) dragging \(pinDrag != nil)"]
        for view in subviews {
            let name = pins[ObjectIdentifier(view)].map { "pin \($0)" } ?? String(describing: type(of: view))
            lines.append("\(name) frame=\(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue) opacity=\(view.layer?.opacity ?? -1) anims=\(view.layer?.animationKeys() ?? [])")
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// pindrag begin <id> | move <x> [y] (window points, top-left; y defaults to the field's middle) | drop | cancel:
    /// the drag a pointer would make, through the same steps.
    func debugPinDrag(_ arg: String) {
        guard let window else { return }
        let f = arg.split(separator: " ").map(String.init)
        let middle = convert(NSPoint(x: 0, y: bounds.midY), to: nil).y
        switch f.first {
        case "begin":
            guard f.count >= 2, let button = pinButton(for: f[1]) else { return }
            _ = beginPinDrag(f[1], at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        case "move":
            guard f.count >= 2, let x = Double(f[1]) else { return }
            let y = f.count >= 3 ? Double(f[2]).map { window.frame.height - $0 } ?? middle : middle
            movePinDrag(to: NSPoint(x: x, y: y))
        case "drop": endPinDrag(drop: true)
        case "cancel": endPinDrag(drop: false)
        default: break
        }
    }
    #endif

    /// Moves a showing pin one place, as a drag does: Move Left and Move Right, by menu or VoiceOver.
    func movePin(_ id: String, by offset: Int) {
        var order = visiblePinIDs
        guard let from = order.firstIndex(of: id), order.indices.contains(from + offset) else { return }
        order.swapAt(from, from + offset)
        onPinsReordered?(order)
    }

    /// Named for VoiceOver, as the space dots are.
    private func updatePinControls(_ showing: [PinEntry]) {
        for entry in pinEntries { entry.button.onDragStart = nil; entry.button.setAccessibilityCustomActions(nil) }
        guard showing.count > 1 else { return }
        for (index, entry) in showing.enumerated() {
            entry.button.onDragStart = { [weak self, weak entry] event in
                guard let self, let entry else { return false }
                return self.dragPin(entry, event: event)
            }
            let id = entry.pin.id
            var actions: [NSAccessibilityCustomAction] = []
            if index > 0 { actions.append(moveAction(id, by: -1)) }
            if index < showing.count - 1 { actions.append(moveAction(id, by: 1)) }
            entry.button.setAccessibilityCustomActions(actions)
        }
    }

    private func moveAction(_ id: String, by offset: Int) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: offset < 0 ? Self.moveLeftTitle : Self.moveRightTitle) { [weak self] in
            MainActor.assumeIsolated { self?.movePin(id, by: offset) }
            return true
        }
    }

    /// The same words as the space icons' actions.
    static let moveLeftTitle = String(localized: "Move Left", comment: "Item in the menu of an extension pinned to the address bar, and VoiceOver action on its button there: moves it one place to the left.")
    static let moveRightTitle = String(localized: "Move Right", comment: "Item in the menu of an extension pinned to the address bar, and VoiceOver action on its button there: moves it one place to the right.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Sidebar.addressRadius
        layer?.cornerCurve = .continuous
        // Keyboard focus: the accent ring, as a field's.
        lock.imageScaling = .scaleNone
        lock.contentTintColor = Tokens.Color.textTertiary
        addSubview(lock)
        // Set with each name (`lineBreak(forName:)`): a long host never loses the end that says whose site it is.
        label.lineBreakMode = .byTruncatingHead
        addSubview(label)
        captureButton.isHidden = true
        addSubview(captureButton)
        readerButton.isHidden = true
        addSubview(readerButton)
        addSubview(siteControlsButton)
        setAccessibilityRole(.button)
        setAccessibilityHelp(String(localized: "Opens the command bar", comment: "Accessibility help of the address in the sidebar."))
    }

    required init?(coder: NSCoder) { fatalError() }

    func setReader(available: Bool, active: Bool) {
        wantsReader = available || active
        readerButton.isSelected = active
        readerButton.toolTip = Shortcuts.tooltip(active ? String(localized: "Hide Reader", comment: "Tooltip of the address bar's Reader button while Reader is on.")
                                                         : String(localized: "Show Reader", comment: "Tooltip of the address bar's Reader button."),
                                                  for: #selector(BrowserWindowController.toggleReader(_:)))
        reflow(animated: true)
    }

    /// The site's name as the address shows it: without "www.", with a port that isn't the usual one, so
    /// "accounts.google.com:81" never reads as Google's own.
    private static func site(_ host: String, port: Int?, scheme: String?) -> String {
        let name = host.withoutWWW
        let usual = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        guard let port, port != usual else { return name }
        return "\(name):\(port)"
    }

    /// The page's name as the address shows it: its site, or what a page with no site is (History, an extension's
    /// own page, a file). Empty for a blank page.
    static func name(of url: URL?) -> String {
        if #available(macOS 15.4, *), let ext = ExtensionCenter.webExtension(ofPage: url) {
            // An extension's own page (its settings) is named after the extension, not its random address.
            return ext.displayName ?? String(localized: "Extension", comment: "The address bar's name for an extension's own page, when the extension has no name.")
        } else if HistoryPage.isHistory(url) {
            return String(localized: "History", comment: "The address bar's name for Zigzag's History page.")
        } else if SettingsPage.isSettings(url) {
            return String(localized: "Settings", comment: "The address bar's name for Zigzag's Settings page.")
        } else if let url, let host = url.host() {
            return site(host, port: url.port, scheme: url.scheme)
        } else if let url, url.isFileURL {
            return url.lastPathComponent
        } else if let url, url.scheme == "blob", let inner = URL(string: url.path), let host = inner.host() {
            // A page made by a site's own script: named for the site that made it.
            return site(host, port: inner.port, scheme: inner.scheme)
        } else if let url, let scheme = url.scheme, scheme != "about" || url.absoluteString != "about:blank" {
            // A page with no site (data:): said so, never left looking like an empty address bar.
            return scheme == "about" ? url.absoluteString : String(localized: "\(scheme): page", comment: "The address bar's name for a page with no site, like a data: page. The placeholder is the address's scheme, like “data”.")
        }
        return ""
    }

    /// How a site's name too long for its room is shortened. Its subdomains go first, from the start, so the domain
    /// that says whose site it is stays whole ("…mail.google.com"). A domain that alone is too long keeps its start and
    /// its end ("physicsandm…tutor.com"), so it reads as itself and its ending still shows.
    static func lineBreak(forName name: String) -> NSLineBreakMode {
        guard name.contains("."), let domain = PublicSuffix.registrableDomain(name.lowercased()) else { return .byTruncatingTail }
        return domain == name.lowercased() ? .byTruncatingMiddle : .byTruncatingHead
    }

    func show(url: URL?, isSecure: Bool) {
        label.stringValue = Self.name(of: url)
        label.lineBreakMode = Self.lineBreak(forName: label.stringValue)
        // The host crisp, in the text's own color; the prompt quiet.
        label.textColor = label.stringValue.isEmpty ? Tokens.Color.textTertiary : Tokens.Color.textPrimary
        if label.stringValue.isEmpty { label.stringValue = String(localized: "Search or enter address", comment: "Placeholder of the address in the sidebar, on a new tab.") }
        // Only a plain http page marks itself, with the not-secure symbol before the host.
        let insecure = url?.scheme == "http"
        lock.image = insecure ? Tokens.Symbol.image(SitePanel.notSecureSymbol, size: Tokens.Symbol.inline) : nil
        lock.isHidden = !insecure
        lock.toolTip = insecure ? SitePanel.notSecure : nil
        setAccessibilityLabel(insecure ? String(localized: "\(label.stringValue), \(SitePanel.notSecure)", comment: "Accessibility label of the address in the sidebar on a plain http page: the site, then that it's not secure.") : label.stringValue)
        reflow(animated: true)
    }

    override func layout() {
        super.layout()
        // A resize follows the pointer, so nothing here animates; changes of what's showing go through `reflow`.
        reflow(animated: false)
    }

    private var wantsReader = false
    private var wantsCapture = false
    /// The buttons drawn in the field, those leaving aside.
    private var drawn = Set<ObjectIdentifier>()

    /// Works out what fits and puts everything in its place. The one place the field is laid out, so a button and the
    /// text beside it never disagree; when nothing changed it does nothing, as it runs throughout a page load.
    private func reflow(animated requested: Bool) {
        // While a pin is carried the places are held still; the drop catches up.
        guard bounds.width > 0, pinDrag == nil else { return }
        let animated = requested && window != nil && !Tokens.Motion.isFromKey
        let side = AddressView.buttonSide, inset = (bounds.height - side) / 2
        // The host sits clear of the field's rounded edge, as far in as the buttons are from its right end, so the
        // text has room to breathe. After the not-secure mark when there is one.
        var x = Tokens.Space.x3
        let lockFrame = NSRect(x: x, y: 0, width: Tokens.Space.x3, height: bounds.height)
        if !lock.isHidden { x = lockFrame.maxX + Tokens.Space.x1 }

        var others: [IconButton] = []
        for (button, wanted) in [(readerButton, wantsReader), (captureButton, wantsCapture)] {
            if wanted { others.append(button) } else { takeAway(button, animated: animated, removing: false) }
        }
        let room = bounds.width - x - inset - Tokens.Space.x1
        let text = (label.stringValue as NSString).size(withAttributes: [.font: label.font ?? Tokens.Font.sidebarRow()]).width
        let fit = Self.pinsThatFit(count: pinEntries.count, otherButtons: others.count + 1, room: room, text: text)
        // The one furthest from Site Controls gives way first.
        let showing = pinEntries.suffix(fit)
        for entry in pinEntries.dropLast(fit) { takeAway(entry.button, animated: animated, removing: false) }
        let showingChanged = visiblePinIDs != showing.map(\.pin.id)
        visiblePinIDs = showing.map(\.pin.id)
        let pinFramesBefore = showing.map(\.button.frame)
        if showingChanged { updatePinControls(Array(showing)) }

        let trailing = others + showing.map(\.button) + [siteControlsButton]
        var right = bounds.width - inset
        for (index, button) in trailing.enumerated().reversed() {
            let frame = NSRect(x: right - side, y: inset, width: side, height: side)
            // Concentric with the field's corners.
            button.radius = Tokens.Sidebar.addressRadius - inset
            // The field's rim around it presses it too: top to bottom, out to the field's end, half the gap to a
            // neighbor.
            button.pressOutset = NSEdgeInsets(top: inset, left: 1, bottom: inset, right: index == trailing.count - 1 ? inset : 1)
            place(button, at: frame, animated: animated)
            right = frame.minX - 2
        }
        if showingChanged || pinFramesBefore != showing.map(\.button.frame) { onPinsMoved?() }

        let h = ceil(label.intrinsicContentSize.height)
        let labelFrame = NSRect(x: x - Label.inset, y: (bounds.height - h) / 2, width: right - Tokens.Space.x1 - x + Label.inset * 2, height: h)
        // A mark appearing starts in its place rather than flying in from the corner.
        if lock.frame.width == 0 { lock.frame = lockFrame }
        guard label.frame != labelFrame || lock.frame != lockFrame else { return }
        if animated && label.frame.width > 0 {
            Tokens.Motion.animate(Tokens.Motion.Curve(duration: Tokens.Motion.standard), moves: true) {
                self.label.animator().frame = labelFrame
                self.lock.animator().frame = lockFrame
            }
        } else {
            label.frame = labelFrame
            lock.frame = lockFrame
        }
    }

    private func place(_ button: IconButton, at frame: NSRect, animated: Bool) {
        guard drawn.insert(ObjectIdentifier(button)).inserted else {
            guard button.frame != frame else { return }
            if animated {
                Tokens.Motion.glide(button, to: frame, timing: Tokens.Motion.easeOut)
            } else {
                Tokens.Motion.withoutAnimation { button.frame = frame }
            }
            return
        }
        button.isHidden = false
        Tokens.Motion.withoutAnimation { button.frame = frame }
        // Shows up the shared way, out of its own middle; or, all at once, takes away what a going left on it.
        if animated { Tokens.Motion.present(button, from: Self.buttonOrigin, entering: true) } else { Tokens.Motion.settle(button) }
    }

    private static let buttonOrigin = Tokens.Motion.Origin.point(CGPoint(x: 0.5, y: 0.5))

    /// Takes a button out of the field, if it's in it. `removing`: its pin is gone for good, so the button goes
    /// whether or not it was showing.
    private func takeAway(_ button: IconButton, animated: Bool, removing: Bool) {
        let wasDrawn = drawn.remove(ObjectIdentifier(button)) != nil
        guard wasDrawn || removing else { return }
        button.isPressed = false
        button.isHovered = false
        let finish = { [weak self, weak button] in
            // Back in the field meanwhile: it stays.
            guard let self, let button, !self.drawn.contains(ObjectIdentifier(button)) else { return }
            button.isHidden = true
            Tokens.Motion.settle(button)
            if removing { button.removeFromSuperview() }
        }
        guard wasDrawn, animated else { finish(); return }
        Tokens.Motion.present(button, from: Self.buttonOrigin, entering: false, completion: finish)
    }

    /// The field's trailing end belongs to its buttons (`pressOutset`): a press on the rim around one presses it
    /// rather than opening the command bar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in [readerButton, captureButton, siteControlsButton] + pinEntries.map(\.button) where !button.isHidden {
            if button.pressArea.contains(button.convert(local, from: self)) { return button }
        }
        return super.hitTest(point)
    }

    override func stateDidChange(animated: Bool) {
        // A soft field of the space's own color, a step lighter under the pointer and pressed. On a page's own color
        // (the bar above the page), a page's neutral field instead, which shows on white too.
        let fill = isOnPage ? (isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.highlight : Tokens.Color.fieldFill)
            : isPressed ? Tokens.Chrome.fieldPressed : isHovered ? Tokens.Chrome.fieldHover : Tokens.Chrome.field
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        Tokens.Motion.withoutAnimation {
            layer?.borderWidth = 0
        }
    }
}

/// One dot per space at the bottom of the sidebar.
final class SpaceDotView: InteractiveView {
    let spaceID: UUID
    private let dot = CALayer()
    /// A space with an icon shows it here instead of a dot, quiet until it's the space you're in.
    private let iconView = NSImageView()
    var icon: String? {
        didSet {
            guard icon != oldValue else { return }
            iconView.image = icon.map { IconChoice.image($0, size: 12) }
            stateDidChange(animated: false)
        }
    }
    var color: NSColor = .gray { didSet { stateDidChange(animated: false) } }
    var isDropTarget = false { didSet { stateDidChange(animated: true) } }
    /// While a swipe pulls toward or away from this space: how much it looks like the space you're in, 0 to 1,
    /// following the fingers. Nil the rest of the time; clearing it eases back to what's really selected.
    var swipeShare: CGFloat? {
        didSet {
            guard oldValue != swipeShare else { return }
            settlesFromSwipe = swipeShare == nil
            stateDidChange(animated: false)
        }
    }
    private var settlesFromSwipe = false
    /// While ⌃ is held: the number that goes to this space with ⌃. The sidebar shows it just above the icon
    /// (`SidebarView.refreshSpaceNumbers`), outside this row, which clips; the icon stays in sight, since it's what
    /// says which space is which as you choose.
    var hint: Int? { didSet { if oldValue != hint { stateDidChange(animated: false) } } }

    init(spaceID: UUID) {
        self.spaceID = spaceID
        super.init(frame: NSRect(x: 0, y: 0, width: Tokens.Sidebar.button, height: Tokens.Sidebar.button))
        pressSinks = true
        layer?.cornerRadius = Tokens.Radius.control
        layer?.addSublayer(dot)
        // Every icon fit to the same square and centered in it, whatever its drawing's own width (a book is wider
        // than a flame), so the row reads as evenly spaced marks.
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        iconView.isHidden = true
        addSubview(iconView)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    /// Each space is a small key with its number, set in tabular figures like a dial marking. The space you're in
    /// is pressed in: a lighter, lit face of the frame's color;
    /// the others are quiet keys, their numbers faint. A space with an icon shows the icon in place of its number.
    var number = 0 { didSet { if oldValue != number { numberLayer.string = "\(number)"; stateDidChange(animated: false) } } }
    private lazy var numberLayer: CATextLayer = {
        let text = CATextLayer()
        text.alignmentMode = .center
        text.contentsScale = window?.backingScaleFactor ?? 2
        text.font = Tokens.Font.figures(10, weight: .regular)
        text.fontSize = 10
        layer?.addSublayer(text)
        return text
    }()
    private let tick = CALayer()
    private var wasSelected: Bool?

    override func stateDidChange(animated: Bool) {
        // VoiceOver says which space you're in.
        setAccessibilityValue(isSelected ? String(localized: "current space", comment: "Spoken by VoiceOver after a space's button at the bottom of the sidebar: it's the space you're in.") : nil)
        setAccessibilitySelected(isSelected)
        let side = Tokens.Sidebar.spaceKey
        let share = swipeShare ?? (isSelected ? 1 : 0)
        let ink = Tokens.Color.textPrimary
        let resting: CGFloat = isHovered ? 0.55 : 0.36
        let tint = ink.withAlphaComponent(resting + (0.86 - resting) * share)
        let changed = (wasSelected != nil && wasSelected != isSelected && swipeShare == nil) || settlesFromSwipe
        wasSelected = isSelected
        settlesFromSwipe = false
        // A quiet dot per space; the one you're in stretches into a short pill in full ink. No boxes, no numbers:
        // the dot's tooltip names the space and its ⌃ key.
        // A space with an icon shows the icon, small, in place of its dot; the one you're in is simply the brightest.
        _ = side
        let iconSide: CGFloat = 14
        let dotSide: CGFloat = icon == nil ? 6 : 2
        let width = icon == nil ? dotSide + 10 * share : 0
        let dotY = icon == nil ? bounds.midY - dotSide / 2
            : (isFlipped ? bounds.midY + iconSide / 2 + 3 : bounds.midY - iconSide / 2 - 3 - dotSide)
        let key = CGRect(x: bounds.midX - width / 2, y: dotY, width: width, height: dotSide)
        let dotFill = ink.withAlphaComponent((isPressed ? 0.6 : 1) * (resting * 0.8 + (0.86 - resting * 0.8) * share))
        let apply = {
            self.dot.frame = key
            self.dot.cornerRadius = dotSide / 2
            self.dot.cornerCurve = .continuous
            self.dot.backgroundColor = self.cgColor(dotFill)
            self.dot.borderWidth = 0
            self.dot.shadowOpacity = 0
            self.dot.opacity = 1
            self.numberLayer.isHidden = true
            self.tick.opacity = 0
        }
        if tick.superlayer == nil { layer?.addSublayer(tick) }
        numberLayer.isHidden = true
        numberLayer.contentsScale = window?.backingScaleFactor ?? 2
        iconView.frame = NSRect(x: bounds.midX - iconSide / 2, y: bounds.midY - iconSide / 2, width: iconSide, height: iconSide)
        iconView.isHidden = icon == nil
        iconView.contentTintColor = tint
        // An emoji keeps its colors, so it says which space is yours by how strongly it shows.
        iconView.alphaValue = icon.map(IconChoice.isSymbol) == false ? 0.45 + 0.55 * share : 1
        if changed && !Tokens.Motion.reduceMotion {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Tokens.Motion.standard)
            CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
            apply()
            CATransaction.commit()
        } else {
            Tokens.Motion.withoutAnimation(apply)
        }
        // The key itself is what answers the pointer; a drop over it lights it as the drop target.
        let fill: NSColor? = isDropTarget ? Tokens.Chrome.pressed : nil
        layer?.set(backgroundColor: fill.map { cgColor($0) }, animated: animated && !isHovered)
    }
}

/// The sidebar: navigation, address, bookmarks, tabs and spaces. Drawn entirely by us.
final class SidebarView: NSView {
    weak var delegate: SidebarDelegate? {
        didSet { list.delegate = delegate; panes.left.list.delegate = delegate; panes.right.list.delegate = delegate }
    }

    /// The top row's and bottom bar's buttons: 26pt, 14pt glyphs, every glyph's ink on the traffic lights' line.
    static let toolbarButton: CGFloat = Tokens.Sidebar.button
    /// The sidebar toggle's glyph: the panel drawn on the side the sidebar is on.
    static func toggleSymbol(onRight: Bool) -> String { onRight ? "sidebar.right" : "sidebar.left" }

    static func chromeButton(_ symbol: String, toolTip: String) -> IconButton {
        let button = IconButton(symbol: symbol, size: toolbarButton, symbolSize: Tokens.Sidebar.glyph, toolTip: toolTip)
        button.isChrome = true
        return button
    }
    // The four top controls are one set: Apple's own symbols, drawn at one size and weight, so they match and line up.
    let backButton = SidebarView.chromeButton("chevron.left", toolTip: String(localized: "Back", comment: "Tooltip of the sidebar's back button."))
    let forwardButton = SidebarView.chromeButton("chevron.right", toolTip: String(localized: "Forward", comment: "Tooltip of the sidebar's forward button."))
    let reloadButton = SidebarView.chromeButton("arrow.clockwise", toolTip: String(localized: "Reload", comment: "Tooltip of the sidebar's reload button."))
    /// Stand-in for the traffic lights while the sidebar slides.
    private let trafficLightsPicture = NSImageView()
    let sidebarButton = SidebarView.chromeButton(SidebarView.toggleSymbol(onRight: false), toolTip: String(localized: "Hide Sidebar", comment: "Tooltip of the sidebar button while the sidebar shows."))
    let address = AddressView()
    let favorites = FavoritesView()
    let list = SidebarListView()
    private let scrollView = NSScrollView()
    /// Tabs running on below the bottom of the list fade out there, rather than being sliced off by the footer.
    private let bottomFade = CAGradientLayer()
    /// The spaces either side, each in a list of its own: the one a swipe pulls in beside the current list, and the
    /// one a switch slides in. Made ahead of time, so a swipe never waits for a list to be built.
    private let panes = (left: SpacePane(), right: SpacePane())
    private func pane(_ side: CGFloat) -> SpacePane { side < 0 ? panes.left : panes.right }

    private let bottomBar = NSView()
    /// The dots, between Downloads and +. Too many to fit at a size you can click, they scroll sideways, keeping
    /// the space you're in in view, with their ends faded.
    private let dotStrip = DotStrip()
    let nowPlaying = NowPlayingView()

    /// A circle with an arrow, drawn in code so the progress ring lies exactly on the circle: one center, one size.
    let downloadsButton: IconButton = {
        let button = SidebarView.chromeButton("arrow.down.circle", toolTip: String(localized: "Downloads", comment: "Tooltip of the sidebar's downloads button."))
        button.glyph = DownloadGlyph.image(.arrow)
        return button
    }()
    let newSpaceButton: IconButton = {
        let button = SidebarView.chromeButton("plus", toolTip: SidebarView.addTip)
        // VoiceOver: a button that opens a menu.
        button.setAccessibilityRole(.menuButton)
        button.glyph = LineGlyph.plus
        return button
    }()
    private var dots: [SpaceDotView] = []
    /// While ⌃ is held: each space shows the number ⌃ goes to it with. Spaces added, removed or moved meanwhile
    /// follow.
    var showsSpaceNumbers = false { didSet { if oldValue != showsSpaceNumbers { refreshSpaceNumbers() } } }
    private var spaceHints: [NumberHintView] = []
    private func refreshSpaceNumbers() {
        let old = spaceHints
        spaceHints = []
        old.forEach { $0.show(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.exit) { old.forEach { $0.removeFromSuperview() } }
        for (dot, label) in zip(dots, SpaceNumbers.labels(count: dots.count)) {
            dot.hint = showsSpaceNumbers ? label : nil
            guard showsSpaceNumbers, let label else { continue }
            let view = NumberHintView()
            view.showsCommand = false
            view.number = label
            addSubview(view)
            spaceHints.append(view)
            view.show(true)
        }
        layoutSpaceHints()
    }
    /// Each number just above its space's icon, centered on it.
    private func layoutSpaceHints() {
        let numbered = dots.filter { $0.hint != nil }
        for (dot, view) in zip(numbered, spaceHints) {
            let key = dot.convert(dot.bounds, to: self), height = NumberHintView.height, gap: CGFloat = 2
            view.frame = NSRect(x: key.midX - view.width / 2, y: isFlipped ? key.minY - height - gap : key.maxY + gap,
                                width: view.width, height: height).integral
        }
    }
    /// Whether the space keys are there to show numbers on: more than one space, in a window that switches them.
    var hasSpaceKeys: Bool { !isPrivate && dots.count > 1 }
    /// A private window keeps to one space and makes none: no dots to switch, no button to add one.
    var isPrivate = false {
        didSet {
            newSpaceButton.isHidden = isPrivate
            dots.forEach { $0.isHidden = isPrivate }
        }
    }
    private let topSeparator = ColorView(color: Tokens.Color.separator)
    /// Width reserved on the left of the top row for the traffic lights.
    var trafficLightsWidth: CGFloat = 52 { didSet { needsLayout = true } }
    /// The sidebar is on the window's right: its toggle's glyph shows that, and while the traffic lights aren't in it
    /// its top row is the left one's mirror image (`topRowFrames`).
    var isOnRight = false {
        didSet {
            guard isOnRight != oldValue else { return }
            sidebarButton.symbol = Self.toggleSymbol(onRight: isOnRight)
            needsLayout = true
        }
    }
    /// Back, forward, reload and the address are here, under the traffic lights; false while they're in the bar above
    /// the page (`TopBarView`), and the favorites and tabs move up into the address's place.
    var holdsAddress = true {
        didSet {
            guard holdsAddress != oldValue else { return }
            if holdsAddress { (holdsButtons ? addressViews : [address]).forEach(addSubview) }
            needsLayout = true
        }
    }
    /// Back, forward and reload are in its top row; false while the strip above the page beside a sidebar on the
    /// right holds them, after the traffic lights (`BrowserRootView.lightsStrip`, #181).
    var holdsButtons = true {
        didSet {
            guard holdsButtons != oldValue else { return }
            if holdsButtons, holdsAddress { addressButtons.forEach(addSubview) }
            needsLayout = true
        }
    }
    /// Where the favorites start while the address is above the page: the page's top, so the two line up under the
    /// top row (set by the window as it lays out the page).
    var contentTop: CGFloat = TopBarView.height { didSet { if contentTop != oldValue { needsLayout = true } } }
    /// What moves to the bar above the page: the three buttons in order, then the address.
    var addressButtons: [IconButton] { [backButton, forwardButton, reloadButton] }
    private var addressViews: [NSView] { addressButtons + [address] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        for button in [sidebarButton, backButton, forwardButton, reloadButton] { addSubview(button) }
        trafficLightsPicture.imageScaling = .scaleNone
        trafficLightsPicture.isHidden = true
        addSubview(trafficLightsPicture)
        addSubview(address)
        addSubview(favorites)
        favorites.onHeightChange = { [weak self] in self?.needsLayout = true }

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = list
        // Like Arc, the sidebar scrolls without showing a scroll bar.
        scrollView.hasVerticalScroller = false
        addSubview(scrollView)
        scrollView.wantsLayer = true
        scrollView.layer?.mask = bottomFade
        addSubview(panes.left.scroll)
        addSubview(panes.right.scroll)
        topSeparator.alphaValue = 0
        addSubview(topSeparator)
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        nowPlaying.isHidden = true
        addSubview(nowPlaying)

        bottomBar.addSubview(dotStrip)
        bottomBar.addSubview(downloadsButton)
        bottomBar.addSubview(newSpaceButton)
        addSubview(bottomBar)
        downloadsButton.onClick = { [weak self] _ in
            guard let self else { return }
            self.delegate?.sidebarShowDownloads(from: self.downloadsButton)
        }
        // A menu, as Arc's + is: a tab, a folder or a space, which a single space has no other button for.
        newSpaceButton.onClick = { [weak self] _ in self?.showAddMenu() }
        address.onClick = { [weak self] _ in self?.delegate?.sidebarOpenCommandBar() }
        themeToken = Brand.themeChanged.observe { [weak self] in self?.tintDownloadsRing() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// What the + says it does, for its tooltip and VoiceOver.
    static var addTip: String {
        String(localized: "New Tab, Folder or Space", comment: "Tooltip of the + button at the bottom of the sidebar: opens a menu to add a tab, a folder or a space.")
    }

    /// Opens just above the +, its trailing edge on the button's, so it covers neither the button nor the spaces.
    /// Clicked again while it's open, the + closes it.
    func showAddMenu() {
        if let open = MenuPanel.current, open.anchor === newSpaceButton { open.close(); return }
        guard let entries = delegate?.sidebarAddMenu(), !entries.isEmpty else { return }
        let button = newSpaceButton
        button.isSelected = true
        MenuPanel.show(entries, from: button, placement: .aboveTrailing) { [weak button] in button?.isSelected = false }
    }

    /// Right-click where no row or button has a menu of its own (below the tabs, between the favorites, the bar at
    /// the bottom): what you'd make here, in the same menu as the +. Not on the address or the buttons above it,
    /// which belong to the page. On the + itself, its own menu.
    func showBlankMenu(for event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= (holdsAddress ? address.frame.maxY : contentTop) else { return false }
        if !newSpaceButton.isHidden, newSpaceButton.bounds.contains(newSpaceButton.convert(event.locationInWindow, from: nil)) {
            showAddMenu()
            return true
        }
        guard let entries = delegate?.sidebarBlankMenu(), !entries.isEmpty else { return false }
        MenuPanel.show(entries, from: self, placement: .at(event.locationInWindow))
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        if !showBlankMenu(for: event) { super.rightMouseDown(with: event) }
    }

    /// The sidebar is the window's title bar: drag it to move the window, and double-click it to zoom (or
    /// whatever the Mac's title bar double-click is set to do). A Control-click is a right-click.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), showBlankMenu(for: event) { return }
        window?.titleBarMouseDown(event)
    }

    @objc private func listScrolled() {
        list.pinHeader()
        updateBottomFade()
        let scrolled = scrollView.contentView.bounds.minY > 1
        if (topSeparator.alphaValue > 0) != scrolled {
            Tokens.Motion.animate(Tokens.Motion.feedback) { self.topSeparator.animator().alphaValue = scrolled ? 1 : 0 }
        }
    }

    // MARK: Layout

    /// The top row across the sidebar's width, x only: the toggle, and back, forward and reload, in that order.
    /// The toggle sits right after the traffic lights, where Arc and Safari put it, its glyph `Sidebar.lightsGap`
    /// after them (the button's own padding inside that); without them (full screen, or a sidebar on the right) it
    /// starts the row, `Sidebar.edge` in. Back, forward and reload are at the trailing end, their glyphs a button
    /// apart, reload's ink as far from the sidebar's edge as the lights' from the other.
    /// `onRight` without the lights in it: the mirror image, the toggle at the sidebar's outer (right) end, where the
    /// bar above the page keeps it while the sidebar is hidden, and back's ink as far from the left edge as reload's
    /// is from the right one on the left. The lights at its left (slid out over the page with no bar) keep the
    /// left's order, out of their way.
    static func topRowFrames(width: CGFloat, trafficLightsWidth: CGFloat, onRight: Bool) -> (toggle: NSRect, buttons: [NSRect]) {
        let b = toolbarButton, pad = Tokens.Sidebar.edge
        func at(_ x: CGFloat) -> NSRect { NSRect(x: x, y: 0, width: b, height: b) }
        if onRight && trafficLightsWidth == 0 {
            let backInk = Tokens.Symbol.inkSize("chevron.left", size: Tokens.Sidebar.glyph).width
            let x = round(trafficLightsX + backInk / 2 - b / 2)
            return (at(width - pad - b), (0..<3).map { at(x + CGFloat($0) * b) })
        }
        let reloadInk = Tokens.Symbol.inkSize("arrow.clockwise", size: Tokens.Sidebar.glyph).width
        let x = round(width - trafficLightsX - reloadInk / 2 - b / 2)
        let glyph = Tokens.Symbol.inkSize(toggleSymbol(onRight: onRight), size: Tokens.Sidebar.glyph).width
        let lead = trafficLightsWidth > 0 ? round(trafficLightsX + trafficLightsWidth + Tokens.Sidebar.lightsGap - (b - glyph) / 2) : pad
        return (at(lead), (0..<3).map { at(x - CGFloat(2 - $0) * b) })
    }

    /// Where the traffic lights start, from the sidebar's left edge.
    static let trafficLightsX = Tokens.Sidebar.lightsX

    /// The y position (from the top) where the traffic lights should be centered.
    var trafficLightCenterY: CGFloat { Tokens.Sidebar.lightsCenter + topRowDrop }
    /// How far the top row sits below its usual line: framed, the bar above the page starts the frame's inset down,
    /// and the lights and the sidebar's toggle stay on its middle line with its buttons (set by the window).
    var topRowDrop: CGFloat = 0 { didSet { if topRowDrop != oldValue { needsLayout = true } } }

    override func layout() {
        super.layout()
        defer { if showsSpaceNumbers { layoutSpaceHints() } }
        let pad = Tokens.Sidebar.edge
        let width = bounds.width
        let rowCenter = trafficLightCenterY
        let button = Self.toolbarButton
        let row = Self.topRowFrames(width: width, trafficLightsWidth: trafficLightsWidth, onRight: isOnRight)
        func onLine(_ rect: NSRect) -> NSRect { NSRect(x: rect.minX, y: rowCenter - button / 2, width: button, height: button) }
        for (b, rect) in zip([backButton, forwardButton, reloadButton], row.buttons) where holdsAddress && holdsButtons { b.frame = onLine(rect) }
        sidebarButton.frame = onLine(row.toggle)
        if holdsAddress {
            address.frame = NSRect(x: pad, y: Tokens.Sidebar.addressTop, width: width - pad * 2, height: Tokens.Sidebar.addressHeight)
        }
        // With the address above the page, the favorites (or the tabs, without any) start where the page does.
        let topEdge = holdsAddress ? address.frame.maxY + Tokens.Space.x2 : contentTop

        let bottomHeight = Tokens.Sidebar.bottomBarHeight
        // Its buttons sit as far from the bottom edge as from the side.
        let buttonInset = (bottomHeight - Tokens.Sidebar.button) / 2
        bottomBar.frame = NSRect(x: 0, y: bounds.height - bottomHeight + buttonInset - pad, width: width, height: bottomHeight)
        let favoritesHeight = favorites.preferredHeight(for: width - pad * 2)
        favorites.isHidden = favoritesHeight == 0
        favorites.frame = NSRect(x: pad, y: topEdge, width: width - pad * 2, height: favoritesHeight)
        let listTop = favoritesHeight > 0 ? favorites.frame.maxY + Tokens.Sidebar.sectionGap
            : holdsAddress ? topEdge - Tokens.Space.x2 + Tokens.Sidebar.sectionGap : topEdge
        let frames = bottomFrames()
        nowPlaying.frame = frames.nowPlaying
        let listBottom = frames.listBottom
        scrollView.frame = NSRect(x: pad + swipeOffset, y: listTop, width: width - pad * 2, height: listBottom - listTop)
        topSeparator.frame = NSRect(x: pad * 2, y: listTop - Tokens.Metric.hairline, width: width - pad * 4, height: Tokens.Metric.hairline)
        if list.frame.width != scrollView.contentSize.width {
            list.setFrameSize(NSSize(width: scrollView.contentSize.width, height: max(list.frame.height, scrollView.contentSize.height)))
        }
        layoutBottomBar()
        updateBottomFade()
        placePanes()
    }

    private func updateBottomFade() {
        Self.fade(bottomFade, for: scrollView, list: list)
    }

    /// Tabs running on below the bottom of a list fade out there. Only the bottom: the top holds the space's name,
    /// pinned while you scroll, and a hairline already says there's more above.
    private static func fade(_ mask: CAGradientLayer, for scrollView: NSScrollView, list: NSView) {
        let bounds = scrollView.bounds
        let clip = scrollView.contentView.bounds
        let moreBelow = list.frame.height - clip.maxY > 1
        let fade = bounds.height > 0 ? min(Tokens.Space.x6 / bounds.height, 0.5) : 0
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        // Drawn top to bottom in the list's own terms; the gradient's y runs the other way in an unflipped layer.
        mask.colors = [solid, solid, moreBelow ? clear : solid]
        mask.locations = [0, NSNumber(value: Double(1 - fade)), 1]
        let flipped = scrollView.layer?.isGeometryFlipped == true || scrollView.isFlipped
        mask.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        mask.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        CATransaction.commit()
    }

    private func layoutBottomBar() {
        let button = Tokens.Sidebar.button
        // Downloads' glyph centered on the icon column, + mirrored at the other end.
        let pad = round(Tokens.Sidebar.iconColumn + Tokens.Sidebar.favicon / 2 - button / 2)
        let h = bottomBar.bounds.height
        downloadsButton.frame = NSRect(x: pad, y: (h - button) / 2, width: button, height: button)
        newSpaceButton.frame = NSRect(x: bottomBar.bounds.width - pad - button, y: (h - button) / 2, width: button, height: button)
        let available = newSpaceButton.frame.minX - downloadsButton.frame.maxX - Tokens.Space.x2
        dotStrip.frame = NSRect(x: downloadsButton.frame.maxX + Tokens.Space.x1, y: 0, width: max(0, available), height: h)
        // Never smaller than a comfortable target; past that, the row scrolls.
        let dotSize = max(DotStrip.smallest, min(Tokens.Sidebar.button, floor(available / CGFloat(max(dots.count, 1)))))
        let total = CGFloat(dots.count) * dotSize
        dotStrip.contentWidth = total
        var x = max(0, (available - total) / 2)
        for dot in dots {
            let frame = NSRect(x: x, y: (h - dotSize) / 2, width: dotSize, height: dotSize)
            if glidesDots, dot.frame.size == frame.size { Tokens.Motion.glide(dot, to: frame) } else { dot.frame = frame }
            x += dotSize
        }
        if let current = dots.first(where: \.isSelected) { dotStrip.reveal(current.frame) }
    }

    func showTrafficLightsPicture(_ image: NSImage?) {
        trafficLightsPicture.image = image
        trafficLightsPicture.isHidden = image == nil
        if let image {
            let x = Self.trafficLightsX
            trafficLightsPicture.frame = NSRect(x: x, y: trafficLightCenterY - image.size.height / 2, width: image.size.width, height: image.size.height)
        }
    }

    // MARK: Updating

    func update(tab: Tab?) {
        backButton.isEnabled = tab?.canGoBackOrReturn ?? false
        forwardButton.isEnabled = tab?.canGoForward ?? false
        reloadButton.isEnabled = tab != nil
        reloadButton.symbol = (tab?.isLoading ?? false) ? "xmark" : "arrow.clockwise"
        reloadButton.toolTip = Self.reloadTip(loading: tab?.isLoading ?? false)
        address.show(url: tab?.url, isSecure: tab?.url?.scheme == "https")
    }

    /// "Reload (⌘R)", or "Stop (⌘.)" while the page loads: what the button does now, with its shortcut.
    static func reloadTip(loading: Bool) -> String {
        loading ? Shortcuts.tooltip(String(localized: "Stop", comment: "Tooltip of the sidebar's reload button while the page loads: stops loading."),
                                    for: #selector(BrowserWindowController.stopLoading(_:)))
                : Shortcuts.tooltip(String(localized: "Reload", comment: "Tooltip of the sidebar's reload button."),
                                    for: #selector(BrowserWindowController.reloadPage(_:)))
    }

    func reloadSpaces(current: UUID) {
        let spaces = Library.shared.spaces
        if dots.map(\.spaceID) != spaces.map(\.id) {
            // The same spaces in a new order (a drag, its undo) keep their dots, which glide to their new places.
            var kept = Dictionary(dots.map { ($0.spaceID, $0) }, uniquingKeysWith: { first, _ in first })
            glidesDots = Set(kept.keys) == Set(spaces.map(\.id)) && window != nil
            for dot in dots where !spaces.contains(where: { $0.id == dot.spaceID }) {
                dot.removeFromSuperview()
                kept[dot.spaceID] = nil
            }
            dots = spaces.map { space in
                if let dot = kept[space.id] { return dot }
                let dot = SpaceDotView(spaceID: space.id)
                dot.onClick = { [weak self, weak dot] _ in
                    guard let self, let dot else { return }
                    // Clicking the space you're in edits it; clicking another switches to it.
                    if dot.isSelected { self.onEditSpace?(space.id) } else { self.delegate?.sidebarSwitchSpace(space.id) }
                }
                dot.onDoubleClick = { [weak self] in self?.onEditSpace?(space.id) }
                dot.onRightClick = { [weak self] _ in self?.delegate?.sidebarSpaceMenu(for: space.id) }
                dot.onDragStart = { [weak self, weak dot] event in
                    guard let self, let dot else { return false }
                    return self.dragSpace(dot, event: event)
                }
                dotStrip.addSubview(dot)
                return dot
            }
        }
        for (i, dot) in dots.enumerated() {
            guard let space = Library.shared.space(dot.spaceID) else { continue }
            dot.number = i + 1
            dot.color = space.swatch
            dot.icon = space.icon
            dot.isSelected = space.id == current
            // The first nine have ⌃1 to ⌃9 (fixed keys, not in Settings › Shortcuts), so the name says which.
            let shortcut = "⌃\(i + 1)"
            dot.toolTip = i < 9 ? String(localized: "\(space.name) (\(shortcut))", comment: "A button's tooltip: its name, then its keyboard shortcut in parentheses, like “Reload (⌘R)”.") : space.name
            dot.setAccessibilityLabel(String(localized: "Space \(space.name)", comment: "Accessibility label of a space's button at the bottom of the sidebar. The placeholder is the space's name."))
            // VoiceOver moves a space as a drag does, one place at a time.
            let id = space.id, count = dots.count
            var actions: [NSAccessibilityCustomAction] = []
            if i > 0 {
                actions.append(NSAccessibilityCustomAction(name: String(localized: "Move Left", comment: "VoiceOver action on a space's button at the bottom of the sidebar: moves the space one place to the left.")) { [weak self] in
                    MainActor.assumeIsolated { self?.onMoveSpace?(id, i - 1) }
                    return true
                })
            }
            if i < count - 1 {
                actions.append(NSAccessibilityCustomAction(name: String(localized: "Move Right", comment: "VoiceOver action on a space's button at the bottom of the sidebar: moves the space one place to the right.")) { [weak self] in
                    MainActor.assumeIsolated { self?.onMoveSpace?(id, i + 1) }
                    return true
                })
            }
            dot.setAccessibilityCustomActions(isPrivate ? nil : actions)
        }
        // A single space needs no switcher, and a private window switches nothing.
        dots.forEach { $0.isHidden = isPrivate || dots.count < 2 }
        refreshSpaceNumbers()
        layoutBottomBar()
        glidesDots = false
    }

    // MARK: Reordering spaces

    /// A space dropped in a new place along the row: its id and new index. The window makes the move, undoably.
    var onMoveSpace: ((UUID, Int) -> Void)?
    /// While the order of the dots changes, those already in place glide to their new places.
    private var glidesDots = false
    /// A dot being carried along the row: where it started, its copy, and the gap it would drop into (nil: off the row).
    private struct SpaceDrag {
        let dot: SpaceDotView
        let from: Int
        let copy: CarriedCopy
        var slot: Int?
        /// Where the pointer is, on screen.
        var point: NSPoint
        /// Scrolls the row while the pointer rests near either end of a row too long to show at once.
        var edgeTimer: Timer?
    }
    private var spaceDrag: SpaceDrag?
    /// Where a carried dot would go, between two others: the favorites' bar, at the dots' size.
    private let spaceDropBar: ColorView = {
        let bar = ColorView(color: Tokens.Color.accent)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1
        bar.isHidden = true
        return bar
    }()

    /// Picks a dot up, as a favorite is: it stays in its place, faint, a see-through copy follows the pointer, and a
    /// bar between two dots shows where it would go. Let go on the row, it moves there; off it, or with Esc, it goes back.
    private func dragSpace(_ dot: SpaceDotView, event: NSEvent) -> Bool {
        guard let window, beginSpaceDrag(dot, at: window.convertPoint(toScreen: event.locationInWindow)) else { return false }
        let released = CarriedCopy.track(in: window) { event in
            self.moveSpaceDrag(to: window.convertPoint(toScreen: event.locationInWindow))
        }
        endSpaceDrag(drop: released != nil)
        return true
    }

    private func beginSpaceDrag(_ dot: SpaceDotView, at screenPoint: NSPoint) -> Bool {
        guard spaceDrag == nil, !isPrivate, dots.count > 1, let from = dots.firstIndex(where: { $0 === dot }) else { return false }
        let copy = CarriedCopy(of: dot, picture: CarriedCopy.picture(of: dot), grabbedAt: screenPoint,
                               ground: Tokens.Color.panelBackground, radius: Tokens.Radius.control)
        dot.isHovered = false
        dot.alphaValue = CarriedCopy.faint
        copy.lift()
        var drag = SpaceDrag(dot: dot, from: from, copy: copy, slot: nil, point: screenPoint)
        if dotStrip.scrolls {
            // In the tracking loop's mode too, so it runs while the button is held.
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.carrySpaceDragToEdge() }
            }
            RunLoop.main.add(timer, forMode: .common)
            drag.edgeTimer = timer
        }
        spaceDrag = drag
        return true
    }

    /// Whether a pointer at this window point is on the row: anywhere along the bar, a little above and below it
    /// too; past its ends is the first or last place.
    private func isOnSpaceRow(_ point: NSPoint) -> Bool {
        bottomBar.bounds.insetBy(dx: 0, dy: -Tokens.Space.x2).contains(bottomBar.convert(point, from: nil))
    }

    private func carrySpaceDragToEdge() {
        guard let drag = spaceDrag, let window else { return }
        let point = window.convertPoint(fromScreen: drag.point)
        guard isOnSpaceRow(point), dotStrip.carry(at: dotStrip.convert(point, from: nil).x) else { return }
        moveSpaceDrag(to: drag.point)
    }

    private func moveSpaceDrag(to screenPoint: NSPoint) {
        guard var drag = spaceDrag, let window else { return }
        drag.copy.follow(screenPoint)
        drag.point = screenPoint
        let point = window.convertPoint(fromScreen: screenPoint)
        if isOnSpaceRow(point) {
            let x = drag.dot.superview?.convert(point, from: nil).x ?? 0
            drag.slot = SpaceReorder.slot(at: x, middles: dots.map(\.frame.midX))
        } else {
            drag.slot = nil
        }
        spaceDrag = drag
        let from = drag.from
        placeSpaceDropBar(drag.slot.flatMap { SpaceReorder.destination(slot: $0, from: from) == nil ? nil : $0 })
    }

    /// Lets go: dropped on the row (`drop`) the space moves to the gap the bar showed and the copy lands in its new
    /// place; called off, it lands back where it was.
    private func endSpaceDrag(drop: Bool) {
        guard let drag = spaceDrag else { return }
        spaceDrag = nil
        drag.edgeTimer?.invalidate()
        placeSpaceDropBar(nil)
        if drop, let slot = drag.slot, let to = SpaceReorder.destination(slot: slot, from: drag.from) {
            onMoveSpace?(drag.dot.spaceID, to)
        }
        drag.dot.alphaValue = 1
        drag.copy.land(on: drag.dot)
    }

    /// The bar in the gap before dot `slot` (after the last for the end); nil hides it.
    private func placeSpaceDropBar(_ slot: Int?) {
        guard let slot, let first = dots.first, let last = dots.last else { spaceDropBar.isHidden = true; return }
        let size = first.frame.height
        let x = slot < dots.count ? dots[slot].frame.minX : last.frame.maxX
        let width: CGFloat = 2, height = max(Tokens.Space.x2, size - 12)
        if spaceDropBar.superview == nil { dotStrip.addSubview(spaceDropBar) }
        let room = spaceDropBar.superview?.bounds.width ?? x
        Tokens.Motion.withoutAnimation {
            spaceDropBar.frame = NSRect(x: min(max(x - width / 2, 0), room - width), y: first.frame.midY - height / 2, width: width, height: height)
        }
        spaceDropBar.isHidden = false
    }

    #if DEBUG
    /// spacedrag begin <i> | move <x> [y] (window points, top-left; y defaults to the bar's middle) | drop | cancel:
    /// the drag a pointer would make, through the same steps.
    func debugSpaceDrag(_ arg: String) {
        guard let window else { return }
        let f = arg.split(separator: " ").map(String.init)
        let barMiddle = bottomBar.convert(NSPoint(x: 0, y: bottomBar.bounds.midY), to: nil).y
        switch f.first {
        case "begin":
            guard let i = f.dropFirst().first.flatMap({ Int($0) }), dots.indices.contains(i) else { return }
            let dot = dots[i]
            _ = beginSpaceDrag(dot, at: window.convertPoint(toScreen: dot.convert(NSPoint(x: dot.bounds.midX, y: dot.bounds.midY), to: nil)))
        case "move":
            guard f.count >= 2, let x = Double(f[1]) else { return }
            let y = f.count >= 3 ? Double(f[2]).map { window.frame.height - $0 } ?? barMiddle : barMiddle
            moveSpaceDrag(to: window.convertPoint(toScreen: NSPoint(x: x, y: y)))
        case "drop": endSpaceDrag(drop: true)
        case "cancel": endSpaceDrag(drop: false)
        default: break
        }
    }
    #endif

    func dot(for spaceID: UUID) -> NSView? { dots.first { $0.spaceID == spaceID } }

    #if DEBUG
    func debugDots() -> [(String, NSRect)] {
        guard let window else { return [] }
        return dots.filter { !$0.isHidden }.map { ("dot:" + (Library.shared.space($0.spaceID)?.name ?? ""), $0.convert($0.bounds, to: nil).flippedIn(window)) }
    }
    #endif

    /// The row of space dots.
    var dotsAnchor: NSView { bottomBar }
    /// The first space's dot, or the row when there's only one.
    var firstDotAnchor: NSView { dots.count > 1 ? dots[0] : bottomBar }
    /// The newest space's dot, or the row when there's only one.
    var lastDotAnchor: NSView { dots.count > 1 ? dots[dots.count - 1] : bottomBar }
    /// The + that makes a space.
    var newSpaceAnchor: NSView { newSpaceButton }
    var onEditSpace: ((UUID) -> Void)?

    /// The bottom stack: the now-playing control sits above the dots.
    private func bottomFrames() -> (nowPlaying: NSRect, listBottom: CGFloat) {
        let pad = Tokens.Sidebar.edge
        var bottom = bottomBar.frame.minY
        let playingHeight = Tokens.Sidebar.nowPlayingHeight
        let playing = NSRect(x: pad, y: bottom - (nowPlaying.isHidden ? 0 : playingHeight), width: bounds.width - pad * 2, height: playingHeight)
        if !nowPlaying.isHidden { bottom = playing.minY - Tokens.Space.x1 }
        return (playing, bottom)
    }

    /// Shows (or hides) the now-playing control, making room above the dots.
    func setNowPlaying(_ tab: Tab?, paused: Bool) {
        let show = tab != nil
        if let tab { nowPlaying.isPaused = paused; nowPlaying.show(tab) }
        guard show == (nowPlaying.isHidden || nowPlayingFadingOut) else { return }
        nowPlayingFadingOut = false
        if show {
            nowPlaying.isHidden = false
            needsLayout = true
            nowPlaying.alphaValue = 0
            Tokens.Motion.animate(Tokens.Motion.snappy) { self.nowPlaying.animator().alphaValue = 1 }
            return
        }
        // Fades out where it is first; only then does the list take back its room, so nothing vanishes at once.
        nowPlayingFadingOut = true
        Tokens.Motion.animate(Tokens.Motion.snappy, { self.nowPlaying.animator().alphaValue = 0 }, completion: {
            // Playing again before the fade finished: it stays.
            guard self.nowPlayingFadingOut else { return }
            self.nowPlayingFadingOut = false
            self.nowPlaying.isHidden = true
            self.nowPlaying.alphaValue = 1
            self.needsLayout = true
        })
    }

    /// True while the now-playing control fades away, before it gives its room back to the list.
    private var nowPlayingFadingOut = false

    func previewDotColor(_ color: NSColor, for spaceID: UUID) {
        dots.first { $0.spaceID == spaceID }?.color = color
    }

    /// The accent drawn over the icon's own circle as downloads run, exactly on it, so nothing changes size as one
    /// starts or ends; a check in the same circle for a moment when they're done.
    private let downloadsRing = CAShapeLayer()
    private var wasDownloading = false
    private var shownMark = DownloadGlyph.Mark.arrow
    private var themeToken: SignalToken?

    func updateDownloads(active: Int, hasAny: Bool, progress: Double = 1) {
        // Always there, in the same place, so the space dots never shift; with nothing downloaded, its panel says so.
        downloadsButton.isHidden = false
        let downloading = active > 0
        if downloadsRing.superlayer == nil, let host = downloadsButton.layer {
            downloadsRing.fillColor = nil
            // A hair heavier than the glyph's line, so the accent covers it cleanly.
            downloadsRing.lineWidth = DownloadGlyph.line + 0.3
            downloadsRing.lineCap = .round
            downloadsRing.strokeEnd = 0
            downloadsRing.opacity = 0
            host.addSublayer(downloadsRing)
        }
        let b = downloadsButton.bounds
        // The glyph's own circle: the button centers the glyph, so the ring is centered the same way, at its size.
        let d = DownloadGlyph.circle
        let rect = CGRect(x: (b.width - d) / 2, y: (b.height - d) / 2, width: d, height: d)
        // Shape, place and color are set as they are: animating them on every progress tick restarted a fade a few
        // times a second, which is what made the ring jump.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if downloadsRing.frame != b {
            // Starts at the top and runs clockwise, like the system's own progress rings. The button's layer counts y
            // downward, so the top is -90° and growing angles turn clockwise on screen.
            let ring = CGMutablePath()
            ring.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: d / 2, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
            downloadsRing.path = ring
            downloadsRing.frame = b
        }
        tintDownloadsRing()
        CATransaction.commit()
        // The fill only moves forward while a download runs, easing from wherever it is on screen to the new amount.
        let target = downloading ? CGFloat(max(0.04, min(progress, 1))) : (wasDownloading ? 1 : 0)
        let shown = downloadsRing.presentation()?.strokeEnd ?? downloadsRing.strokeEnd
        let to = downloading && wasDownloading ? max(target, downloadsRing.strokeEnd) : target
        if to != downloadsRing.strokeEnd {
            let ease = CABasicAnimation(keyPath: "strokeEnd")
            ease.fromValue = shown
            ease.toValue = to
            ease.duration = downloading ? 0.35 : 0.2
            ease.timingFunction = CAMediaTimingFunction(name: downloading ? .linear : .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            downloadsRing.strokeEnd = to
            CATransaction.commit()
            downloadsRing.add(ease, forKey: "progress")
        }
        // Comes and goes with a short fade, never in a single frame.
        let opacity: Float = downloading ? 1 : 0
        if downloadsRing.opacity != opacity {
            for layer in [downloadsRing] {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
                fade.toValue = opacity
                fade.duration = Tokens.Motion.selection
                fade.timingFunction = Tokens.Motion.easeOut
                Tokens.Motion.withoutAnimation { layer.opacity = opacity }
                layer.add(fade, forKey: "fade")
            }
        }
        let mark: DownloadGlyph.Mark = wasDownloading && !downloading ? .check : .arrow
        if shownMark != mark {
            shownMark = mark
            downloadsButton.glyph = DownloadGlyph.image(mark)
        }
        if wasDownloading, !downloading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, !self.wasDownloading else { return }
                self.shownMark = .arrow
                self.downloadsButton.glyph = DownloadGlyph.image(.arrow)
            }
        }
        wasDownloading = downloading
    }

    /// The ring is in this window's space accent, resolved for light or dark; set again when either changes.
    private func tintDownloadsRing() {
        downloadsRing.strokeColor = cgColor(Brand.Theme.for(self).accent)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tintDownloadsRing()
    }

    var downloadsAnchor: NSView { downloadsButton }

    /// Highlights the space dot under a window point during a drag, returning its space.
    func spaceDot(at windowPoint: NSPoint) -> UUID? {
        var found: UUID?
        for dot in dots where !dot.isHidden {
            let inside = dot.bounds.contains(dot.convert(windowPoint, from: nil))
            dot.isDropTarget = inside
            if inside { found = dot.spaceID }
        }
        return found
    }

    func clearDropTargets() { dots.forEach { $0.isDropTarget = false } }

    // MARK: Space transition

    /// Slides the old list out and the new one in, in the direction of travel. Both are real lists, not pictures of
    /// them: the new space comes in on the pane beside the list (already there mid-swipe, so it carries on from the
    /// fingers), and the list keeps showing the space you left until it's out of sight. Then the list takes the new
    /// space and the pane goes, a swap that doesn't show, made once nothing is moving. `snapshot`, a picture of the old
    /// list, is only for a switch in the middle of a drag, when the list itself has to change at once.
    func transitionList(direction: CGFloat, from old: UUID?, snapshot: NSImage? = nil) {
        let width = bounds.width
        let home = Tokens.Sidebar.edge
        // Where the list on screen is now: as the fingers left it, or partway through the last switch.
        var from = scrollView.frame.minX - home + Self.shownSlide(scrollView)
        if let pending = handOff {
            // A switch on top of a switch: the space coming in is the one on screen, and it leaves from where it is.
            from = pending.pane.scroll.frame.minX - home + Self.shownSlide(pending.pane.scroll)
            endHandOff(showing: old)
        }
        swipeGhost?.removeFromSuperview()
        let landing = landingVelocity
        landingVelocity = nil
        if swipeState == .tracking { swipeState = .finished }
        swipeEndWork?.cancel()
        swipeOffset = 0
        clearSwipeDots()
        scrollView.layer?.removeAnimation(forKey: "slide")
        Tokens.Motion.withoutAnimation { scrollView.frame.origin.x = home }
        let side: CGFloat = direction < 0 ? -1 : 1
        let incoming = pane(side)
        hidePane(pane(-side))

        // In the middle of a drag the list itself takes the new space at once, so the drag carries on in it.
        if list.isDragging {
            hidePane(incoming)
            list.refreshDuringDrag()
            if let snapshot, direction != 0 { slideGhost(snapshot, direction: direction, from: from) }
            return
        }
        guard direction != 0, let old, let target = currentSpaceID, width > 0 else {
            hidePane(incoming)
            list.reload(animated: false)
            restoreListScroll()
            updateBottomFade()
            scheduleNeighbors()
            return
        }

        // The new space beside the list, where the fingers had it, or a width away.
        if incoming.scroll.isHidden || incoming.space != target { load(incoming, space: target) }
        incoming.scroll.isHidden = false
        incoming.scroll.layer?.removeAnimation(forKey: "slide")
        incoming.scroll.layer?.removeAnimation(forKey: "fade")
        Tokens.Motion.withoutAnimation { incoming.scroll.frame = scrollView.frame }
        // The list holds on to the space you left while it goes.
        list.spaceOverride = old
        let work = DispatchWorkItem { [weak self] in self?.endHandOff(showing: nil) }
        handOff = (incoming, work)

        if Tokens.Motion.reduceMotion {
            // Nothing slides: the two lists cross-fade where they stand, the old going as the new comes, so their
            // rows never show on top of each other.
            Self.fadeIn(incoming.scroll, duration: Tokens.Motion.standard)
            Self.fadeOut(scrollView, duration: Tokens.Motion.standard * 0.6)
            DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.standard + 0.02, execute: work)
            return
        }
        let curve = landing == nil ? Tokens.Motion.spaceSwitch : Tokens.Motion.swipeSettle
        let velocity = landing ?? 0
        // The new list arrives from beside the old, at the fingers' speed after a swipe.
        let duration = Tokens.Motion.slide(incoming.scroll, fromOffsetX: side * width + from, curve: curve, fromKeyboard: true, velocity: velocity)
        // The old one leaves the other way, a width over, side by side with it.
        Self.slideOut(scrollView, from: from, to: -side * width, like: incoming.scroll)
        // A swipe keeps both lists solid, as the fingers had them; otherwise the one leaving fades, so the two never
        // compete.
        if landing == nil { Self.fadeOut(scrollView, duration: Tokens.Motion.slideDuration) }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(duration, Tokens.Motion.slideDuration) + 0.02, execute: work)
    }

    /// A switch in progress: the pane bringing the new space in, and the swap to make once it's home.
    private var handOff: (pane: SpacePane, work: DispatchWorkItem)?

    /// The swap: the list takes the space the pane brought in (or `showing`, when another switch is already on its
    /// way and the list has to stand in for the space on screen), in the same place and scrolled the same, and the pane
    /// goes.
    private func endHandOff(showing space: UUID?) {
        guard let pending = handOff else { return }
        handOff = nil
        pending.work.cancel()
        let shown = pending.pane.scroll.contentView.bounds.origin.y
        scrollView.layer?.removeAnimation(forKey: "slide")
        scrollView.layer?.removeAnimation(forKey: "fade")
        list.spaceOverride = space == currentSpaceID ? nil : space
        Tokens.Motion.withoutAnimation {
            scrollView.frame.origin.x = Tokens.Sidebar.edge
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            let maxY = max(0, list.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(shown, maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            updateBottomFade()
            hidePane(pending.pane)
        }
        if space == nil { scheduleNeighbors() }
    }

    /// How far a view is drawn from its frame by a slide still running.
    private static func shownSlide(_ view: NSView) -> CGFloat {
        guard let layer = view.layer, layer.animation(forKey: "slide") != nil else { return 0 }
        return layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
    }

    /// Moves a view from `from` to `to` (offsets from where it stands) on the same curve and in the same time as
    /// `partner`'s slide, staying there until the swap takes it back.
    private static func slideOut(_ view: NSView, from: CGFloat, to: CGFloat, like partner: NSView) {
        guard let layer = view.layer else { return }
        let animation: CABasicAnimation
        if let lead = partner.layer?.animation(forKey: "slide") as? CABasicAnimation, let copy = lead.copy() as? CABasicAnimation {
            animation = copy
        } else {
            animation = CABasicAnimation()
            animation.duration = Tokens.Motion.slideDuration
        }
        animation.keyPath = "transform.translation.x"
        animation.fromValue = from
        animation.toValue = to
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "slide")
    }

    private static func fadeOut(_ view: NSView, duration: TimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = Tokens.Motion.easeOut
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        view.layer?.add(fade, forKey: "fade")
    }

    private static func fadeIn(_ view: NSView, duration: TimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = Tokens.Motion.easeOut
        fade.fillMode = .backwards
        view.layer?.add(fade, forKey: "fade")
    }

    /// Mid-drag only: a picture of the old list slides out and fades, and the list, already the new space's, comes in.
    private func slideGhost(_ snapshot: NSImage, direction: CGFloat, from: CGFloat) {
        let width = bounds.width
        var end = scrollView.frame
        end.origin.x -= direction * width
        let ghost = NSImageView(frame: end)
        ghost.image = snapshot
        ghost.imageScaling = .scaleNone
        ghost.imageAlignment = .alignTopLeft
        ghost.wantsLayer = true
        addSubview(ghost)
        swipeGhost = ghost
        guard !Tokens.Motion.reduceMotion else { ghost.removeFromSuperview(); return }
        let duration = Tokens.Motion.slide(ghost, fromOffsetX: direction * width + from, curve: Tokens.Motion.spaceSwitch, fromKeyboard: true)
        Tokens.Motion.slide(scrollView, fromOffsetX: direction * width + from, curve: Tokens.Motion.spaceSwitch, fromKeyboard: true)
        Self.fadeOut(ghost, duration: Tokens.Motion.slideDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(duration, Tokens.Motion.slideDuration) + 0.02) { ghost.removeFromSuperview() }
    }

    /// Fills a pane with a space's list, scrolled where you left that space.
    private func load(_ pane: SpacePane, space: UUID) {
        pane.list.privateLabel = list.privateLabel
        Tokens.Motion.withoutAnimation {
            pane.scroll.frame = scrollView.frame
            pane.list.spaceOverride = space
            pane.list.setFrameSize(NSSize(width: pane.scroll.contentSize.width, height: max(pane.list.frame.height, pane.scroll.contentSize.height)))
            pane.list.reload(animated: false)
            pane.list.layoutSubtreeIfNeeded()
            let maxY = max(0, pane.list.frame.height - pane.scroll.contentView.bounds.height)
            pane.scroll.contentView.scroll(to: NSPoint(x: 0, y: min(listScroll[space] ?? 0, maxY)))
            pane.scroll.reflectScrolledClipView(pane.scroll.contentView)
            Self.fade(pane.fade, for: pane.scroll, list: pane.list)
        }
    }

    private func hidePane(_ pane: SpacePane) {
        pane.scroll.layer?.removeAnimation(forKey: "slide")
        pane.scroll.layer?.removeAnimation(forKey: "fade")
        pane.scroll.isHidden = true
    }

    private var neighborWork: DispatchWorkItem?

    /// After a switch, once things are still, the spaces either side are put in their panes, out of sight, so the next
    /// swipe finds them made and only has to bring them up to date.
    private func scheduleNeighbors() {
        neighborWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.prepareNeighbors(next: 0) }
        neighborWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// One side per turn of the run loop, so neither holds up a scroll that has just started.
    private func prepareNeighbors(next index: Int) {
        guard index < 2, handOff == nil, swipeState != .tracking, let current = currentSpaceID else { return }
        let spaces = Library.shared.spaces
        guard let at = spaces.firstIndex(where: { $0.id == current }) else { return }
        let side: CGFloat = index == 0 ? 1 : -1
        let neighbor = at + Int(side)
        let pane = pane(side)
        if pane.scroll.isHidden, spaces.indices.contains(neighbor), pane.space != spaces[neighbor].id || pane.list.subviews.isEmpty {
            load(pane, space: spaces[neighbor].id)
        }
        let work = DispatchWorkItem { [weak self] in self?.prepareNeighbors(next: index + 1) }
        neighborWork = work
        DispatchQueue.main.async(execute: work)
    }

    func listSnapshot() -> NSImage? {
        let rect = scrollView.bounds
        guard let rep = scrollView.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        scrollView.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Two-finger swipe between spaces

    var onSwipeSpace: ((Int) -> Bool)?

    /// Where a gesture over the sidebar is: not yet known to be sideways or up and down, following the fingers
    /// sideways, scrolling the list, or let go (its momentum still to swallow).
    private enum SwipeState { case idle, deciding, tracking, scrolling, finished }
    private var swipeState = SwipeState.idle

    /// Called by the window for every scroll over the sidebar. From the first sideways movement the list follows
    /// the fingers, with the next space sliding in beside it, so you can move a little and come back. Letting go
    /// lands on whichever space is nearer, or the next one after a flick that way; otherwise the list springs home.
    /// Up and down scrolls the list as usual: the first few points decide which way a gesture goes, for all of it.
    /// Returns true when it handled the event.
    func handleSwipe(_ event: NSEvent) -> Bool {
        let now = event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime
        let gap = now - lastSwipeEventTime
        lastSwipeEventTime = now

        // A mouse: a notched wheel tilted sideways or turned with Shift, or one that scrolls smoothly (Logi Options+,
        // Mos) and so sends fine steps with no gesture phases. A tiny nudge sideways switches straight away.
        let momentum = event.momentumPhase != []
        if !event.hasPreciseScrollingDeltas || (event.phase == [] && !momentum) {
            return handleWheel(event, now: now, gap: gap)
        }

        // A new gesture starts on its first phase.
        if event.phase == .began || event.phase == .mayBegin {
            // The last one's end never came: it lets go where it is before this one starts.
            if swipeState == .tracking { finishSwipe(velocity: 0) }
            beginSwipe()
        }

        switch swipeState {
        case .idle:
            // Momentum from a scroll that's over, or a gesture that started before the pointer came over the sidebar.
            if momentum { return false }
            beginSwipe()
        case .scrolling:
            // Its momentum, if any, scrolls the list too (idle lets it through).
            if event.phase == .ended || event.phase == .cancelled { swipeState = .idle }
            return false
        case .finished:
            // The rest of a sideways gesture is part of it, momentum included, so the list never drifts after it.
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled { swipeState = .idle; return true }
            // Fingers still down after the end went missing: pick the list back up.
            guard event.phase == .changed else { return true }
            // It may have landed on another space meanwhile: its neighbors are the ones now.
            swipeGeneration += 1
            findNeighbors()
            startTracking()
        case .deciding, .tracking:
            break
        }
        if momentum { return true }

        if swipeState == .deciding {
            if event.phase == .ended || event.phase == .cancelled { swipeState = .idle; return false }
            swipeAccumX += event.scrollingDeltaX
            swipeAccumY += event.scrollingDeltaY
            if abs(swipeAccumY) >= SpaceSwipe.axisLock, abs(swipeAccumY) > abs(swipeAccumX) {
                swipeState = .scrolling
                return false
            }
            guard abs(swipeAccumX) >= SpaceSwipe.axisLock, abs(swipeAccumX) > abs(swipeAccumY) else {
                // Still deciding; hold sideways movement so the list doesn't twitch.
                return abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            startTracking()
            swipeTravel += swipeAccumX
            swipeSamples.append((now, swipeAccumX))
            moveSwipe()
            scheduleSwipeEnd()
            return true
        }

        // Following the fingers.
        if event.phase == .ended || event.phase == .cancelled {
            swipeSamples.append((now, 0))
            finishSwipe(velocity: event.phase == .ended ? SpaceSwipe.velocity(swipeSamples, at: now) : 0, cancelled: event.phase == .cancelled)
            return true
        }
        swipeTravel += event.scrollingDeltaX
        swipeSamples.append((now, event.scrollingDeltaX))
        swipeSamples.removeAll { now - $0.time > SpaceSwipe.velocityWindow }
        moveSwipe()
        scheduleSwipeEnd()
        return true
    }

    /// One turn of the wheel, however many notches or fine steps it sends, moves one space: steps closer together
    /// than a moment belong to the same turn, so a free spinning wheel never races through every space.
    private func handleWheel(_ event: NSEvent, now: TimeInterval, gap: TimeInterval) -> Bool {
        if gap > SpaceSwipe.wheelTurnGap {
            wheelAccumX = 0
            wheelAccumY = 0
            wheelTurnSwitched = false
        }
        wheelAccumX += event.scrollingDeltaX
        wheelAccumY += event.scrollingDeltaY
        // Up and down scrolls the list as usual.
        guard abs(wheelAccumX) > abs(wheelAccumY) else { return false }
        // A notch is enough; fine steps need the same few points that tell a trackpad gesture is sideways.
        if !wheelTurnSwitched, abs(wheelAccumX) > (event.hasPreciseScrollingDeltas ? SpaceSwipe.axisLock : 0) {
            wheelTurnSwitched = true
            _ = onSwipeSpace?(wheelAccumX > 0 ? -1 : 1)
        }
        return true
    }

    private var lastSwipeEventTime: TimeInterval = 0
    private var wheelAccumX: CGFloat = 0
    private var wheelAccumY: CGFloat = 0
    private var wheelTurnSwitched = false
    private var swipeAccumX: CGFloat = 0
    private var swipeAccumY: CGFloat = 0
    /// How far the fingers have moved sideways since the list started following them.
    private var swipeTravel: CGFloat = 0
    /// Where that puts the list: the travel, held back past the first and last space.
    private var swipeTarget: CGFloat = 0
    /// How far the list is drawn from home right now (stays 0 with Reduce Motion, where nothing moves until it lands).
    private var swipeOffset: CGFloat = 0
    private var swipeSamples: [(time: TimeInterval, dx: CGFloat)] = []
    /// The spaces on either side of the one this gesture started in.
    private var swipeNeighbors: (left: UUID?, right: UUID?) = (nil, nil)
    /// Set while a swipe lands, so the new list carries on at the fingers' speed.
    private var landingVelocity: CGFloat?
    private weak var swipeGhost: NSView?
    private var swipeEndWork: DispatchWorkItem?
    /// Counts gestures, so a spring-back finishing late doesn't hide the neighbor a newer gesture is showing.
    private var swipeGeneration = 0

    private func beginSwipe() {
        swipeGeneration += 1
        swipeState = .deciding
        swipeAccumX = 0
        swipeAccumY = 0
        swipeEndWork?.cancel()
        findNeighbors()
    }

    /// The spaces either side of the one in front now.
    private func findNeighbors() {
        let spaces = Library.shared.spaces
        let index = spaces.firstIndex { $0.id == currentSpaceID }
        swipeNeighbors = (index.flatMap { $0 > 0 ? spaces[$0 - 1].id : nil },
                          index.flatMap { $0 + 1 < spaces.count ? spaces[$0 + 1].id : nil })
    }

    /// The gesture is sideways: from here the list follows the fingers. Caught while still settling from the last
    /// swipe, it's picked up from where it is on screen.
    private func startTracking() {
        swipeState = .tracking
        swipeSamples = []
        var shown = Self.shownSlide(scrollView)
        if let pending = handOff {
            // Still sliding in from the last switch: the space coming in is the one picked up, from where it is.
            shown = pending.pane.scroll.frame.minX - Tokens.Sidebar.edge + Self.shownSlide(pending.pane.scroll) - swipeOffset
            endHandOff(showing: nil)
        }
        scrollView.layer?.removeAnimation(forKey: "slide")
        for pane in [panes.left, panes.right] { pane.scroll.layer?.removeAnimation(forKey: "slide") }
        swipeGhost?.removeFromSuperview()
        swipeTravel = SpaceSwipe.travel(toOffset: swipeOffset + shown, width: bounds.width,
                                        hasLeft: swipeNeighbors.left != nil, hasRight: swipeNeighbors.right != nil)
        moveSwipe()
    }

    private func moveSwipe() {
        swipeTarget = SpaceSwipe.offset(forTravel: swipeTravel, width: bounds.width,
                                        hasLeft: swipeNeighbors.left != nil, hasRight: swipeNeighbors.right != nil)
        // With Reduce Motion nothing slides: the gesture still decides, and the space changes in place.
        guard !Tokens.Motion.reduceMotion else { return }
        swipeOffset = swipeTarget
        Tokens.Motion.withoutAnimation {
            scrollView.frame.origin.x = Tokens.Sidebar.edge + swipeOffset
            showNeighbor()
        }
        // The dots follow too: the pill shrinks on this space and grows on the one coming in.
        let width = bounds.width
        let share = width > 0 ? min(abs(swipeOffset) / width, 1) : 0
        let incoming = swipeOffset > 0 ? swipeNeighbors.left : swipeOffset < 0 ? swipeNeighbors.right : nil
        for dot in dots {
            dot.swipeShare = dot.spaceID == currentSpaceID ? 1 - share : dot.spaceID == incoming ? share : nil
        }
    }

    /// The dots go back to showing only the space you're in.
    private func clearSwipeDots() { dots.forEach { $0.swipeShare = nil } }

    /// Puts the space the fingers are pulling in one sidebar width beside the current list. Its pane was filled ahead
    /// of time; here it's only brought up to date, a row at a time where anything changed.
    private func showNeighbor() {
        let side: CGFloat = swipeOffset > 0 ? -1 : 1
        if !pane(-side).scroll.isHidden { hidePane(pane(-side)) }
        let shown = pane(side)
        guard swipeOffset != 0, let neighbor = side < 0 ? swipeNeighbors.left : swipeNeighbors.right else {
            if !shown.scroll.isHidden { hidePane(shown) }
            return
        }
        if shown.scroll.isHidden {
            load(shown, space: neighbor)
            shown.scroll.isHidden = false
        } else if shown.space != neighbor {
            load(shown, space: neighbor)
        }
        placePanes()
    }

    /// Each pane out during a swipe sits a sidebar width beside the list, on its side; one bringing a switch in is
    /// where the list is.
    private func placePanes() {
        for (side, pane) in [(CGFloat(-1), panes.left), (1, panes.right)] where !pane.scroll.isHidden {
            var frame = scrollView.frame
            if handOff?.pane !== pane { frame.origin.x += side * bounds.width }
            pane.scroll.frame = frame
        }
    }

    /// A safety net for an end that never arrives (macOS sometimes drops it): resting fingers send nothing, so it
    /// waits long, and then only springs home, never switching space under fingers that may still be down.
    private func scheduleSwipeEnd() {
        swipeEndWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.swipeState == .tracking else { return }
            self.finishSwipe(velocity: 0, cancelled: true)
        }
        swipeEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Letting go: lands on the next space or springs home, carrying on at the fingers' speed either way.
    private func finishSwipe(velocity: CGFloat, cancelled: Bool = false) {
        swipeEndWork?.cancel()
        guard swipeState == .tracking else { return }
        swipeState = .finished
        let direction = cancelled ? 0 : SpaceSwipe.landing(offset: swipeTarget, velocity: velocity, width: bounds.width)
        let neighbor = direction < 0 ? swipeNeighbors.left : direction > 0 ? swipeNeighbors.right : nil
        if neighbor != nil {
            // The switch slides the new list in from where the neighbor is now (transitionList).
            landingVelocity = velocity
            if onSwipeSpace?(direction) == true { Haptics.snap(); return }
            landingVelocity = nil
        }
        settleHome(velocity: velocity)
    }

    private func settleHome(velocity: CGFloat) {
        let offset = swipeOffset
        swipeOffset = 0
        swipeTarget = 0
        clearSwipeDots()
        let out = [panes.left, panes.right].filter { !$0.scroll.isHidden }
        guard offset != 0 else { out.forEach(hidePane); return }
        Tokens.Motion.withoutAnimation {
            scrollView.frame.origin.x = Tokens.Sidebar.edge
            placePanes()
        }
        let curve = Tokens.Motion.swipeSettle
        Tokens.Motion.slide(scrollView, fromOffsetX: offset, curve: curve, velocity: velocity)
        guard let pane = out.first else { return }
        let duration = Tokens.Motion.slide(pane.scroll, fromOffsetX: offset, curve: curve, velocity: velocity)
        // Hidden once home, unless a new swipe has it out again; it stays filled, and is brought up to date when it
        // next shows.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak pane] in
            guard let self, let pane, self.swipeState != .tracking, self.handOff?.pane !== pane else { return }
            self.hidePane(pane)
        }
    }

    /// The space this sidebar shows; set by the window. Leaving one remembers how far down its list was scrolled.
    var currentSpaceID: UUID? {
        didSet {
            guard let old = oldValue, old != currentSpaceID else { return }
            // Mid-switch the space on screen is the one in the pane coming in.
            if let pending = handOff, pending.pane.space == old {
                listScroll[old] = pending.pane.scroll.contentView.bounds.origin.y
            } else {
                listScroll[old] = scrollView.contentView.bounds.origin.y
            }
        }
    }
    /// How far down each space's list was, so coming back to a space finds it where you left it.
    private var listScroll: [UUID: CGFloat] = [:]

    /// The list where it was when you last left this space, or at the top for one you haven't scrolled.
    #if DEBUG
    /// listscroll <y>: the list scrolled to y, or with no number, how far it's scrolled (in debug.log).
    func debugListScroll(_ y: CGFloat?) {
        if let y { scrollView.contentView.scroll(to: NSPoint(x: 0, y: y)); scrollView.reflectScrolledClipView(scrollView.contentView) }
        debugLog("listscroll \(scrollView.contentView.bounds.origin.y) of \(list.frame.height)")
    }
    #endif

    private func restoreListScroll() {
        list.layoutSubtreeIfNeeded()
        let saved = currentSpaceID.flatMap { listScroll[$0] } ?? 0
        let maxY = max(0, list.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(saved, maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

}

/// The rules of a swipe between spaces, apart from the views so they can be checked on their own. Offsets and
/// velocities are in points, positive when the list moves right (which brings in the space on the left).
enum SpaceSwipe {
    /// How far the fingers move before a gesture counts as sideways or up and down, for the rest of it.
    static let axisLock: CGFloat = 4
    /// Letting go past this share of the width lands on the next space: a third of the way is enough to mean it.
    static let landingShare: CGFloat = 0.35
    /// A flick at least this fast (points per second) lands, however short: an easy flick, not a hard one.
    static let flickSpeed: CGFloat = 300
    /// How much recent movement counts toward the speed at letting go.
    static let velocityWindow: TimeInterval = 0.08
    /// A mouse wheel going quiet this long ends one turn of it; the next turn can move another space.
    static let wheelTurnGap: TimeInterval = 0.25
    /// Past the first or last space the list gives less the further it's pulled, up to this share of the width.
    static let edgeGive: CGFloat = 0.5
    private static let edgeStiffness: CGFloat = 0.55

    /// Where the fingers' travel puts the list: one to one toward a neighbor (at most a full width), held back
    /// like a rubber band where there's none.
    static func offset(forTravel travel: CGFloat, width: CGFloat, hasLeft: Bool, hasRight: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        if travel > 0 ? hasLeft : hasRight { return max(-width, min(width, travel)) }
        let limit = width * edgeGive
        let pulled = (1 - 1 / (abs(travel) * edgeStiffness / limit + 1)) * limit
        return travel < 0 ? -pulled : pulled
    }

    /// The travel that puts the list at `offset`: the reverse of `offset(forTravel:)`, to pick a moving list up.
    static func travel(toOffset offset: CGFloat, width: CGFloat, hasLeft: Bool, hasRight: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        if offset > 0 ? hasLeft : hasRight { return offset }
        let limit = width * edgeGive
        let share = min(abs(offset) / limit, 0.95)
        let travel = (1 / (1 - share) - 1) * limit / edgeStiffness
        return offset < 0 ? -travel : travel
    }

    /// Which way letting go goes: -1 to the space on the left, 1 to the right, 0 back home. A flick decides on its
    /// own (the way the list is already pulled lands; back toward home doesn't); otherwise it's how far it went.
    static func landing(offset: CGFloat, velocity: CGFloat, width: CGFloat) -> Int {
        guard offset != 0 else { return 0 }
        let toward = offset > 0 ? -1 : 1
        if abs(velocity) >= flickSpeed { return (velocity > 0) == (offset > 0) ? toward : 0 }
        return abs(offset) >= width * landingShare ? toward : 0
    }

    /// The fingers' speed at `now`, in points per second, from the movement in the last moment.
    static func velocity(_ samples: [(time: TimeInterval, dx: CGFloat)], at now: TimeInterval) -> CGFloat {
        let recent = samples.filter { now - $0.time <= velocityWindow }
        guard let first = recent.first, recent.count > 1, now > first.time else { return 0 }
        // The first sample's movement happened before its time, so it's the start of the span, not part of it.
        return recent.dropFirst().reduce(0) { $0 + $1.dx } / CGFloat(now - first.time)
    }
}

/// The count on an extension's button, the same in the address and in Site Controls: a small dark pill with white
/// figures in the button's bottom-right corner, over the icon's corner and inside the button, as Chrome and Safari
/// draw it. "!" when the extension needs you is a small dot in the top-right corner instead.
final class BadgeView: NSView {
    private(set) var text: String
    private var attention: Bool
    /// From the button's bottom and right edges to the pill (top and right to the dot).
    var inset: CGFloat = BadgeView.buttonInset { didSet { needsLayout = true } }

    /// The pill: 12pt tall, 9pt semibold figures, 3pt either side, never narrower than it's tall.
    static let height: CGFloat = 12
    static let padding: CGFloat = 3
    static let dot: CGFloat = 7
    /// In an address button: a point in from its edges, inside its rounded corner.
    static let buttonInset: CGFloat = 1
    /// At most this many characters, as Chrome shows.
    static let maxLength = 4
    static var font: NSFont { .systemFont(ofSize: Tokens.TypeSize.badge, weight: .semibold) }

    /// The pill's size for `text`, no wider than `limit`.
    static func size(for text: String, limit: CGFloat = .greatestFiniteMagnitude) -> NSSize {
        let ink = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return NSSize(width: min(limit, max(height, ink + padding * 2)), height: height)
    }

    /// Where the pill for `text` sits in a button of `bounds` (top-left origin): its bottom-right corner, `inset` in.
    static func frame(for text: String, in bounds: NSRect, inset: CGFloat) -> NSRect {
        let size = size(for: text, limit: bounds.width - inset * 2)
        return NSRect(x: bounds.maxX - inset - size.width, y: bounds.maxY - inset - size.height, width: size.width, height: size.height)
    }

    /// Where the attention dot sits: the top-right corner, `inset` in.
    static func dotFrame(in bounds: NSRect, inset: CGFloat) -> NSRect {
        NSRect(x: bounds.maxX - inset - dot, y: bounds.minY + inset, width: dot, height: dot)
    }

    init(text: String, attention: Bool) {
        self.text = String(text.prefix(Self.maxLength))
        self.attention = attention
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// What it says now, in place.
    func update(text: String, attention: Bool) {
        self.text = String(text.prefix(Self.maxLength))
        self.attention = attention
        needsLayout = true
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        needsLayout = true
    }

    /// Places itself in its button, so whoever holds it never has to.
    override func layout() {
        super.layout()
        guard let superview else { return }
        // In the button's own top-left terms, whichever way it counts.
        var rect = attention ? Self.dotFrame(in: superview.bounds, inset: inset) : Self.frame(for: text, in: superview.bounds, inset: inset)
        if !superview.isFlipped { rect.origin.y = superview.bounds.height - rect.maxY }
        if frame != rect { frame = rect; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        (attention ? NSColor.systemOrange : Tokens.Color.badge).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        guard !attention, !text.isEmpty else { return }
        let font = Self.font
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let width = string.size().width
        // The figures' cap height centered in the pill, not the line box, so they sit in its optical middle.
        let baseline = ((rect.height + font.capHeight) / 2).rounded()
        string.draw(at: NSPoint(x: (rect.width - width) / 2, y: baseline - font.ascender))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The download button's picture, drawn to match the sidebar's 13pt symbols in size and weight: a circle, and an
/// arrow or (for a moment, when downloads finish) a check in it.
enum DownloadGlyph {
    enum Mark { case arrow, check }
    /// Drawn to the size of the bottom bar's other symbols (`Sidebar.glyph`): the circle's diameter through the middle
    /// of its line, and the line, as SF's arrow.down.circle has them.
    static let circle: CGFloat = (Tokens.Sidebar.glyph * 1.046 * 10).rounded() / 10
    static let line: CGFloat = LineGlyph.stroke
    /// The arrow and the check were drawn for a 13.6pt circle; they grow with it.
    private static let k = circle / 13.6

    static func image(_ mark: Mark) -> NSImage {
        let line = Self.line, k = Self.k
        let side = circle + line
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            NSColor.black.setStroke()
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: line / 2, dy: line / 2))
            ring.lineWidth = line
            ring.stroke()
            let path = NSBezierPath()
            path.lineWidth = line
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: c.x + x * k, y: c.y + y * k) }
            switch mark {
            case .arrow:
                path.move(to: p(0, -3.6))
                path.line(to: p(0, 3.4))
                path.move(to: p(-2.9, 0.6))
                path.line(to: p(0, 3.5))
                path.line(to: p(2.9, 0.6))
            case .check:
                path.move(to: p(-3.1, 0.2))
                path.line(to: p(-0.9, 2.5))
                path.line(to: p(3.3, -2.4))
            }
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A space's list, beside the sidebar's own: where a swipe shows the space it's pulling in, and where a switch slides
/// the next space in from.
@MainActor
private final class SpacePane {
    let list = SidebarListView()
    let scroll = NSScrollView()
    let fade = CAGradientLayer()

    init() {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = list
        scroll.isHidden = true
        scroll.wantsLayer = true
        scroll.layer?.mask = fade
    }

    /// The space it shows, once loaded.
    var space: UUID? { list.spaceOverride }
}

/// The space dots' row: it clips them, and scrolls sideways (a trackpad swipe or the wheel) when there are more than
/// fit, its ends fading so you can tell there's more.
private final class DotStrip: NSView {
    /// The smallest a dot's target gets before the row scrolls instead.
    static let smallest = Tokens.Space.x4
    private let content = NSView()
    private let fade = CAGradientLayer()
    var contentWidth: CGFloat = 0 { didSet { scroll(to: offset, animated: false) } }
    private var offset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        super.addSubview(content)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func addSubview(_ view: NSView) { content.addSubview(view) }

    override func layout() {
        super.layout()
        scroll(to: offset, animated: false)
    }

    /// Brings a dot (in the row's own terms) into view, as little as it takes.
    func reveal(_ rect: NSRect) {
        var target = offset
        if rect.minX < target { target = rect.minX - Self.smallest / 2 }
        if rect.maxX > target + bounds.width { target = rect.maxX - bounds.width + Self.smallest / 2 }
        scroll(to: target, animated: window != nil)
    }

    override func scrollWheel(with event: NSEvent) {
        guard contentWidth > bounds.width else { super.scrollWheel(with: event); return }
        // Sideways or up and down, both move along the row.
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scroll(to: offset - delta * (event.hasPreciseScrollingDeltas ? 1 : Tokens.Space.x4), animated: false)
    }

    /// More dots than fit: the row scrolls.
    var scrolls: Bool { contentWidth > bounds.width }

    /// A dot held near either end (`x` in the row's own terms) scrolls the row on toward it, a step a frame, faster
    /// the closer it is. Returns whether it moved.
    func carry(at x: CGFloat) -> Bool {
        guard scrolls else { return false }
        let edge = Tokens.Space.x6
        let depth = x < edge ? x - edge : x > bounds.width - edge ? x - (bounds.width - edge) : 0
        guard depth != 0 else { return false }
        let before = offset
        let step = min(abs(depth), edge) / edge * 4 + 1
        scroll(to: offset + (depth < 0 ? -step : step), animated: false)
        return offset != before
    }

    private func scroll(to target: CGFloat, animated: Bool) {
        offset = min(max(0, target), max(0, contentWidth - bounds.width))
        let frame = NSRect(x: -offset, y: 0, width: max(contentWidth, bounds.width), height: bounds.height)
        if animated, !Tokens.Motion.reduceMotion {
            Tokens.Motion.animate(Tokens.Motion.snappy) { self.content.animator().frame = frame }
        } else {
            content.frame = frame
        }
        // A soft edge only where more dots wait past it.
        guard contentWidth > bounds.width, bounds.width > 0 else { layer?.mask = nil; return }
        let edge = min(Self.smallest / bounds.width, 0.3)
        let start = offset > 0.5 ? 0.0 : 1.0, end = offset < contentWidth - bounds.width - 0.5 ? 0.0 : 1.0
        let opaque = NSColor.black.cgColor
        fade.colors = [NSColor.black.withAlphaComponent(start).cgColor, opaque, opaque, NSColor.black.withAlphaComponent(end).cgColor]
        fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        Tokens.Motion.withoutAnimation { fade.frame = bounds }
        layer?.mask = fade
    }
}

/// Where a space's dot carried along the row lands.
enum SpaceReorder {
    /// The gap a pointer at `x` is over, among dots whose middles are `middles`, left to right: 0 before the first,
    /// `middles.count` after the last. The carried dot's own middle counts, as it still holds its place.
    static func slot(at x: CGFloat, middles: [CGFloat]) -> Int { middles.filter { $0 < x }.count }

    /// The index the space carried from `from` ends up at when dropped in `slot`; nil where it wouldn't move (the
    /// gaps either side of it).
    static func destination(slot: Int, from: Int) -> Int? {
        let to = slot > from ? slot - 1 : slot
        return to == from ? nil : to
    }
}
