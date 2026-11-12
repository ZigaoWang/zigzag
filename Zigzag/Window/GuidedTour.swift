import AppKit

/// Getting started, in the window itself: one step at a time, the place to act lit up, and a small pill beside
/// it with the keys and three words. It follows along as you do the step (the address bar, a peek), then shows
/// you what changed for a moment before moving on, so nothing happens unnoticed.
final class GuidedTour: NSView {
    private static weak var current: GuidedTour?
    private weak var controller: BrowserWindowController?
    private let dim = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let card = FloatingPanelView()
    private let step = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let check = NSImageView()
    private let title = Label("", font: .systemFont(ofSize: 22, weight: .semibold), color: Tokens.Color.textPrimary)
    private let note = Label("", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    private var caps: [(ColorView, Label)] = []
    private let skip = TextButton(title: String(localized: "Skip", comment: "Button in the getting-started guide, a card in the window: skips the step."), font: Tokens.Font.small(.medium))
    /// Ends the guide for good; Help › Getting Started brings it back.
    private let close = IconButton(symbol: "xmark", size: .compact, toolTip: String(localized: "End Getting Started", comment: "Tooltip of the close button of the getting-started guide, a card in the window."))
    private let finish = PrimaryButton(title: String(localized: "Start Browsing", comment: "Button that ends the getting-started guide, a card in the window, after its last step."))
    // The last card: a note from the person who made Zigzag.
    private let wordmark = WordmarkView()
    private let letter = NSTextField(wrappingLabelWithString: "")
    private let signature = Label(String(localized: "Zigao, who makes Zigzag", comment: "Signature under the thank-you note at the end of the getting-started guide, a card in the window. Zigao is the maker's name."), font: Tokens.Font.body(.medium), color: Tokens.Color.textSecondary)
    /// The step shown being done, in the window itself, on your own tabs and buttons.
    private lazy var demo = TourDemo(in: layer!)
    /// Where Peek's link is on the page, looked up now and then as you scroll.
    private var peekLink: CGPoint?
    private var peekLinkAsked = Date.distantPast
    private var tokens: [SignalToken] = []
    private var watch: Timer?
    private var ending = false
    /// The app, the window, its being covered or in the Dock: whatever decides whether anyone can see the guide.
    private var observers: [NSObjectProtocol] = []
    /// The card has stepped aside for another panel, and its demo with it.
    private var isAside = false

    /// Showing what a step just did, before the next one.
    private var confirming: Tutorial.Task?
    /// What the pill shows now, so it only redraws when that changes.
    private var shown = ""
    /// The step the pill was last showing, so its note follows it.
    private var lastStepID: String?
    /// The step points at something in the sidebar: with the sidebar hidden, it slides out and stays out meanwhile.
    private var pointsIntoSidebar = false

    /// Whether the guide in this window keeps the hidden sidebar slid out, to point at something in it.
    static func holdsSidebar(in window: NSWindow?) -> Bool {
        guard let current, current.pointsIntoSidebar, !current.ending else { return false }
        return window != nil && current.window === window
    }

    /// Starts, or picks up at the step you're on. Nothing happens once every step is done or it was ended.
    static func start(in controller: BrowserWindowController) {
        guard Tutorial.current != nil, !Tutorial.isHidden else { return }
        current?.removeFromSuperview()
        let tour = GuidedTour(controller: controller)
        current = tour
        tour.frame = controller.root.overlay.bounds
        tour.autoresizingMask = [.width, .height]
        controller.root.overlay.addSubview(tour, positioned: .below, relativeTo: nil)
        tour.refresh(animated: false)
        tour.alphaValue = 0
        Tokens.Motion.animate(Tokens.Motion.gentle, evenFromKeyboard: true) { tour.animator().alphaValue = 1 }
    }

    private init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        dim.fillRule = .evenOdd
        layer?.addSublayer(dim)
        ring.fillColor = nil
        // Bold enough to find at a glance, with a soft glow of its color around it.
        ring.lineWidth = 3
        ring.shadowOpacity = 0.6
        ring.shadowRadius = 8
        ring.shadowOffset = .zero
        layer?.addSublayer(ring)
        _ = demo
        applyColors()
        check.image = Tokens.Symbol.image("checkmark.circle.fill", size: Tokens.TypeSize.display)
        skip.textColor = NSColor.white.withAlphaComponent(0.6)
        // Dark, whatever the page: a white card on a white page disappears.
        card.surfaceTint = NSColor(white: 0.1, alpha: 1)
        card.tintStrength = 0.94
        card.appearance = NSAppearance(named: .darkAqua)
        card.radius = Tokens.Radius.large
        [step, check, title, note, skip, close, finish, wordmark, letter, signature].forEach { card.addSubview($0) }
        [title, note].forEach { $0.lineBreakMode = .byTruncatingTail }
        wordmark.color = .white
        letter.isSelectable = false
        letter.font = Tokens.Font.body()
        letter.textColor = Tokens.Color.textPrimary
        letter.alignment = .center
        signature.alignment = .center
        letter.stringValue = String(localized: "Thanks for trying Zigzag. I made it to be a calm home for everything you do on the web. I hope it feels that way.", comment: "Thank-you note from the maker at the end of the getting-started guide, a card in the window, signed by him.")
        
        addSubview(card)
        // One skip per step: a burst of clicks never runs past steps you haven't seen.
        skip.onClick = { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastSkip) > 0.6 else { return }
            self.lastSkip = Date()
            Tutorial.skip()
        }
        finish.onClick = { [weak self] _ in self?.end() }
        close.onClick = { [weak self] _ in
            Tutorial.isHidden = true
            self?.end()
        }
        tokens.append(Tutorial.changed.observe { [weak self] in self?.stepDone() })
        tokens.append(Brand.themeChanged.observe { [weak self] in self?.applyColors() })
        tokens.append(controller.tabManager.changed.observe { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(animated: true) }
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The guide lives in a browser window, so it's in that window's space accent, resolved for light or dark;
    /// set again whenever either changes.
    private func applyColors() {
        let accent = Brand.Theme.for(self).accent
        dim.fillColor = cgColor(NSColor.black.withAlphaComponent(0.28))
        // What to click next is ringed in the space's own accent.
        ring.strokeColor = cgColor(accent)
        ring.shadowColor = cgColor(accent)
        check.contentTintColor = accent
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    isolated deinit {
        watch?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        applyColors()
        if let window {
            let app: [Notification.Name] = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
            let own: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            for (names, object) in [(app, nil as NSWindow?), (own, window)] {
                for name in names {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.pace() }
                    })
                }
            }
        }
        pace()
    }

    /// Whether you could be looking at the guide: Zigzag in front, and this window on screen and not covered.
    private var canBeSeen: Bool {
        guard let window, NSApp.isActive else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// Follows along only while it can be seen, and picks up where it was when it can again.
    private func pace() {
        if !ending, canBeSeen {
            if watch == nil {
                // Follows what you're doing: the address bar opening, a peek opening and closing.
                let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                timer.tolerance = 0.05
                watch = timer
            }
        } else {
            watch?.invalidate()
            watch = nil
        }
    }

    override var isFlipped: Bool { true }

    /// Everything outside the pill goes straight to the browser, so you can do the step while the guide is up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        card.frame.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    private func end() {
        ending = true
        watch?.invalidate()
        watch = nil
        tokens = []
        demo.clear()
        Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true, { self.animator().alphaValue = 0 },
                              completion: { [weak self] in self?.removeFromSuperview() })
    }

    // MARK: Following along

    private func tick() {
        guard let controller, !ending else { return }
        // Other panels (site controls, downloads) come first: the guide steps aside.
        let bar = controller.commandBar.isVisible, peek = controller.peek.isVisible
        let editing = SpaceEditorPanel.current != nil
        let spaceStep = editingNewSpace || confirming?.id == "space"
        // The tab overview is the overview step's own screen: the guide stays, to say what to do there.
        let overviewStep = controller.desk.isVisible && (Tutorial.current?.id == "overview" || confirming?.id == "overview")
        let relevant = (bar && Tutorial.current?.id == "newTab") || (peek && Tutorial.current?.id == "peek") || (editing && spaceStep) || overviewStep
        let aside = !relevant && (controller.hasFloatingPanel || peek)
        // During the Peek step the card sits above the peek, so "Close it" is right there; otherwise it stays beneath
        // everything that floats.
        if let overlay = superview {
            // Over the tab overview too, while it's the step: "every tab, at a glance" is said over it.
            let onTop = (peek && Tutorial.current?.id == "peek") || overviewStep
            if onTop, overlay.subviews.last !== self { overlay.addSubview(self) }
            if !onTop, overlay.subviews.first !== self { overlay.addSubview(self, positioned: .below, relativeTo: nil) }
        }
        if isAside != aside { isAside = aside }
        let alpha: CGFloat = aside ? 0 : 1
        if alphaValue != alpha {
            Tokens.Motion.animate(Tokens.Motion.snap, evenFromKeyboard: true) { self.animator().alphaValue = alpha }
        }
        refresh(animated: true)
    }

    /// You did it: the pill turns into a short note on what changed, pointing at it, then the next step.
    private func stepDone() {
        guard confirming == nil else { return }
        // Skipped, not done: straight on to the next step.
        if let skipped = Tutorial.skipped {
            Tutorial.skipped = nil
            if skipped == lastStepID { refresh(animated: true); return }
        }
        confirming = Tutorial.tasks.first { $0.id == lastStepID && Tutorial.done.contains($0.id) }
        refresh(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self else { return }
            self.confirming = nil
            self.refresh(animated: true)
        }
    }

    // MARK: What to show

    private struct Display: Equatable {
        var keys: [String]
        var title: String
        var note: String
        var count: String
        var isDone: Bool
        var isFinal: Bool
        var target: String
    }

    /// The + made a space and opened its editor. Making it already counted, so the guide is on to "go back" by now,
    /// but the editor is still part of the space step.
    private var editingNewSpace: Bool {
        SpaceEditorPanel.current != nil && [nil, "space", "switch"].contains(Tutorial.current?.id)
    }

    private var display: Display {
        guard let controller else { return Display(keys: [], title: "", note: "", count: "", isDone: false, isFinal: true, target: "") }
        // The + opened the new space's editor: say what it's for, and finish once it's closed.
        if editingNewSpace {
            return Display(keys: ["↩"], title: String(localized: "Name it, then pick its color", comment: "A hint in the middle of a step in the getting-started guide, a card in the window, while the new space's editor is open."),
                           note: String(localized: "Return keeps it, Esc cancels", comment: "Under a hint in the getting-started guide, a card in the window, while the new space's editor is open. Return and Esc are keys."), count: "", isDone: false, isFinal: false, target: "editor")
        }
        if let done = confirming {
            return Display(keys: [], title: done.done, note: done.doneNote, count: "", isDone: true, isFinal: false, target: "done." + done.id)
        }
        guard let task = Tutorial.current, let index = Tutorial.tasks.firstIndex(where: { $0.id == task.id }) else {
            return Display(keys: [], title: String(localized: "You’re all set", comment: "Title of the getting-started guide, a card in the window once every step is done."), note: "", count: "", isDone: false, isFinal: true, target: "")
        }
        let step = index + 1, steps = Tutorial.tasks.count
        let count = String(localized: "Step \(step) of \(steps)", comment: "Which step of the getting-started guide, a card in the window this is, like Step 2 of 7.")
        // Mid-step hints, where you are, for the moment you'd otherwise stall.
        // Searching a site, a key at a time: its name, Tab, then what to find.
        if task.id == "newTab", controller.commandBar.isVisible {
            if controller.commandBar.isSearchingSite {
                return Display(keys: ["↩"], title: String(localized: "Type what to find, then Return", comment: "A hint in the middle of a step in the getting-started guide, a card in the window, while searching a site from the command bar. Return is the key."),
                               note: String(localized: "For example: lofi music", comment: "Under a hint in the getting-started guide, a card in the window: something to search YouTube for."), count: "", isDone: false, isFinal: false, target: "bar")
            }
            if controller.commandBar.isOfferingSiteSearch {
                return Display(keys: ["Tab"], title: String(localized: "Press Tab", comment: "A hint in the middle of a step in the getting-started guide, a card in the window, when the command bar offers to search YouTube. Tab is the key."),
                               note: String(localized: "Now you’re searching on YouTube", comment: "Under a hint in the getting-started guide, a card in the window, when the command bar offers to search YouTube."), count: "", isDone: false, isFinal: false, target: "bar")
            }
            return Display(keys: [], title: String(localized: "Type “youtube”", comment: "A hint in the middle of a step in the getting-started guide, a card in the window. Keep youtube as it is: it's what to type."),
                           note: String(localized: "Just the word", comment: "Under the hint to type youtube, in the getting-started guide, a card in the window."), count: "", isDone: false, isFinal: false, target: "bar")
        }
        if task.id == "peek", controller.peek.isVisible {
            return Display(keys: ["Esc"], title: String(localized: "Close it", comment: "A hint in the middle of a step in the getting-started guide, a card in the window, while a Peek is open. The Esc key is shown beside it."),
                           note: String(localized: "Or click outside it", comment: "Under the hint to close a Peek, in the getting-started guide, a card in the window."), count: "", isDone: false, isFinal: false, target: "peek")
        }
        if task.id == "peek" { return Display(keys: task.keys, title: task.title, note: task.note, count: count, isDone: false, isFinal: false, target: "article") }
        // In the overview: what it's for is in front of you, so the hint is how to get back to a page.
        if task.id == "overview", controller.desk.isVisible {
            return Display(keys: [], title: String(localized: "Click a tab to go to it", comment: "A hint in the middle of a step in the getting-started guide, a card in the window, while the tab overview (every tab as a card) is open."),
                           note: String(localized: "Or press Esc to go back", comment: "Under a hint in the getting-started guide, a card in the window, while the tab overview is open. Esc is the key."), count: "", isDone: false, isFinal: false, target: "desk")
        }
        // The + opens a menu: the space is its last item.
        if task.id == "space", let menu = MenuPanel.current, menu.anchor === controller.sidebar.newSpaceAnchor {
            return Display(keys: [], title: String(localized: "Click New Space", comment: "A hint in the middle of a step in the getting-started guide, a card in the window, while the menu of the sidebar's + is open. New Space is an item in that menu."),
                           note: "", count: "", isDone: false, isFinal: false, target: "addmenu")
        }
        // Names the very tab to drag, and a cursor in the window shows the drag on it: a ring alone reads as the tab
        // you're on.
        if task.id == "split" {
            let title = splitCandidate.map {
                let name = Self.shortName($0.title)
                return String(localized: "Drag “\(name)” onto the page", comment: "The split view step's title in the getting-started guide, a card in the window, naming the tab to drag. The name is a page's title.")
            } ?? task.title
            return Display(keys: [], title: title, note: String(localized: "It opens beside this one", comment: "Under the split view step's title in the getting-started guide, a card in the window."),
                           count: count, isDone: false, isFinal: false, target: "split")
        }
        // A space made in Settings leaves you where you were: the last step is then to go to the new one.
        if task.id == "switch", let index = Library.shared.spaces.firstIndex(where: { $0.id == controller.tabManager.currentSpaceID }),
           !Tutorial.switchGoesBack(currentSpaceIndex: index) {
            return Display(keys: [], title: String(localized: "Switch to your new space", comment: "The last step's title in the getting-started guide, a card in the window, when you're still in the space you started in."),
                           note: task.note, count: count, isDone: false, isFinal: false, target: "switchNew")
        }
        return Display(keys: task.keys, title: task.title, note: task.note, count: count, isDone: false, isFinal: false, target: task.id)
    }

    /// Where to point.
    private func view(for target: String) -> NSView? {
        guard let controller else { return nil }
        let row = controller.tabManager.selectedTab.flatMap { controller.sidebar.list.row(for: $0) }
        switch target {
        case "newTab": return controller.sidebar.address
        case "bar": return controller.commandBar.panelView
        case "pin", "done.newTab", "done.pin": return row ?? controller.sidebar.list
        case "peek": return controller.peek.panelView
        case "done.peek", "article": return controller.root.card
        case "split": return splitCandidate.flatMap { controller.sidebar.list.row(for: $0) }
        case "done.split", "overview", "done.overview": return controller.root.card
        case "space": return controller.sidebar.newSpaceAnchor
        case "editor": return SpaceEditorPanel.current
        case "addmenu": return MenuPanel.current
        case "switch": return controller.sidebar.firstDotAnchor
        case "switchNew": return controller.sidebar.lastDotAnchor
        case "done.space", "done.switch": return controller.sidebar.dotsAnchor
        default: return nil
        }
    }

    private func refresh(animated: Bool) {
        let now = display
        let key = "\(now)"
        if key != shown {
            shown = key
            if !now.isDone, !now.isFinal {
                if Tutorial.current?.id == "peek", lastStepID != "peek" {
                    openArticle()
                    if !hasSplitPartner { openSplitPartner() }
                }
                if ["overview", "split"].contains(Tutorial.current?.id), lastStepID != Tutorial.current?.id { openSplitPartner() }
                lastStepID = Tutorial.current?.id
            }
            // A different card (another step, done or finished): the old one leaves first, the new one arrives in its
            // own place. Only small changes within a card, like the bar's typing hints, move in place.
            let swap = animated && (now.isDone != shownDone || now.isFinal || (!now.count.isEmpty && now.count != shownCount))
            shownDone = now.isDone
            shownCount = now.count.isEmpty ? shownCount : now.count
            if swap {
                swapping = true
                Tokens.Motion.animate(Tokens.Motion.snap, evenFromKeyboard: true, { self.card.animator().alphaValue = 0 }, completion: { [weak self] in
                    guard let self else { return }
                    self.swapping = false
                    let latest = self.display
                    self.apply(latest, animated: false)
                    self.layoutTour(latest, animated: false)
                    self.card.alphaValue = 1
                    self.card.present(arrival: .pop)
                })
                return
            }
            apply(now, animated: animated)
        }
        if swapping { return }
        layoutTour(now, animated: animated)
    }

    private var shownDone = false
    private var shownCount = ""
    private var swapping = false

    /// Peek needs a page full of links: an article, opened for you, rather than asking you to find one.
    private func openArticle() {
        guard let controller, controller.tabManager.selectedTab?.url?.host()?.hasSuffix("wikipedia.org") != true,
              let url = URL(string: "https://en.wikipedia.org/wiki/Web_browser") else { return }
        controller.open(url, disposition: .foregroundTab, allowSwitch: false)
    }

    /// The page the guide opens to go beside yours: its own, so the step never names some other tab of yours.
    /// Wikipedia sends it on to "Split screen (computing)", so any of its Split screen pages counts.
    private static let splitPartnerURL = URL(string: "https://en.wikipedia.org/wiki/Split_screen_(computer_graphics)")!

    /// The guide's own pages: Peek's article and the one opened to go beside it.
    private static func isGuidePage(_ url: URL?) -> Bool {
        guard let url, url.host()?.hasSuffix("wikipedia.org") == true else { return false }
        return url.path.hasPrefix("/wiki/Split_screen") || url.path.hasPrefix("/wiki/Web_browser")
    }

    /// The guide's other page, once open, if it can go beside the one you're on. Either one: the overview step
    /// may have left you on the second.
    private var splitCandidate: Tab? {
        guard let controller, let current = controller.tabManager.selectedTab else { return nil }
        let manager = controller.tabManager
        return manager.tabs(in: manager.currentSpaceID).first {
            $0 !== current && Self.isGuidePage($0.url) && manager.split(for: $0) == nil && manager.canSplit(current, with: $0)
        }
    }

    /// A tab's title without its site's name or an aside ("Split screen (computing) - Wikipedia" is "Split screen"),
    /// short enough for the card.
    private static func shortName(_ title: String) -> String {
        var name = title
        for separator in [" - ", " – ", " — ", " | "] {
            if let range = name.range(of: separator, options: .backwards), range.lowerBound > name.startIndex {
                name = String(name[..<range.lowerBound])
                break
            }
        }
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards), open.lowerBound > name.startIndex {
            name = String(name[..<open.lowerBound])
        }
        return name.count > 28 ? String(name.prefix(27)).trimmingCharacters(in: .whitespaces) + "…" : name
    }

    /// The guide's second page is open in this space already.
    private var hasSplitPartner: Bool {
        guard let controller else { return false }
        let manager = controller.tabManager
        return manager.tabs(in: manager.currentSpaceID).contains { $0.url?.host()?.hasSuffix("wikipedia.org") == true && $0.url?.path.hasPrefix("/wiki/Split_screen") == true }
    }

    /// Split View needs a second ordinary tab: the guide opens its own, behind this one.
    private func openSplitPartner() {
        guard let controller, splitCandidate == nil else { return }
        controller.open(Self.splitPartnerURL, disposition: .backgroundTab, allowSwitch: false)
    }

    private func apply(_ d: Display, animated: Bool) {
        caps.forEach { $0.0.removeFromSuperview() }
        caps = []
        for key in d.keys {
            // The keys in the space's accent, white on it: what to press stands out first.
            let cap = ColorView(color: Brand.Theme.for(self).accent)
            cap.wantsLayer = true
            cap.layer?.cornerRadius = Tokens.Radius.control
            cap.layer?.cornerCurve = .continuous
            let label = Label(key, font: .systemFont(ofSize: 18, weight: .semibold), color: Brand.Theme.for(self).onAccent)
            label.alignment = .center
            cap.addSubview(label)
            card.addSubview(cap)
            caps.append((cap, label))
        }
        title.stringValue = d.title
        note.stringValue = d.note
        step.stringValue = d.count
        check.isHidden = !d.isDone
        // Naming a new space is the middle of a step: nothing to skip there.
        // Mid-step hints (no count) are part of a step: nothing to skip there, and the pill stays small.
        skip.isHidden = d.isDone || d.isFinal || d.count.isEmpty
        close.isHidden = d.isFinal
        countShown = !(d.isDone || d.isFinal || d.count.isEmpty)
        step.isHidden = !countShown
        finish.isHidden = !d.isFinal
        note.isHidden = d.isFinal || d.note.isEmpty
        [wordmark, letter, signature].forEach { $0.isHidden = !d.isFinal }
        title.alignment = d.isFinal ? .center : .left
        title.font = d.isFinal ? Brand.displayFont(Tokens.TypeSize.display) : .systemFont(ofSize: 22, weight: .semibold)
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Tokens.Motion.snap.duration
            fade.timingFunction = Tokens.Motion.snap.timing
            card.layer?.add(fade, forKey: "step")
        }
    }

    override func layout() {
        super.layout()
        layoutTour(display, animated: false)
    }

    /// Whether the card says which step this is, room allowing.
    private var countShown = false

    /// The card's size, no wider than `room` (the page, less its margins): in a narrow window the step count gives
    /// way first, then the words end in "…", so the card stays over the page and off the sidebar.
    private func pillSize(_ d: Display, room: CGFloat) -> NSSize {
        guard !d.isFinal else { return pillSize(d) }
        step.isHidden = !countShown
        var size = pillSize(d)
        if size.width > room, countShown {
            step.isHidden = true
            size = pillSize(d)
        }
        size.width = max(Tokens.Tour.minCardWidth, min(size.width, floor(room)))
        return size
    }

    private func pillSize(_ d: Display) -> NSSize {
        if d.isFinal {
            typealias F = Tokens.Tour
            let inner = F.finalWidth - F.finalPad * 2
            let lh = ceil(letter.sizeThatFits(NSSize(width: inner, height: 400)).height)
            return NSSize(width: F.finalWidth, height: F.finalPad + F.finalWordmark + Tokens.Space.x6 + F.finalTitleHeight + Tokens.Space.x3 + lh
                          + Tokens.Space.x3 + signature.lineHeight + Tokens.Space.x8 + Tokens.Space.x10 + F.finalPad)
        }
        let keys = caps.map { max(Tokens.Tour.keySide, $0.1.inkWidth + Tokens.Space.x4) }.reduce(0, +) + CGFloat(max(caps.count - 1, 0)) * Tokens.Tour.keyGap
        let text = max(title.textWidth, d.note.isEmpty ? 0 : note.textWidth)
        var width = Tokens.Space.x4 + (d.isDone ? Tokens.Tour.checkSide : keys) + Tokens.Space.x3 + text + Tokens.Space.x5
        if !skip.isHidden { width += skip.fittingWidth - Tokens.Space.x2 }
        if !close.isHidden { width += close.frame.width + Tokens.Space.x1 }
        if !step.isHidden { width += step.textWidth + Tokens.Space.x3 }
        let row = d.note.isEmpty ? Tokens.Tour.rowHeight : Tokens.Tour.rowWithNoteHeight
        // One width for every step, so the card never jumps.
        return NSSize(width: max(ceil(width), Self.cardWidth), height: row)
    }

    private func layoutTour(_ d: Display, animated: Bool) {
        let target = view(for: d.target)
        // Out first, so the ring goes where the sidebar is, not where it hides.
        pointsIntoSidebar = !d.isFinal && controller.map { target?.isDescendant(of: $0.sidebar) == true } ?? false
        if pointsIntoSidebar { controller?.root.reveal(true) }
        if let target, ["pin", "split"].contains(d.target) { scrollIntoSight(target) }
        let visible = target.flatMap { $0.window != nil ? shownRect(of: $0) : nil }
        let hole = Tutorial.ringRect(visible: visible, outset: Tokens.Tour.ringOutset, within: bounds, margin: ring.lineWidth + Tokens.Space.x1,
                                       roundBelow: Tokens.Tour.ringRoundBelow) ?? .zero
        // Dragging a tab onto the page uses the sidebar and the page at once: nothing dimmed, nothing ringed.
        // The tab to drag keeps its ring, so you know which one.
        // Nothing is dimmed: the window stays as it is, and a soft ring marks only small things to click.
        let cut = CGMutablePath()
        let page = controller?.root.cardFrame ?? bounds
        let ringed = hole != .zero && !d.isDone && !d.isFinal && hole.width < page.width * 0.6 && !["bar", "editor", "peek", "addmenu"].contains(d.target)
        // Something as small as a space's dot gets a round ring; anything bigger, a rounded rectangle.
        let radius = max(hole.width, hole.height) < Tokens.Tour.ringRoundBelow ? min(hole.width, hole.height) / 2 : Tokens.Radius.tile
        let ringPath: CGPath = ringed ? CGPath(roundedRect: hole, cornerWidth: radius, cornerHeight: radius, transform: nil) : CGMutablePath()
        // A spotlight: everything but the thing to click dims a little, so the eye goes straight to it. Only the dim
        // is drawn; clicks pass through it as ever.
        _ = cut
        // Pulses only when it lands on something new, never on every layout.
        if ringed, d.target != pulsedTarget { pulsedTarget = d.target; pulse(true) } else if !ringed { pulsedTarget = nil; pulse(false) }
        demo.show(gesture(for: d, target: target, hole: hole, ringed: ringed, page: page), in: self)
        let curve = Tokens.Motion.gentle
        if animated, ring.path != ringPath, !Tokens.Motion.reduceMotion {
            for (layer, path) in [(dim, cut as CGPath), (ring, ringPath)] {
                let move = CABasicAnimation(keyPath: "path")
                move.fromValue = layer.presentation()?.path ?? layer.path
                move.toValue = path
                move.duration = curve.duration
                move.timingFunction = curve.timing
                layer.add(move, forKey: "move")
            }
        }
        // This runs on every look at what you're doing; touching the layers only when something moved keeps
        // the window from redrawing several times a second while nothing changes.
        Tokens.Motion.withoutAnimation {
            if dim.frame != bounds { dim.frame = bounds }
            if ring.frame != bounds { ring.frame = bounds }
            if dim.path.map({ $0 != cut }) ?? true { dim.path = cut }
            if ring.path.map({ $0 != ringPath }) ?? true { ring.path = ringPath }
        }

        // The card stays over the page, and off the sidebar where it's slid out over the page to point into it.
        var cardArea = page
        if let root = controller?.root, root.isSidebarFloatingVisible {
            let sidebar = root.sidebarContainer.convert(root.sidebarContainer.bounds, to: self)
            if root.sidebarOnRight {
                if sidebar.minX > cardArea.minX, sidebar.minX < cardArea.maxX {
                    cardArea = NSRect(x: cardArea.minX, y: cardArea.minY, width: sidebar.minX - cardArea.minX, height: cardArea.height)
                }
            } else if sidebar.maxX > cardArea.minX, sidebar.maxX < cardArea.maxX {
                cardArea = NSRect(x: sidebar.maxX, y: cardArea.minY, width: cardArea.maxX - sidebar.maxX, height: cardArea.height)
            }
        }
        let size = pillSize(d, room: cardArea.width - Tokens.Space.x8 * 2)
        var frame: NSRect
        if !d.isFinal {
            // Right under the address bar while it's open (where your eyes are), otherwise a bar at the bottom middle of
            // the page, never over what you need to click.
            if d.target == "bar", hole != .zero {
                frame = NSRect(x: hole.midX - size.width / 2, y: hole.maxY + Tokens.Space.x3, width: size.width, height: size.height)
            } else {
                frame = NSRect(x: windowCentered(size.width, in: cardArea), y: page.maxY - size.height - Tokens.Space.x8, width: size.width, height: size.height)
                // Never over the +'s menu: beside it instead.
                if d.target == "addmenu", hole != .zero, frame.intersects(hole) { frame.origin.x = hole.maxX + Tokens.Space.x4 }
            }
        } else if hole == .zero {
            // Where ⌘T's bar opens: centered on the whole window, a little above the middle of the page.
            frame = NSRect(x: windowCentered(size.width, in: page), y: page.minY + max(Tokens.Space.x12, floor(page.height * 0.18)),
                           width: size.width, height: size.height)
        } else if d.target == "bar" || d.target == "editor" {
            // Right under the bar or the editor: next to what you're looking at.
            frame = NSRect(x: d.target == "bar" ? hole.midX - size.width / 2 : hole.minX, y: hole.maxY + Tokens.Space.x3, width: size.width, height: size.height)
        } else if d.target == "peek", let sidebar = controller?.root.sidebarContainer.frame, sidebar.width > size.width * 0.8 {
            // The peek fills the page, so the pill waits in the sidebar, clear of it.
            frame = NSRect(x: sidebar.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        } else if hole.width > page.width * 0.6 {
            // The page itself: the pill sits inside it, bottom right, clear of links.
            frame = NSRect(x: page.maxX - size.width - Tokens.Space.x6, y: page.maxY - size.height - Tokens.Space.x6, width: size.width, height: size.height)
        } else {
            // Beside the lit place, to its right, level with it; to its left when there's no room on the right (a
            // sidebar on the right).
            frame = NSRect(x: hole.maxX + Tokens.Space.x4, y: hole.midY - size.height / 2, width: size.width, height: size.height)
            if frame.maxX > bounds.width - Tokens.Space.x4 { frame.origin.x = hole.minX - Tokens.Space.x4 - size.width }
        }
        frame.origin.x = min(max(Tokens.Space.x4, frame.origin.x), bounds.width - size.width - Tokens.Space.x4)
        frame.origin.y = min(max(Tokens.Space.x2, frame.origin.y), bounds.height - size.height - Tokens.Space.x4)
        // With Reduce Motion the card simply appears in its new place.
        if animated, card.frame != frame, !Tokens.Motion.reduceMotion {
            Tokens.Motion.animate(curve, evenFromKeyboard: true, moves: true) { self.card.animator().frame = frame }
        } else if card.frame != frame {
            card.frame = frame
        }
        layoutPill(d, in: frame.size)
    }

    /// Where a view is, here, cut to what the scroll views around it show: a row scrolled half away is ringed only
    /// where you can see it.
    private func shownRect(of view: NSView) -> NSRect {
        var rect = view.convert(view.bounds, to: self)
        var ancestor = view.superview
        while let current = ancestor {
            if current is NSClipView { rect = rect.intersection(current.convert(current.bounds, to: self)) }
            ancestor = current.superview
        }
        return rect.isNull ? .zero : rect
    }

    /// The row to ring, scrolled into sight once if the list has it out of view.
    private weak var scrolledTo: NSView?
    private func scrollIntoSight(_ target: NSView) {
        guard target !== scrolledTo, target.window != nil else { return }
        scrolledTo = target
        if shownRect(of: target).height < target.bounds.height { target.scrollToVisible(target.bounds) }
    }

    static let cardWidth = Tokens.Tour.cardWidth
    /// When Skip was last pressed.
    private var lastSkip = Date.distantPast
    /// The step whose ring last pulsed.
    private var pulsedTarget: String?

    /// A ring pulses until you do what it marks, so it's never missed, however long you take.
    private func pulse(_ on: Bool) {
        guard on, !Tokens.Motion.reduceMotion else {
            if ring.animation(forKey: "pulse") != nil { ring.removeAnimation(forKey: "pulse") }
            if ring.opacity != 1 { ring.opacity = 1 }
            return
        }
        guard ring.animation(forKey: "pulse") == nil else { return }
        let beat = CABasicAnimation(keyPath: "opacity")
        beat.fromValue = 1
        beat.toValue = 0.25
        beat.duration = 0.45
        beat.autoreverses = true
        beat.repeatCount = .infinity
        beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(beat, forKey: "pulse")
    }

    /// What the step is shown doing: the drag, click or swipe it asks for, on the real thing.
    private func gesture(for d: Display, target: NSView?, hole: NSRect, ringed: Bool, page: NSRect) -> TourDemo.Gesture? {
        guard !d.isDone, !d.isFinal, !isAside, let controller else { return nil }
        let center = CGPoint(x: hole.midX, y: hole.midY)
        switch d.target {
        case "split":
            // Picks up the ringed tab and drops it on the page's right half, where it would open.
            guard ringed, let target else { return nil }
            let drop = NSRect(x: page.midX, y: page.minY, width: page.width / 2, height: page.height)
                .insetBy(dx: Tokens.Metric.dropInset * 2, dy: Tokens.Metric.dropInset * 2)
            return .drag(row: target, from: CGPoint(x: hole.minX + Tokens.Tour.ringOutset, y: hole.minY + Tokens.Tour.ringOutset), drop: drop)
        case "space":
            return ringed ? .click(at: center, holding: nil) : nil
        case "switch", "switchNew":
            // Two fingers across the sidebar's list, toward the space to go to: back to the first (to the left, so
            // they go right), or on to the new one (to the right, so they go left).
            let list = controller.sidebar.list.convert(controller.sidebar.list.bounds, to: self)
            let band = NSRect(x: list.minX, y: list.minY + min(list.height, 240) / 2 - 20, width: list.width, height: 40)
            return list.width > 0 ? .swipe(across: band, toRight: d.target == "switch") : nil
        case "article":
            findPeekLink()
            return peekLink.map { .click(at: $0, holding: "⇧") }
        default:
            return nil
        }
    }

    /// Finds a link in the article you can see, for Peek's step to click on, now and then as you scroll.
    private func findPeekLink() {
        guard Date().timeIntervalSince(peekLinkAsked) > 1, let webView = controller?.selectedWebView else { return }
        peekLinkAsked = Date()
        let script = """
        (() => {
          const links = document.querySelectorAll('#mw-content-text p a[href^="/wiki/"], main p a[href], article p a[href], p a[href]');
          for (const a of links) {
            const r = a.getBoundingClientRect();
            if (r.width > 24 && r.top > 80 && r.bottom < innerHeight * 0.6) return [r.left + Math.min(r.width / 2, 40), r.top + r.height / 2];
          }
          return null;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
            MainActor.assumeIsolated {
                guard let self, let webView, let point = result as? [Double], point.count == 2 else { self?.peekLink = nil; return }
                let zoom = webView.pageZoom * webView.magnification
                let inPage = NSPoint(x: point[0] * zoom, y: point[1] * zoom)
                let flipped = webView.isFlipped ? inPage : NSPoint(x: inPage.x, y: webView.bounds.height - inPage.y)
                let spot = webView.convert(flipped, to: self)
                guard spot != self.peekLink else { return }
                self.peekLink = spot
                self.needsLayout = true
            }
        }
    }

    /// Like ⌘T's bar: centered on the whole window, not just the page beside the sidebar, but kept inside the page.
    private func windowCentered(_ width: CGFloat, in page: NSRect) -> CGFloat {
        let margin = Tokens.Space.x8
        return min(max(page.minX + margin, floor(bounds.midX - width / 2)), page.maxX - width - margin)
    }

    private func layoutPill(_ d: Display, in size: NSSize) {
        let width = size.width
        let top: CGFloat = 0
        let height = size.height
        if d.isFinal {
            typealias F = Tokens.Tour
            let pad = F.finalPad, inner = width - pad * 2
            // One calm surface, centered: the wordmark, the title, the note and who wrote it, then the way out.
            let wh = F.finalWordmark
            wordmark.frame = NSRect(x: (width - wh * WordmarkView.aspect) / 2, y: pad, width: wh * WordmarkView.aspect, height: wh)
            title.frame = NSRect(x: pad, y: wordmark.frame.maxY + Tokens.Space.x6, width: inner, height: F.finalTitleHeight)
            let lh = ceil(letter.sizeThatFits(NSSize(width: inner, height: 400)).height)
            letter.frame = NSRect(x: pad, y: title.frame.maxY + Tokens.Space.x3, width: inner, height: lh)
            signature.frame = NSRect(x: pad, y: letter.frame.maxY + Tokens.Space.x3, width: inner, height: signature.lineHeight)
            finish.frame = NSRect(x: pad, y: signature.frame.maxY + Tokens.Space.x8, width: inner, height: Tokens.Space.x10)
            return
        }
        var x = Tokens.Space.x4
        if d.isDone {
            let c = Tokens.Tour.checkSide
            check.frame = NSRect(x: x, y: top + (height - c) / 2, width: c, height: c)
            x = check.frame.maxX + Tokens.Space.x3
        }
        for (cap, label) in caps {
            let side = Tokens.Tour.keySide
            let w = max(side, label.inkWidth + Tokens.Space.x4)
            cap.frame = NSRect(x: x, y: top + (height - side) / 2, width: w, height: side)
            label.frame = NSRect(x: 0, y: (side - label.lineHeight) / 2, width: w, height: label.lineHeight)
            x += w + Tokens.Tour.keyGap
        }
        if !caps.isEmpty { x += Tokens.Space.x3 - Tokens.Tour.keyGap }
        let sw = skip.fittingWidth
        let cs = IconButton.Size.compact.side
        close.frame = NSRect(x: width - Tokens.Space.x3 - cs, y: top + (height - cs) / 2, width: cs, height: cs)
        let end = close.isHidden ? width - Tokens.Space.x2 : close.frame.minX - Tokens.Space.x1
        skip.frame = NSRect(x: end - sw, y: top + (height - Tokens.Space.x8) / 2, width: sw, height: Tokens.Space.x8)
        let cw = step.textWidth + 2
        step.frame = NSRect(x: skip.frame.minX - Tokens.Space.x1 - cw, y: top + (height - step.lineHeight) / 2, width: cw, height: step.lineHeight)
        // The words take what's left, ending in "…" when the card is as narrow as the page.
        let right = !step.isHidden ? step.frame.minX : !skip.isHidden ? skip.frame.minX : !close.isHidden ? close.frame.minX : width
        let room = max(0, right - x)
        if note.isHidden {
            title.frame = NSRect(x: x, y: top + (height - title.lineHeight) / 2, width: min(title.textWidth + 4, room), height: title.lineHeight)
        } else {
            // Title, and the why beneath it, as one block in the middle.
            let block = title.lineHeight + 2 + note.lineHeight
            title.frame = NSRect(x: x, y: top + (height - block) / 2, width: min(title.textWidth + 4, room), height: title.lineHeight)
            note.frame = NSRect(x: x, y: title.frame.maxY + 2, width: min(note.textWidth + 4, room), height: note.lineHeight)
        }
    }
}
