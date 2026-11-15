import AppKit
import WebKit

/// Leave Zigzag while a video plays in the page you're on, for another app or another desktop (a full screen app's
/// own, too), and the video floats in Picture in Picture over whatever you went to, as Arc does (#238). Come back to
/// that page and it goes back in. Only what Zigzag floated itself goes back: Picture in Picture you started yourself
/// stays until you close it. Come back to another tab and it floats on, until you go to its tab. Switching tabs inside
/// Zigzag is the mini player's (`MiniPlayer`); a video already there stays there, since its panel floats over other
/// apps and desktops already. It floats through WebKit's own Picture in Picture (`togglePictureInPicture`), which needs
/// no press on the page; for a video WebKit's own doesn't have yet (one that started by itself, never pressed), the
/// page's script floats it (`PageVideos`). Settings › Tabs › Picture in picture when you leave Zigzag turns it off.
final class AutoPictureInPicture {
    static let shared = AutoPictureInPicture()

    private static let key = "PictureInPictureWhenLeaving"
    /// On unless turned off in Settings.
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private var model = AutoPictureInPictureModel()
    /// The page Zigzag floated, while it floats.
    private weak var floated: BrowserWebView?
    /// WebKit takes a moment to float it: until then it isn't floating yet, rather than stopped.
    private var enteringUntil = Date.distantPast
    /// The page in front as Zigzag went to the background, for floating once it's really gone.
    private weak var leaving: BrowserWebView?
    private var leaveWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillResign() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconsider() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        })
    }

    // MARK: Leaving

    /// The page you're on in the window in front: the focused half of a split, or Zigzag Mini's page.
    private static func frontPage() -> BrowserWebView? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible, !window.isMiniaturized else { return nil }
        if let controller = window.windowController as? BrowserWindowController { return controller.tabManager.selectedTab?.webView }
        if let controller = window.windowController as? MiniWindowController { return controller.tab.webView }
        return nil
    }

    private func appWillResign() {
        // A moment later, once Zigzag is really in the background: a passing system prompt over it isn't leaving.
        leaving = Self.frontPage()
        scheduleLeave { !NSApp.isActive }
    }

    /// Another desktop came up while Zigzag stays the active app (one with none of its windows on it).
    private func spaceChanged() {
        guard NSApp.isActive else { return }
        if let page = Self.frontPage(), let window = page.window, !window.isOnActiveSpace {
            leaving = page
            scheduleLeave { [weak page] in NSApp.isActive && page?.window?.isOnActiveSpace == false }
        } else {
            reconsider()
        }
    }

    private func scheduleLeave(while stillAway: @escaping () -> Bool) {
        leaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, stillAway(), let page = self.leaving else { return }
                self.leaving = nil
                self.float(page)
            }
        }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func float(_ webView: BrowserWebView) {
        let tab = webView.owner
        let followed = PageVideos.shared.followed(in: webView, leavingPage: tab?.isLeavingPage ?? false)
        let native = webView.canTogglePictureInPicture
        let page = AutoPictureInPictureModel.Page(canFloat: native || followed != nil, isFloating: Self.isFloating(webView),
                                                  isFullScreen: webView.fullscreenState != .notInFullscreen, video: followed?.video)
        guard model.leaving(ObjectIdentifier(webView), page: page, isOn: Self.isOn) else {
            debugLog("autopip: not floating (on=\(Self.isOn) native=\(native) floating=\(page.isFloating) full=\(page.isFullScreen) video=\(followed != nil) blocks=\(followed?.video.blocksPictureInPicture ?? false))")
            return
        }
        floated = webView
        enteringUntil = Date().addingTimeInterval(1.5)
        if native {
            webView.togglePictureInPicture()
        } else if let followed {
            // WebKit's own has no video to float until one's been pressed: the page's script floats the one you were
            // watching, as if pressed (`PageVideos`' float).
            Task {
                _ = await PageVideos.shared.run("float", [("i", followed.video.index)], in: followed.frame, of: webView)
                PictureInPicture.floatSoon()
            }
        }
        debugLog("autopip: floated \(tab?.displayTitle ?? "?") native=\(native)")
        // WebKit may decline it after all (the video gone a moment before): then it isn't Zigzag's to end.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
            MainActor.assumeIsolated {
                guard let self, let webView, self.floated === webView else { return }
                let floating = Self.isFloating(webView)
                if !floating { self.model.stopped(ObjectIdentifier(webView)); self.floated = nil }
                debugLog("autopip: after 1.5s floating=\(floating)")
            }
        }
    }

    /// Whether a video of the page floats in Picture in Picture: WebKit's own, or one the page's script floated.
    private static func isFloating(_ webView: BrowserWebView) -> Bool {
        webView.isPictureInPictureActive || PageVideos.shared.frames(in: webView).contains { $0.pictureInPicture }
    }

    // MARK: Coming back

    private func cameBack() {
        leaveWork?.cancel()
        leaving = nil
        // The window you come back to is key a moment after the app is active.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.reconsider() } }
    }

    /// Back in front of the page Zigzag floated (the app active, its window key on this desktop, the page on screen
    /// in it): its video goes back in. Called as the app comes back, a window becomes key, the desktop changes, and
    /// a window shows another tab.
    func reconsider() {
        guard let webView = floated else { model.forget(); return }
        let id = ObjectIdentifier(webView)
        let floating = Self.isFloating(webView)
        if !floating, Date() < enteringUntil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in MainActor.assumeIsolated { self?.reconsider() } }
            return
        }
        let inFront = NSApp.isActive && Self.isInFront(webView)
        guard model.returning(id, isFloating: floating, isInFront: inFront) else {
            if !model.owns(id) { floated = nil }
            return
        }
        floated = nil
        debugLog("autopip: back, ending")
        if webView.isPictureInPictureActive {
            webView.togglePictureInPicture()
        } else {
            for frame in PageVideos.shared.frames(in: webView) where frame.pictureInPicture {
                Task { _ = await PageVideos.shared.run("unfloat", in: frame, of: webView) }
            }
        }
    }

    /// The page is on screen in the key window, on this desktop: the tab you're on, or beside it in a split.
    private static func isInFront(_ webView: BrowserWebView) -> Bool {
        guard let window = NSApp.keyWindow, webView.window === window, window.isOnActiveSpace, !window.isMiniaturized else { return false }
        if let controller = window.windowController as? BrowserWindowController {
            guard let tab = webView.owner, let selected = controller.tabManager.selectedTab else { return false }
            return controller.tabManager.panes(of: selected).contains { $0 === tab }
        }
        if let controller = window.windowController as? MiniWindowController { return controller.tab.webView === webView }
        return false
    }
}

