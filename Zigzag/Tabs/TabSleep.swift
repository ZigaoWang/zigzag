import Foundation

/// When a background tab gives its memory back: it sleeps (its page is let go, its history and place kept) and loads
/// again where it was when you go back to it.
///
/// A reload is never quite free: a long page that builds itself (a forum thread far down, a feed) can come back
/// somewhere else, and a live one misses what came in. Safari never sleeps a tab on its own, and Edge waits two hours.
/// So a tab out of sight sleeps after an hour, after a quarter of an hour once more than 20 are awake, and after
/// five minutes only while macOS says it's short of memory (sooner Zigzag's choice of tab than macOS's choice of
/// process). Never while something you typed is still in it.
nonisolated enum TabSleep {
    struct Candidate: Sendable {
        let id: UUID
        /// How long since you last looked at it.
        let unseen: TimeInterval
        /// On screen, playing, in a call, or from a site that notifies.
        let mustStay: Bool
        let hasTypedText: Bool
    }

    static let idle: TimeInterval = 60 * 60
    static let crowd = 20
    static let crowdedIdle: TimeInterval = 15 * 60
    static let lowOnMemoryIdle: TimeInterval = 5 * 60

    /// The tabs to sleep now, longest unseen first. `awake`: how many tabs have their page loaded, all told.
    static func sleepers(_ tabs: [Candidate], awake: Int, lowOnMemory: Bool) -> [UUID] {
        var awake = awake
        var out: [UUID] = []
        for tab in tabs.sorted(by: { $0.unseen > $1.unseen }) where !tab.mustStay && !tab.hasTypedText {
            guard tab.unseen > idle || (lowOnMemory && tab.unseen > lowOnMemoryIdle) || (awake > crowd && tab.unseen > crowdedIdle) else { continue }
            out.append(tab.id)
            awake -= 1
        }
        return out
    }
}

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

/// macOS saying memory is running short (before it starts ending processes): background tabs sleep sooner, and a
/// page that stops soon after is put down to it.
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
        for controller in WindowManager.shared.controllers { controller.tabManager.sleepIdleTabs() }
    }
}
