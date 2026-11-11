import CoreGraphics
import Foundation
import Testing
@testable import Zigzag

/// The mini player's arithmetic and its rules: which video follows you out of a tab, the card's size and corner, how
/// the page is placed in it, and what happens as you move between tabs.
struct MiniPlayerTests {
    private let viewport = CGSize(width: 1280, height: 800)

    private func video(_ index: Int, _ rect: CGRect, playing: Bool = true, muted: Bool = false) -> PageVideo {
        PageVideo(index: index, rect: rect, natural: CGSize(width: 1920, height: 1080), isPlaying: playing, isMuted: muted)
    }

    // MARK: Choosing the video

    @Test func thePlayingVideoIsChosenOverAPausedOne() {
        let paused = video(0, CGRect(x: 0, y: 0, width: 960, height: 540), playing: false)
        let playing = video(1, CGRect(x: 0, y: 600, width: 320, height: 180))
        #expect(MiniPlayerLayout.choose([paused, playing], viewport: viewport)?.index == 1)
    }

    @Test func nothingIsChosenWhenNothingPlays() {
        let ended = PageVideo(index: 0, rect: CGRect(x: 0, y: 0, width: 640, height: 360), natural: CGSize(width: 640, height: 360),
                              isPlaying: true, hasEnded: true)
        #expect(MiniPlayerLayout.choose([video(1, CGRect(x: 0, y: 0, width: 640, height: 360), playing: false), ended], viewport: viewport) == nil)
    }

    @Test func theLargestVisibleOneWins() {
        let small = video(0, CGRect(x: 0, y: 0, width: 320, height: 180))
        let big = video(1, CGRect(x: 0, y: 200, width: 960, height: 540))
        // Bigger still, but scrolled almost out of sight.
        let offscreen = video(2, CGRect(x: 0, y: 780, width: 1280, height: 720))
        #expect(MiniPlayerLayout.choose([small, big, offscreen], viewport: viewport)?.index == 1)
    }

    @Test func oneYouCanHearComesFirst() {
        let silentBig = video(0, CGRect(x: 0, y: 0, width: 960, height: 540), muted: true)
        let audible = video(1, CGRect(x: 0, y: 560, width: 320, height: 180))
        #expect(MiniPlayerLayout.choose([silentBig, audible], viewport: viewport)?.index == 1)
    }

    @Test func aPagesMovingBackgroundAndThumbnailsNeverFollow() {
        var background = video(0, CGRect(x: 0, y: 0, width: 1280, height: 720), muted: true)
        background.loops = true
        var autoplaying = video(1, CGRect(x: 0, y: 0, width: 1280, height: 720), muted: true)
        autoplaying.autoplays = true
        let thumbnail = video(2, CGRect(x: 0, y: 0, width: 100, height: 56))
        #expect(MiniPlayerLayout.choose([background, autoplaying, thumbnail], viewport: viewport) == nil)
        // With its controls showing, a muted video is one you're watching.
        background.hasControls = true
        #expect(MiniPlayerLayout.follows(background))
        // A silent video that simply plays (no sound track, not set to loop) follows too.
        #expect(MiniPlayerLayout.follows(video(3, CGRect(x: 0, y: 0, width: 640, height: 360), muted: true)))
    }

    @Test func readsWhatThePageSays() {
        let parsed = PageVideo(["i": 2, "x": 10, "y": 20.5, "w": 640, "h": 360, "vw": 1280, "vh": 720, "playing": true, "ended": false,
                                "muted": false, "loop": false, "autoplay": true, "controls": false, "fit": "cover", "t": 12.5, "d": -1] as [String: Any])
        #expect(parsed?.index == 2)
        #expect(parsed?.rect == CGRect(x: 10, y: 20.5, width: 640, height: 360))
        #expect(parsed?.fit == "cover")
        #expect(parsed?.duration == nil)
        #expect(PageVideo(["x": 1]) == nil)
    }

    // MARK: The picture inside its element

    @Test func aLetterboxedPictureIsFoundInsideItsElement() {
        // A 16:9 picture in a square element: bars above and below.
        let v = PageVideo(index: 0, rect: CGRect(x: 100, y: 100, width: 400, height: 400), natural: CGSize(width: 1600, height: 900), isPlaying: true)
        #expect(MiniPlayerLayout.pictureRect(of: v) == CGRect(x: 100, y: 187.5, width: 400, height: 225))
        var cover = v
        cover.fit = "cover"
        #expect(MiniPlayerLayout.pictureRect(of: cover) == v.rect)
    }

