import AppKit
import Testing
@testable import Zigzag

/// The tab overview's pictures are made ready off the main thread, drawn in bands at once: each band must land where
/// it belongs, and a card's copy is no wider than the largest card.
@MainActor struct ReadyPicturesTests {
    /// A picture red on top, blue underneath, green down its left edge.
    private func picture(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 10, height: height))
        return context.makeImage()!
    }

    /// The color at (x, y), y down from the top, as (r, g, b).
    private func color(of image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    @Test func bandsLandWhereTheyBelong() throws {
        let source = picture(width: 1200, height: 1600)
        let ready = try #require(ReadyPictures.render(source, width: nil, in: CGColorSpace(name: CGColorSpace.sRGB)!))
        #expect(ready.width == 1200 && ready.height == 1600)
        // Every band's top and bottom row, down the picture: red over blue, the green edge all the way.
        for y in Array(stride(from: 0, to: 1600, by: 50)) + [1599] {
            let (r, _, b) = color(of: ready, x: 600, y: y)
            if y < 790 { #expect(r > 240 && b < 15, "row \(y)") }
            if y > 810 { #expect(b > 240 && r < 15, "row \(y)") }
            #expect(color(of: ready, x: 5, y: y).1 > 240, "row \(y)")
        }
    }

    @Test func aCardsCopyIsNoWiderThanTheLargestCard() throws {
        let source = picture(width: 2400, height: 1500)
        let ready = try #require(ReadyPictures.render(source, width: 880, in: CGColorSpace(name: CGColorSpace.sRGB)!))
        #expect(ready.width == 880)
        #expect(ready.height == 550)
        // Smaller than that, it keeps its own size.
        let small = try #require(ReadyPictures.render(picture(width: 400, height: 300), width: 880, in: CGColorSpace(name: CGColorSpace.sRGB)!))
        #expect(small.width == 400 && small.height == 300)
    }

    @Test func aPreparedPictureIsKnownAndKeptWithIt() async {
        let image = NSImage(cgImage: picture(width: 800, height: 600), size: NSSize(width: 400, height: 300))
        #expect(!ReadyPictures.isReady(image, for: .card))
        await withCheckedContinuation { done in
            ReadyPictures.prepare([image], for: .card, in: nil) { done.resume() }
        }
        #expect(ReadyPictures.isReady(image, for: .card))
        // Smaller than a card's largest copy, it's the whole picture, good for flying too.
        #expect(ReadyPictures.isReady(image, for: .full))
        #expect(TabThumbnailView.knownBlank(image) == false)
    }
}
