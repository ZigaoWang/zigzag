import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Empty space page: a tint of the space's color (the sidebar color a few steps lighter, deep at night) or the picture
/// chosen in the space editor (Background), with the wordmark (`EmptySpaceMark`) on top.
enum EmptyPage {
    /// Page card background with no page: `Theme.wash`, the space tint used by Settings and Passwords columns, halfway
    /// between frame and white. White, grays, black and near-neutral spaces have no hue and keep the plain card, as do
    /// private windows (always the same dark gray, so they're recognizable).
    static func ground(for space: SpaceInfo?, isPrivate: Bool) -> NSColor {
        guard !isPrivate, let space else { return Tokens.Color.cardBackground }
        let theme = Brand.Theme.of(space)
        guard let hue = theme.surfaceHue else { return Tokens.Color.cardBackground }
        // A palette color on glass: a fainter tint, so the window reads as one piece of glass.
        if space.isSeeThrough, SpaceLook.presets.contains(where: { $0.seeThrough > 0 && $0.matches(space) })
            || SpaceColor.palette.contains(where: { $0.defaultLook?.matches(space) == true }) {
            return Tokens.Color.dynamic(light: SpaceColor.tone(hue: hue, lightness: Tokens.Frame.glassPageLightness, chroma: Tokens.Frame.glassPageChroma),
                                        dark: SpaceColor.tone(hue: hue, lightness: Tokens.Frame.glassPageDarkLightness, chroma: Tokens.Frame.glassPageDarkChroma))
        }
        return theme.wash
    }

    /// The space's picture, never in a private window.
    static func picture(for space: SpaceInfo?, isPrivate: Bool) -> String? {
        isPrivate ? nil : space?.backgroundImage
    }
}

/// Space pictures, copied into Zigzag's data folder (`Backgrounds`) so they survive the original being moved, and
/// scaled down to the largest screen.
nonisolated enum SpaceBackground {
    static var folder: URL { Paths.directory("Backgrounds") }

    /// A unique name per choice, so an old picture is never shown in its place.
    static func freshName(for space: UUID) -> String { "\(space.uuidString)-\(UUID().uuidString.prefix(8)).jpg" }

    /// Longest side in pixels to keep so `image` still aspect-fills `screen`: shrinks only, never enlarges.
    static func keptLongestSide(of image: CGSize, covering screen: CGSize) -> Int {
        guard image.width > 0, image.height > 0 else { return 0 }
        let longest = max(image.width, image.height)
        guard screen.width > 0, screen.height > 0 else { return Int(longest.rounded()) }
        let scale = min(1, max(screen.width / image.width, screen.height / image.height))
        return Int((longest * scale).rounded())
    }

    /// Largest screen size, in pixels.
    @MainActor static var screenPixels: CGSize {
        NSScreen.screens.map { CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor) }
            .max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 3024, height: 1964)
    }

    /// Copies `source` into `folder` for `space`, scaled down for `screen`. Returns the stored name; nil if unreadable.
    static func store(_ source: URL, for space: UUID, screen: CGSize, in folder: URL = folder) -> String? {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(input) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat($0.doubleValue) }),
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat($0.doubleValue) }) else { return nil }
        // Orientations 5-8 rotate, swapping width and height.
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

    /// Decodes the stored picture; nil if missing.
    static func load(_ name: String, in folder: URL = folder) -> CGImage? {
        let url = folder.appendingPathComponent(name)
        guard let input = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(input, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// A thumbnail `side` pixels on its longest side, for the space editor swatch.
    static func thumbnail(_ name: String, side: Int, in folder: URL = folder) -> CGImage? {
        guard let input = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        return CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary)
    }

    /// Whether the picture still exists (⌘Z can restore a name whose file Remove deleted).
    static func isKept(_ name: String, in folder: URL = folder) -> Bool {
        isOwnName(name) && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// Deletes a stored picture. Only plain names in the folder, never other paths.
    static func remove(_ name: String?, in folder: URL = folder) {
        guard let name, isOwnName(name) else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }

    /// Deletes stored pictures no space references (deleted spaces whose undo ended with relaunch).
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

/// Empty page background on the page card (`PageCardView.setBackdrop`): the space tint, or its picture centered to
/// fill. The picture is decoded only while empty (`isActive`) and released when a page opens.
final class EmptyPageBackdrop: NSView {
    private let picture = CALayer()
    private var ground: NSColor = Tokens.Color.cardBackground
    /// Stored picture name, shown while active.
    private(set) var pictureName: String?
    /// Decoded picture, kept only while empty.
    private var decoded: (name: String, image: CGImage)?
    private var loads = 0
    /// Called when a picture appears or goes, so content adapts (`EmptySpaceMark.onPicture`).
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

    /// Sets the background and picture, animated over `Motion.large` like the frame color when `animated`.
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
            } else {
                layer?.removeAnimation(forKey: "ground")
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
