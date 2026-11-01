# Zigzag's design language

Glassy, deft, calm and confident: a Mac app in the spirit of Apple's own on macOS 26, Aside, Craft and Linear, that
is still unmistakably Zigzag (space colors and gradients, the see-through frame, the drawn ZIGZAG wordmark, the
sidebar that carries back, forward, reload and the address).

Every value lives in `Tokens.swift`. Every shared part lives in `Components.swift`, `Controls.swift` and
`Page.swift`. A view never invents a color, radius, shadow, size or duration; if the system lacks one, add it to
Tokens with a line saying what it's for, and use it everywhere it applies. Rebuild a view to the system rather than
tuning its old numbers, and delete one-off styling instead of keeping it beside the new.

## Layers and depth

Four layers, front to back. Each has one material and one depth cue; nothing else casts a shadow.

| Layer | What | Material | Depth |
|---|---|---|---|
| 0. Frame | The window behind everything: the space's color, gradient, grain, or the desktop through it | Space color (`SpaceColor`), clear glass when see-through | None |
| 1. Surfaces | The page card; Settings, History, Passwords pages | Opaque `Color.surface` | `Color.cardShadow`, barely there |
| 2. Cards | The selected row, a selected tile, grouped rows on a page | `Color.selectedFill` / `surfaceGroup` | Hairline `selectedEdge` and `liftShadow` (`setLifted`) |
| 3. Floating | Panels, popovers, menus, the command bar, previews, toasts | Liquid Glass (`.regular`) on macOS 26, `.popover` frost before, under `Color.panelWash` | Hairline `panelEdge` and the one panel shadow (`Shadow.panelRadius`, `panelDrop`) |

The sidebar has no surface of its own: it is the frame. What sits on it is either quiet (rows at rest, labels) or
soft glass (favorite tiles, `Color.glassFill` with a light `glassEdge`).

Glass is only for floating things. Never on the window background (see-through spaces handle that) and never under
long reading text without the wash.

## Type

SF Pro, one weight per role. Secondary text is light gray and never bold; selection never changes weight.

