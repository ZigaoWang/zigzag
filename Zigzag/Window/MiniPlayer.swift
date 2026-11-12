import AppKit
import WebKit

/// Arc's mini player: leave a tab while its video plays and the video keeps playing in a small card, until you come
/// back to the tab or close the card. The card floats in a panel of its own (#172), over the window and other apps,
/// on every space and beside full screen windows, as the Mac's Picture in Picture does. It is the tab's own live
/// page, moved into the card and scaled so only its video shows: nothing is copied or reloaded, the page keeps its
/// layout (its size never changes, so it never reflows), and sound simply carries on. It drags anywhere on screen;
/// minimized, it goes and the video plays on in its tab, out of sight. One per window, in private windows too, kept across spaces.
/// Settings › Tabs › Keep videos playing when you switch tabs turns it off.
final class MiniPlayer {
    private weak var controller: BrowserWindowController?
    private var model = MiniPlayerModel()
    private(set) weak var tab: Tab?
    private weak var webView: BrowserWebView?
    private(set) var card: MiniPlayerView?
    /// The floating panel the card is in, while it shows.
    private var panel: MiniPlayerPanel?
    /// The window moving or resizing, or the screens changing: the card keeps to its place.
    private var windowWatch: [NSObjectProtocol] = []
    /// The frame the video is in, and which of its videos it is.
    private var frameID: String?
    private var videoIndex = 0
    private var video: PageVideo?
    /// Where that frame's viewport starts in the page, in CSS pixels.
    private var frameOrigin: CGPoint = .zero
    private var tokens: [SignalToken] = []
    /// The video went missing: the player waits a moment for it (a page moving on to the next video), then goes.
    private var lostWait: DispatchWorkItem?
    /// The frame whose video is shown alone (`isolate`), to give back as it was.
    private var isolatedFrame: PageVideos.Frame?
    /// Minimized videos' pages, playing on out of sight (MiniPlayerParking).
    private var parked: [Parked] = []
    private struct Parked {
        weak var tab: Tab?
        weak var webView: BrowserWebView?
        /// What waits in the window: the page in its holder.
        weak var holder: PageHolder?
        /// The card fading out with the page still in it, until it hands the page over.
        weak var card: MiniPlayerView?
        var frame: PageVideos.Frame?
        var tokens: [SignalToken] = []
        /// The video stopped: the page is let go of after a moment, unless it plays again.
        var stopped: DispatchWorkItem?
    }
    private lazy var parking: MiniPlayerParking = {
        let view = MiniPlayerParking()
        controller?.root.addSubview(view, positioned: .below, relativeTo: nil)
        return view
    }()

    init(controller: BrowserWindowController) {
        self.controller = controller
    }

    /// Where the card rests, as you last let it go: a corner of the page area, or a place of its own. None until
    /// it's first moved: it starts at the bottom right of the page.
    static var place: MiniPlayerLayout.Place? {
        get { UserDefaults.standard.string(forKey: "MiniPlayerPlace").flatMap(MiniPlayerLayout.Place.init(stored:)) }
        set { UserDefaults.standard.set(newValue?.stored, forKey: "MiniPlayerPlace") }
    }

    /// The screen the card was last let go on, for a place on the screen (its corner, or a place of its own): by
    /// the screen's number, as macOS gives it. None, or a screen that's gone: the window's screen.
    static var screenID: UInt32? {
        get { (UserDefaults.standard.object(forKey: "MiniPlayerScreen") as? NSNumber)?.uint32Value }
        set { UserDefaults.standard.set(newValue.map { NSNumber(value: $0) }, forKey: "MiniPlayerScreen") }
    }

    /// The card's size as you last left it, by its longer side, for a video of any shape. None until it's first
    /// resized: it's a third of the page area wide.
    static var extent: CGFloat? {
        get { let value = UserDefaults.standard.double(forKey: "MiniPlayerSize"); return value > 0 ? value : nil }
        set { UserDefaults.standard.set(newValue.map(Double.init), forKey: "MiniPlayerSize") }
    }

    var isShowing: Bool { model.tab != nil }

