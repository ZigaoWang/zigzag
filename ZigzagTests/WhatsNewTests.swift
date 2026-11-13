import AppKit
import Testing
@testable import Zigzag

/// The notes the app shows after an update, read from the same file the release uses.
@MainActor
struct WhatsNewTests {
    @Test func parsesThisVersionOnly() {
        let log = """
        # Changelog

        ## [1.1.0] - 2026-11-01

        ### New
        - One
        - Two

        ### Fixed
        - Three

        ## [1.0.0] - 2026-10-01

        ### New
        - Old
        """
        let release = WhatsNew.parse(log, version: "1.1.0")
        #expect(release.sections.map(\.title) == ["New", "Fixed"])
        #expect(release.sections.map { $0.items.map(\.text) } == [["One", "Two"], ["Three"]])
        #expect(release.date == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        #expect(WhatsNew.parse(log, version: "1.0.0").sections.map { $0.items.map(\.text) } == [["Old"]])
        // A version with no notes shows none, rather than another version's.
        #expect(WhatsNew.parse(log, version: "1.1").sections.isEmpty)
        #expect(WhatsNew.parse(log, version: "2.0.0") == WhatsNew.Release())
    }

    /// A point that runs on over more lines is one point; one indented under another is nested in it.
    @Test func continuationAndNestedPoints() {
        let log = """
        ## [1.2.0] - 2026-11-02

        ### Fixed
        - A long point
          that runs on. ([#4](https://github.com/o/r/issues/4))
          - A detail under it.
        * Another point.

        - After a blank line.
        """
        let items = WhatsNew.parse(log, version: "1.2.0").sections.first?.items ?? []
        #expect(items.map(\.text) == ["A long point that runs on.", "A detail under it.", "Another point.", "After a blank line."])
        #expect(items.map(\.nested) == [false, true, false, false])
        #expect(items.first?.issues.map(\.number) == [4])
    }

    /// A beta reads the notes of the version it leads up to.
    @Test func betaReadsItsPlannedVersion() {
        #expect(WhatsNew.notesVersion == WhatsNew.version.components(separatedBy: "-").first)
        let log = "## [0.8.0] - 2026-12-01\n\n### New\n- Planned\n"
        #expect(WhatsNew.parse(log, version: "0.8.0").sections.first?.items.first?.text == "Planned")
        #expect(WhatsNew.parse(log, version: "0.8.0-beta.1").sections.isEmpty)
    }

    /// Every build carries notes for its own version: a release without them can't go out.
    @Test func iconLinksAreReadFromAPage() {
        let html = #"<head><link rel="icon" type="image/png" href="https://cdn.x.com/f.png" sizes="96x96"/><link rel="stylesheet" href="a.css"><LINK REL='apple-touch-icon' HREF='/t.png'></head>"#
        let links = FaviconStore.iconLinks(in: html)
        #expect(links.count == 2)
        #expect(links.first?["href"] == "https://cdn.x.com/f.png" && links.first?["sizes"] == "96x96")
        #expect(links.last?["rel"] == "apple-touch-icon")
    }

    @Test func customSearchNeedsAPlaceForTheWords() {
        #expect(SearchEngine.isValidTemplate("https://example.com/search?q=%s"))
        #expect(!SearchEngine.isValidTemplate("https://example.com/search"))
        #expect(!SearchEngine.isValidTemplate("javascript:alert(%s)"))
    }

