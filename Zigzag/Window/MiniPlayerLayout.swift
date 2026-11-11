import CoreGraphics
import Foundation

/// A video on a page, as the page's own script sees it (`PageVideos`): where it is in its frame, in CSS pixels from
/// the top left of the frame's viewport, and how it's playing.
nonisolated struct PageVideo: Equatable, Sendable {
    /// Its place among the frame's videos, as the script last listed them: what commands name it by.
    var index: Int
    var rect: CGRect
    /// The picture's own size (`videoWidth` by `videoHeight`); zero until it has a frame.
    var natural: CGSize
    var isPlaying: Bool
    var hasEnded = false
    /// Muted, or its volume all the way down.
    var isMuted = false
    var loops = false
    var autoplays = false
    var hasControls = false
    /// Its CSS object-fit.
    var fit = "contain"
    var time: Double = 0
    /// Nil for a live stream, or before the page knows.
    var duration: Double?

    init(index: Int, rect: CGRect, natural: CGSize, isPlaying: Bool, hasEnded: Bool = false, isMuted: Bool = false, loops: Bool = false,
         autoplays: Bool = false, hasControls: Bool = false, fit: String = "contain", time: Double = 0, duration: Double? = nil) {
        self.index = index
        self.rect = rect
        self.natural = natural
        self.isPlaying = isPlaying
        self.hasEnded = hasEnded
        self.isMuted = isMuted
        self.loops = loops
        self.autoplays = autoplays
        self.hasControls = hasControls
        self.fit = fit
        self.time = time
        self.duration = duration
    }

    /// From one entry of what the script posts.
    init?(_ value: Any) {
        guard let o = value as? [String: Any], let index = o["i"] as? Int else { return nil }
        func number(_ key: String) -> Double { (o[key] as? NSNumber)?.doubleValue ?? 0 }
        func flag(_ key: String) -> Bool { o[key] as? Bool ?? false }
        let duration = number("d")
        self.init(index: index, rect: CGRect(x: number("x"), y: number("y"), width: number("w"), height: number("h")),
                  natural: CGSize(width: number("vw"), height: number("vh")), isPlaying: flag("playing"), hasEnded: flag("ended"),
                  isMuted: flag("muted"), loops: flag("loop"), autoplays: flag("autoplay"), hasControls: flag("controls"),
                  fit: o["fit"] as? String ?? "contain", time: number("t"), duration: duration > 0 ? duration : nil)
    }

    /// A muted loop or a muted autoplaying picture with no controls: a page's moving background, not something you
    /// were watching.
    var isDecoration: Bool { isMuted && (loops || autoplays) && !hasControls }
}

