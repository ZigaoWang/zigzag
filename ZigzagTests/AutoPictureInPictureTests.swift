import AppKit
import Testing
@testable import Zigzag

/// Auto PiP on leaving Zigzag, undone on return only if Zigzag moved it (#238).
@MainActor struct AutoPictureInPictureTests {
    private typealias Model = AutoPictureInPictureModel

    private static func video(playing: Bool = true, muted: Bool = false, user: Bool = true, link: Bool = false, blocks: Bool = false,
                              size: CGSize = CGSize(width: 640, height: 360)) -> PageVideo {
        PageVideo(index: 0, rect: CGRect(origin: .zero, size: size), natural: CGSize(width: 1280, height: 720), isPlaying: playing,
                  isMuted: muted, isStartedByUser: user, isInLink: link, blocksPictureInPicture: blocks)
    }

    private static func page(video: PageVideo? = video(), inView: Bool = true, tabMuted: Bool = false, presenting: Bool = false,
                             busy: Bool = false) -> Model.Page {
        Model.Page(video: video, isInView: inView, isTabMuted: tabMuted, isPresentingItself: presenting, isMiniPlayerBusy: busy)
    }

    @Test func movesAPlayingVideoYouWereWatching() {
        #expect(Model.moves(Self.page(), isOn: true))
        // A long one the page started, heard a while.
        let now = Date()
        var heard = Self.video(user: false)
        heard.heardSince = now.addingTimeInterval(-30)
        heard.duration = 900
        #expect(Model.moves(Self.page(video: heard), isOn: true, now: now))
    }

    /// The same rule as switching tabs (#582): a muted autoplay, a small product video, or one the page started a
    /// moment ago stays in its page.
    @Test func leavesVideosYoureNotWatching() {
        let now = Date()
        #expect(!Model.moves(Self.page(video: Self.video(muted: true, user: false)), isOn: true, now: now))
        #expect(!Model.moves(Self.page(video: Self.video(size: CGSize(width: 300, height: 170))), isOn: true, now: now))
        var fresh = Self.video(user: false)
        fresh.heardSince = now.addingTimeInterval(-2)
        fresh.duration = 900
        #expect(!Model.moves(Self.page(video: fresh), isOn: true, now: now))
        var short = fresh
        short.heardSince = now.addingTimeInterval(-30)
        short.duration = 30
        #expect(!Model.moves(Self.page(video: short), isOn: true, now: now))
    }

    @Test func leavesTheRestAlone() {
        // Off by default.
        #expect(!Model.moves(Self.page(), isOn: false))
        // No playing video: none, paused, or a link preview.
        #expect(!Model.moves(Self.page(video: nil), isOn: true))
        #expect(!Model.moves(Self.page(video: Self.video(playing: false)), isOn: true))
        #expect(!Model.moves(Self.page(video: Self.video(link: true)), isOn: true))
        // Muted video or tab.
        #expect(!Model.moves(Self.page(video: Self.video(muted: true)), isOn: true))
        #expect(!Model.moves(Self.page(video: Self.video(muted: true, user: true)), isOn: true))
        #expect(!Model.moves(Self.page(tabMuted: true), isOn: true))
        #expect(!Model.moves(Self.page(inView: false), isOn: true))
        // Already in PiP or full screen.
        #expect(!Model.moves(Self.page(presenting: true), isOn: true))
        // A mini player already showing.
        #expect(!Model.moves(Self.page(busy: true), isOn: true))
        // The page disallows PiP.
        #expect(!Model.moves(Self.page(video: Self.video(blocks: true)), isOn: true))
    }

    @Test func onlyARealSwitchCounts() {
        func app(zigzag: Bool = false, webApp: Bool = false, regular: Bool = true) -> Model.FrontApp {
            Model.FrontApp(isZigzag: zigzag, isZigzagWebApp: webApp, isRegular: regular)
        }
        // A regular app.
        #expect(Model.isRealSwitch(to: app()))
        // Spotlight, Notification Center, menu extras, system prompts, the Dock.
        #expect(!Model.isRealSwitch(to: app(regular: false)))
        // Zigzag itself (Mini, popups) or its web apps.
        #expect(!Model.isRealSwitch(to: app(zigzag: true)))
        #expect(!Model.isRealSwitch(to: app(webApp: true)))
        #expect(!Model.isRealSwitch(to: nil))
    }

