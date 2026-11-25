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
- Close a tab → its page is let go at once, so WebKit can end its process; ⇧⌘T loads it again with its history.
  Test: PageReleaseTests.aClosedTabLetsGoOfItsPageAndItself

## Reopening
- ⇧⌘T → whatever closed last comes back, app-wide: a tab, a tab of a closed window, or a whole window.
  Test: ReopenLastClosedTests.theLatestClosedComesBackFirst
- ⇧⌘T for a tab → back in its own window, at its old place, split and group.
  Test: ReopenLastClosedTests.aClosedTabComesBackIntoItsWindow
- ⇧⌘T for a tab of a closed window → it opens in the front window on its own.
  Test: ReopenLastClosedTests.aTabOfAClosedWindowComesBackOnItsOwn
- ⇧⌘T in an everyday window → never a private tab; private windows reopen only their own.
  Test: ReopenLastClosedTests.aPrivateTabNeverComesBackInAnEverydayWindow

## Relaunching
- Quit and open again with On launch set to Continue where you left off → sites' session cookies come back with the tabs, before any page asks for anything (YouTube's theater mode, sign-ins that use them).
  Test: SessionCookiesTests.onlySessionCookiesComeBackAsTheyWere
  Test: SessionCookiesTests.theyreBackBeforeThePageAsksForAnything
- The same with Open a new window → they're gone, as before.
  Test: SessionCookiesTests.openANewWindowDropsThemUnread
- A private window → none are kept.
  Test: SessionCookiesTests.privateWindowsKeepNone
- Clear a site's cookies or website data, or every site's → its kept session cookies go too.
  Test: SessionCookiesTests.clearingASiteTakesItsSavedCookies
- Quit and open again with Continue where you left off, or restart for an update → each tab's page gets back the sessionStorage it had (asleep, or open as Zigzag quit) before its own scripts first run, so a site that keeps your sign-in there (Microsoft 365) still has you signed in; no other page gets it.
  Test: UnloadedTabTests.aRestoredTabGetsItsSessionStorageBackBeforeItsFirstLoad
  Test: SessionCookiesTests.sessionStorageWaitsForItsTabAndTheFileStays
- Zigzag opened for Zigzag Mini, an installed site or AI apps alone, then a browser window → the session comes back with its session cookies and sessionStorage, as it would at launch.
  Test: RelaunchIgnoresLaunchChoiceTests.aSessionLeftWaitingKeepsItsSignIns
- The same with Open a new window → it's gone unread. A private tab's is never kept.
  Test: SessionCookiesTests.openANewWindowDropsSessionStorageUnread
  Test: SessionCookiesTests.aPrivateTabsSessionStorageIsNeverKept
- Clear a site's cookies or website data, or close the tab → what it kept for the next launch goes too.
  Test: UnloadedTabTests.clearingASitesDataDropsWhatTheNextLaunchWouldGetBack
- Clear History → it stays, as in Chrome and Safari: clearing history doesn't sign you out.
  Test: UnloadedTabTests.clearingHistoryKeepsWhatASleepingTabKept
- It's kept in an owner-only file in the profile's folder, up to 250,000 characters a tab and 4,000,000 in all; a tab past that is skipped, not the rest.
  Test: SessionCookiesTests.theSessionStorageFileIsOwnerOnly
  Test: SessionCookiesTests.savedSessionStorageIsCappedATabAtATime

## New tabs
- ⌘T → the command bar opens centered on the window, near the top of the page.
  Test: CommandBarPlacementTests.defaultIsCenteredOnTheWindowAndHighOnThePage
- Open links from a tab → by default each lands below it, after the ones it already opened, in reading order.
  Test: TabCloseSelectionTests.linksOpenedBehindKeepTheirOrderAndCloseToTheNextOne
- ⌘-click or middle-click a link → a background tab; ⇧⌘-click → in front; ⇧-click → Zigzag Mini; in a frame only ⌘ and middle-click.
  Test: PageLinkTests.aClicksModifierDecidesWhereALinkOpens
- ⌘-click or middle-click a link a page took off on purpose, its address kept in `data-zigzag-href` → opens that address as the link would; a plain, ⇧ or ⌥ click stays the page's, and only web addresses are put back.
  Test: CommandClickedLinksTests.aCommandClickOnADelinkedAnchorOpensItsAddress
  Test: CommandClickedLinksTests.aMiddleClickOnADelinkedAnchorOpensItsAddress
  Test: CommandClickedLinksTests.otherClicksOnADelinkedAnchorAreThePages
  Test: CommandClickedLinksTests.aDelinkedAnchorWithAScriptAddressStaysOff
