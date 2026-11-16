import AppKit

/// The measure a card over the page keeps. A site's permission question and a notice are the same kind of thing in the
/// same place — read the same way, over the pane the page is in — so they are the same size, and there is one rule for
/// how wide they may get.
enum CardOverThePage {
    static let width: CGFloat = 420
    /// The widest either is allowed to get.
    static let maxWidth: CGFloat = 720
    static let pad: CGFloat = 16
    static let iconSide = Tokens.Dialog.iconSide

    /// How wide a card is: wide enough for what it holds, and never past the pane it is on.
    static func width(measured: CGFloat, in area: NSRect) -> CGFloat {
        min(max(width, measured), min(maxWidth, area.width - Tokens.Space.x6))
    }
}

/// How a notice reads: an ordinary one, one that worked, one that didn't.
nonisolated enum NoticeTone: Equatable {
    case plain
    case good
    case bad
}

/// What a script rule's notice says, in each state it can be in. Kept apart from the card that draws it, so the words
/// can be checked without a window.
nonisolated struct ScriptNotice: Equatable {
    enum State: Equatable {
        case running
        /// It exited 0.
        case ran
        /// It exited with an error, and printed this (its own last words, usually on stderr).
        case failed(String)
    }

    /// The script's own file name: what the rule named, not the rule's name.
    var script: String
    var state: State

    var title: String {
        switch state {
        case .running: String(localized: "Running script: \(script)", comment: "A notice over the page while a download rule's script runs. The placeholder is the script's file name.")
        case .ran: String(localized: "Ran script: \(script)", comment: "A notice over the page saying a download rule's script has finished and exited 0. The placeholder is the script's file name.")
        case .failed: String(localized: "Script failed: \(script)", comment: "A notice over the page saying a download rule's script has failed. The placeholder is the script's file name, and the script's own last words are under it.")
        }
    }

    /// The script's own words, on the line under the title — where it failed, and only where it said something.
    var detail: String? {
        guard case .failed(let said) = state else { return nil }
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var symbol: String {
        switch state {
        case .running: "terminal"
        case .ran: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tone: NoticeTone {
        switch state {
        case .running: .plain
        case .ran: .good
        case .failed: .bad
        }
    }

    /// Whether it is over: the states a card stays up for, and then goes on its own.
    var isOver: Bool { state != .running }
}

/// A notice over the page that isn't a question: something a rule is doing, or has done. It sits where a site's
/// permission question does — over the pane the page is in, following its tab and the sidebar — with an icon, a title,
/// a line under it for its own words, and an × to put it away. Nothing is answered and nothing waits: it goes on its
/// own once it has been read.
@MainActor
final class NoticeCard: FloatingPanelView {
    private let picture = NSImageView()
    private let spinner = Spinner()
    private let heading = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    private let line = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let closeButton = IconButton(symbol: "xmark", toolTip: String(localized: "Put This Away", comment: "Tooltip of the × on a notice over the page, like a script's while it runs."))

    private var notice: ScriptNotice
    /// The tab whose page it belongs to: it shows while that tab is in front, and goes with it.
    private weak var tab: Tab?
    private weak var controller: PromptHost?
    private var tabsToken: SignalToken?
    private var questionsToken: SignalToken?
    private var appearWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var isUp = false
    /// The pointer put it away: nothing more is said for this notice, and its outcome is said somewhere else.
    private var wasPutAway = false

    /// How long something has to take before a card appears for it while it runs. A script over in a moment never
    /// flashes "running": its ending is the first thing seen.
    private static let grace: TimeInterval = 0.25
    /// How long it stays once it is over, by how it went: a failure is worth reading.
    private static func stay(_ tone: NoticeTone) -> TimeInterval { tone == .bad ? 8 : 4 }
    /// The notice on screen in each window, so it can follow the sidebar as a question does, and so a second one
    /// takes the place of the first rather than stacking over it.
    private static var shown: [ObjectIdentifier: NoticeCard] = [:]

    private init(_ notice: ScriptNotice) {
        self.notice = notice
        super.init(frame: .zero)
        picture.imageScaling = .scaleNone
        [picture, spinner, heading, line, closeButton].forEach { addSubview($0) }
        heading.lineBreakMode = .byTruncatingTail
        line.lineBreakMode = .byTruncatingTail
        line.maximumNumberOfLines = 2
        closeButton.onClick = { [weak self] _ in self?.putAway() }
        onLayout = { [weak self] in self?.layoutContent() }
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Showing

    /// Shows a notice in the window its tab is in, and gives the card back so whatever it is about can say how it
    /// ended. Nothing is kept if the window can't be found: a caller with no card says its own ending itself.
    static func show(_ notice: ScriptNotice, tab: Tab?, in host: PromptHost) -> NoticeCard {
        // The one already up in this window steps aside: a notice is the last thing that happened, not a list.
        if let existing = shown[ObjectIdentifier(host)] { existing.takeDown() }
        let card = NoticeCard(notice)
        card.tab = tab
        card.controller = host
        card.tabsToken = host.observePromptTabs { [weak card] in card?.followTab() }
        // A question takes the same place, so the notice steps aside while one is up and comes back after it.
        card.questionsToken = PermissionPrompt.waitingChanged.observe { [weak card] in card?.followTab() }
        host.promptOverlay.addSubview(card)
        card.isHidden = true
        shown[ObjectIdentifier(host)] = card
        card.followTab()
        card.appearAfterGrace()
        return card
    }

    /// Says how it is going, or how it went. False means this card is no longer the one that says it — it was put
    /// away, another notice took its place, or its window has gone — so the caller has to say it some other way.
    @discardableResult
    func say(_ notice: ScriptNotice) -> Bool {
        guard !wasPutAway, let controller, Self.shown[ObjectIdentifier(controller)] === self else { return false }
        self.notice = notice
        render()
        appearWork?.cancel()
        if notice.isOver {
            showNow()
            hideAfterWhile()
        }
        return true
    }

    // MARK: Its own life

    private func appearAfterGrace() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showNow() }
        }
        appearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: work)
    }

    private func showNow() {
        guard !wasPutAway, superview != nil, let controller, !isUp else { return }
        guard !PermissionPrompt.isShowing(in: controller) else { return }
        rePlace { place(in: controller) }
        isHidden = false
        isUp = true
        slidesFromTop = true
        present()
    }

    private func hideAfterWhile() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.takeDown() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stay(notice.tone), execute: work)
    }

    /// Put away by the pointer: it goes, and the outcome is not said here again.
    private func putAway() {
        wasPutAway = true
        takeDown()
    }

    private func takeDown() {
        appearWork?.cancel()
        hideWork?.cancel()
        stopFollowing()
        guard superview != nil else { return }
        if isUp { dismiss() }
        removeFromSuperview()
    }

    private func stopFollowing() {
        tabsToken = nil
        questionsToken = nil
        if let controller, Self.shown[ObjectIdentifier(controller)] === self { Self.shown[ObjectIdentifier(controller)] = nil }
    }

    /// Shown while its tab is in front (either side of a split counts), set aside while another tab is, and gone once
    /// that tab is closed or has moved to another window.
    private func followTab() {
        guard let controller else { return }
        guard let tab, !tab.isClosed, controller.promptHolds(tab) else { takeDown(); return }
        if controller.promptShows(tab), !PermissionPrompt.isShowing(in: controller) {
            showNow()
        } else if isUp {
            isUp = false
            isHidden = true
        }
    }

    // MARK: The card

    private func render() {
        heading.stringValue = notice.title
        line.stringValue = notice.detail ?? ""
        line.isHidden = notice.detail == nil
        if notice.state == .running {
            spinner.frame = NSRect(x: 0, y: 0, width: CardOverThePage.iconSide, height: CardOverThePage.iconSide)
            spinner.startAnimation(nil)
            picture.isHidden = true
        } else {
            spinner.stopAnimation(nil)
            picture.isHidden = false
            picture.image = Tokens.Symbol.image(notice.symbol, size: Tokens.TypeSize.heading)
            picture.contentTintColor = ink(for: notice.tone)
        }
        setAccessibilityLabel(notice.title)
        if let detail = notice.detail { setAccessibilityValue(detail) }
        needsLayout = true
    }

    /// The colour of the icon: the ink of the text while it runs, green when it worked, and the app's own
    /// something-to-fix colour when it didn't (its red is kept for what can't be undone).
    private func ink(for tone: NoticeTone) -> NSColor {
        switch tone {
        case .plain: Tokens.Color.textPrimary
        case .good: Tokens.Color.success
        case .bad: Tokens.Color.warning
        }
    }

    private var textX: CGFloat { CardOverThePage.pad + CardOverThePage.iconSide + Tokens.Space.x3 }

    /// Room kept at the right of the text for the ×.
    private var closeRoom: CGFloat { Tokens.Metric.iconButton }

    private var measuredWidth: CGFloat {
        let text = max(heading.inkWidth, line.isHidden ? 0 : line.inkWidth)
        return text + textX + CardOverThePage.pad + closeRoom
    }

    private func headingHeight(for width: CGFloat) -> CGFloat {
        ceil(heading.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 200)).height ?? heading.lineHeight)
    }

    private func textHeight(for width: CGFloat) -> CGFloat {
        headingHeight(for: width) + (line.isHidden ? 0 : 2 + line.lineHeight)
    }

    private func height(for width: CGFloat) -> CGFloat {
        let textWidth = width - textX - CardOverThePage.pad - closeRoom
        return CardOverThePage.pad + max(CardOverThePage.iconSide, textHeight(for: textWidth)) + CardOverThePage.pad
    }

    /// At the top of the pane the page is in, centred: the same place a site's question comes up, so the two are read
    /// from the same spot.
    private func place(in controller: PromptHost) {
        surfaceTint = nil
        tintStrength = nil
        isElevated = true
        radius = Tokens.Radius.panel
        let area = controller.focusedPaneFrame
        let width = CardOverThePage.width(measured: measuredWidth, in: area)
        frame = NSRect(x: round(area.midX - width / 2), y: area.minY + Tokens.Space.x3,
                       width: width, height: height(for: width))
    }

    private func layoutContent() {
        let pad = CardOverThePage.pad, w = bounds.width
        let iconSide = CardOverThePage.iconSide
        let textWidth = w - textX - pad - closeRoom
        let th = textHeight(for: w)
        let header = max(iconSide, th)
        picture.frame = NSRect(x: pad, y: pad + (header - iconSide) / 2, width: iconSide, height: iconSide)
        spinner.frame = picture.frame
        let top = pad + (header - th) / 2
        heading.frame = NSRect(x: textX - Label.inset, y: top, width: textWidth + Label.inset * 2, height: headingHeight(for: w))
        line.frame = NSRect(x: textX - Label.inset, y: heading.frame.maxY + 2, width: textWidth + Label.inset * 2, height: line.lineHeight)
        let close = closeButton.frame.size
        closeButton.frame.origin = NSPoint(x: w - Tokens.Space.x2 - close.width, y: Tokens.Space.x2)
    }

    // MARK: Following the window

    /// Puts the notice back where it belongs after the sidebar or the window changed.
    static func reposition(in controller: PromptHost, slide: TimeInterval? = nil, timing: CAMediaTimingFunction = Tokens.Motion.drawer) {
        guard let card = shown[ObjectIdentifier(controller)], card.superview != nil, !card.isHidden else { return }
        card.rePlace(slide: slide, timing: timing) { card.place(in: controller) }
    }
}

extension FloatingPanelView {
    /// Moves a card over the page from where it was to where it belongs now, after the sidebar or the window changed.
    /// It never jumps: riding a sidebar slide it moves with the sidebar on the same curve, and between two places it
    /// glides there.
    func rePlace(slide: TimeInterval? = nil, timing: CAMediaTimingFunction = Tokens.Motion.drawer, _ place: () -> Void) {
        let old = frame
        place()
        let dx = old.minX - frame.minX, dy = old.minY - frame.minY
        // Dragging the window's edge, it simply stays with the page; gliding there would trail behind.
        guard abs(dx) > 0.5 || abs(dy) > 0.5, !Tokens.Motion.reduceMotion, window?.inLiveResize != true, let layer else { return }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(dx, dy, 0))
        move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        move.duration = slide ?? Tokens.Motion.standard
        move.timingFunction = slide == nil ? Tokens.Motion.drawer : timing
        move.fillMode = .backwards
        layer.add(move, forKey: "follow")
    }
}