    @Test func waitsAMomentBeforeMoving() {
        // Long enough to ignore a quick click away, short enough to feel immediate.
        #expect(Model.delay >= 0.6)
        #expect(Model.delay <= 1)
    }

    private static func sight(hidden: Bool = false, minimized: Bool = false, inView: Bool = true, window: UInt32? = 1,
                              focus: UInt32? = 1) -> Model.Sight {
        Model.Sight(isHidden: hidden, isMinimized: minimized, isInView: inView, windowDisplay: window, focusDisplay: focus)
    }

    @Test func movesOnlyOnceTheWindowIsOutOfSight() {
        // Hidden, minimized, covered or on a desktop not showing.
        #expect(Model.isOutOfSight(Self.sight(hidden: true)))
        #expect(Model.isOutOfSight(Self.sight(minimized: true)))
        #expect(Model.isOutOfSight(Self.sight(inView: false)))
        #expect(Model.isOutOfSight(Self.sight(inView: false, window: 2)))
        // Another app on the window's own display, as on a single display.
        #expect(Model.isOutOfSight(Self.sight()))
        #expect(Model.isOutOfSight(Self.sight(focus: nil)))
        #expect(Model.isOutOfSight(Self.sight(window: nil)))
    }

    @Test func aWindowInViewOnAnotherDisplayKeepsItsVideo() {
        // Focus moved to the main display, the window still showing on the second (#496).
        #expect(!Model.isOutOfSight(Self.sight(window: 2, focus: 1)))
        // Later covered, minimized, hidden or its desktop switched away: it moves then.
        #expect(Model.isOutOfSight(Self.sight(inView: false, window: 2, focus: 1)))
        #expect(Model.isOutOfSight(Self.sight(minimized: true, window: 2, focus: 1)))
        #expect(Model.isOutOfSight(Self.sight(hidden: true, window: 2, focus: 1)))
        // Or you switch to an app on its display.
        #expect(Model.isOutOfSight(Self.sight(window: 2, focus: 2)))
    }

    @Test func putsBackOnlyWhatItMovedOnceYoureBackOnItsTab() {
        let id = UUID(), other = UUID()
        var model = Model()
        func leave(_ id: UUID, page: Model.Page) -> Bool { model.leaving(id, page: page, isOn: true) }
        func back(_ id: UUID, isHeld: Bool, isInFront: Bool) -> Bool { model.returning(id, isHeld: isHeld, isInFront: isInFront) }
        #expect(leave(id, page: Self.page()))
        #expect(model.owns(id))
        // Another tab or window in front: keeps playing in the mini player.
        #expect(!back(id, isHeld: true, isInFront: false))
        #expect(model.owns(id))
        // Never ends another tab's mini player.
        #expect(!back(other, isHeld: true, isInFront: true))
        // Back on its tab: restored once.
        #expect(back(id, isHeld: true, isInFront: true))
        #expect(!model.owns(id))
        #expect(!back(id, isHeld: true, isInFront: true))
    }

    @Test func forgetsOneClosedAnotherWay() {
        let id = UUID()
        var model = Model()
        func leave(_ id: UUID, page: Model.Page) -> Bool { model.leaving(id, page: page, isOn: true) }
        func back(_ id: UUID, isHeld: Bool, isInFront: Bool) -> Bool { model.returning(id, isHeld: isHeld, isInFront: isInFront) }
        #expect(leave(id, page: Self.page()))
        // Closed or minimized while away: nothing to restore, and a later mini player isn't ended.
        #expect(!back(id, isHeld: false, isInFront: false))
        #expect(!model.owns(id))
        #expect(!back(id, isHeld: true, isInFront: true))
        // The mini player didn't take it.
        #expect(leave(id, page: Self.page()))
        model.forget()
        #expect(!model.owns(id))
        // Not moved by Zigzag.
        #expect(!leave(id, page: Self.page(busy: true)))
        #expect(!back(id, isHeld: true, isInFront: true))
    }