- ⇧-click or Open Link in Zigzag Mini → a Zigzag Mini centered over the window's page, in the page's space and profile.
  Test: MiniFromPageTests.itOpensOverTheWindowsPage
- The same from a private window → the Mini is private: its own store, never saved to History or brought back after an update.
  Test: MiniFromPageTests.aPrivateWindowsMiniIsPrivate
- ⌘O in a Mini opened from a page → the same live page becomes a tab right after the one it came from.
  Test: MiniFromPageTests.openInZigzagPutsItRightAfterTheTabItCameFrom
- Settings › Zigzag Mini › Open ⇧-clicked links in the page off, as it starts → ⇧-click opens the standalone Zigzag Mini as above.
  Test: InPageMiniPolicyTests.theSettingIsOffUntilTurnedOn
  Test: InPageMiniHostTests.withTheSettingOffAShiftClickIsTheStandaloneMini
- The same setting on → ⇧-click opens the Mini over the page you clicked from, the page dimmed behind it, following the page as the window moves or resizes.
  Test: InPageMiniHostTests.aDockedMiniIsABorderlessChildOfTheBrowserWindow
  Test: InPageMiniHostTests.theDockedMiniFollowsThePageCard
- Esc, a click on the dimmed page, ⌘W, the page's `window.close()` or switching tabs → the Mini over the page closes.
  Test: InPageMiniHostTests.escClosesTheDockedMini
  Test: InPageMiniHostTests.aClickOnTheDimClosesTheDockedMini
  Test: InPageMiniHostTests.commandWClosesTheDockedMini
  Test: InPageMiniHostTests.closeWindowStaysOnForADockedMini
  Test: InPageMiniHostTests.aPagesWindowCloseClosesTheDockedMini
  Test: InPageMiniHostTests.aTabSwitchClosesTheDockedMini
- Esc closes the Mini only while the page has the keys: rows picked in the sidebar, its fields and the command bar keep Esc for themselves.
  Test: InPageMiniHostTests.theDockedMiniTakesEscFromThePageButNotFromPickedRows
- ⌘T from the Mini over a page → the browser's new tab bar opens, with the Mini out of its way.
  Test: InPageMiniHostTests.commandTOpensTheBrowsersNewTabBarAndDropsTheDockedMini
- A scroll over the dimmed page around the Mini stays out of the page behind it.
  Test: InPageMiniHostTests.aScrollOverTheDimLeavesThePageBehindStill
- Expand on the Mini over the page → the same live page goes into a Mini window of its own, without reloading.
  Test: InPageMiniHostTests.promotingTakesTheMiniOutIntoAWindowOfItsOwn
  Test: InPageMiniHostTests.expandKeepsTheSameLivePage

