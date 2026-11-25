import AppKit
import Testing
@testable import Zigzag

/// What the address bar treats as a place to go, and what it searches for.
@MainActor
struct AddressTests {
    @Test func addresses() {
        #expect(CommandRanker.url(from: "example.com")?.absoluteString == "https://example.com")
        #expect(CommandRanker.url(from: "example.com?q=1")?.absoluteString == "https://example.com?q=1")
        #expect(CommandRanker.url(from: "example.com#top")?.absoluteString == "https://example.com#top")
        #expect(CommandRanker.url(from: "readme.md")?.absoluteString == "https://readme.md")
        #expect(CommandRanker.url(from: "localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(CommandRanker.url(from: "192.168.1.1/admin")?.absoluteString == "http://192.168.1.1/admin")
        #expect(CommandRanker.url(from: "printer.local")?.absoluteString == "http://printer.local")
        #expect(CommandRanker.url(from: "youtube.com/@mkbhd")?.absoluteString == "https://youtube.com/@mkbhd")
    }

    /// Selected text that's an address gets Open in the context menu (#234); surrounding punctuation is trimmed.
    @Test func selectedTextThatIsAnAddress() {
        #expect(CommandRanker.destination(fromSelection: " example.com ")?.url.absoluteString == "https://example.com")
        #expect(CommandRanker.destination(fromSelection: "(github.com/ZigaoWang/zigzag).")?.url.absoluteString == "https://github.com/ZigaoWang/zigzag")
        #expect(CommandRanker.destination(fromSelection: "“https://example.com/a?b=1”")?.url.absoluteString == "https://example.com/a?b=1")
        // Balanced parentheses stay in the address.
        let planet = "https://en.wikipedia.org/wiki/Mercury_(planet)"
        #expect(CommandRanker.destination(fromSelection: planet)?.url.absoluteString == planet)
        #expect(CommandRanker.destination(fromSelection: "(\(planet)).")?.url.absoluteString == planet)
        #expect(CommandRanker.destination(fromSelection: "\(planet),")?.url.absoluteString == planet)
        #expect(CommandRanker.destination(fromSelection: "example.com/a)")?.url.absoluteString == "https://example.com/a")
        #expect(CommandRanker.destination(fromSelection: "(example.com/a")?.url.absoluteString == "https://example.com/a")
        #expect(CommandRanker.destination(fromSelection: "localhost:3000")?.url.absoluteString == "http://localhost:3000")
        #expect(CommandRanker.destination(fromSelection: "node.js") == nil)
        #expect(CommandRanker.destination(fromSelection: "go to example.com") == nil)
        #expect(CommandRanker.destination(fromSelection: "example.com\nexample.org") == nil)
        #expect(CommandRanker.destination(fromSelection: "name@example.com") == nil)
        #expect(CommandRanker.destination(fromSelection: "file:///etc/hosts") == nil)
        #expect(CommandRanker.destination(fromSelection: "about:blank") == nil)
        #expect(CommandRanker.destination(fromSelection: "") == nil)
    }

    /// Schemeless addresses use https, then http once if https fails.
    @Test func anAddressWithoutASchemeFallsBackToHTTP() {
        let typed = CommandRanker.destination(from: "localtest.me:3600/x?y=1#z")
        #expect(typed?.url.absoluteString == "https://localtest.me:3600/x?y=1#z")
        #expect(typed?.httpFallback == true)
        #expect(CommandRanker.destination(from: " example.com ")?.httpFallback == true)
        #expect(CommandRanker.destination(fromSelection: "(example.com).")?.httpFallback == true)
        // An explicit scheme, or an address already on http, has no fallback.
        for text in ["https://example.com", "http://example.com", "localhost:3000", "192.168.1.1", "printer.local", "app.test",
                     "file:///etc/hosts", "about:blank"] {
            #expect(CommandRanker.destination(from: text)?.httpFallback == false, "\(text)")
        }
        #expect(CommandRanker.destination(from: "node.js") == nil)
        #expect(CommandRanker.destination(from: "go to example.com") == nil)
    }