    @Test func theMiniPlayerTakesTheTabOnScreen() {
        let tab = UUID(), other = UUID()
        var model = MiniPlayerModel()
        func left(_ id: UUID) -> [MiniPlayerModel.Step] { model.left(id) }
        func switched(to shown: Set<UUID>) -> [MiniPlayerModel.Step] { model.switched(shown: shown, playing: nil) }
        // Still the visible tab: it goes into the player anyway.
        #expect(left(tab) == [.show(tab)])
        #expect(model.tab == tab)
        // Switching tabs within Zigzag keeps it.
        #expect(switched(to: [other]) == [])
        #expect(switched(to: [tab]) == [.end(tab)])
        #expect(model.tab == nil)
        // Never replaces one already showing.
        _ = left(tab)
        #expect(left(other) == [])
        #expect(model.tab == tab)
    }

    @Test func settingIsOffByDefault() {
        let key = "PictureInPictureWhenLeaving"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(!AutoPictureInPicture.isOn)
        AutoPictureInPicture.isOn = true
        #expect(AutoPictureInPicture.isOn)
        AutoPictureInPicture.isOn = false
        #expect(!AutoPictureInPicture.isOn)
    }

    @Test func readsThePagesNoPictureInPicture() {
        let item: [String: Any] = ["i": 0, "w": 640, "h": 360, "vw": 1280, "vh": 720, "playing": true, "nopip": true]
        #expect(PageVideo(item)?.blocksPictureInPicture == true)
        #expect(PageVideo(["i": 0])?.blocksPictureInPicture == false)
    }
}

/// Space icons in the bottom bar follow the sidebar size setting and keep it with many spaces (#238).
struct SpaceIconSizeTests {
    @Test func scalesWithTheSidebar() {
        #expect(Tokens.Sidebar.spaceIcon(for: .small) == 16)
        #expect(Tokens.Sidebar.spaceIcon(for: .medium) == 18)
        #expect(Tokens.Sidebar.spaceIcon(for: .large) == 20)
        // Same as the favorite icon, even points at every size.
        #expect(Tokens.Sidebar.spaceIcon(for: .medium) == Tokens.Sidebar.favoriteIcon)
        for size in Tokens.Sidebar.Size.allCases { #expect(Tokens.Sidebar.spaceIcon(for: size).truncatingRemainder(dividingBy: 2) == 0) }
    }

    @Test func iconFitsItsKey() {
        for size in Tokens.Sidebar.Size.allCases {
            #expect(Tokens.Sidebar.spaceIcon(for: size) + Tokens.Sidebar.spaceIconRoom <= Tokens.Sidebar.spaceTarget(for: size))
            #expect(Tokens.Sidebar.spaceTarget(for: size) <= Tokens.Sidebar.bottomBarHeight)
        }
    }

    @Test func manySpacesScrollBeforeIconsShrink() {
        let smallest: CGFloat = 16
        // Room for all: full width.
        #expect(Tokens.Sidebar.spaceKeyWidth(available: 166, count: 4, hasIcons: true, smallest: smallest, size: .medium) == 26)
        #expect(Tokens.Sidebar.spaceKeyWidth(available: 166, count: 4, hasIcons: true, smallest: smallest, size: .large) == 28)
        // Crowded: narrower, never below the icon plus padding.
        #expect(Tokens.Sidebar.spaceKeyWidth(available: 166, count: 7, hasIcons: true, smallest: smallest, size: .medium) == 23)
        for size in Tokens.Sidebar.Size.allCases {
            let width = Tokens.Sidebar.spaceKeyWidth(available: 166, count: 12, hasIcons: true, smallest: smallest, size: size)
            #expect(width == Tokens.Sidebar.spaceIcon(for: size) + Tokens.Sidebar.spaceIconRoom)
        }
        // Dots alone shrink to the smallest target.
        #expect(Tokens.Sidebar.spaceKeyWidth(available: 166, count: 12, hasIcons: false, smallest: smallest, size: .large) == 16)
    }
}
