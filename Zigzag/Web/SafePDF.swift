import AppKit
import CryptoKit

/// A PDF read by the sandboxed PDF helper (ZigzagPDFRenderer), never in Zigzag: the PDF viewer draws everything from
/// what this hands back. Zigzag holds the PDF's bytes only to send them there and to save them as they came.
///
/// Each PDF has its own connection, and the helper keeps it open there. The helper is one process for all of them,
/// so when it goes (it crashed, or ended itself over a request stuck in it) every PDF in it is sent again. A PDF
/// that had the helper to itself then is what brought it down, and fails. One that shared it with another PDF's
/// request is a suspect: its next requests go alone, with nothing else in the helper, and if the helper goes again
/// while one of them is in it, that PDF fails. A request past its time limit fails its PDF at once. A PDF that fails
/// asks nothing more; its viewer gives way to WebKit's (`onFail`). One that crashed the helper, or stalled it, is
/// remembered for the rest of the session, by its bytes and by where it came from: opened again (a page reloading
/// it), it fails at once instead of bringing the helper down again.
///
/// The helper answers one request at a time for each PDF, so each PDF has one request there at a time too, the rest
/// waiting here (`Gate`): a request's clock then runs only while the helper works on it, never while it waits behind
/// a long find. Pictures go before a page's text, and that before every page's text for find.
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
    /// Where the PDF came from, to remember it by if it brings the helper down.
    let source: URL?
    /// Once true, nothing more is asked: the helper couldn't read it, crashed on it, or took too long.
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
    private let gate = Gate()

    /// Turns in the helper, shared by every PDF: a request takes one, a suspect's all of them.
    nonisolated static let turns = 6
    nonisolated private static let slots = Slots(turns)

    /// The PDFs that brought the helper down this session: each one's size and digest, and the addresses they came
    /// from. Only in memory.
    private static var harmful: [(count: Int, digest: SHA256.Digest)] = []
    private static var harmfulSources: Set<URL> = []

    /// A PDF from `url` brought the helper down this session: WebKit's viewer shows it from now on.
    static func broughtDownTheHelper(_ url: URL) -> Bool { harmfulSources.contains(url) }

    convenience init(data: Data, source: URL? = nil, serviceName: String = PDFService.name, timeScale: Double = 1) {
        self.init(data: data, source: source, timeScale: timeScale) { XPCPDFLink(serviceName: serviceName) }
    }

    init(data: Data, source: URL? = nil, timeScale: Double = 1, makeLink: @escaping () -> PDFLink) {
        self.data = data
        self.source = source
        self.timeScale = timeScale
        self.makeLink = makeLink
    }

    // The connection goes with this object (`XPCPDFLink` invalidates it), and the helper lets the PDF go with it.

    // MARK: Asking

    /// Opens the PDF in the helper. Nil when it can't be read there (not a PDF, locked, past the limits, or the
    /// helper failed on it): WebKit's viewer shows it instead.
    func open() async -> Info? {
        if let info { return info }
        guard data.count <= Self.maxInputBytes, !hasFailed else { return nil }
        if await isKnownHarmful() { fail(harmful: false); return nil }
        guard await reopen() else { return nil }
        return info
    }

    /// A picture of `rect` (in the page's points as shown) at `scale` pixels a point, or nil.
    func render(page: Int, rect: CGRect, scale: CGFloat, dark: Bool) async -> CGImage? {
        let width = Int((rect.width * scale).rounded(.up)), height = Int((rect.height * scale).rounded(.up))
        let tile: RemotePDFTile? = await ask(PDFLimits.renderTime, .picture) { proxy, reply in
            proxy.render(page: page, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, scale: scale, dark: dark, reply: reply)
        }
        guard let tile else { return nil }
        // Pixels that don't add up are no answer the helper gives: something else is answering, and the PDF fails.
        guard tile.isWellFormed else { reject(); return nil }
        // At most the size asked for (a pixel more for rounding), checked before it's taken as pixels.
        guard tile.width <= width + 1, tile.height <= height + 1 else { return nil }
        return Self.image(from: tile)
    }

    func text(page: Int) async -> PageText? {
        guard let info, info.pageSizes.indices.contains(page) else { return nil }
        let text: RemotePageText? = await ask(PDFLimits.textTime, .text) { proxy, reply in proxy.text(page: page, reply: reply) }
        guard let text else { return nil }
        guard text.isWellFormed(pages: info.pageSizes.count) else { reject(); return nil }
        return Self.pageText(from: text, pageSize: info.pageSizes[page])
    }

    /// Every page's text, for find.
    func strings() async -> [String]? {
        guard let info else { return nil }
        let reply: RemotePDFStrings? = await ask(PDFLimits.stringsTime, .find) { proxy, reply in proxy.strings(reply: reply) }
        guard let reply else { return nil }
        guard reply.isWellFormed(pages: info.pageSizes.count), let strings = reply.strings else { reject(); return nil }
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
        guard let pageSizes = remote.checkedPageSizes() else { return nil }
        let outline = remote.outline.map {
            OutlineItem(title: $0.title, level: $0.level, page: $0.page >= 0 ? $0.page : nil, y: $0.y.isNaN ? nil : $0.y)
        }
        let title = remote.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Info(pageSizes: pageSizes, title: title?.isEmpty == false ? title : nil, outline: outline, allowsCopying: remote.allowsCopying)
    }

    /// A link may cover at most this much of its page: one over most of it would open on any click there.
    nonisolated static let maxLinkShare = 0.5

    /// `pageSize`: the page's size as shown, to leave out links that cover most of it.
    nonisolated static func pageText(from remote: RemotePageText, pageSize: CGSize? = nil) -> PageText {
        let boxes: [CGRect] = remote.boxes.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Float32.self)
            return stride(from: 0, to: values.count - 3, by: 4).map {
                CGRect(x: CGFloat(values[$0]), y: CGFloat(values[$0 + 1]), width: CGFloat(values[$0 + 2]), height: CGFloat(values[$0 + 3]))
            }
        }
        let page = pageSize.map { CGRect(origin: .zero, size: $0) }
        let links = remote.links.compactMap { link -> Link? in
            let url = link.url.flatMap(URL.init(string:))
            guard url != nil || link.page >= 0 else { return nil }
            if let page {
                let covered = CGRect(x: link.x, y: link.y, width: link.width, height: link.height).intersection(page)
                if !covered.isNull, covered.width * covered.height > page.width * page.height * maxLinkShare { return nil }
            }
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
            let remote: RemotePDFInfo? = await ask(PDFLimits.openTime, .open) { proxy, reply in
                proxy.open(data) { reply($0, true) }
            }
            guard let remote, let info = Self.info(from: remote),
                  self.info == nil || self.info?.pageSizes == info.pageSizes else {
                fail(harmful: false)
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
        /// The connection broke: the helper went (`interrupted`), or couldn't be reached at all.
        case broken(interrupted: Bool)
        case timedOut
        /// The answer wasn't of the one class asked for: the helper isn't answering as it does.
        case wrongClass
    }

    /// One request, in its turn: this PDF's one request in the helper (`gate`), then a turn there. Opens the PDF in
    /// the helper first when it isn't there.
    private func ask<T: NSObject & Sendable>(_ limit: TimeInterval, _ priority: Gate.Priority,
                                  _ request: @escaping @Sendable (PDFRendering, @escaping @Sendable (T?, Bool) -> Void) -> Void) async -> T? {
        let opens = priority == .open
        var sent = 0
        while sent < 3 {
            guard !hasFailed else { return nil }
            if !opens, !isOpen { guard await reopen() else { return nil } }
            await gate.enter(priority)
            // While it waited, the helper may have started afresh without the PDF, or the PDF failed.
            guard !hasFailed, opens || isOpen else { gate.leave(); continue }
            sent += 1
            let alone = isSuspect
            let weight = alone ? Self.turns : 1
            await Self.slots.acquire(weight)
            let turn = Turn(self)
            let outcome = await send(limit, request)
            turn.end()
            Self.slots.release(weight)
            gate.leave()
            switch outcome {
            case .answered(let value, let held):
                if alone { isSuspect = false }
                // The helper started afresh since the PDF was sent: again, once it has it.
                guard held else { isOpen = false; continue }
                return value
            case .broken(let interrupted):
                isOpen = false
                // No helper to be had: nothing this PDF did.
                guard interrupted else { fail(harmful: false); return nil }
                // The helper went while this PDF was in it alone: it's what brings it down. Failing it at once also
                // spares the helper a second start soon after the first, which the system holds back for seconds.
                if alone || !turn.sharedTheHelper { fail(harmful: true); return nil }
                isSuspect = true
            case .timedOut:
                // The helper ends itself over it, taking every other PDF's requests with it.
                fail(harmful: true)
                return nil
            case .wrongClass:
                reject()
                return nil
            }
        }
        return nil
    }

    private func send<T: NSObject & Sendable>(_ limit: TimeInterval,
                                   _ request: @escaping @Sendable (PDFRendering, @escaping @Sendable (T?, Bool) -> Void) -> Void) async -> Outcome<T> {
        let link = currentLink()
        let once = AnswerOnce()
        let wait = limit * timeScale + (timeScale < 1 ? 0 : 3)
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
            let finish: @Sendable (Outcome<T>) -> Void = { outcome in
                if once.claim() { continuation.resume(returning: outcome) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait) { finish(.timedOut) }
            link.send({ proxy in
                request(proxy) { value, held in
                    // Exactly the class asked for, read from the object itself: the reply's type is only what the
                    // helper was meant to send.
                    if let value, !Self.isExactly(value, T.self) { finish(.wrongClass); return }
                    finish(.answered(value, held: held))
                }
            },
                      failed: { interrupted in finish(.broken(interrupted: interrupted)) })
        }
        if case .broken = outcome { drop(link) }
        return outcome
    }

    /// Whether `object` is of `type` itself, asked of the object at run time rather than taken from its static type.
    nonisolated static func isExactly(_ object: AnyObject, _ type: AnyClass) -> Bool {
        guard let actual: AnyClass = object_getClass(object) else { return false }
        return ObjectIdentifier(actual) == ObjectIdentifier(type)
    }

    /// The helper answered with something it never sends: this PDF fails, and asks nothing more of it.
    private func reject() {
        Diagnostics.note("PDF helper sent a malformed reply")
        fail(harmful: false)
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

    /// Whether these bytes brought the helper down before. Only hashed when one the same size did.
    private func isKnownHarmful() async -> Bool {
        let count = data.count
        let digests = Self.harmful.filter { $0.count == count }.map(\.digest)
        guard !digests.isEmpty else { return false }
        let data = self.data
        let digest = await Task.detached(priority: .userInitiated) { SHA256.hash(data: data) }.value
        return digests.contains(digest)
    }

    /// `harmful`: it crashed or stalled the helper, and is remembered so it never does again this session.
    private func fail(harmful: Bool) {
        guard !hasFailed else { return }
        if harmful {
            Self.harmful.append((data.count, SHA256.hash(data: data)))
            if let source { Self.harmfulSources.insert(source) }
        }
        hasFailed = true
        isOpen = false
        link?.invalidate()
        link = nil
        onFail?()
    }
}

/// One request at a time for each PDF: the helper answers them one at a time anyway, so the rest wait here, where
/// their clocks haven't started. The most urgent waiting goes next, in the order asked among equals.
@MainActor
private final class Gate {
    enum Priority: Int {
        case find, text, picture, open
    }

    private var busy = false
    private var waiting: [(priority: Priority, continuation: CheckedContinuation<Void, Never>)] = []

    func enter(_ priority: Priority) async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append((priority, $0)) }
    }

    /// Hands the turn to the most urgent waiting, the first asked among equals; or frees it.
    func leave() {
        var next: Int?
        for index in waiting.indices where next.map({ waiting[index].priority.rawValue > waiting[$0].priority.rawValue }) ?? true {
            next = index
        }
        guard let next else { busy = false; return }
        waiting.remove(at: next).continuation.resume()
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

/// One connection to the PDF helper. `failed` is called when it breaks before the answer comes: true when the
/// helper went (crashed, or ended itself), false when it couldn't be reached at all.
nonisolated protocol PDFLink: AnyObject, Sendable {
    func send(_ request: @escaping @Sendable (PDFRendering) -> Void, failed: @escaping @Sendable (Bool) -> Void)
    func invalidate()
}

/// The helper over XPC.
nonisolated final class XPCPDFLink: PDFLink, @unchecked Sendable {
    private let connection: NSXPCConnection

    convenience init(serviceName: String) {
        self.init(NSXPCConnection(serviceName: serviceName))
    }

    /// A helper reached by an endpoint rather than by name: tests' stand-ins.
    convenience init(endpoint: NSXPCListenerEndpoint) {
        self.init(NSXPCConnection(listenerEndpoint: endpoint))
    }

    private init(_ connection: NSXPCConnection) {
        self.connection = connection
        connection.remoteObjectInterface = PDFService.interface()
        connection.resume()
    }

    /// The helper keeps each connection's PDF (up to `PDFLimits.maxInputBytes`) until the connection goes.
    deinit { connection.invalidate() }

    func send(_ request: @escaping @Sendable (PDFRendering) -> Void, failed: @escaping @Sendable (Bool) -> Void) {
        // Interrupted (the helper crashed or ended itself) or invalid (it can't be found): every request waiting on
        // it hears so here. So does one whose reply wasn't the one class allowed for it (`NSXPCConnectionReplyInvalid`),
        // which XPC drops before it gets here: that PDF fails.
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            failed((error as NSError).code == NSXPCConnectionInterrupted)
        }) as? PDFRendering else { failed(false); return }
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
