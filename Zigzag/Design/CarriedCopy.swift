import AppKit

/// What follows the pointer while a row or tile is dragged, the same in the sidebar's list, the favorites grid and
/// Settings: the item itself stays in its place, faint, and this see-through copy of it is carried, turning solid as it
/// lands on its new place. A copy can have a second shape it turns into over somewhere else (a favorite over the tab
/// list becomes the row it would be there).
@MainActor
final class CarriedCopy {
    /// How solid the copy is while carried: enough to read, light enough to see the line or row under it.
    static let opacity: CGFloat = 0.7
    /// How faint the item stays in its place meanwhile.
    static let faint: CGFloat = 0.35

    private let panel: NSPanel
    private let card = NSView()
    private let picture = NSImageView()
    private let alternate: NSView?
    private let size: NSSize, grab: NSPoint
    private let alternateSize: NSSize, alternateGrab: NSPoint
    private let radius: CGFloat, alternateRadius: CGFloat
    /// The panel fits either shape with room for the shadow; the pointer stays at this spot in it.
    private let anchor: NSPoint
    private static let margin: CGFloat = 20

    /// A copy of `view`, held where the pointer pressed it (a point on screen). `ground`: drawn under the picture, for
    /// rows that are see-through on the sidebar. `alternate`: the second shape, the pointer holding it at `grab`.
    convenience init(of view: NSView, picture image: NSImage?, grabbedAt screenPoint: NSPoint, ground: NSColor?, radius: CGFloat,
                     alternate: (view: NSView, size: NSSize, grab: NSPoint, radius: CGFloat)? = nil) {
        let rect = view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
        self.init(picture: image, size: rect.size, grab: NSPoint(x: screenPoint.x - rect.minX, y: screenPoint.y - rect.minY),
                  at: screenPoint, appearance: view.effectiveAppearance, ground: ground, radius: radius, alternate: alternate)
    }

    /// A copy of something not shown at this size (a pane's page, small): `image` at `size`, the pointer holding it at
    /// `grab` (from its bottom-left corner), now at `screenPoint`.
    init(picture image: NSImage?, size: NSSize, grab: NSPoint, at screenPoint: NSPoint, appearance: NSAppearance, ground: NSColor?,
         radius: CGFloat, alternate: (view: NSView, size: NSSize, grab: NSPoint, radius: CGFloat)? = nil) {
        self.size = size
        self.grab = grab
        self.alternate = alternate?.view
        alternateSize = alternate?.size ?? size
        alternateGrab = alternate?.grab ?? grab
        self.radius = radius
        alternateRadius = alternate?.radius ?? radius
        let m = Self.margin
        anchor = NSPoint(x: m + max(grab.x, alternateGrab.x), y: m + max(grab.y, alternateGrab.y))
        let width = anchor.x + max(size.width - grab.x, alternateSize.width - alternateGrab.x) + m
        let height = anchor.y + max(size.height - grab.y, alternateSize.height - alternateGrab.y) + m
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.appearance = appearance
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        panel.contentView = content

        card.wantsLayer = true
        card.layer?.cornerRadius = radius
        card.layer?.cornerCurve = .continuous
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.18
        card.layer?.shadowRadius = 8
        card.layer?.shadowOffset = CGSize(width: 0, height: -3)
        var fill: CGColor?
        appearance.performAsCurrentDrawingAppearance { fill = ground?.cgColor }
        card.layer?.backgroundColor = fill
        content.addSubview(card)
        picture.image = image
        picture.imageScaling = .scaleNone
        picture.autoresizingMask = [.width, .height]
        if let alternate = alternate?.view {
            alternate.autoresizingMask = [.width, .height]
            alternate.alphaValue = 0
            card.addSubview(alternate)
        }
        card.addSubview(picture)
        card.frame = frame(alternate: false)
        picture.frame = card.bounds
        alternate?.view.frame = card.bounds
        updateShadow()
        follow(screenPoint)
    }

    /// A newer picture of the same thing, clipped to the copy's corners (a page's, taken once the drag began).
    func show(picture image: NSImage?) {
        picture.wantsLayer = true
        picture.layer?.cornerRadius = radius
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.image = image
    }

