import AppKit
import Testing
@testable import Zigzag

/// A row of several pages lines up with the rows around it (#203): the same height and icon size; with room for titles
/// each part laid out as a tab's row is, its icon a row's inset in from where the part starts, its title after it, a
/// hairline between parts; without, each icon centered in its part, the hairlines still between.
@MainActor struct SplitRowAlignmentTests {
    private func icons(of row: TabRowView) -> [NSRect] {
        row.subviews.compactMap { $0 as? FaviconView }.filter { !$0.isHidden }.map(\.frame).sorted { $0.minX < $1.minX }
    }

    private func titles(of row: TabRowView) -> [Label] {
        row.subviews.compactMap { $0 as? Label }.filter { !$0.isHidden && $0.frame.width > 0 }.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Hairlines between parts: thin views the row's height minus margins.
    private func lines(of row: TabRowView) -> [NSRect] {
        row.subviews.filter { !$0.isHidden && $0.frame.width == Tokens.Metric.hairline && $0.frame.height == row.bounds.height - Tokens.Space.x4 }
            .map(\.frame).sorted { $0.minX < $1.minX }
    }

    private func row(parts: Int, width: CGFloat) -> TabRowView {
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: width, height: Tokens.Sidebar.rowHeight))
        row.isBookmark = true
        row.fixedTitle = "Page"
        row.configure(tab: nil)
        row.configure(parts: (1..<max(parts, 1)).map { TabRowView.Part(page: nil, name: $0 == 1 ? "Second" : "Page \($0)") })
        row.layoutSubtreeIfNeeded()
        return row
    }

    @Test(arguments: [2, 3, 4]) func theIconsLineUpWithTheRowsAround(parts: Int) {
        for width in [200, 260, 340] as [CGFloat] {
            let single = icons(of: row(parts: 1, width: width))
            let group = icons(of: row(parts: parts, width: width))
            #expect(group.count == parts)
            #expect(group.allSatisfy { $0.midY == single[0].midY && $0.size == single[0].size })
            // A split of two always has titles, its first icon in the tabs' column.
            if parts == 2 { #expect(group.first?.minX == single.first?.minX) }
        }
    }

    /// A tab title's fade is applied once per layout at its final position.
    @Test func aTabsTitleIsFadedOnceALayout() {
        let row = row(parts: 1, width: 220)
        let before = row.title.fadesAsked
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        #expect(row.title.fadesAsked == before + 1)
    }

    @Test func theOtherIconsStepAlongEvenly() {
        let xs = icons(of: row(parts: 4, width: 260)).map(\.minX)
        let steps = zip(xs.dropFirst(), xs).map { $0 - $1 }
        // Even steps, a pixel's rounding apart at most.
        #expect((steps.max() ?? 0) - (steps.min() ?? 0) <= 1)
    }
}

