import CoreGraphics
import Foundation

/// Where a page sits in a tile group (#160): a half of the page area or a quarter of it. The area is a grid of two
/// columns and two rows; a half takes two of its cells, a quarter one.
nonisolated enum TileRegion: String, Codable, CaseIterable, Sendable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

    /// The grid's cells it covers, one bit each: top left, top right, bottom left, bottom right.
    var cells: UInt8 {
        switch self {
        case .left: 0b0101
        case .right: 0b1010
        case .top: 0b0011
        case .bottom: 0b1100
        case .topLeft: 0b0001
        case .topRight: 0b0010
        case .bottomLeft: 0b0100
        case .bottomRight: 0b1000
        }
    }

    init?(cells: UInt8) {
        guard let region = Self.allCases.first(where: { $0.cells == cells }) else { return nil }
        self = region
    }

    var isQuarter: Bool { cells.nonzeroBitCount == 1 }
    var isHalf: Bool { cells.nonzeroBitCount == 2 }
    /// A half that runs top to bottom: the left or right one.
    var isColumn: Bool { self == .left || self == .right }
    /// A half that runs left to right: the top or bottom one.
    var isRowHalf: Bool { self == .top || self == .bottom }

    /// The half across from this one.
    var opposite: TileRegion? {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        default: nil
        }
    }

    /// The columns (0, 1) and rows (0, 1) it spans.
    var columns: ClosedRange<Int> { cells & 0b0101 != 0 ? (cells & 0b1010 != 0 ? 0...1 : 0...0) : 1...1 }
    var rows: ClosedRange<Int> { cells & 0b0011 != 0 ? (cells & 0b1100 != 0 ? 0...1 : 0...0) : 1...1 }
}

