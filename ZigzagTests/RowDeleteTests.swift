import AppKit
import Testing
@testable import Zigzag

/// Settings' delete buttons: every row's trash follows one rule.
@MainActor
struct RowDeleteTests {
    @Test func showsOnHoverFocusOrVoiceOver() {
        #expect(!RowDelete.shows(hovered: false, focused: false, voiceOver: false))
        #expect(RowDelete.shows(hovered: true, focused: false, voiceOver: false))
        #expect(RowDelete.shows(hovered: false, focused: true, voiceOver: false))
        #expect(RowDelete.shows(hovered: false, focused: false, voiceOver: true))
    }

    @Test func hiddenKeepsItsPlaceAndItsTabStop() {
        let button = IconButton(symbol: "trash", size: .compact, toolTip: "Delete")
        RowDelete.apply(button, shows: false, keyboardAccess: false)
        #expect(button.isHidden)
        #expect(button.alphaValue == 0)
        // With Full Keyboard Access, Tab can still reach it.
        RowDelete.apply(button, shows: false, keyboardAccess: true)
        #expect(!button.isHidden)
        #expect(button.alphaValue == 0)
        RowDelete.apply(button, shows: true, keyboardAccess: false)
        #expect(!button.isHidden)
        #expect(button.alphaValue == 1)
    }

    @Test func aFormRowsTrashKeepsItsRoomWhileHidden() {
        let trash = IconButton(symbol: "trash", size: .compact, toolTip: "Delete")
        let edit = PillButton(title: "Edit…")
        let stack = NSStackView(views: [trash, edit])
        let row = FormRow(title: "Work", detail: "2 spaces", control: stack)
        let before = stack.fittingSize.width
        row.revealsOnHover(trash)
        #expect(!stack.detachesHiddenViews)
        #expect(trash.alphaValue == 0 || RowDelete.voiceOver)
        #expect(stack.fittingSize.width == before)
    }
}
