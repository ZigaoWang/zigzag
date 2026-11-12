import AppKit
import WebKit

/// The web page as a card: rounded, lifted by a hairline and a whisper of shadow, inset from the window or, borderless,
/// meeting its edges.
final class PageCardView: NSView {
    /// The card's face: its rounded shape, its edge and its ground, the page's own color (`ground`). It follows
    /// the card's frame, gliding with it when that's animated (the sidebar coming or going), while the page on it
    /// takes its new size at once, as a website should be laid out only once. So the card narrows and widens in one
    /// piece: the room the page has yet to reach, or has just given up, is the card's own ground, never a hole onto
    /// the window's frame.
    private let surface = FlippedView()
    /// The page's place on the surface: at its final size from the moment the card starts to move.
    private let clip = NSView()
    private let edge = CALayer()
    private(set) weak var webView: WKWebView?
    /// The shown page's holder (`Tab.pageHolder`), borrowed while the card shows it.
    private weak var holder: PageHolder?
    /// In split view, the pane you're working in: its toolbar is at full strength, the other's dims. An outline
    /// would run along the window's own edges where a pane meets them.
    var isFocusedPane = false { didSet { refreshColors() } }
    /// In split view, a pane you're not working in.
    var isUnfocusedPane = false { didSet { refreshColors() } }
    /// In split view each pane gets its own small toolbar.
    let header = PaneHeaderView()
    var showsHeader = false { didSet { if !liftsHeader { header.isHidden = !showsHeader }; needsLayout = true } }
    /// Lent to the bar above the page (`BrowserRootView`): the header sits in the bar's row instead, and the page starts
    /// at the card's top. Given back, it's on the card again.
    var liftsHeader = false {
        didSet {
            guard liftsHeader != oldValue else { return }
            if !liftsHeader {
                header.isInBar = false
                header.addressCenter = nil
                header.alphaValue = headerAlpha
                clip.addSubview(header)
                header.isHidden = !showsHeader
            }
            needsLayout = true
        }
    }
    /// The header's strength: dimmed on the pane you're not in.
    var headerAlpha: CGFloat { isUnfocusedPane ? Tokens.Color.unfocusedPaneAlpha : 1 }
    /// Whether the header takes the top of the card.
    private var headerOnCard: Bool { showsHeader && !liftsHeader }
    /// Under the bar above the page, the card's top this tall is the bar's: the page starts under it, and the card's
    /// ground shows there in the page's own color (`ground`), so the bar and the page read as one card: its
    /// corners, edge and shadow are the card's, and it moves with it.
    var band: CGFloat = 0 { didSet { if band != oldValue { needsLayout = true } } }
    /// The page's own color (`Tab.pageColor`), for the card's ground and what lies on it. None for a page at a
    /// size of its own: it stands on plain ground, so its edges show.
    var pageColor: NSColor? { pageSize == nil ? (webView as? BrowserWebView)?.owner?.pageColor : nil }
    /// The card's color wherever the page isn't: the page's own, so a split's two cards each have theirs; the plain
    /// card's with no page, under what covers it, or around a page at a size of its own.
    /// Around a page at a size of its own, the backdrop a PDF's pages lie on: the page reads as a sheet on it, as a
    /// device's screen does in a responsive view, whatever color the page is.
    private var ground: NSColor { pageColor ?? (pageSize != nil ? Tokens.Color.pdfBackdrop : Tokens.Color.cardBackground) }
    /// A hairline around a page at a size of its own, so its edges show on any backdrop, light page or dark.
    private let pageOutline = ColorView(color: Tokens.Color.cardEdge)
    /// The page's part of the card, in the superview's terms: under the band.
    var pageFrame: NSRect { NSRect(x: frame.minX, y: frame.minY + band, width: frame.width, height: max(0, frame.height - band)) }
    /// The page at a size of its own rather than filling the card: in the middle of its room, the card's plain
    /// ground around it. What's docked beside the page (the Web Inspector) is beside it, not in it:
    /// the page keeps its size. What covers the page (a PDF, Settings, Reader) fills the room as ever.
    var pageSize: CGSize? {
        didSet {
            guard pageSize != oldValue else { return }
            needsLayout = true
            refreshGround()
        }
    }

