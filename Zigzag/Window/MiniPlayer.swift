import AppKit
import WebKit

/// Arc's mini player: leave a tab while its video plays and the video keeps playing in a small card over the window,
/// until you come back to the tab or close the card. It is the tab's own live page, moved into the card and scaled so
/// only its video shows: nothing is copied or reloaded, the page keeps its layout (its size never changes, so it never
/// reflows), and sound simply carries on. It drags anywhere in the window, over the sidebar too; minimized, it goes
/// and the video plays on in its tab, out of sight. One per window, in private windows too, kept across spaces.
/// Settings › Tabs › Keep videos playing when you switch tabs turns it off.
final class MiniPlayer {
    private weak var controller: BrowserWindowController?
    private var model = MiniPlayerModel()
    private(set) weak var tab: Tab?
    private weak var webView: BrowserWebView?
    private(set) var card: MiniPlayerView?
    /// The frame the video is in, and which of its videos it is.
    private var frameID: String?
    private var videoIndex = 0
    private var video: PageVideo?
    /// Where that frame's viewport starts in the page, in CSS pixels.
    private var frameOrigin: CGPoint = .zero
    private var tokens: [SignalToken] = []
    /// The video went missing: the player waits a moment for it (a page moving on to the next video), then goes.
    private var lostWait: DispatchWorkItem?

    init(controller: BrowserWindowController) {
        self.controller = controller
    }

    /// Where the card sits, where you last let it go: from the window's nearest corner. None until it's first moved:
    /// it starts at the bottom right of the page.
    static var anchor: MiniPlayerLayout.Anchor? {
        get { UserDefaults.standard.string(forKey: "MiniPlayerPlace").flatMap(MiniPlayerLayout.Anchor.init(stored:)) }
        set { UserDefaults.standard.set(newValue?.stored, forKey: "MiniPlayerPlace") }
    }

    var isShowing: Bool { model.tab != nil }

    // MARK: Moving between tabs

    /// The tabs on screen changed: `before` were in the page cards, `after` are going in now (two in a split). Called
    /// before the cards change, while a tab you're leaving is still in its card.
    func switched(from before: [Tab], to after: [Tab]) {
        let shown = Set(after.map(\.id))
        let playing = PictureInPicture.followsTabs ? before.first { !shown.contains($0.id) && $0.id != model.tab && follows($0) } : nil
        apply(model.switched(shown: shown, playing: playing?.id))
    }

    /// Whether this tab's video would follow you out of it: its page is on screen and plays a video, and isn't
    /// floating or filling the screen with it itself.
    private func follows(_ tab: Tab) -> Bool {
        guard !tab.isPeek, !tab.isClosed, let webView = tab.webView, webView.window != nil, webView.superview?.superview is PageCardView,
              !PageVideos.shared.isPresentingItself(webView) else { return false }
        return PageVideos.shared.playing(in: webView) != nil
    }

    /// Tabs came or went: one closed, or moved to another window, takes the player with it.
    func tabsChanged() {
        guard let id = model.tab else { return }
        if let tab, !tab.isClosed, controller?.tabManager.tab(with: id) === tab, let webView, tab.webView === webView,
           let card, webView.isDescendant(of: card) { return }
        apply(model.lost(id))
    }

    /// Its close button: the video stops, and the player goes.
    func close() {
        apply(model.close())
    }

    /// Back to the tab (its arrow, its site's name, a double-click on the card), in its own space if it's in another:
    /// its page, video still playing, goes back into the page card.
    func returnToTab() {
        guard let tab, let controller, !tab.isClosed, controller.tabManager.tab(with: tab.id) === tab else { return }
        controller.tabManager.select(tab)
    }

    /// Its minimize button: the card goes and the video plays on in its tab, out of sight; the sidebar's now-playing
    /// row goes back to it.
    func minimize() {
        apply(model.minimize())
    }

    private func apply(_ steps: [MiniPlayerModel.Step]) {
        for step in steps {
            switch step {
            case .show(let id):
                if let tab = controller?.tabManager.tab(with: id) { start(tab) }
            case .pause:
                pause()
            case .end:
                finish(closing: steps.contains { if case .pause = $0 { true } else { false } })
            case .hide:
                finish(closing: true)
            }
        }
    }

