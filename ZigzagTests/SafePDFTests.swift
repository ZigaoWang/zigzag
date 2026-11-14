import AppKit
import CoreText
import Network
import os
import Testing
import WebKit
@testable import Zigzag

/// PDFs are read by the sandboxed PDF helper, never in Zigzag: what it answers, how a PDF that breaks it or stalls
/// it fails alone, and that nothing in the app opens a PDF itself.
/// One at a time: two of them bring the helper down on purpose.
@Suite(.serialized) struct SafePDFTests {
    // MARK: PDFs to read

    /// A PDF drawn with CoreGraphics: a red square at each page's top left, a line of text, a web link over the text
    /// on page 1 and a link to page 2, and contents. Pages 300 by 400 points.
    static func pdf(pages: Int = 2, title: String? = "Zigzag Test", text: String = "Hello world") -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, info as CFDictionary)!
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 380, width: 20, height: 20))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text + " \(page + 1)", attributes: [.font: NSFont.systemFont(ofSize: 20)]))
            context.textPosition = CGPoint(x: 40, y: 300)
            CTLineDraw(line, context)
            let second = CTLineCreateWithAttributedString(NSAttributedString(string: "Second line", attributes: [.font: NSFont.systemFont(ofSize: 20)]))
            context.textPosition = CGPoint(x: 40, y: 260)
            CTLineDraw(second, context)
            if page == 0 {
                context.setURL(URL(string: "https://example.com/a")! as CFURL, for: CGRect(x: 40, y: 295, width: 100, height: 25))
                context.setDestination("second" as CFString, for: CGRect(x: 40, y: 100, width: 100, height: 40))
            }
            if page == 1 { context.addDestination("second" as CFString, at: CGPoint(x: 0, y: 200)) }
            context.endPDFPage()
        }
        let outline: [String: Any] = [
            kCGPDFOutlineChildren as String: [
                [kCGPDFOutlineTitle as String: "One", kCGPDFOutlineDestination as String: 1] as [String: Any],
                [kCGPDFOutlineTitle as String: "Two", kCGPDFOutlineDestination as String: 2,
                 kCGPDFOutlineChildren as String: [[kCGPDFOutlineTitle as String: "Two point one", kCGPDFOutlineDestination as String: 2]]] as [String: Any],
            ],
        ]
        CGPDFContextSetOutline(context, outline as CFDictionary)
        context.closePDF()
        return data as Data
    }

    /// A one-page PDF written by hand, 200 by 100 points, turned 90° clockwise, with a red square at its top left.
    static func rotatedPDF() -> Data {
        let stream = "1 0 0 rg 0 80 20 20 re f"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Rotate 90 /Contents 4 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// A one-page PDF written by hand with a text field to fill in.
    static func formPDF() -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [20 120 280 150] /P 3 0 R >>",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 4))
    }

    // MARK: What the helper answers

    /// A form to fill in goes back to WebKit's viewer, where its fields can be typed into.
    @Test @MainActor func aFormToFillInIsHandedBack() async throws {
        #expect(await SafePDF(data: Self.formPDF()).open() == nil)
        #expect(await SafePDF(data: Self.pdf(pages: 1)).open() != nil)
    }

    @Test @MainActor func aPDFOpensWithItsPagesTitleAndContents() async throws {
        let document = SafePDF(data: Self.pdf(pages: 3))
        let info = try #require(await document.open())
        #expect(info.pageSizes == Array(repeating: CGSize(width: 300, height: 400), count: 3))
        #expect(info.title == "Zigzag Test")
        #expect(info.allowsCopying)
        #expect(info.outline.map(\.title) == ["One", "Two", "Two point one"])
        #expect(info.outline.map(\.level) == [0, 0, 1])
        #expect(info.outline.map(\.page) == [0, 1, 1])
    }

    @Test @MainActor func aPartOfAPageComesBackAsPixels() async throws {
        let document = SafePDF(data: Self.pdf())
        _ = try #require(await document.open())
        // The top left 40 by 40 points at 2 pixels a point: the red square fills the first 40 pixels each way.
        let image = try #require(await document.render(page: 0, rect: CGRect(x: 0, y: 0, width: 40, height: 40), scale: 2, dark: false))
        #expect(image.width == 80 && image.height == 80)
        let red = Self.pixel(image, x: 10, y: 10), paper = Self.pixel(image, x: 70, y: 70)
        #expect(red[0] > 230 && red[1] < 30 && red[2] < 30, "\(red)")
        #expect(paper.allSatisfy { $0 > 245 }, "\(paper)")
        // Dark pages: the paper goes dark, the red stays red.
        let dark = try #require(await document.render(page: 0, rect: CGRect(x: 0, y: 0, width: 40, height: 40), scale: 2, dark: true))
        let darkPaper = Self.pixel(dark, x: 70, y: 70), darkRed = Self.pixel(dark, x: 10, y: 10)
        #expect(darkPaper[0] < 50 && darkPaper[1] < 50 && darkPaper[2] < 50, "\(darkPaper)")
        #expect(darkRed[0] > darkRed[1] + 60 && darkRed[0] > darkRed[2] + 60, "\(darkRed)")
    }

    @Test @MainActor func aTurnedPageIsShownTurned() async throws {
        let document = SafePDF(data: Self.rotatedPDF())
        let info = try #require(await document.open())
        #expect(info.pageSizes == [CGSize(width: 100, height: 200)])
        let image = try #require(await document.render(page: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 200), scale: 1, dark: false))
        // Turned clockwise, the square at its top left is at the top right.
        #expect(Self.pixel(image, x: 90, y: 10)[1] < 30)
        #expect(Self.pixel(image, x: 10, y: 10)[1] > 240)
    }

    // MARK: Dark pages keep their pictures

    /// Four colors, red, green, blue and yellow, two by two: smoothed out, a small photo.
    static let photoHex = "FF000000FF000000FFFFFF00"

    static func photo() -> CGImage {
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255]
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// A 300 by 400 point page drawn with CoreGraphics: a line of text, and `photo()` in `picture` (page points, y up).
    static func picturePDF(picture: CGRect, background: CGImage? = nil) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        if let background { context.draw(background, in: box) }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Curriculum vitae", attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        context.textPosition = CGPoint(x: 20, y: 300)
        CTLineDraw(line, context)
        context.draw(photo(), in: picture)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A PDF written by hand from its objects, numbered from 1, the first the catalog.
    static func handWritten(_ objects: [String]) -> Data {
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    static func stream(_ dictionary: String = "", _ content: String) -> String {
        "<< \(dictionary) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
    }

    static let photoObject = stream("/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode",
                                    photoHex + ">")

    /// An image's pixels, 8-bit RGBA, rows top to bottom.
    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    /// How far apart two renders are at most in `rect` (pixels, y down), any channel.
    static func difference(_ a: CGImage, _ b: CGImage, in rect: CGRect) -> Int {
        let one = pixels(a), other = pixels(b)
        var most = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                for channel in 0..<3 {
                    let index = (y * a.width + x) * 4 + channel
                    most = max(most, abs(Int(one[index]) - Int(other[index])))
                }
            }
        }
        return most
    }

    static func isDark(_ pixel: [UInt8]) -> Bool { pixel[0] < 50 && pixel[1] < 50 && pixel[2] < 50 }

    /// Light and dark renders of a whole page at a pixel a point.
    @MainActor static func lightAndDark(_ data: Data) async throws -> (light: CGImage, dark: CGImage) {
        let document = SafePDF(data: data)
        let info = try #require(await document.open())
        let size = try #require(info.pageSizes.first)
        let rect = CGRect(origin: .zero, size: size)
        let light = try #require(await document.render(page: 0, rect: rect, scale: 1, dark: false))
        let dark = try #require(await document.render(page: 0, rect: rect, scale: 1, dark: true))
        return (light, dark)
    }

    @Test @MainActor func aDarkPageKeepsItsPhotosColors() async throws {
        // The photo at 150...250 across, 50...150 up: 250...350 down the page as shown.
        let (light, dark) = try await Self.lightAndDark(Self.picturePDF(picture: CGRect(x: 150, y: 50, width: 100, height: 100)))
        let photo = Self.pixel(light, x: 160, y: 260)
        #expect(photo[0] > 150 && photo[1] < 120, "the light render shows the photo's red corner: \(photo)")
        #expect(Self.difference(light, dark, in: CGRect(x: 153, y: 253, width: 94, height: 94)) <= 2)
        // The paper and the text around it go dark: the text's line is mostly dark paper with light letters.
        #expect(Self.isDark(Self.pixel(dark, x: 100, y: 200)), "\(Self.pixel(dark, x: 100, y: 200))")
        #expect(Self.isDark(Self.pixel(dark, x: 140, y: 300)), "\(Self.pixel(dark, x: 140, y: 300))")
        let line = Self.pixels(dark)
        var bright = 0, all = 0
        for y in 80..<110 {
            for x in 20..<220 {
                all += 1
                if line[(y * dark.width + x) * 4] > 150 { bright += 1 }
            }
        }
        #expect(bright > 50 && bright < all / 2, "\(bright) light pixels of \(all) in the text's line")
    }

    @Test @MainActor func aScannedPageStillGoesDark() async throws {
        // A scan: one picture over the whole page, white with a gray band, and the small photo on it.
        let white = [UInt8](repeating: 255, count: 30 * 40 * 4)
        var scan = white
        for y in 10..<12 { for x in 0..<30 { for c in 0..<3 { scan[(y * 30 + x) * 4 + c] = 90 } } }
        let provider = CGDataProvider(data: Data(scan) as CFData)!
        let page = CGImage(width: 30, height: 40, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 120, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)!
        let (_, dark) = try await Self.lightAndDark(Self.picturePDF(picture: CGRect(x: 150, y: 50, width: 100, height: 100), background: page))
        #expect(Self.isDark(Self.pixel(dark, x: 50, y: 200)), "the scan's paper: \(Self.pixel(dark, x: 50, y: 200))")
        #expect(Self.isDark(Self.pixel(dark, x: 200, y: 20)), "\(Self.pixel(dark, x: 200, y: 20))")
    }

    @Test @MainActor func aTurnedPageKeepsItsPhotosColorsWhereItsShown() async throws {
        // 200 by 100 points turned 90° clockwise, the photo in its top left 40 points: at the top right as shown.
        let data = Self.handWritten([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Rotate 90 /Contents 4 0 R /Resources << /XObject << /Im1 5 0 R >> >> >>",
            Self.stream("", "q 40 0 0 40 0 60 cm /Im1 Do Q 0 g 100 20 60 10 re f"),
            Self.photoObject,
        ])
        let (light, dark) = try await Self.lightAndDark(data)
        #expect(light.width == 100 && light.height == 200)
        #expect(!Self.isDark(Self.pixel(light, x: 80, y: 20)) && Self.pixel(light, x: 80, y: 20) != [255, 255, 255, 255])
        #expect(Self.difference(light, dark, in: CGRect(x: 63, y: 3, width: 34, height: 34)) <= 2)
        #expect(Self.isDark(Self.pixel(dark, x: 20, y: 20)), "\(Self.pixel(dark, x: 20, y: 20))")
        #expect(Self.isDark(Self.pixel(dark, x: 50, y: 150)), "\(Self.pixel(dark, x: 50, y: 150))")
    }

    @Test @MainActor func photosInAFormOrInlineKeepTheirColors() async throws {
        // A form, drawn twice its size at 100, 20, with the photo 30 points in it: 100...160 across, 20...80 up.
        // And an inline photo 40 points at 20, 140.
        let data = Self.handWritten([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << /XObject << /Fm1 5 0 R >> >> >>",
            Self.stream("", "q 1 0 0 1 100 20 cm /Fm1 Do Q q 40 0 0 40 20 140 cm BI /W 2 /H 2 /CS /RGB /BPC 8 /F /AHx ID \(Self.photoHex)> EI Q"),
            Self.stream("/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [2 0 0 2 0 0] /Resources << /XObject << /Im1 6 0 R >> >>",
                        "q 30 0 0 30 0 0 cm /Im1 Do Q"),
            Self.photoObject,
        ])
        let (light, dark) = try await Self.lightAndDark(data)
        #expect(Self.pixel(light, x: 105, y: 125)[0] > 150, "the form's photo, light: \(Self.pixel(light, x: 105, y: 125))")
        #expect(Self.difference(light, dark, in: CGRect(x: 103, y: 123, width: 54, height: 54)) <= 2)
        #expect(Self.pixel(light, x: 25, y: 25)[0] > 150, "the inline photo, light: \(Self.pixel(light, x: 25, y: 25))")
        #expect(Self.difference(light, dark, in: CGRect(x: 23, y: 23, width: 34, height: 34)) <= 2)
        #expect(Self.isDark(Self.pixel(dark, x: 100, y: 100)), "\(Self.pixel(dark, x: 100, y: 100))")
        #expect(Self.isDark(Self.pixel(dark, x: 180, y: 20)), "\(Self.pixel(dark, x: 180, y: 20))")
    }

    @Test @MainActor func aPagesTextComesWithWhereEachCharacterIs() async throws {
        let document = SafePDF(data: Self.pdf())
        _ = try #require(await document.open())
        let text = try #require(await document.text(page: 0))
        #expect((text.string as String).contains("Hello world 1"))
        #expect(text.boxes.count == text.string.length)
        // "H" sits at 40 points across, its baseline 100 points down from the top (300 up from the bottom of 400).
        let h = text.string.range(of: "H").location
        let box = text.boxes[h]
        #expect(abs(box.minX - 40) < 4 && box.maxY > 90 && box.maxY < 106 && box.minY > 70, "\(box)")
        // Where a point is, and the run selected along the line.
        #expect(PDFText.index(at: CGPoint(x: box.midX, y: box.midY), in: text.boxes) == h)
        let lines = PDFText.lines(h..<h + 5, in: text.boxes)
        #expect(lines.count == 1 && lines[0].minX <= box.minX + 0.5 && lines[0].width > box.width * 3)
        #expect(PDFText.word(at: h + 1, in: text.string) == NSRange(location: h, length: 5))
        // The next line's characters are where they are too, not one along for each line before.
        let s = text.string.range(of: "Second").location
        #expect(s != NSNotFound)
        #expect(abs(text.boxes[s].minX - 40) < 4 && text.boxes[s].minY > box.maxY, "\(text.boxes[s])")
        #expect(PDFText.lines(s..<s + 6, in: text.boxes).count == 1)
        // A web link over the text, and one to page 2, 200 points down it.
        let web = try #require(text.links.first { $0.url != nil })
        #expect(web.url?.absoluteString == "https://example.com/a")
        #expect(abs(web.rect.minX - 40) < 1 && abs(web.rect.minY - 80) < 1 && abs(web.rect.height - 25) < 1, "\(web.rect)")
        let inside = try #require(text.links.first { $0.url == nil })
        #expect(inside.page == 1)
        #expect(inside.y.map { abs($0 - 200) < 1 } ?? false, "\(String(describing: inside.y))")
    }

    @Test @MainActor func aLargePieceAtAnOddScaleStillComes() async throws {
        // Four 1024-pixel pieces across at 3.39 pixels a point: rounding must never push it past the helper's limit.
        let document = SafePDF(data: Self.pdf())
        _ = try #require(await document.open())
        let scale: CGFloat = 217 / 64
        let side = 4 * 1024 / scale
        let image = await document.render(page: 0, rect: CGRect(x: 0, y: 0, width: min(side, 300), height: min(side, 400)), scale: scale, dark: false)
        #expect(image != nil)
        let wide = await document.render(page: 0, rect: CGRect(x: 0, y: 0, width: 4096 / 16, height: 4096 / 16), scale: 16, dark: false)
        #expect(wide?.width == 4096)
    }

    @Test @MainActor func everyPagesTextForFind() async throws {
        let document = SafePDF(data: Self.pdf(pages: 3))
        _ = try #require(await document.open())
        let strings = try #require(await document.strings())
        #expect(strings.count == 3)
        #expect(strings[2].contains("Hello world 3"))
        // Asking for what isn't there gets nothing, and the PDF is still fine.
        #expect(await document.text(page: 7) == nil)
        #expect(await document.render(page: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 100, dark: false) == nil)
        #expect(await document.render(page: 0, rect: CGRect(x: 500, y: 500, width: 10, height: 10), scale: 1, dark: false) == nil)
        #expect(!document.hasFailed)
        #expect(await document.text(page: 1) != nil)
    }

    // MARK: When a PDF is bad

    @Test @MainActor func whatIsntAPDFIsntOpened() async throws {
        for bytes in [Data(), Data("<html>not found</html>".utf8), Data("%PDF-1.7\nnothing else at all".utf8),
                      Data(Self.pdf().prefix(200)), Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919) })] {
            let document = SafePDF(data: bytes)
            #expect(await document.open() == nil)
        }
        // The helper is fine for the next one.
        #expect(await SafePDF(data: Self.pdf()).open() != nil)
    }

    // Each PDF made to crash the helper is its own bytes: one that crashed it is remembered, and never sent again.
    @Test @MainActor func aPDFThatBringsTheHelperDownFailsAlone() async throws {
        let good = SafePDF(data: Self.pdf(pages: 2))
        _ = try #require(await good.open())
        var failed = false
        let bad = SafePDF(data: Data("%PDF-ZIGZAG-TEST-CRASH\nshared".utf8))
        bad.onFail = { failed = true }
        // Both at once: the good one's request is in the helper as it goes down.
        async let goodTile = good.render(page: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1, dark: false)
        async let badInfo = bad.open()
        let (tile, info) = await (goodTile, badInfo)
        #expect(info == nil)
        #expect(bad.hasFailed && failed)
        #expect(tile != nil)
        // The good one goes on in a helper started afresh, which has it again.
        #expect(!good.hasFailed)
        #expect(await good.text(page: 0)?.string.contains("Hello") == true)
        // A failed PDF asks nothing more.
        #expect(await bad.strings() == nil)
    }

    @Test @MainActor func aPDFThatHadTheHelperToItselfFailsAtOnce() async throws {
        var breaks = 0
        let bad = SafePDF(data: Data("%PDF-ZIGZAG-TEST-CRASH\nalone".utf8)) {
            breaks += 1
            return XPCPDFLink(serviceName: PDFService.name)
        }
        #expect(await bad.open() == nil)
        #expect(bad.hasFailed)
        // One connection, one crash: it isn't sent again to bring the helper down a second time.
        #expect(breaks == 1)
        #expect(await SafePDF(data: Self.pdf()).open() != nil)
    }

    @Test @MainActor func aPDFThatBroughtTheHelperDownIsntSentAgain() async throws {
        let bytes = Data("%PDF-ZIGZAG-TEST-CRASH\nremembered".utf8)
        let url = URL(string: "https://example.com/crash-\(UUID().uuidString).pdf")!
        #expect(!SafePDF.broughtDownTheHelper(url))
        #expect(await SafePDF(data: bytes, source: url).open() == nil)
        #expect(SafePDF.broughtDownTheHelper(url))
        // The page reloads it, from the same address or another: it fails at once, the helper never asked.
        var links = 0
        let again = SafePDF(data: bytes) {
            links += 1
            return XPCPDFLink(serviceName: PDFService.name)
        }
        #expect(await again.open() == nil)
        #expect(again.hasFailed)
        #expect(links == 0)
        // Other bytes the same size are sent as ever.
        var otherLinks = 0
        let sameSize = SafePDF(data: Data("%PDF-ZIGZAG-TEST-CRASI\nremembered".utf8)) {
            otherLinks += 1
            return XPCPDFLink(serviceName: PDFService.name)
        }
        #expect(await sameSize.open() == nil)
        #expect(otherLinks == 1)
    }

    @Test @MainActor func aPDFTooSlowFailsAndTheRestGoOn() async throws {
        // A tenth of the time limits: the slow one (4 seconds to open) is given 2.
        let slow = SafePDF(data: Data("%PDF-ZIGZAG-TEST-SLOW\n".utf8), timeScale: 0.1)
        let start = Date()
        #expect(await slow.open() == nil)
        #expect(slow.hasFailed)
        #expect(Date().timeIntervalSince(start) < 3.5)
        let other = SafePDF(data: Self.pdf())
        #expect(await other.open() != nil)
        #expect(await other.render(page: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 50), scale: 1, dark: false) != nil)
    }

    @Test @MainActor func noHelperMeansWebKitsViewerSoon() async {
        let missing = SafePDF(data: Self.pdf(), serviceName: "wang.zigao.zigzag.no-such-helper")
        let start = Date()
        #expect(await missing.open() == nil)
        #expect(missing.hasFailed)
        #expect(Date().timeIntervalSince(start) < 5)
        // No helper isn't the PDF's doing: it opens once there is one.
        #expect(await SafePDF(data: Self.pdf()).open() != nil)
    }

    // MARK: One request at a time for each PDF

    /// Pictures asked for while a long find is in the helper wait in Zigzag, their clocks not yet running: in the
    /// helper they'd wait behind it, and run out of time there.
    @Test @MainActor func picturesWaitingBehindAFindDontRunOutOfTime() async throws {
        // A fiftieth of the limits: pictures get 0.24 seconds, find 0.8. Find takes 0.4 in this helper.
        let helper = FakePDFHelper(renderTime: 0.02, stringsTime: 0.4)
        let document = SafePDF(data: Data("%PDF-fake".utf8), timeScale: 0.02) { FakePDFLink(helper) }
        _ = try #require(await document.open())
        let find = Task { await document.strings() }
        let tiles = (0..<3).map { _ in
            Task { await document.render(page: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 1, dark: false) }
        }
        #expect(await find.value?.count == 1)
        for tile in tiles { #expect(await tile.value != nil) }
        #expect(!document.hasFailed)
        #expect(helper.most == 1, "requests in the helper at once: \(helper.most)")
    }

    @Test @MainActor func picturesGoBeforeTextAndFind() async throws {
        let helper = FakePDFHelper(renderTime: 0.1)
        let document = SafePDF(data: Data("%PDF-fake".utf8)) { FakePDFLink(helper) }
        _ = try #require(await document.open())
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let first = Task { await document.render(page: 0, rect: rect, scale: 1, dark: false) }
        let find = Task { await document.strings() }
        let text = Task { await document.text(page: 0) }
        let picture = Task { await document.render(page: 0, rect: rect, scale: 1, dark: false) }
        _ = await (first.value, find.value, text.value, picture.value)
        #expect(helper.log == ["open", "render", "render", "text", "strings"])
    }

    /// A piece the helper draws nothing for isn't asked for again and again.
    @Test @MainActor func aPieceThatComesBackEmptyIsntAskedForAgain() async throws {
        let helper = FakePDFHelper(drawsNothing: true)
        let document = SafePDF(data: Data("%PDF-fake".utf8)) { FakePDFLink(helper) }
        let info = try #require(await document.open())
        let view = ZigzagPDFView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 500)
        view.show(document, info: info, startPage: 0)
        view.whenShown {}
        try await Task.sleep(for: .milliseconds(800))
        let asked = helper.log.filter { $0 == "render" }.count
        #expect(asked > 0 && asked < 12, "\(asked) pictures asked for")
        // The other way, dark: those are new pieces, asked for once each too.
        view.isDark = true
        view.whenShown {}
        try await Task.sleep(for: .milliseconds(500))
        let dark = helper.log.filter { $0 == "render" }.count - asked
        #expect(dark > 0 && dark < 12, "\(dark) dark pictures asked for")
    }

    // MARK: Find

    @Test func findLooksThroughEveryPageAndAnOlderSearchStops() async {
        let strings = ["Hello world", "nothing", "HÉLLO again, hello"]
        let found = ZigzagPDFView.matches(of: "hello", in: strings)
        #expect(found.map(\.page) == [0, 2, 2])
        #expect(found.map(\.range) == [NSRange(location: 0, length: 5), NSRange(location: 0, length: 5), NSRange(location: 13, length: 5)])
        let stopped = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ZigzagPDFView.matches(of: "hello", in: strings)
        }
        #expect(await stopped.value.isEmpty)
    }

    @Test @MainActor func findInThePDFsText() async throws {
        let document = SafePDF(data: Self.pdf(pages: 3))
        let info = try #require(await document.open())
        let view = ZigzagPDFView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 500)
        view.show(document, info: info, startPage: 0)
        // A newer search while the first waits: the first comes back empty, the newer finds its matches.
        let older = Task { @MainActor in await view.matches(of: "hello") }
        let newer = Task { @MainActor in await view.matches(of: "world 3") }
        let (first, second) = await (older.value, newer.value)
        #expect(second.map(\.page) == [2])
        #expect(first.isEmpty || first.count == 3)
        #expect(await view.matches(of: "second line").count == 3)
    }

    @Test func badAnswersAreNotTaken() {
        #expect(SafePDF.image(from: RemotePDFTile(pixels: Data(count: 10), width: 4, height: 4)) == nil)
        let big = PDFLimits.maxTileSide + 1
        #expect(!RemotePDFTile(pixels: Data(count: big * 4), width: big, height: 1).isWellFormed)
        #expect(SafePDF.image(from: RemotePDFTile(pixels: Data(count: 64), width: 4, height: 4))?.width == 4)

        func sizes(_ values: [Double]) -> Data { values.withUnsafeBytes { Data($0) } }
        let fine = RemotePDFInfo(pageCount: 1, sizes: sizes([300, 400]), title: nil, outline: [], allowsCopying: true)
        #expect(SafePDF.info(from: fine)?.pageSizes == [CGSize(width: 300, height: 400)])
        #expect(SafePDF.info(from: RemotePDFInfo(pageCount: 2, sizes: sizes([300, 400]), title: nil, outline: [], allowsCopying: true)) == nil)
        #expect(SafePDF.info(from: RemotePDFInfo(pageCount: 1, sizes: sizes([.infinity, 400]), title: nil, outline: [], allowsCopying: true)) == nil)
        #expect(SafePDF.info(from: RemotePDFInfo(pageCount: 1, sizes: sizes([0, 400]), title: nil, outline: [], allowsCopying: true)) == nil)
        let farOutline = RemotePDFInfo(pageCount: 1, sizes: sizes([300, 400]), title: nil,
                                       outline: [RemoteOutlineEntry(title: "x", level: 0, page: 5, y: .nan)], allowsCopying: true)
        #expect(SafePDF.info(from: farOutline) == nil)

        let text = RemotePageText(string: "ab", boxes: Data(count: 16), links: [])
        #expect(!text.isWellFormed(pages: 1))
        #expect(RemotePageText(string: "ab", boxes: Data(count: 32), links: []).isWellFormed(pages: 1))
        let farLink = RemoteLink(x: 0, y: 0, width: 1, height: 1, url: nil, page: 9, pageY: .nan)
        #expect(!RemotePageText(string: "", boxes: Data(), links: [farLink]).isWellFormed(pages: 1))
        // A box that's no place, or turned inside out, isn't taken: it would reach the layers that mark text.
        func boxes(_ values: [Float32]) -> Data { values.withUnsafeBytes { Data($0) } }
        #expect(RemotePageText(string: "a", boxes: boxes([1, 2, 3, 4]), links: []).isWellFormed(pages: 1))
        #expect(RemotePageText(string: "a", boxes: boxes([0, 0, 0, 0]), links: []).isWellFormed(pages: 1))
        for bad: [Float32] in [[.nan, 2, 3, 4], [1, .infinity, 3, 4], [1, 2, -.infinity, 4], [1, 2, 3, .nan], [1, 2, -1, 4], [1, 2, 3, -0.5]] {
            #expect(!RemotePageText(string: "a", boxes: boxes(bad), links: []).isWellFormed(pages: 1), "\(bad)")
        }
    }

    // MARK: Where the pages sit

    @Test func pagesSitInOneColumnOrTwoAsInABook() {
        #expect(PDFLayout.rows(count: 4, twoUp: true) == [[nil, 0], [1, 2], [3, nil]])
        #expect(PDFLayout.rows(count: 2, twoUp: false) == [[0], [1]])
        let sizes = [CGSize(width: 100, height: 200), CGSize(width: 100, height: 200), CGSize(width: 50, height: 100)]
        let scale = PDFLayout.fitScale(sizes: sizes, twoUp: false, width: 232)
        #expect(abs(scale - 2) < 0.001)
        let column = PDFLayout(sizes: sizes, scale: 1, twoUp: false, width: 400)
        #expect(column.frames[0] == CGRect(x: 150, y: PDFLayout.margin, width: 100, height: 200))
        #expect(column.frames[2].midX == 200)
        #expect(column.frames[1].minY == column.frames[0].maxY + PDFLayout.gap)
        #expect(column.pages(in: CGRect(x: 0, y: 250, width: 400, height: 10)) == [1])
        let book = PDFLayout(sizes: sizes, scale: 1, twoUp: true, width: 400)
        // The first page alone on the right of the middle, then two by two.
        #expect(book.frames[0].minX == 200 + PDFLayout.gap / 2)
        #expect(book.frames[1].maxX == 200 - PDFLayout.gap / 2 && book.frames[2].minX == 200 + PDFLayout.gap / 2)
        #expect(book.frames[1].minY > book.frames[0].maxY)
    }

    // MARK: Zigzag never opens a PDF itself

    @Test @MainActor func aPDFOpensInTheViewerThroughTheHelper() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let bytes = Self.pdf()
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let webView = WKWebView()
        let data = try #require(await PDFViewerView.load(file, from: webView, userAgent: nil))
        // The bytes as they are, to save untouched; the pages from the helper.
        #expect(data == bytes)
        let (document, info) = try #require(await PDFViewerView.open(data))
        #expect(document.data == data)
        #expect(info.pageSizes.count == 2)
        // Not an address the viewer fetches.
        #expect(await PDFViewerView.load(URL(string: "ftp://example.com/a.pdf")!, from: webView, userAgent: nil) == nil)
    }

    /// A file past the limit isn't read in to find out: its size says so. (A sparse file: nothing written.)
    @Test @MainActor func aFileTooBigIsntRead() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("%PDF-1.4\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(SafePDF.maxInputBytes) + 1)
        try handle.close()
        let start = Date()
        #expect(await PDFViewerView.load(file, from: WKWebView(), userAgent: nil) == nil)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(await PDFViewerView.load(file, from: WKWebView(), userAgent: nil, limit: Int.max) != nil)
    }

    /// The viewer's own download: as the browser, never CFNetwork's default; and given up past the limit, whether the
    /// server says it's too big or only sends too much.
    @Test @MainActor func theViewersDownloadSaysItsTheBrowserAndStopsPastTheLimit() async throws {
        let server = try PDFTestServer()
        let base = try await server.start()
        defer { server.stop() }
        let webView = WKWebView()
        let small = try #require(await PDFViewerView.load(base.appendingPathComponent("ua"), from: webView, userAgent: nil))
        #expect(small.starts(with: Data("%PDF-".utf8)))
        let sent = try #require(server.userAgents.withLock { $0.last })
        #expect(sent.hasPrefix("Mozilla/5.0") && sent.contains("Safari/605.1.15"), "\(sent)")
        // The page's own, when it said; the web view's custom one, when it has one.
        _ = await PDFViewerView.load(base.appendingPathComponent("ua"), from: webView, userAgent: "Page/1.0")
        #expect(server.userAgents.withLock { $0.last } == "Page/1.0")
        webView.customUserAgent = "Custom/2.0"
        _ = await PDFViewerView.load(base.appendingPathComponent("ua"), from: webView, userAgent: nil)
        #expect(server.userAgents.withLock { $0.last } == "Custom/2.0")
        // Past the limit: sent without saying how long, or said too long up front.
        #expect(await PDFViewerView.load(base.appendingPathComponent("stream"), from: webView, userAgent: nil, limit: 64 * 1024) == nil)
        #expect(await PDFViewerView.load(base.appendingPathComponent("stream"), from: webView, userAgent: nil, limit: 1024 * 1024)?.count == 256 * 1024)
        #expect(await PDFViewerView.load(base.appendingPathComponent("said"), from: webView, userAgent: nil, limit: 64 * 1024) == nil)
        #expect(await PDFViewerView.load(base.appendingPathComponent("missing"), from: webView, userAgent: nil) == nil)
    }

    // MARK: A helper that answers out of turn

    /// A helper taken over by a PDF can send anything back. Over a real XPC connection: whatever isn't the one class
    /// each reply carries (another class, an array of arrays where find's strings go) fails that PDF alone, and
    /// the app goes on.
    @Test(arguments: LooseReply.allCases) @MainActor func aReplyOfTheWrongShapeFailsThatPDFAlone(_ reply: LooseReply) async throws {
        let helper = LoosePDFHelper(reply)
        defer { helper.stop() }
        var failed = false
        let document = SafePDF(data: Data("%PDF-loose-\(UUID().uuidString)".utf8)) { XPCPDFLink(endpoint: helper.endpoint) }
        document.onFail = { failed = true }
        let info = await document.open()
        switch reply {
        case .openWithData, .openWithArray:
            #expect(info == nil)
        case .renderWithText:
            #expect(info != nil)
            #expect(await document.render(page: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 1, dark: false) == nil)
        case .stringsAsArrays, .stringsWrapperOfArrays, .stringsWithData, .textMalformed:
            #expect(info != nil)
            #expect(await document.strings() == nil)
        }
        #expect(document.hasFailed && failed, "\(reply)")
        // Nothing else is asked of it, and other PDFs go on.
        #expect(await document.text(page: 0) == nil)
        let other = SafePDF(data: Data("%PDF-fake".utf8)) { FakePDFLink(FakePDFHelper()) }
        #expect(await other.open() != nil)
        #expect(await other.strings() == [""])
    }

    /// The reply's static type is only what the helper was meant to send: each answer's class is checked on the
    /// object itself before anything uses it, even where XPC isn't between them.
    @Test @MainActor func anAnswerOfAnotherClassIsNeverUsed() async throws {
        let open = SafePDF(data: Data("%PDF-loose-\(UUID().uuidString)".utf8)) { MisclassedPDFLink(.openWithData) }
        #expect(await open.open() == nil)
        #expect(open.hasFailed)
        let render = SafePDF(data: Data("%PDF-loose-\(UUID().uuidString)".utf8)) { MisclassedPDFLink(.renderWithText) }
        _ = try #require(await render.open())
        #expect(await render.render(page: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 1, dark: false) == nil)
        #expect(render.hasFailed)
        let find = SafePDF(data: Data("%PDF-loose-\(UUID().uuidString)".utf8)) { MisclassedPDFLink(.stringsWithData) }
        _ = try #require(await find.open())
        #expect(await find.strings() == nil)
        #expect(find.hasFailed)
        #expect(SafePDF.isExactly(RemotePDFStrings([]), RemotePDFStrings.self))
        #expect(!SafePDF.isExactly(NSData(), RemotePDFStrings.self))
    }

    /// Text that doesn't add up (a box past the end of the string) is no answer either: the PDF fails.
    @Test @MainActor func malformedTextFailsThePDF() async throws {
        let document = SafePDF(data: Data("%PDF-loose-\(UUID().uuidString)".utf8)) { MisclassedPDFLink(.textMalformed) }
        _ = try #require(await document.open())
        #expect(await document.text(page: 0) == nil)
        #expect(document.hasFailed)
    }

    /// A link over most of a page would open on any click there: it's left out. Smaller ones stay.
    @Test func aLinkOverMostOfThePageIsLeftOut() {
        let page = CGSize(width: 300, height: 400)
        let links = [
            RemoteLink(x: 0, y: 0, width: 300, height: 400, url: "https://example.com/all", page: -1, pageY: .nan),
            RemoteLink(x: -1000, y: -1000, width: 5000, height: 5000, url: "https://example.com/past", page: -1, pageY: .nan),
            RemoteLink(x: 0, y: 0, width: 300, height: 210, url: "https://example.com/most", page: -1, pageY: .nan),
            RemoteLink(x: 0, y: 0, width: 300, height: 190, url: "https://example.com/half", page: -1, pageY: .nan),
            RemoteLink(x: 40, y: 80, width: 100, height: 25, url: "https://example.com/a", page: -1, pageY: .nan),
        ]
        let text = SafePDF.pageText(from: RemotePageText(string: "", boxes: Data(), links: links), pageSize: page)
        #expect(text.links.map { $0.url?.lastPathComponent } == ["half", "a"])
    }

    /// A closed PDF's connection ends at once, and it asks nothing more.
    @Test @MainActor func aClosedPDFEndsItsConnection() async throws {
        let link = CountingPDFLink(FakePDFHelper())
        let document = SafePDF(data: Data("%PDF-fake".utf8)) { link }
        _ = try #require(await document.open())
        document.close()
        #expect(link.invalidated)
        #expect(await document.text(page: 0) == nil)
        #expect(link.sent == 1)
    }

    /// Nothing in the app reads a PDF's bytes: no PDFKit, no CoreGraphics PDF reader, no AppKit PDF picture. The
    /// helper does all of it. The one exception is the full-page screenshot, which reads the PDF WebKit itself makes
    /// of the page, never a site's.
    @Test func theAppHasNoPDFReaderOfItsOwn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Zigzag")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
        #expect(files.count > 50)
        let readers = [#"import PDFKit"#, #"\bPDFDocument\b"#, #"\bPDFView\b"#, #"\bPDFPage\b"#, #"\bCGPDFDocument"#, #"\bNSPDFImageRep\b"#, #"\bCGPDFPage"#]
        var found: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for reader in readers where source.range(of: reader, options: .regularExpression) != nil {
                if file.lastPathComponent == "PageScreenshot.swift", reader.contains("CGPDF") { continue }
                found.append("\(file.lastPathComponent): \(reader)")
            }
        }
        #expect(found.isEmpty, "\(found)")
        // And the viewer decodes no pictures either: what it shows is the helper's pixels.
        for name in ["PDFViewer.swift", "PDFPagesView.swift", "SafePDF.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Web").appendingPathComponent(name), encoding: .utf8)
            for decoder in ["NSImage(data", "CGImageSource", "NSImage(contentsOf", "NSBitmapImageRep(data"] {
                #expect(!source.contains(decoder), "\(name): \(decoder)")
            }
        }
    }
}

