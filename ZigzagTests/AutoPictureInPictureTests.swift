import AppKit
import Testing
@testable import Zigzag

/// Leaving Zigzag moves the video you were watching into Zigzag's own mini player, when turned on; coming back to its
/// tab puts it back, only when Zigzag moved it (#238).
@MainActor struct AutoPictureInPictureTests {
    private typealias Model = AutoPictureInPictureModel

    private static func video(playing: Bool = true, muted: Bool = false, user: Bool = false, link: Bool = false, blocks: Bool = false) -> PageVideo {
        PageVideo(index: 0, rect: CGRect(x: 0, y: 0, width: 640, height: 360), natural: CGSize(width: 1280, height: 720), isPlaying: playing,
                  isMuted: muted, isStartedByUser: user, isInLink: link, blocksPictureInPicture: blocks)
    }

    private static func page(video: PageVideo? = video(), inView: Bool = true, tabMuted: Bool = false, presenting: Bool = false,
                             busy: Bool = false) -> Model.Page {
        Model.Page(video: video, isInView: inView, isTabMuted: tabMuted, isPresentingItself: presenting, isMiniPlayerBusy: busy)
    }

    @Test func movesAPlayingVideoYouWereWatching() {
        #expect(Model.moves(Self.page(), isOn: true))
        #expect(Model.moves(Self.page(video: Self.video(user: true)), isOn: true))
    }

    @Test func leavesTheRestAlone() {
        // Off, as it is unless turned on.
        #expect(!Model.moves(Self.page(), isOn: false))
        // No video you were watching: none, paused, a card's preview in a link.
        #expect(!Model.moves(Self.page(video: nil), isOn: true))
        #expect(!Model.moves(Self.page(video: Self.video(playing: false)), isOn: true))
        #expect(!Model.moves(Self.page(video: Self.video(link: true)), isOn: true))
        // Muted, the video or its tab, even one you started yourself.
        #expect(!Model.moves(Self.page(video: Self.video(muted: true)), isOn: true))
        #expect(!Model.moves(Self.page(video: Self.video(muted: true, user: true)), isOn: true))
        #expect(!Model.moves(Self.page(tabMuted: true), isOn: true))
        // Scrolled out of view.
        #expect(!Model.moves(Self.page(inView: false), isOn: true))
        // In Picture in Picture or full screen already (you put it there): never touched.
        #expect(!Model.moves(Self.page(presenting: true), isOn: true))
        // A mini player already showing, yours, stays as it is.
        #expect(!Model.moves(Self.page(busy: true), isOn: true))
        // The page says it mustn't float.
        #expect(!Model.moves(Self.page(video: Self.video(blocks: true)), isOn: true))
    }

    @Test func onlyARealSwitchCounts() {
        func app(zigzag: Bool = false, webApp: Bool = false, regular: Bool = true) -> Model.FrontApp {
            Model.FrontApp(isZigzag: zigzag, isZigzagWebApp: webApp, isRegular: regular)
        }
        // Finder, or any app of yours.
        #expect(Model.isRealSwitch(to: app()))
        // Spotlight, Notification Center, a menu bar item, a system prompt, the Dock: not apps you went to.
        #expect(!Model.isRealSwitch(to: app(regular: false)))
        // Still Zigzag (Zigzag Mini, a popup), or one of its web apps.
        #expect(!Model.isRealSwitch(to: app(zigzag: true)))
        #expect(!Model.isRealSwitch(to: app(webApp: true)))
        #expect(!Model.isRealSwitch(to: nil))
    }

    @Test func waitsAMomentBeforeMoving() {
        // Long enough that a quick click elsewhere and back moves nothing, short enough to be there as you look up.
        #expect(Model.delay >= 0.6)
        #expect(Model.delay <= 1)
    }

    @Test func putsBackOnlyWhatItMovedOnceYoureBackOnItsTab() {
        let id = UUID(), other = UUID()
        var model = Model()
        func leave(_ id: UUID, page: Model.Page) -> Bool { model.leaving(id, page: page, isOn: true) }
        func back(_ id: UUID, isHeld: Bool, isInFront: Bool) -> Bool { model.returning(id, isHeld: isHeld, isInFront: isInFront) }
        #expect(leave(id, page: Self.page()))
        #expect(model.owns(id))
        // Back on another tab or window: it plays on in the mini player.
        #expect(!back(id, isHeld: true, isInFront: false))
        #expect(model.owns(id))
        // Another tab's mini player is never Zigzag's to end.
        #expect(!back(other, isHeld: true, isInFront: true))
        // Back on its tab: it goes back, once.
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
        // Closed or minimized from its card while you were away: nothing to put back, and a mini player you get later
        // isn't ended.
        #expect(!back(id, isHeld: false, isInFront: false))
        #expect(!model.owns(id))
        #expect(!back(id, isHeld: true, isInFront: true))
        // The mini player didn't take it after all.
        #expect(leave(id, page: Self.page()))
        model.forget()
        #expect(!model.owns(id))
        // Not moved: nothing of Zigzag's.
        #expect(!leave(id, page: Self.page(busy: true)))
        #expect(!back(id, isHeld: true, isInFront: true))
    }

    @Test func theMiniPlayerTakesTheTabOnScreen() {
        let tab = UUID(), other = UUID()
        var model = MiniPlayerModel()
        func left(_ id: UUID) -> [MiniPlayerModel.Step] { model.left(id) }
        func switched(to shown: Set<UUID>) -> [MiniPlayerModel.Step] { model.switched(shown: shown, playing: nil) }
        // The tab is still the one on screen: it goes into the player all the same.
        #expect(left(tab) == [.show(tab)])
        #expect(model.tab == tab)
        // Switching tabs back in Zigzag, it stays, as any mini player does.
        #expect(switched(to: [other]) == [])
        // Back on its tab: back in its page.
        #expect(switched(to: [tab]) == [.end(tab)])
        #expect(model.tab == nil)
        // Never in place of one showing already.
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

/// The bottom bar's space icons follow Settings › Appearance › Sidebar size as the rows do, and keep that size when
/// there are many spaces (#238).
struct SpaceIconSizeTests {
    @Test func scalesWithTheSidebar() {
        #expect(Tokens.Sidebar.spaceIcon(for: .small) == 16)
        #expect(Tokens.Sidebar.spaceIcon(for: .medium) == 18)
        #expect(Tokens.Sidebar.spaceIcon(for: .large) == 20)
        // The favorites' icon, in even points at every size.
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
        // Room for all: full keys.
        #expect(Tokens.Sidebar.spaceKeyWidth(available: 166, count: 4, hasIcons: true, smallest: smallest, size: .medium) == 26)
        #expect(Tokens.Sidebar.spaceKeyWidth(available: 166, count: 4, hasIcons: true, smallest: smallest, size: .large) == 28)
        // Crowded: narrower keys, never narrower than the icon and its room.
        #expect(Tokens.Sidebar.spaceKeyWidth(available: 166, count: 7, hasIcons: true, smallest: smallest, size: .medium) == 23)
        for size in Tokens.Sidebar.Size.allCases {
            let width = Tokens.Sidebar.spaceKeyWidth(available: 166, count: 12, hasIcons: true, smallest: smallest, size: size)
            #expect(width == Tokens.Sidebar.spaceIcon(for: size) + Tokens.Sidebar.spaceIconRoom)
        }
        // Dots alone still pack down to the smallest target.
        #expect(Tokens.Sidebar.spaceKeyWidth(available: 166, count: 12, hasIcons: false, smallest: smallest, size: .large) == 16)
    }
}
