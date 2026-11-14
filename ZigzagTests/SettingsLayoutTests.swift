import AppKit
import Testing
@testable import Zigzag

/// Settings' layout when its page changes size inside an animation, as it does when Borderless page is switched.
@MainActor
struct SettingsLayoutTests {
    /// Inside an animation a view still answers with the frame it had, so a layout that reads its views back is laid
    /// out for the last size. The sections and the pane are laid out for the size the page was just given.
    @Test func fitsThePageItIsGivenInsideAnAnimation() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 776), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        let settings = SettingsView(pane: .appearance)
        settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
        window.contentView?.addSubview(settings)
        settings.layoutSubtreeIfNeeded()

        // Checked once the animation is over: until then the views here answer with their old frames too.
        await withCheckedContinuation { done in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.05
                context.allowsImplicitAnimation = true
                settings.frame = NSRect(x: 0, y: 0, width: 1032, height: 760)
                settings.layoutSubtreeIfNeeded()
            }, completionHandler: { done.resume() })
        }

        let scrolls = settings.subviews.compactMap { $0 as? NSScrollView }
        let sections = try #require(scrolls.first?.documentView), pane = try #require(scrolls.last?.documentView)
        #expect(scrolls.count == 2)
        // Neither is taller than the page, so neither scrolls: everything in Appearance fits a page this size.
        #expect(sections.frame.height <= 760)
        #expect(pane.frame.height <= 760)
        // The pane's rows are as wide as the page leaves beside the column and its edge.
        #expect(sections.frame.width == Tokens.Page.columnWidth)
        #expect(pane.frame.width == 1032 - Tokens.Page.columnWidth - Tokens.Metric.hairline)
    }

    /// A control's words sit with their capitals in the middle: the system font draws them a little under its line's
    /// middle, so a label is set that much higher than its line box would be, in a container counting from the top
    /// or from the bottom, on the screen's pixels.
    @Test func labelsCenterTheirCapitals() {
        let font = Tokens.Font.control()
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let height = Tokens.Page.controlHeight
        let down = Label("HOEX", font: font), up = Label("HOEX", font: font)
        let flipped = Flipped(), plain = NSView()
        flipped.addSubview(down)
        plain.addSubview(up)
        let below = Label.capsBelowMiddle(of: font, lineHeight: down.lineHeight)
        #expect(below > 0 && below < 1)
        let lineBox = (height - down.lineHeight) / 2
        let y = (down: down.centeredY(in: height), up: up.centeredY(in: height))
        #expect(y.down < lineBox && y.up > lineBox)
        #expect(abs(y.down - (lineBox - below)) <= 0.25 && abs(y.up - (lineBox + below)) <= 0.25)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        #expect((y.down * scale).rounded() == y.down * scale && (y.up * scale).rounded() == y.up * scale)
        withExtendedLifetime((flipped, plain)) {}
    }

    /// A row's explanation is measured at the width it's drawn at: one that just fits on a line gets one line's room,
    /// not two, at every width, so the row's text and control share its middle.
    @Test func rowsKeepRoomOnlyForTheLinesTheyDraw() {
        let detail = "A small window for a quick look at a page. Esc closes it, and ⌘O moves it into your browser window to keep it."
        for width in stride(from: CGFloat(420), through: 1000, by: 1) {
            let row = FormRow(title: "New Zigzag Mini", detail: detail, control: Toggle(isOn: false))
            row.frame = NSRect(x: 0, y: 0, width: width, height: row.height(for: width))
            row.layoutSubtreeIfNeeded()
            let field = row.debugDetail
            let drawn = ceil(field.sizeThatFits(NSSize(width: field.frame.width, height: 400)).height)
            #expect(field.frame.height == drawn, "at \(width)")
            if field.frame.height != drawn { break }
        }
    }
}