    // MARK: Showing and going

    private func start(_ tab: Tab) {
        guard let controller, let webView = tab.webView, let (frame, video) = PageVideos.shared.playing(in: webView) else {
            _ = model.lost(tab.id)
            return
        }
        let root = controller.root
        self.tab = tab
        self.webView = webView
        frameID = frame.id
        videoIndex = video.index
        self.video = video
        frameOrigin = .zero
        // Where the video was on screen, to grow the card out of; a frame's place in its page isn't known yet.
        let source: NSRect? = frame.isMain ? webView.convert(pictureRect(in: webView), to: root) : nil

        let card = MiniPlayerView()
        card.siteName = Self.siteName(tab.url)
        card.onBack = { [weak self] in self?.returnToTab() }
        card.onClose = { [weak self] in self?.close() }
        card.onMinimize = { [weak self] in self?.minimize() }
        card.onToggle = { [weak self] in self?.command("toggle") }
        card.onSeek = { [weak self] by in self?.command("seek", [("by", by)]) }
        card.onSeekTo = { [weak self] fraction in self?.command("seekTo", [("f", fraction)]) }
        card.onMoved = { [weak self] in self?.dropped() }
        self.card = card
        root.showMiniPlayer(card)
        card.adopt(webView)
        tab.isInMiniPlayer = true
        place()
        card.update(video)
        card.appear(from: source)

        tokens = [
            PageVideos.shared.reported.observe { [weak self, weak webView] page in
                guard let self, page === webView else { return }
                self.pageReported()
            },
            tab.changed.observe { [weak self, weak tab] change in
                guard let self, let tab else { return }
                if change == .url { self.card?.siteName = Self.siteName(tab.url) }
                guard change == .webView || change == .url else { return }
                if tab.webView !== self.webView { self.apply(self.model.lost(tab.id)) }
            },
        ]
        // Into view if you'd scrolled past it, then reporting four times a second while it's here.
        Task { [weak self] in
            guard let self, self.webView === webView else { return }
            if !frame.isMain, let origin = await PageVideos.shared.origin(of: frame, in: webView) { self.frameOrigin = origin; self.place() }
            _ = await PageVideos.shared.run("reveal", [("i", video.index)], in: frame, of: webView)
            _ = await PageVideos.shared.run("watch", [("on", true)], in: frame, of: webView)
        }
    }

    /// Lets the page go. Coming back to its tab, it's put back in the page card next, and scrolled back to where you
    /// left it; closed, the card fades as it goes.
    private func finish(closing: Bool) {
        lostWait?.cancel()
        lostWait = nil
        tokens = []
        let webView = webView, frame = currentFrame
        if let webView, let frame {
            Task {
                _ = await PageVideos.shared.run("watch", [("on", false)], in: frame, of: webView)
                _ = await PageVideos.shared.run("restore", in: frame, of: webView)
            }
        }
        tab?.isInMiniPlayer = false
        if let card {
            if closing { card.disappear() } else { card.release(); card.removeFromSuperview() }
        }
        card = nil
        tab = nil
        self.webView = nil
        frameID = nil
        video = nil
    }

    private func pause() {
        guard let webView else { return }
        if let frame = currentFrame {
            let index = videoIndex
            Task { _ = await PageVideos.shared.run("pause", [("i", index)], in: frame, of: webView) }
        } else {
            webView.pauseAllMediaPlayback(completionHandler: nil)
        }
    }

    private func command(_ name: String, _ arguments: [(String, Any)] = []) {
        guard let webView, let frame = currentFrame else { return }
        let all = [("i", videoIndex as Any)] + arguments
        Task {
            _ = await PageVideos.shared.run(name, all, in: frame, of: webView)
            _ = await PageVideos.shared.run("report", in: frame, of: webView)
        }
    }

    private var currentFrame: PageVideos.Frame? {
        guard let webView, let frameID else { return nil }
        return PageVideos.shared.frames(in: webView).first { $0.id == frameID }
    }

    // MARK: Following the page

