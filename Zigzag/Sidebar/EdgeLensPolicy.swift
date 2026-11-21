import AppKit

/// What a dismissal closes: the lens alone, or the lens and the sidebar with it.
enum EdgeLensDismissal: Equatable {
    case lensOnly
    case all
}

/// Why the lens is closing. A sidebar action keeps the sidebar; everything else closes the lens and then lets the
/// sidebar follow its proximity rule, except a closed window or the feature going off, which take it too.
enum EdgeLensReason: Equatable {
    case sameTab
    case sidebarClick
    case escape
    case outsideClick
    case altTab
    case spaceChange
    case browserFront
    case windowClose
    case featureOff
    case selection
}

/// What opening a page does to a lens that is already out: a page opened from the lens replaces its page; a sidebar
/// action closes the lens instead.
enum EdgeLensOpenAction: Equatable {
    case open
    case replace
    case close
}

/// The edge lens's rules (#365): the sidebar and the lens are one session, and every dismissal says what it closes.
enum EdgeLensPolicy {
    /// The sidebar cannot hide while the lens is open: a lens that outlived its sidebar would leave a page floating
    /// over another app with nothing to put it back into.
    static func blocksSidebarHide(lensOpen: Bool) -> Bool { lensOpen }

    /// A click on a tab, the sidebar's own row, or Esc closes the lens and leaves the sidebar where it was. Everything
    /// else closes the lens and then lets the sidebar follow the pointer.
    static func dismissal(for reason: EdgeLensReason) -> EdgeLensDismissal {
        switch reason {
        case .sameTab, .sidebarClick, .escape, .selection: .lensOnly
        case .outsideClick, .altTab, .spaceChange, .browserFront, .windowClose, .featureOff: .all
        }
    }

    /// A page opened from the lens replaces the page it shows; a row or another sidebar action closes the lens instead.
    static func openAction(isVisible: Bool, replacing: Bool) -> EdgeLensOpenAction {
        guard isVisible else { return .open }
        return replacing ? .replace : .close
    }

    /// Whether the sidebar takes the keyboard back after the lens collapses. A lens action leaves it working in the
    /// sidebar; a context change leaves the keyboard where the user put it.
    static func keepsKey(after reason: EdgeLensReason) -> Bool {
        switch reason {
        case .sameTab, .sidebarClick, .escape: true
        case .outsideClick, .altTab, .spaceChange, .browserFront, .windowClose, .featureOff, .selection: false
        }
    }

    /// Whether the sidebar hides once the lens has collapsed. A deliberate sidebar action never hides it. A closed
    /// window or the feature going off always does. Otherwise the sidebar follows its normal rule: it stays out while
    /// the pointer is in its edge zone and the panel can still show.
    static func hidesSidebar(after reason: EdgeLensReason, pointerInEdgeZone: Bool, panelCanShow: Bool) -> Bool {
        switch dismissal(for: reason) {
        case .lensOnly:
            false
        case .all:
            switch reason {
            case .windowClose, .featureOff: true
            default: !pointerInEdgeZone || !panelCanShow
            }
        }
    }
}

/// Where the lens sits and how big it is: the page's shape under a caption, beside the sidebar card, inside the
/// screen's margins.
enum EdgeLensLayout {
    /// About 60% of the screen's visible width.
    static let widthFraction: CGFloat = 0.6
    static let minWidth: CGFloat = 480
    static let maxWidth: CGFloat = 1200
    /// Never the Peek's near-full card.
    static let heightFraction: CGFloat = 0.7

    /// The card's frame: `pageAspect` is the page's width over its height, and `caption` is the caption's height. The
    /// height cap is the promise that the lens never becomes a near-full card, so a page too tall for it shrinks with
    /// its aspect rather than growing past the screen. A screen too narrow to hold the minimum beside the sidebar
    /// narrows the card instead of covering the sidebar's own controls.
    static func frame(beside sidebar: NSRect, in visible: NSRect, pageAspect: CGFloat, caption: CGFloat,
                      onRight: Bool, rowMidY: CGFloat) -> NSRect {
        let margin = Tokens.Space.x2
        let gap = Tokens.Space.x2
        let aspect = pageAspect > 0 ? pageAspect : 1
        var width = min(max(visible.width * widthFraction, minWidth), maxWidth)
        width = min(width, visible.width)
        let beside = onRight ? sidebar.minX - gap - visible.minX : visible.maxX - sidebar.maxX - gap
        if beside > 1 { width = min(width, beside) }
        var pageHeight = width / aspect
        let cap = visible.height * heightFraction
        if pageHeight + caption > cap, pageHeight > 0 {
            let scale = max((cap - caption) / pageHeight, 0)
            width *= scale
            pageHeight *= scale
        }
        let height = pageHeight + caption
        let x = onRight ? sidebar.minX - gap - width : sidebar.maxX + gap
        let clampedX = min(max(x, visible.minX), max(visible.maxX - width, visible.minX))
        let y = min(max(rowMidY - height / 2, visible.minY + margin),
                    max(visible.maxY - margin - height, visible.minY + margin))
        return NSRect(x: clampedX, y: y, width: width, height: height)
    }
}
