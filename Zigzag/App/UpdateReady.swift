import Foundation

/// An update Sparkle downloaded and staged, for the card, the Zigzag menu and Settings. Sparkle installs it on quit. It
/// stops reading the feed once staged, so `isStale` lets a newer release replace it.
nonisolated struct UpdateReadiness: Equatable, Sendable {
    struct Staged: Equatable, Sendable {
        /// Display version, e.g. 0.9.2-beta.3.
        var version: String
        /// Build number (CFBundleVersion), used for comparisons.
        var build: String
    }

    private(set) var staged: Staged?
    /// Build whose card was dismissed this run; a newer build shows it again.
    private(set) var dismissedBuild: String?

    /// The card in the sidebar.
    var showsCard: Bool { staged != nil && staged?.build != dismissedBuild }
    /// Restart to Update is available whenever an update is staged.
    var canRestart: Bool { staged != nil }

    /// An older build never replaces a staged one.
    mutating func stage(version: String, build: String) {
        if let staged, Self.isNewer(staged.build, than: build) { return }
        staged = Staged(version: version, build: build)
    }

    /// Hides the card until a newer update is staged; it still installs on quit.
    mutating func dismiss() {
        dismissedBuild = staged?.build
    }

    /// A check found the staged update: show the card again.
    mutating func undismiss() {
        dismissedBuild = nil
    }

    /// You put the card away for the update that's staged.
    var isDismissed: Bool { staged != nil && staged?.build == dismissedBuild }

    /// Installed, replaced, or gone from the feed.
    mutating func clear() {
        staged = nil
    }

    /// The feed's newest build is newer than the staged one: the staged one is out of date.
    func isStale(feedNewest: String?) -> Bool {
        guard let staged, let feedNewest else { return false }
        return Self.isNewer(feedNewest, than: staged.build)
    }

    /// Compares as Sparkle does, number by number (116 > 99, 1.10 > 1.9).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    }
}

