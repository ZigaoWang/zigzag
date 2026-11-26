import AppKit

/// The single source of truth for every visual decision in Zigzag. The system these values make, its layers,
/// materials, type, spacing, radii, states and motion, is written down in Design/DESIGN.md: build to it.
/// Views never use literal numbers or colors; they reach in here.
enum Tokens {

    // MARK: - Spacing (4pt grid)

    enum Space {
        static let grid: CGFloat = 4
        static let x1: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        static let x5: CGFloat = 20
        static let x6: CGFloat = 24
        static let x8: CGFloat = 32
        static let x10: CGFloat = 40
        static let x12: CGFloat = 48
        static let x16: CGFloat = 64
        /// The height of a compact button in forms and panels.
        static let x7Height: CGFloat = 28

        /// Rounds a value onto the 4pt grid.
        static func snap(_ value: CGFloat) -> CGFloat { (value / grid).rounded() * grid }
    }

    // MARK: - Corner radii

    /// One scale, a step apart: small 4, control 6, field 8, row 10, tile 12, panel 14, large 16.
    enum Radius {
        /// The web page card. Concentric with the window corner at an 8pt inset.
        static let card: CGFloat = 8
        /// The window's own corner. A page that meets the window's edges takes it, so the two curves match.
        static let window: CGFloat = 16
        /// The page's corners beside the sidebar when it meets the window's edges: the window's own curve, so all four
        /// of the page's corners match.
        static let attached: CGFloat = window
        /// A row in a floating list or on a page. The sidebar's rows are tighter (`Sidebar.rowRadius`).
        static let row: CGFloat = 10
        /// A glass tile (`GlassTile`).
        static let tile: CGFloat = 12
        static let control: CGFloat = 6
        /// Fields, pills, menu buttons and filter segments: a step rounder than a plain control.
        static let field: CGFloat = 8
        static let small: CGFloat = 4
        /// Grouped cards on a window's background: Settings and Passwords groups, the site panel's sections.
        static let group: CGFloat = 10
        /// Floating surfaces: command bar, previews, menus.
        static let panel: CGFloat = 14
        /// Large floating surfaces that hold rounded things of their own: the tab switcher, Reader's options, the tour.
        static let large: CGFloat = 16
        static let thumbnail: CGFloat = 8
    }

    // MARK: - Layout metrics

    enum Metric {
        static let cardInset: CGFloat = Space.x2
        /// The gap between split panes whose page meets the window's edges (borderless beside the sidebar).
        static let paneGutter: CGFloat = Space.x1
        static let sidebarWidth: CGFloat = 240
        /// The narrowest the sidebar gets: room for the traffic lights and the toolbar's four icon buttons.
        static let sidebarMinWidth: CGFloat = 216
        static let sidebarMaxWidth: CGFloat = 400
        static let sidebarPadding: CGFloat = Space.x2
        /// A sidebar row: relaxed, with room around 14pt text. With `rowGap` the rows sit 36pt apart.
        static let rowHeight: CGFloat = Space.x8 + 2
        static let rowGap: CGFloat = 2
        /// A section's quiet label (the space's name, Tabs): the label sits low, with generous room above it.
        static let sectionLabelHeight: CGFloat = Space.x8
        /// Hit targets: one size for every icon button you reach for (the toolbar, the bottom bar, a pane's header,
        /// the find bar, a panel's close), and a compact one for buttons inside a row or a field (a tab's close, the
        /// address's Reader). The hover fill shows the whole target.
        static let iconButton: CGFloat = Space.x8
        static let compactIconButton: CGFloat = Space.x6
        /// One control height on pages and in panels: pill buttons, dropdowns, the search field, a menu's rows.
        static let controlHeight: CGFloat = Space.x7Height
        /// A row's picture: a favicon, or a symbol (`Symbol.row`) in its place. The same in the sidebar, on pages,
        /// in panels and in the command bar, so rows line up wherever they are.
        static let favicon: CGFloat = 18
        static let sectionGap: CGFloat = Space.x4
        /// With the sidebar hidden, the strip just inside the window's edge where the pointer brings it out.
        static let edgeRevealWidth: CGFloat = Space.x2
        /// How far out past that edge the pointer still counts as at it: room to overshoot onto the desktop or the
        /// next display, as a hand reaching for the edge does with another screen beside the window (a report: a
        /// slow move stopping 54pt over left the sidebar hidden at 32), and no more, so a pointer on its way well into
        /// the other screen leaves the sidebar be.
        static let edgeRevealReach: CGFloat = Space.x16 + Space.x4
        static let resizeHandleWidth: CGFloat = Space.x2
        /// How far past a drawn edge you drag (the sidebar's, a split's line) the pointer still takes it, into a page;
        /// half that on a page's scroll bar side, so the scroll bar stays the page's (#362).
        static let dragReach: CGFloat = Space.x1
        /// How far into the sidebar its edge takes the pointer: the empty strip beside its rows, and a little of them.
        static var sidebarDragReach: CGFloat { Sidebar.edge + Space.x1 }
        static let hairline: CGFloat = 1
        /// Keyboard focus: the ring's width, and its gap outside the control.
        static let focusRing: CGFloat = 2
        static let focusGap: CGFloat = 2
        /// A drop target's accent edge (`Color.dropAlpha`), and how far a split's half sits inside the row or tile
        /// it would open beside.
        static let dropEdge: CGFloat = 1.5
        static let dropInset: CGFloat = 3
        /// Zigzag's switch (`Toggle`): track and knob.
        static let toggleSize = NSSize(width: 34, height: 20)
        static let toggleKnob: CGFloat = 14
        /// A field being typed in or recording: the accent ring's width.
        static let fieldRing: CGFloat = 1.5
        /// A list's bullet (What's New).
        static let bullet: CGFloat = 5
        static let commandBarWidth: CGFloat = 640
        static let commandBarFieldHeight: CGFloat = Space.x12 + Space.x2
        static let commandBarRowHeight: CGFloat = Space.x10
        static let commandBarMaxRows: Int = 8
        static let previewWidth: CGFloat = 320
        static let switcherThumbWidth: CGFloat = 224
        /// The narrowest a Control+Tab card gets before the cards go into rows: its title still reads.
        static let switcherThumbMinWidth: CGFloat = 184
        /// How far a zoomed pane's card sits in from the page area's edges.
        static let zoomInsetRatio: CGFloat = 0.08
        static let findBarWidth: CGFloat = 320
        static let popupDefaultSize = NSSize(width: 520, height: 640)
        /// Zigzag Mini, for one page opened from another app: big enough to read, small enough to stay out of the way.
        static let miniWindowSize = NSSize(width: 900, height: 640)
        /// The smallest Zigzag Mini gets: its strip's lights, its space and its button, over a page you can read.
        static let miniWindowMinSize = NSSize(width: 360, height: 260)
        /// Zigzag Mini's strip on top: as slim as a split view pane's, the traffic lights centered in it.
        static let miniStripHeight: CGFloat = Pane.height
        /// A Mini docked in a page opens at the old Peek's size: 8% of the page card in from each side, a little
        /// less above and below.
        static let miniPeekInsetRatio: CGFloat = 0.08
        /// The space's color around Zigzag Mini's page, on its sides and below: a thin, even frame.
        static let miniFrame: CGFloat = Space.x1 + 2
        /// ⌘L's command bar over Zigzag Mini's strip, at its widest before you type.
        static let miniAddressWidth: CGFloat = 480
        static let windowDefaultSize = NSSize(width: 1280, height: 820)
        /// A site installed as an app, the first time it opens: a working window, smaller than the browser's.
        static let webAppWindowSize = NSSize(width: 1120, height: 760)
        /// An installed app with its toolbar off: the title bar it doesn't draw, which the traffic lights center in
        /// and which moves the window around them.
        static let webAppTitleBarHeight: CGFloat = 28
        /// The same, across the rest of the top: a band thin enough to leave the page's own controls under it alone.
        static let webAppDragBand: CGFloat = Space.x2
        static let windowMinSize = NSSize(width: 560, height: 400)
        static let deskCardWidth: CGFloat = 176
        static let deskCardMaxWidth: CGFloat = 440
        /// A toast, a floating capsule at the page's top; its action is a pill this tall, inset evenly.
        static let toastHeight: CGFloat = Space.x8 + Space.x1
        static let toastButtonHeight: CGFloat = Space.x7Height
        /// Find bar height matches a toast, so a toast beside it lines up; its buttons match a toast's action.
        static let findBarHeight: CGFloat = toastHeight
        static let findBarButton: CGFloat = toastButtonHeight
        /// Where a hovered link goes: the small floating capsule in the page's bottom-left corner.
        static let linkStatusHeight: CGFloat = Space.x6
        /// A keycap (`KeyCap`): Return on a chosen result, Tab beside "Search YouTube".
        static let keyCapHeight: CGFloat = Space.x5 - 2
        /// A small round button floating over a page edge on its own (swipe arrows, the stand-in Downloads button).
        static let floatingButton: CGFloat = Space.x8 + Space.x1
        /// A tab preview's caption under the picture.
        static let previewCaptionHeight: CGFloat = Space.x12
        /// Capture's toolbar (⇧⌘2): a capsule of control-height buttons, `Space.x1 + 2` in from its edge.
        static let captureToolbarHeight: CGFloat = controlHeight + (Space.x1 + 2) * 2
        /// The round grips on a captured area's corners and sides.
        static let captureHandle: CGFloat = Space.x2 + 1
        /// A drag shorter than this either way is a click, not an area.
        static let captureMinSide: CGFloat = Space.x2
        /// The card that shows a capture, and the tallest its picture gets.
        static let capturePreviewWidth: CGFloat = 240
        static let capturePreviewMaxImage: CGFloat = 160
    }

    // MARK: - Pages

    /// Zigzag's built-in pages (History, Settings) and, from here on, its other surfaces: one plain surface, the
    /// small wordmark and a semibold title at the top left, the search field and actions at the top right, quiet
    /// rows under it. History's CSS is generated from these values (`PageStyle`), so the two never drift.
    /// The sidebar's own proportions: compact and precise, in the spirit of Linear and shadcn on the window's glass.
    /// 13pt rows 30 tall, 16pt favicons, small favorites as many to a row as fit, 26pt toolbar buttons with 14pt glyphs. Nothing
    /// bigger than its role needs. Light structure, always visible: faint fills and 1px edges on the address and the
    /// favorites, a clear fill on the row you're on. One left edge runs down it: the traffic lights and every icon at
    /// 12pt, every title and label at 36pt. Pages (Settings, History) keep the calmer app scale (`Metric`,
    /// `TypeSize.row`).
    enum Sidebar {
        /// Settings › Appearance › Sidebar size (#183, #361), as macOS's own Sidebar icon size: the rows' text, icons
        /// and heights, the space's name, the favorites' tiles and the address, all together. Medium is the sizes
        /// written here; the toolbar's buttons, the traffic lights and the gaps between things stay as they are.
        enum Size: String, CaseIterable {
            case small, medium, large
            /// The size you set, as a percentage of Medium.
            case custom

            var scale: CGFloat {
                switch self {
                case .small: 0.9
                case .medium: 1
                case .large: 1.15
                case .custom: Sidebar.customScale
                }
            }
        }

        /// The sidebar's scale now: its size's, and for Custom, the percentage set.
        static var scale: CGFloat { current.scale }

        /// The custom size's percents, 80 to 150 by 5: what the − and + beside Sidebar size step through.
        static let customSteps: [CGFloat] = stride(from: 80, through: 150, by: 5).map { CGFloat($0) / 100 }

        /// The custom size's scale, 0.8 to 1.5: written back in whole percents within that range, so every size it
        /// makes is one the sidebar can lay out. Every part of the sidebar lays itself out again when it changes.
        static var customScale: CGFloat {
            get { CGFloat(customPercent) / 100 }
            set {
                let percent = min(max(Int((newValue * 100).rounded()), 80), 150)
                guard percent != customPercent else { return }
                customPercent = percent
                UserDefaults.standard.set(percent, forKey: "SidebarSizePercent")
                // Another size doesn't read it, so nothing would move.
                if current == .custom { NotificationCenter.default.post(name: sizeChanged, object: nil) }
            }
        }

        static var size: Size {
            get { current }
            set {
                guard newValue != current else { return }
                current = newValue
                UserDefaults.standard.set(newValue.rawValue, forKey: "SidebarSize")
                NotificationCenter.default.post(name: sizeChanged, object: nil)
            }
        }
        /// Posted after `size` changes: the sidebar and the addresses set their rows again.
        static let sizeChanged = Notification.Name("SidebarSizeChanged")
        /// Read once: the sidebar asks for its sizes on every layout.
        private static var current: Size = UserDefaults.standard.string(forKey: "SidebarSize").flatMap(Size.init(rawValue:)) ?? .medium
        /// A custom percentage as kept: 100 if none was kept, and within 80 to 150.
        static func keptCustomPercent(_ stored: Int?) -> Int { min(max(stored ?? 100, 80), 150) }
        /// Custom's percentage, read once and written as it changes.
        /// `integer(forKey:)` also reads it when it was set as text, like `-SidebarSizePercent 120` at launch.
        private static var customPercent = keptCustomPercent(UserDefaults.standard.object(forKey: "SidebarSizePercent") == nil ? nil
            : UserDefaults.standard.integer(forKey: "SidebarSizePercent"))

