import AppKit
import WebKit

/// What a launch does with the last session: pick it up, or start with one fresh window, the saved session left for
/// History › Reopen Last Session (#433). Reopening is the default, so nothing changes for anyone who never opens Settings.
enum LaunchChoice: String, CaseIterable, Sendable {
    case resume, fresh

    /// Kept in the app's defaults, beside the other settings.
    static var choice: LaunchChoice {
        get { LaunchChoice(rawValue: defaults.string(forKey: key) ?? "") ?? .resume }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }

    /// What keeps it, so a test can swap in its own suite instead of the dev app's defaults.
    static var defaults: UserDefaults = .standard

    static let key = "LaunchChoice"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    /// Which of `pendingURLs` were handed off from another device: those open in a tab, never Zigzag Mini (#456).
    private var pendingHandoffs: Set<URL> = []
    /// Sites installed as apps asked for before launch finished (one opened with Zigzag not running).
    private var pendingWebApps: [URL] = []
    /// Zigzag backups opened from Finder before launch finished.
    private var pendingBackups: [URL] = []
    private var launched = false
    private var blockerToken: SignalToken?
    private var extensionsToken: SignalToken?
    private var developerToken: SignalToken?

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
        // Applies the saved spelling and substitution choices to every page (#296).
        PageTextChecking.shared.start()
        // A second copy (one opened from the disk image while the installed one runs) would load the same data
        // and save over it: it hands over to the one already running and goes, before reading anything.
        // With --headless it asks the running copy instead; otherwise it says you opened it.
        if !Self.isHostingTests, !SingleCopy.claim() {
            if Headless.isAsked(by: CommandLine.arguments) { Headless.askRunningCopy() } else { Headless.tellRunningCopyYouOpened(); SingleCopy.showRunningCopy() }
            exit(0)
        }
        // With --headless: runs for AI apps alone, with no Dock icon or window. Set before anything shows.
        if !Self.isHostingTests { Headless.willLaunch() }
        if !Self.isHostingTests {
            // A new version backs up the data the last one left, and a restore asked for before restarting puts
            // a backup back, both before anything reads it.
            // The day Zigzag was first used here, kept once, while the last run's version is still on record.
            CardStart.settle()
            // A new version owes its notes: noted before the backup records this version as the one that ran.
            WhatsNew.noteLaunch()
            let info = Bundle.main.infoDictionary
            UpdateBackup.backUpIfUpdated(build: info?["CFBundleVersion"] as? String ?? "", version: info?["CFBundleShortVersionString"] as? String ?? "")
            UpdateBackup.restoreIfAsked()
            // Site permissions kept by host alone become per origin before any page can ask.
            SitePermissions.migrateHostOnlyAnswers()
            SitePermissions.migrateMediaAnswers()
            // Converts old yes/no answers to action ids once at launch.
            SitePermissions.migrateAnswersToActions()
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
        // Every other window (Settings, a sheet's) hears fingers once it's in use.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window { TouchPress.watch(window) } }
        }
        settleSpaceNameStyle()
        Tutorial.migrate()
        // The sidebar at the screen's edge (#363), if it's on.
        EdgeSidebar.shared.startIfOn()
        // Getting started picks up where you left off, if you'd begun and haven't ended it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard !Tutorial.done.isEmpty, WelcomeWindowController.shared == nil,
                  let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
            GuidedTour.start(in: controller)
        }
        _ = Library.shared
        _ = Profiles.shared.default.history
        // Deletes empty-page backgrounds no space uses; kept until now for ⌘Z.
        let backgrounds = Set(Library.shared.spaces.compactMap(\.backgroundImage))
        DispatchQueue.global(qos: .utility).async { SpaceBackground.prune(keeping: backgrounds) }
        // Deletes image icons nothing uses any more (#303); kept until now for ⌘Z.
        let started = Date()
        // Site icons (#310) live in settings, not files.
        let siteIcons = Data(SiteIcons.all.values.joined(separator: "\n").utf8)
        DispatchQueue.global(qos: .utility).async {
            let saved = ((try? FileManager.default.contentsOfDirectory(at: Paths.support, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.compactMap { try? Data(contentsOf: $0) } + [siteIcons]
            PageImageIcon.prune(keepingNamesIn: saved, before: started)
        }
        // Icons clearing history set aside, if Zigzag didn't get to remove them when it quit.
        try? FileManager.default.removeItem(at: Paths.setAsideIcons)
        // Copies an import read through, if Zigzag stopped before removing them: they can hold passwords.
        DispatchQueue.global(qos: .utility).async { ImportScratch.removeLeftovers() }
        // Loads the Public Suffix List off the main thread before the first address shows. The HSTS list is searched in
        // place.
        DispatchQueue.global(qos: .userInitiated).async { _ = PublicSuffix.isLoaded }
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
        // Live folders fetch their feeds in the background; the test host fetches nothing.
        if !Self.isHostingTests { LiveFolders.shared.start() }
        // The app you were in, for Zigzag Mini to go back to.
        AppSwitching.start()
        // New lists or settings reach open pages on their next load.
        blockerToken = ContentBlocker.changed.observe {
            for tab in WindowManager.shared.everyOpenTab {
                if let webView = tab.webView, !Tab.isExtensionPage(tab.url) { ContentBlocker.apply(to: webView, for: tab.url) }
            }
        }
        // Developer tools turned on or off, or a site put on its list or taken off: open tabs are told at once.
        developerToken = DeveloperTools.changed.observe {
            // Before the tabs, so a listed page waits for its no-images rule.
            PageImages.sitesChanged()
            for tab in WindowManager.shared.everyOpenTab { tab.refreshDevelopment(settingsChanged: true) }
            // Its menu items come and go with it, and whatever lists the menu bar's shortcuts hears of it.
            // The listed sizes in View › Developer › Page Size follow the list.
            if DeveloperTools.isOn { MainMenu.refreshPageSizes(in: NSApp.mainMenu) }
            if MainMenu.setDeveloperTools(DeveloperTools.isOn, in: NSApp.mainMenu) {
                if DeveloperTools.isOn {
                    Shortcuts.applyToNew(Shortcuts.allItems.filter { item in DeveloperTool.menuItems.contains { $0.action == item.action } })
                }
                Shortcuts.changed.send()
            }
        }
        if #available(macOS 15.4, *) {
            // An ad blocker extension turned on or off, or let onto YouTube or not: open pages follow on their next load.
            extensionsToken = ExtensionCenter.changed.observe {
                for tab in WindowManager.shared.everyOpenTab {
                    if let webView = tab.webView, !Tab.isExtensionPage(tab.url) { ContentBlocker.applyFilters(to: webView, for: tab.url) }
                }
            }
            ExtensionStore.setUpIfNeeded()
        }
        // Onboarding not finished: it comes first, instead of the window that was waiting behind it. Opened for links that
        // all go to Zigzag Mini, only Zigzag Mini comes up, as Little Arc does; the windows come back when you ask.
        let handoffs = pendingHandoffs
        let goesToMini = { (url: URL) in Self.pendingOpensInMini(url, handedOff: handoffs, opensInMini: WindowManager.shared.opensInMini) }
        let miniOnly = !pendingURLs.isEmpty && !WindowManager.needsOnboarding && pendingURLs.allSatisfy(goesToMini)
        // Opened by a site installed as an app: only its window comes up, as Chrome's apps do; the browser windows
        // wait until you ask for them.
        let webAppOnly = pendingURLs.isEmpty && !pendingWebApps.isEmpty && !WindowManager.needsOnboarding
        // With --headless alone it runs for AI apps; a link or an installed site makes it the regular app.
        if Headless.isBackgroundOnly, !pendingURLs.isEmpty || !pendingWebApps.isEmpty { Headless.becomeRegular() }
        let backgroundOnly = Headless.isBackgroundOnly
        // Restarted for an update: exactly what was open comes back, Zigzag Mini windows too.
        let relaunch = backgroundOnly ? nil : UpdateRelaunch.take()
        let plan = UpdateRelaunch.plan(relaunch: relaunch, now: Date(), needsOnboarding: WindowManager.needsOnboarding,
                                       miniOnly: miniOnly, webAppOnly: webAppOnly, backgroundOnly: backgroundOnly)
        WindowManager.shared.sessionWaiting = plan.sessionWaiting
        // Settings › General › On launch: a fresh start keeps the saved session for History › Reopen Last Session
        // instead of bringing it back, and doesn't write over it until the new window is used (#433). An update's
        // relaunch puts exactly what was open back, unless it interrupted a fresh start still unused.
        let resumes = UpdateRelaunch.resumes(plan: plan, relaunch: relaunch, choice: LaunchChoice.choice)
        WindowManager.shared.startingFresh = UpdateRelaunch.startsFresh(plan: plan, relaunch: relaunch, choice: LaunchChoice.choice)
        if WindowManager.shared.startingFresh { WindowManager.shared.keepSessionForReopening() }
        // Session cookies come back with the session, before any of its pages loads; otherwise they're dropped.
        SessionCookies.start(resumes: resumes)
        let restored = resumes ? WindowManager.shared.restoreSession() : false
        if plan.restoresMinis { relaunch?.minis.forEach { MiniWindowController.reopen($0) } }
        // Opened from the disk image or a download macOS keeps apart: offered a move to Applications, so it can update.
        MoveToApplications.offerWhenReady()
        launched = true
        if !pendingURLs.isEmpty {
            // A link for Zigzag Mini opens just that, as it would with Zigzag already running.
            if !restored, !goesToMini(pendingURLs[0]) {
                WindowManager.shared.newWindow(url: pendingURLs.removeFirst(), showCommandBar: false)
            }
            pendingURLs.forEach { handoffs.contains($0) ? WindowManager.shared.openHandedOff($0) : WindowManager.shared.openExternal($0) }
            pendingURLs = []
            pendingHandoffs = []
        } else if !restored, !plan.sessionWaiting {
            WindowManager.shared.newWindow()
        }
        pendingWebApps.forEach { WebAppStore.handle($0) }
        pendingWebApps = []
        pendingBackups.forEach { ImportWindowController.restore($0) }
        pendingBackups = []
        // For you, not AI apps: running for them alone, this waits until you open Zigzag.
        let forYou = { [weak self] in
            Updater.shared.start()
            // Just updated: what's new comes first, and the default browser offer waits for another launch. Profiles
            // that couldn't be read come before either: what's new waits a launch.
            if Library.shared.profilesWereSetAside { self?.tellProfilesSetAside() } else if !WhatsNew.offerIfUpdated() { self?.offerDefaultBrowserOnce() }
            DockProgress.shared.start()
            AutoPictureInPicture.shared.start()
        }
        if Headless.isBackgroundOnly { Headless.whenOpened = forYou } else { forYou() }
        Tokens.Contrast.start()
        DebugBridge.start()
        // Only if you turned it on in Settings: otherwise nothing listens.
        MCPService.startIfOn()
        Headless.start()
    }

    func applicationWillBecomeActive(_ notification: Notification) { MiniLinkWake.appWillActivate() }
    func applicationWillResignActive(_ notification: Notification) {
        // A Picture in Picture window that hasn't floated yet does before you're in the other app (#210).
        PictureInPicture.floatPanels()
    }
    func applicationDidResignActive(_ notification: Notification) { MiniLinkWake.appDidResign() }
    // A hidden Zigzag offers no page to your other devices.
    func applicationDidHide(_ notification: Notification) { WindowManager.shared.controllers.forEach { $0.updateHandoff() } }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opened while it ran for AI apps alone: it's yours now, your windows with it.
        if Headless.openedByYou() { return true }
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
    /// restarting or shutting down, when an update restarts Zigzag, or for Quit chosen in the menu or the Dock: only
    /// the Quit key asks. ⌘Q again, or Return, quits.
    static var asksBeforeQuitting: Bool {
        get { UserDefaults.standard.object(forKey: "AskBeforeQuitting") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "AskBeforeQuitting") }
    }

    /// Set while the Quit key quits: choosing Quit anywhere else is the confirmation, as in Chrome (#441).
    private static var quittingFromKey = false

    /// Whether the setting asks for this quit: only for the Quit key, or always while files download.
    static func asks(fromKey: Bool, setting: Bool, downloading: Int) -> Bool {
        (setting && fromKey) || downloading > 0
    }

    /// Quit Zigzag's shortcut as it is now, after Settings › Shortcuts; ⌘Q before the menu bar is built.
    static var quitCombo: Shortcuts.Combo {
        Shortcuts.allItems.first { $0.action == #selector(quitFromMenu(_:)) }.map(Shortcuts.combo(of:))
            ?? Shortcuts.Combo(key: "q", modifiers: NSEvent.ModifierFlags.command.rawValue)
    }

    /// Whether the event is Quit's shortcut, the one quit the setting asks about.
    static func isQuitKey(_ event: NSEvent?, combo: Shortcuts.Combo = quitCombo) -> Bool {
        guard let event, event.type == .keyDown, !combo.key.isEmpty, let pressed = Shortcuts.combo(from: event) else { return false }
        let wanted = combo.flags.intersection([.command, .option, .control, .shift])
        // An uppercase key equivalent carries ⇧ by itself.
        let flags = combo.key.lowercased() != combo.key ? wanted.union(.shift) : wanted
        guard pressed.flags == flags else { return false }
        if pressed.key == combo.key.lowercased() { return true }
        // A layout without Latin letters (Russian, Greek, Hebrew) types its own letter there, and the menu still takes
        // the key where the letter sits on a US keyboard: so does this.
        guard !pressed.key.unicodeScalars.allSatisfy(\.isASCII), let code = ansiKeyCode(combo.key) else { return false }
        return event.keyCode == code
    }

    /// Where a letter or digit sits on a US keyboard (the kVK_ANSI_ codes).
    static func ansiKeyCode(_ key: String) -> UInt16? {
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
            "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ]
        guard key.count == 1, let char = key.lowercased().first else { return nil }
        return codes[char]
    }

    @objc func quitFromMenu(_ sender: Any?) {
        Self.quittingFromKey = Self.isQuitKey(NSApp.currentEvent)
        defer { Self.quittingFromKey = false }
        NSApp.terminate(sender)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isHostingTests else { return .terminateNow }
        let downloading = DownloadManager.shared.activeCount
        // Going for good: downloads still coming in pause first, so they go on from Downloads after the next launch.
        func quitNow() -> NSApplication.TerminateReply {
            guard downloading > 0 || !KeptCookies.profilesClearingOnQuit().isEmpty || SessionCookies.isOn else { return .terminateNow }
            Self.finishBeforeQuitting(downloading: downloading)
            return .terminateLater
        }
        // Asked already, or not asking: downloads are the one thing worth asking about anyway.
        guard !Self.quitConfirmed, Self.asks(fromKey: Self.quittingFromKey, setting: Self.asksBeforeQuitting, downloading: downloading) else { return quitNow() }
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
            Self.finishBeforeQuitting(downloading: downloading)
        }
        // Under Start Fresh the next launch won't bring these back by itself, so the sheet doesn't promise it does.
        let fresh = LaunchChoice.choice == .fresh
        let keepsTabs = String(localized: "Your tabs and spaces will be right here when you open it again.",
                               comment: "Message of the sheet that asks before quitting; “it” is Zigzag.")
        let freshTabs = String(localized: "Your tabs and spaces are saved, and History › Reopen Last Session brings them back.",
                               comment: "Message of the sheet that asks before quitting, with On launch set to Start Fresh: the next launch opens a new window, and the session is reopened from the History menu.")
        let message = downloading == 0
            ? (fresh ? freshTabs : keepsTabs)
            : String(localized: "\(downloading) downloads are still in progress. They pause, and you can resume them from Downloads when you open Zigzag again.",
                     comment: "Message of the sheet that asks before quitting while files download.")
        ConfirmSheet.show(in: host, title: String(localized: "Quit Zigzag?", comment: "Title of the sheet that asks before quitting."), message: message,
                          confirmTitle: String(localized: "Quit", comment: "Button of the sheet that asks before quitting.")) { answer($0) }
        // While it asks, the Quit key again means yes (macOS doesn't ask the app a second time on its own).
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isQuitKey(event) else { return event }
            host.subviews.compactMap { $0 as? ConfirmSheet }.forEach { $0.removeFromSuperview() }
            answer(true)
            return nil
        }
        return .terminateLater
    }

    /// Pauses downloads and clears the cookies chosen to go at quit (#334), then saves session cookies, side by side,
    /// each bounded, then quits.
    private static func finishBeforeQuitting(downloading: Int) {
        let cookieJobs = KeptCookies.clearJobs(KeptCookies.profilesClearingOnQuit()) + SessionCookies.quitJobs()
        var left = (downloading > 0 ? 1 : 0) + (cookieJobs.isEmpty ? 0 : 1)
        guard left > 0 else { NSApp.reply(toApplicationShouldTerminate: true); return }
        let finish = {
            left -= 1
            if left == 0 { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        if downloading > 0 { DownloadManager.shared.pauseAllForQuit(then: finish) }
        if !cookieJobs.isEmpty { KeptCookies.whenDone(cookieJobs, within: KeptCookies.quitWait, done: finish) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        WindowManager.shared.prepareForTermination()
        // What's still being written goes to disk before Zigzag ends.
        TabArchive.flush()
        HistoryStore.finishWriting()
        FaviconStore.finishWriting()
        StrictTransport.finishWriting()
        LiveFolders.shared.saveNow()
        // Undo ends with Zigzag, and the icons clearing history set aside for it go now (or at the next start).
        try? FileManager.default.removeItem(at: Paths.setAsideIcons)
        // Clears a copied password from the clipboard on quit.
        Clipboard.clearIfStillOurs()
        // Password managers' helpers end with Zigzag, so none are left running.
        if #available(macOS 15.4, *) { NativeMessagingHost.terminateAll() }
        // Quit properly: the next launch knows this wasn't a crash.
        Diagnostics.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Opening URLs from elsewhere

    /// A `file:` URL to a readable local HTML, SVG or PDF file; never a folder or anything runnable.
    nonisolated static func localPage(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), url.isFileURL,
              ["html", "htm", "xhtml", "svg", "pdf"].contains(url.pathExtension.lowercased()) else { return nil }
        let file = url.standardizedFileURL
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
              values.isRegularFile == true, values.isReadable == true else { return nil }
        return file
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        // A site installed as an app, opened or quit (only its small app sends these).
        if let link = URL(string: string), WebAppLink.parse(link) != nil {
            let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
            if launched {
                // An installed site opened while Zigzag ran for AI apps alone: you're here.
                Headless.becomeRegular()
                WebAppStore.handle(link, from: sender)
            } else {
                pendingWebApps.append(link)
            }
            return
        }
        // Only a web address or a local page; never an internal, extension or folder URL, or other file types.
        guard let url = Scripting.webAddress(string) ?? Self.localPage(string) else { return }
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

    /// Files opened with Zigzag, and links handed over as a document: web addresses and local files only. A Zigzag
    /// backup goes to the Import window, which asks before restoring it.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch Self.documentRoute(url) {
            case .restore:
                if launched { ImportWindowController.restore(url) } else { pendingBackups.append(url) }
            case .page: open(url)
            case .ignore: break
            }
        }
    }

    nonisolated enum DocumentRoute: Equatable { case page, restore, ignore }

    /// Where a URL handed over as a document goes: a Zigzag backup to the Import window, never a tab.
    nonisolated static func documentRoute(_ url: URL) -> DocumentRoute {
        guard opensAsDocument(url) else { return .ignore }
        return url.isFileURL && url.pathExtension.lowercased() == "zigzagbackup" ? .restore : .page
    }

    /// Whether a URL handed over as a document opens: local files always open in a tab; web addresses only when Zigzag
    /// Mini takes links.
    nonisolated static func opensAsDocument(_ url: URL) -> Bool {
        url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Whether a link waiting for launch goes to Zigzag Mini: as the setting says, but never a handed-off page (#456).
    static func pendingOpensInMini(_ url: URL, handedOff: Set<URL>, opensInMini: (URL) -> Bool) -> Bool {
        !handedOff.contains(url) && opensInMini(url)
    }

    private func open(_ url: URL) {
        guard launched else { pendingURLs.append(url); return }
        // A link while it ran for AI apps alone: you're here, so it's the Zigzag you know.
        Headless.becomeRegular()
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

    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        userActivityType == NSUserActivityTypeBrowsingWeb
    }

    /// A page handed off from your iPhone or another Mac opens in a tab here, routed like a link from any app.
    /// macOS hands a browsing activity from another device only to the default browser.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        guard launched else {
            pendingURLs.append(url)
            pendingHandoffs.insert(url)
            return true
        }
        WindowManager.shared.openHandedOff(url)
        NSApp.activate()
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
    /// History › Reopen Last Session: the session a fresh start passed over (#433).
    @objc func reopenLastSession(_ sender: Any?) { WindowManager.shared.reopenLastSession() }
    /// The latest closed tab or window, as in Chrome; with no window open, that's usually the window.
    @objc func reopenClosedTab(_ sender: Any?) {
        WindowManager.shared.reopenLastClosed(from: WindowManager.shared.controllers.isEmpty ? nil : WindowManager.shared.keyController?.tabManager)
    }
    @objc func showHistory(_ sender: Any?) { frontBrowserWindow().map(HistoryPage.open) }
    @objc func showArchive(_ sender: Any?) { frontBrowserWindow().map(ArchivePage.open) }
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

    /// Window › Show AI Apps Window: brings the AI apps' background window on screen (Headless).
    @objc func showHeadlessWindow(_ sender: Any?) { Headless.showWindow() }

    /// Settings opens as a tab in the front window, as History does.
    @objc func showSettings(_ sender: Any?) { frontBrowserWindow().map { SettingsPage.open(in: $0) } }
    /// Help › Keyboard Shortcuts: every shortcut, where you can change them.
    @objc func showKeyboardShortcuts(_ sender: Any?) { frontBrowserWindow().map { SettingsPage.open(.shortcuts, in: $0) } }

    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates() }

    @objc func makeDefaultBrowser(_ sender: Any?) { DefaultBrowser.make() }

    @objc func importFromBrowser(_ sender: Any?) { ImportWindowController.show() }

    @objc func exportData(_ sender: Any?) { frontBrowserWindow().map { DataExport.show(in: $0) } }

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
        // There when a fresh start is the setting, and dimmed once its session is back.
        if menuItem.action == #selector(reopenLastSession(_:)) {
            menuItem.isHidden = LaunchChoice.choice != .fresh
            return WindowManager.shared.canReopenLastSession
        }
        // Only while AI apps work in the background.
        if menuItem.action == #selector(showHeadlessWindow(_:)) {
            menuItem.isHidden = !Headless.isActive
            return Headless.isActive
        }
        // Zigzag Mini names it Open in Zigzag while it's in front; anywhere else it's itself again.
        if menuItem.action == #selector(openDocument(_:)) { menuItem.title = BrowserWindowController.openFileTitle }
        // Shows Restart to Update while an update is ready.
        if menuItem.action == #selector(checkForUpdates(_:)) { menuItem.title = Updater.shared.menuTitle }
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            let manager = WindowManager.shared.controllers.isEmpty ? nil : (WindowManager.shared.keyController ?? WindowManager.shared.controllers.first)?.tabManager
            return WindowManager.shared.canReopenLastClosed(from: manager)
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
