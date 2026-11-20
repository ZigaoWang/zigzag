import AppKit
import Testing
@testable import Zigzag

/// Sidebar Now Playing cards: which tabs, order, hiding, and reappearing.
@MainActor
struct NowPlayingTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    private func tab(_ id: UUID, _ page: String = "https://video.example/watch?v=1", sounding: Bool = true, selected: Bool = false) -> NowPlayingChoice.Candidate {
        .init(id: id, page: page, sounding: sounding, isSelected: selected)
    }

    @Test func showsTheSoundingTabsYouAreNotOn() {
        var choice = NowPlayingChoice()
        #expect(choice.pick(from: [tab(a, selected: true), tab(b, sounding: false), tab(c)]) == [c])
        // b starts after c: b's card on top, c's by the dots.
        #expect(choice.pick(from: [tab(a, sounding: false, selected: true), tab(b), tab(c)]) == [b, c])
        #expect(choice.pick(from: [tab(a, selected: true)]).isEmpty)
        #expect(choice.pick(from: []).isEmpty)
    }

    /// A paused embedded video whose page WebKit still says plays (its sound went through Web Audio): its card goes
    /// once the sound is over, and the tab playing now gets the card when you leave it.
    @Test func aPausedVideosCardGoesAndThePlayingTabGetsIt() {
        let start = Date()
        var embed = PageSound()
        var choice = NowPlayingChoice()
        func pick(webKit: Bool, media: Bool, at time: TimeInterval, onVideo: Bool) -> [UUID] {
            let sounding = embed.update(webKit: webKit, media: media, now: start + time).playing
            return choice.pick(from: [tab(b, "https://videos.example/", sounding: true, selected: onVideo), tab(a, "https://news.example/", sounding: sounding)])
        }
        #expect(pick(webKit: true, media: true, at: 0, onVideo: false) == [b, a])
        #expect(pick(webKit: true, media: false, at: 10, onVideo: true) == [a])
        #expect(pick(webKit: true, media: false, at: 10 + PageSound.hold, onVideo: true).isEmpty)
        #expect(pick(webKit: true, media: false, at: 600, onVideo: false) == [b])
    }

    @Test func everyTabThatStartsGetsACardOnTopAndNoneMove() {
        var choice = NowPlayingChoice()
        let on = tab(e, sounding: false, selected: true)
        #expect(choice.pick(from: [on, tab(a)]) == [a])
        // Recent order puts b first, but a started first: a stays at the bottom.
        #expect(choice.pick(from: [on, tab(b), tab(a)]) == [b, a])
        #expect(choice.pick(from: [on, tab(a), tab(c), tab(b)]) == [c, b, a])
        // One goes quiet: the others keep their order.
        #expect(choice.pick(from: [on, tab(a), tab(c), tab(b, sounding: false)]) == [c, a])
        // Starting again makes it newest.
        #expect(choice.pick(from: [on, tab(a), tab(c), tab(b)]) == [b, c, a])
    }

    @Test func severalStartingAtOnceTheOneUsedLastIsTheNewest() {
        var choice = NowPlayingChoice()
        #expect(choice.pick(from: [tab(e, sounding: false, selected: true), tab(a), tab(b), tab(c)]) == [a, b, c])
    }

    @Test func atMostThreeTheMostRecent() {
        #expect(NowPlayingChoice.limit == 3)
        var choice = NowPlayingChoice()
        let on = tab(e, sounding: false, selected: true)
        _ = choice.pick(from: [on, tab(a)])
        _ = choice.pick(from: [on, tab(b), tab(a)])
        _ = choice.pick(from: [on, tab(c), tab(b), tab(a)])
        #expect(choice.pick(from: [on, tab(d), tab(c), tab(b), tab(a)]) == [d, c, b])
        // The newest goes quiet: the one it pushed out returns.
        #expect(choice.pick(from: [on, tab(d, sounding: false), tab(c), tab(b), tab(a)]) == [c, b, a])
    }

    @Test func goingToATabTakesOnlyItsCardAndItComesBackInItsPlace() {
        var choice = NowPlayingChoice()
        _ = choice.pick(from: [tab(e, sounding: false, selected: true), tab(a)])
        _ = choice.pick(from: [tab(e, sounding: false, selected: true), tab(b), tab(a)])
        #expect(choice.pick(from: [tab(e, sounding: false, selected: true), tab(c), tab(b), tab(a)]) == [c, b, a])
        #expect(choice.pick(from: [tab(b, selected: true), tab(e, sounding: false), tab(c), tab(a)]) == [c, a])
        #expect(choice.pick(from: [tab(e, sounding: false, selected: true), tab(b), tab(c), tab(a)]) == [c, b, a])
    }

    @Test func hidingOneCardLeavesTheOthers() {
        var choice = NowPlayingChoice()
        let on = tab(e, sounding: false, selected: true)
        _ = choice.pick(from: [on, tab(a)])
        #expect(choice.pick(from: [on, tab(b), tab(a)]) == [b, a])
        choice.hide(b, page: "https://video.example/watch?v=1")
        #expect(choice.pick(from: [on, tab(b), tab(a)]) == [a])
        // Hidden past the limit, the next most recent takes its place.
        _ = choice.pick(from: [on, tab(c), tab(b), tab(a)])
        #expect(choice.pick(from: [on, tab(d), tab(c), tab(b), tab(a)]) == [d, c, a])
    }

    @Test func pausedInTheMiniPlayerKeepsTheCard() {
        // Paused in the mini player: no sound, but the card stays and shows Play.
        #expect(NowPlayingChoice.isSounding(playing: false, pausedFromCard: false, inMiniPlayer: true))
        #expect(NowPlayingChoice.isPaused(playing: false, pausedFromCard: false, inMiniPlayer: true))
        // Playing there again: Pause.
        #expect(!NowPlayingChoice.isPaused(playing: true, pausedFromCard: false, inMiniPlayer: true))
        // Paused from the card, as before.
        #expect(NowPlayingChoice.isSounding(playing: false, pausedFromCard: true, inMiniPlayer: false))
        #expect(NowPlayingChoice.isPaused(playing: false, pausedFromCard: true, inMiniPlayer: false))
        // Stopped by the page with no mini player: no card.
        #expect(!NowPlayingChoice.isSounding(playing: false, pausedFromCard: false, inMiniPlayer: false))
        var choice = NowPlayingChoice()
        let paused = NowPlayingChoice.isSounding(playing: false, pausedFromCard: false, inMiniPlayer: true)
        #expect(choice.pick(from: [tab(a, sounding: false, selected: true), tab(b, sounding: paused)]) == [b])
    }

    @Test func aMutedVideoPlayingInTheMiniPlayerShowsPause() {
        // A muted playing video makes no sound; the card shows Pause, then Play once paused.
        let playing = NowPlayingChoice.isPlaying(sound: false, miniPlayerVideo: true)
        #expect(!NowPlayingChoice.isPaused(playing: playing, pausedFromCard: false, inMiniPlayer: true))
        let stopped = NowPlayingChoice.isPlaying(sound: false, miniPlayerVideo: false)
        #expect(NowPlayingChoice.isPaused(playing: stopped, pausedFromCard: false, inMiniPlayer: true))
        // Outside the mini player, the tab's sound decides.
        #expect(NowPlayingChoice.isPlaying(sound: true, miniPlayerVideo: nil))
        #expect(!NowPlayingChoice.isPlaying(sound: false, miniPlayerVideo: nil))
    }

    @Test func hiddenItStaysAwayWhileTheTabPlaysOn() {
        var choice = NowPlayingChoice()
        let page = "https://video.example/watch?v=1"
        choice.hide(a, page: page)
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a, page)]).isEmpty)
        // Paused in the page and played again, on the same page: still away.
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a, page, sounding: false)]).isEmpty)
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a, page)]).isEmpty)
        // Going to the tab and leaving it again doesn't bring it back either.
        #expect(choice.pick(from: [tab(a, page, selected: true)]).isEmpty)
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a, page)]).isEmpty)
    }

    @Test func anotherTabMakingSoundGetsTheCard() {
        var choice = NowPlayingChoice()
        choice.hide(a, page: "https://video.example/watch?v=1")
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a), tab(b, "https://music.example/")]) == [b])
        // That one quiet again: the hidden one stays hidden.
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a), tab(b, "https://music.example/", sounding: false)]).isEmpty)
    }

    @Test func itComesBackWhenTheTabGoesToAnotherPage() {
        var choice = NowPlayingChoice()
        choice.hide(a, page: "https://video.example/watch?v=1")
        #expect(choice.pick(from: [tab(c, selected: true), tab(a, "https://video.example/watch?v=2")]) == [a])
        #expect(choice.hidden.isEmpty)
        // Back on the first page, it's something new again: it doesn't hide by itself.
        #expect(choice.pick(from: [tab(c, selected: true), tab(a, "https://video.example/watch?v=1")]) == [a])
    }

    @Test func aJumpWithinThePageIsNotSomethingNew() {
        #expect(NowPlayingChoice.page(of: URL(string: "https://video.example/watch?v=1#t=30")) == "https://video.example/watch?v=1")
        #expect(NowPlayingChoice.page(of: nil) == "")
        var choice = NowPlayingChoice()
        choice.hide(a, page: NowPlayingChoice.page(of: URL(string: "https://video.example/watch?v=1")))
        let jumped = NowPlayingChoice.page(of: URL(string: "https://video.example/watch?v=1#chapter-2"))
        #expect(choice.pick(from: [tab(c, selected: true), tab(a, jumped)]).isEmpty)
    }

    @Test func aClosedTabIsForgotten() {
        var choice = NowPlayingChoice()
        choice.hide(a, page: "https://video.example/watch?v=1")
        #expect(choice.pick(from: [tab(c, selected: true)]).isEmpty)
        #expect(choice.hidden.isEmpty)
    }

    @Test func theCardIsARowsHeightAtEverySize() {
        let was = Tokens.Sidebar.size
        defer { Tokens.Sidebar.size = was }
        for size in Tokens.Sidebar.Size.allCases {
            Tokens.Sidebar.size = size
            #expect(Tokens.Sidebar.nowPlayingHeight == Tokens.Sidebar.rowHeight)
            #expect(Tokens.Sidebar.nowPlayingHeight >= Tokens.Sidebar.rowButton + 2 * SidebarRowView.buttonEdge)
        }
    }

    @Test func theButtonsLineUpWithARowsAndTheCloseComesLast() {
        let view = NowPlayingView(frame: NSRect(x: 0, y: 0, width: 228, height: Tokens.Sidebar.nowPlayingHeight))
        view.layoutSubtreeIfNeeded()
        view.layout()
        let b = Tokens.Sidebar.rowButton
        #expect(view.hideButton.frame.maxX == 228 - SidebarRowView.buttonEdge)
        #expect(view.hideButton.frame.width == b)
        #expect(view.muteButton.frame.maxX == view.hideButton.frame.minX - 2)
        #expect(view.playButton.frame.maxX == view.muteButton.frame.minX - 2)
        // Nothing moves or appears as the pointer comes: a click aimed at mute lands on mute.
        let frames = [view.playButton.frame, view.muteButton.frame, view.hideButton.frame]
        view.isHovered = true
        view.layout()
        #expect([view.playButton.frame, view.muteButton.frame, view.hideButton.frame] == frames)
        #expect(view.hideButton.alphaValue == 1)
        #expect(view.hitTest(NSPoint(x: view.hideButton.frame.midX, y: view.hideButton.frame.midY)) === view.hideButton)
    }

    @Test func hidingCallsBackAndVoiceOverCanHideIt() {
        let view = NowPlayingView(frame: NSRect(x: 0, y: 0, width: 228, height: Tokens.Sidebar.nowPlayingHeight))
        var hidden = 0
        view.onHide = { hidden += 1 }
        view.hideButton.accessibilityPerformPress()
        #expect(hidden == 1)
        let actions = view.accessibilityCustomActions() ?? []
        #expect(actions.count == 2)
        _ = actions.last?.handler?()
        #expect(hidden == 2)
        #expect(view.hideButton.accessibilityLabel() == "Hide")
    }

    @Test func theSidebarStacksACardForEachTabAndEachHidesItsOwn() {
        let was = Tokens.Sidebar.size
        defer { Tokens.Sidebar.size = was }
        let tabs = ["One", "Two", "Three"].map { Tab(url: URL(string: "https://\($0.lowercased()).example/"), title: $0, spaceID: UUID()) }
        for size in Tokens.Sidebar.Size.allCases {
            Tokens.Sidebar.size = size
            let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 700))
            var hidden: [UUID] = []
            sidebar.onNowPlayingHide = { hidden.append($0.id) }
            sidebar.setNowPlaying(tabs.map { (tab: $0, paused: false) })
            sidebar.layoutSubtreeIfNeeded()
            let cards = sidebar.nowPlayingCards
            #expect(cards.map { $0.tab?.id } == tabs.map(\.id))
            // Top to bottom: row height each, small gaps, same width.
            for (upper, lower) in zip(cards, cards.dropFirst()) {
                #expect(lower.frame.minY == upper.frame.maxY + Tokens.Space.x1)
                #expect(lower.frame.width == upper.frame.width)
            }
            #expect(cards.allSatisfy { $0.frame.height == Tokens.Sidebar.nowPlayingHeight })
            // Each has a VoiceOver label naming its tab.
            #expect(cards.map { $0.accessibilityLabel() ?? "" } == tabs.map { "Now playing: \($0.displayTitle)" })
            cards[1].hideButton.accessibilityPerformPress()
            #expect(hidden == [tabs[1].id])
            // Same tabs keep their cards; removing one leaves the others in place.
            sidebar.setNowPlaying([(tab: tabs[0], paused: true), (tab: tabs[2], paused: false)], hiding: tabs[1].id)
            #expect(sidebar.nowPlayingCards.first === cards[0])
            #expect(sidebar.nowPlayingCards.last === cards[2])
            #expect(cards[0].isPaused)
            #expect(cards[1].isLeaving)
        }
    }
}