/// The update card's state for a manual update: downloading, preparing, then ready. `available` is one found with
/// automatic installs off.
nonisolated enum UpdateCardState: Equatable, Sendable {
    /// `total` is 0 until the size is known.
    case downloading(version: String, received: UInt64, total: UInt64)
    /// Sparkle is unpacking and checking the signature.
    case preparing(version: String)
    case ready(version: String)
    case available(version: String)

    var version: String {
        switch self {
        case .downloading(let version, _, _), .preparing(let version), .ready(let version), .available(let version): version
        }
    }

    /// Downloading or preparing: the bar shows, no buttons.
    var isBusy: Bool {
        switch self {
        case .downloading, .preparing: true
        case .ready, .available: false
        }
    }

    /// Download fraction, 0 to 1, when the size is known.
    var share: Double? {
        guard case .downloading(_, let received, let total) = self, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    var isReady: Bool { if case .ready = self { true } else { false } }

    /// Changed enough to redraw: a new step or a whole percent.
    func differsVisibly(from old: UpdateCardState?) -> Bool {
        guard let old, let share, let before = old.share, old.version == version else { return self != old }
        return abs(share - before) >= 0.01 || (share >= 1) != (before >= 1)
    }
}

/// An update found while automatic installs are off (#492): offered on the card until you get it or skip it.
nonisolated struct UpdateOffer: Equatable, Sendable {
    enum Choice: Equatable, Sendable {
        /// Download it (and install, as before).
        case install
        /// Show it on the card; Sparkle leaves it alone for now.
        case offer
        /// Tell Sparkle to skip it, so background checks stop finding it.
        case skip
    }

    /// The update on the card.
    private(set) var available: UpdateReadiness.Staged?
    /// Build you skipped, until Sparkle records the skip on its next background check.
    private(set) var skipping: String?

    /// What to do with an update Sparkle found that isn't downloaded yet. `getting` is a click on Update; `background`
    /// is a check you didn't ask for.
    mutating func found(_ update: UpdateReadiness.Staged, automatic: Bool, getting: Bool, background: Bool) -> Choice {
        if automatic || getting { return .install }
        if background, update.build == skipping {
            skipping = nil
            return .skip
        }
        // A newer build, or a check you asked for, is offered even after a skip.
        skipping = nil
        available = update
        return .offer
    }

    /// Skip This Version: off the card now, recorded by Sparkle on the next background check.
    mutating func skip() {
        guard let available else { return }
        skipping = available.build
        self.available = nil
    }

    /// Downloaded, gone from the feed, or automatic installs back on.
    mutating func clear() {
        available = nil
        skipping = nil
    }
}

/// Display version: 0.9.2-beta.1 reads "0.9.2 beta 1". Reports and logs keep the raw version.
nonisolated enum VersionName {
    /// Raw version, e.g. 0.9.2-beta.1.
    static var running: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    static func display(_ version: String) -> String {
        guard let dash = version.firstIndex(of: "-") else { return version }
        let base = String(version[..<dash])
        let tag = version[version.index(after: dash)...].split(separator: ".").map(String.init)
        if tag.count == 2, tag[0].lowercased() == "beta", Int(tag[1]) != nil {
            let number = tag[1]
            return String(localized: "\(base) beta \(number)",
                          comment: "A beta of Zigzag as people read it: 0.9.2 beta 1. The placeholders are the version and the beta's number.")
        }
        return ([base] + tag).joined(separator: " ")
    }
}

/// Background update checks: every few hours, and after waking if it's been a while, at most once an hour.
nonisolated enum UpdateSchedule {
    /// Sparkle's SUScheduledCheckInterval; also how often a staged update is checked against the feed.
    static let interval: TimeInterval = 4 * 60 * 60
    /// The least time between two checks, however many wakes come between.
    static let minimumGap: TimeInterval = 60 * 60

    /// On wake, after `minimumGap`; on the timer, after `interval`.
    static func shouldCheck(lastCheck: Date?, now: Date, onWake: Bool) -> Bool {
        guard let lastCheck else { return true }
        let since = now.timeIntervalSince(lastCheck)
        // Clock set back.
        if since < 0 { return true }
        return since >= (onWake ? minimumGap : interval)
    }
}

/// Reads the newest version on the appcast, only to tell whether the staged update is still newest; Sparkle does all
/// downloads and installs. Filters mirror SUAppcastDriver; an item that can't be judged for sure (a phased rollout
/// without a readable date) doesn't count.
nonisolated enum UpdateFeed {
    struct Item: Equatable, Sendable {
        var build: String
        var version: String
    }

    /// What Sparkle knows of this copy of Zigzag when it reads the feed in the background.
    struct Host: Sendable {
        var build: String
        var system: OperatingSystemVersion
        /// Phased rollout group 0–6; nil means not picked yet, treated as the last group.
        var phasedGroup: Int?
        var now: Date
        var isIntel: Bool

        static var current: Host {
            #if arch(x86_64)
            let intel = true
            #else
            let intel = false
            #endif
            // Sparkle stores the seed in defaults and uses it modulo 7.
            let seed = UserDefaults.standard.object(forKey: "SUUpdateGroupIdentifier") as? NSNumber
            return Host(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
                        system: ProcessInfo.processInfo.operatingSystemVersion,
                        phasedGroup: seed.map { Int($0.uint32Value % 7) }, now: Date(), isIntel: intel)
        }
    }

    /// The newest item Sparkle's background check would offer, skipping what Sparkle skips: other channels or OS,
    /// delta-only or informational, unsupported macOS or hardware, `minimumUpdateVersion`, `minimumAutoupdateVersion`,
    /// and not yet rolled out to this group.
    static func newest(in data: Data, host: Host = .current) -> Item? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        guard parser.parse() else { return nil }
        let system = host.system
        let running = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        func newer(_ a: String?, than b: String) -> Bool { a.map { UpdateReadiness.isNewer($0, than: b) } ?? false }
        return reader.items
            .filter { item in
                item.channel == nil && item.hasFullEnclosure && !item.build.isEmpty && !item.informational
                    && (item.os == nil || item.os == "macos")
                    && !newer(item.minimumSystem, than: running)
                    && !(item.maximumSystem.map { UpdateReadiness.isNewer(running, than: $0) } ?? false)
                    && !newer(item.minimumUpdate, than: host.build)
                    && !newer(item.minimumAutoupdate, than: host.build)
                    // Sparkle treats macOS 27+ as Apple silicon only.
                    && !(host.isIntel && (item.hardware.contains("arm64") || !newer("27", than: item.minimumSystem ?? "0")))
                    && rolledOut(item, to: host)
            }
            .max { UpdateReadiness.isNewer($1.build, than: $0.build) }
            .map { Item(build: $0.build, version: $0.version.isEmpty ? $0.build : $0.version) }
    }

    /// Group n gets an item n intervals after its date.
    private static func rolledOut(_ item: Reader.Entry, to host: Host) -> Bool {
        guard let interval = item.phasedInterval else { return true }
        guard let seconds = TimeInterval(interval), let date = item.date.flatMap({ pubDate.date(from: $0) }) else { return false }
        return host.now.timeIntervalSince(date) >= seconds * TimeInterval(host.phasedGroup ?? 6)
    }

    /// The format Sparkle reads pubDate with.
    private static let pubDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "E, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    private final class Reader: NSObject, XMLParserDelegate {
        struct Entry {
            var build = "", version = "", channel: String?, minimumSystem: String?, maximumSystem: String?
            var minimumUpdate: String?, minimumAutoupdate: String?, phasedInterval: String?, date: String?, os: String?
            var hardware: Set<String> = []
            var informational = false
            /// A full app enclosure, not just a delta.
            var hasFullEnclosure = false
        }
        var items: [Entry] = []
        private var current: Entry?
        private var text = ""
        /// Inside sparkle:deltas or sparkle:informationalUpdate.
        private var nested = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "item" { current = Entry(); nested = false }
            if name == "sparkle:deltas" || name == "sparkle:informationalUpdate" { nested = true }
            if name == "sparkle:informationalUpdate" { current?.informational = true }
            guard name == "enclosure", current != nil, !nested, attributes["sparkle:deltaFrom"] == nil else { return }
            current?.hasFullEnclosure = true
            current?.os = attributes["sparkle:os"]
            // Older feeds put the versions on the enclosure.
            if current?.build.isEmpty == true, let build = attributes["sparkle:version"] { current?.build = build }
            if current?.version.isEmpty == true, let version = attributes["sparkle:shortVersionString"] { current?.version = version }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "item": if let current { items.append(current) }; current = nil
            case "sparkle:deltas", "sparkle:informationalUpdate": nested = false
            case _ where nested: break
            case "sparkle:version": current?.build = value
            case "sparkle:shortVersionString": current?.version = value
            case "sparkle:channel": current?.channel = value
            case "sparkle:minimumSystemVersion": current?.minimumSystem = value
            case "sparkle:maximumSystemVersion": current?.maximumSystem = value
            case "sparkle:minimumUpdateVersion": current?.minimumUpdate = value
            case "sparkle:minimumAutoupdateVersion": current?.minimumAutoupdate = value
            case "sparkle:phasedRolloutInterval": current?.phasedInterval = value
            case "sparkle:hardwareRequirements":
                current?.hardware = Set(value.lowercased().split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init))
            case "pubDate": current?.date = value
            default: break
            }
            text = ""
        }
    }
}
