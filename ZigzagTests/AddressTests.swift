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

    @Test func copyLinkIsOfferedOnPagesWithAnAddressToShare() {
        for address in ["https://example.com/a?b=1", "http://localhost:3000", "webkit-extension://abc/options.html"] {
            #expect(URL(string: address)!.offersCopyLink, "\(address)")
        }
        for address in ["about:blank", "file:///tmp/a.html", "data:text/plain,hi", "zigzag://history", "zigzag://settings"] {
            #expect(!URL(string: address)!.offersCopyLink, "\(address)")
        }
    }

    @Test func aNewPinGoesLeftAndPinningTwiceChangesNothing() {
        let pins = ExtensionPins(ids: ["a", "b"]).pinning("c")
        #expect(pins.ids == ["c", "a", "b"])
        #expect(pins.pinning("a") == pins)
        #expect(pins.unpinning("a").ids == ["c", "b"])
    }

    @Test func onlyExtensionsThatAreOnUseASlot() {
        let pins = ExtensionPins(ids: ["a", "b", "c"], limit: 3)
        #expect(!pins.canPin(loaded: ["a", "b", "c", "d"]))
        #expect(pins.canPin(loaded: ["a", "b", "d"]))
    }

    @Test func theRightmostLoadedPinsShow() {
        let pins = ExtensionPins(ids: ["a", "b", "c", "d"], limit: 3)
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

    /// Text and button room is the field less the text's insets, Copy Link's 20pt and, on http, the mark's 16pt.
    @Test(arguments: [(224.0, 0.0, 1, 3), (224.0, 16.0, 1, 2), (200.0, 0.0, 1, 2), (200.0, 16.0, 1, 1), (200.0, 0.0, 3, 0), (200.0, 16.0, 3, 0)])
    func pinsFitTheField(field: Double, http: Double, others: Int, fits: Int) {
        #expect(AddressView.pinsThatFit(count: 3, otherButtons: others, room: field - 38 - http) == fits)
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

    @Test(arguments: [(1, 13.0, 1), (1, 14.0, 2), (1, -14.0, 0), (0, -100.0, 0), (2, 100.0, 2), (0, 56.0, 2)])
    func aCarriedPinTakesAPlaceOnceHalfwayThere(from: Int, dx: Double, slot: Int) {
        #expect(AddressView.pinSlot(from: from, dx: dx, count: 3) == slot)
    }

    @Test func whileAPinIsCarriedContentChangesAndStructureWaits() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        let button = address.pinButton(for: "a")
        #expect(address.beginPinDrag("b", atX: 100))
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
        address.beginPinDrag("a", atX: 100)
        address.movePinDrag(toX: 130)
        address.endPinDrag(drop: true)
        #expect(order == ["b", "a"])
    }

    @Test func callingOffADragChangesNothing() {
        let address = field()
        address.setPins([pin("a"), pin("b")], animated: false)
        var order: [String]?
        address.onPinsReordered = { order = $0 }
        address.beginPinDrag("a", atX: 100)
        address.movePinDrag(toX: 130)
        address.endPinDrag(drop: false)
        #expect(order == nil)
        #expect(address.visiblePinIDs == ["a", "b"])
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
        address.beginPinDrag("a", atX: 100)
        address.movePinDrag(toX: 130)
        address.setPins([pin("a")], animated: false)
        address.endPinDrag(drop: true)
        #expect(address.pinButton(for: "b") == nil)
        #expect(address.visiblePinIDs == ["a"])
    }

    @Test func aDropWithPendingChangesKeepsTheDroppedOrder() {
        let address = field()
        address.setPins([pin("a"), pin("b"), pin("c")], animated: false)
        address.beginPinDrag("a", atX: 100)
        address.movePinDrag(toX: 130)
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