    // MARK: The card

    @Test func theCardIsAThirdOfThePageWithinItsLimits() {
        #expect(MiniPlayerLayout.cardSize(aspect: 16 / 9, in: CGSize(width: 1040, height: 805)) == CGSize(width: 333, height: 187))
        // A big window: no wider than 480.
        #expect(MiniPlayerLayout.cardSize(aspect: 16 / 9, in: CGSize(width: 2400, height: 1400)).width == 480)
        // A small one: no narrower than 240.
        #expect(MiniPlayerLayout.cardSize(aspect: 16 / 9, in: CGSize(width: 500, height: 600)).width == 240)
    }

    @Test func aTallVideoIsKeptToHalfThePageHeight() {
        let size = MiniPlayerLayout.cardSize(aspect: 9 / 16, in: CGSize(width: 1040, height: 600))
        #expect(size.height == 300)
        #expect(size.width == round(300 * 9 / 16))
    }

    @Test func theCardNeverOutgrowsATinyPage() {
        let size = MiniPlayerLayout.cardSize(aspect: 16 / 9, in: CGSize(width: 200, height: 400))
        #expect(size.width <= 200 - MiniPlayerLayout.margin * 2)
    }

    @Test func thePictureFillsTheCard() {
        let picture = CGRect(x: 40, y: 120, width: 720, height: 405)
        let card = CGSize(width: 360, height: 202.5)
        let placement = MiniPlayerLayout.placement(showing: picture, in: card)
        #expect(placement.scale == 0.5)
        #expect(placement.visible(in: card) == picture)
    }

    @Test func aPictureOfAnotherShapeIsCroppedEvenly() {
        // A 2:1 picture in a 16:9 card: the scale fills the card's height, the sides are cut alike.
        let picture = CGRect(x: 0, y: 0, width: 800, height: 400)
        let card = CGSize(width: 320, height: 180)
        let seen = MiniPlayerLayout.placement(showing: picture, in: card).visible(in: card)
        #expect(abs(seen.height - 400) < 0.001)
        #expect(abs(seen.midX - picture.midX) < 0.001)
        #expect(abs(seen.minX - (800 - seen.width) / 2) < 0.001)
    }

    @Test func aFramesVideosArePlacedByItsSize() {
        let frames: [(rect: CGRect, host: String)] = [(CGRect(x: 0, y: 0, width: 300, height: 250), "ads.example"),
                                                      (CGRect(x: 40, y: 300, width: 640, height: 360), "www.youtube.com")]
        #expect(MiniPlayerLayout.frameOrigin(viewport: CGSize(width: 640, height: 360), host: "www.youtube.com", among: frames) == CGPoint(x: 40, y: 300))
        // Two of the same size: the one from the frame's own site.
        let twins = frames + [(CGRect(x: 40, y: 900, width: 640, height: 360), "player.vimeo.com")]
        #expect(MiniPlayerLayout.frameOrigin(viewport: CGSize(width: 640, height: 360), host: "player.vimeo.com", among: twins) == CGPoint(x: 40, y: 900))
        #expect(MiniPlayerLayout.frameOrigin(viewport: CGSize(width: 500, height: 500), host: "x", among: frames) == nil)
    }

    // MARK: Corners

    @Test func theCardSitsInItsCornerAMarginIn() {
        let area = CGRect(x: 240, y: 0, width: 1040, height: 805)
        let size = CGSize(width: 333, height: 187)
        #expect(MiniPlayerLayout.frame(at: .bottomRight, size: size, in: area) == CGRect(x: 935, y: 606, width: 333, height: 187))
        #expect(MiniPlayerLayout.frame(at: .topLeft, size: size, in: area) == CGRect(x: 252, y: 12, width: 333, height: 187))
    }

    @Test func theNearestCornerIsFoundFromAnywhere() {
        let area = CGRect(x: 240, y: 0, width: 1040, height: 805)
        #expect(MiniPlayerLayout.nearestCorner(to: CGPoint(x: 300, y: 100), in: area) == .topLeft)
        #expect(MiniPlayerLayout.nearestCorner(to: CGPoint(x: 1200, y: 100), in: area) == .topRight)
        #expect(MiniPlayerLayout.nearestCorner(to: CGPoint(x: 300, y: 700), in: area) == .bottomLeft)
        #expect(MiniPlayerLayout.nearestCorner(to: CGPoint(x: 1200, y: 700), in: area) == .bottomRight)
        #expect(MiniPlayerLayout.nearestCorner(to: CGPoint(x: 5000, y: -300), in: area) == .topRight)
    }