/// The arithmetic of the mini player: which video follows you out of a tab, how big its card is, where the card sits,
/// and how the page is placed in it so only the video shows. Nothing here touches a view.
nonisolated enum MiniPlayerLayout {
    /// Narrower than this, a video isn't the thing on the page (a thumbnail, an avatar).
    static let smallestVideo = CGSize(width: 120, height: 68)
    /// The card's width: a third of the page area, within these.
    static let minimumWidth: CGFloat = 240
    static let maximumWidth: CGFloat = 480
    static let widthShare: CGFloat = 0.32
    /// It never takes more than this much of the page area's height.
    static let heightShare: CGFloat = 0.5
    /// From the page area's edges.
    static let margin: CGFloat = 12
    /// Widest and tallest shapes a card takes; a video beyond them is cropped to fit.
    static let aspectRange: ClosedRange<CGFloat> = 0.5...2.4

    /// Whether it would follow you out of its tab: playing, big enough, and not a page's moving background.
    static func follows(_ video: PageVideo) -> Bool {
        video.isPlaying && !video.hasEnded && video.natural.width > 0 && video.natural.height > 0
            && video.rect.width >= smallestVideo.width && video.rect.height >= smallestVideo.height && !video.isDecoration
    }

    /// How much of `rect` is inside the viewport.
    static func visibleArea(_ rect: CGRect, viewport: CGSize) -> CGFloat {
        let seen = rect.intersection(CGRect(origin: .zero, size: viewport))
        return seen.isNull ? 0 : seen.width * seen.height
    }

    /// The one to follow you: of those that would, one you can hear before a silent one, then the one that shows the
    /// most, then the biggest.
    static func choose(_ videos: [PageVideo], viewport: CGSize) -> PageVideo? {
        videos.filter(follows).max { a, b in
            if a.isMuted != b.isMuted { return a.isMuted }
            let seenA = visibleArea(a.rect, viewport: viewport), seenB = visibleArea(b.rect, viewport: viewport)
            if seenA != seenB { return seenA < seenB }
            return a.rect.width * a.rect.height < b.rect.width * b.rect.height
        }
    }

    /// Where the picture itself is inside its element, by its object-fit: letterboxed by default, filling it with
    /// `cover` or `fill`.
    static func pictureRect(of video: PageVideo) -> CGRect {
        let box = video.rect
        guard video.natural.width > 0, video.natural.height > 0, box.width > 0, box.height > 0,
              video.fit != "cover", video.fit != "fill" else { return box }
        let scale = min(box.width / video.natural.width, box.height / video.natural.height)
        // `scale-down` never enlarges the picture; `none` keeps it at its own size.
        let k = video.fit == "none" ? 1 : video.fit == "scale-down" ? min(scale, 1) : scale
        let size = CGSize(width: video.natural.width * k, height: video.natural.height * k)
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The card for a picture of this shape in a page area this big: a third of its width (no smaller than 240, no
    /// bigger than 480), and never more than half its height.
    static func cardSize(aspect: CGFloat, in area: CGSize) -> CGSize {
        let ratio = min(max(aspect.isFinite && aspect > 0 ? aspect : 16 / 9, aspectRange.lowerBound), aspectRange.upperBound)
        let room = CGSize(width: max(0, area.width - margin * 2), height: max(0, area.height * heightShare))
        var width = min(max(area.width * widthShare, minimumWidth), maximumWidth, room.width)
        var height = width / ratio
        if height > room.height {
            height = room.height
            width = height * ratio
        }
        return CGSize(width: round(width), height: round(height))
    }

    /// What of the page shows in the card: the picture scaled to fill it (any sliver beyond its shape cropped
    /// evenly), as the page area seen at `scale`, from `origin` in the page's points.
    struct Placement: Equatable {
        var scale: CGFloat
        var origin: CGPoint
        /// The part of the page in the card, in the page's points.
        func visible(in card: CGSize) -> CGRect {
            CGRect(origin: origin, size: CGSize(width: card.width / scale, height: card.height / scale))
        }
    }

    static func placement(showing picture: CGRect, in card: CGSize) -> Placement {
        guard picture.width > 0, picture.height > 0, card.width > 0, card.height > 0 else { return Placement(scale: 1, origin: picture.origin) }
        let scale = max(card.width / picture.width, card.height / picture.height)
        let seen = CGSize(width: card.width / scale, height: card.height / scale)
        return Placement(scale: scale, origin: CGPoint(x: picture.midX - seen.width / 2, y: picture.midY - seen.height / 2))
    }

    /// A frame's videos are placed in its own viewport: the frame's place in the page, found by its size (and its
    /// site, when several frames are that size). `frames` are the page's frames as the page lays them out.
    static func frameOrigin(viewport: CGSize, host: String, among frames: [(rect: CGRect, host: String)]) -> CGPoint? {
        let sized = frames.filter { abs($0.rect.width - viewport.width) <= 2 && abs($0.rect.height - viewport.height) <= 2 }
        let match = sized.count > 1 ? sized.first { $0.host == host } ?? sized.first : sized.first
        return match?.rect.origin
    }

    enum Corner: String, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    /// The card in a corner of an area, a margin in (flipped: y runs down).
    static func frame(at corner: Corner, size: CGSize, in area: CGRect) -> CGRect {
        frame(for: Anchor(corner: corner, offset: CGSize(width: margin, height: margin)), size: size, in: area)
    }

    // MARK: Where it sits

    /// It never goes nearer the window's edges than this, so its rounded edge always shows whole.
    static let edgeInset: CGFloat = 4
    /// Let go this near an edge's resting line (`margin` from the window's edge), it settles on it; anywhere else,
    /// it stays where it was let go.
    static let snapDistance: CGFloat = 16

    /// Where the card sits: how far its edges are from the nearest corner's edges. As the window resizes, it keeps
    /// that distance from that corner, so a card at the bottom right stays at the bottom right.
    struct Anchor: Equatable, Sendable {
        var corner: Corner
        var offset: CGSize

        /// As saved: "bottomRight 8 8".
        var stored: String { "\(corner.rawValue) \(Double(offset.width)) \(Double(offset.height))" }
        init(corner: Corner, offset: CGSize) {
            self.corner = corner
            self.offset = offset
        }
        init?(stored: String) {
            let parts = stored.split(separator: " ")
            guard parts.count == 3, let corner = Corner(rawValue: String(parts[0])), let x = Double(parts[1]), let y = Double(parts[2]),
                  x.isFinite, y.isFinite else { return nil }
            self.init(corner: corner, offset: CGSize(width: max(0, x), height: max(0, y)))
        }
    }

    /// The anchor of a card at `frame`: from the corner of `area` nearest its middle.
    static func anchor(of frame: CGRect, in area: CGRect) -> Anchor {
        let corner = nearestCorner(to: CGPoint(x: frame.midX, y: frame.midY), in: area)
        let x = corner.isLeft ? frame.minX - area.minX : area.maxX - frame.maxX
        let y = corner.isTop ? frame.minY - area.minY : area.maxY - frame.maxY
        return Anchor(corner: corner, offset: CGSize(width: max(0, x), height: max(0, y)))
    }

    /// The card of this size at its anchor in `area`, kept wholly inside it.
    static func frame(for anchor: Anchor, size: CGSize, in area: CGRect) -> CGRect {
        let x = anchor.corner.isLeft ? area.minX + anchor.offset.width : area.maxX - anchor.offset.width - size.width
        let y = anchor.corner.isTop ? area.minY + anchor.offset.height : area.maxY - anchor.offset.height - size.height
        return clamp(CGRect(x: x, y: y, width: size.width, height: size.height), in: area)
    }

    /// Moved back inside `area` where it pokes out; a card bigger than the area keeps to its top left.
    static func clamp(_ frame: CGRect, in area: CGRect) -> CGRect {
        let x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width))
        let y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height))
        return CGRect(x: round(x), y: round(y), width: frame.width, height: frame.height)
    }

    /// Where a card let go at `frame` comes to rest: where it is, inside `area`, except near an edge, where it settles
    /// on the line a margin in from the window's edge (two edges, at a corner).
    static func dropped(_ frame: CGRect, in area: CGRect) -> CGRect {
        var f = clamp(frame, in: area)
        let inset = max(0, margin - edgeInset)
        let rest = area.insetBy(dx: inset, dy: inset)
        if f.minX - rest.minX <= snapDistance { f.origin.x = rest.minX }
        else if rest.maxX - f.maxX <= snapDistance { f.origin.x = rest.maxX - f.width }
        if f.minY - rest.minY <= snapDistance { f.origin.y = rest.minY }
        else if rest.maxY - f.maxY <= snapDistance { f.origin.y = rest.maxY - f.height }
        return clamp(f, in: area)
    }

    /// Where the card may go in a window this big: anywhere in it, an `edgeInset` in, over the sidebar too; under the
    /// bar above the page when there is one (`below`, its bottom), so it never covers the address or its buttons.
    static func movableArea(in bounds: CGRect, below bar: CGFloat?) -> CGRect {
        var area = bounds.insetBy(dx: edgeInset, dy: edgeInset)
        if let bar, bar + edgeInset > area.minY {
            area.size.height = max(0, area.maxY - bar - edgeInset)
            area.origin.y = bar + edgeInset
        }
        return area
    }

    /// The corner nearest a point.
    static func nearestCorner(to point: CGPoint, in area: CGRect) -> Corner {
        let left = point.x < area.midX, top = point.y < area.midY
        switch (left, top) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}