        /// A Medium size at the size chosen, in whole points.
        static func scaled(_ value: CGFloat, for size: Size? = nil) -> CGFloat { (value * (size?.scale ?? scale)).rounded() }
        /// The same for a height or an icon, in even points, so what's centered in it lands on whole points.
        static func scaledEven(_ value: CGFloat, for size: Size? = nil) -> CGFloat { (value * (size?.scale ?? scale) / 2).rounded() * 2 }

        /// From the sidebar's edges to its rows, favorites and address.
        static let edge: CGFloat = 6
        /// The icon column (12), from the sidebar's leading edge.
        static var iconColumn: CGFloat { edge + rowInset }
        /// A row's title (tabs, pinned pages, folders, New Tab) and the address's host.
        static var rowText: CGFloat { scaled(TypeSize.body) }
        /// A section's label ("Personal", "Tabs", Clear): small, medium, muted.
        static var labelText: CGFloat { scaled(TypeSize.small) }
        /// A row, and the gap between two: rows sit 32pt apart.
        static var rowHeight: CGFloat { scaledEven(30) }
        static let rowGap: CGFloat = 2
        /// A row's favicon, or the symbol in its place.
        static var favicon: CGFloat { scaledEven(16) }
        static func favicon(for size: Size) -> CGFloat { scaledEven(16, for: size) }
        /// Minimum title width in a split row; narrower shows only the icon.
        static func splitTitleMin(for size: Size? = nil) -> CGFloat { scaled(20, for: size) }
        /// From a row's edge to its icon, and from the icon to its title's first letter.
        static let rowInset: CGFloat = 6
        static let iconGap: CGFloat = Space.x2
        /// From a title's last letter to a symbol in its line (a tab's speaker): a word space at the title's size.
        static let inlineGlyphGap: CGFloat = 4.5
        /// The corners of small things in the sidebar: a row's fill, a favorite, a button.
        static let rowRadius: CGFloat = Radius.control
        /// A row's own small buttons (a tab's close and mute): a 20pt target, an 11pt glyph.
        static var rowButton: CGFloat { scaledEven(20) }
        static var rowGlyph: CGFloat { scaled(11) }
        /// Developer Mode's mark on a tab's icon (#141): a round chip on the icon's bottom-trailing corner, its side a
        /// share of the icon's (so it scales with every sidebar size and a favorite's larger icon), reaching
        /// `developerBadgeOverhang` of its side past the icon's corner, with the mode's hammer knocked out of it at
        /// `developerGlyphShare` of the chip. The icon (and its ring, its loader) is cut away round it by
        /// `developerBadgeGap`, so the chip stands clear on any ground.
        static let developerBadgeShare: CGFloat = 0.5
        static let developerBadgeOverhang: CGFloat = 0.3
        static let developerGlyphShare: CGFloat = 0.72
        static let developerBadgeGap: CGFloat = 1
        /// A live folder's chip has the feed mark in it: its box `feedMarkShare` of the chip, its lines `feedLineShare`.
        static let feedMarkShare: CGFloat = 0.64
        static let feedLineShare: CGFloat = 0.12
        /// A section label's slot, the label low in it.
        static var labelHeight: CGFloat { scaledEven(24) }
        /// The space's name over its pinned tabs: larger and light, the one heading in the sidebar, with room above it.
        static var spaceNameText: CGFloat { scaled(26) }
        static var spaceNameHeight: CGFloat { scaledEven(36) }
        /// Tracking for the space's name, in points: display type sits tighter.
        /// A space key in the bottom bar: a small rounded key with its number, 4pt between keys.
        static let spaceKey: CGFloat = 18
        /// Between the favorites and the list.
        static let sectionGap: CGFloat = Space.x3

        /// Favorites: as many to a row as fit at least `favoriteMinWidth` wide (three at the sidebar's usual width,
        /// four from about 255, up to `favoriteMaxColumns`), or as many as chosen in Settings; soft tiles.
        static var favoriteMinWidth: CGFloat { scaled(56) }
        /// The narrowest a favorite gets so its row comes out whole instead of leaving one tile alone below.
        static var favoriteTightWidth: CGFloat { scaled(46) }
        static let favoriteMaxColumns = 6
        static var favoriteHeight: CGFloat { scaledEven(36) }
        static var favoriteIcon: CGFloat { scaledEven(18) }
        static let favoriteGap: CGFloat = 6
        static let favoriteRadius: CGFloat = Radius.field
        /// A favorite's close chip, tucked inside its top-right corner.
        static let favoriteClose: CGFloat = 14
        static let favoriteCloseGlyph: CGFloat = 7
        static let favoriteCloseInset: CGFloat = 3
        /// A favorite's speaker badge: its side as a share of the icon's, and its glyph's point size.
        static let favoriteSpeakerShare: CGFloat = 0.55
        static let favoriteSpeakerGlyph: CGFloat = 8

        /// The top row: the traffic lights' center line, from the sidebar's top, and every toolbar glyph's.
        static let lightsCenter: CGFloat = 22
        /// Where the traffic lights start: the icon column.
        static var lightsX: CGFloat { iconColumn }
        /// From the last traffic light to the sidebar toggle's glyph.
        static let lightsGap: CGFloat = Space.x3
        /// Toolbar and bottom bar buttons: 26pt targets, 14pt glyphs, 6pt corners.
        static let button: CGFloat = 26
        static let glyph: CGFloat = 14

        /// The address: a 30pt field with 8pt corners, the favorites' faint fill and 1px edge, the host 10pt in; its
        /// own buttons the toolbar's 26pt with 14pt glyphs, inset evenly, so they're as easy to hit as the ones above.
        static let addressTop: CGFloat = 40
        static var addressHeight: CGFloat { scaledEven(30) }
        static let addressRadius: CGFloat = Radius.field
        static let addressButton: CGFloat = button
        static let addressGlyph: CGFloat = glyph
        /// The room the site's name always keeps: pinned extensions give way before it gets narrower.
        static var addressMinText: CGFloat { scaled(72) }
        /// An extension's icon in the address: a site's icon's size, so it reads as big as the field's glyphs.
        static let addressIcon: CGFloat = 16
        /// The mark on a pinned extension's tile in Site Controls: a 12pt round chip, the count pill's height, with a
        /// 7pt glyph in it.
        static let pinMark: CGFloat = 12
        static let pinMarkGlyph: CGFloat = 7

        /// The bottom bar: 26pt buttons, 4pt from its edges, a space key (`spaceKey`) for each space.
        static let bottomBarHeight: CGFloat = 34
        /// A space's icon in the bottom bar (#210, #238), scaled like favorite icons (16, 18, 20).
        static var spaceIcon: CGFloat { spaceIcon(for: current) }
        static func spaceIcon(for size: Size) -> CGFloat { (18 * size.scale / 2).rounded() * 2 }
        /// Each space's target in the bottom bar: a toolbar button, and from Large up a little more round its larger icon,
        /// as tall as the bar leaves room for. Past Large, the room its icon needs.
        static var spaceTarget: CGFloat { spaceTarget(for: current) }
        static func spaceTarget(for size: Size) -> CGFloat { max(size.scale >= Size.large.scale ? 28 : button, spaceIcon(for: size) + spaceIconRoom) }
        /// Padding around a space icon; the row scrolls before icons shrink (#238).
        static let spaceIconRoom: CGFloat = 4
        /// Each space target's width for `count` spaces: `spaceTarget` when they fit, narrower down to the icon (or
        /// `smallest` for dots), then the row scrolls.
        static func spaceKeyWidth(available: CGFloat, count: Int, hasIcons: Bool, smallest: CGFloat, size: Size) -> CGFloat {
            let least = hasIcons ? max(smallest, spaceIcon(for: size) + spaceIconRoom) : smallest
            return max(least, min(spaceTarget(for: size), floor(available / CGFloat(max(count, 1)))))
        }
        /// The now-playing card above the bottom bar: a row's height, at every size.
        static var nowPlayingHeight: CGFloat { rowHeight }
        /// Two lines with row padding.
        static var updateCardHeight: CGFloat { scaledEven(44) }
        /// Plus the progress bar.
        static var updateCardBusyHeight: CGFloat { scaledEven(56) }
    }

    /// The strip on top of each pane in split view: 30 tall, 24pt buttons with 13pt glyphs, the address in a 22pt
    /// pill at 12pt.
    enum Pane {
        static let height: CGFloat = 30
        static let button: CGFloat = 24
        static let glyph: CGFloat = 13
        /// The page's icon in a strip: a favicon at the sidebar's Medium size, whatever size the sidebar is.
        static let favicon: CGFloat = 16
        static let addressText: CGFloat = TypeSize.label
        static let addressHeight: CGFloat = 22
        /// A slim window strip's buttons (Zigzag Mini, pop-ups, installed apps): the address's height, so every
        /// hover box sits as far from the strip's edges as from the next one (`stripGap`).
        static let stripButton: CGFloat = addressHeight
        static let stripGap: CGFloat = Space.x1
        /// The least room a pane's address keeps before its strip folds its own buttons away (as the sidebar's
        /// address keeps for its host).
        static let addressMinWidth: CGFloat = 72
    }

    enum Page {
        /// The page's edge to its content, and to the header's wordmark.
        static let gutter: CGFloat = Space.x6 + Space.x1
        /// The same, when the page is narrow (half of a split, a small window).
        static let narrowGutter: CGFloat = Space.x4
        /// Narrower than this, a page uses `narrowGutter`.
        static let narrowWidth: CGFloat = 640
        /// The header: its top and bottom padding, and the height of what's in it (title, search, buttons).
        static let headerTop: CGFloat = Space.x4
        static let headerBottom: CGFloat = Space.x3
        static let controlHeight: CGFloat = Metric.controlHeight
        static var headerHeight: CGFloat { headerTop + controlHeight + headerBottom }
        /// The widest the content gets; past it the page centers it.
        static let maxWidth: CGFloat = 880
        /// A row in a list: History's pages, Settings' sections. The sidebar's row, so the two read alike.
        static let rowHeight: CGFloat = Metric.rowHeight
        /// How far a row's hover fill reaches past its text, on each side.
        static let rowInset: CGFloat = Space.x2 + 2
        /// The wordmark in the header: about the title's cap height, so the two read as one line.
        static let wordmarkHeight: CGFloat = 16
        /// The search field in the header.
        static let searchWidth: CGFloat = 280
        /// A column of sections at the left (Settings).
        static let columnWidth: CGFloat = 240
        /// A row in a group on a page (Settings): one line of text, or more with its explanation under it.
        static let groupRowHeight: CGFloat = Space.x10 + Space.x1
        /// From a group's edge to the text and controls in its rows, and above and below a row's two lines.
        static let groupPad: CGFloat = Space.x4
        static let groupRowPad: CGFloat = Space.x3
        /// Between one group on a page and the next section.
        static let groupGap: CGFloat = Space.x6
        /// A page in a window of its own (Passwords): the strip its traffic lights sit in, above the header.
        static let windowTop: CGFloat = Space.x6 + Space.x1
        /// The middle column of a three-part page: the list of things in the chosen section (Passwords' logins).
        static let listWidth: CGFloat = 300
        /// A row of the middle list: a title over a quiet second line.
        static let tallRowHeight: CGFloat = Space.x10 + Space.x1
        /// The text column of a detail pane, so a wide window doesn't stretch its lines.
        static let detailWidth: CGFloat = 520
    }

    // MARK: - The guided tour

    /// The tour's card at the page's bottom: the step's keys, what to do and why, a recording above when there is
    /// one; and the last step, a note with the wordmark across its top.
    enum Tour {
        static let cardWidth: CGFloat = 440
        /// As narrow as a step's card gets, in a narrow window.
        static let minCardWidth: CGFloat = 280
        /// A step's row: one line, or the line and its why.
        static let rowHeight: CGFloat = Space.x16
        static let rowWithNoteHeight: CGFloat = Space.x16 + Space.x6
        /// A key to press: at least this wide and tall, `Space.x1` from the next.
        static let keySide: CGFloat = 44
        static let keyGap: CGFloat = Space.x1
        /// The done mark in place of the keys.
        static let checkSide: CGFloat = Space.x5
        /// The last step: its width, padding, the band the wordmark sits in, and the wordmark's height.
        static let finalWidth: CGFloat = 380
        static let finalPad: CGFloat = Space.x8
        static let finalWordmark: CGFloat = Space.x8 + 2
        static let finalTitleHeight: CGFloat = Space.x8 + 2
        /// The ring around what to click: how far outside it, and round below this size.
        static let ringOutset: CGFloat = 5
        static let ringRoundBelow: CGFloat = 44
    }

    // MARK: - Empty states

    /// A page with nothing to show yet (History, Passwords, the error page): the wordmark faded almost away, a quiet
    /// line under it, maybe one action. The same on every page, native or HTML (`PageStyle` passes these on).
    enum EmptyState {
        static let markWidth: CGFloat = 120
        static let markOpacity: CGFloat = 0.08
        /// Mark to text, and text to the action.
        static let markGap: CGFloat = Space.x4
        static let actionGap: CGFloat = Space.x6
        /// The widest the text runs.
        static let textWidth: CGFloat = 360
        /// A search that finds nothing: its one line this far below the top of where the results go.
        static let noMatchTop: CGFloat = 96

        /// The top of the no-match line in `area` (flipped): `noMatchTop` down, or the middle of a shorter area.
        static func noMatchY(in area: NSRect, lineHeight: CGFloat) -> CGFloat {
            round(min(area.minY + noMatchTop, area.midY - lineHeight / 2))
        }
    }

    // MARK: - Dialogs

