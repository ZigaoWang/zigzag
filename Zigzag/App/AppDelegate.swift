import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private var launched = false
    private var blockerToken: SignalToken?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A second copy (one opened from the disk image while the installed one runs) would load the same profile
        // and save over it: it hands over to the one already running and goes, before reading anything.
        if !Self.isHostingTests, !SingleCopy.claim() {
            SingleCopy.showRunningCopy()
            exit(0)
        }
        if !Self.isHostingTests {
            // A new version backs up the profile the last one left, and a restore asked for before restarting puts
            // a backup back, both before anything reads it.
            let info = Bundle.main.infoDictionary
            ProfileBackup.backUpIfUpdated(build: info?["CFBundleVersion"] as? String ?? "", version: info?["CFBundleShortVersionString"] as? String ?? "")
            ProfileBackup.restoreIfAsked()
        }
        NSApp.mainMenu = MainMenu.build()
        Shortcuts.apply()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// Unit tests run inside the app; they must never touch the person's windows, session or extensions.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        Tutorial.migrate()
        // Getting started picks up where you left off, if you'd begun and haven't ended it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard !Tutorial.done.isEmpty, WelcomeWindowController.shared == nil,
                  let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
            GuidedTour.start(in: controller)
        }
        _ = Library.shared
        _ = HistoryStore.shared
        // Icons clearing history set aside, if Zigzag didn't get to remove them when it quit.
        try? FileManager.default.removeItem(at: Paths.setAsideIcons)
        ContentBlocker.prepare()
        // A page stuck working hard (an extension in a loop, usually) gets named, with a way out.
        EnergyWatch.shared.start()
        // Crash and freeze reports from macOS, kept here for Help › Report a Problem.
        CrashReports.shared.start()
        // What goes wrong from now on, kept for the same report, and whether the last run ended badly.
        Diagnostics.start()
        // New lists or settings reach open pages on their next load.
        blockerToken = ContentBlocker.changed.observe {
            for tab in WindowManager.shared.controllers.flatMap(\.tabManager.allTabs) {
                if let webView = tab.webView, !Tab.isExtensionPage(tab.url) { ContentBlocker.apply(to: webView, for: tab.url) }
            }
        }
        if #available(macOS 15.4, *) {
            ExtensionStore.setUpIfNeeded()
        }
        // Onboarding not finished: it comes first, instead of the window that was waiting behind it.
        let restored = WindowManager.needsOnboarding ? false : WindowManager.shared.restoreSession()
        // Opened from the disk image or a download macOS keeps apart: offered a move to Applications, so it can update.
        MoveToApplications.offerWhenReady()
        launched = true
        if !pendingURLs.isEmpty {
            if !restored { WindowManager.shared.newWindow(url: pendingURLs.removeFirst(), showCommandBar: false) }
            pendingURLs.forEach { WindowManager.shared.openExternal($0) }
            pendingURLs = []
        } else if !restored {
            WindowManager.shared.newWindow()
        }
        Updater.shared.start()
        // Just updated: what's new comes first, and the default browser offer waits for another launch.
        if !WhatsNew.offerIfUpdated() { offerDefaultBrowserOnce() }
        DockProgress.shared.start()
        DebugBridge.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        // Only minimized: the window comes back (the last one you used first), rather than another opening beside it.
        let windows = ([WindowManager.shared.keyController] + WindowManager.shared.controllers.reversed()).compactMap { $0?.window }
        if let minimized = windows.first(where: \.isMiniaturized) {
            minimized.deminiaturize(nil)
        } else {
            WindowManager.shared.reopen()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Set once quitting is decided (confirmed, or restarting for an update), so it isn't asked twice.
    static var quitConfirmed = false

    /// Asks before quitting, in the window, like Zigzag's other confirmations. Never when the Mac is logging out,
    /// restarting or shutting down, or when an update restarts Zigzag. ⌘Q again, or Return, quits.
    static var asksBeforeQuitting: Bool {
        get { UserDefaults.standard.object(forKey: "AskBeforeQuitting") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "AskBeforeQuitting") }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isHostingTests else { return .terminateNow }
        let downloading = DownloadManager.shared.activeCount
        // Going for good: downloads still coming in pause first, so they go on from Downloads after the next launch.
        func quitNow() -> NSApplication.TerminateReply {
            guard downloading > 0 else { return .terminateNow }
            DownloadManager.shared.pauseAllForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        // Asked already, or not asking: downloads are the one thing worth asking about anyway.
        guard !Self.quitConfirmed, Self.asksBeforeQuitting || downloading > 0 else { return quitNow() }
        // Logging out, restarting or shutting down: the system's own reason is on the quit event.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil { return quitNow() }
        guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first,
              let window = controller.window, window.isVisible, let host = window.contentView else { return quitNow() }
        // Already asking: ⌘Q a second time means yes.
        if host.subviews.contains(where: { $0 is ConfirmSheet }) { return quitNow() }
        window.makeKeyAndOrderFront(nil)
        var answered = false
        var monitor: Any?
        func answer(_ quit: Bool) {
            guard !answered else { return }
            answered = true
            if let monitor { NSEvent.removeMonitor(monitor) }
            guard quit else { NSApp.reply(toApplicationShouldTerminate: false); return }
            Self.quitConfirmed = true
            if downloading > 0 {
                DownloadManager.shared.pauseAllForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
            } else {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        let message = downloading == 0 ? "Your tabs and spaces will be right here when you open it again."
            : downloading == 1 ? "A download is still in progress. It pauses, and you can resume it from Downloads when you open Zigzag again."
            : "\(downloading) downloads are still in progress. They pause, and you can resume them from Downloads when you open Zigzag again."
        ConfirmSheet.show(in: host, title: "Quit Zigzag?", message: message, confirmTitle: "Quit") { answer($0) }
        // While it asks, ⌘Q again means yes (macOS doesn't ask the app a second time on its own).
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "q" else { return event }
            host.subviews.compactMap { $0 as? ConfirmSheet }.forEach { $0.removeFromSuperview() }
            answer(true)
            return nil
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        WindowManager.shared.prepareForTermination()
        // Undo ends with Zigzag, and the icons clearing history set aside for it go now (or at the next start).
        try? FileManager.default.removeItem(at: Paths.setAsideIcons)
        // Password managers' helpers end with Zigzag, so none are left running.
        if #available(macOS 15.4, *) { NativeMessagingHost.terminateAll() }
        // Quit properly: the next launch knows this wasn't a crash.
        Diagnostics.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Opening URLs from elsewhere

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: string),
              // A link another app hands over is a web address: never one of Zigzag's own pages, an extension's, or a file.
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        open(url)
    }

    /// Files opened with Zigzag, and links handed over as a document: web addresses and local files only.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.filter { $0.isFileURL || ["http", "https"].contains($0.scheme?.lowercased() ?? "") }.forEach(open)
    }

    private func open(_ url: URL) {
        guard launched else { pendingURLs.append(url); return }
        WindowManager.shared.openExternal(url)
        NSApp.activate()
    }

    /// Right-click the Dock icon: a new window, or a private one, as every browser offers.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Private Window", action: #selector(newPrivateWindow(_:)), keyEquivalent: "").target = self
        return menu
    }

    /// A page handed off from your iPhone or another Mac opens here, like a link from any app.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        open(url)
        return true
    }

    /// One quiet offer, on the second launch, never repeated: by then you know whether you like it here.
    private func offerDefaultBrowserOnce() {
        let defaults = UserDefaults.standard
        let launches = defaults.integer(forKey: "LaunchCount") + 1
        defaults.set(launches, forKey: "LaunchCount")
        guard launches >= 2, !defaults.bool(forKey: "DefaultBrowserOffered"), !DefaultBrowser.isDefault else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let controller = WindowManager.shared.keyController else { return }
            defaults.set(true, forKey: "DefaultBrowserOffered")
            Toast.show("Open links in Zigzag?", symbol: "safari", action: ("Set as Default", { DefaultBrowser.make() }),
                       duration: 8, in: controller)
        }
    }

    // MARK: App menu actions

    @objc func newWindow(_ sender: Any?) {
        // With every window closed, a new one brings back the one you closed, tabs and all.
        if WindowManager.shared.controllers.contains(where: { !$0.tabManager.isPrivate }) { WindowManager.shared.newWindow() } else { WindowManager.shared.reopen() }
    }
    @objc func newPrivateWindow(_ sender: Any?) { WindowManager.shared.newWindow(isPrivate: true) }

    // With Passwords or Import in front, or no window open, these reach here rather than a browser window: that
    // window comes forward (or the closed one comes back) and does it, instead of the menu item being greyed out.
    @objc func newTab(_ sender: Any?) { frontBrowserWindow()?.commandBar.show(mode: .newTab) }
    @objc func openLocation(_ sender: Any?) { frontBrowserWindow()?.commandBar.show(mode: .editCurrent) }
    @objc func reopenClosedWindow(_ sender: Any?) { WindowManager.shared.reopenClosedWindow() }
    /// With no window open, the tab went with its window: that comes back instead.
    @objc func reopenClosedTab(_ sender: Any?) {
        if WindowManager.shared.controllers.isEmpty { WindowManager.shared.reopenClosedWindow() } else { frontBrowserWindow()?.tabManager.reopenClosedTab() }
    }
    @objc func showHistory(_ sender: Any?) { frontBrowserWindow().map(HistoryPage.open) }

    @objc func sendFeedback(_ sender: Any?) { frontBrowserWindow().map(Feedback.show) }
    @objc func reportProblem(_ sender: Any?) { frontBrowserWindow().map(ProblemReport.show) }
    /// Help › Zigzag on GitHub: the source, issues and releases, opened in a tab here.
    @objc func showSourceCode(_ sender: Any?) {
        if let url = URL(string: "https://github.com/ZigaoWang/zigzag") { WindowManager.shared.openExternal(url) }
    }

    /// ⌘W in a window without tabs (Passwords, Import) closes that window, as on any Mac.
    @objc func closeTab(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    private func frontBrowserWindow() -> BrowserWindowController? {
        if WindowManager.shared.controllers.isEmpty { WindowManager.shared.reopen() }
        // Onboarding in front: the window waits behind it. Left open behind a browser window, it doesn't stop ⌘Y or ⌘,.
        if WelcomeWindowController.shared?.window?.isKeyWindow == true { return nil }
        guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return nil }
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    @objc func showAbout(_ sender: Any?) { AboutWindowController.show() }

    /// Settings opens as a tab in the front window, as History does.
    @objc func showSettings(_ sender: Any?) { frontBrowserWindow().map { SettingsPage.open(in: $0) } }

    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates() }

    @objc func makeDefaultBrowser(_ sender: Any?) { DefaultBrowser.make() }

    @objc func importFromBrowser(_ sender: Any?) { ImportWindowController.show() }

    @objc func showPasswords(_ sender: Any?) { PasswordsWindowController.show() }
}