    /// The page said something about its videos: the card follows the video's place, shape and time. No video for a
    /// couple of seconds (the page went somewhere else), or the page floats it itself, and the player goes.
    private func pageReported() {
        guard let webView, let tab else { return }
        if PageVideos.shared.isPresentingItself(webView) { apply(model.lost(tab.id)); return }
        let frame = currentFrame
        let found = frame.flatMap { frame -> PageVideo? in
            if let same = frame.videos.first(where: { $0.index == videoIndex }), same.natural.width > 0 { return same }
            return MiniPlayerLayout.choose(frame.videos, viewport: frame.viewport)
        } ?? PageVideos.shared.playing(in: webView).map { found in
            frameID = found.frame.id
            frameOrigin = .zero
            return found.video
        }
        guard let found else {
            if lostWait == nil {
                let wait = DispatchWorkItem { [weak self] in
                    guard let self, let id = self.model.tab else { return }
                    self.apply(self.model.lost(id))
                }
                lostWait = wait
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: wait)
            }
            return
        }
        lostWait?.cancel()
        lostWait = nil
        videoIndex = found.index
        video = found
        card?.update(found)
        place()
        // A frame moves with its page: its place is asked again as it reports.
        if let frame = currentFrame, !frame.isMain {
            Task { [weak self] in
                guard let origin = await PageVideos.shared.origin(of: frame, in: webView), let self, self.webView === webView else { return }
                if origin != self.frameOrigin { self.frameOrigin = origin; self.place() }
            }
        }
    }

    /// The video's picture in the page's own points.
    private func pictureRect(in webView: WKWebView) -> NSRect {
        guard let video else { return .zero }
        let css = MiniPlayerLayout.pictureRect(of: video).offsetBy(dx: frameOrigin.x, dy: frameOrigin.y)
        let main = PageVideos.shared.frames(in: webView).first(where: \.isMain)?.viewport.width ?? 0
        let scale = main > 0 ? webView.bounds.width / main : webView.pageZoom * webView.magnification
        let rect = NSRect(x: css.minX * scale, y: css.minY * scale, width: css.width * scale, height: css.height * scale)
        // Only what the page has on screen can show.
        let seen = rect.intersection(webView.bounds)
        return seen.isNull || seen.width < 1 || seen.height < 1 ? rect : seen
    }

    /// Where the card may go: anywhere in the window, over the sidebar too, but under the bar above the page.
    private var movableArea: NSRect {
        guard let root = controller?.root else { return .zero }
        return MiniPlayerLayout.movableArea(in: root.bounds, below: root.showsTopBar ? root.topBarFrame.maxY : nil)
    }

    /// Sizes the card for the video and the window, where you left it (or where it's being dragged).
    func place() {
        guard let controller, let card, let webView else { return }
        let area = movableArea
        let picture = pictureRect(in: webView)
        let aspect = picture.height > 0 ? picture.width / picture.height : 16 / 9
        let size = MiniPlayerLayout.cardSize(aspect: aspect, in: controller.root.cardFrame.size)
        // Until it's first moved, at the bottom right of the page.
        let target = Self.anchor.map { MiniPlayerLayout.frame(for: $0, size: size, in: area) }
            ?? MiniPlayerLayout.clamp(MiniPlayerLayout.frame(at: .bottomRight, size: size, in: controller.root.cardFrame), in: area)
        card.dragArea = area
        if !card.isDragging, card.frame != target { card.frame = target }
        card.show(MiniPlayerLayout.placement(showing: picture, in: target.size))
    }

    /// Let go after a drag: it stays where it was let go, settling on the edge when it's let go near one. Its place is
    /// kept from the window's nearest corner, for the next video too.
    private func dropped() {
        guard let card else { return }
        let area = movableArea
        let target = MiniPlayerLayout.dropped(card.frame, in: area)
        Self.anchor = MiniPlayerLayout.anchor(of: target, in: area)
        guard target != card.frame else { return }
        Tokens.Motion.animate(Tokens.Motion.snappy, moves: true) { card.animator().frame = target }
    }

    static func siteName(_ url: URL?) -> String {
        guard let host = url?.host(), !host.isEmpty else { return url?.absoluteString ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    #if DEBUG
    /// The card's state for scripted checks.
    var debugState: [String: Any] {
        ["showing": isShowing, "tab": tab?.displayTitle ?? "", "frame": card.map { NSStringFromRect($0.frame) } ?? "",
         "anchor": Self.anchor?.stored ?? "", "area": NSStringFromRect(movableArea), "playing": video?.isPlaying ?? false, "time": video?.time ?? 0,
         "selected": controller?.tabManager.selectedTab?.displayTitle ?? "", "space": controller?.tabManager.currentSpaceID.uuidString ?? "",
         "follows": controller?.tabManager.allTabs.filter(follows).map(\.displayTitle) ?? [],
         "reporting": controller?.tabManager.allTabs.filter { $0.webView.map { !PageVideos.shared.frames(in: $0).isEmpty } ?? false }.map(\.displayTitle) ?? [],
         "hovered": card?.showsControls ?? false, "webViewInCard": webView.map { $0.isDescendant(of: card ?? NSView()) } ?? false]
    }
    #endif
}

// MARK: - The card

/// The card the video plays in: rounded, on the floating layer's one shadow, the page inside scaled so its video
/// fills it. Pointing at it dims the picture and brings its controls; it drags anywhere in the window.
final class MiniPlayerView: NSView {
    /// Rounds the page inside: an AppKit view only clips what's in it (the page's layers included) with
    /// `clipsToBounds` on, whatever its layer says.
    private let clip = NSView()
    /// Holds the page at its own size; its bounds are the part of the page that shows, so the page is scaled into the
    /// card without being laid out again.
    private let host = MiniPlayerPage()
    private let edge = MiniPlayerShape()
    private let controls = MiniPlayerControls()
    /// Under the controls: an even dim over the picture, deeper at the top and bottom where the words and the time
    /// sit, so white reads on any video, words in it included.
    private let scrim = MiniPlayerScrim()
    private let backButton = MiniPlayerSiteButton()
    private let minimizeButton = MiniPlayerView.overlayButton("minus", side: MiniPlayerView.topSide, glyph: 13,
        tip: String(localized: "Minimize", comment: "Tooltip of the mini player's button that hides it; the video keeps playing in its tab."))
    private let closeButton = MiniPlayerView.overlayButton("xmark", side: MiniPlayerView.topSide, glyph: 13,
        tip: String(localized: "Close", comment: "Tooltip of the mini player's close button: stops the video and closes the player."))
    private let rewindButton = MiniPlayerView.overlayButton("gobackward.15", side: MiniPlayerView.centerSide, glyph: 20,
        tip: String(localized: "Back 15 Seconds", comment: "Tooltip of the mini player's button that skips the video back 15 seconds."))
    private let playButton = MiniPlayerView.overlayButton("pause.fill", side: MiniPlayerView.centerSide, glyph: 24,
        tip: String(localized: "Pause", comment: "Tooltip of the mini player's play button while the video plays."))
    private let forwardButton = MiniPlayerView.overlayButton("goforward.15", side: MiniPlayerView.centerSide, glyph: 20,
        tip: String(localized: "Forward 15 Seconds", comment: "Tooltip of the mini player's button that skips the video ahead 15 seconds."))
    private let progress = MiniPlayerProgress()
    private weak var webView: WKWebView?

    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onToggle: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onSeekTo: ((Double) -> Void)?
    var onMoved: (() -> Void)?
    /// Where it may be dragged, in its superview.
    var dragArea: NSRect = .infinite
    var siteName = "" {
        didSet {
            guard siteName != oldValue else { return }
            backButton.title = siteName
            setAccessibilityLabel(String(localized: "Video from \(siteName)", comment: "VoiceOver's name for the mini player. The site is a domain, like youtube.com."))
            needsLayout = true
        }
    }

    /// The buttons along the top, and the three in the middle.
    private static let topSide: CGFloat = 28
    private static let centerSide: CGFloat = 36
    /// The controls go this long after the pointer stops moving over the video.
    private static let idleHide: TimeInterval = 2.5

    /// A white glyph on the picture, a step bolder than the window's own, on a soft shadow so it reads on white too.
    private static func overlayButton(_ symbol: String, side: CGFloat, glyph: CGFloat, tip: String) -> IconButton {
        let button = IconButton(symbol: symbol, size: side, symbolSize: glyph, toolTip: tip)
        button.glyph = overlayGlyph(symbol, size: glyph)
        button.tint = .white
        button.radius = side / 2
        button.layer?.shadowColor = .black
        button.layer?.shadowOpacity = 0.6
        button.layer?.shadowRadius = 4
        button.layer?.shadowOffset = .zero
        return button
    }

    static func overlayGlyph(_ symbol: String, size: CGFloat) -> NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)) ?? NSImage()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1
        layer?.shadowRadius = Tokens.Shadow.panelRadius
        clip.wantsLayer = true
        clip.clipsToBounds = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .continuous
        clip.layer?.backgroundColor = .black
        addSubview(clip)
        clip.addSubview(host)

        // The controls draw as they would at night: white glyphs and washes over the picture.
        controls.appearance = NSAppearance(named: .darkAqua)
        controls.wantsLayer = true
        // The dim takes the card's shape too.
        controls.clipsToBounds = true
        controls.layer?.masksToBounds = true
        controls.layer?.cornerCurve = .continuous
        controls.alphaValue = 0
        controls.addSubview(scrim)
        for view in [backButton, minimizeButton, closeButton, rewindButton, playButton, forwardButton, progress] as [NSView] { controls.addSubview(view) }
        addSubview(controls)

        edge.layer?.borderWidth = Tokens.Metric.hairline
        addSubview(edge)

        backButton.onClick = { [weak self] _ in self?.onBack?() }
        minimizeButton.onClick = { [weak self] _ in self?.onMinimize?() }
        closeButton.onClick = { [weak self] _ in self?.onClose?() }
        rewindButton.onClick = { [weak self] _ in self?.onSeek?(-15) }
        forwardButton.onClick = { [weak self] _ in self?.onSeek?(15) }
        playButton.onClick = { [weak self] _ in self?.onToggle?() }
        progress.onSeek = { [weak self] fraction in self?.onSeekTo?(fraction) }
        // Holding the bar keeps the controls up.
        progress.onScrub = { [weak self] _ in self?.keepControls() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: The page inside

    /// Takes the page in, at the size it had in the page card.
    func adopt(_ webView: WKWebView) {
        self.webView = webView
        let size = webView.frame.size
        webView.autoresizingMask = []
        host.addSubview(webView)
        webView.frame = NSRect(origin: .zero, size: size)
    }

    /// Lets the page go, unless something else has already taken it (its tab shown in another window).
    func release() {
        guard let webView, webView.superview === host else { return }
        webView.removeFromSuperview()
        webView.autoresizingMask = [.width, .height]
        self.webView = nil
    }

    private var placement = MiniPlayerLayout.Placement(scale: 1, origin: .zero)

    /// Which part of the page shows, and how big.
    func show(_ placement: MiniPlayerLayout.Placement) {
        guard placement != self.placement else { return }
        self.placement = placement
        needsLayout = true
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            let radius = Tokens.Radius.panel
            clip.frame = bounds
            clip.layer?.cornerRadius = radius
            host.frame = clip.bounds
            host.bounds = placement.visible(in: bounds.size)
            edge.frame = bounds
            edge.radius = radius
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            layer?.shadowOffset = Tokens.Shadow.panelOffset(flipped: isFlipped)
            controls.layer?.cornerRadius = radius
            layoutControls()
        }
    }

    private func layoutControls() {
        controls.frame = bounds
        scrim.frame = bounds
        let pad = Tokens.Space.x2, top = Self.topSide
        closeButton.frame = NSRect(x: bounds.width - pad - top, y: pad, width: top, height: top)
        minimizeButton.frame = NSRect(x: closeButton.frame.minX - Tokens.Space.x1 - top, y: pad, width: top, height: top)
        let room = max(0, minimizeButton.frame.minX - Tokens.Space.x2 - pad)
        backButton.frame = NSRect(x: pad, y: pad, width: min(backButton.fittingWidth, room), height: top)
        // The three in the middle, evenly apart, a touch below the middle so they sit between the two rows.
        let side = Self.centerSide
        let middle = NSPoint(x: bounds.midX, y: round((pad + top + bounds.height - MiniPlayerProgress.height) / 2))
        let gap = round(min(max(bounds.width * 0.18, 52), 76))
        for (button, dx) in [(rewindButton, -gap), (playButton, 0), (forwardButton, gap)] {
            button.frame = NSRect(x: round(middle.x + dx - side / 2), y: round(middle.y - side / 2), width: side, height: side)
        }
        progress.frame = NSRect(x: Tokens.Space.x3, y: bounds.height - MiniPlayerProgress.height - 2,
                                width: max(0, bounds.width - Tokens.Space.x3 * 2), height: MiniPlayerProgress.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
            edge.layer?.borderColor = cgColor(Tokens.Color.panelEdge)
        }
    }

    // MARK: State

    /// The video's state: play or pause, its time, and whether it can be skipped through at all (not a live stream).
    func update(_ video: PageVideo) {
        let playing = video.isPlaying
        let symbol = playing ? "pause.fill" : "play.fill"
        if playButton.symbol != symbol {
            let tip = playing ? String(localized: "Pause", comment: "Tooltip of the mini player's play button while the video plays.")
                : String(localized: "Play", comment: "Tooltip of the mini player's play button while the video is paused.")
            playButton.symbol = symbol
            playButton.glyph = Self.overlayGlyph(symbol, size: 24)
            playButton.toolTip = tip
        }
        let seekable = video.duration != nil
        rewindButton.isHidden = !seekable
        forwardButton.isHidden = !seekable
        progress.isHidden = !seekable
        if let duration = video.duration, duration > 0 { progress.setFraction(video.time / duration) }
    }

    // MARK: Showing up and going

    /// Grows out of where the video was on the page (`source`, in the superview), or fades in where it sits.
    func appear(from source: NSRect?) {
        guard let layer, let superview else { return }
        superview.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        guard let source, source.width > 1, !Tokens.Motion.reduceMotion else {
            Tokens.Motion.present(self, from: .inPlace, entering: true)
            return
        }
        // From the video's place and size to the card's, on the render server.
        let k = source.width / max(frame.width, 1)
        let anchor = CGPoint(x: layer.anchorPoint.x * frame.width, y: layer.anchorPoint.y * frame.height)
        let down: CGFloat = superview.isFlipped ? 1 : -1
        let dx = (source.minX + k * anchor.x) - (frame.minX + anchor.x)
        let dy = ((source.minY + k * anchor.y) - (frame.minY + anchor.y)) * down
        let from = CATransform3DConcat(CATransform3DMakeScale(k, k, 1), CATransform3DMakeTranslation(dx, dy, 0))
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: from)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = Tokens.Motion.zoom * Tokens.Motion.debugSlowdown
        grow.timingFunction = Tokens.Motion.easeOut
        layer.add(grow, forKey: "grow")
    }

    /// Fades as it goes, then lets the page go.
    func disappear() {
        isGoing = true
        setControls(false, animated: false)
        Tokens.Motion.present(self, from: .point(CGPoint(x: 0.5, y: 0.5)), entering: false) { [weak self] in
            self?.release()
            self?.removeFromSuperview()
        }
    }
    private var isGoing = false

    // MARK: Pointer

    /// Only the controls take clicks; everywhere else the card is one thing to drag, click or double-click. The page
    /// inside never gets the pointer, so it can't be clicked or scrolled from here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isGoing, !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if showsControls, let hit = controls.hitTest(local), hit is InteractiveView || hit is MiniPlayerProgress, !hit.isHidden {
            return hit
        }
        return self
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { keepControls() }
    override func mouseMoved(with event: NSEvent) { keepControls() }
    override func mouseExited(with event: NSEvent) {
        guard !isDragging, !progress.isScrubbing else { return }
        hideTimer?.invalidate()
        setControls(false, animated: true)
    }
    override func scrollWheel(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private(set) var showsControls = false
    private var hideTimer: Timer?

    /// Up, and up for a while longer: the pointer is on the card.
    private func keepControls() {
        setControls(true, animated: true)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.idleHide, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDragging, !self.progress.isScrubbing else { return }
                // Over a button, they stay.
                if let window = self.window, let hit = self.hitTest(self.superview?.convert(window.mouseLocationOutsideOfEventStream, from: nil) ?? .zero),
                   hit !== self { return }
                self.setControls(false, animated: true)
            }
        }
    }

    /// The controls come and go in a quick fade: they sit over a moving picture, so a cut would flash.
    func setControls(_ on: Bool, animated: Bool) {
        guard on != showsControls else { return }
        showsControls = on
        if animated {
            Tokens.Motion.animate(Tokens.Motion.feedback) { self.controls.animator().alphaValue = on ? 1 : 0 }
        } else {
            controls.alphaValue = on ? 1 : 0
        }
        if !on { [backButton, minimizeButton, closeButton, rewindButton, playButton, forwardButton].forEach { $0.isHovered = false } }
    }

    // MARK: Dragging

    private(set) var isDragging = false
    private var pressPoint: NSPoint?
    private var pressOrigin: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        // Twice on the card: back to its tab, as Arc's does.
        if event.clickCount == 2 { pressPoint = nil; onBack?(); return }
        pressPoint = superview?.convert(event.locationInWindow, from: nil)
        pressOrigin = frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint, let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        let dx = point.x - start.x, dy = point.y - start.y
        if !isDragging {
            guard hypot(dx, dy) > 4 else { return }
            isDragging = true
            layer?.removeAnimation(forKey: "grow")
        }
        moveTo(NSPoint(x: pressOrigin.x + dx, y: pressOrigin.y + dy))
    }

    /// Follows the pointer, never out of the window.
    private func moveTo(_ origin: NSPoint) {
        let moved = MiniPlayerLayout.clamp(NSRect(origin: origin, size: frame.size), in: dragArea)
        setFrameOrigin(moved.origin)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressPoint != nil else { return }
        pressPoint = nil
        if isDragging {
            isDragging = false
            onMoved?()
        } else {
            keepControls()
        }
    }

    #if DEBUG
    /// Scripted checks: the controls as the pointer brings them, without a pointer.
    func debugHover(_ on: Bool) {
        if on { setControls(true, animated: false); hideTimer?.invalidate() } else { setControls(false, animated: false) }
    }
    func debugPress(_ name: String) {
        switch name {
        case "back", "site": onBack?()
        case "close": onClose?()
        case "minimize": onMinimize?()
        case "play": onToggle?()
        case "rewind": onSeek?(-15)
        case "forward": onSeek?(15)
        case "double": onBack?()
        default: break
        }
    }
    /// A drag of the card by this much, let go where it ends.
    func debugDrag(dx: CGFloat, dy: CGFloat) {
        isDragging = true
        moveTo(NSPoint(x: frame.minX + dx, y: frame.minY + dy))
        isDragging = false
        onMoved?()
    }
    #endif
}

