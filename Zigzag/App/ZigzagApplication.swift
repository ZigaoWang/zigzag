import AppKit

/// Zigzag's application object. In Debug builds, a test copy started with `ZIGZAG_STAY_BEHIND=1` never brings itself
/// forward, so checking a change in it doesn't take the screen or the keyboard from whatever you're doing.
final class ZigzagApplication: NSApplication {
    /// One that left a Swift job leaves the runtime pointing at the job's freed frame, which a later deinit crashes on.
    /// Nonisolated: the main actor check itself reads that freed frame.
    nonisolated override func reportException(_ exception: NSException) {
        switch Self.jobException(name: exception.name.rawValue, reason: exception.reason, thrownAt: exception.callStackSymbols,
                                 caughtAt: Thread.callStackSymbols, crashes: Self.crashesOnJobExceptions) {
        case .crash(let message): fatalError(message)
        case .note(let kind, let detail): Diagnostics.note(kind, detail, limit: 1000)
        case nil: break
        }
        typealias Report = @convention(c) (NSApplication, Selector, NSException) -> Void
        let selector = #selector(NSApplication.reportException(_:))
        unsafeBitCast(class_getMethodImplementation(NSApplication.self, selector), to: Report.self)(self, selector, exception)
    }

    /// Whether a Swift job ran between the throw and the catch.
    nonisolated static func leftASwiftJob(thrownAt: [String], caughtAt: [String]) -> Bool {
        func jobs(_ frames: [String]) -> Int { frames.count { $0.contains("swift_job_run") } }
        return jobs(thrownAt) > jobs(caughtAt)
    }

    /// Tests and test copies crash on one, so the throw is named; the app notes it for Report a Problem.
    #if DEBUG
    nonisolated static let crashesOnJobExceptions = true
    #else
    nonisolated static let crashesOnJobExceptions = false
    #endif

    nonisolated enum JobException: Equatable {
        case crash(String)
        case note(kind: String, detail: String)
    }

    /// What to do with an exception AppKit caught: nothing unless it left a Swift job.
    nonisolated static func jobException(name: String, reason: String?, thrownAt: [String], caughtAt: [String],
                                         crashes: Bool) -> JobException? {
        guard leftASwiftJob(thrownAt: thrownAt, caughtAt: caughtAt) else { return nil }
        let kind = "Exception thrown out of a Swift job", what = "\(name): \(reason ?? "")"
        if crashes { return .crash((["\(kind): \(what)"] + thrownAt).joined(separator: "\n")) }
        let top = thrownAt.prefix(8).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return .note(kind: kind, detail: ([what] + top).joined(separator: " | "))
    }

    /// A key an AI app pressed in a page (press_key) that the page didn't take comes back here from WebKit on its
    /// way to the menus, as keys do. It stops here: it never runs a Zigzag shortcut or reaches anything but the page.
    override func sendEvent(_ event: NSEvent) {
        if MCPKeyDelivery.stopsOnTheWayBack(event) { return }
        // Your own clicks and keys, for a page's pop-up that WebKit didn't count as clicked.
        PopupNotice.noteInput(event)
        super.sendEvent(event)
    }

    #if DEBUG
    static let staysBehind = ProcessInfo.processInfo.environment["ZIGZAG_STAY_BEHIND"] == "1"
    #else
    static let staysBehind = false
    #endif

    /// Running for AI apps alone, Zigzag never comes forward until you open it.
    override func activate() {
        guard !Self.staysBehind, !Headless.isBackgroundOnly else { return }
        super.activate()
    }

    override func activate(ignoringOtherApps flag: Bool) {
        guard !Self.staysBehind, !Headless.isBackgroundOnly else { return }
        super.activate(ignoringOtherApps: flag)
    }
}