| Role | Token | Size, weight | Color |
|---|---|---|---|
| Section label ("Tabs", the space name, a panel's group) | `Font.label()` | 12 medium | `textTertiary` |
| Small print, captions, counts | `Font.small()` | 11 regular | `textSecondary` / `textTertiary` |
| Body: panels, forms, page rows | `Font.body()` | 13 regular | `textPrimary` |
| Sidebar rows and address | `Font.row()` | 14 regular | `textPrimary` |
| A panel's title | `Font.heading()` | 15 semibold | `textPrimary` |
| What a button or dropdown says | `Font.control()` | 14 medium | `textPrimary` |
| Large | `Font.large()` | 18 | |
| Display (one line per window) | `Brand.display`, `TypeSize.title` | 22 heavy | |

Pages (Settings, History, Passwords) read a size up from panels, for a friendlier feel:

| Role on a page | Token | Size, weight | Color |
|---|---|---|---|
| The page's title in its header | `Font.pageTitle()` | 17 semibold | `textPrimary` |
| A row's title in a group | `Font.pageRow()` | 15 medium | `textPrimary` |
| The column of sections, a menu's items, History's titles | `Font.pageRow(.regular)` | 15 regular | `textPrimary` |
| A row's explanation | `Font.pageDetail()` | 13 regular | `textSecondary` |
| A group's heading (`Label.groupHeading`) | `Font.pageLabel()` | 13 medium | `textTertiary` |

Symbols are regular weight (`Symbol.weight`), monochrome outlines, sized to the text beside them, tinted `Color.icon`.

## Spacing

A 4pt grid (`Space.x1`...`x16`). Rhythm:

- Sidebar: 8pt from its edges; rows `Metric.rowHeight` (34) with `Metric.rowGap` (2), so rows sit 36pt apart; 10pt
  (`CardRow.inset`) from a row's edge to its icon and from the icon to its title; 16pt (`Metric.sectionGap`)
  between groups.
- Sections are separated by space and a quiet label (`Label.section`, in a `Metric.sectionLabelHeight` slot with the
  label low in it), never by divider lines.
- Panels: 12pt padding (`Space.x3`), 4pt inset for rows inside them so a row's corners run with the panel's.
- Pages: `Tokens.Page` (gutter 28, header 16 + 32 + 12, max width 880). Grouped rows are at least 56 tall with 20pt
  (`groupPad`) from the group's edge and 16pt (`groupRowPad`) above and below their two lines; list rows are 38.
  Narrower than a row's text needs, its control moves under the text instead of squeezing it, and a header's search
  gives way to the title before either is cut.

## Radii

One scale, concentric where things nest (inner = outer minus the gap):

| `Radius.` | pt | For |
|---|---|---|
| `small` | 4 | Tiny marks, thumbnails in rows |
| `control` | 6 | Icon buttons, small controls |
| `field` | 8 | Fields, menu buttons, page card (`card`) |
| `row` | 10 | Rows in the sidebar and in panels and menus |
| `group` | 10 | Grouped rows on a page |
| `tile` | 12 | Favorite tiles, glass tiles |
| `panel` | 14 | Floating panels, popovers, menus |
| `large` / `window` | 16 | Big floating surfaces holding rounded things; the window |

Pills (pill buttons, pill fields, the Clear chip) are capsules: radius = height / 2. Corners are always
`.continuous`.

## States

One look for each state, everywhere:

- Rest: nothing (rows), `fieldFill` (fields, plain pills), `glassFill` (tiles).
- Hover: `Color.hoverFill` (rows, quiet buttons), `controlHover` (outlined buttons, dropdowns), `glassHover` (tiles),
  a step lighter on the dark primary. Instant, both ways: a fade on something you sweep past all day reads as lag.
- Pressed: a step darker (`pressedFill`, `controlPressed`, `primaryPressed`) at once, and buttons and rows give
  under the finger (`InteractiveView.pressScales`, `showPress`): down to `Motion.pressScale` (0.97) around their
  middle, eased out in `pressIn` (80ms), and a critically damped spring back in `pressOut` (200ms) when let go, from
  wherever they are. No bounce, and the action never waits on it. Not from the keyboard, not with Reduce Motion.
- Selected / current: the soft card, `selectedFill` + `setLifted(true)` (`applyRowStyle`). In a list of places
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
- **Sidebar**: on the frame. Top row: traffic lights, sidebar toggle, back, forward, reload (light, regular-weight
  symbols). The address: a quiet pill (`Color.addressFill`, 14pt text). Favorites: glass tiles. Then the space name
  as a quiet section label, pinned rows, the "Tabs" label with Clear, New Tab, tabs. The bottom bar: downloads,
  space dots, +.
- **Page**: the opaque card the web page sits in, `Radius.card`, concentric with the window.
- **Built-in pages** (History, Settings, Passwords): one plain `Color.surface`, `PageTitleView` (wordmark, hairline,
  title) at the top left, `PageHeader` with search and actions at the right, `ListItem` for a column of places,
  quiet rows.
- **Floating panel** (`FloatingPanelView`): glass, panel radius, panel shadow, hairline edge, 12pt padding,
  `CardRow`-style rows inset 4pt. Command bar, space editor, icon picker, site panel, downloads, previews, peek.
- **Menu** (`MenuPanel`): Zigzag draws its own; only right-click menus are the system's. A solid panel
  (`panelBackground`, white in light mode), `Radius.panel`, a hairline `panelEdge`, a lit top rim (`topHighlight`),
  and depth in two layers: a tight contact shadow (`contactShadow`, 1.5pt) under the wide panel shadow. 15pt items
  `Page.controlHeight` tall with `Radius.row`, inset 4pt; every item has its picture slot, a neutral globe where a
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
- **Buttons** (`ButtonLook`, `applyButtonLook`), capsules `Page.controlHeight` (32) tall, `Font.control()`:
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

## Words

US English. No em dashes, no "A · B · C" lines, no filler. Labels say what a thing is; nothing explains itself.