/// Which tab is in the mini player, and what happens to it as you move between tabs. One per window: steps come out
/// in the order they're to be done.
nonisolated struct MiniPlayerModel: Equatable {
    enum Step: Equatable {
        /// The tab's video goes into the mini player.
        case show(UUID)
        /// Its video stops.
        case pause(UUID)
        /// The mini player lets it go: back into its page, or simply away.
        case end(UUID)
        /// The card goes and the video plays on, out of sight, until you go to its tab.
        case hide(UUID)
    }

    private(set) var tab: UUID?

    /// Tabs changed on screen. `shown`: the tabs on screen now (two in a split). `playing`: a tab that was on screen,
    /// isn't now, and is playing a video that would follow you. Coming back to the mini player's tab puts its video
    /// back in the page, still playing; leaving another playing tab takes its place, and the one it replaces stops,
    /// so only one plays.
    mutating func switched(shown: Set<UUID>, playing: UUID?) -> [Step] {
        var steps: [Step] = []
        if let tab, shown.contains(tab) {
            steps.append(.end(tab))
            self.tab = nil
        }
        if let playing, playing != tab, !shown.contains(playing) {
            if let tab { steps += [.pause(tab), .end(tab)] }
            tab = playing
            steps.append(.show(playing))
        }
        return steps
    }

    /// Its minimize button: the card goes and the video plays on in its tab, out of sight. It comes back only the
    /// next time you leave that tab while it plays: never by itself while you're on other tabs, which would undo
    /// the minimize. The sidebar's now-playing row is the way back to it.
    mutating func minimize() -> [Step] {
        guard let tab else { return [] }
        self.tab = nil
        return [.hide(tab)]
    }

    /// Its close button: the video stops and the player goes.
    mutating func close() -> [Step] {
        guard let tab else { return [] }
        self.tab = nil
        return [.pause(tab), .end(tab)]
    }

    /// The tab closed, slept, left the window, or its page no longer has a video (or floats it itself): the player
    /// goes, with nothing left to stop.
    mutating func lost(_ id: UUID) -> [Step] {
        guard tab == id else { return [] }
        tab = nil
        return [.end(id)]
    }
}
