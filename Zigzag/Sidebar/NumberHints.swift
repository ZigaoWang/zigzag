import AppKit

/// ⌘1–⌘9 count the sidebar's places as it shows them: each favorite tile, then each pinned page and tab row.
enum TabNumbers {
    /// Where a number goes among `count` places: ⌘1–⌘8 to their own, ⌘9 to the last, as in every browser. A number
    /// past the end goes to the last too.
    static func index(for number: Int, count: Int) -> Int? {
        guard count > 0, (1...9).contains(number) else { return nil }
        return number == 9 ? count - 1 : min(number - 1, count - 1)
    }

    /// The number each place shows while ⌘ is held: its own for the first eight, 9 on the last, none in between.
    static func labels(count: Int) -> [Int?] {
        (0..<max(0, count)).map { i in i < 8 ? i + 1 : i == count - 1 ? 9 : nil }
    }
}

/// ⌃1–⌃9 count the spaces in their order along the bottom of the sidebar: each number goes to its own space, ⌃9 to the
/// ninth (not the last, as ⌘9 does with tabs), and a number with no space goes nowhere.
enum SpaceNumbers {
    static func index(for number: Int, count: Int) -> Int? {
        guard (1...9).contains(number), number <= count else { return nil }
        return number - 1
    }

    /// The number each space shows while ⌃ is held: the first nine theirs, none past them.
    static func labels(count: Int) -> [Int?] {
        (0..<max(0, count)).map { $0 < 9 ? $0 + 1 : nil }
    }
}

/// When holding a modifier has gone on long enough to show the numbers it goes with, as Safari does for ⌘: that
/// modifier alone, held `delay` with no key pressed and nothing clicked meanwhile. Anything else on the way (another
/// modifier, a key, a click) spoils it until every modifier is let go, so typing ⌘T, ⌘W, ⌃Tab or ⌃1 quickly never
/// shows them.
struct ModifierHold {
    static let delay: TimeInterval = 0.5
    static let modifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]

    /// The one modifier this hold waits for: ⌘ for the tabs' numbers, ⌃ for the spaces'.
    let modifier: NSEvent.ModifierFlags
    /// When the modifier alone went down, while it's still held and nothing else has happened.
    private var since: TimeInterval?
    private var spoiled = false

    init(_ modifier: NSEvent.ModifierFlags) { self.modifier = modifier }

    /// The modifiers held changed.
    mutating func modifiersChanged(to flags: NSEvent.ModifierFlags, at time: TimeInterval) {
        let held = flags.intersection(Self.modifiers)
        if held.isEmpty {
            spoiled = false
            since = nil
        } else if held == modifier, !spoiled {
            if since == nil { since = time }
        } else {
            spoiled = true
            since = nil
        }
    }

    /// A key, a click or a scroll, or the window going to the back: no numbers until the modifier is pressed afresh.
    mutating func interrupted(holding flags: NSEvent.ModifierFlags) {
        since = nil
        spoiled = !flags.intersection(Self.modifiers).isEmpty
    }

    /// Whether these flags are the modifier alone, as the hold wants them.
    func isAlone(_ flags: NSEvent.ModifierFlags) -> Bool { flags.intersection(Self.modifiers) == modifier }

    /// When the numbers are due, while the modifier alone is held.
    var dueAt: TimeInterval? { since.map { $0 + Self.delay } }
    func isDue(at time: TimeInterval) -> Bool { dueAt.map { time >= $0 - 0.001 } ?? false }
}

/// The number a place answers to while ⌘ is held, written as the menus write it ("⌘1") on a small quiet key: the
/// space key's face and hairline, in the row's own muted ink. In a favorite's corner it's the digit alone. Never takes
/// clicks; VoiceOver has the menu items.
final class NumberHintView: NSView {
    static let height: CGFloat = 16
    private let label = Label("", font: Tokens.Font.figures(Tokens.TypeSize.small, weight: .semibold))

    var number = 0 { didSet { refreshText() } }
    var showsCommand = true { didSet { if oldValue != showsCommand { refreshText() } } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.small
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Tokens.Metric.hairline
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// "⌘1" as the menus write it; the digit alone when there's no room for both.
    static func text(_ number: Int, command: Bool) -> String { command ? "⌘\(number)" : "\(number)" }

    /// How wide the key is: its text with a little room each side, never narrower than it is tall.
    var width: CGFloat {
        let ink = ceil((Self.text(number, command: showsCommand) as NSString).size(withAttributes: [.font: label.font ?? Tokens.Font.small()]).width)
        return max(Self.height, ink + Tokens.Space.x1 * 2)
    }

    private func refreshText() {
        label.stringValue = Self.text(number, command: showsCommand)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: -Label.inset, y: (bounds.height - label.lineHeight) / 2, width: bounds.width + Label.inset * 2, height: label.lineHeight)
        refreshColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    func refreshColors() {
        label.textColor = Brand.Theme.for(self).quietInk
        Tokens.Motion.withoutAnimation {
            layer?.backgroundColor = cgColor(Tokens.Chrome.key)
            layer?.borderColor = cgColor(Tokens.Chrome.keyEdge)
        }
    }

    /// Shown with a short soft fade (at once with Reduce Motion), gone at once: the moment ⌘ is let go, the place is
    /// yours again.
    func show(_ shown: Bool) {
        if shown {
            refreshColors()
            if Tokens.Motion.reduceMotion {
                alphaValue = 1
            } else {
                Tokens.Motion.animate(Tokens.Motion.Curve(duration: Tokens.Motion.hoverFade), evenFromKeyboard: true) { self.animator().alphaValue = 1 }
            }
        } else {
            layer?.removeAllAnimations()
            alphaValue = 0
        }
    }
}

/// Holding ⌘ a moment shows, on each favorite and row, the number that goes to it with ⌘, as Safari does with its
/// tabs; holding ⌃ shows, on each space key, the number that goes to it with ⌃. Letting go, any key, a click, a scroll
/// or the window going to the back hides them at once.
final class NumberHints {
    /// The tabs' numbers with ⌘, the spaces' with ⌃: each waits on its own hold, and only one is ever held alone.
    private enum Kind: CaseIterable {
        case tabs, spaces
        var modifier: NSEvent.ModifierFlags { self == .tabs ? .command : .control }
    }

