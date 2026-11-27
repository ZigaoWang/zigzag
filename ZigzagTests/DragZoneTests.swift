import AppKit
import Testing
@testable import Zigzag

/// Draggable edges take the pointer in a band wider than the drawn line, and a drag moves the line from where it is (#362).
@MainActor
struct DragZoneTests {
    let window = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let width: CGFloat = 240

    @Test func theSidebarsEdgeReachesIntoTheSidebarAndLessOverThePagesScrollBar() {
        let reach = Tokens.Metric.dragReach, inside = Tokens.Metric.sidebarDragReach
        let left = BrowserRootView.resizeHandleFrame(in: window, sidebarWidth: width, onRight: false)
        #expect(left.minX == width - inside && left.maxX == width + reach && left.height == window.height)
        #expect(left.minX + BrowserRootView.resizeHandleLine(onRight: false) == width)
        // On the right the page's scroll bar is against the edge: the band keeps mostly to the sidebar.
        let edge = window.maxX - width
        let right = BrowserRootView.resizeHandleFrame(in: window, sidebarWidth: width, onRight: true)
        #expect(right.maxX == edge + inside && right.minX == edge - reach / 2 && right.height == window.height)
        #expect(right.minX + BrowserRootView.resizeHandleLine(onRight: true) == edge)
        // Wider than the drawn edge either way, and nowhere near the window's own edges.
        #expect(left.width > Tokens.Metric.resizeHandleWidth && right.width > Tokens.Metric.resizeHandleWidth)
        #expect(left.minX > window.minX + 100 && right.maxX < window.maxX - 100)
    }

