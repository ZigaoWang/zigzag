import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What a space with no page open shows on its page card: a soft wash of the space's own color, the sidebar's color a
/// few steps lighter (deep and calm at night), or the picture chosen for it in the space's editor (Background). The
/// wordmark (`EmptySpaceMark`) lies on top either way.
enum EmptyPage {
    /// The page card's ground with no page: `Theme.wash`, the light tint of the space that Settings' and Passwords'
    /// columns take, halfway between the frame and the white page, so the page reads as a lighter sidebar. White,
    /// grays, black and a barely tinted space have no hue to wash with, and keep the plain card, as a private
    /// window does: it's always the same dark gray, so you know at once which window you're in.
    static func ground(for space: SpaceInfo?, isPrivate: Bool) -> NSColor {
        guard !isPrivate, let space else { return Tokens.Color.cardBackground }
        let theme = Brand.Theme.of(space)
        guard theme.surfaceHue != nil else { return Tokens.Color.cardBackground }
        return theme.wash
    }

    /// The picture to show, if any: the space's own, never in a private window.
    static func picture(for space: SpaceInfo?, isPrivate: Bool) -> String? {
        isPrivate ? nil : space?.backgroundImage
    }
}

/// A space's picture for its empty page, kept in Zigzag's own data folder (`Backgrounds`): a copy, so it stays when
/// the original is moved or deleted, and no larger than the largest screen needs to fill it, so it's light to hold.
nonisolated enum SpaceBackground {
    static var folder: URL { Paths.directory("Backgrounds") }

    /// A new name each time one is chosen, so a picture never stands in for the one before it.
    static func freshName(for space: UUID) -> String { "\(space.uuidString)-\(UUID().uuidString.prefix(8)).jpg" }

    /// The pixels across the longest side to keep of an image `image` big, so it still covers a `screen` of pixels at
    /// aspect fill, centered: shrunk until its shorter fit meets the screen, never enlarged.
    static func keptLongestSide(of image: CGSize, covering screen: CGSize) -> Int {
        guard image.width > 0, image.height > 0 else { return 0 }
        let longest = max(image.width, image.height)
        guard screen.width > 0, screen.height > 0 else { return Int(longest.rounded()) }
        let scale = min(1, max(screen.width / image.width, screen.height / image.height))
        return Int((longest * scale).rounded())
    }

    /// The largest screen, in pixels.
    @MainActor static var screenPixels: CGSize {
        NSScreen.screens.map { CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor) }
            .max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 3024, height: 1964)
    }

    /// Copies the picture at `source` into `folder` for `space`, made no larger than `screen` needs, and gives the
    /// name it's kept under. Nil when it isn't a picture that can be read.
    static func store(_ source: URL, for space: UUID, screen: CGSize, in folder: URL = folder) -> String? {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(input) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat($0.doubleValue) }),
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat($0.doubleValue) }) else { return nil }
        // Turned on its side by its orientation, its sides swap.
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) { swap(&width, &height) }
        let longest = keptLongestSide(of: CGSize(width: width, height: height), covering: screen)
        guard longest > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longest]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = freshName(for: space)
        let url = folder.appendingPathComponent(name)
        guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { try? FileManager.default.removeItem(at: url); return nil }
        return name
    }

    /// The kept picture, decoded, or nil when it's gone.
    static func load(_ name: String, in folder: URL = folder) -> CGImage? {
        let url = folder.appendingPathComponent(name)
        guard let input = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(input, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// The kept picture made small, `side` pixels on its longest side, for its swatch in the space editor.
    static func thumbnail(_ name: String, side: Int, in folder: URL = folder) -> CGImage? {
        guard let input = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        return CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary)
    }

    /// Whether the picture is still in the folder (⌘Z can bring back a name whose copy Remove deleted).
    static func isKept(_ name: String, in folder: URL = folder) -> Bool {
        isOwnName(name) && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// Deletes a kept picture. Only a plain name in the folder: never a path anywhere else.
    static func remove(_ name: String?, in folder: URL = folder) {
        guard let name, isOwnName(name) else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }

    /// Deletes every kept picture no space names any more (a space deleted, its undo no longer possible once Zigzag
    /// starts again).
    static func prune(keeping names: Set<String>, in folder: URL = folder) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files where !names.contains(file) && isOwnName(file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }

    private static func isOwnName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && name.hasSuffix(".jpg")
    }
}

/// The empty page's ground, on the page card's surface under where the page goes (`PageCardView.setBackdrop`):
/// the space's wash, or its picture filling the card, centered. The picture is read only while the page is empty
/// (`isActive`) and let go the moment a page opens.
final class EmptyPageBackdrop: NSView {
    private let picture = CALayer()
    private var ground: NSColor = Tokens.Color.cardBackground
    /// The kept picture's name, shown while active.
    private(set) var pictureName: String?
    /// The picture decoded, kept only while the page is empty.
    private var decoded: (name: String, image: CGImage)?
    private var loads = 0
    /// Told when a picture shows or goes, so what lies on it can read on it (`EmptySpaceMark.onPicture`).
    var onPictureChange: ((Bool) -> Void)?
    var showsPicture: Bool { picture.contents != nil }

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            refreshPicture(animated: false)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(picture)
        setAccessibilityElement(false)
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation { picture.frame = bounds }
    }

    /// The ground and the picture for a space, eased over `Motion.large` as the frame's color is when `animated`.
    func show(ground: NSColor, picture name: String?, animated: Bool) {
        let groundChanged = ground != self.ground
        self.ground = ground
        if groundChanged {
            if animated, !Tokens.Motion.reduceMotion, let layer {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = (layer.presentation() ?? layer).backgroundColor
                fade.duration = Tokens.Motion.large
                fade.timingFunction = Tokens.Motion.easeOut
                layer.add(fade, forKey: "ground")
            }
            paint()
        }
        guard name != pictureName else { return }
        pictureName = name
        refreshPicture(animated: animated)
    }

    private func paint() {
        var color = ground.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = ground.cgColor }
        Tokens.Motion.withoutAnimation { layer?.backgroundColor = color }
    }

    private func refreshPicture(animated: Bool) {
        loads += 1
        guard isActive, let name = pictureName else {
            decoded = nil
            set(nil, animated: animated && isActive)
            return
        }
        if let decoded, decoded.name == name { set(decoded.image, animated: animated); return }
        let load = loads
        DispatchQueue.global(qos: .userInitiated).async {
            let image = SpaceBackground.load(name)
            DispatchQueue.main.async { [weak self] in
                guard let self, load == self.loads, self.isActive, self.pictureName == name else { return }
                self.decoded = image.map { (name, $0) }
                self.set(image, animated: animated)
            }
        }
    }

    private func set(_ image: CGImage?, animated: Bool) {
        let had = picture.contents != nil
        if animated, !Tokens.Motion.reduceMotion, had || image != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Tokens.Motion.large
            fade.timingFunction = Tokens.Motion.easeOut
            picture.add(fade, forKey: "picture")
        }
        picture.contents = image
        if had != (image != nil) { onPictureChange?(image != nil) }
    }
}
