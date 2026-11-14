import AppKit
import PDFKit

// Zigzag's PDF helper: opens the PDFs Zigzag shows, from the web or your Mac, in the App Sandbox with no network and
// no files, and answers its viewer in plain numbers, strings and pixels (PDFService.swift). Only Zigzag itself can
// reach it: an XPC service bundled in the app is visible to that app alone.
//
// Each connection holds one PDF, until Zigzag lets the connection go. A request stuck past its time limit (a PDF
// made to hang PDFKit) ends the helper; Zigzag starts it again and sends the PDFs that were open again. A PDF that
// brings it down with the helper to itself fails alone; one that shared it is sent alone next time (SafePDF.swift).

/// One PDF, and the answers about it.
final class Renderer: NSObject, PDFRendering, @unchecked Sendable {
    /// One request at a time for each PDF, in the order asked: PDFKit's document isn't shared between threads here.
    private let queue = DispatchQueue(label: "wang.zigao.zigzag.pdfrenderer.document", qos: .userInitiated)
    private var document: PDFDocument?
    /// Each page's shown size, as `open` measured it.
    private var sizes: [CGSize] = []
    /// Where each page asked for dark paints its pictures, found once (`PictureAreas`).
    private var pictures: [Int: [[CGPoint]]] = [:]

    func open(_ data: Data, reply: @escaping @Sendable (RemotePDFInfo?) -> Void) {
        run(PDFLimits.openTime) { [self] in
            document = nil
            sizes = []
            pictures = [:]
            #if DEBUG
            // Tests only: a PDF that brings the helper down, and one that keeps it busy, to see each fail alone.
            if data.starts(with: Data("%PDF-ZIGZAG-TEST-CRASH".utf8)) { exit(1) }
            if data.starts(with: Data("%PDF-ZIGZAG-TEST-SLOW".utf8)) { Thread.sleep(forTimeInterval: 4) }
            #endif
            guard data.count <= PDFLimits.maxInputBytes, Self.looksLikePDF(data),
                  let document = PDFDocument(data: data), !document.isLocked,
                  (1...PDFLimits.maxPages).contains(document.pageCount) else { reply(nil); return }
            var sizes: [CGSize] = []
            sizes.reserveCapacity(document.pageCount)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { reply(nil); return }
                // A form to fill in: Zigzag's viewer only shows its fields, so it's left to WebKit's viewer, where they
                // can be typed into. Declining is how the viewer hands a PDF back.
                if page.annotations.contains(where: { $0.type?.hasSuffix("Widget") == true }) { reply(nil); return }
                let size = Self.shownBox(of: page).size
                let side = 1.0...PDFLimits.maxPageSide
                guard side.contains(size.width), side.contains(size.height) else { reply(nil); return }
                sizes.append(size)
            }
            self.document = document
            self.sizes = sizes
            var packed = Data(capacity: sizes.count * 16)
            for size in sizes {
                withUnsafeBytes(of: Double(size.width)) { packed.append(contentsOf: $0) }
                withUnsafeBytes(of: Double(size.height)) { packed.append(contentsOf: $0) }
            }
            let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
                .map { String($0.prefix(PDFLimits.maxTitle)) }
            reply(RemotePDFInfo(pageCount: sizes.count, sizes: packed, title: title, outline: outline(of: document),
                                allowsCopying: document.allowsCopying))
        }
    }

    func render(page index: Int, x: Double, y: Double, width: Double, height: Double, scale: Double, dark: Bool,
                reply: @escaping @Sendable (RemotePDFTile?, Bool) -> Void) {
        run(PDFLimits.renderTime) { [self] in
            guard let document else { reply(nil, false); return }
            guard sizes.indices.contains(index), let page = document.page(at: index),
                  [x, y, width, height, scale].allSatisfy(\.isFinite), scale > 0, scale <= PDFLimits.maxScale else { reply(nil, true); return }
            let size = sizes[index]
            let rect = CGRect(x: x, y: y, width: width, height: height).intersection(CGRect(origin: .zero, size: size))
            let pixelWidth = Int((rect.width * scale - 0.01).rounded(.up)), pixelHeight = Int((rect.height * scale - 0.01).rounded(.up))
            guard !rect.isNull, (1...PDFLimits.maxTileSide).contains(pixelWidth), (1...PDFLimits.maxTileSide).contains(pixelHeight),
                  pixelWidth * pixelHeight <= PDFLimits.maxTilePixels,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { reply(nil, true); return }
            context.interpolationQuality = .high
            // The page's shown space has y going up from its bottom: the rect's bottom edge is at the bitmap's.
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -rect.minX, y: -(size.height - rect.maxY))
            var kept: [[CGPoint]] = []
            if dark {
                kept = pictures[index] ?? PictureAreas.find(on: page, size: size)
                pictures[index] = kept
            }
            Self.draw(page, dark: dark, keeping: kept, in: context)
            guard let base = context.data else { reply(nil, true); return }
            let tile = RemotePDFTile(pixels: Data(bytes: base, count: pixelWidth * pixelHeight * 4), width: pixelWidth, height: pixelHeight)
            reply(tile.isWellFormed ? tile : nil, true)
        }
    }

    func text(page index: Int, reply: @escaping @Sendable (RemotePageText?, Bool) -> Void) {
        run(PDFLimits.textTime) { [self] in
            guard let document else { reply(nil, false); return }
            guard sizes.indices.contains(index), let page = document.page(at: index) else { reply(nil, true); return }
            let height = sizes[index].height
            let transform = page.transform(for: .cropBox)
            /// From the page's own space to its shown space, y going down.
            func shown(_ rect: CGRect) -> CGRect {
                let up = rect.applying(transform)
                return CGRect(x: up.minX, y: height - up.maxY, width: up.width, height: up.height)
            }
            let string = Self.string(of: page)
            let units = (string as NSString).length
            var boxes = Data(capacity: units * 16)
            for unit in 0..<units {
                // Asked as a selection of that one unit: `characterBounds(at:)` counts without the line breaks the
                // page's string has, and drifts a character further each line.
                let character = (string as NSString).character(at: unit)
                let box = character == 10 || character == 13 ? .null
                    : page.selection(for: NSRange(location: unit, length: 1))?.bounds(for: page) ?? .null
                let rect = box.isNull || box.isInfinite || box.width <= 0 || box.height <= 0 ? .zero : shown(box)
                for value in [rect.minX, rect.minY, rect.width, rect.height] {
                    withUnsafeBytes(of: Float32(value.isFinite ? value : 0)) { boxes.append(contentsOf: $0) }
                }
            }
            var links: [RemoteLink] = []
            for annotation in page.annotations where annotation.type == "Link" {
                guard links.count < PDFLimits.maxLinks else { break }
                let rect = shown(annotation.bounds)
                guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { continue }
                if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
                    links.append(RemoteLink(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
                                            url: String(url.absoluteString.prefix(8192)), page: -1, pageY: .nan))
                } else if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
                          let place = place(of: destination, in: document) {
                    links.append(RemoteLink(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
                                            url: nil, page: place.page, pageY: place.y))
                }
            }
            let text = RemotePageText(string: string, boxes: boxes, links: links)
            reply(text.isWellFormed(pages: sizes.count) ? text : nil, true)
        }
    }

    func strings(reply: @escaping @Sendable (RemotePDFStrings?, Bool) -> Void) {
        run(PDFLimits.stringsTime) { [self] in
            guard let document else { reply(nil, false); return }
            reply(RemotePDFStrings((0..<sizes.count).map { index in document.page(at: index).map(Self.string(of:)) ?? "" }), true)
        }
    }

    // MARK: Reading

    /// Runs a request in its turn. One that takes past `limit` ends the helper: whatever stuck it can't be stopped.
    private func run(_ limit: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        queue.async {
            let done = Flag()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) {
                if !done.isSet { exit(0) }
            }
            autoreleasepool { work() }
            done.set()
        }
    }

    /// A PDF's header within its first kilobyte, as readers allow; anything else isn't read at all.
    static func looksLikePDF(_ data: Data) -> Bool {
        let head = data.prefix(1024)
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    /// The page's crop box, rotated as it's shown, from the origin.
    static func shownBox(of page: PDFPage) -> CGRect {
        let box = page.bounds(for: .cropBox).applying(page.transform(for: .cropBox)).standardized
        return CGRect(origin: .zero, size: box.size)
    }

    /// The page's text, cut at the limit: `text` and `strings` always agree on it.
    static func string(of page: PDFPage) -> String {
        let string = (page.string ?? "") as NSString
        guard string.length > PDFLimits.maxPageText else { return string as String }
        return string.substring(with: string.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: PDFLimits.maxPageText - 8)))
    }

    /// Draws the page on white paper, rotated as it's shown; dark: its brightness flipped against a soft grey (white
    /// paper to #1C1C1E, black ink to #E3E3E3), then drawn again in color blending, which puts back each color's own
    /// hue and strength on the new brightness. A diagram's blue box stays blue, only darker. The pictures in `kept`
    /// (shapes in the page's shown space, from `PictureAreas`) are then drawn again as they are, so a photo is never
    /// a negative.
    static func draw(_ page: PDFPage, dark: Bool, keeping kept: [[CGPoint]] = [], in context: CGContext) {
        let area = context.boundingBoxOfClipPath
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(area)
        page.draw(with: .cropBox, to: context)
        if dark {
            context.setBlendMode(.difference)
            context.setFillColor(CGColor(gray: 0.89, alpha: 1))
            context.fill(area)
            context.setBlendMode(.color)
            page.draw(with: .cropBox, to: context)
            let shown = kept.filter { Self.bounds(of: $0).intersects(area) }
            if !shown.isEmpty {
                context.setBlendMode(.normal)
                context.beginPath()
                for shape in shown {
                    context.addLines(between: shape)
                    context.closePath()
                }
                context.clip()
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(area)
                page.draw(with: .cropBox, to: context)
            }
        }
        context.restoreGState()
    }

    static func bounds(of shape: [CGPoint]) -> CGRect {
        let xs = shape.map(\.x), ys = shape.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Where a destination goes: its page, and how far down the page as shown (NaN for the page's top).
    private func place(of destination: PDFDestination, in document: PDFDocument) -> (page: Int, y: Double)? {
        guard let page = destination.page else { return nil }
        let index = document.index(for: page)
        guard sizes.indices.contains(index) else { return nil }
        let point = destination.point
        guard point.y != kPDFDestinationUnspecifiedValue, point.y.isFinite else { return (index, .nan) }
        let x = point.x == kPDFDestinationUnspecifiedValue || !point.x.isFinite ? 0 : point.x
        let up = CGPoint(x: x, y: point.y).applying(page.transform(for: .cropBox))
        return (index, min(max(sizes[index].height - up.y, 0), sizes[index].height))
    }

    /// The contents, in reading order, each heading with how deep it sits.
    private func outline(of document: PDFDocument) -> [RemoteOutlineEntry] {
        var entries: [RemoteOutlineEntry] = []
        func add(_ item: PDFOutline, level: Int) {
            guard level <= 64 else { return }
            for i in 0..<item.numberOfChildren {
                guard entries.count < PDFLimits.maxOutline, let child = item.child(at: i) else { return }
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                let place = destination.flatMap { self.place(of: $0, in: document) }
                entries.append(RemoteOutlineEntry(title: String((child.label ?? "").prefix(PDFLimits.maxTitle)), level: level,
                                                  page: place?.page ?? -1, y: place?.y ?? .nan))
                add(child, level: level + 1)
            }
        }
        if let root = document.outlineRoot { add(root, level: 0) }
        return entries
    }
}

/// Where a page paints pictures, for dark pages to leave them as they are. Read from the page's own drawing
/// instructions with CGPDFScanner: the transform `q`, `Q` and `cm` build up, and at each image (`Do` of an Image
/// XObject, or an inline `BI`…`EI`, which the scanner hands over at `EI`) the square it fills, through that
/// transform. Form XObjects are read inside, with their `/Matrix`. Stencil masks (`/ImageMask`) paint in the ink's
/// color as text does, so they go dark with it. Each shape is in the page's shown space, y going up from its
/// bottom, as `Renderer.draw` draws.
///
/// A picture over more than `pagePart` of the page is the page itself, a scan, and goes dark with the rest. At most
/// `maxAreas` pictures a page, read for at most `time` seconds (within the render's own limit); a page past either
/// keeps the ones found so far.
nonisolated enum PictureAreas {
    static let maxAreas = 200
    static let time: TimeInterval = 2
    static let pagePart = 0.9
    static let maxFormDepth = 8
    static let maxForms = 500
    static let maxSaved = 1024

    static func find(on page: PDFPage, size: CGSize) -> [[CGPoint]] {
        guard let pageRef = page.pageRef, let table = CGPDFOperatorTableCreate() else { return [] }
        let scan = Scan(shown: page.transform(for: .cropBox), size: size, table: table)
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let scan = Scan.from(info), !scan.isDone else { return }
            if scan.saved.count < PictureAreas.maxSaved { scan.saved.append(scan.ctm) } else { scan.lost += 1 }
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let scan = Scan.from(info), !scan.isDone else { return }
            if scan.lost > 0 { scan.lost -= 1 } else if scan.saved.count > scan.floor { scan.ctm = scan.saved.removeLast() }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let scan = Scan.from(info), !scan.isDone, let matrix = PictureAreas.popMatrix(scanner) else { return }
            scan.ctm = matrix.concatenating(scan.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "EI") { scanner, info in
            guard let scan = Scan.from(info), !scan.isDone else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFScannerPopStream(scanner, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            if !PictureAreas.isMask(dictionary, keys: ["IM", "ImageMask"]) { scan.add() }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let scan = Scan.from(info), !scan.isDone else { return }
            var name: UnsafePointer<CChar>?
            var stream: CGPDFStreamRef?
            var subtype: UnsafePointer<CChar>?
            let content = CGPDFScannerGetContentStream(scanner)
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(content, "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                if !PictureAreas.isMask(dictionary, keys: ["ImageMask"]) { scan.add() }
            case "Form":
                guard scan.depth < PictureAreas.maxFormDepth, scan.forms < PictureAreas.maxForms else { return }
                scan.forms += 1
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array {
                    guard let values = PictureAreas.numbers(array), values.count == 6 else { return }
                    matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
                }
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                // Without resources of its own, a form uses those of whatever draws it: the stream's own dictionary
                // stands in, holding none, and each name is looked for in the parent stream's (`content`) next.
                let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
                let innerScanner = CGPDFScannerCreate(inner, scan.table, info)
                // A form draws inside its own `q`…`Q`: what it leaves saved, or tries to restore past, is its own.
                let (ctm, saved, floor, lost) = (scan.ctm, scan.saved, scan.floor, scan.lost)
                scan.ctm = matrix.concatenating(ctm)
                scan.floor = saved.count
                scan.lost = 0
                scan.depth += 1
                _ = CGPDFScannerScan(innerScanner)
                scan.depth -= 1
                (scan.ctm, scan.saved, scan.floor, scan.lost) = (ctm, saved, floor, lost)
            default:
                return
            }
        }
        let content = CGPDFContentStreamCreateWithPage(pageRef)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(scan).toOpaque())
        _ = CGPDFScannerScan(scanner)
        return withExtendedLifetime(scan) { scan.shapes }
    }

    /// `a b c d e f cm`: the operands come off the stack last first.
    private static func popMatrix(_ scanner: CGPDFScannerRef) -> CGAffineTransform? {
        var values = [CGPDFReal](repeating: 0, count: 6)
        for i in (0..<6).reversed() {
            guard CGPDFScannerPopNumber(scanner, &values[i]), values[i].isFinite else { return nil }
        }
        return CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
    }

    private static func numbers(_ array: CGPDFArrayRef) -> [CGFloat]? {
        let count = CGPDFArrayGetCount(array)
        guard count <= 6 else { return nil }
        var values = [CGPDFReal](repeating: 0, count: count)
        for i in 0..<count {
            guard CGPDFArrayGetNumber(array, i, &values[i]), values[i].isFinite else { return nil }
        }
        return values
    }

    private static func isMask(_ dictionary: CGPDFDictionaryRef, keys: [String]) -> Bool {
        keys.contains { key in
            var value: CGPDFBoolean = 0
            return CGPDFDictionaryGetBoolean(dictionary, key, &value) && value != 0
        }
    }

    private final class Scan {
        let shown: CGAffineTransform
        let page: CGRect
        let table: CGPDFOperatorTableRef
        let deadline = CFAbsoluteTimeGetCurrent() + PictureAreas.time
        var ctm = CGAffineTransform.identity
        var saved: [CGAffineTransform] = []
        /// How deep `saved` was as the form being read began: it can't restore past that.
        var floor = 0
        /// `q`s past `maxSaved`, which their `Q`s answer without restoring anything.
        var lost = 0
        var depth = 0
        var forms = 0
        var shapes: [[CGPoint]] = []

        init(shown: CGAffineTransform, size: CGSize, table: CGPDFOperatorTableRef) {
            self.shown = shown
            page = CGRect(origin: .zero, size: size)
            self.table = table
        }

        static func from(_ info: UnsafeMutableRawPointer?) -> Scan? {
            info.map { Unmanaged<Scan>.fromOpaque($0).takeUnretainedValue() }
        }

        var isDone: Bool { shapes.count >= PictureAreas.maxAreas || CFAbsoluteTimeGetCurrent() > deadline }

        /// The unit square an image fills, as the page is shown, unless it's (nearly) the whole page or nothing.
        func add() {
            let transform = ctm.concatenating(shown)
            var shape = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { $0.applying(transform) }
            guard shape.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
            let seen = Renderer.bounds(of: shape).intersection(page)
            guard !seen.isNull, seen.width * seen.height >= 1,
                  seen.width * seen.height <= PictureAreas.pagePart * page.width * page.height else { return }
            // All one way round, so overlapping pictures add up under the nonzero rule instead of cutting holes.
            if transform.a * transform.d - transform.b * transform.c < 0 { shape.reverse() }
            shapes.append(shape)
        }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = PDFService.interface()
        connection.exportedObject = Renderer()
        connection.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
