import Foundation
import JavaScriptCore
import WebKit
import Testing
@testable import Zigzag

/// The rules behind fixes that people would only notice going wrong: what Try Again re-runs, which saved logins
/// may fill where, and old data from a newer version still reading.
@MainActor
struct ShipFixesTests {
    @Test func tryAgainRunsOnlyWhatFailed() {
        let all: ImportCoordinator.Choice = [.passwords, .bookmarks, .history]
        // Chrome's passwords stayed locked: only passwords again, never history (which would double the counts).
        let locked = ImportProblem(message: "", fix: .retry, retries: ImportCoordinator.Choice.passwords.rawValue)
        #expect(ImportCoordinator.Choice.retrying([locked], else: all) == .passwords)
        // A primary password is about passwords too.
        let primary = ImportProblem(message: "", fix: .primaryPassword)
        #expect(ImportCoordinator.Choice.retrying([primary], else: all) == .passwords)
        // A problem that doesn't say what failed: everything, as before.
        let unknown = ImportProblem(message: "", fix: .retry)
        #expect(ImportCoordinator.Choice.retrying([unknown], else: all) == all)
        // Nothing to retry: everything.
        #expect(ImportCoordinator.Choice.retrying([], else: all) == all)
    }

    /// #272: with the sidebar hidden, a background new tab shows a note; with it visible the new row does, and over the desk there's no page for it.
    @Test func newTabNoteOnlyWithTheSidebarOutOfSight() {
        #expect(NewTabNote.shows(sidebarVisible: false, sidebarFloating: false, deskVisible: false))
        #expect(!NewTabNote.shows(sidebarVisible: true, sidebarFloating: false, deskVisible: false))
        #expect(!NewTabNote.shows(sidebarVisible: false, sidebarFloating: true, deskVisible: false))
        #expect(!NewTabNote.shows(sidebarVisible: false, sidebarFloating: false, deskVisible: true))
    }

    /// #272: WebKit's empty tab shows the site it's about to load; once the tab has a page, its own title, live.
    @Test func newTabRowFollowsTheTabsTitle() {
        let site = URL(string: "https://www.youtube.com/watch?v=1")!
        let empty = Tab(url: nil, spaceID: UUID())
        #expect(NewTabNote.placeholder(for: empty, site: site) == "www.youtube.com")
        #expect(NewTabNote.placeholder(for: Tab(url: site, spaceID: UUID()), site: site) == nil)

        let peek = NewTabPeekView(tab: empty, site: site)
        #expect(peek.row.title.stringValue == "www.youtube.com")
        empty.customTitle = "A Video"
        #expect(peek.row.title.stringValue == "A Video")
        let titled = Tab(url: site, title: "YouTube", spaceID: UUID())
        let live = NewTabPeekView(tab: titled, site: site)
        #expect(live.row.title.stringValue == "YouTube")
        titled.customTitle = "Another Video"
        #expect(live.row.title.stringValue == "Another Video")
        #expect(NewTabNote.announcement(for: "A Video").contains("A Video"))
    }

    /// #272: each new tab's row comes out at its own place in the list; one scrolled past comes out at that end of the
    /// list in sight, stacked inward in list order and clear of the others.
    @Test func newTabRowsEachTakeTheirOwnPlace() {
        let h: CGFloat = 30, gap: CGFloat = 2, sight: ClosedRange<CGFloat> = 100...400
        #expect(NewTabNote.slots(rows: [120, 152, 184], visible: sight, height: h, gap: gap) == [120, 152, 184])
        // Below the fold: up from the bottom, the last lowest.
        #expect(NewTabNote.slots(rows: [500, 532], visible: sight, height: h, gap: gap) == [338, 370])
        // Above: down from the top. Nowhere (in a closed folder): the bottom.
        #expect(NewTabNote.slots(rows: [10, nil], visible: sight, height: h, gap: gap) == [100, 370])
        // A stacked one steps past a row already there.
        #expect(NewTabNote.slots(rows: [370, 600], visible: sight, height: h, gap: gap) == [370, 338])
    }

    @Test func oldHTTPLoginsFillOnTheSecureSiteOnly() throws {
        let http = try #require(Origin(URL(string: "http://example.com/login")))
        let https = try #require(Origin(URL(string: "https://example.com/")))
        let other = try #require(Origin(URL(string: "https://example.org/")))
        let port = try #require(Origin(URL(string: "https://example.com:8443/")))
        #expect(https.fills(on: https))
        #expect(http.fills(on: https))       // upgraded to the secure page
        #expect(!https.fills(on: http))      // never the other way round
        #expect(!http.fills(on: other))      // never another site
        #expect(!http.fills(on: port))       // nor another port
    }

    @Test func unknownSpaceColourStillReads() throws {
        let json = Data(#"["sky", "ultraviolet", "mint"]"#.utf8)
        let colours = try JSONDecoder().decode([SpaceColor].self, from: json)
        #expect(colours == [.sky, .graphite, .mint])
    }

    @Test func aPageInFullScreenKeepsTheSizeWebKitGaveIt() {
        let card = PageCardView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // The tab is kept for the whole test: the card shows a page in its tab's holder, and finds none without the tab.
        let tab = Tab(url: nil, spaceID: UUID(), configuration: WKWebViewConfiguration())
        let webView = tab.ensureWebView()
        card.show(webView)
        card.layoutSubtreeIfNeeded()
        #expect(webView.frame.size == NSSize(width: 800, height: 600))
        // A video goes full screen: WebKit takes the page into a window of its own, the size of the screen.
        let screen = NSView(frame: NSRect(x: 0, y: 0, width: 1512, height: 949))
        screen.addSubview(webView)
        webView.frame = screen.bounds
        // The card lays itself out meanwhile (the page shown changes, the window resizes): the page isn’t its to size.
        card.showsHeader = false
        card.setFrameSize(NSSize(width: 700, height: 500))
        card.layoutSubtreeIfNeeded()
        #expect(webView.frame == screen.bounds)
    }

    @Test func aPageBackFromFullScreenBehindAnotherLeavesTheCard() throws {
        let card = PageCardView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let videoTab = Tab(url: nil, spaceID: UUID(), configuration: WKWebViewConfiguration())
        let otherTab = Tab(url: nil, spaceID: UUID(), configuration: WKWebViewConfiguration())
        let video = videoTab.ensureWebView(), other = otherTab.ensureWebView()
        card.show(video)
        let holder = try #require(videoTab.pageHolder), clip = try #require(holder.superview)
        // In full screen, in WebKit's window, while you switch to another tab in the browser window: its holder stays
        // in the card, under the page now shown, for WebKit to put it back in.
        let fullScreen = NSView()
        fullScreen.addSubview(video)
        card.show(other)
        clip.addSubview(holder, positioned: .below, relativeTo: otherTab.pageHolder)
        // Its full screen ends: WebKit puts it back where it was.
        holder.addSubview(video)
        #expect(video.isDescendant(of: card))
        card.pageLeftFullScreen(video)
        #expect(!video.isDescendant(of: card))
        #expect(holder.superview == nil)
        #expect(other.isDescendant(of: card))
        // The page shown is never taken out.
        card.pageLeftFullScreen(other)
        #expect(other.isDescendant(of: card))
    }
}

/// Passwords across one site's parts, never across sites, by the Public Suffix List.
struct SiteMatchingTests {
    @Test func findsTheRegistrableDomain() {
        #expect(PublicSuffix.registrableDomain("www.netflix.com") == "netflix.com")
        #expect(PublicSuffix.registrableDomain("news.bbc.co.uk") == "bbc.co.uk")
        #expect(PublicSuffix.registrableDomain("alice.github.io") == "alice.github.io")
        #expect(PublicSuffix.registrableDomain("co.uk") == nil)
        #expect(PublicSuffix.registrableDomain("github.io") == nil)
        #expect(PublicSuffix.registrableDomain("192.168.1.1") == nil)
        #expect(PublicSuffix.registrableDomain("localhost") == nil)
    }

    @Test func fillsAcrossOneSiteOnly() {
        func origin(_ s: String) -> Origin { Origin(URL(string: s))! }
        #expect(origin("https://www.netflix.com").fills(on: origin("https://netflix.com")))
        #expect(origin("https://m.facebook.com").fills(on: origin("https://www.facebook.com")))
        #expect(origin("http://www.example.com").fills(on: origin("https://login.example.com")))
        #expect(!origin("https://login.example.com").fills(on: origin("http://www.example.com")))   // never onto an insecure page
        #expect(!origin("https://alice.github.io").fills(on: origin("https://bob.github.io")))     // different owners
        #expect(!origin("https://bbc.co.uk").fills(on: origin("https://evil.co.uk")))
        #expect(!origin("https://example.com").fills(on: origin("https://example.com.evil.net")))
        #expect(!origin("https://example.com:8443").fills(on: origin("https://www.example.com")))
    }
}

/// Folders of pinned pages: kept together, in order, never holding pages that are gone.
struct BookmarkFolderTests {
    private func pages(_ names: String...) -> [Bookmark] { names.map { Bookmark(url: URL(string: "https://\($0).com")!, title: $0) } }

    @Test func gathersAFoldersPagesWhereTheFirstIs() {
        let b = pages("a", "b", "c", "d", "e")
        let folder = BookmarkFolder(name: "Work", bookmarkIDs: [b[3].id, b[1].id])
        let (list, folders) = Library.tidied(b, [folder])
        #expect(list.map(\.title) == ["a", "b", "d", "c", "e"])
        #expect(folders[0].bookmarkIDs == [b[1].id, b[3].id])   // the list's order
    }

    @Test func forgetsPagesThatAreGone() {
        let b = pages("a", "b")
        let gone = UUID()
        let (list, folders) = Library.tidied(b, [BookmarkFolder(name: "F", bookmarkIDs: [gone, b[1].id])])
        #expect(list.map(\.title) == ["a", "b"])
        #expect(folders[0].bookmarkIDs == [b[1].id])
    }

    @Test func leavesLoosePagesAndEmptyFoldersAlone() {
        let b = pages("a", "b", "c")
        let (list, folders) = Library.tidied(b, [BookmarkFolder(name: "Empty")])
        #expect(list.map(\.title) == ["a", "b", "c"])
        #expect(folders.count == 1 && folders[0].bookmarkIDs.isEmpty)
    }

    @Test func keepsTwoFoldersApart() {
        let b = pages("a", "b", "c", "d")
        let one = BookmarkFolder(name: "1", bookmarkIDs: [b[0].id, b[2].id])
        let two = BookmarkFolder(name: "2", bookmarkIDs: [b[1].id, b[3].id])
        let (list, _) = Library.tidied(b, [one, two])
        #expect(list.map(\.title) == ["a", "c", "b", "d"])
    }

    @Test func keepsASubfolderInsideItsParent() {
        let b = pages("a", "b", "c", "d", "e")
        let outer = BookmarkFolder(name: "Outer", bookmarkIDs: [b[1].id])
        var inner = BookmarkFolder(name: "Inner", bookmarkIDs: [b[4].id, b[3].id])
        inner.parentID = outer.id
        let (list, folders) = Library.tidied(b, [outer, inner])
        // Outer's own page, then Inner's pages, all together where Outer's first page was.
        #expect(list.map(\.title) == ["a", "b", "d", "e", "c"])
        #expect(folders.pages(in: outer.id) == Set([b[1].id, b[3].id, b[4].id]))
        #expect(folders.depth(of: inner.id) == 1)
    }

    @Test func aFolderNeverEndsUpInsideItself() {
        let b = pages("a", "b")
        var one = BookmarkFolder(name: "1", bookmarkIDs: [b[0].id])
        var two = BookmarkFolder(name: "2", bookmarkIDs: [b[1].id])
        one.parentID = two.id
        two.parentID = one.id
        let (list, folders) = Library.tidied(b, [one, two])
        #expect(list.count == 2)
        #expect(folders.contains { $0.parentID == nil })
    }

    @Test func anEmptySubfolderSitsAtTheTopOfItsParent() {
        let b = pages("a", "b")
        let outer = BookmarkFolder(name: "Outer", bookmarkIDs: [b[0].id, b[1].id])
        var empty = BookmarkFolder(name: "Empty")
        empty.parentID = outer.id
        let (list, folders) = Library.tidied(b, [outer, empty])
        #expect(list.map(\.title) == ["a", "b"])
        #expect(folders.children(of: outer.id).map(\.name) == ["Empty"])
    }

