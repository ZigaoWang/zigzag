import AppKit

/// Whether the screen is locked or another user has the Mac, and whether Zigzag's next wake is the one unlocking
/// brings: macOS gives the front back to the app that had it, which is never a link's wake.
@MainActor final class ScreenLock {
    static let shared = ScreenLock()
    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    /// Posted on the default center when `isLocked` changes.
    static let changedNotification = Notification.Name("ZigzagScreenLockChanged")
    /// How long after unlocking its wake may still reach Zigzag.
    static let unlockGrace: TimeInterval = 2

    private var screenLocked = false
    private var sessionAway = false
    var isLocked: Bool { screenLocked || sessionAway }
    /// From a lock until its unlock's wake has come, to Zigzag or another app, or `unlockGrace` after.
    private(set) var wakeIsUnlock = false
    private var graceWork: DispatchWorkItem?
    private var observers: [(NotificationCenter, Any)] = []

    /// Centers are injectable so tests never broadcast a screen lock.
    func start(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
               distributed: NotificationCenter = DistributedNotificationCenter.default()) {
        guard observers.isEmpty else { return }
        let events: [(NotificationCenter, Notification.Name)] = [
            (distributed, Self.lockedNotification), (distributed, Self.unlockedNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification), (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (workspace, NSWorkspace.didActivateApplicationNotification),
        ]
        observers = events.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let isZigzag = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                let isLoginWindow = app?.bundleIdentifier == "com.apple.loginwindow", name = note.name
                MainActor.assumeIsolated { self?.heard(name, isZigzag: isZigzag, isLoginWindow: isLoginWindow) }
            })
        }
    }

    private func heard(_ name: Notification.Name, isZigzag: Bool, isLoginWindow: Bool) {
        switch name {
        case Self.lockedNotification: screenDidLock()
        case Self.unlockedNotification: screenDidUnlock()
        case NSWorkspace.sessionDidResignActiveNotification: sessionDidResign()
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionDidBecomeActive()
        default: appActivated(isZigzag: isZigzag, isLoginWindow: isLoginWindow)
        }
    }

    func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
    }

    func screenDidLock() { set(screen: true) }
    func screenDidUnlock() { set(screen: false) }
    func sessionDidResign() { set(session: true) }
    func sessionDidBecomeActive() { set(session: false) }

    /// Another app came to the front after unlocking: that was the unlock's wake, and Zigzag's next one is its own.
    func appActivated(isZigzag: Bool, isLoginWindow: Bool) {
        guard !isZigzag, !isLoginWindow, !isLocked else { return }
        endUnlockWake()
    }

    /// Zigzag is waking: true once, when unlocking woke it.
    func takeUnlockWake() -> Bool {
        let unlocking = wakeIsUnlock
        if !isLocked { endUnlockWake() }
        return unlocking
    }

    private func set(screen: Bool? = nil, session: Bool? = nil) {
        let was = isLocked
        if let screen { screenLocked = screen }
        if let session { sessionAway = session }
        if isLocked {
            graceWork?.cancel()
            graceWork = nil
            wakeIsUnlock = true
        } else if was {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.endUnlockWake() } }
            graceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.unlockGrace, execute: work)
        }
        if was != isLocked { NotificationCenter.default.post(name: Self.changedNotification, object: self) }
    }

    private func endUnlockWake() {
        graceWork?.cancel()
        graceWork = nil
        wakeIsUnlock = false
    }

    #if DEBUG
    /// For tests: back to unlocked, with no wake pending.
    func reset() {
        let was = isLocked
        screenLocked = false
        sessionAway = false
        endUnlockWake()
        if was { NotificationCenter.default.post(name: Self.changedNotification, object: self) }
    }
    #endif
}