/// How a tile group's pages share the page area: where each one sits (in the group's order) and where the lines
/// between them are. Two pages are halves, side by side or stacked, as a split always was; three are a half and two
/// quarters; four a grid of quarters. Worked out top-down, as the window lays its panes out.
///
/// A grid of four quarters can part its line between the columns, a segment per row (#316), so the top left can be
/// wider than the bottom left. Every other line is one line: a half spans the rows or columns beside it, and four
/// rectangles covering the area cannot hold both pairs of lines apart without leaving a hole between them.
nonisolated struct TileShape: Equatable, Sendable {
    var regions: [TileRegion]
    /// The share of the width left of the line between the columns, in each row (top, bottom).
    var columnShares: [CGFloat] = [0.5, 0.5]
    /// The share of the height above the line between the rows, in each column (left, right). Where the rows share one
    /// line, both hold it.
    var rowShares: [CGFloat] = [0.5, 0.5]

    static let maxPanes = 4

    /// Pages that sit as `regions`, their lines where `column` and `row` put them: one line each, as a split always
    /// had. A grid of four starts from them too, and the segments move apart from there.
    init(regions: [TileRegion], column: CGFloat = 0.5, row: CGFloat = 0.5) {
        self.regions = regions
        self.columnShares = [column, column]
        self.rowShares = [row, row]
        normalize()
    }

    /// A split of two: side by side, the first `ratio` of the width, or stacked, of the height.
    static func pair(ratio: CGFloat, vertical: Bool) -> TileShape {
        vertical ? TileShape(regions: [.top, .bottom], row: ratio) : TileShape(regions: [.left, .right], column: ratio)
    }

    /// The share of the width left of the line between the columns: the one line where a page spans both rows, else the
    /// top row's.
    var column: CGFloat {
        get { columnShares[0] }
        set { columnShares = [newValue, newValue] }
    }

    /// The share of the height above the line between the rows: the one line where a page spans both columns, else the
    /// line in the column that has one.
    var row: CGFloat {
        get { rowShares[rowLineColumn] }
        set { rowShares = [newValue, newValue] }
    }

    /// The column whose line between the rows divides pages: the one across from a half page, else the left.
    private var rowLineColumn: Int {
        if regions.contains(.left) { return 1 }
        if regions.contains(.right) { return 0 }
        return 0
    }

    /// A page runs down both rows, so the columns share one line between them; and one runs across both columns, so
    /// the rows share one.
    private var spansRows: Bool { regions.contains(where: \.isColumn) }
    private var spansColumns: Bool { regions.contains(where: \.isRowHalf) }

    /// One line where the pages need one: a page spanning both rows makes the column line one, a page spanning both
    /// columns makes the row line one. A grid of four can part either pair of lines, never both: four rectangles
    /// covering the area leave no room for two broken pairs, so parting one pair joins the other.
    mutating func normalize() {
        if spansRows { columnShares[1] = columnShares[0] }
        if spansColumns { rowShares[1] = rowShares[0] }
        guard isGrid else { return }
        if columnsApart { rowShares[1] = rowShares[0] }
        else if rowsApart { columnShares[1] = columnShares[0] }
    }

    /// Pages that cover the area once each: two to four of them, none overlapping, nothing left over.
    static func isValid(_ regions: [TileRegion]) -> Bool {
        guard (2...maxPanes).contains(regions.count) else { return false }
        var covered: UInt8 = 0
        for region in regions {
            guard covered & region.cells == 0 else { return false }
            covered |= region.cells
        }
        return covered == 0b1111
    }

    var isValid: Bool { Self.isValid(regions) }

    /// Two pages, one above the other.
    var isStacked: Bool { regions.count == 2 && !regions[0].isColumn }

    /// Each page's frame in `area`, in the group's order, `gap` apart.
    func frames(in area: CGRect, gap: CGFloat) -> [CGRect] {
        let width = max(0, area.width - gap), height = max(0, area.height - gap)
        let xs: [CGFloat]
        let ys: [CGFloat]
        if spansRows || rowsApart {
            // A page runs down both rows, or a grid's rows are parted: one line between the columns, and a line in
            // each column between the rows.
            let x = area.minX + floor(width * columnShares[0])
            xs = [x, x]
            ys = rowShares.map { area.minY + floor(height * $0) }
        } else {
            // A line in each row between the columns; the line between the rows is one.
            xs = columnShares.map { area.minX + floor(width * $0) }
            let y = area.minY + floor(height * rowShares[0])
            ys = [y, y]
        }
        func span(_ range: ClosedRange<Int>, from start: CGFloat, to end: CGFloat, split: CGFloat) -> (CGFloat, CGFloat) {
            switch (range.lowerBound, range.upperBound) {
            case (0, 0): (start, split)
            case (1, 1): (split + gap, end)
            default: (start, end)
            }
        }
        return regions.map { region in
            let (minX, maxX) = span(region.columns, from: area.minX, to: area.maxX, split: xs[region.rows.lowerBound])
            let (minY, maxY) = span(region.rows, from: area.minY, to: area.maxY, split: ys[region.columns.lowerBound])
            return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        }
    }

    /// A stretch of the line between two pages, which you drag to resize them (#316): the two either side trade width
    /// or height, and the rest stay put.
    nonisolated struct Segment: Equatable, Sendable {
        nonisolated enum Axis: Hashable, Sendable { case column, row }
        var axis: Axis
        /// The row whose line between the columns this is, for a column segment.
        var row: Int
        /// The column whose line between the rows this is, for a row segment.
        var column: Int
        /// The pages either side, in the group's order: left and right, or top and bottom.
        var first: Int
        var second: Int
        /// The strip you drag, `slop` wider on each side.
        var frame: CGRect
    }

    /// Where a line between the columns and one between the rows meet. Dragging here moves both, so the page at the
    /// corner grows or shrinks both ways and the other pages give way (#309).
    nonisolated struct Corner: Equatable, Sendable {
        /// The rows whose line between the columns ends here, and the columns whose line between the rows does.
        var rows: [Int]
        var columns: [Int]
        /// The square you drag.
        var frame: CGRect
    }

    /// The strips between pages you drag to resize them: one between each pair beside each other, as tall or as wide as
    /// the two pages, `slop` wider on both sides so it's easy to catch; the column line `leading` (when given) on its
    /// left instead, so a page's scroll bar side keeps more of its edge (#362).
    func segments(in area: CGRect, gap: CGFloat, slop: CGFloat, leading: CGFloat? = nil) -> [Segment] {
        let leftReach = leading ?? slop
        let frames = frames(in: area, gap: gap)
        var segments: [Segment] = []
        for a in frames.indices {
            for b in frames.indices where b != a {
                let first = frames[a], second = frames[b]
                if first.minX < second.minX, abs(first.maxX + gap - second.minX) <= 0.5 {
                    let top = max(first.minY, second.minY), bottom = min(first.maxY, second.maxY)
                    guard bottom - top > 0.5 else { continue }
                    // The page that keeps to one row names it; a half names the row of the page across from it.
                    let row = regions[a].rows.count == 1 ? regions[a].rows.lowerBound : regions[b].rows.lowerBound
                    segments.append(Segment(axis: .column, row: row, column: 0, first: a, second: b,
                                            frame: CGRect(x: first.maxX - leftReach, y: top,
                                                          width: gap + leftReach + slop, height: bottom - top)))
                }
                if first.minY < second.minY, abs(first.maxY + gap - second.minY) <= 0.5 {
                    let left = max(first.minX, second.minX), right = min(first.maxX, second.maxX)
                    guard right - left > 0.5 else { continue }
                    let column = regions[a].columns.count == 1 ? regions[a].columns.lowerBound : regions[b].columns.lowerBound
                    segments.append(Segment(axis: .row, row: 0, column: column, first: a, second: b,
                                            frame: CGRect(x: left, y: first.maxY - slop, width: right - left,
                                                          height: gap + slop * 2)))
                }
            }
        }
        return segments
    }

    /// Where the segments meet, the square you drag to move both at once (#309).
    func corners(in area: CGRect, gap: CGFloat, slop: CGFloat, leading: CGFloat? = nil) -> [Corner] {
        let strips = segments(in: area, gap: gap, slop: slop, leading: leading)
        let vertical = strips.filter { $0.axis == .column }, horizontal = strips.filter { $0.axis == .row }
        // Larger than where the two strips cross, so the corner is easy to catch.
        let side = gap + slop * 4, reach = gap + slop + 0.5
        var corners: [Corner] = []
        for line in vertical {
            for across in horizontal {
                let x = line.frame.midX, y = across.frame.midY
                guard y >= line.frame.minY - reach, y <= line.frame.maxY + reach,
                      x >= across.frame.minX - reach, x <= across.frame.maxX + reach else { continue }
                if let i = corners.firstIndex(where: { abs($0.frame.midX - x) <= 0.5 && abs($0.frame.midY - y) <= 0.5 }) {
                    if !corners[i].rows.contains(line.row) { corners[i].rows.append(line.row) }
                    if !corners[i].columns.contains(across.column) { corners[i].columns.append(across.column) }
                } else {
                    corners.append(Corner(rows: [line.row], columns: [across.column],
                                          frame: CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)))
                }
            }
        }
        return corners
    }

    /// The strips between pages, one per line where it divides them, as the whole line each way: what a thumbnail
    /// draws, and what a split of two always had.
    func dividers(in area: CGRect, gap: CGFloat, slop: CGFloat, leading: CGFloat? = nil) -> (column: CGRect?, row: CGRect?) {
        let strips = segments(in: area, gap: gap, slop: slop, leading: leading)
        func union(_ axis: Segment.Axis) -> CGRect? {
            let frames = strips.filter { $0.axis == axis }.map(\.frame)
            guard let first = frames.first else { return nil }
            return frames.dropFirst().reduce(first) { $0.union($1) }
        }
        return (union(.column), union(.row))
    }

    /// A grid of four, the one layout whose line between the columns has a segment in each row.
    var isGrid: Bool { regions.count == 4 }

    /// A grid whose rows have moved their lines between the columns apart (#316).
    var isParted: Bool { columnsApart || rowsApart }

    /// A grid of four with its line between the columns parted, a segment per row.
    var columnsApart: Bool { isGrid && abs(columnShares[0] - columnShares[1]) > 0.0001 }

    /// A grid of four with its line between the rows parted, a segment per column (#316).
    var rowsApart: Bool { isGrid && abs(rowShares[0] - rowShares[1]) > 0.0001 }

    /// Moves the line between the columns in `row` to `share` of the width, kept so no page gets smaller than `minimum`
    /// points. `whole`, or any layout but a grid: every row's line moves together, the old full-height split;
    /// otherwise only the segment in `row` moves (#316).
    mutating func moveColumnLine(in row: Int, to share: CGFloat, length: CGFloat, minimum: CGFloat, whole: Bool = false) {
        let value = Self.clamped(share, length: length, minimum: minimum)
        guard !whole, isGrid, columnShares.indices.contains(row) else {
            columnShares = [value, value]
            return
        }
        columnShares[row] = value
        // Parting one pair of lines joins the other: the rows are one line while the columns are apart.
        if columnsApart { joinRows() }
    }

    /// Moves the line between the rows in `column` to `share` of the height. `whole`, or any layout but a grid: one
    /// line, both columns' shares moving together; otherwise only this column's segment moves (#316), and the columns
    /// join into one line, since a grid parts one pair of lines at a time.
    mutating func moveRowLine(in column: Int, to share: CGFloat, length: CGFloat, minimum: CGFloat, whole: Bool = false) {
        let value = Self.clamped(share, length: length, minimum: minimum)
        guard !whole, isGrid, rowShares.indices.contains(column) else {
            rowShares = [value, value]
            return
        }
        rowShares[column] = value
        if rowsApart { joinColumns() }
    }

    /// Moves a corner to `point` (in the area's top-down coordinates): the line between the columns there and the line
    /// between the rows, each kept so no page gets smaller than `minimumWidth` by `minimumHeight`. `whole`: both
    /// full lines move, as the old corner did; otherwise only the segments that meet there (#309).
    mutating func moveCorner(_ corner: Corner, to point: CGPoint, in area: CGRect, minimumWidth: CGFloat, minimumHeight: CGFloat, whole: Bool = false) {
        let x = Self.clamped((point.x - area.minX) / max(area.width, 1), length: area.width, minimum: minimumWidth)
        let y = Self.clamped((point.y - area.minY) / max(area.height, 1), length: area.height, minimum: minimumHeight)
        if whole || !isGrid {
            columnShares = [x, x]
            rowShares = [y, y]
        } else if rowsApart {
            // The rows are parted: the column line is one, and only the row segments that meet here move.
            columnShares = [x, x]
            for column in corner.columns where rowShares.indices.contains(column) { rowShares[column] = y }
        } else {
            rowShares = [y, y]
            for row in corner.rows where columnShares.indices.contains(row) { columnShares[row] = x }
        }
    }

    /// Whether every line sits in the middle: the standard even grid.
    var isEven: Bool {
        columnShares.allSatisfy { abs($0 - 0.5) < 0.001 } && rowShares.allSatisfy { abs($0 - 0.5) < 0.001 }
    }

    /// Whether `share` is within `points` of the middle of a line `length` long. On a parted grid of four, the drag
    /// then shows the even guide and snaps on release unless Shift holds it away; other drags never snap.
    static func nearEven(_ share: CGFloat, length: CGFloat, points: CGFloat = 8) -> Bool {
        abs(share - 0.5) * max(length, 1) <= points
    }

    /// Where the line between the columns in `row` would snap to, if it is close enough: the middle, or the other
    /// row's line, so two segments come together into one line (#316). `whole`, or any layout but a grid, has only
    /// the middle.
    func columnSnapShare(in row: Int, whole: Bool, length: CGFloat, points: CGFloat = 8) -> CGFloat? {
        guard !whole, isGrid, columnShares.indices.contains(row) else {
            return columnShares.allSatisfy { Self.nearEven($0, length: length, points: points) } ? 0.5 : nil
        }
        return Self.snapShare(columnShares[row], also: columnShares[1 - row], length: length, points: points)
    }

    /// Where the line between the rows in `column` would snap to, if it is close enough: the middle, or the other
    /// column's line (#316).
    func rowSnapShare(in column: Int, whole: Bool, length: CGFloat, points: CGFloat = 8) -> CGFloat? {
        guard !whole, isGrid, rowShares.indices.contains(column) else {
            return rowShares.allSatisfy { Self.nearEven($0, length: length, points: points) } ? 0.5 : nil
        }
        return Self.snapShare(rowShares[column], also: rowShares[1 - column], length: length, points: points)
    }

    /// The share a dragged line snaps to: the middle or `also`, whichever it is closer to within `points`. `also`
    /// matters only after a grid is parted, when two segments can meet and become one line again.
    private static func snapShare(_ share: CGFloat, also other: CGFloat, length: CGFloat, points: CGFloat) -> CGFloat? {
        var best: (distance: CGFloat, share: CGFloat)?
        for candidate in [0.5, other] {
            let distance = abs(share - candidate) * max(length, 1)
            if distance <= points, best == nil || distance < best!.distance { best = (distance, candidate) }
        }
        return best?.share
    }

    /// Whether the line between the columns in `row` is near a snap: the middle, or the other row's line.
    func columnLineIsNearEven(in row: Int, whole: Bool, length: CGFloat, points: CGFloat = 8) -> Bool {
        columnSnapShare(in: row, whole: whole, length: length, points: points) != nil
    }

    /// Whether the line between the rows in `column` is near a snap: the middle, or the other column's line.
    func rowLineIsNearEven(in column: Int, whole: Bool, length: CGFloat, points: CGFloat = 8) -> Bool {
        rowSnapShare(in: column, whole: whole, length: length, points: points) != nil
    }

    /// Puts the line between the columns in `row` at `share` exactly: the snap when a drag lets go near one. Landing
    /// on the other row's line makes the two one line again. `whole`, or any layout but a grid, moves every line.
    mutating func snapColumnLine(in row: Int, to share: CGFloat, whole: Bool = false) {
        guard !whole, isGrid, columnShares.indices.contains(row) else {
            columnShares = [share, share]
            return
        }
        columnShares[row] = share
        if abs(share - columnShares[1 - row]) < 0.0001 { columnShares = [share, share] }
        if columnsApart { joinRows() }
    }

    /// Puts the line between the rows in `column` at `share` exactly: the snap when a drag lets go near one.
    mutating func snapRowLine(in column: Int, to share: CGFloat, whole: Bool = false) {
        guard !whole, isGrid, rowShares.indices.contains(column) else {
            rowShares = [share, share]
            return
        }
        rowShares[column] = share
        if abs(share - rowShares[1 - column]) < 0.0001 { rowShares = [share, share] }
        if rowsApart { joinColumns() }
    }

    /// One line between the rows, where the two segments were.
    private mutating func joinRows() {
        let one = (rowShares[0] + rowShares[1]) / 2
        rowShares = [one, one]
    }

    /// One line between the columns, where the two segments were.
    private mutating func joinColumns() {
        let one = (columnShares[0] + columnShares[1]) / 2
        columnShares = [one, one]
    }

    /// Whether a drag on `axis` moves one segment alone: that line is parted already, or Shift parts it while the
    /// other line is one (#316). Anything else moves the whole line, as a split always did.
    func movesAlone(_ axis: Segment.Axis, shift: Bool) -> Bool {
        guard isGrid else { return false }
        let own = axis == .column ? columnsApart : rowsApart
        let other = axis == .column ? rowsApart : columnsApart
        return own || (shift && !other)
    }

    /// The even grid again: every line at the middle.
    mutating func evenOut() {
        columnShares = [0.5, 0.5]
        rowShares = [0.5, 0.5]
    }

    /// A divider's share, from where it was dragged to, kept so no page gets smaller than `minimum` points (or a
    /// fifth of the area): the middle when the area is too small for both sides.
    static func clamped(_ share: CGFloat, length: CGFloat, minimum: CGFloat) -> CGFloat {
        let floor = max(0.2, minimum / max(length, 1)), ceiling = min(0.8, 1 - floor)
        return floor < ceiling ? min(max(share, floor), ceiling) : 0.5
    }

    // MARK: Changing the group

    /// Where existing pages go when a new one takes `target`, in order; nil if impossible. A half beside one page moves
    /// that page to the other half; beside two halves, both become quarters of the other half (first left or top). A
    /// quarter takes that corner of its half. At most four, only halves and quarters.
    /// A page dropped on a split's sidebar row (`onRight`: right half) takes the second quarter of that side's half.
    /// Two become a half and two quarters, three a 2x2 grid. Nil when no half is left.
    static func joining(_ regions: [TileRegion], onRight: Bool) -> TileDrop.Kind? {
        guard regions.count < maxPanes else { return nil }
        let halves = regions.filter(\.isHalf)
        guard let half = halves.first(where: { $0.isColumn && ($0 == .right) == onRight }) ?? halves.last else { return nil }
        let target: TileRegion = switch half {
        case .left: .bottomLeft
        case .right: .bottomRight
        case .top: .topRight
        default: .bottomRight
        }
        guard let placed = placing(target, beside: regions) else { return nil }
        return .place(region: target, regions: placed)
    }

    static func placing(_ target: TileRegion, beside regions: [TileRegion]) -> [TileRegion]? {
        if regions.isEmpty {
            guard let other = target.opposite else { return nil }
            return [other]
        }
        guard isValid(regions), regions.count < maxPanes else { return nil }
        if target.isHalf {
            guard regions.count == 2, let other = target.opposite else { return nil }
            // The other half's two quarters, first (left or top) to first.
            let quarters: [TileRegion] = switch other {
            case .left: [.topLeft, .bottomLeft]
            case .right: [.topRight, .bottomRight]
            case .top: [.topLeft, .topRight]
            default: [.bottomLeft, .bottomRight]
            }
            let firstLeads = regions[0] == .left || regions[0] == .top
            return firstLeads ? quarters : quarters.reversed()
        }
        guard let index = regions.firstIndex(where: { $0.cells & target.cells != 0 }), regions[index].isHalf,
              let rest = TileRegion(cells: regions[index].cells & ~target.cells) else { return nil }
        var placed = regions
        placed[index] = rest
        return placed
    }

    /// The group without its page at `index`: what's left takes its room. Nil when one page would be left, which is
    /// no group. A quarter's room goes to the page beside it in the same column, else in the same row, that makes a
    /// half with it; a half's to the two quarters across from it, which become halves.
    static func removing(_ index: Int, from regions: [TileRegion]) -> [TileRegion]? {
        guard regions.indices.contains(index), regions.count > 2 else { return nil }
        let gone = regions[index]
        var rest = regions
        rest.remove(at: index)
        // A page that makes a half with the one that went takes its place: in the same column first.
        let partners = rest.indices.filter { TileRegion(cells: rest[$0].cells | gone.cells)?.isHalf == true }
        if let taker = partners.first(where: { TileRegion(cells: rest[$0].cells | gone.cells)?.isColumn == true }) ?? partners.first {
            rest[taker] = TileRegion(cells: rest[taker].cells | gone.cells)!
            return isValid(rest) ? rest : nil
        }
        // A half went: each quarter across from it grows across its room.
        rest = rest.map { region in
            let mirror: UInt8 = gone.isColumn
                ? ((region.cells & 0b0101) << 1 | (region.cells & 0b1010) >> 1)
                : ((region.cells & 0b0011) << 2 | (region.cells & 0b1100) >> 2)
            return TileRegion(cells: region.cells | mirror) ?? region
        }
        return isValid(rest) ? rest : nil
    }

    /// A group's pages in reading order, as the sidebar's row shows them: the top left first, then across and down.
    /// Two are left (or top) first, as a split always was.
    static func ordered(_ regions: [TileRegion]) -> [Int] {
        regions.indices.sorted { regions[$0].cells.trailingZeroBitCount < regions[$1].cells.trailingZeroBitCount }
    }
}

