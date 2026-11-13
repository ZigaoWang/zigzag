import Foundation

// What Zigzag and its picture helper (ZigzagImageDecoder.xpc) say to each other. This file is built into both.
//
// Pictures a website sends (site icons, home-screen and app icons, the store's extension icons, the SVGs Dark Pages
// looks at) are read by the helper, never by Zigzag: it runs in the App Sandbox with no network and no files, so a
// picture made to break the system's image decoders breaks only the helper. It sends back plain pixels, which Zigzag
// takes as they are, with nothing left to decode.

/// The helper's one request: read a picture, at most `maxSide` pixels across, and reply with its pixels, or nil.
@objc(ZigzagPictureDecoding) nonisolated protocol PictureDecoding {
    func decode(_ data: Data, maxSide: Int, reply: @escaping @Sendable (DecodedPicture?) -> Void)
}

nonisolated enum PictureService {
    /// The helper's bundle identifier, which is also its service name.
    static let name = "wang.zigao.zigzag.imagedecoder"

    /// The interface both ends use: the reply may carry a `DecodedPicture` and nothing else.
    static func interface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: PictureDecoding.self)
        interface.setClasses(NSSet(object: DecodedPicture.self) as! Set<AnyHashable>, for: #selector(PictureDecoding.decode(_:maxSide:reply:)), argumentIndex: 0, ofReply: true)
        return interface
    }
}

/// A picture as plain pixels: 8-bit RGBA, premultiplied, sRGB, rows top to bottom with no padding.
@objc(ZigzagDecodedPicture) nonisolated final class DecodedPicture: NSObject, NSSecureCoding, @unchecked Sendable {
    let pixels: Data
    let width: Int
    let height: Int
    /// Its own size: the pixels for a bitmap, the size an SVG says it is (drawn at most `maxSide` across).
    let pointWidth: Double
    let pointHeight: Double
    /// An SVG, drawn for the size asked rather than at pixels of its own.
    let isVector: Bool

    init(pixels: Data, width: Int, height: Int, pointWidth: Double, pointHeight: Double, isVector: Bool) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.isVector = isVector
    }

    static var supportsSecureCoding: Bool { true }

    func encode(with coder: NSCoder) {
        coder.encode(pixels as NSData, forKey: "pixels")
        coder.encode(width, forKey: "width")
        coder.encode(height, forKey: "height")
        coder.encode(pointWidth, forKey: "pointWidth")
        coder.encode(pointHeight, forKey: "pointHeight")
        coder.encode(isVector, forKey: "isVector")
    }

    init?(coder: NSCoder) {
        guard let pixels = coder.decodeObject(of: NSData.self, forKey: "pixels") as Data? else { return nil }
        self.pixels = pixels
        width = coder.decodeInteger(forKey: "width")
        height = coder.decodeInteger(forKey: "height")
        pointWidth = coder.decodeDouble(forKey: "pointWidth")
        pointHeight = coder.decodeDouble(forKey: "pointHeight")
        isVector = coder.decodeBool(forKey: "isVector")
    }

    /// Whether the pixels are what they say: a size within the limit and exactly that many bytes.
    var isWellFormed: Bool {
        (1...PictureFormat.maxSide).contains(width) && (1...PictureFormat.maxSide).contains(height)
            && pixels.count == width * height * 4 && pointWidth.isFinite && pointHeight.isFinite && pointWidth > 0 && pointHeight > 0
    }
}

/// The kinds of picture the helper reads, told by their first bytes (never by what the site says they are). Anything
/// else, a PDF above all, is turned away before any decoder sees it.
nonisolated enum PictureFormat: String, CaseIterable, Sendable {
    case png, jpeg, gif, ico, bmp, webp, svg

    /// The most a request may send, and the most pixels across a reply may have.
    static let maxInputBytes = 8 * 1024 * 1024
    static let maxSide = 1024
    /// The largest bitmap read at all: past this a picture is too big to be an icon, and too big to decode safely.
    static let maxSourcePixels = 4096 * 4096

    /// The type ImageIO must find in the data too; nil for SVG, which ImageIO doesn't read.
    var imageIOType: String? {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .gif: "com.compuserve.gif"
        case .ico: "com.microsoft.ico"
        case .bmp: "com.microsoft.bmp"
        case .webp: "org.webmproject.webp"
        case .svg: nil
        }
    }

    static func sniff(_ data: Data) -> PictureFormat? {
        guard !data.isEmpty, data.count <= maxInputBytes else { return nil }
        let head = [UInt8](data.prefix(16))
        func starts(_ bytes: [UInt8]) -> Bool { head.count >= bytes.count && Array(head.prefix(bytes.count)) == bytes }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return .gif }
        // An icon file with at least one picture in it.
        if head.count >= 6, starts([0x00, 0x00, 0x01, 0x00]), head[4] | head[5] != 0 { return .ico }
        if head.count >= 12, starts(Array("RIFF".utf8)), Array(head[8..<12]) == Array("WEBP".utf8) { return .webp }
        if head.count >= 14, starts(Array("BM".utf8)) { return .bmp }
        if isSVG(data) { return .svg }
        return nil
    }

    /// SVG is text: an `<svg` element near the start, after at most an XML declaration, comments and a doctype.
    private static func isSVG(_ data: Data) -> Bool {
        var bytes = data.prefix(4096)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        // Cut at 4 KB, the last character may be split: decoded leniently.
        let text = String(decoding: bytes, as: UTF8.self)
        let trimmed = text.drop { $0.isWhitespace }
        guard trimmed.hasPrefix("<") else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<svg") { return true }
        return (lower.hasPrefix("<?xml") || lower.hasPrefix("<!--") || lower.hasPrefix("<!doctype svg")) && lower.contains("<svg")
    }
}
