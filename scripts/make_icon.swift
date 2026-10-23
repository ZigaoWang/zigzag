import AppKit
// Zigzag's icon: the browser itself, reduced to two flat shapes. A dark sidebar and a light page,
// meeting along one zigzag seam. No gradients, no shadows; macOS adds its own depth.
let size: CGFloat = 1024

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
    color(0xF3F0EA).setFill()   // paper
    squircle.fill()
    squircle.addClip()

    // The sidebar: everything left of the seam.
    let seamX: CGFloat = 420
    let amplitude: CGFloat = 110
    let teeth = 2
    let top = tile.maxY, bottom = tile.minY
    let step = (top - bottom) / CGFloat(teeth * 2)
    let sidebar = NSBezierPath()
    sidebar.move(to: NSPoint(x: tile.minX, y: bottom))
    sidebar.line(to: NSPoint(x: seamX - amplitude / 2, y: bottom))
    var y = bottom
    for i in 0..<(teeth * 2) {
        y += step
        sidebar.line(to: NSPoint(x: i % 2 == 0 ? seamX + amplitude / 2 : seamX - amplitude / 2, y: y))
    }
    sidebar.line(to: NSPoint(x: tile.minX, y: top))
    sidebar.close()
    color(0x1D1D21).setFill()   // ink
    sidebar.fill()
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