/// A stand-in for the PDF helper: one page, 300 by 400, answered one request at a time as the helper does, each
/// noted in order. `drawsNothing`: every picture comes back empty.
nonisolated private final class FakePDFHelper: NSObject, PDFRendering, @unchecked Sendable {
    private let queue = DispatchQueue(label: "zigzag.tests.fake-pdf-helper")
    private let lock = NSLock()
    private var noted: [String] = []
    private var inside = 0
    private var mostInside = 0
    private let renderTime: TimeInterval
    private let stringsTime: TimeInterval
    private let drawsNothing: Bool

    var log: [String] { lock.withLock { noted } }
    /// The most requests that were in it at once, waiting or worked on.
    var most: Int { lock.withLock { mostInside } }

    init(renderTime: TimeInterval = 0, stringsTime: TimeInterval = 0, drawsNothing: Bool = false) {
        self.renderTime = renderTime
        self.stringsTime = stringsTime
        self.drawsNothing = drawsNothing
    }

    private func run(_ name: String, _ work: @escaping @Sendable () -> Void) {
        lock.withLock { inside += 1; mostInside = max(mostInside, inside) }
        queue.async { [self] in
            lock.withLock { noted.append(name) }
            work()
            lock.withLock { inside -= 1 }
        }
    }

    func open(_ data: Data, reply: @escaping @Sendable (RemotePDFInfo?) -> Void) {
        run("open") {
            let sizes = [300.0, 400.0].withUnsafeBytes { Data($0) }
            reply(RemotePDFInfo(pageCount: 1, sizes: sizes, title: nil, outline: [], allowsCopying: true))
        }
    }

    func render(page: Int, x: Double, y: Double, width: Double, height: Double, scale: Double, dark: Bool,
                reply: @escaping @Sendable (RemotePDFTile?, Bool) -> Void) {
        run("render") { [renderTime, drawsNothing] in
            Thread.sleep(forTimeInterval: renderTime)
            guard !drawsNothing else { reply(nil, true); return }
            let w = max(1, Int((min(width, 300) * scale - 0.01).rounded(.up))), h = max(1, Int((min(height, 400) * scale - 0.01).rounded(.up)))
            reply(RemotePDFTile(pixels: Data(count: w * h * 4), width: w, height: h), true)
        }
    }

    func text(page: Int, reply: @escaping @Sendable (RemotePageText?, Bool) -> Void) {
        run("text") { reply(RemotePageText(string: "", boxes: Data(), links: []), true) }
    }

    func strings(reply: @escaping @Sendable (RemotePDFStrings?, Bool) -> Void) {
        run("strings") { [stringsTime] in
            Thread.sleep(forTimeInterval: stringsTime)
            reply(RemotePDFStrings([""]), true)
        }
    }
}

