import Foundation

// What Zigzag and its PDF helper (ZigzagPDFRenderer.xpc) say to each other. This file is built into both.
//
// A PDF is read by the helper, never by Zigzag: it runs in the App Sandbox with no network and no files, so a PDF
// made to break PDFKit or CoreGraphics breaks only the helper. Zigzag sends the PDF's bytes once, then asks for what
// its viewer draws: the pages' sizes, pictures of parts of pages, each page's text with where each character is,
// its links, and the contents. All of it comes back as plain numbers, strings and pixels, checked on arrival
// (`isWellFormed`), with nothing left for Zigzag to parse.
//
// Places on a page are in the page's own points as it's shown: rotated as the PDF says, its origin at the top left,
// y going down.

/// The helper's requests, for the one PDF each connection holds. Each reply's last value says whether the helper
/// has the PDF at all: false when it started afresh since (`open` again, then ask again).
@objc(ZigzagPDFRendering) nonisolated protocol PDFRendering {
    /// Reads the PDF. Nil when it isn't one, is empty, is locked with a password, or is past the limits.
    func open(_ data: Data, reply: @escaping @Sendable (RemotePDFInfo?) -> Void)
    /// A picture of `rect` (in the page's points) on page `page`, `scale` pixels to a point.
    func render(page: Int, x: Double, y: Double, width: Double, height: Double, scale: Double, dark: Bool,
                reply: @escaping @Sendable (RemotePDFTile?, Bool) -> Void)
    /// A page's text, where each of its characters is, and its links.
    func text(page: Int, reply: @escaping @Sendable (RemotePageText?, Bool) -> Void)
    /// Every page's text, without positions: what find searches.
    func strings(reply: @escaping @Sendable ([String]?, Bool) -> Void)
}

nonisolated enum PDFService {
    /// The helper's bundle identifier, which is also its service name.
    static let name = "wang.zigao.zigzag.pdfrenderer"

    /// The interface both ends use: each reply may carry its own class and nothing else.
    static func interface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: PDFRendering.self)
        func allow(_ classes: [AnyClass], _ selector: Selector) {
            interface.setClasses(NSSet(array: classes) as! Set<AnyHashable>, for: selector, argumentIndex: 0, ofReply: true)
        }
        allow([RemotePDFInfo.self, RemoteOutlineEntry.self, NSArray.self, NSString.self, NSData.self], #selector(PDFRendering.open(_:reply:)))
        allow([RemotePDFTile.self, NSData.self], #selector(PDFRendering.render(page:x:y:width:height:scale:dark:reply:)))
        allow([RemotePageText.self, RemoteLink.self, NSArray.self, NSString.self, NSData.self], #selector(PDFRendering.text(page:reply:)))
        allow([NSArray.self, NSString.self], #selector(PDFRendering.strings(reply:)))
        return interface
    }
}

/// What the helper may be sent and send back, and how long each request may take there.
nonisolated enum PDFLimits {
    static let maxInputBytes = 512 * 1024 * 1024
    static let maxPages = 20_000
    /// A page's own size, in points, either way: past PDF's own limit is no page.
    static let maxPageSide = 14_400.0
    /// A picture is at most this many pixels across, and this many in all.
    static let maxTileSide = 4096
    static let maxTilePixels = 4096 * 4096
    static let maxScale = 16.0
    static let maxPageText = 500_000
    static let maxLinks = 5_000
    static let maxOutline = 10_000
    static let maxTitle = 1_000

    /// Seconds each request may run in the helper before it ends itself.
    static let openTime: TimeInterval = 20
    static let renderTime: TimeInterval = 12
    static let textTime: TimeInterval = 12
    static let stringsTime: TimeInterval = 40
}

/// The PDF as a whole.
@objc(ZigzagRemotePDFInfo) nonisolated final class RemotePDFInfo: NSObject, NSSecureCoding, @unchecked Sendable {
    let pageCount: Int
    /// Each page's shown size, width then height, as Float64s.
    let sizes: Data
    let title: String?
    let outline: [RemoteOutlineEntry]
    /// The PDF lets its text be copied.
    let allowsCopying: Bool

    init(pageCount: Int, sizes: Data, title: String?, outline: [RemoteOutlineEntry], allowsCopying: Bool) {
        self.pageCount = pageCount
        self.sizes = sizes
        self.title = title
        self.outline = outline
        self.allowsCopying = allowsCopying
    }

    static var supportsSecureCoding: Bool { true }

    func encode(with coder: NSCoder) {
        coder.encode(pageCount, forKey: "pageCount")
        coder.encode(sizes as NSData, forKey: "sizes")
        coder.encode(title as NSString?, forKey: "title")
        coder.encode(outline as NSArray, forKey: "outline")
        coder.encode(allowsCopying, forKey: "allowsCopying")
    }

    init?(coder: NSCoder) {
        guard let sizes = coder.decodeObject(of: NSData.self, forKey: "sizes") as Data?,
              let outline = coder.decodeObject(of: [NSArray.self, RemoteOutlineEntry.self], forKey: "outline") as? [RemoteOutlineEntry] else { return nil }
        pageCount = coder.decodeInteger(forKey: "pageCount")
        self.sizes = sizes
        title = coder.decodeObject(of: NSString.self, forKey: "title") as String?
        self.outline = outline
        allowsCopying = coder.decodeBool(forKey: "allowsCopying")
    }

    /// The pages' sizes, read from `sizes`.
    var pageSizes: [CGSize] {
        sizes.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Double.self)
            return stride(from: 0, to: values.count - 1, by: 2).map { CGSize(width: values[$0], height: values[$0 + 1]) }
        }
    }

    var isWellFormed: Bool { checkedPageSizes() != nil }

    /// The pages' sizes, read once, if everything sent is within the limits; nil otherwise.
    func checkedPageSizes() -> [CGSize]? {
        guard (1...PDFLimits.maxPages).contains(pageCount), sizes.count == pageCount * 16,
              outline.count <= PDFLimits.maxOutline, (title?.count ?? 0) <= PDFLimits.maxTitle else { return nil }
        let side = 1.0...PDFLimits.maxPageSide
        let pageSizes = self.pageSizes
        guard pageSizes.allSatisfy({ side.contains($0.width) && side.contains($0.height) }),
              outline.allSatisfy({ $0.isWellFormed(pages: pageCount) }) else { return nil }
        return pageSizes
    }
}

