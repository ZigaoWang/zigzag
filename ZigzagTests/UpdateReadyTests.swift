import Foundation
import Testing
@testable import Zigzag

/// An update that's ready: when the sidebar's card shows, putting it away, a newer version taking the place of a
/// staged one, the menu's title, and how often Zigzag looks.
struct UpdateReadyTests {
    @Test func nothingStagedShowsNothing() {
        let readiness = UpdateReadiness()
        #expect(!readiness.showsCard)
        #expect(!readiness.canRestart)
        #expect(readiness.staged == nil)
    }

    @Test func aStagedUpdateShowsTheCardAndRestart() {
        var readiness = UpdateReadiness()
        readiness.stage(version: "0.9.2", build: "117")
        #expect(readiness.showsCard)
        #expect(readiness.canRestart)
        #expect(readiness.staged == .init(version: "0.9.2", build: "117"))
    }

    @Test func puttingTheCardAwayKeepsRestartInTheMenu() {
        var readiness = UpdateReadiness()
        readiness.stage(version: "0.9.2", build: "117")
        readiness.dismiss()
        #expect(!readiness.showsCard)
        // Still staged: it installs on quit, and Zigzag › Restart to Update is still there.
        #expect(readiness.canRestart)
        // The same update found again by a later check stays put away.
        readiness.stage(version: "0.9.2", build: "117")
        #expect(!readiness.showsCard)
    }

    @Test func aNewerUpdateBringsThePutAwayCardBack() {
        var readiness = UpdateReadiness()
        readiness.stage(version: "0.9.2", build: "117")
        readiness.dismiss()
        readiness.stage(version: "0.9.3", build: "118")
        #expect(readiness.showsCard)
        #expect(readiness.staged?.version == "0.9.3")
    }

    @Test func anOlderUpdateNeverReplacesANewerOne() {
        var readiness = UpdateReadiness()
        readiness.stage(version: "0.9.3", build: "118")
        readiness.stage(version: "0.9.2", build: "117")
        #expect(readiness.staged?.build == "118")
    }

    @Test func clearingTakesTheCardAndRestartAway() {
        var readiness = UpdateReadiness()
        readiness.stage(version: "0.9.2", build: "117")
        readiness.clear()
        #expect(!readiness.showsCard)
        #expect(!readiness.canRestart)
    }

    @Test func aNewerBuildOnTheFeedMakesTheStagedOneStale() {
        var readiness = UpdateReadiness()
        #expect(!readiness.isStale(feedNewest: "118"))
        readiness.stage(version: "0.9.2", build: "117")
        #expect(readiness.isStale(feedNewest: "118"))
        #expect(!readiness.isStale(feedNewest: "117"))
        #expect(!readiness.isStale(feedNewest: "116"))
        // A feed that couldn't be read leaves the staged one alone.
        #expect(!readiness.isStale(feedNewest: nil))
    }

    @Test func buildsCompareByNumberNotText() {
        #expect(UpdateReadiness.isNewer("116", than: "99"))
        #expect(!UpdateReadiness.isNewer("99", than: "116"))
        #expect(UpdateReadiness.isNewer("1.10", than: "1.9"))
        #expect(UpdateReadiness.isNewer("1.0.1", than: "1.0"))
        #expect(!UpdateReadiness.isNewer("1.0", than: "1.0.0"))
        #expect(!UpdateReadiness.isNewer("117", than: "117"))
    }

