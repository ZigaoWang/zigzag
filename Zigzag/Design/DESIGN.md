# Zigzag's design language

Thin, calm and warm: each space is a soft color of its own, and the whole window wears it. The chrome on top is
light: thin icons, light type with a clear hierarchy, no boxes, lines only where they structure something, and every
fill a wash of the space's own color, so a space feels like yours rather than a gray template. Motion is short,
eased out, never bouncy, and gets out of the way. The references are Arc's color per space without its complexity,
Aside's polish, and the interaction craft of animations.dev. Still unmistakably Zigzag: the ribbon Z and the drawn
ZIGZAG wordmark exactly as they are, the see-through frame, the sidebar that carries back, forward, reload and the
address.

## Character

Arc's warmth and a color per space, set with the care of a good piece of hardware: light words with a
confident jump in size, thin precise line drawings, a few small details that each do something, and controls you want
to touch. Warm and friendly, never techy: no monospace, no capitals for effect, no readouts.

- **Typeface: SF Pro, tuned.** Zigzag keeps the system face on purpose: it renders natively at every size, covers every
  script a page title can be in, and its display cut is the Univers-like grotesque this direction wants. What makes it
  ours is how it's set: light weights, one large display size against small text, display type tracked tight
  (`Font.voiceKern`), and tabular figures where numbers mark something (`Font.figures`).
- **Case, decided once.** Every word Zigzag says is in its normal case, titles included: "History", "Downloads",
  buttons, labels, menu items, tooltips ("New Tab", "Clear", "Close Duplicates"). No lowercase styling. Content keeps
  its own case: a page's title, a site's name, what you typed.
- **Confident contrast.** Rows at 13pt and labels at 11pt, nothing in between; the space's name is the one heading
  over them, a semibold step at the rows' size, or 26 light where it's set large.
- **Line drawings** (`LineGlyph`): where a stock symbol says too little, Zigzag draws its own on a 16pt square with
  one 1.1pt stroke, round caps and joins, 1.5pt margins: the sidebar toggle, the plus for new tab and new space,
  downloads (its circle shares the stroke, so the progress ring lies on it). Every other symbol is SF's light weight.
- **No extra accent color.** What's on or chosen takes the space's own accent (`Brand.Theme.accent`); there is no
  separate warm or orange accent anywhere.
- **Small details that work:** the space dots, the one you're in stretched into a short pill; the selected card's top edge catching the light by one pixel at night (`Chrome.rim`, `setCardRim`; by day the card is too near white for a lit edge to read at 1x, so it has none); a
  hairline under the toolbar only while the list is scrolled under it.
- **Scroll edge in the sidebar** (`Color.separator`, 12pt in from each side): a hairline on the list's top edge only
  while it's scrolled. Tabs running on under the bottom bar fade out instead of meeting a line. Nothing divides the
  favorites from the list; the space between them does.
- **Edges.** The sidebar has three, and everything sits on one of them: the container edge (6pt: the address field,
  the favorites, the cards), the icon column (12pt: the traffic lights, the address's host, every icon, the
  "Tabs" label, and the space's name, whose ink is pulled back by its side bearing to meet it), and the text column
  (36pt: every row's title, "New Tab"). The large name stands on the outer edge as a heading, a full 24pt out from the rows'
  text, not a near miss. No state moves anything: hover, selection, the sliding card and switching spaces change
  fills and color only.

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
- **Ink**: on the frame, row titles and quiet words take the space's own ink (`Theme.rowInk`, `quietInk`), a deep or
  pale tone of its hue, checked against every curated color under the hover and card washes: titles at least 11.7:1
  by day and 7.5:1 at night, quiet words 5.2:1 and 4.8:1. Each space's inks are checked against its own frame (both
  ends of a gradient, bare and under the washes) in each mode, and only a mode that would miss AA falls back to the
  plain near-black or near-white. See-through frames, over a desktop no one can know, always take the plain ones.
- **Switching spaces** cross-fades the frame's color, gradient and grain together (`Motion.large`, eased out); from the keyboard too, since the
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
| 1. Surfaces | The page card; Settings, History, Passwords pages | Opaque `Color.surface`; Settings' and Passwords' column of places a light tint of their window's space (`Theme.wash`); History has no column and stays plain | `Color.cardShadow`, barely there |
| 2. Cards | The selected tab, a selected favorite; grouped rows and chosen rows on pages and panels | On the frame `Chrome.card`; elsewhere `Color.selectedFill` / `surfaceGroup` | A quiet edge and a shadow-sm (`Chrome.cardEdge`, `cardShadow`; `setLifted`) |
| 3. Floating | Panels, popovers, menus, the command bar, find, downloads, Peek, the switcher | Opaque, leaning toward the space (`Brand.Theme.panel`) | Hairline `panelEdge` and one soft small shadow (`Shadow.panelRadius` 16, `panelDrop` 3) |

The sidebar has no surface of its own: it is the frame, in the space's full color. What sits on it is quiet (rows at
rest, labels) or a soft wash of that color: the address and the favorites are soft fields (`Chrome.field`) with no
line around them; the tab you're on is a light card of the color (`Chrome.card`, white at 96% by day, 18% at night)
with an edge only just there and a shadow-sm, seen at a glance on any color. Hover is a gentler wash (`Chrome.hover`).
No bevels, no puffy shadows, no boxes.

No glass gimmicks: in the browser, see-through spaces frost the desktop under the frame, and the sidebar that slides out over the page is glass, the page blurred under the space's color at 88% by day and 90% at night (`Frame.floatingCover`), see-through spaces too, so it's the same color slid out as shown; Liquid Glass where the Mac has it, tinted as the window's own glass is, or the frosting when the space chose it. Those are the only blurs (brand moments keep their `GlassSurface`, under Materials). With Reduce Transparency, or Low Power Mode, the sliding sidebar is the space's solid color.

