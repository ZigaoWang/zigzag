import AppKit

/// When a tab you're not looking at plays sound, a small control sits above the space dots, one for each such tab:
/// the site, play/pause and mute. Click the title to go there. It's laid out as a tab's row is: the same height,
/// icon and text columns, and the same small buttons at its end, with a close button last, always
/// there, that hides the card for what that tab is playing now; the sound plays on.
final class NowPlayingView: InteractiveView {
    private let icon = FaviconView()
    private let title = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
    let playButton = TabRowView.rowButton("pause.fill", toolTip: String(localized: "Pause", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background."))
    let muteButton = TabRowView.rowButton("speaker.wave.2", toolTip: String(localized: "Mute Tab", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background."))
    /// Last, where a tab row's close is. Always there: a button that appeared on hover would push play and mute aside
    /// just as the pointer reached them, and a click meant for mute would hide the card.
    let hideButton = TabRowView.rowButton("xmark", toolTip: String(localized: "Hide", comment: "Tooltip, VoiceOver action and menu item of the close button on the sidebar's Now Playing control: hides the control; the tab keeps playing."))
    /// Hides the card for what's playing now: the close button, the menu's Hide and VoiceOver's.
    var onHide: (() -> Void)?
    private(set) weak var tab: Tab?
    private var sizeObserver: NSObjectProtocol?
    var isPaused = false { didSet { refresh() } }
    /// Fading away, its tab quiet or hidden; it keeps its place until it's gone (`SidebarView.setNowPlaying`).
    var isLeaving = false
    /// Counts its leavings, so a fade that was turned around doesn't take it away when it ends.
    var leaves = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Sidebar.rowRadius
        layer?.cornerCurve = .continuous
        // A long title fades out at its end, as a tab row's does.
        title.fadesTail = true
        [icon, title, playButton, muteButton, hideButton].forEach { addSubview($0) }
        hideButton.onClick = { [weak self] _ in self?.onHide?() }
        // Settings › Appearance › Sidebar size: the site's name, icon and buttons at the rows' size.
        sizeObserver = NotificationCenter.default.addObserver(forName: Tokens.Sidebar.sizeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.title.font = Tokens.Font.sidebarRow()
                for button in [self.playButton, self.muteButton, self.hideButton] { button.symbolSize = Tokens.Sidebar.rowGlyph }
                self.needsLayout = true
            }
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Now playing", comment: "Accessibility label of the sidebar's control for a tab playing sound in the background."))
        // VoiceOver goes to the playing tab as a click on the title does, or hides the card; the buttons speak for themselves.
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "Show Tab", comment: "VoiceOver action on the sidebar's Now Playing control: goes to the tab playing sound.")) { [weak self] in
                MainActor.assumeIsolated { self?.accessibilityPerformPress() ?? false }
            },
            NSAccessibilityCustomAction(name: String(localized: "Hide", comment: "Tooltip, VoiceOver action and menu item of the close button on the sidebar's Now Playing control: hides the control; the tab keeps playing.")) { [weak self] in
                MainActor.assumeIsolated {
                    guard let onHide = self?.onHide else { return false }
                    onHide()
                    return true
                }
            },
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: Tab) {
        self.tab = tab
        refresh()
    }

    func refresh() {
        guard let tab else { return }
        icon.image = tab.displayIcon
        title.stringValue = tab.displayTitle
        setAccessibilityLabel(String(localized: "Now playing: \(tab.displayTitle)", comment: "Accessibility label of the sidebar's Now Playing control. The placeholder is the playing tab's title."))
        playButton.symbol = isPaused ? "play.fill" : "pause.fill"
        playButton.toolTip = isPaused ? String(localized: "Play", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background.") : String(localized: "Pause", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background.")
        muteButton.symbol = tab.isMuted ? "speaker.slash" : "speaker.wave.2"
        muteButton.toolTip = tab.isMuted ? String(localized: "Unmute Tab", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background.") : String(localized: "Mute Tab", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background.")
        needsLayout = true
    }

    /// Play, mute and the close button at the card's end, always there, so nothing moves under the pointer.
    private func placeButtons() {
        let b = Tokens.Sidebar.rowButton
        let y = (bounds.height - b) / 2
        let end = bounds.width - SidebarRowView.buttonEdge
        let hide = NSRect(x: end - b, y: y, width: b, height: b)
        let mute = NSRect(x: hide.minX - Self.buttonGap - b, y: y, width: b, height: b)
        let play = NSRect(x: mute.minX - Self.buttonGap - b, y: y, width: b, height: b)
        let x = icon.frame.maxX + SidebarRowView.titleOffset
        let h = ceil(title.intrinsicContentSize.height)
        let titleFrame = NSRect(x: x, y: title.centeredY(in: bounds.height), width: max(0, play.minX - x - SidebarRowView.buttonEdge), height: h)
        muteButton.frame = mute
        playButton.frame = play
        title.frame = titleFrame
        title.fadeTail()
        hideButton.frame = hide
        // A title cut short reads whole in its tooltip.
        toolTip = title.intrinsicContentSize.width > titleFrame.width ? title.stringValue : nil
    }

    override func layout() {
        super.layout()
        // A tab row's layout: the icon and title where a tab's are, the buttons where a tab's speaker and close are,
        // as far in from the trailing edge as a row's.
        let size = Tokens.Sidebar.favicon
        icon.frame = NSRect(x: SidebarRowView.inset, y: (bounds.height - size) / 2, width: size, height: size)
        placeButtons()
    }

    /// Between the two buttons, as between a row's.
    private static let buttonGap: CGFloat = 2

    override func stateDidChange(animated: Bool) {
        // The rows' ink, on the space's color.
        title.textColor = Brand.Theme.for(self).rowInk
        // The address's and favorites' look: a soft field of the space's color.
        let fill = isPressed ? Tokens.Chrome.fieldPressed : isHovered ? Tokens.Chrome.fieldHover : Tokens.Chrome.field
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        Tokens.Motion.withoutAnimation {
            layer?.borderWidth = 0
        }
    }
}

/// Which tabs the sidebar's Now Playing cards are for, and the ones they've been hidden for.
///
/// A card for each tab you aren't looking at that makes sound, that Zigzag paused, or whose video is in the mini
/// player, paused there or not, so a few that start at once can each be paused or muted (#274). They keep the order
/// they started in, the first by the dots and each new one on top, so a card never moves when another comes; only the
/// `limit` most recent show. Hiding one is for what that tab is playing now, never a pause: its card stays away while
/// the tab plays on, pauses and plays again on the same page, and comes back once the tab goes to another page (the
/// next video, another track's page). A closed tab is forgotten.
struct NowPlayingChoice {
    /// A tab of the window, in most-recent order.
    struct Candidate: Equatable {
        let id: UUID
        /// The page it's on (`page(of:)`).
        let page: String
        /// Playing sound, paused from the card, or in the mini player, playing or paused there.
        let sounding: Bool
        let isSelected: Bool
    }