    @MainActor @Test func theMenuSaysRestartToUpdateOnlyWhileOneIsReady() {
        #if DEBUG
        let updater = Updater.shared
        updater.debugStage(nil)
        #expect(updater.menuTitle == String(localized: "Check for Updates…", comment: "Zigzag menu item."))
        updater.debugStage("0.9.2")
        #expect(updater.menuTitle == String(localized: "Restart to Update", comment: "Zigzag menu item in place of Check for Updates… while an update is ready: restarts Zigzag into it."))
        // Put away from the sidebar: the menu still offers it.
        updater.dismissCard()
        #expect(updater.menuTitle == String(localized: "Restart to Update", comment: "Zigzag menu item in place of Check for Updates… while an update is ready: restarts Zigzag into it."))
        #expect(!updater.readiness.showsCard)
        updater.debugStage(nil)
        #expect(updater.menuTitle == String(localized: "Check for Updates…", comment: "Zigzag menu item."))
        #endif
    }

    @Test func checksEveryFewHoursAndOnWakeAtMostHourly() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(UpdateSchedule.shouldCheck(lastCheck: nil, now: now, onWake: false))
        #expect(!UpdateSchedule.shouldCheck(lastCheck: now.addingTimeInterval(-3 * 3600), now: now, onWake: false))
        #expect(UpdateSchedule.shouldCheck(lastCheck: now.addingTimeInterval(-4 * 3600), now: now, onWake: false))
        // Waking: once an hour has gone by.
        #expect(!UpdateSchedule.shouldCheck(lastCheck: now.addingTimeInterval(-30 * 60), now: now, onWake: true))
        #expect(UpdateSchedule.shouldCheck(lastCheck: now.addingTimeInterval(-61 * 60), now: now, onWake: true))
        // A clock set back.
        #expect(UpdateSchedule.shouldCheck(lastCheck: now.addingTimeInterval(3600), now: now, onWake: false))
    }

    private func feed(_ items: String) -> Data {
        Data("""
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Zigzag</title>
        \(items)
        </channel></rss>
        """.utf8)
    }

    private func item(_ build: String, _ version: String, minimum: String? = nil, channel: String? = nil, enclosure: Bool = true) -> String {
        """
        <item><title>\(version)</title><sparkle:version>\(build)</sparkle:version>
        <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
        \(minimum.map { "<sparkle:minimumSystemVersion>\($0)</sparkle:minimumSystemVersion>" } ?? "")
        \(channel.map { "<sparkle:channel>\($0)</sparkle:channel>" } ?? "")
        <description><![CDATA[<h3>New</h3><ul><li>sparkle:version 999</li></ul>]]></description>
        \(enclosure ? "<enclosure url=\"https://example.com/Zigzag-\(version).zip\" length=\"1\" type=\"application/octet-stream\" sparkle:edSignature=\"x\"/>" : "")
        </item>
        """
    }

    private let mac = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)

    @Test func theFeedsNewestItemIsByBuild() {
        let data = feed(item("116", "0.9.1") + item("118", "0.9.3") + item("117", "0.9.2"))
        #expect(UpdateFeed.newest(in: data, system: mac) == .init(build: "118", version: "0.9.3"))
    }

    @Test func theFeedSkipsWhatThisMacCantInstall() {
        // For a newer macOS, for another channel, or with nothing to download.
        let data = feed(item("116", "0.9.1") + item("119", "1.0", minimum: "27.0") + item("118", "0.9.3-x", channel: "nightly")
                        + item("117", "0.9.2-info", enclosure: false))
        #expect(UpdateFeed.newest(in: data, system: mac) == .init(build: "116", version: "0.9.1"))
    }

    @Test func theFeedReadsVersionsOnTheEnclosureToo() {
        let data = feed("""
        <item><title>0.5.0</title><enclosure url="https://example.com/z.zip" length="1" sparkle:version="80" sparkle:shortVersionString="0.5.0"/></item>
        """)
        #expect(UpdateFeed.newest(in: data, system: mac) == .init(build: "80", version: "0.5.0"))
    }

    @Test func aFeedThatIsntOneHasNoNewest() {
        #expect(UpdateFeed.newest(in: Data("<html><body>Not found</body>".utf8), system: mac) == nil)
        #expect(UpdateFeed.newest(in: feed(""), system: mac) == nil)
    }
}
