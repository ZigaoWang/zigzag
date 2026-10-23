import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Library.shared
        _ = HistoryStore.shared
        if #available(macOS 15.4, *) {
            ExtensionHost.shared.loadInstalled()
            KnownExtension.setUpIfNeeded()
        }
        let restored = WindowManager.shared.restoreSession()
        launched = true
        if !pendingURLs.isEmpty {
            if !restored { WindowManager.shared.newWindow(url: pendingURLs.removeFirst(), showCommandBar: false) }
            pendingURLs.forEach { WindowManager.shared.openExternal($0) }
            pendingURLs = []
        } else if !restored {
            WindowManager.shared.newWindow()
        }
        Updater.shared.start()
        DockProgress.shared.start()
        DebugBridge.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.newWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        WindowManager.shared.prepareForTermination()
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

    // MARK: App menu actions

    @objc func newWindow(_ sender: Any?) { WindowManager.shared.newWindow() }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "A calm browser for the Mac.", attributes: [
                .font: Tokens.Font.small(), .foregroundColor: NSColor.secondaryLabelColor,
            ]),
        ])
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates() }

    @objc func makeDefaultBrowser(_ sender: Any?) { DefaultBrowser.make() }

    @objc func importFromArc(_ sender: Any?) { ArcImporter.runInteractive() }
}