extension SplitRowAlignmentTests {
    /// Every part shows a truncated title: the last ends like a tab title, others leave the same gap before the hairline as the next icon after it.
    @Test(arguments: [2, 3, 4]) func eachPartShowsItsTitle(parts: Int) {
        let width: CGFloat = 360
        let r = row(parts: parts, width: width)
        let single = row(parts: 1, width: width)
        let shown = titles(of: r), icons = icons(of: r), lines = lines(of: r)
        #expect(shown.count == parts)
        #expect(lines.count == parts - 1)
        // Titles align with a tab's, after the icon.
        for (label, icon) in zip(shown, icons) {
            #expect(label.frame.minY == single.title.frame.minY && label.frame.height == single.title.frame.height)
            #expect(label.frame.minX - icon.maxX == single.title.frame.minX - single.icon.frame.maxX)
        }
        // No room reserved for close: the last title ends where a tab's does.
        #expect(shown.last?.frame.maxX == single.title.frame.maxX)
        // Equal margins either side of each hairline.
        for (i, line) in lines.enumerated() {
            let textEnd = shown[i].frame.maxX - Label.inset
            #expect(abs((line.midX - textEnd) - (icons[i + 1].minX - line.midX)) <= 1)
            #expect(abs(line.midX - textEnd - TabRowView.inset) <= 0.5)
        }
        // Equal part widths within a point.
        let starts = [0] + lines.map(\.midX) + [width]
        let widths = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1)
    }

    /// Each part has its own ×, which comes over its faded title, so no room is kept at the row's end: the parts run
    /// to it in equal widths.
    @Test func aNarrowRowsPartsRunToItsEnd() {
        let parts = 3
        let r = row(parts: parts, width: 228)
        let shown = titles(of: r)
        #expect(shown.count == parts)
        let lines = lines(of: r)
        let starts = [0] + lines.map(\.midX) + [r.bounds.width]
        let widths = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1)
    }

    @Test func withoutTitlesEachIconIsCenteredInItsPart() {
        let width: CGFloat = 200
        let r = row(parts: 4, width: width)
        let xs = icons(of: r).map(\.midX)
        #expect(!TabRowView.segmentShowsTitle(width: width / 4))
        #expect(titles(of: r).isEmpty)
        // Centered in four equal parts ending at the close button's room, hairlines halfway between.
        let lines = lines(of: r)
        #expect(xs.count == 4 && lines.count == 3)
        let steps = zip(xs.dropFirst(), xs).map { $0 - $1 }
        #expect((steps.max() ?? 0) - (steps.min() ?? 0) <= 1)
        for (i, line) in lines.enumerated() { #expect(abs(line.midX - (xs[i] + xs[i + 1]) / 2) <= 1) }
        #expect(xs[3] < r.closeButton.frame.minX)
    }

    /// Parts never overflow the row.
    @Test(arguments: [2, 3, 4]) func neverOverflows(parts: Int) {
        for width in [120, 160, 200, 240, 300] as [CGFloat] {
            let r = row(parts: parts, width: width)
            #expect(icons(of: r).allSatisfy { $0.minX >= 0 && $0.maxX <= width })
            #expect(titles(of: r).allSatisfy { $0.frame.maxX <= width })
            #expect(icons(of: r).count == parts)
        }
    }

    /// Minimum part width for a title per sidebar size: icon, gap, a few letters, insets.
    @Test func theTitleThresholdFollowsTheSidebarSize() {
        #expect(TabRowView.segmentMinWidth(for: .medium) == 56)
        #expect(TabRowView.segmentMinWidth(for: .small) < TabRowView.segmentMinWidth(for: .medium))
        #expect(TabRowView.segmentMinWidth(for: .large) > TabRowView.segmentMinWidth(for: .medium))
        for size in Tokens.Sidebar.Size.allCases {
            let least = TabRowView.segmentMinWidth(for: size)
            #expect(TabRowView.segmentShowsTitle(width: least, size: size))
            #expect(!TabRowView.segmentShowsTitle(width: least - 1, size: size))
        }
    }

    /// VoiceOver names every page in the row.
    @Test func theRowNamesItsPages() {
        let label = row(parts: 3, width: 260).accessibilityLabel() ?? ""
        #expect(["Page", "Second", "Page 2"].allSatisfy { label.contains($0) })
        #expect(row(parts: 1, width: 260).accessibilityLabel() == "Page")
    }

    /// The Custom size (#361) is a whole percentage from 80 to 150, 100 if none is kept, and gives the whole and
    /// even points every other size does.
    @Test func theCustomSizeIsAWholePercentageWithinItsRange() {
        let wasSize = Tokens.Sidebar.size
        let wasScale = Tokens.Sidebar.customScale
        // The tests run in the app, on its own preferences: the percentage goes back to unset if it was.
        let wasKept = UserDefaults.standard.object(forKey: "SidebarSizePercent")
        defer {
            Tokens.Sidebar.size = wasSize
            Tokens.Sidebar.customScale = wasScale
            UserDefaults.standard.set(wasKept, forKey: "SidebarSizePercent")
        }

        #expect(Tokens.Sidebar.keptCustomPercent(nil) == 100)
        #expect(Tokens.Sidebar.keptCustomPercent(79) == 80)
        #expect(Tokens.Sidebar.keptCustomPercent(151) == 150)

        Tokens.Sidebar.size = .custom
        Tokens.Sidebar.customScale = 1.3
        #expect(abs(Tokens.Sidebar.scale - 1.3) < 0.0001)
        #expect(abs(Tokens.Sidebar.customScale - 1.3) < 0.0001)
        #expect(UserDefaults.standard.integer(forKey: "SidebarSizePercent") == 130)

        // Not a whole percentage: rounded to one.
        Tokens.Sidebar.customScale = 1.294
        #expect(abs(Tokens.Sidebar.customScale - 1.29) < 0.0001)
        Tokens.Sidebar.customScale = 1.296
        #expect(abs(Tokens.Sidebar.customScale - 1.3) < 0.0001)

        // Outside 80 to 150: stays at the end.
        Tokens.Sidebar.customScale = 0.1
        #expect(abs(Tokens.Sidebar.customScale - 0.8) < 0.0001)
        Tokens.Sidebar.customScale = 2
        #expect(abs(Tokens.Sidebar.customScale - 1.5) < 0.0001)

        // Whole and even points, as at any other size.
        Tokens.Sidebar.customScale = 1.3
        #expect(Tokens.Sidebar.scaled(21) == 27)
        #expect(Tokens.Sidebar.scaledEven(21) == 28)
        #expect(Tokens.Sidebar.scaled(15, for: .custom) == 20)
        #expect(Tokens.Sidebar.scaledEven(15, for: .custom) == 20)

        // 5% steps from 80% to 150%.
        let steps = Tokens.Sidebar.customSteps
        #expect(steps.count == 15)
        #expect(abs((steps.first ?? 0) - 0.8) < 0.0001 && abs((steps.last ?? 0) - 1.5) < 0.0001)
        for (step, next) in zip(steps, steps.dropFirst()) { #expect(abs(next - step - 0.05) < 0.0001) }
    }

    /// The sidebar lays itself out again when Custom's percentage really changes, and not for the same percentage
    /// or while another size is chosen.
    @Test func theCustomSizeTellsTheSidebarOnlyWhenItChanges() {
        let wasSize = Tokens.Sidebar.size
        let wasScale = Tokens.Sidebar.customScale
        // The tests run in the app, on its own preferences: the percentage goes back to unset if it was.
        let wasKept = UserDefaults.standard.object(forKey: "SidebarSizePercent")
        defer {
            Tokens.Sidebar.size = wasSize
            Tokens.Sidebar.customScale = wasScale
            UserDefaults.standard.set(wasKept, forKey: "SidebarSizePercent")
        }

        nonisolated final class Count: @unchecked Sendable { var heard = 0 }
        let count = Count()
        let token = NotificationCenter.default.addObserver(forName: Tokens.Sidebar.sizeChanged, object: nil, queue: nil) { _ in count.heard += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        Tokens.Sidebar.size = .custom
        Tokens.Sidebar.customScale = 1.25
        count.heard = 0
        Tokens.Sidebar.customScale = 1.3
        #expect(count.heard == 1)
        Tokens.Sidebar.customScale = 1.3
        #expect(count.heard == 1)
        Tokens.Sidebar.customScale = 1.304
        #expect(count.heard == 1)

        Tokens.Sidebar.size = .medium
        count.heard = 0
        Tokens.Sidebar.customScale = 1.4
        #expect(count.heard == 0)
    }
}

/// A tab's speaker sits in its title's line as a symbol in text does: a word space after the title, its middle a
/// little under the caps' middle, and its body on the same pixels playing and muted.
@MainActor struct TabSpeakerTests {
    @Test func theSpeakerSitsBetweenTheXHeightAndTheCaps() {
        let font = Tokens.Font.sidebarRow()
        let drop = TabRowView.speakerDrop(capHeight: font.capHeight, xHeight: font.xHeight)
        // Halfway between the caps' middle and the x-height's.
        #expect(abs(drop - (font.capHeight / 2 - font.xHeight / 2) / 2) < 0.001)
        #expect(drop > 0 && drop < 1)
        #expect(Tokens.Sidebar.inlineGlyphGap < Tokens.Sidebar.iconGap)
    }

    /// Placed by the shared offsets, both symbols have their alignment rect's origin, where the speaker's body
    /// starts on the baseline, at one point.
    @Test func playingAndMutedShareTheSpeakersPlace() {
        let config = NSImage.SymbolConfiguration(pointSize: Tokens.Sidebar.rowText, weight: .regular, scale: .small)
        let images = ["speaker.wave.2", "speaker.slash"].compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config) }
        guard images.count == 2 else { return }
        for reference in [0, nil] as [Int?] {
            let inks = Tokens.Symbol.sharedInkOffsets(of: images, keys: ["test wave", "test slash"], reference: reference)
            // Each image's middle sits at -ink from the button's; its alignment origin is that much further on.
            let origins = zip(images, inks).map { image, ink in
                CGPoint(x: -ink.width + image.alignmentRect.minX - image.size.width / 2, y: -ink.height + image.alignmentRect.minY - image.size.height / 2)
            }
            #expect(abs(origins[0].x - origins[1].x) < 0.001 && abs(origins[0].y - origins[1].y) < 0.001, "\(origins)")
        }
        // Centered by the playing glyph alone, it's where it was before muting was shared.
        let alone = Tokens.Symbol.inkOffset(of: images[0], key: "test wave")
        let shared = Tokens.Symbol.sharedInkOffsets(of: images, keys: ["test wave", "test slash"], reference: 0)[0]
        #expect(abs(alone.width - shared.width) < 0.001 && abs(alone.height - shared.height) < 0.001)
    }
}

