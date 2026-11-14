import AppKit

/// A PDF read by the sandboxed PDF helper (ZigzagPDFRenderer), never in Zigzag: the PDF viewer draws everything from
/// what this hands back. Zigzag holds the PDF's bytes only to send them there and to save them as they came.
///
/// Each PDF has its own connection, and the helper keeps it open there. The helper is one process for all of them,
/// so when it goes (it crashed, or ended itself over a request stuck in it) every PDF in it is sent again. A PDF
/// that had the helper to itself then is what brought it down, and fails. One that shared it with another PDF's
/// request is a suspect: its next requests go alone, with nothing else in the helper, and if the helper goes again
/// while one of them is in it, that PDF fails. A request past its time limit fails its PDF at once. A PDF that fails
/// asks nothing more; its viewer gives way to WebKit's (`onFail`).
@MainActor
final class SafePDF {
    nonisolated struct Info: @unchecked Sendable {
        let pageSizes: [CGSize]
        let title: String?
        let outline: [OutlineItem]
        let allowsCopying: Bool
    }

    nonisolated struct OutlineItem: @unchecked Sendable {
        let title: String
        let level: Int
        /// The page it goes to, and how far down that page (nil: its top).
        let page: Int?
        let y: CGFloat?
    }

    /// A page's text: each UTF-16 unit's box on the page (zero for a space with no place), and its links.
    nonisolated struct PageText: @unchecked Sendable {
        let string: NSString
        let boxes: [CGRect]
        let links: [Link]
    }

    nonisolated struct Link: @unchecked Sendable {
        let rect: CGRect
        let url: URL?
        let page: Int?
        let y: CGFloat?
    }

    static let maxInputBytes = PDFLimits.maxInputBytes

    let data: Data
    private(set) var info: Info?
    /// Once true, nothing more is asked: the helper couldn't read it, crashed on it twice, or took too long.
    private(set) var hasFailed = false
    var onFail: (() -> Void)?

    /// How much of each request's time limit in the helper Zigzag waits, and a little more: the helper ends itself
    /// first. Tests make it shorter.
    private let timeScale: Double
    private let makeLink: () -> PDFLink
    private var link: PDFLink?
    /// The helper holds this PDF (`open` answered since it last started).
    private var isOpen = false
    private var opening: Task<Bool, Never>?
    private var isSuspect = false

    /// Turns in the helper, shared by every PDF: a request takes one, a suspect's all of them.
    nonisolated static let turns = 6
    nonisolated private static let slots = Slots(turns)

    convenience init(data: Data, serviceName: String = PDFService.name, timeScale: Double = 1) {
        self.init(data: data, timeScale: timeScale) { XPCPDFLink(serviceName: serviceName) }
    }

    init(data: Data, timeScale: Double = 1, makeLink: @escaping () -> PDFLink) {
        self.data = data
        self.timeScale = timeScale
        self.makeLink = makeLink
    }

    // No deinit: the connection holds nothing back; it goes with this object, and the helper lets the PDF go.

    // MARK: Asking

    /// Opens the PDF in the helper. Nil when it can't be read there (not a PDF, locked, past the limits, or the
    /// helper failed on it): WebKit's viewer shows it instead.
    func open() async -> Info? {
        if let info { return info }
        guard data.count <= Self.maxInputBytes, !hasFailed, await reopen() else { return nil }
        return info
    }

    /// A picture of `rect` (in the page's points as shown) at `scale` pixels a point, or nil.
    func render(page: Int, rect: CGRect, scale: CGFloat, dark: Bool) async -> CGImage? {
        let width = Int((rect.width * scale).rounded(.up)), height = Int((rect.height * scale).rounded(.up))
        let tile: RemotePDFTile? = await ask(PDFLimits.renderTime) { proxy, reply in
            proxy.render(page: page, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, scale: scale, dark: dark, reply: reply)
        }
        // At most the size asked for (a pixel more for rounding), checked before it's taken as pixels.
        guard let tile, tile.isWellFormed, tile.width <= width + 1, tile.height <= height + 1 else { return nil }
        return Self.image(from: tile)
    }

    func text(page: Int) async -> PageText? {
        guard let info, info.pageSizes.indices.contains(page) else { return nil }
        let text: RemotePageText? = await ask(PDFLimits.textTime) { proxy, reply in proxy.text(page: page, reply: reply) }
        guard let text, text.isWellFormed(pages: info.pageSizes.count) else { return nil }
        return Self.pageText(from: text)
    }

    /// Every page's text, for find.
    func strings() async -> [String]? {
        guard let info else { return nil }
        let strings: [String]? = await ask(PDFLimits.stringsTime) { proxy, reply in proxy.strings(reply: reply) }
        guard let strings, strings.count == info.pageSizes.count,
              strings.allSatisfy({ ($0 as NSString).length <= PDFLimits.maxPageText }) else { return nil }
        return strings
    }

    // MARK: Taking the answers