extension AppDelegate: NSMenuItemValidation {
    /// Reopen Closed Window is dimmed when there's nothing to bring back; Set as Default Browser hides once it is.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reopenClosedWindow(_:)) { return WindowManager.shared.canReopenClosedWindow }
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            let manager = (WindowManager.shared.keyController ?? WindowManager.shared.controllers.first)?.tabManager
            return manager?.canReopenClosedTab ?? WindowManager.shared.canReopenClosedWindow
        }
        // Already your browser: nothing to offer, so it isn't there (as in Safari and Chrome).
        if menuItem.action == #selector(makeDefaultBrowser(_:)) { menuItem.isHidden = DefaultBrowser.isDefault; return true }
        if menuItem.action == #selector(closeTab(_:)) { return NSApp.keyWindow?.styleMask.contains(.closable) ?? false }
        return true
    }
}

/// One Zigzag per profile: a lock on a file beside the profile, held for as long as Zigzag runs. The system lets it
/// go when the process ends, crash or not.
enum SingleCopy {
    private static var lock: Int32 = -1

    static func claim() -> Bool {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let file = Paths.support.appendingPathComponent("Running.lock").path
        lock = open(file, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { return true }
        return flock(lock, LOCK_EX | LOCK_NB) == 0
    }

    /// Brings the copy already running to the front.
    static func showRunningCopy() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        others.first { $0.processIdentifier != me }?.activate()
    }
}
