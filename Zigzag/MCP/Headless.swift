import AppKit
import WebKit

/// Headless mode (#214): AI apps work in an unseen window of their own, on the AI Apps profile.
@MainActor
enum Headless {
    // MARK: When it's on

    private static let settingKey = "RunsAIAppsInBackground"

    /// Settings › Automation › Run AI apps in the background.
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: settingKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: settingKey)
            refresh()
        }
    }

    /// Sent when headless mode starts or stops, and when Zigzag stops running for AI apps alone.
    static let changed = Signal<Void>()

    /// Both switches on: AI apps may use Zigzag, and in the background.
    nonisolated static func isActive(isOn: Bool, accessOn: Bool) -> Bool { accessOn && isOn }

    static var isActive: Bool { isActive(isOn: isOn, accessOn: MCPService.isOn) }

    // MARK: Opening Zigzag for it

    nonisolated static let argument = "--headless"

    /// Whether Zigzag was opened for it. The first argument is the app's own path.
    nonisolated static func isAsked(by arguments: [String]) -> Bool { arguments.dropFirst().contains(argument) }

    /// Running for AI apps alone: no Dock icon, menu bar or window until you open Zigzag.
    private(set) static var isBackgroundOnly = false

    /// Work deferred until you open Zigzag (updates, Dock download progress, launch offers). Runs once.
    static var whenOpened: (() -> Void)?

    /// With `--headless`: runs for AI apps alone, or exits while headless mode is off.
    static func willLaunch(arguments: [String] = CommandLine.arguments) {
        guard isAsked(by: arguments) else { return }
        guard isActive else { refuseWhileOff() }
        isBackgroundOnly = true
        NSApp.setActivationPolicy(.accessory)
    }

    /// `--headless` with either switch off: says so on stderr and exits with an error.
    private static func refuseWhileOff() -> Never {
        FileHandle.standardError.write(Data("Zigzag: turn on Let AI apps use Zigzag and Run AI apps in the background in Settings › Automation first.\n".utf8))
        NSLog("Zigzag: opened with --headless, but AI apps in the background are off in Settings › Automation")
        exit(1)
    }

    /// `--headless` while Zigzag runs: asks the running copy, which only restarts its idle wait.
    static func askRunningCopy() {
        guard isActive else { refuseWhileOff() }
        DistributedNotificationCenter.default().postNotificationName(requestName, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// A copy opened the usual way tells the running one, which may be running for AI apps alone with no icon to
    /// click: activating it alone wouldn't make it yours. Carries no data.
    static func tellRunningCopyYouOpened() {
        DistributedNotificationCenter.default().postNotificationName(openedName, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private static func name(_ what: String) -> Notification.Name { .init((Bundle.main.bundleIdentifier ?? "app.zigzag.Zigzag") + "." + what) }
    private static var requestName: Notification.Name { name("headless") }
    private static var openedName: Notification.Name { name("opened") }

    private static var accessToken: SignalToken?
    private static var idleTimer: Timer?

    /// After launch: listens for other copies (`--headless` or usual), follows the AI apps setting, and starts if on.
    static func start() {
        // Delivered while Zigzag is inactive too (as DebugBridge's are): that's when requests come.
        for (selector, name) in [(#selector(Listener.asked(_:)), requestName), (#selector(Listener.opened(_:)), openedName)] {
            DistributedNotificationCenter.default().addObserver(Listener.shared, selector: selector, name: name,
                                                                object: nil, suspensionBehavior: .deliverImmediately)
        }
        accessToken = MCPService.changed.observe { refresh() }
        // Zigzag quits by itself when idle only while running for AI apps alone.
        if isBackgroundOnly {
            waitingSince = Date()
            idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { quitIfIdle() } }
            idleTimer?.tolerance = 10
        }
        refresh()
    }

    private final class Listener: NSObject {
        static let shared = Listener()
        @objc func asked(_ note: Notification) {
            DispatchQueue.main.async { MainActor.assumeIsolated { Headless.askedByAnotherCopy() } }
        }
        @objc func opened(_ note: Notification) {
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = Headless.openedByYou() } }
        }
    }

    /// A copy opened with `--headless` asked: the idle wait starts over. Ignored while headless mode is off.
    static func askedByAnotherCopy(active: Bool? = nil, now: Date = Date()) {
        guard active ?? isActive else { return }
        waitingSince = now
        refresh()
    }

    /// You opened Zigzag (its icon, or a copy opened the usual way) while it ran for AI apps alone: it becomes yours,
    /// with your windows. False when it already was.
    static func openedByYou() -> Bool {
        guard isBackgroundOnly else { return false }
        becomeRegular()
        WindowManager.shared.reopen()
        return true
    }

    /// Turns a run for AI apps alone into the regular app (Dock icon, menus), and runs `whenOpened`.
    static func becomeRegular() {
        guard isBackgroundOnly else { return }
        isBackgroundOnly = false
        idleTimer?.invalidate()
        idleTimer = nil
        NSApp.setActivationPolicy(.regular)
        let waiting = whenOpened
        whenOpened = nil
        waiting?()
        refreshStatusItem()
        changed.send()
        NSApp.activate()
    }

    /// After anything that may start or stop it: updates the menu bar item, and closes the AI apps' window once they
    /// can't use it. Zigzag then quits if it ran for them alone.
    static func refresh() {
        if !isActive {
            closeWindow()
            if isBackgroundOnly { quit() }
        }
        refreshStatusItem()
        changed.send()
    }

    /// The menu bar item shows exactly while their window is open or Zigzag runs for them alone. Never in a test run.
    private static func refreshStatusItem() {
        guard !AppDelegate.isHostingTests else { return }
        if isBackgroundOnly || controller != nil { StatusItem.show() } else { StatusItem.hide() }
        StatusItem.refresh()
    }

    // MARK: Their window

    private static var controller: BrowserWindowController?
    private static var heldProfile: UUID?
    private static var activity: NSObjectProtocol?
    private static var libraryToken: SignalToken?
    private static var useToken: SignalToken?

    /// The window AI apps work in, while it's open.
    static var window: BrowserWindowController? { controller }

    /// The window AI apps work in, as it is, or made on first need on the AI Apps profile's space (with the profile
    /// and its space if missing: `Library.headlessSpace`). Open, it's left on the space it shows: one of theirs
    /// (`TabManager.keepsTo`), and closed if that space goes.
    static func openWindow() -> BrowserWindowController {
        if let controller { return controller }
        let space = Library.shared.headlessSpace()
        let made = WindowManager.shared.makeHeadless(spaceID: space.id)
        made.onClose = { closed in if controller === closed { windowClosed() } }
        controller = made
        // Not removed while AI apps work in it: their tabs would land in your first profile.
        let profile = Library.shared.profileID(ofSpace: space.id)
        if Profiles.shared.hold(profile) { heldProfile = profile }
        // Its pages keep running as if seen while an app is at work in them (`refreshActivity`).
        useToken = AgentControl.shared.changed.observe { refreshActivity() }
        // Closes the window once its space is removed or moved to another profile. The next need makes it again.
        libraryToken = Library.shared.changed.observe {
            guard let controller else { return }
            // A removed space keeps its profile (for undo), so its existence is checked too.
            let space = controller.tabManager.currentSpaceID
            if Library.shared.space(space) == nil || Library.shared.profileID(ofSpace: space) != heldProfile { closeWindow() }
        }
        park(made)
        refreshStatusItem()
        changed.send()
        return made
    }

    /// Show AI Apps Window: brings their window on screen (making it if needed) to watch them work, with the same tabs
    /// and refs. Zigzag becomes a regular app. Your own windows open when you ask.
    static func showWindow() {
        guard isActive else { return }
        let controller = openWindow()
        becomeRegular()
        unpark(controller)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Toast.show(String(localized: "AI apps are using this window. Closing it hides it again while they work.", comment: "Toast in the window AI apps use in the background, when you show it (Show AI Apps Window)."),
                   symbol: "sparkles", duration: 6, in: controller)
    }

    /// Back on screen as a browser window is, in the middle of the screen.
    static func unpark(_ controller: BrowserWindowController) {
        guard let window = controller.window as? BrowserWindow, window.isParked else { return }
        window.isParked = false
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.isExcludedFromWindowsMenu = false
        window.hasShadow = true
        // For watching only: no full screen, no Dock. Minimized, it would stop counting as on screen, and pages
        // couldn't be captured.
        window.collectionBehavior = [.fullScreenNone]
        window.styleMask.remove(.miniaturizable)
        window.setFrame(BrowserWindowController.defaultFrame(), display: true)
        // Wakes the front tab if it slept, as selecting a tab in any window does.
        let manager = controller.tabManager
        manager.selectedTab.map { manager.panes(of: $0) }?.forEach { _ = $0.ensureWebView() }
    }

    /// Closing their window while they work hides it again, so their tabs stay. False when it may close.
    static func parksInsteadOfClosing(_ controller: BrowserWindowController) -> Bool {
        guard controller === self.controller, isActive else { return false }
        park(controller)
        return true
    }

    /// Whether macOS is kept from napping Zigzag, for their pages' sake.
    static var holdsOffAppNap: Bool { activity != nil }

    /// Keeps their pages running while an AI app uses one (`AgentControl`: until a while after its last tool), since
    /// macOS naps an app with no window on screen. Not held whenever the window is open: idle, it costs what any window
    /// of sleeping tabs does.
    private static func refreshActivity() {
        let atWork = controller?.tabManager.allTabs.contains { AgentControl.shared.isUsing($0.id) } ?? false
        if atWork, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "AI apps are working in the background")
        } else if !atWork, let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
    }

    /// Closes the window AI apps work in, with its tabs. The AI Apps profile and its space stay.
    static func closeWindow() {
        controller?.window?.close()
    }

    private static func windowClosed() {
        guard let closed = controller else { return }
        controller = nil
        closed.tabManager.invalidate()
        if let heldProfile { Profiles.shared.done(heldProfile) }
        heldProfile = nil
        useToken?.cancel()
        useToken = nil
        refreshActivity()
        libraryToken?.cancel()
        libraryToken = nil
        refreshStatusItem()
        changed.send()
    }

    /// Whether AI apps may use the tab in headless mode: one in their window, on the AI Apps profile.
    static func owns(_ tab: Tab) -> Bool {
        guard let controller, tab.profile.isHeadless else { return false }
        return controller.tabManager.allTabs.contains { $0 === tab }
    }

    /// Hides the window as extensions' hidden pages are (BridgeOffscreen): far off screen, clear, and skipped by the
    /// mouse, Mission Control and ⌘`. It still counts as shown, so its pages run and draw.
    static func park(_ controller: BrowserWindowController) {
        guard let window = controller.window as? BrowserWindow else { return }
        // Ordered out first when key or main, so keyboard focus moves to your next window instead of staying unseen.
        if window.isKeyWindow || window.isMainWindow { window.orderOut(nil) }
        window.isParked = true
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone, .stationary]
        window.setFrame(NSRect(origin: parkedOrigin, size: parkedSize), display: false)
        window.orderBack(nil)
    }

    /// Where it's offered: the menu bar item, the Window menu and the command bar.
    static var showTitle: String {
        String(localized: "Show AI Apps Window", comment: "Menu item and command bar command: brings the window AI apps use in the background on screen, to watch them work. AI Apps is the name of their profile.")
    }

    static let parkedOrigin = NSPoint(x: -20000, y: -20000)
    static let parkedSize = NSSize(width: 1280, height: 800)

    // MARK: Leaving

    /// Start of the idle wait when running for AI apps alone: launch, or the last `--headless` request.
    private(set) static var waitingSince = Date()

    /// How long Zigzag, running for AI apps alone, stays after their last request. Long enough for an app that thinks
    /// a while between steps.
    static var idleQuitAfter: TimeInterval {
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["ZIGZAG_HEADLESS_IDLE"].flatMap(TimeInterval.init) { return seconds }
        #endif
        return 30 * 60
    }

    /// Whether Zigzag, running for AI apps alone, may quit: no request for long enough (`last`: their last request of
    /// any kind, MCPEndpoint) and no active download.
    nonisolated static func isIdle(since last: Date, downloads: Int = 0, now: Date, after wait: TimeInterval) -> Bool {
        downloads == 0 && now.timeIntervalSince(last) >= wait
    }

    /// When it was last needed: an app's request or the start of the wait, whichever is later.
    nonisolated static func lastNeeded(request: Date?, waitingSince: Date) -> Date { max(request ?? waitingSince, waitingSince) }

    private static func quitIfIdle() {
        let last = lastNeeded(request: MCPService.lastRequest, waitingSince: waitingSince)
        guard isBackgroundOnly, isIdle(since: last, downloads: DownloadManager.shared.activeCount, now: Date(), after: idleQuitAfter) else { return }
        quit()
    }

    private static func quit() {
        AppDelegate.quitConfirmed = true
        NSApp.terminate(nil)
    }

    // MARK: Their pages

    /// No WebKit full screen and no clipboard writes for their pages: an app's clicks count as yours to WebKit.
    static func prepare(_ configuration: WKWebViewConfiguration) {
        configuration.preferences.isElementFullscreenEnabled = false
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { ($0.source as NSString).hasPrefix(clipboardMarker) }) else { return }
        controller.addUserScript(WKUserScript(source: clipboardMarker + "\n" + clipboardScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
    }

    private static let clipboardMarker = "/* zigzag ai apps clipboard */"

    /// Copy and cut from script, and the async Clipboard API's writes, are refused. Your own ⌘C still copies.
    static let clipboardScript = #"""
    (() => {
      const refused = () => Promise.reject(new DOMException('Write permission denied.', 'NotAllowedError'));
      const lock = (o, n, value) => { try { Object.defineProperty(o, n, { value, writable: false, configurable: false }); } catch (e) {} };
      const C = window.Clipboard && Clipboard.prototype;
      if (C) for (const n of ['write', 'writeText']) if (n in C) lock(C, n, refused);
      const exec = Document.prototype.execCommand;
      if (exec) lock(Document.prototype, 'execCommand', function (command, ...rest) {
        if (/^\s*(copy|cut)\s*$/i.test(String(command))) return false;
        return exec.call(this, command, ...rest);
      });
    })();
    """#

    // MARK: The menu bar item

    /// The one sign that AI apps work in the background, with the way to stop them.
    private enum StatusItem {
        private static var item: NSStatusItem?

        static func show() {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let title = String(localized: "Zigzag: AI apps in the background", comment: "Tooltip and VoiceOver name of the menu bar item shown while AI apps use Zigzag in the background.")
            item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: title)
            item.button?.toolTip = title
            self.item = item
            refresh()
        }

        static func hide() {
            guard let item else { return }
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }

        static func refresh() {
            guard let item else { return }
            let menu = NSMenu()
            menu.addItem(.sectionHeader(title: String(localized: "AI Apps in the Background", comment: "Heading of the menu bar item's menu while AI apps use Zigzag in the background.")))
            let show = NSMenuItem(title: Headless.showTitle, action: #selector(Actions.show(_:)), keyEquivalent: "")
            show.target = Actions.shared
            menu.addItem(show)
            let stop = NSMenuItem(title: String(localized: "Stop AI Apps", comment: "Menu bar item's menu while AI apps use Zigzag in the background: cuts every AI app off, as Stop on a tab's bar does."),
                                  action: #selector(Actions.stop(_:)), keyEquivalent: "")
            stop.target = Actions.shared
            menu.addItem(stop)
            // Running for AI apps alone, there is no Dock icon or menu bar to quit from.
            if isBackgroundOnly {
                let quit = NSMenuItem(title: String(localized: "Quit Zigzag", comment: "Zigzag menu item."), action: #selector(Actions.quit(_:)), keyEquivalent: "")
                quit.target = Actions.shared
                menu.addItem(quit)
            }
            item.menu = menu
        }
    }

    private final class Actions: NSObject {
        static let shared = Actions()
        @objc func show(_ sender: Any?) { MainActor.assumeIsolated { Headless.showWindow() } }
        @objc func stop(_ sender: Any?) { MainActor.assumeIsolated { MCPService.stopAccess() } }
        @objc func quit(_ sender: Any?) { MainActor.assumeIsolated { Headless.quit() } }
    }
}
