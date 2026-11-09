import AppKit

/// A link from another app wakes Zigzag, and macOS brings every Zigzag window forward with it, a moment before Zigzag
/// hears of the link. For a link going to Zigzag Mini, as Little Arc, the browser windows should stay where they were.
/// So unless Zigzag was plainly woken some other way, its browser windows wait unseen for that moment; a link for
/// Zigzag Mini then puts them back exactly where they were, and anything else shows them where macOS put them. The
/// other ways are told apart by what you did last and where the pointer is, never by how long ago (a busy Zigzag can
/// take a while to hear it woke): ⌘Tab, Spotlight and shortcuts end with a key, and the Dock, a notification or a
/// Zigzag window sits under the pointer. Those are never touched.
enum MiniLinkWake {
    private static var waiting: [NSWindow] = []
    /// Each waiting window's place as Zigzag woke: the window just above it, of any app, top to bottom.
    private static var places: [(window: NSWindow, below: Int?)] = []
    private static var timeout: DispatchWorkItem?
    /// Why the last wake didn't hold the windows (nil: it did), and when.
    private static var lastReason: (reason: String?, at: Date)?
    /// How long the windows wait for the link: it comes about a twentieth of a second after the wake.
    private static let wait: TimeInterval = 0.35

    static func appWillActivate() {
        guard MiniWindowController.opensExternalLinks, waiting.isEmpty else { return }
        let windows = WindowManager.shared.controllers.compactMap(\.window).filter { $0.isVisible && !$0.isMiniaturized }
        guard !windows.isEmpty else { return }
        let reason = Self.reasonNotToWait()
        lastReason = (reason, Date())
        guard reason == nil else { return }
        // Where they were as Zigzag went to the background: by now macOS may already have raised them, and their
        // places taken now would put them back on top.
        places = settled.filter { place in windows.contains { $0 === place.window } }
        if places.count != windows.count { places = Self.places(of: windows) }
        waiting = windows
        windows.forEach { $0.alphaValue = 0 }
        let work = DispatchWorkItem { release(restoring: false) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Zigzag went to the background: where its windows sit among every app's, for a wake to put them back to.
    private static var settled: [(window: NSWindow, below: Int?)] = []

    static func appDidResign() {
        guard MiniWindowController.opensExternalLinks else { settled = []; return }
        // A moment later, once the app you went to has come up over them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !NSApp.isActive else { return }
            settled = places(of: WindowManager.shared.controllers.compactMap(\.window).filter { $0.isVisible && !$0.isMiniaturized })
        }
    }

    /// The link went to Zigzag Mini: the browser windows go back exactly where they were, then show.
    static func linkOpenedInMini() {
        // What the wake was taken for, for Help › Report a Problem when windows come up anyway.
        if let last = lastReason, Date().timeIntervalSince(last.at) < 5 {
            Diagnostics.note("Zigzag Mini link", last.reason.map { "windows not held: \($0)" } ?? (waiting.isEmpty ? "windows shown before the link" : "windows held"))
        }
        guard !waiting.isEmpty else { return }
        release(restoring: true)
    }

    private static func release(restoring: Bool) {
        timeout?.cancel()
        timeout = nil
        // Top to bottom, so each window it goes under is already back in its place.
        if restoring {
            let onScreen = Set(onScreenWindowNumbers())
            let front = frontWindowOfAnotherApp()
            for place in places {
                if let below = place.below, onScreen.contains(below) { place.window.order(.below, relativeTo: below) }
                else if let front { place.window.order(.below, relativeTo: front) }
            }
        }
        waiting.forEach { $0.alphaValue = 1 }
        waiting = []
        places = []
    }

    /// Why this wake plainly isn't a link from another app, if it plainly isn't.
    private static func reasonNotToWait() -> String? {
        let state = CGEventSourceStateID.combinedSessionState
        let owner = ownerOfWindowUnderPointer()
        return reasonNotToWait(sinceClick: CGEventSource.secondsSinceLastEventType(state, eventType: .leftMouseUp),
                               sinceKey: CGEventSource.secondsSinceLastEventType(state, eventType: .keyDown),
                               sinceModifier: CGEventSource.secondsSinceLastEventType(state, eventType: .flagsChanged),
                               under: owner.map { ($0.pid == ProcessInfo.processInfo.processIdentifier, $0.name) })
    }

    /// The decision on its own: seconds since the last click let go, key pressed and modifier changed, and whose
    /// window is under the pointer (Zigzag's own, or another app's by name). Nil: a link may be on its way.
    static func reasonNotToWait(sinceClick: Double, sinceKey: Double, sinceModifier: Double, under owner: (isZigzag: Bool, name: String)?) -> String? {
        if sinceModifier < sinceClick { return "a modifier last (⌘Tab)" }
        if sinceKey < sinceClick { return "a key last" }
        if owner?.isZigzag == true { return "a click on Zigzag" }
        if let name = owner?.name, ["Dock", "NotificationCenter", "Control Center"].contains(name) { return "a click on \(name)" }
        return nil
    }

    /// The app whose window is under the pointer: "Dock" over the Dock itself (the strip of the screen outside its
    /// usable area; the Dock also owns invisible windows over the whole screen, so its windows can't tell), otherwise
    /// the owner of the topmost normal window there.
    private static func ownerOfWindowUnderPointer() -> (pid: Int32, name: String)? {
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
            let usable = screen.visibleFrame, whole = screen.frame
            let inMenuBar = pointer.y >= usable.maxY
            if !inMenuBar, !usable.contains(pointer), whole.contains(pointer) { return (0, "Dock") }
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        // Window bounds count from the top left of the main display.
        let point = CGPoint(x: pointer.x, y: top - pointer.y)
        for entry in list where (entry[kCGWindowLayer as String] as? Int) == 0 {
            guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point),
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { continue }
            return (entry[kCGWindowOwnerPID as String] as? Int32 ?? 0, entry[kCGWindowOwnerName as String] as? String ?? "")
        }
        return nil
    }

    private static func onScreenWindowNumbers() -> [Int] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    private static func frontWindowOfAnotherApp() -> Int? {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.first { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) != me }?[kCGWindowNumber as String] as? Int
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
