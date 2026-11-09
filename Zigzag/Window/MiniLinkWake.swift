import AppKit

/// A link from another app wakes Zigzag, and macOS brings every Zigzag window forward with it, a moment before Zigzag
/// hears of the link. For a link going to Zigzag Mini, as Little Arc, the browser windows should stay where they were.
/// So when what woke Zigzag was a click that just ended over another app's window (a link in WeChat, Mail, Slack), its
/// browser windows wait unseen for that moment; a link for Zigzag Mini then puts them back exactly where they were,
/// and anything else shows them where macOS put them. ⌘Tab (a key), the Dock, a notification or a click on a Zigzag
/// window never trigger it, so coming back to Zigzag any other way is never touched.
enum MiniLinkWake {
    private static var waiting: [NSWindow] = []
    /// Each waiting window's place as Zigzag woke: the window just above it, of any app, top to bottom.
    private static var places: [(window: NSWindow, below: Int?)] = []
    private static var timeout: DispatchWorkItem?
    /// How long the windows wait for the link: it comes about a twentieth of a second after the wake.
    private static let wait: TimeInterval = 0.35

    static func appWillActivate() {
        guard MiniWindowController.opensExternalLinks, waiting.isEmpty, wokenByClickInAnotherApp() else { return }
        let windows = WindowManager.shared.controllers.compactMap(\.window).filter { $0.isVisible && !$0.isMiniaturized }
        guard !windows.isEmpty else { return }
        places = Self.places(of: windows)
        waiting = windows
        windows.forEach { $0.alphaValue = 0 }
        let work = DispatchWorkItem { release(restoring: false) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// The link went to Zigzag Mini: the browser windows go back exactly where they were, then show.
    static func linkOpenedInMini() {
        guard !waiting.isEmpty else { return }
        release(restoring: true)
    }

    private static func release(restoring: Bool) {
        timeout?.cancel()
        timeout = nil
        // Top to bottom, so each window it goes under is already back in its place.
        if restoring { for place in places { if let below = place.below { place.window.order(.below, relativeTo: below) } } }
        waiting.forEach { $0.alphaValue = 1 }
        waiting = []
        places = []
    }

    /// The last thing you did was let go of a click, just now, over another app's window: a link clicked there. A key
    /// since (⌘Tab, Spotlight, a shortcut), or the pointer on the Dock, a notification, or a Zigzag window, isn't.
    private static func wokenByClickInAnotherApp() -> Bool {
        let state = CGEventSourceStateID.combinedSessionState
        let owner = ownerOfWindowUnderPointer()
        return wokenByClick(sinceClick: CGEventSource.secondsSinceLastEventType(state, eventType: .leftMouseUp),
                            sinceKey: CGEventSource.secondsSinceLastEventType(state, eventType: .keyDown),
                            sinceModifier: CGEventSource.secondsSinceLastEventType(state, eventType: .flagsChanged),
                            under: owner.map { ($0.pid == ProcessInfo.processInfo.processIdentifier, $0.name) })
    }

    /// The decision on its own: seconds since the last click let go, key pressed and modifier changed, and whose
    /// window is under the pointer (Zigzag's own, or another app's by name).
    static func wokenByClick(sinceClick: Double, sinceKey: Double, sinceModifier: Double, under owner: (isZigzag: Bool, name: String)?) -> Bool {
        guard sinceClick < 0.6, sinceClick < sinceKey, sinceClick < sinceModifier, let owner, !owner.isZigzag else { return false }
        return !["Dock", "NotificationCenter", "Control Center", "Window Server"].contains(owner.name)
    }

    private static func ownerOfWindowUnderPointer() -> (pid: Int32, name: String)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        // Window bounds count from the top left of the main display.
        let pointer = NSEvent.mouseLocation
        let point = CGPoint(x: pointer.x, y: top - pointer.y)
        for entry in list {
            guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point),
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { continue }
            return (entry[kCGWindowOwnerPID as String] as? Int32 ?? 0, entry[kCGWindowOwnerName as String] as? String ?? "")
        }
        return nil
    }

    /// Where each window sits among every app's windows on screen, as the window right above it.
    private static func places(of windows: [NSWindow]) -> [(window: NSWindow, below: Int?)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let byNumber = Dictionary(windows.map { ($0.windowNumber, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [(window: NSWindow, below: Int?)] = []
        var above: Int?
        for entry in list where (entry[kCGWindowLayer as String] as? Int) == 0 {
            guard let number = entry[kCGWindowNumber as String] as? Int else { continue }
            if let window = byNumber[number] { result.append((window, above)) }
            above = number
        }
        return result
    }
}