nonisolated private final class FakePDFLink: PDFLink, @unchecked Sendable {
    private let helper: FakePDFHelper
    init(_ helper: FakePDFHelper) { self.helper = helper }
    func send(_ request: @escaping @Sendable (PDFRendering) -> Void, failed: @escaping @Sendable (Bool) -> Void) { request(helper) }
    func invalidate() {}
}

/// What a taken-over helper sends back instead of the real answer.
nonisolated enum LooseReply: CaseIterable, Sendable {
    case openWithData, openWithArray, renderWithText, stringsAsArrays, stringsWrapperOfArrays, stringsWithData
    /// Only in process: a page's text whose boxes don't match its string.
    case textMalformed

    static var allCases: [LooseReply] { [.openWithData, .openWithArray, .renderWithText, .stringsAsArrays, .stringsWrapperOfArrays, .stringsWithData] }
}

/// The helper's requests as a helper that answers anything would see them: the same messages, any object back.
@objc(ZigzagTestsLoosePDFRendering) nonisolated protocol LoosePDFRendering {
    func open(_ data: Data, reply: @escaping @Sendable (NSObject?) -> Void)
    func render(page: Int, x: Double, y: Double, width: Double, height: Double, scale: Double, dark: Bool,
                reply: @escaping @Sendable (NSObject?, Bool) -> Void)
    func text(page: Int, reply: @escaping @Sendable (NSObject?, Bool) -> Void)
    func strings(reply: @escaping @Sendable (NSObject?, Bool) -> Void)
}

