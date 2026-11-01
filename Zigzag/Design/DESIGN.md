# Zigzag's design language

Thin, calm and warm: each space is a soft color of its own, and the whole window wears it. The chrome on top is
light: thin icons, light type with a clear hierarchy, no boxes, lines only where they structure something, and every
fill a wash of the space's own color, so a space feels like yours rather than a gray template. Motion is short,
eased out, never bouncy, and gets out of the way. The references are Arc's color per space without its complexity,
Aside's polish, and the interaction craft of animations.dev. Still unmistakably Zigzag: the ribbon Z and the drawn
ZIGZAG wordmark exactly as they are, the see-through frame, the sidebar that carries back, forward, reload and the
address.

## Space color

The soul of the window. A space's color fills the sidebar and the frame around the page completely, by day and at
night (`SpaceColor`, `Tokens.Frame`).

- **Curated colors**: white, sky, lavender, rose, peach, sand, sage, mint and graphite. The hues sit at one OKLCH
  lightness (0.915) and one gentle chroma (0.045) by day, and at a deep, quiet tint (0.27, 0.04) at night, so any two
  look right side by side and each is colored enough to tell at a glance. A curated space follows the Mac between
  its two shades. A new space takes the next curated color no other space has.
- **Custom**: any hue and depth from the wheel, mixed in OKLCH (`SpaceColor.paint`); a deep one turns the window dark.
- **Effects**, all optional: a second color for a gradient and its direction, see-through (the frosted desktop under
  a thinner coat of the color), and grain.
- **Ink**: text and icons are near-black or near-white with a little alpha, so the color shows through them a touch;
  the window's mode follows the color's lightness, so they always pass AA on it.
- **Switching spaces** cross-fades the frame's color (`Motion.standard`, eased out); from the keyboard too, since the
  layout of the window should move so you see where you went.
- Everything on the frame derives from the color (`Tokens.Chrome`): washes of white over it, so in any space, on a
  gradient or see-through, each fill is a lighter step of that same color.

Every value lives in `Tokens.swift`. Every shared part lives in `Components.swift`, `Controls.swift` and
`Page.swift`. A view never invents a color, radius, shadow, size or duration; if the system lacks one, add it to
Tokens with a line saying what it's for, and use it everywhere it applies. Rebuild a view to the system rather than
tuning its old numbers, and delete one-off styling instead of keeping it beside the new.

## Layers and depth

Four layers, front to back. Each has one material and one depth cue; nothing else casts a shadow.

| Layer | What | Material | Depth |
|---|---|---|---|
| 0. Frame | The window behind everything: the space's color, gradient, grain, or the desktop through it | Space color (`SpaceColor`), clear glass when see-through | None |
| 1. Surfaces | The page card; Settings, History, Passwords pages | Opaque `Color.surface`; Settings' column a light tint of the space (`Theme.wash`) | `Color.cardShadow`, barely there |
| 2. Cards | The selected tab, a selected favorite; grouped rows and chosen rows on pages and panels | On the frame `Chrome.card`; elsewhere `Color.selectedFill` / `surfaceGroup` | A quiet edge and a shadow-sm (`Chrome.cardEdge`, `cardShadow`; `setLifted`) |
| 3. Floating | Panels, popovers, menus, the command bar, find, downloads, Peek, the switcher | Opaque, leaning toward the space (`Brand.Theme.panel`) | Hairline `panelEdge` and one soft small shadow (`Shadow.panelRadius` 16, `panelDrop` 3) |

The sidebar has no surface of its own: it is the frame, in the space's full color. What sits on it is quiet (rows at
rest, labels) or a soft wash of that color: the address and the favorites are soft fields (`Chrome.field`) with no
line around them; the tab you're on is a light card of the color (`Chrome.card`, white at 80% by day, 13% at night)
with a crisp quiet edge and a shadow-sm, seen at a glance on any color. Hover is a gentler wash (`Chrome.hover`).
No bevels, no puffy shadows, no boxes.

No glass gimmicks: see-through spaces frost the desktop under the frame, and that is the only blur.

## Size scale

