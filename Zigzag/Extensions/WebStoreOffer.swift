import AppKit

/// On an extension's Chrome Web Store page: the extension itself (its icon and name), that it works in Zigzag,
/// and one button to add it. The store's own button only works in Chrome, so this stands in for it.
final class WebStoreOffer: FloatingPanelView {
    private static weak var current: WebStoreOffer?
    private weak var controller: BrowserWindowController?
    private let icon = NSImageView()
    private let name = Label("", font: Tokens.Font.body(.semibold), color: Tokens.Color.textPrimary)
    private let line = Label("Works in Zigzag", font: Tokens.Font.small(), color: Tokens.Color.textSecondary)
    private let add = PrimaryButton(title: "Add to Zigzag")
    private let close = IconButton(symbol: "xmark", size: Tokens.Space.x6, symbolSize: 9, toolTip: "Not Now")
    private let id: String
    private let spinner = Spinner()
    private let done = NSImageView(image: Tokens.Symbol.image("checkmark.circle.fill", size: 22))
    private var tabToken: SignalToken?

    static let size = NSSize(width: 400, height: 64)

    static func show(_ id: String, in controller: BrowserWindowController) {
        current?.dismiss()
        let offer = WebStoreOffer(id: id, controller: controller)
        current = offer
        offer.place()
        controller.root.overlay.addSubview(offer)
        offer.present(arrival: .drop)
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
        icon.image = Tokens.Symbol.image("puzzlepiece.extension", size: 22)
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
            if change == .loading, self.controller?.tabManager.selectedTab?.isLoading == false { self.loadIcon() }
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = alpha
        }
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
        let script = "(document.querySelector('meta[property=\"og:image\"]')||{}).content || ''"
        tab.webView?.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let string = result as? String, let url = URL(string: string) else { return }
                Task { @MainActor [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data), image.isValid,
                          let self else { return }
                    self.icon.image = image
                    self.icon.contentTintColor = nil
                }
            }
        }
    }

    private func place() {
        guard let card = controller?.root.cardFrame else { return }
        frame.origin = NSPoint(x: card.midX - Self.size.width / 2, y: card.minY + Tokens.Space.x4)
    }

    private func layoutContent() {
        let h = bounds.height, pad: CGFloat = 14
        icon.frame = NSRect(x: pad, y: (h - 36) / 2, width: 36, height: 36)
        let cb = close.frame.width
        close.frame.origin = NSPoint(x: bounds.width - pad + 4 - cb, y: (h - cb) / 2)
        let aw = max(add.fittingWidth, 120)
        add.frame = NSRect(x: close.frame.minX - 8 - aw, y: (h - Tokens.Space.x8) / 2, width: aw, height: Tokens.Space.x8)
        spinner.frame = NSRect(x: close.frame.minX - 8 - 18, y: (h - 18) / 2, width: 18, height: 18)
        done.frame = NSRect(x: close.frame.minX - 8 - 24, y: (h - 24) / 2, width: 24, height: 24)
        let right = add.isHidden ? (done.isHidden ? spinner.frame.minX : done.frame.minX) : add.frame.minX
        let x = icon.frame.maxX + 12, w = right - x - 12
        let block = name.lineHeight + 1 + line.lineHeight
        name.frame = NSRect(x: x, y: (h - block) / 2, width: w, height: name.lineHeight)
        line.frame = NSRect(x: x, y: name.frame.maxY + 1, width: w, height: line.lineHeight)
    }
}
