import AppKit

/// A link, an address or words dropped on an address field (#182): the sidebar's, the bar above the page's, a split
/// pane's strip's and Zigzag Mini's. A link or an address loads in that field's page; any other text is searched for
/// with the default search engine, as typed into the command bar would be. While something that can drop is over the
/// field, an accent ring around it says it'll land there, the same ring the sidebar and the page show for a drop.
@MainActor
final class AddressDrop {
    /// What a drop carries, as Zigzag goes to it: the first link (a page on the web or a file), else the text as an
    /// address when it reads as one, else a search for it. Nil for nothing usable (an empty string, a link of another
    /// kind, like `javascript:`).
    static func destination(urls: [URL], text: String?, engine: SearchEngine) -> URL? {
        if let url = urls.first(where: { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") }) { return url }
        guard urls.isEmpty, let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Text broken over lines is one search, words apart.
        let words = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if let url = CommandRanker.url(from: words) {
            return ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        return engine.searchURL(words)
    }

    /// Where a drag would go: what its pasteboard carries.
    static func destination(of info: NSDraggingInfo) -> URL? {
        let board = info.draggingPasteboard
        let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        return destination(urls: urls, text: board.string(forType: .string), engine: Library.shared.searchEngine)
    }

    static let types: [NSPasteboard.PasteboardType] = [.URL, .fileURL, .string]

    private weak var view: NSView?
    private let ring = CALayer()
    /// Goes to the dropped address in the field's page; false when there's no page to load it in.
    var onDrop: ((URL) -> Bool)?

    init(_ view: NSView) {
        self.view = view
        view.registerForDraggedTypes(Self.types)
        ring.borderWidth = 2
        ring.cornerCurve = .continuous
        ring.opacity = 0
        ring.zPosition = 50
    }

    func entered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard onDrop != nil, Self.destination(of: info) != nil else { show(false); return [] }
        show(true)
        return .copy
    }

    func exited() { show(false) }

    func perform(_ info: NSDraggingInfo) -> Bool {
        show(false)
        guard let url = Self.destination(of: info) else { return false }
        return onDrop?(url) ?? false
    }

    #if DEBUG
    /// addressdrop: the ring while something is held over the field (`hold`), or text let go on it.
    func debugHold(_ on: Bool) { show(on) }
    func debugDrop(_ text: String) -> Bool {
        show(false)
        guard let url = Self.destination(urls: URL(string: text).map { $0.scheme == "http" || $0.scheme == "https" ? [$0] : [] } ?? [],
                                         text: text, engine: Library.shared.searchEngine) else { return false }
        return onDrop?(url) ?? false
    }
    #endif

    /// The ring around the field, fading in or out.
    private func show(_ on: Bool) {
        guard let view, let layer = view.layer else { return }
        if ring.superlayer !== layer { layer.addSublayer(ring) }
        Tokens.Motion.withoutAnimation {
            ring.frame = view.bounds
            ring.cornerRadius = layer.cornerRadius
            ring.borderColor = view.cgColor(Tokens.Color.accent)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = ring.presentation()?.opacity ?? ring.opacity
        fade.toValue = on ? 1 : 0
        fade.duration = Tokens.Motion.selection
        fade.timingFunction = Tokens.Motion.easeOut
        Tokens.Motion.withoutAnimation { ring.opacity = on ? 1 : 0 }
        ring.add(fade, forKey: "fade")
    }
}
