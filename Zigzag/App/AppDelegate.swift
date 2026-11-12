import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    /// Sites installed as apps asked for before launch finished (one opened with Zigzag not running).
    private var pendingWebApps: [URL] = []
    private var launched = false
    private var blockerToken: SignalToken?
    private var extensionsToken: SignalToken?

    /// What you type into a web page stays as you typed it, as in Chrome and Safari: WebKit would otherwise follow
    /// the Mac's text substitutions, turning `--` into `—` (breaking GitHub's `<!-- Uploading … -->` placeholders
    /// and every pasted command) and straight quotes into curly ones. Your own Text Replacements (System Settings ›
    /// Keyboard) do apply, as in Safari: they only ever change a shortcut you set up yourself. Edit › Substitutions
    /// turns each on or off.
    static let pageTextDefaults: [String: Any] = [
        "WebAutomaticDashSubstitutionEnabled": false,
        "WebAutomaticQuoteSubstitutionEnabled": false,
        "WebAutomaticTextReplacementEnabled": true,
    ]

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: Self.pageTextDefaults)
        // A second copy (one opened from the disk image while the installed one runs) would load the same data
        // and save over it: it hands over to the one already running and goes, before reading anything.
        if !Self.isHostingTests, !SingleCopy.claim() {
            SingleCopy.showRunningCopy()
            exit(0)
        }
        if !Self.isHostingTests {
            // A new version backs up the data the last one left, and a restore asked for before restarting puts
            // a backup back, both before anything reads it.
            // A new version owes its notes: noted before the backup records this version as the one that ran.
            WhatsNew.noteLaunch()
            let info = Bundle.main.infoDictionary
            UpdateBackup.backUpIfUpdated(build: info?["CFBundleVersion"] as? String ?? "", version: info?["CFBundleShortVersionString"] as? String ?? "")
            UpdateBackup.restoreIfAsked()
            // Site permissions kept by host alone become per origin before any page can ask.
            SitePermissions.migrateHostOnlyAnswers()
            // Extensions' service worker backgrounds start afresh, as in Chrome, before WebKit reads their registrations:
            // in every profile's store, each before WebKit has opened it. Off the main thread, while launch goes on; a
            // store waits for it as it's first made (Profile.store).
            let stores = [ExtensionStore.defaultWebsiteData]
                + Library.shared.profiles.filter { !$0.isDefault }.map { ExtensionStore.websiteData(ofStore: $0.id) }
            ExtensionStore.forgetServiceWorkerRegistrationsInBackground(in: stores)
            Library.shared.pruneProfileAssignments()
            Profiles.finishRemovals()
        }
        NSApp.mainMenu = MainMenu.build()
        Shortcuts.apply()
        // An installed app's window in front gets the app's own menus.
        WebAppMenuBar.start()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// Unit tests run inside the app; they must never touch the person's windows, session or extensions.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        settleSpaceNameStyle()
        Tutorial.migrate()
        // Getting started picks up where you left off, if you'd begun and haven't ended it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard !Tutorial.done.isEmpty, WelcomeWindowController.shared == nil,
                  let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
            GuidedTour.start(in: controller)
        }
        _ = Library.shared
        _ = Profiles.shared.default.history
        // Icons clearing history set aside, if Zigzag didn't get to remove them when it quit.
        try? FileManager.default.removeItem(at: Paths.setAsideIcons)
        // Copies an import read through, if Zigzag stopped before removing them: they can hold passwords.
        DispatchQueue.global(qos: .utility).async { ImportScratch.removeLeftovers() }
        ContentBlocker.prepare()
        // A page stuck working hard (an extension in a loop, usually) gets named, with a way out.
        EnergyWatch.shared.start()
        // macOS saying memory is short: background tabs sleep sooner, Zigzag's pick rather than macOS's.
        MemoryPressure.shared.start()
        // Crash and freeze reports from macOS, kept here for Help › Report a Problem.
        CrashReports.shared.start()
        // What goes wrong from now on, kept for the same report, and whether the last run ended badly.
        Diagnostics.start()
        // HTTP/3 kept from another network can go around a VPN or proxy: forgotten now and whenever the network changes.
        NetworkChanges.start()
        // The app you were in, for Zigzag Mini to go back to.
        AppSwitching.start()
        // New lists or settings reach open pages on their next load.
        blockerToken = ContentBlocker.changed.observe {
            for tab in WindowManager.shared.controllers.flatMap(\.tabManager.allTabs) {
                if let webView = tab.webView, !Tab.isExtensionPage(tab.url) { ContentBlocker.apply(to: webView, for: tab.url) }
            }
        }
        if #available(macOS 15.4, *) {
            // An ad blocker extension turned on or off, or let onto YouTube or not: open pages follow on their next load.
            extensionsToken = ExtensionCenter.changed.observe {
                for tab in WindowManager.shared.controllers.flatMap(\.tabManager.allTabs) {
                    if let webView = tab.webView, !Tab.isExtensionPage(tab.url) { ContentBlocker.applyFilters(to: webView, for: tab.url) }
                }
            }
            ExtensionStore.setUpIfNeeded()
        }
        // Onboarding not finished: it comes first, instead of the window that was waiting behind it. Opened for links that
        // all go to Zigzag Mini, only Zigzag Mini comes up, as Little Arc does; the windows come back when you ask.
        let miniOnly = !pendingURLs.isEmpty && !WindowManager.needsOnboarding && pendingURLs.allSatisfy(WindowManager.shared.opensInMini)
        // Opened by a site installed as an app: only its window comes up, as Chrome's apps do; the browser windows
        // wait until you ask for them.
        let webAppOnly = pendingURLs.isEmpty && !pendingWebApps.isEmpty && !WindowManager.needsOnboarding
        // Restarted for an update: exactly what was open comes back, Zigzag Mini windows too.
        let relaunch = UpdateRelaunch.take()
        let plan = UpdateRelaunch.plan(relaunch: relaunch, now: Date(), needsOnboarding: WindowManager.needsOnboarding,
                                       miniOnly: miniOnly, webAppOnly: webAppOnly)
        WindowManager.shared.sessionWaiting = plan.sessionWaiting
        let restored = plan.restoresSession ? WindowManager.shared.restoreSession() : false
        if plan.restoresMinis { relaunch?.minis.forEach { MiniWindowController.reopen($0) } }
        // Opened from the disk image or a download macOS keeps apart: offered a move to Applications, so it can update.
        MoveToApplications.offerWhenReady()
        launched = true
        if !pendingURLs.isEmpty {
            // A link for Zigzag Mini opens just that, as it would with Zigzag already running.
            if !restored, !WindowManager.shared.opensInMini(pendingURLs[0]) {
                WindowManager.shared.newWindow(url: pendingURLs.removeFirst(), showCommandBar: false)
            }
            pendingURLs.forEach { WindowManager.shared.openExternal($0) }
            pendingURLs = []
        } else if !restored, !plan.sessionWaiting {
            WindowManager.shared.newWindow()
        }
        pendingWebApps.forEach { WebAppStore.handle($0) }
        pendingWebApps = []
        Updater.shared.start()
        // Just updated: what's new comes first, and the default browser offer waits for another launch. Profiles
        // that couldn't be read come before either: what's new waits a launch.
        if Library.shared.profilesWereSetAside { tellProfilesSetAside() } else if !WhatsNew.offerIfUpdated() { offerDefaultBrowserOnce() }
        DockProgress.shared.start()
        Tokens.Contrast.start()
        DebugBridge.start()
        // Only if you turned it on in Settings: otherwise nothing listens.
        MCPService.startIfOn()
    }

    func applicationWillBecomeActive(_ notification: Notification) { MiniLinkWake.appWillActivate() }
    func applicationDidResignActive(_ notification: Notification) { MiniLinkWake.appDidResign() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Only a Zigzag Mini up counts as no window: the Dock icon brings the browser back.
        let browsing = WindowManager.shared.controllers.contains { $0.window?.isVisible == true }
        guard !flag || !browsing else { return true }
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
        let message = downloading == 0
            ? String(localized: "Your tabs and spaces will be right here when you open it again.",
                     comment: "Message of the sheet that asks before quitting; “it” is Zigzag.")
            : String(localized: "\(downloading) downloads are still in progress. They pause, and you can resume them from Downloads when you open Zigzag again.",
                     comment: "Message of the sheet that asks before quitting while files download.")
        ConfirmSheet.show(in: host, title: String(localized: "Quit Zigzag?", comment: "Title of the sheet that asks before quitting."), message: message,
                          confirmTitle: String(localized: "Quit", comment: "Button of the sheet that asks before quitting.")) { answer($0) }
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
        // What's still being written goes to disk before Zigzag ends.
        TabArchive.flush()
        HistoryStore.finishWriting()
        FaviconStore.finishWriting()
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
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        // A site installed as an app, opened or quit (only its small app sends these).
        if let link = URL(string: string), WebAppLink.parse(link) != nil {
            let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
            if launched { WebAppStore.handle(link, from: sender) } else { pendingWebApps.append(link) }
            return
        }
        // A link another app hands over (or a script's `open location`) is a web address: never one of Zigzag's own
        // pages, an extension's, or a file.
        guard let url = Scripting.webAddress(string) else { return }
        // Zigzag handing a link to macOS (as the default browser) gets it straight back: that's a link from inside
        // Zigzag, so it opens in a tab here, not in Zigzag Mini as one from another app would.
        if launched, Self.isFromZigzag(event) { WindowManager.shared.openFromZigzag(url); return }
        open(url)
    }

    /// Whether the app that sent this event is Zigzag itself.
    static func isFromZigzag(_ event: NSAppleEventDescriptor) -> Bool {
        isZigzag(senderPID: event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value)
    }

    /// An event macOS delivers says which process sent it; one without a sender is never taken for Zigzag's own.
    static func isZigzag(senderPID: Int32?) -> Bool {
        senderPID == ProcessInfo.processInfo.processIdentifier
    }

    /// Files opened with Zigzag, and links handed over as a document: web addresses and local files only.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.filter { $0.isFileURL || ["http", "https"].contains($0.scheme?.lowercased() ?? "") }.forEach(open)
    }

    private func open(_ url: URL) {
        guard launched else { pendingURLs.append(url); return }
        // Zigzag Mini comes forward on its own, as Little Arc does: activating the whole app would bring every browser
        // window up behind it.
        let mini = WindowManager.shared.opensInMini(url)
        WindowManager.shared.openExternal(url)
        if !mini { NSApp.activate() }
    }

    /// Right-click the Dock icon: a new window, or a private one, as every browser offers.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "New Window", comment: "Item in the Dock icon's menu."), action: #selector(newWindow(_:)),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "New Private Window", comment: "Item in the Dock icon's menu."), action: #selector(newPrivateWindow(_:)),
                     keyEquivalent: "").target = self
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

    /// Space names start small, a plain heading most people coming from Arc read at a glance; large and light is one
    /// right-click away. Someone who used Zigzag before small became the start keeps the large names they had.
    private func settleSpaceNameStyle() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "LargeSpaceNames") == nil else { return }
        defaults.set(defaults.integer(forKey: "LaunchCount") > 0, forKey: "LargeSpaceNames")
    }

    /// Profiles.json couldn't be read and was set aside: said once, so spaces turning up on Default isn't a mystery.
    /// Settings › Profiles lists the data the other profiles left, to keep or erase.
    private func tellProfilesSetAside() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
            Toast.show(String(localized: "Zigzag couldn’t read your profiles, so every space is on Default for now. The file was kept.", comment: "Toast at launch when the file listing the profiles couldn't be read and was set aside. Default is the first profile's name."),
                       symbol: "exclamationmark.triangle",
                       action: (String(localized: "Show Profiles", comment: "Button in the toast saying the profiles couldn't be read: opens Settings › Profiles."),
                                { [weak controller] in controller.map { SettingsPage.open(.profiles, in: $0) } }),
                       duration: 12, closes: true, in: controller)
        }
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
            Toast.show(String(localized: "Open links in Zigzag?", comment: "Toast offering to make Zigzag the default browser."), symbol: "safari",
                       action: (String(localized: "Set as Default", comment: "Button in the toast offering to make Zigzag the default browser."),
                                { DefaultBrowser.make() }),
                       duration: 8, closes: true, in: controller)
        }
    }

    // MARK: App menu actions

    @objc func newWindow(_ sender: Any?) {
        // With every window closed, a new one brings back the one you closed, tabs and all.
        if WindowManager.shared.controllers.contains(where: { !$0.tabManager.isPrivate }) { WindowManager.shared.newWindow() } else { WindowManager.shared.reopen() }
    }
    @objc func newPrivateWindow(_ sender: Any?) { WindowManager.shared.newWindow(isPrivate: true) }
    /// The command bar on its own, for a quick look in Zigzag Mini that needn't become a tab. Again, it goes.
    @objc func newMiniWindow(_ sender: Any?) { MiniQuickOpen.toggle() }

    // With Passwords or Import in front, or no window open, these reach here rather than a browser window: that
    // window comes forward (or the closed one comes back) and does it, instead of the menu item being greyed out.
    @objc func newTab(_ sender: Any?) { frontBrowserWindow()?.commandBar.show(mode: .newTab) }
    @objc func openLocation(_ sender: Any?) { frontBrowserWindow()?.commandBar.show(mode: .editCurrent) }
    @objc func openDocument(_ sender: Any?) { frontBrowserWindow()?.openDocument(sender) }
    @objc func reopenClosedWindow(_ sender: Any?) { WindowManager.shared.reopenClosedWindow() }
    /// With no window open, the tab went with its window: that comes back instead.
    @objc func reopenClosedTab(_ sender: Any?) {
        if WindowManager.shared.controllers.isEmpty { WindowManager.shared.reopenClosedWindow() } else { frontBrowserWindow()?.tabManager.reopenClosedTab() }
    }
    @objc func showHistory(_ sender: Any?) { frontBrowserWindow().map(HistoryPage.open) }
    /// From Zigzag Mini or with no window open too: in the browser window, which comes forward.
    @objc func showWhatsNew(_ sender: Any?) { frontBrowserWindow().map { WhatsNew.show(in: $0) } }

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
    /// Help › Keyboard Shortcuts: every shortcut, where you can change them.
    @objc func showKeyboardShortcuts(_ sender: Any?) { frontBrowserWindow().map { SettingsPage.open(.shortcuts, in: $0) } }

    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates() }

    @objc func makeDefaultBrowser(_ sender: Any?) { DefaultBrowser.make() }

    @objc func importFromBrowser(_ sender: Any?) { ImportWindowController.show() }

    @objc func showPasswords(_ sender: Any?) { PasswordsWindowController.show() }

    /// Window › Keep on Top, for the window in front.
    @objc func toggleKeepOnTop(_ sender: Any?) {
        guard let window = KeepOnTop.frontWindow, KeepOnTop.applies(to: window) else { return }
        KeepOnTop.toggle(window)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Reopen Closed Window is dimmed when there's nothing to bring back; Set as Default Browser hides once it is.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reopenClosedWindow(_:)) { return WindowManager.shared.canReopenClosedWindow }
        // Zigzag Mini names it Open in Zigzag while it's in front; anywhere else it's itself again.
        if menuItem.action == #selector(openDocument(_:)) { menuItem.title = BrowserWindowController.openFileTitle }
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            let manager = (WindowManager.shared.keyController ?? WindowManager.shared.controllers.first)?.tabManager
            return manager?.canReopenClosedTab ?? WindowManager.shared.canReopenClosedWindow
        }
        // Already your browser: nothing to offer, so it isn't there (as in Safari and Chrome).
        if menuItem.action == #selector(makeDefaultBrowser(_:)) { menuItem.isHidden = DefaultBrowser.isDefault; return true }
        if menuItem.action == #selector(closeTab(_:)) { return NSApp.keyWindow?.styleMask.contains(.closable) ?? false }
        if menuItem.action == #selector(toggleKeepOnTop(_:)) {
            let window = KeepOnTop.frontWindow
            menuItem.state = window.map(KeepOnTop.isOn) == true ? .on : .off
            return KeepOnTop.applies(to: window)
        }
        return true
    }
}

/// One Zigzag per data folder: a lock on a file in it, held for as long as Zigzag runs. The system lets it
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
