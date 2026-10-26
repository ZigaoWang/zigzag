import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private var launched = false
    private var blockerToken: SignalToken?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        Shortcuts.apply()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// Unit tests run inside the app; they must never touch the person's windows, session or extensions.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        // Getting started picks up where you left off, if you'd begun and haven't ended it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard !Tutorial.done.isEmpty, WelcomeWindowController.shared == nil,
                  let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
            GuidedTour.start(in: controller)
        }
        _ = Library.shared
        _ = HistoryStore.shared
        ContentBlocker.prepare()
        // A page stuck working hard (an extension in a loop, usually) gets named, with a way out.
        EnergyWatch.shared.start()
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
        if !flag { WindowManager.shared.reopen() }
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
        guard !Self.quitConfirmed, !Self.isHostingTests, Self.asksBeforeQuitting else { return .terminateNow }
        // Logging out, restarting or shutting down: the system's own reason is on the quit event.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil { return .terminateNow }
        guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first,
              let window = controller.window, window.isVisible, let host = window.contentView else { return .terminateNow }
        // Already asking: ⌘Q a second time means yes.
        if host.subviews.contains(where: { $0 is ConfirmSheet }) { return .terminateNow }
        window.makeKeyAndOrderFront(nil)
        var answered = false
        var monitor: Any?
        func answer(_ quit: Bool) {
            guard !answered else { return }
            answered = true
            if let monitor { NSEvent.removeMonitor(monitor) }
            if quit { Self.quitConfirmed = true }
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        ConfirmSheet.show(in: host, title: "Quit Zigzag?", message: "Your tabs and spaces will be right here when you open it again.",
                          confirmTitle: "Quit") { answer($0) }
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
        // Password managers' helpers end with Zigzag, so none are left running.
        if #available(macOS 15.4, *) { NativeMessagingHost.terminateAll() }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Opening URLs from elsewhere

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: string) else { return }
        open(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    private func open(_ url: URL) {
        guard launched else { pendingURLs.append(url); return }
        WindowManager.shared.openExternal(url)
        NSApp.activate()
    }

    /// One quiet offer, on the second launch, never repeated: by then you know whether you like it here.
    private func offerDefaultBrowserOnce() {
        let defaults = UserDefaults.standard
        let launches = defaults.integer(forKey: "LaunchCount") + 1
        defaults.set(launches, forKey: "LaunchCount")
        guard launches >= 2, !defaults.bool(forKey: "DefaultBrowserOffered"), !SettingsWindowController.isDefaultBrowser else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let controller = WindowManager.shared.keyController else { return }
            defaults.set(true, forKey: "DefaultBrowserOffered")
            Toast.show("Open links in Zigzag?", symbol: "safari", action: ("Make Default", { DefaultBrowser.make() }),
                       duration: 8, in: controller)
        }
    }

    // MARK: App menu actions

    @objc func newWindow(_ sender: Any?) {
        // With every window closed, a new one brings back the one you closed, tabs and all.
        if WindowManager.shared.controllers.contains(where: { !$0.tabManager.isPrivate }) { WindowManager.shared.newWindow() } else { WindowManager.shared.reopen() }
    }
    @objc func newPrivateWindow(_ sender: Any?) { WindowManager.shared.newWindow(isPrivate: true) }

    // With Settings or Passwords in front, or no window open, these reach here rather than a browser window: that
    // window comes forward (or the closed one comes back) and does it, instead of the menu item being greyed out.
    @objc func newTab(_ sender: Any?) { frontBrowserWindow()?.commandBar.show(mode: .newTab) }
    @objc func openLocation(_ sender: Any?) { frontBrowserWindow()?.commandBar.show(mode: .editCurrent) }
    @objc func reopenClosedWindow(_ sender: Any?) { WindowManager.shared.reopenClosedWindow() }

    @objc func sendFeedback(_ sender: Any?) { frontBrowserWindow().map(Feedback.show) }

    private func frontBrowserWindow() -> BrowserWindowController? {
        if WindowManager.shared.controllers.isEmpty { WindowManager.shared.reopen() }
        // Onboarding still showing: the window waits behind it.
        guard WelcomeWindowController.shared == nil, let controller = WindowManager.shared.keyController else { return nil }
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    @objc func showAbout(_ sender: Any?) { AboutWindowController.show() }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates() }

    @objc func makeDefaultBrowser(_ sender: Any?) { DefaultBrowser.make() }

    @objc func importFromBrowser(_ sender: Any?) { ImportWindowController.show() }

    @objc func showPasswords(_ sender: Any?) { PasswordsWindowController.show() }
}

extension AppDelegate: NSMenuItemValidation {
    /// Reopen Closed Window is dimmed when there's nothing to bring back.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(reopenClosedWindow(_:)) { return WindowManager.shared.canReopenClosedWindow }
        return true
    }
}