/// Where a page dragged over the page area would go, and how the hint shows it (#160). Pop!_OS-like: the area's
/// edges are its halves, its corners its quarters; anywhere else, the half of the page under the pointer (beside a
/// page alone, as the split always did) or that page's own place when it can't split again.
nonisolated struct TileDrop: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The new page takes `region`; the ones there move to `regions` (in the group's order).
        case place(region: TileRegion, regions: [TileRegion])
        /// The new page takes the place of the group's page at this index, which goes back to being a tab of its own.
        case replace(Int)
    }
    var kind: Kind
    /// Where the hint shows: the new page's frame once it's in.
    var frame: CGRect

    /// How far in from the area's edges a drop means a half or a quarter of the whole area.
    static func edge(for area: CGRect) -> CGFloat {
        min(max(min(area.width, area.height) * 0.16, 40), 120)
    }

    /// The drop at `point` (in the area's top-down coordinates). `shape` is the group on screen, nil for a page alone.
    static func target(at point: CGPoint, in area: CGRect, shape: TileShape?, gap: CGFloat) -> TileDrop? {
        guard area.contains(point) else { return nil }
        let edge = edge(for: area)
        let nearLeft = point.x < area.minX + edge, nearRight = point.x > area.maxX - edge
        let nearTop = point.y < area.minY + edge, nearBottom = point.y > area.maxY - edge
        let ratio = shape ?? TileShape(regions: [])
        func place(_ target: TileRegion) -> TileDrop? {
            guard let placed = TileShape.placing(target, beside: shape?.regions ?? []) else { return nil }
            var after = TileShape(regions: placed + [target], column: ratio.column, row: ratio.row)
            // Beside a page alone the two get even halves, as a split always opened; in a group, the lines it has.
            if shape == nil {
                after.column = 0.5
                after.row = 0.5
            } else {
                after.columnShares = ratio.columnShares
                after.rowShares = ratio.rowShares
                after.normalize()
            }
            guard let frame = after.frames(in: area, gap: gap).last else { return nil }
            return TileDrop(kind: .place(region: target, regions: placed), frame: frame)
        }
        guard let shape else {
            // A page alone: the top and bottom edges stack; anywhere else, the left or right half, as before.
            if nearTop && !nearLeft && !nearRight { return place(.top) }
            if nearBottom && !nearLeft && !nearRight { return place(.bottom) }
            return place(point.x < area.midX ? .left : .right)
        }
        let corner: TileRegion? = switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): .topLeft
        case (_, true, true, _): .topRight
        case (true, _, _, true): .bottomLeft
        case (_, true, _, true): .bottomRight
        default: nil
        }
        if let corner, let drop = place(corner) { return drop }
        let half: TileRegion? = nearLeft ? .left : nearRight ? .right : nearTop ? .top : nearBottom ? .bottom : nil
        if corner == nil, let half, let drop = place(half) { return drop }
        // Over a page: it splits, and the new one takes the half of it under the pointer; a quarter can't split, so
        // the new page takes its place.
        let frames = shape.frames(in: area, gap: gap)
        guard let index = frames.firstIndex(where: { $0.insetBy(dx: -gap, dy: -gap).contains(point) }) else { return nil }
        let pane = shape.regions[index], frame = frames[index]
        if pane.isHalf {
            let quarter: UInt8 = pane.isColumn
                ? pane.cells & (point.y < frame.midY ? 0b0011 : 0b1100)
                : pane.cells & (point.x < frame.midX ? 0b0101 : 0b1010)
            if let target = TileRegion(cells: quarter), let drop = place(target) { return drop }
        }
        return TileDrop(kind: .replace(index), frame: frame)
    }
}

