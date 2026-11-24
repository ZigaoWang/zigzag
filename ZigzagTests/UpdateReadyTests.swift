import AppKit
import Foundation
import Testing
@testable import Zigzag

/// Ready updates: when the sidebar card shows, dismissing it, newer versions replacing a staged one, the menu title, and check frequency.
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
        // Still staged: installs on quit, and Restart to Update stays in the menu.
        #expect(readiness.canRestart)
        // The same update found again stays dismissed.
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
        // An unreadable feed leaves the staged update alone.
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

    @Test func theCardCountsTheDownloadAPercentAtATime() {
        let start = UpdateCardState.downloading(version: "0.9.2", received: 0, total: 0)
        #expect(start.share == nil)
        let sized = UpdateCardState.downloading(version: "0.9.2", received: 0, total: 1000)
        #expect(sized.share == 0)
        #expect(sized.differsVisibly(from: start))
        // Under 1%: not redrawn.
        #expect(!UpdateCardState.downloading(version: "0.9.2", received: 5, total: 1000).differsVisibly(from: sized))
        #expect(UpdateCardState.downloading(version: "0.9.2", received: 10, total: 1000).differsVisibly(from: sized))
        // Every stage change is.
        #expect(UpdateCardState.preparing(version: "0.9.2").differsVisibly(from: sized))
        #expect(UpdateCardState.ready(version: "0.9.2").isReady)
        #expect(UpdateCardState.preparing(version: "0.9.2-beta.1").version == "0.9.2-beta.1")
    }

    @MainActor @Test func theCardSaysHowMuchHasComeToOneDecimal() {
        #expect(UpdateCard.amount(9_480_000, of: 18_240_000) == "9.4 of 18.2 MB")
        #expect(UpdateCard.amount(12_000_000, of: 40_000_000) == "12.0 of 40.0 MB")
        #expect(UpdateCard.amount(50_000_000, of: 40_000_000) == "40.0 of 40.0 MB")
        #expect(UpdateCard.amount(400_400, of: 900_000) == "400 of 900 KB")
    }

    /// While downloading, the amount and the bar end as far from the card's right as the icon's art starts from its left.
    @MainActor @Test func theDownloadingCardHasEqualSideInsets() throws {
        let card = UpdateCard(frame: NSRect(x: 0, y: 0, width: 208, height: Tokens.Sidebar.updateCardBusyHeight))
        card.show(.downloading(version: "0.9.9", received: 12_000_000, total: 40_000_000))
        card.layoutSubtreeIfNeeded()
        let parts = Dictionary(uniqueKeysWithValues: Mirror(reflecting: card).children.compactMap { child in (child.value as? NSView).map { (child.label ?? "", $0) } })
        let icon = try #require(parts["icon"]), amount = try #require(parts["amount"]), bar = try #require(parts["bar"])
        let art = icon.frame.minX + round(icon.frame.width * 100 / 1024 * 2) / 2
        #expect(card.bounds.width - (amount.frame.maxX - Label.inset) == art)
        #expect(card.bounds.width - bar.frame.maxX == art)
    }

    @MainActor @Test func aCheckYouAskedForShowsOnTheCard() {
        #if DEBUG
        let updater = Updater.shared
        updater.debugStage("0.9.2-beta.1")
        #expect(updater.cardState == .ready(version: "0.9.2-beta.1"))
        updater.dismissCard()
        #expect(updater.cardState == nil)
        #expect(!updater.cardFloats)
        updater.debugStage(nil)
        #expect(updater.cardState == nil)
        #endif
    }

    // MARK: Automatic installs off (#492)

    private let found = UpdateReadiness.Staged(version: "0.9.5", build: "120")
    private let newer = UpdateReadiness.Staged(version: "0.9.6", build: "121")

    @Test func withAutomaticInstallsOnEveryFindDownloads() {
        var offer = UpdateOffer()
        #expect(offer.found(found, automatic: true, getting: false, background: true) == .install)
        #expect(offer.found(found, automatic: true, getting: false, background: false) == .install)
        #expect(offer.available == nil)
    }

    @Test func withAutomaticInstallsOffAFindIsOfferedNotDownloaded() {
        var offer = UpdateOffer()
        #expect(offer.found(found, automatic: false, getting: false, background: true) == .offer)
        #expect(offer.available == found)
        // A check you asked for offers it too.
        var asked = UpdateOffer()
        #expect(asked.found(found, automatic: false, getting: false, background: false) == .offer)
        #expect(asked.available == found)
    }

    @Test func updateOnTheCardDownloadsIt() {
        var offer = UpdateOffer()
        _ = offer.found(found, automatic: false, getting: false, background: true)
        #expect(offer.found(found, automatic: false, getting: true, background: false) == .install)
    }

    @Test func skippingTakesItOffTheCardAndSparkleSkipsThatBuild() {
        var offer = UpdateOffer()
        _ = offer.found(found, automatic: false, getting: false, background: true)
        offer.skip()
        #expect(offer.available == nil)
        #expect(offer.skipping == "120")
        // The next background check finds it: Sparkle is told to skip it, and it stays off the card.
        #expect(offer.found(found, automatic: false, getting: false, background: true) == .skip)
        #expect(offer.available == nil)
        #expect(offer.skipping == nil)
    }

    @Test func aNewerBuildIsOfferedAfterASkip() {
        var offer = UpdateOffer()
        _ = offer.found(found, automatic: false, getting: false, background: true)
        offer.skip()
        #expect(offer.found(newer, automatic: false, getting: false, background: true) == .offer)
        #expect(offer.available == newer)
        #expect(offer.skipping == nil)
    }

    @Test func checkForUpdatesStillOffersASkippedBuild() {
        var offer = UpdateOffer()
        _ = offer.found(found, automatic: false, getting: false, background: true)
        offer.skip()
        #expect(offer.found(found, automatic: false, getting: false, background: false) == .offer)
        #expect(offer.available == found)
    }

    @Test func clearingTheOfferForgetsTheSkipToo() {
        var offer = UpdateOffer()
        _ = offer.found(found, automatic: false, getting: false, background: true)
        offer.skip()
        offer.clear()
        #expect(offer == UpdateOffer())
        // Skipping with nothing offered does nothing.
        offer.skip()
        #expect(offer.skipping == nil)
    }

    @Test func anAvailableUpdateIsATwoLineCardWithItsVersion() {
        let state = UpdateCardState.available(version: "0.9.5")
        #expect(!state.isBusy)
        #expect(!state.isReady)
        #expect(state.version == "0.9.5")
        #expect(UpdateCard.height(for: state) == Tokens.Sidebar.updateCardHeight)
        #expect(UpdateCard.height(for: .downloading(version: "0.9.5", received: 0, total: 0)) == Tokens.Sidebar.updateCardBusyHeight)
    }

    @MainActor @Test func settingsSaysWhichVersionIsAvailable() {
        let running = VersionName.display(VersionName.running)
        #expect(SettingsVersionRow.detail(ready: nil, available: "0.9.5-beta.2")
                == String(localized: "Version \(VersionName.display("0.9.5-beta.2")) is available. You have \(running).",
                          comment: "Under Zigzag's name in Settings › General while automatic installs are off and an update was found, beside Update. The placeholders are the new version and the one running."))
        // A ready update wins.
        #expect(SettingsVersionRow.detail(ready: "0.9.5", available: "0.9.5") == SettingsVersionRow.detail(ready: "0.9.5"))
    }

    @MainActor @Test func anOfferedUpdateShowsOnTheCardUntilSkipped() {
        #if DEBUG
        let updater = Updater.shared
        updater.debugStage(nil)
        updater.debugOffer("0.9.5")
        #expect(updater.cardState == .available(version: "0.9.5"))
        #expect(updater.cardFloats)
        // A ready update takes the card's place.
        updater.debugStage("0.9.5")
        #expect(updater.cardState == .ready(version: "0.9.5"))
        updater.debugStage(nil)
        updater.debugOffer("0.9.5")
        updater.skipOffered()
        #expect(updater.cardState == nil)
        #expect(!updater.cardFloats)
        updater.debugOffer(nil)
        #endif
    }

    @MainActor @Test func theAvailableCardOffersUpdateAndSkip() {
        let card = UpdateCard(frame: NSRect(x: 0, y: 0, width: 208, height: Tokens.Sidebar.updateCardHeight))
        card.show(.available(version: "0.9.5"))
        card.layoutSubtreeIfNeeded()
        #expect(!card.updateButton.isHidden && !card.skipButton.isHidden)
        #expect(card.restartButton.isHidden && card.hideButton.isHidden)
        // Skip ends where close does; Update sits before it.
        #expect(card.skipButton.frame.maxX == card.bounds.width - SidebarRowView.buttonEdge)
        #expect(card.updateButton.frame.maxX < card.skipButton.frame.minX)
        card.show(.ready(version: "0.9.5"))
        #expect(card.updateButton.isHidden && card.skipButton.isHidden)
        #expect(!card.restartButton.isHidden)
    }

    @Test func versionsReadAsPeopleSayThem() {
        #expect(VersionName.display("0.9.2-beta.1") == "0.9.2 beta 1")
        #expect(VersionName.display("1.0.0-beta.12") == "1.0.0 beta 12")
        #expect(VersionName.display("0.9.2") == "0.9.2")
        #expect(VersionName.display("1.10") == "1.10")
        #expect(VersionName.display("") == "")
        // Other suffixes lose the dash and dots too.
        #expect(VersionName.display("1.0-rc.2") == "1.0 rc 2")
        #expect(VersionName.display("1.0-beta") == "1.0 beta")
    }

    @MainActor @Test func theMenuSaysRestartToUpdateOnlyWhileOneIsReady() {
        #if DEBUG
        let updater = Updater.shared
        updater.debugStage(nil)
        #expect(updater.menuTitle == String(localized: "Check for Updates…", comment: "Zigzag menu item."))
        updater.debugStage("0.9.2")
        #expect(updater.menuTitle == String(localized: "Restart to Update", comment: "Zigzag menu item in place of Check for Updates… while an update is ready: restarts Zigzag into it."))
        // Dismissed from the sidebar: still in the menu.
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
        // On wake: once an hour has passed.
        #expect(!UpdateSchedule.shouldCheck(lastCheck: now.addingTimeInterval(-30 * 60), now: now, onWake: true))
        #expect(UpdateSchedule.shouldCheck(lastCheck: now.addingTimeInterval(-61 * 60), now: now, onWake: true))
        // Clock set back.
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

    private let mac = UpdateFeed.Host(build: "115", system: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0),
                                      phasedGroup: 3, now: Date(timeIntervalSince1970: 1_800_000_000), isIntel: false)

    @Test func theFeedsNewestItemIsByBuild() {
        let data = feed(item("116", "0.9.1") + item("118", "0.9.3") + item("117", "0.9.2"))
        #expect(UpdateFeed.newest(in: data, host: mac) == .init(build: "118", version: "0.9.3"))
    }

    @Test func theFeedSkipsWhatThisMacCantInstall() {
        // Requires newer macOS, another channel, or no download.
        let data = feed(item("116", "0.9.1") + item("119", "1.0", minimum: "27.0") + item("118", "0.9.3-x", channel: "nightly")
                        + item("117", "0.9.2-info", enclosure: false))
        #expect(UpdateFeed.newest(in: data, host: mac) == .init(build: "116", version: "0.9.1"))
    }

    @Test func theFeedReadsVersionsOnTheEnclosureToo() {
        let data = feed("""
        <item><title>0.5.0</title><enclosure url="https://example.com/z.zip" length="1" sparkle:version="80" sparkle:shortVersionString="0.5.0"/></item>
        """)
        #expect(UpdateFeed.newest(in: data, host: mac) == .init(build: "80", version: "0.5.0"))
    }

    @Test func aFeedThatIsntOneHasNoNewest() {
        #expect(UpdateFeed.newest(in: Data("<html><body>Not found</body>".utf8), host: mac) == nil)
        #expect(UpdateFeed.newest(in: feed(""), host: mac) == nil)
    }

    /// `item` with extra elements before its description.
    private func item(_ build: String, _ version: String, with extra: String) -> String {
        item(build, version).replacingOccurrences(of: "<description>", with: extra + "<description>")
    }

    @Test func theFeedSkipsWhatSparkleWouldntFetchInTheBackground() {
        // Delta-only, other OS, informational, major upgrade, and one that can't update build 115.
        let delta = """
        <item><sparkle:version>120</sparkle:version><sparkle:shortVersionString>0.9.6</sparkle:shortVersionString>
        <sparkle:deltas><enclosure url="https://example.com/d.delta" sparkle:version="120" sparkle:deltaFrom="115" length="1"/></sparkle:deltas></item>
        """
        let windows = """
        <item><sparkle:version>121</sparkle:version><enclosure url="https://example.com/z.msi" sparkle:os="windows" length="1"/></item>
        """
        let informational = """
        <item><sparkle:version>122</sparkle:version><sparkle:informationalUpdate><sparkle:version>1</sparkle:version></sparkle:informationalUpdate>
        <enclosure url="https://example.com/z.zip" length="1"/></item>
        """
        let major = item("123", "1.0", with: "<sparkle:minimumAutoupdateVersion>200</sparkle:minimumAutoupdateVersion>")
        let notFromHere = item("124", "1.1", with: "<sparkle:minimumUpdateVersion>116</sparkle:minimumUpdateVersion>")
        let data = feed(item("116", "0.9.1") + delta + windows + informational + major + notFromHere)
        #expect(UpdateFeed.newest(in: data, host: mac) == .init(build: "116", version: "0.9.1"))
        // A full enclosure beside deltas counts, with its own version.
        let both = delta.replacingOccurrences(of: "</item>", with: "<enclosure url=\"https://example.com/z.zip\" length=\"1\"/></item>")
        #expect(UpdateFeed.newest(in: feed(item("116", "0.9.1") + both), host: mac) == .init(build: "120", version: "0.9.6"))
    }

    @Test func aPhasedRolloutCountsOnceItReachesThisMacsGroup() {
        // Group 3 of a daily phased rollout: eligible three days after its date.
        func newest(daysAgo: Double, group: Int?) -> String? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "E, dd MMM yyyy HH:mm:ss Z"
            let date = formatter.string(from: mac.now.addingTimeInterval(-daysAgo * 86_400))
            let rolling = item("118", "0.9.3", with: "<pubDate>\(date)</pubDate><sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>")
            var host = mac
            host.phasedGroup = group
            return UpdateFeed.newest(in: feed(item("116", "0.9.1") + rolling), host: host)?.build
        }
        #expect(newest(daysAgo: 2, group: 3) == "116")
        #expect(newest(daysAgo: 3.1, group: 3) == "118")
        // No group yet: treated as last, so newer items wait longest.
        #expect(newest(daysAgo: 3.1, group: nil) == "116")
        #expect(newest(daysAgo: 6.1, group: nil) == "118")
        // A rollout without a readable date doesn't count.
        let undated = item("118", "0.9.3", with: "<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>")
        #expect(UpdateFeed.newest(in: feed(item("116", "0.9.1") + undated), host: mac)?.build == "116")
    }

    @Test func anIntelMacSkipsAppleSiliconOnlyItems() {
        var intel = mac
        intel.isIntel = true
        let arm = item("118", "0.9.3", with: "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>")
        #expect(UpdateFeed.newest(in: feed(item("116", "0.9.1") + arm), host: intel)?.build == "116")
        #expect(UpdateFeed.newest(in: feed(item("116", "0.9.1") + arm), host: mac)?.build == "118")
    }
}
