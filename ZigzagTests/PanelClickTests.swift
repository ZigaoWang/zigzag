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
