import AppKit

/// A pane of a split view or tile group picked up by its strip (#160), the way every drag in Zigzag goes: the pane
/// stays in its place, faint; a small picture of its page follows the pointer; and the hint a tab dragged from the
/// sidebar shows marks where it would land. Over another pane the two trade places; on the page's edges and corners it
/// takes that half or quarter, the rest closing up as when a tab is dropped there. Onto a sidebar's tab list it leaves
/// the group for that spot, the list's line showing where; out of every window, into a new one (with ⌥, Zigzag Mini).
/// Esc, or back where it was, changes nothing.
@MainActor
final class PaneDrag {
    private weak var controller: BrowserWindowController?
    let tab: Tab
    private weak var card: PageCardView?
    private let copy: CarriedCopy
    private let cardAlpha: CGFloat
    /// The list showing where the tab would land, this window's or another's.
    private weak var list: SidebarListView?

    enum Target: Equatable {
        case none
        /// Somewhere else in the group.
        case move(PaneMove.Kind)
        /// A tab of its own, in a sidebar's list.
        case list
        /// Out of every window.
        case outside
    }
    private(set) var target = Target.none

    /// The page's picture at most this wide, the pane's shape kept (a very tall or wide one cut to fit).
    nonisolated static let pictureWidth: CGFloat = 220

    init?(controller: BrowserWindowController, tab: Tab, card: PageCardView, at screenPoint: NSPoint) {
        guard let window = card.window else { return nil }
        self.controller = controller
        self.tab = tab
        self.card = card
        cardAlpha = card.alphaValue
        let pane = window.convertToScreen(card.convert(card.bounds, to: nil))
        let size = Self.pictureSize(for: pane.size)
        // Held where it was pressed across the strip, a little under the picture's top edge.
        let across = pane.width > 0 ? min(max((screenPoint.x - pane.minX) / pane.width, 0.1), 0.9) : 0.5
        let grab = NSPoint(x: round(size.width * across), y: size.height - min(14, size.height / 4))
        copy = CarriedCopy(picture: nil, size: size, grab: grab, at: screenPoint, appearance: card.effectiveAppearance,
                           ground: tab.pageColor ?? Tokens.Color.cardBackground, radius: Tokens.Radius.row)
        copy.show(picture: Self.picture(tab.snapshot, size: size))
        // A fresh picture of the page as it is now, in a moment.
        tab.captureSnapshot(keep: false) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.copy.show(picture: Self.picture(tab.snapshot, size: size))
        }
    }

    /// The pane's shape, `pictureWidth` wide, its height kept between half and the whole of that.
    nonisolated static func pictureSize(for pane: CGSize) -> CGSize {
        guard pane.width > 0, pane.height > 0 else { return CGSize(width: pictureWidth, height: pictureWidth * 0.625) }
        let width = min(pictureWidth, pane.width)
        return CGSize(width: width, height: round(min(max(width * pane.height / pane.width, width / 2), width)))
    }

    /// The page's picture filling `size`, from its top.
    private static func picture(_ image: NSImage?, size: CGSize) -> NSImage? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: (rect.width - drawn.width) / 2, y: rect.height - drawn.height, width: drawn.width, height: drawn.height),
                       from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    /// Picked up: the pane goes faint and its picture comes off it.
    func lift() {
        card?.alphaValue = CarriedCopy.faint
        copy.lift()
    }

    /// The pointer is at a point on screen: the hint, or a list's line, shows where the pane would go.
    func moved(to screenPoint: NSPoint) {
        copy.follow(screenPoint)
        guard let controller, let window = controller.window else { return }
        var next = Target.none
        var move: PaneMove?
        var over: SidebarListView?
        if let (owner, list) = SidebarListView.list(at: screenPoint), controller.canMovePane(tab, toListOf: owner) {
            over = list
            next = .list
        } else if Self.window(at: screenPoint) === window, let pair = controller.tabManager.split(for: tab),
                  let index = pair.ids.firstIndex(of: tab.id) {
            move = controller.root.splitDropHint.move(moving: index, at: window.convertPoint(fromScreen: screenPoint),
                                                      shape: pair.shape, gap: controller.root.paneGap)
            next = move.map { .move($0.kind) } ?? .none
        } else if Self.window(at: screenPoint) == nil {
            next = .outside
        }
        if over !== list { list?.externalHover(at: nil) }
        list = over
        over?.externalHover(at: screenPoint)
        controller.root.splitDropHint.follow(window.convertPoint(fromScreen: screenPoint))
        controller.root.splitDropHint.show(move: move)
        // A tick as it comes onto another place it would take.
        if next != target, next != .none, next != .outside { Haptics.snap() }
        target = next
    }

    /// Let go at a point on screen: the pane goes where the hint said. `option`: out of every window, into Zigzag Mini.
    func drop(at screenPoint: NSPoint, option: Bool) {
        moved(to: screenPoint)
        let target = self.target
        finish()
        guard let controller else { return }
        switch target {
        case .none:
            break
        case .move(let kind):
            controller.rearrangeWithUndo(tab, kind)
        case .list:
            guard let (owner, list) = SidebarListView.list(at: screenPoint) else { return }
            controller.movePaneToList(tab, of: owner, at: list.dropIndex(at: screenPoint))
        case .outside:
            if option, controller.canOpenInMini(tab) { controller.openInMini(tab, at: screenPoint) } else { controller.movePaneToNewWindow(tab, at: screenPoint) }
        }
    }

    /// Called off (Esc): nothing changes.
    func cancel() { finish() }

    private func finish() {
        list?.externalHover(at: nil)
        list = nil
        controller?.root.splitDropHint.show(move: nil)
        card?.alphaValue = cardAlpha
        copy.land(on: nil)
    }

    /// The Zigzag window in front at a point on screen, if any: not the carried picture itself, which the pointer holds.
    private static func window(at screenPoint: NSPoint) -> NSWindow? {
        NSApp.orderedWindows.first { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(screenPoint) }
    }
}

extension BrowserWindowController {
    /// A pane's strip pressed and dragged: the pane is carried until it's let go, or Esc calls it off.
    func dragPane(_ tab: Tab, press: NSEvent, moved: NSEvent) {
        guard let window, tabManager.split(for: tab) != nil,
              let card = root.paneCards.first(where: { $0.header.tab === tab && !$0.isHidden }),
              let drag = PaneDrag(controller: self, tab: tab, card: card, at: window.convertPoint(toScreen: press.locationInWindow)) else { return }
        closeFloatingPanels()
        drag.lift()
        drag.moved(to: window.convertPoint(toScreen: moved.locationInWindow))
        let released = CarriedCopy.track(in: window) { drag.moved(to: window.convertPoint(toScreen: $0.locationInWindow)) }
        if let released {
            drag.drop(at: window.convertPoint(toScreen: released.locationInWindow), option: released.modifierFlags.contains(.option))
        } else {
            drag.cancel()
        }
    }

    /// Whether a pane can leave its group for a place in `owner`'s tab list: an ordinary tab, into this window's list
    /// or another's, as a tab moves between windows (#167), never between a private window and another.
    func canMovePane(_ tab: Tab, toListOf owner: BrowserWindowController) -> Bool {
        guard tab.bookmarkID == nil, tabManager.split(for: tab) != nil else { return false }
        return owner === self || (!tabManager.isPrivate && !owner.tabManager.isPrivate)
    }
}