/// Sent as a `RemotePDFStrings`, holding an array of arrays where its strings go.
@objc(ZigzagTestsStringsOfArrays) nonisolated private final class StringsOfArrays: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    override init() {}
    init?(coder: NSCoder) { nil }
    override var classForCoder: AnyClass { RemotePDFStrings.self }
    func encode(with coder: NSCoder) { coder.encode([["a"]] as NSArray, forKey: "strings") }
}

/// A helper that answers one request with what it shouldn't, and the rest as the real one would.
nonisolated private final class LooseAnswers: NSObject, LoosePDFRendering, @unchecked Sendable {
    let reply: LooseReply
    init(_ reply: LooseReply) { self.reply = reply }

    func open(_ data: Data, reply: @escaping @Sendable (NSObject?) -> Void) {
        switch self.reply {
        case .openWithData: reply(NSData(data: Data(count: 64)))
        case .openWithArray: reply([[NSData()]] as NSArray)
        default:
            let sizes = [300.0, 400.0].withUnsafeBytes { Data($0) }
            reply(RemotePDFInfo(pageCount: 1, sizes: sizes, title: nil, outline: [], allowsCopying: true))
        }
    }

    func render(page: Int, x: Double, y: Double, width: Double, height: Double, scale: Double, dark: Bool,
                reply: @escaping @Sendable (NSObject?, Bool) -> Void) {
        reply(RemotePageText(string: "", boxes: Data(), links: []), true)
    }

    func text(page: Int, reply: @escaping @Sendable (NSObject?, Bool) -> Void) {
        if self.reply == .textMalformed {
            reply(RemotePageText(string: "abc", boxes: Data(count: 16), links: []), true)
        } else {
            reply(RemotePageText(string: "", boxes: Data(), links: []), true)
        }
    }

    func strings(reply: @escaping @Sendable (NSObject?, Bool) -> Void) {
        switch self.reply {
        case .stringsWrapperOfArrays: reply(StringsOfArrays(), true)
        case .stringsWithData: reply(NSData(), true)
        default: reply([["a"]] as NSArray, true)
        }
    }
}