    /// Every question Zigzag asks over a window or a page (a confirmation, saving a password, a permission, adding
    /// an extension): one floating panel, the same padding, the same header and the same row of pill buttons.
    enum Dialog {
        static let width: CGFloat = 360
        /// From the panel's edge to everything in it.
        static let padding: CGFloat = Space.x5
        /// The picture at the start of the header: a site's icon, an extension's, or a symbol on a soft circle.
        static let iconSide: CGFloat = Space.x8
        /// Between the header and what's under it, and before the buttons.
        static let gap: CGFloat = Space.x4
        /// The space between two buttons in the row.
        static let buttonGap: CGFloat = Space.x2
        /// The narrowest a button in the row gets, so a short "OK" still reads as a button.
        static let minButtonWidth: CGFloat = Space.x16 + Space.x4
    }

    // MARK: - Brand moments

    /// First run, the welcome and the import window: the brand's blue frame and what floats on it.
    enum Welcome {
        /// The wordmark on the hello screen.
        static let wordmarkHeight: CGFloat = 72
        /// The glass card a step's choice sits on.
        static let cardWidth: CGFloat = 560
        /// A step's big title, in display weight: the one place type is this large.
        static let titleSize: CGFloat = 30
        /// The count of what came over in an import: the one number set this large.
        static let countSize: CGFloat = 60
        /// A brand moment's card (onboarding's import card).
        static let cardRadius: CGFloat = 22
        /// About › Acknowledgments: wide enough for a license's lines as written.
        static let acknowledgementsSize = NSSize(width: 640, height: 600)
        /// The progress dots.
        static let dot: CGFloat = 6
        /// The main pill on a step and the welcome's one button.
        static let buttonHeight: CGFloat = Space.x10
        static let buttonWidth: CGFloat = 168
        static let groupGap: CGFloat = Space.x6 + Space.x1
    }

    /// Your Zigzag Card, the hero of About Zigzag: a bank card's proportions.
    enum Keepsake {
        /// ISO ID-1 (85.6 × 54 mm), at 5 points a millimeter.
        static let size = NSSize(width: 428, height: 270)
        /// ID-1's 3.18 mm corner.
        static let radius: CGFloat = 16
        /// From the card's edges to what's on it, the same on every side.
        static let pad: CGFloat = Space.x6 + Space.x1
        static let wordmarkHeight: CGFloat = 18
        /// The wordmark alone in the middle of the back.
        static let backWordmarkHeight: CGFloat = 30
        /// The name, and the smallest it shrinks to before it's cut short.
        static let nameSize: CGFloat = 28
        static let nameSmallest: CGFloat = 20
        /// The ribbon Z pressed into the front at its bottom right: its height, its ribbon as wide as the icon's, its depth.
        static let emblemHeight: CGFloat = 150
        static let emblemWeight: CGFloat = Brand.weight
        static let emblemDepth: CGFloat = 1.2
        /// How deep the wordmark is stamped.
        static let stampDepth: CGFloat = 0.35
        /// The most it turns toward the pointer, in degrees, and how far the eye is from it.
        static let tilt: CGFloat = 8
        static let perspective: CGFloat = 1100
        /// Turning after the pointer, slow enough to feel its weight; settling back on a soft spring; turning over.
        static let follow: TimeInterval = Material.follow * 0.5
        static let settle: TimeInterval = Material.follow
        static let settleBounce: CGFloat = 0.12
        static let turn: TimeInterval = Motion.large * 2
        /// The saved picture: a 16:10 scene in points, at 3 pixels a point (2400 × 1500).
        static let exportScene = NSSize(width: 800, height: 500)
        static let exportScale: CGFloat = 3
        /// The card in the saved picture, a little larger than in About, so it takes six tenths of the width.
        static let exportGrow: CGFloat = 1.12
        /// Two shadows: a wide soft one it floats on, and a close one where it nearly touches.
        static let ambientRadius: CGFloat = 24
        static let ambientDrop: CGFloat = 14
        static let contactRadius: CGFloat = 3
        static let contactDrop: CGFloat = 1.5
        /// Room around it in About: at the sides, above it (under the traffic lights), and under it.
        static let margin: CGFloat = Space.x10
        static let top: CGFloat = Space.x12
        static let gap: CGFloat = Space.x6
    }

    // MARK: - Type (SF Pro: six roles, one scale for the whole app)

    /// Every text in Zigzag is one of these. Pages, panels and the sidebar share them: the same role is the same size
    /// everywhere. DESIGN.md has the table.
    enum TypeSize {
        /// Small print, captions, counts, a keycap.
        static let small: CGFloat = 11
        /// A section's label and a group's heading (medium, gray); a row's explanation (regular).
        static let label: CGFloat = 12
        /// Panels, forms, menus, what a button or dropdown says.
        static let body: CGFloat = 13
        /// A row's title in any list: the sidebar's rows and address, Settings' sections and rows, History's pages.
        static let row: CGFloat = 14
        /// A panel's title, a section's title on a page.
        static let heading: CGFloat = 15
        /// A page's title in its header, a big panel's title, the command bar's field.
        static let title: CGFloat = 17
        /// Display headings in heavy type (`Brand.display`): a window's or a card's one big line.
        static let display: CGFloat = 22
        /// The count on an extension's button: semibold figures in a 12pt pill.
        static let badge: CGFloat = 9
    }