    /// The helper's pixels as an image. Nothing here decodes anything.
    nonisolated static func image(from tile: RemotePDFTile) -> CGImage? {
        guard tile.isWellFormed, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: tile.pixels as CFData) else { return nil }
        return CGImage(width: tile.width, height: tile.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tile.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    nonisolated static func info(from remote: RemotePDFInfo) -> Info? {
        guard remote.isWellFormed else { return nil }
        let outline = remote.outline.map {
            OutlineItem(title: $0.title, level: $0.level, page: $0.page >= 0 ? $0.page : nil, y: $0.y.isNaN ? nil : $0.y)
        }
        let title = remote.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Info(pageSizes: remote.pageSizes, title: title?.isEmpty == false ? title : nil, outline: outline, allowsCopying: remote.allowsCopying)
    }

    nonisolated static func pageText(from remote: RemotePageText) -> PageText {
        let boxes: [CGRect] = remote.boxes.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Float32.self)
            return stride(from: 0, to: values.count - 3, by: 4).map {
                CGRect(x: CGFloat(values[$0]), y: CGFloat(values[$0 + 1]), width: CGFloat(values[$0 + 2]), height: CGFloat(values[$0 + 3]))
            }
        }
        let links = remote.links.compactMap { link -> Link? in
            let url = link.url.flatMap(URL.init(string:))
            guard url != nil || link.page >= 0 else { return nil }
            return Link(rect: CGRect(x: link.x, y: link.y, width: link.width, height: link.height), url: url,
                        page: url == nil ? link.page : nil, y: link.pageY.isNaN ? nil : link.pageY)
        }
        return PageText(string: remote.string as NSString, boxes: boxes, links: links)
    }

    // MARK: The helper

    /// The PDF sent to the helper (again, if it started afresh since); the same sending shared by everyone waiting.
    private func reopen() async -> Bool {
        if isOpen { return true }
        if let opening { return await opening.value }
        let task = Task { @MainActor [self] () -> Bool in
            let data = self.data
            let remote: RemotePDFInfo? = await ask(PDFLimits.openTime, opens: true) { proxy, reply in
                proxy.open(data) { reply($0, true) }
            }
            guard let remote, let info = Self.info(from: remote),
                  self.info == nil || self.info?.pageSizes == info.pageSizes else {
                fail()
                return false
            }
            self.info = info
            isOpen = true
            return true
        }
        opening = task
        let opened = await task.value
        opening = nil
        return opened
    }

    private enum Outcome<T: Sendable>: Sendable {
        /// The helper's answer, and whether it still had the PDF.
        case answered(T?, held: Bool)
        case broken
        case timedOut
    }

    /// One request, in its turn. Opens the PDF in the helper first when it isn't there.
    private func ask<T: Sendable>(_ limit: TimeInterval, opens: Bool = false,
                                  _ request: @escaping @Sendable (PDFRendering, @escaping @Sendable (T?, Bool) -> Void) -> Void) async -> T? {
        for _ in 0..<3 {
            guard !hasFailed else { return nil }
            if !opens, !isOpen { guard await reopen() else { return nil } }
            let alone = isSuspect
            let weight = alone ? Self.turns : 1
            await Self.slots.acquire(weight)
            let turn = Turn(self)
            let outcome = await send(limit, request)
            turn.end()
            Self.slots.release(weight)
            switch outcome {
            case .answered(let value, let held):
                if alone { isSuspect = false }
                // The helper started afresh since the PDF was sent: again, once it has it.
                guard held else { isOpen = false; continue }
                return value
            case .broken:
                isOpen = false
                // The helper went while this PDF was in it alone: it's what brings it down. Failing it at once also
                // spares the helper a second start soon after the first, which the system holds back for seconds.
                if alone || !turn.sharedTheHelper { fail(); return nil }
                isSuspect = true
            case .timedOut:
                fail()
                return nil
            }
        }
        return nil
    }

    private func send<T: Sendable>(_ limit: TimeInterval,
                                   _ request: @escaping @Sendable (PDFRendering, @escaping @Sendable (T?, Bool) -> Void) -> Void) async -> Outcome<T> {
        let link = currentLink()
        let once = AnswerOnce()
        let wait = limit * timeScale + (timeScale < 1 ? 0 : 3)
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
            let finish: @Sendable (Outcome<T>) -> Void = { outcome in
                if once.claim() { continuation.resume(returning: outcome) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait) { finish(.timedOut) }
            link.send({ proxy in request(proxy) { value, held in finish(.answered(value, held: held)) } }, failed: { finish(.broken) })
        }
        if case .broken = outcome { drop(link) }
        return outcome
    }

    private func currentLink() -> PDFLink {
        if let link { return link }
        let made = makeLink()
        link = made
        return made
    }

    /// A connection that broke goes; the next request makes a fresh one, which starts the helper again.
    private func drop(_ broken: PDFLink) {
        guard link === broken else { return }
        link = nil
        broken.invalidate()
    }

    private func fail() {
        guard !hasFailed else { return }
        hasFailed = true
        isOpen = false
        link?.invalidate()
        link = nil
        onFail?()
    }
}

/// A request in the helper, and whether another PDF had one there at any time while it was: when the helper goes,
/// one that had it to itself is what brought it down.
@MainActor
private final class Turn {
    private static var open: [Turn] = []
    private let owner: ObjectIdentifier
    private(set) var sharedTheHelper = false

    init(_ document: SafePDF) {
        owner = ObjectIdentifier(document)
        for other in Self.open where other.owner != owner {
            other.sharedTheHelper = true
            sharedTheHelper = true
        }
        Self.open.append(self)
    }

    func end() { Self.open.removeAll { $0 === self } }
}

/// One connection to the PDF helper. `failed` is called when it breaks before the answer comes.
nonisolated protocol PDFLink: AnyObject, Sendable {
    func send(_ request: @escaping @Sendable (PDFRendering) -> Void, failed: @escaping @Sendable () -> Void)
    func invalidate()
}

/// The helper over XPC.
nonisolated final class XPCPDFLink: PDFLink, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(serviceName: String) {
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = PDFService.interface()
        connection.resume()
    }

    func send(_ request: @escaping @Sendable (PDFRendering) -> Void, failed: @escaping @Sendable () -> Void) {
        // Interrupted (the helper crashed or ended itself) or invalid (it can't be found): every request waiting on
        // it hears so here.
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in failed() }) as? PDFRendering else { failed(); return }
        request(proxy)
    }

    func invalidate() { connection.invalidate() }
}

/// True for the first caller only.
nonisolated private final class AnswerOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }
}