/// Where a pane picked up by its strip would go, and how the hint shows it (#160). The places a dropped tab takes:
/// the area's edges are its halves, its corners its quarters, the rest of the group closing up and making room as when
/// a tab comes in. Over another pane the two trade places; over its own, or anywhere that leaves the group as it is,
/// nothing changes (nil).
nonisolated struct PaneMove: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The pane trades places with the group's pane at this index.
        case swap(Int)
        /// The pane takes `region`; the group's places become `regions`, in its order (the pane's own among them).
        case place(region: TileRegion, regions: [TileRegion])
    }
    var kind: Kind
    /// Where the hint shows: where the pane lands.
    var frame: CGRect

    /// The move for the pane at `index` of `shape` let go at `point` (in the area's top-down coordinates).
    static func target(moving index: Int, at point: CGPoint, in area: CGRect, shape: TileShape, gap: CGFloat) -> PaneMove? {
        guard area.contains(point), shape.isValid, shape.regions.indices.contains(index) else { return nil }
        let edge = TileDrop.edge(for: area)
        let nearLeft = point.x < area.minX + edge, nearRight = point.x > area.maxX - edge
        let nearTop = point.y < area.minY + edge, nearBottom = point.y > area.maxY - edge
        // The others' places with the pane gone: beside one page, there's nothing to close up.
        let rest = shape.regions.count == 2 ? [] : TileShape.removing(index, from: shape.regions)
        // The pane into `target`, the rest making room as for a tab: nil if it can't go there; `.some(nil)` if every
        // pane would stay where it is, which is the answer all the same.
        func place(_ target: TileRegion) -> PaneMove?? {
            guard let rest, let placed = TileShape.placing(target, beside: rest) else { return nil }
            var regions = placed
            regions.insert(target, at: index)
            guard regions != shape.regions else { return .some(nil) }
            var after = shape
            after.regions = regions
            guard after.isValid else { return nil }
            return PaneMove(kind: .place(region: target, regions: regions), frame: after.frames(in: area, gap: gap)[index])
        }
        let corner: TileRegion? = switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): .topLeft
        case (_, true, true, _): .topRight
        case (true, _, _, true): .bottomLeft
        case (_, true, _, true): .bottomRight
        default: nil
        }
        if let corner, let move = place(corner) { return move }
        // An edge's half; in a corner that can't take a quarter (beside one page), the nearer edge's half first.
        let dx = min(point.x - area.minX, area.maxX - point.x), dy = min(point.y - area.minY, area.maxY - point.y)
        let side: TileRegion? = nearLeft ? .left : nearRight ? .right : nil
        let end: TileRegion? = nearTop ? .top : nearBottom ? .bottom : nil
        for half in (dx <= dy ? [side, end] : [end, side]).compactMap({ $0 }) {
            if let move = place(half) { return move }
        }
        // Over another pane: the two trade places. Over its own, it stays.
        let frames = shape.frames(in: area, gap: gap)
        guard let other = frames.firstIndex(where: { $0.insetBy(dx: -gap, dy: -gap).contains(point) }), other != index else { return nil }
        return PaneMove(kind: .swap(other), frame: frames[other])
    }
}

