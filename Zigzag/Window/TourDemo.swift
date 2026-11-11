import AppKit

/// The getting-started guide showing a step in the window itself, on your real tabs and buttons: a cursor that clicks
/// or drags, or fingertips that swipe, over and over until you do it. While you hold the mouse down it gets
/// out of the way, so it never mixes with what you're doing.
@MainActor
final class TourDemo {
    enum Gesture: Equatable {
        /// Picks up `row` and carries a copy of it onto `drop`, which lights up as a real drop target does.
        case drag(row: NSView, from: CGPoint, drop: NSRect)
        /// Clicks at a point, with a key held (shown beside the pointer) or none.
        case click(at: CGPoint, holding: String?)
        /// Two fingertips across a stretch of the sidebar, toward the right or the left.
        case swipe(across: NSRect, toRight: Bool)

        static func == (a: Gesture, b: Gesture) -> Bool { a.key == b.key }

        /// Equal when it would draw the same, so asking again for what's showing doesn't restart it.
        var key: String {
            switch self {
            case .drag(let row, let from, let drop):
                return "drag \(ObjectIdentifier(row)) \((row as? TabRowView)?.title.stringValue ?? "") \(from) \(drop)"
            case .click(let at, let holding): return "click \(at) \(holding ?? "")"
            case .swipe(let across, let toRight): return "swipe \(across) \(toRight)"
            }
        }
    }

    private let host: CALayer
    private let stage = CALayer()
    private let target = CALayer()
    private var shown: String?
    private var monitor: Any?
    private let cycle: CFTimeInterval = 3.2

    init(in host: CALayer) {
        self.host = host
        host.addSublayer(target)
        host.addSublayer(stage)
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Shows `gesture` in `view`'s coordinates, or nothing.
    func show(_ gesture: Gesture?, in view: NSView) {
        guard let gesture, !Tokens.Motion.reduceMotion else { clear(); return }
        guard gesture.key != shown else { return }
        clear()
        shown = gesture.key
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let held = event.type == .leftMouseDown
            Tokens.Motion.withoutAnimation {
                self?.stage.isHidden = held
                self?.target.isHidden = held
            }
            return event
        }
        Tokens.Motion.withoutAnimation {
            stage.frame = host.bounds
            target.opacity = 0
        }
        switch gesture {
        case .drag(let row, let from, let drop): drag(row, from: from, drop: drop, in: view)
        case .click(let at, let holding): click(at: at, holding: holding, in: view)
        case .swipe(let across, let toRight): swipe(across: across, toRight: toRight)
        }
    }

    func clear() {
        shown = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        stage.sublayers?.forEach { $0.removeFromSuperlayer() }
        target.removeAllAnimations()
        Tokens.Motion.withoutAnimation {
            stage.isHidden = false
            target.isHidden = false
            target.opacity = 0
        }
    }

    // MARK: Gestures

    /// Arrive and press, carry it across, let go, fade.
    /// Where the lifted tab comes to rest: its grab point over the middle of where it drops, but the whole tab kept
    /// inside the window, so in a narrow one it never runs past the edge.
    static func dragEnd(drop: NSRect, grab: CGPoint, size: NSSize, within bounds: NSRect) -> CGPoint {
        let inset = Tokens.Space.x2
        var x = drop.midX - grab.x
        x = min(max(x, bounds.minX + inset), bounds.maxX - inset - size.width)
        var y = drop.minY + drop.height * 0.35
        y = min(max(y, bounds.minY + inset), bounds.maxY - inset - size.height)
        return CGPoint(x: x, y: y)
    }

