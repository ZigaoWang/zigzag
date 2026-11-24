import AppKit
import UniformTypeIdentifiers

/// The card a capture leaves in the page's corner, as macOS leaves its screenshot's: the picture, already copied,
/// to drag into another app, with Copy, Save and Share under it. It goes by itself after a few seconds unless the
/// pointer is on it, or at a click anywhere else or Esc.
final class CapturePreview: FloatingPanelView {
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    /// Kept up while a sheet or the share picker it opened is up.
    var holds = false

    private let image: NSImage
    private let data: Data
    private let name: String
    private let thumbnail: CaptureThumbnail
    private let note: Label?
    private let copyTile: PanelTile
    private let saveTile: PanelTile
    private let shareTile: PanelTile
    /// An × in the corner while the pointer is on the card, white on a dark disc so it reads over any picture; at 13pt
    /// its ink sits on the disc's middle.
    private let closeButton = IconButton(symbol: "xmark", size: CapturePreview.closeSide, symbolSize: 13,
                                         toolTip: String(localized: "Close", comment: "Tooltip of the × on the card a capture leaves in the page's corner: puts the card away."))
    private let closeDisc = ColorView(color: NSColor(white: 0, alpha: 0.62))
    private var tracking: NSTrackingArea?
    private var monitors: [Any] = []
    private var hideWork: DispatchWorkItem?
    private var closed = false
    private let sharing = SharingWatch()

    /// How long it stays on its own.
    static let duration: TimeInterval = 6

