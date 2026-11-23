# Tabs

## Closing
- ⌘W on a tab opened from another tab, before you switched tabs yourself → the next tab that opener opened, else the opener.
  Test: TabCloseSelectionTests.aLinkOpenedInFrontClosesBackToItsPage
- ⌘W on any other tab → the tab below, else the one above; never the one you used last.
  Test: TabCloseSelectionTests.closingGoesToTheTabBelowNotTheOneYouWereOnBefore
- ⌘W on a pinned tab or favorite → it unloads and stays; next time it opens fresh at its saved address.
  Test: TabCloseSelectionTests.closingAPinnedPageOrFavoriteUnloadsItAndKeepsIt
- ⌘W on the last tab of a space → the space's most recent page, else the space shows empty.
  Test: TabCloseSelectionTests.closingTheLastTabGoesToTheSpacesRecentPageElseEmpty

## Reopening
- ⇧⌘T → whatever closed last comes back, app-wide: a tab, a tab of a closed window, or a whole window.
  Test: ReopenLastClosedTests.theLatestClosedComesBackFirst
- ⇧⌘T for a tab → back in its own window, at its old place, split and group.
  Test: ReopenLastClosedTests.aClosedTabComesBackIntoItsWindow
- ⇧⌘T for a tab of a closed window → it opens in the front window on its own.
  Test: ReopenLastClosedTests.aTabOfAClosedWindowComesBackOnItsOwn
- ⇧⌘T in an everyday window → never a private tab; private windows reopen only their own.
  Test: ReopenLastClosedTests.aPrivateTabNeverComesBackInAnEverydayWindow

## New tabs
- ⌘T → the command bar opens centered on the window, near the top of the page.
  Test: CommandBarPlacementTests.defaultIsCenteredOnTheWindowAndHighOnThePage
- Open links from a tab → by default each lands below it, after the ones it already opened, in reading order.
  Test: TabCloseSelectionTests.linksOpenedBehindKeepTheirOrderAndCloseToTheNextOne
- ⌘-click or middle-click a link → a background tab; ⇧⌘-click → in front; ⇧-click → Zigzag Mini; in a frame only ⌘ and middle-click.
  Test: PageLinkTests.aClicksModifierDecidesWhereALinkOpens
- ⇧-click or Open Link in Zigzag Mini → a Zigzag Mini centered over the window's page, in the page's space and profile.
  Test: MiniFromPageTests.itOpensOverTheWindowsPage
- The same from a private window → the Mini is private: its own store, never saved to History or brought back after an update.
  Test: MiniFromPageTests.aPrivateWindowsMiniIsPrivate
- ⌘O in a Mini opened from a page → the same live page becomes a tab right after the one it came from.
  Test: MiniFromPageTests.openInZigzagPutsItRightAfterTheTabItCameFrom