    /// The pointer is on the card, or the card is being dragged: the sidebar's hover previews hold off for the tabs
    /// under it, which you're not pointing at.
    var isUnderPointer: Bool {
        guard let card, let window = card.window, card.superview != nil, !card.isHiddenOrHasHiddenAncestor else { return false }
        #if DEBUG
        if debugPointerOnCard { return true }
        #endif
        if card.isDragging { return true }
        return card.frame.contains(card.superview!.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    #if DEBUG
    /// Scripted checks: the pointer counts as on the card, wherever the real one is.
    var debugPointerOnCard = false
    #endif

    // MARK: Moving between tabs

    /// The tabs on screen changed: `before` were in the page cards, `after` are going in now (two in a split). Called
    /// before the cards change, while a tab you're leaving is still in its card.
    func switched(from before: [Tab], to after: [Tab]) {
        let shown = Set(after.map(\.id))
        // A minimized video's tab coming back: its page goes into the page card, as from the card.
        unpark { $0.tab.map { shown.contains($0.id) } ?? true }
        let playing = PictureInPicture.followsTabs ? before.first { !shown.contains($0.id) && $0.id != model.tab && follows($0) } : nil
        apply(model.switched(shown: shown, playing: playing?.id))
    }

    /// Whether this tab's video would follow you out of it: its page is on screen, and plays a video you were
    /// watching (`MiniPlayerLayout.followed`), not one it's leaving behind for a page on its way in.
    private func follows(_ tab: Tab) -> Bool {
        guard !tab.isPeek, !tab.isClosed, let webView = tab.webView, webView.window != nil, Self.isInPageCard(tab.pageHolder) else { return false }
        return PageVideos.shared.followed(in: webView, leavingPage: tab.isLeavingPage) != nil
    }

    /// Whether the page is shown in one of the window's page cards (not the mini player's, nor a peek's), however
    /// deep in it its holder sits.
    private static func isInPageCard(_ holder: PageHolder?) -> Bool {
        var view = holder?.superview
        while let current = view {
            if current is PageCardView { return true }
            if current is MiniPlayerView { return false }
            view = current.superview
        }
        return false
    }

    /// Tabs came or went: one closed, or moved to another window, takes the player with it.
    func tabsChanged() {
        unpark { entry in
            guard let tab = entry.tab, let webView = entry.webView else { return true }
            return tab.isClosed || controller?.tabManager.tab(with: tab.id) !== tab || tab.webView !== webView
        }
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
        // From over another app, or a window put away in the Dock: the window comes forward with its tab.
        if let window = controller.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Its window is closing: the card goes with it, and minimized videos' pages too.
    func windowClosing() {
        unpark { _ in true }
        guard let id = model.tab else { return }
        windowIsClosing = true
        defer { windowIsClosing = false }
        apply(model.lost(id))
    }
    /// While its window closes: the keyboard isn't handed back to it.
    private var windowIsClosing = false

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
                finish(closing: true, parking: true)
            }
        }
    }

    // MARK: Showing and going

    private func start(_ tab: Tab) {
        guard let controller, let webView = tab.webView, let holder = tab.pageHolder,
              let (frame, video) = PageVideos.shared.followed(in: webView, leavingPage: tab.isLeavingPage) else {
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
        card.onMoved = { [weak self] free in self?.dropped(free: free) }
        card.onResize = { [weak self] in self?.place() }
        card.onResized = { [weak self] in self?.resized() }
        // A tab's hover preview never stays over the card you're on.
        card.onPointer = { [weak self] in self?.controller?.previews.hide() }
        self.card = card
        let panel = MiniPlayerPanel(card: card)
        self.panel = panel
        card.adopt(holder)
        tab.isInMiniPlayer = true
        place()
        card.update(video)
        panel.orderFrontRegardless()
        card.appear(from: source.flatMap { rect in root.window.map { Self.global($0.convertToScreen(root.convert(rect, to: nil))) } })
        watchWindow()

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
            self.isolate()
        }
    }

    /// Lets the page go. Coming back to its tab, it's put back in the page card next, and scrolled back to where you
    /// left it; closed, the card fades as it goes. `parking`: minimized, the page stays in the window, out of sight,
    /// so its video plays on even with no sound (`park`).
    private func finish(closing: Bool, parking: Bool = false) {
        lostWait?.cancel()
        lostWait = nil
        tokens = []
        let webView = webView, frame = currentFrame, isolated = isolatedFrame
        isolatedFrame = nil
        if let webView {
            Task {
                // The page whole again first: it's going back on screen.
                if let isolated { await Self.unisolate(isolated, in: webView) }
                guard let frame else { return }
                _ = await PageVideos.shared.run("watch", [("on", false)], in: frame, of: webView)
                // Parked, the video stays in view in its page (one scrolled out of it may be paused): the page is
                // scrolled back as it's let go of.
                if !parking { _ = await PageVideos.shared.run("restore", in: frame, of: webView) }
            }
        }
        if parking, let tab, let webView {
            park(webView, of: tab, frame: currentFrame)
        } else {
            tab?.isInMiniPlayer = false
        }
        // It had the keyboard: back to the page you're on, in its window, when Zigzag is the app you're in. Not to a
        // window that's closing: the Mac picks the next one.
        if let card, let window = card.window, window.isKeyWindow, !windowIsClosing, let browser = controller?.window {
            if NSApp.isActive { browser.makeKeyAndOrderFront(nil) }
            browser.makeFirstResponder(controller?.tabManager.selectedTab?.webView)
        }
        windowWatch.forEach(NotificationCenter.default.removeObserver)
        windowWatch = []
        if let spaceWatch { NSWorkspace.shared.notificationCenter.removeObserver(spaceWatch) }
        spaceWatch = nil
        panel = nil
        if let card {
            if closing {
                card.disappear(handOff: parking ? { [weak self] holder in
                    guard let self, self.parked.contains(where: { $0.holder === holder }) else { return }
                    self.parking.park(holder)
                } : nil)
            } else { card.release(); card.dismiss() }
        }
        if parking, let index = parked.indices.last { parked[index].card = card }
        card = nil
        tab = nil
        self.webView = nil
        frameID = nil
        video = nil
    }

