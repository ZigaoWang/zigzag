import Foundation
import Testing
@testable import Zigzag

/// The page a space shows with no tab open: a `zigzag://` document, so the card shows it the one way it shows any
/// page, and nothing is drawn over a page as a view.
@MainActor
@Suite(.serialized)
struct ViewportPageTests {
    @Test func theBlankPageIsAZigzagPage() {
        #expect(ViewportPage.blank.scheme == HistoryPage.scheme)
        #expect(ViewportPage.blank.host() == "blank")
        #expect(ViewportPage.isBlank(ViewportPage.blank))
        #expect(!ViewportPage.isBlank(URL(string: "zigzag://history")!))
        #expect(!ViewportPage.isBlank(URL(string: "https://example.com/")!))
    }

    @Test func theBlankPageDrawsTheWordmarkItSays() {
        // The page carries the same drawing the app uses, from the same geometry (`WordmarkView.svg`).
        let html = ViewportPage.blankHTML(for: nil, isPrivate: false)
        #expect(html.contains("<svg"))
        #expect(html.contains("stroke-linecap=\"round\""))
        #expect(html.contains("var(--mark)"))
    }

    @Test func theBlankPageIsWrittenForBothAppearances() {
        // One document follows the window between light and dark, as the other zigzag:// pages do, so turning the
        // window dark never has to serve the page again.
        let html = ViewportPage.blankHTML(for: nil, isPrivate: false)
        #expect(html.contains("prefers-color-scheme: dark"))
        #expect(html.contains("--ground:"))
    }

    @Test func aPrivateWindowIgnoresTheSpace() {
        // A private window is the same whatever space it's in, as the native empty card is: its ground is the plain
        // card, never the space's wash or picture.
        let tinted = SpaceInfo(name: "Sky", color: .sky)
        #expect(ViewportPage.blankHTML(for: tinted, isPrivate: true) == ViewportPage.blankHTML(for: nil, isPrivate: true))
        #expect(ViewportPage.blankHTML(for: tinted, isPrivate: true) != ViewportPage.blankHTML(for: tinted, isPrivate: false))
    }

    @Test func aBlankAddressNamesTheSpaceItIsFor() {
        // What the card and the Mini ask for is the whole request: the page is served to a child window too, so no
        // part of it may come from whichever window is key.
        let id = UUID()
        #expect(ViewportPage.blankRequest(in: ViewportPage.blankURL(for: id, isPrivate: false))?.space == id)
        #expect(ViewportPage.blankRequest(in: ViewportPage.blankURL(for: id, isPrivate: false))?.isPrivate == false)
        #expect(ViewportPage.blankRequest(in: ViewportPage.blankURL(for: id, isPrivate: true))?.isPrivate == true)
        // A bare `zigzag://blank` asks for no space: the plain card, not a guess.
        #expect(ViewportPage.blankRequest(in: ViewportPage.blank)?.space == nil)
        #expect(ViewportPage.blankRequest(in: URL(string: "zigzag://history")!) == nil)
    }

    @Test func aPageIsDrawnForTheSpaceInItsAddress() {
        // The address names the space, and the page is drawn from it. The resolver stands in for the Library, so a
        // lookup that read a window (or the Library) instead of the address could not draw this space at all: it is
        // not in the Library, and no window is key here.
        let wanted = SpaceInfo(name: "Sky", color: .sky)
        let other = SpaceInfo(name: "Mint", color: .mint)
        let html = ViewportPage.html(for: ViewportPage.blankURL(for: wanted.id, isPrivate: false)) { id in
            id == wanted.id ? wanted : other
        }
        #expect(html == ViewportPage.blankHTML(for: wanted, isPrivate: false))
        #expect(html != ViewportPage.blankHTML(for: other, isPrivate: false))
        #expect(html != ViewportPage.blankHTML(for: nil, isPrivate: false), "the plain card, as a guess would draw")
        // The address carries the privacy too, so a private window's page is the private one whichever window is key.
        let privateHTML = ViewportPage.html(for: ViewportPage.blankURL(for: wanted.id, isPrivate: true)) { _ in wanted }
        #expect(privateHTML == ViewportPage.blankHTML(for: wanted, isPrivate: true))
    }

    @Test func theAddressCarriesThePictureItDraws() {
        // A picture change must be a different address, or a reload could hand back the document with the old photo.
        // Only a picture Zigzag actually kept goes in it, and a private window's address never names one.
        let id = UUID()
        let kept = SpaceBackground.freshName(for: id)
        #expect(ViewportPage.blankRequest(in: ViewportPage.blankURL(for: id, isPrivate: false, picture: kept))?.picture == nil,
                "nothing was stored under this name")
        #expect(ViewportPage.blankRequest(in: ViewportPage.blankURL(for: id, isPrivate: true, picture: kept))?.picture == nil)
        // The page draws the picture its address names.
        let html = ViewportPage.blankHTML(for: nil, isPrivate: false, picture: kept)
        #expect(html.contains("\(ViewportPage.pictureHost)?name=\(kept)"))
        #expect(!ViewportPage.blankHTML(for: nil, isPrivate: true, picture: kept).contains("blank-picture?name="))
    }

    @Test func theBlankPageHasNoChromeOfItsOwn() {
        let html = ViewportPage.blankHTML(for: nil, isPrivate: false)
        // Nothing to press, nothing to select, nothing to scroll: the card is a page, not a control.
        #expect(!html.contains("<button"))
        #expect(!html.contains("<a "))
        #expect(html.contains("-webkit-user-select:none"))
        #expect(html.contains("overflow:hidden"))
    }

    @Test func theBlankPageHasNoBridge() {
        // It asks Zigzag for nothing, so it registers no message handler and needs no script of its own.
        let html = ViewportPage.blankHTML(for: nil, isPrivate: false)
        #expect(!html.contains("messageHandlers"))
        #expect(!html.contains("<script"))
    }

    @Test func aPictureIsServedFromZigzagsOwnFolder() {
        // The stored name is a file in Zigzag's folder, which a page can't read: the page asks for it by name and the
        // route answers with its bytes. A name that is not one of Zigzag's own is never served.
        let name = SpaceBackground.freshName(for: UUID())
        let url = URL(string: "zigzag://\(ViewportPage.pictureHost)?name=\(name)")!
        #expect(ViewportPage.pictureName(in: url) == nil, "nothing was stored under this name")
        #expect(ViewportPage.pictureName(in: URL(string: "zigzag://\(ViewportPage.pictureHost)?name=../../etc/passwd")!) == nil)
        #expect(ViewportPage.pictureName(in: URL(string: "zigzag://\(ViewportPage.pictureHost)")!) == nil)
        #expect(ViewportPage.pictureName(in: URL(string: "zigzag://icon?name=\(name)")!) == nil)
    }
}