    init(image: NSImage, data: Data, name: String, note text: String?) {
        self.image = image
        self.data = data
        self.name = name
        thumbnail = CaptureThumbnail(image: image)
        note = text.map { Label($0, font: Tokens.Font.small(), color: Tokens.Color.textSecondary) }
        copyTile = PanelTile(symbol: "doc.on.doc", caption: String(localized: "Copied", comment: "Under a capture's picture: it's on the clipboard; clicking copies it again."))
        saveTile = PanelTile(symbol: "square.and.arrow.down", caption: DownloadManager.asksWhereToSave
                             ? String(localized: "Save…", comment: "Under a capture's picture: saves it, asking where.")
                             : String(localized: "Save", comment: "Under a capture's picture: saves it to the download folder."))
        shareTile = PanelTile(symbol: "square.and.arrow.up", caption: String(localized: "Share", comment: "Action in the site panel: shares the page."))
        super.init(frame: .zero)
        copyTile.isOn = true
        copyTile.toolTip = String(localized: "Copied to the Clipboard", comment: "Tooltip of Copied under a capture's picture.")
        if !DownloadManager.asksWhereToSave { saveTile.toolTip = String(localized: "Save to the Download Folder", comment: "Tooltip of Save under a capture's picture.") }
        shareTile.toolTip = String(localized: "Share", comment: "Action in the site panel: shares the page.")
        thumbnail.toolTip = String(localized: "Drag into Another App", comment: "Tooltip of a capture's picture on the card after Capture.")
        thumbnail.setAccessibilityLabel(String(localized: "Captured picture", comment: "VoiceOver name of a capture's picture on the card after Capture."))
        [thumbnail, copyTile, saveTile, shareTile].forEach { addSubview($0) }
        closeButton.tint = .white
        closeButton.isHidden = true
        closeDisc.wantsLayer = true
        closeDisc.isHidden = true
        closeDisc.layer?.shadowColor = NSColor.black.cgColor
        closeDisc.layer?.shadowOpacity = 0.25
        closeDisc.layer?.shadowRadius = 3
        closeDisc.layer?.shadowOffset = .zero
        closeButton.onClick = { [weak self] _ in self?.close() }
        if let note {
            note.usesSingleLineMode = false
            note.maximumNumberOfLines = 2
            note.lineBreakMode = .byWordWrapping
            note.cell?.wraps = true
            addSubview(note)
        }
        [closeDisc, closeButton].forEach { addSubview($0) }
        if TouchGestures.isAvailable {
            // A tap on it shows its ×, as the pointer over it does.
            let watch = TouchWatch()
            watch.onTap = { [weak self] _ in self?.showClose(true) }
            addGestureRecognizer(watch)
        }
        copyTile.onClick = { [weak self] _ in self?.copyAgain() }
        saveTile.onClick = { [weak self] _ in self?.onSave?() }
        shareTile.onClick = { [weak self] _ in self?.share() }
        thumbnail.onDragStart = { [weak self] event in self?.beginDrag(event) ?? false }
        thumbnail.onEnded = { [weak self] dropped in
            guard let self else { return }
            self.holds = false
            if dropped { self.close() } else { self.restartTimer() }
        }
        sharing.done = { [weak self] in
            self?.holds = false
            self?.restartTimer()
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Screenshot copied", comment: "Toast after taking a screenshot of the whole page."))
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: closeButton.toolTip ?? "") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    self.close()
                    return true
                }
            },
        ])
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var replacesExtensionPopup: Bool { true }

    private static let pad = Tokens.Space.x3
    private static let rowInset = Tokens.Space.x1
    /// The ×'s disc, concentric with the card's corner.
    private static let closeSide: CGFloat = 20
    private static var closeInset: CGFloat { Tokens.Radius.panel - closeSide / 2 }
    private var pictureWidth: CGFloat { Tokens.Metric.capturePreviewWidth - Self.pad * 2 }
    private var pictureSize: NSSize {
        CaptureGeometry.thumbnailSize(for: image.size, width: pictureWidth, maxHeight: Tokens.Metric.capturePreviewMaxImage)
    }
    private var noteHeight: CGFloat {
        guard let note else { return 0 }
        let size = note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: pictureWidth + Label.inset * 2, height: 200)) ?? .zero
        return ceil(size.height) + Tokens.Space.x2
    }

    override var fittingSize: NSSize {
        NSSize(width: Tokens.Metric.capturePreviewWidth,
               height: Self.pad + pictureSize.height + noteHeight + Tokens.Space.x2 + PanelTile.captionedHeight + Self.rowInset)
    }

    private func layoutContent() {
        let picture = pictureSize
        thumbnail.frame = NSRect(x: round((bounds.width - picture.width) / 2), y: Self.pad, width: picture.width, height: picture.height)
        var y = thumbnail.frame.maxY + Tokens.Space.x2
        if let note {
            note.frame = NSRect(x: Self.pad - Label.inset, y: y, width: pictureWidth + Label.inset * 2, height: noteHeight - Tokens.Space.x2)
            y += noteHeight
        }
        let tiles = [copyTile, saveTile, shareTile]
        let width = (bounds.width - Self.rowInset * 2 - Tokens.Space.x1 * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)
        for (i, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: Self.rowInset + CGFloat(i) * (width + Tokens.Space.x1), y: y, width: width, height: PanelTile.captionedHeight)
        }
        let side = Self.closeSide, inset = Self.closeInset
        closeButton.frame = NSRect(x: bounds.width - inset - side, y: inset, width: side, height: side)
        closeButton.radius = side / 2
        closeDisc.frame = closeButton.frame
        closeDisc.layer?.cornerRadius = side / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { showClose(true) }
    override func mouseExited(with event: NSEvent) { showClose(false) }

    private func showClose(_ shown: Bool) {
        closeButton.isHidden = !shown
        closeDisc.isHidden = !shown
    }

    private func copyAgain() {
        onCopy?()
        restartTimer()
    }

    /// Out of the corner, then it waits; a click elsewhere or Esc puts it away.
    func show(in controller: BrowserWindowController) {
        growsFrom = CGPoint(x: 1, y: 1)
        layoutSubtreeIfNeeded()
        present(arrival: .pop)
        let clicks = TouchPress.addMonitor(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, !self.holds, event.window === self.window else { return event }
            if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close() }
            return event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.holds, event.window === self.window, event.keyCode == 53 else { return event }
            self.close()
            return nil
        }
        monitors = [clicks, keys].compactMap { $0 }
        restartTimer()
    }

    private func restartTimer() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.closeWhenClear() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    /// Waits while the pointer is on it or something it opened is up, as a toast with an action does.
    private func closeWhenClear() {
        guard !closed else { return }
        let pointer = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        if holds || bounds.contains(pointer) {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.closeWhenClear() } }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            return
        }
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        hideWork?.cancel()
        monitors.forEach { TouchPress.removeMonitor($0) }
        monitors = []
        dismiss()
        onClose?()
    }

    /// The share picker under Share, with the picture and its name; nothing is written for it.
    func share() {
        holds = true
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        provider.suggestedName = name
        let picker = NSSharingServicePicker(items: [provider])
        picker.delegate = sharing
        picker.show(relativeTo: shareTile.bounds, of: shareTile, preferredEdge: .minY)
    }

    /// The picture as a file to drop in Finder or a folder (written only where it lands), or as image data for an
    /// app that takes pictures.
    private func beginDrag(_ event: NSEvent) -> Bool {
        let promise = CaptureFilePromise(data: data, name: name)
        let item = NSDraggingItem(pasteboardWriter: promise)
        if thumbnail.showsTop, let rep = thumbnail.bitmapImageRepForCachingDisplay(in: thumbnail.bounds) {
            // The top it shows, as it looks on the card.
            thumbnail.cacheDisplay(in: thumbnail.bounds, to: rep)
            let shown = NSImage(size: thumbnail.bounds.size)
            shown.addRepresentation(rep)
            item.setDraggingFrame(thumbnail.bounds, contents: shown)
        } else {
            item.setDraggingFrame(thumbnail.picture, contents: image)
        }
        holds = true
        thumbnail.beginDraggingSession(with: [item], event: event, source: thumbnail)
        return true
    }

    #if DEBUG
    /// `capture card copy|save|share|close`: as a click on that part of the card.
    func debugPress(_ part: String) {
        switch part {
        case "copy": copyAgain()
        case "save": onSave?()
        case "share": share()
        case "close": close()
        default: break
        }
    }

    #endif
}