    @Test func unknownSearchEngineKeepsTheLibrary() throws {
        let engine = try JSONDecoder().decode([SearchEngine].self, from: Data(#"["notanengine","kagi"]"#.utf8))
        #expect(engine == [.google, .kagi])
    }

    /// Issue references at a point's end become its issues; links in its words, credits among them, stay.
    @Test func issuesAndLinks() {
        let one = WhatsNew.item("Spaces can have an icon. ([#1](https://x/issues/1), [#7](https://x/pull/7))")
        #expect(one.text == "Spaces can have an icon.")
        #expect(one.issues == [WhatsNew.Issue(number: 1, url: URL(string: "https://x/issues/1")!), WhatsNew.Issue(number: 7, url: URL(string: "https://x/pull/7")!)])
        let credit = WhatsNew.item("Faster. Thanks to [zemu](https://github.com/ze-mu-zhou) for measuring it. ([#29](https://x/29))")
        #expect(credit.text == "Faster. Thanks to [zemu](https://github.com/ze-mu-zhou) for measuring it.")
        #expect(credit.issues.map(\.number) == [29])
        // A link whose address has parentheses, and a reference mid-sentence, are words, not issues.
        let wiki = WhatsNew.item("See [Foo](https://en.wikipedia.org/wiki/Foo_(bar)) and ([#3](https://x/3)) here.")
        #expect(wiki.issues.isEmpty && wiki.text.hasSuffix("here."))
        #expect(WhatsNew.item("No references.").issues.isEmpty)
    }

    /// The sheet draws the Markdown: links clickable in the words, issues as "#n" links, no stray syntax.
    @Test func drawsInlineMarkdown() {
        let item = WhatsNew.item("**Bold** and `code` see [Foo](https://en.wikipedia.org/wiki/Foo_(bar)). Thanks to [zemu](https://github.com/ze-mu-zhou). ([#1](https://x/1), [#2](https://x/2))")
        let text = WhatsNew.attributed(item, accent: .systemBlue)
        #expect(text.string == "Bold and code see Foo. Thanks to zemu. #1, #2")
        var links: [URL] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links.map(\.absoluteString) == ["https://en.wikipedia.org/wiki/Foo_(bar)", "https://github.com/ze-mu-zhou", "https://x/1", "https://x/2"])
        let bold = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        // Only web links are links.
        let local = WhatsNew.attributed(WhatsNew.item("[x](file:///etc/hosts) [y](javascript:alert(1))"), accent: .systemBlue)
        #expect(local.attribute(.link, at: 0, effectiveRange: nil) == nil)
    }

    /// The notes after an update: owed from the first launch of a new version until they've been on screen, and
    /// never on a fresh install.
    @Test func offerIsOwedUntilShown() throws {
        let suite = "zigzag-whatsnew-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // A fresh install: quiet.
        WhatsNew.noteLaunch(defaults: defaults, version: "0.7.7")
        #expect(!WhatsNew.isPending(defaults: defaults, version: "0.7.7"))
        // Updated from 0.7.6: owed, even after the backup records 0.7.7 as run, as it does at every new build.
        defaults.set("0.7.6", forKey: "LastRunVersion")
        WhatsNew.noteLaunch(defaults: defaults, version: "0.7.7")
        UpdateBackup.backUpIfUpdated(build: "72", version: "0.7.7", defaults: defaults, root: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        #expect(defaults.string(forKey: "LastRunVersion") == "0.7.7")
        #expect(WhatsNew.isPending(defaults: defaults, version: "0.7.7"))
        // No browser window came up that launch: the next one still owes it.
        WhatsNew.noteLaunch(defaults: defaults, version: "0.7.7")
        #expect(WhatsNew.isPending(defaults: defaults, version: "0.7.7"))
        // Shown once: done, and the launch after stays quiet.
        WhatsNew.markOffered(defaults: defaults)
        WhatsNew.noteLaunch(defaults: defaults, version: "0.7.7")
        #expect(!WhatsNew.isPending(defaults: defaults, version: "0.7.7"))
        // A Mac that ran Zigzag before the version was remembered.
        defaults.removeObject(forKey: "LastRunVersion")
        defaults.set(3, forKey: "LaunchCount")
        WhatsNew.noteLaunch(defaults: defaults, version: "0.8.0-beta.1")
        #expect(WhatsNew.isPending(defaults: defaults, version: "0.8.0-beta.1"))
        // Owed for one version only: the next one owes its own.
        #expect(!WhatsNew.isPending(defaults: defaults, version: "0.8.0"))
    }

    @Test func shippedNotesAreThere() {
        #expect(!WhatsNew.sections.isEmpty)
    }

    /// Chinese reads the Chinese changelog; English and any other language read CHANGELOG.md alone.
    @Test func chineseReadsItsOwnChangelog() {
        #expect(WhatsNew.notesFile(for: "zh-Hans") == "CHANGELOG.zh-Hans")
        #expect(WhatsNew.notesFile(for: "zh-Hans-CN") == "CHANGELOG.zh-Hans")
        #expect(WhatsNew.notesFile(for: "en") == nil)
        #expect(WhatsNew.notesFile(for: "en-GB") == nil)
        #expect(WhatsNew.notesFile(for: "ja") == nil)
    }

    /// The translated notes when they have the version, the English ones when they don't.
    @Test func translatedNotesFallBackToEnglish() {
        let english = """
        ## [1.1.0] - 2026-11-01

        ### New
        - One. ([#1](https://github.com/o/r/issues/1))

        ## [1.0.0] - 2026-10-01

        ### Fixed
        - Old
        """
        let chinese = """
        <!-- Each release adds its section here too. -->
        # 更新日志

        ## [1.1.0] - 2026-11-01

        ### 新功能
        - 一。([#1](https://github.com/o/r/issues/1))
        """
        let translated = WhatsNew.pick(english: english, localized: chinese, version: "1.1.0")
        #expect(translated.sections.map(\.title) == ["新功能"])
        #expect(translated.sections.first?.items.first?.text == "一。")
        #expect(translated.sections.first?.items.first?.issues.map(\.number) == [1])
        #expect(translated.date == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        // A version not translated yet: its English notes.
        #expect(WhatsNew.pick(english: english, localized: chinese, version: "1.0.0").sections.map { $0.items.map(\.text) } == [["Old"]])
        // No translation at all, as in English.
        #expect(WhatsNew.pick(english: english, localized: nil, version: "1.1.0") == WhatsNew.parse(english, version: "1.1.0"))
        #expect(WhatsNew.pick(english: english, localized: chinese, version: "2.0.0").sections.isEmpty)
    }

    /// New and Fixed are shown in the app's language from either changelog; other headings as written.
    @Test func sectionHeadingsAreTheApps() {
        let new = String(localized: "New", comment: "Heading in What’s New: the new things in this version.")
        let fixed = String(localized: "Fixed", comment: "Heading in What’s New: what this version fixes.")
        #expect(WhatsNew.heading("New") == new && WhatsNew.heading("新功能") == new)
        #expect(WhatsNew.heading("Fixed") == fixed && WhatsNew.heading("修复") == fixed)
        #expect(WhatsNew.heading("Security") == "Security")
    }

    /// The Chinese changelog in the app follows the English one: every version it has is a real one with the same day,
    /// its sections are 新功能 and 修复 in the same order, and each point is there with the same issues.
    @Test func shippedChineseNotesMatchTheEnglish() throws {
        func text(_ name: String) throws -> String {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "md"))
            return try String(contentsOf: url, encoding: .utf8)
        }
        let english = try text("CHANGELOG"), chinese = try text("CHANGELOG.zh-Hans")
        let versions = chinese.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("## ["), let end = line.firstIndex(of: "]") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 4)..<end])
        }.filter { $0 != "Unreleased" }
        #expect(versions.count >= 6)
        let names = ["New": "新功能", "Fixed": "修复"]
        for version in versions {
            let en = WhatsNew.parse(english, version: version), zh = WhatsNew.parse(chinese, version: version)
            #expect(!en.sections.isEmpty, "\(version) isn't in CHANGELOG.md")
            #expect(zh.date == en.date, "\(version) has another day")
            #expect(zh.sections.map(\.title) == en.sections.map { names[$0.title] ?? $0.title }, "\(version) has other sections")
            #expect(zh.sections.map { $0.items.map { $0.issues.map(\.number) } } == en.sections.map { $0.items.map { $0.issues.map(\.number) } },
                    "\(version) has other points or issues")
        }
    }
}