nonisolated extension TabManager.SplitPair {
    /// A group of `ids` laid out as `shape`: two in their usual order (left or top first); nil if it isn't a group.
    init?(ids: [UUID], shape: TileShape) {
        guard ids.count == shape.regions.count, shape.isValid, Set(ids).count == ids.count else { return nil }
        let order = TileShape.ordered(shape.regions)
        let ordered = order.map { ids[$0] }
        self.init(left: ordered[0], right: ordered[1])
        more = Array(ordered.dropFirst(2))
        var placed = shape
        placed.regions = order.map { shape.regions[$0] }
        setShape(placed)
    }

    /// Its pages, in order.
    var ids: [UUID] { [left, right] + more }
    var count: Int { 2 + more.count }

    /// The same places and lines with pages `ids` in them, in order (a group's tabs as its pinned pages, and back);
    /// nil unless there's one for each place, all different.
    func withPages(_ ids: [UUID]) -> Self? {
        guard ids.count == count, Set(ids).count == ids.count else { return nil }
        if isGroup { guard let regions, regions.count == count, TileShape.isValid(regions) else { return nil } }
        var after = self
        after.left = ids[0]
        after.right = ids[1]
        after.more = Array(ids.dropFirst(2))
        return after
    }
    func contains(_ id: UUID) -> Bool { left == id || right == id || more.contains(id) }
    /// Three or four pages, not a split of two.
    var isGroup: Bool { !more.isEmpty }

    /// How its pages share the page area.
    var shape: TileShape {
        if let regions, regions.count == count {
            var shape = TileShape(regions: regions, column: CGFloat(ratio), row: CGFloat(otherRatio))
            if let shares, shares.count == 4 {
                shape.columnShares = [CGFloat(shares[0]), CGFloat(shares[1])]
                shape.rowShares = [CGFloat(shares[2]), CGFloat(shares[3])]
                shape.normalize()
            }
            return shape
        }
        return vertical ? TileShape(regions: [.top, .bottom], column: CGFloat(otherRatio), row: CGFloat(ratio))
            : TileShape(regions: [.left, .right], column: CGFloat(ratio), row: CGFloat(otherRatio))
    }

    /// Takes `shape`'s lines, and its places for the pages in order.
    private mutating func setShape(_ shape: TileShape) {
        if shape.regions.count == 2 {
            vertical = shape.isStacked
            ratio = Double(vertical ? shape.row : shape.column)
            otherRatio = Double(vertical ? shape.column : shape.row)
            regions = nil
            shares = nil
        } else {
            regions = shape.regions
            ratio = Double(shape.column)
            otherRatio = Double(shape.row)
            shares = shape.columnShares.map(Double.init) + shape.rowShares.map(Double.init)
        }
    }

    /// Takes `shape`'s lines, the places kept: each row's line between the columns and each column's between the rows.
    mutating func setLines(of shape: TileShape) {
        var after = self.shape
        after.columnShares = shape.columnShares
        after.rowShares = shape.rowShares
        after.normalize()
        setShape(after)
    }

    /// The lines moved, the places kept.
    mutating func setRatios(column: CGFloat, row: CGFloat) {
        var shape = self.shape
        shape.column = column
        shape.row = row
        setShape(shape)
    }

    /// The same places, page `old` swapped for `new`.
    mutating func replace(_ old: UUID, with new: UUID) {
        if left == old { left = new } else if right == old { right = new } else if let i = more.firstIndex(of: old) { more[i] = new }
    }

    /// Without page `id`: the rest of the group, its room taken by the others; nil when one page would be left,
    /// which is no group.
    func removing(_ id: UUID) -> Self? {
        guard let index = ids.firstIndex(of: id), let regions = TileShape.removing(index, from: shape.regions) else { return nil }
        var rest = ids
        rest.remove(at: index)
        var after = shape
        after.regions = regions
        // A parted grid's quarter that grows into a half keeps its row's width.
        if shape.isParted, let half = regions.firstIndex(where: \.isColumn),
           let grown = ids.firstIndex(of: rest[half]) {
            after.column = shape.columnShares[shape.regions[grown].rows.lowerBound]
        }
        // A grid parted between its rows keeps the row line of the column still split in two.
        if shape.rowsApart, let half = regions.first(where: \.isColumn) {
            after.row = shape.rowShares[half == .left ? 1 : 0]
        }
        return Self(ids: rest, shape: after)
    }

    /// With page `new` in, where `drop` puts it; nil if it can't go there.
    func adding(_ new: UUID, _ drop: TileDrop.Kind) -> Self? {
        guard !contains(new) else { return nil }
        switch drop {
        case .place(let region, let regions):
            guard regions.count == count else { return nil }
            var after = shape
            after.regions = regions + [region]
            return Self(ids: ids + [new], shape: after)
        case .replace(let index):
            guard ids.indices.contains(index) else { return nil }
            var after = self
            after.replace(ids[index], with: new)
            return after
        }
    }

    /// With page `id` moved where `move` puts it (`PaneMove`): the same pages and the same lines; nil if it can't.
    func moving(_ id: UUID, _ move: PaneMove.Kind) -> Self? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        var pages = ids, after = shape
        switch move {
        case .swap(let other):
            guard pages.indices.contains(other), other != index else { return nil }
            pages.swapAt(index, other)
        case .place(_, let regions):
            guard regions.count == count else { return nil }
            after.regions = regions
        }
        return Self(ids: pages, shape: after)
    }

    /// A page alone and `new` beside it, where `drop` puts it.
    static func pair(_ page: UUID, _ new: UUID, _ drop: TileDrop.Kind) -> Self? {
        guard case .place(let region, let regions) = drop, regions.count == 1, page != new else { return nil }
        return Self(ids: [page, new], shape: TileShape(regions: regions + [region]))
    }
}

