import AppKit
// Draws Zigzag's app icon at 1024px: a sky squircle with a single white zigzag stroke.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    let inset: CGFloat = 100
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius: CGFloat = 185
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    // Soft drop shadow, as on every macOS icon.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor(srgbRed: 0.33, green: 0.52, blue: 0.82, alpha: 1).setFill()
    squircle.fill()
    ctx.restoreGState()
    // Gentle top-to-bottom light, the way Apple's own icons are lit.
    squircle.addClip()
    let gradient = NSGradient(colors: [NSColor(srgbRed: 0.47, green: 0.68, blue: 0.94, alpha: 1),
                                       NSColor(srgbRed: 0.27, green: 0.46, blue: 0.80, alpha: 1)])!
    gradient.draw(in: rect, angle: -90)
    // The mark: one confident zigzag.
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 312, y: 646))
    path.line(to: NSPoint(x: 712, y: 646))
    path.line(to: NSPoint(x: 312, y: 378))
    path.line(to: NSPoint(x: 712, y: 378))
    path.lineWidth = 92
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.18).cgColor)
    NSColor.white.setStroke()
    path.stroke()
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
