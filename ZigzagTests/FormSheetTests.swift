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

    @Test func tabReachesAFieldNestedBesideItsButton() {
        // App and Script rows wrap the field in a stack with a Choose… button; Tab must still find it.
        let field = FilledField(placeholder: "App")
        let stack = NSStackView(views: [field, PillButton(title: "Choose…")])
        let row = FormSheet.Row(label: "App", view: stack)
        let candidates = FormSheet.focusCandidates(rows: [row])
        #expect(candidates.contains { $0 === field.field })
        // One field, one stop: the row isn't counted too.
        #expect(candidates.filter { $0 === stack }.isEmpty)

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

    /// A form that can't be confirmed puts the reason in the button's tooltip and, on hover, has the owner mark the blocking fields. A live button says nothing.
    @Test func aFormThatCannotBeConfirmedSaysWhatHoldsItUp() throws {
        var confirmable = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        let host = try #require(window.contentView)
        let sheet = FormSheet.show(in: host, title: "Add", rows: [], confirmTitle: "Add",
                                   canConfirm: { confirmable }, completion: { _ in })
        sheet.heldUpNote = { confirmable ? nil : "Give it a name." }
        sheet.revalidate()

        var hovered: Bool?
        sheet.onConfirmHover = { hovered = $0 }
        let confirm = try #require(sheet.selfAndDescendants(of: PillButton.self).first { $0.title == "Add" })
        #expect(!confirm.isEnabled)
        #expect(confirm.toolTip == "Give it a name.")

        // Hovering the disabled button tells the owner to mark the blocking fields.
        confirm.isHovered = true
        #expect(hovered == true)
        confirm.isHovered = false
        #expect(hovered == false)

        // Nothing blocking: live and silent.
        confirmable = true
        sheet.revalidate()
        #expect(confirm.isEnabled)
        #expect(confirm.toolTip == nil)
    }

    /// A field on the window's frame takes the sidebar address's fill, and the accent ring while typing, as every field.
    @Test func aFieldOnTheFrameKeepsTheSharedRing() throws {
        let field = FilledField.search("Search tabs")
        field.isOnFrame = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 20, y: 20, width: 300, height: Tokens.Metric.controlHeight)
        let fill = try #require(field.layer?.backgroundColor)
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            #expect(fill == Tokens.Chrome.field.cgColor)
        }
        #expect((field.layer?.borderColor?.alpha ?? 0) == 0)
        #expect(window.makeFirstResponder(field.field))
        #expect((field.layer?.borderColor?.alpha ?? 0) > 0)
        #expect(field.layer?.borderWidth == 1.5)
    }
}

extension NSView {
    /// Finds controls in a sheet so tests can exercise them through their normal actions.
    func selfAndDescendants<T: NSView>(of kind: T.Type) -> [T] {
        ((self as? T).map { [$0] } ?? []) + subviews.flatMap { $0.selfAndDescendants(of: kind) }
    }
}
