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
    private let step = Label("", font: Tokens.Font.small(.medium), color: Tokens.Color.textTertiary)
    private let check = NSImageView()
    private let title = Label("", font: Tokens.Font.large(.semibold), color: Tokens.Color.textPrimary)
    private let note = Label("", font: Tokens.Font.body(), color: Tokens.Color.textSecondary)
    private var caps: [(ColorView, Label)] = []
    private let skip = TextButton(title: "Skip", font: Tokens.Font.small(.medium))
    private let finish = PrimaryButton(title: "Start Browsing")
    // The last card: a note from the person who made Zigzag.
    private let wordmark = WordmarkView()
    private let header = BrandSurface()
    private let letter = NSTextField(wrappingLabelWithString: "")
    private let signature = Label("— Zigao, who makes Zigzag", font: Tokens.Font.body(.medium), color: Tokens.Color.textSecondary)
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
    private var sawPeek = false
    /// What the pill shows now, so it only redraws when that changes.
    private var shown = ""
    /// The step the pill was last showing, so its note follows it.
    private var lastStepID: String?

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
        ring.lineWidth = 2.5
        layer?.addSublayer(ring)
        applyColors()
        check.image = Tokens.Symbol.image("checkmark.circle.fill", size: 20)
        skip.textColor = Tokens.Color.textTertiary
        card.radius = Tokens.Radius.large
        header.cornerRadius = 0
        header.layer?.borderWidth = 0
        header.showsWatermark = false
        [header, step, check, title, note, skip, finish, wordmark, letter, signature, video].forEach { card.addSubview($0) }
        video.wantsLayer = true
        video.layer?.cornerRadius = 10
        video.layer?.cornerCurve = .continuous
        video.layer?.masksToBounds = true
        videoLayer.videoGravity = .resizeAspectFill
        video.layer?.addSublayer(videoLayer)
        wordmark.color = Brand.ribbon
        letter.isSelectable = false
        letter.font = Tokens.Font.body()
        letter.textColor = Tokens.Color.textPrimary
        letter.stringValue = "Thanks for trying Zigzag. I made it to be a calm home for everything you do on the web. I hope it feels that way."
        
        addSubview(card)
        skip.onClick = { _ in Tutorial.skip() }
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
        dim.fillColor = cgColor(Tokens.Color.scrim)
        ring.strokeColor = cgColor(accent)
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
        // Peek counts once you've closed it again: that's the whole move.
        if confirming == nil, Tutorial.current?.id == "peek" {
            if controller.peek.isVisible { sawPeek = true } else if sawPeek { sawPeek = false; Tutorial.complete("peek") }
        }
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
            return Display(keys: ["↩"], title: "Name it, then pick its color", note: "Return keeps it, esc cancels", count: "", isDone: false, isFinal: false, target: "editor", clip: "spaces")
        }
        if let done = confirming {
            return Display(keys: [], title: done.done, note: done.doneNote, count: "", isDone: true, isFinal: false, target: "done." + done.id)
        }
        guard let task = Tutorial.current, let index = Tutorial.tasks.firstIndex(where: { $0.id == task.id }) else {
            return Display(keys: [], title: "You’re all set", note: "", count: "", isDone: false, isFinal: true, target: "")
        }
        let count = "\(index + 1)/\(Tutorial.tasks.count)"
        // Mid-step hints, where you are, for the moment you'd otherwise stall.
        // Searching a site, a key at a time: its name, Tab, then what to find.
        if task.id == "newTab", controller.commandBar.isVisible {
            if controller.commandBar.isSearchingSite {
                return Display(keys: ["lofi music", "↩"], title: "Now type what to find", note: "Anything works. Then press Return", count: "", isDone: false, isFinal: false, target: "bar", clip: "search")
            }
            if controller.commandBar.isOfferingSiteSearch {
                return Display(keys: ["Tab"], title: "Press Tab", note: "To search right on YouTube", count: "", isDone: false, isFinal: false, target: "bar", clip: "search")
            }
            return Display(keys: ["youtube"], title: "Type this", note: "Just the word, then you’ll press Tab", count: "", isDone: false, isFinal: false, target: "bar", clip: "search")
        }
        if task.id == "peek", controller.peek.isVisible {
            return Display(keys: ["esc"], title: "Close it", note: "Or click outside it", count: "", isDone: false, isFinal: false, target: "peek", clip: "peek")
        }
        if task.id == "peek" { return Display(keys: task.keys, title: task.title, note: task.note, count: count, isDone: false, isFinal: false, target: "article", clip: "peek") }
        // Names the very tab to drag, lit up in the sidebar, so there's nothing to work out.
        if task.id == "split" {
            return Display(keys: ["Drag"], title: "Drag the lit tab onto the page", note: "Like in the video",
                           count: count, isDone: false, isFinal: false, target: "split", clip: "split")
        }
        let clips = ["newTab": "search", "pin": "pin", "space": "spaces", "switch": "switch"]
        return Display(keys: task.keys, title: task.title, note: task.note, count: count, isDone: false, isFinal: false, target: task.id, clip: clips[task.id])
    }

    /// Where to point.
    private func view(for target: String) -> NSView? {
        guard let controller else { return nil }
        let row = controller.tabManager.selectedTab.flatMap { controller.sidebar.list.rowView(for: $0) }
        switch target {
        case "newTab": return controller.sidebar.address
        case "bar": return controller.commandBar.panelView
        case "pin", "done.newTab", "done.pin": return row ?? controller.sidebar.list
        case "peek": return controller.peek.panelView
        case "done.peek", "article": return controller.root.card
        case "split": return splitCandidate.flatMap { controller.sidebar.list.rowView(for: $0) }
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

    /// A tab that can go beside this page: an ordinary one (pinned pages can't split), not the one you're on.
    private var splitCandidate: Tab? {
        guard let controller, let current = controller.tabManager.selectedTab else { return nil }
        return controller.tabManager.tabs(in: controller.tabManager.currentSpaceID).first { $0 !== current && controller.tabManager.canSplit(current, with: $0) }
    }

    /// Split View needs a second ordinary tab; the earlier steps may have pinned the only one.
    private func openSplitPartner() {
        guard let controller, splitCandidate == nil, let url = URL(string: "https://en.wikipedia.org/wiki/Split_screen_(computer_graphics)") else { return }
        controller.open(url, disposition: .backgroundTab, allowSwitch: false)
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
            let cap = ColorView(color: Tokens.Color.fieldFill)
            cap.wantsLayer = true
            cap.layer?.cornerRadius = 6
            cap.layer?.cornerCurve = .continuous
            let label = Label(key, font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
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
        [wordmark, letter, signature, header].forEach { $0.isHidden = !d.isFinal }
        title.font = d.isFinal ? Brand.displayFont(Tokens.TypeSize.title) : Tokens.Font.large(.semibold)
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
            let inner: CGFloat = 380 - 64
            let lh = ceil(letter.sizeThatFits(NSSize(width: inner, height: 400)).height)
            return NSSize(width: 380, height: 120 + 26 + 34 + 10 + lh + 12 + signature.lineHeight + 24 + Tokens.Space.x10 + 28)
        }
        let keys = caps.map { max(34, $0.1.inkWidth + Tokens.Space.x4) }.reduce(0, +) + CGFloat(max(caps.count - 1, 0)) * 4
        let text = max(title.textWidth, d.note.isEmpty ? 0 : note.textWidth)
        var width = Tokens.Space.x4 + (d.isDone ? 20 : keys) + Tokens.Space.x3 + text + Tokens.Space.x5
        if !skip.isHidden { width += skip.fittingWidth - Tokens.Space.x2 }
        if !step.isHidden { width += step.textWidth + Tokens.Space.x3 }
        let row: CGFloat = d.note.isEmpty ? 64 : 76
        // One width for every step, so the card never jumps; the recording on top when there is one.
        let w = max(ceil(width), Self.cardWidth)
        return NSSize(width: w, height: row + (showsVideo(d) ? Self.videoHeight(for: w) : 0))
    }

    private func layoutTour(_ d: Display, animated: Bool) {
        let target = view(for: d.target)
        let hole: NSRect = target.flatMap { $0.window != nil ? $0.convert($0.bounds, to: self).insetBy(dx: -5, dy: -5) : nil } ?? .zero
        // Dragging a tab onto the page uses the sidebar and the page at once: nothing dimmed, nothing ringed.
        // The tab to drag keeps its ring, so you know which one.
        // Nothing is dimmed: the window stays as it is, and a soft ring marks only small things to click.
        let cut = CGMutablePath()
        let page = controller?.root.cardFrame ?? bounds
        let ringed = hole != .zero && !d.isDone && !d.isFinal && hole.width < page.width * 0.6 && !["bar", "editor", "peek"].contains(d.target)
        // Something as small as a space's dot gets a round ring; anything bigger, a rounded rectangle.
        let radius = max(hole.width, hole.height) < 44 ? min(hole.width, hole.height) / 2 : 12
        let ringPath: CGPath = ringed ? CGPath(roundedRect: hole, cornerWidth: radius, cornerHeight: radius, transform: nil) : CGMutablePath()
        pulse(ringed)
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
            // Always the same place: the page's bottom right corner, growing upward. It never moves around.
            frame = NSRect(x: page.maxX - size.width - Tokens.Space.x5, y: page.maxY - size.height - Tokens.Space.x5, width: size.width, height: size.height)
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
            frame = NSRect(x: page.midX - size.width / 2, y: page.midY - size.height / 2, width: size.width, height: size.height)
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
            Tokens.Motion.animate(curve, evenFromKeyboard: true) { self.card.animator().frame = frame }
        } else if card.frame != frame {
            card.frame = frame
        }
        layoutPill(d, in: frame.size)
    }

    static let cardWidth: CGFloat = 400

    /// The recording shows unless a peek covers the page (the card would sit on it).
    private func showsVideo(_ d: Display) -> Bool { d.clip != nil && d.target != "peek" }

    /// The ring holds still: its color is enough to find it, and nothing on screen loops forever.
    private func pulse(_ on: Bool) {
        if ring.animation(forKey: "pulse") != nil { ring.removeAnimation(forKey: "pulse") }
        if ring.opacity != 1 { ring.opacity = 1 }
    }

    /// The recordings are a 1120 by 720 window, inset 8 from the card's edges.
    private static func videoHeight(for width: CGFloat) -> CGFloat { round((width - 16) * 720 / 1120) + 8 }

    private func layoutPill(_ d: Display, in size: NSSize) {
        let width = size.width
        let top = showsVideo(d) ? Self.videoHeight(for: width) : 0
        video.isHidden = !showsVideo(d)
        updatePlayback()
        if showsVideo(d) {
            let videoFrame = NSRect(x: 8, y: 8, width: width - 16, height: top - 8)
            if video.frame != videoFrame { video.frame = videoFrame }
            if videoLayer.frame != video.bounds { Tokens.Motion.withoutAnimation { videoLayer.frame = video.bounds } }
        }
        let height = size.height - top
        if d.isFinal {
            let pad: CGFloat = 32, inner = width - pad * 2
            // The brand across the top, the note beneath it.
            header.frame = NSRect(x: 0, y: 0, width: width, height: 120)
            let wh: CGFloat = 34
            wordmark.frame = NSRect(x: (width - wh * WordmarkView.aspect) / 2, y: (120 - wh) / 2, width: wh * WordmarkView.aspect, height: wh)
            title.frame = NSRect(x: pad, y: header.frame.maxY + 26, width: inner, height: 34)
            let lh = ceil(letter.sizeThatFits(NSSize(width: inner, height: 400)).height)
            letter.frame = NSRect(x: pad, y: title.frame.maxY + 10, width: inner, height: lh)
            signature.frame = NSRect(x: pad, y: letter.frame.maxY + 12, width: inner, height: signature.lineHeight)
            finish.frame = NSRect(x: pad, y: signature.frame.maxY + 24, width: inner, height: Tokens.Space.x10)
            return
        }
        var x = Tokens.Space.x4
        if d.isDone {
            check.frame = NSRect(x: x, y: top + (height - 20) / 2, width: 20, height: 20)
            x = check.frame.maxX + Tokens.Space.x3
        }
        for (cap, label) in caps {
            let w = max(34, label.inkWidth + Tokens.Space.x4)
            cap.frame = NSRect(x: x, y: top + (height - 34) / 2, width: w, height: 34)
            label.frame = NSRect(x: 0, y: (34 - label.lineHeight) / 2, width: w, height: label.lineHeight)
            x += w + 4
        }
        if !caps.isEmpty { x += Tokens.Space.x3 - 4 }
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
