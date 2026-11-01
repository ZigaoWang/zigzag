import AppKit

/// When a tab you're not looking at plays sound, a small control sits above the space dots:
/// the site, play/pause and mute. Click the title to go there.
final class NowPlayingView: InteractiveView {
    private let icon = FaviconView()
    private let title = Label("", font: Tokens.Font.sidebarRow(), color: Tokens.Color.textPrimary)
    let playButton = TabRowView.rowButton("pause.fill", toolTip: "Pause")
    let muteButton = TabRowView.rowButton("speaker.wave.2.fill", toolTip: "Mute")
    private(set) weak var tab: Tab?
    var isPaused = false { didSet { refresh() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Sidebar.rowRadius
        layer?.cornerCurve = .continuous
        [icon, title, playButton, muteButton].forEach { addSubview($0) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Now playing")
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: Tab) {
        self.tab = tab
        refresh()
    }

    func refresh() {
        guard let tab else { return }
        icon.image = tab.favicon
        title.stringValue = tab.displayTitle
        playButton.symbol = isPaused ? "play.fill" : "pause.fill"
        playButton.toolTip = isPaused ? "Play" : "Pause"
        muteButton.symbol = tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        muteButton.toolTip = tab.isMuted ? "Unmute" : "Mute"
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
        let fill = isPressed ? Tokens.Chrome.pressed : isHovered ? Tokens.Chrome.fieldHover : Tokens.Chrome.field
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
        Tokens.Motion.withoutAnimation {
            layer?.borderWidth = 0
        }
    }
}
