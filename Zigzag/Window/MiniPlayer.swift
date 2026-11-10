import AppKit
import WebKit

/// Arc's mini player: leave a tab while its video plays and the video keeps playing in a small card over the page
/// area, until you come back to the tab or close the card. It is the tab's own live page, moved into the card and
/// scaled so only its video shows: nothing is copied or reloaded, the page keeps its layout (its size never changes,
/// so it never reflows), and sound simply carries on. One per window, in private windows too, kept across spaces.
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

    /// The corner it sits in, the one you last dragged it to.
    static var corner: MiniPlayerLayout.Corner {
        get { UserDefaults.standard.string(forKey: "MiniPlayerCorner").flatMap(MiniPlayerLayout.Corner.init) ?? .bottomRight }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "MiniPlayerCorner") }
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

    /// Back to the tab: its page, video and all, goes back into the page card.
    func returnToTab() {
        guard let tab, let controller else { return }
        controller.tabManager.select(tab)
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
                guard let self, change == .webView || change == .url, let tab else { return }
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

    /// Sizes the card for the video and the window, in its corner (or where it's being dragged).
    func place() {
        guard let controller, let card, let webView else { return }
        let area = controller.root.cardFrame
        let picture = pictureRect(in: webView)
        let aspect = picture.height > 0 ? picture.width / picture.height : 16 / 9
        let size = MiniPlayerLayout.cardSize(aspect: aspect, in: area.size)
        if !card.isDragging {
            card.frame = MiniPlayerLayout.frame(at: Self.corner, size: size, in: area)
        }
        card.show(MiniPlayerLayout.placement(showing: picture, in: size))
    }

    /// Let go after a drag: to the nearest corner, which it keeps.
    private func dropped() {
        guard let controller, let card else { return }
        let area = controller.root.cardFrame
        Self.corner = MiniPlayerLayout.nearestCorner(to: CGPoint(x: card.frame.midX, y: card.frame.midY), in: area)
        let target = MiniPlayerLayout.frame(at: Self.corner, size: card.frame.size, in: area)
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
         "corner": Self.corner.rawValue, "playing": video?.isPlaying ?? false, "time": video?.time ?? 0,
         "follows": controller?.tabManager.allTabs.filter(follows).map(\.displayTitle) ?? [],
         "reporting": controller?.tabManager.allTabs.filter { $0.webView.map { !PageVideos.shared.frames(in: $0).isEmpty } ?? false }.map(\.displayTitle) ?? [],
         "hovered": card?.showsControls ?? false, "webViewInCard": webView.map { $0.superview?.superview?.superview === card } ?? false]
    }
    #endif
}

// MARK: - The card

/// The card the video plays in: rounded, on the floating layer's one shadow, the page inside scaled so its video
/// fills it. Pointing at it brings its controls; it drags anywhere and settles in the nearest corner.
final class MiniPlayerView: NSView {
    private let clip = NSView()
    /// Holds the page at its own size; its bounds are the part of the page that shows, so the page is scaled into the
    /// card without being laid out again.
    private let host = MiniPlayerPage()
    private let edge = CALayer()
    private let controls = NSView()
    /// Under the controls: an even dim over the picture, deeper at the top and bottom edges where the words and the
    /// time sit, so white reads on any video.
    private let dim = CALayer()
    private let topShade = CAGradientLayer()
    private let bottomShade = CAGradientLayer()
    private let backButton = IconButton(symbol: "arrow.up.left", toolTip: String(localized: "Back to Tab", comment: "Tooltip of the mini player's button that takes you back to the tab its video is from."))
    private let closeButton = IconButton(symbol: "xmark", toolTip: String(localized: "Close", comment: "Tooltip of the mini player's close button: stops the video and closes the player."))
    private let rewindButton = IconButton(symbol: "gobackward.15", toolTip: String(localized: "Back 15 Seconds", comment: "Tooltip of the mini player's button that skips the video back 15 seconds."))
    private let playButton = IconButton(symbol: "pause", size: MiniPlayerView.playSide, symbolSize: MiniPlayerView.playGlyph,
                                        toolTip: String(localized: "Pause", comment: "Tooltip of the mini player's play button while the video plays."))
    private let forwardButton = IconButton(symbol: "goforward.15", toolTip: String(localized: "Forward 15 Seconds", comment: "Tooltip of the mini player's button that skips the video ahead 15 seconds."))
    private let title = Label("", font: Tokens.Font.small(.medium), color: .white)
    private let progress = MiniPlayerProgress()
    private weak var webView: WKWebView?

    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggle: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onSeekTo: ((Double) -> Void)?
    var onMoved: (() -> Void)?
    var siteName = "" {
        didSet {
            title.stringValue = siteName
            setAccessibilityLabel(String(localized: "Video from \(siteName)", comment: "VoiceOver's name for the mini player. The site is a domain, like youtube.com."))
        }
    }

    /// The play button is the card's main control: a size up from the others.
    private static let playSide: CGFloat = 40
    private static let playGlyph: CGFloat = 22
    /// The controls go this long after the pointer stops moving over the video.
    private static let idleHide: TimeInterval = 2.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1
        layer?.shadowRadius = Tokens.Shadow.panelRadius
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Tokens.Radius.panel
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = .black
        addSubview(clip)
        clip.addSubview(host)