/// The site's name with the arrow back to its tab, in the card's top left: one button, the name as much as the arrow.
final class MiniPlayerSiteButton: InteractiveView {
    private let arrow = NSImageView()
    private let label = Label("", font: Tokens.Font.small(.semibold), color: .white)
    var title = "" {
        didSet {
            label.stringValue = title
            toolTip = String(localized: "Back to \(title)", comment: "Tooltip of the mini player's site name: goes back to the tab its video is from. The placeholder is a domain, like youtube.com.")
            needsLayout = true
        }
    }
    private static let lead: CGFloat = 8, gap: CGFloat = 5, trail: CGFloat = 10, glyph: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        pressScales = true
        layer?.cornerRadius = MiniPlayerView.topSideRadius
        layer?.cornerCurve = .continuous
        arrow.image = MiniPlayerView.overlayGlyph("arrow.up.left", size: Self.glyph)
        arrow.imageScaling = .scaleNone
        arrow.contentTintColor = .white
        label.lineBreakMode = .byTruncatingTail
        for view in [arrow, label] as [NSView] {
            addSubview(view)
            view.wantsLayer = true
            view.layer?.shadowColor = .black
            view.layer?.shadowOpacity = 0.5
            view.layer?.shadowRadius = 3
            view.layer?.shadowOffset = .zero
        }
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var toolTip: String? { didSet { setAccessibilityLabel(toolTip) } }

