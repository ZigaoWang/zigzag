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

## Picked rows
- ⌫, ⌦ or ⌘⌫ with two or more rows picked → picked tabs close and picked pinned pages are removed, once per press.
  Test: SidebarDeleteKeyTests.deleteClosesPickedRowsOnceAndOnlyWhilePicked

## Between windows
- Drag a tab into another window's sidebar → it moves there at the drop line and is shown; it isn't a closed tab, so ⇧⌘T has nothing to reopen.
  Test: OwnWindowTabsTests.aMovedTabLeavesOneWindowForTheOtherAsItIs
- Drag a split to another window → it moves whole and stays a split.
  Test: OwnWindowTabsTests.aSplitMovesWholeAndStaysASplit
