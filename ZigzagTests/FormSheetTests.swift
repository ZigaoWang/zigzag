import AppKit
import Testing
@testable import Zigzag

/// What keys do while a form is up: typing reaches its fields, Return confirms only what may be confirmed and is
/// never how something gets deleted, and shortcuts don't reach the window behind it.
@MainActor
struct FormSheetTests {
    private func action(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String? = nil,
                        destructive: Bool = false, canConfirm: Bool = true, composing: Bool = false) -> FormSheet.KeyAction {
        FormSheet.keyAction(keyCode: keyCode, modifiers: modifiers, characters: characters, destructive: destructive, canConfirm: canConfirm, composing: composing)
    }

    @Test func returnConfirmsAFormThatCanBeConfirmed() {
        #expect(action(36) == .confirm)
        #expect(action(76) == .confirm)
        #expect(action(36, canConfirm: false) == .swallow)
    }

    @Test func returnNeverDeletes() {
        #expect(action(36, destructive: true) == .swallow)
        #expect(action(76, destructive: true, canConfirm: true) == .swallow)
    }

    @Test func escapeCancels() {
        #expect(action(53) == .cancel)
        #expect(action(53, destructive: true, canConfirm: false) == .cancel)
    }

    @Test func typingAndEditingReachTheField() {
        #expect(action(0, [], "a") == .pass)
        #expect(action(51) == .pass)
        // Tab stays in the form, as in a confirmation: on to its next stop, or with Shift back to the one before.
        #expect(action(48) == .moveFocus(backward: false))
        #expect(action(48, .shift) == .moveFocus(backward: true))
        #expect(action(48, .command) == .swallow)
        for key in ["a", "c", "v", "x", "z"] { #expect(action(0, .command, key) == .pass) }
    }

    @Test func otherShortcutsStopAtTheForm() {
        #expect(action(13, .command, "w") == .swallow)
        #expect(action(17, .command, "t") == .swallow)
        #expect(action(0, [.command, .option], "a") == .swallow)
        // Redo is an editing key too.
        #expect(action(6, [.command, .shift], "z") == .pass)
        #expect(action(12, .command, "q") == .pass)
    }

    @Test func aWordBeingComposedKeepsItsKeys() {
        #expect(action(36, composing: true) == .pass)
        #expect(action(53, composing: true) == .pass)
    }
}