One scale for pages and panels, in `Tokens`: the same role is the same size everywhere on them. Pages read calm,
Mac-like. The browser window's chrome (the sidebar and a split pane's header) is a compact scale of its own,
`Tokens.Sidebar` and `Tokens.Pane`, in the table after these. Nothing else picks a size.

SF Pro, one weight per role. Secondary text is light gray and never bold; selection never changes weight. The
space's name in the sidebar is the one heading there: 16 light (`Font.spaceName`), in a 40pt slot, low in it.

| Text | Token | Size, weight | For |
|---|---|---|---|
| label | `Font.label()` | 12 medium, `textTertiary` | A section's label ("Tabs", the space name), a group's heading on a page |
| | `Font.detail()` | 12 regular, `textSecondary` | A row's explanation under its title |
| small | `Font.small()` | 11 | Small print, captions, counts, keycaps |
| body | `Font.body()`, `Font.control()` | 13 regular; 13 medium | Panels, forms, menus; what a button or dropdown says |
| row | `Font.row()` | 14 regular | A row's title in a list on a page: Settings' sections and rows, History, Passwords |
| heading | `Font.heading()` | 15 semibold | A panel's title, a section's title on a page |
| title | `Font.title()` | 17 semibold | A page's title in its header, a big panel's title, the command bar's field |
| display | `Brand.display`, `TypeSize.display` | 22 heavy | Brand moments only, one line per window |

| Icon | Token | pt | For |
|---|---|---|---|
| glyph | `Symbol.glyph` | 17 | In an icon button: toolbar, bottom bar, pane header, find bar, a panel's close |
| compact glyph | `Symbol.compactGlyph` | 14 | In a compact icon button, inside a row or a field |
| row icon | `Metric.favicon`, `Symbol.row` | 18 slot, 16pt symbol | A favicon, or the symbol in its place, wherever a row has a picture |
| inline | `Symbol.inline` | 11 | A lock, a disclosure chevron, a dropdown's arrows |

| Hit target | Token | pt | For |
|---|---|---|---|
| icon button | `Metric.iconButton`, `IconButton(.regular)` | 32 | Everything above that takes a `glyph` |
| compact icon button | `Metric.compactIconButton`, `IconButton(.compact)` | 24 | A tab's close and mute, the address's Reader and extensions, a row's trash |
| control | `Metric.controlHeight` (`Page.controlHeight`) | 28 | Pill buttons, dropdowns, search fields, a menu's items |
| row | `Metric.rowHeight` (`Page.rowHeight`) | 34 | A list of places, History |

