import Foundation
import Testing
@testable import Zigzag

/// A background tab sleeps only once it's been out of sight a long while, sooner only when lots are awake or the Mac is
/// short of memory, and never with something you typed in it. A page that stops says why.
struct TabSleepTests {
    private let minute: TimeInterval = 60

    private func tab(_ unseen: TimeInterval, mustStay: Bool = false, typed: Bool = false) -> TabSleep.Candidate {
        TabSleep.Candidate(id: UUID(), unseen: unseen, mustStay: mustStay, hasTypedText: typed)
    }

    @Test func aTabUnseenForLessThanAnHourStaysAwake() {
        // Fifteen minutes put it to sleep before: a forum you went back to was loading again every time.
        #expect(TabSleep.sleepers([tab(16 * minute), tab(59 * minute)], awake: 3, memory: .normal).isEmpty)
    }

    @Test func aTabUnseenForAnHourSleeps() {
        let old = tab(61 * minute)
        #expect(TabSleep.sleepers([old, tab(10 * minute)], awake: 3, memory: .normal) == [old.id])
    }

    @Test func manyAwakeSleepsTheLongestUnseenUntilBackToTheCrowd() {
        let tabs = (0..<24).map { tab(TimeInterval(16 + $0) * minute) }
        let slept = TabSleep.sleepers(tabs, awake: 24, memory: .normal)
        // Down to 20 awake, oldest first.
        #expect(slept == tabs.sorted { $0.unseen > $1.unseen }.prefix(4).map(\.id))
    }

    @Test func manyAwakeStillLeavesOnesYouJustLeft() {
        let tabs = (0..<30).map { _ in tab(10 * minute) }
        #expect(TabSleep.sleepers(tabs, awake: 30, memory: .normal).isEmpty)
    }

    @Test func lowOnMemorySleepsTabsUnseenForFiveMinutes() {
        let away = tab(6 * minute), recent = tab(2 * minute)
        #expect(TabSleep.sleepers([away, recent], awake: 3, memory: .low) == [away.id])
    }

    @Test func typedTextAndTabsInUseNeverSleep() {
        let tabs = [tab(5 * 60 * minute, typed: true), tab(5 * 60 * minute, mustStay: true)]
        #expect(TabSleep.sleepers(tabs, awake: 40, memory: .low).isEmpty)
    }

    @Test func aFavoriteStaysAwakeHoweverLongUnseenOrManyAwake() {
        let favorite = TabSleep.Candidate(id: UUID(), unseen: 5 * 60 * minute, mustStay: false, hasTypedText: false, isFavorite: true)
        #expect(TabSleep.sleepers([favorite], awake: 40, memory: .normal).isEmpty)
    }

    @Test func aFavoriteStaysAwakeOnMacOSFirstMemoryWarning() {
        // macOS warns often in everyday use: one warning put every favorite left five minutes ago to sleep at once.
        let favorite = TabSleep.Candidate(id: UUID(), unseen: 30 * minute, mustStay: false, hasTypedText: false, isFavorite: true)
        let other = tab(30 * minute)
        #expect(TabSleep.sleepers([favorite, other], awake: 3, memory: .low) == [other.id])
    }

    @Test func aFavoriteSleepsOnlyWhenMemoryIsCritical() {
        let away = TabSleep.Candidate(id: UUID(), unseen: 30 * minute, mustStay: false, hasTypedText: false, isFavorite: true)
        let recent = TabSleep.Candidate(id: UUID(), unseen: 2 * minute, mustStay: false, hasTypedText: false, isFavorite: true)
        let typed = TabSleep.Candidate(id: UUID(), unseen: 30 * minute, mustStay: false, hasTypedText: true, isFavorite: true)
        #expect(TabSleep.sleepers([away, recent, typed], awake: 3, memory: .critical) == [away.id])
    }

    // MARK: A site kept awake (#91)

    private func kept(_ unseen: TimeInterval, favorite: Bool = false, typed: Bool = false) -> TabSleep.Candidate {
        TabSleep.Candidate(id: UUID(), unseen: unseen, mustStay: false, hasTypedText: typed, isFavorite: favorite, keptAwake: true)
    }

    @Test func aSiteKeptAwakeNeverSleepsForBeingIdleOrOneOfMany() {
        let tabs = (0..<30).map { kept(TimeInterval(2 + $0) * 60 * minute) }
        #expect(TabSleep.sleepers(tabs, awake: 40, memory: .normal).isEmpty)
        #expect(TabSleep.sleepers([kept(5 * 60 * minute, favorite: true)], awake: 40, memory: .normal).isEmpty)
    }

