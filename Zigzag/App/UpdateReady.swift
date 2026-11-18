import Foundation

/// An update Sparkle has downloaded and staged, waiting for Zigzag to restart into it: what the sidebar's card, the
/// Zigzag menu and Settings › General show, and whether you've put the card away for now.
///
/// Sparkle installs a staged update whenever Zigzag quits, so putting the card away never loses it. Once staged,
/// Sparkle stops reading the feed until the update is installed, so a newer version can come out meanwhile: `isStale`
/// says when the feed has one, and the staged update is then let go for it.
nonisolated struct UpdateReadiness: Equatable, Sendable {
    struct Staged: Equatable, Sendable {
        /// What people see: 0.9.2, 0.9.2-beta.3.
        var version: String
        /// Sparkle's version, the build number, which is what's compared.
        var build: String
    }

    private(set) var staged: Staged?
    /// The build whose card you put away, for as long as Zigzag runs. A newer one brings the card back.
    private(set) var dismissedBuild: String?

    /// The card in the sidebar.
    var showsCard: Bool { staged != nil && staged?.build != dismissedBuild }
    /// Zigzag › Restart to Update and Settings' Restart: there while an update is staged, card put away or not.
    var canRestart: Bool { staged != nil }

    /// An update is staged. One older than the one already staged never takes its place.
    mutating func stage(version: String, build: String) {
        if let staged, Self.isNewer(staged.build, than: build) { return }
        staged = Staged(version: version, build: build)
    }

    /// The card's ×: away until a newer update is staged. The update still installs when Zigzag quits.
    mutating func dismiss() {
        dismissedBuild = staged?.build
    }

    /// The staged update is gone: installed, let go for a newer one, or no longer on the feed.
    mutating func clear() {
        staged = nil
    }

    /// The feed's newest build is newer than the staged one: the staged one is out of date.
    func isStale(feedNewest: String?) -> Bool {
        guard let staged, let feedNewest else { return false }
        return Self.isNewer(feedNewest, than: staged.build)
    }

    /// Build numbers compared as Sparkle compares them: by each number in turn (116 after 99, 1.10 after 1.9).
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

/// Zigzag's version as people read it: 0.9.2-beta.1 is "0.9.2 beta 1", and a stable version stays as it is. Every
/// place that shows a version to people goes through it; reports and logs keep the version as written.
nonisolated enum VersionName {
    /// This copy of Zigzag's version, as written (0.9.2-beta.1).
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

/// How often Zigzag looks for updates on its own, quietly: every few hours while it runs, and on waking from sleep
/// when it's been a while, never more than once an hour.
nonisolated enum UpdateSchedule {
    /// Sparkle's own interval (SUScheduledCheckInterval), and how often a staged update is checked against the feed.
    static let interval: TimeInterval = 4 * 60 * 60
    /// The least time between two checks, however many wakes come between.
    static let minimumGap: TimeInterval = 60 * 60

    /// Whether to look now: on a wake, after `minimumGap`; on the clock, after `interval`.
    static func shouldCheck(lastCheck: Date?, now: Date, onWake: Bool) -> Bool {
        guard let lastCheck else { return true }
        let since = now.timeIntervalSince(lastCheck)
        // A clock set back: the last check looks like it's to come, so look now.
        if since < 0 { return true }
        return since >= (onWake ? minimumGap : interval)
    }
}

/// The newest version on an update feed (a Sparkle appcast), read without downloading anything else: only to tell
/// whether the update Sparkle has staged is still the newest. Sparkle itself does every download, check and install.
///
/// A staged update is let go only for one Sparkle will fetch in its place, so an item counts only when Sparkle's own
/// background check would take it: the filters follow Sparkle's (SUAppcastDriver), and where one can't be told for
/// sure (a phased rollout without a date it reads), the item doesn't count.
nonisolated enum UpdateFeed {
    struct Item: Equatable, Sendable {
        var build: String
        var version: String
    }

    /// What Sparkle knows of this copy of Zigzag when it reads the feed in the background.
    struct Host: Sendable {
        /// The running build (CFBundleVersion).
        var build: String
        var system: OperatingSystemVersion
        /// Sparkle's phased rollout group, 0 to 6; nil before Sparkle has picked one, taken as the last group.
        var phasedGroup: Int?
        var now: Date
        var isIntel: Bool

        static var current: Host {
            #if arch(x86_64)
            let intel = true
            #else
            let intel = false
            #endif
            // Sparkle keeps its group's seed in the app's defaults, and takes it modulo seven.
            let seed = UserDefaults.standard.object(forKey: "SUUpdateGroupIdentifier") as? NSNumber
            return Host(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
                        system: ProcessInfo.processInfo.operatingSystemVersion,
                        phasedGroup: seed.map { Int($0.uint32Value % 7) }, now: Date(), isIntel: intel)
        }
    }

    /// The newest item a background check by Sparkle would offer this Mac, by build. Skipped, as Sparkle skips
    /// them: items for another channel or OS, with only a delta or nothing to download, informational only, for a
    /// newer or older macOS, for Apple silicon on an Intel Mac, that can't update this build
    /// (`minimumUpdateVersion`), a major upgrade Sparkle doesn't fetch by itself (`minimumAutoupdateVersion`), and
    /// one not yet rolled out to this Mac's phased rollout group.
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
                    // Sparkle takes macOS 27 and later as Apple silicon only.
                    && !(host.isIntel && (item.hardware.contains("arm64") || !newer("27", than: item.minimumSystem ?? "0")))
                    && rolledOut(item, to: host)
            }
            .max { UpdateReadiness.isNewer($1.build, than: $0.build) }
            .map { Item(build: $0.build, version: $0.version.isEmpty ? $0.build : $0.version) }
    }

    /// Sparkle's phased rollout: group n gets an item n intervals after its date.
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
            /// An enclosure of the whole app, not only a delta from one version.
            var hasFullEnclosure = false
        }
        var items: [Entry] = []
        private var current: Entry?
        private var text = ""
        /// Inside sparkle:deltas or sparkle:informationalUpdate, whose contents aren't the item's own.
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
