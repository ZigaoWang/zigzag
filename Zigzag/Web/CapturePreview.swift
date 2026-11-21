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
        if let note {
            note.usesSingleLineMode = false
            note.maximumNumberOfLines = 2
            note.lineBreakMode = .byWordWrapping
            note.cell?.wraps = true
            addSubview(note)
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
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var replacesExtensionPopup: Bool { true }

    private static let pad = Tokens.Space.x3
    private static let rowInset = Tokens.Space.x1
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
        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
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
        monitors.forEach { NSEvent.removeMonitor($0) }
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
        item.setDraggingFrame(thumbnail.bounds, contents: image)
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

/// The capture on the card: its top when it's tall, in a softly rounded frame, picked up to drag out.
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

    override func stateDidChange(animated: Bool) {}

    override func draw(_ dirtyRect: NSRect) {
        guard image.size.width > 0, image.size.height > 0, bounds.width > 0 else { return }
        // As wide as the frame; a picture taller than it shows from its top.
        let shown = min(image.size.height, image.size.width * bounds.height / bounds.width)
        let source = NSRect(x: 0, y: image.size.height - shown, width: image.size.width, height: shown)
        image.draw(in: bounds, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
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
