import Foundation
import Testing
@testable import Zigzag

/// Tile groups (#160): how two to four pages share the page area, where a dragged tab lands, and how a group grows,
/// shrinks and is saved.
struct TileLayoutTests {
    typealias Pair = TabManager.SplitPair
    let area = CGRect(x: 100, y: 50, width: 1000, height: 600)

    // MARK: Places

    /// A tab dropped on a split row joins it: a quarter of the half on its side, then the last half.
    @Test func aTabJoinsASplitFromTheSidebar() {
        #expect(TileShape.joining([.left, .right], onRight: true) == .place(region: .bottomRight, regions: [.left, .topRight]))
        #expect(TileShape.joining([.left, .right], onRight: false) == .place(region: .bottomLeft, regions: [.topLeft, .right]))
        #expect(TileShape.joining([.left, .topRight, .bottomRight], onRight: true) == .place(region: .bottomLeft, regions: [.topLeft, .topRight, .bottomRight]))
        #expect(TileShape.joining([.top, .bottom], onRight: true) == .place(region: .bottomRight, regions: [.top, .bottomLeft]))
        #expect(TileShape.joining([.topLeft, .topRight, .bottomLeft, .bottomRight], onRight: true) == nil)
    }

    @Test func everyRegionIsItsCells() {
        for region in TileRegion.allCases { #expect(TileRegion(cells: region.cells) == region) }
        #expect(TileRegion(cells: 0b0111) == nil)
        #expect(TileRegion(cells: 0b1111) == nil)
        #expect(TileRegion.allCases.filter(\.isHalf).count == 4 && TileRegion.allCases.filter(\.isQuarter).count == 4)
        #expect(TileRegion.left.opposite == .right && TileRegion.top.opposite == .bottom && TileRegion.topLeft.opposite == nil)
    }

    @Test func aGroupCoversThePageOnce() {
        #expect(TileShape.isValid([.left, .right]))
        #expect(TileShape.isValid([.top, .bottom]))
        #expect(TileShape.isValid([.left, .topRight, .bottomRight]))
        #expect(TileShape.isValid([.bottom, .topLeft, .topRight]))
        #expect(TileShape.isValid([.topLeft, .topRight, .bottomLeft, .bottomRight]))
        // One page is no group; overlaps and gaps aren't either.
        #expect(!TileShape.isValid([.left]))
        #expect(!TileShape.isValid([.left, .top]))
        #expect(!TileShape.isValid([.left, .topRight]))
        #expect(!TileShape.isValid([.topLeft, .topRight, .bottomLeft]))
        #expect(!TileShape.isValid([.left, .left]))
    }

    // MARK: Frames

    @Test func twoPagesAreTheSplitTheyAlwaysWere() {
        // As a split of two always laid out: the first gets its share of what the gap leaves, the second the rest.
        let gap: CGFloat = 8
        let frames = TileShape.pair(ratio: 0.4, vertical: false).frames(in: area, gap: gap)
        let leftWidth = floor((area.width - gap) * 0.4)
        #expect(frames[0] == CGRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height))
        #expect(frames[1] == CGRect(x: area.minX + leftWidth + gap, y: area.minY, width: area.width - leftWidth - gap, height: area.height))
        let stacked = TileShape.pair(ratio: 0.5, vertical: true).frames(in: area, gap: gap)
        let topHeight = floor((area.height - gap) * 0.5)
        #expect(stacked[0] == CGRect(x: area.minX, y: area.minY, width: area.width, height: topHeight))
        #expect(stacked[1] == CGRect(x: area.minX, y: area.minY + topHeight + gap, width: area.width, height: area.height - topHeight - gap))
    }

    @Test func aGridIsFourQuartersAGapApart() {
        let frames = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight]).frames(in: area, gap: 10)
        #expect(frames[0] == CGRect(x: 100, y: 50, width: 495, height: 295))
        #expect(frames[1] == CGRect(x: 605, y: 50, width: 495, height: 295))
        #expect(frames[2] == CGRect(x: 100, y: 355, width: 495, height: 295))
        #expect(frames[3] == CGRect(x: 605, y: 355, width: 495, height: 295))
        // Nothing overlaps, and together they reach every edge.
        for i in 0..<4 { for j in (i + 1)..<4 { #expect(!frames[i].intersects(frames[j])) } }
        #expect(frames.map(\.minX).min() == area.minX && frames.map(\.maxX).max() == area.maxX)
        #expect(frames.map(\.minY).min() == area.minY && frames.map(\.maxY).max() == area.maxY)
    }

    @Test func aHalfAndTwoQuartersShareTheLines() {
        let shape = TileShape(regions: [.left, .topRight, .bottomRight], column: 0.6, row: 0.3)
        let frames = shape.frames(in: area, gap: 0)
        #expect(frames[0] == CGRect(x: 100, y: 50, width: 600, height: 600))
        #expect(frames[1] == CGRect(x: 700, y: 50, width: 400, height: 180))
        #expect(frames[2] == CGRect(x: 700, y: 230, width: 400, height: 420))
    }

    @Test func linesRunOnlyWhereTheyDividePages() {
        let gap: CGFloat = 8
        // Side by side: only the line between the columns, all the way down.
        let pair = TileShape(regions: [.left, .right]).dividers(in: area, gap: gap, slop: 2)
        #expect(pair.row == nil)
        #expect(pair.column?.height == area.height && pair.column?.width == gap + 4)
        // Stacked: only the line between the rows.
        let stacked = TileShape(regions: [.top, .bottom]).dividers(in: area, gap: gap, slop: 2)
        #expect(stacked.column == nil && stacked.row?.width == area.width)
        // A half on the left: the column line runs the whole height, the row line only across the right column.
        let three = TileShape(regions: [.left, .topRight, .bottomRight]).dividers(in: area, gap: gap, slop: 0)
        let x = area.minX + floor((area.width - gap) / 2)
        #expect(three.column == CGRect(x: x, y: area.minY, width: gap, height: area.height))
        #expect(three.row?.minX == x + gap && three.row?.maxX == area.maxX)
        // A half on top: the column line only in the bottom row.
        let top = TileShape(regions: [.top, .bottomLeft, .bottomRight]).dividers(in: area, gap: gap, slop: 0)
        #expect(top.row?.width == area.width && top.column?.maxY == area.maxY && top.column?.minY ?? 0 > area.minY)
        // A grid: both, all the way across.
        let grid = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight]).dividers(in: area, gap: gap, slop: 0)
        #expect(grid.column?.height == area.height && grid.row?.width == area.width)
    }

    // MARK: Sizes of their own (#316, #309)

    @Test func eachRowKeepsItsOwnLineBetweenTheColumns() {
        var shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        // The top row's line moves; the bottom row's stays where it was.
        shape.moveColumnLine(in: 0, to: 0.3, length: area.width, minimum: 100)
        let frames = shape.frames(in: area, gap: 10)
        #expect(frames[0] == CGRect(x: 100, y: 50, width: 297, height: 295))
        #expect(frames[1] == CGRect(x: 407, y: 50, width: 693, height: 295))
        #expect(frames[2] == CGRect(x: 100, y: 355, width: 495, height: 295))
        #expect(frames[3] == CGRect(x: 605, y: 355, width: 495, height: 295))
        #expect(shape.columnShares == [0.3, 0.5])
        // Nothing overlaps, and together they still reach every edge.
        for i in 0..<4 { for j in (i + 1)..<4 { #expect(!frames[i].intersects(frames[j])) } }
        #expect(frames.map(\.minX).min() == area.minX && frames.map(\.maxX).max() == area.maxX)
        #expect(frames.map(\.minY).min() == area.minY && frames.map(\.maxY).max() == area.maxY)
    }

    @Test func theLineBetweenTheRowsIsOneLine() throws {
        var shape = TileShape(regions: [.left, .topRight, .bottomRight])
        // The right column's line moves; the left page still runs the whole height, and its column's share follows.
        shape.moveRowLine(in: 1, to: 0.4, length: area.height, minimum: 100)
        let frames = shape.frames(in: area, gap: 0)
        #expect(frames[0] == CGRect(x: 100, y: 50, width: 500, height: 600))
        #expect(frames[1] == CGRect(x: 600, y: 50, width: 500, height: 240))
        #expect(frames[2] == CGRect(x: 600, y: 290, width: 500, height: 360))
        #expect(shape.rowShares == [0.4, 0.4])
        #expect(frames[0].maxX == frames[1].minX && frames[2].maxY == area.maxY)
        // A fourth page in the left half's place keeps the line where it was.
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let three = try #require(Pair(ids: Array(ids.prefix(3)), shape: shape))
        let four = try #require(three.adding(ids[3], .place(region: .bottomLeft, regions: [.topLeft, .topRight, .bottomRight])))
        #expect(four.shape.rowShares == [0.4, 0.4])
        // Out of a grid the line between the columns is one line too.
        var top = TileShape(regions: [.top, .bottomLeft, .bottomRight])
        top.moveColumnLine(in: 1, to: 0.3, length: area.width, minimum: 100)
        #expect(top.columnShares == [0.3, 0.3] && !top.isParted)
    }

    @Test func aPartedGridsQuarterKeepsItsWidthAsItGrows() throws {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        var shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        shape.columnShares = [0.3, 0.6]
        #expect(shape.isParted)
        let group = try #require(Pair(ids: ids, shape: shape))
        // The top left goes: the bottom left grows into the left half at its own width.
        let rest = try #require(group.removing(ids[0]))
        #expect(rest.shape.regions.contains(.left) && rest.shape.column == 0.6)
        // A grid whose line is one, at any share, isn't parted.
        #expect(!TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight], column: 0.3).isParted)
        #expect(!TileShape(regions: [.left, .right], column: 0.3).isParted)
    }

    @Test func eachColumnKeepsItsOwnLineBetweenTheRows() {
        var shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        // The right column's line moves; the left column's stays where it was, so the top right grows taller.
        shape.moveRowLine(in: 1, to: 0.7, length: area.height, minimum: 100)
        let frames = shape.frames(in: area, gap: 10)
        #expect(frames[0].height == 295 && frames[2].height == 295)
        #expect(frames[1].height + frames[3].height + 10 == 600, "\(frames) shares \(shape.columnShares) \(shape.rowShares)")
        #expect(frames[1].height > frames[0].height && frames[3].height < frames[0].height, "\(frames) shares \(shape.columnShares) \(shape.rowShares) apart \(shape.rowsApart)")
        #expect(frames[2].minY == frames[0].maxY + 10)
        #expect(frames[1].minY == frames[0].minY && frames[3].minY == frames[1].maxY + 10)
        #expect(shape.rowShares == [0.5, 0.7])
        #expect(shape.rowsApart && !shape.columnsApart && shape.isParted)
        // Four rectangles cover the area only with one pair of lines apart: parting the rows joined the columns.
        #expect(shape.columnShares == [0.5, 0.5])
        for i in 0..<4 { for j in (i + 1)..<4 { #expect(!frames[i].intersects(frames[j])) } }
        #expect(frames.map(\.minX).min() == area.minX && frames.map(\.maxX).max() == area.maxX)
        #expect(frames.map(\.minY).min() == area.minY && frames.map(\.maxY).max() == area.maxY)
        // Parting the columns in turn joins the rows again.
        shape.moveColumnLine(in: 0, to: 0.3, length: area.width, minimum: 100)
        #expect(shape.columnsApart && !shape.rowsApart)
    }

    @Test func onlyShiftOrAPartedLineMovesASegmentAlone() {
        let grid: [TileRegion] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let even = TileShape(regions: grid)
        #expect(!even.movesAlone(.column, shift: false) && !even.movesAlone(.row, shift: false))
        #expect(even.movesAlone(.column, shift: true) && even.movesAlone(.row, shift: true))
        // Columns parted: their segments move alone; the row line stays one line, even with Shift.
        var columns = even
        columns.columnShares = [0.3, 0.6]
        #expect(columns.movesAlone(.column, shift: false))
        #expect(!columns.movesAlone(.row, shift: false) && !columns.movesAlone(.row, shift: true))
        // And the other way round.
        var rows = even
        rows.rowShares = [0.3, 0.6]
        #expect(rows.movesAlone(.row, shift: false) && !rows.movesAlone(.column, shift: true))
        // Out of a grid nothing parts.
        #expect(!TileShape(regions: [.left, .topRight, .bottomRight]).movesAlone(.row, shift: true))
    }

    @Test func aCornerOfPartedRowsMovesOnlyItsOwnSegment() throws {
        var shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        shape.rowShares = [0.3, 0.6]
        let corner = try #require(shape.corners(in: area, gap: 10, slop: 2).first { $0.columns == [1] })
        shape.moveCorner(corner, to: CGPoint(x: area.minX + 0.45 * area.width, y: area.minY + 0.7 * area.height),
                         in: area, minimumWidth: 100, minimumHeight: 100)
        // The left column's line stays put; the column line stays one line.
        #expect(shape.rowShares[0] == 0.3 && abs(shape.rowShares[1] - 0.7) < 1e-9)
        #expect(shape.columnShares[0] == shape.columnShares[1] && abs(shape.columnShares[0] - 0.45) < 1e-9)
    }

    @Test func pagesComeAndGoFromPartedRowsWithoutAJump() throws {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        var shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        shape.rowShares = [0.3, 0.6]
        let group = try #require(Pair(ids: ids, shape: shape))
        // The top left goes: the right column, still in two, keeps its line.
        let rest = try #require(group.removing(ids[0]))
        #expect(rest.shape.row == 0.6 && rest.shape.rowShares == [0.6, 0.6])
        // A page back in the left half's bottom: the new grid's row line is where the right column's was.
        let back = try #require(rest.adding(UUID(), .place(region: .bottomLeft, regions: [.topLeft, .topRight, .bottomRight])))
        #expect(back.shape.rowShares == [0.6, 0.6])
        // A grid saved with its columns parted, as before rows could part, opens the same.
        var columns = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight], row: 0.4)
        columns.columnShares = [0.3, 0.6]
        let saved = try #require(Pair(ids: ids, shape: columns))
        let reopened = try JSONDecoder().decode(Pair.self, from: JSONEncoder().encode(saved))
        #expect(reopened.shape.columnShares == [0.3, 0.6] && reopened.shape.rowShares == [0.4, 0.4])
    }

    @Test func aSegmentSnapsToTheOtherColumnsLineAndTheMiddle() {
        var shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        shape.moveRowLine(in: 0, to: 0.35, length: area.height, minimum: 100)
        shape.moveRowLine(in: 1, to: 0.35 + 5 / area.height, length: area.height, minimum: 100)
        // The right column's line is a few points from the left's: that is where it snaps, not the middle.
        #expect(shape.rowSnapShare(in: 1, whole: false, length: area.height) == 0.35)
        shape.snapRowLine(in: 1, to: 0.35)
        #expect(shape.rowShares == [0.35, 0.35] && !shape.isParted)
        // Far from the other line, the middle is still the snap.
        shape.moveRowLine(in: 0, to: 0.4, length: area.height, minimum: 100)
        shape.moveRowLine(in: 1, to: 0.5 + 6 / area.height, length: area.height, minimum: 100)
        #expect(shape.rowSnapShare(in: 1, whole: false, length: area.height) == 0.5)
        // A whole line has only the middle.
        #expect(shape.rowSnapShare(in: 0, whole: true, length: area.height) == nil)
    }

    @Test func linesKeepTheirShareOfTheArea() {
        var shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        shape.moveColumnLine(in: 0, to: 0.3, length: area.width, minimum: 100)
        // A smaller window lays the same sizes out again, in its own points.
        let small = CGRect(x: 0, y: 0, width: 500, height: 300)
        let frames = shape.frames(in: small, gap: 10)
        #expect(frames[0] == CGRect(x: 0, y: 0, width: 147, height: 145))
        #expect(frames[1] == CGRect(x: 157, y: 0, width: 343, height: 145))
        #expect(frames[2] == CGRect(x: 0, y: 155, width: 245, height: 145))
        #expect(frames[3] == CGRect(x: 255, y: 155, width: 245, height: 145))
    }

    @Test func aSegmentRunsWhereTwoPagesMeet() throws {
        let pair = TileShape(regions: [.left, .right]).segments(in: area, gap: 8, slop: 2)
        #expect(pair.count == 1)
        let line = try #require(pair.first)
        #expect(line.axis == .column && line.first == 0 && line.second == 1)
        #expect(line.frame == CGRect(x: 594, y: 50, width: 12, height: 600))
        #expect(TileShape(regions: [.left, .right]).corners(in: area, gap: 8, slop: 2).isEmpty)
        let stacked = TileShape(regions: [.top, .bottom]).segments(in: area, gap: 8, slop: 2)
        #expect(stacked.count == 1 && stacked[0].axis == .row && stacked[0].column == 0)
        // A half and two quarters: a segment in the top row and one in the bottom, and one between the quarters.
        let three = TileShape(regions: [.left, .topRight, .bottomRight])
        let strips = three.segments(in: area, gap: 8, slop: 2)
        #expect(strips.count == 3)
        #expect(strips.filter { $0.axis == .column }.map(\.row).sorted() == [0, 1])
        #expect(strips.filter { $0.axis == .row }.map(\.column) == [1])
        let corners = three.corners(in: area, gap: 8, slop: 2)
        #expect(corners.count == 1 && corners[0].rows == [0, 1] && corners[0].columns == [1])
    }

    @Test func aSegmentMovesOnlyTheTwoPagesItDivides() throws {
        var shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        let strips = shape.segments(in: area, gap: 10, slop: 2)
        #expect(strips.count == 4)
        let segment = try #require(strips.first { $0.axis == .column && $0.row == 0 })
        #expect(segment.first == 0 && segment.second == 1)
        #expect(segment.frame.height == 295 && segment.frame.width == 14)
        shape.moveColumnLine(in: segment.row, to: 0.3, length: area.width, minimum: 100)
        let frames = shape.frames(in: area, gap: 10)
        // Only the top left and top right changed; the bottom row is as it was.
        #expect(frames[0].width == 297 && frames[1].maxX == area.maxX && frames[1].width == 693)
        #expect(frames[2] == CGRect(x: 100, y: 355, width: 495, height: 295))
        #expect(frames[3] == CGRect(x: 605, y: 355, width: 495, height: 295))
        #expect(shape.columnShares == [0.3, 0.5])
    }

    @Test func aCornerMovesEveryLineThatMeetsThere() throws {
        let shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        let corners = shape.corners(in: area, gap: 10, slop: 2)
        #expect(corners.count == 1)
        let corner = try #require(corners.first)
        // From the even grid both rows' lines between the columns and both columns' between the rows meet here.
        #expect(corner.rows == [0, 1] && corner.columns == [0, 1])
        var moved = shape
        moved.moveCorner(corner, to: CGPoint(x: area.minX + 0.4 * area.width, y: area.minY + 0.35 * area.height),
                         in: area, minimumWidth: 100, minimumHeight: 100)
        #expect(moved.columnShares == [0.4, 0.4] && moved.rowShares == [0.35, 0.35])
        let frames = moved.frames(in: area, gap: 10)
        #expect(frames[0] == CGRect(x: 100, y: 50, width: 396, height: 206))
        #expect(frames[1] == CGRect(x: 506, y: 50, width: 594, height: 206))
        #expect(frames[2] == CGRect(x: 100, y: 266, width: 396, height: 384))
        #expect(frames[3] == CGRect(x: 506, y: 266, width: 594, height: 384))
    }

    @Test func evenAgainPutsEveryLineInTheMiddle() {
        var shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        shape.moveColumnLine(in: 0, to: 0.3, length: area.width, minimum: 100)
        shape.moveRowLine(in: 0, to: 0.7, length: area.height, minimum: 100)
        shape.evenOut()
        #expect(shape.columnShares == [0.5, 0.5] && shape.rowShares == [0.5, 0.5])
        let even = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        #expect(shape.frames(in: area, gap: 10) == even.frames(in: area, gap: 10))
    }

    @Test func aWholeLineMovesEveryRowOrColumnTogether() {
        var grid = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        // The plain drag of an even grid: the one line between the columns moves in both rows.
        grid.moveColumnLine(in: 0, to: 0.3, length: area.width, minimum: 100, whole: true)
        #expect(grid.columnShares == [0.3, 0.3])
        #expect(grid.rowShares == [0.5, 0.5])
        // Shift moves only the top row's segment.
        grid.moveColumnLine(in: 0, to: 0.7, length: area.width, minimum: 100)
        #expect(grid.columnShares == [0.7, 0.3])
        // A corner dragged whole moves both lines the same way.
        let corner = TileShape(regions: [.left, .topRight, .bottomRight]).corners(in: area, gap: 10, slop: 2)[0]
        var three = TileShape(regions: [.left, .topRight, .bottomRight])
        three.moveCorner(corner, to: CGPoint(x: area.minX + 0.4 * area.width, y: area.minY + 0.4 * area.height),
                         in: area, minimumWidth: 100, minimumHeight: 100, whole: true)
        #expect(three.columnShares == [0.4, 0.4] && three.rowShares == [0.4, 0.4])
    }

    @Test func aCustomLayoutSnapsALineBackToTheMiddleNearEven() {
        var grid = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        grid.moveColumnLine(in: 0, to: 0.3, length: area.width, minimum: 100)
        grid.moveColumnLine(in: 1, to: 0.7, length: area.width, minimum: 100)
        #expect(!grid.isEven)
        // Within 8pt of the middle, the guide shows and the line snaps in when let go.
        #expect(TileShape.nearEven(0.5 + 6 / area.width, length: area.width))
        #expect(!TileShape.nearEven(0.5 + 12 / area.width, length: area.width))
        #expect(grid.columnLineIsNearEven(in: 0, whole: false, length: area.width) == false)
        grid.snapColumnLine(in: 0, to: 0.5)
        #expect(grid.columnShares == [0.5, 0.7])
        // The other row's line is still custom; snapping it too makes the columns even.
        grid.snapColumnLine(in: 1, to: 0.5)
        #expect(grid.columnShares == [0.5, 0.5] && grid.isEven)
        // A row segment parts the rows and joins the columns into one line.
        grid.moveRowLine(in: 1, to: 0.7, length: area.height, minimum: 100)
        #expect(grid.rowsApart && !grid.columnsApart)
        #expect(grid.rowLineIsNearEven(in: 1, whole: false, length: area.height) == false)
        grid.snapRowLine(in: 1, to: 0.5)
        #expect(grid.rowShares == [0.5, 0.5] && grid.isEven)
        // A whole line snaps every share, and the even grid reads as even.
        var whole = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight], column: 0.3, row: 0.6)
        whole.snapColumnLine(in: 0, to: 0.5, whole: true)
        whole.snapRowLine(in: 0, to: 0.5, whole: true)
        #expect(whole.isEven)
    }

    @Test func aGroupsEvenStateComesFromItsShares() {
        #expect(TileShape(regions: [.left, .right]).isEven)
        var split = TileShape(regions: [.left, .right])
        split.moveColumnLine(in: 0, to: 0.4, length: area.width, minimum: 100)
        #expect(!split.isEven)
        split.snapColumnLine(in: 0, to: 0.5)
        #expect(split.isEven)
        // A near line is within the 8pt guide band; a far one is not.
        #expect(split.columnLineIsNearEven(in: 0, whole: false, length: area.width))
        split.moveColumnLine(in: 0, to: 0.42, length: area.width, minimum: 100)
        #expect(!split.columnLineIsNearEven(in: 0, whole: false, length: area.width))
    }

    @Test func everyLineKeepsEachPageUsable() throws {
        var shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        // The top row's line stops where its pages are still wide enough, and leaves the bottom row's alone.
        shape.moveColumnLine(in: 0, to: 0.01, length: area.width, minimum: 260)
        #expect(abs(shape.columnShares[0] - 0.26) < 1e-9)
        #expect(shape.columnShares[1] == 0.5)
        // The right column's line between the rows stops where a page is still tall enough; the left's stays, and
        // the columns join into one line.
        shape.moveRowLine(in: 1, to: 0.99, length: area.height, minimum: 260)
        let tallest = 1 - 260.0 / area.height
        #expect(abs(shape.rowShares[1] - tallest) < 1e-9 && shape.rowShares[0] == 0.5)
        #expect(abs(shape.columnShares[0] - 0.38) < 1e-9 && shape.columnShares[1] == shape.columnShares[0])
        // A corner both ways, each against its own minimum.
        var grid = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        let corner = try #require(grid.corners(in: area, gap: 10, slop: 2).first)
        grid.moveCorner(corner, to: CGPoint(x: area.maxX, y: area.maxY), in: area, minimumWidth: 260, minimumHeight: 260)
        #expect(abs(grid.columnShares[0] - 0.74) < 1e-9 && grid.columnShares[1] == grid.columnShares[0])
        #expect(abs(grid.rowShares[0] - tallest) < 1e-9)
        // Still four separate pages, still covering the area.
        let frames = grid.frames(in: area, gap: 10)
        for i in 0..<4 { for j in (i + 1)..<4 { #expect(!frames[i].intersects(frames[j])) } }
        #expect(frames.map(\.minX).min() == area.minX && frames.map(\.maxX).max() == area.maxX)
        #expect(frames.map(\.minY).min() == area.minY && frames.map(\.maxY).max() == area.maxY)
    }

    @Test func aGroupsOwnLinesComeBackAsTheyWereSaved() throws {
        var shape = TileShape(regions: [.left, .topRight, .bottomRight])
        shape.moveRowLine(in: 1, to: 0.3, length: area.height, minimum: 100)
        let ids = [UUID(), UUID(), UUID()]
        let group = try #require(Pair(ids: ids, shape: shape))
        #expect(group.shares == [0.5, 0.5, 0.3, 0.3])
        #expect(group.shape == shape)
        let back = try JSONDecoder().decode(Pair.self, from: JSONEncoder().encode(group))
        #expect(back.shape.columnShares == shape.columnShares && back.shape.rowShares == shape.rowShares)
        // The pinned group keeps them too, and opens with them.
        let pinned = try #require(PinnedSplit(ids, as: group))
        #expect(pinned.shares == group.shares)
        let reopened = try JSONDecoder().decode(PinnedSplit.self, from: JSONEncoder().encode(pinned))
        #expect(reopened.shares == group.shares)
        let pair = try #require(reopened.pair(of: ids))
        #expect(pair.shape.columnShares == shape.columnShares && pair.shape.rowShares == shape.rowShares)
        // A group saved before its rows had lines of their own opens with the even ones.
        let old = #"{"left":"\#(ids[0].uuidString)","right":"\#(ids[1].uuidString)","more":["\#(ids[2].uuidString)"],"regions":["left","topRight","bottomRight"],"ratio":0.6}"#
        let older = try JSONDecoder().decode(Pair.self, from: Data(old.utf8))
        #expect(older.shape.columnShares == [0.6, 0.6] && older.shape.rowShares == [0.5, 0.5])
    }

    @Test func movingTheLinesSavesThemWithoutMovingThePages() throws {
        var shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        shape.moveColumnLine(in: 1, to: 0.7, length: area.width, minimum: 100)
        let group = try #require(Pair(ids: [UUID(), UUID(), UUID(), UUID()], shape: shape))
        var moved = group
        moved.setLines(of: shape)
        #expect(moved.regions == group.regions && moved.ids == group.ids)
        #expect(moved.shape.columnShares == [0.5, 0.7] && moved.shape.rowShares == [0.5, 0.5])
        #expect(moved.ratio == group.ratio && moved.otherRatio == group.otherRatio)
        // The old way of moving the lines still keeps the one line each, as a split always had.
        var three = try #require(Pair(ids: [UUID(), UUID(), UUID()], shape: TileShape(regions: [.left, .topRight, .bottomRight])))
        three.setRatios(column: 0.4, row: 0.25)
        #expect(three.shape.columnShares == [0.4, 0.4] && three.shape.rowShares == [0.25, 0.25])
    }

    @Test func aDividerKeepsEveryPaneUsable() {
        #expect(abs(TileShape.clamped(0.05, length: 1000, minimum: 260) - 0.26) < 1e-9)
        #expect(abs(TileShape.clamped(0.95, length: 1000, minimum: 260) - 0.74) < 1e-9)
        #expect(TileShape.clamped(0.5, length: 1000, minimum: 260) == 0.5)
        #expect(TileShape.clamped(0.1, length: 3000, minimum: 260) == 0.2)
        // Too small for two: the middle.
        #expect(TileShape.clamped(0.3, length: 400, minimum: 260) == 0.5)
    }

    // MARK: Growing and shrinking

    @Test func besideOnePageAHalfTakesTheOtherHalf() {
        #expect(TileShape.placing(.left, beside: []) == [.right])
        #expect(TileShape.placing(.bottom, beside: []) == [.top])
        // A quarter beside a page alone would leave a hole.
        #expect(TileShape.placing(.topLeft, beside: []) == nil)
    }

    @Test func aCornerSplitsTheHalfItIsIn() {
        #expect(TileShape.placing(.topLeft, beside: [.left, .right]) == [.bottomLeft, .right])
        #expect(TileShape.placing(.bottomRight, beside: [.left, .right]) == [.left, .topRight])
        #expect(TileShape.placing(.topRight, beside: [.top, .bottom]) == [.topLeft, .bottom])
        // Three: the half splits; a quarter can't.
        #expect(TileShape.placing(.bottomLeft, beside: [.left, .topRight, .bottomRight]) == [.topLeft, .topRight, .bottomRight])
        #expect(TileShape.placing(.topRight, beside: [.left, .topRight, .bottomRight]) == nil)
        // Four is full.
        #expect(TileShape.placing(.topLeft, beside: [.topLeft, .topRight, .bottomLeft, .bottomRight]) == nil)
    }

    @Test func anEdgeBesideTwoMovesBothIntoTheOtherHalf() {
        // Dropped on the left edge of two side by side: they stack on the right, the left one on top.
        #expect(TileShape.placing(.left, beside: [.left, .right]) == [.topRight, .bottomRight])
        #expect(TileShape.placing(.top, beside: [.left, .right]) == [.bottomLeft, .bottomRight])
        #expect(TileShape.placing(.right, beside: [.top, .bottom]) == [.topLeft, .bottomLeft])
        // In their order on screen, whichever is first in the group.
        #expect(TileShape.placing(.left, beside: [.right, .left]) == [.bottomRight, .topRight])
        // Three have no half to give.
        #expect(TileShape.placing(.top, beside: [.left, .topRight, .bottomRight]) == nil)
    }

    @Test func aPageThatGoesLeavesItsRoomToTheOthers() {
        // Two left: no group.
        #expect(TileShape.removing(0, from: [.left, .right]) == nil)
        // A quarter goes: the one beside it in its half takes the half.
        #expect(TileShape.removing(1, from: [.left, .topRight, .bottomRight]) == [.left, .right])
        #expect(TileShape.removing(2, from: [.top, .bottomLeft, .bottomRight]) == [.top, .bottom])
        // The half goes: the quarters across from it become halves.
        #expect(TileShape.removing(0, from: [.left, .topRight, .bottomRight]) == [.top, .bottom])
        #expect(TileShape.removing(0, from: [.bottom, .topLeft, .topRight]) == [.left, .right])
        // Out of four, the page below or above takes the room, so the columns stay.
        #expect(TileShape.removing(0, from: [.topLeft, .topRight, .bottomLeft, .bottomRight]) == [.topRight, .left, .bottomRight])
        #expect(TileShape.removing(3, from: [.topLeft, .topRight, .bottomLeft, .bottomRight]) == [.topLeft, .right, .bottomLeft])
        // Whatever goes, what's left still covers the page.
        let shapes: [[TileRegion]] = [[.left, .topRight, .bottomRight], [.right, .topLeft, .bottomLeft], [.top, .bottomLeft, .bottomRight],
                                      [.bottom, .topLeft, .topRight], [.topLeft, .topRight, .bottomLeft, .bottomRight]]
        for shape in shapes { for i in shape.indices { #expect(TileShape.removing(i, from: shape).map(TileShape.isValid) == true) } }
    }

    // MARK: Where a drop lands

    private func drop(_ x: CGFloat, _ y: CGFloat, _ shape: TileShape?) -> TileDrop.Kind? {
        TileDrop.target(at: CGPoint(x: area.minX + area.width * x, y: area.minY + area.height * y), in: area, shape: shape, gap: 8)?.kind
    }

    @Test func besideOnePageItIsHalvesAsBefore() {
        // Most of the page is the left or the right half, as the split's drop always was.
        #expect(drop(0.3, 0.5, nil) == .place(region: .left, regions: [.right]))
        #expect(drop(0.7, 0.5, nil) == .place(region: .right, regions: [.left]))
        #expect(drop(0.02, 0.02, nil) == .place(region: .left, regions: [.right]))
        #expect(drop(0.98, 0.98, nil) == .place(region: .right, regions: [.left]))
        // The top and bottom edges stack.
        #expect(drop(0.5, 0.03, nil) == .place(region: .top, regions: [.bottom]))
        #expect(drop(0.5, 0.97, nil) == .place(region: .bottom, regions: [.top]))
        // Off the page: nowhere.
        #expect(TileDrop.target(at: CGPoint(x: 10, y: 10), in: area, shape: nil, gap: 8) == nil)
    }

    @Test func besideTwoCornersAreQuartersAndEdgesHalves() {
        let pair = TileShape(regions: [.left, .right])
        #expect(drop(0.02, 0.02, pair) == .place(region: .topLeft, regions: [.bottomLeft, .right]))
        #expect(drop(0.98, 0.98, pair) == .place(region: .bottomRight, regions: [.left, .topRight]))
        #expect(drop(0.02, 0.5, pair) == .place(region: .left, regions: [.topRight, .bottomRight]))
        #expect(drop(0.5, 0.02, pair) == .place(region: .top, regions: [.bottomLeft, .bottomRight]))
        // Over a page's middle, it splits: the quarter of it under the pointer.
        #expect(drop(0.25, 0.3, pair) == .place(region: .topLeft, regions: [.bottomLeft, .right]))
        #expect(drop(0.75, 0.7, pair) == .place(region: .bottomRight, regions: [.left, .topRight]))
        let stacked = TileShape(regions: [.top, .bottom])
        #expect(drop(0.7, 0.3, stacked) == .place(region: .topRight, regions: [.topLeft, .bottom]))
    }

    @Test func aQuarterThatCannotSplitTakesTheNewPage() {
        let three = TileShape(regions: [.left, .topRight, .bottomRight])
        // The half still splits, at its corners and in its middle.
        #expect(drop(0.02, 0.98, three) == .place(region: .bottomLeft, regions: [.topLeft, .topRight, .bottomRight]))
        #expect(drop(0.25, 0.2, three) == .place(region: .topLeft, regions: [.bottomLeft, .topRight, .bottomRight]))
        // An edge with no half to give splits the page under it.
        #expect(drop(0.25, 0.02, three) == .place(region: .topLeft, regions: [.bottomLeft, .topRight, .bottomRight]))
        // A quarter: in its place.
        #expect(drop(0.75, 0.25, three) == .replace(1))
        #expect(drop(0.98, 0.98, three) == .replace(2))
        let grid = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        #expect(drop(0.25, 0.75, grid) == .replace(2))
        #expect(drop(0.02, 0.5, grid) == .replace(0) || drop(0.02, 0.5, grid) == .replace(2))
    }

    @Test func theHintShowsWhereThePageWillBe() {
        // Beside a page alone, gapless halves of the page, as the hint always showed.
        let half = TileDrop.target(at: CGPoint(x: 200, y: 300), in: CGRect(x: 0, y: 0, width: 1000, height: 600), shape: nil, gap: 0)
        #expect(half?.frame == CGRect(x: 0, y: 0, width: 500, height: 600))
        // A corner beside two: that quarter, at the lines the group has.
        let quarter = TileDrop.target(at: CGPoint(x: 990, y: 10), in: CGRect(x: 0, y: 0, width: 1000, height: 600),
                                      shape: TileShape(regions: [.left, .right], column: 0.4), gap: 0)
        #expect(quarter?.frame == CGRect(x: 400, y: 0, width: 600, height: 300))
        // In a page's place: that page.
        let grid = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        let replace = TileDrop.target(at: CGPoint(x: 900, y: 500), in: CGRect(x: 0, y: 0, width: 1000, height: 600), shape: grid, gap: 0)
        #expect(replace?.frame == CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    @Test func theEdgesGrowWithThePageWithinReason() {
        #expect(TileDrop.edge(for: CGRect(x: 0, y: 0, width: 200, height: 150)) == 40)
        #expect(TileDrop.edge(for: CGRect(x: 0, y: 0, width: 1200, height: 700)) == 112)
        #expect(TileDrop.edge(for: CGRect(x: 0, y: 0, width: 4000, height: 3000)) == 120)
    }

    // MARK: The group itself

    @Test func anOldSplitOpensUnchanged() throws {
        let a = UUID(), b = UUID()
        let json = #"{"left":"\#(a.uuidString)","right":"\#(b.uuidString)","ratio":0.3,"vertical":true}"#
        let pair = try JSONDecoder().decode(Pair.self, from: Data(json.utf8))
        #expect(pair.ids == [a, b] && !pair.isGroup && pair.ratio == 0.3 && pair.vertical)
        #expect(pair.shape.regions == [.top, .bottom] && pair.shape.row == 0.3)
        // The oldest, before sizes were kept.
        let plain = try JSONDecoder().decode(Pair.self, from: Data(#"{"left":"\#(a.uuidString)","right":"\#(b.uuidString)"}"#.utf8))
        #expect(plain.ratio == 0.5 && !plain.vertical && plain.shape.regions == [.left, .right])
    }

    @Test func aGroupComesBackAsItWasSaved() throws {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight], column: 0.35, row: 0.6)
        let group = try #require(Pair(ids: ids, shape: shape))
        let back = try JSONDecoder().decode(Pair.self, from: JSONEncoder().encode(group))
        #expect(back == group && back.ids == ids && back.shape == shape)
        // An older Zigzag reads only the first two: a split of them, side by side.
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(group)) as? [String: Any])
        #expect(object["left"] as? String == ids[0].uuidString && object["right"] as? String == ids[1].uuidString)
    }

    @Test func aGroupThatDoesNotAddUpOpensAsASplit() throws {
        let a = UUID(), b = UUID(), c = UUID()
        // Two places for three pages.
        let short = #"{"left":"\#(a.uuidString)","right":"\#(b.uuidString)","more":["\#(c.uuidString)"],"regions":["left","right"]}"#
        let pair = try JSONDecoder().decode(Pair.self, from: Data(short.utf8))
        #expect(pair.ids == [a, b] && !pair.isGroup)
        // Overlapping places, a page twice, a place it doesn't know: the same.
        for bad in [#""regions":["left","left","right"]"#, #""regions":["sideways","topRight","bottomRight"]"#] {
            let json = #"{"left":"\#(a.uuidString)","right":"\#(b.uuidString)","more":["\#(c.uuidString)"],\#(bad)}"#
            #expect(try JSONDecoder().decode(Pair.self, from: Data(json.utf8)).ids == [a, b])
        }
        let twice = #"{"left":"\#(a.uuidString)","right":"\#(b.uuidString)","more":["\#(a.uuidString)"],"regions":["left","topRight","bottomRight"]}"#
        #expect(try JSONDecoder().decode(Pair.self, from: Data(twice.utf8)).ids == [a, b])
    }

    @Test func twoAreKeptLeftOrTopFirst() throws {
        let a = UUID(), b = UUID()
        let pair = try #require(Pair(ids: [a, b], shape: TileShape(regions: [.right, .left], column: 0.3)))
        #expect(pair.left == b && pair.right == a && !pair.vertical && pair.regions == nil)
        let stacked = try #require(Pair(ids: [a, b], shape: TileShape(regions: [.bottom, .top], row: 0.7)))
        #expect(stacked.left == b && stacked.vertical && stacked.ratio == 0.7)
        #expect(Pair(ids: [a], shape: TileShape(regions: [.left])) == nil)
        #expect(Pair(ids: [a, a], shape: TileShape(regions: [.left, .right])) == nil)
    }

    @Test func aSplitGrowsIntoAGroupAndBack() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var pair = Pair(left: a, right: b)
        pair.ratio = 0.6
        // A third in the top right: the right page keeps the bottom right; the line stays where it was. The pages
        // are kept in reading order, as the row shows them.
        let three = try #require(pair.adding(c, .place(region: .topRight, regions: [.left, .bottomRight])))
        #expect(three.ids == [a, c, b] && three.isGroup && three.regions == [.left, .topRight, .bottomRight] && three.ratio == 0.6)
        // A fourth makes the grid, and leads it from the top left.
        let four = try #require(three.adding(d, .place(region: .topLeft, regions: [.bottomLeft, .topRight, .bottomRight])))
        #expect(four.count == 4 && four.shape.isValid && four.ids == [d, c, a, b])
        #expect(four.regions == [.topLeft, .topRight, .bottomLeft, .bottomRight])
        // Already in it, or a place that doesn't fit: no change.
        #expect(three.adding(a, .place(region: .topLeft, regions: [.bottomLeft, .topRight, .bottomRight])) == nil)
        #expect(three.adding(d, .place(region: .topLeft, regions: [.bottomLeft])) == nil)
        // Back down: one goes, the rest close up; down to two it's a plain split again, in its usual order.
        let back = try #require(four.removing(d))
        #expect(back.count == 3 && back.shape.isValid)
        let two = try #require(three.removing(c))
        #expect(two == pair)
        #expect(two.removing(a) == nil)
        // Stacked, in its usual order.
        let stacked = try #require(Pair(ids: [a, b, c], shape: TileShape(regions: [.top, .bottomLeft, .bottomRight])))
        let pairAgain = try #require(stacked.removing(b))
        #expect(pairAgain.vertical && pairAgain.ids == [a, c])
    }

    @Test func aPageCanTakeAnothersPlace() throws {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let group = try #require(Pair(ids: ids, shape: TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])))
        let e = UUID()
        let swapped = try #require(group.adding(e, .replace(2)))
        #expect(swapped.ids == [ids[0], ids[1], e, ids[3]] && swapped.shape == group.shape)
        #expect(group.adding(e, .replace(7)) == nil)
    }

    @Test func movingTheLinesKeepsThePlaces() throws {
        var stacked = Pair(left: UUID(), right: UUID())
        stacked.vertical = true
        stacked.setRatios(column: 0.3, row: 0.7)
        #expect(stacked.vertical && stacked.ratio == 0.7 && stacked.otherRatio == 0.3)
        var group = try #require(Pair(ids: [UUID(), UUID(), UUID()], shape: TileShape(regions: [.left, .topRight, .bottomRight])))
        group.setRatios(column: 0.4, row: 0.25)
        #expect(group.shape == TileShape(regions: [.left, .topRight, .bottomRight], column: 0.4, row: 0.25))
    }

    @Test func aPairOfAPageAloneAndANewOne() throws {
        let a = UUID(), b = UUID()
        let left = try #require(Pair.pair(a, b, .place(region: .left, regions: [.right])))
        #expect(left.left == b && left.right == a && !left.vertical)
        let below = try #require(Pair.pair(a, b, .place(region: .bottom, regions: [.top])))
        #expect(below.left == a && below.right == b && below.vertical)
        #expect(Pair.pair(a, b, .replace(0)) == nil)
    }

    // MARK: Around the window

    @Test func aGroupShowsInOneRow() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        // The group's first page carries the rest.
        #expect(SidebarListView.ridingTabs(tabs: [a, b, c, d, e], groups: [[a, b, c, d]], pinned: []) == [b, c, d])
        #expect(SidebarListView.ridingTabs(tabs: [c, a, b], groups: [[a, b, c]], pinned: []) == [b, c])
        // A split of two, as before.
        #expect(SidebarListView.ridingTabs(tabs: [a, b], groups: [[a, b]], pinned: []) == [b])
        #expect(SidebarListView.ridingTabs(tabs: [b], groups: [[a, b]], pinned: []).isEmpty)
    }

    @Test func clearKeepsEveryPageOnScreen() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let result = TabManager.clearing([a, b, c, d], current: a, partners: [b, c], busy: [], ages: [a: 0, b: 500, c: 500, d: 2])
        #expect(result.ids == [d] && result.kind == .others)
        #expect(TabManager.clearing([a, b, c], current: a, partners: [b, c], busy: [], ages: [:]).kind == .last)
    }

    @MainActor @Test func theRowSplitsIntoAPartForEachPage() {
        // Equal parts, contiguous, from row start to end.
        for count in 2...4 {
            let parts = TabRowView.splitParts(count: count, end: 220)
            #expect(parts.count == count && parts[0].start == 0 && parts[count - 1].end == 220)
            for i in 1..<count { #expect(parts[i].start == parts[i - 1].end) }
            let widths = parts.map { $0.end - $0.start }
            #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1)
        }
        #expect(TabRowView.splitParts(count: 1, end: 220).count == 1)
        // Titles show while a part fits a few letters: thirds and quarters of a usual sidebar.
        #expect(TabRowView.segmentShowsTitle(width: 228 / 3, size: .medium))
        #expect(TabRowView.segmentShowsTitle(width: 228 / 4, size: .medium))
        #expect(!TabRowView.segmentShowsTitle(width: 200 / 4, size: .medium))
    }

    @MainActor @Test func theHintSaysWhereThePageGoes() {
        let titles = TileRegion.allCases.map { SplitDropHint.title(for: .place(region: $0, regions: [])) }
        #expect(Set(titles).count == TileRegion.allCases.count && titles.allSatisfy { !$0.isEmpty })
        #expect(SplitDropHint.title(for: .replace(0)) != titles[0])
    }

    @MainActor @Test func aGroupsStripHasNoSwapOrLayout() {
        // Two buttons fewer (Zoom Pane stays), so the address fits whole sooner than beside them.
        #expect(PaneHeaderView.fit(width: 335, edge: 2, address: 180, splitButtons: false) == .all)
        #expect(PaneHeaderView.fit(width: 335, edge: 2, address: 180) != .all)
        // Narrower, Zoom Pane goes into ⋯ first, as swap and the layout do.
        #expect(PaneHeaderView.fit(width: 300, edge: 2, address: 180, splitButtons: false) == .splitInMore)
    }
}