    @Test func olderLibrariesWithoutFoldersStillLoad() throws {
        let json = Data(#"{"id":"6B1E4C1E-0000-4000-8000-000000000002","name":"Home","color":"sky","bookmarks":[]}"#.utf8)
        let space = try JSONDecoder().decode(SpaceInfo.self, from: json)
        #expect(space.folders == nil)
    }

    // MARK: Swiping back and forward

    /// The swipe arrow stays in the page's gap, never over the sidebar, the next pane or the window edge.
    @Test func swipeArrowStaysInsideTheCard() {
        let page = NSRect(x: 300, y: 0, width: 800, height: 600)
        let size = SwipeArrowView.size, margin = Tokens.Space.x2
        // Back: centered in a wide gap, a margin from the card edge in a narrow one.
        let wide = SwipeArrowView.frame(in: page, offset: size + margin * 4, back: true)
        #expect(wide.minX == page.minX + margin * 2)
        let narrow = SwipeArrowView.frame(in: page, offset: 10, back: true)
        #expect(narrow.minX == page.minX + margin)
        // Forward: same at the right edge.
        let forward = SwipeArrowView.frame(in: page, offset: -10, back: false)
        #expect(forward.maxX == page.maxX - margin)
        // Vertically centered either way.
        #expect(narrow.midY == page.midY)
    }

    private func decide(dx: CGFloat, dy: CGFloat = 0, back: Bool = true, forward: Bool = false,
                        scrolls: (left: Bool, right: Bool)? = (false, false), page: SwipeDecision.Page = .left,
                        waited: TimeInterval = 0.02, overFrame: Bool = false) -> SwipeDecision {
        SwipeDecision.decide(dx: dx, dy: dy, canGoBack: back, canGoForward: forward, pageScrolls: scrolls, page: page,
                             waited: waited, overFrame: overFrame)
    }

    @Test func onlyTheStartAndEndOfAScrollCanStartOrEndASwipe() {
        #expect(!SwipeNavigator.isMidGesture(.began))
        #expect(!SwipeNavigator.isMidGesture(.ended))
        #expect(!SwipeNavigator.isMidGesture(.cancelled))
        #expect(SwipeNavigator.isMidGesture(.changed))
        #expect(SwipeNavigator.isMidGesture(.stationary))
        #expect(SwipeNavigator.isMidGesture(.mayBegin))
        // A wheel's turn and the glide after a gesture carry no phase.
        #expect(SwipeNavigator.isMidGesture([]))
    }

    @Test func swipeGoesBackOnAPlainPage() {
        // A scroll toward the left edge goes back (fingers to the right, with natural scrolling), once it has gone
        // far enough to tell.
        #expect(decide(dx: 4) == .undecided)
        #expect(decide(dx: 14) == .track(-1))
        #expect(decide(dx: -14, forward: true) == .track(1))
        // Nowhere to go, or mostly down the page: a scroll.
        #expect(decide(dx: -14) == .ignore)
        #expect(decide(dx: 14, dy: 13) == .ignore)
        // A page that scrolls sideways that way keeps it.
        #expect(decide(dx: 14, scrolls: (true, false)) == .ignore)
        #expect(decide(dx: 14, scrolls: (false, true)) == .track(-1))
    }

    @Test func swipeFollowsTheMacsScrollingDirection() {
        // dx is the scroll, as macOS reports it after its scrolling direction setting: back is a scroll toward the
        // page's left edge, as in Safari. With natural scrolling that's fingers to the right; without it, fingers to
        // the left. Either way, a page with room on its left keeps a back swipe, and room on its right a forward one.
        #expect(decide(dx: 14, back: true, forward: true) == .track(-1))
        #expect(decide(dx: -14, back: true, forward: true) == .track(1))
        #expect(decide(dx: 14, back: true, forward: true, scrolls: (true, false)) == .ignore)
        #expect(decide(dx: 14, back: true, forward: true, scrolls: (false, true)) == .track(-1))
        #expect(decide(dx: -14, back: true, forward: true, scrolls: (false, true)) == .ignore)
        #expect(decide(dx: -14, back: true, forward: true, scrolls: (true, false)) == .track(1))
    }

    @Test func swipeLeavesPagesThatPanThemselves() {
        // Canva, Figma, Google Maps: the page cancelled the gesture's sideways scrolls, so it has the gesture, even
        // before the fingers have gone far.
        #expect(decide(dx: 4, page: .took) == .ignore)
        #expect(decide(dx: 40, page: .took) == .ignore)
        #expect(decide(dx: -40, forward: true, page: .took) == .ignore)
    }

    @Test func swipeWaitsBrieflyForThePagesAnswer() {
        // Not heard from the page yet: a moment's wait, with the page still getting the gesture, then on without it.
        #expect(decide(dx: 14, page: .unknown, waited: 0.01) == .undecided)
        #expect(decide(dx: 14, page: .unknown, waited: SwipeDecision.answerWait) == .track(-1))
        // An answer that it left them ends the wait at once.
        #expect(decide(dx: 14, page: .left, waited: 0.001) == .track(-1))
        // Nothing to wait for when the swipe couldn't go anyway.
        #expect(decide(dx: -14, page: .unknown, waited: 0.001) == .ignore)
    }

    @Test func swipeOverAFrameWaitsForTheFramesAnswer() {
        // Excel's sheet is in a frame the page around it can't see into: the frame's answer decides, and a busy
        // web app gets a little longer to give it than a plain page.
        #expect(decide(dx: 14, page: .unknown, waited: SwipeDecision.answerWait, overFrame: true) == .undecided)
        #expect(decide(dx: 14, page: .unknown, waited: SwipeDecision.frameWait, overFrame: true) == .track(-1))
        // The frame kept it (its sheet scrolls there, or it asked for no overscroll), or left it.
        #expect(decide(dx: 14, page: .took, waited: 0.001, overFrame: true) == .ignore)
        #expect(decide(dx: 14, page: .left, waited: 0.001, overFrame: true) == .track(-1))
        // Not yet known what's under the pointer: the longer wait too.
        #expect(decide(dx: 14, scrolls: nil, page: .unknown, waited: SwipeDecision.answerWait) == .undecided)
        #expect(decide(dx: 14, scrolls: nil, page: .left, waited: 0.001) == .track(-1))
    }

    @Test func swipeArrowLeansInWhileThePageAnswers() {
        func lean(dx: CGFloat, dy: CGFloat = 0, scrolls: (left: Bool, right: Bool)? = (false, false), page: SwipeDecision.Page = .unknown,
                  waited: TimeInterval = 0.01, overFrame: Bool = false, leans: Bool = true) -> SwipeDecision {
            SwipeDecision.decide(dx: dx, dy: dy, canGoBack: true, canGoForward: true, pageScrolls: scrolls, page: page,
                                 waited: waited, overFrame: overFrame, leans: leans)
        }
        // Nothing sideways under the pointer: the arrow comes with the first sideways steps, the page not yet heard from (#508).
        #expect(lean(dx: 12) == .lean(-1))
        #expect(lean(dx: -12) == .lean(1))
        // The page's answer, or the end of the wait, makes it the swipe's.
        #expect(lean(dx: 12, page: .left) == .track(-1))
        #expect(lean(dx: 12, waited: SwipeDecision.answerWait) == .track(-1))
        // A carousel or wide table with room that way keeps it, and one that cancelled the scrolls takes it back.
        #expect(lean(dx: 12, scrolls: (true, false)) == .ignore)
        #expect(lean(dx: 12, page: .took) == .ignore)
        // Up and down the page never shows it.
        #expect(lean(dx: 2, dy: 14) == .ignore)
        #expect(lean(dx: 12, dy: 11) == .ignore)
        #expect(lean(dx: 4) == .undecided)
        // Over a frame, not yet probed, or on a page that cancelled sideways scrolls before: it waits as before.
        #expect(lean(dx: 12, overFrame: true) == .undecided)
        #expect(lean(dx: 12, scrolls: nil) == .undecided)
        #expect(lean(dx: 12, leans: false) == .undecided)
    }

    @Test func swipeArrowShowsWithTheFirstMovement() {
        // Visible as soon as it comes, fully there a fifth of the way (#508).
        #expect(SwipeArrowView.opacity(progress: 0.05, armed: false) >= 0.4)
        #expect(SwipeArrowView.opacity(progress: 0.2, armed: false) == 1)
        #expect(SwipeArrowView.opacity(progress: 0, armed: true) == 1)
    }

    /// Milliseconds from a gesture's first scroll to its arrow showing: `step` points toward back every 8 ms, the probe
    /// answering after `probe` ms and the page after `answer` ms, as SwipeNavigator decides each step.
    private func arrowAfter(step: CGFloat, probe: Double, answer: Double, leans: Bool) -> Double? {
        var dx: CGFloat = 0
        for index in 1...40 {
            let ms = Double(index) * 8
            dx += step
            let decision = SwipeDecision.decide(dx: dx, dy: 0, canGoBack: true, canGoForward: false,
                                                pageScrolls: ms >= probe ? (false, false) : nil, page: ms >= answer ? .left : .unknown,
                                                waited: ms / 1000, leans: leans)
            if case .track = decision { return ms }
            if case .lean = decision { return ms }
        }
        return nil
    }

    @Test func swipeArrowDoesntWaitOnABusyPage() {
        // A page that answers in a frame: the arrow comes with the step that crosses 10 points either way.
        #expect(arrowAfter(step: 3, probe: 4, answer: 12, leans: true) == 32)
        #expect(arrowAfter(step: 3, probe: 4, answer: 12, leans: false) == 32)
        // A busy page slow to answer the scroll: before, the arrow waited out the 50 ms; now it comes at 10 points (#508).
        #expect(arrowAfter(step: 3, probe: 4, answer: 90, leans: false) == 56)
        #expect(arrowAfter(step: 3, probe: 4, answer: 90, leans: true) == 32)
        // The probe asked at touch-down is back before the scroll begins; one not back within a frame doesn't hold
        // the arrow back either, unless the page has cancelled sideways scrolls before.
        #expect(arrowAfter(step: 3, probe: 200, answer: 200, leans: true) == 32)
        #expect(arrowAfter(step: 3, probe: 200, answer: 200, leans: false) == 120)
    }

    @Test func aTouchDownsProbeIsForTheGestureAtItsSpot() {
        // Two-finger scrolls leave the pointer where it is: the answer from the touch-down holds for that gesture.
        #expect(SwipeNavigator.sameSpot(NSPoint(x: 100, y: 200), NSPoint(x: 101, y: 200)))
        #expect(!SwipeNavigator.sameSpot(NSPoint(x: 100, y: 200), NSPoint(x: 140, y: 200)))
    }

    /// A two-finger scroll at `phase` (1 began, 2 changed, 4 ended), `dx` and `dy` points.
    private func scroll(phase: Int64, dx: Int32 = 0, dy: Int32 = 0) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        return try #require(NSEvent(cgEvent: cg))
    }

    @MainActor @Test func aSwipesPageListensOnlyUntilItsGestureIsDecided() throws {
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled, SwipeNavigator.isOn else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        let page = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView?.addSubview(page)
        let swipe = page.swipeNavigator
        // Up and down: the page never listens.
        _ = swipe.handle(try scroll(phase: 1, dy: -6))
        #expect(!swipe.pageListens)
        _ = swipe.handle(try scroll(phase: 2, dy: -12))
        #expect(!swipe.pageListens)
        _ = swipe.handle(try scroll(phase: 4))
        // Sideways, it listens; with nowhere to go it's decided as a scroll, and it stops.
        _ = swipe.handle(try scroll(phase: 1, dx: 6))
        #expect(swipe.pageListens)
        _ = swipe.handle(try scroll(phase: 2, dx: 12))
        #expect(!swipe.pageListens)
        // Let go before deciding.
        _ = swipe.handle(try scroll(phase: 1, dx: 2))
        #expect(swipe.pageListens)
        _ = swipe.handle(try scroll(phase: 4))
        #expect(!swipe.pageListens)
    }

    @MainActor @Test func theSwipeScriptListensOnlyWhenAsked() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(SwipeAnswers.script)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        webView.loadHTMLString("<iframe srcdoc='<p>frame</p>'></iframe>", baseURL: URL(string: "https://example.com"))
        for _ in 0..<100 where webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        func run(_ js: String) async throws -> Bool? {
            try await webView.callAsyncJavaScript("return \(js)", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        }
        let listen = "window.\(SwipeAnswers.listen)"
        // The page itself: not until Zigzag asks, and no longer once told to stop.
        #expect(try await run("\(listen)()") == false)
        #expect(try await run("\(listen)(true)") == true)
        #expect(try await run("\(listen)(false)") == false)
        // A frame, which Zigzag can't ask: while the pointer is in it.
        let frame = "document.querySelector('iframe').contentWindow"
        #expect(try await run("\(frame).\(SwipeAnswers.listen)()") == true)
        let left = "(\(frame).document.dispatchEvent(new MouseEvent('mouseout', { bubbles: true, relatedTarget: null })), \(frame).\(SwipeAnswers.listen)())"
        #expect(try await run(left) == false)
        let back = "(\(frame).document.body.dispatchEvent(new MouseEvent('mouseover', { bubbles: true })), \(frame).\(SwipeAnswers.listen)())"
        #expect(try await run(back) == true)
    }

    @Test func swipeAnswersBelongToTheirGesture() {
        let began = 1_000_000.0
        // The first answer decides; one about the last gesture's momentum, answered late, doesn't count.
        #expect(SwipeDecision.page(.unknown, answered: true, at: began - 30, began: began) == .unknown)
        #expect(SwipeDecision.page(.unknown, answered: false, at: began + 8, began: began) == .left)
        #expect(SwipeDecision.page(.unknown, answered: true, at: began + 8, began: began) == .took)
        // Kept once, kept for the rest: a sheet that had room when the gesture started stays the page's after the
        // gesture scrolls it to its edge.
        #expect(SwipeDecision.page(.took, answered: false, at: began + 200, began: began) == .took)
        // Left at first, kept later (a page that cancels the scrolls after a few, or answers late while the arrow
        // shows): the page has it, and the arrow goes.
        #expect(SwipeDecision.page(.left, answered: true, at: began + 60, began: began) == .took)
    }

    /// Runs the swipe script's own decision in JavaScriptCore over made-up elements: `chain` from the one under the
    /// pointer outward, each a JavaScript object literal with its style.
    private func keeps(_ chain: [String], root: String = "null", ends: String = "[]", view: String = "null",
                       deltaX: Double, prevented: Bool = false) throws -> Bool {
        let context = try #require(JSContext())
        let result = context.evaluateScript("""
        const chain = [\(chain.joined(separator: ", "))];
        chain.forEach((el, i) => { el.parentElement = chain[i + 1] || null; });
        const style = (el) => Object.assign({ overflowX: 'visible', overflowY: 'visible', overscrollBehaviorX: 'auto', direction: 'ltr' }, el.style);
        const room = (\(SwipeAnswers.sideways))(chain[0], style, \(root), \(ends), \(view));
        (\(SwipeAnswers.keeps))(room, \(deltaX), \(prevented))
        """)
        #expect(context.exception == nil)
        return try #require(result?.toBool() as Bool?)
    }

    private func grid(scrollLeft: Double, overscroll: String = "auto") -> String {
        "{ scrollWidth: 3000, clientWidth: 800, scrollHeight: 600, clientHeight: 600, scrollLeft: \(scrollLeft), style: { overflowX: 'auto', overscrollBehaviorX: '\(overscroll)' } }"
    }
    private let cell = "{ scrollWidth: 80, clientWidth: 80, style: {} }"

    @Test func swipeScriptKeepsWhatScrollsThatWay() throws {
        // Fingers to the right (back) move the content toward its left edge: the page's deltaX is negative, and the
        // sheet needs room on its left.
        #expect(try keeps([cell, grid(scrollLeft: 300)], deltaX: -12))
        #expect(try !keeps([cell, grid(scrollLeft: 0)], deltaX: -12))
        // At its left edge it still scrolls right, the other way.
        #expect(try keeps([cell, grid(scrollLeft: 0)], deltaX: 12))
        #expect(try !keeps([cell, grid(scrollLeft: 2200)], deltaX: 12))
        // Right to left, the start is at the right: scrollLeft runs from 0 down to minus the overflow.
        let rtl = "{ scrollWidth: 3000, clientWidth: 800, scrollLeft: 0, style: { overflowX: 'auto', direction: 'rtl' } }"
        #expect(try keeps([cell, rtl], deltaX: -12))
        #expect(try !keeps([cell, rtl], deltaX: 12))
        // A page a little too wide by accident has no room ahead; scrolled along, it has room behind (#377).
        #expect(try !keeps([cell], root: "{ scrollWidth: 1040, clientWidth: 1000, scrollLeft: 0, style: {} }", deltaX: 12))
        #expect(try !keeps([cell], root: "{ scrollWidth: 1040, clientWidth: 1000, scrollLeft: 0, style: {} }", deltaX: -12))
        #expect(try keeps([cell], root: "{ scrollWidth: 1040, clientWidth: 1000, scrollLeft: 20, style: {} }", deltaX: -12))
        #expect(try keeps([cell], root: "{ scrollWidth: 3000, clientWidth: 1000, scrollLeft: 20, style: {} }", deltaX: -12))
        // Nothing scrolls: a plain page leaves it to the swipe.
        #expect(try !keeps([cell, "{ scrollWidth: 1000, clientWidth: 1000, style: {} }"], deltaX: -12))
    }