    // MARK: Minimized

    /// Keeps a minimized video's page in the window, out of sight, until you go to its tab, it closes, its tab gets a
    /// new page, or its video stops. WebKit pauses a muted or silent video in a page that isn't in a window (only
    /// sound plays on there); in the window, however small and hidden, its page counts as on screen and plays on.
    /// The tab stays awake meanwhile.
    private func park(_ webView: BrowserWebView, of tab: Tab, frame: PageVideos.Frame?) {
        unpark { $0.webView === webView }
        let tokens = [
            PageVideos.shared.reported.observe { [weak self, weak webView] page in
                guard let self, let webView, page === webView else { return }
                self.parkedPageReported(webView)
            },
            tab.changed.observe { [weak self, weak tab, weak webView] change in
                guard let self, let tab, change == .webView, tab.webView !== webView else { return }
                self.unpark { $0.tab === tab }
            },
        ]
        parked.append(Parked(tab: tab, webView: webView, holder: tab.pageHolder, frame: frame, tokens: tokens))
        tab.isInMiniPlayer = true
    }

    /// A parked page's video stopped (paused from Now Playing, ended): a couple of seconds on, with nothing playing
    /// again, the page is let go of, as it would be with no mini player.
    private func parkedPageReported(_ webView: BrowserWebView) {
        guard let index = parked.firstIndex(where: { $0.webView === webView }) else { return }
        if PageVideos.shared.playing(in: webView, any: true) != nil {
            parked[index].stopped?.cancel()
            parked[index].stopped = nil
            return
        }
        guard parked[index].stopped == nil else { return }
        let wait = DispatchWorkItem { [weak self, weak webView] in
            guard let self, let webView, PageVideos.shared.playing(in: webView, any: true) == nil else { return }
            self.unpark { $0.webView === webView }
        }
        parked[index].stopped = wait
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: wait)
    }

    /// Lets go of the parked pages that `which` picks: out of the window (or into the page card that's about to take
    /// them), scrolled back to where you left them.
    private func unpark(_ which: (Parked) -> Bool) {
        let going = parked.filter(which)
        guard !going.isEmpty else { return }
        parked.removeAll(where: which)
        for entry in going {
            entry.stopped?.cancel()
            entry.card?.release()
            if let holder = entry.holder { parking.release(holder) }
            guard let webView = entry.webView else { continue }
            if entry.tab?.id != model.tab { entry.tab?.isInMiniPlayer = false }
            if let frame = entry.frame { Task { _ = await PageVideos.shared.run("restore", in: frame, of: webView) } }
        }
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

    /// Shows only the video in its page (the site's own controls and overlays, and the page around it, made
    /// invisible), and with a frame's video, only that frame in the page. Called as the page reports; the same video
    /// again changes nothing, and a new one (the page replaced it, an ad ended) is shown alone in its place.
    private func isolate() {
        guard let webView, let frame = currentFrame else { return }
        let index = videoIndex, origin = frameOrigin, previous = isolatedFrame
        isolatedFrame = frame
        Task { [weak self] in
            if let previous, previous.id != frame.id { await Self.unisolate(previous, in: webView) }
            guard self?.webView === webView else { return }
            _ = await PageVideos.shared.run("isolate", [("i", index)], in: frame, of: webView)
            guard !frame.isMain, self?.webView === webView else { return }
            _ = await PageVideos.shared.run("isolateFrame", [("x", origin.x), ("y", origin.y)], in: nil, of: webView)
        }
    }

    /// The page exactly as it was: the frame's video, and the page around a frame.
    private static func unisolate(_ frame: PageVideos.Frame, in webView: WKWebView) async {
        _ = await PageVideos.shared.run("unisolate", in: frame, of: webView)
        if !frame.isMain { _ = await PageVideos.shared.run("unisolate", in: nil, of: webView) }
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
        isolate()
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

    // MARK: Where it goes

    // The card's arithmetic (MiniPlayerLayout) is done with y running down from the top of the main screen, across
    // every screen: `global` turns the Mac's screen coordinates into that, and back.

    static func global(_ rect: NSRect) -> NSRect {
        MiniPlayerLayout.flipped(rect, mainScreenHeight: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    /// Each screen, and its usable part (clear of the menu bar and the Dock), as the card's arithmetic has them.
    private static var screens: [(id: UInt32?, visible: NSRect, frame: NSRect)] {
        NSScreen.screens.map { screen in
            ((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value, global(screen.visibleFrame), global(screen.frame))
        }
    }

    /// Whether the window is where you can see it: open, not put away in the Dock, and on the space you're on (the
    /// card floats on every space; a window on another one is nowhere near it).
    private static func isShowing(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.isOnActiveSpace
    }

    /// The window's page area on screen; nil while the window isn't showing (`isShowing`): the card takes the
    /// screen's corner then.
    private var pageArea: NSRect? {
        guard let root = controller?.root, let window = root.window, Self.isShowing(window) else { return nil }
        return Self.global(window.convertToScreen(root.convert(root.cardFrame, to: nil)))
    }

    /// The whole window on screen, the sidebar too: let go over it, the card goes to the page's corner.
    private var windowArea: NSRect? {
        guard let window = controller?.window, Self.isShowing(window) else { return nil }
        return Self.global(window.frame)
    }

    /// Where the card may go on the screen that has this point, or the one nearest it.
    private static func movableArea(at point: NSPoint) -> NSRect {
        let all = screens
        func distance(_ frame: NSRect) -> CGFloat { hypot(frame.midX - point.x, frame.midY - point.y) }
        let screen = all.first { $0.frame.contains(point) } ?? all.min { distance($0.frame) < distance($1.frame) }
        return MiniPlayerLayout.movableArea(onScreen: screen?.visible ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
    }

    /// Where the card may go for its place: the page's screen for its corner; the screen it was let go on for a place
    /// on the screen, else the window's.
    private func movableArea(for place: MiniPlayerLayout.Place) -> NSRect {
        if case .corner = place, let page = pageArea { return Self.movableArea(at: NSPoint(x: page.midX, y: page.midY)) }
        if let id = Self.screenID, let screen = Self.screens.first(where: { $0.id == id }) { return MiniPlayerLayout.movableArea(onScreen: screen.visible) }
        let window = windowArea ?? Self.global(NSScreen.main?.visibleFrame ?? .zero)
        return Self.movableArea(at: NSPoint(x: window.midX, y: window.midY))
    }

    /// Where it goes before it's ever moved (`MiniPlayerLayout.firstCorner`).
    private var firstPlace: MiniPlayerLayout.Place {
        .corner(MiniPlayerLayout.firstCorner(sidebarOnRight: controller?.root.sidebarOnRight == true))
    }

    /// Its place: a corner of the page whose window isn't on screen is the same corner of the screen meanwhile.
    private var currentPlace: MiniPlayerLayout.Place {
        let place = Self.place ?? firstPlace
        if case .corner(let corner) = place, pageArea == nil { return .screen(corner) }
        return place
    }

    /// Sizes the card for the video, where you left it (or where it's being dragged).
    func place() {
        guard let controller, let card, let webView else { return }
        let place = currentPlace
        let area = movableArea(for: place)
        let picture = pictureRect(in: webView)
        let aspect = picture.height > 0 ? picture.width / picture.height : 16 / 9
        let size = Self.extent.map { MiniPlayerLayout.cardSize(aspect: aspect, extent: $0, in: area.size) }
            ?? MiniPlayerLayout.cardSize(aspect: aspect, in: controller.root.cardFrame.size)
        // Until it's first moved, at the bottom of the page away from the sidebar.
        let target = MiniPlayerLayout.frame(for: place, size: size, page: pageArea ?? area, in: area)
        card.dragArea = { Self.movableArea(at: $0) }
        if !card.isDragging, !card.isSettling, card.globalFrame != target { card.globalFrame = target }
        let shown = card.isDragging || card.isSettling ? card.globalFrame.size : target.size
        card.show(MiniPlayerLayout.placement(showing: card.shown(picture, of: webView), in: shown))
    }

    /// Follows the window as it moves, resizes or goes to the Dock, and the screens as they change.
    private func watchWindow() {
        let center = NotificationCenter.default
        let moved: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.place() } }
        let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                                          NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        windowWatch = names.map { center.addObserver(forName: $0, object: controller?.window, queue: .main, using: moved) }
            + [center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: moved)]
        // Off to another space, the window is out of sight there as in the Dock: the screen's corner meanwhile.
        spaceWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                       object: nil, queue: .main, using: moved)
    }
    /// The space you're on changing, which takes the window out of sight or back.
    private var spaceWatch: NSObjectProtocol?

    /// Let go after a drag: over the window, it glides into the page area's nearest corner; anywhere else, into the
    /// screen's nearest corner, as the Mac's Picture in Picture does. Let go with ⌘ held (`free`), it stays where it
    /// was let go, settling on an edge only near one. Its place, and its screen, are kept for the next video too.
    private func dropped(free: Bool) {
        guard let card else { return }
        let frame = card.globalFrame
        let middle = NSPoint(x: frame.midX, y: frame.midY)
        let area = Self.movableArea(at: middle)
        let (target, place) = MiniPlayerLayout.rest(frame, free: free, page: pageArea ?? area, window: windowArea, in: area)
        Self.place = place
        if let id = Self.screens.first(where: { $0.frame.contains(middle) })?.id { Self.screenID = id }
        card.settle(at: target)
    }

    /// Let go after resizing: its size is kept, for the next video too, and it stays in its corner (or, placed
    /// freely, where it is).
    private func resized() {
        guard let card else { return }
        Self.extent = max(card.globalFrame.width, card.globalFrame.height)
        let place = currentPlace
        if case .free = place { dropped(free: true); return }
        if Self.place == nil { Self.place = firstPlace }
        let area = movableArea(for: place)
        card.settle(at: MiniPlayerLayout.frame(for: place, size: card.globalFrame.size, page: pageArea ?? area, in: area))
    }

    static func siteName(_ url: URL?) -> String {
        guard let host = url?.host(), !host.isEmpty else { return url?.absoluteString ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    #if DEBUG
    /// The card's state for scripted checks.
    var debugState: [String: Any] {
        ["showing": isShowing, "tab": tab?.displayTitle ?? "", "frame": card.map { NSStringFromRect($0.globalFrame) } ?? "",
         "anchor": Self.place?.stored ?? "", "area": NSStringFromRect(movableArea(for: currentPlace)),
         "page": pageArea.map(NSStringFromRect) ?? "",
         "panel": panel.map { ["number": $0.windowNumber, "visible": $0.isVisible, "level": $0.level.rawValue, "key": $0.isKeyWindow] as [String: Any] } ?? [:], "playing": video?.isPlaying ?? false, "time": video?.time ?? 0,
         "selected": controller?.tabManager.selectedTab?.displayTitle ?? "", "space": controller?.tabManager.currentSpaceID.uuidString ?? "",
         "follows": controller?.tabManager.allTabs.filter(follows).map(\.displayTitle) ?? [],
         // Each tab's videos as its page last told them, and whether its page is on its way out.
         "videos": controller?.tabManager.allTabs.map { tab -> [String: Any] in
             let videos = tab.webView.map { PageVideos.shared.frames(in: $0).flatMap(\.videos) } ?? []
             return ["tab": tab.displayTitle, "leaving": tab.isLeavingPage, "videos": videos.map { String(describing: $0) },
                     "inWindow": tab.webView?.window != nil, "inCard": Self.isInPageCard(tab.pageHolder),
                     "presenting": tab.webView.map { PageVideos.shared.isPresentingItself($0) } ?? false]
         } ?? [],
         "reporting": controller?.tabManager.allTabs.filter { $0.webView.map { !PageVideos.shared.frames(in: $0).isEmpty } ?? false }.map(\.displayTitle) ?? [],
         "hovered": card?.showsControls ?? false, "webViewInCard": webView.map { $0.isDescendant(of: card ?? NSView()) } ?? false,
         "parked": parked.compactMap { $0.tab?.displayTitle }, "parkedInWindow": parked.compactMap { $0.holder.map { $0.superview === parking && $0.window != nil } }]
    }
    #endif
}

// MARK: - Minimized

/// Where a minimized video's page waits while its video plays on (MiniPlayer's `park`): in the window, so WebKit
/// counts the page as on screen, but a single point at the back of it, clipped and transparent, so nothing of it
/// shows; it never takes the pointer, and VoiceOver passes over it. The page keeps its size, so it never reflows.
final class MiniPlayerParking: NSView {
    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        wantsLayer = true
        clipsToBounds = true
        layer?.masksToBounds = true
        alphaValue = 0
        autoresizingMask = []
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    func park(_ holder: PageHolder) {
        let size = holder.frame.size
        holder.autoresizingMask = []
        addSubview(holder)
        holder.frame = NSRect(origin: .zero, size: size)
    }

    /// Out of the window, unless something else has already taken it (its tab's page card).
    func release(_ holder: PageHolder) {
        guard holder.superview === self else { return }
        holder.removeFromSuperview()
        holder.autoresizingMask = [.width, .height]
    }
}

// MARK: - The card

/// The card the video plays in: rounded, the page inside scaled so its video fills it, in a floating panel of its own
/// (`MiniPlayerPanel`) whose shadow is the window's. Pointing at it dims the picture and brings its controls; it drags
/// anywhere on screen, its panel with it. Where it is (`globalFrame`) runs down from the top of the main screen.
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
    private weak var holder: PageHolder?

    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onToggle: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onSeekTo: ((Double) -> Void)?
    /// Let go after a drag; true with ⌘ held, to stay where it was let go.
    var onMoved: ((Bool) -> Void)?
    /// Resized by an edge or a corner: as it goes, and once let go.
    var onResize: (() -> Void)?
    var onResized: (() -> Void)?
    /// The pointer came onto the card, or pressed on it.
    var onPointer: (() -> Void)?
    /// Where it may be dragged, for the pointer at a point: the room on that point's screen.
    var dragArea: (NSPoint) -> NSRect = { _ in .infinite }

    /// Where the card is on screen, y running down from the top of the main screen (`MiniPlayer.global`): its panel's
    /// frame. Set, the panel moves.
    var globalFrame: NSRect {
        get { window.map { MiniPlayer.global($0.frame) } ?? frame }
        set {
            guard let window else { frame = newValue; return }
            let target = MiniPlayer.global(newValue)
            if window.frame != target { window.setFrame(target, display: true) }
        }
    }
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
        autoresizingMask = [.width, .height]
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
        progress.onStep = { [weak self] by in self?.onSeek?(by) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: The page inside

    /// Takes the page in, in its holder, at the size it had in the page card.
    func adopt(_ holder: PageHolder) {
        self.holder = holder
        let size = holder.frame.size
        holder.autoresizingMask = []
        host.addSubview(holder)
        holder.frame = NSRect(origin: .zero, size: size)
    }

    /// A part of the page, in the web view's own points, as it lies in what the card shows: the same, unless the Web
    /// Inspector is docked to the page's left. When the page isn't in the card (WebKit has it in full screen for a
    /// moment while the window resizes), as given.
    func shown(_ rect: NSRect, of webView: WKWebView) -> NSRect {
        webView.isDescendant(of: host) ? host.convert(rect, from: webView) : rect
    }

    /// Lets the page go, unless something else has already taken it (its tab shown in another window).
    func release() {
        guard let holder, holder.superview === host else { return }
        holder.removeFromSuperview()
        holder.autoresizingMask = [.width, .height]
        self.holder = nil
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
            controls.layer?.cornerRadius = radius
            layoutControls()
        }
        // The panel's shadow takes the card's rounded shape at its new size.
        window?.invalidateShadow()
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

    /// Grows out of where the video was on the page (`source`, on screen as `globalFrame` is), or fades in where it
    /// sits. While it grows, its panel takes in both places, so nothing of it is cut off, then fits the card again.
    func appear(from source: NSRect?) {
        guard let layer, let superview, let window else { return }
        layoutSubtreeIfNeeded()
        guard let source, source.width > 1, !Tokens.Motion.reduceMotion else {
            Tokens.Motion.present(self, from: .inPlace, entering: true)
            return
        }
        let target = globalFrame
        let room = target.union(source)
        window.hasShadow = false
        autoresizingMask = []
        globalFrame = room
        // The panel's view runs down as `globalFrame` does: places in it are places on screen less its corner.
        frame = target.offsetBy(dx: -room.minX, dy: -room.minY)
        superview.layoutSubtreeIfNeeded()
        let from = source.offsetBy(dx: -room.minX, dy: -room.minY)
        // From the video's place and size to the card's, on the render server.
        let k = from.width / max(frame.width, 1)
        let anchor = CGPoint(x: layer.anchorPoint.x * frame.width, y: layer.anchorPoint.y * frame.height)
        let down: CGFloat = superview.isFlipped ? 1 : -1
        let dx = (from.minX + k * anchor.x) - (frame.minX + anchor.x)
        let dy = ((from.minY + k * anchor.y) - (frame.minY + anchor.y)) * down
        let start = CATransform3DConcat(CATransform3DMakeScale(k, k, 1), CATransform3DMakeTranslation(dx, dy, 0))
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.fitPanel(to: target) }
        }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: start)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = Tokens.Motion.zoom * Tokens.Motion.debugSlowdown
        grow.timingFunction = Tokens.Motion.easeOut
        layer.add(grow, forKey: "grow")
        CATransaction.commit()
    }

    /// The panel back to the card's own size once it has grown in, unless it was moved meanwhile.
    private func fitPanel(to target: NSRect) {
        guard let window, let superview, autoresizingMask.isEmpty else { return }
        let now = frame.offsetBy(dx: MiniPlayer.global(window.frame).minX, dy: MiniPlayer.global(window.frame).minY)
        Tokens.Motion.withoutAnimation {
            globalFrame = isDragging ? now : target
            frame = superview.bounds
            autoresizingMask = [.width, .height]
        }
        window.hasShadow = true
        window.invalidateShadow()
    }

    /// Fades as it goes, then lets the page go: to `handOff` when given (a minimized video's page, to be kept in the
    /// window), unless something else took it meanwhile.
    func disappear(handOff: ((PageHolder) -> Void)? = nil) {
        isGoing = true
        setControls(false, animated: false)
        Tokens.Motion.present(self, from: .point(CGPoint(x: 0.5, y: 0.5)), entering: false) { [weak self] in
            guard let self else { return }
            if let handOff, let holder, holder.superview === host {
                self.holder = nil
                handOff(holder)
            } else {
                release()
            }
            dismiss()
        }
    }

    /// Out of sight at once, its panel with it.
    func dismiss() {
        let panel = window
        removeFromSuperview()
        panel?.orderOut(nil)
    }
    private var isGoing = false

    // MARK: Pointer

    /// Only the controls take clicks; everywhere else the card is one thing to drag, click or double-click. The page
    /// inside never gets the pointer, so it can't be clicked or scrolled from here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isGoing, !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        // Its edges resize it, over the controls too.
        if !MiniPlayerLayout.edges(at: local, in: bounds.size).isEmpty { return self }
        if showsControls, let hit = controls.hitTest(local), hit is InteractiveView || hit is MiniPlayerProgress, !hit.isHidden {
            return hit
        }
        return self
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Over another app too: it floats there.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onPointer?(); keepControls() }
    override func mouseMoved(with event: NSEvent) { keepControls() }
    override func mouseExited(with event: NSEvent) {
        guard !isDragging, !progress.isScrubbing else { return }
        hideTimer?.invalidate()
        setControls(false, animated: true)
    }
    override func scrollWheel(with event: NSEvent) {}

    // MARK: Keyboard

    /// Clicked, it takes the keyboard, as a player window does: Space plays or pauses, Esc and ⌘W close it. The
    /// page you were on gets it back when you click there, or as the card goes.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty
        if plain, event.keyCode == 49 { onToggle?(); return }
        if plain, event.keyCode == 53 { onClose?(); return }
        super.keyDown(with: event)
    }

    /// ⌘W in its own panel, which the menu bar may not reach while another app is in front.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if window?.firstResponder === self, flags == .command, event.charactersIgnoringModifiers == "w" { onClose?(); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    /// ⌘W (File › Close Tab) closes the card while it has the keyboard, not the tab under it.
    @objc func closeTab(_ sender: Any?) { onClose?() }
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

    /// Moved or resized by the pointer, right now.
    private(set) var isDragging = false
    private var pressPoint: NSPoint?
    private var pressFrame: NSRect = .zero
    /// The edges a press took hold of, to resize the card by; none to move it.
    private var resizing: MiniPlayerLayout.Edges = []

    override func mouseDown(with event: NSEvent) {
        let edges = MiniPlayerLayout.edges(at: convert(event.locationInWindow, from: nil), in: bounds.size)
        // Twice on the card: back to its tab, as Arc's does.
        if event.clickCount == 2, edges.isEmpty { pressPoint = nil; onBack?(); return }
        onPointer?()
        pressPoint = Self.pointer
        pressFrame = globalFrame
        resizing = edges
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint else { return }
        // On screen, not in the panel, which moves under the pointer.
        let point = Self.pointer
        let dx = point.x - start.x, dy = point.y - start.y
        if !isDragging {
            // An edge takes hold at once; the card itself after a few points, so a click stays a click.
            guard !resizing.isEmpty || hypot(dx, dy) > 4 else { return }
            isDragging = true
            layer?.removeAnimation(forKey: "grow")
            if autoresizingMask.isEmpty, let window {
                fitPanel(to: frame.offsetBy(dx: MiniPlayer.global(window.frame).minX, dy: MiniPlayer.global(window.frame).minY))
                pressFrame = globalFrame
            }
        }
        if resizing.isEmpty {
            moveTo(NSPoint(x: pressFrame.minX + dx, y: pressFrame.minY + dy))
        } else {
            resize(by: CGSize(width: dx, height: dy))
        }
    }

    /// Its held edges follow the pointer, the video's shape kept.
    private func resize(by delta: CGSize) {
        let target = MiniPlayerLayout.resized(pressFrame, from: resizing, by: delta, in: dragArea(NSPoint(x: pressFrame.midX, y: pressFrame.midY)))
        guard target != globalFrame else { return }
        globalFrame = target
        onResize?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    /// The resize arrows along its edges and at its corners, as a window's.
    override func resetCursorRects() {
        super.resetCursorRects()
        let w = bounds.width, h = bounds.height, g = MiniPlayerLayout.grip, c = MiniPlayerLayout.cornerGrip
        guard w > c * 2, h > c * 2 else { return }
        let zones: [(NSRect, NSCursor.FrameResizePosition)] = [
            (NSRect(x: c, y: 0, width: w - c * 2, height: g), .top),
            (NSRect(x: c, y: h - g, width: w - c * 2, height: g), .bottom),
            (NSRect(x: 0, y: c, width: g, height: h - c * 2), .left),
            (NSRect(x: w - g, y: c, width: g, height: h - c * 2), .right),
            (NSRect(x: 0, y: 0, width: c, height: c), .topLeft),
            (NSRect(x: w - c, y: 0, width: c, height: c), .topRight),
            (NSRect(x: 0, y: h - c, width: c, height: c), .bottomLeft),
            (NSRect(x: w - c, y: h - c, width: c, height: c), .bottomRight),
        ]
        for (rect, position) in zones { addCursorRect(rect, cursor: .frameResize(position: position, directions: .all)) }
    }

    /// Glides to where it comes to rest after a drag, briefly, as a window snaps; at once with Reduce Motion.
    /// Meanwhile the page inside keeps the card's size, so nothing jumps.
    func settle(at target: NSRect) {
        guard target != globalFrame else { return }
        guard let window else { frame = target; return }
        isSettling = true
        Tokens.Motion.animate(Tokens.Motion.snappy, moves: true) {
            window.animator().setFrame(MiniPlayer.global(target), display: true)
        } completion: { [weak self] in
            self?.isSettling = false
            // The window may have changed meanwhile: placed again for it.
            self?.onResize?()
        }
    }
    private(set) var isSettling = false

    /// Follows the pointer, never off the screen it's on.
    private func moveTo(_ origin: NSPoint, pointer: NSPoint? = nil) {
        let size = globalFrame.size
        let at = pointer ?? Self.pointer
        globalFrame = MiniPlayerLayout.clamp(NSRect(origin: origin, size: size), in: dragArea(at))
    }

    /// The pointer on screen, as `globalFrame` has it.
    private static var pointer: NSPoint {
        MiniPlayer.global(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
    }

    override func mouseUp(with event: NSEvent) {
        guard pressPoint != nil else { return }
        pressPoint = nil
        let resized = !resizing.isEmpty
        resizing = []
        if isDragging {
            isDragging = false
            if resized { onResized?() } else { onMoved?(event.modifierFlags.contains(.command)) }
        } else {
            // The keyboard, as a player's window takes it; its panel never brings Zigzag in front of the app you're in.
            window?.makeKey()
            window?.makeFirstResponder(self)
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
    /// A drag of these edges (l, r, t, b; "tl" a corner) by this much, let go where it ends.
    func debugResize(_ edges: String, dx: CGFloat, dy: CGFloat) {
        let names: [Character: MiniPlayerLayout.Edges] = ["l": .left, "r": .right, "t": .top, "b": .bottom]
        resizing = MiniPlayerLayout.Edges(edges.compactMap { names[$0] })
        pressFrame = globalFrame
        isDragging = true
        resize(by: CGSize(width: dx, height: dy))
        isDragging = false
        resizing = []
        onResized?()
    }
    /// A drag of the card by this much, let go where it ends (with ⌘ held: `free`).
    func debugDrag(dx: CGFloat, dy: CGFloat, free: Bool = false) {
        isDragging = true
        let from = globalFrame
        let to = NSPoint(x: from.minX + dx, y: from.minY + dy)
        moveTo(to, pointer: NSPoint(x: to.x + from.width / 2, y: to.y + from.height / 2))
        isDragging = false
        onMoved?(free)
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
    /// VoiceOver's increment and decrement: 15 seconds on or back, as the card's buttons go.
    var onStep: ((Double) -> Void)?
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

    override func accessibilityPerformIncrement() -> Bool { onStep?(15); return true }
    override func accessibilityPerformDecrement() -> Bool { onStep?(-15); return true }

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

/// The mini player's own floating window (#172): borderless and see-through around the card, it never makes Zigzag
/// the app in front, floats over other apps' windows, on every space and beside full screen windows, as the Mac's
/// Picture in Picture does, and stays when Zigzag isn't in front. Its shadow is the window's, in the card's shape.
final class MiniPlayerPanel: NSPanel {
    init(card: MiniPlayerView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        tabbingMode = .disallowed
        let content = MiniPlayerPanelContent(frame: NSRect(origin: .zero, size: frame.size))
        contentView = content
        card.frame = content.bounds
        content.addSubview(card)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's view, running down as the card's places on screen do.
private final class MiniPlayerPanelContent: NSView {
    override var isFlipped: Bool { true }
}