    private func drag(_ row: NSView, from start: CGPoint, drop: NSRect, in view: NSView) {
        let grab = CGPoint(x: Tokens.Sidebar.favicon * 2.5, y: row.bounds.height / 2)
        // The tab as it looks lifted to drag. The card is see-through over the sidebar's color, and would all but
        // vanish over a white page, so it carries that color under it, solid, in the sidebar's own look.
        let lifted = CALayer()
        lifted.frame = CGRect(origin: .zero, size: row.bounds.size)
        lifted.cornerRadius = Tokens.Sidebar.rowRadius
        lifted.cornerCurve = .continuous
        lifted.backgroundColor = row.cgColor(row.window?.backgroundColor ?? .windowBackgroundColor)
        if let tint = (row.window?.windowController as? BrowserWindowController)?.root.sidebarContainer.tint {
            lifted.backgroundColor = row.cgColor(tint)
        }
        lifted.shadowOpacity = 0.3
        lifted.shadowRadius = 10
        lifted.shadowOffset = CGSize(width: 0, height: 4)
        let card = CALayer()
        card.frame = lifted.bounds
        if let image = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
            row.cacheDisplay(in: row.bounds, to: image)
            card.contents = image.cgImage
        }
        card.contentsGravity = .resize
        card.backgroundColor = row.cgColor(Tokens.Chrome.card)
        card.cornerRadius = lifted.cornerRadius
        card.cornerCurve = .continuous
        card.borderWidth = Tokens.Metric.hairline
        card.borderColor = row.cgColor(Tokens.Chrome.cardEdge)
        lifted.addSublayer(card)
        let pointer = cursor(at: grab, in: view)
        let group = CALayer()
        group.anchorPoint = .zero
        group.bounds = lifted.bounds
        group.addSublayer(lifted)
        group.addSublayer(pointer)
        stage.addSublayer(group)