/// A stand-in helper over a real XPC connection, in this process.
nonisolated private final class LoosePDFHelper: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let answers: LooseAnswers

    init(_ reply: LooseReply) {
        answers = LooseAnswers(reply)
        super.init()
        listener.delegate = self
        listener.resume()
    }

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }
    func stop() { listener.invalidate() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The real interface, with anything let through on this side: only Zigzag's side holds the line.
        let interface = PDFService.interface()
        let anything = NSSet(array: [NSArray.self, NSString.self, NSData.self, RemotePDFInfo.self, RemotePDFTile.self,
                                     RemotePageText.self, RemotePDFStrings.self, StringsOfArrays.self]) as! Set<AnyHashable>
        for selector in [#selector(PDFRendering.open(_:reply:)), #selector(PDFRendering.render(page:x:y:width:height:scale:dark:reply:)),
                         #selector(PDFRendering.text(page:reply:)), #selector(PDFRendering.strings(reply:))] {
            interface.setClasses(anything, for: selector, argumentIndex: 0, ofReply: true)
        }
        connection.exportedInterface = interface
        connection.exportedObject = answers
        connection.resume()
        return true
    }
}

/// The loose helper called straight, as if its answers had the classes the requests name.
nonisolated private final class MisclassedPDFLink: PDFLink, @unchecked Sendable {
    private let answers: LooseAnswers
    init(_ reply: LooseReply) { answers = LooseAnswers(reply) }
    func send(_ request: @escaping @Sendable (PDFRendering) -> Void, failed: @escaping @Sendable (Bool) -> Void) {
        request(unsafeBitCast(answers as AnyObject, to: PDFRendering.self))
    }
    func invalidate() {}
}

