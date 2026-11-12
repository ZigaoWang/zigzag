import AppKit
import Testing
@testable import Zigzag

/// The grips beside a page at a size of its own (#141): where they go, and the size a drag gives.
@MainActor
struct PageSizeHandleTests {
    private let room = NSRect(x: 0, y: 0, width: 1000, height: 700)
    private let page = NSRect(x: 303, y: 50, width: 393, height: 600)

    @Test func theGripsLieBesideThePageNotOverIt() throws {
        let frames = PageSizeHandle.frames(page: page, room: room)
        let right = try #require(frames[.right]), bottom = try #require(frames[.bottom]), corner = try #require(frames[.corner])
        #expect(right.minX == page.maxX && abs(right.midY - page.midY) <= 0.5)
        // The view counts up from the bottom: under the page is below its minY.
        #expect(bottom.maxY == page.minY && abs(bottom.midX - page.midX) <= 0.5)
        #expect(corner.minX == page.maxX && corner.maxY == page.minY)
        for frame in frames.values { #expect(!frame.intersects(page) && room.contains(frame)) }
        // Counting down from the top, under the page is past its maxY.
        let flipped = PageSizeHandle.frames(page: page, room: room, flipped: true)
        #expect(flipped[.bottom]?.minY == page.maxY)
    }

    @Test func noGripWhereThePageMeetsItsRoom() {
        let wide = NSRect(x: 0, y: 50, width: 1000, height: 600)
        let frames = PageSizeHandle.frames(page: wide, room: room)
        #expect(frames[.right] == nil && frames[.corner] == nil && frames[.bottom] != nil)
        #expect(PageSizeHandle.frames(page: room, room: room).isEmpty)
    }

    @Test func aDragTakesBothSidesWithIt() {
        let phone = CGSize(width: 393, height: 852)
        // The page stays in the middle: its right side moves half the change, so 10 points out is 20 wider.
        #expect(PageSizeHandle.resized(phone, edge: .right, delta: CGSize(width: 10, height: -40), scale: 1) == CGSize(width: 413, height: 852))
        // Down is a negative y in window points, and makes it taller.
        #expect(PageSizeHandle.resized(phone, edge: .bottom, delta: CGSize(width: 10, height: -40), scale: 1) == CGSize(width: 393, height: 932))
        #expect(PageSizeHandle.resized(phone, edge: .corner, delta: CGSize(width: -10, height: 40), scale: 1) == CGSize(width: 373, height: 772))
        // A page shown at half its size moves twice as much under the pointer.
        #expect(PageSizeHandle.resized(CGSize(width: 1920, height: 1080), edge: .right, delta: CGSize(width: 10, height: 0), scale: 0.5) == CGSize(width: 1960, height: 1080))
        // Never past the sizes a page can be.
        #expect(PageSizeHandle.resized(phone, edge: .corner, delta: CGSize(width: -500, height: 900), scale: 1)
                == CGSize(width: PageSizes.limits.lowerBound, height: PageSizes.limits.lowerBound))
    }

    @Test func eachGripHasAName() {
        let names = PageSizeHandle.Edge.allCases.map(PageSizeHandle.name(of:))
        #expect(Set(names).count == names.count && names.allSatisfy { !$0.isEmpty })
    }
}
