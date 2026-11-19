import AppKit

/// Shared sizing for cards over the page. Permission questions and notices sit in the same place, so they share one
/// width rule.
enum CardOverThePage {
    static let width: CGFloat = 420
    static let maxWidth: CGFloat = 720
    static let pad: CGFloat = 16
    static let iconSide = Tokens.Dialog.iconSide

    /// Fits its content, capped by the pane.
    static func width(measured: CGFloat, in area: NSRect) -> CGFloat {
        min(max(width, measured), min(maxWidth, area.width - Tokens.Space.x6))
    }
}

nonisolated enum NoticeTone: Equatable {
    case plain
    case good
    case bad
}

/// A script rule notice's text per state, separate from the card so it can be tested without a window.
nonisolated struct ScriptNotice: Equatable {
    enum State: Equatable {
        case running
        /// Exited 0.
        case ran
        /// Exited with an error; holds its last output (usually stderr).
        case failed(String)
    }

    /// The script's file name, not the rule's name.
    var script: String
    var state: State

    var title: String {
        switch state {
        case .running: String(localized: "Running script: \(script)", comment: "A notice over the page while a download rule's script runs. The placeholder is the script's file name.")
        case .ran: String(localized: "Ran script: \(script)", comment: "A notice over the page saying a download rule's script has finished and exited 0. The placeholder is the script's file name.")
        case .failed: String(localized: "Script failed: \(script)", comment: "A notice over the page saying a download rule's script has failed. The placeholder is the script's file name, and the script's own last words are under it.")
        }
    }

    /// The script's own output under the title, only on failure and only if it printed something.
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

    /// Finished: the card stays briefly, then goes.
    var isOver: Bool { state != .running }
}

/// A non-question notice over the page about a rule's progress or result. Sits where permission questions do, follows
/// its tab and the sidebar, and has an icon, title, detail line and ×. Dismisses itself.
@MainActor
final class NoticeCard: FloatingPanelView {
    private let picture = NSImageView()
    private let spinner = Spinner()
    private let heading = Label("", font: Tokens.Font.body(.medium), color: Tokens.Color.textPrimary)
    private let line = Label("", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let closeButton = IconButton(symbol: "xmark", toolTip: String(localized: "Close", comment: "Tooltip of the × on a notice over the page, like a script's while it runs."))

    private var notice: ScriptNotice
    /// Shown while this tab is in front; goes with it.
    private weak var tab: Tab?
    private weak var controller: PromptHost?
    private var tabsToken: SignalToken?
    private var questionsToken: SignalToken?
    private var appearWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var isUp = false
    /// Dismissed with ×; the outcome is reported elsewhere.
    private var wasPutAway = false

    /// Delay before showing a running card, so quick scripts show only the result.
    private static let grace: TimeInterval = 0.25
    /// Failures stay longer.
    private static func stay(_ tone: NoticeTone) -> TimeInterval { tone == .bad ? 8 : 4 }
    /// One per window, so it follows the sidebar and a new one replaces the old.
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

    /// Shows a notice in its tab's window and returns the card for later updates. Callers without a card report the
    /// outcome themselves.
    static func show(_ notice: ScriptNotice, tab: Tab?, in host: PromptHost) -> NoticeCard {
        // Replace, don't stack.
        if let existing = shown[ObjectIdentifier(host)] { existing.takeDown() }
        let card = NoticeCard(notice)
        card.tab = tab
        card.controller = host
        card.tabsToken = host.observePromptTabs { [weak card] in card?.followTab() }
        // Steps aside while a question is up, then comes back.
        card.questionsToken = PermissionPrompt.waitingChanged.observe { [weak card] in card?.followTab() }
        host.promptOverlay.addSubview(card)
        card.isHidden = true
        shown[ObjectIdentifier(host)] = card
        card.followTab()
        card.appearAfterGrace()
        return card
    }

    /// Updates the notice. False when the card no longer owns it (dismissed, replaced, or its window closed), so the
    /// caller must report another way.
    @discardableResult
    func say(_ notice: ScriptNotice) -> Bool {
        guard !wasPutAway, let controller, Self.shown[ObjectIdentifier(controller)] === self else { return false }
        self.notice = notice
        render()
        appearWork?.cancel()
        // Only over its own tab: a background tab's result waits there, and its timeout starts once seen.
        if notice.isOver {
            // Resizes in place; a failure adds a detail line.
            if isUp { rePlace { place(in: controller) } }
            followTab()
            if isUp, hideWork == nil { hideAfterWhile() }
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
        if notice.isOver, hideWork == nil { hideAfterWhile() }
    }

    private func hideAfterWhile() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.takeDown() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stay(notice.tone), execute: work)
    }

    /// Dismissed with ×: the outcome isn't reported again here.
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

    /// Shown while its tab is in front (either split side), hidden otherwise, removed when the tab closes or moves
    /// window.
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

    /// Text color while running, green on success, the app's warning color on failure (red is for destructive
    /// things).
    private func ink(for tone: NoticeTone) -> NSColor {
        switch tone {
        case .plain: Tokens.Color.textPrimary
        case .good: Tokens.Color.success
        case .bad: Tokens.Color.warning
        }
    }

    private var textX: CGFloat { CardOverThePage.pad + CardOverThePage.iconSide + Tokens.Space.x3 }

    /// Space for the ×.
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

    /// Centered at the top of the page's pane, where permission questions appear.
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

    /// After the sidebar or window changed.
    static func reposition(in controller: PromptHost, slide: TimeInterval? = nil, timing: CAMediaTimingFunction = Tokens.Motion.drawer) {
        guard let card = shown[ObjectIdentifier(controller)], card.superview != nil, !card.isHidden else { return }
        card.rePlace(slide: slide, timing: timing) { card.place(in: controller) }
    }
}

extension FloatingPanelView {
    /// Animates to the new position: in step with a sidebar slide, or a glide otherwise.
    func rePlace(slide: TimeInterval? = nil, timing: CAMediaTimingFunction = Tokens.Motion.drawer, _ place: () -> Void) {
        let old = frame
        place()
        let dx = old.minX - frame.minX, dy = old.minY - frame.minY
        // No glide during live resize; it would lag behind.
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