    @Test func swipeScriptKeepsWhatAskedForNoOverscroll() throws {
        // A sheet at its edge that asked to keep its overscroll (Excel): no going back past it, either way.
        #expect(try keeps([cell, grid(scrollLeft: 0, overscroll: "none")], deltaX: -12))
        #expect(try keeps([cell, grid(scrollLeft: 0, overscroll: "contain")], deltaX: -12))
        // Only something that scrolls passes its overscroll on: the setting on a box that doesn't is nothing.
        #expect(try !keeps([cell, "{ scrollWidth: 800, clientWidth: 800, style: { overflowX: 'auto', overscrollBehaviorX: 'none' } }"], deltaX: -12))
        // The page's root or body asking for it turns off going back and forward there.
        #expect(try keeps([cell], ends: "[{ style: { overscrollBehaviorX: 'none' } }, null]", deltaX: -12))
        #expect(try keeps([cell], ends: "[{ style: {} }, { style: { overscrollBehaviorX: 'contain' } }]", deltaX: 12))
        #expect(try !keeps([cell], ends: "[{ style: {} }, { style: {} }]", deltaX: -12))
        // A page that cancels the scrolls itself (Canva) keeps them, whatever scrolls.
        #expect(try keeps([cell], deltaX: -12, prevented: true))
    }

    @Test func swipeScriptKeepsWhatPansWhenPinchedIn() throws {
        // Pinched in to twice the size, the visible half pans across a page no wider than the window (#377).
        let root = "{ scrollWidth: 832, clientWidth: 832, scrollLeft: 0, style: {} }"
        let panned = "{ scale: 2, pageLeft: 200, width: 416 }"
        #expect(try keeps([cell], root: root, view: panned, deltaX: -12))
        #expect(try keeps([cell], root: root, view: panned, deltaX: 12))
        // At its left edge it goes back; at its right edge it goes forward.
        #expect(try !keeps([cell], root: root, view: "{ scale: 2, pageLeft: 0, width: 416 }", deltaX: -12))
        #expect(try !keeps([cell], root: root, view: "{ scale: 2, pageLeft: 416, width: 416 }", deltaX: 12))
        // Not pinched in: the page's own width decides.
        #expect(try !keeps([cell], root: root, view: "{ scale: 1, pageLeft: 0, width: 832 }", deltaX: 12))
    }

    @Test func swipeScriptLeavesAPageAFewPixelsOffAlone() throws {
        // Nudged a pixel or two by a diagonal scroll: back still goes back.
        let nudged = "{ scrollWidth: 1040, clientWidth: 1000, scrollLeft: 3, style: {} }"
        #expect(try !keeps([cell], root: nudged, deltaX: -12))
        // Right to left, at its start on the right, 10 pixels too wide: back goes back, forward too.
        let rtl = "{ scrollWidth: 1010, clientWidth: 1000, scrollLeft: 0, style: { direction: 'rtl' } }"
        #expect(try !keeps([cell], root: rtl, deltaX: -12))
        #expect(try !keeps([cell], root: rtl, deltaX: 12))
        // Scrolled along to its left end, it has room behind it, on the right.
        let rtlAlong = "{ scrollWidth: 1040, clientWidth: 1000, scrollLeft: -40, style: { direction: 'rtl' } }"
        #expect(try keeps([cell], root: rtlAlong, deltaX: 12))
        #expect(try !keeps([cell], root: rtlAlong, deltaX: -12))
        // A really wide one keeps the way it can scroll, either way scrollLeft counts.
        let wide = "{ scrollWidth: 3000, clientWidth: 1000, scrollLeft: 0, style: { direction: 'rtl' } }"
        #expect(try keeps([cell], root: wide, deltaX: -12))
        #expect(try !keeps([cell], root: wide, deltaX: 12))
        let legacy = "{ scrollWidth: 3000, clientWidth: 1000, scrollLeft: 2000, style: { direction: 'rtl' } }"
        #expect(try keeps([cell], root: legacy, deltaX: -12))
        #expect(try !keeps([cell], root: legacy, deltaX: 12))
        // An element right to left, at its start, a few pixels too wide.
        let box = "{ scrollWidth: 810, clientWidth: 800, scrollLeft: 0, style: { overflowX: 'auto', direction: 'rtl' } }"
        #expect(try !keeps([cell, box], deltaX: -12))
    }

    @Test func swipeScriptSkipsAPageThatHidesItsSidewaysScroll() throws {
        // overflow-x: hidden on the root or the body: the page can't be scrolled sideways, so back goes back.
        let along = "{ scrollWidth: 1400, clientWidth: 1000, scrollLeft: 200, style: {} }"
        #expect(try !keeps([cell], root: along, ends: "[{ style: { overflowX: 'hidden' } }, { style: {} }]", deltaX: -12))
        #expect(try !keeps([cell], root: along, ends: "[{ style: {} }, { style: { overflowX: 'hidden' } }]", deltaX: -12))
        #expect(try !keeps([cell], root: along, ends: "[{ style: { overflowX: 'clip' } }, { style: {} }]", deltaX: 12))
        // The body's own overflow doesn't count once the root scrolls itself.
        #expect(try keeps([cell], root: along, ends: "[{ style: { overflowX: 'auto' } }, { style: { overflowX: 'hidden' } }]", deltaX: -12))
        // Pinched in, the visible part still pans.
        let view = "{ scale: 2, pageLeft: 200, width: 500 }"
        #expect(try keeps([cell], root: along, ends: "[{ style: { overflowX: 'hidden' } }, { style: {} }]", view: view, deltaX: -12))
    }

    @Test func aFlickIsMeasuredUpToTheRelease() {
        // 20 points every 8 ms toward back: 2500 points a second.
        let samples: [(time: TimeInterval, dx: CGFloat)] = (0..<8).map { (time: 1 + Double($0) * 0.008, dx: CGFloat($0) * 20) }
        let last = samples[7].time
        #expect(abs(SwipeDecision.speed(samples, at: last, direction: -1) - 2500) < 1)
        #expect(SwipeDecision.speed(samples, at: last, direction: 1) < 0)
        // Fingers that stopped before letting go aren't flicking.
        #expect(SwipeDecision.speed(samples, at: last + SwipeDecision.flickWindow * 2, direction: -1) == 0)
        #expect(SwipeDecision.speed([], at: last, direction: -1) == 0)
    }

    @Test func swipeNeedsAThirdOfThePage() {
        // A third of a narrow page, at most 180 points however wide the window (#377).
        #expect(SwipeDecision.distance(forWidth: 450) == 150)
        #expect(SwipeDecision.distance(forWidth: 900) == 180)
        #expect(SwipeDecision.distance(forWidth: 300) == 120)
        #expect(SwipeDecision.distance(forWidth: 2000) == 180)
        // All the way, or a flick that got started.
        #expect(SwipeDecision.commits(progress: 1, speed: 0))
        #expect(SwipeDecision.commits(progress: 0.5, speed: 1000))
        // Short, slow, or pulled back before letting go: no.
        #expect(!SwipeDecision.commits(progress: 0.2, speed: 2000))
        #expect(!SwipeDecision.commits(progress: 0.9, speed: 0))
        #expect(!SwipeDecision.commits(progress: 0.6, speed: -800))
    }

    /// Taps a swipe would give over these steps of progress, and whether letting go at the end navigates at `speed`.
    private func arm(_ steps: [CGFloat], speed: CGFloat = 0) -> (taps: Int, goes: Bool) {
        var arming = SwipeArming()
        let taps = steps.filter { arming.step(progress: $0) }.count
        return (taps, arming.release(progress: steps.last ?? 0, speed: speed))
    }

