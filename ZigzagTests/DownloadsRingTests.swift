import AppKit
import Foundation
import Testing
@testable import Zigzag

/// The sidebar's downloads button shows progress as a ring that reads on any space (#564): a track as heavy as the
/// progress, both on the icon's own circle, the progress in a color that stands out from the frame.
@MainActor struct DownloadsRingTests {
    private func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        var out = color
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
        return out
    }

    private func same(_ a: CGColor?, _ b: NSColor) -> Bool {
        guard let a, let x = NSColor(cgColor: a)?.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        return abs(x.redComponent - y.redComponent) < 0.002 && abs(x.greenComponent - y.greenComponent) < 0.002
            && abs(x.blueComponent - y.blueComponent) < 0.002 && abs(x.alphaComponent - y.alphaComponent) < 0.002
    }

    @Test func theRingAndItsTrackLieOnTheIconsCircle() throws {
        let manager = TabManager(spaceID: Library.shared.spaces[0].id)
        defer { manager.invalidate() }
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        controller.root.layoutSubtreeIfNeeded()
        let sidebar = controller.sidebar
        sidebar.updateDownloads(active: 1, hasAny: true, progress: 0.3)
        let button = sidebar.downloadsButton
        let ring = sidebar.downloadsRing, track = sidebar.downloadsCircle
        #expect(ring.frame == button.bounds && track.frame == button.bounds)
        let center = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        for layer in [ring, track] {
            let box = try #require(layer.path?.boundingBoxOfPath)
            // One circle, centered on the button, the icon's own size.
            #expect(abs(box.midX - center.x) < 0.001 && abs(box.midY - center.y) < 0.001)
            #expect(abs(box.width - DownloadGlyph.circle) < 0.001 && abs(box.height - DownloadGlyph.circle) < 0.001)
            #expect(layer.lineWidth == DownloadGlyph.ring)
        }
        // Heavy enough to read: well over the icon's line, and the arrow inside clear of it.
        #expect(DownloadGlyph.ring >= DownloadGlyph.line * 1.8)
        // The arrow reaches about 4.4pt from the middle.
        #expect(DownloadGlyph.circle / 2 - DownloadGlyph.ring / 2 > 5.5)
        // The mark's image is even whole points, so the button centers it on the circle's center exactly.
        let image = try #require(button.glyph)
        #expect(image.size.width == DownloadGlyph.side && image.size.height == DownloadGlyph.side)
        #expect((button.bounds.width - DownloadGlyph.side).truncatingRemainder(dividingBy: 2) == 0)
        #expect(ring.strokeEnd == 0.3)
        #expect(ring.opacity == 1)
        // Colors: the track from its token, the progress the space's badge.
        let appearance = sidebar.effectiveAppearance
        var trackColor = Tokens.Color.progressTrack, ringColor = Brand.Theme.for(sidebar).badge
        appearance.performAsCurrentDrawingAppearance {
            trackColor = Tokens.Color.progressTrack.usingColorSpace(.sRGB) ?? trackColor
            ringColor = Brand.Theme.for(sidebar).badge.usingColorSpace(.sRGB) ?? ringColor
        }
        #expect(same(track.strokeColor, trackColor))
        #expect(same(ring.strokeColor, ringColor))
        // Done: filled, faded, and the circle back to the icon's line.
        sidebar.updateDownloads(active: 0, hasAny: true)
        #expect(ring.strokeEnd == 1 && ring.opacity == 0)
        #expect(track.lineWidth == DownloadGlyph.line)
    }

    /// The progress stands out from every curated frame, by day and at night: 3:1, the least a graphic needs.
    @Test func theProgressReadsOnEverySpaceColor() {
        for color in SpaceColor.allCases {
            let theme = Brand.Theme.of(SpaceInfo(name: color.name, color: color))
            // White is only ever a light window and black a dark one.
            for dark in [false, true] where !(color == .snow && dark) && !(color == .ink && !dark) {
                let ground = resolved(color.background, dark: dark)
                let progress = resolved(theme.badge, dark: dark)
                let ratio = Brand.contrast(progress, ground)
                #expect(ratio >= 3, "\(color.name) \(dark ? "dark" : "light"): \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// The track shows on every curated frame, and the progress stands apart from the track under it.
    @Test func theTrackShowsAndTheProgressStandsApartFromIt() {
        for color in SpaceColor.allCases {
            let theme = Brand.Theme.of(SpaceInfo(name: color.name, color: color))
            // White is only ever a light window and black a dark one.
            for dark in [false, true] where !(color == .snow && dark) && !(color == .ink && !dark) {
                let ground = resolved(color.background, dark: dark)
                let wash = resolved(Tokens.Color.progressTrack, dark: dark)
                let a = wash.alphaComponent
                let track = NSColor(srgbRed: wash.redComponent * a + ground.redComponent * (1 - a), green: wash.greenComponent * a + ground.greenComponent * (1 - a),
                                    blue: wash.blueComponent * a + ground.blueComponent * (1 - a), alpha: 1)
                let label = "\(color.name) \(dark ? "dark" : "light")"
                #expect(Brand.contrast(track, ground) >= 1.2, "\(label) track")
                #expect(Brand.contrast(resolved(theme.badge, dark: dark), track) >= 2, "\(label) progress on track")
            }
        }
    }
}
