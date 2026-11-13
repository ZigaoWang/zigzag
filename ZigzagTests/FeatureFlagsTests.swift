import Foundation
import Testing
import WebKit
@testable import Zigzag

/// WebKit's feature flags in Settings › Developer (#173): only what you change is kept, it's set on new pages while
/// Developer Mode is on, Reset to Defaults forgets it all, and a WebKit without the list shows nothing.
@MainActor
@Suite(.serialized)
struct FeatureFlagsTests {
    /// A list of flags of its own, noting what it's asked to set.
    private final class FakeEngine: FeatureFlags.Engine {
        var flags: [FeatureFlags.Flag]?
        var applied: [(key: String, on: Bool)] = []
        init(_ flags: [FeatureFlags.Flag]?) { self.flags = flags }
        func set(_ on: Bool, key: String, in preferences: WKPreferences) { applied.append((key, on)) }
    }

    private static let anchors = FeatureFlags.Flag(key: "CSSAnchorPositioningEnabled", name: "CSS Anchor Positioning",
                                                   details: "Enable CSS Anchor Positioning", status: .stable, defaultValue: true)
    private static let mixing = FeatureFlags.Flag(key: "CSSCalcMixEnabled", name: "CSS calc-mix()", details: "", status: .preview, defaultValue: false)
    private static let tiles = FeatureFlags.Flag(key: "TileDebugEnabled", name: "Tile Debugging", details: "Shows tiles", status: .internal, defaultValue: false)
    private static let embedded = FeatureFlags.Flag(key: "JavaScriptCanOpenWindowsAutomatically", name: "", details: "", status: .embedder, defaultValue: true)

    private func with(_ flags: [FeatureFlags.Flag]? = [anchors, mixing, tiles, embedded], _ body: (FakeEngine) throws -> Void) rethrows {
        let name = "FeatureFlagsTests-\(UUID().uuidString)"
        let saved = (FeatureFlags.defaults, FeatureFlags.engine, DeveloperTools.defaults)
        let defaults = UserDefaults(suiteName: name)!
        let engine = FakeEngine(flags)
        FeatureFlags.defaults = defaults
        DeveloperTools.defaults = defaults
        FeatureFlags.engine = engine
        defer {
            defaults.removePersistentDomain(forName: name)
            (FeatureFlags.defaults, FeatureFlags.engine, DeveloperTools.defaults) = saved
        }
        try body(engine)
    }

    @Test func onlyWhatYouChangeIsKept() {
        with { _ in
            #expect(FeatureFlags.overrides.isEmpty)
            #expect(FeatureFlags.isOn(Self.anchors) && !FeatureFlags.isOn(Self.mixing))
            FeatureFlags.set(false, for: Self.anchors)
            FeatureFlags.set(true, for: Self.mixing)
            #expect(FeatureFlags.overrides == ["CSSAnchorPositioningEnabled": false, "CSSCalcMixEnabled": true])
            #expect(!FeatureFlags.isOn(Self.anchors) && FeatureFlags.isOn(Self.mixing))
            #expect(FeatureFlags.isChanged(Self.anchors) && !FeatureFlags.isChanged(Self.tiles))
            // Back to its default, a flag is forgotten, so a later WebKit's default holds again.
            FeatureFlags.set(true, for: Self.anchors)
            #expect(FeatureFlags.overrides == ["CSSCalcMixEnabled": true])
            #expect(!FeatureFlags.isChanged(Self.anchors))
            // Set to what it already is: nothing kept.
            FeatureFlags.set(false, for: Self.tiles)
            #expect(FeatureFlags.overrides.keys.sorted() == ["CSSCalcMixEnabled"])
        }
    }

    @Test func changesAreSetOnNewPagesWhileDeveloperModeIsOn() {
        with { engine in
            FeatureFlags.set(false, for: Self.anchors)
            FeatureFlags.set(true, for: Self.tiles)
            engine.applied = []
            FeatureFlags.apply(to: WKPreferences())
            #expect(engine.applied.sorted { $0.key < $1.key }.map { "\($0.key) \($0.on)" } == ["CSSAnchorPositioningEnabled false", "TileDebugEnabled true"])
            // Developer Mode off: new pages are WebKit's own, and the changes are kept for when it's back.
            DeveloperTools.isOn = false
            engine.applied = []
            FeatureFlags.apply(to: WKPreferences())
            #expect(engine.applied.isEmpty)
            #expect(FeatureFlags.overrides.count == 2)
        }
    }

    @Test func nothingChangedSetsNothing() {
        with { engine in
            FeatureFlags.apply(to: WKPreferences())
            #expect(engine.applied.isEmpty)
        }
    }

    @Test func resetForgetsEveryChange() {
        with { _ in
            FeatureFlags.set(false, for: Self.anchors)
            FeatureFlags.set(true, for: Self.mixing)
            var heard = 0
            let token = FeatureFlags.changed.observe { heard += 1 }
            FeatureFlags.reset()
            #expect(FeatureFlags.overrides.isEmpty && !FeatureFlags.hasOverrides)
            #expect(FeatureFlags.isOn(Self.anchors) && !FeatureFlags.isOn(Self.mixing))
            #expect(heard == 1)
            // Nothing to reset: nobody's told.
            FeatureFlags.reset()
            #expect(heard == 1)
            token.cancel()
        }
    }