    /// Where the page's holder goes in the page's room. No size: all of it. A size: that, plus the room what's
    /// docked beside the page takes, in the middle of the room both ways. A page larger than its room is shown
    /// smaller, whole (`pageFit`); without the view scale to do that, it's cut to the room.
    static func pageRect(content: NSRect, size: CGSize?, docked: NSSize, scales: Bool = false) -> NSRect {
        pageFit(content: content, size: size, docked: docked, scales: scales).frame
    }

    /// The holder's place for a page of `size` in `content`, and the scale the page is shown at: 1 where it fits.
    /// Larger than the room, it's laid out at its own size and shown smaller to fit, as a responsive view in Chrome
    /// or Polypane does, so a desktop width can be checked in a laptop's window. What's docked beside it (the Web
    /// Inspector) keeps its own size beside the page.
    static func pageFit(content: NSRect, size: CGSize?, docked: NSSize, scales: Bool) -> (frame: NSRect, scale: CGFloat) {
        guard let size, size.width > 0, size.height > 0 else { return (content, 1) }
        let room = NSSize(width: max(0, content.width - docked.width), height: max(0, content.height - docked.height))
        let scale = scales ? max(minimumScale, min(1, room.width / size.width, room.height / size.height)) : 1
        let page = NSSize(width: scale < 1 ? round(size.width * scale) : size.width, height: scale < 1 ? round(size.height * scale) : size.height)
        let width = min(content.width, page.width + docked.width), height = min(content.height, page.height + docked.height)
        let frame = NSRect(x: content.minX + floor((content.width - width) / 2), y: content.minY + floor((content.height - height) / 2), width: width, height: height)
        // The scale the page's whole points come to, a hair under, so it's laid out at exactly its width: WebKit
        // divides in single precision and drops the fraction, and 1040 / (1040 / 1920) came out 1919.
        return (frame, scale < 1 ? page.width / (size.width + 0.25) : 1)
    }

    /// The smallest a page is shown at: a full HD width still reads in a small window.
    static let minimumScale: CGFloat = 0.25

    /// WebKit's view scale (`_setViewScale:`, macOS only, private): the page is laid out at its view's size divided by
    /// it and drawn that much smaller. Asked before use, so a WebKit without it leaves the page cut to its room.
    static let setViewScale = NSSelectorFromString("_setViewScale:")
    static func canScale(_ webView: WKWebView?) -> Bool { webView?.responds(to: setViewScale) == true }

    /// The scale the shown page is drawn at (`pageFit`), 1 at its own size.
    private(set) var pageScale: CGFloat = 1 { didSet { if pageScale != oldValue { onPageArea?(pageArea) } } }

    /// Gives a page the view scale, or takes it back to 1, only when it changes.
    private static func apply(scale: CGFloat, to webView: WKWebView?) {
        guard let webView, canScale(webView) else { return }
        let now = webView.value(forKey: "viewScale") as? CGFloat ?? 1
        if abs(now - scale) > 0.0001 { webView.setValue(scale, forKey: "viewScale") }
    }

    /// Places the shown page's holder for its size, the view scale with it, and says the page's area.
    private func place(_ holder: PageHolder, in content: NSRect) {
        // A page with a size of its own keeps it as the card changes; any other fills the card with it.
        holder.autoresizingMask = pageSize == nil ? [.width, .height] : []
        let fit = Self.pageFit(content: content, size: pageSize, docked: holder.dockedRoom, scales: Self.canScale(webView))
        holder.frame = fit.frame
        Self.apply(scale: fit.scale, to: webView)
        pageScale = fit.scale
        // The page's own area, as its styles see it: its size when shown smaller, else what the holder leaves it.
        let shown = NSSize(width: holder.frame.width - holder.dockedRoom.width, height: holder.frame.height - holder.dockedRoom.height)
        pageArea = fit.scale < 1 ? (pageSize ?? shown) : shown
    }

