import AppKit

/// Pictures from the web, read by the sandboxed picture helper rather than in Zigzag (ZigzagImageDecoder). Every
/// picture bytes a website chose go through here: site icons, home-screen and app icons, the store's extension
/// icons, notification icons and the SVGs Dark Pages looks at. What comes back is plain pixels; nil means the bytes
/// weren't an allowed picture, the helper couldn't read them, crashed or took too long, and the caller shows what it
/// shows for no icon (the globe).
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

    private let serviceName: String
    let timeout: TimeInterval
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    init(serviceName: String, timeout: TimeInterval = 4) {
        self.serviceName = serviceName
        self.timeout = timeout
    }

    /// Reads `data`, at most `maxSide` pixels across (and never more than `PictureFormat.maxSide`).
    func decode(_ data: Data, maxSide: Int) async -> Picture? {
        // Only the allowed kinds go to the helper at all: a PDF, or anything else, is no picture.
        guard PictureFormat.sniff(data) != nil else { return nil }
        guard let reply = await ask(data, maxSide: min(max(maxSide, 1), PictureFormat.maxSide)) else { return nil }
        return Self.picture(from: reply)
    }

    /// The helper's own answer, for any bytes (the allowlist is checked again there).
    func ask(_ data: Data, maxSide: Int) async -> DecodedPicture? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<DecodedPicture?, Never>) in
            let finish: @Sendable (DecodedPicture?) -> Void = { picture in
                if once.claim() { continuation.resume(returning: picture) }
            }
            let connection = currentConnection()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(nil) } as? PictureDecoding
            guard let proxy else { finish(nil); return }
            // A helper that never answers: nothing, and a fresh helper for the next picture.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                if once.claim() {
                    continuation.resume(returning: nil)
                    self?.drop(connection)
                }
            }
            proxy.decode(data, maxSide: maxSide) { picture in finish(picture) }
        }
    }

    private func currentConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let made = NSXPCConnection(serviceName: serviceName)
            made.remoteObjectInterface = PictureService.interface()
            // Invalidated (the helper can't be found or was dropped): the next picture makes a new connection. Merely
            // interrupted (it crashed or quit), the same connection starts it again.
            made.invalidationHandler = { [weak self, weak made] in
                guard let self, let made else { return }
                self.lock.withLock { if self.connection === made { self.connection = nil } }
            }
            made.resume()
            connection = made
            return made
        }
    }

    private func drop(_ connection: NSXPCConnection) {
        lock.withLock { if self.connection === connection { self.connection = nil } }
        connection.invalidate()
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

/// True for the first caller only.
nonisolated private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }
}
