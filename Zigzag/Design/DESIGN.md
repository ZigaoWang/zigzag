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
| A page's or panel's title | `Font.heading()` | 15 semibold | `textPrimary` |
| Large | `Font.large()` | 18 | |
| Display (one line per window) | `Brand.display`, `TypeSize.title` | 22 heavy | |

Symbols are regular weight (`Symbol.weight`), sized to the text beside them, tinted `Color.icon`.

## Spacing

A 4pt grid (`Space.x1`...`x16`). Rhythm:

- Sidebar: 8pt from its edges; rows `Metric.rowHeight` (34) with `Metric.rowGap` (2), so rows sit 36pt apart; 10pt
  (`CardRow.inset`) from a row's edge to its icon and from the icon to its title; 16pt (`Metric.sectionGap`)
  between groups.
- Sections are separated by space and a quiet label (`Label.section`, in a `Metric.sectionLabelHeight` slot with the
  label low in it), never by divider lines.
- Panels: 12pt padding (`Space.x3`), 4pt inset for rows inside them so a row's corners run with the panel's.
- Pages: `Tokens.Page` (gutter 28, header 16 + 28 + 12, max width 880).

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
- Hover: `Color.hoverFill` (rows, buttons), `glassHover` (tiles), `highlight` on filled controls. Instant, both ways.
- Pressed: `Color.pressedFill`. Instant.
- Selected / current: the soft card, `selectedFill` + `setLifted(true)` (`applyRowStyle`). In a list of places
  (Settings' sections) and for a keyboard-chosen result: the accent at `Color.selectionAlpha`.
- Keyboard highlight in a floating list: `Color.highlight`.
- Focus: the field's ring in the accent at 60%, 1.5pt; drawn focus rings for keyboard access stay on.
- Disabled: `Opacity.disabled`.
- Drop target: the accent at 14% with a 1.5pt accent edge; an insertion is a 2pt accent line with round ends. A
  carried item stays faint in place (`CarriedCopy.faint`) while a see-through copy follows the pointer.

## Motion

Quick, eased, no bounce (`Tokens.Motion`).

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
- **Popover / menu**: a floating panel, small: rows `Page.controlHeight` tall with `Radius.row`, `highlight` on
  hover. The HTML pages' `.menu` uses the same values (`--radius-float`, `--radius-row`).
- **Card**: the chosen thing in a list (`applyRowStyle`, `GlassTile` when selected).
- **Row** (`CardRow`): icon, title, quiet trailing detail; states above.
- **Tile** (`GlassTile`): soft glass, `Radius.tile`; a fine darker edge (`openEdge`) when its page is open.
- **Pill button** (`PillButton`): capsule, `.plain` on `fieldFill`, `.quiet` fill on hover only, `.prominent` in
  the accent, one per surface; `isDestructive` for what can't be undone. `PrimaryButton` and `TextButton` remain
  in Settings and a few panels until rebuilt.
- **Dialog** (`Tokens.Dialog`): `DialogHeader` (a picture, the question in the heading's weight, a quiet line under
  it), the explaining text, then `DialogButtons` (the answers at the trailing end, the main one last and filled; a
  quiet choice alone at the leading end). Confirmations, page dialogs, extension and save-password prompts use it.
- **Field** (`FilledField`): soft fill, accent ring while typing; `.isPill` for a field on its own in a panel;
  `FilledField.search` with the magnifying glass.

## Words

US English. No em dashes, no "A · B · C" lines, no filler. Labels say what a thing is; nothing explains itself.
