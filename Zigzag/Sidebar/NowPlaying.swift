import AppKit

/// Card above the space dots for each background tab playing sound: site, play/pause and mute; click the title to go
/// there. Laid out like a tab row, with an always-visible close button that hides the card for the current media
/// (sound keeps playing).
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
    /// Fading out (tab quiet or hidden); keeps its slot until gone (`SidebarView.setNowPlaying`).
    var isLeaving = false
    /// Hide counter, so a reversed fade doesn't remove it when it ends.
    var leaves = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsMenu = true
        layer?.cornerRadius = Tokens.Sidebar.rowRadius
        layer?.cornerCurve = .continuous
        // Long titles fade at the end, like tab rows.
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

/// Which tabs get Now Playing cards, and which are hidden.
///
/// A card for each background tab that plays sound, was paused from its card, or has video in the mini player, so
/// several can be paused or muted (#274). Cards keep start order (first by the dots, newest on top) so none move;
/// only the `limit` newest show. Hiding applies to the current page: the card stays hidden through pause and play and
/// returns when the tab navigates. Closed tabs are dropped.
struct NowPlayingChoice {
    /// A tab of the window, in most-recent order.
    struct Candidate: Equatable {
        let id: UUID
        /// The page it's on (`page(of:)`).
        let page: String
        /// Playing sound, paused from the card, or in the mini player.
        let sounding: Bool
        let isSelected: Bool
    }

    /// Whether a tab gets a card: playing sound, paused from the card, or in the mini player (until it releases it).
    static func isSounding(playing: Bool, pausedFromCard: Bool, inMiniPlayer: Bool) -> Bool {
        playing || pausedFromCard || inMiniPlayer
    }

    /// Playing state for the button: mini player videos by their own state (muted video still plays), others by sound.
    static func isPlaying(sound: Bool, miniPlayerVideo: Bool?) -> Bool {
        miniPlayerVideo ?? sound
    }

    /// Shows paused with Play: paused from the card, or stopped in the mini player.
    static func isPaused(playing: Bool, pausedFromCard: Bool, inMiniPlayer: Bool) -> Bool {
        pausedFromCard || (inMiniPlayer && !playing)
    }

    /// Max cards, so the tab list keeps its room.
    static let limit = 3

    /// Each hidden tab, with the page it was hidden on.
    private(set) var hidden: [UUID: String] = [:]
    /// Tabs with cards in start order. A tab keeps its slot while paused, selected or hidden; removed once quiet.
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

    /// Tabs to show, newest first (top to bottom); empty for none. Clears hides for pages the tab has left, and gone tabs.
    mutating func pick(from candidates: [Candidate]) -> [UUID] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        hidden = hidden.filter { id, page in byID[id]?.page == page }
        order.removeAll { byID[$0]?.sounding != true }
        // Several starting together: the last used counts as newest.
        var known = Set(order)
        for candidate in candidates.reversed() where candidate.sounding && known.insert(candidate.id).inserted {
            order.append(candidate.id)
        }
        let shown = order.filter { byID[$0]?.isSelected == false && hidden[$0] == nil }
        return Array(shown.suffix(Self.limit).reversed())
    }
}
