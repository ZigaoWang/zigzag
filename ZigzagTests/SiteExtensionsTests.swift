import AppKit
import Testing
@testable import Zigzag

/// The Extensions section of Site Controls (#215): in the panel itself, folded to a strip or open as rows or a grid
/// on the panel's text column, with badges and the extensions that don't work on the site dimmed.
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

    /// A section laid out in the panel's column, its choice as it was before, put back after.
    private func section(_ items: [SiteExtensionsSection.Item], open: Bool? = nil, whole: Bool = false, column: CGFloat? = nil,
                         _ check: (SiteExtensionsSection) -> Void) {
        let column = column ?? self.column
        let kept = SiteExtensionsSection.chosenOpen
        defer { SiteExtensionsSection.chosenOpen = kept }
        SiteExtensionsSection.chosenOpen = open
        let s = SiteExtensionsSection(items: items, isWhole: whole, profile: nil, get: {}, manage: {})
        let width = column + PanelLinkRow.outset * 2
        s.frame = NSRect(x: 0, y: 0, width: width, height: s.height(for: column))
        s.layoutSubtreeIfNeeded()
        check(s)
    }

    private func shown(_ s: SiteExtensionsSection) -> [InteractiveView] { s.buttons.filter { !$0.isHidden } }
    private func tiles(_ s: SiteExtensionsSection) -> [PanelTile] { s.buttons.compactMap { $0 as? PanelTile } }

    // MARK: Layout

    /// Pinned to the address first, then those that work on this site, then the rest, by name in each (#384).
    @Test func pinnedAndWorkingOnesComeFirst() {
        let all = items(5, access: { [0, 3].contains($0) ? .blocked : .runs })
        let ordered = SiteExtensionsSection.ordered(all.reversed(), pinned: ["ext3", "ext4"])
        #expect(ordered.map(\.id) == ["ext3", "ext4", "ext1", "ext2", "ext0"])
        #expect(SiteExtensionsSection.ordered(all, pinned: []).map(\.id) == ["ext1", "ext2", "ext4", "ext0", "ext3"])
    }

    @Test func noneIsOneQuietRow() {
        section([]) { s in
            #expect(s.height(for: column) == PanelLinkRow.height)
            #expect(shown(s).isEmpty)
            #expect(s.debugState["shown"] as? Int == 0)
        }
    }

    /// One to three are rows with their names, their icons on the panel's text column as its rows' words are.
    @Test func aFewAreNamedRows() {
        for count in [1, 3] {
            section(items(count)) { s in
                #expect(s.isOpen)
                #expect(shown(s).count == count)
                #expect(shown(s).allSatisfy { $0 is SiteExtensionRow })
                // Full width, the rows' wash past the column on each side, one under the other.
                #expect(shown(s).allSatisfy { $0.frame.minX == 0 && $0.frame.width == column + PanelLinkRow.outset * 2 })
                #expect(Set(shown(s).map(\.frame.minY)).count == count)
                // A section label's gap under the header's caps, then Manage as the list's next row.
                #expect(shown(s).first?.frame.minY == s.bodyTop)
                #expect(s.bodyTop > 0 && s.bodyTop < SiteExtensionsLayout.headerHeight)
                #expect(s.height(for: column) == s.bodyTop + CGFloat(count) * SiteExtensionRow.height
                        + CGFloat(count) * PanelLinkRow.gap + PanelLinkRow.height)
            }
        }
    }

    /// Four and more are a grid of icons: the first icon starts on the text column, the last column's ends on its
    /// right edge, and every one of them shows once open; the header's fold is the one way to show fewer.
    @Test func manyAreAGridOnTheTextColumn() {
        let cases: [(Int, CGFloat)] = [(4, 200), (9, 200), (9, 176), (20, 200), (20, 268)]
        for (count, columnWidth) in cases {
            section(items(count), open: true, column: columnWidth) { s in
                let grid = tiles(s)
                #expect(grid.count == count)
                #expect(shown(s).count == count)
                let columns = SiteExtensionsLayout.columns(width: columnWidth)
                let inset = (SiteExtensionsLayout.tileSide - SiteExtensionsLayout.iconSide) / 2
                // The first icon's edge on the text column, which starts `outset` into the section.
                #expect(grid[0].frame.minX + inset == PanelLinkRow.outset)
                if count >= columns {
                    // The last column's icon ends on the column's right edge, to the point.
                    let last = grid[columns - 1].frame
                    #expect(abs(last.maxX - inset - (PanelLinkRow.outset + columnWidth)) <= 0.5)
                }
                // Tiles never touch: at least the rows' gap apart, across and down.
                let rows = (count + columns - 1) / columns
                #expect(Set(grid.map(\.frame.minY)).count == rows)
                if columns > 1 { #expect(grid[1].frame.minX - grid[0].frame.maxX >= SiteExtensionsLayout.minGap - 0.5) }
                if rows > 1 { #expect(grid[columns].frame.minY - grid[0].frame.maxY >= SiteExtensionsLayout.minGap) }
                #expect(grid[0].frame.minY == s.bodyTop)
                #expect(s.height(for: columnWidth) == s.bodyTop
                        + SiteExtensionsLayout.bodyHeight(count: count, width: columnWidth) + PanelLinkRow.gap + PanelLinkRow.height)
            }
        }
    }

    @Test func columnsFitTheTextColumn() {
        // The sidebar at its narrowest, at its usual width, and a 300pt panel.
        #expect(SiteExtensionsLayout.columns(width: 176) == 5)
        #expect(SiteExtensionsLayout.columns(width: 200) == 5)
        #expect(SiteExtensionsLayout.columns(width: 268) == 7)
        let widths: [CGFloat] = [150, 176, 200, 233, 268]
        for width in widths {
            let columns = SiteExtensionsLayout.columns(width: width)
            let pitch = SiteExtensionsLayout.pitch(width: width, columns: columns)
            #expect(pitch - SiteExtensionsLayout.tileSide >= SiteExtensionsLayout.minGap)
            // One more wouldn't fit with its gap.
            #expect(CGFloat(columns + 1) * SiteExtensionsLayout.tileSide + CGFloat(columns) * SiteExtensionsLayout.minGap > width + PanelLinkRow.outset * 2)
            let gap = SiteExtensionsLayout.rowGap(width: width, columns: columns)
            #expect(gap >= SiteExtensionsLayout.minGap && gap <= SiteExtensionsLayout.maxRowGap)
            // Every tile on whole points, the last row's bottom at the grid's.
            let frames = (0..<20).map { SiteExtensionsLayout.tileFrame($0, width: width) }
            #expect(frames.allSatisfy { $0.minX == $0.minX.rounded() && $0.minY == $0.minY.rounded() }, "\(width)")
            #expect(frames.last?.maxY == SiteExtensionsLayout.bodyHeight(count: 20, width: width), "\(width)")
        }
        #expect(SiteExtensionsLayout.listed(count: 3))
        #expect(!SiteExtensionsLayout.listed(count: 4))
    }

    @Test func eightFoldToAStripUntilChosen() {
        section(items(8)) { s in
            #expect(!s.isOpen)
            #expect(shown(s).isEmpty)
            #expect(s.height(for: column) == SiteExtensionsLayout.headerHeight)
            let strip = s.debugState["strip"] as? Int ?? 0
            #expect(strip > 0 && strip < 8)
            #expect(s.debugState["more"] as? String == "+\(8 - strip)")
        }
        // Opened, all eight in a grid.
        section(items(8), open: true) { s in
            #expect(shown(s).count == 8)
            #expect(s.debugState["more"] as? String == "")
        }
    }

    @Test func theChoiceToFoldIsRemembered() {
        section(items(2)) { s in
            s.setOpen(false)
            #expect(SiteExtensionsSection.chosenOpen == false)
            #expect(!s.isOpen)
            #expect(s.height(for: column) == SiteExtensionsLayout.headerHeight)
        }
        section(items(2), open: false) { s in #expect(!s.isOpen) }
        section(items(15), open: true) { s in
            #expect(s.isOpen)
            #expect(shown(s).count == 15)
        }
    }

    /// On a new tab the section is the whole panel: open, every one, nothing to fold.
    @Test func aNewTabShowsThemAll() {
        section(items(15), open: false, whole: true) { s in
            #expect(s.isOpen)
            #expect(shown(s).count == 15)
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

    // MARK: Badge and access

    @Test func theBadgeShows() {
        section(items(5, badge: { $0 == 1 ? "12" : "" }), open: true) { s in
            #expect(tiles(s)[1].badge == "12")
            #expect(tiles(s)[0].badge.isEmpty)
            #expect(tiles(s)[1].accessibilityValue() as? String == "12")
        }
        // On a row, the same pill on its icon.
        section(items(2, badge: { $0 == 1 ? "12" : "" }), open: true) { s in
            #expect(s.buttons[1].accessibilityValue() as? String == "12")
        }
    }

    @Test func extensionsThatDontWorkHereAreDimmed() {
        let access: [SiteExtensionAccess] = [.runs, .onClick, .blocked, .offHere]
        section(items(4, access: { access[$0] }), open: true) { s in
            #expect(tiles(s).map(\.isDimmed) == [false, true, true, true])
            // Named under the pointer, and why it's dimmed.
            #expect(tiles(s)[0].toolTip == "Extension 0")
            #expect(tiles(s)[2].toolTip == "Extension 2\nCan’t read this site")
            // Still a button: a click on one that runs on click gives it the site.
            #expect(tiles(s)[1].isEnabled)
        }
        section(items(2, access: { access[$0 + 1] }), open: true) { s in
            #expect(s.buttons.compactMap { ($0 as? SiteExtensionRow)?.isDimmed } == [true, true])
            #expect(s.buttons[1].toolTip == "Extension 1\nCan’t read this site")
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

    // MARK: Pinning

    private final class FlippedBox: NSView {
        override var isFlipped: Bool { true }
    }

    /// A section with its pins wired as Site Controls wires them, `pinned` the extensions pinned.
    private func wired(_ s: SiteExtensionsSection, pinned: Set<String>) {
        s.wirePins(state: { pinned.contains($0) ? .pinned : .unpinned }, toggle: { _ in },
                   title: { pinned.contains($0) ? SitePanel.unpinTitle : SitePanel.pinTitle })
        s.layoutSubtreeIfNeeded()
    }

    /// Every point of a tile, its pinned corner too, is the tile's: nothing on it takes a click.
    @Test func everyPointOfATileOpensTheExtension() throws {
        for count in [2, 6] {
            section(items(count), open: true) { s in
                wired(s, pinned: ["ext1"])
                // In a flipped view of its own at the origin, so a point in the section is one in its superview.
                let container = FlippedBox(frame: s.frame)
                container.addSubview(s)
                #expect(s.debugPinMarks["ext1"] == true)
                #expect(s.debugPinMarks["ext0"] == false)
                for button in s.buttons {
                    let f = button.frame
                    for x in stride(from: f.minX + 0.5, to: f.maxX, by: 1) {
                        for y in stride(from: f.minY + 0.5, to: f.maxY, by: 1) {
                            let hit = s.hitTest(NSPoint(x: x, y: y))
                            guard hit !== button, hit?.isDescendant(of: button) != true else { continue }
                            Issue.record("\(type(of: hit)) took a click at \(x),\(y) on \(count) extensions")
                            return
                        }
                    }
                }
            }
        }
    }

    /// The mark shows only on a pinned extension, comes and goes as it's pinned, and folds away with the section.
    @Test func thePinMarkFollowsThePins() {
        section(items(5), open: true) { s in
            var pinned: Set<String> = []
            s.wirePins(state: { pinned.contains($0) ? .pinned : .unpinned }, toggle: { _ in }, title: { _ in nil })
            #expect(s.debugPinMarks.values.allSatisfy { !$0 })
            pinned = ["ext2"]
            s.refreshPins()
            #expect(s.debugPinMarks.filter(\.value).map(\.key) == ["ext2"])
            s.setOpen(false)
            #expect(s.debugPinMarks.values.allSatisfy { !$0 })
            s.setOpen(true)
            #expect(s.debugPinMarks["ext2"] == true)
        }
    }

    /// The menu's pin item says what pinning does now, and pinning reaches the address.
    @Test func theMenuPinsAndUnpinsToTheAddress() throws {
        let library = Library.shared
        let info = library.addProfile(name: "Pin menu test")
        let profile = Profiles.shared.profile(info.id)
        let installs = profile.installs
        let id = "pin-menu-test"
        defer {
            installs.unpin(id)
            library.removeProfile(info.id)
            library.finishedRemovingProfile(info.id)
        }
        var heard = 0
        let token = profile.extensions.changed.observe { heard += 1 }
        defer { token.cancel() }
        let pin = BrowserWindowController.pinItem(for: id, installs: installs)
        #expect(pin.title == SitePanel.pinTitle && pin.isEnabled)
        let menu = NSMenu()
        menu.addItem(pin)
        menu.performActionForItem(at: 0)
        #expect(installs.pins.contains(id))
        #expect(heard == 1)
        let unpin = BrowserWindowController.pinItem(for: id, installs: installs)
        #expect(unpin.title == SitePanel.unpinTitle)
        let again = NSMenu()
        again.addItem(unpin)
        again.performActionForItem(at: 0)
        #expect(!installs.pins.contains(id))
        #expect(heard == 2)
    }
}