    /// The hairline goes round the page's holder while the page has a size of its own, under it, and is hidden
    /// otherwise.
    private func placeOutline() {
        guard pageSize != nil, let holder, holder.superview === clip else {
            if !pageOutline.isHidden { pageOutline.isHidden = true }
            return
        }
        let line = Tokens.Metric.hairline
        if pageOutline.superview !== clip || clip.subviews.firstIndex(of: pageOutline).map({ $0 + 1 }) != clip.subviews.firstIndex(of: holder) {
            clip.addSubview(pageOutline, positioned: .below, relativeTo: holder)
        }
        pageOutline.frame = holder.frame.insetBy(dx: -line, dy: -line)
        pageOutline.isHidden = false
    }

    /// How far down the card the page starts: under the bar's band and a split pane's header.
    private var contentTop: CGFloat { band + (headerOnCard ? PaneHeaderView.height : 0) }
    /// The page's own area as the card last laid it out, without what's docked beside it; whoever says the page's
    /// size hears when it changes.
    private(set) var pageArea = NSSize.zero { didSet { if pageArea != oldValue { onPageArea?(pageArea) } } }
    var onPageArea: ((NSSize) -> Void)?
    /// Reader, over the page, which stays loaded underneath.
    private(set) var overlay: NSView?
    /// What covers the shown tab's page: its PDF viewer, over WebKit's own, or Settings.
    private weak var document: NSView?
    private var documentToken: SignalToken?
    /// A page that left the card while its video was in full screen: WebKit puts it back here when that ends.
    private var fullScreenWatch: NSKeyValueObservation?

    /// No corners, edge or shadow: the page fills the window.
    var isEdgeToEdge: Bool {
        get { edgeToEdge }
        set { setEdgeToEdge(newValue, duration: 0) }
    }
    private var edgeToEdge = false

    /// The right corners that are the window's own corners, which the window rounds itself: square here.
    var squaresRightCorners = (top: false, bottom: false) { didSet { if squaresRightCorners != oldValue { needsLayout = true } } }
    /// The same on the left: Zigzag Mini's borderless page meets both of the window's bottom corners.
    var squaresLeftCorners = (top: false, bottom: false) { didSet { if squaresLeftCorners != oldValue { needsLayout = true } } }
    /// Meeting the window's edges beside the sidebar (or under Zigzag Mini's strip): its corners curve like the window's, so a split's two panes
    /// match across the gap and the corner by the sidebar matches the window's.
    var isAttached = false { didSet { if isAttached != oldValue { needsLayout = true; refreshColors() } } }

    /// The corner it rounds to: none edge to edge, the generous sheet's beside the sidebar, a card's floating.
    private var cornerRadius: CGFloat { edgeToEdge ? 0 : isAttached ? Self.attachedRadius : Tokens.Radius.card }
    #if DEBUG
    /// Debug builds: another attached radius, to compare (`pagecorner <points>`).
    static var attachedRadius = Tokens.Radius.attached
    #else
    static let attachedRadius = Tokens.Radius.attached
    #endif
    /// Beside the sidebar the page rests on the frame as a sheet: a soft shadow falls onto the sidebar along its edge
    /// (the window's own edges hide it everywhere else); floating, the card keeps its whisper of shadow.
    private var castsShadow: Bool { !edgeToEdge }

    /// Squares the corners off (or rounds them back) over `duration`, in step with the sidebar sliding away or back.
    func setEdgeToEdge(_ on: Bool, duration: TimeInterval) {
        guard on != edgeToEdge else { return }
        edgeToEdge = on
        let radius = cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(duration == 0)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
        surface.layer?.cornerRadius = radius
        edge.cornerRadius = radius
        edge.opacity = on ? 0 : 1
        layer?.shadowOpacity = castsShadow ? 1 : 0
        ambient.shadowOpacity = castsShadow && isAttached ? 1 : 0
        CATransaction.commit()
        needsLayout = true
    }

