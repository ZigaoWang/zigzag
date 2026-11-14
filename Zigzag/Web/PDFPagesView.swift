import AppKit
import QuartzCore

/// Where each page sits: one column of pages, or two side by side as in a book (the first page alone on the right),
/// centered, `margin` around and `gap` between, with room under the last page for the viewer's bar.
struct PDFLayout: Equatable {
    static let margin: CGFloat = Tokens.Space.x4
    static let gap: CGFloat = Tokens.Space.x3
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 8

    let frames: [CGRect]
    let size: CGSize

    /// The pages in rows, nil for the empty place left of a book's first page.
    static func rows(count: Int, twoUp: Bool) -> [[Int?]] {
        guard twoUp else { return (0..<count).map { [$0] } }
        guard count > 0 else { return [] }
        var rows: [[Int?]] = [[nil, 0]]
        var index = 1
        while index < count {
            rows.append(index + 1 < count ? [index, index + 1] : [index, nil])
            index += 2
        }
        return rows
    }

    /// The scale that fits the widest page (or two of them) across `width`.
    static func fitScale(sizes: [CGSize], twoUp: Bool, width: CGFloat) -> CGFloat {
        let widest = sizes.map(\.width).max() ?? 1
        let room = width - margin * 2 - (twoUp ? gap : 0)
        return min(max(room / (widest * (twoUp ? 2 : 1)), minScale), 4)
    }

    init(sizes: [CGSize], scale: CGFloat, twoUp: Bool, width: CGFloat, bottom: CGFloat = 0) {
        let widest = (sizes.map(\.width).max() ?? 0) * scale
        let content = twoUp ? widest * 2 + Self.gap : widest
        let documentWidth = max(width, content + Self.margin * 2)
        let middle = documentWidth / 2
        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var y = Self.margin
        for row in Self.rows(count: sizes.count, twoUp: twoUp) {
            let height = row.compactMap { $0.map { sizes[$0].height * scale } }.max() ?? 0
            for (column, index) in row.enumerated() {
                guard let index else { continue }
                let size = CGSize(width: sizes[index].width * scale, height: sizes[index].height * scale)
                let x = !twoUp ? middle - size.width / 2 : column == 0 ? middle - Self.gap / 2 - size.width : middle + Self.gap / 2
                frames[index] = CGRect(x: x, y: y + (height - size.height) / 2, width: size.width, height: size.height)
            }
            y += height + Self.gap
        }
        self.frames = frames
        size = CGSize(width: documentWidth, height: max(y - Self.gap + Self.margin + bottom, Self.margin * 2))
    }

    /// The pages whose frames meet `rect`, in order.
    func pages(in rect: CGRect) -> [Int] {
        // Rows only go down: the first whose bottom is past the rect's top, then on until past its bottom.
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY < rect.minY - Self.gap - 1 { low = mid + 1 } else { high = mid }
        }
        var found: [Int] = []
        var index = max(0, low - 1)
        while index < frames.count, frames[index].minY <= rect.maxY {
            if frames[index].intersects(rect) { found.append(index) }
            index += 1
        }
        return found
    }

    /// The page at `point`, or the nearest one.
    func page(at point: CGPoint) -> Int? {
        guard !frames.isEmpty else { return nil }
        let near = pages(in: CGRect(x: 0, y: point.y - 2000, width: size.width, height: 4000))
        let candidates = near.isEmpty ? Array(frames.indices) : near
        return candidates.min { distance(frames[$0], point) < distance(frames[$1], point) }
    }

    private func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX), dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dy * 4 + dx
    }
}

/// A place in the PDF's text: a page, and a UTF-16 unit on it.
struct PDFTextPoint: Comparable, Hashable {
    let page: Int
    let index: Int
    static func < (a: Self, b: Self) -> Bool { (a.page, a.index) < (b.page, b.index) }
}

/// Working with a page's text: which character a point is at, and the boxes a run of it fills, line by line.
enum PDFText {
    /// The character at `point` (in the page's points), or the nearest one on its line, or the nearest line's.
    static func index(at point: CGPoint, in boxes: [CGRect]) -> Int? {
        var best: Int?, bestDistance = CGFloat.infinity
        for (index, box) in boxes.enumerated() where box.width > 0 && box.height > 0 {
            if box.contains(point) { return index }
            let dx = max(box.minX - point.x, 0, point.x - box.maxX), dy = max(box.minY - point.y, 0, point.y - box.maxY)
            let distance = dy * 6 + dx
            if distance < bestDistance { bestDistance = distance; best = index }
        }
        return best
    }

    /// Whether `point` is on a character, give or take a little.
    static func isOnText(_ point: CGPoint, in boxes: [CGRect]) -> Bool {
        boxes.contains { $0.width > 0 && $0.height > 0 && $0.insetBy(dx: -2, dy: -2).contains(point) }
    }

    /// The boxes the characters in `range` fill, one for each run along a line.
    static func lines(_ range: Range<Int>, in boxes: [CGRect]) -> [CGRect] {
        var lines: [CGRect] = []
        var line: CGRect?
        for index in range where boxes.indices.contains(index) {
            let box = boxes[index]
            guard box.width > 0, box.height > 0 else { continue }
            if let current = line, abs(box.midY - current.midY) < max(box.height, current.height) / 2, box.minX > current.minX - 1 {
                line = current.union(box)
            } else {
                if let current = line { lines.append(current) }
                line = box
            }
        }
        if let line { lines.append(line) }
        return lines
    }

    /// The word around `index`, or the character itself when it isn't in one.
    static func word(at index: Int, in string: NSString) -> NSRange {
        guard index < string.length else { return NSRange(location: index, length: 0) }
        let line = string.lineRange(for: NSRange(location: index, length: 0))
        var found = NSRange(location: index, length: 1)
        string.enumerateSubstrings(in: line, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            if NSLocationInRange(index, range) { found = range; stop.pointee = true }
        }
        return found
    }

    /// The line around `index`, without its line break.
    static func line(at index: Int, in string: NSString) -> NSRange {
        guard index < string.length else { return NSRange(location: index, length: 0) }
        var range = string.lineRange(for: NSRange(location: index, length: 0))
        while range.length > 0, let scalar = UnicodeScalar(string.character(at: NSMaxRange(range) - 1)), CharacterSet.newlines.contains(scalar) {
            range.length -= 1
        }
        return range
    }
}