/// One heading of the contents, in order, with how deep it sits.
@objc(ZigzagRemoteOutlineEntry) nonisolated final class RemoteOutlineEntry: NSObject, NSSecureCoding, @unchecked Sendable {
    let title: String
    let level: Int
    /// The page it goes to, or -1; and how far down it, or NaN for its top.
    let page: Int
    let y: Double

    init(title: String, level: Int, page: Int, y: Double) {
        self.title = title
        self.level = level
        self.page = page
        self.y = y
    }

    static var supportsSecureCoding: Bool { true }

    func encode(with coder: NSCoder) {
        coder.encode(title as NSString, forKey: "title")
        coder.encode(level, forKey: "level")
        coder.encode(page, forKey: "page")
        coder.encode(y, forKey: "y")
    }

    init?(coder: NSCoder) {
        guard let title = coder.decodeObject(of: NSString.self, forKey: "title") as String? else { return nil }
        self.title = title
        level = coder.decodeInteger(forKey: "level")
        page = coder.decodeInteger(forKey: "page")
        y = coder.decodeDouble(forKey: "y")
    }

    func isWellFormed(pages: Int) -> Bool {
        title.count <= PDFLimits.maxTitle && (0...64).contains(level) && (-1..<pages).contains(page) && (y.isNaN || y.isFinite)
    }
}