    /// Page loading, in the space's accent: a thin line along the card's top edge that grows with the load and fades
    /// when done. Between WebKit's steps it keeps creeping on, so a slow page never looks stuck.
    private let progressLine = CALayer()
    private var progress: CGFloat = 0
    private var isShowingProgress = false
    private var creep: Timer?

    /// The page whose load the line shows: the one in this card, whichever tab is selected. In split view each card
    /// follows its own pane's page.
    private weak var loadingTab: Tab?
    private var loadingToken: SignalToken?

    func showLoading(of tab: Tab?) {
        guard tab !== loadingTab || loadingToken == nil else { return }
        loadingTab = tab
        loadingToken = tab?.changed.observe { [weak self, weak tab] change in
            guard let self, let tab, tab === self.loadingTab else { return }
            if change == .progress || change == .loading || change == .url || change == .navigation {
                self.setLoading(tab.isLoading, progress: tab.progress)
            }
        }
        // A different page: no line carried over from the last one, and nothing of it sweeping across this one.
        resetLoading()
        if let tab, tab.isLoading { setLoading(true, progress: tab.progress) }
    }

    /// The line gone at once, wherever it was.
    private func resetLoading() {
        progressLine.removeAllAnimations()
        stopCreeping()
        isShowingProgress = false
        progress = 0
        Tokens.Motion.withoutAnimation {
            progressLine.opacity = 0
            if progressLine.superlayer != nil { Tokens.Motion.withoutAnimation { layoutProgress() } }
        }
    }

