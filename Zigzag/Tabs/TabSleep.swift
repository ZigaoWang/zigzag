import Foundation

/// Why a page's process ended. WebKit says (in its private `_WKProcessTerminationReason`) when it ended a page for
/// going over the memory or processor time it allows one; anything else looks like a crash to it, macOS taking the
/// memory back included, so a page that stops while the Mac is short of memory is put down to that.
nonisolated enum PageStop: Equatable, Sendable {
    case pageMemory, macMemory, processor, crash

    /// `lowOnMemoryAgo`: how long since macOS last said memory was short.
    init(webKitReason: Int?, lowOnMemoryAgo: TimeInterval?) {
        switch webKitReason {
        case 0: self = .pageMemory
        case 1: self = .processor
        default: self = (lowOnMemoryAgo ?? .infinity) < MemoryPressure.lasts ? .macMemory : .crash
        }
    }

    var isMemory: Bool { self == .pageMemory || self == .macMemory }

    /// For Help › Report a Problem.
    var detail: String {
        switch self {
        case .pageMemory: "used too much memory"
        case .macMemory: "Mac low on memory"
        case .processor: "used too much CPU"
        case .crash: "crashed"
        }
    }

    /// Said over the page once it has loaded again, for the memory cases; a crash reload stays quiet, as before.
    var reloadedText: String? {
        switch self {
        case .pageMemory: String(localized: "This page was reloaded because it was using a lot of memory", comment: "Toast after a page loaded again because WebKit ended it for using too much memory.")
        case .macMemory: String(localized: "This page was reloaded because your Mac was low on memory", comment: "Toast after a page loaded again because macOS ended it while memory was short.")
        case .processor, .crash: nil
        }
    }
}

/// macOS saying memory is running short (before it starts ending processes): a page that stops soon after is put
/// down to it.
@MainActor
final class MemoryPressure {
    static let shared = MemoryPressure()
    /// How long after a warning the Mac counts as short of memory.
    nonisolated static let lasts: TimeInterval = 2 * 60

    private(set) var lastWarning: Date?
    private var source: DispatchSourceMemoryPressure?

    var isLow: Bool { lastWarning.map { Date().timeIntervalSince($0) < Self.lasts } ?? false }
    var warningAgo: TimeInterval? { lastWarning.map { Date().timeIntervalSince($0) } }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            let critical = source?.data.contains(.critical) == true
            MainActor.assumeIsolated { MemoryPressure.shared.warned(critical: critical) }
        }
        source.activate()
        self.source = source
    }

    func warned(critical: Bool) {
        let now = Date()
        // Noted once in a while: macOS can say it again and again.
        if !isLow { Diagnostics.note("Mac low on memory", critical ? "critical" : "warning") }
        lastWarning = now
    }
}