/// The pages of a PDF the sandboxed helper reads (`SafePDF`), drawn from what it sends back: pictures of the parts of
/// pages on screen, at the scale they're shown, so text stays sharp at any zoom; each page's text and links for
/// selecting, copying, find and clicking. Only the pages near the screen are asked for; what was drawn is kept a
/// while, and what scrolled away before its turn is never asked for.
///
/// Its scrolls go to its swipe first (`takesSwipe`), from the window, so the swipe sees every gesture begin and end.
@MainActor
final class ZigzagPDFView: NSView, NSMenuItemValidation {
    private(set) var document: SafePDF?
    private(set) var pageSizes: [CGSize] = []
    var pageCount: Int { pageSizes.count }
    private var allowsCopying = true

    var onSwipe: ((NSEvent, (left: Bool, right: Bool)) -> Bool)?
    /// The page at the top changed, or may have.
    var onPageChanged: (() -> Void)?
    /// A web link in the PDF was clicked.
    var onOpenURL: ((URL) -> Void)?
    /// A picture of a page came in for the sidebar's thumbnails.
    var onThumbnail: ((Int) -> Void)?

    let scrollView = NSScrollView()
    private let canvas = PDFCanvas()

    private(set) var scale: CGFloat = 1
    /// The pages fit the width, as the window changes; zooming turns it off.
    private(set) var autoScales = true
    var twoUp = false {
        didSet { if twoUp != oldValue { autoScales = true; relayout(keeping: topAnchor()) } }
    }
    var isDark = false {
        didSet { if isDark != oldValue { darkChanged() } }
    }
    var pageShadows = true {
        didSet { if pageShadows != oldValue { refreshLayers() } }
    }
    var backdrop: NSColor = Tokens.Color.pdfBackdrop {
        didSet { applyBackdrop() }
    }
    /// Room under the last page, clear of the bar.
    var bottomInset: CGFloat = 0

