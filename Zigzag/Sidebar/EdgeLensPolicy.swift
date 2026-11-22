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

/// What a row picked in the sidebar does while the page is out.
enum EdgeLensPick: Equatable {
    case open
    case replace
    case lock
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

    /// A row picked while the page is out: the same row locks it, another row brings that page into the panel.
    static func pickAction(isVisible: Bool, sameTab: Bool) -> EdgeLensPick {
        guard isVisible else { return .open }
        return sameTab ? .lock : .replace
    }

    /// Whether the panel takes this page. It lends the tab's own page, so a page Zigzag serves itself (Settings,
    /// History, the archive) is not one it can show there: its row stays, greyed, and takes no pick. Hover still
    /// lights its place, enough to see where the pointer is and move off it.
    static func takesPage(url: URL?) -> Bool { !HistoryPage.isInternal(url) }

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
            // A space switch made in the panel switches what the panel lists: it stays out on the new space.
            case .spaceChange: false
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

    /// The card's frame: one size for every page, whatever the page's shape, so bringing another tab into the lens
    /// never moves or resizes it. Beside the sidebar card, inside the screen's margins, centred on the row.
    static func frame(beside sidebar: NSRect, in visible: NSRect, onRight: Bool, rowMidY: CGFloat) -> NSRect {
        let margin = Tokens.Space.x2
        let gap = Tokens.Space.x2
        var width = min(max(visible.width * widthFraction, minWidth), maxWidth)
        width = min(width, max(0, visible.width - margin * 2))
        let beside = onRight ? sidebar.minX - gap - visible.minX : visible.maxX - sidebar.maxX - gap
        if beside > 1 { width = min(width, beside) }
        let height = min(visible.height * heightFraction, max(0, visible.height - margin * 2))
        let x = onRight ? sidebar.minX - gap - width : sidebar.maxX + gap
        let clampedX = min(max(x, visible.minX), max(visible.maxX - width, visible.minX))
        let y = min(max(rowMidY - height / 2, visible.minY + margin),
                    max(visible.maxY - margin - height, visible.minY + margin))
        return NSRect(x: clampedX, y: y, width: width, height: height)
    }
}