    /// The item as it looks, from its layers.
    static func picture(of view: NSView) -> NSImage? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        // Layers draw flipped against the bitmap.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        layer.render(in: cg)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Follows the pointer through a drag in `window` until it's let go, calling `moved` for every step and for the
    /// release. Returns the release, or nil when Esc called the drag off.
    static func track(in window: NSWindow, _ moved: (NSEvent) -> Void) -> NSEvent? {
        var result: NSEvent?
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            switch event.type {
            case .keyDown:
                // Esc: nothing changes. Other keys wait.
                guard event.keyCode == 53 else { return }
                stop.pointee = true
            case .leftMouseUp:
                moved(event)
                result = event
                stop.pointee = true
            default:
                moved(event)
            }
        }
        return result
    }

    private func frame(alternate: Bool) -> NSRect {
        let size = alternate ? alternateSize : self.size, grab = alternate ? alternateGrab : self.grab
        return NSRect(x: anchor.x - grab.x, y: anchor.y - grab.y, width: size.width, height: size.height)
    }

    /// Picked up: it comes off the item and turns see-through.
    func lift() {
        // Picked up by a move already past the press: it starts under the pointer there, not where the press was, so
        // it never jumps to catch up on the next move.
        if let event = NSApp.currentEvent, event.type == .leftMouseDragged, let window = event.window {
            follow(window.convertPoint(toScreen: event.locationInWindow))
        }
        panel.alphaValue = 1
        panel.orderFront(nil)
        Tokens.Motion.animate(Tokens.Motion.feedback) { self.panel.animator().alphaValue = Self.opacity }
    }

    /// Keeps the pointer where it holds the copy.
    func follow(_ screenPoint: NSPoint) {
        panel.setFrameOrigin(NSPoint(x: screenPoint.x - anchor.x, y: screenPoint.y - anchor.y))
    }

    /// Shows the second shape (true) or the item's own.
    var showsAlternate = false {
        didSet {
            guard showsAlternate != oldValue, let alternate else { return }
            let target = frame(alternate: showsAlternate)
            Tokens.Motion.animate(Tokens.Motion.change, moves: true) {
                self.card.animator().frame = target
                alternate.animator().alphaValue = self.showsAlternate ? 1 : 0
                self.picture.animator().alphaValue = self.showsAlternate ? 0 : 1
                self.card.layer?.cornerRadius = self.showsAlternate ? self.alternateRadius : self.radius
            }
            updateShadow(for: target)
        }
    }

    private func updateShadow(for frame: NSRect? = nil) {
        let size = (frame ?? card.frame).size
        let radius = showsAlternate ? alternateRadius : self.radius
        card.layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Lets go: glides onto `view` (the item in its new place), turning solid as it lands, while the view waits
    /// unseen under it. Without a view on screen to land on (it went to another space, window or kind of place), it
    /// fades where it is.
    func land(on view: NSView?, completion: (@MainActor () -> Void)? = nil) {
        let panel = self.panel
        guard let view, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else {
            Tokens.Motion.animate(Tokens.Motion.feedback, { panel.animator().alphaValue = 0 }, completion: {
                panel.orderOut(nil)
                completion?()
            })
            return
        }
        // Whatever the drop changed (a favorite's new row, a row's new place) settles first, so it flies to where the
        // item really ends up instead of to where it was a moment before and then dropping with the layout.
        window.contentView?.layoutSubtreeIfNeeded()
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let card = card.frame
        let target = NSRect(x: rect.minX - card.minX, y: rect.minY - card.minY, width: panel.frame.width, height: panel.frame.height)
        view.alphaValue = 0
        Tokens.Motion.animate(Tokens.Motion.snappy, moves: true, {
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }, completion: {
            // Only if nothing else has set it since: picked up again mid-landing, the row stays faint for that drag.
            if view.alphaValue == 0 { view.alphaValue = 1 }
            panel.orderOut(nil)
            completion?()
        })
    }
}
