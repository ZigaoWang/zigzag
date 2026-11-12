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

/// How a tile group's pages share the page area: where each one sits (in the group's order) and where the two
/// dividers are. Two pages are halves, side by side or stacked, as a split always was; three are a half and two
/// quarters; four a grid of quarters. Worked out top-down, as the window lays its panes out.
nonisolated struct TileShape: Equatable, Sendable {
    var regions: [TileRegion]
    /// The share of the width left of the line between the columns.
    var column: CGFloat = 0.5
    /// The share of the height above the line between the rows.
    var row: CGFloat = 0.5

    static let maxPanes = 4

    /// A split of two: side by side, the first `ratio` of the width, or stacked, of the height.
    static func pair(ratio: CGFloat, vertical: Bool) -> TileShape {
        vertical ? TileShape(regions: [.top, .bottom], row: ratio) : TileShape(regions: [.left, .right], column: ratio)
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
        let x = area.minX + floor(max(0, area.width - gap) * column)
        let y = area.minY + floor(max(0, area.height - gap) * row)
        func span(_ range: ClosedRange<Int>, from start: CGFloat, to end: CGFloat, split: CGFloat) -> (CGFloat, CGFloat) {
            switch (range.lowerBound, range.upperBound) {
            case (0, 0): (start, split)
            case (1, 1): (split + gap, end)
            default: (start, end)
            }
        }
        return regions.map { region in
            let (minX, maxX) = span(region.columns, from: area.minX, to: area.maxX, split: x)
            let (minY, maxY) = span(region.rows, from: area.minY, to: area.maxY, split: y)
            return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        }
    }

    /// Which page covers a cell of the grid (0 top left, 1 top right, 2 bottom left, 3 bottom right).
    private func page(atCell cell: Int) -> Int? { regions.firstIndex { $0.cells & (1 << cell) != 0 } }

    /// Where the line between the columns divides two pages: in the top row, the bottom row, or both.
    var columnLineRows: ClosedRange<Int>? {
        let top = page(atCell: 0) != page(atCell: 1), bottom = page(atCell: 2) != page(atCell: 3)
        return top && bottom ? 0...1 : top ? 0...0 : bottom ? 1...1 : nil
    }

    /// Where the line between the rows divides two pages: in the left column, the right one, or both.
    var rowLineColumns: ClosedRange<Int>? {
        let left = page(atCell: 0) != page(atCell: 2), right = page(atCell: 1) != page(atCell: 3)
        return left && right ? 0...1 : left ? 0...0 : right ? 1...1 : nil
    }

    /// The strips between pages you drag to resize them: the gap between the columns where it divides pages, and the
    /// gap between the rows, each `slop` wider on both sides so it's easy to catch.
    func dividers(in area: CGRect, gap: CGFloat, slop: CGFloat) -> (column: CGRect?, row: CGRect?) {
        let x = area.minX + floor(max(0, area.width - gap) * column)
        let y = area.minY + floor(max(0, area.height - gap) * row)
        func extent(_ range: ClosedRange<Int>, start: CGFloat, end: CGFloat, split: CGFloat) -> (CGFloat, CGFloat) {
            switch (range.lowerBound, range.upperBound) {
            case (0, 0): (start, split)
            case (1, 1): (split + gap, end)
            default: (start, end)
            }
        }
        let columnLine = columnLineRows.map { rows -> CGRect in
            let (top, bottom) = extent(rows, start: area.minY, end: area.maxY, split: y)
            return CGRect(x: x - slop, y: top, width: gap + slop * 2, height: max(0, bottom - top))
        }
        let rowLine = rowLineColumns.map { columns -> CGRect in
            let (left, right) = extent(columns, start: area.minX, end: area.maxX, split: x)
            return CGRect(x: left, y: y - slop, width: max(0, right - left), height: gap + slop * 2)
        }
        return (columnLine, rowLine)
    }

    /// A divider's share, from where it was dragged to, kept so no page gets smaller than `minimum` points (or a
    /// fifth of the area): the middle when the area is too small for both sides.
    static func clamped(_ share: CGFloat, length: CGFloat, minimum: CGFloat) -> CGFloat {
        let floor = max(0.2, minimum / max(length, 1)), ceiling = min(0.8, 1 - floor)
        return floor < ceiling ? min(max(share, floor), ceiling) : 0.5
    }

    // MARK: Changing the group

    /// Where the pages already in the group go when a new one takes `target`, in their order; nil if it can't.
    /// A half beside one page puts that page in the other half. A half beside two halves moves both into the other
    /// half, a quarter each, first one first (left or top). A quarter takes that corner of the half it's in, which
    /// keeps the other corner. Never more than four, and never a page left with a shape that isn't a half or a quarter.
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
            // Beside a page alone the two get even halves, as a split always opened.
            if shape == nil { after.column = 0.5; after.row = 0.5 }
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

extension TabManager.SplitPair {
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
    func contains(_ id: UUID) -> Bool { left == id || right == id || more.contains(id) }
    /// Three or four pages, not a split of two.
    var isGroup: Bool { !more.isEmpty }

    /// How its pages share the page area.
    var shape: TileShape {
        if let regions, regions.count == count {
            return TileShape(regions: regions, column: CGFloat(ratio), row: CGFloat(otherRatio))
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
        } else {
            regions = shape.regions
            ratio = Double(shape.column)
            otherRatio = Double(shape.row)
        }
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

    /// A page alone and `new` beside it, where `drop` puts it.
    static func pair(_ page: UUID, _ new: UUID, _ drop: TileDrop.Kind) -> Self? {
        guard case .place(let region, let regions) = drop, regions.count == 1, page != new else { return nil }
        return Self(ids: [page, new], shape: TileShape(regions: regions + [region]))
    }
}