/// When Zigzag floats a video as you leave, and when it ends one as you come back: only one it floated itself.
nonisolated struct AutoPictureInPictureModel {
    /// The page in front as you leave.
    struct Page {
        /// WebKit's own Picture in Picture has a video in it to float, or the page's script has one.
        var canFloat: Bool
        /// It's in Picture in Picture already (you put it there).
        var isFloating: Bool
        /// Its video fills the screen: it has a desktop of its own.
        var isFullScreen: Bool
        /// The video you were watching (`MiniPlayerLayout.followed`), if any.
        var video: PageVideo?
    }

    /// The page Zigzag floated, while it floats.
    private(set) var owned: ObjectIdentifier?

    func owns(_ page: ObjectIdentifier) -> Bool { owned == page }

    /// Whether a page floats as you leave Zigzag: the setting on, a video you were watching playing in it, one the
    /// page lets float, not already floating or in full screen.
    static func floats(_ page: Page, isOn: Bool) -> Bool {
        guard isOn, page.canFloat, !page.isFloating, !page.isFullScreen, let video = page.video else { return false }
        return !video.blocksPictureInPicture
    }

    /// You left with `page` in front: whether to float it. If so it's Zigzag's, to end when you're back.
    mutating func leaving(_ id: ObjectIdentifier, page: Page, isOn: Bool) -> Bool {
        guard Self.floats(page, isOn: isOn) else { return false }
        owned = id
        return true
    }

    /// It stopped floating some other way (its own buttons, the page): nothing to end.
    mutating func stopped(_ id: ObjectIdentifier) {
        if owned == id { owned = nil }
    }

    mutating func forget() { owned = nil }

    /// Whether to end the page's Picture in Picture now: Zigzag's own, still floating, and you're back in front of
    /// its page. Not back in front, it floats on.
    mutating func returning(_ id: ObjectIdentifier, isFloating: Bool, isInFront: Bool) -> Bool {
        guard owned == id else { return false }
        guard isFloating else { owned = nil; return false }
        guard isInFront else { return false }
        owned = nil
        return true
    }
}