    enum Font {
        static func small(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: TypeSize.small, weight: weight) }
        static func body(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: TypeSize.body, weight: weight) }
        static func row(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: TypeSize.row, weight: weight) }
        static func heading(_ weight: NSFont.Weight = .semibold) -> NSFont { .systemFont(ofSize: TypeSize.heading, weight: weight) }
        static func title(_ weight: NSFont.Weight = .semibold) -> NSFont { .systemFont(ofSize: TypeSize.title, weight: weight) }
        /// A quiet section label: "Tabs", the space's name over its pinned tabs, a group's heading on a page.
        static func label() -> NSFont { .systemFont(ofSize: TypeSize.label, weight: .medium) }
        /// A row's explanation under its title, in `textSecondary`.
        static func detail() -> NSFont { .systemFont(ofSize: TypeSize.label) }
        /// What a button or a dropdown says.
        static func control() -> NSFont { .systemFont(ofSize: TypeSize.body) }
        /// The sidebar's rows and address (13 regular), and its section labels (11 medium): `Tokens.Sidebar`.
        static func sidebarRow() -> NSFont { .systemFont(ofSize: Sidebar.rowText) }
        static func sidebarLabel() -> NSFont { .systemFont(ofSize: Sidebar.labelText, weight: .medium) }
        /// Zigzag's voice: SF Pro Light, set a touch tight. The one type style that's ours, for every
        /// name and title that speaks for the app (a space's name, a page's title, a panel's title, the welcome) and,
        /// in its own case, the address bar's text. Always through `voice` and `voiceText`, so its size, weight and
        /// tracking never drift from place to place.
        static func voice(_ size: CGFloat = Sidebar.spaceNameText) -> NSFont { .systemFont(ofSize: size, weight: .light) }
        /// The voice's tracking: 2.3% of the size, tight enough to read as one shape, never so tight letters touch.
        static func voiceKern(_ size: CGFloat = Sidebar.spaceNameText) -> CGFloat { -size * 0.023 }
        /// Text in the voice, in its normal case.
        static func voiceText(_ text: String, size: CGFloat = Sidebar.spaceNameText, color: NSColor = Color.textPrimary,
                              paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [.font: voice(size), .kern: voiceKern(size), .foregroundColor: color]
            if let paragraph { attributes[.paragraphStyle] = paragraph }
            return NSAttributedString(string: text, attributes: attributes)
        }
        /// The space's name in the sidebar: the voice at 26.
        static func spaceName() -> NSFont { voice() }
        /// Numbers that count something on a control (a space key): tabular figures, so they sit like dial markings.
        static func figures(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: weight) }
        /// An address as a developer reads it, every character the same width (SF Mono): the developer tools' bar.
        static func code(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }
    }

    // MARK: - Symbols (one weight everywhere)

    enum Symbol {
        /// Light: thin strokes that sit as lightly as the text beside them, never heavier than a row's title.
        static let weight: NSFont.Weight = .light
        /// Four sizes, by where the symbol sits. In an icon button (`Metric.iconButton`): back, forward, reload,
        /// the bottom bar, a pane's header, the find bar, a panel's close. Big enough to be a pleasure to press.
        static let glyph: CGFloat = 17
        /// In a compact icon button (`Metric.compactIconButton`), inside a row or a field.
        static let compactGlyph: CGFloat = 14
        /// A row's picture where it's a symbol rather than a favicon: it fills the favicon's slot (`Metric.favicon`).
        static let row: CGFloat = 16
        /// A tiny mark inline with text: a lock, a disclosure chevron, a dropdown's arrows.
        static let inline: CGFloat = 11
        /// Beside body text (a pill button's symbol, a panel's line): the text's own size.
        static let pointSize: CGFloat = TypeSize.body

        static func image(_ name: String, size: CGFloat = pointSize) -> NSImage {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            return image ?? NSImage()
        }

        /// How far a symbol's ink sits from the middle of its image, in points (x right, y up). A symbol's image
        /// keeps room for its neighbors in text, so a chevron leans toward the side it points to; a button
        /// moves it back so every icon in a row looks evenly spaced.
        @MainActor static func inkOffset(_ name: String, size: CGFloat = pointSize) -> CGSize {
            let box = inkBox(name, size: size)
            guard weightCentered.contains(name) else { return CGSize(width: box.midX, height: box.midY) }
            return CGSize(width: box.midX, height: inkWeightY["\(name) \(size)"] ?? box.midY)
        }

        /// Centered vertically by ink weight, not box: reload's arrowhead would leave its ring low.
        static let weightCentered: Set<String> = ["arrow.clockwise"]

        /// The size of a symbol's ink, for lining it up by what you see rather than by its image's padding.
        @MainActor static func inkSize(_ name: String, size: CGFloat = pointSize) -> CGSize { inkBox(name, size: size).size }

        /// A symbol's ink, in points from the middle of its image (x right, y up).
        @MainActor private static func inkBox(_ name: String, size: CGFloat) -> CGRect {
            let drawn = measuredAsDrawn.contains(name)
            let key = "\(name) \(size)", scale: CGFloat = drawn ? 2 : 4
            // Measured once: the symbol's image is only made for the first look.
            if let known = inkBoxes[boxKey(key, scale: scale, asDrawn: drawn)] { return known }
            return inkBox(of: Self.image(name, size: size), key: key, scale: scale, asDrawn: drawn)
        }

        /// Measured as a 2x screen draws them, not scaled up: the screen draws xmark half a point lower than its image.
        static let measuredAsDrawn: Set<String> = ["xmark"]

        /// How far an image's ink sits from its middle (x right, y up), for a symbol drawn some other way (a heavier
        /// weight, a glyph of its own); `key` names it for the cache, `scale` is pixels per point.
        @MainActor static func inkOffset(of image: NSImage, key: String, scale: CGFloat = 4) -> CGSize {
            let box = inkBox(of: image, key: key, scale: scale)
            return CGSize(width: box.midX, height: box.midY)
        }

        /// The size of an image's ink; `key` names it for the cache.
        @MainActor static func inkSize(of image: NSImage, key: String, scale: CGFloat = 4) -> CGSize { inkBox(of: image, key: key, scale: scale).size }

        private static func boxKey(_ key: String, scale: CGFloat, asDrawn: Bool) -> String {
            scale == 4 ? key : "\(key) @\(scale)x\(asDrawn ? " drawn" : "")"
        }

        @MainActor private static func inkBox(of image: NSImage, key: String, scale: CGFloat = 4, asDrawn: Bool = false) -> CGRect {
            let key = boxKey(key, scale: scale, asDrawn: asDrawn)
            if let known = inkBoxes[key] { return known }
            let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
            var box = CGRect.zero
            if w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                // As drawn: the bitmap at the image's size in points, so the symbol snaps to pixels as on screen.
                if asDrawn { rep.size = image.size }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: asDrawn ? NSRect(origin: .zero, size: image.size) : NSRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
                var minX = w, maxX = -1, minY = h, maxY = -1
                var weight = 0.0, weightedY = 0.0
                if let data = rep.bitmapData {
                    for y in 0..<h {
                        for x in 0..<w {
                            let alpha = data[y * rep.bytesPerRow + x * 4 + 3]
                            weight += Double(alpha); weightedY += Double(alpha) * (Double(y) + 0.5)
                            guard alpha > 50 else { continue }
                            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        }
                    }
                }
                if weight > 0 { inkWeightY[key] = (CGFloat(h) / 2 - CGFloat(weightedY / weight)) / scale }
                if maxX >= minX {
                    // Bitmap rows run top down.
                    box = CGRect(x: (CGFloat(minX) - CGFloat(w) / 2) / scale, y: (CGFloat(h) / 2 - CGFloat(maxY + 1)) / scale,
                                 width: CGFloat(maxX + 1 - minX) / scale, height: CGFloat(maxY + 1 - minY) / scale)
                }
            }
            inkBoxes[key] = box
            return box
        }
        @MainActor private static var inkBoxes: [String: CGRect] = [:]
        /// Each measured image's ink weight center from its middle (y up), by the same key.
        @MainActor private static var inkWeightY: [String: CGFloat] = [:]

        /// Offsets (as `inkOffset`) for symbols that take turns in one place (a speaker playing and muted): each is
        /// drawn with its alignment rect's origin, its baseline's start, where the others' is, so what they share (the
        /// speaker's body) stays on the same pixels. The ink centered is `reference`'s, or with none, all of theirs.
        @MainActor static func sharedInkOffsets(of images: [NSImage], keys: [String], reference: Int? = nil) -> [CGSize] {
            let origins = images.map { CGPoint(x: $0.alignmentRect.minX - $0.size.width / 2, y: $0.alignmentRect.minY - $0.size.height / 2) }
            let boxes = zip(images, keys).enumerated().map { i, pair in inkBox(of: pair.0, key: pair.1).offsetBy(dx: -origins[i].x, dy: -origins[i].y) }
            let middle = reference.map { boxes[$0] } ?? boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            return origins.map { CGSize(width: middle.midX + $0.x, height: middle.midY + $0.y) }
        }
    }

    // MARK: - Motion (five roles, one curve family)

    enum Motion {
        // MARK: Roles
        //
        // Every animation in the app plays one of these roles (DESIGN.md › Motion). Durations come from a role, never
        // from a number at the call site (`scripts/check-motion.sh` holds the line). The one exception is the download
        // thrown into its button (`flight`) and its progress ring.

        /// The five kinds of movement, and how each one moves.
        enum Role: CaseIterable {
            /// Hover and press feedback: answers under the finger, `feedbackIn` / `feedbackOut`, eased out.
            case feedback
            /// A small change of state in place: a toggle, a row's selection, a chip fading in. `state`, eased out.
            case state
            /// A panel, popover, menu or sheet showing up (`enter`) and going (`exit`), eased out, from where it opened.
            case present
            /// A drawer or the sidebar sliding, and the window's layout making room: `drawerIn` / `drawerOut` on the
            /// drawer curve.
            case drawer
            /// A large transition: switching spaces, the Desk, the whole window changing. `large`, on the drawer curve.
            case large

            /// How long it takes, coming in (or simply changing) or going. With Reduce Motion nothing travels: feedback
            /// is instant, everything else only cross-fades, in `crossfade`.
            func duration(entering: Bool = true, reduceMotion: Bool = Motion.reduceMotion) -> TimeInterval {
                if reduceMotion { return self == .feedback ? 0 : crossfade }
                switch self {
                case .feedback: return entering ? feedbackIn : feedbackOut
                case .state: return Motion.state
                case .present: return entering ? enter : exit
                case .drawer: return entering ? drawerIn : drawerOut
                case .large: return Motion.large
                }
            }

            /// The curve for what moves: the house ease-out for what answers or appears in place, the drawer's for what
            /// travels. A fade or a color change in any role is on the house ease-out.
            var timing: CAMediaTimingFunction {
                switch self {
                case .feedback, .state, .present: return Motion.easeOut
                case .drawer, .large: return Motion.drawer
                }
            }

            /// As a `Curve`, for `Motion.animate` and `Motion.slide`.
            func curve(entering: Bool = true) -> Curve {
                Curve(duration: duration(entering: entering, reduceMotion: false), timing: timing)
            }
        }

        /// Feedback: a press going down, a hint fading. Hover itself is instant both ways.
        static let feedbackIn: TimeInterval = 0.1
        /// Feedback letting go: the press settling back.
        static let feedbackOut: TimeInterval = 0.12
        /// A small change of state in place.
        static let state: TimeInterval = 0.16
        /// Showing up: a menu, popover, panel, bar or sheet arrives in `enter`, eased out, growing from `enterScale` out
        /// of what opened it (or sliding in from the edge it's attached to) as it fades in. Going is quicker and
        /// subtler: `exit`, toward `exitScale`.
        static let enter: TimeInterval = 0.18
        static let exit: TimeInterval = 0.12
        /// A drawer coming out (the sidebar, a notice from beyond the window's edge), and going back, quicker.
        static let drawerIn: TimeInterval = 0.26
        static let drawerOut: TimeInterval = 0.2
        /// The ceiling for UI: switching spaces, the Desk zooming, the window changing. Under 300ms.
        static let large: TimeInterval = 0.28
        /// Reduce Motion: what moved or grew only crossfades in place, this quickly.
        static let crossfade: TimeInterval = 0.12

        // The roles under the names the app grew up with.

        /// Feedback: a hint fading, a tile fading out of a list.
        static let quick: TimeInterval = feedbackIn
        /// Something that shows after you've held a key a while (the ⌘ and ⌃ numbers): a state change.
        static let hoverFade: TimeInterval = state
        /// A change of selection in a list (the card settling onto the chosen row), a fill or color changing: state.
        static let selection: TimeInterval = state
        /// One shared highlight gliding from row to row in a menu, and a selection gliding between a list's places
        /// or a filter's segments: state.
        static let highlightGlide: TimeInterval = state
        /// A layout move with no way in or out (rows making room, a split opening): the drawer role at `drawerOut`.
        static let standard: TimeInterval = drawerOut
        /// The page shrinking into its card in the Desk, and a card growing back into the page: large.
        static let zoom: TimeInterval = large
        /// The hidden sidebar sliding out at the window's edge, and back: the drawer.
        static let edgeSlideDuration: TimeInterval = drawerIn
        static let edgeTuckDuration: TimeInterval = drawerOut
        /// A notice coming in from beyond the window's edge (a site's question, an offer) travels like a drawer.
        static let noticeIn: TimeInterval = drawerIn
        static let noticeOut: TimeInterval = drawerOut

        // Delays and ambient time, which aren't transitions.

        /// Delay before a hover preview appears.
        static let previewDelay: TimeInterval = 0.6
        /// How long the pointer can stray off the floating sidebar before it slides away.
        static let edgeHideDelay: TimeInterval = 0.05
        /// The page's loading line inching on between WebKit's steps, linearly, once this often.
        static let progressCreep: TimeInterval = 0.5
        /// Motion that isn't an answer to anything you did: the wordmark drawing itself, the guided tour's beat, a
        /// space's atmosphere drifting. Never on the way of something you asked for.
        enum Ambient {
            /// The ribbon Z drawing in, the ZIGZAG wordmark writing itself, and the loading mark's cycle and breath.
            static let draw: TimeInterval = 0.7
            static let wordmark: TimeInterval = 1.1
            static let markCycle: TimeInterval = 1.1
            static let breathe: TimeInterval = 0.9
            /// The guided tour's pulse on what to try.
            static let beat: TimeInterval = 0.45
            /// A space's atmosphere easing into its new look.
            static let atmosphere: TimeInterval = 1.0
            /// The materials showcase's float (a debug window).
            static let float: TimeInterval = 3.6
        }

        /// The tactile press: a button or row eases down to this scale as it's pressed (`pressIn`) and back when let
        /// go (`pressSettle`), both eased out, never overshooting. The action never waits on it.
        static let pressScale: CGFloat = 0.97
        static let pressIn: TimeInterval = feedbackIn
        /// The sink: keys, switches, pill buttons and favorites go down this far as they're pressed (`pressIn`), and
        /// settle back over `pressSettle`, eased out, with no bounce (`showSink`).
        static let pressSink: CGFloat = 1
        static let pressSettle: TimeInterval = feedbackOut
        /// A download thrown into its button: a slow, high lob you can follow, the one movement past `large`.
        static let flight: TimeInterval = 1.1
        static let enterScale: CGFloat = 0.96
        static let exitScale: CGFloat = 0.98
        /// How far a bar attached to an edge (the find bar, a toast) slides in from it; it leaves half as far.
        static let edgeOffset: CGFloat = 6
        /// A sheet (a confirmation, the notes) grows from a little below its middle, so it settles up into place over
        /// its scrim rather than swelling out of a point.
        static let sheetOrigin = CGPoint(x: 0.5, y: 0.7)

        /// A layer's transform scaling it by `k` around `point` (0 to 1 across its bounds, from its top left), whatever
        /// its anchor: what a press or a growing menu uses.
        static func scale(_ k: CGFloat, of layer: CALayer, around point: CGPoint = CGPoint(x: 0.5, y: 0.5), flipped: Bool = true) -> CATransform3D {
            scale(k, size: layer.bounds.size, anchor: layer.anchorPoint, around: point, flipped: flipped)
        }

        static func scale(_ k: CGFloat, size: CGSize, anchor: CGPoint, around point: CGPoint, flipped: Bool) -> CATransform3D {
            let px = (point.x - anchor.x) * size.width
            let py = ((flipped ? point.y : 1 - point.y) - anchor.y) * size.height
            return CATransform3DConcat(CATransform3DMakeScale(k, k, 1), CATransform3DMakeTranslation(px * (1 - k), py * (1 - k), 0))
        }

        // MARK: Showing up and going

        /// Where something comes from as it shows up, and goes back to as it leaves.
        enum Origin: Equatable {
            /// Grows out of this point of its bounds (0 to 1 from its top left): the control that opened it.
            case point(CGPoint)
            /// Slides `edgeOffset` in from the edge it's attached to: the find bar from the page's top.
            case edge(NSRectEdge)
            /// Comes in from beyond the window's edge, this far, and leaves back out: a notice at the page's top.
            case offstage(NSRectEdge, CGFloat)
            /// Only fades, where it is: something that stands in for what's under it.
            case inPlace
        }

        /// How long showing up or going takes. With Reduce Motion, only a short crossfade.
        static func presenceDuration(_ origin: Origin, entering: Bool, reduceMotion: Bool) -> TimeInterval {
            if reduceMotion { return crossfade }
            if case .offstage = origin { return Role.drawer.duration(entering: entering, reduceMotion: false) }
            // Hung from an edge (a toast, the find bar): it lifts back the way it dropped in, at the same pace, so its
            // going reads as the same movement rather than a vanishing.
            if case .edge = origin { return enter }
            return entering ? enter : exit
        }

        /// The pose it's hidden in, in its superview's coordinates (`flipped`: y runs down): a little smaller around its
        /// origin, or a little way toward its edge. Leaving a point is subtler than arriving; an edge's or offstage's is the same way back.
        static func hiddenTransform(_ origin: Origin, entering: Bool, size: CGSize, anchor: CGPoint, flipped: Bool) -> CATransform3D {
            func toward(_ edge: NSRectEdge, _ d: CGFloat) -> CATransform3D {
                switch edge {
                case .minX: return CATransform3DMakeTranslation(-d, 0, 0)
                case .maxX: return CATransform3DMakeTranslation(d, 0, 0)
                case .minY: return CATransform3DMakeTranslation(0, -d, 0)
                case .maxY: return CATransform3DMakeTranslation(0, d, 0)
                @unknown default: return CATransform3DIdentity
                }
            }
            switch origin {
            case .point(let point):
                return scale(entering ? enterScale : exitScale, size: size, anchor: anchor, around: point, flipped: flipped)
            case .edge(let edge):
                return toward(screenEdge(edge, flipped: flipped), edgeOffset)
            case .offstage(let edge, let distance):
                return toward(screenEdge(edge, flipped: flipped), distance)
            case .inPlace:
                return CATransform3DIdentity
            }
        }

        /// `.minY` is the top as you look at it: in an unflipped view that's toward larger y.
        private static func screenEdge(_ edge: NSRectEdge, flipped: Bool) -> NSRectEdge {
            guard !flipped else { return edge }
            switch edge {
            case .minY: return .maxY
            case .maxY: return .minY
            default: return edge
            }
        }

        /// Turned around partway (closed while still arriving, opened again while leaving), it carries on from what's on
        /// screen over the part of the way that's left, so a quick open and close never waits or jumps. How far along
        /// it is reads from its opacity, which runs the whole way from 0 to 1.
        static func remainingDuration(_ full: TimeInterval, shownOpacity: Float, entering: Bool) -> TimeInterval {
            let left = Double(entering ? 1 - shownOpacity : shownOpacity)
            guard left > 0.02 else { return 0 }
            return max(full * min(left, 1), 0.04)
        }

        /// Shows `view` arriving from `origin`, or leaving toward it, on the render server: fading as it grows or slides
        /// (the fade a touch quicker coming in, so it's solid before it settles), from wherever it's drawn right now.
        /// Leaving, it stays hidden (opacity 0) until it's shown again or taken away; `completion` runs when the
        /// movement ends, or when it's turned around, or at once when there's nothing to move.
        static func present(_ view: NSView, from origin: Origin, entering: Bool, completion: (() -> Void)? = nil) {
            guard let layer = view.layer else { completion?(); return }
            let reduce = reduceMotion
            let flipped = view.superview?.isFlipped ?? true
            let hidden = reduce ? CATransform3DIdentity
                : hiddenTransform(origin, entering: entering, size: layer.bounds.size, anchor: layer.anchorPoint, flipped: flipped)
            // Mid-way through the last change: start from what's drawn, not from where that change began.
            let moving = layer.animation(forKey: "presence.opacity") != nil || layer.animation(forKey: "presence.transform") != nil
            let shown = moving ? layer.presentation() : nil
            let fromOpacity = shown?.opacity ?? (entering ? 0 : layer.opacity)
            let fromTransform = shown?.transform ?? (entering ? hidden : CATransform3DIdentity)
            let full = presenceDuration(origin, entering: entering, reduceMotion: reduce)
            let time = (moving ? remainingDuration(full, shownOpacity: fromOpacity, entering: entering) : full) * debugSlowdown
            layer.removeAnimation(forKey: "presence.opacity")
            layer.removeAnimation(forKey: "presence.transform")
            withoutAnimation {
                layer.opacity = entering ? 1 : 0
                layer.transform = CATransform3DIdentity
            }
            guard time > 0 else { completion?(); return }
            CATransaction.begin()
            CATransaction.setCompletionBlock(completion)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = entering ? 1 : 0
            fade.duration = entering && !reduce ? time * 0.7 : time
            fade.timingFunction = easeOut
            fade.fillMode = .both
            layer.add(fade, forKey: "presence.opacity")
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: fromTransform)
            move.toValue = NSValue(caTransform3D: entering ? CATransform3DIdentity : hidden)
            move.duration = time
            // A notice from beyond the window's edge travels, so it rides the drawer's curve; the rest appear in place.
            if case .offstage = origin, !reduce { move.timingFunction = drawer } else { move.timingFunction = easeOut }
            // Leaving, it lands back in place the moment its fade reaches nothing, so nothing has to hold the pose.
            layer.add(move, forKey: "presence.transform")
            CATransaction.commit()
        }

        /// Fades a backdrop (sheet scrim, a zoomed pane's dimming) in or out from its current opacity, eased; crossfade with
        /// Reduce Motion. `evenFromKeyboard` false: appears instantly from a key, like the command bar.
        static func fadeBackdrop(_ view: NSView, entering: Bool, evenFromKeyboard: Bool = true, completion: (@MainActor () -> Void)? = nil) {
            if let layer = view.layer, layer.animation(forKey: "opacity") != nil, let shown = layer.presentation()?.opacity {
                withoutAnimation { view.alphaValue = CGFloat(shown) }
            }
            let instant = isFromKey && !evenFromKeyboard
            let time = instant ? 0 : presenceDuration(.inPlace, entering: entering, reduceMotion: reduceMotion) * debugSlowdown
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = time
                context.timingFunction = easeOut
                view.animator().alphaValue = entering ? 1 : 0
            }, completionHandler: Self.completion(completion))
        }

        /// Takes away what `present(_:from:entering:)` left on `view`, so it shows plainly where it is.
        static func settle(_ view: NSView) {
            view.layer?.removeAnimation(forKey: "presence.opacity")
            view.layer?.removeAnimation(forKey: "presence.transform")
            withoutAnimation { view.layer?.opacity = 1; view.layer?.transform = CATransform3DIdentity }
        }

        /// A motion style: how long, and which curve. Every curve is a fast-out, no-overshoot spring shape,
        /// run by Core Animation on the render server so it stays smooth while pages are busy.
        struct Curve {
            let duration: TimeInterval
            /// When set, slides use a real spring with this much bounce instead of an eased curve.
            var bounce: CGFloat? = nil
            var timing: CAMediaTimingFunction = Motion.easeOut
        }

        /// The one ease-out for anything arriving, leaving or settling: fast at first, so it answers at once, then a
        /// long soft finish (cubic-bezier(0.23, 1, 0.32, 1)). Never ease-in: it starts slow, right when you're looking.
        static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

        /// A panel the width of the sidebar coming out from the window's edge or going back: cubic-bezier(0.32, 0.72,
        /// 0, 1), the drawer's curve. Eased out like `easeOut`, answering at once, but it starts at about twice its
        /// average speed rather than four times, so the panel travels its whole width in even steps instead of
        /// covering half of it in the first frame or two.
        static let drawer = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)

        // The roles as curves. Nothing eases in, and nothing springs unless the fingers threw it (`swipeSettle`).

        /// Feedback: a hint or a drop marker fading.
        static let feedback = Role.feedback.curve()
        /// A small change of state in place: a fade, a fill, a chip coming or going.
        static let change = Role.state.curve()
        /// A layout move: rows, tiles, panes and bars moving to make room (the drawer role, at `drawerOut`).
        static let snappy = Role.drawer.curve(entering: false)
        /// The sidebar, docked or hidden, coming out, and going back (quicker, as leaving is).
        static let edgeSlide = Role.drawer.curve(entering: true)
        static let edgeTuck = Role.drawer.curve(entering: false)
        /// Finishing a swipe: the fingers already did most of the travel, so the rest is a state change.
        static let snap = Role.state.curve()
        /// Switching spaces: a large transition that shows which way you went, with no bounce.
        static let spaceSwitch = Role.large.curve()
        /// Letting go of a swipe between spaces: thrown, so a critically damped spring that carries on at the
        /// fingers' speed and never overshoots, whether it lands on the next space or springs back.
        static let swipeSettle = Curve(duration: state, bounce: 0)
        /// A large transition: the Desk, the sidebar changing sides, the guided tour.
        static let gentle = Role.large.curve()
        /// A scrim or a wash coming with something that shows up, and going with it.
        static let entering = Role.present.curve(entering: true)
        static let leaving = Role.present.curve(entering: false)
        /// Reduce Motion's stand-in for anything that would have moved: a crossfade in place.
        static let crossfading = Curve(duration: crossfade)

        /// True while handling ⌘T: a new tab is for typing at once, so it appears instantly. Every other shortcut
        /// (⌘W, switching tabs and spaces) animates like the same action done with the pointer, so you see what changed.
        static var isKeyboardDriven: Bool {
            guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
            // The T key wherever it is, in any keyboard layout, with Caps Lock on or off.
            return event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command && event.keyCode == 17
        }

        /// True while handling any key press. Panels (find, downloads, a confirmation) opened or closed by a key appear
        /// and go at once; changes to the window's layout still move, so you see where things went.
        static var isFromKey: Bool { NSApp.currentEvent?.type == .keyDown }

        /// Runs AppKit animator() changes. Frames jump to their final values right away (so layout and
        /// hit-testing always see the truth); only what's drawn animates. From any key press it's instant.
        /// `evenFromKeyboard`: for changes to the window's layout (the sidebar, a split), where seeing where things
        /// went matters more than a few milliseconds. `moves`: the changes move or resize something, so with Reduce
        /// Motion they happen at once; fades and color changes still play with it on.
        static func animate(_ curve: Curve = snappy, evenFromKeyboard: Bool = false, moves: Bool = false, _ changes: @escaping () -> Void, completion: (@MainActor () -> Void)? = nil) {
            if isFromKey && !evenFromKeyboard {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0
                    ctx.allowsImplicitAnimation = false
                    changes()
                }, completionHandler: Self.completion(completion))
                return
            }
            if reduceMotion && moves {
                // Reduce Motion: things move to where they go at once; nothing slides. Fades still play.
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0
                    ctx.allowsImplicitAnimation = false
                    changes()
                }, completionHandler: Self.completion(completion))
                return
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = curve.duration * debugSlowdown
                ctx.timingFunction = curve.timing
                ctx.allowsImplicitAnimation = true
                changes()
            }, completionHandler: Self.completion(completion))
        }

        /// An animation group's completion, which AppKit calls on the main thread, run as the main actor's.
        static func completion(_ done: (@MainActor () -> Void)?) -> (@Sendable () -> Void)? {
            guard let done else { return nil }
            return { MainActor.assumeIsolated { done() } }
        }

        static var reduceMotion: Bool {
            #if DEBUG
            if debugReduceMotion { return true }
            #endif
            return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || reducesMotionHere
        }
        /// Settings › Appearance › Reduce motion: the same as the Mac's own, for Zigzag alone.
        static var reducesMotionHere: Bool {
            get { UserDefaults.standard.bool(forKey: "ReduceMotion") }
            set { UserDefaults.standard.set(newValue, forKey: "ReduceMotion") }
        }
        #if DEBUG
        /// Debug builds: Reduce Motion for this app alone, for testing, without changing the Mac's setting.
        static var debugReduceMotion = false
        #endif

        /// Debug builds: ZIGZAG_SLOW_ANIMATIONS=10 plays animations ten times slower, to look at them.
        static let debugSlowdown: Double = {
            #if DEBUG
            return Double(ProcessInfo.processInfo.environment["ZIGZAG_SLOW_ANIMATIONS"] ?? "") ?? 1
            #else
            return 1
            #endif
        }()

        /// Slides a view horizontally into its current (final) position from `offset` points away, on the
        /// render server. Returns how long the slide takes, 0 if it was skipped.
        /// `velocity`: how fast the view is already moving, in points per second (positive is rightward), so a slide
        /// that takes over from the fingers doesn't stall or lurch. Springs only.
        @discardableResult
        static func slide(_ view: NSView, fromOffsetX offset: CGFloat, curve: Curve = snappy, fromKeyboard: Bool = false,
                          velocity: CGFloat = 0) -> TimeInterval {
            guard let layer = view.layer, fromKeyboard || !isKeyboardDriven, !reduceMotion else { return 0 }
            // Interrupting a slide carries on from where it is on screen, not from where it was headed.
            var offset = offset
            if layer.animation(forKey: "slide") != nil,
               let shown = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat {
                offset += shown
            }
            guard abs(offset) > 0.5 else { layer.removeAnimation(forKey: "slide"); return 0 }
            let animation: CABasicAnimation
            if let bounce = curve.bounce {
                let spring = CASpringAnimation(perceptualDuration: curve.duration, bounce: bounce)
                if velocity != 0 {
                    // The spring counts speed in whole distances per second, toward where it's going. Without bounce,
                    // starting faster than its natural frequency would carry it past the end, so it's capped there.
                    let natural = sqrt(spring.stiffness / spring.mass)
                    spring.initialVelocity = min(-velocity / offset, bounce == 0 ? natural : .greatestFiniteMagnitude)
                }
                spring.duration = spring.settlingDuration
                animation = spring
            } else {
                animation = CABasicAnimation()
                animation.duration = curve.duration
                animation.timingFunction = curve.timing
            }
            animation.keyPath = "transform.translation.x"
            animation.fromValue = offset
            animation.toValue = 0
            animation.fillMode = .backwards
            layer.add(animation, forKey: "slide")
            return animation.duration
        }

        /// Moves a view to `frame` at once, so layout and clicks see the truth, and lets the render server show it
        /// traveling there from wherever it's drawn right now. Smooth however busy the app is, and a move that
        /// changes course mid-way carries on from where it is on screen, never jumping back. For rows and tiles
        /// that make room for something being dragged.
        /// `resizes`: a view that changes size on the way (the address, as the bar above the page gets wider or
        /// narrower) is shown growing or shrinking to it too, rather than at its new size from the start. What's in
        /// it goes with it: it's laid out for its new size at once, and the subviews that moves glide to their new
        /// places as well, so one that keeps to its far edge (a button at the address's end) stays on that edge
        /// all the way.
        static func glide(_ view: NSView, to frame: NSRect, duration: TimeInterval = standard,
                          timing: CAMediaTimingFunction = drawer, resizes: Bool = false) {
            guard let layer = view.layer else { view.frame = frame; return }
            let size = view.frame.size
            var shown = view.frame.origin
            if layer.animation(forKey: "glide") != nil, let drawn = layer.presentation()?.transform {
                shown.x += drawn.m41
                shown.y += drawn.m42
            }
            let resized = resizes && (abs(size.width - frame.width) > 0.5 || abs(size.height - frame.height) > 0.5)
            let inside = resized ? view.subviews.filter { !$0.isHidden }.map { ($0, $0.frame) } : []
            withoutAnimation {
                view.frame = frame
                if resized { view.layoutSubtreeIfNeeded() }
            }
            layer.removeAnimation(forKey: "glide")
            layer.removeAnimation(forKey: "glideSize")
            guard !reduceMotion else { return }
            for (subview, was) in inside where !subview.isHidden && subview.frame.origin != was.origin {
                let place = subview.frame
                withoutAnimation { subview.frame.origin = was.origin }
                glide(subview, to: place, duration: duration, timing: timing)
            }
            if resized {
                let grow = CABasicAnimation(keyPath: "bounds.size")
                grow.fromValue = NSValue(size: size)
                grow.toValue = NSValue(size: frame.size)
                grow.duration = duration * debugSlowdown
                grow.timingFunction = timing
                grow.fillMode = .backwards
                layer.add(grow, forKey: "glideSize")
            }
            // A layer's y runs the way its view's superview does, so the offset carries over as it is.
            let dx = shown.x - frame.minX, dy = shown.y - frame.minY
            guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = CATransform3DMakeTranslation(dx, dy, 0)
            animation.toValue = CATransform3DIdentity
            animation.duration = duration * debugSlowdown
            animation.timingFunction = timing
            animation.fillMode = .backwards
            layer.add(animation, forKey: "glide")
        }

        /// Applies changes immediately with no implicit animation.
        static func withoutAnimation(_ changes: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }

        /// An eased animation over exactly `duration` (the house ease-out, or the drawer curve for something
        /// traveling): for movements whose completion has to land on time (a spring settles well after it looks done).
        static func easeAnimation(keyPath: String, duration: TimeInterval = standard, timing: CAMediaTimingFunction = easeOut) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration * debugSlowdown
            animation.timingFunction = timing
            return animation
        }

        /// A critically damped spring: it never overshoots, and runs until it has settled. Only for something the
        /// fingers let go of mid-move (a swipe), so it carries on at their speed.
        static func springAnimation(keyPath: String, duration: TimeInterval = standard) -> CASpringAnimation {
            let spring = CASpringAnimation(perceptualDuration: duration * debugSlowdown, bounce: 0)
            spring.keyPath = keyPath
            spring.duration = spring.settlingDuration
            return spring
        }
    }

    // MARK: - Opacity

    enum Opacity {
        /// Whole-control fade for disabled: text still 3:1 in light and dark. Text-only buttons use
        /// `Color.textDisabled`.
        static let disabled: CGFloat = 0.5
        /// Floor for tabs that have not been looked at in a long time.
        static let fadedFloor: CGFloat = 0.42
        /// What a panel opened over the sidebar (downloads, the site panel) sits on: stepped back, still readable,
        /// so the panel reads first without the tabs vanishing.
        static let receded: CGFloat = 0.4
    }

    // MARK: - Fading

    enum Fade {
        /// Tabs start fading after this long without being looked at.
        static let start: TimeInterval = 6 * 60 * 60
        /// ...and reach the faded floor at this age.
        static let full: TimeInterval = 4 * 24 * 60 * 60
    }

    // MARK: - Increase Contrast and Reduce Transparency

    /// System Settings › Accessibility › Display. With Increase Contrast on, every color that has a stronger version
    /// (`Color.dynamic(light:dark:highLight:highDark:)`: hairlines, edges, separators, quiet text, icons, the chrome's
    /// fills and the controls' borders) takes it, so text reads at AA or better on its ground in either mode; nothing
    /// else changes. With Reduce Transparency (or Increase Contrast) on, what floats is opaque. Both are read as they
    /// are now, so a color resolves to the setting of the moment, and `start` draws every window again when either
    /// changes.
    enum Contrast {
        /// Increase Contrast is on, or forced in a Debug build (`debugOverride`, ZIGZAG_HIGH_CONTRAST=1).
        nonisolated static var isIncreased: Bool {
            #if DEBUG
            if let forced = debugOverride { return forced }
            #endif
            return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }

        /// Whether a color drawn in `appearance` takes its high-contrast version: the setting is on, or the appearance
        /// is one of the Mac's high-contrast ones.
        nonisolated static func isHigh(_ appearance: NSAppearance) -> Bool {
            if isIncreased { return true }
            let name = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            return name == .accessibilityHighContrastAqua || name == .accessibilityHighContrastDarkAqua
        }

        /// Floating things drop their see-through wash: Reduce Transparency is on, or Increase Contrast.
        nonisolated static var isOpaque: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || isIncreased
        }

        #if DEBUG
        /// Debug builds: high-contrast colors forced on (true) or off (false) for this app alone, without changing the
        /// Mac's setting; nil follows the Mac. ZIGZAG_HIGH_CONTRAST=1 starts with it on; `contrast on|off|system`
        /// changes it while running.
        nonisolated(unsafe) static var debugOverride: Bool? = ProcessInfo.processInfo.environment["ZIGZAG_HIGH_CONTRAST"] == "1" ? true : nil
        #endif

        /// Follows the Mac's display options from launch on.
        static func start() {
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                              object: nil, queue: .main) { _ in
                // A turn later, once the windows have heard of it themselves (a see-through frame going solid).
                DispatchQueue.main.async { MainActor.assumeIsolated { redraw() } }
            }
        }

        /// Draws every window again in the colors of the moment: layers keep the color they were given until a view
        /// sets it again, which Zigzag's views do when their appearance changes, so each of ours is told so. Pages
        /// are left alone.
        static func redraw() {
            for window in NSApp.windows {
                guard let root = window.contentView?.superview ?? window.contentView else { continue }
                redraw(root)
            }
            Brand.themeChanged.send(())
        }

        private static func redraw(_ view: NSView) {
            if let web = NSClassFromString("WKWebView"), view.isKind(of: web) { return }
            if Bundle(for: type(of: view)) == .main { view.viewDidChangeEffectiveAppearance() }
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
    }

    // MARK: - Colors (light and dark designed together)

    enum Color {
        nonisolated static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        }

        /// A color with a stronger version for Increase Contrast (`Tokens.Contrast`), by day and at night. Without it
        /// the color resolves exactly as `dynamic(light:dark:)` does.
        nonisolated static func dynamic(light: NSColor, dark: NSColor, highLight: NSColor, highDark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                let high = Contrast.isHigh(appearance)
                return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? (high ? highDark : dark) : (high ? highLight : light)
            }
        }

        nonisolated static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: alpha)
        }

        static let textPrimary = dynamic(light: hex(0x000000, alpha: 0.86), dark: hex(0xFFFFFF, alpha: 0.92),
            highLight: hex(0x000000, alpha: 0.92), highDark: hex(0xFFFFFF, alpha: 0.98))
        static let textSecondary = dynamic(light: hex(0x000000, alpha: 0.54), dark: hex(0xFFFFFF, alpha: 0.56),
            highLight: hex(0x000000, alpha: 0.72), highDark: hex(0xFFFFFF, alpha: 0.80))
        static let textTertiary = dynamic(light: hex(0x000000, alpha: 0.45), dark: hex(0xFFFFFF, alpha: 0.42),
            highLight: hex(0x000000, alpha: 0.64), highDark: hex(0xFFFFFF, alpha: 0.72))
        /// Disabled quiet button text: the faintest text at full opacity, still 3:1.
        static let textDisabled = textTertiary
        /// A round swatch's ring under the pointer: faint beside the chosen one's, with nothing moving.
        static let swatchHoverRing = dynamic(light: hex(0x000000, alpha: 0.2), dark: hex(0xFFFFFF, alpha: 0.28))

        static let icon = dynamic(light: hex(0x000000, alpha: 0.62), dark: hex(0xFFFFFF, alpha: 0.66),
            highLight: hex(0x000000, alpha: 0.80), highDark: hex(0xFFFFFF, alpha: 0.84))
        /// The window's own toolbar and bottom bar glyphs: a step crisper than a panel's icons, on any space's color.
        static let chromeIcon = dynamic(light: hex(0x000000, alpha: 0.72), dark: hex(0xFFFFFF, alpha: 0.78),
            highLight: hex(0x000000, alpha: 0.86), highDark: hex(0xFFFFFF, alpha: 0.92))

        /// Row and button overlays drawn on top of the window background.
        static let hoverFill = dynamic(light: hex(0x000000, alpha: 0.05), dark: hex(0xFFFFFF, alpha: 0.06),
            highLight: hex(0x000000, alpha: 0.09), highDark: hex(0xFFFFFF, alpha: 0.11))
        static let pressedFill = dynamic(light: hex(0x000000, alpha: 0.09), dark: hex(0xFFFFFF, alpha: 0.10),
            highLight: hex(0x000000, alpha: 0.15), highDark: hex(0xFFFFFF, alpha: 0.17))
        /// A button's hover and press over a playing video (the mini player's controls): white washes strong enough
        /// to show over the dimmed picture, whatever its colors.
        static let mediaHover = NSColor.white.withAlphaComponent(0.22)
        static let mediaPressed = NSColor.white.withAlphaComponent(0.32)
        /// A chosen row on a panel or a page: a clear neutral fill with a 1px edge (`selectedEdge`) and a shadow-sm
        /// (`liftShadow`). The sidebar's own rows sit on the frame and use `Tokens.Chrome` instead.
        static let selectedFill = dynamic(light: hex(0x000000, alpha: 0.09), dark: hex(0xFFFFFF, alpha: 0.11),
            highLight: hex(0x000000, alpha: 0.13), highDark: hex(0xFFFFFF, alpha: 0.17))
        static let selectedHoverFill = dynamic(light: hex(0x000000, alpha: 0.11), dark: hex(0xFFFFFF, alpha: 0.13),
            highLight: hex(0x000000, alpha: 0.16), highDark: hex(0xFFFFFF, alpha: 0.20))
        static let selectedEdge = dynamic(light: hex(0x000000, alpha: 0.06), dark: hex(0xFFFFFF, alpha: 0.06),
            highLight: hex(0x000000, alpha: 0.32), highDark: hex(0xFFFFFF, alpha: 0.32))
        static let liftShadow = dynamic(light: hex(0x000000, alpha: 0.06), dark: hex(0x000000, alpha: 0.28))
        /// A split pane's address on the page card: a faint fill and a 1px edge, a step deeper under the pointer.
        static let chromeFill = dynamic(light: hex(0x000000, alpha: 0.05), dark: hex(0xFFFFFF, alpha: 0.07),
            highLight: hex(0x000000, alpha: 0.09), highDark: hex(0xFFFFFF, alpha: 0.12))
        static let chromeHover = dynamic(light: hex(0x000000, alpha: 0.075), dark: hex(0xFFFFFF, alpha: 0.10),
            highLight: hex(0x000000, alpha: 0.13), highDark: hex(0xFFFFFF, alpha: 0.16))
        static let chromeEdge = dynamic(light: hex(0x000000, alpha: 0.08), dark: hex(0xFFFFFF, alpha: 0.08),
            highLight: hex(0x000000, alpha: 0.32), highDark: hex(0xFFFFFF, alpha: 0.32))
        static let glassFill = dynamic(light: hex(0xFFFFFF, alpha: 0.32), dark: hex(0xFFFFFF, alpha: 0.06),
            highLight: hex(0xFFFFFF, alpha: 0.6), highDark: hex(0xFFFFFF, alpha: 0.12))
        static let glassHover = dynamic(light: hex(0xFFFFFF, alpha: 0.5), dark: hex(0xFFFFFF, alpha: 0.1),
            highLight: hex(0xFFFFFF, alpha: 0.75), highDark: hex(0xFFFFFF, alpha: 0.18))
        static let glassEdge = dynamic(light: hex(0xFFFFFF, alpha: 0.55), dark: hex(0xFFFFFF, alpha: 0.08),
            highLight: hex(0x000000, alpha: 0.3), highDark: hex(0xFFFFFF, alpha: 0.3))
        /// A tile whose page is open in the background: a fine darker edge in place of the usual one.
        static let openEdge = dynamic(light: hex(0x000000, alpha: 0.16), dark: hex(0xFFFFFF, alpha: 0.2),
            highLight: hex(0x000000, alpha: 0.5), highDark: hex(0xFFFFFF, alpha: 0.5))
        /// The keyboard-selected row in floating lists (command bar, downloads).
        static let highlight = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0xFFFFFF, alpha: 0.09),
            highLight: hex(0x000000, alpha: 0.12), highDark: hex(0xFFFFFF, alpha: 0.15))
        static let fieldFill = dynamic(light: hex(0x000000, alpha: 0.045), dark: hex(0xFFFFFF, alpha: 0.06),
            highLight: hex(0x000000, alpha: 0.08), highDark: hex(0xFFFFFF, alpha: 0.11))

        /// The secondary button, a dropdown, a page's search field: white with a hairline and a faint shadow, a lighter
        /// step of the surface in dark mode. Hover is a hair grayer, pressed a step darker; never a scale.
        static let controlFill = dynamic(light: hex(0xFFFFFF), dark: hex(0xFFFFFF, alpha: 0.09))
        static let controlHover = dynamic(light: hex(0xF6F6F7), dark: hex(0xFFFFFF, alpha: 0.13))
        static let controlPressed = dynamic(light: hex(0xECECEE), dark: hex(0xFFFFFF, alpha: 0.06))
        static let controlEdge = dynamic(light: hex(0x000000, alpha: 0.12), dark: hex(0xFFFFFF, alpha: 0.1),
            highLight: hex(0x000000, alpha: 0.45), highDark: hex(0xFFFFFF, alpha: 0.42))
        static let controlShadow = dynamic(light: hex(0x000000, alpha: 0.06), dark: hex(0x000000, alpha: 0.3))
        /// The one primary action on a surface: a dark filled pill (light in dark mode), whatever the space.
        static let primaryFill = dynamic(light: hex(0x1D1D1F), dark: hex(0xF2F2F4))
        static let primaryHover = dynamic(light: hex(0x343437), dark: hex(0xFFFFFF))
        static let primaryPressed = dynamic(light: hex(0x000000), dark: hex(0xD9D9DD))
        static let onPrimary = dynamic(light: hex(0xFFFFFF), dark: hex(0x1D1D1F))
        /// Keyboard focus on a drawn control: a ring in the window's accent at this opacity, `Metric.focusRing` wide,
        /// `Metric.focusGap` outside the control.
        static let focusAlpha: CGFloat = 0.6

        static let separator = dynamic(light: hex(0x000000, alpha: 0.08), dark: hex(0xFFFFFF, alpha: 0.08),
            highLight: hex(0x000000, alpha: 0.32), highDark: hex(0xFFFFFF, alpha: 0.30))

        /// The page card when there is no page, and its edge.
        static let cardBackground = dynamic(light: hex(0xFFFFFF), dark: hex(0x1E1E20))
        static let cardEdge = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0xFFFFFF, alpha: 0.07),
            highLight: hex(0x000000, alpha: 0.32), highDark: hex(0xFFFFFF, alpha: 0.30))
        /// Only shadow in the window: lifts the page off the frame.
        static let cardShadow = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0x000000, alpha: 0.28))
        /// The page beside the sidebar, resting on the frame: soft, falling onto the sidebar along the page's edge.
        static let sheetShadow = dynamic(light: hex(0x000000, alpha: 0.05), dark: hex(0x000000, alpha: 0.32))
        /// Right at the page's edge beside the sidebar: tight and a little darker, so the edge reads crisp.
        static let sheetContact = dynamic(light: hex(0x000000, alpha: 0.12), dark: hex(0x000000, alpha: 0.5))

        /// A floating surface in a window with no space color (or a white, gray or black one): opaque. Panels in a
        /// colored space lean toward it (`Brand.Theme.panel`).
        static let panelBackground = dynamic(light: hex(0xFCFCFC), dark: hex(0x2A2A2D))
        /// A small floating thing over a page that has to stay light (the swipe arrows): the panel color, mostly opaque;
        /// fully, with Reduce Transparency or Increase Contrast (`Contrast.isOpaque`).
        static let panelWash = NSColor(name: nil) { appearance in
            let solid = Contrast.isOpaque || Contrast.isHigh(appearance)
            return appearance.isDark ? hex(0x1F1F22, alpha: solid ? 1 : 0.88) : hex(0xFFFFFF, alpha: solid ? 1 : 0.9)
        }
        static let panelEdge = dynamic(light: hex(0x000000, alpha: 0.09), dark: hex(0xFFFFFF, alpha: 0.10),
            highLight: hex(0x000000, alpha: 0.4), highDark: hex(0xFFFFFF, alpha: 0.4))
        static let panelShadow = dynamic(light: hex(0x000000, alpha: 0.10), dark: hex(0x000000, alpha: 0.4))
        static let scrim = dynamic(light: hex(0x000000, alpha: 0.10), dark: hex(0x000000, alpha: 0.30))
        /// A firmer dim than `scrim`, under the docked Mini: the page reads as a layer beneath it.
        static let peekScrim = dynamic(light: hex(0x000000, alpha: 0.20), dark: hex(0x000000, alpha: 0.42))

        /// Zigzag's one accent. The rule: UI in a browser window takes that window's space accent, so progress,
        /// focus, selection and actions agree there; windows that belong to the app rather than a space (Settings,
        /// Passwords, Import, About, the welcome) take the brand's, `Brand.Theme.brand`. This is the front browser
        /// window's; a view that can show in either kind of window asks `Brand.Theme.for(self)` instead.
        @MainActor static var accent: NSColor { Brand.Theme.current.accent }
        /// Counts on extension buttons: a neutral dark pill under white figures, a step lighter in dark so it still
        /// stands off the field.
        static let badge = dynamic(light: hex(0x48484A), dark: hex(0x636366))

        /// A page's one surface (History, Settings), the same as the page card's.
        static let surface = cardBackground
        /// A group of rows on the surface, and its hairline edge.
        static let surfaceGroup = dynamic(light: hex(0xFFFFFF), dark: hex(0x2A2A2D))
        static let surfaceGroupEdge = dynamic(light: hex(0x000000, alpha: 0.08), dark: hex(0xFFFFFF, alpha: 0.06),
            highLight: hex(0x000000, alpha: 0.32), highDark: hex(0xFFFFFF, alpha: 0.30))
        /// Wordmark on a space background image: white with a soft shadow (`Shadow.liftRadius`, `liftDrop`), like the
        /// lock screen. Stronger with Increase Contrast.
        static let markOnPicture = dynamic(light: hex(0xFFFFFF, alpha: 0.9), dark: hex(0xFFFFFF, alpha: 0.86),
            highLight: hex(0xFFFFFF, alpha: 1), highDark: hex(0xFFFFFF, alpha: 1))
        static let markOnPictureShadow = dynamic(light: hex(0x000000, alpha: 0.32), dark: hex(0x000000, alpha: 0.45),
            highLight: hex(0x000000, alpha: 0.55), highDark: hex(0x000000, alpha: 0.65))
        /// Behind a PDF's pages and in its sidebar: a shade off the card, so each page stands out as paper.
        static let pdfBackdrop = dynamic(light: hex(0xEDEDF0), dark: hex(0x161618))
        /// Between a PDF's pages while they're drawn dark: a shade lighter than the dark paper, so each still reads as one.
        static let pdfBackdropDarkPages = hex(0x2A2A2D)
        /// Something chosen in a list (a section, a row reached with the keyboard), drawn in the accent at this opacity.
        static let selectionAlpha: CGFloat = 0.14
        /// The same, held down.
        static let selectionPressedAlpha: CGFloat = 0.22
        /// Where something carried would land (a folder, the first favorite's place, a split's half): the accent at
        /// this opacity, inside a `Metric.dropEdge` accent edge at `dropEdgeAlpha`. One look for every drop target.
        static let dropAlpha: CGFloat = 0.14
        static let dropEdgeAlpha: CGFloat = 0.7
        /// The header of the split pane you're not working in, faded to this, so the one you are reads first.
        static let unfocusedPaneAlpha: CGFloat = 0.45
        /// Selected text in our own fields (the command bar, its inline completion), in the accent at this opacity.
        static let textSelectionAlpha: CGFloat = 0.26
        /// A firmer dim than `scrim`, under a zoomed pane: a page above the page should read as a layer.
        static let zoomScrim = dynamic(light: hex(0x000000, alpha: 0.2), dark: hex(0x000000, alpha: 0.42))
        /// Capture's dim over the page around what's picked: firm enough that the clear part reads at once.
        static let captureScrim = dynamic(light: hex(0x000000, alpha: 0.3), dark: hex(0x000000, alpha: 0.5))
        /// The edge of a picked area: a light line that reads on the dim and on the page it frames.
        static let captureEdge = hex(0xFFFFFF, alpha: 0.9)
        /// A keycap's fill and edge (`KeyCap`): a touch of the field fill with a hairline, like a key seen from above.
        static let keyCapFill = dynamic(light: hex(0x000000, alpha: 0.04), dark: hex(0xFFFFFF, alpha: 0.07),
            highLight: hex(0x000000, alpha: 0.07), highDark: hex(0xFFFFFF, alpha: 0.11))
        static let keyCapEdge = dynamic(light: hex(0x000000, alpha: 0.1), dark: hex(0xFFFFFF, alpha: 0.1),
            highLight: hex(0x000000, alpha: 0.42), highDark: hex(0xFFFFFF, alpha: 0.4))

        /// Settings: the window behind grouped rows (System Settings proportions).
        static let formBackground = dynamic(light: hex(0xF2F2F4), dark: hex(0x1E1E20))
        static let progress = dynamic(light: hex(0x000000, alpha: 0.28), dark: hex(0xFFFFFF, alpha: 0.32),
            highLight: hex(0x000000, alpha: 0.5), highDark: hex(0xFFFFFF, alpha: 0.55))
        static let destructive = NSColor.systemRed
        /// Status: something to fix (a weak password, an import problem).
        static let warning = NSColor.systemOrange
        /// Status: worth knowing (a reused password). A deep amber on light backgrounds, where yellow can't be read.
        static let caution = dynamic(light: hex(0x9A5B00), dark: hex(0xF2C14E))
        /// Status: done and fine.
        static let success = NSColor.systemGreen

        /// Text on a color Zigzag doesn't choose (a site's brand on its search chip, a page's own top color in a strip):
        /// near-white on dark colors, near-black on light ones.
        static func ink(on color: NSColor) -> NSColor {
            guard let c = color.usingColorSpace(.sRGB) else { return textPrimary }
            let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            return luminance < 0.58 ? hex(0xFFFFFF, alpha: 0.94) : hex(0x000000, alpha: 0.84)
        }

        /// How dark a color is, 0 to 1 by its luminance: for deciding whether a color we don't choose needs an edge.
        static func luminance(of color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0.5 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        /// A status color's soft fill behind a note (a weak password's warning): the color at this opacity.
        static let statusFillAlpha: CGFloat = 0.12
    }

    // MARK: - The slide switch

    /// `Toggle`, a slide switch: a recessed matte track (`Metric.toggleSize`, 34 by 20) with a hairline edge and shade
    /// under its upper lip, and a small round knob (`Metric.toggleKnob`, 14) that is porcelain when off and the one
    /// space's accent when on. The track never lights up; on and off differ by the knob's place and color.
    enum Switch {
        private static func ink(_ alpha: CGFloat) -> NSColor { Color.hex(0x000000, alpha: alpha) }
        private static func light(_ alpha: CGFloat) -> NSColor { Color.hex(0xFFFFFF, alpha: alpha) }
        /// Off track: darker than the page in light; lighter in dark, like macOS's switch, since a darker track
        /// vanishes.
        static let track = Color.dynamic(light: ink(0.075), dark: light(0.16),
            highLight: ink(0.16), highDark: light(0.26))
        static let trackHover = Color.dynamic(light: ink(0.095), dark: light(0.19),
            highLight: ink(0.19), highDark: light(0.3))
        static let trackPressed = Color.dynamic(light: ink(0.115), dark: light(0.22),
            highLight: ink(0.22), highDark: light(0.34))
        static let edge = Color.dynamic(light: ink(0.06), dark: light(0.08),
            highLight: ink(0.4), highDark: light(0.35))
        /// The shade under the track's upper lip, fading out by `recessDepth` of its height.
        static let recess = Color.dynamic(light: ink(0.07), dark: ink(0.18))
        static let recessDepth: CGFloat = 0.55
        static let knob = Color.dynamic(light: Color.hex(0xFBFAF8), dark: Color.hex(0xE9E7E4))
        /// On: white on the accent-filled track, in both modes.
        static let knobOn = Color.hex(0xFFFFFF)
        /// On: the accent track's edge, a touch deeper than it, stronger with Increase Contrast.
        static let edgeOn = Color.dynamic(light: ink(0.1), dark: ink(0.2),
            highLight: ink(0.45), highDark: Color.hex(0xFFFFFF, alpha: 0.4))
        static let knobEdge = Color.dynamic(light: ink(0.11), dark: ink(0.3),
            highLight: ink(0.4), highDark: ink(0.5))
        static let knobShadow = Color.dynamic(light: ink(0.18), dark: ink(0.45))
        static let knobShadowRadius: CGFloat = 1
        static let knobShadowDrop: CGFloat = 0.5
    }

    // MARK: - The frame and the chrome on it

    /// The space's color as the window wears it: a curated color's OKLCH lightness and chroma, by day and at night.
    /// Soft enough to live with all day, colored enough that each space is unmistakably its own.
    enum Frame {
        static let lightness = 0.915
        static let chroma = 0.045
        static let darkLightness = 0.27
        static let darkChroma = 0.04
        /// The space editor's palette: a touch richer than the colors before it, by day and at night.
        static let paletteLightness = 0.915
        static let paletteChroma = 0.078
        static let paletteDarkLightness = 0.27
        static let paletteDarkChroma = 0.05
        /// How strong a new space's palette color is to a Zigzag from before the palette's own day and night depths
        /// (`SpaceColor.background(hue:intensity:)`).
        static let followingIntensity = 0.8
        static let softFollowingIntensity = 0.5
        /// The least a palette look's clear glass covers in a dark window (`SpaceInfo.clearTint`): its deep tint keeps
        /// light text readable over a light desktop.
        static let clearNightCover: CGFloat = 0.68
        /// A blank page in a palette space on glass: fainter than `wash`, near white by day and near the page's dark at night.
        static let glassPageLightness = 0.982
        static let glassPageChroma = 0.012
        static let glassPageDarkLightness = 0.228
        static let glassPageDarkChroma = 0.018
        /// A floating panel: near white with a breath of the space by day, a deep gray of it at night.
        static let panelLightness = 0.975
        static let panelChroma = 0.02
        static let panelDarkLightness = 0.27
        static let panelDarkChroma = 0.04
        /// The floating sidebar: how much of its glass the space's color covers, by day and at night. Enough that
        /// it's the same color as the docked sidebar over any page, and its inks keep their contrast; the page still
        /// shows through as soft color.
        static let floatingCover: CGFloat = 0.88
        static let floatingCoverDark: CGFloat = 0.9
        /// A page's quiet column (Settings' sections, Passwords' list): halfway between the frame and the white page.
        static let washLightness = 0.962
        static let washChroma = 0.016
        static let washDarkLightness = 0.235
        static let washDarkChroma = 0.016
        /// Reader's Auto paper: barely the space's hue, read as paper rather than color, lighter than a panel by day.
        static let readerLightness = 0.985
        static let readerChroma = 0.0035
        static let readerDarkLightness = 0.235
        static let readerDarkChroma = 0.005
        /// Reader's Space paper: the space's own color, held out of the middle tones and as calm as a frame.
        static let readerSpaceLightness = 0.86
        static let readerSpaceChroma = 0.05
        static let readerSpaceDarkLightness = 0.3
        static let readerSpaceDarkChroma = 0.045
    }

    /// What sits on the frame (the sidebar's rows, its address and favorites): washes of white, so whatever the
    /// space's color, gradient or see-through, each is a lighter step of that same color, never a gray laid over it.
    enum Chrome {
        private static func white(_ alpha: CGFloat) -> NSColor { Color.hex(0xFFFFFF, alpha: alpha) }
        private static func black(_ alpha: CGFloat) -> NSColor { Color.hex(0x000000, alpha: alpha) }

        /// The tab you're on: by day a near-white card lifted by one soft shadow (`cardShadow`, `Shadow.lift`), its edge
        /// only just there, so it reads as a card rather than an outline; at night a lighter step of the space's color.
        static let card = Color.dynamic(light: white(0.96), dark: white(0.18),
            highLight: white(1), highDark: white(0.24))
        static let cardHover = Color.dynamic(light: white(1), dark: white(0.21),
            highLight: white(1), highDark: white(0.27))
        /// At night the card's top edge catches the light: one pixel inside its upper rim (`setCardRim`). By day the
        /// card is nearly white already and a lit edge can't read at 1x, so there is none.
        static let rim = Color.dynamic(light: .clear, dark: white(0.14))
        /// Only just there by night too: the lit rim and the shadow part the card, a bright line all round would
        /// outline it.
        static let cardEdge = Color.dynamic(light: Color.hex(0x000000, alpha: 0.035), dark: white(0.035),
            highLight: Color.hex(0x000000, alpha: 0.3), highDark: white(0.3))
        static let cardShadow = Color.dynamic(light: Color.hex(0x1E2A44, alpha: 0.10), dark: Color.hex(0x000000, alpha: 0.3))
        /// A row or a toolbar button under the pointer. By day a shade, not a white wash: white can't show on a white or
        /// near-white space. About the same step on every space, light or dark; pressed, a step more.
        static let hover = Color.dynamic(light: black(0.06), dark: white(0.065),
            highLight: black(0.12), highDark: white(0.12))
        /// New Tab under the pointer: a lighter wash than a tab's, so the one quiet row stays quiet.
        static let quietHover = Color.dynamic(light: black(0.035), dark: white(0.04),
            highLight: black(0.08), highDark: white(0.08))
        /// Pressed: a step further from the space than hover (`showSink`).
        static let pressed = Color.dynamic(light: black(0.10), dark: white(0.10),
            highLight: black(0.16), highDark: white(0.16))

        /// A button's hover and press wash against its ground, as WCAG contrast ratios; and with Increase Contrast.
        nonisolated static let washContrast = (hover: 1.2, pressed: 1.36)
        nonisolated static let highWashContrast = (hover: 1.4, pressed: 1.6)
        /// The strongest a button's wash gets.
        nonisolated static let washMaxAlpha: CGFloat = 0.3

        /// A button's hover or press wash: white at night, black by day, just strong enough to reach `washContrast` on
        /// every one of `grounds`; with none known, on black at night and white by day.
        nonisolated static func buttonWash(pressed: Bool, on grounds: [NSColor] = []) -> NSColor {
            NSColor(name: nil) { appearance in
                let dark = appearance.isDark
                let goals = Contrast.isHigh(appearance) ? highWashContrast : washContrast
                var shown: [NSColor] = []
                appearance.performAsCurrentDrawingAppearance { shown = grounds.compactMap { $0.usingColorSpace(.sRGB) } }
                if shown.isEmpty { shown = [NSColor(srgbRed: dark ? 0 : 1, green: dark ? 0 : 1, blue: dark ? 0 : 1, alpha: 1)] }
                let alpha = shown.map { washAlpha(on: $0, white: dark, contrast: pressed ? goals.pressed : goals.hover) }.max() ?? 0
                return NSColor(srgbRed: dark ? 1 : 0, green: dark ? 1 : 0, blue: dark ? 1 : 0, alpha: alpha)
            }
        }

        /// The least alpha of white (or black) laid over the sRGB `ground` that parts from it by `contrast`.
        nonisolated static func washAlpha(on ground: NSColor, white: Bool, contrast: Double) -> CGFloat {
            let ink: CGFloat = white ? 1 : 0
            let channels = [ground.redComponent, ground.greenComponent, ground.blueComponent]
            func luminance(_ c: [CGFloat]) -> Double {
                let linear = c.map { v -> Double in let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
            }
            let base = luminance(channels)
            func parts(_ a: CGFloat) -> Bool {
                let laid = luminance(channels.map { $0 * (1 - a) + ink * a })
                return (max(laid, base) + 0.05) / (min(laid, base) + 0.05) >= contrast
            }
            guard parts(washMaxAlpha) else { return washMaxAlpha }
            var low: CGFloat = 0, high = washMaxAlpha
            for _ in 0..<16 {
                let mid = (low + high) / 2
                if parts(mid) { high = mid } else { low = mid }
            }
            return high
        }

        /// The address and the favorites: a soft field of the space's color, no line around it.
        static let field = Color.dynamic(light: white(0.45), dark: white(0.065),
            highLight: white(0.72), highDark: white(0.12))
        static let fieldHover = Color.dynamic(light: white(0.62), dark: white(0.095),
            highLight: white(0.85), highDark: white(0.16))
        /// A field or a favorite held down: a step back from its hover, never below the field at rest.
        static let fieldPressed = Color.dynamic(light: white(0.52), dark: white(0.08),
            highLight: white(0.78), highDark: white(0.14))
        /// A space key: its matte face, the hairline around it, and the shade along its lower lip.
        static let key = Color.dynamic(light: white(0.5), dark: white(0.07),
            highLight: white(0.75), highDark: white(0.12))
        static let keyEdge = Color.dynamic(light: Color.hex(0x000000, alpha: 0.07), dark: white(0.09),
            highLight: Color.hex(0x000000, alpha: 0.4), highDark: white(0.35))
        /// Open favorite tile: brighter than closed, halfway to the selected card; brighter on hover.
        static let openTile = Color.dynamic(light: white(0.74), dark: white(0.125),
            highLight: white(0.9), highDark: white(0.19))
        static let openTileHover = Color.dynamic(light: white(0.84), dark: white(0.15),
            highLight: white(0.95), highDark: white(0.22))
        /// A pinned page or favorite whose page is open: a hint of an edge, quieter than the selected card's (#351).
        static let openEdge = Color.dynamic(light: Color.hex(0x000000, alpha: 0.035), dark: white(0.03),
            highLight: Color.hex(0x000000, alpha: 0.45), highDark: white(0.45))
    }

    // MARK: - Materials (the tactile kit in Materials.swift; Design/DESIGN.md, "Materials")

    /// One light, straight above: highlights sit on top edges, shadows fall straight down and are tinted with the
    /// navy, so they read as shade on a colored world rather than gray smudges.
    enum Material {
        /// A color for light and one for dark, resolved by the layer that draws it.
        struct Tone {
            let light: NSColor
            let dark: NSColor
            func cg(_ isDark: Bool) -> CGColor { (isDark ? dark : light).cgColor }
        }

        /// How far a thing stands off what's under it: a wide, soft ambient shadow and a tight contact one.
        struct Elevation {
            var ambientRadius: CGFloat, ambientDrop: CGFloat, ambientOpacity: Float
            var contactRadius: CGFloat, contactDrop: CGFloat, contactOpacity: Float

            /// The same elevation for a thing `factor` times the size it was drawn for.
            func scaled(_ factor: CGFloat) -> Elevation {
                Elevation(ambientRadius: ambientRadius * factor, ambientDrop: ambientDrop * factor, ambientOpacity: ambientOpacity,
                          contactRadius: contactRadius * factor, contactDrop: contactDrop * factor, contactOpacity: contactOpacity)
            }
        }

        private static func white(_ alpha: CGFloat) -> NSColor { Color.hex(0xFFFFFF, alpha: alpha) }
        private static func ink(_ alpha: CGFloat) -> NSColor { Color.hex(0x0B1A2E, alpha: alpha) }

        /// The color shadows are made of. Dark mode's are deeper (`darkShadowGain`), since dark surfaces need more to part.
        static let shadowInk = Tone(light: Color.hex(0x0B1A2E), dark: Color.hex(0x000000))
        static let darkShadowGain: Float = 2.2

        /// The specular rim along a raised or glass thing's top edge, and the fainter light caught at its bottom edge.
        static let rim = Tone(light: white(0.95), dark: white(0.30))
        static let rimCatch = Tone(light: white(0.5), dark: white(0.08))
        /// The darker bottom of a raised thing's bevel.
        static let bevelShade = Tone(light: ink(0.16), dark: Color.hex(0x000000, alpha: 0.5))
        /// A hairline just outside a raised or glass thing, so it parts from what's behind it.
        static let outline = Tone(light: ink(0.10), dark: Color.hex(0x000000, alpha: 0.55))

        /// Raised surfaces (a secondary button): lit at the top, a step deeper at the bottom.
        static let raisedTop = Tone(light: Color.hex(0xFFFFFF), dark: Color.hex(0x464A54))
        static let raisedBottom = Tone(light: Color.hex(0xEEF1F5), dark: Color.hex(0x30333B))
        /// The same pressed in: the gradient turned over, so the light seems to fall into it.
        static let pressedTop = Tone(light: Color.hex(0xE3E7ED), dark: Color.hex(0x2A2D34))
        static let pressedBottom = Tone(light: Color.hex(0xF4F6F9), dark: Color.hex(0x3A3D46))
        /// A tile's porcelain body, and a toggle's knob.
        static let porcelainTop = Tone(light: Color.hex(0xFAFBFD), dark: Color.hex(0xE2E7EE))
        static let porcelainBottom = Tone(light: Color.hex(0xE2E7EE), dark: Color.hex(0xB3BDCB))

        /// Recessed things (a field, a toggle's track): darker at the top where the lip shades them, an inner
        /// shadow under that lip, and the light caught on the lower lip outside.
        static let recessTop = Tone(light: ink(0.10), dark: Color.hex(0x000000, alpha: 0.42))
        static let recessBottom = Tone(light: ink(0.035), dark: Color.hex(0x000000, alpha: 0.26))
        static let recessShade = Tone(light: ink(0.30), dark: Color.hex(0x000000, alpha: 0.9))
        static let lip = Tone(light: white(0.9), dark: white(0.09))

        /// Glass: the wash over the frost, top to bottom, the glow just inside its edge, and the specular hot spot.
        static let glassWashTop = Tone(light: white(0.50), dark: white(0.07))
        static let glassWashBottom = Tone(light: white(0.20), dark: white(0.02))
        static let glassGlow = Tone(light: white(1), dark: white(0.5))
        static let sheen = Tone(light: white(0.85), dark: white(0.22))
        /// Text on a tactile primary, which keeps the deep accent in dark mode too, glossy and saturated.
        static let primaryInk = NSColor.white
        /// Grain over glass, so it reads as a material rather than a screen.
        static let grainOpacity: Float = 0.05

        /// Elevations: a raised control at rest, under the pointer and pressed; a 64pt tile at rest and lifted
        /// (scale with its side); a floating glass surface.
        static let raisedRest = Elevation(ambientRadius: 6, ambientDrop: 3, ambientOpacity: 0.12, contactRadius: 1, contactDrop: 1, contactOpacity: 0.2)
        static let raisedHover = Elevation(ambientRadius: 10, ambientDrop: 5, ambientOpacity: 0.16, contactRadius: 1.5, contactDrop: 1.5, contactOpacity: 0.18)
        static let raisedPressed = Elevation(ambientRadius: 2, ambientDrop: 1, ambientOpacity: 0.06, contactRadius: 0.5, contactDrop: 0.5, contactOpacity: 0.22)
        static let tileRest = Elevation(ambientRadius: 12, ambientDrop: 10, ambientOpacity: 0.2, contactRadius: 1.5, contactDrop: 1.5, contactOpacity: 0.24)
        static let tileLifted = Elevation(ambientRadius: 20, ambientDrop: 17, ambientOpacity: 0.24, contactRadius: 2.5, contactDrop: 2, contactOpacity: 0.16)
        static let floating = Elevation(ambientRadius: 44, ambientDrop: 26, ambientOpacity: 0.16, contactRadius: 1.5, contactDrop: 1, contactOpacity: 0.12)

        /// How far a raised thing rises under the pointer, how far a pressed one sinks, and a lifted tile's rise.
        static let lift: CGFloat = 1
        static let sink: CGFloat = 1
        static let tileLift: CGFloat = 3
        /// A pressed control shrinks a touch as it sinks, as a thing pushed away from you does.
        static let pressScale: CGFloat = 0.97
        /// The most a hero object turns toward the pointer, in degrees, and the depth it's seen from.
        static let tilt: CGFloat = 5
        static let perspective: CGFloat = -1 / 1100
        /// A material object rising, sinking or settling: the one hover that moves rather than appears, since it's
        /// a thing moving, not a fill changing. Pressing in is quicker than coming back.
        static let settle: TimeInterval = Motion.standard
        static let pressIn: TimeInterval = Motion.quick
        /// Turning to follow the pointer: slow enough to feel like weight.
        static let follow: TimeInterval = 0.6
        /// A tile's corner as a share of its side, as app icons have it.
        static let tileCorner: CGFloat = 0.2237
        /// A large glass surface on a brand moment, and the height of its tactile controls.
        static let heroRadius: CGFloat = 28
        static let controlHeight: CGFloat = Space.x10
        /// The one big action on a brand moment ("Get Started"), and its text.
        static let largeControlHeight: CGFloat = Space.x10 + Space.x1
        static let largeText: CGFloat = 15
        /// A brand moment's headline: one line saying what Zigzag is.
        static let headline: CGFloat = 30
        /// The keyboard focus ring's soft glow around a field.
        static let focusGlow: CGFloat = 4
    }

    // MARK: - Shadows (purposeful only)

    enum Shadow {
        /// Card: barely there, separates page from frame.
        static let cardRadius: CGFloat = 2
        static let cardOffset = CGSize(width: 0, height: -1)
        /// The page beside the sidebar: a wide, soft fall onto the sidebar.
        static let sheetRadius: CGFloat = 8
        static let sheetContact: CGFloat = 1
        /// Floating panels sit just above the page: one soft, small shadow that falls below them, never above.
        static let panelRadius: CGFloat = 16
        static let panelDrop: CGFloat = 3
        /// The selected row and a selected tile: a small, soft shadow just under them, so the card lifts off the
        /// sidebar instead of being outlined.
        static let liftRadius: CGFloat = 4
        static let liftDrop: CGFloat = 1.5
        /// A row carried to its new place: a small, crisp lift while it travels.
        static let carryRadius: CGFloat = 4
        static let carryDrop: CGFloat = 2
        /// A secondary button's faint shadow: just enough to sit on the white it's on.
        static let controlRadius: CGFloat = 1.5
        static let controlDrop: CGFloat = 0.5

        /// The drop as a layer offset: flipped views measure y downward, so the sign follows the view.
        static func panelOffset(flipped: Bool) -> CGSize { CGSize(width: 0, height: flipped ? panelDrop : -panelDrop) }
    }
}

extension NSAppearance {
    nonisolated var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
