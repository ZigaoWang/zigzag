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
        var silentBig = video(0, CGRect(x: 0, y: 0, width: 960, height: 540), muted: true)
        silentBig.isStartedByUser = true
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
        // Controls showing don't make a muted autoplay one you're watching.
        background.hasControls = true
        #expect(!MiniPlayerLayout.follows(background))
    }

    // MARK: Which video follows you out (#156)

    private func page(_ videos: PageVideo...) -> [(viewport: CGSize, videos: [PageVideo])] { [(viewport, videos)] }

    @Test func aMutedVideoFollowsOnlyWhenYouStartedIt() {
        var muted = video(0, CGRect(x: 0, y: 0, width: 960, height: 540), muted: true)
        #expect(MiniPlayerLayout.followed(in: page(muted), leavingPage: false, presentingItself: false) == nil)
        // Pressed play, or turned its sound on, yourself: a silent video you're watching follows.
        muted.isStartedByUser = true
        #expect(MiniPlayerLayout.followed(in: page(muted), leavingPage: false, presentingItself: false)?.video.index == 0)
    }

    @Test func aVideoYouCanHearFollows() {
        let audible = video(0, CGRect(x: 0, y: 0, width: 960, height: 540))
        #expect(MiniPlayerLayout.followed(in: page(audible), leavingPage: false, presentingItself: false)?.video.index == 0)
        // Scrolled on past it to the comments, it still follows.
        let below = video(0, CGRect(x: 0, y: -900, width: 960, height: 540))
        #expect(MiniPlayerLayout.followed(in: page(below), leavingPage: false, presentingItself: false) != nil)
    }

    @Test func aHomepagesHoverPreviewNeverFollows() {
        // A card's preview, playing under the pointer as you click through to the video's own page.
        var preview = video(0, CGRect(x: 300, y: 200, width: 290, height: 163), muted: true)
        preview.isInLink = true
        #expect(MiniPlayerLayout.followed(in: page(preview), leavingPage: false, presentingItself: false) == nil)
        // With its sound on by itself, still a preview.
        preview.isMuted = false
        #expect(MiniPlayerLayout.followed(in: page(preview), leavingPage: false, presentingItself: false) == nil)
        // Its sound turned on by you: you're watching it.
        preview.isStartedByUser = true
        #expect(MiniPlayerLayout.followed(in: page(preview), leavingPage: false, presentingItself: false) != nil)
        // A muted autoplay beside a video you started: yours follows, however much bigger the other is.
        var mine = video(1, CGRect(x: 0, y: 600, width: 320, height: 180), muted: true)
        mine.isStartedByUser = true
        let other = video(2, CGRect(x: 0, y: 0, width: 960, height: 540), muted: true)
        #expect(MiniPlayerLayout.followed(in: page(mine, other), leavingPage: false, presentingItself: false)?.video.index == 1)
    }

    @Test func nothingFollowsAPageOnItsWayOut() {
        let audible = video(0, CGRect(x: 0, y: 0, width: 960, height: 540))
        #expect(MiniPlayerLayout.followed(in: page(audible), leavingPage: true, presentingItself: false) == nil)
        // Floating or filling the screen with it itself: the page's own player has it.
        #expect(MiniPlayerLayout.followed(in: page(audible), leavingPage: false, presentingItself: true) == nil)
    }

    @Test func theBestOfAllFramesFollows() {
        let ad = video(0, CGRect(x: 0, y: 0, width: 300, height: 250), muted: true)
        let player = video(0, CGRect(x: 0, y: 0, width: 640, height: 360))
        let frames: [(viewport: CGSize, videos: [PageVideo])] = [(viewport, [ad]), (CGSize(width: 640, height: 360), [player])]
        let found = MiniPlayerLayout.followed(in: frames, leavingPage: false, presentingItself: false)
        #expect(found?.frame == 1)
        #expect(found?.video == player)
        #expect(MiniPlayerLayout.followed(in: [], leavingPage: false, presentingItself: false) == nil)
    }

    @Test func readsWhatThePageSays() {
        let parsed = PageVideo(["i": 2, "x": 10, "y": 20.5, "w": 640, "h": 360, "vw": 1280, "vh": 720, "playing": true, "ended": false,
                                "muted": false, "loop": false, "autoplay": true, "controls": false, "user": true, "link": true, "fit": "cover",
                                "t": 12.5, "d": -1] as [String: Any])
        #expect(parsed?.index == 2)
        #expect(parsed?.rect == CGRect(x: 10, y: 20.5, width: 640, height: 360))
        #expect(parsed?.fit == "cover")
        #expect(parsed?.isStartedByUser == true)
        #expect(parsed?.isInLink == true)
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

    /// A 1280 by 805 screen's usable part, its edges `edgeInset` in: the card floats anywhere on it (#172).
    private let window = MiniPlayerLayout.movableArea(onScreen: CGRect(x: 0, y: 0, width: 1280, height: 805))
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

    @Test func letGoNearAnEdgeItStaysWhereItWasLetGo() {
        // Near an edge or a corner, it doesn't jump onto it: it rests exactly where it was let go.
        let near = CGRect(x: 15, y: 300, width: 333, height: 187)
        #expect(MiniPlayerLayout.dropped(near, in: window) == near)
        let corner = CGRect(x: 1280 - 333 - 20, y: 805 - 187 - 5, width: 333, height: 187)
        #expect(MiniPlayerLayout.dropped(corner, in: window) == corner)
    }

    @Test func aPressNearItsEdgesResizes() {
        let size = CGSize(width: 333, height: 187)
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: 6, y: 90), in: size) == [.left])
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: 327, y: 90), in: size) == [.right])
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: 10, y: 10), in: size) == [.top, .left])
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: 160, y: 90), in: size).isEmpty)
    }

    @Test func itKeepsToItsCornerAsTheWindowResizes() {
        let dropped = CGRect(x: 900, y: 580, width: 333, height: 187)
        let anchor = MiniPlayerLayout.anchor(of: dropped, in: window)
        #expect(anchor.corner == .bottomRight)
        #expect(MiniPlayerLayout.frame(for: anchor, size: card, in: window) == dropped)
        // A smaller window: the same distance from the bottom right.
        let smaller = MiniPlayerLayout.movableArea(onScreen: CGRect(x: 0, y: 0, width: 1000, height: 700))
        let moved = MiniPlayerLayout.frame(for: anchor, size: card, in: smaller)
        #expect(1000 - moved.maxX == 1280 - dropped.maxX)
        #expect(700 - moved.maxY == 805 - dropped.maxY)
        // Too small for that distance: still wholly inside.
        let tiny = MiniPlayerLayout.movableArea(onScreen: CGRect(x: 0, y: 0, width: 400, height: 260))
        #expect(tiny.contains(MiniPlayerLayout.frame(for: MiniPlayerLayout.Anchor(corner: .topLeft, offset: CGSize(width: 300, height: 300)), size: card, in: tiny)))
    }

    @Test func itsPlaceIsKeptAsText() {
        let anchor = MiniPlayerLayout.Anchor(corner: .bottomLeft, offset: CGSize(width: 51, height: 258))
        #expect(MiniPlayerLayout.Anchor(stored: anchor.stored) == anchor)
        #expect(MiniPlayerLayout.Anchor(stored: "middle 1 2") == nil)
        #expect(MiniPlayerLayout.Anchor(stored: "topLeft x 2") == nil)
    }

    @Test func screenCoordinatesTurnOverAndBack() {
        // The Mac's screen coordinates run up from the main screen's bottom; the card's arithmetic runs down from its top.
        let cocoa = CGRect(x: 100, y: 50, width: 320, height: 180)
        let down = MiniPlayerLayout.flipped(cocoa, mainScreenHeight: 900)
        #expect(down == CGRect(x: 100, y: 900 - 50 - 180, width: 320, height: 180))
        #expect(MiniPlayerLayout.flipped(down, mainScreenHeight: 900) == cocoa)
        // A screen above the main one is above its top: negative.
        #expect(MiniPlayerLayout.flipped(CGRect(x: 0, y: 900, width: 1440, height: 900), mainScreenHeight: 900).minY == -900)
    }

    // MARK: Snapping to a corner

    /// A browser window on that screen, and its page area beside a 240-point sidebar.
    private let browser = CGRect(x: 0, y: 0, width: 1280, height: 805)
    private let pageArea = CGRect(x: 240, y: 4, width: 1036, height: 797)

    @Test func letGoItGlidesIntoThePagesNearestCorner() {
        // Let go a little up and left of the bottom right: into that corner, a margin in.
        let there = CGRect(x: 800, y: 500, width: 333, height: 187)
        let (frame, place) = MiniPlayerLayout.rest(there, free: false, page: pageArea, window: browser, in: window)
        #expect(place == .corner(.bottomRight))
        #expect(frame == CGRect(x: 1276 - 12 - 333, y: 801 - 12 - 187, width: 333, height: 187))
        // Over the sidebar at the top: the page's top left, not the sidebar's.
        let sidebar = MiniPlayerLayout.rest(CGRect(x: 10, y: 60, width: 333, height: 187), free: false, page: pageArea, window: browser, in: window)
        #expect(sidebar.place == .corner(.topLeft))
        #expect(sidebar.frame.origin == CGPoint(x: 252, y: 16))
    }

    @Test func letGoOutsideTheWindowItGlidesIntoTheScreensCorner() {
        // A 2560 by 1415 screen's usable part, the window in its top left: let go off the window, toward the bottom right.
        let screen = MiniPlayerLayout.movableArea(onScreen: CGRect(x: 0, y: 25, width: 2560, height: 1415))
        let there = CGRect(x: 1900, y: 1000, width: 333, height: 187)
        let (frame, place) = MiniPlayerLayout.rest(there, free: false, page: pageArea, window: browser, in: screen)
        #expect(place == .screen(.bottomRight))
        // A margin in from the screen's usable edges, as the Mac's Picture in Picture rests.
        #expect(frame == CGRect(x: 2560 - 12 - 333, y: 25 + 1415 - 12 - 187, width: 333, height: 187))
        // With no window on screen (put away in the Dock), anywhere is the screen's.
        #expect(MiniPlayerLayout.rest(CGRect(x: 800, y: 500, width: 333, height: 187), free: false, page: pageArea, window: nil, in: screen).place == .screen(.topLeft))
        // The screen's corner stays the screen's whatever the window does.
        #expect(MiniPlayerLayout.frame(for: .screen(.topLeft), size: card, page: pageArea, in: screen).origin == CGPoint(x: 12, y: 37))
    }

    @Test func letGoWithCommandItStaysWhereItWas() {
        let there = CGRect(x: 600, y: 300, width: 333, height: 187)
        let (frame, place) = MiniPlayerLayout.rest(there, free: true, page: pageArea, window: browser, in: window)
        #expect(frame == there)
        #expect(place == .free(MiniPlayerLayout.anchor(of: there, in: window)))
    }

    @Test func aCornerKeepsToThePageAsTheWindowChanges() {
        let size = CGSize(width: 333, height: 187)
        let frame = MiniPlayerLayout.frame(for: .corner(.bottomLeft), size: size, page: pageArea, in: window)
        #expect(frame.origin == CGPoint(x: 252, y: 801 - 12 - 187))
        // The sidebar hidden: the page is the whole window, and the card goes with its corner.
        let whole = MiniPlayerLayout.frame(for: .corner(.bottomLeft), size: size, page: window, in: window)
        #expect(whole.minX == 16)
    }

    @Test func itsRestingPlaceIsKeptAsText() {
        #expect(MiniPlayerLayout.Place(stored: MiniPlayerLayout.Place.corner(.topRight).stored) == .corner(.topRight))
        #expect(MiniPlayerLayout.Place.screen(.bottomLeft).stored == "screen bottomLeft")
        #expect(MiniPlayerLayout.Place(stored: "screen bottomLeft") == .screen(.bottomLeft))
        #expect(MiniPlayerLayout.Place(stored: "screen middle") == nil)
        let anchor = MiniPlayerLayout.Anchor(corner: .bottomLeft, offset: CGSize(width: 51, height: 258))
        #expect(MiniPlayerLayout.Place(stored: MiniPlayerLayout.Place.free(anchor).stored) == .free(anchor))
        // A place saved before the card snapped stays where it was.
        #expect(MiniPlayerLayout.Place(stored: "bottomRight 8 8") == .free(MiniPlayerLayout.Anchor(corner: .bottomRight, offset: CGSize(width: 8, height: 8))))
        #expect(MiniPlayerLayout.Place(stored: "middle") == nil)
    }

    // MARK: Resizing

    @Test func aSizeYouChoseKeepsForAnyShape() {
        let area = window.size
        #expect(MiniPlayerLayout.cardSize(aspect: 16 / 9, extent: 400, in: area) == CGSize(width: 400, height: 225))
        // A tall video: the same longer side, standing up.
        #expect(MiniPlayerLayout.cardSize(aspect: 9 / 16, extent: 400, in: area) == CGSize(width: 225, height: 400))
        // Never smaller than its controls need, nor more than most of the window.
        #expect(MiniPlayerLayout.cardSize(aspect: 16 / 9, extent: 50, in: area).width == MiniPlayerLayout.smallestCard.width)
        let huge = MiniPlayerLayout.cardSize(aspect: 16 / 9, extent: 5000, in: area)
        #expect(huge.width <= area.width * MiniPlayerLayout.largestShare)
        #expect(huge.height <= area.height * MiniPlayerLayout.largestShare)
    }

    @Test func itsEdgesAndCornersTakeHold() {
        let size = CGSize(width: 320, height: 180)
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: 2, y: 90), in: size) == .left)
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: 318, y: 90), in: size) == .right)
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: 160, y: 1), in: size) == .top)
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: 160, y: 178), in: size) == .bottom)
        // A corner reaches a little further in than an edge.
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: 9, y: 9), in: size) == [.left, .top])
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: 312, y: 172), in: size) == [.right, .bottom])
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: 160, y: 90), in: size).isEmpty)
        #expect(MiniPlayerLayout.edges(at: CGPoint(x: -3, y: 90), in: size).isEmpty)
    }

    @Test func draggingACornerKeepsTheShapeAndTheOppositeCorner() {
        let card = CGRect(x: 931, y: 602, width: 320, height: 180)
        let bigger = MiniPlayerLayout.resized(card, from: [.left, .top], by: CGSize(width: -160, height: -10), in: window)
        #expect(bigger.maxX == card.maxX)
        #expect(bigger.maxY == card.maxY)
        #expect(bigger.width == 480)
        #expect(bigger.height == 270)
        // The other way: down to the smallest, no further.
        let smaller = MiniPlayerLayout.resized(card, from: [.left, .top], by: CGSize(width: 400, height: 400), in: window)
        #expect(smaller.width == MiniPlayerLayout.smallestCard.width)
        #expect(smaller.maxX == card.maxX)
    }

    @Test func draggingAnEdgeKeepsTheCardInItsCorner() {
        let card = CGRect(x: 931, y: 602, width: 320, height: 180)
        // The left edge out: the right stays, and the bottom, the side nearer the window's edge.
        let wider = MiniPlayerLayout.resized(card, from: .left, by: CGSize(width: -80, height: 0), in: window)
        #expect(wider == CGRect(x: 851, y: 557, width: 400, height: 225))
        // The top edge up: height leads.
        let taller = MiniPlayerLayout.resized(card, from: .top, by: CGSize(width: 0, height: -45), in: window)
        #expect(taller == CGRect(x: 851, y: 557, width: 400, height: 225))
    }

    @Test func itNeverGrowsOutOfTheWindow() {
        let card = CGRect(x: 931, y: 602, width: 320, height: 180)
        // The bottom right corner pulled far out: only as far as the window goes.
        let pulled = MiniPlayerLayout.resized(card, from: [.right, .bottom], by: CGSize(width: 900, height: 900), in: window)
        #expect(window.contains(pulled))
        #expect(pulled.minX == card.minX)
        #expect(pulled.minY == card.minY)
        #expect(abs(pulled.width / pulled.height - 16 / 9) < 0.02)
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

    // MARK: Kept in the window

    @Test func aPageYouLeavePlayingSoundStaysInTheWindow() {
        // Out of the window, WebKit won't load or start a playlist's next song (#199).
        #expect(MiniPlayerLayout.keepsInWindow(playingSound: true, followed: false, inFullScreen: false))
        // A quiet page goes as ever; the mini player's card and a video's full screen hold the page themselves.
        #expect(!MiniPlayerLayout.keepsInWindow(playingSound: false, followed: false, inFullScreen: false))
        #expect(!MiniPlayerLayout.keepsInWindow(playingSound: true, followed: true, inFullScreen: false))
        #expect(!MiniPlayerLayout.keepsInWindow(playingSound: true, followed: false, inFullScreen: true))
    }

    @Test func aPlaylistHasTimeForItsNextSong() {
        // YouTube Music took up to 8 seconds from the end of one song to the start of the next.
        #expect(MiniPlayerLayout.nextItemWait >= 20)
        // Not kept for good: a page paused for a while leaves the window again.
        #expect(MiniPlayerLayout.nextItemWait <= 120)
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

    @Test func withNoVideoToGrowFromItComesOutOfItsOwnCorner() {
        let area = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(MiniPlayerLayout.growPoint(of: CGRect(x: 1080, y: 680, width: 340, height: 190), in: area) == CGPoint(x: 1, y: 1))
        #expect(MiniPlayerLayout.growPoint(of: CGRect(x: 20, y: 680, width: 340, height: 190), in: area) == CGPoint(x: 0, y: 1))
        #expect(MiniPlayerLayout.growPoint(of: CGRect(x: 20, y: 20, width: 340, height: 190), in: area) == CGPoint(x: 0, y: 0))
        #expect(MiniPlayerLayout.growPoint(of: CGRect(x: 1080, y: 20, width: 340, height: 190), in: area) == CGPoint(x: 1, y: 0))
    }

    @MainActor @Test func itsButtonsTakeTheSameWashesAsItsSiteName() {
        let button = IconButton(symbol: "xmark", size: 28, symbolSize: 13)
        button.isOverMedia = true
        #expect(button.layer?.backgroundColor == nil)
        #expect(button.layer?.cornerRadius == 14)
        button.isHovered = true
        #expect(button.layer?.backgroundColor == Tokens.Color.mediaHover.cgColor)
        #expect(button.layer?.shadowOpacity == 0)
        button.isPressed = true
        #expect(button.layer?.backgroundColor == Tokens.Color.mediaPressed.cgColor)
        button.isPressed = false
        button.isHovered = false
        #expect(button.layer?.shadowOpacity == 0.6)
    }
}
