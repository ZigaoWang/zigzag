import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// An extension's button icon as 1Password sets it: a full-bleed circle with a badge in its corner, from
/// `action.setIcon`, drawn whole and centered in the address's pin and clear of the pin mark in Site Controls.
@MainActor
@Suite(.serialized)
struct ExtensionActionIconTests {
    /// The icon a button gets after the button was first laid out, as a pinned extension's icon arrives once WebKit
    /// has it: drawn in the pin's 16pt slot, not the frame the puzzle piece left behind.
    @Test func anIconThatArrivesLateFillsItsSlot() {
        let button = pinButton()
        button.layoutSubtreeIfNeeded()
        button.image = Self.badgedCircle(points: 19, pixels: [19, 38])
        button.layoutSubtreeIfNeeded()
        let side = Tokens.Sidebar.addressIcon
        let slot = NSRect(x: (button.bounds.width - side) / 2, y: (button.bounds.height - side) / 2, width: side, height: side)
        #expect(button.subviews.first { $0 is NSImageView }?.frame == slot)
    }

    /// `setIcon` with ImageData at 19 and 38 pixels, as 1Password draws on an OffscreenCanvas: at 1x and 2x the icon
    /// fills the pin's slot edge to edge, centered, its badge in the corner and its colors kept.
    @Test func setIconImageDataDrawsWholeAndCentered() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Synthetic","version":"1.0","action":{}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><title>page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: ext)
        try controller.load(context)
        defer { try? controller.unload(context) }
        let page = WKWebView(frame: .zero, configuration: try #require(context.webViewConfiguration))
        page.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        for _ in 0..<100 where page.isLoading || page.title != "page" { try await Task.sleep(for: .milliseconds(100)) }
        #expect(page.title == "page")
        let result = try await page.callAsyncJavaScript("""
            function draw(side) {
              const canvas = new OffscreenCanvas(side, side), g = canvas.getContext('2d');
              g.fillStyle = 'rgb(20, 100, 230)';
              g.beginPath(); g.arc(side / 2, side / 2, side / 2, 0, Math.PI * 2); g.fill();
              g.fillStyle = 'rgb(255, 0, 0)';
              g.fillRect(side * 0.6, side * 0.6, side * 0.4, side * 0.4);
              return g.getImageData(0, 0, side, side);
            }
            try { await chrome.action.setIcon({ imageData: { 19: draw(19), 38: draw(38) } }); return 'ok'; }
            catch (error) { return String(error); }
            """, in: nil, contentWorld: .page) as? String
        #expect(result == "ok")
        var icon: NSImage?
        for _ in 0..<50 where icon == nil {
            try await Task.sleep(for: .milliseconds(100))
            icon = context.action(for: nil)?.icon(for: NSSize(width: 32, height: 32))
        }
        let image = try #require(icon)

        for scale in [1, 2] {
            let button = pinButton()
            button.layoutSubtreeIfNeeded()
            button.image = image
            button.layoutSubtreeIfNeeded()
            let pixels = render(button, scale: scale)
            let slot = Int(Tokens.Sidebar.addressIcon) * scale, start = (pixels.side - slot) / 2, end = start + slot - 1
            let ink = pixels.inkBounds
            // Whole: the circle's edges reach each side of the slot, and nothing is drawn outside it.
            #expect(ink.minX == start && ink.maxX == end, "x \(ink.minX)...\(ink.maxX) at \(scale)x")
            #expect(ink.minY == start && ink.maxY == end, "y \(ink.minY)...\(ink.maxY) at \(scale)x")
            // Centered: the circle's widest row and column are the slot's middle ones.
            let middle = start + slot / 2
            #expect(pixels.isInk(start, middle) && pixels.isInk(middle, start))
            // The badge in its bottom-right corner, red as drawn; the circle blue.
            let badge = pixels.color(end, end), body = pixels.color(start + slot / 4, middle)
            #expect(badge.red > 0.85 && badge.green < 0.2 && badge.blue < 0.2, "badge \(badge) at \(scale)x")
            #expect(body.blue > 0.8 && body.red < 0.25, "circle \(body) at \(scale)x")
        }
    }

    /// In Site Controls' grid a pinned tile's mark sits in its corner, never over its icon, even one that fills it.
    @Test func thePinMarkIsClearOfTheIcon() {
        let kept = SiteExtensionsSection.chosenOpen
        defer { SiteExtensionsSection.chosenOpen = kept }
        SiteExtensionsSection.chosenOpen = true
        let icon = Self.badgedCircle(points: 19, pixels: [19, 38])
        let items: [SiteExtensionsSection.Item] = (0..<6).map { i in
            .init(id: "ext\(i)", name: "Extension \(i)", label: "Extension \(i)", icon: icon, badge: "", needsAttention: i == 3,
                  access: .runs, run: { _ in }, menu: { nil })
        }
        let section = SiteExtensionsSection(items: items, isWhole: false, profile: nil, get: {}, manage: {})
        section.frame = NSRect(x: 0, y: 0, width: 200 + PanelLinkRow.outset * 2, height: section.height(for: 200))
        section.wirePins(state: { _ in .pinned }, toggle: { _ in }, title: { _ in nil })
        section.layoutSubtreeIfNeeded()
        let marks = section.subviews.compactMap { $0 as? PinMark }
        #expect(marks.count == items.count)
        let side = SiteExtensionsLayout.iconSide
        for (tile, mark) in zip(section.buttons, marks) {
            let iconFrame = NSRect(x: tile.frame.midX - side / 2, y: tile.frame.midY - side / 2, width: side, height: side)
            #expect(tile is PanelTile)
            #expect(!mark.isHidden)
            #expect(tile.frame.contains(mark.frame))
            #expect(!mark.frame.intersects(iconFrame), "\(mark.frame) over \(iconFrame)")
        }
    }

    // MARK: Helpers

    private func pinButton() -> IconButton {
        let button = AddressView.button("puzzlepiece.extension", toolTip: "Synthetic")
        button.imageSide = Tokens.Sidebar.addressIcon
        let window = NSWindow(contentRect: button.bounds, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView?.addSubview(button)
        return button
    }

    /// A blue full-bleed circle with a red square badge in its bottom-right corner, one bitmap per pixel size.
    private static func badgedCircle(points: CGFloat, pixels: [Int]) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points))
        for side in pixels {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let s = CGFloat(side)
            NSColor(srgbRed: 0.08, green: 0.4, blue: 0.9, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: s, height: s)).fill()
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            NSRect(x: s * 0.6, y: 0, width: s * 0.4, height: s * 0.4).fill()
            NSGraphicsContext.restoreGraphicsState()
            rep.size = image.size
            image.addRepresentation(rep)
        }
        return image
    }

    private struct Pixels {
        let rep: NSBitmapImageRep
        var side: Int { rep.pixelsWide }
        /// Row 0 is the top.
        func color(_ x: Int, _ y: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
            return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        }
        func isInk(_ x: Int, _ y: Int) -> Bool { color(x, y).alpha > 0.5 }
        var inkBounds: (minX: Int, maxX: Int, minY: Int, maxY: Int) {
            var b = (minX: side, maxX: -1, minY: side, maxY: -1)
            for y in 0..<side { for x in 0..<side where isInk(x, y) {
                b = (min(b.minX, x), max(b.maxX, x), min(b.minY, y), max(b.maxY, y))
            } }
            return b
        }
    }

    /// The view drawn at `scale` pixels to a point.
    private func render(_ view: NSView, scale: Int) -> Pixels {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return Pixels(rep: rep)
    }
}
