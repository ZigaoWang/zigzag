import AppKit
import Testing
import WebKit
@testable import Zigzag

/// A tab's page sits in a holder of its own (`PageHolder`), and that holder is what a card or the mini player shows.
/// WebKit docks the Web Inspector beside the page, in the page's parent, as tall as that parent: so the inspector
/// stays in the page's part of a card, and goes where its tab goes.
@MainActor
struct PageHolderTests {
    /// Kept by each test for as long as it runs: a page only knows its tab weakly, and without the tab there's no
    /// holder for a card to show.
    private func tab() -> Tab { Tab(url: nil, spaceID: UUID(), configuration: WKWebViewConfiguration()) }

    private func card(width: CGFloat = 800, height: CGFloat = 600) -> PageCardView {
        PageCardView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    /// What WebKit does to dock the inspector at a side: a view beside the page, in the page's own parent and as tall
    /// as it, the page made narrower for it.
    private func dockInspector(beside page: WKWebView, width: CGFloat = 300, onLeft: Bool = false) throws -> NSView {
        let parent = try #require(page.superview)
        let rest = parent.bounds.width - width
        let inspector = NSView(frame: NSRect(x: onLeft ? 0 : rest, y: 0, width: width, height: parent.bounds.height))
        inspector.autoresizingMask = [.height, onLeft ? .maxXMargin : .minXMargin]
        page.frame = NSRect(x: onLeft ? width : 0, y: 0, width: rest, height: page.frame.height)
        parent.addSubview(inspector, positioned: .below, relativeTo: page)
        return inspector
    }

    @Test func aDockedInspectorStartsBelowTheBarAboveThePage() throws {
        let card = card(), tab = tab()
        let page = tab.ensureWebView()
        card.band = 44
        card.show(page)
        card.layoutSubtreeIfNeeded()
        #expect(page.superview === tab.pageHolder)
        let inspector = try dockInspector(beside: page)
        // The card's top 44 points are the bar's: the inspector is as tall as the page under it, no taller.
        #expect(card.convert(inspector.bounds, from: inspector) == NSRect(x: 500, y: 44, width: 300, height: 556))
        #expect(card.convert(page.bounds, from: page) == NSRect(x: 0, y: 44, width: 500, height: 556))
    }

    @Test func aDockedInspectorStartsBelowAPanesHeader() throws {
        let card = card(), tab = tab()
        let page = tab.ensureWebView()
        card.showsHeader = true
        card.show(page)
        card.layoutSubtreeIfNeeded()
        #expect(page.superview === tab.pageHolder)
        let inspector = try dockInspector(beside: page)
        #expect(card.convert(inspector.bounds, from: inspector).minY == PaneHeaderView.height)
    }

    @Test func theInspectorLeavesWithItsTabAndComesBackWithIt() throws {
        let card = card(), first = tab(), second = tab()
        let page = first.ensureWebView()
        card.show(page)
        card.layoutSubtreeIfNeeded()
        let inspector = try dockInspector(beside: page)
        let place = card.convert(inspector.bounds, from: inspector)

        card.show(second.ensureWebView())
        card.layoutSubtreeIfNeeded()
        // Nothing of the first tab is left in the card, and its inspector is still beside its page, in its holder.
        #expect(!inspector.isDescendant(of: card))
        #expect(!page.isDescendant(of: card))
        #expect(page.superview === first.pageHolder)
        #expect(inspector.superview === first.pageHolder)

        card.show(page)
        card.layoutSubtreeIfNeeded()
        #expect(card.convert(inspector.bounds, from: inspector) == place)
        #expect(page.frame.width == 500)
    }

    @Test func resizingTheCardKeepsTheInspectorsWidth() throws {
        let card = card(), tab = tab()
        let page = tab.ensureWebView()
        card.show(page)
        card.layoutSubtreeIfNeeded()
        let inspector = try dockInspector(beside: page)
        card.setFrameSize(NSSize(width: 1000, height: 700))
        card.layoutSubtreeIfNeeded()
        // The page takes the new room; the card never lays it over the inspector.
        #expect(page.frame == NSRect(x: 0, y: 0, width: 700, height: 700))
        #expect(inspector.frame == NSRect(x: 700, y: 0, width: 300, height: 700))
    }

    @Test func aTabsNewPageAppearsWhereItsOldOneWas() throws {
        let card = card(), tab = tab()
        let old = tab.ensureWebView()
        card.show(old)
        card.layoutSubtreeIfNeeded()
        let holder = try #require(tab.pageHolder)
        // The tab's page is made again (it woke, or changed profile) while it's shown.
        old.removeFromSuperview()
        let new = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        new.owner = tab
        holder.hold(new)
        card.show(new)
        // Same holder, still in the card: the new page fills it.
        #expect(new.superview === holder)
        #expect(holder.isDescendant(of: card))
        #expect(new.frame.size == NSSize(width: 800, height: 600))
    }

    @Test func swappingASplitsPanesLeavesBothShown() {
        let leftCard = card(), rightCard = card()
        let left = tab(), right = tab()
        let leftPage = left.ensureWebView(), rightPage = right.ensureWebView()
        leftCard.show(leftPage)
        rightCard.show(rightPage)
        leftCard.show(rightPage)
        rightCard.show(leftPage)
        // Each page came across in its tab's own holder.
        #expect(leftPage.superview === left.pageHolder)
        #expect(rightPage.superview === right.pageHolder)
        // The second card doesn't take out the holder the first has just taken from it.
        #expect(rightPage.isDescendant(of: leftCard))
        #expect(leftPage.isDescendant(of: rightCard))
    }

    @Test func theMiniPlayerTakesThePageWithItsInspector() throws {
        let card = card(), tab = tab()
        let page = tab.ensureWebView()
        card.show(page)
        card.layoutSubtreeIfNeeded()
        let inspector = try dockInspector(beside: page, onLeft: true)
        let holder = try #require(tab.pageHolder)

        let player = MiniPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        player.adopt(holder)
        // Page and inspector keep their sizes, so the page never reflows.
        #expect(page.frame.size == NSSize(width: 500, height: 600))
        #expect(page.superview === holder)
        #expect(inspector.superview === holder)
        // The video's place in what's shown counts from the holder's corner: past the inspector on the page's left.
        #expect(player.shown(NSRect(x: 20, y: 30, width: 160, height: 90), of: page) == NSRect(x: 320, y: 30, width: 160, height: 90))

        // Minimized, the holder waits in the window at its size, then goes back to resizing with whatever shows it.
        let parking = MiniPlayerParking()
        parking.park(holder)
        #expect(holder.frame.size == NSSize(width: 800, height: 600))
        parking.release(holder)
        #expect(holder.superview == nil)
        #expect(holder.autoresizingMask == [.width, .height])
    }

    @Test func aPageThatLeftTheCardCountsAsOffScreen() {
        let card = card(), first = tab(), second = tab()
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(card)
        let page = first.ensureWebView()
        card.show(page)
        // Shown in a window: the tab overview has no picture to take out of sight.
        #expect(!Tab.needsPictureOutOfSight(hasWebView: true, onScreen: page.window != nil, loaded: true, hasPicture: false))
        card.show(second.ensureWebView())
        // It still has a parent (its holder), so "on screen" asks for the window, not for a parent.
        #expect(page.superview === first.pageHolder)
        #expect(Tab.needsPictureOutOfSight(hasWebView: true, onScreen: page.window != nil, loaded: true, hasPicture: false))
    }

    @Test func aClosedTabsHolderLeavesTheCard() throws {
        let card = card(), tab = tab()
        card.show(tab.ensureWebView())
        card.layoutSubtreeIfNeeded()
        let holder = try #require(tab.pageHolder)
        #expect(holder.isDescendant(of: card))
        tab.close()
        // Nothing of the tab stays behind in the card, an inspector docked in its holder included.
        #expect(holder.superview == nil)
        #expect(!holder.isDescendant(of: card))
        #expect(tab.pageHolder?.superview == nil)
    }

    @Test func theCardDoesNotResizeAHolderItNoLongerHosts() throws {
        let card = card(), tab = tab()
        card.show(tab.ensureWebView())
        card.layoutSubtreeIfNeeded()
        let holder = try #require(tab.pageHolder)
        #expect(holder.frame.size == NSSize(width: 800, height: 600))
        // The mini player takes the page while the card still has it as its shown one.
        let player = MiniPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        player.adopt(holder)
        #expect(!holder.isDescendant(of: card))
        card.setFrameSize(NSSize(width: 1000, height: 700))
        card.layoutSubtreeIfNeeded()
        // Sized from the card, the page would reflow under the video.
        #expect(holder.frame.size == NSSize(width: 800, height: 600))
    }
}