/// One pane of a split or tile group enlarged over the others for a moment (#160), as a terminal or an editor zooms a
/// pane: nothing in the layout changes, and the zoom ends as soon as the group isn't laid out as it was zoomed in.
nonisolated struct PaneZoom: Equatable, Sendable {
    /// The page enlarged; nil while none is.
    private(set) var tabID: UUID?
    /// The pages of the group it was zoomed in, in order.
    private var group: [UUID] = []
    /// Where each of them sat.
    private var places: [TileRegion]?

    var isZoomed: Bool { tabID != nil }

    /// Zooms page `id` of the group `ids` (sitting at `places`); zoomed already, it goes back. Not a page of a group
    /// of two or more: nothing.
    mutating func toggle(_ id: UUID, in ids: [UUID], places: [TileRegion]? = nil) {
        if tabID == id { self = PaneZoom(); return }
        guard ids.count > 1, ids.contains(id) else { return }
        tabID = id
        group = ids
        self.places = places
    }

    mutating func clear() { self = PaneZoom() }

    /// The enlarged page's place in the group now on screen (`ids` at `places`, nil with no split). Any rearrangement
    /// ends the zoom, as DESIGN.md has it: a page that came or went, places swapped, a pane moved or the layout
    /// changed, the group ending or leaving the window. Only the lines between the panes may move.
    mutating func index(in ids: [UUID]?, places: [TileRegion]? = nil) -> Int? {
        guard let tabID else { return nil }
        guard let ids, ids == group, places == self.places,
              let index = ids.firstIndex(of: tabID) else {
            self = PaneZoom()
            return nil
        }
        return index
    }
}
