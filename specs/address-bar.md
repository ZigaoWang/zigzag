# Address bar above the page

## The choices
- Settings › Appearance › Address bar above the page › Off → back, forward, reload and the address stay in the sidebar, with no bar above the page.
  Test: TopBarTests.theThreeAddressBarChoicesPlaceTheBar
- Address bar above the page › Always → they're in a bar above the page that's always there.
  Test: TopBarTests.theThreeAddressBarChoicesPlaceTheBar
- Address bar above the page › Autohide → the same bar, there when a page opens, that goes away as you read down.
  Test: TopBarTests.theThreeAddressBarChoicesPlaceTheBar
- The old Address bar above the page switch turned on → Always; the switch is still written, so an older Zigzag keeps the bar.
  Test: TopBarTests.theOldSwitchIsAlwaysAndStillWrittenForAnOlderZigzag
- Autohide turned off with the bar away → it comes straight back.
  Test: TopBarTests.turningAutohideOffBringsTheBarBack

## Autohide
- Scroll down → the bar moves up with the page from its first point and the page takes its room; once it's out, the page scrolls as usual.
  Test: TopBarTests.autohideIsBoundToThePagesPosition
- While the bar moves, the content moves with your fingers once, not twice.
  Test: TopBarTests.thePagesOwnMovementMovesTheBar
- Scroll back up in the same swipe, wheel burst or scroll bar drag that took the bar fully out → it stays out; the next one brings it back as you scroll up.
  Test: TopBarTests.aGestureThatClosedTheBarDoesNotReopenIt
  Test: TopBarTests.aScrollBarDragThatClosedTheBarDoesNotReopenIt
- Scroll with the arrow keys, Space, Page Up or Down after a swipe took it out → a new gesture: scrolling up brings the bar back.
  Test: TopBarTests.aKeyScrollAfterATrackpadCloseBringsTheBarBack
- Scroll up to the page's very top, or scroll up with the page already there → the bar is back.
  Test: TopBarTests.theVeryTopAlwaysBringsTheBarBack
  Test: TopBarTests.aScrollUpAtThePagesTopBringsTheBarBack
- The page scrolls by itself (a chat, a feed) → the bar stays where it is.
  Test: TopBarTests.theVeryTopAlwaysBringsTheBarBack
- Type in a field on the page → the bar stays where it is, there or away.
  Test: TopBarTests.typingInAFieldHoldsTheBarWhereItIs
- Move the pointer to the window's top → the bar slides back. In full screen the screen's top is the menu bar's, so the bar stays away.
  Test: TopBarTests.thePointerAtTheTopBringsTheBarBack
  Test: TopBarTests.fullScreenGivesTheScreenTopToTheMenuBar
- ⌘L → the bar is back with the address to edit, and stays while you do.
  Test: TopBarTests.openLocationBringsTheBarBack
- A finger on a touch display where the bar was → it slides back, and that tap does nothing else.
  Test: TopBarTests.aFingerWhereTheBarWentBringsItBack
- Open a new page → the bar is there; a page changing its address in place doesn't bring it back.
  Test: TopBarTests.aNewDocumentResetsTheBarButANavigationChangeDoesNot
- Switch tabs → the bar is there.
  Test: TopBarTests.switchingTabsBringsTheBarBack
- In split view → each page's bar or strip goes with that page's own scroll, the others stay.
  Test: TopBarTests.aSplitScrollHidesOnlyItsOwnBar
  Test: TopBarTests.splitAutohideMovesOnlyItsOwnPane

## The window buttons
- Sidebar docked on the left → they stay in its top row while the bar goes and comes back.
  Test: TopBarTests.aDockedSidebarKeepsTheLightsInItsRowWhileTheBarTravels
- Sidebar hidden, or on the right → they ride in the bar as it goes, and go with it; nothing stays over the page.
  Test: TopBarTests.theLightsGoWithAnAutohideBar
- Full screen with the sidebar hidden and the bar away → they come down with the menu bar on their own backing.
  Test: TrafficLightTests.fullScreenBacksTheLightsWhenTheBarIsAway