        let accent = Brand.Theme.for(row).accent
        Tokens.Motion.withoutAnimation {
            target.frame = drop
            target.cornerRadius = Tokens.Radius.large
            target.cornerCurve = .continuous
            target.backgroundColor = row.cgColor(accent.withAlphaComponent(Tokens.Color.dropAlpha))
            target.borderWidth = Tokens.Metric.dropEdge
            target.borderColor = row.cgColor(accent.withAlphaComponent(Tokens.Color.dropEdgeAlpha))
        }
        let end = Self.dragEnd(drop: drop, grab: grab, size: row.bounds.size, within: view.bounds)
        let times: [NSNumber] = [0, 0.12, 0.22, 0.62, 0.76, 0.86, 1]
        run([
            (group, keyframes("position", [start, start, start, end, end, end, end].map { NSValue(point: $0) }, times, eased: true)),
            (group, keyframes("opacity", [0, 1, 1, 1, 1, 0, 0], times)),
            (lifted, keyframes("opacity", [0, 0, 0.95, 0.95, 0.95, 0, 0], times)),
            (pointer, keyframes("transform.scale", [1, 1, 0.85, 0.85, 1, 1, 1], times)),
            (target, keyframes("opacity", [0, 0, 0, 0.6, 1, 0, 0], times)),
        ])
    }

    /// Glide in, press (with the key held, if any), a ripple where it clicked, fade.
    private func click(at point: CGPoint, holding key: String?, in view: NSView) {
        let pointer = cursor(at: .zero, in: view)
        let group = CALayer()
        group.anchorPoint = .zero
        group.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        group.addSublayer(pointer)
        if let key {
            // The key, held: a small cap just past the pointer, in the guide's dark.
            let label = CATextLayer()
            label.string = key
            label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            label.fontSize = 13
            label.alignmentMode = .center
            label.foregroundColor = .white
            label.contentsScale = view.window?.backingScaleFactor ?? 2
            let cap = CALayer()
            cap.frame = CGRect(x: 16, y: 18, width: 24, height: 22)
            cap.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
            cap.cornerRadius = Tokens.Radius.control
            cap.cornerCurve = .continuous
            label.frame = CGRect(x: 0, y: 3, width: 24, height: 18)
            cap.addSublayer(label)
            group.addSublayer(cap)
        }
        stage.addSublayer(group)
        let ripple = CALayer()
        let side: CGFloat = 36
        ripple.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ripple.position = point
        ripple.cornerRadius = side / 2
        ripple.borderWidth = 2
        ripple.borderColor = view.cgColor(Brand.Theme.for(view).accent)
        ripple.opacity = 0
        stage.addSublayer(ripple)

        let from = CGPoint(x: point.x + 70, y: point.y + 50)
        let times: [NSNumber] = [0, 0.1, 0.45, 0.55, 0.62, 0.85, 1]
        run([
            (group, keyframes("position", [from, from, point, point, point, point, point].map { NSValue(point: $0) }, times, eased: true)),
            (group, keyframes("opacity", [0, 1, 1, 1, 1, 0, 0], times)),
            (pointer, keyframes("transform.scale", [1, 1, 1, 0.85, 1, 1, 1], times)),
            (ripple, keyframes("opacity", [0, 0, 0, 0.9, 0.6, 0, 0], times)),
            (ripple, keyframes("transform.scale", [0.3, 0.3, 0.3, 0.4, 0.8, 1.2, 1.2], times)),
        ])
    }

    /// Two fingertips side by side, sliding across together.
    private func swipe(across area: NSRect, toRight: Bool) {
        let y = area.midY
        let left = area.minX + area.width * 0.2, right = area.maxX - area.width * 0.2
        let (from, to) = toRight ? (left, right) : (right, left)
        let times: [NSNumber] = [0, 0.12, 0.62, 0.78, 1]
        for offset in [-Self.fingerGap / 2, Self.fingerGap / 2] {
            let tip = fingertip()
            stage.addSublayer(tip)
            let a = CGPoint(x: from + offset, y: y), b = CGPoint(x: to + offset, y: y)
            run([
                (tip, keyframes("position", [a, a, b, b, b].map { NSValue(point: $0) }, times, eased: true)),
                (tip, keyframes("opacity", [0, 1, 1, 0, 0], times)),
            ])
        }
    }

    // MARK: Pieces

    private static let fingerGap: CGFloat = 34

    /// The system's own arrow, its tip at `tip` in its parent.
    private func cursor(at tip: CGPoint, in view: NSView) -> CALayer {
        let image = NSCursor.arrow.image
        let layer = CALayer()
        layer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer.contentsScale = view.window?.backingScaleFactor ?? 2
        let hot = NSCursor.arrow.hotSpot
        layer.frame = CGRect(x: tip.x - hot.x, y: tip.y - hot.y, width: image.size.width, height: image.size.height)
        // Pressed, it shrinks toward its tip, as a finger presses the pad.
        layer.anchorPoint = CGPoint(x: hot.x / image.size.width, y: hot.y / image.size.height)
        layer.position = tip
        return layer
    }

    /// A fingertip on the trackpad: a dark disc with a light rim, so it shows on a white page and a dark sidebar alike.
    private func fingertip() -> CALayer {
        let side: CGFloat = 28
        let tip = CALayer()
        tip.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        tip.cornerRadius = side / 2
        tip.backgroundColor = NSColor(white: 0.15, alpha: 0.6).cgColor
        tip.borderWidth = 2
        tip.borderColor = NSColor(white: 1, alpha: 0.9).cgColor
        tip.shadowOpacity = 0.35
        tip.shadowRadius = 6
        tip.shadowOffset = CGSize(width: 0, height: 2)
        tip.opacity = 0
        return tip
    }

    private func keyframes(_ path: String, _ values: [Any], _ times: [NSNumber], eased: Bool = false) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: path)
        animation.values = values
        animation.keyTimes = times
        if eased { animation.timingFunctions = (1..<times.count).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) } }
        return animation
    }

    /// All in step, on a loop that runs until the guide moves on.
    private func run(_ animations: [(CALayer, CAKeyframeAnimation)]) {
        let start = CACurrentMediaTime() + 0.4
        for (layer, animation) in animations {
            animation.duration = cycle
            animation.repeatCount = .infinity
            animation.beginTime = start
            animation.fillMode = .both
            layer.add(animation, forKey: animation.keyPath)
        }
        Tokens.Motion.withoutAnimation {
            for (layer, animation) in animations where animation.keyPath == "opacity" && layer !== target { layer.opacity = 0 }
        }
    }
}