## Size scale

One scale for pages and panels, in `Tokens`: the same role is the same size everywhere on them. Pages read calm,
Mac-like. The browser window's chrome (the sidebar and a split pane's header) is a compact scale of its own,
`Tokens.Sidebar` and `Tokens.Pane`, in the table after these. Nothing else picks a size.

SF Pro, one weight per role. Secondary text is light gray and never bold; selection never changes weight. The
space's name in the sidebar is the one heading there, in the case you typed it and the space's own ink
(`Brand.Theme.ink`): 13 semibold in a row's 30pt slot (`SpaceHeaderView.nameFont`), the start for a new install, a plain
heading anyone coming from Arc reads at a glance; or, with Large space names (Settings › Appearance, or the name's
right-click), 26 light, tracked tight (`Font.spaceName`), low in a 36pt slot. Someone who used Zigzag before small
became the start keeps the large names they had (`settleSpaceNameStyle`).

| Text | Token | Size, weight | For |
|---|---|---|---|
| label | `Font.label()` | 12 medium, `textTertiary` | A section's label ("Tabs", the space name), a group's heading on a page |
| | `Font.detail()` | 12 regular, `textSecondary` | A row's explanation under its title |
| small | `Font.small()` | 11 | Small print, captions, counts, keycaps |
| body | `Font.body()`, `Font.control()` | 13 regular | Panels, forms, menus; what a button or dropdown says |
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
| Address | 30pt soft field, radius 8, `Chrome.field` and no line, the host at 13pt 10pt in, its buttons 26pt with 14pt glyphs; up to 3 pinned extensions before Site Controls, dragged to reorder as the space icons are (the pin stays faint in its place, a see-through copy follows the pointer, a 2pt accent line marks the gap), hiding from the left before the host or the prompt is cut (and never below 72pt for it), each pin the same 26pt button as Reader and Site Controls with the extension's icon at 16pt in the middle, 2pt between every button; a count is a 12pt dark pill with 9pt semibold white figures in the button's bottom-right corner, 1pt inside it (the same pill, 3pt in, on a Site Controls tile); in Site Controls a 16pt round pin button (control fill, hairline, 9pt glyph, 20pt target) 2pt inside the tile's top-right corner, the top-left when the tile has a count: always there and filled (pin.fill) while pinned, an outline pin on hover otherwise, dimmed at the limit, and Pin to Address in the tile's menu; the accent ring from the keyboard |
| Favorites | As many to a row as fit 56pt wide (3 at the usual width), or 2, 3 or 4 as chosen in Settings; 36pt soft tiles 6pt apart, 18pt icons, radius 8, `Chrome.field`; a fine `Chrome.openEdge` while the page is loaded (not while it sleeps or waits since a relaunch), the card while it's the one you're on; the × chip 14pt, 3pt inside the corner |
| Space name | As typed, its ink on the icon column: 13 semibold in a 30pt slot; large, 26 light (`Font.spaceName`), kern -0.6, 36pt slot |
| Rows | 13pt text (`Font.sidebarRow`), 30pt tall, 2pt apart, 16pt favicons; icons at 12pt from the sidebar's edge, titles at 36; a pinned page that's open has a fine `Chrome.openEdge`, as a favorite does, only while its page is loaded. A tab whose page isn't running looks the same however it got there (put to sleep, or not loaded yet since Zigzag reopened, #205): in the Tabs list, a split's parts, the ⌃Tab switcher and Show All Tabs, the sleeping ring (a hairline of even dashes in `textTertiary`, 1.5pt out, the icon at 85% inside it); a pinned page or favorite that isn't running has no edge and no ring, as one never opened. Its hover card, or a favorite's tooltip, says why: asleep, and what that freed, or not loaded since Zigzag reopened |
| Selected row | `Chrome.card` with a 1px `Chrome.cardEdge` and a shadow-sm, radius 6; hover is `Chrome.hover`, pressed `Chrome.pressed` |
| Row buttons | 20pt targets, 11pt glyphs: close, and a speaker beside the half that plays |
| Developer Mode | A tab on a site in Developer Mode (#141) is marked on its icon, as a sleeping one is: a round chip on the favicon's bottom-trailing corner, half the icon's side (`Sidebar.developerBadgeShare`), reaching 30% of its own side past the corner, the mode's hammer knocked out of it (`developerGlyphShare`) so the ground shows through, and the icon, its sleeping ring and its globe cut away round it by `developerBadgeGap` (1pt), as a status on an avatar. In the space's accent (`Theme.badge`), the row's ink where the accent would fall under 3:1 on the frame or on a see-through one, whose ground can't be known; never a fixed color, so it reads on every space. The row keeps its height, its one line, its card and its edges; at rest, under the pointer and selected alike, beside the ring, the loader and the speaker. Each part of a split in it has its own chip, and a favorite's icon has it too. Pointing at the icon says "Developer Mode" and the host with its port, and the hover card says "Developer Mode" under the address; VoiceOver says it after the name |
| Section labels | 11pt medium, the space's quiet ink, on the icon column, low in a 24pt slot; Clear at its end in the same ink |
| Bottom bar | 14pt glyphs in 26pt buttons; a space dot for each space (`SpaceDotView`) in a 26pt target: a 6pt dot in the space's ink at rest, the one you're in stretched into a 16pt pill in full ink, eased over `standard`; a space with an icon shows it at 14pt in place of its dot, brightest when it's yours. No numbers: the tooltip names the space and its ⌃ key, and holding ⌃ shows the numbers just above |
| Pane header (split) | 30pt tall, 13pt glyphs in 24pt buttons, the address at 12pt in a 22pt field; narrow, swap and the layout fold into ⋯ first, then Separate, Forward and Reload, so the address keeps 72pt (`Pane.addressMinWidth`) and × is never cut |
| Peek's strip | The pane header's scale: 30pt tall (`Metric.peekHeaderHeight`), 13pt glyphs in 24pt buttons, the host at 12pt after a 16pt favicon placed as a button's would be; the page 2pt inside the panel's rim at the sides and below (`Metric.peekInset`), its corners concentric. Once the page has a color, the panel and strip take it, the ink light or dark by contrast, as a pane's strip does (`PeekHeaderView.ground`). Pages keep WebKit's own scrollbars, as in Safari: overlay or always shown as the Mac is set, in the page's own light or dark |

## Spacing

A 4pt grid (`Space.x1`...`x16`). Rhythm:

- Sidebar: 6pt from its edges (`Sidebar.edge`); rows 30 with 2 between, so rows sit 32pt apart; 6pt from a row's
  edge to its 16pt icon and 8pt from the icon to its title, so one left edge runs down the sidebar: the traffic
  lights, every icon and the "Tabs" label at 12, every title at 36. The address 40pt from the top, the favorites 8pt
  under it, the list 12pt (`Sidebar.sectionGap`) under them.
- Sections are separated by space and a quiet label, low in its slot (`Metric.sectionLabelHeight`, 32, on pages and
  panels; `Sidebar.labelHeight`, 24, in the sidebar's compact scale), not by divider lines; the sidebar's scroll edges
  are the only ones.
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
  primary. Instant both ways, in and out: a fade on something you sweep past all day reads as lag.
- Pressed: a step darker (`pressedFill`, `controlPressed`, `primaryPressed`, `Chrome.pressed` on the frame) at
  once; the address and the favorites step back from their hover to `Chrome.fieldPressed`, never below the field at
  rest. Things that read as objects (space dots, pill buttons, favorites) sink (`pressSinks`, `showSink`): down
  `Motion.pressSink` (1pt) in `pressIn` (100ms), eased out, and back over `pressSettle` (120ms), eased out, with
  no bounce. Rows and small icon buttons give instead (`pressScales`, `showPress`): to
  `Motion.pressScale` (0.97) and back the same way. Both start from wherever they are, and the action
  never waits on them. Not from the keyboard, not with Reduce Motion. The switch's knob travels its short way in
  `Motion.state`, eased out, with its track's color.
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
- Increase Contrast (the Mac's, `Tokens.Contrast`): hairlines, edges, separators, quiet text, icons, the chrome's
  fills and the controls' borders take their stronger versions (`Color.dynamic(light:dark:highLight:highDark:)`),
  quiet and tertiary text at AA or better on every surface and frame; every window draws again when it changes.
  With it or Reduce Transparency, floating panels are opaque. Debug builds force it with ZIGZAG_HIGH_CONTRAST=1 or
  `contrast on|off|system`.
- Drop target: the accent at 14% with a 1.5pt accent edge; an insertion is a 2pt accent line with round ends. A
  carried item stays faint in place (`CarriedCopy.faint`) while a see-through copy follows the pointer.

## Motion

Quick, eased, no bounce (`Tokens.Motion`). The bar is the craft at animations.dev: every movement says where
something came from, answers at once, and can be interrupted.

Every animation plays one of five roles (`Motion.Role`), and takes its duration and curve from it, never from a
number of its own (`scripts/check-motion.sh` fails on one):

- **Feedback** (`.feedback`): hover hints and a press, `feedbackIn` 100ms down, `feedbackOut` 120ms back, eased out.
- **State** (`.state`): a small change in place, a toggle, a row's selection, a chip fading in, `state` 160ms, eased out.
- **Present** (`.present`): a panel, popover, menu or sheet showing up in `enter` 180ms, growing a little and fading,
  and going in `exit` 120ms, eased out.
- **Drawer** (`.drawer`): the sidebar sliding, a notice from beyond the window's edge, and the layout making room,
  `drawerIn` 260ms out, `drawerOut` 200ms back (and for a move with no way in or out), on `Motion.drawer`.
- **Large** (`.large`): switching spaces, the Desk, the whole window changing, `large` 280ms, on `Motion.drawer`.
- **Reduce Motion**: feedback is instant, every other role only crossfades in place in `crossfade` 120ms.

Two curves, one family: `Motion.easeOut` (0.23, 1, 0.32, 1) for what answers or appears, and for every fade and
color change; `Motion.drawer` (0.32, 0.72, 0, 1) for what travels. Outside the roles: the download's flight and
progress ring, the page's loading line (`progressCreep`), and ambient brand motion (`Motion.Ambient`).

The rules behind them, from animations.dev, Emil Kowalski's writing and Apple's HIG:

- Ease out for anything entering or answering, never ease in: it starts slow, right when you're looking.
- Custom curves, not the system's ease: the built-in ones are too weak.
- Under 300ms: `large` is the ceiling, and most things are shorter.
- Exits are quicker than entrances.
- Animate from where it came from: a popover grows out of its control, never from its middle or from nothing.
- What you do many times an hour, from the keyboard most of all, is instant or nearly so.
- Springs only for what the fingers threw (a swipe let go mid-move), so it carries on at their speed.
- Interruptible: a new change starts from what's on screen now, never jumps.
- Reduce Motion is respected everywhere, with a crossfade or nothing.

- Showing up and going: one vocabulary, `Motion.present(_:from:entering:)`, and `FloatingPanelView.present` and
  `dismiss` on it. Where a thing lives decides where it comes from (`Motion.Origin`):
  - `.point`: a menu, popover or panel grows out of the control that opened it (`growsFrom`), from `enterScale`
    (0.96) with a fade, in `enter` (180ms) on the house ease-out (0.23, 1, 0.32, 1). A sheet grows from a little
    below its middle (`sheetOrigin`), its scrim fading in `enter` and out in `exit`.
  - `.edge`: a bar that hangs from an edge slides `edgeOffset` (6pt) in from it: the find bar (⌘F) and a toast
    from the page's top, the Desk's and a PDF's bars from the bottom.
  - `.offstage`: a notice from outside (a site's question, Save password?, an offer) comes down from beyond the
    window's top edge in `noticeIn` (260ms) on the drawer curve and goes back up in `noticeOut` (200ms).
  - `.inPlace`: what stands in for something under it (the address being edited) only fades.
  Leaving is quicker and subtler, two thirds to three quarters: `exit` (120ms) toward 0.98, or half the edge offset.
  The fade runs a touch quicker than the movement coming in, so it's solid before it settles.
- The selected tab's card slides: picking another row with the pointer, the card travels there from the row it was
  on (`SelectionCardView`, `Motion.selection`, eased out), and the new row takes it over when it lands. A click
  mid-slide carries on from where the card is. From the keyboard, with Reduce Motion or while dragging, it lands.
- Space color: switching spaces cross-fades the frame, its color, gradient, grain and mode in one `large` fade; pointing at a preset in the space editor tries it on the
  window at once, and moving off puts back what you have.
- One highlight that moves: in a menu, the soft gray pill glides from row to row (`highlightGlide`, the state role) instead of
  each row lighting on its own. A list of places (Settings' sections) glides its selection the same way
  (`SelectionGlide`). From the keyboard it simply lands.
- Interruptible: every animation starts from what's on screen now (`presentation()`), so opening and closing fast,
  or pressing twice, never queues or jumps. Turned around partway, it takes only the time left
  (`Motion.remainingDuration`): ⌘F pressed twice fast lifts the bar a little and brings it straight back.

- Hover itself is instant both ways: a fade on something you sweep past all day reads as lag.
- Keys: a panel shows up and goes the same way whether a key or the pointer asked (⌘F, Esc, a menu), because the
  movement says where it is. What you summon to type in or flick through many times an hour is simply there and
  simply gone: the command bar (⌘T, ⌘L), the tab and space switchers (⌃Tab), the link under the pointer, and anything
  shown while ⌘T is handled (`Arrival.instant`, `Motion.isKeyboardDriven`). Typing, moving through a list with the
  arrows, and switching tabs never animate; the find bar following its tab comes and goes with the page, at once.
  Changes made with `Motion.animate` (layout, hovers, lists) are still instant from a key, except the window's
  layout (the sidebar, splits, switching spaces), which moves so you see where things went (`evenFromKeyboard`).
- Light and dark cross-fade with the space's color when a space changes the window's mode: one fade, no flicker.
- A closed tab's row folds away: it takes no more clicks, and its height closes as it fades, in step with the rows
  below gliding up.
- Reduce Motion (the Mac's, or Settings › Appearance › Reduce motion for Zigzag alone): nothing slides, scales or
  travels; fades and color changes still play (`Motion.animate(moves:)`), anything showing up or going crossfades
  in place in `crossfade` (120ms), and a space switch cross-fades the list in place instead of sliding it.
- Arrivals and departures in lists: a new tab's row opens its height from nothing as it fades in; a closed one folds
  away. Favorites keep their tiles by id and glide to new places; a new one fades in, a removed one fades out.
  A favicon that swaps for another cross-fades (`state`). A split opens at `standard`, a closed pane fades where it
  was as the other grows over it, and double-clicking the divider glides the panes back to even.
- The sidebar, docked or hidden at the window's edge, comes out in `drawerIn` (260ms) and goes back in `drawerOut`
  (200ms) on `Motion.drawer` (0.32, 0.72, 0, 1), the page and the bar with it: eased out, but it starts at about twice its average speed, not four
  times, so it travels its whole width in even steps. The card moves whole, glass, color, shadow and rows, as one
  layer on the render server, with nothing laid out on the way. With Reduce Motion it fades where it lands, or where
  it was. Whether the pointer meant it is decided once, 100ms after it meets the edge (`SidebarEdgeReveal`): a quick
  move counts, even one that runs on past the edge and comes back within 400ms or bounces back off the screen's
  edge, and then it slides all the way out before leaving can send it back, and out past the edge the pointer has
  400ms more to come back, so a quick move and a slow one look the same.
- The one movement past `large`: a download thrown into its button, `Motion.flight` (1.1s), eased out along its arc.
- Moves whose completion must land on time (the Desk's zoom) use `Motion.easeAnimation`, not a spring, which settles
  well after it looks done.

## Surfaces

- **Window frame**: the space's color or gradient, its grain, optionally see-through. The sidebar and the gaps
  around the page are the frame.
- **Sidebar**: on the frame, compact (`Tokens.Sidebar`, the table above). Top row: the traffic lights,
  `Sidebar.lightsGap` (12) to the toggle's glyph, then back, forward and reload at the trailing end, every glyph's
  ink centered on the lights' line (`Symbol.inkOffset`), in `Color.chromeIcon`, no fill until the pointer is on it.
  The address: a soft field of the space's color (`Chrome.field`, the host in `textPrimary`, its own small buttons, any pinned extensions by Site Controls at its right,
  the accent ring from the keyboard). A link, an address or words dragged over any address field (the sidebar's, the
  bar above the page's, a pane strip's, Zigzag Mini's) get the accent drop ring around the field, and let go they
  load in that field's page, or search for the words (`AddressDrop`, #182). Favorites: small soft tiles four to a row in the same look. The space's name
  over its pinned tabs. The tab you're on: the light card of the color, which slides when you pick another. A split row shows both pages, each half with its icon, its title and, while that page
  plays or is muted, its own speaker; a pinned page split beside a tab carries the pair in its own row, so each page
  shows once and one row is lit. A tile group of three or four tabs is one row too, a part for each page in reading
  order with a hairline between, each part's title only while every part has room for a few words
  (`TabRowView.segments`), else each icon in the middle of its part; pointing at a part names its page, and a
  double-click renames that page (over its title, or the row for the moment when the part shows no title). A row of
  several pages keeps the close button's room while it's hidden, so nothing in it moves under the pointer.
  A pinned page that has wandered reads "<its name> / <the page it's on>". Then
  the bottom bar: downloads, space dots, +. A space with an icon shows it in place of its dot, at the sidebar's size
  (`Sidebar.spaceIcon`: 14, 16, 20), each in a 26pt key (28 at Large, `Sidebar.spaceTarget`).
- **Sidebar on the right** (#166, Settings › Appearance, View › Move Sidebar to Right): the whole layout is the
  left one's mirror image (`BrowserRootView.mirrored`): the page on the left, its window corners on its left side,
  the resize edge on the sidebar's left, the hidden sidebar coming out of the right edge, panels that open beside
  the sidebar (previews, the space editor, icons) opening left of it, the mini player first in the page's bottom
  left. Everything else is the left layout's, not its mirror: the traffic lights ride in the sidebar's top row, as
  Arc's right sidebar has them, and the row reads as the left one does, the lights, the toggle after them (glyph
  `sidebar.right`), back, forward and reload at the trailing end (`SidebarView.topRowFrames`), so the page runs up
  to the top as beside a left sidebar, with no strip of frame above it. Hidden, the lights go with the sidebar and
  come back with it slid out, as on the left; a bar above the page there for a page's tools alone leaves them in the
  sidebar, and carries them at its leading end only while the sidebar is hidden, as on the left. With the address
  bar above the page they're at the bar's leading end always, and the sidebar's top row is the mirror image, the
  toggle at its outer end where the bar keeps it while the sidebar is hidden, so it stays put as the sidebar comes
  and goes. The command bar stays centered on the window. Changing sides, the sidebar slides across
  while the pages glide the other way (`gentle`).
- **Developer tools in the bar** (`DeveloperBarTools`, #141): for a tab on a site in Developer Mode and shown on
  its own, with Tools above the page on (`TopBarView.accessory`), the bar's own kind of button (`Tokens.Sidebar`:
  26pt targets, 14pt glyphs) wearing its ink and its fills. With the address kept in the sidebar the bar is there
  for them alone, as Arc's developer bar: from the page's left edge the page's whole address
  (`DeveloperAddressView`: the lock, then scheme, host, port, path and query in `Font.code`, SF Mono at the label
  size), taking the room the tools leave, a click editing it as the address does, then Copy Link; at the trailing
  end the tools in groups a hairline apart (`lineRoom`, the line 16pt tall in `Color.separator`): Console and
  Inspect Element; the page's look and size; reload's choices and ⋯. The address keeps
  `DeveloperBarTools.addressMinWidth` before a button gives way. With the address in the bar, the tools alone
  after it, the same groups, and they give way first, into ⋯, the last first; the address keeps
  `TopBarView.addressMinWidth`. The address and the sidebar's rows stay where the setting puts them, so nothing
  in the sidebar moves for it. Never in a split, where the row is the panes' own strips: there, and with the
  setting off, the console, inspecting and reloading are tiles under Developer in Site Controls, after the
  page's actions. The console's button carries the page's errors as a count, the pill a pinned extension's
  count is (`BadgeView`), "99+" past that; on ⋯ while the console is under it. A count of what happened on the
  page, not a readout: nothing shows at zero.
  A button that holds a choice wears the choice's symbol (Page Appearance: the half-filled circle following the
  Mac, the sun, the moon, a printer for print styles), and its menu checks the one in effect.
  Page Size's button is a phone, a tablet or a laptop by the size chosen (a tablet: short side 500 or more, squarer
  than 1.55 and under 1400 long), with the size after it (`PageSizeReadout`) while the page has a size of its own:
  the listed size's name in `textSecondary`, then the width and height as two fields at the label size in
  tabular figures with "×" between, then "at 86%" in `textTertiary` while it's shown smaller. A field shows the
  bar's hover fill under the pointer and `fieldFill` while you type; Return sets it, Esc leaves it, ↑ and ↓ step it
  by 1, ⇧ by 10, Tab goes on to the height, and a side stays within `PageSizes.limits`. Pressed anywhere else, the
  readout (with the hover fill a button has) opens Page Size's menu. Where room is short the name goes first,
  then the readout.
  ⋯ is filled (`ellipsis.circle.fill`) while something chosen under it is in effect (JavaScript off, another user
  agent, outlines), so no choice is one nothing shows. Its menu: what gave way, what's on or off, User Agent under
  its heading with Open In after it, then View Source, Developer Settings and Turn Off Developer Mode.
- **Developer Mode for a site** (#141): one per-site switch (the list in Settings › Developer), turned on or off
  alike from Turn On (Off) Developer Mode in Site Controls' ⋯ menu and the command bar, and View › Developer ›
  Turn On (Off) Developer Mode for This Site (⌥⇧⌘D, shown in the menus). Not a row of This Site (#198): it's for
  the people who build sites, and one menu item is enough. At once, with a toast naming the site and Undo, in `DeveloperTool.modeSymbol`
  (the outline hammer, the one mark Developer Mode has in menus, toasts and Settings). Never from a private window,
  which keeps nothing about its sites: its tabs follow the list, but can't change it.
- **A page at a size of its own** (`PageCardView.pageSize`, the developer tools'): in the middle of its room on
  the card, both ways, on the PDF viewer's backdrop (`Color.pdfBackdrop`) rather than the page's color, with a
  hairline in `Color.cardEdge` round it, so its edges show on a light page or a dark one; the bar above the page
  turns plain with it. The Web Inspector docks beside it, in room of its own
  (`PageHolder.dockedRoom`): the page keeps its size. A size larger than the room is laid out at its size and shown smaller, whole, through WebKit's view scale (`_setViewScale:`, asked first; without it, cut to the room), never below a quarter; the size beside the button then says how large ("at 54%"). Grips lie on the backdrop beside it, never over it (`PageSizeHandle`): a short 4pt bar in `textTertiary`, `textSecondary` under the pointer, at the right edge for the width, under it for the height, a dot at the corner for both; a drag takes both sides, the page staying in the middle, and none shows where the page meets its room or the Web Inspector is docked. What covers
  the page (a PDF, Settings, Reader) fills the room as ever.
- **Pane header** (split view): on the page card, 30 tall: back, forward and reload, the address centered in a small
  field, and the split's own buttons. Everything in it is its own pane's page: its buttons act on it, its loading
  line and reload state follow it, and clicking its address focuses that pane and opens the address bar over it.
  A tile group's panes (#160) have no swap or layout buttons: their places are where they were dropped. Its ink is
  light or dark by contrast with its page's color, as the bar above the page's is (`PaneHeaderView.ground`).
  Pressed and moved 4pt, the strip picks its pane up (`PaneDrag`), as every drag goes: the pane stays faint, a small
  rounded picture of its page follows the pointer, and the drop hint shows where it lands ("Swap Places", "Move Top
  Left"): another pane's middle swaps, the page's edges and corners take a half or quarter as for a tab, the sidebar's
  list (its line) makes it a tab of its own there, outside every window a new window (⌥: Zigzag Mini). Esc, or its own
  place, changes nothing; one ⌘Z puts it back. Up in the bar above the page the strip moves the window instead.
- **Zoom Pane** (#160): a terminal's or editor's "maximize pane", in Peek's look: the pane (live, the same page, never
  reloaded) grows out of its place to Peek's card frame over the rest, which stay live under Peek's dimming
  (`BrowserRootView.setZoomedPane`, `PaneZoom`). From ⇧-clicking its part of the row of the pages on screen (elsewhere
  ⇧ still picks rows), the strip's button (with zoom, swap and the layout, into ⋯ first) or View › Zoom Pane, ⇧⌘↩.
  Esc, a click beside it, zooming it again or going to another pane puts it back; so does any change to the group.
  Nothing is saved. The row lights the zoomed part with the pressed fill. With Reduce Motion, a crossfade.
- **Tiling** (`TileLayout.swift`): two to four panes on a 2×2 grid, halves and quarters, with a line between the
  columns and one between the rows, each dragged on its own and run only where it divides panes. A tab dragged over
  the page: its edges are halves, its corners quarters, anywhere else the half of the pane under the pointer (beside a
  page alone, the left or right half, as always), and a quarter that can't split takes the tab in its place. The drop
  hint shows where it lands, in the split's one style, named for the place ("Open Top Left") on a toast's pill so it
  reads over any page: near the zone's top, or its bottom while the pointer is in its upper half, clear of what hangs
  under the pointer.
- **Windows** (#167): each window has its own tabs, as in Chrome and Safari; pinned tabs and favorites are every
  window's. A tab dragged out of the sidebar follows the drag-and-drop model: its row stays faint, and over another
  window's sidebar that list's line shows where it lands. Let go there, or over that window's page, and it moves in,
  on screen; let go outside Zigzag and it becomes a window of its own (with ⌥, Zigzag Mini). The page moves as it is,
  never reloaded, a split or tile group whole. A window a move leaves with no tabs closes, unless it's the only one,
  and one ⌘Z in the window they went to sends them back. A private window keeps its tabs to itself.
- **Page**: the opaque card the web page sits in, `Radius.card`, concentric with the window. Beside the sidebar and
  meeting the window's edges it meets the frame cleanly: all four corners at the window's radius
  (`Radius.attached`), no outline, no shadow.
- **Reader** (`Reader.swift`): the article on the page card, scripts off, crossfading in and out in `crossfade`. One
  column of 34em (the text's own size, so about 70 characters a line; Narrow 29em, Wide 40em), and everything in it
  on that column's left edge: the header (the site's icon and name at 14pt, the title in the body face at 2.1em,
  bold, balanced, then the author and the day it was published if the page says), generous space, no rule, then the
  text. New York at 20px with 1.6 leading by default (SF as Sans); Chinese, Japanese and Korean in PingFang, Hiragino
  Sans or Apple SD Gothic Neo at 1.8 in either face, never italic. Pictures at their own size or the column's,
  never larger; captions 14pt in the soft ink under them. Links in the text's color with a quiet underline, the link
  color on hover; quotes behind a 2pt rule; code and tables scroll sideways. Light (warm off-white), Sepia, Dark
  (`Color.surface` at night) and Auto, from `Reader.Palette`. Its one control, Aa, sits on the article's paper at
  the top right, there at the top and when you scroll back up, away while you read on; its panel holds size, face,
  width and colors. Reader itself comes and goes with the address's Reader button, ⌘⇧R or Esc.
- **Mini player** (`MiniPlayer`): leave a tab while a video you were watching plays and it follows you in a card that
  floats in a panel of its own (`MiniPlayerPanel`, #172), over the window and other apps, on every space and beside a
  full screen window, as Picture in Picture does: one you can hear, or one you started or turned up yourself; never a muted autoplay, a page's moving
  background, a card's preview in a link, or anything on a page that's on its way out to another
  (`MiniPlayerLayout.followed`). The tab's own live page moved in and scaled so only its video shows, never laid out
  again. A third of the page area wide (240 to 480), the video's shape, never over half its height, until you resize
  it by any edge or corner, as a window: the video's shape kept, the opposite edge or corner staying put, from 200
  wide to 80% of the screen, its longer side kept for the next video; `Radius.panel` (the page clipped to it
  with `clipsToBounds`, which a web view's layers obey), the floating layer's hairline and the window's own shadow, first
  12pt into the page area's bottom right. It grows out of where the video was (`Motion.zoom`; a fade with Reduce Motion) and fades as it closes. Pointing at it brings its
  controls in a quick fade over a 38% dim, deeper at the top and bottom, so white reads over any picture, words in
  it too: the arrow and the site's name at the top left (one button back to the tab), minimize and close at the top
  right, back 15 seconds, play or pause and forward 15 seconds in the middle (36pt, semibold 20 to 24pt white glyphs
  on a soft shadow), a thin time line to press or drag along the bottom (no skipping or time line for a live
  stream). They go 2.5 seconds after the pointer stops. Drag it anywhere on screen, 4pt in from the edges of its usable
  part (clear of the menu bar and the Dock); let go over its window, it glides (`Motion.snappy`) into the page area's
  nearest corner, 12pt in, and keeps to that corner as the window moves and changes; let go anywhere else, into the
  screen's nearest corner, 12pt in, as the Mac's Picture in Picture does, and stays there whatever the window does.
  Let go with ⌘ held, it stays where it's let go, settling a margin in only within 16pt of an edge, and keeps its
  distance from the screen's nearest corner. Clicked, it takes the keyboard without bringing Zigzag in front of the app
  you're in: Space plays or pauses, Esc and ⌘W close it. Double-click it, or its arrow or site name, to go back to the
  tab, in its own space, its window coming forward. Minimize makes it a pill in the card's corner, `Radius.tile`, on
  `panelBackground`: the video live in a 54 by 32 thumbnail, the tab's title, play or pause, and expand; a click
  brings the card back there. The video plays on all the while. (Not the sidebar's Now Playing row: that shows only
  for a tab you can hear, and a silent video plays on too.)
- **Full screen in the page** (`PageFullScreen`, #168): with Settings › Tabs › Full screen videos fill set to The Page,
  or a site's own Full screen fills the page row in its controls, a page's full screen (a player's button, its key)
  fills the page card, or its pane in a split, in black, the window's chrome as it was. No bar, no note: the player's
  own controls say it's in full screen, and Esc, in the page or anywhere in the window, leaves it.
- **The bar of a one-page window** (`PageBar`, Zigzag Mini and installed apps): the page's own color, as a web app's
  title bar is in Chrome and Safari, the page under it edge to edge so the two read as one surface. The color is the
  site's theme color (WebKit picks its light or dark one), an installed app's manifest `theme_color` after it, each
  only on the page's side of light and dark, else the page's own background; the plain card ground until the page
  says. No space color or grain on it. Its ink is light or dark by contrast (`PageBar.inkAppearance`), its
  controls take the neutral fills (`isOnPage`), and a 1px hairline marks its foot only when the page under it is
  within `PageBar.hairlineContrast` of it. Zigzag Mini keeps its space as the chip that says where Open in goes.
- **A site installed as an app** (`WebAppWindowController`, #165): that bar, `Metric.miniStripHeight` tall: the
  traffic lights, back, forward and reload in `Tokens.Pane` sizes on the lights' center line, and the app's name in
  the middle in the window title's font (`titleBarFont`), dimmed while the window isn't key (the host instead, on
  another site it went to for a sign-in). No sidebar, no address. Show Toolbar off (its View menu, the bar's
  right-click, Settings › General › Installed Apps), the page fills the window with the traffic lights over it in a
  title bar's place (`Metric.webAppTitleBarHeight`), which still moves the window around them and in an 8pt band
  across the top (`Metric.webAppDragBand`), leaving the page's own controls under it alone. While its window is
  key the menu bar is the app's own (`WebAppMenuBar`): Hide and Quit name it and act on it alone, and there's no
  New Tab or other browser item. It opens at `Metric.webAppWindowSize` and keeps its own frame.
  The install sheet is a `FormSheet`: the icon at 72pt over the name field, Install as its one prominent button. The
  icon is the site's own picture filling the Mac's rounded square (824 of 1024, with the system's soft shadow), a
  shape of its own on white with room around it, or the name's first letter on the site's color.
- **Empty states** (`Tokens.EmptyState`, the same in HTML through `PageStyle`): the wordmark 120pt wide at 8%, 16pt
  to a quiet line no wider than 360, 24pt to an optional action. History, Passwords and the error page share it.
- **Built-in pages** (History, Settings, Passwords): one plain `Color.surface` (the column of places in Settings and
  Passwords in a light tint of their window's space, `Brand.Theme.for(view).wash`), `PageTitleView` (wordmark, hairline,
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
  uses any of them. Between the name and the colors, Profile: a dropdown of the profiles, with New Profile at its end
  (a profile of the space's own, named after it and following its name while you type it, in one step with no
  sheet), and one `detail` line under it: spaces on the same profile share sign-ins, history and extensions. The
  same editor opens for a new space, wherever it's made (the sidebar, the menus, the command bar, Settings ›
  Spaces), so the choice is there from the start. With one profile nothing else names profiles; with more, the
  space's header, the space switcher's rows and the top of a space's menu show its profile's name, quiet, unless
  it's the space's own name.
- **Menu** (`MenuPanel`): Zigzag draws its own; only right-click menus are the system's, except the sidebar's empty
  space, whose menu is the +'s. The floating panel's
  surface and its one shadow, `Radius.panel`, a hairline `panelEdge`. `body` items
  `Metric.controlHeight` tall with `Radius.row`, inset 4pt; every item has its picture slot, a neutral globe where a
  site's icon is missing; the chosen item has a check at its trailing end in the window's accent. An item's shortcut,
  as the menu bar has it now, sits at the trailing end in `textTertiary`, as the Mac's menus set it. The sidebar's +
  opens its menu (New Tab, New Folder, New Space) 4pt above it, the trailing edges lined up; a right-click on the
  sidebar's empty space opens the same items, with Edit Space…, under the pointer. Keys: Up and Down,
  Home and End, Return or Space to choose, Esc or Tab to close, typing to jump to a name. VoiceOver reads it as a menu
  of menu items and speaks the item the keys reach. A click outside closes it and goes no further. Panels under it
  leave Esc and that click to it (`MenuPanel.current`). The HTML pages' `.menu` matches it.
- **Dropdown** (`DropdownButton`): a choice from a list. The secondary look with `Radius.row` corners, the current
  choice with its picture, and the up-down chevron. Its menu opens with the chosen item right over the button and
  its text lined up with the button's, as macOS places it; below the button when there's no room, scrolled when the
  list is taller than the window. Press and drag to an item to choose in one movement. With the keyboard, Space,
  Return, Up or Down opens it. VoiceOver: a pop-up button whose value is the choice. `actions` are items after a
  separator that do something and choose nothing ("New Profile"). A choice of profile is filled by
  `ProfileChoice`, each profile with its tile, wherever one is asked for. `showsPictureOnly` leaves only the
  choice's picture where there's no room for its name (Settings' profile menu beside the search on a narrow
  page); the name is then its tooltip and its VoiceOver value.
- **Card**: the chosen thing in a list (`applyRowStyle`, `GlassTile` when selected).
- **Row** (`CardRow`): icon, title, quiet trailing detail; states above.
- **A row's delete** (`RowDelete`): the compact trash, 8pt before the row's last control, shown while the row is
  pointed at or has keyboard focus, and always with VoiceOver on. Hidden, it keeps its room, so nothing moves.
- **Tile** (`GlassTile`): soft glass, `Radius.tile`; a fine darker edge (`openEdge`) when its page is open.
- **Pill button** (`PillButton`): capsule, `.plain` on `fieldFill`, `.quiet` fill on hover only, `.prominent` in
  the accent, one per surface; `isDestructive` for what can't be undone. `PrimaryButton` and `TextButton` remain
  in Settings and a few panels until rebuilt.
- **Dialog** (`Tokens.Dialog`): `DialogHeader` (a picture, the question in the heading's weight, a quiet line under
  it), the explaining text, then `DialogButtons` (the answers at the trailing end, the main one last and filled; a
  quiet choice alone at the leading end). Confirmations, page dialogs, extension and save-password prompts use it.
  A form (`FormSheet`) is the same dialog with rows between the text and the buttons: a field, or a control after
  its label, the labels sharing a column. For what needs more than yes or no: a profile's name and color (the
  space editor's `LookSwatch`), or its name typed to remove it. Return confirms once it can be, never what's
  destructive; Tab stays within it.
- **Buttons** (`ButtonLook`, `applyButtonLook`), capsules `Metric.controlHeight` (28) tall, `Font.control()`:
  - Secondary (`PillButton` `.plain`, `TextButton.form`): `controlFill` (white; a lighter step of the surface in
    dark mode), a hairline `controlEdge` and a faint `controlShadow` (1.5pt, 0.5 down). A symbol may lead the title.
  - Primary (`PillButton` `.prominent`, `PrimaryButton`): the one thing to do on a surface, a pill filled with the
    space's accent (`Brand.Theme.accent`) and its `onAccent` text, a step lighter under the pointer and deeper
    pressed, as a switch that's on; red only for what can't be undone. `Color.primaryFill` (dark, light at night) is
    left only for the plain `ButtonLook.primary` with no tint.
  - Quiet (`.quiet`): no fill until the pointer is over it.
  `PrimaryButton` and `TextButton` draw the same looks for the forms that still use them; new code uses `PillButton`.
- **Switch** (`Toggle`): a slide switch, 34 by 20: a matte recessed track (shade under its upper lip, a hairline
  around it) and a small round 14pt knob. Off, a porcelain knob on the left of a neutral track; on, the knob slides
  right, turns white, and the track fills with the space's accent (`Switch.knobOn`, `edgeOn`), a step deeper under
  the pointer, so on reads at a glance in every space and with Increase Contrast. The knob settles in `Motion.state` (160ms), eased out, and stretches
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

## Next: panels rebuilt in the TE language

The floating panels (Downloads, Site Controls, the address bar opened over the page) are still the old card UI with a
new material. They get rebuilt from scratch to match the sidebar's language, not adapted:

- **One sheet, no boxes inside.** A panel is a single calm sheet of the space's own color family (a lighter step of
  the frame by day, a deeper one by night), with one hairline edge and the one panel shadow. No tiles, no grouped
  cards, no outlined buttons inside it.
- **Type does the structure.** A large light title in the space's ink, like the sidebar's space name ("Downloads",
  "avoidxray.com"), then plain rows. Secondary words are small and quiet. Normal case throughout; a space's name shows
  as you typed it.
- **Actions are a row of thin line glyphs with small labels under them**, set on a grid (share, copy link, screenshot), not three big rounded buttons.
- **Settings for the site are plain rows** with the slide switch at the end, separated by space, not by a card.
- **One accent:** only what's on or chosen (a switch that's on, the main button) takes the space's accent.
- **Empty states are one quiet line**, never a big icon and sentence ("Nothing downloaded yet").
- **The address bar over the page** is the same sheet: the address in large light type, suggestions as plain rows
  below, the chosen row a soft wash, no dark slab.

## The voice

Zigzag speaks in one type style: SF Pro Light, tracked in by 2.3% of its size, in normal case. It's what makes the app
feel like itself, so it's used only where the app is naming something: a space's name set large (26), a page's title (26), a
panel's title (Downloads, 26), the welcome (`Welcome.titleSize`), and in its own case the address bar's text (22 for a
new tab, the sidebar's size over the address). Everything else is SF Pro Regular in normal case.

Always set it through `Tokens.Font.voice(_:)` and `Tokens.Font.voiceText(_:)`, and `letter-spacing: -0.023em` on the
HTML pages, so its weight, tracking and case never drift between screens. Never in bold, never in caps, never for
body text or controls.
