import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

// Renders scripts/dmg/background.html into scripts/dmg-background.tiff, at 1x and 2x so the disk image's window is
// sharp on every screen. JPEG inside the TIFF: the sky is a photo, and this keeps the download small.
// swift scripts/dmg/render.swift
@MainActor final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    let root: URL
    init(root: URL) { self.root = root }

    func start() {
        web.navigationDelegate = self
        let page = root.appendingPathComponent("scripts/dmg/background.html")
        web.loadFileURL(page, allowingReadAccessTo: root)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Fonts and the pictures settle a moment after load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.shoot() }
    }

    /// One picture at twice the window's size, then the 1x made from it, so both show exactly the same.
    private func shoot() {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 640
        web.takeSnapshot(with: config) { image, _ in
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("snapshot failed") }
            self.writeTIFF(cg)
        }
    }

    /// Both sizes in one TIFF, 72 and 144 pixels per inch, as Finder wants a window background for Retina screens.
    private func writeTIFF(_ snapshot: CGImage) {
        let tiff = root.appendingPathComponent("scripts/dmg-background.tiff")
        guard let out = CGImageDestinationCreateWithURL(tiff as CFURL, UTType.tiff.identifier as CFString, 2, nil) else { fatalError() }
        for (width, height, dpi) in [(640, 400, 72), (1280, 800, 144)] {
            let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                          kCGImageDestinationLossyCompressionQuality: 0.88,
                                          kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 7]]
            CGImageDestinationAddImage(out, scaled(snapshot, width: width, height: height), props as CFDictionary)
        }
        guard CGImageDestinationFinalize(out) else { fatalError("couldn't write \(tiff.path)") }
        print("Wrote \(tiff.path)")
        exit(0)
    }

    private func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let app = NSApplication.shared
let renderer = MainActor.assumeIsolated { Renderer(root: root) }
MainActor.assumeIsolated { renderer.start() }
app.run()
