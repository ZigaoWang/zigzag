import AppKit
import CoreText
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

    @Test @MainActor func aPDFThatBringsTheHelperDownFailsAlone() async throws {
        let good = SafePDF(data: Self.pdf(pages: 2))
        _ = try #require(await good.open())
        var failed = false
        let bad = SafePDF(data: Data("%PDF-ZIGZAG-TEST-CRASH\n".utf8))
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
        let bad = SafePDF(data: Data("%PDF-ZIGZAG-TEST-CRASH\n".utf8)) {
            breaks += 1
            return XPCPDFLink(serviceName: PDFService.name)
        }
        #expect(await bad.open() == nil)
        #expect(bad.hasFailed)
        // One connection, one crash: it isn't sent again to bring the helper down a second time.
        #expect(breaks == 1)
        #expect(await SafePDF(data: Self.pdf()).open() != nil)
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
