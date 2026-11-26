import AppKit
import Testing
@testable import Zigzag

/// Settings' layout when its page changes size inside an animation, as it does when Borderless page is switched.
@MainActor
struct SettingsLayoutTests {
    /// Inside an animation a view still answers with the frame it had, so a layout that reads its views back is laid
    /// out for the last size. The sections and the pane are laid out for the size the page was just given.
    @Test func fitsThePageItIsGivenInsideAnAnimation() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 976), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        let settings = SettingsView(pane: .appearance)
        settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 976)
        window.contentView?.addSubview(settings)
        settings.layoutSubtreeIfNeeded()

        // Checked after the animation, since views report old frames until then. Uses a deadline so a stuck animation fails instead of hanging.
        final class Over: @unchecked Sendable { var yes = false }
        let over = Over()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.05
            context.allowsImplicitAnimation = true
            settings.frame = NSRect(x: 0, y: 0, width: 1032, height: 960)
            settings.layoutSubtreeIfNeeded()
        }, completionHandler: { MainActor.assumeIsolated { over.yes = true } })
        let deadline = Date().addingTimeInterval(5)
        while !over.yes, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(over.yes, "the animation never finished")

        let scrolls = settings.subviews.compactMap { $0 as? NSScrollView }
        let sections = try #require(scrolls.first?.documentView), pane = try #require(scrolls.last?.documentView)
        #expect(scrolls.count == 2)
        // Neither is taller than the page, so neither scrolls: everything in Appearance fits a page this size.
        #expect(sections.frame.height <= 960)
        #expect(pane.frame.height <= 960)
        // The pane's rows are as wide as the page leaves beside the column and its edge.
        #expect(sections.frame.width == Tokens.Page.columnWidth)
        #expect(pane.frame.width == 1032 - Tokens.Page.columnWidth - Tokens.Metric.hairline)
    }

    /// Labels center their capitals: the system font sits a bit low in its line, so labels shift up, in flipped and unflipped containers, pixel-aligned.
    @Test func labelsCenterTheirCapitals() {
        // The offset is sub-pixel and rounds away at 1x, so this only measures on Retina; CI runners have no screen.
        guard (NSScreen.main?.backingScaleFactor ?? 1) >= 2 else { return }
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

    /// Row explanations are measured at their drawn width, so one that fits one line gets one line's height.
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

    /// Menus in a settings group share the widest width and update when choices change.
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

    /// A label caches its measured width and remeasures when text, attributed text or font changes.
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
        // Tracked attributed text is measured as drawn.
        let font = label.font ?? Tokens.Font.body()
        label.attributedStringValue = NSAttributedString(string: "A much longer title than that", attributes: [.font: font, .kern: 4])
        #expect(!label.hasMeasuredInk)
        let tracked = label.inkWidth
        #expect(tracked > ceil(("A much longer title than that" as NSString).size(withAttributes: [.font: font]).width))
        // Each matches a fresh label.
        let fresh = Label("", font: font)
        fresh.attributedStringValue = NSAttributedString(string: "A much longer title than that", attributes: [.font: font, .kern: 4])
        #expect(fresh.inkWidth == tracked)
    }

    /// Text or font set through the cell is remeasured too, since the cache records what it measured.
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

    /// The trailing fade follows the text: on when it overflows, off when it fits.
    @Test func aLabelsFadeFollowsItsText() {
        let label = Label("Fits", font: Tokens.Font.body())
        label.fadesTail = true
        label.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        label.fadeTail()
        #expect(label.layer?.mask == nil)
        label.stringValue = "A title far too long for a hundred and twenty points"
        label.fadeTail()
        #expect(label.layer?.mask != nil)
        // Unchanged: the mask stays.
        let mask = label.layer?.mask
        label.fadeTail()
        #expect(label.layer?.mask === mask)
        label.stringValue = "Fits"
        label.fadeTail()
        #expect(label.layer?.mask == nil)
    }

    /// Rows size controls by their own width; fields have none, so a row with one (the download rules test address) drew no field.
    @Test func aFieldInARowIsGivenRoomToDraw() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 776), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        let settings = SettingsView(pane: .downloads)
        settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
        window.contentView?.addSubview(settings)
        settings.layoutSubtreeIfNeeded()

        let pane = try #require(settings.subviews.compactMap { $0 as? NSScrollView }.last?.documentView)
        var fields: [FilledField] = []
        func collect(_ view: NSView) {
            if let field = view as? FilledField { fields.append(field) }
            view.subviews.forEach(collect)
        }
        collect(pane)
        #expect(!fields.isEmpty)
        for field in fields {
            #expect(field.frame.width > 0)
            #expect(field.frame.height > 0)
        }
    }

    /// Form sheets lay rows out by frame; `NSStackView(views:)` disables autoresizing, so a field plus Choose… overflowed the row and hid the button.
    @Test func aFieldBesideAButtonKeepsTheButtonInsideTheRow() {
        let field = FilledField(placeholder: "example.com")
        let button = PillButton(title: "Choose…")
        let stack = DownloadRuleSheet.stack(field, button)
        let rowWidth: CGFloat = 216
        stack.frame = NSRect(x: 0, y: 0, width: rowWidth, height: Tokens.Metric.controlHeight)
        stack.layoutSubtreeIfNeeded()
        #expect(stack.frame.width == rowWidth, "the stack took the row's width")
        #expect(field.frame.width > 0)
        #expect(button.frame.width > 0, "the button was given room")
        #expect(field.frame.minX >= -0.5)
        #expect(button.frame.maxX <= rowWidth + 0.5, "the button sits inside the row, not past its end")
    }

    /// Sidebar size (#361) has a Custom choice, and the percentage beside it shows only for Custom: − and + step
    /// the sidebar's size, and the percentage puts it back to 100%.
    @Test func theCustomSidebarSizeShowsItsPercentageOnlyWhenChosen() {
        let wasSize = Tokens.Sidebar.size
        let wasScale = Tokens.Sidebar.customScale
        // The tests run in the app, on its own preferences: the percentage goes back to unset if it was.
        let wasKept = UserDefaults.standard.object(forKey: "SidebarSizePercent")
        defer {
            Tokens.Sidebar.size = wasSize
            Tokens.Sidebar.customScale = wasScale
            UserDefaults.standard.set(wasKept, forKey: "SidebarSizePercent")
        }
        Tokens.Sidebar.size = .medium
        Tokens.Sidebar.customScale = 1

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 776), styleMask: [.borderless], backing: .buffered, defer: false)
        let settings = SettingsView(pane: .appearance)
        settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
        window.contentView?.addSubview(settings)
        settings.layoutSubtreeIfNeeded()

        func find<T: NSView>(_ kind: T.Type, in view: NSView, matching: (T) -> Bool = { _ in true }) -> T? {
            if let found = view as? T, matching(found) { return found }
            for child in view.subviews {
                if let found = find(kind, in: child, matching: matching) { return found }
            }
            return nil
        }
        let row = find(FormRow.self, in: settings) { $0.debugTitle == "Sidebar size" }
        let stack = row?.control as? NSStackView
        let menu = stack?.views.compactMap { $0 as? DropdownButton }.first
        let stepper = stack?.views.compactMap { $0 as? ZoomStepper }.first
        #expect(menu?.options.map(\.title) == ["Small", "Medium", "Large", "Custom"])
        #expect(menu?.selectedIndex == 1)
        #expect(stepper != nil)
        #expect(stepper?.isHidden == true)

        menu?.selectedIndex = 3
        menu?.onSelect?(3)
        #expect(Tokens.Sidebar.size == .custom)
        #expect(stepper?.isHidden == false)
        #expect(stepper?.zoom == 1)

        stepper?.debugPress("in")
        #expect(abs(Tokens.Sidebar.customScale - 1.05) < 0.0001)
        #expect(stepper?.zoom == 1.05)
        stepper?.debugPress("reset")
        #expect(Tokens.Sidebar.customScale == 1)

        menu?.selectedIndex = 1
        menu?.onSelect?(1)
        #expect(Tokens.Sidebar.size == .medium)
        #expect(stepper?.isHidden == true)
    }

    /// A heading with controls beside it (Add Rule…, Find a site) keeps the heading gap below the controls, not just
    /// below its label (#527).
    @Test func headingControlsKeepTheGapToTheirGroup() throws {
        let library = Library.shared
        let info = library.addProfile(name: "Heading controls test")
        defer {
            _ = library.removeProfile(info.id)
            library.finishedRemovingProfile(info.id)
        }
        var checked = 0
        for pane in [SettingsPane.downloads, .spaces, .profiles, .translation, .developer, .websiteData] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 776), styleMask: [.borderless], backing: .buffered, defer: false)
            let settings = SettingsView(pane: pane)
            settings.frame = NSRect(x: 0, y: 0, width: 1040, height: 776)
            window.contentView?.addSubview(settings)
            settings.debugReadNow()
            settings.layoutSubtreeIfNeeded()
            for heading in settings.debugHeadingControls.keys.sorted() {
                guard let gaps = settings.debugHeadingGaps(heading) else { continue }
                checked += 1
                // The nearer of the two is exactly the heading gap: neither the label nor the controls crowd the group.
                #expect(min(gaps.controls, gaps.label) == Tokens.Space.x2, "\(heading)")
            }
        }
        #expect(checked >= 4)
    }
}
