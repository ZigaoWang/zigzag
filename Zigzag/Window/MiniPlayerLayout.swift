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
    /// You started it, or changed its sound, yourself: a press or a key on the page just before (not on a link).
    var isStartedByUser = false
    /// It sits in a link: a card's preview of a page it goes to.
    var isInLink = false
    /// Its CSS object-fit.
    var fit = "contain"
    var time: Double = 0
    /// Nil for a live stream, or before the page knows.
    var duration: Double?

    init(index: Int, rect: CGRect, natural: CGSize, isPlaying: Bool, hasEnded: Bool = false, isMuted: Bool = false, loops: Bool = false,
         autoplays: Bool = false, hasControls: Bool = false, isStartedByUser: Bool = false, isInLink: Bool = false, fit: String = "contain",
         time: Double = 0, duration: Double? = nil) {
        self.index = index
        self.rect = rect
        self.natural = natural
        self.isPlaying = isPlaying
        self.hasEnded = hasEnded
        self.isMuted = isMuted
        self.loops = loops
        self.autoplays = autoplays
        self.hasControls = hasControls
        self.isStartedByUser = isStartedByUser
        self.isInLink = isInLink
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
                  isStartedByUser: flag("user"), isInLink: flag("link"), fit: o["fit"] as? String ?? "contain", time: number("t"), duration: duration > 0 ? duration : nil)
    }

    /// Something you were watching, not a page's own motion: one you started or turned up yourself, or one you can
    /// hear that isn't a link's preview. A muted autoplay, a page's moving background, and the preview a card plays
    /// as the pointer passes over it are not.
    var isWatched: Bool { isStartedByUser || (!isMuted && !isInLink) }
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

    /// How long a page kept in the window out of sight (`keepsInWindow`, or minimized) stays there once nothing in it
    /// plays: long enough for a playlist to load and start its next song. WebKit won't load or start the next one in
    /// a page that's out of the window, so letting go of it between two songs leaves the player stuck.
    static let nextItemWait: TimeInterval = 30

    /// Whether a page you're leaving stays in the window, out of sight, rather than out of it: one playing sound,
    /// unless the mini player takes it (`followed`) or it fills the screen with its video.
    static func keepsInWindow(playingSound: Bool, followed: Bool, inFullScreen: Bool) -> Bool {
        playingSound && !followed && !inFullScreen
    }

    /// Whether it's playing a picture big enough to be the thing on the page.
    static func plays(_ video: PageVideo) -> Bool {
        video.isPlaying && !video.hasEnded && video.natural.width > 0 && video.natural.height > 0
            && video.rect.width >= smallestVideo.width && video.rect.height >= smallestVideo.height
    }

    /// Whether it would follow you out of its tab: playing, big enough, and one you were watching.
    static func follows(_ video: PageVideo) -> Bool {
        plays(video) && video.isWatched
    }

    /// The video leaving a tab takes along, and the index of its frame among `frames` (each frame's viewport and
    /// videos): none while the page is on its way out (`leavingPage`, a link followed: what's still playing is the
    /// page you're done with), or floats or fills the screen with a video itself.
    static func followed(in frames: [(viewport: CGSize, videos: [PageVideo])], leavingPage: Bool, presentingItself: Bool) -> (frame: Int, video: PageVideo)? {
        guard !leavingPage, !presentingItself else { return nil }
        return best(in: frames, by: follows)
    }

    /// Across frames, by `choose`: each frame's best by its own viewport, then the best of those.
    static func best(in frames: [(viewport: CGSize, videos: [PageVideo])], by rule: (PageVideo) -> Bool) -> (frame: Int, video: PageVideo)? {
        let found = frames.indices.compactMap { i in choose(frames[i].videos, viewport: frames[i].viewport, by: rule).map { (frame: i, video: $0) } }
        let everything = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        guard let winner = choose(found.map(\.video), viewport: everything, by: rule) else { return nil }
        return found.first { $0.video == winner }
    }

    /// How much of `rect` is inside the viewport.
    static func visibleArea(_ rect: CGRect, viewport: CGSize) -> CGFloat {
        let seen = rect.intersection(CGRect(origin: .zero, size: viewport))
        return seen.isNull ? 0 : seen.width * seen.height
    }

    /// The one to follow you: of those that would, one you can hear before a silent one, then the one that shows the
    /// most, then the biggest.
    static func choose(_ videos: [PageVideo], viewport: CGSize, by rule: (PageVideo) -> Bool = follows) -> PageVideo? {
        videos.filter(rule).max { a, b in
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
        let ratio = clampedAspect(aspect)
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

    /// Where the card first goes, before it's ever moved: the page area's bottom corner away from the sidebar, the
    /// bottom right as the Mac's Picture in Picture has it, or the bottom left beside a sidebar on the right.
    static func firstCorner(sidebarOnRight: Bool) -> Corner { sidebarOnRight ? .bottomLeft : .bottomRight }

    /// Where on the card it comes out of when it shows up with no video's place to grow from: the corner of it
    /// nearest the corner of `area` it sits in (0 to 1 from its top left, y running down as `frame`'s does).
    static func growPoint(of frame: NSRect, in area: NSRect) -> CGPoint {
        CGPoint(x: frame.midX < area.midX ? 0 : 1, y: frame.midY < area.midY ? 0 : 1)
    }

    /// The card in a corner of an area, a margin in (flipped: y runs down).
    static func frame(at corner: Corner, size: CGSize, in area: CGRect) -> CGRect {
        frame(for: Anchor(corner: corner, offset: CGSize(width: margin, height: margin)), size: size, in: area)
    }

    // MARK: Where it sits

    /// It never goes nearer the screen's edges than this, so its rounded edge always shows whole.
    static let edgeInset: CGFloat = 4

    /// Where the card sits: how far its edges are from the nearest corner's edges. As its room changes, it keeps
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
    /// on the line a margin in from the screen's edge (two edges, at a corner).
    static func dropped(_ frame: CGRect, in area: CGRect) -> CGRect {
        // Exactly where it was let go, only kept on screen: it never jumps to an edge or a corner on its own.
        clamp(frame, in: area)
    }

    /// Where the card may go on a screen (#172): anywhere in its usable part (`visible`: clear of the menu bar and
    /// the Dock), an `edgeInset` in, over the window and other apps' windows too.
    static func movableArea(onScreen visible: CGRect) -> CGRect {
        visible.insetBy(dx: edgeInset, dy: edgeInset)
    }

    // MARK: Snapping to a corner

    /// Where the card rests (#172): in a corner of the page area of its window, a margin in, as #156 had it; in a
    /// corner of the screen, as the Mac's own Picture in Picture does, once let go outside the window; or, let go
    /// with ⌘ held, wherever it was let go (`Anchor`, from the screen's nearest corner).
    enum Place: Equatable, Sendable {
        case corner(Corner)
        case screen(Corner)
        case free(Anchor)

        /// As saved: "bottomRight" for a page's corner, "screen bottomRight" for the screen's, "bottomRight 8 8" for a
        /// free place (as every place was saved before the card snapped, so those keep where they were).
        var stored: String {
            switch self {
            case .corner(let corner): corner.rawValue
            case .screen(let corner): "screen " + corner.rawValue
            case .free(let anchor): anchor.stored
            }
        }
        init?(stored: String) {
            if let corner = Corner(rawValue: stored) { self = .corner(corner) }
            else if stored.hasPrefix("screen "), let corner = Corner(rawValue: String(stored.dropFirst(7))) { self = .screen(corner) }
            else if let anchor = Anchor(stored: stored) { self = .free(anchor) }
            else { return nil }
        }
    }

    /// The card of this size at its place: in its corner of `page` (the page area), in its corner of the screen
    /// whose room is `area` (where it may go at all, `edgeInset` in from the screen's usable part), or at its anchor
    /// in `area`; and wholly inside `area` either way.
    static func frame(for place: Place, size: CGSize, page: CGRect, in area: CGRect) -> CGRect {
        switch place {
        case .corner(let corner): clamp(frame(at: corner, size: size, in: page), in: area)
        case .screen(let corner): clamp(frame(at: corner, size: size, in: area.insetBy(dx: -edgeInset, dy: -edgeInset)), in: area)
        case .free(let anchor): frame(for: anchor, size: size, in: area)
        }
    }

    /// Where a card let go at `frame` comes to rest, and its place from then on. Over its window (`window`, the
    /// page and the sidebar both), in the page area's corner nearest its middle; anywhere else on the screen, the
    /// screen's nearest corner; with `free` (⌘ held), where it was let go, settling on an edge only near one
    /// (`dropped`).
    static func rest(_ frame: CGRect, free: Bool, page: CGRect, window: CGRect?, in area: CGRect) -> (frame: CGRect, place: Place) {
        if free {
            let target = dropped(frame, in: area)
            return (target, .free(anchor(of: target, in: area)))
        }
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        let place: Place = window?.contains(middle) == true ? .corner(nearestCorner(to: middle, in: page)) : .screen(nearestCorner(to: middle, in: area))
        return (self.frame(for: place, size: frame.size, page: page, in: area), place)
    }

    /// A rectangle in the Mac's screen coordinates (y up from the bottom of the main screen) in the same space with y
    /// running down from its top, as the card's arithmetic is done, or back: the same flip either way.
    static func flipped(_ rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Resizing

    /// The smallest card: room for its controls.
    static let smallestCard = CGSize(width: 200, height: 112)
    /// The largest: this much of the screen either way.
    static let largestShare: CGFloat = 0.8

    /// The widths a card of this shape may take in an area this big (where it may go).
    static func widthRange(aspect: CGFloat, in area: CGSize) -> ClosedRange<CGFloat> {
        let ratio = clampedAspect(aspect)
        let lowest = max(smallestCard.width, smallestCard.height * ratio)
        let highest = max(0, floor(min(area.width * largestShare, area.height * largestShare * ratio)))
        return min(lowest, highest)...highest
    }

    /// The card you sized yourself: its longer side `extent` long, for a video of any shape, within `widthRange`.
    static func cardSize(aspect: CGFloat, extent: CGFloat, in area: CGSize) -> CGSize {
        let ratio = clampedAspect(aspect)
        let wanted = ratio >= 1 ? extent : extent * ratio
        let range = widthRange(aspect: ratio, in: area)
        let width = round(min(max(wanted, range.lowerBound), range.upperBound))
        return CGSize(width: width, height: round(width / ratio))
    }

    static func clampedAspect(_ aspect: CGFloat) -> CGFloat {
        min(max(aspect.isFinite && aspect > 0 ? aspect : 16 / 9, aspectRange.lowerBound), aspectRange.upperBound)
    }

    /// The edges a press on the card takes hold of, to resize it by: within `grip` of an edge, two edges within
    /// `corner` of a corner. `point` is in the card's own points, y running down.
    struct Edges: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    static let grip: CGFloat = 8
    static let cornerGrip: CGFloat = 18

    static func edges(at point: CGPoint, in size: CGSize) -> Edges {
        guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return [] }
        func near(_ reach: CGFloat) -> Edges {
            var edges: Edges = []
            if point.x < reach { edges.insert(.left) } else if point.x > size.width - reach { edges.insert(.right) }
            if point.y < reach { edges.insert(.top) } else if point.y > size.height - reach { edges.insert(.bottom) }
            return edges
        }
        let corner = near(cornerGrip)
        if corner.intersection([.left, .right]).isEmpty == false, corner.intersection([.top, .bottom]).isEmpty == false { return corner }
        return near(grip)
    }

    /// The card pressed at `frame`, its `edges` dragged `by` this much: the same shape, the opposite edge (or corner)
    /// staying put, within `widthRange` and inside `area`. Dragging one edge, the side across it that stays is the one
    /// nearer the area's edge, so a card in a corner stays in it.
    static func resized(_ frame: CGRect, from edges: Edges, by delta: CGSize, in area: CGRect) -> CGRect {
        guard !edges.isEmpty, frame.width > 0, frame.height > 0 else { return frame }
        let ratio = frame.width / frame.height
        let horizontal = !edges.intersection([.left, .right]).isEmpty, vertical = !edges.intersection([.top, .bottom]).isEmpty
        let byX = edges.contains(.left) ? frame.width - delta.width : frame.width + delta.width
        let byY = (edges.contains(.top) ? frame.height - delta.height : frame.height + delta.height) * ratio
        var width = horizontal && vertical ? max(byX, byY) : horizontal ? byX : byY
        // Which side stays put, either way.
        let keepsRight = edges.contains(.left) || (!horizontal && frame.midX > area.midX)
        let keepsBottom = edges.contains(.top) || (!vertical && frame.midY > area.midY)
        let fixed = CGPoint(x: keepsRight ? frame.maxX : frame.minX, y: keepsBottom ? frame.maxY : frame.minY)
        let roomX = keepsRight ? fixed.x - area.minX : area.maxX - fixed.x
        let roomY = (keepsBottom ? fixed.y - area.minY : area.maxY - fixed.y) * ratio
        let range = widthRange(aspect: ratio, in: area.size)
        width = min(max(width, range.lowerBound), range.upperBound, max(range.lowerBound, min(roomX, roomY)))
        width = round(width)
        let height = round(width / ratio)
        let rect = CGRect(x: keepsRight ? fixed.x - width : fixed.x, y: keepsBottom ? fixed.y - height : fixed.y, width: width, height: height)
        return clamp(rect, in: area)
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
