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
        #expect(try JSONDecoder().decode(ExtensionStore.State.self, from: json).version == "1.0")
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

    private func field() -> AddressView { AddressView(frame: NSRect(x: 0, y: 0, width: 224, height: 30)) }

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
        let address = AddressView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        #expect(address.visiblePinIDs == ["b", "c"])
        #expect(address.pinButton(for: "a")?.isHidden == true)
    }

    /// On a 224pt field the pins sit at 112, 140 and 168 (middles 125, 153, 181), Site Controls at 196.
    private func at(_ x: CGFloat, _ y: CGFloat = 15) -> NSPoint { NSPoint(x: x, y: y) }

    @Test func aCarriedPinStaysFaintInItsPlaceAndNothingElseMoves() {
        let address = field()
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        let frames = ["a", "b", "c"].map { address.pinButton(for: $0)?.frame }
        #expect(address.beginPinDrag("a", at: at(125)))
        address.movePinDrag(to: at(190))
        #expect(["a", "b", "c"].map { address.pinButton(for: $0)?.frame } == frames)
        #expect(address.pinButton(for: "a")?.alphaValue == CarriedCopy.faint)
        #expect(address.pinButton(for: "b")?.alphaValue == 1)
        #expect(address.pinDropDestination == 2)
        address.endPinDrag(drop: false)
        #expect(address.pinButton(for: "a")?.alphaValue == 1)
    }

    @Test(arguments: [(100.0, nil), (130.0, nil), (150.0, nil), (160.0, 1), (190.0, 2), (215.0, 2), (230.0, nil)] as [(Double, Int?)])
    func aPinDropsIntoTheGapUnderThePointer(x: Double, destination: Int?) {
        let address = field()
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        address.beginPinDrag("a", at: at(125))
        address.movePinDrag(to: at(x))
        #expect(address.pinDropDestination == destination)
    }

    @Test func offTheFieldAPinGoesBack() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        var order: [String]?
        address.onPinsReordered = { order = $0 }
        address.beginPinDrag("a", at: at(153))
        address.movePinDrag(to: at(190, 60))
        #expect(address.pinDropDestination == nil)
        address.endPinDrag(drop: true)
        #expect(order == nil)
        #expect(address.visiblePinIDs == ["a", "b"])
    }

    @Test func whileAPinIsCarriedContentChangesAndStructureWaits() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        let button = address.pinButton(for: "a")
        #expect(address.beginPinDrag("b", at: at(181)))
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
        address.beginPinDrag("a", at: at(153))
        address.movePinDrag(to: at(190))
        address.endPinDrag(drop: true)
        #expect(order == ["b", "a"])
    }

    @Test func callingOffADragChangesNothing() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        var order: [String]?
        address.onPinsReordered = { order = $0 }
        address.beginPinDrag("a", at: at(153))
        address.movePinDrag(to: at(190))
        address.endPinDrag(drop: false)
        #expect(order == nil)
        #expect(address.visiblePinIDs == ["a", "b"])
    }

    @Test func atTheLimitThePinOnATileOnlyExplains() {
        let pin = HoverPin()
        var clicks = 0
        pin.onClick = { _ in clicks += 1 }
        pin.state = .atLimit
        #expect(!pin.isEnabled)
        #expect(pin.toolTip == SitePanel.pinLimitTip)
        #expect(!pin.accessibilityPerformPress())
        pin.state = .unpinned
        #expect(pin.isEnabled)
        #expect(pin.accessibilityPerformPress())
        #expect(clicks == 1)
    }

    /// A pinned extension is one more of the field's buttons: Reader's and Site Controls' size, corners and press
    /// area, the same 2pt between every pair, its icon a site icon's 16pt in the middle.
    @Test func aPinnedButtonIsTheFieldsOwnButton() {
        let address = AddressView(frame: NSRect(x: 0, y: 0, width: 400, height: Tokens.Sidebar.addressHeight))
        address.setReader(available: true, active: false)
        address.setPins([pin("a", badge: "18"), pin("b")], animated: false)
        guard let a = address.pinButton(for: "a"), let b = address.pinButton(for: "b") else { Issue.record("no pins"); return }
        let row = [address.readerButton, a, b, address.siteControlsButton]
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

    /// The pin button on a tile: a 16pt chip inside the tile's top-right corner (top-left beside a count), a 20pt
    /// target around it.
    @Test func aTilesPinButtonIsEasyToHitAndInsideTheTile() {
        let tile = NSRect(x: 100, y: 50, width: 40, height: 40)
        for left in [false, true] {
            let frame = SitePanel.pinFrame(on: tile, left: left)
            #expect(frame.width >= 20 && frame.height >= 20)
            let pin = HoverPin()
            let chip = pin.chipFrame.offsetBy(dx: frame.minX, dy: frame.minY)
            #expect(chip.width == Tokens.Sidebar.hoverPinChip)
            #expect(tile.contains(chip))
            #expect(chip.minY == tile.minY + Tokens.Sidebar.hoverPinInset)
            #expect(left ? chip.minX == tile.minX + Tokens.Sidebar.hoverPinInset : chip.maxX == tile.maxX - Tokens.Sidebar.hoverPinInset)
        }
    }

    @Test func aTilesPinIsFilledOnlyOncePinned() {
        let pin = HoverPin()
        #expect(pin.symbol == "pin")
        pin.state = .pinned
        #expect(pin.symbol == "pin.fill")
        #expect(pin.toolTip == SitePanel.unpinTitle)
        pin.state = .unpinned
        #expect(pin.toolTip == SitePanel.pinTitle)
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

    @Test func keepingDropsOnlyWhatIsNoLongerKept() {
        #expect(ExtensionPins(ids: ["a", "b", "c"]).keeping { $0 != "b" }.ids == ["a", "c"])
    }

    @Test func removingAHiddenPinRemovesItsButton() {
        let address = AddressView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        let button = address.pinButton(for: "a")
        #expect(button?.superview === address)
        address.setPins([pin("b"), pin("c")], animated: false)
        #expect(button?.superview == nil)
    }

    @Test func aPinRemovedDuringADragGoesEvenIfTheStoreSaysNothing() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        address.beginPinDrag("a", at: at(153))
        address.movePinDrag(to: at(190))
        address.setPins([pin("a")], animated: false)
        address.endPinDrag(drop: true)
        #expect(address.pinButton(for: "b") == nil)
        #expect(address.visiblePinIDs == ["a"])
    }

    @Test func aDropWithPendingChangesKeepsTheDroppedOrder() {
        let address = field()
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        address.beginPinDrag("a", at: at(125))
        address.movePinDrag(to: at(170))
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

    @Test func searches() {
        #expect(CommandRanker.url(from: "node.js") == nil)
        #expect(CommandRanker.url(from: "main.swiftui") == nil)
        #expect(CommandRanker.url(from: "user@example.com") == nil)
        #expect(CommandRanker.url(from: "foo..com") == nil)
        #expect(CommandRanker.url(from: "localhostfoo") == nil)
        #expect(CommandRanker.url(from: "hello world") == nil)
    }
}
