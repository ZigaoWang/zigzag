import AppKit

/// A site icon that turns into the folding ribbon while its page loads. Falls back to a globe for sites without icons.
final class FaviconView: NSView {
    private let imageLayer = CALayer()
    private let spinner = RibbonView()
    private let fallback = NSImageView()
    /// Dark one-color icons (GitHub, X, Notion) vanish on a dark frame; they get a light tile behind them.
    private let backing = CALayer()
    private var needsBacking = false

    var image: NSImage? { didSet { refreshImage() } }
    var isLoading = false { didSet { if oldValue != isLoading { refreshLoading() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        imageLayer.cornerRadius = Tokens.Radius.small - 1
        imageLayer.masksToBounds = true
        backing.cornerRadius = Tokens.Radius.small
        backing.cornerCurve = .continuous
        backing.isHidden = true
        layer?.addSublayer(backing)
        layer?.addSublayer(imageLayer)

        spinner.weight = 0.3
        spinner.alphaValue = 0
        addSubview(spinner)

        fallback.image = Tokens.Symbol.image("globe", size: Tokens.TypeSize.body)
        fallback.contentTintColor = Tokens.Color.textTertiary
        fallback.imageScaling = .scaleNone
        addSubview(fallback)
        refreshImage()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            backing.frame = bounds
            imageLayer.frame = needsBacking && effectiveAppearance.isDark ? bounds.insetBy(dx: 2, dy: 2) : bounds
            spinner.frame = bounds
            spinner.ribbonWidth = bounds.width * 0.62
            fallback.frame = bounds
        }
        refreshColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        if isLoading { startSpinning() }
    }

    private func refreshColors() {
        Tokens.Motion.withoutAnimation {
            spinner.color = Tokens.Color.icon
            backing.backgroundColor = cgColor(Tokens.Color.hex(0xFFFFFF, alpha: 0.92))
            backing.isHidden = !(needsBacking && effectiveAppearance.isDark) || imageLayer.opacity == 0
            imageLayer.frame = needsBacking && effectiveAppearance.isDark ? bounds.insetBy(dx: 2, dy: 2) : bounds
            imageLayer.cornerRadius = needsBacking && effectiveAppearance.isDark ? 0 : Tokens.Radius.small - 1
        }
    }

    private func refreshImage() {
        needsBacking = image.map(FaviconView.isDarkMonochrome) ?? false
        refreshColors()
        Tokens.Motion.withoutAnimation {
            let scale = window?.backingScaleFactor ?? 2
            imageLayer.contents = image?.layerContents(forContentsScale: scale)
            imageLayer.contentsScale = scale
        }
        fallback.isHidden = image != nil || isLoading
    }

    private func refreshLoading() {
        let showSpinner = isLoading
        fallback.isHidden = image != nil || isLoading
        let toSpinner: Float = showSpinner ? 1 : 0
        let toImage: Float = showSpinner ? 0 : 1
        for (layer, target) in [(spinner.layer!, toSpinner), (imageLayer, toImage)] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = target
            fade.duration = Tokens.Motion.quick
            layer.add(fade, forKey: "fade")
            Tokens.Motion.withoutAnimation { layer.opacity = target }
        }
        if showSpinner { startSpinning() } else { spinner.stopLooping() }
        Tokens.Motion.withoutAnimation { backing.isHidden = !(needsBacking && effectiveAppearance.isDark) || showSpinner }
    }

    private static var monochromeCache: [ObjectIdentifier: Bool] = [:]

    /// True for icons that are mostly dark, colorless ink on transparency.
    static func isDarkMonochrome(_ image: NSImage) -> Bool {
        let key = ObjectIdentifier(image)
        if let cached = monochromeCache[key] { return cached }
        var result = false
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let side = 16
            if let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let data = ctx.data {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
                let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
                var opaque = 0, transparent = 0, dark = 0, colorful = 0
                for i in 0..<(side * side) {
                    let a = Int(px[i * 4 + 3])
                    if a < 40 { transparent += 1; continue }
                    opaque += 1
                    let r = Int(px[i * 4]) * 255 / a, g = Int(px[i * 4 + 1]) * 255 / a, b = Int(px[i * 4 + 2]) * 255 / a
                    if max(r, g, b) < 90 { dark += 1 }
                    if max(r, g, b) - min(r, g, b) > 40 { colorful += 1 }
                }
                result = opaque > 0 && transparent > side * side / 6 && dark * 10 >= opaque * 7 && colorful * 10 < opaque
            }
        }
        monochromeCache[key] = result
        return result
    }

    private func startSpinning() { spinner.startLooping() }
}