## Order and sidebar keys
- ⌥⌘↓ / ⌥⌘↑ or ⇧⌘] / ⇧⌘[ → next or previous row as the sidebar shows it, wrapping, never another space.
  Test: TabNavigationTests.goesDownTheSidebarAndWraps
- The same keys on a split → it's one stop; folded groups are skipped.
  Test: TabNavigationTests.aSplitIsOneStop
- ⌃Tab → recent tabs by default; sidebar order when Settings › Tabs › ⌃Tab switches to says so.
  Test: TabNavigationTests.controlTabFollowsTheSetting
- ⌘1–⌘8 → that row of the sidebar; ⌘9, or a number past the end → the last row.
  Test: NumberHintsTests.numbersGoToTheirPlaceAndNineToTheLast

## Sleeping
- Leave a tab out of sight for an hour → it sleeps.
  Test: TabSleepTests.aTabUnseenForAnHourSleeps
- A tab holding typed text, or one in use → it never sleeps on its own.
  Test: TabSleepTests.typedTextAndTabsInUseNeverSleep
- Suspend Page on a running tab → it sleeps now, and you move to its opener or a neighbor.
  Test: SidebarRowMenuTests.theTabYoureOnGoesOutOfSightAsItSleeps
- A sleeping tab in the tab list → its icon wears a dashed ring.
  Test: UnloadedTabTests.inTheTabsListATabNotRunningWearsTheRing
- Click a sleeping tab → it loads again where it was.
  Test: UnloadedTabTests.aSleepingTabClickedLoadsAgainWhereItWas
- A sleeping tab woken, or one restored after a relaunch → its page plays nothing with sound until you use it.
  Test: UnloadedTabTests.aWokenOrRestoredPageStartsNoSoundOnItsOwn
- A sleeping tab woken, or one restored after a relaunch → its page is the site's page now, not a copy kept from before.
  Test: UnloadedTabTests.aRestoredPageIsTheSitesPageNowNotWebKitsOldCopy

## Handoff
- The key window's tab on an http or https page → offered to your other devices; never a private window, Zigzag's own pages, a file, an error page or this Mac's own address.
  Test: HandoffTests.onlyAWebPageAnotherDeviceCanOpenIsOffered

## Sound
- A tab playing sound or muted → a speaker after its title; clicking it mutes or unmutes that page.
  Test: RowSpeakerTests.theSpeakerMutesAndUnmutesItsPage
- A tab's menu, or an open pinned page's or favorite's → Mute Tab or Unmute Tab, even before it plays; it stays muted through a reload and sleep.
  Test: SidebarRowMenuTests.aTabCanBeMutedBeforeItPlays
- Pause the video or audio a tab's sound came from → its speaker goes away after a moment, even if WebKit still says it plays.
  Test: MiniPlayerPageTests.aSoundFromAVideoEndsOnceItStops

## Mini player when you leave
- Show a mini player when you leave Zigzag on, and switch to another app with the window covered, minimized, hidden or on a desktop no longer showing → after a moment the watched video moves into the mini player.
  Test: AutoPictureInPictureTests.movesOnlyOnceTheWindowIsOutOfSight
- The same, with the window still in view on another display → the video stays in its page until that window goes out of sight.
  Test: AutoPictureInPictureTests.aWindowInViewOnAnotherDisplayKeepsItsVideo

## Picked rows
- ⌫, ⌦ or ⌘⌫ with two or more rows picked → picked tabs close and picked pinned pages are removed, once per press.
  Test: SidebarDeleteKeyTests.deleteClosesPickedRowsOnceAndOnlyWhilePicked

## Between windows
- Drag a tab into another window's sidebar → it moves there at the drop line and is shown; it isn't a closed tab, so ⇧⌘T has nothing to reopen.
  Test: OwnWindowTabsTests.aMovedTabLeavesOneWindowForTheOtherAsItIs
- Drag a split to another window → it moves whole and stays a split.
  Test: OwnWindowTabsTests.aSplitMovesWholeAndStaysASplit

## Touch
- Touch and hold a row → its menu opens where the finger is, the same one a right-click opens.
  Test: TouchGesturesTests.aHeldFingerOpensTheMenuARightClickOpens
- Tap a row → its × and other hover-only buttons show until a finger lands outside the sidebar, another row is tapped, or the pointer moves over it.
  Test: TouchGesturesTests.aTapShowsARowsButtonsUntilThePointerOrAFingerElsewhere
- Tap just beside a row's showing × → the tab closes; a mouse click there is still the row's.
  Test: TouchGesturesTests.aFingerNearTheCloseButtonCloses
- Tap an open favorite → its × shows, as hovering shows it, until a finger lands outside the sidebar, something else is tapped, or the pointer moves over it.
  Test: TouchGesturesTests.aTapShowsAnOpenFavoritesClose
- Tap the Tabs label above today's tabs → Clear shows, as hovering the list shows it, until a finger lands outside the sidebar or the pointer comes over the list.
  Test: TouchGesturesTests.aTapShowsClearAboveTheTabs
- Two taps on a tab, a space's dot or a resize edge → what a double-click there does (rename, edit the space, the usual width or even tiles).
  Test: TouchMovesTests.twoTapsOnAControlAreADoubleClick
- Touch a page, then it opens a pop-up → the pop-up counts as clicked, as after a mouse click.
  Test: TouchGesturesTests.aFingerLandingRunsTheMouseDownHooks
- Touch and hold a row, slide onto its menu without lifting → the item under the finger lights; lift on it → it runs.
  Test: TouchMovesTests.slidingOntoTheMenuAndLiftingChooses
- Touch and hold a row, lift off its menu → the menu stays open, to be tapped.
  Test: TouchMovesTests.liftingOffTheMenuLeavesItOpen
- Touch and hold a row, then move away from its menu, or before it shows → the row is picked up and drags as with the mouse.
  Test: TouchMovesTests.movingAwayFromTheMenuPicksItUp
- A finger and the mouse drag a row the same way: reorder, into a folder, a split, another space.
  Test: TouchMovesTests.theMouseAndAFingerDriveTheSameDrag
- A row carried by a finger out over the page → it keeps following the finger there until it lifts.
  Test: SplitDragTests.theWindowFollowsTheFingerOverThePage
- One finger sideways across the sidebar → the previous or next space, as two fingers on the trackpad; up and down scrolls.
  Test: TouchMovesTests.aFingerAcrossTheSidebarSwitchesSpaces
- Pinch in on a page at its usual size → Show All Tabs; zoomed in, or pinching out, the page zooms. Pinch out on a card → it opens.
  Test: TouchMovesTests.pinchingInAtTheUsualSizeOpensTheOverview
- Two fingers sideways on a page → Back or Forward with the trackpad swipe's arrow, when the Mac's touch setting and Zigzag's allow swiping.
  Test: TouchMovesTests.twoFingersOnAPageGoBackAndForward
- One finger on a page is the page's, two go back or forward; each decides only after the fingers have moved ten points.
  Test: TouchMovesTests.fingersOnAPageRouteByCount
- Three fingers on a page are left to macOS, which takes them for switching desktops.
  Test: TouchMovesTests.threeFingersRouteNowhere
- Two fingers sideways across the sidebar → the previous or next space, as one does.
  Test: TouchMovesTests.theSwipesAreTouchOnly
- Sidebar hidden, a finger in from the page's edge → the sidebar slides out under it; let go a third of the way out or with a flick and it stays, otherwise it slides back.
  Test: TouchMovesTests.aFingerFromTheEdgePullsOutTheSidebar
- A finger landing on the window's outer 12 points is left to macOS, which resizes the window there; the pull starts from 12 to 40 points in from the page's edge.
  Test: TouchMovesTests.theEdgeRules
- Sidebar hidden and a finger used in the window in the last 15 minutes → a small grabber shows at the window's edge on the sidebar's side, 8 points in, centered on the page; the pointer moving, or the sidebar shown, hides it.
  Test: TouchMovesTests.theGrabberShowsForARecentFinger
- The grabber sits on the sidebar's side, left or right, and takes a finger in a 44 by 88 point box.
  Test: TouchMovesTests.theGrabberSitsInsetOnTheSidebarsSide
- Tap the grabber → the sidebar slides out and stays, as after a finger's pull; drag from it → the sidebar follows the finger and stays or slides back as from the edge.
  Test: TouchMovesTests.aTapOnTheGrabberBringsTheSidebarOutToStay
- A finger from the grabber up or down 24 points → the previous or next space, one a swipe, its name shown beside the grabber; the sidebar stays hidden.
  Test: TouchMovesTests.aFingerFromTheGrabberPullsOrChangesSpace
- Tap the sidebar toggle in the bar above the page with the sidebar hidden or out by touch → it docks, as a click does.
  Test: TouchMovesTests.aTapOnTheBarsToggleDocksTheSidebar
- Out by a finger, the sidebar stays until a tap on the page, a tab is picked, a finger on the page swipes it back, or the pointer moves.
  Test: TouchMovesTests.theEdgeRules
- Tap just beside the sidebar toggle in the bar above the page → it shows the sidebar; a mouse click there is still the bar's.
  Test: TouchMovesTests.theBarsToggleTakesAFingerBesideIt
- A finger dragging a page sideways → it scrolls, never Back or Forward.
  Test: TouchMovesTests.aFingerDraggingThePageIsNotATrackpadSwipe
- The trackpad's swipes, the pointer at the window's edge and the sidebar toggles work as before alongside all of it.
  Test: TouchMovesTests.theTrackpadsScrollsAreNotClaimed
