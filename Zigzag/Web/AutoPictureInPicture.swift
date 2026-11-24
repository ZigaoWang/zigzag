import AppKit
import WebKit

/// Moves the front tab's playing video into the mini player (`MiniPlayer`) when you switch to another app or desktop
/// (#238), and back when you return to that tab. Off unless enabled in Settings › Tabs › Show a mini player when you
/// leave Zigzag. Only for a real switch: Zigzag must stay in the background for `AutoPictureInPictureModel.delay`,
/// with a regular app in front (not a system prompt, Spotlight, menu bar, Notification Center or a Zigzag web app),
/// and the window out of sight (`AutoPictureInPictureModel.isOutOfSight`, #496).
/// Muted, paused or offscreen videos stay, as do ones already in Picture in Picture or full screen, and an existing
/// mini player isn't replaced. If the mini player can't take the video, nothing happens; Picture in Picture never
/// starts automatically.
final class AutoPictureInPicture {
    static let shared = AutoPictureInPicture()

    private static let key = "PictureInPictureWhenLeaving"
    /// Off by default. Only the switch writes the key, so a stored value is a choice.
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private var model = AutoPictureInPictureModel()
    /// The tab the mini player took the video from.
    private weak var taken: Tab?
    private weak var takenBy: BrowserWindowController?
    /// The front tab when Zigzag went to the background.
    private weak var leaving: Tab?
    private weak var leavingIn: BrowserWindowController?
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
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
            let window = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.sightChanged(window) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sightChanged(nil) }
        })
    }

    // MARK: Leaving

    /// The focused tab of the front browser window. Mini, web app windows and others have no mini player.
    private static func front() -> (tab: Tab, controller: BrowserWindowController)? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible, !window.isMiniaturized,
              let controller = window.windowController as? BrowserWindowController, let tab = controller.tabManager.selectedTab else { return nil }
        return (tab, controller)
    }

    private func appWillResign() {
        debugLog("autopip: Zigzag going to the background (on=\(Self.isOn) front=\(Self.front()?.tab.displayTitle ?? "none"))")
        guard Self.isOn, let (tab, controller) = Self.front() else { return }
        leaving = tab
        leavingIn = controller
        scheduleAway()
    }

    /// After the delay: away, a regular app in front, the window out of sight; else the tab keeps waiting.
    private func scheduleAway() {
        scheduleLeave(keepIfNot: true) { [weak self] in
            guard !NSApp.isActive, AutoPictureInPictureModel.isRealSwitch(to: Self.frontApp()) else { return false }
            guard let window = self?.leavingIn?.window else { return false }
            let out = AutoPictureInPictureModel.isOutOfSight(Self.sight(of: window))
            if !out { debugLog("autopip: window still in view on another display, waiting") }
            return out
        }
    }

    /// Zigzag in the background with a tab waiting: a window's sight or the front app changed.
    private func sightChanged(_ window: ObjectIdentifier?) {
        guard !NSApp.isActive, leaving != nil, let candidate = leavingIn?.window else { return }
        if let window, window != ObjectIdentifier(candidate) { return }
        scheduleAway()
    }

    private static func sight(of window: NSWindow) -> AutoPictureInPictureModel.Sight {
        .init(isHidden: NSApp.isHidden, isMinimized: window.isMiniaturized,
              isInView: window.isVisible && window.occlusionState.contains(.visible),
              windowDisplay: window.screen.flatMap(display(of:)), focusDisplay: focusDisplay())
    }

    private static func display(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The display of the front app's frontmost window, else the one under the pointer.
    private static func focusDisplay() -> UInt32? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0 {
                guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary), bounds.width > 1, bounds.height > 1 else { continue }
                var id: CGDirectDisplayID = 0
                var count: UInt32 = 0
                if CGGetDisplaysWithPoint(CGPoint(x: bounds.midX, y: bounds.midY), 1, &id, &count) == .success, count > 0 { return id }
            }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }.flatMap(display(of:))
    }

    /// Another desktop came up while Zigzag stays active (none of its windows there).
    private func spaceChanged() {
        guard NSApp.isActive else { return }
        if Self.isOn, let (tab, controller) = Self.front(), let window = controller.window, !window.isOnActiveSpace {
            leaving = tab
            leavingIn = controller
            scheduleLeave { [weak window] in NSApp.isActive && window?.isOnActiveSpace == false }
        } else {
            reconsider()
        }
    }

    private static func frontApp() -> AutoPictureInPictureModel.FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let own = Bundle.main.bundleIdentifier ?? ""
        let id = app.bundleIdentifier ?? ""
        return .init(isZigzag: app.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                     isZigzagWebApp: !own.isEmpty && id.hasPrefix(own + ".app."), isRegular: app.activationPolicy == .regular)
    }

    /// `keepIfNot` keeps the tab waiting when `stillAway` fails, for `sightChanged` to try again.
    private func scheduleLeave(keepIfNot: Bool = false, while stillAway: @escaping () -> Bool) {
        leaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let tab = self.leaving, controller = self.leavingIn
                let away = stillAway()
                if !away && keepIfNot && !NSApp.isActive { return }
                self.leaving = nil
                self.leavingIn = nil
                guard away, let tab, let controller else { return }
                self.take(tab, in: controller)
            }
        }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AutoPictureInPictureModel.delay, execute: work)
    }

    /// Only if the video qualifies and the mini player accepts it.
    private func take(_ tab: Tab, in controller: BrowserWindowController) {
        guard controller.tabManager.selectedTab === tab, let webView = tab.webView else { return }
        let followed = PageVideos.shared.followed(in: webView, leavingPage: tab.isLeavingPage)
        let page = AutoPictureInPictureModel.Page(
            video: followed?.video,
            isInView: followed.map { MiniPlayerLayout.visibleArea($0.video.rect, viewport: $0.frame.viewport) > 0 } ?? false,
            isTabMuted: tab.isMuted,
            isPresentingItself: PageVideos.shared.isPresentingItself(webView),
            isMiniPlayerBusy: controller.miniPlayer.isShowing)
        guard model.leaving(tab.id, page: page, isOn: Self.isOn) else {
            debugLog("autopip: not moving (video=\(followed != nil) inView=\(page.isInView) muted=\(page.video?.isMuted ?? false)/\(page.isTabMuted) presenting=\(page.isPresentingItself) busy=\(page.isMiniPlayerBusy))")
            return
        }
        guard controller.miniPlayer.takeOnLeaving(tab) else {
            // Nothing else floats it instead.
            model.forget()
            debugLog("autopip: the mini player didn't take \(tab.displayTitle)")
            return
        }
        taken = tab
        takenBy = controller
        debugLog("autopip: moved \(tab.displayTitle) into the mini player")
    }

    // MARK: Coming back

    private func cameBack() {
        leaveWork?.cancel()
        leaveWork = nil
        leaving = nil
        leavingIn = nil
        // The returned window becomes key a moment after the app activates.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.reconsider() } }
    }

    /// Puts the video back when you're in front of the tab it came from again (app active, its window key on this
    /// desktop, tab visible). Called on activation, key window changes, desktop changes and tab switches.
    func reconsider() {
        guard let tab = taken, let controller = takenBy else { model.forget(); return }
        let isHeld = controller.miniPlayer.holds(tab)
        let inFront = NSApp.isActive && Self.isInFront(tab, of: controller)
        guard model.returning(tab.id, isHeld: isHeld, isInFront: inFront) else {
            if !model.owns(tab.id) { taken = nil; takenBy = nil }
            return
        }
        taken = nil
        takenBy = nil
        debugLog("autopip: back, the video goes back in its page")
        controller.miniPlayer.cameBack()
    }

    /// The tab is visible in the key window on this desktop, selected or in a split.
    private static func isInFront(_ tab: Tab, of controller: BrowserWindowController) -> Bool {
        guard let window = controller.window, window.isKeyWindow, window.isOnActiveSpace, !window.isMiniaturized,
              let selected = controller.tabManager.selectedTab else { return false }
        return controller.tabManager.panes(of: selected).contains { $0 === tab }
    }
}