    /// The selection counts only while WebKit's menu is for it; a click that selects a word has no Open (#234).
    @Test func theMenuIsForTheSelectionReadAsTheClickStarted() {
        #expect(BrowserWebView.lookUpTitle("Look Up “example.com”", names: "example.com"))
        #expect(BrowserWebView.lookUpTitle("Look Up “https://example.com/a-v…”", names: "https://example.com/a-very-long-path"))
        #expect(!BrowserWebView.lookUpTitle("Look Up “Visit”", names: "example.com"))
        #expect(!BrowserWebView.lookUpTitle("Look Up “exa…”", names: "example.org/x".replacingOccurrences(of: "exa", with: "ex")))
        #expect(!BrowserWebView.lookUpTitle("Look Up", names: "example.com"))
    }

    @Test func atMostThreeExtensionsArePinned() {
        #expect(ExtensionPins.limit == 3)
        #expect(ExtensionPins(ids: ["a", "b"]).canPin(loaded: ["a", "b"]))
        #expect(!ExtensionPins(ids: ["a", "b", "c"]).canPin(loaded: ["a", "b", "c"]))
    }

    @Test func aNewPinGoesLeftAndPinningTwiceChangesNothing() {
        let pins = ExtensionPins(ids: ["a", "b"]).pinning("c")
        #expect(pins.ids == ["c", "a", "b"])
        #expect(pins.pinning("a") == pins)
        #expect(pins.unpinning("a").ids == ["c", "b"])
    }

    @Test func onlyExtensionsThatAreOnUseASlot() {
        let pins = ExtensionPins(ids: ["a", "b", "c"])
        #expect(!pins.canPin(loaded: ["a", "b", "c", "d"]))
        #expect(pins.canPin(loaded: ["a", "b", "d"]))
    }

    @Test func theRightmostLoadedPinsShow() {
        let pins = ExtensionPins(ids: ["a", "b", "c", "d"])
        #expect(pins.shown(among: ["a", "b", "c", "d"]) == ["b", "c", "d"])
        #expect(pins.shown(among: ["a", "b", "d"]) == ["a", "b", "d"])
        #expect(pins.shown(among: []).isEmpty)
    }

    @Test func reorderingFillsOnlyTheVisiblePlaces() {
        // "b" is hidden or off and stays where it is.
        let pins = ExtensionPins(ids: ["a", "b", "c", "d"])
        #expect(pins.reordered(visible: ["d", "a", "c"]).ids == ["d", "b", "a", "c"])
        // "x" went away during the drag.
        #expect(pins.reordered(visible: ["c", "x", "a"]).ids == ["c", "b", "a", "d"])
    }

