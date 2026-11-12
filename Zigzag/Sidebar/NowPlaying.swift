import AppKit

/// When a tab you're not looking at plays sound, a small control sits above the space dots:
/// the site, play/pause and mute. Click the title to go there.
final class NowPlayingView: InteractiveView {
    private let icon = FaviconView()
    private let title = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
    let playButton = TabRowView.rowButton("pause", toolTip: String(localized: "Pause", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background."))
    let muteButton = TabRowView.rowButton("speaker.wave.2", toolTip: String(localized: "Mute Tab", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background."))
    private(set) weak var tab: Tab?
    private var sizeObserver: NSObjectProtocol?
    var isPaused = false { didSet { refresh() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Sidebar.rowRadius
        layer?.cornerCurve = .continuous
        [icon, title, playButton, muteButton].forEach { addSubview($0) }
        // Settings › Appearance › Sidebar size: the site's name at the rows' size.
        sizeObserver = NotificationCenter.default.addObserver(forName: Tokens.Sidebar.sizeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.title.font = Tokens.Font.sidebarRow()
                self?.needsLayout = true
            }
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Now playing", comment: "Accessibility label of the sidebar's control for a tab playing sound in the background."))
        // VoiceOver goes to the playing tab as a click on the title does; the buttons speak for themselves.
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: String(localized: "Show Tab", comment: "VoiceOver action on the sidebar's Now Playing control: goes to the tab playing sound.")) { [weak self] in
            MainActor.assumeIsolated { self?.accessibilityPerformPress() ?? false }
        }])
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
        playButton.symbol = isPaused ? "play" : "pause"
        playButton.toolTip = isPaused ? String(localized: "Play", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background.") : String(localized: "Pause", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background.")
        muteButton.symbol = tab.isMuted ? "speaker.slash" : "speaker.wave.2"
        muteButton.toolTip = tab.isMuted ? String(localized: "Unmute Tab", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background.") : String(localized: "Mute Tab", comment: "Tooltip of a button in the sidebar's Now Playing control, for a tab playing sound in the background.")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // A sidebar row's proportions: the icon and title where a tab's are, the buttons as a tab's close.
        let size = Tokens.Sidebar.favicon
        icon.frame = NSRect(x: SidebarRowView.inset, y: (bounds.height - size) / 2, width: size, height: size)
        let b = Tokens.Sidebar.rowButton
        let edge = (bounds.height - b) / 2
        muteButton.frame = NSRect(x: bounds.width - edge - b, y: edge, width: b, height: b)
        playButton.frame = NSRect(x: muteButton.frame.minX - 2 - b, y: edge, width: b, height: b)
        let x = icon.frame.maxX + SidebarRowView.titleOffset
        let h = title.lineHeight
        title.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: playButton.frame.minX - x - Tokens.Space.x1, height: h)
    }

    override func stateDidChange(animated: Bool) {
        // The address's and favorites' look: a soft field of the space's color.
        let fill = isPressed ? Tokens.Chrome.fieldPressed : isHovered ? Tokens.Chrome.fieldHover : Tokens.Chrome.field
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        Tokens.Motion.withoutAnimation {
            layer?.borderWidth = 0
        }
    }
}
