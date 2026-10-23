import AppKit
// Zigzag's icon: one ribbon of paper, folded twice into a zigzag, on a warm paper tile.
// The two folds are shaded like the underside of the strip, so it reads as an object, not a letter.
let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func poly(_ points: [NSPoint]) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: points[0])
    points.dropFirst().forEach { p.line(to: $0) }
    p.close()
    return p
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x000000, 0.25).cgColor)
    color(0xF3EEE6).setFill()
    squircle.fill()
    ctx.restoreGState()

    squircle.addClip()
    NSGradient(colors: [color(0xFBF8F3), color(0xEDE6DB)])!.draw(in: tile, angle: -90)

    // The ribbon: top strip, a diagonal fold back, bottom strip. Band height t.
    let t: CGFloat = 132
    let left: CGFloat = 268, right: CGFloat = 756
    let topY: CGFloat = 640, bottomY: CGFloat = 252
    let top = poly([NSPoint(x: left, y: topY), NSPoint(x: right, y: topY), NSPoint(x: right, y: topY + t), NSPoint(x: left, y: topY + t)])
    let bottom = poly([NSPoint(x: left, y: bottomY), NSPoint(x: right, y: bottomY), NSPoint(x: right, y: bottomY + t), NSPoint(x: left, y: bottomY + t)])
    // The diagonal runs from under the top strip's right end to over the bottom strip's left end.
    let diagonal = poly([NSPoint(x: right - t * 1.7, y: topY), NSPoint(x: right, y: topY),
                         NSPoint(x: left + t * 1.7, y: bottomY + t), NSPoint(x: left, y: bottomY + t)])

    let face = color(0xF0603A)       // the front of the ribbon
    let faceLight = color(0xFF8257)
    let back = color(0xB83E22)       // the underside, seen on the diagonal

    // Soft shadow the ribbon casts on the paper.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x6B2A14, 0.30).cgColor)
    face.setFill()
    top.fill(); bottom.fill(); diagonal.fill()
    ctx.restoreGState()

    // Diagonal: the underside, darker toward the folds.
    NSGradient(colors: [back, color(0xD24E2C), back])!.draw(in: diagonal, angle: -40)
    // Strips: lit from above.
    NSGradient(colors: [faceLight, face])!.draw(in: top, angle: -90)
    NSGradient(colors: [faceLight, face])!.draw(in: bottom, angle: -90)

    // Fold creases: a thin shadow where each strip turns.
    ctx.saveGState()
    color(0x000000, 0.18).setStroke()
    let crease1 = NSBezierPath(); crease1.move(to: NSPoint(x: right - t * 1.7, y: topY)); crease1.line(to: NSPoint(x: right, y: topY))
    let crease2 = NSBezierPath(); crease2.move(to: NSPoint(x: left, y: bottomY + t)); crease2.line(to: NSPoint(x: left + t * 1.7, y: bottomY + t))
    crease1.lineWidth = 6; crease2.lineWidth = 6
    crease1.stroke(); crease2.stroke()
    ctx.restoreGState()
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