/// A fake helper's link that counts what's sent and notes when it ends.
nonisolated private final class CountingPDFLink: PDFLink, @unchecked Sendable {
    private let helper: FakePDFHelper
    private let lock = NSLock()
    private var count = 0
    private var ended = false
    var sent: Int { lock.withLock { count } }
    var invalidated: Bool { lock.withLock { ended } }
    init(_ helper: FakePDFHelper) { self.helper = helper }
    func send(_ request: @escaping @Sendable (PDFRendering) -> Void, failed: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { count += 1 }
        request(helper)
    }
    func invalidate() { lock.withLock { ended = true } }
}

/// A local server for the viewer's own download: `/ua` notes the user agent and answers a small PDF; `/stream`
/// sends 256 KB without saying how long; `/said` says a gigabyte; anything else is not found.
nonisolated private final class PDFTestServer: @unchecked Sendable {
    let listener: NWListener
    let userAgents = OSAllocatedUnfairLock(initialState: [String]())
    private let queue = DispatchQueue(label: "zigzag.tests.pdf-server")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = queue, userAgents = userAgents
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receive(connection, bytes: Data(), userAgents: userAgents)
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { done in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    done.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    done.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private static func receive(_ connection: NWConnection, bytes: Data, userAgents: OSAllocatedUnfairLock<[String]>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var bytes = bytes
            if let data { bytes.append(data) }
            guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete && error == nil && bytes.count < 65536 { receive(connection, bytes: bytes, userAgents: userAgents) } else { connection.cancel() }
                return
            }
            let lines = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let path = lines.first?.components(separatedBy: " ").dropFirst().first ?? "/"
            let head: String, body: Data
            switch path {
            case "/ua":
                let agent = lines.first { $0.lowercased().hasPrefix("user-agent:") }.map { String($0.dropFirst("User-Agent:".count)).trimmingCharacters(in: .whitespaces) }
                userAgents.withLock { $0.append(agent ?? "") }
                body = Data("%PDF-1.4\nsmall".utf8)
                head = "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            case "/stream":
                body = Data(count: 256 * 1024)
                head = "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nConnection: close\r\n\r\n"
            case "/said":
                body = Data(count: 1024)
                head = "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Length: 1000000000\r\nConnection: close\r\n\r\n"
            default:
                body = Data("not found".utf8)
                head = "HTTP/1.1 404 Not Found\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            }
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
