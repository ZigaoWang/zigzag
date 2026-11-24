import AppKit
import os

/// Notices Zigzag freezing as it happens, rather than a day later from macOS: while Zigzag is in front, the main
/// thread ticks four times a second and another thread watches the ticks. A gap of a second or more is a freeze,
/// noted with how long it lasted once it's over, and with what the main thread was running: while it's stuck, the
/// watcher looks at its stack every half second, and the note names Zigzag's own functions most of those looks were
/// in (MainThreadStack). The last few freezes' whole stacks are kept in "Freezes.log", for Help › Report a Problem.
/// In the background both rest, so an idle Zigzag costs nothing.
///
/// Debug builds started with ZIGZAG_STALL_MS (say 50) watch closely instead, in front or not: every stall at least
/// that long goes to "stalls.log" in the data folder, with what ran, for measuring.
nonisolated final class Freezes: @unchecked Sendable {
    static let shared = Freezes()
    private let beat = OSAllocatedUnfairLock(initialState: (last: Date(), counts: false))
    /// Wakes the watcher when Zigzag comes to the front.
    private let wake = DispatchSemaphore(value: 0)
    private var timer: Timer?
    private var started = false
    private var tokens: [NSObjectProtocol] = []

    /// The shortest stall that counts, and how often the main thread ticks and the watcher looks.
    private let threshold: TimeInterval
    private let tick: TimeInterval
    private let lookEvery: TimeInterval
    /// Debug: every stall over `threshold` is logged, whether Zigzag is in front or not.
    private let measuring: Bool
    private static let maxLooks = 12

    private init() {
        #if DEBUG
        if let ms = ProcessInfo.processInfo.environment["ZIGZAG_STALL_MS"].flatMap(Double.init), ms > 0 {
            threshold = ms / 1000
            tick = min(0.01, threshold / 4)
            lookEvery = max(threshold / 2, 0.02)
            measuring = true
            return
        }
        #endif
        threshold = 1
        tick = 0.25
        lookEvery = 0.5
        measuring = false
    }

    func start() {
        guard !started else { return }
        started = true
        // Called at launch, on the main thread: it says which thread it is, for the looks at its stack.
        MainThreadStack.prepare()
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { Stalls.shared.start() }
            if measuring { MainActor.assumeIsolated { resume() }; return }
            let center = NotificationCenter.default
            self.tokens = [
                center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resume() }
                },
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.rest() }
                },
            ]
            if MainActor.assumeIsolated({ NSApp.isActive }) { self.resume() }
        }
        let watcher = Thread { [weak self] in self?.watch() }
        watcher.name = "Zigzag freeze watch"
        // Looks at the main thread the moment it's stuck, even with the Mac busy.
        watcher.qualityOfService = .userInteractive
        watcher.start()
    }

    @MainActor private func resume() {
        guard timer == nil else { return }
        beat.withLock { $0 = (Date(), true) }
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            self?.beat.withLock { $0 = (Date(), true) }
        }
        timer.tolerance = tick / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wake.signal()
    }

    @MainActor private func rest() {
        timer?.invalidate()
        timer = nil
        beat.withLock { $0.counts = false }
    }

    private func watch() {
        var frozenSince: Date?
        var looks: [[UInt]] = []
        var nextLook = Date.distantFuture
        while true {
            let (last, counts) = beat.withLock { $0 }
            guard counts || frozenSince != nil else {
                // In the background: wait to be woken, not on a clock.
                wake.wait()
                continue
            }
            Thread.sleep(forTimeInterval: tick)
            let now = Date()
            let gap = now.timeIntervalSince(last)
            if frozenSince == nil {
                guard counts, gap >= threshold else { continue }
                frozenSince = last
                looks = [MainThreadStack.capture()]
                nextLook = now.addingTimeInterval(lookEvery)
            } else if !counts {
                frozenSince = nil
                looks = []
            } else if gap >= min(threshold, 0.5) {
                // Still stuck: another look, to see where it's spending the time.
                if now >= nextLook, looks.count < Self.maxLooks {
                    looks.append(MainThreadStack.capture())
                    nextLook = now.addingTimeInterval(lookEvery)
                }
            } else if let since = frozenSince {
                frozenSince = nil
                let length = last.timeIntervalSince(since)
                // Longer than this is the Mac asleep, not Zigzag stuck.
                if length >= threshold, length < 120 { report(length, looks: looks) }
                looks = []
            }
        }
    }

    private func report(_ length: TimeInterval, looks: [[UInt]]) {
        let named = looks.map(MainThreadStack.frames)
        // Every look found it waiting for work: the tick was late (the Mac busy, Zigzag in the background), but
        // nothing was stuck, and nothing was in your way.
        if !named.isEmpty, named.allSatisfy(MainThreadStack.isIdle) { return }
        let chosen = MainThreadStack.mostCommon(named)
        let running = chosen.map { MainThreadStack.summary($0) } ?? ""
        if measuring {
            Self.append("\(Date().formatted(.iso8601)) \(Int(length * 1000)) ms  \(running)\n", to: Paths.support.appendingPathComponent("stalls.log"), keep: 400_000)
        }
        guard length >= 1 else { return }
        Diagnostics.note("Zigzag froze", String(format: "for %.1f s", length) + (running.isEmpty ? "" : ", in \(running)"), limit: 400)
        if let chosen {
            let lines = chosen.prefix(40).map { "  \($0.text)" }.joined(separator: "\n")
            let header = "\(Date().formatted(.iso8601)) froze for \(String(format: "%.1f", length)) s (\(looks.count) looks)\n"
            Self.append(header + lines + "\n\n", to: Self.file, keep: 40_000)
        }
    }

    // MARK: Short stalls

    /// Short stalls too, in release builds as well: a run loop observer times each piece of work the main thread does
    /// between two looks at its run loop, which costs two clock reads a turn and no wakeups of its own. Work that took
    /// `Stalls.threshold` or longer is noted in Diagnostics with what was going on: the event being handled, the last
    /// few things Zigzag noted doing (`mark`), and the front page's site. At most one note every few seconds; the
    /// ones between are counted in the next.
    @MainActor static func mark(_ what: StaticString) { Stalls.shared.mark(what) }

    /// The last few freezes' stacks.
    static var file: URL { CrashReports.folder.appendingPathComponent("Freezes.log") }

    /// The freezes kept on this Mac, newest last; empty when there were none.
    static var recentStacks: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    /// Adds to a log, keeping only its last `keep` bytes or so.
    private static func append(_ text: String, to url: URL, keep: Int) {
        var data = (try? Data(contentsOf: url)) ?? Data()
        data.append(Data(text.utf8))
        if data.count > keep, let cut = data.dropFirst(data.count - keep).firstIndex(of: UInt8(ascii: "\n")) {
            data = data.suffix(from: cut + 1)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// The main thread's work timed between two looks at its run loop (`Freezes.mark`). Its observer runs last of the run
/// loop's, so Core Animation's drawing before a wait counts too.
@MainActor
final class Stalls {
    static let shared = Stalls()
    /// Work this long, in ms, is a stall you can feel: three frames at 60 Hz.
    nonisolated static let threshold = 50.0
    /// At most one note this often; the stalls between are counted in the next.
    nonisolated static let noteEvery: TimeInterval = 10

    /// When stalls may be noted, and how many waited.
    nonisolated struct Pacing: Equatable {
        private(set) var lastNote: TimeInterval = -.infinity
        private(set) var waiting = 0
        private(set) var longestWaiting = 0.0

        /// A stall of `ms` at `now` (seconds): the count and longest of those held back since the last note, when this
        /// one is to be noted; nil when it waits.
        mutating func add(_ ms: Double, at now: TimeInterval) -> (more: Int, longest: Double)? {
            guard now - lastNote >= Stalls.noteEvery else {
                waiting += 1
                longestWaiting = max(longestWaiting, ms)
                return nil
            }
            defer { lastNote = now; waiting = 0; longestWaiting = 0 }
            return (waiting, longestWaiting)
        }
    }

    private var observer: CFRunLoopObserver?
    private var last: UInt64 = 0
    private var awake = false
    private var pacing = Pacing()
    /// What Zigzag noted doing lately, oldest first, at most `keptMarks`.
    private var marks: [(what: StaticString, at: UInt64)] = []
    private static let keptMarks = 8
    private static let msPerTick: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom) / 1_000_000
    }()

    func start() {
        guard observer == nil else { return }
        // Once a turn before its sources, and around each wait: enough to time each turn's work, few calls.
        let activities: CFRunLoopActivity = [.beforeSources, .beforeWaiting, .afterWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated { Stalls.shared.turned(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func mark(_ what: StaticString) {
        if marks.count >= Self.keptMarks { marks.removeFirst() }
        marks.append((what, mach_absolute_time()))
    }

    private func turned(_ activity: CFRunLoopActivity) {
        let now = mach_absolute_time()
        if awake, last != 0, now > last {
            let ms = Double(now - last) * Self.msPerTick
            // Longer than a second in front is a freeze, which `Freezes` notes with its stack; far longer, the Mac slept.
            if ms >= Self.threshold, ms < 30_000, ms < 1000 || !NSApp.isActive { stalled(ms, since: last) }
        }
        awake = activity != .beforeWaiting
        last = now
    }

    private func stalled(_ ms: Double, since start: UInt64) {
        guard let (more, longest) = pacing.add(ms, at: ProcessInfo.processInfo.systemUptime) else { return }
        let during = marks.filter { $0.at >= start }.map { "\($0.what)" }
        let startUptime = Double(start) * Self.msPerTick / 1000
        let event = NSApp.currentEvent.flatMap { $0.timestamp >= startUptime - 0.005 ? Self.name(of: $0.type) : nil }
        let front = WindowManager.shared.keyController
        Diagnostics.note("Zigzag stalled", site: front?.tabManager.selectedTab?.url?.host(),
                         Self.detail(ms: ms, event: event, marks: during, more: more, longest: longest),
                         isPrivate: front?.tabManager.isPrivate ?? false)
    }

    /// "120 ms, handling a scroll, in session save, sidebar reload (3 more since, longest 80 ms)".
    nonisolated static func detail(ms: Double, event: String?, marks: [String], more: Int, longest: Double) -> String {
        var seen = Set<String>()
        let named = marks.filter { seen.insert($0).inserted }.suffix(4)
        var text = "\(Int(ms.rounded())) ms"
        if let event { text += ", handling \(event)" }
        if !named.isEmpty { text += ", in " + named.joined(separator: ", ") }
        if more > 0 { text += " (\(more) more since, longest \(Int(longest.rounded())) ms)" }
        return text
    }

    nonisolated static func name(of type: NSEvent.EventType) -> String {
        switch type {
        case .scrollWheel: "a scroll"
        case .keyDown, .keyUp: "a key"
        case .flagsChanged: "a modifier key"
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: "a click"
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: "a drag"
        case .mouseMoved, .mouseEntered, .mouseExited: "the pointer moving"
        case .magnify, .rotate, .swipe, .smartMagnify, .gesture, .beginGesture, .endGesture, .pressure: "a gesture"
        default: "an event"
        }
    }
}