    @Test func oldStateWithThePinnedFieldStillDecodes() throws {
        let json = Data(#"{"version":"1.0","enabled":true,"pinned":true}"#.utf8)
        #expect(try JSONDecoder().decode(ExtensionStore.Package.self, from: json).version == "1.0")
        #expect(try JSONDecoder().decode(ExtensionInstalls.State.self, from: json).enabled)
    }

    /// Text and button room is the field less the text's insets and, on http, the mark's 16pt.
    @Test(arguments: [(224.0, 0.0, 1, 3), (224.0, 16.0, 1, 3), (200.0, 0.0, 1, 2), (200.0, 16.0, 1, 2), (170.0, 0.0, 1, 1), (160.0, 16.0, 1, 0), (200.0, 0.0, 3, 0), (200.0, 16.0, 3, 0)])
    func pinsFitTheField(field: Double, http: Double, others: Int, fits: Int) {
        #expect(AddressView.pinsThatFit(count: 3, otherButtons: others, room: field - 18 - http) == fits)
    }

    /// The prompt on a new tab is about 150pt: in the usual 224pt field there's room for one pin beside it, and the
    /// rest give way rather than cut it short.
    @Test(arguments: [(224.0, 150.0, 1), (224.0, 60.0, 3), (224.0, 110.0, 2), (200.0, 150.0, 0), (224.0, 300.0, 0)])
    func pinsGiveWayBeforeTheNameIsCut(field: Double, text: Double, fits: Int) {
        #expect(AddressView.pinsThatFit(count: 3, otherButtons: 1, room: field - 18, text: text) == fits)
    }

    @Test func aPinsCountStaysInsideItsButton() {
        let address = field()
        address.setPins([pin("a", badge: "12"), pin("b", badge: "3")], animated: false)
        for id in ["a", "b"] {
            guard let button = address.pinButton(for: id), let badge = button.subviews.compactMap({ $0 as? BadgeView }).first else {
                Issue.record("no badge on \(id)"); continue
            }
            badge.layout()
            #expect(button.bounds.contains(badge.frame))
        }
    }

    @Test func pinsNeverFitANegativeCountOrMoreThanThereAre() {
        #expect(AddressView.pinsThatFit(count: 3, otherButtons: 5, room: 20) == 0)
        #expect(AddressView.pinsThatFit(count: 1, otherButtons: 1, room: 400) == 1)
    }

    private func pin(_ id: String, badge: String = "") -> AddressView.Pin {
        AddressView.Pin(id: id, image: nil, label: id, badge: badge, action: { _ in }, menu: { nil })
    }

    /// Room for three pins beside the star and Site Controls, on a page that can be pinned.
    private func field() -> AddressView {
        let address = AddressView(frame: NSRect(x: 0, y: 0, width: 224 + AddressView.buttonSide + 2, height: 30))
        address.setSaved(false, canSave: true)
        return address
    }

    @Test func aPinKeepsItsButtonAcrossUpdates() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        let button = address.pinButton(for: "a")
        address.setPins([pin("a", badge: "7"), pin("b")], animated: false)
        #expect(address.pinButton(for: "a") === button)
        #expect((button?.subviews.compactMap { $0 as? BadgeView }.first)?.text == "7")
        let badge = button?.subviews.compactMap { $0 as? BadgeView }.first
        address.setPins([pin("a", badge: "8"), pin("b")], animated: false)
        #expect((button?.subviews.compactMap { $0 as? BadgeView }.first) === badge)
        #expect(badge?.text == "8")
    }