/// Light or dark text follows what actually reads on a space's colors.
@MainActor
struct ReadableAppearanceTests {
    private func space(_ hue: Double, _ depth: Double, to hue2: Double? = nil, _ depth2: Double? = nil) -> SpaceInfo {
        var s = SpaceInfo(name: "Test", color: .sky)
        s.hue = hue; s.brightness = depth; s.hue2 = hue2; s.brightness2 = depth2
        return s
    }

    @Test func lightAndDeepColors() {
        #expect(space(0.6, 0.1).readableAppearance == "light")
        #expect(space(0.6, 0.9).readableAppearance == "dark")
    }

    @Test func gradientJudgedAtItsHarderEnd() {
        // Deep green into pale orange: white text would vanish on the pale end, so it's light.
        #expect(space(0.25, 0.54, to: 0.06, 0.09).readableAppearance == "light")
    }

    @Test func followsTheMacUntilChosen() {
        var s = SpaceInfo(name: "Test", color: .sky)
        s.appearance = nil
        #expect(s.readableAppearance == nil)
    }
}

/// Spaces saved before 0.4, with white, grays and black as their own kind and see-through as glass, look the same
/// after the update.
@MainActor
struct SpaceLookUpgradeTests {
    private func decode(_ fields: String) throws -> SpaceInfo {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Old","bookmarks":[],"# + fields + "}"
        return try JSONDecoder().decode(SpaceInfo.self, from: Data(json.utf8)).upgraded
    }