    // MARK: Moving it anywhere

    /// A 1280 by 805 window, its edges `edgeInset` in.
    private let window = MiniPlayerLayout.movableArea(in: CGRect(x: 0, y: 0, width: 1280, height: 805), below: nil)
    private let card = CGSize(width: 333, height: 187)

    @Test func itGoesAnywhereInTheWindowOverTheSidebarToo() {
        #expect(window == CGRect(x: 4, y: 4, width: 1272, height: 797))
        // Over the sidebar, in the middle of nowhere: it stays where it was let go.
        let there = CGRect(x: 60, y: 300, width: 333, height: 187)
        #expect(MiniPlayerLayout.dropped(there, in: window) == there)
    }

    @Test func itNeverLeavesTheWindow() {
        let out = CGRect(x: -200, y: 900, width: 333, height: 187)
        let clamped = MiniPlayerLayout.clamp(out, in: window)
        #expect(clamped == CGRect(x: 4, y: 805 - 4 - 187, width: 333, height: 187))
        #expect(window.contains(MiniPlayerLayout.dropped(out, in: window)))
    }

    @Test func letGoNearAnEdgeItSettlesOnIt() {
        // 15 points from the left edge, far from the others: onto the resting line a margin in, and no further.
        let near = CGRect(x: 15, y: 300, width: 333, height: 187)
        #expect(MiniPlayerLayout.dropped(near, in: window) == CGRect(x: MiniPlayerLayout.margin, y: 300, width: 333, height: 187))
        // Near a corner: both edges.
        let corner = CGRect(x: 1280 - 333 - 20, y: 805 - 187 - 5, width: 333, height: 187)
        #expect(MiniPlayerLayout.dropped(corner, in: window) == CGRect(x: 1280 - 12 - 333, y: 805 - 12 - 187, width: 333, height: 187))
        // A little further than the snap distance: it stays.
        let away = CGRect(x: 12 + MiniPlayerLayout.snapDistance + 2, y: 300, width: 333, height: 187)
        #expect(MiniPlayerLayout.dropped(away, in: window) == away)
    }

    @Test func itKeepsToItsCornerAsTheWindowResizes() {
        let dropped = CGRect(x: 900, y: 580, width: 333, height: 187)
        let anchor = MiniPlayerLayout.anchor(of: dropped, in: window)
        #expect(anchor.corner == .bottomRight)
        #expect(MiniPlayerLayout.frame(for: anchor, size: card, in: window) == dropped)
        // A smaller window: the same distance from the bottom right.
        let smaller = MiniPlayerLayout.movableArea(in: CGRect(x: 0, y: 0, width: 1000, height: 700), below: nil)
        let moved = MiniPlayerLayout.frame(for: anchor, size: card, in: smaller)
        #expect(1000 - moved.maxX == 1280 - dropped.maxX)
        #expect(700 - moved.maxY == 805 - dropped.maxY)
        // Too small for that distance: still wholly inside.
        let tiny = MiniPlayerLayout.movableArea(in: CGRect(x: 0, y: 0, width: 400, height: 260), below: nil)
        #expect(tiny.contains(MiniPlayerLayout.frame(for: MiniPlayerLayout.Anchor(corner: .topLeft, offset: CGSize(width: 300, height: 300)), size: card, in: tiny)))
    }

    @Test func itsPlaceIsKeptAsText() {
        let anchor = MiniPlayerLayout.Anchor(corner: .bottomLeft, offset: CGSize(width: 51, height: 258))
        #expect(MiniPlayerLayout.Anchor(stored: anchor.stored) == anchor)
        #expect(MiniPlayerLayout.Anchor(stored: "middle 1 2") == nil)
        #expect(MiniPlayerLayout.Anchor(stored: "topLeft x 2") == nil)
    }

    @Test func itStaysUnderTheBarAboveThePage() {
        let area = MiniPlayerLayout.movableArea(in: CGRect(x: 0, y: 0, width: 1280, height: 805), below: 44)
        #expect(area.minY == 48)
        #expect(area.maxY == 801)
        let dragged = MiniPlayerLayout.dropped(CGRect(x: 400, y: -100, width: 333, height: 187), in: area)
        #expect(dragged.minY >= 44)
    }

    // MARK: Minimized