    /// Whether a tab has the card's attention: playing sound, paused from the card, or its video in the mini player,
    /// paused there or not (the card stays until the mini player lets it go).
    static func isSounding(playing: Bool, pausedFromCard: Bool, inMiniPlayer: Bool) -> Bool {
        playing || pausedFromCard || inMiniPlayer
    }

    /// Whether a tab is playing, for the card's button: a video in the mini player by its own state (a muted or silent
    /// video plays without a sound); anything else by its sound.
    static func isPlaying(sound: Bool, miniPlayerVideo: Bool?) -> Bool {
        miniPlayerVideo ?? sound
    }

    /// Whether the card shows it paused, with Play: paused from the card, or stopped in the mini player.
    static func isPaused(playing: Bool, pausedFromCard: Bool, inMiniPlayer: Bool) -> Bool {
        pausedFromCard || (inMiniPlayer && !playing)
    }

    /// The most cards at once, so the sidebar's list keeps its room.
    static let limit = 3

    /// Each hidden tab, with the page it was hidden on.
    private(set) var hidden: [UUID: String] = [:]
    /// The tabs with the cards' attention, in the order they started, the first first. A tab keeps its place while
    /// it's paused, selected or hidden, and goes once it's quiet.
    private(set) var order: [UUID] = []

    /// A page by its address without the part after #: a jump within the page isn't something new.
    static func page(of url: URL?) -> String {
        guard let url else { return "" }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    mutating func hide(_ id: UUID, page: String) {
        hidden[id] = page
    }

    /// The tabs to show from all of the window's, most recent first, as the cards go from top to bottom: the newest
    /// on top, the first to start by the dots; none for no card. Drops what was hidden on a page the tab has since
    /// left, and tabs that are gone.
    mutating func pick(from candidates: [Candidate]) -> [UUID] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        hidden = hidden.filter { id, page in byID[id]?.page == page }
        order.removeAll { byID[$0]?.sounding != true }
        // Several starting at once: the one you used last counts as the newest.
        var known = Set(order)
        for candidate in candidates.reversed() where candidate.sounding && known.insert(candidate.id).inserted {
            order.append(candidate.id)
        }
        let shown = order.filter { byID[$0]?.isSelected == false && hidden[$0] == nil }
        return Array(shown.suffix(Self.limit).reversed())
    }
}