## Order and sidebar keys
- ⌥⌘↓ / ⌥⌘↑ or ⇧⌘] / ⇧⌘[ → next or previous row as the sidebar shows it, wrapping, never another space.
  Test: TabNavigationTests.goesDownTheSidebarAndWraps
- The same keys on a split → it's one stop; folded groups are skipped.
  Test: TabNavigationTests.aSplitIsOneStop
- ⌃Tab → recent tabs by default; sidebar order when Settings › Tabs › ⌃Tab switches to says so.
  Test: TabNavigationTests.controlTabFollowsTheSetting
- ⌘1–⌘8 → that row of the sidebar; ⌘9, or a number past the end → the last row.
  Test: NumberHintsTests.numbersGoToTheirPlaceAndNineToTheLast

## Nesting
- Drag a tab and move the pointer right past half a step → the line sets in a level and the drop puts it under the row above, as that tab's last, even one with nothing under it yet; never deeper than two levels, and never under or as a split.
  Test: NestedTabsTests.setInPastTheRowAboveADropGoesUnderIt
- While dragging, how far the pointer moved across since the row was picked up sets the level, the same by finger; half a step back left takes it back out.
  Test: NestedTabsTests.movingAcrossSetsTheCarriedRowInAndOut
- Drag a tab right in its own place → the line shows set in, right under the row above.
  Test: NestedTabRowsTests.draggedRightTheLineSetsInRightUnderTheRowAbove
- The last tab under a tab leaves → that tab's chevron goes too.
  Test: NestedTabRowsTests.theChevronGoesWithTheLastTabUnderIt
- ⌃⇧→ (View › Nest Tab) → the tab you're on goes under the tab above it at its level, with the tabs under it; ⌃⇧← (Unnest Tab) → it goes a level out, just after the tab it was under and that tab's run.
  Test: NestedTabsTests.nestTabGoesUnderTheTabAboveAtItsLevel
- ⌘Z after nesting or unnesting → the tab is back where it was; a relaunch keeps the nesting.
  Test: NestedTabsTests.nestAndUnnestTabUndoAndAreSaved

## Sleeping
- Leave a tab out of sight for an hour → it sleeps.
  Test: TabSleepTests.aTabUnseenForAnHourSleeps
- A tab holding typed text, or one in use → it never sleeps on its own.
  Test: TabSleepTests.typedTextAndTabsInUseNeverSleep
- Suspend Page on a running tab → it sleeps now, and you move to its opener or a neighbor.
  Test: SidebarRowMenuTests.theTabYoureOnGoesOutOfSightAsItSleeps
- A tab goes to sleep → its page is let go, not paused, so WebKit can end its process.
  Test: PageReleaseTests.aSleepingTabLetsGoOfItsPage
- A sleeping tab in the tab list → its icon wears a dashed ring.
  Test: UnloadedTabTests.inTheTabsListATabNotRunningWearsTheRing
- Click a sleeping tab → it loads again where it was.
  Test: UnloadedTabTests.aSleepingTabClickedLoadsAgainWhereItWas
- A sleeping tab woken → its page has its sessionStorage back, and only that first page.
  Test: UnloadedTabTests.aWokenTabKeepsItsSessionStorage
- A sleeping tab's sessionStorage with an item too big to carry → the rest of it is still kept.
  Test: UnloadedTabTests.aBigItemDoesntCostTheRestOfTheSession
- WebKit's network process ends while a tab sleeps (macOS ends it when memory is short) → woken, its page still has its session cookies and its sessionStorage, so it's still signed in.
  Test: UnloadedTabTests.aWokenTabStaysSignedInAfterWebKitsNetworkProcessEnds
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

## Frame rate
- A page on a 120 Hz display → it draws at the display's full rate, as in Chrome; Prefer Page Rendering Updates near 60fps in Settings › Developer › Feature Flags holds every page near 60 instead.
  Test: FeatureFlagsTests.pagesDrawAtTheScreensRateUnlessChanged
- A feature flag you changed → a Reset button beside its switch puts it back to its default; a flag Zigzag starts other than WebKit says so under its name.
  Test: FeatureFlagsTests.aFlagZigzagStartsOtherwiseSaysSoAndResetsToIt
- Every page Zigzag shows (tab, Mini, web app, pop-up, extension page, Reader) → starts at that same rate.
  Test: FramePacingTests.everyPageStartsAtTheChosenRate
- A page that misses more than a quarter of the display's frames in two of three one-second spells of scrolling → held near 60 fps, as in Safari, until its tab goes to another site; a page that keeps up stays at the full rate.
  Test: FramePacingTests.aPageThatCantKeepUpIsHeldNear60
  Test: FramePacingTests.aPageKeepingUpStaysAtTheFullRate
  Test: FramePacingTests.anotherSiteStartsOver

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
- Taps on different tabs one after another → each selects its tab; two taps count as a double-click only on the same tab.
  Test: TouchMovesTests.tapsOnTabRowsSelectThem
- Two taps with a finger on the title bar strip's empty space, beside the traffic lights or the sidebar's buttons → what a double-click there does, once.
  Test: TouchMovesTests.theTitlebarHearsADoubleTapAndZooms
- Touch a page, then it opens a pop-up → the pop-up counts as clicked, as after a mouse click.
  Test: TouchGesturesTests.aFingerLandingRunsTheMouseDownHooks
- Touch and hold a row, slide onto its menu without lifting → the item under the finger lights; lift on it → it runs.
  Test: TouchMovesTests.slidingOntoTheMenuAndLiftingChooses
- Touch and hold a row, lift off its menu → the menu stays open, to be tapped.
  Test: TouchMovesTests.liftingOffTheMenuLeavesItOpen
- Touch and hold a row, then move away from its menu, or before it shows → the row is picked up and drags as with the mouse.
  Test: TouchMovesTests.movingAwayFromTheMenuPicksItUp
- Touch and hold a row, a favorite or a space's dot for about a third of a second → it lifts under the finger at once; move a few points → it's picked up and drags, and its menu doesn't open in the way.
  Test: TouchMovesTests.aHeldRowLiftsAndAMovingFingerKeepsTheMenuAway
- Touch and hold a row and keep still a moment after it lifts → its menu opens; let go → the row settles back.
  Test: TouchMovesTests.aStillLiftedRowOpensItsMenu
- Once a row has lifted under a finger, the list's scrolling can't take the finger; before that, moving scrolls the list at once.
  Test: TouchMovesTests.scrollingCantCancelAHoldOnceRecognized
- A row carried by a finger near the top or bottom of the list → the list scrolls that way, faster nearer the edge.
  Test: TouchMovesTests.theListScrollsNearItsEdgesFasterNearer
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
- Sidebar hidden, no bar above the page, and a finger used in the window in the last 15 minutes → a sidebar toggle can show; the pointer moving, the sidebar shown or the bar above the page shown hides it. Over a page nothing shows by default; right after the sidebar hides with a finger in use it shows for 2 seconds, then fades.
  Test: TouchMovesTests.theGrabberShowsForARecentFinger
- Over a page, a finger's tap along the window's top from its edge on the sidebar's side to 16 points past the toggle (52 points down) shows the toggle with the traffic lights, and that tap does nothing else. Shown, it goes 3 seconds after the last finger there, at once when a finger lands elsewhere (that tap is the page's), or when the pointer moves.
  Test: TouchMovesTests.aTapWhereTheGroupSitsShowsItAWhile
  Test: TouchMovesTests.theTapThatShowsTheGroupClicksNothing
  Test: TouchMovesTests.theGroupGoesAfterItsTime
