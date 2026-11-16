import AppKit

/// AI apps working with nothing on screen (#214): in a window of their own that no one sees, on the Headless
/// profile's space, while your windows and tabs are out of their reach. Asked for by opening Zigzag with `--headless`
/// (with nothing else open, Zigzag then runs with no Dock icon, menu bar or window until you open it), or by
/// Settings › Automation › Run AI apps in the background. Only while AI apps may use Zigzag at all: it never turns
/// that on. While it's on, an item in the menu bar says so, with the way to stop them.
@MainActor
enum Headless {
    // MARK: When it's on

    private static let settingKey = "RunsAIAppsInBackground"

    /// Settings › Automation › Run AI apps in the background.
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: settingKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: settingKey)
            // Turned off, it's off: also when this run was asked to with --headless.
            if !newValue { forThisRun = false }
            refresh()
        }
    }

    /// Asked for this run only: opened with `--headless`, or asked since by a copy opened with it.
    private(set) static var forThisRun = false

    /// Asked for, by the setting or for this run: what the switch in Settings shows.
    static var isWanted: Bool { isOn || forThisRun }

    /// Told when AI apps start or stop working in the background, and when Zigzag stops running for them alone.
    static let changed = Signal<Void>()

    /// Whether AI apps work in the background: asked for, and AI apps allowed at all.
    nonisolated static func isActive(isOn: Bool, forThisRun: Bool, accessOn: Bool) -> Bool { accessOn && (isOn || forThisRun) }

    static var isActive: Bool { isActive(isOn: isOn, forThisRun: forThisRun, accessOn: MCPService.isOn) }

    // MARK: Opening Zigzag for it

    nonisolated static let argument = "--headless"

    /// Whether Zigzag was opened for it. The first argument is the app's own path.
    nonisolated static func isAsked(by arguments: [String]) -> Bool { arguments.dropFirst().contains(argument) }

    /// Running for AI apps alone: no Dock icon, no menu bar, no window, until you open Zigzag yourself.
    private(set) static var isBackgroundOnly = false

    /// What waits for Zigzag to be opened by you (updates, the Dock's download progress, the offers made as it opens),
    /// run once when it is.
    static var whenOpened: (() -> Void)?

    /// As Zigzag opens, before anything shows: opened with `--headless`, it runs for AI apps alone. With AI apps not
    /// allowed, there's nothing it could do: it says so and goes.
    static func willLaunch(arguments: [String] = CommandLine.arguments) {
        if isContinued(by: arguments) { goOn() }
        guard isAsked(by: arguments) else { return }
        guard MCPService.isOn else { refuseWithoutAccess() }
        forThisRun = true
        isBackgroundOnly = true
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Over a restart

    /// What Zigzag gives itself when it restarts itself in the middle of a run opened with `--headless` (a restore,
    /// a new language): the run goes on, as the usual Zigzag you had made of it by opening it. Not for anyone
    /// else to pass: `--headless` is.
    nonisolated static let continuesArgument = "--ai-apps-in-background"

    /// The arguments to open Zigzag again with, for the run to go on over a restart of Zigzag's own.
    static var restartArguments: [String] { forThisRun ? [continuesArgument] : [] }

    /// Whether this launch goes on with such a run. The first argument is the app's own path.
    nonisolated static func isContinued(by arguments: [String]) -> Bool { arguments.dropFirst().contains(continuesArgument) }

    /// Restarted in the middle of such a run, by Zigzag itself (`continuesArgument`) or for an update (which notes it,
    /// `UpdateRelaunch.Saved`): AI apps are kept to the background as they were.
    static func goOn() { forThisRun = true }

    /// Opened with `--headless` while AI apps aren't allowed: it says so where whoever ran it reads, and goes with an
    /// error, never as if it had worked.
    private static func refuseWithoutAccess() -> Never {
        FileHandle.standardError.write(Data("Zigzag: AI apps aren’t allowed to use Zigzag. Turn on Settings › Automation › Let AI apps use Zigzag first.\n".utf8))
        NSLog("Zigzag: opened with --headless, but AI apps aren't allowed in Settings › Automation")
        exit(1)
    }

    /// A copy opened with `--headless` while Zigzag already runs: it asks the one running to, and goes. The request
    /// carries nothing: it can only keep AI apps to the background. With AI apps not allowed (the same setting, read
    /// here), nothing is asked: it's refused as it is with Zigzag closed.
    static func askRunningCopy() {
        guard MCPService.isOn else { refuseWithoutAccess() }
        DistributedNotificationCenter.default().postNotificationName(requestName, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// A copy opened the usual way while Zigzag already runs tells the one running, which may run for AI apps
    /// alone, with no icon to click: only being brought forward wouldn't make it yours. It carries nothing either.
    static func tellRunningCopyYouOpened() {
        DistributedNotificationCenter.default().postNotificationName(openedName, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private static func name(_ what: String) -> Notification.Name { .init((Bundle.main.bundleIdentifier ?? "app.zigzag.Zigzag") + "." + what) }
    private static var requestName: Notification.Name { name("headless") }
    private static var openedName: Notification.Name { name("opened") }

    private static var accessToken: SignalToken?
    private static var idleTimer: Timer?

    /// Once Zigzag has opened: listens for copies opened while it runs (with `--headless`, or the usual way),
    /// follows AI apps being allowed or not, and starts if it's asked for.
    static func start() {
        // Delivered while Zigzag isn't the active app too (as DebugBridge's are): that's when it's asked.
        for (selector, name) in [(#selector(Listener.asked(_:)), requestName), (#selector(Listener.opened(_:)), openedName)] {
            DistributedNotificationCenter.default().addObserver(Listener.shared, selector: selector, name: name,
                                                                object: nil, suspensionBehavior: .deliverImmediately)
        }
        accessToken = MCPService.changed.observe { refresh() }
        // Only running for AI apps alone does Zigzag go by itself once they're done.
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

    /// Asked by a copy opened with `--headless`. Not while AI apps aren't allowed: it would only wait, unseen, to
    /// keep them to the background the day they are.
    /// Being asked for is a reason to stay: running for AI apps alone, Zigzag waits again from now.
    static func askedByAnotherCopy(accessOn: Bool? = nil, now: Date = Date()) {
        guard accessOn ?? MCPService.isOn else { return }
        forThisRun = true
        waitingSince = now
        refresh()
    }

    /// You opened Zigzag while it ran for AI apps alone (its icon, or a copy opened the usual way handing over):
    /// it's yours now, your windows with it. False when it was yours already.
    static func openedByYou() -> Bool {
        guard isBackgroundOnly else { return false }
        becomeRegular()
        WindowManager.shared.reopen()
        return true
    }

    /// You opened Zigzag while it ran for AI apps alone: it becomes the Zigzag you know, with its Dock icon, menus
    /// and your windows, and what waited for that starts.
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

    /// After anything that may start or stop it: the menu bar item comes or goes, and the window AI apps work in
    /// closes when they can't any more. Running for them alone, Zigzag then has nothing to stay for.
    static func refresh() {
        if !isActive {
            closeWindow()
            if isBackgroundOnly { quit() }
        }
        refreshStatusItem()
        changed.send()
    }

    /// The menu bar item is there exactly while something of theirs runs unseen: their window is open, or Zigzag
    /// runs for them alone. Never in a test run.
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
        // Its space removed, or put on another profile: the window isn't theirs to work in any more, and closes. The
        // next time one needs it, it's made again, with its space.
        libraryToken = Library.shared.changed.observe {
            guard let controller else { return }
            // A removed space is still noted as its profile's (for undo), so whether it's there is asked too.
            let space = controller.tabManager.currentSpaceID
            if Library.shared.space(space) == nil || Library.shared.profileID(ofSpace: space) != heldProfile { closeWindow() }
        }
        park(made)
        refreshStatusItem()
        changed.send()
        return made
    }

    /// Whether macOS is kept from napping Zigzag, for their pages' sake.
    static var holdsOffAppNap: Bool { activity != nil }

    /// Their pages keep running as if seen while an AI app is using one (`AgentControl`: until a while after its last
    /// tool): macOS would otherwise nap an app with no window on screen. Not for as long as the window is open: left
    /// alone, it costs what any window of sleeping tabs does.
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

    /// A tab AI apps may use while they work in the background: one of their window's, on the Headless profile.
    static func owns(_ tab: Tab) -> Bool {
        guard let controller, tab.profile.isHeadless else { return false }
        return controller.tabManager.allTabs.contains { $0 === tab }
    }

    /// Out of sight, as the extensions' hidden pages are (BridgeOffscreen): far off the screen, clear, and passed over
    /// by the mouse, Mission Control and ⌘`. It still counts as shown, so its pages run and draw as if seen.
    static func park(_ controller: BrowserWindowController) {
        guard let window = controller.window as? BrowserWindow else { return }
        window.isParked = true
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone, .stationary]
        window.setFrame(NSRect(origin: parkedOrigin, size: parkedSize), display: false)
        window.orderBack(nil)
    }

    static let parkedOrigin = NSPoint(x: -20000, y: -20000)
    static let parkedSize = NSSize(width: 1280, height: 800)

    // MARK: Leaving

    /// Since when Zigzag has waited, running for AI apps alone: from when it opened or was last asked for, until an
    /// app has asked it something.
    private(set) static var waitingSince = Date()

    /// How long Zigzag stays, running for AI apps alone, after one last asked it anything. Long enough for an app
    /// that thinks for a while between two steps.
    static var idleQuitAfter: TimeInterval {
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["ZIGZAG_HEADLESS_IDLE"].flatMap(TimeInterval.init) { return seconds }
        #endif
        return 30 * 60
    }

    /// Whether Zigzag, running for AI apps alone, has nothing left to stay for: none has asked it anything for long
    /// enough (`last`: their last request of any kind, MCPEndpoint), and nothing is still downloading.
    nonisolated static func isIdle(since last: Date, downloads: Int = 0, now: Date, after wait: TimeInterval) -> Bool {
        downloads == 0 && now.timeIntervalSince(last) >= wait
    }

    /// What it has last been needed for: an app's request, or being asked to wait for one, whichever is later.
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

    // MARK: The menu bar item

    /// While AI apps work in the background, the one place that shows it, and the way to stop them.
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
            let stop = NSMenuItem(title: String(localized: "Stop AI Apps", comment: "Menu bar item's menu while AI apps use Zigzag in the background: cuts every AI app off, as Stop on a tab's bar does."),
                                  action: #selector(Actions.stop(_:)), keyEquivalent: "")
            stop.target = Actions.shared
            menu.addItem(stop)
            // Running for AI apps alone, nothing else quits it: no Dock icon, no menu bar of its own.
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
        @objc func stop(_ sender: Any?) { MainActor.assumeIsolated { MCPService.stopAccess() } }
        @objc func quit(_ sender: Any?) { MainActor.assumeIsolated { Headless.quit() } }
    }
}