/// When a video moves to the mini player on leave and back on return; only videos it moved itself.
nonisolated struct AutoPictureInPictureModel {
    /// Ignores quick switches, system prompts and Mission Control passing through.
    static let delay: TimeInterval = 0.8

    struct Page {
        /// The watched video (`MiniPlayerLayout.followed`), if playing and not in a link.
        var video: PageVideo?
        /// Partly visible in the page.
        var isInView: Bool
        /// Muted from the sidebar.
        var isTabMuted: Bool
        /// The page itself shows it in Picture in Picture or full screen.
        var isPresentingItself: Bool
        var isMiniPlayerBusy: Bool
    }

    /// Where the window is while Zigzag is in the background.
    struct Sight {
        var isHidden: Bool
        var isMinimized: Bool
        /// Visible and at least partly uncovered, on a desktop that's showing.
        var isInView: Bool
        var windowDisplay: UInt32?
        /// The display of the app you switched to.
        var focusDisplay: UInt32?
    }

    /// Hidden, minimized, out of view, or in view only on the display you switched on (#496).
    static func isOutOfSight(_ sight: Sight) -> Bool {
        if sight.isHidden || sight.isMinimized || !sight.isInView { return true }
        guard let window = sight.windowDisplay, let focus = sight.focusDisplay else { return true }
        return window == focus
    }

    struct FrontApp {
        var isZigzag: Bool
        /// A site installed as a web app.
        var isZigzagWebApp: Bool
        /// Has windows and a Dock icon; Spotlight, Notification Center, menu bar items, system prompts and the Dock
        /// don't.
        var isRegular: Bool
    }

    private(set) var owned: UUID?

    func owns(_ tab: UUID) -> Bool { owned == tab }

    /// A regular app in front, not Zigzag or one of its web apps.
    static func isRealSwitch(to app: FrontApp?) -> Bool {
        guard let app else { return false }
        return app.isRegular && !app.isZigzag && !app.isZigzagWebApp
    }

    /// Setting on, a watched video playing in view with sound, not already presented elsewhere, and the mini player
    /// free.
    static func moves(_ page: Page, isOn: Bool) -> Bool {
        guard isOn, let video = page.video, page.isInView, !page.isTabMuted, !page.isPresentingItself, !page.isMiniPlayerBusy else { return false }
        return MiniPlayerLayout.follows(video) && !video.isMuted && !video.blocksPictureInPicture
    }

    /// Whether `page`'s video moves. If so it's owned until you return.
    mutating func leaving(_ id: UUID, page: Page, isOn: Bool) -> Bool {
        guard Self.moves(page, isOn: isOn) else { return false }
        owned = id
        return true
    }

    mutating func forget() { owned = nil }

    /// True when the mini player still has the video and you're back on its tab. Otherwise it keeps playing; if it
    /// left the mini player another way (closed, replaced), nothing to do.
    mutating func returning(_ id: UUID, isHeld: Bool, isInFront: Bool) -> Bool {
        guard owned == id else { return false }
        guard isHeld else { owned = nil; return false }
        guard isInFront else { return false }
        owned = nil
        return true
    }
}
