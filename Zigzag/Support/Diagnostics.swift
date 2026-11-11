import AppKit
import os

/// What went wrong lately, for Help › Report a Problem: a page that didn't load or stopped, a pop-up blocked, a
/// question a site asked and the answer, an error a page threw, a moment Zigzag froze. Each with the time and the
/// site it happened on (its name only, never the page's address), so a report says where to look.
///
/// Kept on this Mac only: the last 300 events, in memory and in "Diagnostics", so they outlast a crash. Nothing from a
/// private window names its site. Nothing leaves the Mac unless you send a report yourself.
nonisolated enum Diagnostics {
    struct Event: Codable, Sendable {
        let date: Date
        let kind: String
        let site: String?
        let detail: String?
        var count = 1
    }

    private static let keep = 300
    private static let state = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var events: [Event] = []
        var saveScheduled = false
        /// Events per page, so one page in a loop of errors can't push out everything else.
        var perSite: [String: Int] = [:]
    }
    private static let queue = DispatchQueue(label: "app.zigzag.diagnostics", qos: .utility)
    private static let log = Logger(subsystem: "wang.zigao.zigzag", category: "diagnostics")
    private static var file: URL { CrashReports.folder.appendingPathComponent("Events.json") }
    /// There while Zigzag runs, gone once it quits properly: still there at launch means the last run ended badly.
    private static var runningMark: URL { CrashReports.folder.appendingPathComponent("Running") }

    /// Notes something that went wrong (or a step in a flow that tends to: a pop-up, a sign-in). `site` is a host;
    /// pass `isPrivate` from a private window and the site is left out. Repeats in a row are counted, not added.
    /// `limit`: how long the detail may be; a freeze's says what was running, which takes more room than an error.
    static func note(_ kind: String, site: String? = nil, _ detail: String? = nil, isPrivate: Bool = false, limit: Int = 200) {
        let site = isPrivate ? nil : site.map { $0.withoutWWW }.flatMap { $0.isEmpty ? nil : $0 }
        // A private window's own words (an error quoting a host, a certificate naming its site) never land here:
        // only an error's code, which names nothing.
        let detail = isPrivate ? detail.flatMap(errorCode) : detail.map { clean($0, limit: limit) }
        let (added, schedule) = state.withLock { s -> (Bool, Bool) in
            let now = Date()
            if var last = s.events.last, last.kind == kind, last.site == site, last.detail == detail, now.timeIntervalSince(last.date) < 60 {
                last.count += 1
                s.events[s.events.count - 1] = last
            } else {
                let key = "\(site ?? "")|\(kind)"
                // A page throwing the same kind of thing over and over: the first 20 say enough.
                guard s.perSite[key, default: 0] < 20 else { return (false, false) }
                s.perSite[key, default: 0] += 1
                s.events.append(Event(date: now, kind: kind, site: site, detail: detail))
                if s.events.count > keep { s.events.removeFirst(s.events.count - keep) }
            }
            // Saved a moment later, once for a burst.
            if s.saveScheduled { return (true, false) }
            s.saveScheduled = true
            return (true, true)
        }
        guard added else { return }
        log.notice("\(kind, privacy: .public) \(site ?? "", privacy: .private) \(detail ?? "", privacy: .private)")
        if schedule { queue.asyncAfter(deadline: .now() + 2) { save() } }
    }

    /// Clearing history: what was noted since then goes too, as it names the sites you were on.
    static func forget(since date: Date?) {
        state.withLock { s in
            s.events.removeAll { date == nil || $0.date >= date! }
            s.perSite = [:]
        }
        queue.async { save() }
    }

    /// The events kept, oldest first.
    static var events: [Event] { state.withLock { $0.events } }

    /// At launch: the last run's events come back, marked off, and a run that never quit properly is noted.
    static func start() {
        let folder = CrashReports.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
        let endedBadly = FileManager.default.fileExists(atPath: runningMark.path)
        state.withLock { s in
            s.events = Array(previous.suffix(keep - 2))
            if !previous.isEmpty || endedBadly {
                s.events.append(Event(date: Date(), kind: endedBadly ? "Zigzag started after quitting unexpectedly" : "Zigzag started",
                                      site: nil, detail: version))
            }
        }
        try? Data().write(to: runningMark)
        Freezes.shared.start()
        if endedBadly { queue.async { save() } }
    }

    /// Zigzag is quitting properly: the record is saved, and the next launch knows it wasn't a crash.
    static func stop() {
        queue.sync { save() }
        try? FileManager.default.removeItem(at: runningMark)
    }

    private static func save() {
        let events = state.withLock { s -> [Event] in
            s.saveScheduled = false
            return s.events
        }
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// "(NSURLErrorDomain -1202)" from the end of a described error, or nil.
    private static func errorCode(_ text: String) -> String? {
        text.range(of: #"\([A-Za-z]+ -?\d+\)$"#, options: .regularExpression).map { String(text[$0]) }
    }

    /// A page's own words, kept short, with any address in them cut to its site: an error can quote a link that
    /// carries a token or an email.
    static func clean(_ text: String, limit: Int = 200) -> String {
        var out = text.replacingOccurrences(of: "\n", with: " ")
        if let links = linkPattern {
            out = links.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        }
        if let emails = emailPattern {
            out = emails.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "(email)")
        }
        return out.count > limit ? String(out.prefix(limit)) + "…" : out
    }

    // Made once: every tab put to sleep or page that didn't load is noted, and making them is most of the cost.
    private static let linkPattern = try? NSRegularExpression(pattern: #"[a-zA-Z][a-zA-Z0-9+.-]*://([^/\s'"?#)]+)[^\s'")]*"#)
    private static let emailPattern = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)

    /// An error in plain words with its code, so it can be looked up: "The site’s security certificate isn’t valid
    /// (NSURLErrorDomain -1202)".
    static func describe(_ error: NSError) -> String {
        "\(clean(error.localizedDescription)) (\(error.domain) \(error.code))"
    }

    /// The events as report lines: "14:02:11  Page didn't load  teams.microsoft.com  Secure connection failed (×3)".
    static func lines(since: Date? = nil) -> [String] {
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        let day = Date.FormatStyle(date: .abbreviated, time: .standard)
        let today = Calendar.current.startOfDay(for: Date())
        return events.filter { since == nil || $0.date >= since! }.map { e in
            var line = "\(e.date >= today ? e.date.formatted(time) : e.date.formatted(day))  \(e.kind)"
            if let site = e.site { line += "  \(site)" }
            if let detail = e.detail, !detail.isEmpty { line += "  \(detail)" }
            if e.count > 1 { line += " (×\(e.count))" }
            return line
        }
    }
}

