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
        if parts > 1 { row.configure(pinnedPartner: "Second", icon: nil, unloaded: true) }
        row.configure(pinnedExtras: (2..<max(parts, 2)).map { ("Page \($0)", nil, nil) })
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

    /// When the close button would hide the last title, its room is reserved even at rest, so nothing shifts on hover.
    @Test func aNarrowLastPartKeepsTheCloseButtonsRoom() {
        let parts = 3
        let r = row(parts: parts, width: 228)
        let shown = titles(of: r)
        #expect(shown.count == parts)
        #expect((shown.last?.frame.maxX ?? .infinity) <= r.closeButton.frame.minX)
        let lines = lines(of: r)
        let starts = [0] + lines.map(\.midX) + [r.closeButton.frame.minX]
        let widths = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 3)
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
}
