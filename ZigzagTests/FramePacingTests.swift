import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Pages draw at the display's full rate; one that misses too many of its frames while scrolling is held near 60 fps
/// until its tab goes to another site (#394).
@MainActor
@Suite(.serialized)
struct FramePacingTests {
    private typealias Judge = FramePacing.Judge
    private static let at120 = 1000.0 / 120

    /// One page's judge, fed at 120 Hz unless told otherwise.
    private final class Page {
        var judge: Judge
        init(_ site: String) { judge = Judge(site: site) }
        func add(_ gaps: [Double], interval: Double = FramePacingTests.at120) -> Bool { judge.add(gaps, interval: interval) }
        func visit(_ site: String) -> Bool { judge.visit(site) }
    }

    /// A little over a second of frames, each `ms` apart.
    private func frames(_ ms: Double) -> [Double] { Array(repeating: ms, count: Int((1050 / ms).rounded(.up))) }

    /// What #394 measured on signed-in GitHub with the flag off: 82 frames of 8.3 ms, 89 of 16.7, 9 of 25.
    private static let heavy = Array(repeating: 8.3, count: 82) + Array(repeating: 16.7, count: 89) + Array(repeating: 25.0, count: 9)

    @Test func aPageKeepingUpStaysAtTheFullRate() {
        let page = Page("example.com")
        // On the display's beat, give or take a millisecond either way.
        let steady = (0..<130).map { [7.4, 9.3, 8.1, 8.5][$0 % 4] }
        for _ in 0..<6 { #expect(!page.add(steady)) }
        // At 100 fps a sixth of the frames bring nothing new: not enough.
        for _ in 0..<6 { #expect(!page.add(frames(10))) }
        #expect(!page.judge.held && page.judge.judged == 12)
        #expect(Judge.missed(steady, interval: Self.at120) < 0.01)
    }

    @Test func aPageThatCantKeepUpIsHeldNear60() {
        let page = Page("github.com")
        #expect(Judge.missed(Self.heavy, interval: Self.at120) > 0.35)
        // One slow spell is not enough; a second one holds it.
        #expect(!page.add(Self.heavy))
        #expect(page.add(Self.heavy))
        #expect(page.judge.held)
        // Held, it stays held, however it goes after.
        for _ in 0..<5 { #expect(!page.add(frames(Self.at120))) }
        #expect(page.judge.held)
    }

    @Test func aRenderingUpdateLongerThanAFrameIsSlow() {
        // WebKit starts the next update as soon as one ends: a 14 ms page runs at 71 fps, not in 16.7 ms steps.
        let page = Page("example.com")
        #expect(!page.add(frames(14)))
        #expect(page.add(frames(14)))
    }

    @Test func oneSlowSpellAmongSteadyOnesHoldsNothing() {
        let page = Page("example.com")
        let steady = frames(Self.at120)
        for gaps in [Self.heavy, steady, steady, Self.heavy] { #expect(!page.add(gaps)) }
        #expect(!page.judge.held)
        // Two of the last three are slow.
        #expect(page.add(Self.heavy))
    }

    @Test func pausesAreNotThePagesPace() {
        let page = Page("example.com")
        // Half a second of frames around a long pause: not yet a window.
        let gaps = Array(repeating: Self.at120, count: 31) + [400] + Array(repeating: Self.at120, count: 31)
        #expect(!page.add(gaps))
        #expect(page.judge.windows.isEmpty)
        #expect(!page.add(gaps))
        #expect(page.judge.windows.count == 1 && page.judge.windows[0] < 0.01)
    }

    @Test func atSixtyHertzSixtyIsNoMiss() {
        #expect(Judge.missed(frames(1000.0 / 60), interval: 1000.0 / 60) < 0.01)
    }

    @Test func anotherSiteStartsOver() {
        let page = Page("github.com")
        _ = page.add(Self.heavy)
        _ = page.add(Self.heavy)
        #expect(page.judge.held)
        // Another page of the same site stays held.
        #expect(!page.visit("github.com"))
        #expect(page.judge.held)
        // Another site: nothing held, nothing measured yet.
        #expect(page.visit("example.com"))
        #expect(page.judge == Judge(site: "example.com"))
        #expect(!page.add(Self.heavy))
        #expect(!page.judge.held)
    }

    // MARK: Pages

    private static let key = "PreferPageRenderingUpdatesNear60FPSEnabled"

    /// Fresh choices, WebKit's real flags.
    private func with(_ body: () throws -> Void) rethrows {
        let name = "FramePacingTests-\(UUID().uuidString)"
        let saved = (FeatureFlags.defaults, FeatureFlags.engine, DeveloperTools.defaults)
        let defaults = UserDefaults(suiteName: name)!
        FeatureFlags.defaults = defaults
        DeveloperTools.defaults = defaults
        FeatureFlags.engine = WebKitFeatures()
        defer {
            defaults.removePersistentDomain(forName: name)
            (FeatureFlags.defaults, FeatureFlags.engine, DeveloperTools.defaults) = saved
        }
        try body()
    }

    private func near60(_ preferences: WKPreferences) throws -> Bool {
        let feature = try #require(((WKPreferences.self as AnyObject).perform(WebKitFeatures.listSelector)?.takeUnretainedValue() as? [NSObject])?
            .first { $0.value(forKey: "key") as? String == Self.key })
        let isEnabled = NSSelectorFromString("_isEnabledForFeature:")
        typealias IsEnabled = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(preferences.method(for: isEnabled), to: IsEnabled.self)(preferences, isEnabled, feature)
    }

    private func sixtyFlag() throws -> FeatureFlags.Flag {
        try #require(FeatureFlags.flags?.first { $0.key == Self.key })
    }

    @Test func everyPageStartsAtTheChosenRate() throws {
        guard WebKitFeatures().flags?.contains(where: { $0.key == Self.key }) == true else { return }
        try with {
            // A tab's, Mini's and a web app's page; a pop-up's or a page's new window, even from a page held near 60;
            // Reader; an extension's pages.
            #expect(try !near60(WebKitSetup.makeConfiguration(for: Profiles.shared.profile(Profile.defaultID)).preferences))
            let opened = WKWebViewConfiguration()
            FeatureFlags.engine.set(true, key: Self.key, in: opened.preferences)
            WebKitSetup.separatePreferences(of: opened)
            #expect(try !near60(opened.preferences))
            #expect(try !near60(ReaderView.configuration(store: .nonPersistent()).preferences))
            if #available(macOS 15.4, *) {
                #expect(try !near60(Profiles.shared.profile(Profile.defaultID).extensions.controller.configuration.webViewConfiguration.preferences))
            }
            // Held near 60 in Settings: every one of them starts there.
            FeatureFlags.set(true, for: try sixtyFlag())
            #expect(try near60(WebKitSetup.makeConfiguration(for: Profiles.shared.profile(Profile.defaultID)).preferences))
            let another = WKWebViewConfiguration()
            WebKitSetup.separatePreferences(of: another)
            #expect(try near60(another.preferences))
            #expect(try near60(ReaderView.configuration(store: .nonPersistent()).preferences))
        }
    }

    @Test func theSwitchHoldsEveryPageAndNothingIsMeasured() throws {
        guard WebKitFeatures().flags?.contains(where: { $0.key == Self.key }) == true else { return }
        try with {
            let webView = WKWebView()
            // At the full rate a page measures; held near 60 in Settings, none does, and none is changed.
            #expect(FramePacing.received([:], site: "example.com", from: webView))
            FeatureFlags.set(true, for: try sixtyFlag())
            #expect(!FramePacing.received([:], site: "example.com", from: webView))
            #expect(!FramePacing.received(["gaps": Self.heavy + Self.heavy], site: "example.com", from: webView))
            #expect(!FramePacing.holds(webView))
            // A page with no site measures nothing.
            FeatureFlags.set(false, for: try sixtyFlag())
            #expect(!FramePacing.received([:], site: "", from: webView))
        }
    }
}