/// Part of a page as plain pixels: 8-bit RGBA, premultiplied, sRGB, rows top to bottom with no padding.
@objc(ZigzagRemotePDFTile) nonisolated final class RemotePDFTile: NSObject, NSSecureCoding, @unchecked Sendable {
    let pixels: Data
    let width: Int
    let height: Int

    init(pixels: Data, width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    static var supportsSecureCoding: Bool { true }

    func encode(with coder: NSCoder) {
        coder.encode(pixels as NSData, forKey: "pixels")
        coder.encode(width, forKey: "width")
        coder.encode(height, forKey: "height")
    }

    init?(coder: NSCoder) {
        guard let pixels = coder.decodeObject(of: NSData.self, forKey: "pixels") as Data? else { return nil }
        self.pixels = pixels
        width = coder.decodeInteger(forKey: "width")
        height = coder.decodeInteger(forKey: "height")
    }

    var isWellFormed: Bool {
        (1...PDFLimits.maxTileSide).contains(width) && (1...PDFLimits.maxTileSide).contains(height)
            && width * height <= PDFLimits.maxTilePixels && pixels.count == width * height * 4
    }
}

/// A page's text: the string, each of its UTF-16 units' box (x, y, width, height as Float32s; empty for a space
/// the PDF doesn't place), and its links.
@objc(ZigzagRemotePageText) nonisolated final class RemotePageText: NSObject, NSSecureCoding, @unchecked Sendable {
    let string: String
    let boxes: Data
    let links: [RemoteLink]

    init(string: String, boxes: Data, links: [RemoteLink]) {
        self.string = string
        self.boxes = boxes
        self.links = links
    }

    static var supportsSecureCoding: Bool { true }

    func encode(with coder: NSCoder) {
        coder.encode(string as NSString, forKey: "string")
        coder.encode(boxes as NSData, forKey: "boxes")
        coder.encode(links as NSArray, forKey: "links")
    }

    init?(coder: NSCoder) {
        guard let string = coder.decodeObject(of: NSString.self, forKey: "string") as String?,
              let boxes = coder.decodeObject(of: NSData.self, forKey: "boxes") as Data?,
              let links = coder.decodeObject(of: [NSArray.self, RemoteLink.self], forKey: "links") as? [RemoteLink] else { return nil }
        self.string = string
        self.boxes = boxes
        self.links = links
    }

    func isWellFormed(pages: Int) -> Bool {
        let units = (string as NSString).length
        guard units <= PDFLimits.maxPageText, boxes.count == units * 16, links.count <= PDFLimits.maxLinks,
              links.allSatisfy({ $0.isWellFormed(pages: pages) }) else { return false }
        // Every box a real place: NaN or infinity would reach the layers that mark text, which refuse them.
        return boxes.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Float32.self)
            return stride(from: 0, to: values.count, by: 4).allSatisfy { index in
                values[index].isFinite && values[index + 1].isFinite && values[index + 2].isFinite && values[index + 3].isFinite
                    && values[index + 2] >= 0 && values[index + 3] >= 0
            }
        }
    }
}

/// A link on a page: where it is, and a web address or a place in the PDF (page, and how far down it or NaN).
@objc(ZigzagRemoteLink) nonisolated final class RemoteLink: NSObject, NSSecureCoding, @unchecked Sendable {
    let x: Double, y: Double, width: Double, height: Double
    let url: String?
    let page: Int
    let pageY: Double

    init(x: Double, y: Double, width: Double, height: Double, url: String?, page: Int, pageY: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.url = url
        self.page = page
        self.pageY = pageY
    }

    static var supportsSecureCoding: Bool { true }

    func encode(with coder: NSCoder) {
        coder.encode(x, forKey: "x")
        coder.encode(y, forKey: "y")
        coder.encode(width, forKey: "width")
        coder.encode(height, forKey: "height")
        coder.encode(url as NSString?, forKey: "url")
        coder.encode(page, forKey: "page")
        coder.encode(pageY, forKey: "pageY")
    }

    init?(coder: NSCoder) {
        x = coder.decodeDouble(forKey: "x")
        y = coder.decodeDouble(forKey: "y")
        width = coder.decodeDouble(forKey: "width")
        height = coder.decodeDouble(forKey: "height")
        url = coder.decodeObject(of: NSString.self, forKey: "url") as String?
        page = coder.decodeInteger(forKey: "page")
        pageY = coder.decodeDouble(forKey: "pageY")
    }

    func isWellFormed(pages: Int) -> Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width >= 0 && height >= 0 && (url?.utf8.count ?? 0) <= 8192
            && (-1..<pages).contains(page) && (pageY.isNaN || pageY.isFinite) && (url != nil || page >= 0)
    }
}
