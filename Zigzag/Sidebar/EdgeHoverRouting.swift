import Foundation

/// When a row reports that no tab is hovered, the edge panel closes the preview after a moment. A row's tracking area
/// reports nothing while the pointer crosses from one row to the next, and the next row's report cancels the close —
/// but only if it arrives inside that moment. Move slowly, or stop between two rows, and the page closed and came back:
/// a flicker that reads as the preview fighting the list.
enum EdgeHoverRouting {
    /// Whether the delayed close should go ahead. The pointer being in the list, on the page itself, or anywhere the
    /// panel is still being kept open for means the nil was a crossing or a departure over the page, not leaving.
    /// A page outliving a trip off the rows is the point: so long as the sidebar would stay, its page stays.
    static func closesAfterNilHover(pointerOverRows: Bool, pointerOverPreview: Bool, panelKept: Bool) -> Bool {
        !pointerOverRows && !pointerOverPreview && !panelKept
    }
}