- Over a page, that toggle shows with the traffic lights as one group on the title bar's material, light or dark as the page's top, where the docked sidebar has its lights and toggle, left or right. In full screen, where the lights come down with the menu bar, it shows there on its own. A finger takes it anywhere in 44 points around it, clear of the lights.
  Test: TouchMovesTests.theGrabberSitsWhereTheSidebarsToggleDoes
- In split view with the panes' strips along the top of the page, it is a button in the top pane's strip on the sidebar's side instead, like the strip's own: before Back on the left, after the close button on the right.
  Test: TouchMovesTests.theGrabberJoinsTheTopPanesStrip
- Tap it → the sidebar shows in the window, as a click on the sidebar toggle does; drag from it → the sidebar follows the finger and stays or slides back as from the edge.
  Test: TouchMovesTests.aTapOnTheGrabberBringsTheSidebarOutToStay
- A finger's tap or pull that brings the sidebar out does only that: the sidebar now under the finger takes neither its click nor its tap; a mouse click there after is the sidebar's.
  Test: TouchMovesTests.aTapThatOpensTheSidebarDoesNothingElse
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

## Back and Forward
- Press and hold Back or Forward for half a second → the pages that way, nearest first, in Zigzag's menu under the button; let go on the button and it stays open to click, Esc closes it. The sidebar's, the bar above the page's, a split pane's strip, Zigzag Mini's and a web app's.
  Test: SidebarRowMenuTests.holdingBackOpensItsListUnderItAfterTheDelay
  Test: SidebarRowMenuTests.everyBackAndForwardInAWindowListsItsPages
- A quick click on Back or Forward → one page that way, no list.
  Test: SidebarRowMenuTests.aQuickClickOnBackGoesOneStepWithNoList
- Hold, slide onto a page in the list and let go → that page.
  Test: SidebarRowMenuTests.pressDragAndReleaseOnAPageGoesThere
  Test: BackHoldEventTests.pressDragAndReleaseOnTheSidebarsBackGoesThere
  Test: BackHoldEventTests.pressDragAndReleaseGoesThereWhenTheDragNeverArrives
  Test: BackHoldEventTests.backAndForwardAreNotWindowDragArea
  Test: BackHoldEventTests.pressDragAndReleaseOnTheTopBarsBackGoesThere
- Back or Forward dimmed, with no pages that way → holding it opens nothing.
  Test: SidebarRowMenuTests.aDisabledBackOpensNothing
- A finger held on Back or Forward → the same list; slide onto a page and lift to go there.
  Test: SidebarRowMenuTests.aFingerHeldOnBackOpensTheSameList
- Hold the mouse's Back or Forward button for half a second anywhere in a page window → the same list at the pointer; slide onto a page and let go to go there, let go anywhere else and it stays open to click. A quick press → one page that way, no list. The browser window, a split's pane under the pointer, Zigzag Mini and a web app.
  Test: SideButtonTests.holdingBackOpensItsListAtThePointerAfterTheDelay
  Test: SideButtonTests.aQuickSideButtonPressGoesOneStepWithNoList
  Test: SideButtonTests.holdSlideAndReleaseOnAPageGoesThere
  Test: SideButtonTests.everyPageWindowListsItsPagesForASideButton
