import Foundation

/// When a row reports that no tab is hovered, the edge panel closes the preview after a moment (#534). A row's
/// tracking area reports nothing while the pointer crosses from one row to the next, and the next row's report cancels
/// the close — but only if it arrives inside that moment. Move slowly, or stop between two rows, and the page closed
/// and came back: a flicker that reads as the preview fighting the list.
enum EdgeHoverRouting {
    /// Whether the delayed close should go ahead. The pointer being in the list, on the page itself, or anywhere the
    /// panel is still being kept open for means the nil was a crossing or a departure over the page, not leaving.
    /// A page outliving a trip off the rows is the point: so long as the sidebar would stay, its page stays.
    static func closesAfterNilHover(pointerOverRows: Bool, pointerOverPreview: Bool, panelKept: Bool) -> Bool {
        !pointerOverRows && !pointerOverPreview && !panelKept
    }
}

/// Where a space switch's fold comes from: the list slides in from the side of the space that was picked. Kept for
/// the system-page card, which arrives from the sidebar's side.
enum EdgePreviewRouting {
    static func spaceSlide(from before: UUID?, to after: UUID?, order: [UUID]) -> Int {
        guard let before, let after, before != after,
              let from = order.firstIndex(of: before), let to = order.firstIndex(of: after) else { return 0 }
        return to > from ? 1 : -1
    }
}

/// Whether a hover that reports nothing should close the panel's preview (#546).
enum EdgeHoverKeep {
    /// The panel is holding the empty page after a space switch: there is no page to close, and closing here would
    /// narrow the panel and take away what the switch just put in place.
    static func closesOnNilHover(blankSlateShown: Bool) -> Bool { !blankSlateShown }
}
