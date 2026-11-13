import AppKit
import Testing
@testable import Zigzag

/// A floating panel over the sidebar takes every press and scroll inside it; nothing behind it hears them (#216).
@MainActor
struct PanelClickTests {
    /// A window-sized root with a sidebar of rows, and a panel over it with a row, a label and gaps, as Site Controls is.
    private func scene() -> (root: NSView, sidebar: NSView, row: InteractiveView, panel: FloatingPanelView, panelRow: InteractiveView, label: Label) {
        // Held in a frame as the window's content is, so points are in its terms as AppKit's hit-testing has them.
        let holder = FlippedView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        let root = FlippedView(frame: holder.bounds)
        holder.addSubview(root)
        let sidebar = FlippedView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        root.addSubview(sidebar)
        let row = InteractiveView(frame: NSRect(x: 0, y: 100, width: 240, height: 400))
        sidebar.addSubview(row)
        let overlay = PassthroughView(frame: root.bounds)
        root.addSubview(overlay)
        let panel = FloatingPanelView(frame: NSRect(x: 8, y: 80, width: 224, height: 300))
        overlay.addSubview(panel)
        let box = FlippedView(frame: panel.bounds)
        panel.addSubview(box)
        let panelRow = InteractiveView(frame: NSRect(x: 12, y: 40, width: 200, height: 30))
        box.addSubview(panelRow)
        let label = Label("This Site", font: Tokens.Font.label(), color: Tokens.Color.textTertiary)
        label.frame = NSRect(x: 12, y: 100, width: 100, height: 16)
        box.addSubview(label)
        panel.layoutSubtreeIfNeeded()
        return (root, sidebar, row, panel, panelRow, label)
    }

    @Test func noPointInsideThePanelHitsTheSidebar() {
        let s = scene()
        for x in stride(from: s.panel.frame.minX, to: s.panel.frame.maxX, by: 4) {
            for y in stride(from: s.panel.frame.minY, to: s.panel.frame.maxY, by: 4) {
                let hit = s.root.hitTest(NSPoint(x: x, y: y))
                #expect(hit?.isDescendant(of: s.panel) == true, "(\(x), \(y)) hit \(String(describing: hit))")
                #expect(!BrowserWindowController.isInSidebar(hit, s.sidebar))
            }
        }
        // Outside it, the sidebar is the sidebar's.
        #expect(BrowserWindowController.isInSidebar(s.root.hitTest(NSPoint(x: 100, y: 450)), s.sidebar))
    }

    /// A press on a gap or a label is the panel's alone: it never moves the window or falls through. One on a control
    /// in it is the control's.
    @Test func pressesOnThePanelSurfaceStayThere() {
        let s = scene()
        #expect(FloatingPanelView.isBareSurface(s.root.hitTest(NSPoint(x: 100, y: 90))))
        #expect(FloatingPanelView.isBareSurface(s.label))
        #expect(FloatingPanelView.isBareSurface(s.panel))
        #expect(!FloatingPanelView.isBareSurface(s.panelRow))
        #expect(!FloatingPanelView.isBareSurface(s.row))
        #expect(!FloatingPanelView.isBareSurface(nil))
        #expect(!s.panel.mouseDownCanMoveWindow)
    }
}

/// A field in a panel is the field's, edge to edge: a press on its padding or bezel focuses it, never counts as the
/// panel's surface (the Rename and icon panels, any panel with a text, search or token field).
@MainActor
struct PanelFieldPressTests {
    /// A view around a field that focuses it on a press, as a third-party field wrapper would.
    private final class Wrapper: NSView {
        override func mouseDown(with event: NSEvent) {}
    }

    @Test func aPressOnAFieldsPaddingIsTheFields() {
        // Held in a frame as the window's content is, so points are in its terms as AppKit's hit-testing has them.
        let frame = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let holder = FlippedView(frame: frame.bounds)
        frame.addSubview(holder)
        let panel = FloatingPanelView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        holder.addSubview(panel)
        let filled = FilledField(placeholder: "Name")
        filled.frame = NSRect(x: 12, y: 12, width: 260, height: 32)
        panel.addSubview(filled)
        let search = NSSearchField(frame: NSRect(x: 12, y: 60, width: 260, height: 24))
        panel.addSubview(search)
        let tokens = NSTokenField(frame: NSRect(x: 12, y: 100, width: 260, height: 24))
        panel.addSubview(tokens)
        let bezeled = NSTextField(frame: NSRect(x: 12, y: 140, width: 260, height: 24))
        panel.addSubview(bezeled)
        let wrapper = Wrapper(frame: NSRect(x: 12, y: 180, width: 260, height: 40))
        wrapper.addSubview(NSTextField(frame: NSRect(x: 10, y: 8, width: 240, height: 24)))
        panel.addSubview(wrapper)
        let label = Label("Rename", font: Tokens.Font.label(), color: Tokens.Color.textTertiary)
        label.frame = NSRect(x: 12, y: 240, width: 100, height: 16)
        panel.addSubview(label)
        panel.layoutSubtreeIfNeeded()
        filled.layoutSubtreeIfNeeded()

        // The filled field's padding: its left inset, outside the field inside it.
        let padding = holder.hitTest(NSPoint(x: 14, y: 14))
        #expect(padding === filled, "hit \(String(describing: padding))")
        #expect(!FloatingPanelView.isBareSurface(padding))
        #expect(!FloatingPanelView.isBareSurface(filled.field))
        #expect(!filled.mouseDownCanMoveWindow)
        // The bezel of a search, token or plain field.
        for view in [search, tokens, bezeled] as [NSView] {
            let hit = holder.hitTest(NSPoint(x: view.frame.minX + 1, y: view.frame.minY + 1))
            #expect(!FloatingPanelView.isBareSurface(hit), "hit \(String(describing: hit))")
            #expect(!FloatingPanelView.isBareSurface(view))
        }
        let wrapperPadding = holder.hitTest(NSPoint(x: 14, y: 182))
        #expect(wrapperPadding === wrapper)
        #expect(!FloatingPanelView.isBareSurface(wrapperPadding))

        // Gaps and labels are still the panel's own.
        #expect(FloatingPanelView.isBareSurface(holder.hitTest(NSPoint(x: 290, y: 290))))
        #expect(FloatingPanelView.isBareSurface(holder.hitTest(NSPoint(x: 150, y: 52))))
        #expect(FloatingPanelView.isBareSurface(label))
    }
}
