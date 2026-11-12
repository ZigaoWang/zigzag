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
}