    @Test func aPinThatWentLosesItsButton() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        let button = address.pinButton(for: "a")
        address.setPins([pin("b")], animated: false)
        #expect(address.pinButton(for: "a") == nil)
        #expect(button?.superview == nil)
        #expect(address.visiblePinIDs == ["b"])
    }

    @Test func thePinFurthestFromSiteControlsHidesFirst() {
        let address = AddressView(frame: NSRect(x: 0, y: 0, width: 200 + AddressView.buttonSide + 2, height: 30))
        address.setSaved(false, canSave: true)
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        #expect(address.visiblePinIDs == ["b", "c"])
        #expect(address.pinButton(for: "a")?.isHidden == true)
    }

    @Test func theStarSitsBetweenThePinsAndSiteControls() throws {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        let last = try #require(address.pinButton(for: "b")?.frame)
        #expect(address.visiblePinIDs == ["a", "b"])
        #expect(address.saveButton.frame.minX > last.maxX)
        #expect(address.saveButton.frame.maxX < address.siteControlsButton.frame.minX)
    }

    /// Nothing to pin takes the star's slot away, and the pins that were hidden for it come back (#442).
    @Test func aHiddenStarGivesItsRoomToThePins() throws {
        let address = AddressView(frame: NSRect(x: 0, y: 0, width: 200 + AddressView.buttonSide + 2, height: 30))
        address.setSaved(false, canSave: true)
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        #expect(address.visiblePinIDs == ["b", "c"])

        // A Zigzag view: the star goes, and its room goes to the pins.
        address.setSaved(false, canSave: false)
        #expect(address.saveButton.isHidden)
        #expect(address.visiblePinIDs == ["a", "b", "c"])
        let last = try #require(address.pinButton(for: "c")?.frame)
        #expect(address.siteControlsButton.frame.minX - last.maxX == 2)
    }

    /// Points along the field, from where its pins are laid out, so the buttons after them can change.
    private func at(_ x: CGFloat, _ y: CGFloat = 15) -> NSPoint { NSPoint(x: x, y: y) }
    /// The middle of a pin's button.
    private func mid(_ address: AddressView, _ id: String) -> CGFloat { address.pinButton(for: id)?.frame.midX ?? .nan }

    @Test func aCarriedPinStaysFaintInItsPlaceAndNothingElseMoves() {
        let address = field()
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        let frames = ["a", "b", "c"].map { address.pinButton(for: $0)?.frame }
        #expect(address.beginPinDrag("a", at: at(mid(address, "a"))))
        address.movePinDrag(to: at(mid(address, "c") + 9))
        #expect(["a", "b", "c"].map { address.pinButton(for: $0)?.frame } == frames)
        #expect(address.pinButton(for: "a")?.alphaValue == CarriedCopy.faint)
        #expect(address.pinButton(for: "b")?.alphaValue == 1)
        #expect(address.pinDropDestination == 2)
        address.endPinDrag(drop: false)
        #expect(address.pinButton(for: "a")?.alphaValue == 1)
    }

    /// Offsets from a pin's middle; past the last pin, over the buttons after it, is still the end; past the field, nowhere.
    @Test(arguments: [("a", -25.0, nil), ("a", 5.0, nil), ("b", -3.0, nil), ("b", 7.0, 1), ("c", 9.0, 2), ("c", 34.0, 2), ("c", 80.0, nil)] as [(String, Double, Int?)])
    func aPinDropsIntoTheGapUnderThePointer(pin near: String, offset: Double, destination: Int?) {
        let address = field()
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        address.beginPinDrag("a", at: at(mid(address, "a")))
        address.movePinDrag(to: at(mid(address, near) + offset))
        #expect(address.pinDropDestination == destination)
    }

    @Test func offTheFieldAPinGoesBack() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        var order: [String]?
        address.onPinsReordered = { order = $0 }
        address.beginPinDrag("a", at: at(mid(address, "a")))
        address.movePinDrag(to: at(mid(address, "b") + 9, 60))
        #expect(address.pinDropDestination == nil)
        address.endPinDrag(drop: true)
        #expect(order == nil)
        #expect(address.visiblePinIDs == ["a", "b"])
    }

    @Test func whileAPinIsCarriedContentChangesAndStructureWaits() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        let button = address.pinButton(for: "a")
        #expect(address.beginPinDrag("b", at: at(mid(address, "b"))))
        address.setPins([pin("b", badge: "3")], animated: false)
        #expect(address.pinButton(for: "a") === button)
        #expect(address.pinButton(for: "b")?.subviews.compactMap { $0 as? BadgeView }.first?.text == "3")
        address.endPinDrag(drop: false)
        #expect(address.pinButton(for: "a") == nil)
    }

    @Test func droppingAPinReportsTheNewOrder() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        var order: [String]?
        address.onPinsReordered = { order = $0 }
        address.beginPinDrag("a", at: at(mid(address, "a")))
        address.movePinDrag(to: at(mid(address, "b") + 9))
        address.endPinDrag(drop: true)
        #expect(order == ["b", "a"])
    }

    @Test func callingOffADragChangesNothing() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        var order: [String]?
        address.onPinsReordered = { order = $0 }
        address.beginPinDrag("a", at: at(mid(address, "a")))
        address.movePinDrag(to: at(mid(address, "b") + 9))
        address.endPinDrag(drop: false)
        #expect(order == nil)
        #expect(address.visiblePinIDs == ["a", "b"])
    }

    /// A pinned extension is one more of the field's buttons: Reader's and Site Controls' size, corners and press
    /// area, the same 2pt between every pair, its icon a site icon's 16pt in the middle.
    @Test func aPinnedButtonIsTheFieldsOwnButton() {
        let address = AddressView(frame: NSRect(x: 0, y: 0, width: 400, height: Tokens.Sidebar.addressHeight))
        address.setSaved(false, canSave: true)
        address.setReader(available: true, active: false)
        address.setPins([pin("a", badge: "18"), pin("b")], animated: false)
        guard let a = address.pinButton(for: "a"), let b = address.pinButton(for: "b") else { Issue.record("no pins"); return }
        let row = [address.readerButton, a, b, address.saveButton, address.siteControlsButton]
        for button in row {
            #expect(button.frame.size == NSSize(width: AddressView.buttonSide, height: AddressView.buttonSide))
            #expect(button.frame.minY == AddressView.buttonInset)
            #expect(button.radius == address.siteControlsButton.radius)
        }
        let gaps = zip(row, row.dropFirst()).map { $1.frame.minX - $0.frame.maxX }
        #expect(Set(gaps) == [2])
        #expect(address.bounds.maxX - address.siteControlsButton.frame.maxX == AddressView.buttonInset)
        #expect(a.imageSide == 16 && b.imageSide == Tokens.Sidebar.addressIcon)
    }

    /// Reader's button is a toggle: it stays put when Reader turns on, shows pressed, and says what a click does.
    @Test func readersOneButtonSaysWhatAClickDoes() {
        let address = AddressView(frame: NSRect(x: 0, y: 0, width: 400, height: Tokens.Sidebar.addressHeight))
        address.setReader(available: true, active: false)
        let readerX = address.readerButton.frame.minX
        let width = address.buttonsWidth
        #expect(address.readerButton.toolTip?.hasPrefix("Show Reader") == true)
        #expect(address.readerButton.accessibilityLabel() == "Show Reader")
        address.setReader(available: true, active: true)
        #expect(address.readerButton.frame.minX == readerX)
        #expect(address.buttonsWidth == width)
        #expect(address.readerButton.isSelected)
        #expect(address.readerButton.toolTip?.hasPrefix("Hide Reader") == true)
        #expect(address.readerButton.accessibilityLabel() == "Hide Reader")
        #expect(!address.subviews.contains { ($0 as? IconButton)?.symbol == "textformat.size" })
        address.setReader(available: true, active: false)
        #expect(!address.readerButton.isSelected)
    }

    /// The count is a 12pt pill in the button's bottom-right corner, never past the button's edges, however long.
    @Test(arguments: ["1", "18", "999", "9999", "new"])
    func theCountPillStaysInsideTheButton(text: String) {
        let button = NSRect(x: 0, y: 0, width: AddressView.buttonSide, height: AddressView.buttonSide)
        let pill = BadgeView.frame(for: text, in: button, inset: BadgeView.buttonInset)
        #expect(button.contains(pill))
        #expect(pill.height == BadgeView.height)
        #expect(pill.width >= pill.height)
        #expect(pill.maxX == button.maxX - BadgeView.buttonInset && pill.maxY == button.maxY - BadgeView.buttonInset)
    }

    /// Placed by the badge itself, in the address's button (top-left origin) and a Site Controls tile alike.
    @Test func theCountIsPlacedTheSameInTheAddressAndATile() {
        let address = field()
        address.setPins([pin("a", badge: "18")], animated: false)
        guard let button = address.pinButton(for: "a"), let badge = button.subviews.compactMap({ $0 as? BadgeView }).first else {
            Issue.record("no badge"); return
        }
        badge.layout()
        #expect(badge.frame == BadgeView.frame(for: "18", in: button.bounds, inset: BadgeView.buttonInset))
        let tile = PanelTile(image: nil, symbol: "puzzlepiece.extension", caption: nil)
        tile.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        tile.badge = "18"
        guard let tileBadge = tile.subviews.compactMap({ $0 as? BadgeView }).first else { Issue.record("no tile badge"); return }
        tileBadge.layout()
        #expect(tileBadge.frame.size == badge.frame.size)
        #expect(tile.bounds.contains(tileBadge.frame))
    }

    /// The pin mark on a tile: inside the tile in its corner (top-left beside an attention dot), clear of the icon
    /// even when the icon fills its square, and never a target.
    @Test func aTilesPinMarkIsClearOfTheIconAndTakesNoClicks() {
        let tile = NSRect(x: 100, y: 50, width: SiteExtensionsLayout.tileSide, height: SiteExtensionsLayout.tileSide)
        let side = SiteExtensionsLayout.iconSide
        let icon = NSRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side)
        for left in [false, true] {
            let frame = PinMark.frame(on: tile, iconSide: side, left: left)
            #expect(tile.contains(frame))
            #expect(!frame.intersects(icon))
            #expect(frame.width > 0 && frame.minY == tile.minY)
            #expect(left ? frame.minX == tile.minX : frame.maxX == tile.maxX)
        }
        let mark = PinMark(onTile: true)
        #expect(mark.hitTest(NSPoint(x: mark.bounds.midX, y: mark.bounds.midY)) == nil)
        #expect(!mark.isAccessibilityElement())
    }

    @Test func aPopupOpeningClosesTheOtherOneInItsWindowOnly() {
        let windows = (NSObject(), NSObject())
        let window = ObjectIdentifier(windows.0), other = ObjectIdentifier(windows.1)
        let shown: [String: ObjectIdentifier?] = ["a": window, "b": other, "c": window, "new": window, "sheet": nil]
        #expect(Set(ExtensionPopups.makingWay(for: "new", in: window, among: shown)) == ["a", "c"])
        #expect(ExtensionPopups.makingWay(for: "new", in: window, among: ["new": window]).isEmpty)
        #expect(ExtensionPopups.makingWay(for: "x", in: nil, among: shown) == ["sheet"])
        withExtendedLifetime(windows) {}
    }

    /// A popup stays inside the window, shifting along or past the anchor's address field.
    @Test func aPopupStaysInsideTheWindow() {
        let room = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let margin = ExtensionPopups.windowMargin
        func popup(_ x: CGFloat, _ width: CGFloat) -> ClosedRange<CGFloat> { (x - width / 2)...(x + width / 2) }
        func inside(_ span: ClosedRange<CGFloat>) -> Bool { span.lowerBound >= room.minX + margin - 0.5 && span.upperBound <= room.maxX - margin + 0.5 }
        // Room to center: anchored at the middle.
        let page = NSRect(x: 600, y: 10, width: 26, height: 26)
        #expect(ExtensionPopups.pointingX(anchor: page, reach: page, width: 360, room: room) == page.midX)
        // Narrow popup under the sidebar address shifts right.
        let address = NSRect(x: 6, y: 40, width: 228, height: 30)
        let narrow = ExtensionPopups.pointingX(anchor: address, reach: address, width: 300, room: room)
        #expect(inside(popup(narrow, 300)) && address.contains(NSPoint(x: narrow, y: address.midY)))
        // Wider than twice the address: past its end, inside the window.
        let wide = ExtensionPopups.pointingX(anchor: address, reach: address, width: 500, room: room)
        #expect(inside(popup(wide, 500)) && wide > address.maxX - Tokens.Space.x3)
        // A pinned button near the edge shifts along its address.
        let pin = NSRect(x: 150, y: 44, width: 22, height: 22)
        let fromPin = ExtensionPopups.pointingX(anchor: pin, reach: address, width: 380, room: room)
        #expect(inside(popup(fromPin, 380)) && fromPin > pin.midX && fromPin <= address.maxX)
        let right = NSRect(x: 1250, y: 10, width: 26, height: 26)
        #expect(inside(popup(ExtensionPopups.pointingX(anchor: right, reach: right, width: 360, room: room), 360)))
        // Wider than the window: as centered as the address allows.
        #expect(ExtensionPopups.pointingX(anchor: address, reach: address, width: 2000, room: room) == address.maxX - Tokens.Space.x3)
    }

    @Test func keepingDropsOnlyWhatIsNoLongerKept() {
        #expect(ExtensionPins(ids: ["a", "b", "c"]).keeping { $0 != "b" }.ids == ["a", "c"])
    }

    @Test func removingAHiddenPinRemovesItsButton() {
        let address = AddressView(frame: NSRect(x: 0, y: 0, width: 200 + AddressView.buttonSide + 2, height: 30))
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        let button = address.pinButton(for: "a")
        #expect(button?.superview === address)
        address.setPins([pin("b"), pin("c")], animated: false)
        #expect(button?.superview == nil)
    }

    @Test func aPinRemovedDuringADragGoesEvenIfTheStoreSaysNothing() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        address.beginPinDrag("a", at: at(mid(address, "a")))
        address.movePinDrag(to: at(mid(address, "b") + 9))
        address.setPins([pin("a")], animated: false)
        address.endPinDrag(drop: true)
        #expect(address.pinButton(for: "b") == nil)
        #expect(address.visiblePinIDs == ["a"])
    }

    @Test func aDropWithPendingChangesKeepsTheDroppedOrder() {
        let address = field()
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        address.beginPinDrag("a", at: at(mid(address, "a")))
        address.movePinDrag(to: at(mid(address, "b") + 17))
        address.setPins([pin("a"), pin("b", badge: "2"), pin("c")], animated: false)
        address.endPinDrag(drop: true)
        #expect(address.visiblePinIDs == ["b", "a", "c"])
    }

    @Test func pinControlsAreOnlyRebuiltWhenWhatShowsChanges() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        let action = address.pinButton(for: "a")?.accessibilityCustomActions()?.first
        #expect(action != nil)
        address.layout()
        #expect(address.pinButton(for: "a")?.accessibilityCustomActions()?.first === action)
        address.setPins([pin("b"), pin("a")], animated: false)
        #expect(address.pinButton(for: "a")?.accessibilityCustomActions()?.first !== action)
    }

    private func fieldInWindow() -> (AddressView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        let address = field()
        window.contentView?.addSubview(address)
        return (address, window)
    }

    /// A space switch onto a page without Reader: the new host is placed at once at its full width, never drawn at the
    /// old page's width ("…eloper.apple.com").
    @Test func aNewHostIsPlacedAtOnce() {
        let (address, window) = fieldInWindow()
        address.setReader(available: true, active: false)
        address.show(url: URL(string: "https://example.com/"), notSecure: false)
        address.layoutSubtreeIfNeeded()
        let narrow = address.labelFrame
        address.show(url: URL(string: "https://developer.apple.com/"), notSecure: false)
        #expect(address.labelFrame == narrow)
        address.setReader(available: false, active: false)
        #expect(address.labelFrame.width == narrow.width + AddressView.buttonSide + 2)
        _ = window
    }

    /// Reader coming and going on the same page: the host takes its new width at once, never cut by the old width
    /// nor running under the new button.
    @Test func aButtonOnTheSamePageNeverCutsOrCoversTheHost() {
        let (address, window) = fieldInWindow()
        address.show(url: URL(string: "https://developer.apple.com/"), notSecure: false)
        address.layoutSubtreeIfNeeded()
        let wide = address.labelFrame
        address.setReader(available: true, active: false)
        #expect(address.labelFrame.maxX <= address.readerButton.frame.minX)
        address.setReader(available: false, active: false)
        #expect(address.labelFrame == wide)
        _ = window
    }

    /// The not-secure mark appearing before the same host: it glides right with its end already in place.
    @Test func onlyTheSameHostMovingRightGlides() {
        let old = NSRect(x: 10, y: 5, width: 150, height: 20), right = NSRect(x: 26, y: 5, width: 134, height: 20)
        #expect(AddressView.labelGlideStart(from: old, to: right, sameText: true) == old)
        #expect(AddressView.labelGlideStart(from: old, to: right, sameText: false) == nil)
        #expect(AddressView.labelGlideStart(from: right, to: old, sameText: true) == nil)
        #expect(AddressView.labelGlideStart(from: old, to: NSRect(x: 10, y: 5, width: 120, height: 20), sameText: true) == nil)
        let (address, window) = fieldInWindow()
        address.show(url: URL(string: "https://developer.apple.com/"), notSecure: false)
        address.layoutSubtreeIfNeeded()
        let before = address.labelFrame
        address.show(url: URL(string: "http://developer.apple.com/"), notSecure: true)
        #expect(address.labelFrame.minX == before.minX)
        #expect(address.labelFrame.maxX == before.maxX)
        _ = window
    }

    @Test func searches() {
        #expect(CommandRanker.url(from: "node.js") == nil)
        #expect(CommandRanker.url(from: "main.swiftui") == nil)
        #expect(CommandRanker.url(from: "user@example.com") == nil)
        #expect(CommandRanker.url(from: "foo..com") == nil)
        #expect(CommandRanker.url(from: "localhostfoo") == nil)
        #expect(CommandRanker.url(from: "hello world") == nil)
    }
}