- Two fingers sideways on the trackpad over a page with nothing that scrolls sideways under the pointer → the arrow shows with the first steps, before the page has answered; a page that pans itself takes it back, and up and down never shows it.
  Test: BookmarkFolderTests.swipeArrowLeansInWhileThePageAnswers
  Test: BookmarkFolderTests.swipeArrowShowsWithTheFirstMovement
  Test: BookmarkFolderTests.swipeArrowDoesntWaitOnABusyPage
- The page is asked about the spot under the pointer as two fingers touch the trackpad, before they move.
  Test: BookmarkFolderTests.aTouchDownsProbeIsForTheGestureAtItsSpot
- Let go of a swipe that goes back or forward → the page slides on a little the swipe's way and dims, no spring back; the next page shows in place as it arrives, and within 0.4 seconds the page is back in place whatever happened. Trackpad or fingers on the screen, in a split pane and in Zigzag Mini.
  Test: SwipeExitTests.goingCarriesThePageOnUntilTheNextArrives
  Test: SwipeExitTests.aPageThatNeverArrivesStillGoesBackInPlace
  Test: SwipeExitTests.aNewSwipePutsACarriedPageBackFirst
- Let go of a swipe too soon → the page springs back into place.
  Test: SwipeExitTests.callingItOffStillSpringsBack
- Reduce Motion → the page stays put through a swipe; the arrow alone shows it.
  Test: SwipeExitTests.reduceMotionLeavesThePageWhereItIs
- Let go of a trackpad swipe a third of the page's width along, at most 180 scrolled points, or with a flick a third of that way → back or forward. Fingers on the screen: 100 points, or a third of a narrower pane.
  Test: SwipeGestureTests.swipeGoesAtAThirdCappedOrAFlick
  Test: SwipeGestureTests.aPlainPageGoesBackAndEndsClean
  Test: SwipeGestureTests.aFlickGoesShortOfTheDistance
  Test: SwipeGestureTests.aShortSwipeSpringsBackAndEndsClean
- A sideways gesture that starts where the page can scroll that way, or on a page that cancels its wheel events (a canvas, a map) → the page's for the whole gesture, even once it reaches its edge; only a new gesture there goes back. Mostly up and down, or turning sideways after starting up and down, is a scroll.
  Test: SwipeGestureTests.aSidewaysScrollerKeepsTheGestureUntilANewOneAtItsEdge
  Test: SwipeGestureTests.aPageThatCancelsWheelsNeverSwipes
  Test: SwipeGestureTests.upAndDownAndTurningSidewaysLaterScroll
- While the arrow leans in, the page gets only the sideways part of the scroll: it doesn't move up or down under the swipe.
  Test: SwipeGestureTests.whileTheArrowLeansInThePageOnlyGetsTheSidewaysPart
- A swipe whose end never arrives → it ends as the next gesture starts or its glide comes, when the pointer moves, a click, a key, the window or app going to the back, or after 3 seconds still; no arrow, shifted page or page listener is left. The same in a tab, a split pane, Zigzag Mini and a web app.
  Test: SwipeGestureTests.aLostEndIsClearedByTheNextGesture
  Test: SwipeGestureTests.momentumWithNoEndIsTheRelease
  Test: SwipeGestureTests.aRestHoldsUntilTheWindowGoesOrItRunsOut
  Test: SwipeGestureTests.aRestEndsWhenThePointerMovesInAWindowThatDoesntTrackIt
  Test: SwipeGestureTests.leavingTheWindowMidSwipeEndsClean
  Test: SwipeGestureTests.aPageInACardSwipesTheSameWay
- A new swipe straight after one called off or one that went → it tracks from its first step.
  Test: SwipeGestureTests.aNewSwipeTracksAtOnceAfterOneCalledOff
- Each step of a swipe only moves layers: the backdrop and the page's shadow are set up once as it starts.
  Test: SwipeGestureTests.eachStepOfASwipeIsCheap

## Typing
- Switch a Chinese input method like Pinyin to English mid-word → the letters land without the spaces it showed between syllables ("ni hao" → "nihao"), on a page and in Zigzag's fields, as in Chrome; other input methods, Chinese characters and typing without one are left as they are.
  Test: IMECommitTests.aPageGetsTheLettersCommitted
  Test: IMECommitTests.aCancelledCompositionLeavesLaterTextAlone
  Test: IMECommitTests.aClickOrANewPageForgetsTheComposition
  Test: IMECommitTests.aFieldLeavesOtherTextOverMarkedLettersAlone
