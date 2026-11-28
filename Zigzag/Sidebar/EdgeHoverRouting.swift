import Foundation

/// When a row reports that no tab is hovered, the edge panel closes the preview after a moment. A row's tracking area
/// reports nothing while the pointer crosses from one row to the next, and the next row's report cancels the close —
/// but only if it arrives inside that moment. Move slowly, or stop between two rows, and the page closed and came back:
/// a flicker that reads as the preview fighting the list.
enum EdgeHoverRouting {
    /// Whether the delayed close should go ahead. The panel goes when the pointer leaves it, so the page does too: the
    /// two share one lifetime. The pointer still on the panel — on the rows, on the page, in the sidebar's empty part,
    /// over a row's controls, reaching for Downloads, the + or a space's name — is not leaving, whatever a row's own
    /// tracking area says while it is crossed. Only leaving the panel lets the page go.
    static func closesAfterNilHover(pointerOverRows: Bool, pointerOverPreview: Bool, pointerOnPanel: Bool) -> Bool {
        !pointerOverRows && !pointerOverPreview && !pointerOnPanel
    }
}