    @Test func aChangeForAFlagThisWebKitLacksIsKeptAndPassedToTheEngine() {
        with { engine in
            FeatureFlags.defaults.set(["GoneEnabled": true], forKey: "WebKitFeatureFlags")
            #expect(FeatureFlags.overrides == ["GoneEnabled": true])
            FeatureFlags.apply(to: WKPreferences())
            // The engine finds no such flag and sets nothing (WebKitFeatures.set); the change stays until reset.
            #expect(engine.applied.map(\.key) == ["GoneEnabled"])
            FeatureFlags.reset()
            #expect(FeatureFlags.overrides.isEmpty)
        }
    }

    @Test func listedFlagsLeaveWebKitsOwnOut() {
        with { _ in
            #expect(FeatureFlags.flags?.map(\.key) == ["CSSAnchorPositioningEnabled", "CSSCalcMixEnabled", "TileDebugEnabled"])
            #expect(FeatureFlags.isAvailable)
            let all = FeatureFlags.flags ?? []
            #expect(FeatureFlags.flags(.stable, in: all, matching: []) == [Self.anchors])
            #expect(FeatureFlags.flags(.internal, in: all, matching: []) == [Self.tiles])
            // Internal ones are behind Show All; the listed ones are what Safari shows.
            #expect(!FeatureFlags.Status.listed.contains(.internal) && FeatureFlags.Status.more.contains(.internal))
            #expect(!FeatureFlags.Status.listed.contains(.embedder) && !FeatureFlags.Status.more.contains(.embedder))
        }
    }

    @Test func searchFindsByNameKeyOrLine() {
        let all = [Self.anchors, Self.mixing, Self.tiles]
        #expect(FeatureFlags.flags(.stable, in: all, matching: ["anchor"]) == [Self.anchors])
        #expect(FeatureFlags.flags(.stable, in: all, matching: ["cssanchorpositioningenabled"]) == [Self.anchors])
        #expect(FeatureFlags.flags(.internal, in: all, matching: ["shows", "tiles"]) == [Self.tiles])
        #expect(FeatureFlags.flags(.stable, in: all, matching: ["anchor", "nope"]).isEmpty)
    }

    @Test func noListMeansNoGroup() {
        with(nil) { engine in
            #expect(FeatureFlags.flags == nil)
            #expect(!FeatureFlags.isAvailable)
            FeatureFlags.defaults.set(["CSSCalcMixEnabled": true], forKey: "WebKitFeatureFlags")
            FeatureFlags.apply(to: WKPreferences())
            #expect(engine.applied.map(\.key) == ["CSSCalcMixEnabled"])
        }
        with([Self.embedded]) { _ in #expect(!FeatureFlags.isAvailable) }
    }

    // MARK: Reading WebKit

    @Test func aClassWithoutTheListGivesNone() {
        let features = WebKitFeatures(source: NSObject.self)
        #expect(features.flags == nil)
        // Setting with no list does nothing, and doesn't crash.
        features.set(true, key: "CSSCalcMixEnabled", in: WKPreferences())
    }

    @Test func aStandInListIsRead() {
        let features = WebKitFeatures(source: StandInPreferences.self)
        let flags = features.flags ?? []
        #expect(flags.map(\.key) == ["StandInEnabled"])
        #expect(flags.first == FeatureFlags.Flag(key: "StandInEnabled", name: "Stand-in", details: "A made-up flag", status: .preview, defaultValue: true))
    }

    @Test func thisMacsWebKitListsItsFlags() throws {
        // The real WebKit: every listed flag has a key and a status, and setting one takes.
        let features = WebKitFeatures()
        let flags = try #require(features.flags)
        #expect(!flags.isEmpty)
        let flag = try #require(flags.first { $0.status == .stable && !$0.name.isEmpty })
        let preferences = WKPreferences()
        features.set(!flag.defaultValue, key: flag.key, in: preferences)
        let isEnabled = NSSelectorFromString("_isEnabledForFeature:")
        try #require(preferences.responds(to: isEnabled))
        typealias IsEnabled = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let feature = try #require((WKPreferences.self as AnyObject).perform(WebKitFeatures.listSelector)?.takeUnretainedValue() as? [NSObject])
            .first { $0.value(forKey: "key") as? String == flag.key }
        let object = try #require(feature)
        #expect(unsafeBitCast(preferences.method(for: isEnabled), to: IsEnabled.self)(preferences, isEnabled, object) == !flag.defaultValue)
    }
}

/// A class that lists flags as WKPreferences does, with one made-up flag and one hidden one.
final class StandInPreferences: NSObject {
    @objc class func _features() -> [NSObject] {
        [StandInFeature(key: "StandInEnabled", name: "Stand-in", details: "A made-up flag", status: 5, hidden: false),
         StandInFeature(key: "HiddenEnabled", name: "Hidden", details: "", status: 6, hidden: true),
         StandInFeature(key: "", name: "No key", details: "", status: 6, hidden: false)]
    }
}

final class StandInFeature: NSObject {
    @objc let key: String
    @objc let name: String
    @objc let details: String
    @objc let status: UInt
    @objc let defaultValue = true
    @objc(isHidden) let hidden: Bool

    init(key: String, name: String, details: String, status: UInt, hidden: Bool) {
        self.key = key
        self.name = name
        self.details = details
        self.status = status
        self.hidden = hidden
    }
}