/// A link from another app wakes Zigzag, and macOS brings every Zigzag window forward with it, a moment before Zigzag
/// hears of the link. For a link going to Zigzag Mini, as Little Arc, the browser windows should stay where they were.
/// So unless Zigzag was plainly woken some other way, its browser windows wait unseen for that moment; a link for
/// Zigzag Mini then puts them back exactly where they were, and anything else shows them where macOS put them. The
/// other ways are told apart by what you did last and where the pointer is, never by how long ago (a busy Zigzag can
/// take a while to hear it woke): ⌘Tab, Spotlight and shortcuts end with a key, and the Dock, a notification or a
/// Zigzag window sits under the pointer. Unlocking the screen is never a link's wake either. Those are never touched.
enum MiniLinkWake {
    private static var waiting: [NSWindow] = []
    /// Each waiting window's place as Zigzag woke: the window just above it, of any app, top to bottom.
    private static var places: [(window: NSWindow, below: Int?)] = []
    private static var timeout: DispatchWorkItem?
    /// Why the last wake didn't hold the windows (nil: it did), and when.
    private static var lastReason: (reason: String?, at: Date)?
    /// How long the windows wait for the link: it comes about a twentieth of a second after the wake.
    private static let wait: TimeInterval = 0.35

    /// Until when Zigzag is bringing itself forward for a window of its own (a site installed as an app): that wake
    /// isn't a link's, and macOS brings only that window up.
    private static var ownWakeUntil: Date?

    /// Zigzag is about to activate itself for one window: the browser windows are left as they are.
    static func activatingForOneWindow() { ownWakeUntil = Date().addingTimeInterval(1) }

    static func appWillActivate() {
        if let until = ownWakeUntil {
            ownWakeUntil = nil
            if Date() < until { return }
        }
        guard MiniWindowController.opensExternalLinks, waiting.isEmpty else { return }
        wake(WindowManager.shared.controllers.compactMap(\.window), reason: reasonNotToWait())
    }

    /// Holds `windows` unseen for a link, unless `reason` says the wake plainly isn't one.
    static func wake(_ windows: [NSWindow], reason: @autoclosure () -> String?) {
        let windows = windows.filter { $0.isVisible && !$0.isMiniaturized }
        guard waiting.isEmpty, !windows.isEmpty else { return }
        let reason = reason()
        lastReason = (reason, Date())
        guard reason == nil else { return }
        // Where they were as Zigzag went to the background: by now macOS may already have raised them, and their
        // places taken now would put them back on top.
        places = Self.places(of: windows, in: settled)
        if places.count != windows.count { places = Self.places(of: windows) }
        waiting = windows
        windows.forEach { $0.alphaValue = 0 }
        let work = DispatchWorkItem { release(restoring: false) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// A window's place as Zigzag went to the background, held weakly: kept until the next time, it mustn't keep a
    /// window closed meanwhile alive.
    struct SettledPlace {
        weak var window: NSWindow?
        let below: Int?
    }

    /// Zigzag went to the background: where its windows sit among every app's, for a wake to put them back to.
    private static var settled: [SettledPlace] = []

    static func appDidResign() {
        guard MiniWindowController.opensExternalLinks else { settled = []; return }
        // A moment later, once the app you went to has come up over them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !NSApp.isActive else { return }
            settled = settledPlaces(places(of: WindowManager.shared.controllers.compactMap(\.window).filter { $0.isVisible && !$0.isMiniaturized }))
        }
    }

    static func settledPlaces(_ places: [(window: NSWindow, below: Int?)]) -> [SettledPlace] {
        places.map { SettledPlace(window: $0.window, below: $0.below) }
    }

    /// The settled places of `windows`, in the settled order; a window closed since (gone) or not among them is left out.
    static func places(of windows: [NSWindow], in settled: [SettledPlace]) -> [(window: NSWindow, below: Int?)] {
        settled.compactMap { place in
            guard let window = place.window, windows.contains(where: { $0 === window }) else { return nil }
            return (window, place.below)
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

    /// Whether windows are held unseen for a link now.
    static var isHolding: Bool { !waiting.isEmpty }

    /// Lets held windows show where they are.
    static func release() { release(restoring: false) }

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
    static func reasonNotToWait() -> String? {
        // Unlocking gives the front back to Zigzag: its windows show at once, as they were.
        if ScreenLock.shared.takeUnlockWake() { return "the screen unlocking" }
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
