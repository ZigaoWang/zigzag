import AppKit

// The small app Zigzag puts in ~/Applications for a site installed as an app (File › Install as App…). It holds the
// site's name and icon, so the site has its own Dock icon, ⌘Tab entry, Launchpad and Spotlight entry, and it hands
// every activation to the Zigzag that made it, which shows the site in a window of its own. The page itself runs in
// Zigzag, with the profile's sign-ins, extensions and blocking; this app only stands for it.
//
// What it knows comes from its own Info.plist, which Zigzag wrote when it made the app:
//   ZigzagWebAppID              the app's id in Zigzag's list
//   ZigzagHostBundleIdentifier  the Zigzag that made it (the dev build and test copies have their own)
//   ZigzagHostPath              where that Zigzag was, in case Launch Services doesn't know it
//   ZigzagMissingHostMessage    what to say when that Zigzag is gone, in the language Zigzag spoke

final class Launcher: NSObject, NSApplicationDelegate {
    private let info = Bundle.main.infoDictionary ?? [:]
    private var appID: String { info["ZigzagWebAppID"] as? String ?? "" }
    private var hostID: String { info["ZigzagHostBundleIdentifier"] as? String ?? "wang.zigao.zigzag" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Zigzag quitting or crashing takes the app's window with it: the app goes too.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let quit = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let quit, quit == self.hostID else { return }
                if self.runningHost == nil { exit(0) }
            }
        }
        send("open")
    }

    /// Clicked in the Dock, chosen with ⌘Tab, opened again from Finder: Zigzag brings the window forward.
    func applicationDidBecomeActive(_ notification: Notification) { send("open") }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        send("open")
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quit from its Dock menu: the window in Zigzag closes too. Not when Zigzag itself asked (its window closed,
        // the app was removed, or Zigzag is quitting), and never by starting a Zigzag that isn't running.
        if let host = runningHost, !isFromHost(NSAppleEventManager.shared().currentAppleEvent) { send("close", to: host) }
        return .terminateNow
    }

    // MARK: Zigzag

    private var runningHost: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: hostID).first { !$0.isTerminated }
    }

    private func isFromHost(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let pid = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == hostID
    }

    /// The Zigzag that made this app: the one running, else where it was, else wherever Launch Services has it.
    private var hostURL: URL? {
        if let url = runningHost?.bundleURL { return url }
        if let path = info["ZigzagHostPath"] as? String, let bundle = Bundle(path: path), bundle.bundleIdentifier == hostID {
            return bundle.bundleURL
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: hostID)
    }

    /// Hands `action` ("open" or "close") for this app to Zigzag, as a zigzag-webapp: link only Zigzag is asked to open.
    private func send(_ action: String, to running: NSRunningApplication? = nil) {
        // Launching and becoming active both ask: Zigzag takes the second as bringing the window forward again, which
        // it can only do once this app is active and steps aside for it.
        guard !appID.isEmpty, let link = URL(string: "zigzag-webapp://\(action)/\(appID)") else { exit(1) }
        guard let host = running?.bundleURL ?? hostURL else {
            if action == "open" { tellHostMissing() }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Zigzag brings only this app's window forward, and then itself: activating it from here would raise every
        // browser window with it. This app steps aside so Zigzag may take the front.
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        // Only the app in front can step aside, so this counts once this app is active: opened from Finder, the Dock
        // or Spotlight it becomes so a moment after launching, and asks again then (`applicationDidBecomeActive`).
        if action == "open", NSApp.isActive {
            if let running = running ?? runningHost { NSApp.yieldActivation(to: running) }
            else { NSApp.yieldActivation(toApplicationWithBundleIdentifier: hostID) }
        }
        if action == "close", runningHost == nil { return }
        NSWorkspace.shared.open([link], withApplicationAt: host, configuration: configuration) { _, error in
            guard error != nil, action == "open" else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.tellHostMissing() } }
        }
    }

    private func tellHostMissing() {
        let alert = NSAlert()
        alert.messageText = info["ZigzagMissingHostMessage"] as? String ?? "This app opens in Zigzag, which isn’t on this Mac."
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
        exit(0)
    }
}

let app = NSApplication.shared
let launcher = Launcher()
app.delegate = launcher
app.setActivationPolicy(.regular)
app.run()
