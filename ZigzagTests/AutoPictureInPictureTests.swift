import AppKit
import Testing
@testable import Zigzag

/// Leaving Zigzag floats the video you were watching in Picture in Picture; coming back to its page puts it back,
/// only when Zigzag floated it (#238).
@MainActor struct AutoPictureInPictureTests {
    private typealias Model = AutoPictureInPictureModel

    private static func video(muted: Bool = false, user: Bool = false, blocks: Bool = false) -> PageVideo {
        PageVideo(index: 0, rect: CGRect(x: 0, y: 0, width: 640, height: 360), natural: CGSize(width: 1280, height: 720), isPlaying: true,
                  isMuted: muted, isStartedByUser: user, blocksPictureInPicture: blocks)
    }

    private static func page(canFloat: Bool = true, floating: Bool = false, fullScreen: Bool = false, video: PageVideo? = video()) -> Model.Page {
        Model.Page(canFloat: canFloat, isFloating: floating, isFullScreen: fullScreen, video: video)
    }

    @Test func floatsAPlayingVideoYouWereWatching() {
        #expect(Model.floats(Self.page(), isOn: true))
        // A muted one you started yourself counts too.
        #expect(Model.floats(Self.page(video: Self.video(muted: true, user: true)), isOn: true))
    }

    @Test func leavesTheRestAlone() {
        // Turned off in Settings.
        #expect(!Model.floats(Self.page(), isOn: false))
        // Nothing WebKit can float, or no video you were watching (a muted autoplay isn't one).
        #expect(!Model.floats(Self.page(canFloat: false), isOn: true))
        #expect(!Model.floats(Self.page(video: nil), isOn: true))
        // Already floating (you floated it), or in full screen on a desktop of its own.
        #expect(!Model.floats(Self.page(floating: true), isOn: true))
        #expect(!Model.floats(Self.page(fullScreen: true), isOn: true))
        // The page says it mustn't float.
        #expect(!Model.floats(Self.page(video: Self.video(blocks: true)), isOn: true))
    }

    @Test func endsOnlyWhatItFloatedOnceYoureBackOnItsPage() {
        let page = NSObject(), other = NSObject()
        let id = ObjectIdentifier(page), otherID = ObjectIdentifier(other)
        var model = Model()
        func leave(_ id: ObjectIdentifier, page: Model.Page, isOn: Bool) -> Bool { model.leaving(id, page: page, isOn: isOn) }
        func back(_ id: ObjectIdentifier, isFloating: Bool, isInFront: Bool) -> Bool { model.returning(id, isFloating: isFloating, isInFront: isInFront) }
        #expect(leave(id, page: Self.page(), isOn: true))
        #expect(model.owns(id))
        // Back on another tab: it floats on.
        #expect(!back(id, isFloating: true, isInFront: false))
        #expect(model.owns(id))
        // Another page's Picture in Picture is never Zigzag's to end.
        #expect(!back(otherID, isFloating: true, isInFront: true))
        // Back on its tab: it ends, once.
        #expect(back(id, isFloating: true, isInFront: true))
        #expect(!model.owns(id))
        #expect(!back(id, isFloating: true, isInFront: true))
    }

    @Test func neverEndsPictureInPictureYouStarted() {
        let page = NSObject()
        let id = ObjectIdentifier(page)
        var model = Model()
        func leave(_ id: ObjectIdentifier, page: Model.Page, isOn: Bool) -> Bool { model.leaving(id, page: page, isOn: isOn) }
        func back(_ id: ObjectIdentifier, isFloating: Bool, isInFront: Bool) -> Bool { model.returning(id, isFloating: isFloating, isInFront: isInFront) }
        // Already floating as you leave: not Zigzag's.
        #expect(!leave(id, page: Self.page(floating: true), isOn: true))
        #expect(!back(id, isFloating: true, isInFront: true))
    }

    @Test func forgetsOneClosedAnotherWay() {
        let page = NSObject()
        let id = ObjectIdentifier(page)
        var model = Model()
        func leave(_ id: ObjectIdentifier, page: Model.Page, isOn: Bool) -> Bool { model.leaving(id, page: page, isOn: isOn) }
        func back(_ id: ObjectIdentifier, isFloating: Bool, isInFront: Bool) -> Bool { model.returning(id, isFloating: isFloating, isInFront: isInFront) }
        #expect(leave(id, page: Self.page(), isOn: true))
        // Closed by its own button while you were away: nothing to end, and one you float yourself later isn't ended.
        #expect(!back(id, isFloating: false, isInFront: false))
        #expect(!model.owns(id))
        #expect(!back(id, isFloating: true, isInFront: true))
        // WebKit declined it after all.
        #expect(leave(id, page: Self.page(), isOn: true))
        model.stopped(id)
        #expect(!model.owns(id))
    }

    @Test func settingIsOnByDefault() {
        let key = "PictureInPictureWhenLeaving"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
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
