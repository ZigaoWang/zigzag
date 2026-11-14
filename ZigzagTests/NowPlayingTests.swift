import AppKit
import Testing
@testable import Zigzag

/// The sidebar's Now Playing card: which tab it's for, hiding it, and when it comes back.
@MainActor
struct NowPlayingTests {
    let a = UUID(), b = UUID(), c = UUID()

    private func tab(_ id: UUID, _ page: String = "https://video.example/watch?v=1", sounding: Bool = true, selected: Bool = false) -> NowPlayingChoice.Candidate {
        .init(id: id, page: page, sounding: sounding, isSelected: selected)
    }

    @Test func showsTheMostRecentSoundingTabYouAreNotOn() {
        var choice = NowPlayingChoice()
        #expect(choice.pick(from: [tab(a, selected: true), tab(b, sounding: false), tab(c)]) == c)
        #expect(choice.pick(from: [tab(a, sounding: false, selected: true), tab(b), tab(c)]) == b)
        #expect(choice.pick(from: [tab(a, selected: true)]) == nil)
        #expect(choice.pick(from: []) == nil)
    }

    @Test func hiddenItStaysAwayWhileTheTabPlaysOn() {
        var choice = NowPlayingChoice()
        let page = "https://video.example/watch?v=1"
        choice.hide(a, page: page)
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a, page)]) == nil)
        // Paused in the page and played again, on the same page: still away.
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a, page, sounding: false)]) == nil)
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a, page)]) == nil)
        // Going to the tab and leaving it again doesn't bring it back either.
        #expect(choice.pick(from: [tab(a, page, selected: true)]) == nil)
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a, page)]) == nil)
    }

    @Test func anotherTabMakingSoundGetsTheCard() {
        var choice = NowPlayingChoice()
        choice.hide(a, page: "https://video.example/watch?v=1")
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a), tab(b, "https://music.example/")]) == b)
        // That one quiet again: the hidden one stays hidden.
        #expect(choice.pick(from: [tab(c, sounding: false, selected: true), tab(a), tab(b, "https://music.example/", sounding: false)]) == nil)
    }

    @Test func itComesBackWhenTheTabGoesToAnotherPage() {
        var choice = NowPlayingChoice()
        choice.hide(a, page: "https://video.example/watch?v=1")
        #expect(choice.pick(from: [tab(c, selected: true), tab(a, "https://video.example/watch?v=2")]) == a)
        #expect(choice.hidden.isEmpty)
        // Back on the first page, it's something new again: it doesn't hide by itself.
        #expect(choice.pick(from: [tab(c, selected: true), tab(a, "https://video.example/watch?v=1")]) == a)
    }

    @Test func aJumpWithinThePageIsNotSomethingNew() {
        #expect(NowPlayingChoice.page(of: URL(string: "https://video.example/watch?v=1#t=30")) == "https://video.example/watch?v=1")
        #expect(NowPlayingChoice.page(of: nil) == "")
        var choice = NowPlayingChoice()
        choice.hide(a, page: NowPlayingChoice.page(of: URL(string: "https://video.example/watch?v=1")))
        let jumped = NowPlayingChoice.page(of: URL(string: "https://video.example/watch?v=1#chapter-2"))
        #expect(choice.pick(from: [tab(c, selected: true), tab(a, jumped)]) == nil)
    }

    @Test func aClosedTabIsForgotten() {
        var choice = NowPlayingChoice()
        choice.hide(a, page: "https://video.example/watch?v=1")
        #expect(choice.pick(from: [tab(c, selected: true)]) == nil)
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
        #expect(view.muteButton.frame.maxX == view.hideButton.frame.minX - 2)
        #expect(view.playButton.frame.maxX == view.muteButton.frame.minX - 2)
        #expect(view.hideButton.frame.width == b)
        // Play and mute stay put as the close comes and goes.
        let play = view.playButton.frame
        view.isHovered = true
        view.layout()
        #expect(view.playButton.frame == play)
        view.isHovered = false
        // At rest the close is out of sight and takes no click; under the pointer it shows.
        #expect(view.hideButton.alphaValue == 0)
        #expect(view.hitTest(NSPoint(x: view.hideButton.frame.midX, y: view.hideButton.frame.midY)) === view)
        view.isHovered = true
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
}
