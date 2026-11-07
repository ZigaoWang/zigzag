import AppKit

/// On an extension's Chrome Web Store page: the extension itself (its icon and name), that it works in Zigzag,
/// and one button to add it. The store's own button only works in Chrome, so this stands in for it.
final class WebStoreOffer: FloatingPanelView {
    private static weak var current: WebStoreOffer?
    private weak var controller: BrowserWindowController?
    private let icon = NSImageView()
    private let name = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let line = Label("Works in Zigzag", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let add = PillButton(title: "Add to Zigzag", style: .prominent)
    private let close = IconButton(symbol: "xmark", toolTip: "Not Now")
    private let id: String
    private let spinner = Spinner()
    private let done = NSImageView(image: Tokens.Symbol.image("checkmark.circle.fill", size: Tokens.TypeSize.display))
    private var tabToken: SignalToken?

    static let size = NSSize(width: 400, height: 64)

    static func show(_ id: String, in controller: BrowserWindowController) {
        current?.dismiss()
        let offer = WebStoreOffer(id: id, controller: controller)
        current = offer
        offer.place()
        controller.root.overlay.addSubview(offer)
        offer.slidesFromTop = true
        offer.present(arrival: .pop)
    }

    #if DEBUG
    static func debugAdd() { current?.install() }
    #endif

    static func hide() {
        current?.dismiss()
        current = nil
    }

    private init(id: String, controller: BrowserWindowController) {
        self.id = id
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        radius = Tokens.Radius.panel
        icon.image = Tokens.Symbol.image("puzzlepiece.extension", size: Tokens.TypeSize.display)
        icon.contentTintColor = Tokens.Color.textSecondary
        icon.imageScaling = .scaleProportionallyUpOrDown
        refreshName()
        name.lineBreakMode = .byTruncatingTail
        done.contentTintColor = Tokens.Color.success
        done.isHidden = true
        [icon, name, line, add, close, spinner, done].forEach { addSubview($0) }
        add.onClick = { [weak self] _ in self?.install() }
        // The store page names the extension once it has loaded; follow it.
        tabToken = controller.tabManager.selectedTab?.changed.observe { [weak self] change in
            guard let self, change == .title || change == .loading else { return }
            self.refreshName()
            // A new title is a new listing too (the store changes listings without loading a page).
            if self.controller?.tabManager.selectedTab?.isLoading == false { self.loadIcon() }
        }
        close.onClick = { _ in Self.hide() }
        onLayout = { [weak self] in self?.layoutContent() }
        loadIcon()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refreshName() {
        let title = controller?.tabManager.selectedTab?.title ?? ""
        // "Dark Reader - Chrome Web Store" → "Dark Reader"; until the page has a title, a plain stand-in.
        let clean = title.components(separatedBy: " - Chrome Web Store").first ?? ""
        name.stringValue = clean.isEmpty || clean.contains("chromewebstore") ? "This extension" : clean
    }

    /// Each stage on the bar itself: downloading, then the review sheet, then adding, then done or what failed.
    private func install() {
        let shown = name.stringValue
        controller?.installExtension(id) { [weak self] stage in
            guard let self else { return }
            // The review sheet is the one thing to look at while it's up: the bar steps aside, and comes back
            // with whatever you chose.
            self.step(aside: stage.isReviewing)
            switch stage {
            case .downloading: self.busy("Downloading…")
            case .reviewing:
                self.busy("Review what it can do, then Add")
                self.spinner.stopAnimation(nil)
            case .adding: self.busy("Adding to Zigzag…")
            case .added(let added):
                self.spinner.stopAnimation(nil)
                self.add.isHidden = true
                self.done.isHidden = false
                self.name.stringValue = added.isEmpty ? shown : added
                self.line.stringValue = "Added. Find it in site controls, by the address."
                self.line.textColor = Tokens.Color.textSecondary
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Self.hide() }
            case .failed(let message):
                self.spinner.stopAnimation(nil)
                self.add.isHidden = false
                self.add.title = "Try Again"
                self.line.stringValue = message
                self.line.textColor = Tokens.Color.warning
            case .cancelled:
                self.spinner.stopAnimation(nil)
                self.add.isHidden = false
                self.line.stringValue = "Works in Zigzag"
                self.line.textColor = Tokens.Color.textSecondary
            }
            self.needsLayout = true
        }
    }

    private func step(aside: Bool) {
        let alpha: CGFloat = aside ? 0 : 1
        guard alphaValue != alpha else { return }
        Tokens.Motion.animate(Tokens.Motion.snappy, evenFromKeyboard: true) { self.animator().alphaValue = alpha }
    }

    private func busy(_ text: String) {
        add.isHidden = true
        spinner.startAnimation(nil)
        line.stringValue = text
        line.textColor = Tokens.Color.textSecondary
        needsLayout = true
    }

    /// The extension's own icon, from the store page.
    private func loadIcon() {
        // Only from this extension's own page, so a previous page's icon never shows.
        guard let tab = controller?.tabManager.selectedTab, ExtensionStore.webStoreID(from: tab.url) == id, !tab.isLoading else { return }
        // The listing's own logo, named for the listing on screen. The store moves between listings without loading
        // a page, so the page's preview image (og:image) can still be the first listing's: never trusted on its own.
        let script = """
            (() => {
              const name = document.title.split(' - Chrome Web Store')[0];
              const logo = [...document.images].find((i) => i.alt === 'Item logo image for ' + name);
              return logo ? logo.src : '';
            })()
            """
        tab.webView?.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let string = result as? String, let url = URL(string: string), url.scheme == "https" else { return }
                Task { @MainActor [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data), image.isValid,
                          let self else { return }
                    self.icon.image = image
                    self.icon.contentTintColor = nil
                    // Store icons come square, often on white: set on a rounded tile with a hairline, like an app icon,
                    // so a square one never reads as a pasted box.
                    self.icon.wantsLayer = true
                    self.icon.layer?.cornerCurve = .continuous
                    self.icon.layer?.masksToBounds = true
                    self.icon.layer?.borderWidth = 1 / (self.window?.backingScaleFactor ?? 2)
                    self.needsLayout = true
                }
            }
        }
    }

    private func place() {
        guard let card = controller?.root.cardFrame else { return }
        frame.origin = NSPoint(x: card.midX - Self.size.width / 2, y: card.minY + Tokens.Space.x3)
    }

    private func layoutContent() {
        let h = bounds.height, pad = Tokens.Space.x4, gap = Tokens.Space.x2
        let iconSide = Tokens.Space.x8 + Tokens.Space.x1
        icon.frame = NSRect(x: pad, y: (h - iconSide) / 2, width: iconSide, height: iconSide)
        icon.layer?.cornerRadius = iconSide * 0.26
        icon.layer?.borderColor = Tokens.Color.textPrimary.withAlphaComponent(0.1).cgColor
        let cb = close.frame.width
        close.frame.origin = NSPoint(x: bounds.width - pad + Tokens.Space.x1 - cb, y: (h - cb) / 2)
        let aw = add.fittingWidth, bh = Tokens.Page.controlHeight
        add.frame = NSRect(x: close.frame.minX - gap - aw, y: (h - bh) / 2, width: aw, height: bh)
        let spin = Tokens.Space.x4 + 2, check = Tokens.Space.x6
        spinner.frame = NSRect(x: close.frame.minX - gap - spin, y: (h - spin) / 2, width: spin, height: spin)
        done.frame = NSRect(x: close.frame.minX - gap - check, y: (h - check) / 2, width: check, height: check)
        let right = add.isHidden ? (done.isHidden ? spinner.frame.minX : done.frame.minX) : add.frame.minX
        let x = icon.frame.maxX + Tokens.Space.x3, w = right - x - Tokens.Space.x3
        let block = name.lineHeight + 1 + line.lineHeight
        name.frame = NSRect(x: x, y: (h - block) / 2, width: w, height: name.lineHeight)
        line.frame = NSRect(x: x, y: name.frame.maxY + 1, width: w, height: line.lineHeight)
    }
}
