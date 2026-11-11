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
