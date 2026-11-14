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

    /// Menus in one group of settings share the widest one's width, and follow it when its choices change.
    @Test func menusInAGroupShareAWidth() {
        let short = DropdownButton(), long = DropdownButton()
        short.options = [.init(title: "Small"), .init(title: "Medium")]
        long.options = [.init(title: "Off"), .init(title: "When Zigzag is dark")]
        let alone = short.intrinsicContentSize.width
        let group = FormGroup()
        group.add(FormRow(title: "Sidebar size", control: short))
        group.add(FormRow(title: "Dark pages", control: long))
        #expect(short.intrinsicContentSize.width == long.intrinsicContentSize.width)
        #expect(short.intrinsicContentSize.width > alone)
        long.options = [.init(title: "Off")]
        #expect(short.intrinsicContentSize.width == alone)
        #expect(long.intrinsicContentSize.width == alone)
    }

    /// A label measures its text once (a sidebar row asks on every layout), and again whenever its text, styled
    /// text or font changes.
    @Test func aLabelsMeasuredWidthFollowsItsTextAndFont() {
        let label = Label("Short", font: Tokens.Font.body())
        #expect(!label.hasMeasuredInk)
        let short = label.inkWidth
        #expect(label.hasMeasuredInk)
        #expect(label.inkWidth == short)
        label.stringValue = "A much longer title than that"
        #expect(!label.hasMeasuredInk)
        let long = label.inkWidth
        #expect(long > short)
        label.font = Tokens.Font.body().withSize(Tokens.Font.body().pointSize * 2)
        #expect(!label.hasMeasuredInk)
        #expect(label.inkWidth > long)
        // Styled text with tracking is measured as drawn.
        let font = label.font ?? Tokens.Font.body()
        label.attributedStringValue = NSAttributedString(string: "A much longer title than that", attributes: [.font: font, .kern: 4])
        #expect(!label.hasMeasuredInk)
        let tracked = label.inkWidth
        #expect(tracked > ceil(("A much longer title than that" as NSString).size(withAttributes: [.font: font]).width))
        // Each measurement is the same as a fresh label's.
        let fresh = Label("", font: font)
        fresh.attributedStringValue = NSAttributedString(string: "A much longer title than that", attributes: [.font: font, .kern: 4])
        #expect(fresh.inkWidth == tracked)
    }

    /// Text or a font set around the label, through its cell, is measured again too: what was measured is checked
    /// against what the label has.
    @Test func aLabelsMeasureChecksWhatItWasFor() throws {
        let label = Label("Short", font: Tokens.Font.body())
        let short = label.inkWidth
        let cell = try #require(label.cell)
        cell.stringValue = "A much longer title than that"
        let long = label.inkWidth
        #expect(long > short)
        cell.font = Tokens.Font.body().withSize(Tokens.Font.body().pointSize * 2)
        #expect(label.inkWidth > long)
    }

    /// The fade at a label's end follows its text: one that grows past its room fades, one cut back to fit doesn't.
    @Test func aLabelsFadeFollowsItsText() {
        let label = Label("Fits", font: Tokens.Font.body())
        label.fadesTail = true
        label.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        label.fadeTail()
        #expect(label.layer?.mask == nil)
        label.stringValue = "A title far too long for a hundred and twenty points"
        label.fadeTail()
        #expect(label.layer?.mask != nil)
        // Asked again with nothing changed, it stays as it is.
        let mask = label.layer?.mask
        label.fadeTail()
        #expect(label.layer?.mask === mask)
        label.stringValue = "Fits"
        label.fadeTail()
        #expect(label.layer?.mask == nil)
    }
}
