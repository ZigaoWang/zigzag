import AppKit

/// The copy of a row that follows the pointer while it's carried, see-through so what's under it shows, and that
/// settles onto the row's new place when it's let go. The row itself stays where it was, faint, until then.
@MainActor
final class DragGhost {
    private let panel: NSPanel
    /// Where the pointer holds the copy, from its bottom-left corner.
    private let grab: NSPoint

    init?(of view: NSView, event: NSEvent) {
        guard let window = view.window, let layer = view.layer else { return nil }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let start = window.convertPoint(toScreen: event.locationInWindow)
        grab = NSPoint(x: start.x - rect.minX, y: start.y - rect.minY)
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.appearance = window.effectiveAppearance
        let picture = NSImageView(frame: NSRect(origin: .zero, size: rect.size))
        picture.image = Self.picture(of: layer, size: view.bounds.size, scale: window.backingScaleFactor)
        panel.contentView = picture
        panel.alphaValue = SidebarListView.carriedOpacity
        panel.orderFront(nil)
    }

    func follow(_ event: NSEvent) {
        guard let window = event.window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        panel.setFrameOrigin(NSPoint(x: point.x - grab.x, y: point.y - grab.y))
    }

    /// Glides onto `view` (its row in its new place) and goes, turning solid as it lands.
    func land(on view: NSView?, completion: @escaping @MainActor () -> Void) {
        guard let view, let window = view.window, !Tokens.Motion.reduceMotion else {
            panel.orderOut(nil)
            completion()
            return
        }
        let target = window.convertToScreen(view.convert(view.bounds, to: nil))
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = Tokens.Motion.easeOut
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                completion()
            }
        })
    }

    private static func picture(of layer: CALayer, size: NSSize, scale: CGFloat) -> NSImage? {
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
}