    /// Wide enough for the whole name.
    var fittingWidth: CGFloat { ceil(Self.lead + Self.glyph + 2 + Self.gap + ceil((title as NSString).size(withAttributes: [.font: label.font ?? Tokens.Font.small(.semibold)]).width) + 4 + Self.trail) }

    override func layout() {
        super.layout()
        let side = Self.glyph + 2
        arrow.frame = NSRect(x: Self.lead, y: (bounds.height - side) / 2, width: side, height: side)
        let x = arrow.frame.maxX + Self.gap, h = label.lineHeight
        label.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, bounds.width - x - Self.trail), height: h)
    }

    override func stateDidChange(animated: Bool) {
        let fill: NSColor? = isPressed ? NSColor.white.withAlphaComponent(0.26) : isHovered ? NSColor.white.withAlphaComponent(0.16) : nil
        layer?.set(backgroundColor: fill?.cgColor, animated: animated && !isHovered)
    }
}

extension MiniPlayerView {
    static var topSideRadius: CGFloat { topSide / 2 }
}

/// The dim under the card's controls: even over the whole picture, deeper toward the top and bottom edges.
private final class MiniPlayerScrim: NSView {
    private let dim = CALayer()
    private let top = CAGradientLayer()
    private let bottom = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        layer?.addSublayer(dim)
        for shade in [top, bottom] {
            shade.colors = [NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
            layer?.addSublayer(shade)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            let shade = min(bounds.height * 0.42, 72)
            dim.frame = bounds
            // A flipped view's layer runs down too: the top shade darkens toward y 0.
            top.frame = CGRect(x: 0, y: 0, width: bounds.width, height: shade)
            top.startPoint = CGPoint(x: 0.5, y: 0)
            top.endPoint = CGPoint(x: 0.5, y: 1)
            bottom.frame = CGRect(x: 0, y: bounds.height - shade, width: bounds.width, height: shade)
            bottom.startPoint = CGPoint(x: 0.5, y: 1)
            bottom.endPoint = CGPoint(x: 0.5, y: 0)
        }
    }
}

