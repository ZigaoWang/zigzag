import AppKit
import PDFKit

// Zigzag's PDF helper: opens the PDFs Zigzag shows, from the web or your Mac, in the App Sandbox with no network and
// no files, and answers its viewer in plain numbers, strings and pixels (PDFService.swift). Only Zigzag itself can
// reach it: an XPC service bundled in the app is visible to that app alone.
//
// Each connection holds one PDF. A request stuck past its time limit (a PDF made to hang PDFKit) ends the helper;
// Zigzag starts it again, sends the PDFs that were open again, and a PDF that brings it down twice fails alone.

/// One PDF, and the answers about it.
final class Renderer: NSObject, PDFRendering, @unchecked Sendable {
    /// One request at a time for each PDF, in the order asked: PDFKit's document isn't shared between threads here.
    private let queue = DispatchQueue(label: "wang.zigao.zigzag.pdfrenderer.document", qos: .userInitiated)
    private var document: PDFDocument?
    /// Each page's shown size, as `open` measured it.
    private var sizes: [CGSize] = []

    func open(_ data: Data, reply: @escaping @Sendable (RemotePDFInfo?) -> Void) {
        run(PDFLimits.openTime) { [self] in
            document = nil
            sizes = []
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
            Self.draw(page, dark: dark, in: context)
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

    func strings(reply: @escaping @Sendable ([String]?, Bool) -> Void) {
        run(PDFLimits.stringsTime) { [self] in
            guard let document else { reply(nil, false); return }
            reply((0..<sizes.count).map { index in document.page(at: index).map(Self.string(of:)) ?? "" }, true)
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
    /// hue and strength on the new brightness. A diagram's blue box stays blue, only darker.
    static func draw(_ page: PDFPage, dark: Bool, in context: CGContext) {
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
        }
        context.restoreGState()
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
