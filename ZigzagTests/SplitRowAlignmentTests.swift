import AppKit
import Testing
@testable import Zigzag

/// A row of several pages lines up with the rows around it (#203): the same height and icon size; with room for titles
/// its first page's icon in the column every tab's icon is in, the others stepping along; without, each icon centered
/// in its part, as in a segmented control, with no hairlines between.
@MainActor struct SplitRowAlignmentTests {
    private func icons(of row: TabRowView) -> [NSRect] {
        row.subviews.compactMap { $0 as? FaviconView }.filter { !$0.isHidden }.map(\.frame).sorted { $0.minX < $1.minX }
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

    @Test func theOtherIconsStepAlongEvenly() {
        let xs = icons(of: row(parts: 4, width: 260)).map(\.minX)
        let steps = zip(xs.dropFirst(), xs).map { $0 - $1 }
        // Even steps, a pixel's rounding apart at most.
        #expect((steps.max() ?? 0) - (steps.min() ?? 0) <= 1)
    }
}

extension SplitRowAlignmentTests {
    @Test func withoutTitlesEachIconIsCenteredInItsPart() {
        let width: CGFloat = 200
        let r = row(parts: 3, width: width)
        let xs = icons(of: r).map(\.midX)
        #expect(!TabRowView.segmentShowsTitle(width: width / 3))
        // Centered in three equal parts that end where the close's room begins: evenly apart, the middle one in the
        // middle of the parts.
        let end = r.closeButton.frame.minX
        #expect(xs.count == 3)
        #expect(abs((xs[1] - xs[0]) - (xs[2] - xs[1])) <= 1)
        #expect(abs(xs[1] - end / 2) <= 4)
    }
}