    @Test func aSplitsLineReachesIntoBothPagesLessOnTheLeftPagesScrollBarSide() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let gap: CGFloat = 8
        let x = area.minX + floor((area.width - gap) / 2)
        let pair = TileShape(regions: [.left, .right]).dividers(in: area, gap: gap, slop: 4, leading: 2)
        #expect(pair.column == CGRect(x: x - 2, y: area.minY, width: gap + 6, height: area.height))
        let stacked = TileShape(regions: [.top, .bottom]).dividers(in: area, gap: gap, slop: 4, leading: 2)
        let y = area.minY + floor((area.height - gap) / 2)
        #expect(stacked.row == CGRect(x: area.minX, y: y - 4, width: area.width, height: gap + 8))
        // Without a leading reach, the same on both sides, as before.
        let even = TileShape(regions: [.left, .right]).dividers(in: area, gap: gap, slop: 2)
        #expect(even.column == CGRect(x: x - 2, y: area.minY, width: gap + 4, height: area.height))
    }

    /// Borderless beside the sidebar, the panes sit a tight gutter apart, and the line still takes the pointer across
    /// as wide a band as the frame's inset gave it.
    @Test func aTightGutterKeepsTheLinesDragBand() throws {
        guard BrowserRootView.isBorderless else { return }
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = Tab(url: nil, title: "Page", spaceID: space)
        manager.adopt([tab], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(tab)
        let window = try #require(controller.window)
        let root = controller.root
        guard root.sidebarVisible else { return }
        root.setTiles(TileShape(regions: [.left, .right]), animated: false)
        window.layoutIfNeeded()
        #expect(root.paneGap == Tokens.Metric.paneGutter)
        let frames = root.tileFrames
        #expect(frames[1].minX - frames[0].maxX == Tokens.Metric.paneGutter)
        let frame = try #require(window.contentView?.superview)
        // Both ends of the band, widened by what the gutter saves.
        let widen = (Tokens.Metric.cardInset - Tokens.Metric.paneGutter) / 2
        let reach = Tokens.Metric.dragReach
        for x in [frames[0].maxX - reach / 2 - widen + 0.5, frames[1].minX + reach + widen - 0.5] {
            let point = root.convert(NSPoint(x: x, y: frames[0].midY), to: nil)
            #expect(frame.hitTest(frame.convert(point, from: nil)) is ResizeHandle, "\(x)")
        }
    }

    @Test func aPressAwayFromTheLineMovesItFromWhereItIs() {
        // Pressed 6pt right of the line at 240, then moved 10pt: the line goes to 250, not to the pointer at 256.
        #expect(ResizeHandle.dragged(256, grab: 6) == 250)
        #expect(ResizeHandle.dragged(230, grab: -8) == 238)
    }

    @Test func aVerticalDragMovesTheLineBetweenTheRowsInEveryTileShape() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = Tab(url: nil, title: "Page", spaceID: space)
        manager.adopt([tab], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(tab)
        let window = try #require(controller.window)
        let root = controller.root
        let shapes = [
            TileShape(regions: [.top, .bottom]),
            TileShape(regions: [.left, .topRight, .bottomRight]),
            TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ]
        for shape in shapes {
            root.setTiles(shape, animated: false)
            window.layoutIfNeeded()
            let area = root.cardFrame
            let gap = root.paneGap
            let segment = try #require(root.tiles?.segments(in: area, gap: gap, slop: Tokens.Metric.dragReach).first { $0.axis == .row })
            // On the line between the rows, away from the corner where a square takes the press.
            let point = root.convert(NSPoint(x: segment.frame.midX - segment.frame.width / 4, y: segment.frame.midY), to: nil)
            let frame = try #require(window.contentView?.superview)
            let handle = try #require(frame.hitTest(frame.convert(point, from: nil)) as? ResizeHandle)
            #expect(handle.isVertical, "\(shape.regions)")
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            handle.mouseDown(with: down)
            let moved = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: point.x, y: point.y - 60),
                                                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                        clickCount: 1, pressure: 1))
            handle.mouseDragged(with: moved)
            // Dragged down, the line goes down: the top row gets more of the height.
            let share = try #require(root.tiles?.rowShares[segment.column])
            #expect(share > 0.5, "\(shape.regions)")
        }
    }

    @Test func aPlainDragMovesTheWholeLineAndShiftMovesOneSegment() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = Tab(url: nil, title: "Page", spaceID: space)
        manager.adopt([tab], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(tab)
        let window = try #require(controller.window)
        let root = controller.root
        let shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        root.setTiles(shape, animated: false)
        window.layoutIfNeeded()
        let area = root.cardFrame
        let segment = try #require(root.tiles?.segments(in: area, gap: root.paneGap, slop: Tokens.Metric.dragReach)
            .first { $0.axis == .column && $0.row == 0 })
        let start = root.convert(NSPoint(x: segment.frame.midX, y: segment.frame.midY), to: nil)
        let target = NSPoint(x: start.x + 60, y: start.y)
        let frame = try #require(window.contentView?.superview)
        let handle = try #require(frame.hitTest(frame.convert(start, from: nil)) as? ResizeHandle)
        func drag(_ point: NSPoint, shift: Bool) throws {
            for (type, at) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, point), (.leftMouseUp, point)] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: shift ? [.shift] : [],
                                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: 1, pressure: 1))
                switch type {
                case .leftMouseDown: handle.mouseDown(with: event)
                case .leftMouseDragged: handle.mouseDragged(with: event)
                default: handle.mouseUp(with: event)
                }
            }
        }
        // From the even grid, a plain drag moves both rows' lines together.
        try drag(target, shift: false)
        let whole = try #require(root.tiles)
        #expect(whole.columnShares[0] > 0.5)
        #expect(whole.columnShares[1] == whole.columnShares[0])
        // Again from even, Shift moves only the top row's segment.
        root.setTiles(shape, animated: false)
        window.layoutIfNeeded()
        try drag(target, shift: true)
        let segmentOnly = try #require(root.tiles)
        #expect(segmentOnly.columnShares[0] > 0.5)
        #expect(segmentOnly.columnShares[1] == 0.5)
    }

    @Test func aPlainDragOutsideAPartedGridIsTheDragItAlwaysWas() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = Tab(url: nil, title: "Page", spaceID: space)
        manager.adopt([tab], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(tab)
        let window = try #require(controller.window)
        let root = controller.root
        let frame = try #require(window.contentView?.superview)
        func press(_ shape: TileShape, row: Int, by dx: CGFloat, clicks: Int = 1) throws -> TileShape {
            root.setTiles(shape, animated: false)
            window.layoutIfNeeded()
            let area = root.cardFrame
            let segment = try #require(root.tiles?.segments(in: area, gap: root.paneGap, slop: Tokens.Metric.dragReach)
                .first { $0.axis == .column && $0.row == row })
            let start = root.convert(NSPoint(x: segment.frame.midX, y: segment.frame.midY - segment.frame.height / 4), to: nil)
            let end = NSPoint(x: start.x + dx, y: start.y)
            let handle = try #require(frame.hitTest(frame.convert(start, from: nil)) as? ResizeHandle)
            let steps: [(NSEvent.EventType, NSPoint)] = clicks == 2 ? [(.leftMouseDown, start), (.leftMouseUp, start)]
                : [(.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)]
            for (type, point) in steps {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: clicks, pressure: 1))
                switch type {
                case .leftMouseDown: handle.mouseDown(with: event)
                case .leftMouseDragged: handle.mouseDragged(with: event)
                default: handle.mouseUp(with: event)
                }
            }
            return try #require(root.tiles)
        }
        let grid: [TileRegion] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        // A grid saved off the middle: a plain drag still moves its whole line.
        let moved = try press(TileShape(regions: grid, column: 0.3, row: 0.6), row: 0, by: 60)
        #expect(moved.columnShares[0] > 0.3 && moved.columnShares[1] == moved.columnShares[0] && moved.rowShares == [0.6, 0.6])
        // Let go a few points from the middle, a split stays there.
        let pair = TileShape(regions: [.left, .right], column: 0.45)
        let nearMiddle = (0.5 - 0.45) * root.cardFrame.width - 4
        let kept = try press(pair, row: 0, by: nearMiddle)
        #expect(kept.column != 0.5)
        // Columns parted: a plain drag on the line between the rows still moves that whole line, and the columns stay.
        var parted = TileShape(regions: grid)
        parted.columnShares = [0.3, 0.6]
        root.setTiles(parted, animated: false)
        window.layoutIfNeeded()
        let rowSegment = try #require(root.tiles?.segments(in: root.cardFrame, gap: root.paneGap, slop: Tokens.Metric.dragReach)
            .first { $0.axis == .row && $0.column == 1 })
        let rowStart = root.convert(NSPoint(x: rowSegment.frame.midX, y: rowSegment.frame.midY), to: nil)
        let rowHandle = try #require(frame.hitTest(frame.convert(rowStart, from: nil)) as? ResizeHandle)
        for (type, dy) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseDragged, -50), (.leftMouseUp, -50)] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: rowStart.x, y: rowStart.y + dy), modifierFlags: [.shift],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: rowHandle.mouseDown(with: event)
            case .leftMouseDragged: rowHandle.mouseDragged(with: event)
            default: rowHandle.mouseUp(with: event)
            }
        }
        let afterRows = try #require(root.tiles)
        #expect(afterRows.columnShares == [0.3, 0.6] && afterRows.rowShares[0] == afterRows.rowShares[1] && afterRows.rowShares[0] > 0.5)
        // A double-click on the line between the columns evens that line alone.
        let three = try press(TileShape(regions: [.left, .topRight, .bottomRight], column: 0.3, row: 0.3), row: 0, by: 0, clicks: 2)
        #expect(three.columnShares == [0.5, 0.5] && three.rowShares == [0.3, 0.3])
    }

    @Test func aCornerIsEasyToCatchAndNeverJumps() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = Tab(url: nil, title: "Page", spaceID: space)
        manager.adopt([tab], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(tab)
        let window = try #require(controller.window)
        let root = controller.root
        let shape = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight], column: 0.4, row: 0.6)
        root.setTiles(shape, animated: false)
        window.layoutIfNeeded()
        let area = root.cardFrame, gap = root.paneGap, reach = Tokens.Metric.dragReach
        let corner = try #require(shape.corners(in: area, gap: gap, slop: reach, leading: reach / 2).first)
        // Larger than where the two strips cross.
        let strips = shape.segments(in: area, gap: gap, slop: reach, leading: reach / 2)
        let crossing = try #require(strips.first { $0.axis == .column }?.frame.width)
        #expect(corner.frame.width > crossing && corner.frame.height > crossing)
        // Pressed off its middle and moved nowhere, nothing moves; moved 50 points, the lines move 50 points.
        let start = root.convert(NSPoint(x: corner.frame.midX + 5, y: corner.frame.midY - 5), to: nil)
        let frame = try #require(window.contentView?.superview)
        let handle = try #require(frame.hitTest(frame.convert(start, from: nil)) as? ResizeHandle)
        for (type, dx) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseDragged, 0), (.leftMouseDragged, 50), (.leftMouseUp, 50)] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + dx, y: start.y), modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: handle.mouseDown(with: event)
            case .leftMouseDragged:
                handle.mouseDragged(with: event)
                let moved = try #require(root.tiles)
                #expect(abs(moved.columnShares[0] - (0.4 + dx / area.width)) < 1e-6 && abs(moved.row - 0.6) < 1e-6)
                #expect(moved.columnShares[1] == moved.columnShares[0])
            default: handle.mouseUp(with: event)
            }
        }
    }

    @Test func aNearEvenLineSnapsOnReleaseUnlessShiftHoldsIt() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = Tab(url: nil, title: "Page", spaceID: space)
        manager.adopt([tab], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(tab)
        let window = try #require(controller.window)
        let root = controller.root
        var custom = TileShape(regions: [.topLeft, .topRight, .bottomLeft, .bottomRight])
        custom.columnShares = [0.3, 0.5]
        root.setTiles(custom, animated: false)
        window.layoutIfNeeded()
        let area = root.cardFrame
        let segment = try #require(root.tiles?.segments(in: area, gap: root.paneGap, slop: Tokens.Metric.dragReach)
            .first { $0.axis == .column && $0.row == 0 })
        // On the drawn line itself, so there is no grab offset between the pointer and the line.
        let first = try #require(root.tiles?.frames(in: area, gap: root.paneGap).first)
        let lineX = first.maxX
        let start = root.convert(NSPoint(x: lineX, y: segment.frame.midY), to: nil)
        let near = root.convert(NSPoint(x: area.midX + 4, y: segment.frame.midY), to: nil)
        let frame = try #require(window.contentView?.superview)
        let handle = try #require(frame.hitTest(frame.convert(start, from: nil)) as? ResizeHandle)
        func drag(shift: Bool) throws {
            let events: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, start), (.leftMouseDragged, near), (.leftMouseUp, near)]
            for (type, point) in events {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [],
                                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: 1, pressure: 1))
                switch type {
                case .leftMouseDown: handle.mouseDown(with: event)
                case .leftMouseDragged:
                    handle.mouseDragged(with: event)
                    let during = try #require(root.tiles?.columnShares[0])
                    #expect(abs(during - 0.5) * area.width <= 8)
                default: handle.mouseUp(with: event)
                }
            }
        }
        try drag(shift: false)
        #expect(root.tiles?.columnShares[0] == 0.5)
        // The same near miss with Shift held stays where it was let go.
        root.setTiles(custom, animated: false)
        window.layoutIfNeeded()
        try drag(shift: true)
        let held = try #require(root.tiles?.columnShares[0])
        #expect(held != 0.5)
        #expect(abs(held - 0.5) * area.width <= 8)
    }

    @Test func theBandTakesThePointerOverTheSidebarAndThePage() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = Tab(url: nil, title: "Page", spaceID: space)
        manager.adopt([tab], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(tab)
        let window = try #require(controller.window)
        window.layoutIfNeeded()
        let root = controller.root
        try #require(root.sidebarVisible)
        let edge = root.sidebarWidth
        func hit(_ dx: CGFloat) -> NSView? {
            let point = root.convert(NSPoint(x: edge + dx, y: root.bounds.midY), to: nil)
            return window.contentView?.superview?.hitTest(point)
        }
        // Inside the sidebar's empty strip, on the edge, and just over the page: the handle.
        for dx: CGFloat in [-Tokens.Metric.sidebarDragReach + 1, -3, 0, Tokens.Metric.dragReach - 1] {
            #expect(hit(dx) is ResizeHandle, "at \(dx)")
        }
        // Further in either way: the sidebar's rows, or the page.
        #expect(!(hit(-Tokens.Metric.sidebarDragReach - 4) is ResizeHandle))
        #expect(!(hit(Tokens.Metric.dragReach + 4) is ResizeHandle))
    }

    /// The popout sidebar's edge takes the pointer, the width it leaves behind is kept for the next window, and a
    /// double-click puts the usual width back (#431).
    @Test func thePopoutSidebarEdgeSetsAWidthEveryWindowKeeps() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        let suite = "ZigzagSidebarWidthTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let shared = BrowserRootView.defaults
        BrowserRootView.defaults = defaults
        defer {
            BrowserRootView.defaults = shared
            defaults.removeScratchSuite(suite)
            manager.invalidate()
            Library.shared.restore(before)
        }
        let tab = Tab(url: nil, title: "Page", spaceID: space)
        manager.adopt([tab], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(tab)
        let window = try #require(controller.window)
        let root = controller.root
        root.sidebarWidth = Tokens.Metric.sidebarWidth
        root.sidebarVisible = false
        window.layoutIfNeeded()
        root.needsLayout = false
        root.reveal(true)
        // A real reveal lays out by itself: the handle leaves the shown sidebar's spot without the test doing it.
        #expect(root.needsLayout)
        window.layoutIfNeeded()
        let card = BrowserRootView.sidebarFrame(in: root.bounds, width: root.sidebarWidth, visible: false,
                                               revealed: true, onRight: root.sidebarOnRight)
        #expect(!root.resizeHandle.isHidden)
        #expect(abs(root.resizeHandle.frame.midX - (root.sidebarOnRight ? card.minX : card.maxX)) <= 1)
        // Dragged wider, it keeps the width past this window.
        root.debugEdgeDrag("begin")
        let to = root.convert(NSPoint(x: root.sidebarWidth + 40, y: 300), to: nil).x
        root.debugEdgeDrag("\(to)")
        root.debugEdgeDrag("end")
        // The card floats a frame's inset in from the window, so the pointer's reach is that much wider than the card.
        let reach = BrowserRootView.reach(of: to, in: root.bounds, onRight: root.sidebarOnRight)
        let expected = Tokens.Space.snap(min(max(reach - Tokens.Metric.cardInset,
                                                 Tokens.Metric.sidebarMinWidth), Tokens.Metric.sidebarMaxWidth))
        #expect(root.sidebarWidth == expected)
        #expect(root.sidebarWidth > Tokens.Metric.sidebarWidth)
        let kept = root.sidebarWidth
        let second = BrowserWindowController(tabManager: TabManager(spaceID: space), frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { second.window?.close() }
        #expect(second.root.sidebarWidth == kept)
        // Double-clicking the edge puts the usual width back, and the next window hears about it.
        root.debugEdgeDrag("reset")
        #expect(root.sidebarWidth == Tokens.Metric.sidebarWidth)
        let third = BrowserWindowController(tabManager: TabManager(spaceID: space), frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { third.window?.close() }
        #expect(third.root.sidebarWidth == Tokens.Metric.sidebarWidth)
    }

    /// ⌘Z puts a group's lines back after a change, and redo moves them forward again (#435).
    @Test func undoPutsTheTileLinesBack() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let ids = (0..<2).map { _ in Tab(url: nil, title: "Page", spaceID: space) }
        manager.adopt(ids, in: space)
        manager.makeSplit(ids[0], with: ids[1], vertical: true)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(ids[0])
        let window = try #require(controller.window)
        window.layoutIfNeeded()
        let even = try #require(manager.split(for: ids[0])?.shape)
        #expect(even.isStacked)
        var lower = even
        lower.moveRowLine(in: 0, to: 0.6, length: 600, minimum: 100)
        controller.applyTileShape(lower, undoTo: manager.split(for: ids[0])?.shape)
        #expect(manager.split(for: ids[0])?.shape.rowShares == [0.6, 0.6])
        controller.sidebarUndo.undo()
        #expect(manager.split(for: ids[0])?.shape.rowShares == [0.5, 0.5])
        controller.sidebarUndo.redo()
        #expect(manager.split(for: ids[0])?.shape.rowShares == [0.6, 0.6])
    }

    /// ⌘Z for one group's lines leaves another group alone, even where both are two pages (#435).
    @Test func undoFindsAnotherGroupsLinesWhereverItIs() throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let ids = (0..<4).map { _ in Tab(url: nil, title: "Page", spaceID: space) }
        manager.adopt(ids, in: space)
        manager.makeSplit(ids[0], with: ids[1], vertical: true)
        manager.makeSplit(ids[2], with: ids[3], vertical: true)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(ids[0])
        let window = try #require(controller.window)
        window.layoutIfNeeded()
        let even = try #require(manager.split(for: ids[0])?.shape)
        var lower = even
        lower.moveRowLine(in: 0, to: 0.6, length: 600, minimum: 100)
        controller.applyTileShape(lower, undoTo: manager.split(for: ids[0])?.shape)
        #expect(manager.split(for: ids[0])?.shape.rowShares == [0.6, 0.6])

        manager.select(ids[2])
        window.layoutIfNeeded()
        let other = try #require(manager.split(for: ids[2])?.shape)
        #expect(controller.root.tiles == other)
        controller.sidebarUndo.undo()
        // The group the drag was in goes back, though another split is showing, and the other is left alone.
        #expect(manager.split(for: ids[0])?.shape == even)
        #expect(manager.split(for: ids[2])?.shape == other)
        // Off screen, it changes the group without drawing it over the split that is showing.
        #expect(controller.root.tiles == other)
        // The step is still there to redo, not used up doing nothing.
        #expect(controller.sidebarUndo.canRedo)
    }

}