    @Test func aFlickHoveringAtTheCutoffTapsOnce() {
        // Speed going either side of 450 points a second, a little further each step: armed once, and it stays.
        var arming = SwipeArming(), taps = 0
        for (index, speed) in [440, 460, 440, 460, 445, 455, 440].enumerated() {
            let progress = 0.35 + CGFloat(index) * 0.02
            if arming.step(progress: progress, flicks: SwipeDecision.commits(progress: progress, speed: CGFloat(speed))) { taps += 1 }
            if index > 0 { #expect(arming.armed) }
        }
        #expect(taps == 1)
        let goes = arming.release(progress: 0.47, speed: 0)
        #expect(goes)
    }

    @Test func aFlickDisarmsOnlyPastTheMarginBack() {
        var arming = SwipeArming()
        let armed = arming.step(progress: 0.5, flicks: true)
        #expect(armed)
        // Back a little, slow: still armed.
        let near = arming.step(progress: 0.4)
        #expect(!near && arming.armed)
        // Past the margin from the furthest: empty, no tap, and letting go doesn't go.
        let past = arming.step(progress: 0.34)
        #expect(!past && !arming.armed)
        let goes = arming.release(progress: 0.34, speed: 0)
        #expect(!goes)
    }

    @Test func swipeTapsOnceAsItArms() {
        // Slow, hovering right at the distance: one tap (#377).
        #expect(arm([0.9, 1.01, 0.98, 1.02, 0.96, 1.0]) == (1, true))
        // Fast past the distance.
        #expect(arm([0.2, 0.45, 0.8, 1.2]) == (1, true))
        // Pulled well back, it disarms, and crossing again is a second tap.
        #expect(arm([1.05, 0.7, 1.05]) == (2, true))
        #expect(arm([1.05, 0.7]) == (1, false))
        // Short of the distance and stopped: no tap, and letting go doesn't navigate.
        #expect(arm([0.2, 0.5, 0.8]) == (0, false))
        // A flick still moving as the fingers lift goes, short of the distance.
        #expect(arm([0.2, 0.5], speed: 900) == (0, true))
        #expect(!arm([0.2, 0.5], speed: -900).goes)
    }

    /// What the arrow shows (ring, filled) after each scroll of `deltas`, one every 8 ms toward back, then at each of
    /// `rest` later moments with no new events, the taps, and whether letting go at the end navigates, as SwipeNavigator
    /// does: each scroll's speed can arm it as a flick, and a moment with no event is only redrawn.
    private func replay(_ deltas: [CGFloat], rest: [TimeInterval], distance: CGFloat = 200)
        -> (shown: [(ring: CGFloat, filled: Bool)], taps: Int, goes: Bool) {
        var arming = SwipeArming(), dx: CGFloat = 0, now: TimeInterval = 1, taps = 0
        var shown: [(ring: CGFloat, filled: Bool)] = []
        var samples: [(time: TimeInterval, dx: CGFloat)] = []
        for delta in deltas {
            now += 0.008
            dx += delta
            samples.append((now, dx))
            let speed = SwipeDecision.speed(samples, at: now, direction: -1)
            let flicks = SwipeDecision.going(samples, direction: -1) && SwipeDecision.commits(progress: dx / distance, speed: speed)
            if arming.step(progress: dx / distance, flicks: flicks) { taps += 1 }
            shown.append((min(dx / distance, 1), arming.armed))
        }
        let last = now
        for wait in rest {
            now = last + wait
            shown.append((min(dx / distance, 1), arming.armed))
        }
        let goes = arming.release(progress: dx / distance, speed: SwipeDecision.speed(samples, at: now, direction: -1))
        return (shown, taps, goes)
    }

    @Test func aFlickArmsAndRestingFingersKeepTheArrowAsItIs() {
        // The tester's swipe: fast to about halfway, a zero-delta scroll or two, then the fingers rest (#377).
        let fast = replay(Array(repeating: 12, count: 9) + [0, 0], rest: [0.05, 0.1, 0.5, 1.5])
        let moved = fast.shown[8]
        // The flick filled it, with one tap, and resting never empties it.
        #expect(moved.filled)
        #expect(fast.taps == 1)
        #expect(fast.shown.dropFirst(8).allSatisfy { $0.ring == moved.ring && $0.filled })
        // Shown filled, let go after resting: it navigates, as the arrow said.
        #expect(fast.goes)
        // Slow to halfway: never filled, and letting go doesn't navigate.
        let slow = replay(Array(repeating: 2, count: 50), rest: [0.5])
        #expect(slow.shown.allSatisfy { !$0.filled })
        #expect(slow.taps == 0 && !slow.goes)
        // Past the distance, then resting: the full ring and fill stay, and letting go goes.
        let far = replay(Array(repeating: 25, count: 9) + [0], rest: [0.05, 0.1, 1.5])
        #expect(far.shown.dropFirst(8).allSatisfy { $0.ring == 1 && $0.filled })
        #expect(far.goes)
        // Only moving back takes them away.
        let back = replay(Array(repeating: 25, count: 9) + [-40, -40, -40], rest: [0.2])
        #expect(back.shown.last.map { !$0.filled && $0.ring < 1 } == true)
        #expect(back.taps == 1)
        #expect(!back.goes)
        // A flick let go while still moving goes, though it never reached the distance.
        #expect(replay(Array(repeating: 12, count: 9), rest: []).goes)
    }

    @Test func swipeScriptLooksPastShadowRoots() throws {
        // A sheet inside a web component: the cell's parent chain goes through the shadow root to its host.
        let context = try #require(JSContext())
        let result = context.evaluateScript("""
        const host = { scrollWidth: 3000, clientWidth: 800, scrollLeft: 300, style: { overflowX: 'auto' }, parentElement: null };
        const cell = { scrollWidth: 80, clientWidth: 80, style: {}, parentElement: null, parentNode: { host } };
        const style = (el) => Object.assign({ overflowX: 'visible', overflowY: 'visible', overscrollBehaviorX: 'auto' }, el.style);
        (\(SwipeAnswers.sideways))(cell, style, null, []).left
        """)
        #expect(context.exception == nil)
        #expect(result?.toBool() == true)
    }

    // MARK: Swiping between spaces

    @Test func swipeFollowsTheFingersAndComesBack() {
        // One to one toward a neighbor, so a small move and back leaves the list where it was.
        #expect(SpaceSwipe.offset(forTravel: 12, width: 300, hasLeft: true, hasRight: true) == 12)
        #expect(SpaceSwipe.offset(forTravel: -40, width: 300, hasLeft: true, hasRight: true) == -40)
        #expect(SpaceSwipe.landing(offset: 12, velocity: 0, width: 300) == 0)
        // Never more than a full width.
        #expect(SpaceSwipe.offset(forTravel: 900, width: 300, hasLeft: true, hasRight: true) == 300)
    }

    @Test func swipeLandsPastAThirdOrOnAFlick() {
        // Moving right brings in the space on the left.
        #expect(SpaceSwipe.landing(offset: 106, velocity: 0, width: 300) == -1)
        #expect(SpaceSwipe.landing(offset: -106, velocity: 0, width: 300) == 1)
        #expect(SpaceSwipe.landing(offset: 104, velocity: 0, width: 300) == 0)
        // A short flick that way lands; flicking back home doesn't, however far it went.
        #expect(SpaceSwipe.landing(offset: -30, velocity: -900, width: 300) == 1)
        #expect(SpaceSwipe.landing(offset: 200, velocity: -900, width: 300) == 0)
    }

    @Test func swipeHoldsBackAtTheEnds() {
        // No space on the left: the list gives less and less, and never past half the width.
        let small = SpaceSwipe.offset(forTravel: 30, width: 300, hasLeft: false, hasRight: true)
        let far = SpaceSwipe.offset(forTravel: 3000, width: 300, hasLeft: false, hasRight: true)
        #expect(small > 0 && small < 30)
        #expect(far > small && far < 150)
        #expect(SpaceSwipe.offset(forTravel: -30, width: 300, hasLeft: true, hasRight: false) == -small)
        // Picking a held-back list up again puts it where it was.
        let travel = SpaceSwipe.travel(toOffset: small, width: 300, hasLeft: false, hasRight: true)
        #expect(abs(travel - 30) < 0.001)
    }

    @Test func swipeSpeedComesFromTheLastMoment() {
        let samples: [(time: TimeInterval, dx: CGFloat)] = [(0, 50), (0.95, 0), (0.96, 10), (0.97, 10), (0.98, 10)]
        #expect(abs(SpaceSwipe.velocity(samples, at: 0.98) - 1000) < 0.001)
        // Fingers that stopped before letting go aren't moving.
        #expect(SpaceSwipe.velocity(samples, at: 2) == 0)
    }

    @Test func errorPagesSayItPlainly() throws {
        let url = try #require(URL(string: "https://example.com:25/"))
        let errors = [NSError(domain: "WebKitErrorDomain", code: 103, userInfo: [NSLocalizedDescriptionKey: "Not allowed to use restricted network port"]),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed),
                      NSError(domain: NSURLErrorDomain, code: -99999, userInfo: [NSLocalizedDescriptionKey: "raw system text"])]
        for error in errors {
            let (title, message) = ErrorPage.describe(error, url: url)
            #expect(!title.isEmpty)
            #expect(message.hasSuffix("."))
            #expect(message != error.localizedDescription)
        }
        // A lookup failure names both likely causes.
        let dns = ErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost), url: url).1
        #expect(dns.contains("internet") && dns.contains("typo"))
    }

    @Test func clearingTheLastHourKeepsOlderPDFPlaces() {
        let now = Date()
        let all: [String: Any] = [
            "old.pdf": [3, now.addingTimeInterval(-7200).timeIntervalSince1970],
            "new.pdf": [5, now.addingTimeInterval(-60).timeIntervalSince1970],
            "untimed.pdf": [7],
        ]
        let kept = PDFViewerView.places(all, readBefore: now.addingTimeInterval(-3600))
        #expect(Set(kept.keys) == ["old.pdf", "untimed.pdf"])
    }

    @Test func certificateProceedNeedsTheNonceAndTheWarnedHost() throws {
        let page = try #require(URL(string: "https://router.local:8443/admin?tab=1"))
        let link = try #require(CertificateExceptions.proceedLink(for: page, nonce: "abc"))
        #expect(link.scheme == CertificateExceptions.scheme)
        // The warning's own link goes back to the page it was for, nonce stripped.
        #expect(CertificateExceptions.destination(of: link, warnedHost: "router.local", nonce: "abc") == page)
        // A made-up link: no nonce, the wrong one, or a host the tab never warned about.
        let bare = try #require(URL(string: "zigzag-proceed://router.local:8443/admin"))
        #expect(CertificateExceptions.destination(of: bare, warnedHost: "router.local", nonce: "abc") == nil)
        #expect(CertificateExceptions.destination(of: link, warnedHost: "router.local", nonce: "xyz") == nil)
        #expect(CertificateExceptions.destination(of: link, warnedHost: "bank.com", nonce: "abc") == nil)
        #expect(CertificateExceptions.destination(of: link, warnedHost: nil, nonce: "abc") == nil)
        let plain = try #require(URL(string: "https://router.local/"))
        let plainLink = try #require(CertificateExceptions.proceedLink(for: plain, nonce: "abc"))
        #expect(CertificateExceptions.destination(of: plainLink, warnedHost: "router.local", nonce: "abc") == plain)
    }

    @Test func buttonNamesLeaveOutTheirShortcut() {
        #expect(IconButton.withoutShortcut("Back (⌘[)") == "Back")
        #expect(IconButton.withoutShortcut("Hide Sidebar (⌥⌘S)") == "Hide Sidebar")
        #expect(IconButton.withoutShortcut("Downloads") == "Downloads")
    }

    @Test func onlyFrontPagesReplaceASitesIcon() throws {
        let artifact = try #require(URL(string: "https://claude.ai/artifact/4TsSgQ42Jkne"))
        // An artifact wears its own icon; once Claude has one, the artifact's never replaces it.
        #expect(!FaviconStore.speaksForSite(artifact, hasIcon: true))
        // With no icon yet, any page's is better than a globe.
        #expect(FaviconStore.speaksForSite(artifact, hasIcon: false))
        // The front page (where claude.ai lands) and the bare host do replace it.
        #expect(FaviconStore.speaksForSite(try #require(URL(string: "https://claude.ai/new")), hasIcon: true))
        #expect(FaviconStore.speaksForSite(try #require(URL(string: "https://github.com")), hasIcon: true))
    }

    @Test func suggestionsStayOnTheMacWhenOff() throws {
        // On: a search is sent to the engine for suggestions.
        #expect(SuggestionFetcher.url(for: "shanghai metro", engine: .google, isOn: true) != nil)
        // Off: nothing is sent, for any engine.
        for engine in SearchEngine.allCases {
            #expect(SuggestionFetcher.url(for: "shanghai metro", engine: engine, isOn: false) == nil)
        }
        // Addresses and single letters never were.
        #expect(SuggestionFetcher.url(for: "github.com", engine: .google, isOn: true) == nil)
        #expect(SuggestionFetcher.url(for: "s", engine: .google, isOn: true) == nil)
    }

    @Test func linkStatusShowsTheWholeAddress() throws {
        let link = try #require(URL(string: "https://www.iana.org/domains/reserved/rfc6761?x=1"))
        #expect(LinkStatusController.describe(link) == "iana.org/domains/reserved/rfc6761?x=1")
        #expect(LinkStatusController.describe(try #require(URL(string: "https://example.com/")))  == "example.com")
        #expect(LinkStatusController.describe(try #require(URL(string: "mailto:a@example.com"))) == "Email a@example.com")
    }

    /// The pill follows the pointer: it shows a link only while the pointer is on one, and a press, a move off the
    /// link, or a scroll clears it (#449).
    @Test func theHoverScriptOnlyShowsALinkUnderThePointer() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var posted = [];
        var listeners = {};
        function listen(name, fn) { listeners[name] = fn; }
        var window = {
          webkit: { messageHandlers: { zigzagHover: { postMessage: function (m) { posted.push(m); } } } },
          addEventListener: listen
        };
        var document = { addEventListener: listen };
        var link = { href: 'https://example.com/a', getAttribute: function () { return null; }, textContent: 'A', closest: function () { return this; } };
        var plain = { closest: function () { return null; } };
        """)
        context.evaluateScript(PageScripts.linkHover)
        #expect(context.exception == nil)
        let result = context.evaluateScript("""
        listeners['mouseover']({ target: link });
        var shows = posted.length === 1 && posted[0].url === 'https://example.com/a';
        listeners['mousedown']({});
        var press = posted[posted.length - 1] === '';
        listeners['mouseover']({ target: link });
        listeners['mousemove']({ target: plain });
        var move = posted[posted.length - 1] === '';
        listeners['mouseover']({ target: link });
        listeners['mouseout']({ relatedTarget: plain });
        var out = posted[posted.length - 1] === '';
        listeners['mouseover']({ target: link });
        listeners['scroll']({});
        var scrolled = posted[posted.length - 1] === '';
        shows && press && move && out && scrolled;
        """)
        #expect(result?.toBool() == true)
    }

    @Test func aCutOffSecureConnectionIsNotCalledAnImpostor() throws {
        let url = try #require(URL(string: "https://example.com/"))
        let cutOff = ErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed), url: url)
        #expect(!cutOff.0.contains("private"))
        let forged = ErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted), url: url)
        #expect(forged.0 == "This connection isn’t private")
    }

    @Test func theEmojiFieldTakesEmojiOfEveryKind() {
        for emoji in ["😀", "❤️", "☀️", "✈️", "✌️", "1️⃣", "👍🏽", "🇯🇵"] {
            #expect(IconGrid.lastEmoji(in: emoji) == emoji)
        }
        // The last one typed.
        #expect(IconGrid.lastEmoji(in: "😀a🚀b") == "🚀")
        // A plain digit, "#" or "*" counts as emoji in Unicode, but isn't one to look at.
        for text in ["abc", "1", "#", "*", "©", ""] {
            #expect(IconGrid.lastEmoji(in: text) == nil)
        }
    }

    @Test func anImportSaysWhichPasswordsItKept() {
        var summary = ImportCoordinator.Summary(source: "Passwords.csv")
        summary.passwords = 2
        summary.keptPasswords = 3
        #expect(summary.sentence == "Imported 2 passwords from Passwords.csv. Kept 3 passwords already in Zigzag instead of the imported ones.")
        summary.passwords = 0
        summary.keptPasswords = 1
        #expect(summary.sentence == "Nothing new to bring over from Passwords.csv. Kept 1 password already in Zigzag instead of the imported one.")
    }
}

/// The backup made when a new version first runs, and the restore that puts one back: in a folder of their
/// own, never the real profile.
struct UpdateBackupTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func backsUpOnceWhenTheBuildChanges() throws {
        let root = try makeRoot()
        let suite = "zigzag-backup-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        // A first run, with no profile yet: nothing to back up, only the build noted.
        UpdateBackup.backUpIfUpdated(build: "18", version: "0.4.0", defaults: defaults, root: root)
        #expect(UpdateBackup.all(in: root).isEmpty)
        try "spaces".write(to: root.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        // The same build again: still nothing.
        UpdateBackup.backUpIfUpdated(build: "18", version: "0.4.0", defaults: defaults, root: root)
        #expect(UpdateBackup.all(in: root).isEmpty)
        // A new build: one backup, named for the version it came from.
        UpdateBackup.backUpIfUpdated(build: "19", version: "0.5.0", defaults: defaults, root: root)
        let backups = UpdateBackup.updates(in: root)
        #expect(backups.count == 1)
        #expect(backups.first?.lastPathComponent.hasSuffix("Z 0.4.0") == true)
        #expect(backups.first.flatMap { read($0.appendingPathComponent("Library.json")) } == "spaces")
        UpdateBackup.backUpIfUpdated(build: "19", version: "0.5.0", defaults: defaults, root: root)
        #expect(UpdateBackup.all(in: root).count == 1)
    }

    /// An empty data folder makes no backup, even after another build ran, so General never offers an empty restore.
    @Test func freshDataIsNeverOfferedAsABackup() throws {
        let root = try makeRoot()
        let suite = "zigzag-backup-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        defaults.set("104", forKey: "LastRunBuild")
        defaults.set("0.9.1", forKey: "LastRunVersion")
        UpdateBackup.backUpIfUpdated(build: "105", version: "0.9.1", defaults: defaults, root: root)
        #expect(UpdateBackup.all(in: root).isEmpty)
        #expect(defaults.string(forKey: "LastRunBuild") == "105")
        // Nor empty backups from earlier versions.
        let folder = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("2026-11-15T02-00-00Z 0.9.1"), withIntermediateDirectories: true)
        #expect(UpdateBackup.restorable(in: root) == nil)
        let real = folder.appendingPathComponent("2026-11-14T02-00-00Z 0.9.0")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "spaces".write(to: real.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        #expect(UpdateBackup.restorable(in: root)?.lastPathComponent == real.lastPathComponent)
    }

    @Test func namesSortByTimeAcrossTheOldAndNewStamps() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Backups", isDirectory: true)
        let names = ["2026-10-01T10-00-00 0.3.0", "2026-10-03T08-00-00Z 0.5.0 before restore", "2026-10-02T09-00-00Z 0.4.0"]
        for name in names { try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true) }
        #expect(UpdateBackup.all(in: root).map(\.lastPathComponent) == [names[1], names[2], names[0]])
        // A restore puts back an update's backup, never the one made just before a restore.
        #expect(UpdateBackup.updates(in: root).map(\.lastPathComponent) == [names[2], names[0]])
        #expect(UpdateBackup.date(of: names[2]) == ISO8601DateFormatter().date(from: "2026-10-02T09:00:00Z"))
        #expect(UpdateBackup.date(of: "not a backup") == nil)
    }

    /// A backup from before there were profiles has no Profiles.json: putting it back leaves the one there is, so
    /// spaces stay on their profiles.
    /// The restore marker names a backup folder; paths escaping Backups are ignored.
    @Test func restoreRefusesAPathOutOfTheBackups() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "now".write(to: root.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "planted".write(to: elsewhere.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "../Elsewhere".write(to: folder.appendingPathComponent("Restore"), atomically: true, encoding: .utf8)

        UpdateBackup.restoreIfAsked(root: root)

        #expect(read(root.appendingPathComponent("Library.json")) == "now")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Restore").path))
        #expect(UpdateBackup.isBackupName("2026-10-02T09-00-00Z 0.4.0"))
        for name in ["", ".", "..", "../Elsewhere", "2026-10-02T09-00-00Z 0.4.0/../../x", "/tmp/x", ".hidden"] {
            #expect(!UpdateBackup.isBackupName(name))
        }
    }

    @Test func restoreLeavesProfilesWhenTheBackupHasNone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "now".write(to: root.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        try "profiles now".write(to: root.appendingPathComponent("Profiles.json"), atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("Backups", isDirectory: true)
        let old = "2026-10-02T09-00-00Z 0.4.0"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(old), withIntermediateDirectories: true)
        try "then".write(to: folder.appendingPathComponent(old).appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        try old.write(to: folder.appendingPathComponent("Restore"), atomically: true, encoding: .utf8)

        UpdateBackup.restoreIfAsked(root: root)

        #expect(read(root.appendingPathComponent("Library.json")) == "then")
        #expect(read(root.appendingPathComponent("Profiles.json")) == "profiles now")
    }

    @Test func restorePutsBackTheProfilesABackupHas() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "now".write(to: root.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        try "profiles now".write(to: root.appendingPathComponent("Profiles.json"), atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("Backups", isDirectory: true)
        let newer = "2026-11-02T09-00-00Z 0.8.0"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(newer), withIntermediateDirectories: true)
        try "later".write(to: folder.appendingPathComponent(newer).appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        try "profiles then".write(to: folder.appendingPathComponent(newer).appendingPathComponent("Profiles.json"), atomically: true, encoding: .utf8)
        try newer.write(to: folder.appendingPathComponent("Restore"), atomically: true, encoding: .utf8)

        UpdateBackup.restoreIfAsked(root: root)

        #expect(read(root.appendingPathComponent("Profiles.json")) == "profiles then")
    }

    /// Each profile's history is backed up in its own folder, put back with the rest, and goes from the backups
    /// when its profile is removed.
    @Test func otherProfilesHistoriesAreBackedUpRestoredAndForgotten() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let kept = UUID(), made = UUID()
        func history(_ id: UUID, in base: URL) -> URL { base.appendingPathComponent("Profiles/\(id.uuidString)/History.sqlite") }
        try "library".write(to: root.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        try "profiles".write(to: root.appendingPathComponent("Profiles.json"), atomically: true, encoding: .utf8)
        try manager.createDirectory(at: history(kept, in: root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try "then".write(to: history(kept, in: root), atomically: true, encoding: .utf8)

        let backup = try #require(UpdateBackup.make(from: "0.9.0", in: root))
        #expect(read(history(kept, in: backup)) == "then")

        // Since the backup: more history in that profile, and a profile the backup has never heard of.
        try "now".write(to: history(kept, in: root), atomically: true, encoding: .utf8)
        try manager.createDirectory(at: history(made, in: root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try "new".write(to: history(made, in: root), atomically: true, encoding: .utf8)
        try backup.lastPathComponent.write(to: root.appendingPathComponent("Backups/Restore"), atomically: true, encoding: .utf8)
        UpdateBackup.restoreIfAsked(root: root)

        #expect(read(history(kept, in: root)) == "then")
        #expect(!manager.fileExists(atPath: history(made, in: root).path))
        let before = try #require(UpdateBackup.all(in: root).first { $0.lastPathComponent.hasSuffix("before restore") })
        #expect(read(history(kept, in: before)) == "now")
        #expect(read(history(made, in: before)) == "new")
        let leftovers = try manager.contentsOfDirectory(atPath: history(kept, in: root).deletingLastPathComponent().path).filter { $0.hasSuffix(".restoring") }
        #expect(leftovers.isEmpty)

        UpdateBackup.forget(profile: kept, in: root)
        #expect(!manager.fileExists(atPath: history(kept, in: backup).path))
        #expect(!manager.fileExists(atPath: history(kept, in: before).path))
        #expect(read(history(made, in: before)) == "new")
    }

    /// A removed profile is taken out of each backup's own lists too, with its favorites: a restore can't bring
    /// back what the removal said was gone.
    @Test func aRemovedProfileGoesFromABackupsLists() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var directory = ProfileDirectory()
        let gone = directory.add(name: "Gone"), kept = directory.add(name: "Kept")
        let space = UUID(), keptSpace = UUID(), favorite = UUID(), keptFavorite = UUID(), firstFavorite = UUID()
        directory.assign(space: space, to: gone.id)
        directory.assign(space: keptSpace, to: kept.id)
        directory.assign(favorite: favorite, to: gone.id)
        directory.assign(favorite: keptFavorite, to: kept.id)
        try JSONEncoder().encode(directory).write(to: root.appendingPathComponent("Profiles.json"))
        let library: [String: Any] = ["spaces": [], "searchEngine": "google",
                                      "favorites": [favorite, keptFavorite, firstFavorite].map { ["id": $0.uuidString, "url": "https://example.com/", "title": ""] },
                                      "favoriteSplits": [["left": favorite.uuidString, "right": firstFavorite.uuidString]]]
        try JSONSerialization.data(withJSONObject: library).write(to: root.appendingPathComponent("Library.json"))
        let backup = try #require(UpdateBackup.make(from: "0.9.0", in: root))

        UpdateBackup.forget(profile: gone.id, in: root)

        let read = try JSONDecoder().decode(ProfileDirectory.self, from: Data(contentsOf: backup.appendingPathComponent("Profiles.json")))
        #expect(read.all.map(\.id) == [Profile.defaultID, kept.id])
        #expect(read.profileID(ofSpace: space) == Profile.defaultID && read.profileID(ofSpace: keptSpace) == kept.id)
        #expect(read.assignments.favorites == [keptFavorite.uuidString: kept.id])
        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: backup.appendingPathComponent("Library.json"))) as? [String: Any])
        #expect((after["favorites"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [keptFavorite.uuidString, firstFavorite.uuidString])
        #expect((after["favoriteSplits"] as? [[String: Any]])?.isEmpty == true)
        // What's in use now is untouched.
        let live = try JSONDecoder().decode(ProfileDirectory.self, from: Data(contentsOf: root.appendingPathComponent("Profiles.json")))
        #expect(live == directory)
    }

    /// A backup from before profiles says nothing of the other profiles' histories: they stay.
    @Test func restoreLeavesOtherProfilesHistoriesWhenTheBackupHasNoProfiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let history = root.appendingPathComponent("Profiles/\(id.uuidString)/History.sqlite")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "kept".write(to: history, atomically: true, encoding: .utf8)
        try "now".write(to: root.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("Backups", isDirectory: true)
        let old = "2026-10-02T09-00-00Z 0.4.0"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(old), withIntermediateDirectories: true)
        try "then".write(to: folder.appendingPathComponent(old).appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        try old.write(to: folder.appendingPathComponent("Restore"), atomically: true, encoding: .utf8)

        UpdateBackup.restoreIfAsked(root: root)

        #expect(read(root.appendingPathComponent("Library.json")) == "then")
        #expect(read(history) == "kept")
    }

    @Test func restoreKeepsWhatWasThereAndSwapsWholeFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "now".write(to: root.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        try "journal".write(to: root.appendingPathComponent("History.sqlite-wal"), atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("Backups", isDirectory: true)
        let name = "2026-10-02T09-00-00Z 0.4.0"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        try "then".write(to: folder.appendingPathComponent(name).appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        try name.write(to: folder.appendingPathComponent("Restore"), atomically: true, encoding: .utf8)

        UpdateBackup.restoreIfAsked(root: root)

        #expect(read(root.appendingPathComponent("Library.json")) == "then")
        // The journal didn't come with the backup, so it no longer belongs.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("History.sqlite-wal").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Restore").path))
        // What was there is kept, so the restore can be undone.
        let before = try #require(UpdateBackup.all(in: root).first { $0.lastPathComponent.hasSuffix("before restore") })
        #expect(read(before.appendingPathComponent("Library.json")) == "now")
        #expect(read(before.appendingPathComponent("History.sqlite-wal")) == "journal")
        // Nothing staged is left lying around.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".restoring") }
        #expect(leftovers.isEmpty)
    }

    /// release.sh replaces the beta feed only once the stable version has caught up with its betas.
    @Test func versionComparisonIsNumeric() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/version-at-least.sh")
        func atLeast(_ a: String, _ b: String) throws -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path, a, b]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        #expect(try atLeast("0.5.0", "0.5.0"))
        #expect(try atLeast("0.10.0", "0.9.2"))
        #expect(try atLeast("0.5", "0.5.0"))
        #expect(try atLeast("1.0", "0.99.99"))
        #expect(try !atLeast("0.4.9", "0.5.0"))
        #expect(try !atLeast("0.5.0", "0.5.1"))
    }
}

/// A link Zigzag hands to macOS comes back as its own, so it opens in a tab rather than Zigzag Mini.
@MainActor
struct LinksFromZigzagTests {
    @Test func onlyZigzagsOwnLinksCountAsItsOwn() {
        #expect(AppDelegate.isZigzag(senderPID: ProcessInfo.processInfo.processIdentifier))
        #expect(!AppDelegate.isZigzag(senderPID: 1))
        #expect(!AppDelegate.isZigzag(senderPID: nil))
    }
}

/// A long site name keeps the end that says whose site it is, the same way in the address and Site Controls.
@MainActor
struct SiteNameShorteningTests {
    @Test func subdomainsGoFirstAndADomainKeepsItsEnds() {
        #expect(AddressView.lineBreak(forName: "physicsandmathstutor.com") == .byTruncatingMiddle)
        #expect(AddressView.lineBreak(forName: "www.physicsandmathstutor.com") == .byTruncatingHead)
        #expect(AddressView.lineBreak(forName: "paypal.com.secure-login.example.co.uk") == .byTruncatingHead)
        #expect(AddressView.lineBreak(forName: "example.co.uk") == .byTruncatingMiddle)
        #expect(AddressView.lineBreak(forName: "Settings") == .byTruncatingTail)
    }
}

/// ⌥⌘ and nothing else moves the window from the page, so ⌘-clicks and other shortcuts still reach it.
@MainActor
struct MoveWindowChordTests {
    @Test func onlyOptionCommandMovesTheWindow() {
        #expect(BrowserWindow.isMoveChord([.command, .option]))
        #expect(BrowserWindow.isMoveChord([.command, .option, .capsLock, .function]))
        #expect(!BrowserWindow.isMoveChord([.command]))
        #expect(!BrowserWindow.isMoveChord([.option]))
        #expect(!BrowserWindow.isMoveChord([.command, .option, .shift]))
        #expect(!BrowserWindow.isMoveChord([.command, .option, .control]))
    }
}

/// Text typed into a page stays as typed: `--` never becomes `—`, so GitHub's upload placeholders survive.
@MainActor
struct PageTextSubstitutionTests {
    @Test func dashesAndQuotesStayAsTyped() async throws {
        UserDefaults.standard.register(defaults: AppDelegate.pageTextDefaults)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        webView.loadHTMLString("<textarea id=t></textarea>", baseURL: URL(string: "https://example.com"))
        for _ in 0..<100 where webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        window.makeFirstResponder(webView)
        let typed = #"<!-- Uploading "a.png"... --> and "quotes""#
        let value = try await webView.evaluateJavaScript("""
            (() => { const t = document.getElementById('t'); t.focus(); document.execCommand('insertText', false, \(String(reflecting: typed))); return t.value })()
            """) as? String
        #expect(value == typed)
    }

    @Test func yourOwnTextReplacementsStillApply() {
        #expect(AppDelegate.pageTextDefaults["WebAutomaticTextReplacementEnabled"] as? Bool == true)
    }
}

/// Spelling and substitution changes in one page apply to every open page (#296).
@MainActor
struct PageTextCheckingTests {
    private func page(_ site: String) async throws -> (WKWebView, NSWindow) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        webView.loadHTMLString("<textarea id=t></textarea>", baseURL: URL(string: site))
        for _ in 0..<100 where webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        return (webView, window)
    }

    private func type(_ text: String, in webView: WKWebView, window: NSWindow) async throws -> String? {
        window.makeFirstResponder(webView)
        return try await webView.evaluateJavaScript("""
            (() => { const t = document.getElementById('t'); t.value = ''; t.focus(); for (const c of \(String(reflecting: text))) document.execCommand('insertText', false, c); return t.value })()
            """) as? String
    }

    @Test func aChoiceInOnePageReachesTheOthers() async throws {
        UserDefaults.standard.register(defaults: AppDelegate.pageTextDefaults)
        let key = "WebAutomaticDashSubstitutionEnabled"
        let domain = Bundle.main.bundleIdentifier ?? ""
        let saved = UserDefaults.standard.persistentDomain(forName: domain)?[key]
        let (first, firstWindow) = try await page("https://example.com")
        let (second, secondWindow) = try await page("https://example.org")
        first.perform(#selector(NSTextView.toggleAutomaticDashSubstitution(_:)), with: nil)
        let on = UserDefaults.standard.bool(forKey: key)
        let expected = on ? "a — b" : "a -- b"
        let inFirst = try await type("a -- b", in: first, window: firstWindow)
        let inSecond = try await type("a -- b", in: second, window: secondWindow)
        first.perform(#selector(NSTextView.toggleAutomaticDashSubstitution(_:)), with: nil)
        if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        #expect(inFirst == expected)
        #expect(inSecond == expected)
    }

    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "PageTextCheckingTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func correctingFollowsTheMacUntilYouChoose() {
        // Registered defaults are app-wide, so only the system value is used here.
        let mac = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(registered[PageTextChecking.spellingCorrectionKey] as? Bool == mac)
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let checking = PageTextChecking(defaults: defaults, center: NotificationCenter(), systemCorrects: { mac })
        checking.start()
        #expect(defaults.bool(forKey: PageTextChecking.spellingCorrectionKey) == mac)
        // A user choice overrides the system's.
        defaults.set(!mac, forKey: PageTextChecking.spellingCorrectionKey)
        checking.followSystem()
        #expect(defaults.bool(forKey: PageTextChecking.spellingCorrectionKey) == !mac)
    }

    @Test func aChangedChoiceIsSentToThePagesOnce() async throws {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        // The notification UserDefaults posts on change.
        let center = NotificationCenter.default
        var posted = 0
        let watch = center.addObserver(forName: NSSpellChecker.didChangeAutomaticSpellingCorrectionNotification, object: nil, queue: nil) { _ in posted += 1 }
        defer { center.removeObserver(watch) }
        // A choice of this suite's own, above the Mac's setting, so the last change below always counts as one.
        defaults.set(true, forKey: PageTextChecking.spellingCorrectionKey)
        let checking = PageTextChecking(defaults: defaults, center: center, systemCorrects: { true })
        checking.start()
        func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }
        defaults.set(true, forKey: "WebAutomaticDashSubstitutionEnabled")
        try await settle()
        #expect(checking.sent == 1)
        #expect(posted >= 1)
        defaults.set(true, forKey: "WebAutomaticDashSubstitutionEnabled")
        defaults.set("x", forKey: "SomethingElse")
        try await settle()
        #expect(checking.sent == 1)
        defaults.set(false, forKey: "WebContinuousSpellCheckingEnabled")
        try await settle()
        defaults.set(false, forKey: PageTextChecking.spellingCorrectionKey)
        try await settle()
        #expect(checking.sent == 3)
        #expect(posted >= 3)
    }

    @Test func zigzagsOwnFieldsKeepTheirChoices() {
        let field = MultilineField(text: "")
        func textView(in view: NSView) -> NSTextView? {
            if let found = view as? NSTextView { return found }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        NotificationCenter.default.post(name: NSSpellChecker.didChangeAutomaticSpellingCorrectionNotification, object: nil)
        let view = textView(in: field)
        #expect(view != nil)
        #expect(view?.isAutomaticSpellingCorrectionEnabled == false)
        #expect(view?.isAutomaticQuoteSubstitutionEnabled == false)
    }
}

/// Every control's menu reaches the keyboard and VoiceOver, not only the mouse.
@MainActor
struct ControlMenuTests {
    private func rightClick() -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    @Test func aSpaceRowInSettingsOffersItsMenuEverywhere() {
        let row = SpaceSettingsRow(space: SpaceInfo(name: "Work", color: .sky))
        #expect(row.offersMenu)
        #expect(row.isAccessibilitySelectorAllowed(#selector(NSView.accessibilityPerformShowMenu)))
        let edit = String(localized: "Edit Space…", comment: "Item in the menu of a space's row in Settings › Spaces.")
        // A right-click finds the same menu.
        #expect(row.menu(for: rightClick())?.items.first?.title == edit)
    }

    @Test func reorderMenuMovesOnePlaceAndOmitsUnavailableDirections() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let order = [a, b, c, d]
        let up = String(localized: "Move Up", comment: "Move a row one place up in Settings.")
        let down = String(localized: "Move Down", comment: "Move a row one place down in Settings.")
        var destinations: [UUID?] = []
        func menu(_ id: UUID, in ids: [UUID]) -> NSMenu {
            let menu = NSMenu()
            SiteRouteReorderMenu.addMoves(to: menu, for: id, in: ids) { destinations.append($0) }
            return menu
        }
        #expect(menu(a, in: [a]).items.isEmpty)
        #expect(menu(UUID(), in: order).items.isEmpty)
        let first = menu(a, in: order), middle = menu(b, in: order), last = menu(d, in: order)
        #expect(first.items.map(\.title) == [down])
        #expect(middle.items.map(\.title) == [up, down])
        #expect(last.items.map(\.title) == [up])
        first.performActionForItem(at: 0)
        middle.performActionForItem(at: 0)
        middle.performActionForItem(at: 1)
        menu(c, in: order).performActionForItem(at: 1)
        last.performActionForItem(at: 0)
        #expect(destinations == [c, a, d, nil, c])
    }

    @Test func aControlWithoutAMenuOffersNone() {
        let button = IconButton(symbol: "trash", toolTip: "Delete")
        #expect(!button.offersMenu)
        #expect(!button.isAccessibilitySelectorAllowed(#selector(NSView.accessibilityPerformShowMenu)))
        #expect(button.menu(for: rightClick()) == nil)
    }
}

/// Your Zigzag Card: when you started, kept once and never moved; the beta line; the saved picture's size.
@MainActor
@Suite(.serialized)
struct ZigzagCardTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func withDefaults(_ body: (URL) throws -> Void) throws {
        let name = "ZigzagCardTests-\(UUID().uuidString)"
        let saved = CardStart.defaults
        CardStart.defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-card-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            CardStart.defaults.removePersistentDomain(forName: name)
            CardStart.defaults = saved
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    @Test func aFreshInstallKeepsThisVersionExactly() {
        let record = CardStart.choose(now: now, version: "0.9.4", dates: [now - 30], lastRun: nil, backups: [], launches: 0)
        #expect(record == CardStart.Record(date: now - 30, version: "0.9.4", isExact: true))
    }

    /// Used before the card existed: the earliest date on disk, and the earliest version on record, said as such.
    @Test func anEarlierInstallTakesTheEarliestItKnows() {
        let folder = now - 40 * day, backup = now - 20 * day
        let record = CardStart.choose(now: now, version: "0.9.4", dates: [backup, folder, now - day], lastRun: "0.9.3",
                                      backups: ["0.9.0-beta.1", "0.8.7"], launches: 12)
        #expect(record == CardStart.Record(date: folder, version: "0.8.7", isExact: false))
        // Nothing on record but this version: this version, still not claimed as the first.
        let only = CardStart.choose(now: now, version: "0.9.4", dates: [folder], lastRun: nil, backups: [], launches: 0)
        #expect(only == CardStart.Record(date: folder, version: "0.9.4", isExact: false))
    }

    /// A date from before Zigzag existed, or from the future, is a copied or odd file, never a start.
    @Test func impossibleDatesAreIgnored() {
        let record = CardStart.choose(now: now, version: "0.9.4", dates: [Date(timeIntervalSince1970: 0), now + day], lastRun: nil,
                                      backups: [], launches: 0)
        #expect(record.date == now)
        #expect(record.isExact)
    }

    /// The data folder's creation date and an update backup's date both count, and the kept start never moves.
    @Test func theStartIsReadFromDiskOnceAndKept() throws {
        try withDefaults { root in
            let made = now - 30 * day
            try FileManager.default.setAttributes([.creationDate: made], ofItemAtPath: root.path)
            let backups = root.appendingPathComponent("Backups/2026-11-01T09-00-00Z 0.9.1", isDirectory: true)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let first = CardStart.settle(now: now, version: "0.9.4", root: root)
            #expect(first == CardStart.Record(date: made, version: "0.9.1", isExact: false))
            #expect(CardStart.defaults.object(forKey: CardStart.dateKey) as? Date == made)
            // Later, with newer data and another version: still the same start.
            try FileManager.default.setAttributes([.creationDate: now - 90 * day], ofItemAtPath: root.path)
            #expect(CardStart.settle(now: now + 10 * day, version: "1.0.0", root: root) == first)
            #expect(CardStart.stored == first)
        }
    }

    @Test func theBackupsDateCountsWhenItsEarliest() throws {
        try withDefaults { root in
            try FileManager.default.setAttributes([.creationDate: now - day], ofItemAtPath: root.path)
            let backups = root.appendingPathComponent("Backups/2026-10-30T09-00-00Z 0.9.0", isDirectory: true)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let record = CardStart.settle(now: now, version: "0.9.4", root: root)
            #expect(record.date == UpdateBackup.date(of: "2026-10-30T09-00-00Z"))
            #expect(record.version == "0.9.0")
        }
    }

    @Test func betaIsEverythingBeforeOnePointOh() {
        #expect(CardStart.isBeta("0.9.4"))
        #expect(CardStart.isBeta("0.1.3"))
        #expect(CardStart.isBeta("0.9.2-beta.1"))
        #expect(!CardStart.isBeta("1.0"))
        #expect(!CardStart.isBeta("1.0.0-beta.2"))
        #expect(!CardStart.isBeta("2.1.0"))
        #expect(!CardStart.isBeta(""))
        let face = CardFace(name: "", start: now, version: "1.0.0", isExact: true, day: 1)
    }

    @Test func versionsCompareAsReleasesDo() {
        #expect(CardStart.isEarlier("0.9.2-beta.1", than: "0.9.2"))
        #expect(CardStart.isEarlier("0.9.2", than: "0.10.0"))
        #expect(CardStart.isEarlier("0.9.2-beta.1", than: "0.9.2-beta.2"))
        #expect(!CardStart.isEarlier("0.9.2", than: "0.9.2"))
        #expect(!CardStart.isEarlier("1.0", than: "0.9.9"))
    }

    @Test func daysCountFromOne() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(CardFace.day(from: now, to: now, calendar: calendar) == 1)
        #expect(CardFace.day(from: now - 13 * day, to: now, calendar: calendar) == 14)
        // A clock set back never reads below Day 1.
        #expect(CardFace.day(from: now + 3 * day, to: now, calendar: calendar) == 1)
    }

    /// The finish picked under the card is kept, and an unknown one reads as Space.
    @Test func theFinishIsKept() throws {
        let name = "ZigzagCardFinish-\(UUID().uuidString)"
        let saved = CardFinish.defaults
        CardFinish.defaults = try #require(UserDefaults(suiteName: name))
        defer {
            CardFinish.defaults.removePersistentDomain(forName: name)
            CardFinish.defaults = saved
        }
        #expect(CardFinish.chosen == .space)
        for finish in CardFinish.allCases {
            CardFinish.chosen = finish
            #expect(CardFinish.chosen == finish)
            #expect(CardFinish.defaults.string(forKey: CardFinish.key) == finish.rawValue)
        }
        CardFinish.defaults.set("chrome", forKey: CardFinish.key)
        #expect(CardFinish.chosen == .space)
    }

    /// The saved picture is a 2400 × 1500 scene, solid to its edges on a ground of the card's finish, with the card
    /// about six tenths of its width in the middle and its own round corners, in every finish, by day and at night.
    @Test func theSavedPictureIsASixteenByTenScene() throws {
        let face = CardFace(name: "Ada Lovelace", start: now, version: "0.9.4", isExact: true, day: 14)
        let k = Tokens.Keepsake.self
        for finish in CardFinish.allCases {
            for dark in [false, true] {
                let data = try #require(CardArt.png(face, finish: finish, palette: CardPalette(hue: 0.6, hue2: nil), dark: dark))
                let rep = try #require(NSBitmapImageRep(data: data))
                #expect(rep.pixelsWide == 2400 && rep.pixelsHigh == 1500, "\(finish)")
                #expect(rep.size == k.exportScene)
                for (x, y) in [(0, 0), (rep.pixelsWide - 1, rep.pixelsHigh - 1), (rep.pixelsWide / 2, rep.pixelsHigh / 2)] {
                    #expect(rep.colorAt(x: x, y: y)?.alphaComponent == 1, "\(finish) \(x),\(y)")
                }
                let card = k.size.width * k.exportGrow / k.exportScene.width
                #expect(card > 0.55 && card < 0.65)
                // Just inside the card's top left corner is the ground, not the card: its corner is round.
                let width = k.size.width * k.exportGrow * k.exportScale, height = k.size.height * k.exportGrow * k.exportScale
                let left = Int((CGFloat(rep.pixelsWide) - width) / 2), top = Int((CGFloat(rep.pixelsHigh) - height) / 2) - Int(4 * k.exportScale)
                let corner = try #require(rep.colorAt(x: left + 3, y: top + 3)?.usingColorSpace(.sRGB))
                let ground = try #require(rep.colorAt(x: left - 6, y: top - 6)?.usingColorSpace(.sRGB))
                #expect(abs(corner.redComponent - ground.redComponent) < 0.05, "\(finish) dark: \(dark)")
            }
        }
    }

    /// "Since" gives the month and year, the month in the form a date uses in languages that change it.
    @Test func sinceGivesTheMonthAndYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12)))
        #expect(CardFace.monthAndYear(date, locale: Locale(identifier: "en_US")) == "November 2026")
        #expect(CardFace.monthAndYear(date, locale: Locale(identifier: "ru")).hasPrefix("ноября 2026"))
        #expect(CardFace.monthAndYear(date, locale: Locale(identifier: "pl")) == "listopada 2026")
        #expect(CardFace.monthAndYear(date, locale: Locale(identifier: "zh_Hans")) == "2026年11月")
    }

    /// A long name gets smaller to fit on one line, down to a floor; a short one keeps the full size.
    @Test func aLongNameShrinksToFit() {
        let k = Tokens.Keepsake.self
        #expect(CardArt.nameSize(for: "Ada Lovelace") == k.nameSize)
        let long = CardArt.nameSize(for: "Augusta Ada King, Countess of Lovelace")
        #expect(long < k.nameSize && long >= k.nameSmallest)
        #expect(CardArt.nameSize(for: String(repeating: "W", count: 80)) == k.nameSmallest)
    }

    /// The pressed Z sits inside the margins, on the bottom and right ones, clear of the wordmark.
    @Test func theZSitsOnTheMargins() {
        let k = Tokens.Keepsake.self
        let ink = CardArt.emblemPath().boundingBoxOfPath
        #expect(abs(ink.maxX - (k.size.width - k.pad)) < 0.5)
        #expect(abs(ink.maxY - (k.size.height - k.pad)) < 0.5)
        #expect(!ink.intersects(CardArt.markRect(.front)))
    }

    /// "Since" reads at AA and the name well above it on every finish, by day and at night, wherever the light is.
    @Test func theWordsReadOnEveryFinish() throws {
        let face = CardFace(name: "Ada Lovelace", start: now, version: "0.9.4", isExact: true, day: 14)
        let rects = CardArt.wordRects()
        let lights = [CardLight.rest] + [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1), CGPoint(x: 1, y: -1), .zero]
            .map(CardLight.init(point:))
        for finish in CardFinish.allCases {
            for dark in [false, true] {
                let look = CardLook.of(finish, palette: CardPalette(hue: 0.6, hue2: nil), dark: dark)
                for light in lights {
                    let image = try #require(CardArt.image(face, look: look, light: light, parts: [.surface, .light], scale: 1))
                    let rep = NSBitmapImageRep(cgImage: image)
                    var worst = (ink: Double.infinity, quiet: Double.infinity)
                    for (rect, quiet) in [(rects.name, false), (rects.since, true)] {
                        // The ground as an eye reads it behind a letter: averaged over a few points, past the grain.
                        let cell = 6
                        for x in stride(from: Int(rect.minX), to: Int(min(rect.maxX, rect.minX + 200)) - cell, by: cell) {
                            for y in stride(from: Int(rect.minY), to: Int(rect.maxY) - cell, by: cell) {
                                var sum = (r: 0.0, g: 0.0, b: 0.0)
                                for i in 0..<cell { for j in 0..<cell {
                                    guard let c = rep.colorAt(x: x + i, y: y + j)?.usingColorSpace(.sRGB) else { continue }
                                    sum = (sum.r + c.redComponent, sum.g + c.greenComponent, sum.b + c.blueComponent)
                                } }
                                let n = Double(cell * cell)
                                let ground = NSColor(srgbRed: sum.r / n, green: sum.g / n, blue: sum.b / n, alpha: 1)
                                let color = (quiet ? look.quiet : look.ink).usingColorSpace(.sRGB)!
                                let contrast = Brand.contrast(color, ground)
                                if quiet { worst.quiet = min(worst.quiet, contrast) } else { worst.ink = min(worst.ink, contrast) }
                            }
                        }
                    }
                    #expect(worst.ink >= 5.5, "\(finish) dark: \(dark) \(light.point) ink \(worst.ink)")
                    #expect(worst.quiet >= 4.5, "\(finish) dark: \(dark) \(light.point) quiet \(worst.quiet)")
                }
            }
        }
    }

    /// The quiet lines read at AA on both ends of the face, in every curated hue, by day and at night.
    @Test func theWordsReadOnEveryColor() throws {
        for color in SpaceColor.allCases {
            let palette = CardPalette(hue: color.hue, hue2: nil)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                    for ground in [palette.top, palette.bottom] {
                        let g = ground.usingColorSpace(.sRGB)!
                        #expect(Brand.contrast(palette.quiet.usingColorSpace(.sRGB)!, g) >= 4.5, "\(color) \(name.rawValue)")
                        #expect(Brand.contrast(palette.ink.usingColorSpace(.sRGB)!, g) >= 7, "\(color) \(name.rawValue)")
                    }
                }
            }
        }
    }

    @Test func theChosenFinishHasTheAccentRingAsReadersColorsDo() throws {
        let swatches = CardFinishSwatches(selected: .graphite, palette: CardPalette(hue: Brand.navyHue, hue2: nil))
        swatches.frame = NSRect(origin: .zero, size: swatches.fittingSize)
        swatches.layoutSubtreeIfNeeded()
        let tiles = swatches.subviews.filter { !($0 is NSTextField) }
        #expect(tiles.count == CardFinish.allCases.count)
        // The chosen finish is named beside the swatches, and each swatch names its own for VoiceOver and the pointer.
        let name = try #require(swatches.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(name.stringValue == CardFinish.graphite.name)
        for (tile, finish) in zip(tiles, CardFinish.allCases) {
            #expect(tile.accessibilityLabel() == finish.name)
            #expect(tile.toolTip == finish.name)
            tile.layout()
            let ring = try #require(tile.layer?.sublayers?.first)
            var accent: CGColor?
            tile.effectiveAppearance.performAsCurrentDrawingAppearance { accent = Tokens.Color.accent.cgColor }
            if finish == .graphite {
                #expect(ring.borderColor == accent)
            } else {
                #expect(ring.borderColor != accent)
            }
        }
    }
}

/// A swipe that went back or forward carries the page on until the next one arrives; one called off springs back (#508).
@MainActor
@Suite(.serialized)
struct SwipeExitTests {
    private final class Host: NSWindowController, SwipeArrowHost {
        let swipeArrowLayer = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    /// A page in a window that shows the arrow, swiped `dx` points toward back.
    private func swiping(dx: CGFloat) -> (BrowserWebView, Host) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let host = Host(window: window)
        let page = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        page.wantsLayer = true
        window.contentView?.addSubview(page)
        window.contentView?.addSubview(host.swipeArrowLayer)
        page.swipeNavigator.touchBegan(direction: -1)
        page.swipeNavigator.touchMoved(dx: dx, at: 1)
        return (page, host)
    }

    private func offset(_ page: BrowserWebView) -> CGFloat { page.layer?.affineTransform().tx ?? 0 }

    @Test func goingCarriesThePageOnUntilTheNextArrives() {
        #expect(SwipeExit.offset(from: 50, direction: -1) == 50 + SwipeExit.travel)
        #expect(SwipeExit.offset(from: -50, direction: 1) == -50 - SwipeExit.travel)
        let (page, host) = swiping(dx: 150)
        let held = offset(page)
        #expect(held > 0)
        page.swipeNavigator.touchEnded(at: 1.05, cancelled: false)
        // Not settled: further the swipe's way, dimmed.
        #expect(page.swipeNavigator.isCarryingOn)
        #expect(abs(offset(page) - (held + SwipeExit.travel)) < 0.5)
        #expect(page.layer?.opacity == SwipeExit.dim)
        // The next page arrives: in place at once.
        page.swipeNavigator.pageArrived()
        #expect(!page.swipeNavigator.isCarryingOn)
        #expect(offset(page) == 0 && page.layer?.opacity == 1)
        #expect(page.layer?.animation(forKey: "swipe.settle") == nil)
        _ = host
    }

    @Test func aPageThatNeverArrivesStillGoesBackInPlace() async throws {
        let (page, host) = swiping(dx: 150)
        page.swipeNavigator.touchEnded(at: 1.05, cancelled: false)
        #expect(page.swipeNavigator.isCarryingOn)
        try await Task.sleep(for: .seconds(SwipeExit.wait + 0.2))
        #expect(!page.swipeNavigator.isCarryingOn)
        #expect(offset(page) == 0 && page.layer?.opacity == 1)
        _ = host
    }

    @Test func callingItOffStillSpringsBack() {
        let (page, host) = swiping(dx: 150)
        page.swipeNavigator.touchEnded(at: 1.05, cancelled: true)
        #expect(!page.swipeNavigator.isCarryingOn)
        #expect(offset(page) == 0 && page.layer?.opacity == 1)
        #expect(page.layer?.animation(forKey: "swipe.settle") != nil)
        _ = host
    }

    @Test func aNewSwipePutsACarriedPageBackFirst() {
        let (page, host) = swiping(dx: 150)
        page.swipeNavigator.touchEnded(at: 1.05, cancelled: false)
        page.swipeNavigator.touchBegan(direction: -1)
        #expect(!page.swipeNavigator.isCarryingOn)
        #expect(page.layer?.opacity == 1)
        _ = host
    }

    @Test func reduceMotionLeavesThePageWhereItIs() {
        Tokens.Motion.debugReduceMotion = true
        defer { Tokens.Motion.debugReduceMotion = false }
        let (page, host) = swiping(dx: 150)
        #expect(offset(page) == 0)
        page.swipeNavigator.touchEnded(at: 1.05, cancelled: false)
        #expect(!page.swipeNavigator.isCarryingOn)
        #expect(offset(page) == 0 && page.layer?.opacity == 1)
        _ = host
    }
}

/// A trackpad swipe driven through its phases in-process: it goes back past its distance or with a flick, leaves pages
/// that scroll or pan sideways alone, and every path, lost ends included, finishes with nothing left over.
@MainActor
@Suite(.serialized)
struct SwipeGestureTests {
    private final class Host: NSWindowController, SwipeArrowHost {
        let swipeArrowLayer = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var tab: Tab?
    }

    /// A page 800 points wide in a window that shows the arrow, with somewhere to go back to; a tab's, in a card, if `card`.
    private func page(card: Bool = false) throws -> (BrowserWebView, Host) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let host = Host(window: window)
        var page = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        if card {
            let tab = Tab(url: URL(string: "about:blank"), spaceID: UUID())
            page = try #require(tab.ensureWebView() as? BrowserWebView)
            host.tab = tab
            let holder = PageCardView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            window.contentView?.addSubview(holder)
            holder.show(page)
            holder.layoutSubtreeIfNeeded()
        } else {
            page.wantsLayer = true
            window.contentView?.addSubview(page)
        }
        window.contentView?.addSubview(host.swipeArrowLayer)
        page.swipeNavigator.debugCanGo = (true, false)
        return (page, host)
    }

    private var now: TimeInterval = ProcessInfo.processInfo.systemUptime

    /// A two-finger scroll at CGEvent's `phase` (128 may begin, 1 began, 2 changed, 4 ended, 8 cancelled) or
    /// `momentum` (1 began, 2 going, 3 ended), `dx` and `dy` points, `after` seconds past the last one.
    private mutating func scroll(phase: Int64 = 0, momentum: Int64 = 0, dx: Int32 = 0, dy: Int32 = 0, after: TimeInterval = 0.008) throws -> NSEvent {
        now += after
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        cg.timestamp = CGEventTimestamp(now * 1_000_000_000)
        return try #require(NSEvent(cgEvent: cg))
    }

    /// Fingers down and `steps` moves of `dx` (positive goes back) and `dy`, the page having said what it can scroll.
    private mutating func drag(_ page: BrowserWebView, steps: Int, dx: Int32, dy: Int32 = 0,
                                room: (left: Bool, right: Bool) = (false, false)) throws {
        let swipe = page.swipeNavigator
        _ = swipe.handle(try scroll(phase: 1, dx: dx, dy: dy))
        swipe.debugHeard(left: room.left, right: room.right)
        for _ in 0..<steps { _ = swipe.handle(try scroll(phase: 2, dx: dx, dy: dy)) }
    }

    private var on: Bool { NSEvent.isSwipeTrackingFromScrollEventsEnabled && SwipeNavigator.isOn }

    @Test func swipeGoesAtAThirdCappedOrAFlick() {
        // A third of the page, between 120 and 180 scrolled points.
        #expect(SwipeDecision.distance(forWidth: 300) == 120)
        #expect(SwipeDecision.distance(forWidth: 450) == 150)
        #expect(SwipeDecision.distance(forWidth: 1600) == 180)
        // A flick a third of the way at a moderate speed goes; a slow or short one doesn't.
        #expect(SwipeDecision.commits(progress: 0.3, speed: 500))
        #expect(!SwipeDecision.commits(progress: 0.3, speed: 300))
        #expect(!SwipeDecision.commits(progress: 0.2, speed: 2000))
        // Fingers on the screen: their 100 points, or a third of a narrow pane.
        #expect(SwipeDecision.touchDistance(forWidth: 1200) == 100)
        #expect(SwipeDecision.touchDistance(forWidth: 240) == 80)
        #expect(SwipeDecision.commits(progress: 0.3, touchSpeed: 320))
    }

    @Test mutating func aPlainPageGoesBackAndEndsClean() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        // 200 points, past the 180 an 800 point page needs, slowly enough to stop before letting go.
        try drag(page, steps: 20, dx: 10)
        #expect(swipe.isTracking)
        _ = swipe.handle(try scroll(phase: 4, after: 0.2))
        #expect(swipe.isCarryingOn)
        swipe.pageArrived()
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func aShortSwipeSpringsBackAndEndsClean() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        // 48 points: short of the distance and of a flick's third.
        try drag(page, steps: 5, dx: 8)
        #expect(swipe.isShowing)
        _ = swipe.handle(try scroll(phase: 4, after: 0.2))
        #expect(!swipe.isCarryingOn)
        #expect(swipe.isClean)
        #expect(page.layer?.animation(forKey: "swipe.settle") != nil)
        _ = host
    }

    @Test mutating func aFlickGoesShortOfTheDistance() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        // 66 points, over a third of the way, at 1500 points a second as the fingers lift.
        try drag(page, steps: 10, dx: 6)
        _ = swipe.handle(try scroll(phase: 2, dx: 12))
        _ = swipe.handle(try scroll(phase: 4, after: 0.004))
        #expect(swipe.isCarryingOn)
        swipe.pageArrived()
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func aFlickArmsWithOneTapBeforeLettingGo() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        var taps = 0
        swipe.tap = { taps += 1 }
        // 66 points of 180 at 750 points a second: letting go would go, so it arms now.
        try drag(page, steps: 10, dx: 6)
        #expect(swipe.isTracking && swipe.isArmed)
        #expect(taps == 1)
        // Resting, then letting go: still armed, and it goes.
        _ = swipe.handle(try scroll(phase: 4, after: 0.5))
        #expect(swipe.isCarryingOn)
        #expect(taps == 1)
        swipe.pageArrived()
        _ = host
    }

    @Test mutating func movingBackPastTheMarginDisarmsWithNoTap() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        var taps = 0
        swipe.tap = { taps += 1 }
        try drag(page, steps: 10, dx: 6)
        #expect(swipe.isArmed)
        // Back to 30 points, well past the margin from 66.
        for _ in 0..<6 { _ = swipe.handle(try scroll(phase: 2, dx: -6)) }
        #expect(!swipe.isArmed)
        #expect(taps == 1)
        _ = swipe.handle(try scroll(phase: 4, after: 0.2))
        #expect(!swipe.isCarryingOn)
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func aSlowSwipeTapsOnceAtTheFullDistance() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        var taps = 0
        swipe.tap = { taps += 1 }
        _ = swipe.handle(try scroll(phase: 1, dx: 10))
        swipe.debugHeard(left: false, right: false)
        // 200 points per second, too slow to flick: it arms only once at 180 points.
        for step in 1...20 {
            _ = swipe.handle(try scroll(phase: 2, dx: 10, after: 0.05))
            #expect(swipe.isArmed == (step >= 17))
        }
        #expect(taps == 1)
        _ = swipe.handle(try scroll(phase: 4, after: 0.05))
        #expect(swipe.isCarryingOn)
        swipe.pageArrived()
        _ = host
    }

    @Test func touchSwipesNeverTap() throws {
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        var taps = 0
        swipe.tap = { taps += 1 }
        // A flick on the screen arms it, and so does the full distance, with no tap either way.
        swipe.touchBegan(direction: -1)
        swipe.touchMoved(dx: 40, at: 1)
        swipe.touchMoved(dx: 60, at: 1.02)
        #expect(swipe.isArmed)
        swipe.touchMoved(dx: 150, at: 1.1)
        #expect(swipe.isArmed)
        #expect(taps == 0)
        swipe.touchEnded(at: 1.15, cancelled: false)
        #expect(swipe.isCarryingOn)
        swipe.pageArrived()
        _ = host
    }

    @Test mutating func aSidewaysScrollerKeepsTheGestureUntilANewOneAtItsEdge() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        // Room to scroll back: the page has the gesture, all of it, even once it reaches its edge.
        _ = swipe.handle(try scroll(phase: 1, dx: 10))
        swipe.debugHeard(left: true, right: true)
        for _ in 0..<10 { #expect(!swipe.handle(try scroll(phase: 2, dx: 10))) }
        swipe.debugHeard(left: false, right: true)
        for _ in 0..<20 { #expect(!swipe.handle(try scroll(phase: 2, dx: 10))) }
        #expect(!swipe.isShowing)
        _ = swipe.handle(try scroll(phase: 4))
        #expect(swipe.isClean)
        // A new gesture at the edge goes back.
        try drag(page, steps: 20, dx: 10, room: (false, true))
        #expect(swipe.isTracking)
        _ = swipe.handle(try scroll(phase: 4, after: 0.2))
        swipe.pageArrived()
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func aPageThatCancelsWheelsNeverSwipes() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        // A canvas: nothing scrolls, but it calls preventDefault on the first scroll.
        _ = swipe.handle(try scroll(phase: 1, dx: 10))
        swipe.debugHeard(left: false, right: false)
        swipe.pageAnswered(kept: true, at: 1e15)
        for _ in 0..<30 { #expect(!swipe.handle(try scroll(phase: 2, dx: 10))) }
        #expect(!swipe.isShowing)
        _ = swipe.handle(try scroll(phase: 4))
        #expect(swipe.isClean)
        // Answering late, mid-swipe: the arrow goes and the page has the rest.
        try drag(page, steps: 12, dx: 10)
        #expect(swipe.isShowing)
        swipe.pageAnswered(kept: true, at: 1e15)
        #expect(!swipe.isShowing)
        for _ in 0..<5 { #expect(!swipe.handle(try scroll(phase: 2, dx: 10))) }
        _ = swipe.handle(try scroll(phase: 4))
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func upAndDownAndTurningSidewaysLaterScroll() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        try drag(page, steps: 10, dx: 0, dy: -12)
        #expect(!swipe.isShowing)
        // Turning sideways in the same gesture stays a scroll.
        for _ in 0..<30 { #expect(!swipe.handle(try scroll(phase: 2, dx: 12))) }
        #expect(!swipe.isShowing)
        _ = swipe.handle(try scroll(phase: 4))
        #expect(swipe.isClean)
        // Mostly up and down with a little sideways: a scroll too.
        try drag(page, steps: 20, dx: 6, dy: 10)
        #expect(!swipe.isShowing)
        _ = swipe.handle(try scroll(phase: 4))
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func whileTheArrowLeansInThePageOnlyGetsTheSidewaysPart() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        try drag(page, steps: 1, dx: 12, dy: 3)
        #expect(swipe.isShowing && !swipe.isTracking)
        let step = try scroll(phase: 2, dx: 12, dy: 3)
        #expect(!swipe.handle(step))
        let level = swipe.forPage(step)
        #expect(level.scrollingDeltaY == 0 && level.scrollingDeltaX == step.scrollingDeltaX && level.phase == step.phase)
        // Up and down is the page's as ever.
        _ = swipe.handle(try scroll(phase: 4))
        _ = swipe.handle(try scroll(phase: 1, dy: -12))
        let down = try scroll(phase: 2, dy: -12)
        _ = swipe.handle(down)
        #expect(swipe.forPage(down) === down)
        _ = swipe.handle(try scroll(phase: 4))
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func aLostEndIsClearedByTheNextGesture() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        try drag(page, steps: 10, dx: 10)
        #expect(page.layer?.affineTransform() != .identity)
        // No end; the next gesture is up and down: the page doesn't stay shifted.
        _ = swipe.handle(try scroll(phase: 128, after: 0.05))
        _ = swipe.handle(try scroll(phase: 1, dy: -12))
        #expect(page.layer?.affineTransform() == .identity)
        _ = swipe.handle(try scroll(phase: 2, dy: -12))
        _ = swipe.handle(try scroll(phase: 4))
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func momentumWithNoEndIsTheRelease() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        try drag(page, steps: 20, dx: 10)
        // The end was lost; the glide after it says the fingers lifted.
        #expect(swipe.handle(try scroll(momentum: 1, dx: 20)))
        #expect(swipe.isCarryingOn)
        #expect(swipe.handle(try scroll(momentum: 2, dx: 10)))
        _ = swipe.handle(try scroll(momentum: 3))
        swipe.pageArrived()
        #expect(swipe.isClean)
        // The next scroll is the page's again.
        _ = swipe.handle(try scroll(phase: 1, dy: -10))
        #expect(!swipe.handle(try scroll(phase: 2, dy: -10)))
        _ = swipe.handle(try scroll(phase: 4))
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func aRestHoldsUntilTheWindowGoesOrItRunsOut() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        try drag(page, steps: 10, dx: 10)
        // Resting: the swipe holds and watches for the hand doing something else.
        swipe.debugRest()
        #expect(swipe.isShowing)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: page.window)
        #expect(!swipe.isShowing)
        #expect(swipe.isClean)
        // Resting with nothing else happening: it runs out.
        try drag(page, steps: 10, dx: 10)
        swipe.debugRest()
        swipe.debugRest()
        #expect(swipe.isClean)
        _ = host
    }

    /// Swiping on: still for a moment, it watches for the hand doing something else, and the window going ends it.
    private func expectRestWatched(_ page: BrowserWebView) {
        let swipe = page.swipeNavigator
        #expect(swipe.isShowing)
        swipe.debugRest()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: page.window)
        #expect(swipe.isClean)
    }

    @Test mutating func aSwipeAfterANewGestureStillHasItsWatchdog() throws {
        guard on else { return }
        let (page, host) = try page()
        // A swipe, then another gesture starting over it: the second swipe's lost end is still caught.
        try drag(page, steps: 10, dx: 10)
        try drag(page, steps: 10, dx: 10)
        expectRestWatched(page)
        _ = host
    }

    @Test mutating func aSwipeAfterItsPageLeftTheWindowStillHasItsWatchdog() throws {
        guard on else { return }
        let (page, host) = try page()
        try drag(page, steps: 10, dx: 10)
        page.swipeNavigator.leftWindow()
        try drag(page, steps: 10, dx: 10)
        expectRestWatched(page)
        _ = host
    }

    @Test mutating func aSwipeAfterATouchSwipeStillHasItsWatchdog() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        try drag(page, steps: 10, dx: 10)
        swipe.touchBegan(direction: -1)
        swipe.touchEnded(at: ProcessInfo.processInfo.systemUptime, cancelled: true)
        try drag(page, steps: 10, dx: 10)
        expectRestWatched(page)
        _ = host
    }

    @Test mutating func aRestEndsWhenThePointerMovesInAWindowThatDoesntTrackIt() async throws {
        guard on else { return }
        // A standalone Zigzag Mini that isn't key gets no pointer moves as events.
        let (page, host) = try page()
        page.window?.acceptsMouseMovedEvents = false
        let swipe = page.swipeNavigator
        var at = NSPoint(x: 400, y: 300)
        swipe.pointer = { at }
        try drag(page, steps: 10, dx: 10)
        swipe.debugRest()
        try await Task.sleep(for: .milliseconds(250))
        #expect(swipe.isShowing)
        at.x += 30
        try await Task.sleep(for: .milliseconds(250))
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func aNewSwipeTracksAtOnceAfterOneCalledOff() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        try drag(page, steps: 8, dx: 8)
        _ = swipe.handle(try scroll(phase: 4))
        #expect(page.layer?.animation(forKey: "swipe.settle") != nil)
        // The spring back still running doesn't hide the next swipe's movement.
        try drag(page, steps: 8, dx: 8, room: (false, false))
        #expect(swipe.isShowing)
        #expect(page.layer?.animation(forKey: "swipe.settle") == nil)
        #expect(page.layer?.affineTransform() != .identity)
        _ = swipe.handle(try scroll(phase: 8))
        #expect(swipe.isClean)
        // And straight after one that went.
        try drag(page, steps: 20, dx: 10)
        _ = swipe.handle(try scroll(phase: 4, after: 0.2))
        #expect(swipe.isCarryingOn)
        _ = swipe.handle(try scroll(phase: 1, dx: 10))
        #expect(!swipe.isCarryingOn)
        _ = swipe.handle(try scroll(phase: 4))
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func leavingTheWindowMidSwipeEndsClean() throws {
        guard on else { return }
        let (page, host) = try page()
        let swipe = page.swipeNavigator
        try drag(page, steps: 12, dx: 10)
        #expect(swipe.isShowing)
        page.removeFromSuperview()
        #expect(swipe.isClean)
        _ = host
    }

    @Test mutating func aPageInACardSwipesTheSameWay() throws {
        guard on else { return }
        let (page, host) = try page(card: true)
        let swipe = page.swipeNavigator
        try drag(page, steps: 5, dx: 8)
        #expect(swipe.isShowing)
        let moved = try #require(page.superview?.layer)
        #expect(moved.affineTransform() != .identity)
        _ = swipe.handle(try scroll(phase: 4, after: 0.2))
        #expect(swipe.isClean)
        #expect(moved.affineTransform() == .identity)
        try drag(page, steps: 20, dx: 10)
        _ = swipe.handle(try scroll(phase: 4, after: 0.2))
        #expect(swipe.isCarryingOn)
        swipe.pageArrived()
        #expect(swipe.isClean)
        #expect(moved.affineTransform() == .identity)
        _ = host
    }

    @Test mutating func eachStepOfASwipeIsCheap() throws {
        guard on else { return }
        let (page, host) = try page(card: true)
        let swipe = page.swipeNavigator
        try drag(page, steps: 10, dx: 2)
        var times: [Double] = []
        for _ in 0..<240 {
            let event = try scroll(phase: 2, dx: 1)
            let start = DispatchTime.now().uptimeNanoseconds
            _ = swipe.handle(event)
            CATransaction.flush()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        let sorted = times.sorted()
        print("swipe step µs: median \(Int(sorted[sorted.count / 2])) p95 \(Int(sorted[sorted.count * 95 / 100])) max \(Int(sorted.last ?? 0))")
        // Well inside one 120 Hz frame.
        #expect(sorted[sorted.count / 2] < 1000)
        _ = swipe.handle(try scroll(phase: 8))
        _ = host
    }
}

/// A trackpad swipe driven at the trackpad's 120 Hz in real time over a tab's page in a card, a busy one included:
/// what each step costs, how soon the page first moves, and whether anything animates against the fingers.
@MainActor
@Suite(.serialized)
struct SwipeSmoothnessTests {
    private final class Host: NSWindowController, SwipeArrowHost {
        let swipeArrowLayer = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var tab: Tab?
    }

    /// A tab's page 800 points wide in a card, showing `html`.
    private func page(_ html: String) async throws -> (BrowserWebView, Host) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let host = Host(window: window)
        let tab = Tab(url: URL(string: "about:blank"), spaceID: UUID())
        let page = try #require(tab.ensureWebView() as? BrowserWebView)
        host.tab = tab
        let card = PageCardView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView?.addSubview(card)
        card.show(page)
        card.layoutSubtreeIfNeeded()
        window.contentView?.addSubview(host.swipeArrowLayer)
        page.swipeNavigator.debugCanGo = (true, false)
        page.loadHTMLString(html, baseURL: nil)
        for _ in 0..<60 where page.isLoading || page.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
        return (page, host)
    }

    /// Lots of page, and a script that keeps the page's main thread busy 150 ms at a time.
    private static let busy = """
    <html><body><div id=list></div><script>
    const list = document.getElementById('list');
    for (let i = 0; i < 20000; i++) { const d = document.createElement('div'); d.textContent = 'Row ' + i; list.appendChild(d); }
    function work() { const t = performance.now(); while (performance.now() - t < 150) {} setTimeout(work, 5); }
    setTimeout(work, 0);
    </script></body></html>
    """
    private static let plain = "<html><body><p>Plain</p></body></html>"

    private func scroll(phase: Int64, dx: Int32, at time: TimeInterval) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        cg.timestamp = CGEventTimestamp(time * 1_000_000_000)
        return try #require(NSEvent(cgEvent: cg))
    }

    private var on: Bool { NSEvent.isSwipeTrackingFromScrollEventsEnabled && SwipeNavigator.isOn }

    private func animates(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        if !(layer.animationKeys() ?? []).isEmpty { return true }
        return (layer.sublayers ?? []).contains { animates($0) }
    }

    /// A step of `dx` for each of `steps` at 120 Hz in real time, the run loop turning between them as it does for a
    /// trackpad, then the fingers lifting on the next frame.
    private func drive(_ page: BrowserWebView, host: Host, steps: [Int32]) async throws -> Run {
        var run = Run()
        let swipe = page.swipeNavigator
        let moved = try #require(page.superview?.layer)
        final class Count { var value = 0 }
        let wakes = Count()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in wakes.value += 1 }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        let start = ProcessInfo.processInfo.systemUptime
        _ = swipe.handle(try scroll(phase: 1, dx: steps[0], at: start))
        var offsets: [(time: TimeInterval, tx: CGFloat)] = []
        for (index, dx) in steps.enumerated().dropFirst() {
            let wait = start + Double(index) / 120 - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try await Task.sleep(for: .microseconds(Int(wait * 1_000_000))) }
            let now = ProcessInfo.processInfo.systemUptime
            let event = try scroll(phase: 2, dx: dx, at: now)
            let t = DispatchTime.now().uptimeNanoseconds
            _ = swipe.handle(event)
            CATransaction.flush()
            run.steps.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1000)
            let tx = moved.affineTransform().tx
            offsets.append((now, tx))
            if run.firstMove == nil, tx != 0 { run.firstMove = (now - start) * 1000 }
            let arrow = host.swipeArrowLayer.subviews.first as? SwipeArrowView
            if !swipe.isArmed, animates(moved) || animates(arrow?.layer) { run.animated += 1 }
        }
        run.wakeups = Double(wakes.value) / (ProcessInfo.processInfo.systemUptime - start)
        #if DEBUG
        run.timers = swipe.debugWatchdogTimers
        #endif
        try await Task.sleep(for: .milliseconds(8))
        // The page's own speed over the last few steps, and the spring back's as it starts.
        if let last = offsets.last, let before = offsets.dropLast(3).last, last.time > before.time {
            run.pageSpeed = (last.tx - before.tx) / CGFloat(last.time - before.time)
        }
        // Held in a transaction of its own: committed, a window that was never shown ends its animations at once.
        CATransaction.begin()
        defer { CATransaction.commit() }
        _ = swipe.handle(try scroll(phase: 4, dx: 0, at: ProcessInfo.processInfo.systemUptime))
        if let spring = moved.animation(forKey: "swipe.settle") as? CASpringAnimation,
           let from = (spring.fromValue as? NSValue)?.caTransform3DValue.m41 {
            // Toward home, in whole distances a second: as a speed in points, the way the page was going.
            run.settleSpeed = -spring.initialVelocity * from
        }
        swipe.pageArrived()
        return run
    }

    struct Run {
        /// Milliseconds from the gesture's first scroll to the page first moving.
        var firstMove: Double?
        /// Each step's handling, layers committed, in µs.
        var steps: [Double] = []
        /// Main thread run loop wakeups a second while the fingers moved.
        var wakeups = 0.0
        /// Timers the swipe set while the fingers moved.
        var timers = 0
        /// Steps after which something the swipe moves had an animation on it.
        var animated = 0
        /// Points a second the page moved as the fingers lifted, and the spring back's speed as it starts.
        var pageSpeed: CGFloat = 0
        var settleSpeed: CGFloat = 0
    }

    private func report(_ name: String, _ run: Run) {
        let s = run.steps.sorted()
        let first = run.firstMove.map { String(format: "%.1f ms", $0) } ?? "never"
        print("swipe bench \(name): first move \(first), step µs median \(Int(s[s.count / 2])) p95 \(Int(s[s.count * 95 / 100])) max \(Int(s.last ?? 0)) (step \(run.steps.firstIndex(of: s.last ?? 0) ?? -1), first 4: \(run.steps.prefix(4).map { Int($0) })), wakeups \(Int(run.wakeups))/s, timers \(run.timers), steps with animations \(run.animated), page \(Int(run.pageSpeed)) pt/s, spring back starts \(Int(run.settleSpeed)) pt/s")
    }

    /// Keeps the page's main thread busy for `ms`, as a heavy page's script does, without waiting for it.
    private func busy(_ page: BrowserWebView, ms: Int) {
        page.evaluateJavaScript("{ const t = performance.now(); while (performance.now() - t < \(ms)) {} }", in: nil, in: .page) { _ in }
    }

    /// A calm swipe: past the 10 points that decide it in four steps, a point a step for most of a second, then a little
    /// quicker as the fingers lift, short of arming.
    private static let calm: [Int32] = [3, 3, 3, 3] + Array(repeating: 1, count: 96) + Array(repeating: 3, count: 10)

    @Test func aSwipeAtTheTrackpadsRate() async throws {
        guard on else { return }
        var runs: [Run] = []
        for (name, html, busyFor) in [("plain", Self.plain, 0), ("busy", Self.busy, 300)] {
            let (page, host) = try await page(html)
            if busyFor > 0 { busy(page, ms: busyFor) }
            let run = try await drive(page, host: host, steps: Self.calm)
            report(name, run)
            runs.append(run)
            _ = host
        }
        for run in runs {
            // Nothing animates against the fingers, and a second of steps sets a timer or two, not one a step.
            #expect(run.animated == 0)
            #expect(run.timers <= 3)
            // The spring back starts at about the page's own speed.
            #expect(run.pageSpeed > 10)
            #expect(abs(run.settleSpeed - run.pageSpeed) <= run.pageSpeed * 0.3)
        }
        // A page too busy to answer moves within a frame of a quick one.
        let plain = try #require(runs[0].firstMove), busy = try #require(runs[1].firstMove)
        #expect(busy <= plain + 1000.0 / 60 + 2)
    }

    @Test func aBusyPageLeansWithinAFrame() {
        func decide(waited: TimeInterval, leans: Bool = true, overFrame: Bool = false) -> SwipeDecision {
            SwipeDecision.decide(dx: 12, dy: 0, canGoBack: true, canGoForward: true, pageScrolls: nil, page: .unknown,
                                 waited: waited, overFrame: overFrame, leans: leans)
        }
        #expect(SwipeDecision.probeWait <= 1.0 / 60)
        #expect(decide(waited: 0.01) == .undecided)
        #expect(decide(waited: SwipeDecision.probeWait) == .lean(-1))
        // A page that cancelled sideways scrolls before, or one over a frame, waits for its answer as before.
        #expect(decide(waited: SwipeDecision.probeWait, leans: false) == .undecided)
        #expect(decide(waited: SwipeDecision.probeWait, overFrame: true) == .undecided)
        // Not heard from by the usual wait, it's the swipe's.
        #expect(decide(waited: SwipeDecision.frameWait) == .track(-1))
    }

    @Test func lettingGoCarriesOnAtThePagesSpeed() {
        // Unknown speed: the house ease-out, as before.
        #expect(SwipeExit.carryTiming(distance: 44, velocity: nil) === Tokens.Motion.easeOut)
        func slope(_ velocity: CGFloat) -> Float {
            var first: [Float] = [0, 0]
            SwipeExit.carryTiming(distance: 44, velocity: velocity).getControlPoint(at: 1, values: &first)
            return first[1] / first[0]
        }
        // Starting at the page's speed: 44 points in 0.18 s at an even pace is 244 points a second.
        #expect(abs(slope(400) - Float(400 * SwipeExit.duration / 44)) < 0.01)
        // Never slower than an even pace, nor faster than the house ease-out starts.
        #expect(slope(0) == 1)
        #expect(slope(-300) == 1)
        #expect(abs(slope(5000) - 1 / 0.23) < 0.01)
        // The spring back: toward home at the page's speed, capped where it would go past home.
        let from = CGAffineTransform(translationX: 40, y: 0)
        let still = SwipeExit.springHome(from: from, velocity: 0)
        #expect(still.initialVelocity == 0)
        let coming = SwipeExit.springHome(from: from, velocity: -80)
        #expect(abs(coming.initialVelocity - 2) < 0.001)
        let going = SwipeExit.springHome(from: from, velocity: 80)
        #expect(abs(going.initialVelocity + 2) < 0.001)
        let natural = sqrt(still.stiffness / still.mass)
        #expect(SwipeExit.springHome(from: from, velocity: -100_000).initialVelocity == natural)
    }
}
