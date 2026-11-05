import AppKit
import AVFoundation

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
    private let skip = TextButton(title: "Skip", font: Tokens.Font.small(.medium))
    private let finish = PrimaryButton(title: "Start Browsing")
    // The last card: a note from the person who made Zigzag.
    private let wordmark = WordmarkView()
    private let letter = NSTextField(wrappingLabelWithString: "")
    private let signature = Label("Zigao, who makes Zigzag", font: Tokens.Font.body(.medium), color: Tokens.Color.textSecondary)
    /// A short real recording of the step being done, on a loop, above what to do.
    private let video = NSView()
    private let videoLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var clipName: String?
    private var tokens: [SignalToken] = []
    private var watch: Timer?
    private var ending = false
    /// The app, the window, its being covered or in the Dock: whatever decides whether anyone can see the guide.
    private var observers: [NSObjectProtocol] = []
    /// The card has stepped aside for another panel, so its recording has no one to play to.
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
        layer?.addSublayer(ghost)
        applyColors()
        check.image = Tokens.Symbol.image("checkmark.circle.fill", size: Tokens.TypeSize.display)
        skip.textColor = NSColor.white.withAlphaComponent(0.6)
        // Dark, whatever the page: a white card on a white page disappears.
        card.surfaceTint = NSColor(white: 0.1, alpha: 1)
        card.tintStrength = 0.94
        card.appearance = NSAppearance(named: .darkAqua)
        card.radius = Tokens.Radius.large
        [step, check, title, note, skip, finish, wordmark, letter, signature, video].forEach { card.addSubview($0) }
        video.wantsLayer = true
        video.layer?.cornerRadius = Tokens.Radius.row
        video.layer?.cornerCurve = .continuous
        video.layer?.masksToBounds = true
        videoLayer.videoGravity = .resizeAspectFill
        video.layer?.addSublayer(videoLayer)
        wordmark.color = .white
        letter.isSelectable = false
        letter.font = Tokens.Font.body()
        letter.textColor = Tokens.Color.textPrimary
        letter.alignment = .center
        signature.alignment = .center
        letter.stringValue = "Thanks for trying Zigzag. I made it to be a calm home for everything you do on the web. I hope it feels that way."
        
        addSubview(card)
        // One skip per step: a burst of clicks never runs past steps you haven't seen.
        skip.onClick = { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastSkip) > 0.6 else { return }
            self.lastSkip = Date()
            Tutorial.skip()
        }
        finish.onClick = { [weak self] _ in self?.end() }
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

    /// Follows along, and plays the recording, only while it can be seen; both pick up where they were when it can again.
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
        updatePlayback()
    }

    /// The recording plays only while the card is up, showing it, where you can see it.
    private func updatePlayback() {
        guard let player else { return }
        let play = !ending && !isAside && !video.isHidden && canBeSeen
        if play, player.rate == 0 { player.play() }
        if !play, player.rate != 0 { player.pause() }
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
        updatePlayback()
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
        let relevant = (bar && Tutorial.current?.id == "newTab") || (peek && Tutorial.current?.id == "peek") || (editing && spaceStep)
        let aside = !relevant && (controller.hasFloatingPanel || peek)
        // During the Peek step the card sits above the peek, so "Close it" is right there; otherwise it stays beneath
        // everything that floats.
        if let overlay = superview {
            let onTop = peek && Tutorial.current?.id == "peek"
            if onTop, overlay.subviews.last !== self { overlay.addSubview(self) }
            if !onTop, overlay.subviews.first !== self { overlay.addSubview(self, positioned: .below, relativeTo: nil) }
        }
        if isAside != aside {
            isAside = aside
            updatePlayback()
        }
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
        /// The recording that shows it, by name in Resources/Tour.
        var clip: String? = nil
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
            return Display(keys: ["↩"], title: "Name it, then pick its color", note: "Return keeps it, Esc cancels", count: "", isDone: false, isFinal: false, target: "editor", clip: "spaces")
        }
        if let done = confirming {
            return Display(keys: [], title: done.done, note: done.doneNote, count: "", isDone: true, isFinal: false, target: "done." + done.id)
        }
        guard let task = Tutorial.current, let index = Tutorial.tasks.firstIndex(where: { $0.id == task.id }) else {
            return Display(keys: [], title: "You’re all set", note: "", count: "", isDone: false, isFinal: true, target: "")
        }
        let count = "Step \(index + 1) of \(Tutorial.tasks.count)"
        // Mid-step hints, where you are, for the moment you'd otherwise stall.
        // Searching a site, a key at a time: its name, Tab, then what to find.
        if task.id == "newTab", controller.commandBar.isVisible {
            if controller.commandBar.isSearchingSite {
                return Display(keys: ["↩"], title: "Type what to find, then Return", note: "For example: lofi music", count: "", isDone: false, isFinal: false, target: "bar")
            }
            if controller.commandBar.isOfferingSiteSearch {
                return Display(keys: ["Tab"], title: "Press Tab", note: "Now you’re searching on YouTube", count: "", isDone: false, isFinal: false, target: "bar")
            }
            return Display(keys: [], title: "Type “youtube”", note: "Just the word", count: "", isDone: false, isFinal: false, target: "bar")
        }
        if task.id == "peek", controller.peek.isVisible {
            return Display(keys: ["Esc"], title: "Close it", note: "Or click outside it", count: "", isDone: false, isFinal: false, target: "peek", clip: "peek")
        }
        if task.id == "peek" { return Display(keys: task.keys, title: task.title, note: task.note, count: count, isDone: false, isFinal: false, target: "article", clip: "peek") }
        // Names the very tab to drag, and a cursor in the window shows the drag on it: a ring alone reads as the tab
        // you're on. That shows it better than a recording, so there's none.
        if task.id == "split" {
            let title = splitCandidate.map { "Drag “\(Self.shortName($0.title))” onto the page" } ?? task.title
            return Display(keys: [], title: title, note: "It opens beside this one",
                           count: count, isDone: false, isFinal: false, target: "split")
        }
        let clips = ["space": "spaces", "switch": "switch"]
        return Display(keys: task.keys, title: task.title, note: task.note, count: count, isDone: false, isFinal: false, target: task.id, clip: clips[task.id])
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
        case "done.split": return controller.root.card
        case "space": return controller.sidebar.newSpaceAnchor
        case "editor": return SpaceEditorPanel.current
        case "switch": return controller.sidebar.firstDotAnchor
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
                if Tutorial.current?.id == "peek", lastStepID != "peek" { openArticle() }
                if Tutorial.current?.id == "split", lastStepID != "split" { openSplitPartner() }
                lastStepID = Tutorial.current?.id
            }
            // A different card (another step, a recording appearing or going): the old one leaves first, the new one
            // arrives in its own place. Only small changes within a card, like the bar's typing hints, move in place.
            let swap = animated && (now.clip != shownClip || now.isDone != shownDone || now.isFinal || (!now.count.isEmpty && now.count != shownCount))
            shownClip = now.clip
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

    private var shownClip: String?
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

    /// The guide's own page, once open, if it can go beside the one you're on.
    private var splitCandidate: Tab? {
        guard let controller, let current = controller.tabManager.selectedTab else { return nil }
        let manager = controller.tabManager
        return manager.tabs(in: manager.currentSpaceID).first {
            $0 !== current && $0.url?.host()?.hasSuffix("wikipedia.org") == true && $0.url?.path.hasPrefix("/wiki/Split_screen") == true
                && manager.split(for: $0) == nil && manager.canSplit(current, with: $0)
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

    /// Split View needs a second ordinary tab: the guide opens its own, behind this one.
    private func openSplitPartner() {
        guard let controller, splitCandidate == nil else { return }
        controller.open(Self.splitPartnerURL, disposition: .backgroundTab, allowSwitch: false)
    }

    /// Starts the step's recording on a loop (muted), or stops it when the step has none.
    private func playClip(_ name: String?) {
        guard name != clipName else { return }
        clipName = name
        player?.pause()
        looper = nil
        player = nil
        video.isHidden = name == nil
        guard let name, let url = Bundle.main.url(forResource: "tour-\(name)", withExtension: "mp4") else { video.isHidden = true; return }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        videoLayer.player = queue
        player = queue
        updatePlayback()
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
        playClip(d.clip)
        title.stringValue = d.title
        note.stringValue = d.note
        step.stringValue = d.count
        check.isHidden = !d.isDone
        // Naming a new space is the middle of a step: nothing to skip there.
        // Mid-step hints (no count) are part of a step: nothing to skip there, and the pill stays small.
        skip.isHidden = d.isDone || d.isFinal || d.count.isEmpty
        step.isHidden = d.isDone || d.isFinal || d.count.isEmpty
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
        if !step.isHidden { width += step.textWidth + Tokens.Space.x3 }
        let row = d.note.isEmpty ? Tokens.Tour.rowHeight : Tokens.Tour.rowWithNoteHeight
        // One width for every step, so the card never jumps; the recording on top when there is one.
        let w = max(ceil(width), Self.cardWidth)
        return NSSize(width: w, height: row + (showsVideo(d) ? Self.videoHeight(for: w) : 0))
    }

    private func layoutTour(_ d: Display, animated: Bool) {
        let target = view(for: d.target)
        // Out first, so the ring goes where the sidebar is, not where it hides.
        pointsIntoSidebar = !d.isFinal && controller.map { target?.isDescendant(of: $0.sidebar) == true } ?? false
        if pointsIntoSidebar { controller?.root.reveal(true) }
        let hole: NSRect = target.flatMap { $0.window != nil ? $0.convert($0.bounds, to: self).insetBy(dx: -Tokens.Tour.ringOutset, dy: -Tokens.Tour.ringOutset) : nil } ?? .zero
        // Dragging a tab onto the page uses the sidebar and the page at once: nothing dimmed, nothing ringed.
        // The tab to drag keeps its ring, so you know which one.
        // Nothing is dimmed: the window stays as it is, and a soft ring marks only small things to click.
        let cut = CGMutablePath()
        let page = controller?.root.cardFrame ?? bounds
        let ringed = hole != .zero && !d.isDone && !d.isFinal && hole.width < page.width * 0.6 && !["bar", "editor", "peek"].contains(d.target)
        // Something as small as a space's dot gets a round ring; anything bigger, a rounded rectangle.
        let radius = max(hole.width, hole.height) < Tokens.Tour.ringRoundBelow ? min(hole.width, hole.height) / 2 : Tokens.Radius.tile
        let ringPath: CGPath = ringed ? CGPath(roundedRect: hole, cornerWidth: radius, cornerHeight: radius, transform: nil) : CGMutablePath()
        // A spotlight: everything but the thing to click dims a little, so the eye goes straight to it. Only the dim
        // is drawn; clicks pass through it as ever.
        _ = cut
        // Pulses only when it lands on something new, never on every layout.
        if ringed, d.target != pulsedTarget { pulsedTarget = d.target; pulse(true) } else if !ringed { pulsedTarget = nil; pulse(false) }
        // Split View is a drag, which a ring can't show: a cursor picks up the tab and carries it onto the page.
        showDrag(ringed && d.target == "split" ? target : nil, from: hole, to: page)
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

        let size = pillSize(d)
        var frame: NSRect
        if !d.isFinal {
            // Right under the address bar while it's open (where your eyes are), otherwise a bar at the bottom middle of
            // the page, never over what you need to click.
            if d.target == "bar", hole != .zero {
                frame = NSRect(x: hole.midX - size.width / 2, y: hole.maxY + Tokens.Space.x3, width: size.width, height: size.height)
            } else {
                frame = NSRect(x: windowCentered(size.width, in: page), y: page.maxY - size.height - Tokens.Space.x8, width: size.width, height: size.height)
            }
        } else if d.clip != nil {
            // With a recording: tucked in the page's bottom right, clear of what's lit.
            frame = NSRect(x: page.maxX - size.width - Tokens.Space.x5, y: page.maxY - size.height - Tokens.Space.x5, width: size.width, height: size.height)
            // Below the bar or editor when it reaches down that far, and to its right when it doesn't fit under.
            if hole != .zero, frame.intersects(hole) {
                if page.maxY - hole.maxY - Tokens.Space.x3 >= size.height {
                    frame.origin.y = hole.maxY + Tokens.Space.x3
                } else if page.maxX - hole.maxX - Tokens.Space.x3 >= size.width {
                    frame.origin.x = hole.maxX + Tokens.Space.x3
                }
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
            // Beside the lit place, to its right, level with it.
            frame = NSRect(x: hole.maxX + Tokens.Space.x4, y: hole.midY - size.height / 2, width: size.width, height: size.height)
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

    static let cardWidth = Tokens.Tour.cardWidth
    /// When Skip was last pressed.
    private var lastSkip = Date.distantPast
    /// The step whose ring last pulsed.
    private var pulsedTarget: String?

    /// The recording shows unless a peek covers the page (the card would sit on it).
    /// A recording only where words aren't enough (a Shift-click, a drag, the + and a swipe). Keys say it themselves,
    /// and while the bar, a peek or the editor is open, what you need is already on screen.
    private func showsVideo(_ d: Display) -> Bool {
        guard let clip = d.clip, !d.isDone, !d.isFinal else { return false }
        return ["peek", "split", "spaces", "switch"].contains(clip) && !["bar", "peek", "editor"].contains(d.target)
    }

    /// When a ring lands somewhere new it pulses three times, so the eye goes to it, then holds still: nothing on
    /// screen loops forever.
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
        beat.repeatCount = 3
        beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(beat, forKey: "pulse")
    }

    /// The drag a step asks for, shown in the window itself: a cursor goes to the tab, picks it up and carries a
    /// copy of it onto the page, three times over, then rests, like the ring's pulse.
    private let ghost = CALayer()
    private var ghostRoute: (from: NSRect, to: NSRect)?

    private func showDrag(_ row: NSView?, from hole: NSRect, to page: NSRect) {
        guard let row, !Tokens.Motion.reduceMotion else {
            ghostRoute = nil
            ghost.removeAllAnimations()
            ghost.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }
        if let route = ghostRoute, route.from == hole, route.to == page { return }
        ghostRoute = (hole, page)
        ghost.removeAllAnimations()
        ghost.sublayers?.forEach { $0.removeFromSuperlayer() }

        // The tab as it looks lifted to drag: its own picture on the card, with the card's shadow.
        let copy = CALayer()
        copy.frame = CGRect(origin: .zero, size: row.bounds.size)
        if let image = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
            row.cacheDisplay(in: row.bounds, to: image)
            copy.contents = image.cgImage
        }
        copy.contentsGravity = .resize
        copy.backgroundColor = cgColor(Tokens.Chrome.card)
        copy.cornerRadius = Tokens.Sidebar.rowRadius
        copy.cornerCurve = .continuous
        copy.borderWidth = Tokens.Metric.hairline
        copy.borderColor = cgColor(Tokens.Chrome.cardEdge)
        copy.shadowOpacity = 0.3
        copy.shadowRadius = 10
        copy.shadowOffset = CGSize(width: 0, height: 4)
        let cursorImage = NSCursor.arrow.image
        let cursor = CALayer()
        cursor.contents = cursorImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cursor.contentsScale = window?.backingScaleFactor ?? 2
        // The pointer's tip at the ghost's origin, where it holds the tab: on its title, a little in.
        let tip = NSCursor.arrow.hotSpot
        let grab = CGPoint(x: Tokens.Sidebar.favicon * 2.5, y: row.bounds.height / 2)
        cursor.frame = CGRect(x: grab.x - tip.x, y: grab.y - tip.y, width: cursorImage.size.width, height: cursorImage.size.height)
        ghost.addSublayer(copy)
        ghost.addSublayer(cursor)
        ghost.bounds = CGRect(origin: .zero, size: row.bounds.size)
        ghost.anchorPoint = .zero

        let start = CGPoint(x: hole.minX + Tokens.Tour.ringOutset, y: hole.minY + Tokens.Tour.ringOutset)
        // Into the page's upper part, clear of this card at the bottom.
        let end = CGPoint(x: page.midX, y: page.minY + page.height * 0.3)
        let cycle: CFTimeInterval = 3.2
        // Arrive and press, carry it across, let go, fade.
        let times: [NSNumber] = [0, 0.12, 0.22, 0.62, 0.76, 0.86, 1]
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = [start, start, start, end, end, end, end].map { NSValue(point: $0) }
        move.keyTimes = times
        move.timingFunctions = (0..<6).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 1, 1, 0, 0]
        fade.keyTimes = times
        let lift = CAKeyframeAnimation(keyPath: "opacity")
        lift.values = [0, 0, 0.92, 0.92, 0.92, 0, 0]
        lift.keyTimes = times
        let press = CAKeyframeAnimation(keyPath: "transform.scale")
        press.values = [1, 1, 0.85, 0.85, 1, 1, 1]
        press.keyTimes = times
        for (layer, animation) in [(ghost, move), (ghost, fade), (copy, lift), (cursor, press)] as [(CALayer, CAKeyframeAnimation)] {
            animation.duration = cycle
            animation.repeatCount = 3
            animation.beginTime = CACurrentMediaTime() + 0.6
            animation.fillMode = .both
            layer.add(animation, forKey: animation.keyPath)
        }
        Tokens.Motion.withoutAnimation {
            ghost.position = end
            ghost.opacity = 0
            copy.opacity = 0
        }
    }

    /// Like ⌘T's bar: centered on the whole window, not just the page beside the sidebar, but kept inside the page.
    private func windowCentered(_ width: CGFloat, in page: NSRect) -> CGFloat {
        let margin = Tokens.Space.x8
        return min(max(page.minX + margin, floor(bounds.midX - width / 2)), page.maxX - width - margin)
    }

    /// The recordings are a 1120 by 720 window, inset 8 from the card's edges.
    private static func videoHeight(for width: CGFloat) -> CGFloat {
        let inset = Tokens.Tour.videoInset
        return round((width - inset * 2) * 720 / 1120) + inset
    }

    private func layoutPill(_ d: Display, in size: NSSize) {
        let width = size.width
        let top = showsVideo(d) ? Self.videoHeight(for: width) : 0
        video.isHidden = !showsVideo(d)
        updatePlayback()
        if showsVideo(d) {
            let inset = Tokens.Tour.videoInset
            let videoFrame = NSRect(x: inset, y: inset, width: width - inset * 2, height: top - inset)
            if video.frame != videoFrame { video.frame = videoFrame }
            if videoLayer.frame != video.bounds { Tokens.Motion.withoutAnimation { videoLayer.frame = video.bounds } }
        }
        let height = size.height - top
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
        if note.isHidden {
            title.frame = NSRect(x: x, y: top + (height - title.lineHeight) / 2, width: title.textWidth + 4, height: title.lineHeight)
        } else {
            // Title, and the why beneath it, as one block in the middle.
            let block = title.lineHeight + 2 + note.lineHeight
            title.frame = NSRect(x: x, y: top + (height - block) / 2, width: title.textWidth + 4, height: title.lineHeight)
            note.frame = NSRect(x: x, y: title.frame.maxY + 2, width: note.textWidth + 4, height: note.lineHeight)
        }
        let sw = skip.fittingWidth
        skip.frame = NSRect(x: width - Tokens.Space.x2 - sw, y: top + (height - Tokens.Space.x8) / 2, width: sw, height: Tokens.Space.x8)
        let cw = step.textWidth + 2
        step.frame = NSRect(x: skip.frame.minX - Tokens.Space.x1 - cw, y: top + (height - step.lineHeight) / 2, width: cw, height: step.lineHeight)
    }
}
