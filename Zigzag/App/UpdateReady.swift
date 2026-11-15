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
nonisolated enum UpdateFeed {
    struct Item: Equatable, Sendable {
        var build: String
        var version: String
    }

    /// The newest item this Mac can run: by build, skipping items for another channel, without a download, or for
    /// a newer or older macOS than `system`.
    static func newest(in data: Data, system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Item? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        guard parser.parse() else { return nil }
        let running = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return reader.items
            .filter { item in
                item.channel == nil && item.hasEnclosure && !item.build.isEmpty
                    && !(item.minimumSystem.map { UpdateReadiness.isNewer($0, than: running) } ?? false)
                    && !(item.maximumSystem.map { UpdateReadiness.isNewer(running, than: $0) } ?? false)
            }
            .max { UpdateReadiness.isNewer($1.build, than: $0.build) }
            .map { Item(build: $0.build, version: $0.version.isEmpty ? $0.build : $0.version) }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        struct Entry {
            var build = "", version = "", channel: String?, minimumSystem: String?, maximumSystem: String?
            var hasEnclosure = false
        }
        var items: [Entry] = []
        private var current: Entry?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "item" { current = Entry() }
            guard name == "enclosure", current != nil else { return }
            current?.hasEnclosure = true
            // Older feeds put the versions on the enclosure.
            if current?.build.isEmpty == true, let build = attributes["sparkle:version"] { current?.build = build }
            if current?.version.isEmpty == true, let version = attributes["sparkle:shortVersionString"] { current?.version = version }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "item": if let current { items.append(current) }; current = nil
            case "sparkle:version": current?.build = value
            case "sparkle:shortVersionString": current?.version = value
            case "sparkle:channel": current?.channel = value
            case "sparkle:minimumSystemVersion": current?.minimumSystem = value
            case "sparkle:maximumSystemVersion": current?.maximumSystem = value
            default: break
            }
            text = ""
        }
    }
}