    @Test func minimizingHidesItAndTheVideoPlaysOn() {
        var model = MiniPlayerModel()
        // Nothing showing: nothing to minimize.
        #expect(model.minimize() == [])
        _ = model.switched(shown: [b], playing: a)
        // The card goes; nothing is paused.
        #expect(model.minimize() == [.hide(a)])
        #expect(model.tab == nil)
        #expect(model.minimize() == [])
    }

    @Test func aMinimizedVideoComesBackOnlyWhenYouLeaveItsTabAgain() {
        var model = MiniPlayerModel()
        _ = model.switched(shown: [b], playing: a)
        _ = model.minimize()
        // Moving among other tabs while it plays on out of sight never brings the card back.
        #expect(model.switched(shown: [c], playing: nil) == [])
        #expect(model.switched(shown: [b], playing: nil) == [])
        // Back on its tab, the page simply shows; leaving it again while it plays brings the card.
        #expect(model.switched(shown: [a], playing: nil) == [])
        #expect(model.switched(shown: [b], playing: a) == [.show(a)])
    }

    @Test func anotherVideoAfterAMinimizeTakesTheCardWithoutStoppingIt() {
        var model = MiniPlayerModel()
        _ = model.switched(shown: [b], playing: a)
        _ = model.minimize()
        // a is no longer the player's: leaving b playing shows b, and a, hidden, isn't paused by it.
        #expect(model.switched(shown: [c], playing: b) == [.show(b)])
    }

    @Test func backToTheTabInAnotherSpaceEndsIt() {
        var model = MiniPlayerModel()
        _ = model.switched(shown: [b], playing: a)
        // Selecting it (switching spaces first) shows it alone: the player lets it go, nothing paused.
        #expect(model.switched(shown: [a], playing: nil) == [.end(a)])
        #expect(model.tab == nil)
    }

    // MARK: Moving between tabs

    private let a = UUID(), b = UUID(), c = UUID()

    @Test func leavingAPlayingTabStartsIt() {
        var model = MiniPlayerModel()
        #expect(model.switched(shown: [b], playing: a) == [.show(a)])
        #expect(model.tab == a)
    }

    @Test func leavingAQuietTabDoesNothing() {
        var model = MiniPlayerModel()
        #expect(model.switched(shown: [b], playing: nil) == [])
        #expect(model.tab == nil)
    }

    @Test func comingBackPutsTheVideoBackInItsPage() {
        var model = MiniPlayerModel()
        _ = model.switched(shown: [b], playing: a)
        // Nothing stops: the video carries on in the page.
        #expect(model.switched(shown: [a], playing: nil) == [.end(a)])
        #expect(model.tab == nil)
    }

    @Test func anotherPlayingTabReplacesItAndTheOldOneStops() {
        var model = MiniPlayerModel()
        _ = model.switched(shown: [b], playing: a)
        #expect(model.switched(shown: [c], playing: b) == [.pause(a), .end(a), .show(b)])
        #expect(model.tab == b)
    }

    @Test func comingBackFromAnotherPlayingTabSwapsThem() {
        var model = MiniPlayerModel()
        _ = model.switched(shown: [b], playing: a)
        // Back to a, leaving b playing: a's video goes back in its page, b's takes the card.
        #expect(model.switched(shown: [a], playing: b) == [.end(a), .show(b)])
        #expect(model.tab == b)
    }

    @Test func movingBetweenQuietTabsKeepsIt() {
        var model = MiniPlayerModel()
        _ = model.switched(shown: [b], playing: a)
        #expect(model.switched(shown: [c], playing: nil) == [])
        #expect(model.tab == a)
    }

    @Test func splitBesideItsPageEndsIt() {
        var model = MiniPlayerModel()
        _ = model.switched(shown: [b], playing: a)
        #expect(model.switched(shown: [b, a], playing: nil) == [.end(a)])
    }

    @Test func aTabStillOnScreenNeverStartsIt() {
        var model = MiniPlayerModel()
        // Into the other half of a split: both pages stay on screen.
        #expect(model.switched(shown: [a, b], playing: a) == [])
    }

    @Test func closingItStopsTheVideo() {
        var model = MiniPlayerModel()
        _ = model.switched(shown: [b], playing: a)
        #expect(model.close() == [.pause(a), .end(a)])
        #expect(model.tab == nil)
        #expect(model.close() == [])
    }

    @Test func itsTabClosingEndsItQuietly() {
        var model = MiniPlayerModel()
        _ = model.switched(shown: [b], playing: a)
        #expect(model.lost(c) == [])
        #expect(model.lost(a) == [.end(a)])
        #expect(model.tab == nil)
    }
}