    private weak var controller: BrowserWindowController?
    private var holds = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, ModifierHold($0.modifier)) })
    private var timers: [Kind: Timer] = [:]
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private(set) var isShown = false
    private(set) var areSpacesShown = false

    init(controller: BrowserWindowController) {
        self.controller = controller
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify, .swipe]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        let center = NotificationCenter.default
        let away: [(Notification.Name, Any?)] = [(NSWindow.didResignKeyNotification, controller.window), (NSApplication.didResignActiveNotification, nil)]
        for (name, object) in away {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interrupt() }
            })
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        timers.values.forEach { $0.invalidate() }
        timers = [:]
        hide()
        hideSpaces()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            for kind in Kind.allCases {
                holds[kind]?.modifiersChanged(to: event.modifierFlags, at: event.timestamp)
                if let due = holds[kind]?.dueAt {
                    if timers[kind] == nil { schedule(kind, after: max(0, due - ProcessInfo.processInfo.systemUptime)) }
                } else {
                    timers.removeValue(forKey: kind)?.invalidate()
                    hide(kind)
                }
            }
        } else {
            interrupt(holding: event.modifierFlags)
        }
    }

    private func interrupt(holding flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        for kind in Kind.allCases {
            holds[kind]?.interrupted(holding: flags)
            timers.removeValue(forKey: kind)?.invalidate()
            hide(kind)
        }
    }

    private func schedule(_ kind: Kind, after delay: TimeInterval) {
        timers[kind] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timers[kind] = nil
                // Still held: no release slipped by unseen (a menu open, another app in front).
                guard let hold = self.holds[kind], hold.isDue(at: ProcessInfo.processInfo.systemUptime),
                      hold.isAlone(NSEvent.modifierFlags) else { return }
                switch kind {
                case .tabs: self.show()
                case .spaces: self.showSpaces()
                }
            }
        }
    }

    private func hide(_ kind: Kind) {
        switch kind {
        case .tabs: hide()
        case .spaces: hideSpaces()
        }
    }

    /// Only in the window you're in, while its sidebar is on screen (slid out, when it's hidden) and nothing sits over
    /// it. In the tab overview the numbers pick its cards instead, so there are none in the sidebar then.
    /// `focused`: false skips the window being the one you're in (debug builds drive it from outside).
    private func canShow(focused: Bool) -> Bool {
        guard let controller, let window = controller.window, window.attachedSheet == nil, !controller.desk.isVisible else { return false }
        if focused, !window.isKeyWindow || !NSApp.isActive { return false }
        return controller.root.sidebarVisible || controller.root.isSidebarFloatingVisible
    }

    /// As for the tabs' numbers, and only while there are space keys to show them on (more than one space, not in a
    /// private window), with no switcher or command bar up: the space switcher lists its own ⌃ numbers.
    private func canShowSpaces(focused: Bool) -> Bool {
        guard canShow(focused: focused), let controller, controller.sidebar.hasSpaceKeys,
              !controller.switcher.isActive, !controller.spaceSwitcher.isActive, !controller.commandBar.isVisible else { return false }
        return true
    }

    func show(force: Bool = false) {
        guard let controller, force || canShow(focused: true) else { return }
        let favorites = Library.shared.favoriteTiles(in: controller.tabManager.profile.id).map(\.0.id)
        let rows = controller.sidebar.list.pageRows
        let labels = TabNumbers.labels(count: favorites.count + rows.count)
        var tileNumbers: [UUID: Int] = [:]
        for (i, id) in favorites.enumerated() { if let n = labels[i] { tileNumbers[id] = n } }
        var rowNumbers: [SidebarItem: Int] = [:]
        for (i, item) in rows.enumerated() { if let n = labels[favorites.count + i] { rowNumbers[item] = n } }
        controller.sidebar.favorites.showNumbers(tileNumbers)
        controller.sidebar.list.showNumbers(rowNumbers)
        isShown = true
    }

    func showSpaces(force: Bool = false) {
        guard let controller, force || canShowSpaces(focused: true) else { return }
        controller.sidebar.showsSpaceNumbers = true
        areSpacesShown = true
    }

    #if DEBUG
    /// As holding ⌘ would show them, whether or not the window is in front.
    func debugShow() { if canShow(focused: false) { show(force: true) } }
    /// As holding ⌃ would show them, whether or not the window is in front.
    func debugShowSpaces() { if canShowSpaces(focused: false) { showSpaces(force: true) } }
    #endif

    func hide() {
        guard isShown, let controller else { return }
        isShown = false
        controller.sidebar.favorites.showNumbers([:])
        controller.sidebar.list.showNumbers([:])
    }

    func hideSpaces() {
        guard areSpacesShown, let controller else { return }
        areSpacesShown = false
        controller.sidebar.showsSpaceNumbers = false
    }

    /// The list or the favorites changed under the numbers (a page closed on its own): they follow. The space keys
    /// follow on their own.
    func placesChanged() {
        if isShown { show(force: true) }
    }
}
