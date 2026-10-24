import AppKit
// Zigzag's icon: one paper ribbon on an ink tile, folding back on itself four times. It reads as a Z,
// and it is a zigzag. Flat, two colors, no gradients or shadows; macOS adds its own depth.
let size: CGFloat = 1024

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Apple's continuous-corner tile is a superellipse, not a rounded rectangle.
func squircle(_ rect: NSRect, exponent n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = NSPoint(x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                            y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        i == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // The standard macOS icon grid: an 824pt tile centered on the 1024pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    color(0x1D1D21).setFill()   // ink
    squircle(tile).fill()

    let left: CGFloat = 322, right: CGFloat = 702, top: CGFloat = 694, bottom: CGFloat = 330
    let middle = (top + bottom) / 2, fold: CGFloat = 150
    let ribbon = NSBezierPath()
    ribbon.move(to: NSPoint(x: left, y: top))
    ribbon.line(to: NSPoint(x: right, y: top))
    ribbon.line(to: NSPoint(x: 512 - fold, y: middle))
    ribbon.line(to: NSPoint(x: 512 + fold, y: middle))
    ribbon.line(to: NSPoint(x: left, y: bottom))
    ribbon.line(to: NSPoint(x: right, y: bottom))
    ribbon.lineWidth = 96
    ribbon.lineCapStyle = .round
    ribbon.lineJoinStyle = .round
    color(0xF3F0EA).setStroke()   // paper
    ribbon.stroke()
    return true
}

let out = CommandLine.arguments[1]
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(px).png"))
}