Every symbol is light weight (`Symbol.weight`), a thin monochrome outline tinted `Color.icon`, centered by its ink
(`IconButton` measures it with `Symbol.inkOffset`), and the hover fill shows the whole target. A tick small enough to
need it (a checkbox, a folder's cut-out icon) is the only bolder mark. The sidebar is never narrower than
`Metric.sidebarMinWidth` (216), the room the traffic lights and the four toolbar buttons need; it opens at 240.

The browser window's compact scale (`Tokens.Sidebar`, `Tokens.Pane`):

| Element | Size |
|---|---|
| Toolbar | 14pt glyphs in 26pt buttons (`Sidebar.glyph`, `button`), no fill at rest, a radius-6 hover fill; every glyph's ink on the traffic lights' center line (`Sidebar.lightsCenter`, 22), reload's ink as far from the right edge as the lights from the left |
| Address | 30pt soft field, radius 8, `Chrome.field` and no line, the host at 13pt 10pt in, its buttons 22pt with 13pt glyphs; the accent ring from the keyboard |
| Favorites | 4 to a row, 36pt soft tiles 6pt apart, 18pt icons, radius 8, `Chrome.field`; a fine `Chrome.openEdge` while the page is open, the card while it's the one you're on; the × chip 14pt, 3pt inside the corner |
| Space name | 16 light (`Font.spaceName`), 40pt slot, in the titles' column |
| Rows | 13pt text (`Font.sidebarRow`), 30pt tall, 2pt apart, 16pt favicons; icons at 12pt from the sidebar's edge, titles at 36 |
| Selected row | `Chrome.card` with a 1px `Chrome.cardEdge` and a shadow-sm, radius 6; hover is `Chrome.hover`, pressed `Chrome.pressed` |
| Row buttons | 20pt targets, 11pt glyphs: close, and a speaker beside the half that plays |
| Section labels | 11pt medium, `textTertiary`, in the titles' column, low in a 28pt slot |
| Bottom bar | 14pt icons in 26pt buttons, 6pt space dots, the current one a 14pt pill |
| Pane header (split) | 30pt tall, 13pt glyphs in 24pt buttons, the address at 12pt in a 22pt field |

## Spacing

A 4pt grid (`Space.x1`...`x16`). Rhythm:

- Sidebar: 6pt from its edges (`Sidebar.edge`); rows 30 with 2 between, so rows sit 32pt apart; 6pt from a row's
  edge to its 16pt icon and 8pt from the icon to its title, so one left edge runs down the sidebar: the traffic
  lights and every icon at 12, every title and section label at 36. The address 40pt from the top, the favorites 8pt
  under it, the list 12pt (`Sidebar.sectionGap`) under them.
- Sections are separated by space and a quiet label (`Label.section`, in a `Metric.sectionLabelHeight` slot with the
  label low in it), never by divider lines.
- Panels: 12pt padding (`Space.x3`), 4pt inset for rows inside them so a row's corners run with the panel's.
- Pages: `Tokens.Page` (gutter 28, header 16 + 28 + 12, max width 880). Grouped rows are at least 44 tall with 16pt
  (`groupPad`) from the group's edge and 12pt (`groupRowPad`) above and below their two lines; list rows are 34.
  Narrower than a row's text needs, its control moves under the text instead of squeezing it, and a header's search
  gives way to the title before either is cut.

## Radii

One scale, concentric where things nest (inner = outer minus the gap):

| `Radius.` | pt | For |
|---|---|---|
| `small` | 4 | Tiny marks, thumbnails in rows |
| `control` | 6 | Icon buttons, small controls |
| `field` | 8 | Fields, menu buttons, page card (`card`) |
| `row` | 10 | Rows in panels and menus (the sidebar's are `Sidebar.rowRadius`, 6) |
| `group` | 10 | Grouped rows on a page |
| `tile` | 12 | Glass tiles (favorites are `Sidebar.favoriteRadius`, 8) |
| `panel` | 14 | Floating panels, popovers, menus |
| `large` / `window` | 16 | Big floating surfaces holding rounded things; the window |

Pills (pill buttons, pill fields, the Clear chip) are capsules: radius = height / 2. Corners are always
`.continuous`.

## States

One look for each state, everywhere:

- Rest: nothing (rows), `fieldFill` (fields, plain pills), `Chrome.field` (the sidebar's address and favorites), `glassFill` (glass tiles).
- Hover: on the frame `Chrome.hover` (rows, the toolbar's buttons, the space dots); elsewhere `Color.hoverFill`
  (rows, quiet buttons), `controlHover` (outlined buttons, dropdowns), `glassHover` (tiles), a step lighter on the
  dark primary. Instant, both ways: a fade on something you sweep past all day reads as lag.
- Pressed: a step darker (`pressedFill`, `controlPressed`, `primaryPressed`) at once, and buttons and rows give
  under the finger (`InteractiveView.pressScales`, `showPress`): down to `Motion.pressScale` (0.97) around their
  middle, eased out in `pressIn` (80ms), and a critically damped spring back in `pressOut` (200ms) when let go, from
  wherever they are. No bounce, and the action never waits on it. Not from the keyboard, not with Reduce Motion.
- Selected / current: in the sidebar the light card of the space's color (`Chrome.card`, `cardEdge`, a shadow-sm);
  on a panel a clear neutral fill, `selectedFill`, with a 1px `selectedEdge` and `setLifted(true)`'s shadow-sm
  (`applyRowStyle`). In a list of places
  (Settings' sections) and for a keyboard-chosen result: the accent at `Color.selectionAlpha`.
- Keyboard highlight in a floating list: `Color.highlight`.
- Focus: never the system's blue. A field shows the accent at `focusAlpha` (60%), 1.5pt, while typing. A drawn
  control reached with Tab (Full Keyboard Access) shows a ring in the accent at 60%, `Metric.focusRing` (2pt) wide,
  `Metric.focusGap` (2pt) outside it, following its shape. Only the keyboard brings it; a click never does.
- Pointer: the arrow on every control, as on the Mac; the I-beam in text; the pointing hand only for links in a
  page's text. Hover feedback is the fill, not the cursor.
- Disabled: `Opacity.disabled`.
- Drop target: the accent at 14% with a 1.5pt accent edge; an insertion is a 2pt accent line with round ends. A
  carried item stays faint in place (`CarriedCopy.faint`) while a see-through copy follows the pointer.

## Motion

Quick, eased, no bounce (`Tokens.Motion`). The bar is the craft at animations.dev: every movement says where
something came from, answers at once, and can be interrupted.

- Origin: a menu or popover grows out of what opened it, from `menuFrom` (0.96) with a fade, anchored at that
  control, in `menuIn` (180ms) on the house ease-out (0.23, 1, 0.32, 1). It leaves quicker and subtler: `menuOut`
  (120ms) toward 0.98. Exits are always quieter than entrances.
- The selected tab's card slides: picking another row with the pointer, the card travels there from the row it was
  on (`SelectionCardView`, `Motion.selection`, eased out), and the new row takes it over when it lands. A click
  mid-slide carries on from where the card is. From the keyboard, with Reduce Motion or while dragging, it lands.
- Space color: switching spaces cross-fades the frame; pointing at a preset in the space editor tries it on the
  window at once, and moving off puts back what you have.
- One highlight that moves: in a menu, the soft gray pill glides from row to row (`highlightGlide`, 140ms) instead of
  each row lighting on its own. A list of places (Settings' sections) and a row of filters (`SegmentedPills`) glide
  their selection the same way (`SelectionGlide`). From the keyboard it simply lands.
- Interruptible: every animation starts from what's on screen now (`presentation()`), so opening and closing fast,
  or pressing twice, never queues or jumps.

- Curve: `Motion.easeOut` for anything arriving, leaving or settling; `easeInOut` only for something traveling
  across the screen. Never ease-in, never overshoot.
- Durations: hover and press 0 (instant); `quick` 0.1 for small feedback; `selection` 0.15 for the card moving to a
  new row; `standard` 0.2 for most transitions; panels arrive in 0.18 growing from 97% of their size out of what
  opened them (`FloatingPanelView.present`); `large` 0.3 is the ceiling.
- Anything opened or changed from the keyboard is instant (`Motion.isFromKey`, `isKeyboardDriven`); layout of the
  window (sidebar, splits) still moves so you see where things went.
- Reduce Motion: nothing slides or scales; things fade or simply appear.

## Surfaces

- **Window frame**: the space's color or gradient, its grain, optionally see-through. The sidebar and the gaps
  around the page are the frame.
- **Sidebar**: on the frame, compact (`Tokens.Sidebar`, the table above). Top row: the traffic lights,
  `Sidebar.lightsGap` (12) to the toggle's glyph, then back, forward and reload at the trailing end, every glyph's
  ink centered on the lights' line (`Symbol.inkOffset`), in `Color.chromeIcon`, no fill until the pointer is on it.
  The address: a soft field of the space's color (`Chrome.field`, the host in `textPrimary`, its own small buttons,
  the accent ring from the keyboard). Favorites: small soft tiles four to a row in the same look. The space's name,
  16 light, over its pinned tabs. The tab you're on: the light card of the color, which slides when you pick another. A split row shows both pages, each half with its icon, its title and, while that page
  plays or is muted, its own speaker. A pinned page that has wandered reads "<its name> / <the page it's on>". Then
  the bottom bar: downloads, space dots, +.
- **Pane header** (split view): on the page card, 30 tall: back, forward and reload, the address centered in a small
  field, and the split's own buttons. Everything in it is its own pane's page: its buttons act on it, its loading
  line and reload state follow it, and clicking its address focuses that pane and opens the address bar over it.
- **Page**: the opaque card the web page sits in, `Radius.card`, concentric with the window. Beside the sidebar and
  meeting the window's edges it meets the frame cleanly: all four corners at the window's radius
  (`Radius.attached`), no outline, no shadow.
- **Built-in pages** (History, Settings, Passwords): one plain `Color.surface` (Settings' column of sections in a
  light tint of the space, `Brand.Theme.wash`), `PageTitleView` (wordmark, hairline,
  title) at the top left, `PageHeader` with search and actions at the right, `ListItem` for a column of places,
  quiet rows.
- **Floating panel** (`FloatingPanelView`): opaque, near white by day and a deep gray at night, each leaning just
  perceptibly toward the window's space (`Brand.Theme.panel`), so the panel belongs to it and text always reads.
  Panel radius, a crisp hairline edge, one soft small shadow, 12pt padding, `CardRow`-style rows inset 4pt. It grows
  out of what opened it. Command bar, space editor, icon picker, site panel, find, downloads, previews, Peek, and the
  Control-Tab switcher, which centers on the page beside the sidebar.
- **Space editor** (`SpaceEditorPanel`, `SpaceLookEditor`): the space's name, then one row of curated colors (one tap
  each, a live preview on hover), the wheel and Shade for a color of your own, and Effects folded under a disclosure
  (`DisclosureRow`): a second color and its direction, See-through, Grain. Effects opens by itself when the space
  uses any of them.
- **Menu** (`MenuPanel`): Zigzag draws its own; only right-click menus are the system's. The floating panel's
  surface and its one shadow, `Radius.panel`, a hairline `panelEdge`. `body` items
  `Metric.controlHeight` tall with `Radius.row`, inset 4pt; every item has its picture slot, a neutral globe where a
  site's icon is missing; the chosen item has a check at its trailing end in the window's accent. Keys: Up and Down,
  Home and End, Return or Space to choose, Esc or Tab to close, typing to jump to a name. VoiceOver reads it as a menu
  of menu items and speaks the item the keys reach. A click outside closes it and goes no further. Panels under it
  leave Esc and that click to it (`MenuPanel.current`). The HTML pages' `.menu` matches it.
- **Dropdown** (`DropdownButton`): a choice from a list. The secondary look with `Radius.row` corners, the current
  choice with its picture, and the up-down chevron. Its menu opens with the chosen item right over the button and
  its text lined up with the button's, as macOS places it; below the button when there's no room, scrolled when the
  list is taller than the window. Press and drag to an item to choose in one movement. With the keyboard, Space,
  Return, Up or Down opens it. VoiceOver: a pop-up button whose value is the choice.
- **Card**: the chosen thing in a list (`applyRowStyle`, `GlassTile` when selected).
- **Row** (`CardRow`): icon, title, quiet trailing detail; states above.
- **Tile** (`GlassTile`): soft glass, `Radius.tile`; a fine darker edge (`openEdge`) when its page is open.
- **Pill button** (`PillButton`): capsule, `.plain` on `fieldFill`, `.quiet` fill on hover only, `.prominent` in
  the accent, one per surface; `isDestructive` for what can't be undone. `PrimaryButton` and `TextButton` remain
  in Settings and a few panels until rebuilt.
- **Dialog** (`Tokens.Dialog`): `DialogHeader` (a picture, the question in the heading's weight, a quiet line under
  it), the explaining text, then `DialogButtons` (the answers at the trailing end, the main one last and filled; a
  quiet choice alone at the leading end). Confirmations, page dialogs, extension and save-password prompts use it.
- **Buttons** (`ButtonLook`, `applyButtonLook`), capsules `Metric.controlHeight` (28) tall, `Font.control()`:
  - Secondary (`PillButton` `.plain`, `TextButton.form`): `controlFill` (white; a lighter step of the surface in
    dark mode), a hairline `controlEdge` and a faint `controlShadow` (1.5pt, 0.5 down). A symbol may lead the title.
  - Primary (`PillButton` `.prominent`, `PrimaryButton`): the one thing to do on a surface, a dark filled pill
    (`primaryFill`, light in dark mode) with `onPrimary` text, whatever the space; red only for what can't be undone.
  - Quiet (`.quiet`): no fill until the pointer is over it.
  `PrimaryButton` and `TextButton` draw the same looks for the forms that still use them; new code uses `PillButton`.
- **Switch** (`Toggle`): 36 by 22, a white 18pt knob with a soft shadow. On is the window's accent: one accent per
  window, solved for contrast against white for every space's hue, so on reads at a glance and the switch agrees
  with focus and selection; a green would be a second hue competing with the space's. Off is a plain gray track
  (`toggleOff`), so the two never look alike. The knob settles in 200ms on a critically damped spring and stretches
  4pt while held; the track's color fades over the same time. Reduce Motion: the knob jumps, the color fades.
- **Field** (`FilledField`): soft fill, accent ring while typing; `.isPill` for a field on its own in a panel;
  `.isOutlined` for the page look, white with a hairline and a faint shadow like the buttons beside it, which a
  page's header gives its search; `FilledField.search` with the magnifying glass.

## Materials

For brand moments (onboarding, Import, About) only, never for the browser's everyday chrome, which stays plain and
calm: things drawn as objects under one light straight above. `Materials.swift` holds them; every value is in `Tokens.Material`.

- **Light**: highlights on top edges, shadows straight down, tinted with the navy (`Material.shadowInk`), deeper in
  dark mode (`darkShadowGain`). Every lifted thing has two shadows, a tight contact one and a soft ambient one
  (`CastShadow`, from a path, so they cost nothing to move).
- **`SkyBackdrop`**: the world they stand in. Zigzag's own colors as a sky (pale ribbon blue by day, deep navy by
  night), a few soft drifting fields (`Atmosphere`), grain, and a pool of light from above. `tint` leans it toward
  the space in front. Never stock gradients.
- **`GlassSurface`**: the one panel. Liquid Glass (frost before macOS 26) under a wash brighter at the top, a glow
  inside the edge, a specular rim on the top edge with a faint catch light on the bottom, grain, and a hot spot that
  leans toward `light` (the pointer). `Radius`: `Material.heroRadius`. One per screen; nothing nests in it but
  controls.
- **`RaisedTile`** (and `RaisedTileLayers` for a 3D scene): the app-icon object. Continuous corners at
  `tileCorner` of its side, a porcelain or colored body, a bevel (light top edge, darker bottom one), a hairline, a
  hot spot that slides toward the pointer. A site's own square icon fills the face (`fillsFace`). Hover lifts it
  `tileLift` and grows its shadow; it turns up to `Material.tilt` degrees toward the pointer.
- **`TactileButton`**: a capsule `controlHeight` tall, or `largeControlHeight` with `largeText` for a brand
  moment's one big action. `.primary` is glossy in the deep accent (in dark mode too) with white text and a shadow
  of its own color, one per surface; `.secondary` is porcelain; `.link` is words in the accent, underlined under the
  pointer, for the quieter way on under a primary. Hover rises `lift`; pressed it sinks `sink`, shrinks to
  `pressScale`, its gradient turns over and its shadow tightens.
- **`TactileToggle`**: a glassy knob on its own shadows in a recessed track; the accent fills the track when on.
  With a title, the whole row is the control. Pressed, the knob stretches toward where it's going.
- **`RecessedField`**: set into the surface: darker under the top lip, an inner shadow, the lower lip catching
  light. Typing, the accent rings it with a soft glow.
- **`EmbossedWordmark`**: the drawn ZIGZAG as an object: solid navy with a fine top light by day, the ribbon's
  pale blue, beveled, by night; a glint follows the pointer only while it's over the mark.
- **A brand moment's words**: the wordmark, one headline (`Material.headline`, semibold) saying plainly what Zigzag
  is, one quiet line (`largeText`, `textSecondary`), then the one big action.
- **Recipes**: `MaterialShape.rounded` (continuous corners as a path), `GradientStroke` (rims, bevels, lips),
  `InnerShadow` (recesses), `MaterialMotion` (the ease-out, poses, tilt), `OcclusionPause`.

Motion: the material ease-out (`Motion.easeOut`), no bounce, interruptible (each change starts where the last got
to). A material object's hover moves (`settle`, 0.2) rather than appearing at once, because a thing is moving, not a
fill changing; pressing in is quicker (`pressIn`). Turning toward the pointer is slower (`follow`), for weight.
From the keyboard everything is instant; with Reduce Motion nothing drifts, tilts or lifts. Drift pauses while the
window is out of sight. Text stays on the wash or a solid surface, at AA contrast; effects never sit under it.

## Words

US English. No em dashes, no "A · B · C" lines, no filler. Labels say what a thing is; nothing explains itself.
