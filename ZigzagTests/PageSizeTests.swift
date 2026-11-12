import AppKit
import Testing
import WebKit
@testable import Zigzag

/// A page at a size of its own (#141): the sizes offered, where the page goes on its card, and that it keeps its
/// size beside a docked Web Inspector.
@MainActor
@Suite(.serialized)
struct PageSizeTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "PageSizeTests-\(UUID().uuidString)"
        let saved = DeveloperTools.defaults
        DeveloperTools.defaults = UserDefaults(suiteName: name)!
        defer {
            DeveloperTools.defaults.removePersistentDomain(forName: name)
            DeveloperTools.defaults = saved
            DeveloperTools.changed.send()
        }
        try body()
    }

    private let room = NSRect(x: 0, y: 0, width: 1000, height: 700)

    @Test func withoutASizeThePageFillsItsRoom() {
        #expect(PageCardView.pageRect(content: room, size: nil, docked: .zero) == room)
        #expect(PageCardView.pageRect(content: room, size: nil, docked: NSSize(width: 500, height: 0)) == room)
    }

    @Test func aSizedPageSitsInTheMiddleOfItsRoom() {
        let rect = PageCardView.pageRect(content: room, size: CGSize(width: 393, height: 600), docked: .zero)
        #expect(rect == NSRect(x: 303, y: 50, width: 393, height: 600))
        // Wherever its room is on the card.
        let lower = PageCardView.pageRect(content: NSRect(x: 10, y: 20, width: 1000, height: 700), size: CGSize(width: 393, height: 600), docked: .zero)
        #expect(lower == NSRect(x: 313, y: 70, width: 393, height: 600))
    }

    @Test func theInspectorDocksBesideThePageNotInIt() {
        let phone = CGSize(width: 393, height: 600)
        // At the side: the holder is the page's width and the inspector's; the page keeps its 393.
        let side = PageCardView.pageRect(content: room, size: phone, docked: NSSize(width: 500, height: 0))
        #expect(side.width == 893 && side.height == 600)
        // Page and inspector together are in the middle.
        #expect(side.minX == 53 && side.minY == 50)
        // At the bottom: taller by the inspector, as far as the room goes.
        let bottom = PageCardView.pageRect(content: room, size: phone, docked: NSSize(width: 0, height: 300))
        #expect(bottom.width == 393 && bottom.height == 700 && bottom.minY == 0)
    }

    @Test func aSizeLargerThanTheRoomIsCutToIt() {
        let rect = PageCardView.pageRect(content: room, size: CGSize(width: 1440, height: 900), docked: .zero)
        #expect(rect == room)
        let wide = PageCardView.pageRect(content: room, size: CGSize(width: 1440, height: 400), docked: .zero)
        #expect(wide == NSRect(x: 0, y: 150, width: 1000, height: 400))
    }

    /// Larger than its room, a page is laid out at its size and shown smaller, whole, in the middle.
    @Test func aSizeLargerThanTheRoomIsShownSmallerToFit() {
        let fit = PageCardView.pageFit(content: room, size: CGSize(width: 1440, height: 900), docked: .zero, scales: true)
        // 1000 / 1440 is the tighter of the two.
        #expect(abs(fit.scale - 1000.0 / 1440.0) < 0.001 && (fit.frame.width / fit.scale).rounded(.down) == 1440)
        #expect(fit.frame.width == 1000 && fit.frame.height == round(900 * 1000 / 1440))
        // One that fits is shown at its size.
        let phone = PageCardView.pageFit(content: room, size: CGSize(width: 393, height: 600), docked: .zero, scales: true)
        #expect(phone.scale == 1 && phone.frame.size == NSSize(width: 393, height: 600))
        // The inspector keeps its room beside it; the page shrinks into what's left.
        let docked = PageCardView.pageFit(content: room, size: CGSize(width: 1440, height: 900), docked: NSSize(width: 500, height: 0), scales: true)
        #expect(abs(docked.scale - 500.0 / 1440.0) < 0.001 && docked.frame.width == 1000)
        // Never smaller than a quarter, and then cut to the room.
        let huge = PageCardView.pageFit(content: room, size: CGSize(width: 8000, height: 8000), docked: .zero, scales: true)
        #expect(abs(huge.scale - PageCardView.minimumScale) < 0.001 && huge.frame == room)
        // Without the view scale, cut to the room as before.
        #expect(PageCardView.pageFit(content: room, size: CGSize(width: 1440, height: 900), docked: .zero, scales: false).scale == 1)
    }

    @Test func theSizeIsSaidWithHowLargeItsShown() {
        #expect(DeveloperBarTools.sizeText(nil, scale: 1) == "")
        #expect(DeveloperBarTools.sizeText(CGSize(width: 393, height: 852), scale: 1) == PageSizes.dimensions(CGSize(width: 393, height: 852)))
        let shrunk = DeveloperBarTools.sizeText(CGSize(width: 1440, height: 900), scale: 0.72)
        #expect(shrunk.hasPrefix(PageSizes.dimensions(CGSize(width: 1440, height: 900))) && shrunk.contains("72"))
    }

    /// WebKit's view scale is there on this Mac, and is read back as set.
    @Test func webKitHasTheViewScale() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 450))
        #expect(PageCardView.canScale(webView))
        webView.setValue(0.5, forKey: "viewScale")
        #expect(webView.value(forKey: "viewScale") as? CGFloat == 0.5)
    }

    @Test func theHolderSaysTheRoomWhatIsDockedTakes() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let holder = PageHolder(holding: webView)
        #expect(holder.dockedRoom == .zero)
        // WebKit puts the inspector in the holder and narrows the page.
        let inspector = NSView(frame: NSRect(x: 400, y: 0, width: 500, height: 600))
        holder.addSubview(inspector)
        webView.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        #expect(holder.dockedRoom == NSSize(width: 500, height: 0))
        inspector.removeFromSuperview()
        webView.frame = holder.bounds
        #expect(holder.dockedRoom == .zero)
    }

    @Test func theCardGivesThePageItsSizeAndItsRoomBack() {
        let card = PageCardView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let tab = Tab(url: nil, spaceID: UUID())
        card.show(tab.ensureWebView())
        card.pageSize = CGSize(width: 393, height: 600)
        card.layoutSubtreeIfNeeded()
        #expect(tab.pageHolder?.frame == NSRect(x: 303, y: 50, width: 393, height: 600))
        // The card says the page's own area, for what says its size.
        #expect(card.pageArea == NSSize(width: 393, height: 600))
        // The card growing leaves the page its size.
        card.frame.size = NSSize(width: 1200, height: 900)
        card.layoutSubtreeIfNeeded()
        #expect(tab.pageHolder?.frame.size == NSSize(width: 393, height: 600))
        card.pageSize = nil
        card.layoutSubtreeIfNeeded()
        #expect(tab.pageHolder?.frame == NSRect(x: 0, y: 0, width: 1200, height: 900))
        tab.close()
    }

    @Test func aSizedPageStandsOnPlainGround() {
        let card = PageCardView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let tab = Tab(url: nil, spaceID: UUID())
        let webView = tab.ensureWebView()
        webView.underPageBackgroundColor = .systemTeal
        card.show(webView)
        // The card takes the page's color, and gives it up for a page at a size of its own.
        #expect(card.pageColor != nil)
        card.pageSize = CGSize(width: 393, height: 600)
        #expect(card.pageColor == nil)
        card.pageSize = nil
        #expect(card.pageColor != nil)
        tab.close()
    }

    @Test func aTabsSizeIsItsOwnAndTurns() {
        withDefaults {
            let tab = Tab(url: URL(string: "http://localhost:1/"), spaceID: UUID())
            #expect(tab.developerInEffect.size == nil)
            tab.developer.size = CGSize(width: 393, height: 852)
            #expect(tab.developerInEffect.size == CGSize(width: 393, height: 852))
            #expect(tab.developer.rotatedSize == CGSize(width: 852, height: 393))
            // It remembers the last size it had, for Toggle Page Size, after filling the window again.
            #expect(tab.developerLastSize == CGSize(width: 393, height: 852))
            tab.developer.size = CGSize(width: 820, height: 1180)
            tab.developer.size = nil
            #expect(tab.developerLastSize == CGSize(width: 820, height: 1180))
        }
    }

    @Test func theSizeSaidIsTheSizeThePageReallyIs() {
        let chosen = CGSize(width: 820, height: 1180)
        #expect(DeveloperBarTools.shownSize(chosen: nil, room: NSSize(width: 900, height: 700)) == nil)
        // The room is larger: the size chosen.
        #expect(DeveloperBarTools.shownSize(chosen: chosen, room: NSSize(width: 820, height: 1180)) == chosen)
        // A window too short for it cuts it, and what's said is what's there.
        #expect(DeveloperBarTools.shownSize(chosen: chosen, room: NSSize(width: 820, height: 800)) == CGSize(width: 820, height: 800))
        // Before the card has laid anything out, the size chosen.
        #expect(DeveloperBarTools.shownSize(chosen: chosen, room: .zero) == chosen)
    }

    @Test func aPagesOwnSizeIsNotOfferedInASplit() {
        for tool in [DeveloperTool.sizeFill, .sizeCustom, .rotate] {
            #expect(DeveloperTool.isOffered(tool, isOn: true, isDevelopment: true, url: nil, isPrivate: false, inSplit: false))
            #expect(!DeveloperTool.isOffered(tool, isOn: true, isDevelopment: true, url: nil, isPrivate: false, inSplit: true))
        }
        #expect(DeveloperTool.isOffered(.console, isOn: true, isDevelopment: true, url: nil, isPrivate: false, inSplit: true))
    }

    @Test func sizesKeptThatNoPageCanBeAreLeftOut() throws {
        try withDefaults {
            let kept = [PageSizes.Size(name: "Fine", width: 400, height: 800), PageSizes.Size(name: "Huge", width: 90_000, height: 800),
                        PageSizes.Size(name: "", width: 400, height: 800)]
            DeveloperTools.defaults.set(try JSONEncoder().encode(kept), forKey: "DeveloperPageSizes")
            #expect(PageSizes.all == [PageSizes.Size(name: "Fine", width: 400, height: 800)])
            DeveloperTools.defaults.set(Data("not json".utf8), forKey: "DeveloperPageSizes")
            #expect(PageSizes.all == PageSizes.seed)
        }
    }

    @Test func theSizesStartWithAFewDevicesAndWriteNothing() {
        withDefaults {
            #expect(PageSizes.all == PageSizes.seed)
            #expect(DeveloperTools.defaults.object(forKey: "DeveloperPageSizes") == nil)
            PageSizes.add(PageSizes.Size(name: " Watch ", width: 205, height: 251))
            #expect(PageSizes.all.last == PageSizes.Size(name: "Watch", width: 205, height: 251))
            // The same name again takes the old one's place.
            PageSizes.add(PageSizes.Size(name: "Watch", width: 210, height: 260))
            #expect(PageSizes.all.filter { $0.name == "Watch" } == [PageSizes.Size(name: "Watch", width: 210, height: 260)])
            // Not one with no name or a side out of range.
            PageSizes.add(PageSizes.Size(name: "", width: 300, height: 300))
            PageSizes.add(PageSizes.Size(name: "Tiny", width: 10, height: 300))
            #expect(PageSizes.all.count == PageSizes.seed.count + 1)
            PageSizes.remove(PageSizes.Size(name: "Watch", width: 210, height: 260))
            #expect(PageSizes.all == PageSizes.seed)
        }
    }

    @Test func whatYouTypeBecomesASize() {
        #expect(PageSizes.size(width: "393", height: " 852 ") == CGSize(width: 393, height: 852))
        #expect(PageSizes.size(width: "393", height: "") == nil)
        #expect(PageSizes.size(width: "wide", height: "852") == nil)
        #expect(PageSizes.size(width: "199", height: "852") == nil)
        #expect(PageSizes.size(width: "393", height: "8001") == nil)
        #expect(PageSizes.size(width: "393.5", height: "852") == nil)
    }

    @Test func aSizeIsNamedEitherWayUp() {
        withDefaults {
            #expect(PageSizes.named(CGSize(width: 393, height: 852))?.name == "iPhone 16")
            #expect(PageSizes.named(CGSize(width: 852, height: 393))?.name == "iPhone 16")
            #expect(PageSizes.named(CGSize(width: 400, height: 852)) == nil)
            #expect(PageSizes.named(nil) == nil)
        }
    }

    @Test func theSizeToolsFollowThePagesSize() throws {
        var state = DeveloperState()
        #expect(DeveloperTool.sizeFill.isChecked(in: state))
        #expect(!DeveloperTool.rotate.applies(in: state))
        state.size = CGSize(width: 393, height: 852)
        #expect(!DeveloperTool.sizeFill.isChecked(in: state))
        #expect(DeveloperTool.rotate.applies(in: state) && DeveloperTool.sizeCustom.applies(in: state))
        let part = try #require(DeveloperBarTools.parts.first { $0.tools.contains(.sizeFill) })
        #expect(DeveloperBarTools.symbol(of: part, in: DeveloperState()) == part.symbol)
        #expect(DeveloperBarTools.symbol(of: part, in: state) == "iphone")
        state.size = CGSize(width: 852, height: 393)
        #expect(DeveloperBarTools.symbol(of: part, in: state) == "iphone")
        state.size = CGSize(width: 1180, height: 820)
        #expect(DeveloperBarTools.symbol(of: part, in: state) == "ipad")
        // Each of the sizes Zigzag comes with wears its own device.
        let symbols = PageSizes.seed.map { size -> String in
            state.size = size.size
            return DeveloperBarTools.symbol(of: part, in: state)
        }
        #expect(symbols == ["iphone", "iphone", "iphone", "iphone", "iphone", "ipad", "ipad", "ipad", "laptopcomputer", "laptopcomputer", "laptopcomputer"])
        // Every size Zigzag comes with is a real device's or a common screen's, upright, within the limits.
        #expect(PageSizes.seed.allSatisfy { $0.height > $0.width || $0.width >= 1280 })
        #expect(PageSizes.seed.allSatisfy { PageSizes.limits.contains($0.width) && PageSizes.limits.contains($0.height) })
        #expect(Set(PageSizes.seed.map(\.name)).count == PageSizes.seed.count)
        #expect(DeveloperBarTools.grouped(part.tools) == [[.sizeFill], [.sizeCustom, .rotate, .sizeToggle]])
    }
}