/// Hears when the share picker is done, chosen or put away.
final class SharingWatch: NSObject, NSSharingServicePickerDelegate {
    var done: (() -> Void)?

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) { done?() }
}

/// The capture on the card, never stretched, in a softly rounded frame, picked up to drag out: all of it, or a full
/// page's top fading out below.
final class CaptureThumbnail: InteractiveView, NSDraggingSource {
    private let image: NSImage
    /// When a drag ends: whether somewhere took it.
    var onEnded: ((Bool) -> Void)?

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        layer?.cornerRadius = Tokens.Radius.small
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = Tokens.Metric.hairline
        setAccessibilityRole(.image)
        refreshEdge()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshEdge()
    }

    private func refreshEdge() { layer?.borderColor = cgColor(Tokens.Color.cardEdge) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A page's top draws its own edge, so it fades with the picture.
        layer?.borderWidth = showsTop ? 0 : Tokens.Metric.hairline
        needsDisplay = true
    }

    /// Showing only a full page's top.
    var showsTop: Bool { CaptureGeometry.thumbnailShowsTop(for: image.size, in: bounds.size) }

    /// How far up a page's top fades out.
    private static let fade = Tokens.Space.x8

    override func stateDidChange(animated: Bool) {}

    /// Where the picture is drawn in the frame.
    var picture: NSRect { CaptureGeometry.thumbnailPicture(for: image.size, in: bounds.size) }

    override func draw(_ dirtyRect: NSRect) {
        guard image.size.width > 0, image.size.height > 0, bounds.width > 0 else { return }
        let rect = picture
        // A strip thinner than the frame sits on a quiet backdrop.
        if rect.width < bounds.width - 0.5 || rect.height < bounds.height - 0.5 {
            Tokens.Color.fieldFill.setFill()
            bounds.fill()
        }
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high.rawValue]
        guard showsTop, let context = NSGraphicsContext.current?.cgContext else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
            return
        }
        let hairline = Tokens.Metric.hairline
        context.saveGState()
        NSBezierPath(roundedRect: bounds, xRadius: Tokens.Radius.small, yRadius: Tokens.Radius.small).addClip()
        // Drawn as one group, so the fade clears only the picture and its edge.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: hairline / 2, dy: hairline / 2), xRadius: Tokens.Radius.small, yRadius: Tokens.Radius.small)
        edge.lineWidth = hairline
        Tokens.Color.cardEdge.setStroke()
        edge.stroke()
        // The page goes on: its foot fades into the card.
        context.setBlendMode(.destinationOut)
        let band = NSRect(x: 0, y: bounds.height - Self.fade, width: bounds.width, height: Self.fade)
        NSGradient(colorsAndLocations: (.clear, 0), (NSColor(white: 0, alpha: 0.4), 0.5), (.black, 1))?.draw(in: band, angle: 90)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Let go somewhere that took it: the card's done, as macOS's goes once dragged out.
        onEnded?(operation != [])
    }
}

/// The capture as a file promised to where it's dropped, so no copy is written anywhere else, and as PNG data for
/// apps that take a picture rather than a file.
nonisolated final class CaptureFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let data: Data
    private let name: String

    init(data: Data, name: String) {
        self.data = data
        self.name = name
        super.init()
        fileType = UTType.png.identifier
        delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .png ? data : super.pasteboardPropertyList(forType: type)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do {
            try data.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