    /// sRGB components of a color, resolved in light or dark.
    private func rgba(_ color: NSColor, dark: Bool = false) -> [Double] {
        var out: [Double] = []
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            out = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Double.init)
        }
        return out
    }

    /// What the frame shows laid over a backdrop of plain `white`.
    private func over(_ color: [Double], _ white: Double) -> [Double] {
        color.prefix(3).map { $0 * color[3] + white * (1 - color[3]) }
    }

    private func close(_ a: [Double], _ b: [Double], _ tolerance: Double = 0.004) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test func colorsStayAsTheyWere() throws {
        let space = try decode(#""color":"sky","hue":0.57,"brightness":0.22,"hue2":0.95,"brightness2":0.4"#)
        #expect(space.tint == nil && space.translucency == nil && !space.isSeeThrough)
        #expect(close(rgba(space.background), rgba(SpaceColor.paint(hue: 0.57, depth: 0.22))))
        #expect(close(rgba(space.background2!), rgba(SpaceColor.paint(hue: 0.95, depth: 0.4))))
    }

    @Test func graysBecomeNoTint() throws {
        let space = try decode(#""color":"graphite","brightness":0.3"#)
        #expect(space.tint == 0 && space.isNeutral)
        // Before: the gray of OKLab lightness 0.975 - 0.69 × depth.
        let gray = OKLab.encode(pow(0.975 - 0.69 * 0.3, 3))
        #expect(close(rgba(space.background), [gray, gray, gray, 1]))
        let swatch = 0.86 - 0.56 * 0.3
        #expect(close(rgba(space.swatch), [swatch, swatch, swatch, 1]))
        // Following the Mac, a gray keeps its curated colors.
        let automatic = try decode(#""color":"snow""#)
        #expect(close(rgba(automatic.background), rgba(SpaceColor.snow.background)))
        #expect(close(rgba(automatic.background, dark: true), rgba(SpaceColor.snow.background, dark: true)))
    }

    @Test func glassBecomesSeeThroughAtItsShade() throws {
        for shade in [0.15, 0.5, 0.8] {
            let space = try decode(#""color":"sky","hue":0.6,"glass":true,"brightness":\#(shade)"#)
            #expect(space.glass == nil && space.isSeeThrough && space.isNeutral)
            // Before: white to black with the shade, at half, over the frosted desktop.
            let old = [1 - shade, 1 - shade, 1 - shade, 0.5]
            let new = rgba(space.frameColor)
            for backdrop in [0.0, 0.5, 1.0] { #expect(close(over(new, backdrop), over(old, backdrop), 0.01)) }
        }
    }

    @Test func automaticGlassStaysWhiteByDayAndBlackAtNight() throws {
        let space = try decode(#""color":"rose","glass":true"#)
        #expect(space.brightness == nil && space.isSeeThrough)
        #expect(close(rgba(space.frameColor), [1, 1, 1, 0.5]))
        #expect(close(rgba(space.frameColor, dark: true), [0, 0, 0, 0.5]))
    }

    @Test func tintThinsTowardGray() {
        var space = SpaceInfo(name: "Test", color: .sky)
        space.hue = 0.6
        space.brightness = 0.4
        space.tint = 0
        let gray = rgba(space.background)
        #expect(abs(gray[0] - gray[1]) < 0.004 && abs(gray[1] - gray[2]) < 0.004)
        space.tint = 0.5
        let half = rgba(space.background)
        #expect(half[2] > half[0] + 0.02)
    }
}

@MainActor
struct SpacePresetTests {
    private func rgb(_ color: NSColor) -> [Double] {
        let c = color.usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent].map(Double.init)
    }

    @Test func shadeRunsFromWhiteToBlack() {
        #expect(rgb(SpaceColor.paint(hue: 0.6, depth: 0, tint: 0)).allSatisfy { $0 > 0.999 })
        #expect(rgb(SpaceColor.paint(hue: 0.6, depth: 1, tint: 0)).allSatisfy { $0 < 0.001 })
        #expect(rgb(SpaceColor.paint(hue: 0.3, depth: 1)).allSatisfy { $0 < 0.001 })
    }

    @Test func everyPresetIsPickedOnceApplied() {
        for look in SpaceLook.presets {
            var space = SpaceInfo(name: "Test", color: .sky)
            space.grain = 0.7
            space.translucency = 0.4
            look.apply(to: &space)
            #expect(look.matches(space), "\(look.name)")
            #expect(SpaceLook.presets.filter { $0.matches(space) }.count == 1, "\(look.name)")
        }
    }

    @Test func oldWhiteAndBlackAreThePresets() {
        let white = SpaceLook.presets.first { $0.name == "White" }!
        let black = SpaceLook.presets.first { $0.name == "Black" }!
        #expect(white.matches(SpaceInfo(name: "Old", color: .snow)))
        #expect(black.matches(SpaceInfo(name: "Old", color: .ink)))
    }
}