    @Test func aSiteKeptAwakeStaysAwakeOnMacOSFirstMemoryWarning() {
        let awake = kept(30 * minute), other = tab(30 * minute)
        #expect(TabSleep.sleepers([awake, other], awake: 3, memory: .low) == [other.id])
    }

    @Test func atCriticalMemoryASiteKeptAwakeWaitsForEverythingElse() {
        let awake = kept(3 * 60 * minute), other = tab(30 * minute)
        let favorite = TabSleep.Candidate(id: UUID(), unseen: 30 * minute, mustStay: false, hasTypedText: false, isFavorite: true)
        // Others first, favorites among them, however much longer the kept one has been unseen.
        #expect(TabSleep.sleepers([awake, other, favorite], awake: 3, memory: .critical) == [other.id, favorite.id])
    }

    @Test func atCriticalMemoryASiteKeptAwakeGoesOneAtATimeLongestUnseenFirst() {
        let older = kept(2 * 60 * minute), newer = kept(60 * minute, favorite: true)
        let recent = kept(2 * minute), typed = kept(3 * 60 * minute, typed: true)
        let onScreen = TabSleep.Candidate(id: UUID(), unseen: 4 * 60 * minute, mustStay: true, hasTypedText: false, keptAwake: true)
        let tabs = [newer, recent, typed, older, onScreen]
        #expect(TabSleep.sleepers(tabs, awake: 5, memory: .critical) == [older.id])
        #expect(TabSleep.sleepers(tabs.filter { $0.id != older.id }, awake: 4, memory: .critical) == [newer.id])
        // Left a moment ago, typed in or on screen: stays, as for any tab.
        #expect(TabSleep.sleepers([recent, typed, onScreen], awake: 3, memory: .critical).isEmpty)
    }

    @Test func aBusyTabKeptAwakeIsOnlyPointedOut() {
        #expect(!EnergyWatch.staysAwake(extensionPage: false, playing: false, inUse: false, notifies: false, favorite: false, keptAwake: false, typed: false))
        #expect(EnergyWatch.staysAwake(extensionPage: false, playing: false, inUse: false, notifies: false, favorite: false, keptAwake: true, typed: false))
        #expect(EnergyWatch.staysAwake(extensionPage: false, playing: false, inUse: false, notifies: false, favorite: true, keptAwake: false, typed: false))
    }

    @Test func webKitReasonsAreToldApart() {
        #expect(PageStop(webKitReason: 0, lowOnMemoryAgo: nil) == .pageMemory)
        #expect(PageStop(webKitReason: 1, lowOnMemoryAgo: nil) == .processor)
        #expect(PageStop(webKitReason: 3, lowOnMemoryAgo: nil) == .crash)
        // The public callback, with no reason.
        #expect(PageStop(webKitReason: nil, lowOnMemoryAgo: nil) == .crash)
        // A reason a later WebKit adds is a crash, as WebKit's own mapping does.
        #expect(PageStop(webKitReason: 9, lowOnMemoryAgo: nil) == .crash)
    }

    @Test func aCrashWhileTheMacIsShortOfMemoryIsPutDownToIt() {
        #expect(PageStop(webKitReason: 3, lowOnMemoryAgo: 30) == .macMemory)
        #expect(PageStop(webKitReason: nil, lowOnMemoryAgo: 30) == .macMemory)
        #expect(PageStop(webKitReason: 3, lowOnMemoryAgo: 10 * minute) == .crash)
        // WebKit's own memory limit stays its own, whatever the Mac says.
        #expect(PageStop(webKitReason: 0, lowOnMemoryAgo: 30) == .pageMemory)
    }

    @Test func onlyMemoryReloadsAreSaid() {
        #expect(PageStop.pageMemory.reloadedText != nil)
        #expect(PageStop.macMemory.reloadedText != nil)
        #expect(PageStop.crash.reloadedText == nil)
        #expect(PageStop.processor.reloadedText == nil)
        #expect(PageStop.macMemory.detail == "Mac low on memory")
    }