    private var pageLayout = PDFLayout(sizes: [], scale: 1, twoUp: false, width: 0)
    private var laidOutWidth: CGFloat = -1

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.documentView = canvas
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        canvas.owner = self
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        applyBackdrop()
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "PDF", comment: "VoiceOver label of the pages in the PDF viewer."))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private func applyBackdrop() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = backdrop.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackdrop()
        refreshLayers()
    }

    // MARK: The PDF

    func show(_ document: SafePDF, info: SafePDF.Info, startPage: Int) {
        self.document = document
        pageSizes = info.pageSizes
        allowsCopying = info.allowsCopying
        autoScales = true
        layoutSubtreeIfNeeded()
        relayout(keeping: nil)
        go(toPage: min(max(startPage, 0), pageCount - 1), y: nil, animated: false)
        refresh()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let anchor = pageLayout.frames.isEmpty ? nil : topAnchor()
        scrollView.frame = bounds
        // Only a new width moves the pages.
        if laidOutWidth != scrollView.contentSize.width { relayout(keeping: anchor) }
    }

    /// A place in a page (in its points), and where it sits in the visible area: kept still when the pages change size.
    private struct Anchor {
        let page: Int
        let point: CGPoint
        let inView: CGPoint
    }

    private var visible: CGRect { scrollView.contentView.bounds }

    private func anchor(at inView: CGPoint) -> Anchor? {
        let point = CGPoint(x: visible.minX + inView.x, y: visible.minY + inView.y)
        guard let page = pageLayout.page(at: point) else { return nil }
        let frame = pageLayout.frames[page]
        return Anchor(page: page, point: CGPoint(x: (point.x - frame.minX) / scale, y: (point.y - frame.minY) / scale), inView: inView)
    }

    private func topAnchor() -> Anchor? { anchor(at: CGPoint(x: visible.width / 2, y: 0)) }

    private func relayout(keeping anchor: Anchor?) {
        guard !pageSizes.isEmpty else { return }
        let width = scrollView.contentSize.width
        laidOutWidth = width
        if autoScales { scale = PDFLayout.fitScale(sizes: pageSizes, twoUp: twoUp, width: width) }
        pageLayout = PDFLayout(sizes: pageSizes, scale: scale, twoUp: twoUp, width: width, bottom: bottomInset)
        canvas.frame = CGRect(origin: .zero, size: CGSize(width: pageLayout.size.width, height: max(pageLayout.size.height, scrollView.contentSize.height)))
        if let anchor, pageLayout.frames.indices.contains(anchor.page) {
            let frame = pageLayout.frames[anchor.page]
            let point = CGPoint(x: frame.minX + anchor.point.x * scale, y: frame.minY + anchor.point.y * scale)
            scroll(to: CGPoint(x: point.x - anchor.inView.x, y: point.y - anchor.inView.y))
        }
        refreshLayers()
        refresh()
        onPageChanged?()
    }

    private func scroll(to origin: CGPoint) {
        let clip = scrollView.contentView
        let maxX = max(0, canvas.frame.width - clip.bounds.width), maxY = max(0, canvas.frame.height - clip.bounds.height)
        clip.scroll(to: CGPoint(x: min(max(origin.x, 0), maxX), y: min(max(origin.y, 0), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func scrolled() {
        refreshLayers()
        refresh()
        onPageChanged?()
    }

    // MARK: Where you are

    /// The page at the top of the view.
    var currentPage: Int {
        let point = CGPoint(x: visible.midX, y: visible.minY + 40)
        return pageLayout.page(at: point) ?? 0
    }

    /// Scrolls to a page (and a place down it, in its points), in one smooth move rather than a cut.
    func go(toPage page: Int, y: CGFloat?, animated: Bool) {
        guard pageLayout.frames.indices.contains(page) else { return }
        let frame = pageLayout.frames[page]
        let target = frame.minY + (y.map { min(max($0, 0), pageSizes[page].height) * scale } ?? 0) - Tokens.Space.x3
        var origin = visible.origin
        origin.y = target
        if frame.width > visible.width || frame.maxX > visible.maxX || frame.minX < visible.minX { origin.x = frame.midX - visible.width / 2 }
        let clip = scrollView.contentView
        origin.x = min(max(origin.x, 0), max(0, canvas.frame.width - clip.bounds.width))
        origin.y = min(max(origin.y, 0), max(0, canvas.frame.height - clip.bounds.height))
        guard animated, !Tokens.Motion.reduceMotion else {
            scroll(to: origin)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.snappy.duration
            context.timingFunction = Tokens.Motion.drawer
            clip.animator().setBoundsOrigin(origin)
        } completionHandler: { [weak self, weak clip] in
            MainActor.assumeIsolated {
                guard let self, let clip else { return }
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
                self.onPageChanged?()
            }
        }
    }

    /// Scrolls so a rect on a page (in its points) shows, if it doesn't already.
    func reveal(_ rect: CGRect, onPage page: Int) {
        guard pageLayout.frames.indices.contains(page) else { return }
        let frame = pageLayout.frames[page]
        let shown = CGRect(x: frame.minX + rect.minX * scale, y: frame.minY + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        let room = visible.insetBy(dx: 0, dy: min(80, visible.height / 4))
        guard !room.contains(shown) else { return }
        var origin = visible.origin
        origin.y = shown.midY - visible.height / 2
        if shown.minX < visible.minX || shown.maxX > visible.maxX { origin.x = shown.midX - visible.width / 2 }
        scroll(to: origin)
    }

    /// Whether the pages can scroll further left or right.
    private var sidewaysRoom: (left: Bool, right: Bool) {
        let shown = visible, all = canvas.frame
        return (shown.minX > all.minX + 0.5, shown.maxX < all.maxX - 0.5)
    }

    /// The window hands each scroll over the pages here first (`BrowserWindow.sendEvent`). Zoomed in, a sideways
    /// swipe pans until the pages reach their edge, and only then goes back or forward.
    func takesSwipe(_ event: NSEvent) -> Bool {
        onSwipe?(event, sidewaysRoom) == true
    }

    // MARK: Zoom

    func zoomIn() { zoom(to: scale * 1.25, at: nil) }
    func zoomOut() { zoom(to: scale / 1.25, at: nil) }

    /// The pages at their printed size, as in Preview.
    func actualSize() { zoom(to: 1, at: nil) }

    /// Back to fitting the window.
    func fitWidth() {
        autoScales = true
        relayout(keeping: topAnchor())
    }

    private var isMagnifying = false

    /// To `newScale`, keeping the point under `at` (in the view) where it is, or the middle of the view.
    private func zoom(to newScale: CGFloat, at point: CGPoint?) {
        guard !pageSizes.isEmpty else { return }
        let target = min(max(newScale, PDFLayout.minScale), PDFLayout.maxScale)
        let keep = anchor(at: point ?? CGPoint(x: visible.width / 2, y: visible.height / 2))
        autoScales = false
        scale = target
        relayout(keeping: keep)
    }

    fileprivate func magnify(_ event: NSEvent) {
        switch event.phase {
        case .began: isMagnifying = true
        case .ended, .cancelled: isMagnifying = false
        default: break
        }
        let point = scrollView.contentView.convert(event.locationInWindow, from: nil)
        zoom(to: scale * (1 + event.magnification), at: CGPoint(x: point.x - visible.minX, y: point.y - visible.minY))
        if !isMagnifying { refresh() }
    }

    /// A two-finger double tap: in to twice the fitting size at the pointer, or back to fitting.
    fileprivate func smartMagnify(_ event: NSEvent) {
        let fit = PDFLayout.fitScale(sizes: pageSizes, twoUp: twoUp, width: scrollView.contentSize.width)
        if autoScales || abs(scale - fit) < 0.01 {
            let point = scrollView.contentView.convert(event.locationInWindow, from: nil)
            zoom(to: fit * 2, at: CGPoint(x: point.x - visible.minX, y: point.y - visible.minY))
        } else {
            fitWidth()
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let line: CGFloat = 40, page = max(visible.height - 60, line)
        let shift = event.modifierFlags.contains(.shift), command = event.modifierFlags.contains(.command)
        var origin = visible.origin
        switch Int(event.keyCode) {
        case 49: origin.y += shift ? -page : page // space
        case 125: origin.y = command ? .greatestFiniteMagnitude : origin.y + line // down
        case 126: origin.y = command ? 0 : origin.y - line // up
        case 123: // left: sideways when zoomed in, else the page before
            if sidewaysRoom.left || sidewaysRoom.right { origin.x -= line } else { go(toPage: max(currentPage - (twoUp ? 2 : 1), 0), y: nil, animated: true); return }
        case 124:
            if sidewaysRoom.left || sidewaysRoom.right { origin.x += line } else { go(toPage: min(currentPage + (twoUp ? 2 : 1), pageCount - 1), y: nil, animated: true); return }
        case 121: origin.y += page // page down
        case 116: origin.y -= page // page up
        case 115: origin.y = 0 // home
        case 119: origin.y = .greatestFiniteMagnitude // end
        default:
            super.keyDown(with: event)
            return
        }
        scroll(to: origin)
    }

    // MARK: Pictures of the pages

    /// Pixels a side of each kept piece of a page.
    private static let chunkSide = 1024
    /// Pieces asked for together, at most, either way: the page is drawn once for all of them, well within the helper's limit.
    private static let block = 3

    private struct ChunkKey: Hashable {
        let page: Int
        /// The pixels per point, in 64ths.
        let level: Int
        let column: Int
        let row: Int
        let dark: Bool
    }

    private struct Chunk {
        let image: CGImage
        /// Where it is on its page, in points.
        let rect: CGRect
        var used: Int
    }

    private struct ThumbKey: Hashable {
        let page: Int
        let dark: Bool
    }

    private var chunks: [ChunkKey: Chunk] = [:]
    private var chunkLevels: [Int: Set<Int>] = [:]
    private var chunkBytes = 0
    private var thumbnails: [ThumbKey: (image: CGImage, used: Int)] = [:]
    private var texts: [Int: SafePDF.PageText] = [:]
    private var textUse: [Int: Int] = [:]
    private var clock = 0

    private static let chunkLimit = 160 * 1024 * 1024
    private static let chunkLimitAway = 24 * 1024 * 1024
    private static let thumbnailLimit = 240
    private static let textLimit = 400
    static let thumbnailWidth: CGFloat = 132

    private var level: Int {
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return max(1, Int((scale * backing * 64).rounded()))
    }

    private func pointsPerChunk(_ level: Int) -> CGFloat { CGFloat(Self.chunkSide) * 64 / CGFloat(level) }

    private func chunkRect(page: Int, level: Int, column: Int, row: Int) -> CGRect {
        let side = pointsPerChunk(level)
        return CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
            .intersection(CGRect(origin: .zero, size: pageSizes[page]))
    }

    /// The pieces of a page that cover `rect` (in its points) at `level`.
    private func chunkRange(page: Int, level: Int, covering rect: CGRect) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        let clipped = rect.intersection(CGRect(origin: .zero, size: pageSizes[page]))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let side = pointsPerChunk(level)
        let columns = Int(floor(clipped.minX / side))...Int(floor((clipped.maxX - 0.001) / side))
        let rows = Int(floor(clipped.minY / side))...Int(floor((clipped.maxY - 0.001) / side))
        return (columns, rows)
    }

    /// `rect` (in the pages' view) on page `page`, in its points.
    private func pagePoints(_ rect: CGRect, page: Int) -> CGRect {
        let frame = pageLayout.frames[page]
        return CGRect(x: (rect.minX - frame.minX) / scale, y: (rect.minY - frame.minY) / scale, width: rect.width / scale, height: rect.height / scale)
    }

    private func tick() -> Int { clock += 1; return clock }

    func thumbnail(of page: Int) -> CGImage? {
        guard let kept = thumbnails[ThumbKey(page: page, dark: isDark)] else { return nil }
        thumbnails[ThumbKey(page: page, dark: isDark)]?.used = tick()
        return kept.image
    }

    /// Pages the sidebar shows, whose thumbnails it wants.
    var thumbnailsWanted: [Int] = [] {
        didSet { if thumbnailsWanted != oldValue { refresh() } }
    }

    private func store(_ image: CGImage, for key: ChunkKey, rect: CGRect) {
        if let old = chunks[key] { chunkBytes -= old.image.bytesPerRow * old.image.height }
        chunks[key] = Chunk(image: image, rect: rect, used: tick())
        chunkLevels[key.page, default: []].insert(key.level)
        chunkBytes += image.bytesPerRow * image.height
        trimChunks(to: window == nil ? Self.chunkLimitAway : Self.chunkLimit)
    }

    /// The pieces used longest ago go first, until what's kept fits `limit`.
    private func trimChunks(to limit: Int) {
        guard chunkBytes > limit else { return }
        for (key, chunk) in chunks.sorted(by: { $0.value.used < $1.value.used }) {
            guard chunkBytes > limit else { break }
            chunks[key] = nil
            chunkBytes -= chunk.image.bytesPerRow * chunk.image.height
        }
        chunkLevels = [:]
        for key in chunks.keys { chunkLevels[key.page, default: []].insert(key.level) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A tab in the back keeps only a little of what it drew; back in front, it asks again.
        if window == nil { trimChunks(to: Self.chunkLimitAway) } else { refreshLayers(); refresh() }
    }

    private func darkChanged() {
        // The other look's pieces are no use now: they go at once, under the viewer's crossfade.
        for (key, chunk) in chunks where key.dark != isDark {
            chunks[key] = nil
            chunkBytes -= chunk.image.bytesPerRow * chunk.image.height
        }
        chunkLevels = [:]
        for key in chunks.keys { chunkLevels[key.page, default: []].insert(key.level) }
        refreshLayers()
        refresh()
    }

    // MARK: Asking the helper

    private enum Job: Hashable {
        case chunks(page: Int, level: Int, dark: Bool, columns: ClosedRange<Int>, rows: ClosedRange<Int>)
        case text(page: Int)
        case thumbnail(page: Int, dark: Bool)
    }

    private var queue: [Job] = []
    private var running: Set<Job> = []
    private static let maxRunning = 2
    private var whenReady: [() -> Void] = []
    /// Jobs the helper answered with nothing (a piece it wouldn't draw): not asked again until the pages are shown
    /// at another scale or the other way (light or dark), when they're new jobs anyway.
    private var emptyJobs: Set<Job> = []
    private var emptyFor: (level: Int, dark: Bool)?

    /// Works out what the screen needs, nearest first, and asks for it; whatever was waiting and isn't needed now is
    /// never asked for.
    func refresh() {
        guard let document, !document.hasFailed, !pageSizes.isEmpty, window != nil || !whenReady.isEmpty else { queue = []; return }
        let level = self.level, dark = isDark
        if emptyFor?.level != level || emptyFor?.dark != dark {
            emptyJobs = []
            emptyFor = (level, dark)
        }
        var jobs: [Job] = []
        var seen: Set<Job> = []
        func add(_ job: Job) { if !running.contains(job), !emptyJobs.contains(job), seen.insert(job).inserted { jobs.append(job) } }
        let shown = visible
        let near = shown.insetBy(dx: -shown.width / 2, dy: -shown.height * 0.75)
        let center = CGPoint(x: shown.midX, y: shown.midY)
        let onScreen = pageLayout.pages(in: shown).sorted {
            abs(pageLayout.frames[$0].midY - center.y) < abs(pageLayout.frames[$1].midY - center.y)
        }
        // A quick small picture of each page first, while the sharp one comes; then the sharp ones; then the text.
        for page in onScreen where thumbnails[ThumbKey(page: page, dark: dark)] == nil && !isCovered(page, in: shown, level: level) {
            add(.thumbnail(page: page, dark: dark))
        }
        if !isMagnifying {
            for page in onScreen { missingBlocks(page: page, in: shown, level: level).forEach(add) }
        }
        for page in onScreen where texts[page] == nil { add(.text(page: page)) }
        if !isMagnifying {
            for page in pageLayout.pages(in: near) where !onScreen.contains(page) { missingBlocks(page: page, in: near, level: level).forEach(add) }
        }
        for page in thumbnailsWanted where pageSizes.indices.contains(page) && thumbnails[ThumbKey(page: page, dark: dark)] == nil {
            add(.thumbnail(page: page, dark: dark))
        }
        queue = jobs
        pump()
        checkReady()
    }

    /// The blocks of pieces of `page` within `rect` not yet kept.
    private func missingBlocks(page: Int, in rect: CGRect, level: Int) -> [Job] {
        guard let range = chunkRange(page: page, level: level, covering: pagePoints(rect, page: page)) else { return [] }
        var jobs: [Job] = []
        var blockRow = range.rows.lowerBound - range.rows.lowerBound % Self.block
        while blockRow <= range.rows.upperBound {
            var blockColumn = range.columns.lowerBound - range.columns.lowerBound % Self.block
            while blockColumn <= range.columns.upperBound {
                var columns: ClosedRange<Int>?, rows: ClosedRange<Int>?
                for row in max(blockRow, range.rows.lowerBound)...min(blockRow + Self.block - 1, range.rows.upperBound) {
                    for column in max(blockColumn, range.columns.lowerBound)...min(blockColumn + Self.block - 1, range.columns.upperBound)
                    where chunks[ChunkKey(page: page, level: level, column: column, row: row, dark: isDark)] == nil {
                        columns = columns.map { min($0.lowerBound, column)...max($0.upperBound, column) } ?? column...column
                        rows = rows.map { min($0.lowerBound, row)...max($0.upperBound, row) } ?? row...row
                    }
                }
                if let columns, let rows { jobs.append(.chunks(page: page, level: level, dark: isDark, columns: columns, rows: rows)) }
                blockColumn += Self.block
            }
            blockRow += Self.block
        }
        return jobs
    }

    /// Whether the sharp pictures of `page` cover all of it within `rect`.
    private func isCovered(_ page: Int, in rect: CGRect, level: Int) -> Bool {
        guard let range = chunkRange(page: page, level: level, covering: pagePoints(rect, page: page)) else { return true }
        for row in range.rows {
            for column in range.columns where chunks[ChunkKey(page: page, level: level, column: column, row: row, dark: isDark)] == nil {
                return false
            }
        }
        return true
    }

    private func pump() {
        while running.count < Self.maxRunning, !queue.isEmpty {
            let job = queue.removeFirst()
            running.insert(job)
            Task { @MainActor [weak self] in
                await self?.perform(job)
                guard let self else { return }
                self.running.remove(job)
                self.refresh()
            }
        }
    }

    private func perform(_ job: Job) async {
        guard let document else { return }
        switch job {
        case let .chunks(page, level, dark, columns, rows):
            let first = chunkRect(page: page, level: level, column: columns.lowerBound, row: rows.lowerBound)
            let last = chunkRect(page: page, level: level, column: columns.upperBound, row: rows.upperBound)
            let rect = first.union(last)
            let pixels = CGFloat(level) / 64
            guard let image = await document.render(page: page, rect: rect, scale: pixels, dark: dark) else { emptyJobs.insert(job); return }
            // Cut into its pieces, each kept on its own.
            for row in rows {
                for column in columns {
                    let piece = chunkRect(page: page, level: level, column: column, row: row)
                    let x = (column - columns.lowerBound) * Self.chunkSide, y = (row - rows.lowerBound) * Self.chunkSide
                    let width = min(Self.chunkSide, image.width - x), height = min(Self.chunkSide, image.height - y)
                    guard width > 0, height > 0, !piece.isNull, let cut = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else { continue }
                    store(cut, for: ChunkKey(page: page, level: level, column: column, row: row, dark: dark), rect: piece)
                }
            }
            refreshLayers(pages: [page])
        case let .thumbnail(page, dark):
            let size = pageSizes[page]
            let backing = window?.backingScaleFactor ?? 2
            let pixels = min(Self.thumbnailWidth * backing / size.width, 1024 / max(size.width, size.height) * backing, PDFLimits.maxScale)
            guard let image = await document.render(page: page, rect: CGRect(origin: .zero, size: size), scale: pixels, dark: dark) else {
                emptyJobs.insert(job)
                return
            }
            thumbnails[ThumbKey(page: page, dark: dark)] = (image, tick())
            if thumbnails.count > Self.thumbnailLimit, let oldest = thumbnails.min(by: { $0.value.used < $1.value.used }) {
                thumbnails[oldest.key] = nil
            }
            refreshLayers(pages: [page])
            onThumbnail?(page)
        case let .text(page):
            let text = await document.text(page: page) ?? SafePDF.PageText(string: "", boxes: [], links: [])
            texts[page] = text
            textUse[page] = tick()
            if texts.count > Self.textLimit, let oldest = textUse.min(by: { $0.value < $1.value })?.key, oldest != page {
                texts[oldest] = nil
                textUse[oldest] = nil
            }
            refreshLayers(pages: [page])
            textArrived(page)
        }
    }

    /// Calls `done` once what's on screen is drawn sharp (or after a moment, whatever came by then).
    func whenShown(_ done: @escaping () -> Void) {
        whenReady.append(done)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.fireReady() }
        refresh()
    }

    private func checkReady() {
        guard !whenReady.isEmpty else { return }
        let shown = visible, level = self.level
        if pageLayout.pages(in: shown).allSatisfy({ isCovered($0, in: shown, level: level) }) || document?.hasFailed == true { fireReady() }
    }

    private func fireReady() {
        let calls = whenReady
        whenReady = []
        calls.forEach { $0() }
    }

    // MARK: Layers

    /// One page on screen: its paper and shadow, the pictures of it, and the marks over them (found, selected).
    private final class PageLayers {
        let paper = CALayer()
        let thumbnail = CALayer()
        let found = CAShapeLayer()
        let current = CAShapeLayer()
        let selection = CAShapeLayer()
        var pieces: [ChunkKey: CALayer] = [:]

        init() {
            [paper, thumbnail, found, current, selection].forEach { $0.actions = PageLayers.noActions }
            thumbnail.contentsGravity = .resize
            thumbnail.magnificationFilter = .linear
            paper.addSublayer(thumbnail)
            for mark in [found, current, selection] {
                mark.zPosition = 10
                paper.addSublayer(mark)
            }
            paper.shadowColor = CGColor(gray: 0, alpha: 1)
            paper.shadowRadius = 3
            paper.shadowOffset = CGSize(width: 0, height: -1)
        }

        static let noActions: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "frame": NSNull(),
                                                     "path": NSNull(), "backgroundColor": NSNull(), "shadowOpacity": NSNull(),
                                                     "shadowPath": NSNull(), "hidden": NSNull(), "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
    }

    private var pageLayers: [Int: PageLayers] = [:]

    /// Puts the pages near the screen in their layers, at their place and size, with the best pictures kept of them.
    private func refreshLayers(pages only: [Int]? = nil) {
        guard let root = canvas.layer, !pageSizes.isEmpty else {
            pageLayers.values.forEach { $0.paper.removeFromSuperlayer() }
            pageLayers = [:]
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let near = visible.insetBy(dx: -visible.width / 4, dy: -visible.height / 2)
        let wanted = Set(pageLayout.pages(in: near))
        for (page, layers) in pageLayers where !wanted.contains(page) {
            layers.paper.removeFromSuperlayer()
            pageLayers[page] = nil
        }
        var paperColor = CGColor(gray: 1, alpha: 1), selectionColor = CGColor(gray: 0, alpha: 0.2)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(isDark ? 0.55 : 0.45).cgColor
        }
        if isDark { paperColor = CGColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1) }
        let level = self.level
        for page in wanted where only == nil || only?.contains(page) == true || pageLayers[page] == nil {
            let layers = pageLayers[page] ?? {
                let made = PageLayers()
                root.addSublayer(made.paper)
                pageLayers[page] = made
                return made
            }()
            let frame = pageLayout.frames[page]
            layers.paper.frame = frame
            layers.paper.backgroundColor = paperColor
            layers.paper.shadowOpacity = pageShadows && !isDark ? 0.22 : 0
            layers.paper.shadowPath = CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil)
            layers.thumbnail.frame = CGRect(origin: .zero, size: frame.size)
            layers.thumbnail.contents = thumbnails[ThumbKey(page: page, dark: isDark)]?.image
            placePieces(page: page, layers: layers, level: level, near: near)
            placeMarks(page: page, layers: layers, selectionColor: selectionColor)
        }
    }

    /// The sharp pictures at today's scale; where some are missing, the ones from the nearest other scale under them.
    private func placePieces(page: Int, layers: PageLayers, level: Int, near: CGRect) {
        var keys: [ChunkKey] = []
        let area = pagePoints(near, page: page)
        if let range = chunkRange(page: page, level: level, covering: area) {
            var complete = true
            for row in range.rows {
                for column in range.columns {
                    let key = ChunkKey(page: page, level: level, column: column, row: row, dark: isDark)
                    if chunks[key] != nil { keys.append(key) } else { complete = false }
                }
            }
            if !complete, let other = (chunkLevels[page] ?? []).filter({ $0 != level }).min(by: { abs($0 - level) < abs($1 - level) }),
               let range = chunkRange(page: page, level: other, covering: area) {
                for row in range.rows {
                    for column in range.columns {
                        let key = ChunkKey(page: page, level: other, column: column, row: row, dark: isDark)
                        if chunks[key] != nil { keys.append(key) }
                    }
                }
            }
        }
        let wanted = Set(keys)
        for (key, layer) in layers.pieces where !wanted.contains(key) {
            layer.removeFromSuperlayer()
            layers.pieces[key] = nil
        }
        for key in keys {
            guard var chunk = chunks[key] else { continue }
            chunk.used = tick()
            chunks[key] = chunk
            let layer = layers.pieces[key] ?? {
                let made = CALayer()
                made.actions = PageLayers.noActions
                made.contentsGravity = .resize
                made.contents = chunk.image
                layers.paper.insertSublayer(made, above: layers.thumbnail)
                layers.pieces[key] = made
                return made
            }()
            layer.zPosition = key.level == level ? 2 : 1
            layer.frame = CGRect(x: chunk.rect.minX * scale, y: chunk.rect.minY * scale, width: chunk.rect.width * scale, height: chunk.rect.height * scale)
        }
    }

    private func placeMarks(page: Int, layers: PageLayers, selectionColor: CGColor) {
        func path(_ rects: [CGRect]) -> CGPath? {
            guard !rects.isEmpty else { return nil }
            let path = CGMutablePath()
            for rect in rects {
                let shown = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).insetBy(dx: -1, dy: -1)
                path.addRoundedRect(in: shown, cornerWidth: min(2, shown.width / 2), cornerHeight: min(2, shown.height / 2))
            }
            return path
        }
        let bounds = CGRect(origin: .zero, size: pageLayout.frames[page].size)
        [layers.found, layers.current, layers.selection].forEach { $0.frame = bounds }
        guard let text = texts[page] else {
            [layers.found, layers.current, layers.selection].forEach { $0.path = nil }
            return
        }
        let matchesHere = findMatches.enumerated().filter { $0.element.page == page }
        layers.found.path = path(matchesHere.filter { $0.offset != currentMatch }.flatMap { PDFText.lines(Range($0.element.range) ?? 0..<0, in: text.boxes) })
        layers.found.fillColor = CGColor(srgbRed: 1, green: 0.84, blue: 0.1, alpha: isDark ? 0.4 : 0.38)
        layers.current.path = path(matchesHere.filter { $0.offset == currentMatch }.flatMap { PDFText.lines(Range($0.element.range) ?? 0..<0, in: text.boxes) })
        layers.current.fillColor = CGColor(srgbRed: 1, green: 0.78, blue: 0, alpha: isDark ? 0.75 : 0.7)
        layers.selection.path = path(selectedRange(on: page).map { PDFText.lines($0, in: text.boxes) } ?? [])
        layers.selection.fillColor = selectionColor
    }

    /// What's on screen, for the tab's picture in the switcher and all-tabs view, and the crossfade to dark pages.
    func snapshot() -> NSImage? {
        guard let layer, bounds.width >= 1, bounds.height >= 1 else { return nil }
        let backing = window?.backingScaleFactor ?? 2
        let width = Int(bounds.width * backing), height = Int(bounds.height * backing)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: backing, y: backing)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: bounds.size)
    }

    // MARK: Text

    private var selection: (anchor: PDFTextPoint, head: PDFTextPoint)?

    /// The selected run on `page`, if any of it is there and its text is here.
    private func selectedRange(on page: Int) -> Range<Int>? {
        guard let selection, let text = texts[page] else { return nil }
        let start = min(selection.anchor, selection.head), end = max(selection.anchor, selection.head)
        guard page >= start.page, page <= end.page else { return nil }
        let from = page == start.page ? start.index : 0
        let to = page == end.page ? end.index + 1 : text.string.length
        return from < to ? from..<min(to, text.string.length) : nil
    }

    var hasSelection: Bool { selection != nil }

    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        refreshLayers()
    }

    private func select(_ anchor: PDFTextPoint, _ head: PDFTextPoint) {
        selection = (anchor, head)
        refreshLayers()
    }

    /// The text at a point in the pages' view: the page, and the nearest character on it, if its text is here.
    private func textPoint(at point: CGPoint) -> PDFTextPoint? {
        guard let page = pageLayout.page(at: point), let text = texts[page] else { return nil }
        let frame = pageLayout.frames[page]
        let inPage = CGPoint(x: (point.x - frame.minX) / scale, y: (point.y - frame.minY) / scale)
        return PDFText.index(at: inPage, in: text.boxes).map { PDFTextPoint(page: page, index: $0) }
    }

    private func link(at point: CGPoint) -> SafePDF.Link? {
        guard let page = pageLayout.page(at: point), pageLayout.frames[page].contains(point), let text = texts[page] else { return nil }
        let frame = pageLayout.frames[page]
        let inPage = CGPoint(x: (point.x - frame.minX) / scale, y: (point.y - frame.minY) / scale)
        return text.links.last { $0.rect.contains(inPage) }
    }

    private func isOnText(_ point: CGPoint) -> Bool {
        guard let page = pageLayout.page(at: point), pageLayout.frames[page].contains(point), let text = texts[page] else { return false }
        let frame = pageLayout.frames[page]
        return PDFText.isOnText(CGPoint(x: (point.x - frame.minX) / scale, y: (point.y - frame.minY) / scale), in: text.boxes)
    }

    private var pressedLink: SafePDF.Link?
    private var pressPoint: CGPoint?
    private var dragged = false
    /// Where a drag's selection starts: the character pressed, or the start of the word or line a double or triple
    /// click selected, or the selection's own start with Shift held.
    private var dragAnchor: PDFTextPoint?

    fileprivate func mouseDown(_ event: NSEvent, at point: CGPoint) {
        window?.makeFirstResponder(self)
        pressPoint = point
        dragged = false
        dragAnchor = nil
        pressedLink = event.clickCount == 1 ? link(at: point) : nil
        guard pressedLink == nil, let hit = textPoint(at: point), let text = texts[hit.page] else {
            if event.clickCount == 1 { clearSelection() }
            return
        }
        switch event.clickCount {
        case 1:
            if event.modifierFlags.contains(.shift), let selection {
                dragAnchor = selection.anchor
                select(selection.anchor, hit)
            } else {
                // A click alone selects nothing: the selection starts once the pointer moves.
                dragAnchor = hit
                clearSelection()
            }
        default:
            let range = event.clickCount == 2 ? PDFText.word(at: hit.index, in: text.string) : PDFText.line(at: hit.index, in: text.string)
            guard range.length > 0 else { return }
            dragAnchor = PDFTextPoint(page: hit.page, index: range.location)
            select(PDFTextPoint(page: hit.page, index: range.location), PDFTextPoint(page: hit.page, index: NSMaxRange(range) - 1))
        }
    }

    fileprivate func mouseDragged(_ event: NSEvent, at point: CGPoint) {
        guard let start = pressPoint else { return }
        if !dragged, hypot(point.x - start.x, point.y - start.y) < 3 { return }
        dragged = true
        pressedLink = nil
        canvas.autoscroll(with: event)
        if dragAnchor == nil { dragAnchor = textPoint(at: start) }
        // The page dragged onto has no text here yet: it's asked for, and the selection follows as the pointer does.
        guard let anchor = dragAnchor, let head = textPoint(at: point) else { refresh(); return }
        select(anchor, head)
    }

    fileprivate func mouseUp(_ event: NSEvent, at point: CGPoint) {
        defer { pressPoint = nil; pressedLink = nil }
        guard !dragged, let link = pressedLink, self.link(at: point)?.rect == link.rect else { return }
        if let url = link.url {
            onOpenURL?(url)
        } else if let page = link.page {
            go(toPage: page, y: link.y, animated: true)
        }
    }

    fileprivate func mouseMoved(at point: CGPoint) {
        if link(at: point) != nil { NSCursor.pointingHand.set() } else if isOnText(point) { NSCursor.iBeam.set() } else { NSCursor.arrow.set() }
    }

    /// A page's text came in: a match waiting on it is shown.
    private func textArrived(_ page: Int) {
        if pendingFind?.page == page { revealCurrentMatch() }
    }

    /// The selected text, every page of it: asked of the helper for pages whose text isn't here.
    func selectedText() async -> String? {
        guard let selection else { return nil }
        let start = min(selection.anchor, selection.head), end = max(selection.anchor, selection.head)
        var parts: [String] = []
        for page in start.page...end.page {
            let string: NSString
            if let text = texts[page] { string = text.string } else if let strings = findStrings, strings.indices.contains(page) {
                string = strings[page] as NSString
            } else if let text = await document?.text(page: page) {
                string = text.string
            } else { continue }
            let from = page == start.page ? start.index : 0
            let to = min(page == end.page ? end.index + 1 : string.length, string.length)
            if from < to { parts.append(string.substring(with: NSRange(location: from, length: to - from))) }
        }
        return parts.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard allowsCopying else { NSSound.beep(); return }
        Task { @MainActor [weak self] in
            guard let text = await self?.selectedText(), !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    override func selectAll(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self, let strings = await self.allStrings(), let last = strings.indices.last else { return }
            let length = (strings[last] as NSString).length
            self.select(PDFTextPoint(page: 0, index: 0), PDFTextPoint(page: last, index: max(length - 1, 0)))
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selection != nil && allowsCopying }
        if item.action == #selector(selectAll(_:)) { return document != nil }
        return true
    }

    func menu(at point: CGPoint) -> NSMenu? {
        let menu = NSMenu()
        if selection != nil, allowsCopying {
            menu.addItem(withTitle: String(localized: "Copy", comment: "Context menu item in the PDF viewer: copies the selected text."), action: #selector(copy(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: String(localized: "Zoom In", comment: "Context menu item in the PDF viewer."), action: #selector(zoomInItem), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Zoom Out", comment: "Context menu item in the PDF viewer."), action: #selector(zoomOutItem), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Fit Width", comment: "Context menu item in the PDF viewer: scales the pages to fit the window's width."), action: #selector(fitItem), keyEquivalent: "").target = self
        return menu
    }

    @objc private func zoomInItem() { zoomIn() }
    @objc private func zoomOutItem() { zoomOut() }
    @objc private func fitItem() { fitWidth() }

    // MARK: Find

    private var findStrings: [String]?
    private var stringsTask: Task<[String]?, Never>?
    private var findMatches: [(page: Int, range: NSRange)] = []
    private var currentMatch: Int?
    private var pendingFind: (page: Int, range: NSRange)?
    private var search: Task<[(page: Int, range: NSRange)], Never>?

    private func allStrings() async -> [String]? {
        if let findStrings { return findStrings }
        // One asking for everyone waiting: each keystroke of a search doesn't ask the helper again.
        if let stringsTask { return await stringsTask.value }
        guard let document else { return nil }
        let task = Task { @MainActor in await document.strings() }
        stringsTask = task
        let strings = await task.value
        stringsTask = nil
        findStrings = strings
        return strings
    }

    /// Every match of `query` in the PDF, case and accents aside, looked for off the main thread. A newer query
    /// stops the one before, which comes back empty.
    func matches(of query: String) async -> [(page: Int, range: NSRange)] {
        search?.cancel()
        search = nil
        guard !query.isEmpty, let strings = await allStrings() else { return [] }
        let task = Task.detached(priority: .userInitiated) { Self.matches(of: query, in: strings) }
        search = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Every match of `query` in `strings`, by page; empty once its task is cancelled.
    nonisolated static func matches(of query: String, in strings: [String]) -> [(page: Int, range: NSRange)] {
        var found: [(page: Int, range: NSRange)] = []
        for (page, string) in strings.enumerated() {
            if Task.isCancelled { return [] }
            let text = string as NSString
            var from = 0
            while from < text.length {
                let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: text.length - from))
                guard range.location != NSNotFound, range.length > 0 else { break }
                found.append((page, range))
                from = NSMaxRange(range)
            }
        }
        return Task.isCancelled ? [] : found
    }

    func showMatches(_ matches: [(page: Int, range: NSRange)], current: Int?) {
        findMatches = matches
        currentMatch = current
        pendingFind = current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        if let pendingFind {
            // Its page first, so its text (and where the match is on it) can come.
            if texts[pendingFind.page] == nil { go(toPage: pendingFind.page, y: nil, animated: false) }
            revealCurrentMatch()
        }
        refreshLayers()
    }

    private func revealCurrentMatch() {
        guard let match = pendingFind, let text = texts[match.page] else { refresh(); return }
        pendingFind = nil
        let lines = PDFText.lines(Range(match.range) ?? 0..<0, in: text.boxes)
        if let first = lines.first { reveal(lines.dropFirst().reduce(first) { $0.union($1) }, onPage: match.page) } else { go(toPage: match.page, y: nil, animated: false) }
        refreshLayers(pages: [match.page])
    }

    func clearFind() {
        findMatches = []
        currentMatch = nil
        pendingFind = nil
        clearSelection()
        refreshLayers()
    }
}

/// The pages' scrolling surface: its layers are the pages (`ZigzagPDFView`); it passes the pointer on.
private final class PDFCanvas: NSView {
    weak var owner: ZigzagPDFView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) { owner?.mouseDown(event, at: point(event)) }
    override func mouseDragged(with event: NSEvent) { owner?.mouseDragged(event, at: point(event)) }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp(event, at: point(event)) }
    override func mouseMoved(with event: NSEvent) { owner?.mouseMoved(at: point(event)) }
    override func magnify(with event: NSEvent) { owner?.magnify(event) }
    override func smartMagnify(with event: NSEvent) { owner?.smartMagnify(event) }
    override func menu(for event: NSEvent) -> NSMenu? { owner?.menu(at: point(event)) }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
}

