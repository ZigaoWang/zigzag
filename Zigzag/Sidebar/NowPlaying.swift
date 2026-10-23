import AppKit

/// When a tab you're not looking at plays sound, a small control sits above the space dots:
/// the site, play/pause and mute. Click the title to go there.
final class NowPlayingView: InteractiveView {
    private let icon = FaviconView()
    private let title = Label("", font: Tokens.Font.body(), color: Tokens.Color.textPrimary)
    let playButton = IconButton(symbol: "pause.fill", size: Tokens.Space.x6, toolTip: "Pause")
    let muteButton = IconButton(symbol: "speaker.wave.2.fill", size: Tokens.Space.x6, toolTip: "Mute")
    private(set) weak var tab: Tab?
    var isPaused = false { didSet { refresh() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Tokens.Radius.row
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
        let pad = Tokens.Space.x2
        let size = Tokens.Metric.favicon
        icon.frame = NSRect(x: pad, y: (bounds.height - size) / 2, width: size, height: size)
        let b = Tokens.Space.x6
        muteButton.frame = NSRect(x: bounds.width - Tokens.Space.x1 - b, y: (bounds.height - b) / 2, width: b, height: b)
        playButton.frame = NSRect(x: muteButton.frame.minX - b, y: muteButton.frame.minY, width: b, height: b)
        let x = icon.frame.maxX + Tokens.Space.x2
        let h = title.lineHeight
        title.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: playButton.frame.minX - x - Tokens.Space.x1, height: h)
    }

    override func stateDidChange(animated: Bool) {
        let fill = isPressed ? Tokens.Color.pressedFill : isHovered ? Tokens.Color.highlight : Tokens.Color.fieldFill
        layer?.set(backgroundColor: cgColor(fill), animated: animated && !isHovered)
    }
}