/// A holder whose y runs down, for the card's controls.
private final class MiniPlayerControls: NSView {
    override var isFlipped: Bool { true }
}

/// The card's rounded outline: drawn, never clicked.
private final class MiniPlayerShape: NSView {
    var radius: CGFloat = 0 { didSet { layer?.cornerRadius = radius } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A view whose y runs down, as the page's does, so the part of the page that shows is placed from its top.
private final class MiniPlayerPage: NSView {
    override var isFlipped: Bool { true }
    // The page inside never takes the pointer.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The video's time as a thin line along the card's bottom; press or drag on it to go to a point.
final class MiniPlayerProgress: NSView {
    static let height: CGFloat = 16
    private static let line: CGFloat = 3
    private let track = CALayer()
    private let fill = CALayer()
    private var fraction: Double = 0
    var onSeek: ((Double) -> Void)?
    var onScrub: ((Double) -> Void)?
    private(set) var isScrubbing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        fill.backgroundColor = NSColor.white.cgColor
        for line in [track, fill] {
            line.cornerRadius = Self.line / 2
            layer?.addSublayer(line)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(String(localized: "Time", comment: "VoiceOver's name for the mini player's progress bar."))
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFraction(_ value: Double) {
        guard !isScrubbing else { return }
        fraction = min(max(value.isFinite ? value : 0, 0), 1)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            let y = (bounds.height - Self.line) / 2
            track.frame = CGRect(x: 0, y: y, width: bounds.width, height: Self.line)
            fill.frame = CGRect(x: 0, y: y, width: bounds.width * fraction, height: Self.line)
        }
        setAccessibilityValue(fraction)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func scrub(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        fraction = Double(min(max(x / max(bounds.width, 1), 0), 1))
        needsLayout = true
        onScrub?(fraction)
    }

    override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        scrub(event)
    }

    override func mouseDragged(with event: NSEvent) { scrub(event) }

    override func mouseUp(with event: NSEvent) {
        scrub(event)
        isScrubbing = false
        onSeek?(fraction)
    }
}