/// The pages down the sidebar, small: click one to go there; the one you're on is marked.
final class PDFThumbnailsView: NSView {
    private let scroll = NSScrollView()
    private let list = ThumbnailList()
    var onPick: ((Int) -> Void)?
    weak var pages: ZigzagPDFView? {
        didSet { list.pages = pages; reload() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = list
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        list.onPick = { [weak self] page in self?.onPick?(page) }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func reload() {
        list.reload()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        list.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(list.contentHeight, bounds.height))
        scrolled()
    }

    override func viewDidHide() {
        super.viewDidHide()
        pages?.thumbnailsWanted = []
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        scrolled()
    }

    @objc private func scrolled() {
        guard !isHiddenOrHasHiddenAncestor else { pages?.thumbnailsWanted = []; return }
        pages?.thumbnailsWanted = list.pages(in: scroll.contentView.bounds.insetBy(dx: 0, dy: -200))
    }

    func thumbnailArrived(_ page: Int) { list.redraw(page) }

    func markCurrent(_ page: Int) {
        guard list.current != page else { return }
        list.current = page
        // The page you're on stays in sight in the sidebar.
        if let frame = list.cellFrame(page), !isHiddenOrHasHiddenAncestor {
            let shown = scroll.contentView.bounds
            if frame.minY < shown.minY || frame.maxY > shown.maxY {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, min(frame.midY - shown.height / 2, list.frame.height - shown.height))))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }
}

