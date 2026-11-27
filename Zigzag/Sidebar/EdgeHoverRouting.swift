import Foundation

/// When a row reports that no tab is hovered, the edge panel closes the preview after a moment. A row's tracking area
/// reports nothing while the pointer crosses from one row to the next, and the next row's report cancels the close —
/// but only if it arrives inside that moment. Move slowly, or stop between two rows, and the page closed and came back:
/// a flicker that reads as the preview fighting the list.
enum EdgeHoverRouting {
    /// Whether the delayed close should go ahead. The pointer in the list, on the page itself, or still moving means
    /// the nil was a crossing or a trip towards a row, not leaving; once it stops off both, the page goes.
    static func closesAfterNilHover(pointerOverRows: Bool, pointerOverPreview: Bool, stillMoving: Bool) -> Bool {
        !pointerOverRows && !pointerOverPreview && !stillMoving
    }
}