        // The controls draw as they would at night: white glyphs and washes over the picture.
        controls.appearance = NSAppearance(named: .darkAqua)
        controls.wantsLayer = true
        controls.alphaValue = 0
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        controls.layer?.addSublayer(dim)
        for shade in [topShade, bottomShade] {
            shade.colors = [NSColor.black.withAlphaComponent(0.5).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
            controls.layer?.addSublayer(shade)
        }
        // A layer's y runs up: the bottom one darkens toward the bottom edge, the top one toward the top.
        bottomShade.startPoint = CGPoint(x: 0.5, y: 0)
        bottomShade.endPoint = CGPoint(x: 0.5, y: 1)
        topShade.startPoint = CGPoint(x: 0.5, y: 1)
        topShade.endPoint = CGPoint(x: 0.5, y: 0)
        title.lineBreakMode = .byTruncatingTail
        for view in [backButton, title, closeButton, rewindButton, playButton, forwardButton, progress] as [NSView] { controls.addSubview(view) }
        for button in [backButton, closeButton, rewindButton, playButton, forwardButton] { button.tint = .white }
        addSubview(controls)

        edge.cornerRadius = Tokens.Radius.panel
        edge.cornerCurve = .continuous
        edge.borderWidth = Tokens.Metric.hairline
        layer?.addSublayer(edge)

        backButton.onClick = { [weak self] _ in self?.onBack?() }
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
        self.placement = placement
        needsLayout = true
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            clip.frame = bounds
            host.frame = clip.bounds
            host.bounds = placement.visible(in: bounds.size)
            edge.frame = bounds
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Tokens.Radius.panel, cornerHeight: Tokens.Radius.panel, transform: nil)
            layer?.shadowOffset = Tokens.Shadow.panelOffset(flipped: isFlipped)
            layoutControls()
        }
    }

    private func layoutControls() {
        controls.frame = bounds
        let pad = Tokens.Space.x2, side = Tokens.Metric.iconButton
        let shade = min(bounds.height * 0.4, 64)
        // Its layer isn't flipped: the top of the card is at max y.
        dim.frame = bounds
        topShade.frame = CGRect(x: 0, y: bounds.height - shade, width: bounds.width, height: shade)
        bottomShade.frame = CGRect(x: 0, y: 0, width: bounds.width, height: shade)
        backButton.frame = NSRect(x: pad, y: bounds.height - pad - side, width: side, height: side)
        closeButton.frame = NSRect(x: bounds.width - pad - side, y: bounds.height - pad - side, width: side, height: side)
        let titleHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: backButton.frame.maxX + Tokens.Space.x1, y: backButton.frame.midY - titleHeight / 2,
                             width: max(0, closeButton.frame.minX - backButton.frame.maxX - Tokens.Space.x2), height: titleHeight)
        let mid = NSPoint(x: bounds.midX, y: bounds.midY)
        playButton.frame = NSRect(x: mid.x - Self.playSide / 2, y: mid.y - Self.playSide / 2, width: Self.playSide, height: Self.playSide)
        let gap = Tokens.Space.x6
        rewindButton.frame = NSRect(x: playButton.frame.minX - gap - side, y: mid.y - side / 2, width: side, height: side)
        forwardButton.frame = NSRect(x: playButton.frame.maxX + gap, y: mid.y - side / 2, width: side, height: side)
        progress.frame = NSRect(x: Tokens.Space.x3, y: Tokens.Space.x1, width: max(0, bounds.width - Tokens.Space.x3 * 2), height: MiniPlayerProgress.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            layer?.shadowColor = cgColor(Tokens.Color.panelShadow)
            edge.borderColor = cgColor(Tokens.Color.panelEdge)
        }
    }

    // MARK: State

    /// The video's state: play or pause, its time, and whether it can be skipped through at all (not a live stream).
    func update(_ video: PageVideo) {
        let playing = video.isPlaying
        if playButton.symbol != (playing ? "pause" : "play") {
            playButton.symbol = playing ? "pause" : "play"
            playButton.toolTip = playing ? String(localized: "Pause", comment: "Tooltip of the mini player's play button while the video plays.")
                : String(localized: "Play", comment: "Tooltip of the mini player's play button while the video is paused.")
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

    /// Only the controls take clicks; everywhere else the card is one thing to drag or double-click. The page inside
    /// never gets the pointer, so it can't be clicked or scrolled from here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isGoing, !isHidden, frame.contains(point) else { return nil }
        if showsControls, let hit = controls.hitTest(convert(point, from: superview)), hit is InteractiveView || hit is MiniPlayerProgress, !hit.isHidden {
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
        Tokens.Motion.animate(Tokens.Motion.feedback) { self.controls.animator().alphaValue = on ? 1 : 0 }
        if !animated { controls.alphaValue = on ? 1 : 0 }
        if !on { [backButton, closeButton, rewindButton, playButton, forwardButton].forEach { $0.isHovered = false } }
    }

    // MARK: Dragging

    private(set) var isDragging = false
    private var pressPoint: NSPoint?
    private var pressOrigin: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onBack?(); return }
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
        setFrameOrigin(NSPoint(x: pressOrigin.x + dx, y: pressOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        pressPoint = nil
        guard isDragging else { return }
        isDragging = false
        onMoved?()
    }

    #if DEBUG
    /// Scripted checks: the controls as the pointer brings them, without a pointer.
    func debugHover(_ on: Bool) {
        if on { setControls(true, animated: false); hideTimer?.invalidate() } else { setControls(false, animated: false) }
    }
    func debugPress(_ name: String) {
        switch name {
        case "back": onBack?()
        case "close": onClose?()
        case "play": onToggle?()
        case "rewind": onSeek?(-15)
        case "forward": onSeek?(15)
        default: break
        }
    }
    /// A drag of the card by this much, let go where it ends.
    func debugDrag(dx: CGFloat, dy: CGFloat) {
        isDragging = true
        setFrameOrigin(NSPoint(x: frame.minX + dx, y: frame.minY + dy))
        isDragging = false
        onMoved?()
    }
    #endif
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