private final class ThumbnailList: NSView {
    weak var pages: ZigzagPDFView?
    var onPick: ((Int) -> Void)?
    var current = -1 {
        didSet {
            if let old = cellFrame(oldValue) { setNeedsDisplay(old) }
            if let new = cellFrame(current) { setNeedsDisplay(new) }
        }
    }
    private var cells: [CGRect] = []
    private(set) var contentHeight: CGFloat = 0
    private let label = Tokens.Font.small(.medium)

    override var isFlipped: Bool { true }

    func reload() {
        guard let pages else { cells = []; return }
        let width = ZigzagPDFView.thumbnailWidth
        var y = Tokens.Space.x3
        cells = pages.pageSizes.map { size in
            let height = min(width * size.height / size.width, width * 1.6)
            let cell = CGRect(x: 0, y: y, width: 0, height: height + Tokens.Space.x2 * 2 + 16)
            y += cell.height + Tokens.Space.x1
            return cell
        }
        contentHeight = y + Tokens.Space.x2
        needsDisplay = true
    }

    func cellFrame(_ page: Int) -> CGRect? {
        guard cells.indices.contains(page) else { return nil }
        return CGRect(x: Tokens.Space.x3, y: cells[page].minY, width: bounds.width - Tokens.Space.x6, height: cells[page].height)
    }