/// A split part's speaker (#351): after the title while there's room for both, as a tab's is; otherwise the badge a
/// favorite has, on the icon's corner, the icon cut round it.
@MainActor struct SplitSpeakerTests {
    private func row(parts: Int, width: CGFloat) -> TabRowView {
        let tabs = (0..<parts).map { Tab(url: URL(string: "https://example.com/\($0)"), title: "Page \($0)", spaceID: UUID()) }
        for (i, tab) in tabs.enumerated() { tab.debugShowSound(playing: i % 2 == 0, muted: i % 2 == 1) }
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: width, height: Tokens.Sidebar.rowHeight))
        row.configure(tab: tabs[0])
        row.configure(parts: tabs.dropFirst().map { TabRowView.Part(page: $0) })
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func speakers(of row: TabRowView) -> [IconButton] {
        row.subviews.compactMap { $0 as? IconButton }.filter { !$0.isHidden && $0.toolTip?.localizedCaseInsensitiveContains("mute") == true }
    }

    @Test func iconOnlyPartsShowTheFavoritesBadge() throws {
        let row = row(parts: 4, width: 228)
        let icons = row.subviews.compactMap { $0 as? FaviconView }.filter { !$0.isHidden }
        let badges = speakers(of: row)
        #expect(icons.count == 4 && badges.count == 4)
        #expect(badges.allSatisfy { SpeakerBadge.isBadge($0) && $0.frame.size == NSSize(width: SpeakerBadge.target, height: SpeakerBadge.target) })
        for icon in icons {
            let disc = row.convert(try #require(icon.speakerCut), from: icon)
            #expect(badges.contains { abs($0.frame.midX - disc.midX) < 0.01 && abs($0.frame.midY - disc.midY) < 0.01 })
        }
    }

    @Test func aTitledPartKeepsTheSpeakerAfterItsTitle() {
        let row = row(parts: 2, width: 228)
        let shown = speakers(of: row)
        #expect(shown.count == 2)
        #expect(shown.allSatisfy { !SpeakerBadge.isBadge($0) && $0.frame.width == Tokens.Sidebar.rowButton })
        #expect(row.subviews.compactMap { $0 as? FaviconView }.allSatisfy { $0.speakerCut == nil })
    }

    /// Too narrow for the title and the speaker after it, the title stays and the speaker goes on the icon.
    @Test func aPartTooShortForBothKeepsItsTitle() {
        let row = row(parts: 3, width: 210)
        let shown = speakers(of: row)
        #expect(shown.count == 3 && shown.allSatisfy { SpeakerBadge.isBadge($0) })
        #expect(row.subviews.compactMap { $0 as? Label }.filter { !$0.isHidden && $0.frame.width > 0 }.count == 3)
    }

    /// Back to one page, the row's own speaker is a row button again and its icon whole.
    @Test func leavingTheSplitRestoresTheRowSpeaker() {
        let row = row(parts: 4, width: 228)
        row.configure(parts: [])
        row.layoutSubtreeIfNeeded()
        #expect(!SpeakerBadge.isBadge(row.audioButton) && row.audioButton.frame.width == Tokens.Sidebar.rowButton)
        #expect(row.icon.speakerCut == nil)
    }
}
