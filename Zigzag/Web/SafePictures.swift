import AppKit
import CryptoKit

/// Pictures from the web, read by the sandboxed picture helper rather than in Zigzag (ZigzagImageDecoder). Every
/// picture bytes a website chose go through here: site icons, home-screen and app icons, the store's extension
/// icons, notification icons and the SVGs Dark Pages looks at. What comes back is plain pixels; nil means the bytes
/// weren't an allowed picture, the helper couldn't read them, crashed or took too long, and the caller shows what it
/// shows for no icon (the globe).
///
/// A launch asks for many at once (every tab's icon), so: what the helper read is kept in memory by the bytes' hash
/// and the size asked, and the same bytes asked twice at once go once; at most `concurrency` go to the helper at a
/// time, the rest wait their turn; each has its own time limit, and one that runs out ends only itself. When the
/// helper goes (it crashed, or ended itself over a picture stuck in it), what was waiting on it is asked again,
/// once, each on its own with nothing else in the helper, so a picture that brings the helper down fails alone.
/// Nothing that failed is kept: the next load asks again.
nonisolated final class SafePictures: @unchecked Sendable {
    static let shared = SafePictures(serviceName: PictureService.name)

    /// A picture the helper read.
    struct Picture: @unchecked Sendable {
        let image: CGImage
        /// Its own size, in points: an SVG's declared size, a bitmap's pixels.
        let size: CGSize
        let isVector: Bool

        /// As an NSImage whose one bitmap has the picture's own pixels.
        var nsImage: NSImage {
            let rep = NSBitmapImageRep(cgImage: image)
            let out = NSImage(size: NSSize(width: image.width, height: image.height))
            out.addRepresentation(rep)
            return out
        }
    }

    let timeout: TimeInterval
    let concurrency: Int
    private let makeLink: @Sendable () -> PictureLink
    private let lock = NSLock()
    private var link: PictureLink?
    private var inFlight: [String: Task<Read, Never>] = [:]
    private let slots: Slots
    /// What the helper read, and what it said wasn't a picture, by the bytes' hash and the size asked.
    private let cache = NSCache<NSString, Kept>()

    convenience init(serviceName: String, timeout: TimeInterval = 4, concurrency: Int = 4) {
        self.init(timeout: timeout, concurrency: concurrency) { XPCPictureLink(serviceName: serviceName) }
    }

    /// `makeLink` makes a fresh connection to the helper (a stand-in one in tests).
    init(timeout: TimeInterval = 4, concurrency: Int = 4, makeLink: @escaping @Sendable () -> PictureLink) {
        self.timeout = timeout
        self.concurrency = max(concurrency, 1)
        self.makeLink = makeLink
        slots = Slots(self.concurrency)
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 1_000
    }

    /// Reads `data`, at most `maxSide` pixels across (and never more than `PictureFormat.maxSide`).
    func decode(_ data: Data, maxSide: Int) async -> Picture? {
        if case .picture(let picture) = await read(data, maxSide: maxSide) { return picture }
        return nil
    }

    enum Read: Sendable {
        case picture(Picture)
        /// Not an allowed picture, or one the helper couldn't read: the same bytes never will be.
        case notAPicture
        /// The helper didn't answer (too slow, or gone twice): worth asking again later.
        case unavailable
    }

    func read(_ data: Data, maxSide: Int) async -> Read {
        // Only the allowed kinds go to the helper at all: a PDF, or anything else, is no picture.
        guard PictureFormat.sniff(data) != nil else { return .notAPicture }
        let side = min(max(maxSide, 1), PictureFormat.maxSide)
        let key = Self.key(data, side: side)
        if let kept = cache.object(forKey: key as NSString) { return kept.picture.map(Read.picture) ?? .notAPicture }
        let task = lock.withLock { () -> Task<Read, Never> in
            if let running = inFlight[key] { return running }
            let task = Task.detached(priority: .utility) { [self] () -> Read in
                let read: Read
                if case .answered(let reply) = await request(data, maxSide: side) {
                    let picture = reply.flatMap(Self.picture(from:))
                    // A definite answer, either way; a failure (too slow, the helper gone twice) isn't kept.
                    cache.setObject(Kept(picture), forKey: key as NSString, cost: picture.map { $0.image.width * $0.image.height * 4 } ?? 64)
                    read = picture.map(Read.picture) ?? .notAPicture
                } else {
                    read = .unavailable
                }
                lock.withLock { inFlight[key] = nil }
                return read
            }
            inFlight[key] = task
            return task
        }
        return await task.value
    }

    /// The helper's own answer, for any bytes (the allowlist is checked again there). Never kept.
    func ask(_ data: Data, maxSide: Int) async -> DecodedPicture? {
        if case .answered(let reply) = await request(data, maxSide: maxSide) { return reply }
        return nil
    }

    static func key(_ data: Data, side: Int) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "@\(side)"
    }

    // MARK: Asking the helper

    enum Outcome: Sendable {
        /// The helper's answer: the pixels, or nil for bytes it wouldn't read.
        case answered(DecodedPicture?)
        /// No answer within the time limit.
        case timedOut
        /// The helper went before answering (crashed, ended itself, or couldn't start).
        case broken
    }

    /// One picture, in its turn. If the helper goes before answering, it's asked again, once, on a fresh connection
    /// and alone: whatever brought the helper down then brings down nothing else. One that ran out of time isn't
    /// asked again: it's the one most likely stuck.
    private func request(_ data: Data, maxSide: Int) async -> Outcome {
        await slots.acquire(1)
        let first = await send(data, maxSide: maxSide)
        slots.release(1)
        guard case .broken = first else { return first }
        await slots.acquire(concurrency)
        let again = await send(data, maxSide: maxSide)
        slots.release(concurrency)
        return again
    }

    private func send(_ data: Data, maxSide: Int) async -> Outcome {
        let link = currentLink()
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let finish: @Sendable (Outcome) -> Void = { outcome in
                if once.claim() { continuation.resume(returning: outcome) }
            }
            // Too slow: this one alone ends. The helper ends itself over a picture stuck in it, and what else was
            // in it then is asked again.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(.timedOut) }
            link.decode(data, maxSide: maxSide, reply: { finish(.answered($0)) }, failed: { [weak self] in
                self?.drop(link)
                finish(.broken)
            })
        }
    }

    private func currentLink() -> PictureLink {
        lock.withLock {
            if let link { return link }
            let made = makeLink()
            link = made
            return made
        }
    }

    /// A connection that broke goes; the next picture makes a fresh one.
    private func drop(_ broken: PictureLink) {
        let dropped = lock.withLock { () -> Bool in
            guard link === broken else { return false }
            link = nil
            return true
        }
        if dropped { broken.invalidate() }
    }

    /// The pixels the helper sent, checked for size and length, as an image. Nothing here decodes anything.
    static func picture(from reply: DecodedPicture) -> Picture? {
        guard reply.isWellFormed, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: reply.pixels as CFData),
              let image = CGImage(width: reply.width, height: reply.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: reply.width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return Picture(image: image, size: CGSize(width: reply.pointWidth, height: reply.pointHeight), isVector: reply.isVector)
    }

    /// The bytes of a `data:` URL, as a site's own icon gives them.
    static func bytes(ofDataURL string: String, limit: Int = PictureFormat.maxInputBytes) -> Data? {
        guard string.lowercased().hasPrefix("data:"), let comma = string.firstIndex(of: ",") else { return nil }
        let head = string[..<comma].lowercased(), body = String(string[string.index(after: comma)...])
        guard body.utf8.count <= limit * 2 else { return nil }
        let data = head.hasSuffix(";base64") ? Data(base64Encoded: body, options: .ignoreUnknownCharacters) : body.removingPercentEncoding.map { Data($0.utf8) }
        guard let data, data.count <= limit else { return nil }
        return data
    }

    /// A PNG of a picture already read (for the system's notifications, which take a file).
    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// One connection to the picture helper. `reply` or `failed` is called once per picture: the answer, or the