    private func setLoading(_ loading: Bool, progress value: Double) {
        if progressLine.superlayer == nil {
            progressLine.opacity = 0
            // The surface is flipped: y counts from the top, so the line hangs from its top-left corner.
            progressLine.anchorPoint = CGPoint(x: 0, y: 0)
            // Above the page's own layer.
            progressLine.zPosition = 100
            surface.layer?.addSublayer(progressLine)
        }
        paintProgress()
        let target = loading ? max(0.08, CGFloat(value)) : 1
        guard loading || isShowingProgress else { return }
        if loading && !isShowingProgress {
            // A fresh load starts from the left edge.
            isShowingProgress = true
            progress = 0
            Tokens.Motion.withoutAnimation { progressLine.opacity = 1; layoutProgress() }
            startCreeping()
        }
        guard target >= progress || !loading else { return }
        progress = target
        CATransaction.begin()
        CATransaction.setAnimationDuration(loading ? Tokens.Motion.large : Tokens.Motion.standard)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
        layoutProgress()
        CATransaction.commit()
        guard !loading else { return }
        isShowingProgress = false
        stopCreeping()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Tokens.Motion.large)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
        progressLine.opacity = 0
        CATransaction.commit()
    }

    private func layoutProgress() {
        let top = contentTop
        // On the surface, over the card's edge, along the top of the page (under the band or header, if any). The
        // surface is flipped, so y counts down from its top.
        progressLine.bounds = CGRect(x: 0, y: 0, width: clip.frame.width * progress, height: 2)
        progressLine.position = CGPoint(x: clip.frame.minX, y: clip.frame.minY + top)
    }

    private func paintProgress() {
        Tokens.Motion.withoutAnimation { progressLine.backgroundColor = cgColor(Brand.Theme.current.accent) }
    }

    /// While the page loads, the line inches toward 90% between WebKit's steps, slower the further it gets. Not with
    /// Reduce Motion.
    private func startCreeping() {
        stopCreeping()
        guard !Tokens.Motion.reduceMotion else { return }
        creep = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowingProgress else { return }
                let next = self.progress + (0.9 - self.progress) * 0.05
                guard next > self.progress else { return }
                self.progress = next
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.5)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
                self.layoutProgress()
                CATransaction.commit()
            }
        }
    }

    private func stopCreeping() {
        creep?.invalidate()
        creep = nil
    }

    func setOverlay(_ view: NSView?) {
        overlay?.removeFromSuperview()
        overlay = view
        if let view {
            // Placed at once and kept in step with the card, so nothing of the page shows around it.
            let top = headerOnCard ? PaneHeaderView.height : 0
            view.frame = NSRect(x: 0, y: 0, width: clip.bounds.width, height: clip.bounds.height - top)
            view.autoresizingMask = [.width, .height]
            // Under the header while it's on the card; lent to the bar, the header isn't here.
            if header.superview === clip { clip.addSubview(view, positioned: .below, relativeTo: header) } else { clip.addSubview(view) }
        }
    }

    /// Out of sight under something opaque (the tab overview): the page is hidden, not just see-through, so WebKit
    /// knows it isn't shown and throttles it.
    var isCoveredOver = false { didSet { surface.isHidden = isCoveredOver } }

    /// Shown while a suspended tab wakes up so the card never flashes blank.
    private let placeholder = NSImageView()
    /// Beside the sidebar, the page's second shadow: wide and faint, spreading onto the sidebar under the tight one
    /// the card itself casts at its edge, the way a sheet of paper lies on a table.
    private let ambient = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        ambient.zPosition = -1
        ambient.backgroundColor = .clear
        layer?.addSublayer(ambient)
        layer?.shadowOpacity = 1
        layer?.shadowRadius = Tokens.Shadow.cardRadius
        layer?.shadowOffset = Tokens.Shadow.cardOffset

        surface.wantsLayer = true
        surface.layer?.cornerRadius = Tokens.Radius.card
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        // Resized with the card as its frame is set, inside the animation when there is one, so it glides too.
        surface.autoresizingMask = [.width, .height]
        // Its edges are drawn where they are, between two pixels too, as what it shows is. Cut to whole pixels, an
        // edge stays put for a few frames and then jumps one, while the page glides on: at the end of a move, where
        // a frame covers less than a pixel, the page seemed to catch up with its card.
        surface.layer?.allowsEdgeAntialiasing = true
        surface.layer?.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge, .layerBottomEdge, .layerTopEdge]
        turning.wantsLayer = true
        turning.layer?.cornerCurve = .continuous
        turning.layer?.masksToBounds = true
        turning.layer?.maskedCorners = []
        turning.autoresizingMask = [.width, .height]
        addSubview(turning)
        turning.addSubview(surface)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        surface.addSubview(clip)

        placeholder.imageScaling = .scaleProportionallyUpOrDown
        placeholder.imageAlignment = .alignTop
        placeholder.isHidden = true
        clip.addSubview(placeholder)

        edge.cornerRadius = Tokens.Radius.card
        edge.cornerCurve = .continuous
        edge.borderWidth = Tokens.Metric.hairline
        edge.zPosition = 10
        edge.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        surface.layer?.addSublayer(edge)
        header.isHidden = true
        clip.addSubview(header)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Around the surface, for the length of a move: the corners turning square or round again (`turnCorners`).
    private let turning = FlippedView()
    /// The corners that are round, as the last layout left them, and when the corners now turning will have turned.
    private var roundCorners: CACornerMask = .all
    private var turnsUntil: CFTimeInterval = 0

    /// The animation a layout is part of (Borderless page switched): how long it is and how it eases.
    private typealias Move = (duration: TimeInterval, timing: CAMediaTimingFunction?)
    private var move: Move? {
        let context = NSAnimationContext.current
        return context.allowsImplicitAnimation && context.duration > 0 ? (context.duration, context.timingFunction) : nil
    }

    /// Whether what covers the page moves with the card. A website is laid out only once, so its page takes its new
    /// size at once and the card's ground fills the rest. Settings is laid out by AppKit for any size and has a
    /// tinted column the ground can't stand in for: it glides with the card.
    ///
    /// It sits on the surface for that, not on the clip. The surface counts from its top, so Settings hangs from the
    /// card's top edge whatever the card's height is doing. On the clip, which counts from its bottom, its top would
    /// be the clip's height less its own: two heights changing in two animations, which on screen don't keep step,
    /// so Settings would run ahead of its card or behind it by a pixel or two.
    private func glides(_ document: NSView?) -> Bool { document is SettingsView }

    override func layout() {
        super.layout()
        // Everything is placed from the card's own bounds, not read back from the clip: inside an animation a view
        // still answers with the frame it had.
        let content = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - contentTop)
        // On the surface, under the band and the header; inside an animation it goes there with the card.
        if glides(document) { document?.frame = content.offsetBy(dx: 0, dy: contentTop) }
        let move = move
        Tokens.Motion.withoutAnimation {
            turning.frame = bounds
            surface.frame = bounds
            clip.frame = bounds
            // The clip isn't flipped: the band and then the header are at its top edge, the page fills the rest below.
            if !liftsHeader {
                header.frame = NSRect(x: 0, y: bounds.height - band - PaneHeaderView.height, width: bounds.width, height: PaneHeaderView.height)
            }
            // The holder is sized, not the page (it fills the holder beside a docked Web Inspector, and in full screen
            // WebKit sizes it), and only while it's in this card: the mini player or another window may have borrowed it.
            if let holder, holder.superview === clip {
                // A page with a size of its own keeps it as the card changes; any other fills the card with it.
                place(holder, in: content)
            }
            placeOutline()
            if !glides(document) { document?.frame = content }
            placeholder.frame = content
            overlay?.frame = content
            edge.frame = surface.bounds
            if progressLine.superlayer != nil { layoutProgress() }
            // Inside an animation the corners and the shadows follow the card as it moves, not at once.
            let radius = cornerRadius
            for layer in [surface.layer, edge].compactMap({ $0 }) where layer.cornerRadius != radius {
                follow(move, layer, "cornerRadius", from: (layer.presentation() ?? layer).cornerRadius)
                layer.cornerRadius = radius
            }
            // A layer's own corners count from the bottom, whichever way up its view is: the top ones are at max Y.
            var corners = CACornerMask.all
            if squaresRightCorners.top { corners.remove(.layerMaxXMaxYCorner) }
            if squaresRightCorners.bottom { corners.remove(.layerMaxXMinYCorner) }
            if squaresLeftCorners.top { corners.remove(.layerMinXMaxYCorner) }
            if squaresLeftCorners.bottom { corners.remove(.layerMinXMinYCorner) }
            corners = turnCorners(to: corners, radius: radius, over: move)
            surface.layer?.maskedCorners = corners
            edge.maskedCorners = corners
            // At their final outline at once, the shadows showed past the card as a band along the edges it had yet
            // to reach.
            let outline = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ambient.frame = bounds
            for shadow in [layer, ambient].compactMap({ $0 }) {
                follow(move, shadow, "shadowPath", from: (shadow.presentation() ?? shadow).shadowPath)
                shadow.shadowPath = outline
            }
        }
    }

    /// Has a layer's property go from `from` to what it is set to next over `move`, when there is one.
    private func follow(_ move: Move?, _ layer: CALayer, _ keyPath: String, from: Any?) {
        guard let move, let from else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.duration = move.duration
        animation.timingFunction = move.timing
        // Until it starts, a frame later than the card's own move can, the layer shows where it comes from.
        animation.fillMode = .backwards
        layer.add(animation, forKey: keyPath)
    }

    /// Takes the round corners to `corners` and returns the ones the surface rounds itself. A corner going square, or
    /// round again, inside an animation turns over its length. A layer has one radius for all its corners, and the
    /// others are turning to another one meanwhile, so those corners are handed to `turning` for the move: it takes
    /// them from the radius they had to the one they are going to.
    private func turnCorners(to corners: CACornerMask, radius: CGFloat, over move: Move?) -> CACornerMask {
        let now = CACurrentMediaTime()
        guard let move, corners != roundCorners, let turner = turning.layer else {
            // A layout in the middle of a move leaves the corners to it.
            guard now >= turnsUntil else { return surface.layer?.maskedCorners ?? corners }
            // At rest the surface rounds every round corner itself.
            turning.layer?.maskedCorners = []
            turning.layer?.cornerRadius = 0
            roundCorners = corners
            return corners
        }
        let squaring = roundCorners.subtracting(corners), rounding = corners.subtracting(roundCorners)
        // One way at a time: with corners going both ways at once, the ones rounding just appear.
        let turned = squaring.isEmpty ? rounding : squaring
        turner.maskedCorners = turned
        follow(move, turner, "cornerRadius", from: squaring.isEmpty ? 0 : (surface.layer?.presentation() ?? surface.layer)?.cornerRadius ?? 0)
        turner.cornerRadius = squaring.isEmpty ? radius : 0
        roundCorners = corners
        // Once they have turned, a layout hands them back to the surface.
        turnsUntil = now + move.duration
        DispatchQueue.main.asyncAfter(deadline: .now() + move.duration) { [weak self] in self?.needsLayout = true }
        return corners.subtracting(turned)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        paintProgress()
        Tokens.Motion.withoutAnimation {
            surface.layer?.backgroundColor = cgColor(ground)
            edge.borderColor = cgColor(Tokens.Color.cardEdge)
            // Meeting the window's edges, the page's own edge is its outline: a drawn one runs along the window's edge
            // and round the corners as an extra line.
            edge.borderWidth = isAttached ? 0 : Tokens.Metric.hairline
            header.alphaValue = headerAlpha
            layer?.shadowColor = cgColor(isAttached ? Tokens.Color.sheetContact : Tokens.Color.cardShadow)
            layer?.shadowOpacity = castsShadow ? 1 : 0
            layer?.shadowRadius = isAttached ? Tokens.Shadow.sheetContact : Tokens.Shadow.cardRadius
            layer?.shadowOffset = isAttached ? .zero : Tokens.Shadow.cardOffset
            ambient.shadowColor = cgColor(Tokens.Color.sheetShadow)
            ambient.shadowRadius = Tokens.Shadow.sheetRadius
            ambient.shadowOffset = .zero
            ambient.shadowOpacity = castsShadow && isAttached ? 1 : 0
        }
    }

    /// The page's color changed, or the page did: the card's ground follows, and so does the web view's own.
    private func refreshGround() {
        Tokens.Motion.withoutAnimation { surface.layer?.backgroundColor = cgColor(ground) }
        let pageColor = pageColor
        Self.paintGround(of: webView, pageColor)
        // The pane's strip lies on that color: its ink follows it.
        header.ground = pageColor
    }

    private static let setGround = NSSelectorFromString("_setBackgroundColor:")

    /// What WebKit shows where a page hasn't drawn yet is a plain ground of its own, light or dark with the window:
    /// a white strip down a dark site (or a dark one down a light site) for the few frames after the page is given
    /// more room, as when the sidebar goes. In the page's own color it reads as more of the page; nil gives the web
    /// view its own back, as it leaves the card. Not public API, so only where WebKit has it; without it, that
    /// strip is as it was.
    private static func paintGround(of webView: WKWebView?, _ color: NSColor?) {
        guard let webView, webView.responds(to: setGround) else { return }
        webView.perform(setGround, with: color)
    }

    /// Puts a web view in the card, in its holder. The new one goes in before the old one leaves, so nothing flickers.
    func show(_ newWebView: WKWebView?, placeholderImage: NSImage? = nil) {
        guard newWebView !== webView else { return }
        let old = webView, oldHolder = holder
        let owner = (newWebView as? BrowserWebView)?.owner
        // A tab's page comes in the tab's own holder, with whatever is docked beside it.
        let newHolder = owner?.pageHolder
        if let newHolder {
            let top = contentTop
            let content = NSRect(x: 0, y: 0, width: clip.bounds.width, height: clip.bounds.height - top)
            let fit = Self.pageFit(content: content, size: pageSize, docked: newHolder.dockedRoom, scales: Self.canScale(newWebView))
            newHolder.frame = fit.frame
            Self.apply(scale: fit.scale, to: newWebView)
            newHolder.autoresizingMask = pageSize == nil ? [.width, .height] : []
            // The Web Inspector docking beside a page with a size of its own makes room for itself.
            newHolder.onDockedRoomChange = { [weak self] in self?.needsLayout = true }
            if newHolder.superview !== clip { clip.addSubview(newHolder, positioned: .below, relativeTo: placeholder) }
        }
        webView = newWebView
        holder = newHolder
        // The old page's holder goes, unless it's this one again (its tab has a new page) or another card has it by now.
        // One whose video is in full screen stays until that ends: WebKit puts the page back in it then, and taken
        // out now, the full screen would be left without it.
        // The page that left is whoever shows it next's to size, filling its place as ever.
        if let oldHolder, oldHolder !== newHolder {
            oldHolder.onDockedRoomChange = nil
            oldHolder.autoresizingMask = [.width, .height]
            // At its own scale again wherever it's shown next (the mini player, another window).
            if old !== newWebView { Self.apply(scale: 1, to: old) }
        }
        if let oldHolder, oldHolder !== newHolder, oldHolder.superview === clip {
            if let old, old.fullscreenState != .notInFullscreen {
                fullScreenWatch = old.observe(\.fullscreenState) { [weak self] page, _ in
                    // WebKit puts the page back as its full screen finishes: looked at once it has.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.pageLeftFullScreen(page) } }
                }
            } else {
                oldHolder.removeFromSuperview()
            }
        }
        documentToken = owner?.changed.observe { [weak self] change in
            switch change {
            case .pdf, .settings:
                self?.refreshDocument()
                self?.refreshGround()
            case .themeColor, .darkPage: self?.refreshGround()
            default: break
            }
        }
        refreshDocument()
        placeholder.image = placeholderImage
        placeholder.isHidden = placeholderImage == nil
        // The page that left has its own ground back, whoever shows it next; the one that came has this card's.
        Self.paintGround(of: old, nil)
        refreshGround()
    }

    /// A page's full screen ended: WebKit put it back in its holder. Left here behind the page now shown, that holder
    /// goes, rather than staying under it with its page still on screen to itself.
    func pageLeftFullScreen(_ page: WKWebView) {
        guard page.fullscreenState == .notInFullscreen else { return }
        fullScreenWatch = nil
        if let left = page.superview, left !== holder, left.superview === clip { left.removeFromSuperview() }
        needsLayout = true
    }

    /// Puts the shown tab's PDF viewer (or Settings) over its page, or takes it away. Typing goes to it, as it did to
    /// the page.
    private func refreshDocument() {
        let owner = (webView as? BrowserWebView)?.owner
        let viewer: NSView? = owner?.pdfViewer ?? owner?.settingsView
        guard viewer !== document else { return }
        if let document, document.superview === clip || document.superview === surface {
            // Typing was in the viewer going away: it goes back to the page rather than nowhere.
            if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: document) {
                window.makeFirstResponder(webView)
            }
            document.removeFromSuperview()
        }
        document = viewer
        guard let viewer, let webView, let holder else { return }
        // The page's whole room, whatever the page's own size is: a page at a size of its own has a holder
        // smaller than that. Laid out again with the card.
        let room = NSRect(x: 0, y: 0, width: clip.bounds.width, height: max(0, clip.bounds.height - contentTop))
        needsLayout = true
        viewer.autoresizingMask = [.width, .height]
        if glides(viewer) {
            viewer.frame = room.offsetBy(dx: 0, dy: contentTop)
            surface.addSubview(viewer, positioned: .above, relativeTo: clip)
        } else {
            viewer.frame = room
            clip.addSubview(viewer, positioned: .above, relativeTo: holder)
        }
        if let window, window.firstResponder === webView { window.makeFirstResponder((viewer as? PDFViewerView)?.pdfView ?? viewer) }
    }

    func hidePlaceholder() {
        guard !placeholder.isHidden else { return }
        placeholder.isHidden = true
        placeholder.image = nil
    }
}

private extension CACornerMask {
    static let all: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
}