    func pages(in rect: CGRect) -> [Int] { cells.indices.filter { cells[$0].maxY >= rect.minY && cells[$0].minY <= rect.maxY } }

    func redraw(_ page: Int) { if let frame = cellFrame(page) { setNeedsDisplay(frame) } }

    private func imageFrame(_ page: Int) -> CGRect? {
        guard let cell = cellFrame(page), let size = pages?.pageSizes[page] else { return nil }
        let width = ZigzagPDFView.thumbnailWidth
        let height = min(width * size.height / size.width, width * 1.6)
        let fitted = height < width * size.height / size.width ? height * size.width / size.height : width
        return CGRect(x: round(cell.midX - fitted / 2), y: cell.minY + Tokens.Space.x2, width: round(fitted), height: round(height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pages else { return }
        for page in self.pages(in: dirtyRect) {
            guard let cell = cellFrame(page), let frame = imageFrame(page) else { continue }
            if page == current {
                Tokens.Color.selectedFill.setFill()
                NSBezierPath(roundedRect: cell, xRadius: Tokens.Radius.row, yRadius: Tokens.Radius.row).fill()
            }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(pages.isDark ? 0 : 0.2)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            (pages.isDark ? NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1) : NSColor.white).setFill()
            frame.fill()
            NSGraphicsContext.restoreGraphicsState()
            if let image = pages.thumbnail(of: page) {
                NSImage(cgImage: image, size: frame.size).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
            let number = NSAttributedString(string: "\(page + 1)", attributes: [
                .font: label, .foregroundColor: page == current ? Tokens.Color.textPrimary : Tokens.Color.textSecondary,
            ])
            let size = number.size()
            number.draw(at: CGPoint(x: cell.midX - size.width / 2, y: frame.maxY + Tokens.Space.x1))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let page = cells.indices.first(where: { cellFrame($0)?.contains(point) == true }) { onPick?(page) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