    @Test func pageStateReadsWhatThePageSays() throws {
        let url = try #require(URL(string: "https://linux.do/t/topic/123"))
        let result: [String: Any] = ["x": 0.0, "y": 4200.0, "fields": [["#reply", "half written"]], "typed": false, "manual": false]
        let state = try #require(PageState(result, url: url))
        #expect(state.scroll.y == 4200)
        #expect(state.fields == [PageState.Field(selector: "#reply", value: "half written")])
        // A field you typed in counts as typed text, so the tab stays awake.
        #expect(state.hasTypedText)
        #expect(PageState(nil, url: url) == nil)
        #expect(PageState(result, url: nil) == nil)
    }

    @Test func aPageThatPlacesItselfIsGivenTheChanceFirst() throws {
        // A Discourse topic list says it scrolls itself but comes back at the top after a reload: its place is still
        // passed, so it's put back once the page has had its moment and stayed at the top.
        let url = try #require(URL(string: "https://meta.discourse.org/latest"))
        let state = PageState(url: url, scroll: CGPoint(x: 0, y: 9000), placesItself: true)
        #expect(state.restoreArguments["y"] as? Double == 9000)
        #expect(state.restoreArguments["waits"] as? Bool == true)
        #expect(!state.hasTypedText)
        #expect(PageState(url: url, scroll: CGPoint(x: 0, y: 9000)).restoreArguments["waits"] as? Bool == false)
    }

    @Test func pageStateBelongsToTheSamePageOnly() throws {
        let state = PageState(url: try #require(URL(string: "https://example.com/a?b=1#top")), scroll: .zero)
        #expect(state.belongs(to: URL(string: "https://example.com/a?b=1")))
        #expect(state.belongs(to: URL(string: "https://example.com/a?b=1#end")))
        #expect(!state.belongs(to: URL(string: "https://example.com/a?b=2")))
        #expect(!state.belongs(to: nil))
    }
}

/// The sites kept awake in their site controls: kept, covering subdomains, forgotten, and never chosen in a private
/// window (#91).
@MainActor
@Suite(.serialized)
struct KeepAwakeTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "KeepAwakeTests-\(UUID().uuidString)"
        let saved = KeepAwake.defaults
        KeepAwake.defaults = UserDefaults(suiteName: name)!
        defer {
            KeepAwake.defaults.removePersistentDomain(forName: name)
            KeepAwake.defaults = saved
        }
        try body()
    }

    @Test func aSiteKeptAwakeIsKeptAndCoversItsSubdomains() {
        withDefaults {
            KeepAwake.set(true, for: URL(string: "https://www.example.com/inbox"))
            #expect(KeepAwake.sites == ["example.com"])
            #expect(KeepAwake.defaults.stringArray(forKey: "KeepAwakeSites") == ["example.com"])
            #expect(KeepAwake.isOn(for: URL(string: "https://example.com/")))
            #expect(KeepAwake.isOn(for: URL(string: "https://mail.example.com/")))
            #expect(!KeepAwake.isOn(for: URL(string: "https://example.org/")))
            #expect(!KeepAwake.isOn(for: URL(string: "https://notexample.com/")))
            #expect(!KeepAwake.isOn(for: nil))
        }
    }

    @Test func turningItOffOnASubdomainTakesAwayWhatCoveredIt() {
        withDefaults {
            KeepAwake.set(true, for: URL(string: "https://example.com/"))
            KeepAwake.set(true, for: URL(string: "https://other.org/"))
            KeepAwake.set(false, for: URL(string: "https://mail.example.com/"))
            #expect(KeepAwake.sites == ["other.org"])
            #expect(!KeepAwake.isOn(for: URL(string: "https://example.com/")))
        }
    }

    @Test func turningItOnTwiceKeepsOneEntry() {
        withDefaults {
            KeepAwake.set(true, for: URL(string: "https://example.com/a"))
            KeepAwake.set(true, for: URL(string: "https://www.example.com/b"))
            #expect(KeepAwake.sites == ["example.com"])
        }
    }

    @Test func aPrivateWindowIsNotOfferedTheChoice() {
        let page = URL(string: "https://example.com/")
        #expect(KeepAwake.isOffered(for: page, isPrivate: false))
        #expect(!KeepAwake.isOffered(for: page, isPrivate: true))
        #expect(KeepAwake.isOffered(for: URL(string: "http://localhost:3000/"), isPrivate: false))
        #expect(!KeepAwake.isOffered(for: URL(string: "webkit-extension://abc/popup.html"), isPrivate: false))
        #expect(!KeepAwake.isOffered(for: nil, isPrivate: false))
    }
}
