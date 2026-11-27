import Foundation
import WebKit

/// How long a tab's page took to answer, show and load, for Help › Report a Problem, so a site that never answers can
/// be told from a slow one (#548). Only a load that stalls is noted, with its site and how long each step took; a
/// normal one notes nothing, and a private window's are never timed.
@MainActor
final class LoadTimings {
    struct Limits {
        /// No answer from the server by then.
        var firstByte: TimeInterval = 10
        /// Nothing shown by then.
        var commit: TimeInterval = 30
    }
    var limits = Limits()

    /// One top-level load, as seconds after its request went out.
    nonisolated struct Load: Equatable, Sendable {
        var redirects = 0
        var lastRedirect: TimeInterval?
        var firstByte: TimeInterval?
        var commit: TimeInterval?

        /// The step it's stuck in, as the report says it.
        var phase: String { firstByte == nil ? "waiting for the server" : "receiving the page" }

        /// "waiting for the server for 10.0 s, 1 redirect at 0.2 s": the steps so far.
        func detail(at elapsed: TimeInterval) -> String {
            var parts = ["\(phase) for \(Self.seconds(elapsed))"]
            if redirects > 0, let lastRedirect {
                parts.append(redirects == 1 ? "1 redirect at \(Self.seconds(lastRedirect))" : "\(redirects) redirects, last at \(Self.seconds(lastRedirect))")
            }
            if let firstByte { parts.append("answered at \(Self.seconds(firstByte))") }
            return parts.joined(separator: ", ")
        }

        /// "loaded at 14.1 s, answered at 12.3 s, shown at 12.5 s": how a stalled load ended.
        func outcome(_ ending: String, at elapsed: TimeInterval) -> String {
            var parts = ["\(ending) at \(Self.seconds(elapsed))"]
            if redirects > 0 { parts.append(redirects == 1 ? "1 redirect" : "\(redirects) redirects") }
            parts.append(firstByte.map { "answered at \(Self.seconds($0))" } ?? "no answer")
            if let commit { parts.append("shown at \(Self.seconds(commit))") }
            return parts.joined(separator: ", ")
        }

        nonisolated static func seconds(_ value: TimeInterval) -> String { String(format: "%.1f s", value) }
    }

    /// A moment by two clocks: `awake` stops while the Mac sleeps, as the checks' timers do; `total` doesn't.
    nonisolated struct Instant: Sendable {
        var awake: TimeInterval
        var total: TimeInterval

        nonisolated static var now: Instant {
            Instant(awake: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9,
                    total: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9)
        }
    }
    /// Test seam: the clocks.
    var clock: () -> Instant = { Instant.now }
    /// More sleep than this between two looks is the Mac's, not the page's.
    static let sleepSlack: TimeInterval = 2

    private var navigation: ObjectIdentifier?
    private var site: String?
    private var start = Instant(awake: 0, total: 0)
    private var load: Load?
    /// It was noted as stalled, so how it ends is noted too.
    private var noted = false
    private var check: DispatchWorkItem?

    /// A top-level request went out. Any earlier load in the tab is over.
    func started(_ navigation: WKNavigation?, url: URL?, isPrivate: Bool) {
        check?.cancel()
        check = nil
        noted = false
        guard !isPrivate, let host = url?.host(), ["http", "https"].contains(url?.scheme?.lowercased() ?? "") else {
            load = nil
            return
        }
        self.navigation = navigation.map(ObjectIdentifier.init)
        site = host
        start = clock()
        load = Load()
        schedule(after: limits.firstByte)
    }

    func redirected(_ navigation: WKNavigation?, to url: URL?) {
        guard isCurrent(navigation) else { return }
        load?.redirects += 1
        load?.lastRedirect = elapsed
        if let host = url?.host() { site = host }
    }

    /// The main frame's response headers arrived.
    func responded() {
        guard load != nil, load?.firstByte == nil else { return }
        load?.firstByte = elapsed
    }

    func committed(_ navigation: WKNavigation?) {
        guard isCurrent(navigation), load?.commit == nil else { return }
        let now = elapsed
        load?.commit = now
        if load?.firstByte == nil { load?.firstByte = now }
    }

    func finished(_ navigation: WKNavigation?) {
        end(navigation, "loaded")
    }

    /// `error` nil or a cancel: stopped, not failed (a download, a new load, Stop).
    func failed(_ navigation: WKNavigation?, error: NSError?) {
        let stopped = error.map { $0.code == NSURLErrorCancelled || ($0.domain == "WebKitErrorDomain" && [102, 204].contains($0.code)) } ?? true
        end(navigation, stopped ? "stopped" : "failed")
    }

    /// The page went away (closed, put to sleep): its load isn't waited on any more.
    func forget() {
        check?.cancel()
        check = nil
        load = nil
        noted = false
    }

    /// Seconds since the request went out, counted only while the Mac is awake.
    private var elapsed: TimeInterval { clock().awake - start.awake }

    /// The Mac slept since the request went out: how long the load took says nothing about the site.
    private var sleptSinceStart: Bool {
        let now = clock()
        return (now.total - start.total) - (now.awake - start.awake) > Self.sleepSlack
    }

    private func isCurrent(_ navigation: WKNavigation?) -> Bool {
        guard load != nil else { return false }
        guard let navigation, let current = self.navigation else { return true }
        return ObjectIdentifier(navigation) == current
    }

    private func end(_ navigation: WKNavigation?, _ ending: String) {
        guard isCurrent(navigation), let load else { return }
        check?.cancel()
        check = nil
        self.load = nil
        // A load that went slow without its check coming in time (a busy main thread) is noted too; one the Mac
        // slept through isn't.
        let slow = (load.firstByte ?? elapsed) >= limits.firstByte || (load.commit ?? elapsed) >= limits.commit
        if !sleptSinceStart, noted || (slow && ending != "stopped") {
            Diagnostics.note("Slow page load", site: site, load.outcome(ending, at: elapsed))
        }
        noted = false
    }

    /// Looks again once the load should have answered, then once it should have shown.
    private func schedule(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.look() }
        check = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
    }

    private func look() {
        guard let load, load.commit == nil, !sleptSinceStart else { return }
        let now = elapsed
        if load.firstByte == nil, now >= limits.firstByte, !noted {
            noted = true
            Diagnostics.note("Page is slow to load", site: site, load.detail(at: now))
        } else if load.firstByte != nil, now >= limits.commit {
            Diagnostics.note("Page is slow to load", site: site, load.detail(at: now))
            noted = true
            return
        }
        if now < limits.commit { schedule(after: limits.commit - now) }
    }
}
