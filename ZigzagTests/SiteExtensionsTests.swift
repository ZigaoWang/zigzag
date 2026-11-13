import AppKit
import Testing
@testable import Zigzag

/// The Extensions section of Site Controls (#215): in the panel itself, folded to a strip or open as tiles, with
/// badges and the extensions that don't work on the site dimmed.
@MainActor
@Suite(.serialized)
struct SiteExtensionsTests {
    /// The sidebar's usual lane: a 224pt panel, its 200pt text column.
    private let column: CGFloat = 200

    private func items(_ count: Int, badge: (Int) -> String = { _ in "" },
                       access: (Int) -> SiteExtensionAccess = { _ in .runs }) -> [SiteExtensionsSection.Item] {
        (0..<count).map { i in
            .init(id: "ext\(i)", name: "Extension \(i)", label: "Extension \(i)", icon: nil, badge: badge(i), needsAttention: false,
                  access: access(i), run: { _ in }, menu: { nil })
        }
    }

    /// A section laid out in the panel's column, its choices as they were before, put back after.
    private func section(_ items: [SiteExtensionsSection.Item], open: Bool? = nil, showsAll: Bool = false, whole: Bool = false,
                         _ check: (SiteExtensionsSection) -> Void) {
        let keptOpen = SiteExtensionsSection.chosenOpen, keptAll = SiteExtensionsSection.showsAll
        defer { SiteExtensionsSection.chosenOpen = keptOpen; SiteExtensionsSection.showsAll = keptAll }
        SiteExtensionsSection.chosenOpen = open
        SiteExtensionsSection.showsAll = showsAll
        let s = SiteExtensionsSection(items: items, isWhole: whole, profile: nil, get: {}, manage: {})
        let width = column + PanelLinkRow.outset * 2
        s.frame = NSRect(x: 0, y: 0, width: width, height: s.height(for: column))
        s.layoutSubtreeIfNeeded()
        check(s)
    }

    private func shownTiles(_ s: SiteExtensionsSection) -> [PanelTile] { s.tiles.filter { !$0.isHidden } }

    // MARK: Layout

    @Test func noneIsOneQuietRow() {
        section([]) { s in
            #expect(s.height(for: column) == PanelLinkRow.height)
            #expect(shownTiles(s).isEmpty)
            #expect(s.debugState["tiles"] as? Int == 0)
        }
    }

    @Test func oneOrTwoAreOpenAndNamed() {
        for count in [1, 2] {
            section(items(count)) { s in
                #expect(s.isOpen)
                #expect(shownTiles(s).count == count)
                // Named, half the row each, side by side at the left: no empty grid around them.
                #expect(SiteExtensionsLayout.named(count: count))
                #expect(shownTiles(s).allSatisfy { $0.frame.height == PanelTile.captionedHeight })
                #expect(shownTiles(s).first?.frame.minX == PanelLinkRow.outset)
                #expect(shownTiles(s).first?.frame.width == floor(column / 2))
            }
        }
    }

    @Test func eightFoldToAStripUntilChosen() {
        section(items(8)) { s in
            #expect(!s.isOpen)
            #expect(shownTiles(s).isEmpty)
            #expect(s.height(for: column) == SiteExtensionsLayout.headerHeight)
            let strip = s.debugState["strip"] as? Int ?? 0
            #expect(strip > 0 && strip < 8)
            #expect(s.debugState["more"] as? String == "+\(8 - strip)")
        }
        // Opened, all eight in two rows of a grid, no Show All.
        section(items(8), open: true) { s in
            #expect(shownTiles(s).count == 8)
            #expect(s.debugState["showAll"] as? String == "")
            #expect(Set(shownTiles(s).map(\.frame.minY)).count == 2)
        }
    }

    @Test func fifteenShowTwoRowsThenShowAll() {
        let columns = SiteExtensionsLayout.columns(width: column)
        section(items(15), open: true) { s in
            #expect(shownTiles(s).count == columns * 2)
            #expect(s.debugState["showAll"] as? String == "Show All (15)")
            #expect(Set(shownTiles(s).map(\.frame.minY)).count == 2)
        }
        section(items(15), open: true, showsAll: true) { s in
            #expect(shownTiles(s).count == 15)
            #expect(s.debugState["showAll"] as? String == "Show Less")
            #expect(Set(shownTiles(s).map(\.frame.minY)).count == 3)
        }
    }

