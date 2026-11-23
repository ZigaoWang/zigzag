# Address bar above the page

## The three choices
- Settings › Appearance › Address bar above the page › Off → the address stays in the sidebar; there is no bar above the page.
  Test: TopBarTests.theThreeAddressBarChoicesPlaceTheBar
- Settings › Appearance › Address bar above the page › Autohide → the bar above the page follows the page and can go away.
  Test: TopBarTests.theThreeAddressBarChoicesPlaceTheBar
- Settings › Appearance › Address bar above the page › Always → the bar stays above the page.
  Test: TopBarTests.theThreeAddressBarChoicesPlaceTheBar
- An older Zigzag's "Address bar above the page" switch turned on → Always; the switch is still written for an older Zigzag.
  Test: TopBarTests.theOldSwitchIsAlwaysAndStillWrittenForAnOlderZigzag

## Following the page
- A scroll down moves the bar from the page's first point, with no dead zone, and takes its room out of the page.
  Test: TopBarTests.autohideIsBoundToThePagesPosition
- Once a gesture has taken the bar fully out, that gesture cannot bring it back; a new gesture can.
  Test: TopBarTests.aGestureThatClosedTheBarDoesNotReopenIt
- The page at its very top brings the bar back, even after a locked close; a page scrolling by itself does not move it.
  Test: TopBarTests.theVeryTopAlwaysBringsTheBarBack
- A scrolling key after a trackpad close is a new gesture and brings the bar back.
  Test: TopBarTests.aKeyScrollAfterATrackpadCloseBringsTheBarBack
- A new main-frame document starts with the bar down; a same-document history change does not reset it.
  Test: TopBarTests.aNewDocumentResetsTheBarButANavigationChangeDoesNot
- Typing in a field holds the bar where it is, away or shown.
  Test: TopBarTests.typingInAFieldHoldsTheBarWhereItIs
- A touch in the top band, or a pull down at the page's top, brings the bar back.
  Test: TopBarTests.aTouchInTheTopBandOrAPullAtThePageTopBringsTheBarBack

## The window around it
- With the sidebar docked on the left, the window buttons stay in its row while the bar travels.
  Test: TopBarTests.aDockedSidebarKeepsTheLightsInItsRowWhileTheBarTravels
- In full screen with the sidebar hidden and the bar away, the lights get a backing.
  Test: TrafficLightTests.fullScreenBacksTheLightsWhenTheBarIsAway
- In full screen the pointer at the screen's top brings down the menu bar, not the address bar too.
  Test: TopBarTests.fullScreenGivesTheScreenTopToTheMenuBar

## Scrolling
- The page's scroll reports are coalesced to one per display frame, keeping the last place.
  Test: TopBarTests.theScrollScriptKeepsOneReportPerFrame
- The bar's travel is taken out of the page's scroll, so the content moves once.
  Test: TopBarTests.theBarsTravelTakesItsPartOfThePageScroll