/// connection broke before it came.
nonisolated protocol PictureLink: AnyObject, Sendable {
    func decode(_ data: Data, maxSide: Int, reply: @escaping @Sendable (DecodedPicture?) -> Void, failed: @escaping @Sendable () -> Void)
    func invalidate()
}

/// The helper over XPC.
nonisolated final class XPCPictureLink: PictureLink, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(serviceName: String) {
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = PictureService.interface()
        connection.resume()
    }

    func decode(_ data: Data, maxSide: Int, reply: @escaping @Sendable (DecodedPicture?) -> Void, failed: @escaping @Sendable () -> Void) {
        // Interrupted (the helper crashed or ended itself) or invalid (it can't be found): every picture waiting
        // on it hears so here.
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in failed() }) as? PictureDecoding else { failed(); return }
        proxy.decode(data, maxSide: maxSide, reply: reply)
    }

    func invalidate() { connection.invalidate() }
}

/// What the helper said for some bytes, kept.
nonisolated private final class Kept: @unchecked Sendable {
    let picture: SafePictures.Picture?
    init(_ picture: SafePictures.Picture?) { self.picture = picture }
}

/// Turns to a helper, in order: a request takes one, or all of them to be asked alone (SafePictures, SafePDF).
nonisolated final class Slots: @unchecked Sendable {
    private let lock = NSLock()
    private var free: Int
    private var waiting: [(weight: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ count: Int) { free = count }

    func acquire(_ weight: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if waiting.isEmpty, free >= weight { free -= weight; return true }
                waiting.append((weight, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release(_ weight: Int) {
        let next = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            free += weight
            var next: [CheckedContinuation<Void, Never>] = []
            while let first = waiting.first, free >= first.weight {
                free -= first.weight
                waiting.removeFirst()
                next.append(first.continuation)
            }
            return next
        }
        next.forEach { $0.resume() }
    }
}

/// True for the first caller only.
nonisolated private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }
}