    @Test func theChoiceToFoldIsRemembered() {
        section(items(2)) { s in
            s.setOpen(false)
            #expect(SiteExtensionsSection.chosenOpen == false)
            #expect(!s.isOpen)
        }
        section(items(2), open: false) { s in #expect(!s.isOpen) }
        section(items(15), open: true) { s in #expect(s.isOpen) }
    }

    /// On a new tab the section is the whole panel: open, every tile, nothing to fold.
    @Test func aNewTabShowsThemAll() {
        section(items(15), open: false, whole: true) { s in
            #expect(s.isOpen)
            #expect(shownTiles(s).count == 15)
            #expect(s.debugState["showAll"] as? String == "")
            s.setOpen(false)
            #expect(s.isOpen)
        }
    }

    @Test func defaults() {
        #expect(SiteExtensionsLayout.isOpen(count: 1, chosen: nil))
        #expect(SiteExtensionsLayout.isOpen(count: 4, chosen: nil))
        #expect(!SiteExtensionsLayout.isOpen(count: 5, chosen: nil))
        #expect(SiteExtensionsLayout.isOpen(count: 15, chosen: true))
        #expect(!SiteExtensionsLayout.isOpen(count: 2, chosen: false))
    }

    @Test func theStripFitsItsRoom() {
        let side = SiteExtensionsLayout.stripSide
        #expect(SiteExtensionsLayout.strip(count: 2, room: side * 4) == (2, 0))
        #expect(SiteExtensionsLayout.strip(count: 8, room: side * 4) == (3, 5))
        // Never more than its slots, however wide.
        #expect(SiteExtensionsLayout.strip(count: 15, room: 1_000) == (SiteExtensionsLayout.stripSlots - 1, 15 - SiteExtensionsLayout.stripSlots + 1))
        #expect(SiteExtensionsLayout.strip(count: 6, room: 1_000) == (6, 0))
        #expect(SiteExtensionsLayout.strip(count: 3, room: 0) == (0, 3))
    }

    @Test func showAllAfterTwoRows() {
        #expect(SiteExtensionsLayout.shown(count: 10, columns: 5, showsAll: false) == (10, false))
        #expect(SiteExtensionsLayout.shown(count: 15, columns: 5, showsAll: false) == (10, true))
        #expect(SiteExtensionsLayout.shown(count: 15, columns: 5, showsAll: true) == (15, true))
        #expect(SiteExtensionsLayout.columns(width: 268) == 6)
        #expect(SiteExtensionsLayout.columns(width: 200) == 5)
        #expect(SiteExtensionsLayout.columns(width: 176) == 4)
    }

    // MARK: Badge and access

    @Test func theBadgeShows() {
        section(items(3, badge: { $0 == 1 ? "12" : "" }), open: true) { s in
            #expect(s.tiles[1].badge == "12")
            #expect(s.tiles[0].badge.isEmpty)
            #expect(s.tiles[1].accessibilityValue() as? String == "12")
        }
    }

    @Test func extensionsThatDontWorkHereAreDimmed() {
        let access: [SiteExtensionAccess] = [.runs, .onClick, .blocked, .offHere]
        section(items(4, access: { access[$0] }), open: true) { s in
            #expect(s.tiles.map(\.isDimmed) == [false, true, true, true])
            #expect(s.tiles[0].toolTip == "Extension 0")
            #expect(s.tiles[2].toolTip == "Extension 2\nCan’t read this site")
            // Still a button: a click on one that runs on click gives it the site.
            #expect(s.tiles[1].isEnabled)
        }
    }

    @Test func accessFromWhatTheExtensionWants() {
        typealias A = SiteExtensionAccess
        #expect(A.of(offHere: false, hasAccess: true, wantsSite: true, clickAccess: false) == .runs)
        // A popup of its own that never asks for any site works anywhere.
        #expect(A.of(offHere: false, hasAccess: false, wantsSite: false, clickAccess: false) == .runs)
        #expect(A.of(offHere: false, hasAccess: false, wantsSite: true, clickAccess: true) == .onClick)
        #expect(A.of(offHere: false, hasAccess: false, wantsSite: true, clickAccess: false) == .blocked)
        #expect(A.of(offHere: true, hasAccess: true, wantsSite: true, clickAccess: false) == .offHere)
        #expect(!A.runs.isDimmed && A.blocked.isDimmed && A.runs.note == nil)
    }
}
