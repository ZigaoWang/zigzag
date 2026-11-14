import AppKit
import Testing
@testable import Zigzag

/// Pictures from the web are read by the sandboxed picture helper, never in Zigzag (PDFs: SafePDFTests).
struct SafePicturesTests {
    // MARK: Pictures to read

    static func png(width: Int, height: Int? = nil, _ color: CGColor? = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) -> Data {
        let context = CGContext(data: nil, width: width, height: height ?? width, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let color { context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: width, height: height ?? width)) }
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }

    /// An .ico file holding one PNG picture, as many sites' favicon.ico is.
    static func ico(holding png: Data, side: Int) -> Data {
        var data = Data([0, 0, 1, 0, 1, 0])
        let size = UInt8(side >= 256 ? 0 : side)
        data.append(contentsOf: [size, size, 0, 0, 1, 0, 32, 0])
        withUnsafeBytes(of: UInt32(png.count).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(22).littleEndian) { data.append(contentsOf: $0) }
        data.append(png)
        return data
    }

    static func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 32, height: 32)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static let svg = Data(##"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="24" height="12" viewBox="0 0 24 12"><rect width="24" height="12" fill="#00f"/></svg>"##.utf8)

    // MARK: The kinds read

    @Test func onlyAllowedKindsAreRead() {
        #expect(PictureFormat.sniff(Self.png(width: 4)) == .png)
        #expect(PictureFormat.sniff(Self.ico(holding: Self.png(width: 16), side: 16)) == .ico)
        #expect(PictureFormat.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])) == .jpeg)
        #expect(PictureFormat.sniff(Data("GIF89a\u{1}\0\u{1}\0".utf8)) == .gif)
        #expect(PictureFormat.sniff(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)) == .webp)
        #expect(PictureFormat.sniff(Data("BM\0\0\0\0\0\0\0\0\0\0\0\0".utf8)) == .bmp)
        #expect(PictureFormat.sniff(Self.svg) == .svg)
        #expect(PictureFormat.sniff(Data("\u{FEFF}  <svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)) == .svg)
        // A PDF is never a picture, whatever the site calls it; nor anything else.
        #expect(PictureFormat.sniff(Self.pdf()) == nil)
        #expect(PictureFormat.sniff(Data("%PDF-1.7\n<svg>".utf8)) == nil)
        #expect(PictureFormat.sniff(Data("<html><body>not found</body></html>".utf8)) == nil)
        #expect(PictureFormat.sniff(Data([0, 0, 1, 0, 0, 0])) == nil)
        #expect(PictureFormat.sniff(Data("II*\0".utf8)) == nil)
        #expect(PictureFormat.sniff(Data()) == nil)
        #expect(PictureFormat.sniff(Data(count: PictureFormat.maxInputBytes + 1)) == nil)
    }

    // MARK: The helper

    @Test func aPictureComesBackAsItsPixels() async throws {
        let picture = try #require(await SafePictures.shared.decode(Self.png(width: 64), maxSide: 128))
        #expect(picture.image.width == 64 && picture.image.height == 64)
        #expect(!picture.isVector)
        #expect(picture.nsImage.representations.first?.pixelsWide == 64)
        // Red, as it was sent.
        let bytes = try #require(picture.image.dataProvider?.data as Data?)
        let pixel = Array(bytes[(32 * 64 + 32) * 4..<(32 * 64 + 32) * 4 + 4])
        #expect(pixel[0] > 230 && pixel[1] < 25 && pixel[2] < 25 && pixel[3] == 255, "\(pixel)")
    }

    @Test func aLargePictureIsScaledDown() async throws {
        let picture = try #require(await SafePictures.shared.decode(Self.png(width: 400, height: 200), maxSide: 128))
        #expect(picture.image.width == 128 && picture.image.height == 64)
        // Never past the helper's own limit, whatever is asked.
        let huge = try #require(await SafePictures.shared.decode(Self.png(width: 1500, height: 10), maxSide: 100_000))
        #expect(huge.image.width == PictureFormat.maxSide)
    }

    @Test func anIconFileIsRead() async throws {
        let picture = try #require(await SafePictures.shared.decode(Self.ico(holding: Self.png(width: 32), side: 32), maxSide: 128))
        #expect(picture.image.width == 32)
    }

    @Test func anSVGIsDrawnByTheHelper() async throws {
        let picture = try #require(await SafePictures.shared.decode(Self.svg, maxSide: 64))
        #expect(picture.isVector)
        #expect(picture.size == CGSize(width: 24, height: 12))
        #expect(picture.image.width == 64 && picture.image.height == 32)
    }

    @Test func theHelperTurnsAwayAPDFItself() async {
        // Past Zigzag's own check, straight to the helper: it checks again.
        #expect(await SafePictures.shared.ask(Self.pdf(), maxSide: 64) == nil)
        #expect(await SafePictures.shared.ask(Data("<html>not found</html>".utf8), maxSide: 64) == nil)
        #expect(await SafePictures.shared.decode(Self.pdf(), maxSide: 64) == nil)
        // A PNG's first bytes on a PDF: ImageIO must read the kind the bytes claimed, so it's nothing.
        var disguised = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        disguised.append(Self.pdf())
        #expect(await SafePictures.shared.ask(disguised, maxSide: 64) == nil)
    }

    @Test func manyPicturesAtOnce() async {
        let data = Self.png(width: 16)
        let widths = await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<40 { group.addTask { await SafePictures.shared.decode(data, maxSide: 64)?.image.width } }
            var all: [Int?] = []
            for await width in group { all.append(width) }
            return all
        }
        #expect(widths.count == 40 && widths.allSatisfy { $0 == 16 })
    }

    // MARK: When the helper fails

    @Test func noHelperMeansNoPictureSoon() async {
        let missing = SafePictures(serviceName: "wang.zigao.zigzag.no-such-helper", timeout: 2)
        let start = Date()
        #expect(await missing.decode(Self.png(width: 16), maxSide: 64) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
        // And again: it doesn't stay stuck on the first failure.
        #expect(await missing.decode(Self.png(width: 16), maxSide: 64) == nil)
    }

    @Test func aHelperTooSlowIsLeftAndStartedAfresh() async {
        // No helper answers in no time: nothing comes back, and the next picture gets a new connection that works.
        let hurried = SafePictures(serviceName: PictureService.name, timeout: 0)
        #expect(await hurried.decode(Self.png(width: 16), maxSide: 64) == nil)
        let patient = SafePictures(serviceName: PictureService.name)
        #expect(await patient.decode(Self.png(width: 16), maxSide: 64)?.image.width == 16)
    }

    @Test func aSiteWhoseIconCantBeReadHasNone() async {
        let missing = SafePictures(serviceName: "wang.zigao.zigzag.no-such-helper", timeout: 2)
        // No icon: the sidebar shows the globe.
        #expect(await FaviconStore.decode(Self.png(width: 32), side: 16, using: missing) == nil)
        #expect(await DarkPages.rasterize("data:image/svg+xml;base64," + Self.svg.base64EncodedString(), using: missing) == nil)
        #expect(await WebAppIcon.picture(from: Self.png(width: 128), using: missing) == nil)
    }

    // MARK: A launch's burst of icons

    /// Every tab's icon at once, each a different picture, through the real helper: all of them come back.
    @Test func twoHundredDifferentPicturesAtOnce() async {
        let pictures = SafePictures(serviceName: PictureService.name)
        let inputs = (0..<200).map { i in
            Self.png(width: 16 + i % 32, CGColor(srgbRed: CGFloat(i % 256) / 255, green: CGFloat((i * 7) % 256) / 255, blue: 0.5, alpha: 1))
        }
        let widths = await withTaskGroup(of: (Int, Int?).self) { group in
            for (i, data) in inputs.enumerated() { group.addTask { (i, await pictures.decode(data, maxSide: 64)?.image.width) } }
            var all: [Int: Int?] = [:]
            for await (i, width) in group { all[i] = width }
            return all
        }
        #expect(widths.count == 200)
        #expect((0..<200).allSatisfy { widths[$0] == 16 + $0 % 32 }, "\(widths.filter { $0.value == nil }.count) failed")
    }

    /// A picture helper as the tests run it: one process every connection shares, which answers each picture a
    /// moment later, except a poisoned one. "hang" never answers, and the helper ends itself a while after;
    /// "crash" brings it down at once. Either way every picture in it then hears its connection broke.
    nonisolated final class FakeHelper: @unchecked Sendable {
        static let hang = Data("<svg hang/>".utf8), crash = Data("<svg crash/>".utf8)

        private let lock = NSLock()
        private var pending: [Int: @Sendable () -> Void] = [:]
        private var next = 0
        private var active = 0
        private(set) var peak = 0
        private(set) var links = 0
        private(set) var asked: [Data] = []
        var hangExit: TimeInterval = 0.3
        /// Ends the helper once, as soon as this many pictures are in it.
        var exitWhenActive: Int?

        func makeLink() -> PictureLink { lock.withLock { links += 1 }; return Link(helper: self) }

        final class Link: PictureLink, @unchecked Sendable {
            let helper: FakeHelper
            init(helper: FakeHelper) { self.helper = helper }
            func decode(_ data: Data, maxSide: Int, reply: @escaping @Sendable (DecodedPicture?) -> Void, failed: @escaping @Sendable () -> Void) {
                helper.decode(data, reply: reply, failed: failed)
            }
            func invalidate() {}
        }

        private func decode(_ data: Data, reply: @escaping @Sendable (DecodedPicture?) -> Void, failed: @escaping @Sendable () -> Void) {
            let (id, exitNow) = lock.withLock { () -> (Int, Bool) in
                next += 1
                pending[next] = failed
                active += 1
                peak = max(peak, active)
                asked.append(data)
                let exitNow = exitWhenActive.map { active >= $0 } ?? false
                if exitNow { exitWhenActive = nil }
                return (next, exitNow)
            }
            if exitNow || data == Self.crash { DispatchQueue.global().async { self.exit() }; return }
            if data == Self.hang { DispatchQueue.global().asyncAfter(deadline: .now() + hangExit) { self.exit() }; return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                guard self.lock.withLock({ () -> Bool in
                    guard self.pending.removeValue(forKey: id) != nil else { return false }
                    self.active -= 1
                    return true
                }) else { return }
                reply(DecodedPicture(pixels: Data(count: 4), width: 1, height: 1, pointWidth: 1, pointHeight: 1, isVector: false))
            }
        }

        /// The helper process goes: every picture in it fails.
        func exit() {
            let failing = lock.withLock { () -> [@Sendable () -> Void] in
                defer { pending = [:]; active = 0 }
                return Array(pending.values)
            }
            failing.forEach { $0() }
        }

        func count(_ data: Data) -> Int { lock.withLock { asked.filter { $0 == data }.count } }
    }

    /// Distinct bytes the fake answers: each its own picture as far as the cache can tell.
    private static func icon(_ i: Int) -> Data { Data("<svg id='\(i)'/>".utf8) }

    @Test func noMoreThanFourAtATimeGoToTheHelper() async {
        let helper = FakeHelper()
        let pictures = SafePictures(timeout: 4, makeLink: helper.makeLink)
        let results = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<200 { group.addTask { await pictures.decode(Self.icon(i), maxSide: 16) != nil } }
            var all: [Bool] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.count == 200 && results.allSatisfy { $0 })
        #expect(helper.peak <= 4)
        #expect(helper.links == 1)
    }

    /// A picture that hangs the helper runs out of time alone; the helper ending itself over it fails the others in
    /// it then, and each is asked again on a fresh connection and comes back.
    @Test func aPictureThatHangsTheHelperFailsAlone() async {
        let helper = FakeHelper()
        let pictures = SafePictures(timeout: 0.2, makeLink: helper.makeLink)
        async let poisoned = pictures.decode(FakeHelper.hang, maxSide: 16)
        let others = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<30 { group.addTask { await pictures.decode(Self.icon(i), maxSide: 16) != nil } }
            var all: [Bool] = []
            for await result in group { all.append(result) }
            return all
        }
        let poison = await poisoned
        #expect(poison == nil)
        #expect(others.count == 30 && others.allSatisfy { $0 })
        // Ran out of time, so it isn't asked again.
        #expect(helper.count(FakeHelper.hang) == 1)
    }

    /// A picture that crashes the helper: everything in it then is asked again, once, alone, so the poisoned one
    /// crashes only itself the second time.
    @Test func aPictureThatCrashesTheHelperFailsAlone() async {
        let helper = FakeHelper()
        let pictures = SafePictures(timeout: 4, makeLink: helper.makeLink)
        let results = await withTaskGroup(of: (Int, Bool).self) { group in
            for i in 0..<12 { group.addTask { (i, await pictures.decode(Self.icon(i), maxSide: 16) != nil) } }
            group.addTask { (-1, await pictures.decode(FakeHelper.crash, maxSide: 16) != nil) }
            var all: [Int: Bool] = [:]
            for await (i, ok) in group { all[i] = ok }
            return all
        }
        #expect(results[-1] == false)
        #expect((0..<12).allSatisfy { results[$0] == true })
        #expect(helper.count(FakeHelper.crash) == 2)
    }

    /// The helper going while pictures are in it (it crashed, or ended itself): they're asked again on a fresh
    /// connection rather than all failing.
    @Test func anInterruptedHelperIsAskedAgain() async {
        let helper = FakeHelper()
        helper.exitWhenActive = 4
        let pictures = SafePictures(timeout: 4, makeLink: helper.makeLink)
        let results = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<20 { group.addTask { await pictures.decode(Self.icon(i), maxSide: 16) != nil } }
            var all: [Bool] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.allSatisfy { $0 })
        #expect(helper.links == 2)
    }

    /// What the helper read is kept by the bytes and size, and the same bytes asked twice at once go once. What
    /// failed isn't kept: the next ask tries again.
    @Test func whatWasReadIsKeptAndFailuresAreNot() async {
        let helper = FakeHelper()
        let pictures = SafePictures(timeout: 4, makeLink: helper.makeLink)
        let icon = Self.icon(1)
        async let a = pictures.decode(icon, maxSide: 16)
        async let b = pictures.decode(icon, maxSide: 16)
        let (first, second) = await (a, b)
        #expect(first != nil && second != nil)
        #expect(await pictures.decode(icon, maxSide: 16) != nil)
        #expect(helper.count(icon) == 1)
        // Another size is another picture.
        #expect(await pictures.decode(icon, maxSide: 32) != nil)
        #expect(helper.count(icon) == 2)

        let missing = SafePictures(serviceName: "wang.zigao.zigzag.no-such-helper", timeout: 2)
        if case .unavailable = await missing.read(Self.png(width: 16), maxSide: 16) {} else { Issue.record("not unavailable") }
        // An icon the helper didn't answer for is unavailable, not "no icon", so it's asked for again later.
        let read = await FaviconStore.read(Self.png(width: 16), side: 16, using: missing)
        #expect(read.decoded == nil && read.unavailable)
        // Bytes that aren't a picture at all are a definite no.
        if case .notAPicture = await missing.read(Self.pdf(), maxSide: 16) {} else { Issue.record("not notAPicture") }
    }

    @Test func badPixelsFromTheHelperAreNotTaken() {
        let short = DecodedPicture(pixels: Data(count: 10), width: 4, height: 4, pointWidth: 4, pointHeight: 4, isVector: false)
        #expect(SafePictures.picture(from: short) == nil)
        let big = PictureFormat.maxSide + 1
        let tooBig = DecodedPicture(pixels: Data(count: big * 4), width: big, height: 1, pointWidth: 1, pointHeight: 1, isVector: false)
        #expect(SafePictures.picture(from: tooBig) == nil)
        let right = DecodedPicture(pixels: Data(count: 64), width: 4, height: 4, pointWidth: 4, pointHeight: 4, isVector: false)
        #expect(SafePictures.picture(from: right)?.image.width == 4)
    }

    @Test func aDataURLsBytes() {
        #expect(SafePictures.bytes(ofDataURL: "data:image/png;base64,iVBORw0KGgo=") == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(SafePictures.bytes(ofDataURL: "data:image/svg+xml,%3Csvg%3E") == Data("<svg>".utf8))
        #expect(SafePictures.bytes(ofDataURL: "https://example.com/a.png") == nil)
    }
}
