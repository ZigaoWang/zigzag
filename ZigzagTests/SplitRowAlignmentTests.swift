import AppKit
import Testing
@testable import Zigzag

/// A row of several pages lines up with the rows around it (#203): the same height, its first page's icon in the column
/// every tab's icon is in, the others stepping along evenly; with no room for titles, the last as far in from the row's
/// end as the first is from its start, with no hairlines between.
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

    @Test(arguments: [2, 3, 4]) func theFirstIconIsInTheTabsIconColumn(parts: Int) {
        for width in [200, 260, 340] as [CGFloat] {
            let single = icons(of: row(parts: 1, width: width))
            let group = icons(of: row(parts: parts, width: width))
            #expect(group.count == parts)
            #expect(group.first?.minX == single.first?.minX)
            #expect(group.allSatisfy { $0.midY == single[0].midY && $0.size == single[0].size })
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
    @Test func withoutTitlesTheLastIconRunsUpToTheClosesRoom() {
        let width: CGFloat = 200
        let r = row(parts: 3, width: width)
        let xs = icons(of: r)
        #expect(!TabRowView.segmentShowsTitle(width: width / 3))
        // No empty room after the last icon: it ends a row inset (and the button gap) before the close's room, which
        // the row keeps whether or not the close shows.
        let gap = r.closeButton.frame.minX - (xs.last?.maxX ?? 0)
        #expect(gap >= TabRowView.inset && gap <= TabRowView.inset + 3)
    }
}
