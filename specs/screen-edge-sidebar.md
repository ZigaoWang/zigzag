# Sidebar from the screen edge

Settings › Appearance › Sidebar from the screen edge (#363).

## The switch
- A new install → the switch is off, and nothing watches the pointer.
  Test: EdgeSidebarTests.theSwitchIsOffUntilTurnedOn

## Bringing it out
- With another app in front, push the pointer against the screen's edge on the sidebar's side and rest a moment → the last browser window's sidebar comes out over that app.
  Test: EdgeSidebarTests.onlyThePointerPushedAgainstTheSidebarsEdgeOpensIt
- The last window in front is a private window or the AI Apps window, shown or hidden → the sidebar that comes out is your last other window's.
  Test: EdgeSidebarTests.theAIAppsWindowNeverHasTheEdgesSidebar
- Zigzag in front, or a mouse button held down → it doesn't come out.
  Test: EdgeSidebarTests.itComesOutOnlyOverAnotherAppWithNoButtonDown
- The pointer in a screen corner, over the menu bar or over a Dock at the bottom → it doesn't come out.
  Test: EdgeSidebarTests.theCornersMenuBarAndBottomDockAreLeftToMacOS
- The edge leads onto another display → it doesn't come out there.
  Test: EdgeSidebarTests.anEdgeSharedWithAnotherDisplayIsAWayAcross
- The Dock, or Stage Manager's strip, is on the sidebar's side → that edge never brings it out.
  Test: EdgeSidebarTests.theDockAndStageManagerKeepTheirSide

## Using it
- It shows the spaces, favorites, tabs and what's playing, without the address row; rows don't drag out of it.
  Test: EdgeSidebarTests.theEdgesSidebarIsAListWithoutTheAddressRow
- Its rows and buttons light up under the pointer with the other app still in front.
  Test: EdgeSidebarTests.itsControlsAnswerHoverWithAnotherAppInFront
- Click a tab, a favorite, New Tab or a menu item → the panel goes and the browser window comes forward and does it there.
  No test yet.
- The pointer moves off it, Esc, another app or another Space → it goes back, and the app in front keeps the keyboard unless the panel was clicked.
  Test: EdgeSidebarTests.thePanelRunsDownTheScreensEdgeAndStaysWhileThePointerIsOnIt

## The preview
- Rest the pointer on a tab's row → its page comes out beside the sidebar, in the same Zigzag Mini that opens over a page, as tall as the sidebar and a third of the screen wide. The sidebar keeps its width and place, and the page is laid out once, at that size.
  Test: EdgeSidebarTests.aPreviewWidensThePanelBesideTheSidebar
  Test: EdgeSidebarTests.aTileGroupPreviewStartsAtThePagePillSize
- It is the row's own page, still in the browser's list: closing the preview gives the page back to its tab, and the preview has no space chip to move it with.
  Test: InPageMiniHostTests.theEdgePreviewBorrowsTheRowsLivePage
  Test: InPageMiniHostTests.aBorrowedPreviewKeepsTheSpaceChipHidden
- Move across a split's or tile group's parts → each part's page comes out as the pointer reaches it.
  Test: EdgeSidebarTests.aMultiPageRowReportsThePartUnderThePointer
- Cross from one row to the next, however slowly, or rest on the gap between them → the page stays out; the row the pointer rests on is the one whose page comes out.
  Test: EdgeSidebarTests.aCrossingBetweenRowsKeepsThePage
- A row whose page is asleep or not loaded yet → a card with its name and why it isn't running, in the page's place. Resting on it never wakes the page.
  Test: EdgeSidebarTests.anAsleepRowShowsItsCardAndStaysAsleep
- Click that card → the same as a click on its row: the panel goes and the browser window comes forward with that tab, its page woken there.
  Test: EdgeSidebarTests.clickingAnAsleepCardOpensItsTabInTheWindow
- A page out beside the sidebar, or in a Mini → it doesn't sleep, unseen for long, short of memory or busy; one that goes to sleep anyway shows that card, never an empty page.
  Test: EdgeSidebarTests.aPreviewedPageStaysAwakeAndShowsItsCardIfItSleeps
- A row of Zigzag's own pages, like History or Settings → nothing comes out beside the sidebar; a click opens it in the browser window.
  Test: EdgeSidebarTests.zigzagsOwnPagesOpenInTheWindow
  Test: EdgeSidebarTests.anOwnPagesRowPutsThePageAway
- Click a row while its page is out → the panel and the page go, and the browser window comes forward with that tab, its page in the window.
  Test: EdgeSidebarTests.clickingAPreviewedRowShowsItsPageInTheWindow
  Test: InPageMiniHostTests.aBorrowedPageSelectedWhileOutComesBackToTheCard
- Esc, or the pointer off the rows and the page → the page folds back and the sidebar stays out.
  Test: EdgeSidebarTests.escPutsThePageAwayFirst
  Test: EdgeSidebarTests.leavingTheRowsAndThePageFoldsItBack
- Rest on the same row again while its page is folding away → the new preview has the page, and the tab is never left without one.
  Test: InPageMiniHostTests.reopeningDuringTheFoldOutEndsTheOldBorrowFirst
- Click into the page → Zigzag comes forward, and the sidebar and the page stay out until the pointer leaves them.
  No test yet.
- The page clicked into, then Esc or the pointer back on the sidebar → the page folds back and the panel keeps the keyboard; the browser window stays where it was.
  Test: EdgeSidebarTests.aPageFoldingBackGivesTheKeyboardToThePanel
  Test: EdgeSidebarTests.aPageFoldingBackUnclickedLeavesTheKeyboard
- A menu from the panel while a page is out → the page steps aside until the menu closes, so no part of the menu is under it.
  Test: EdgeSidebarTests.aMenuFromThePanelIsNeverUnderThePage
- Open in Zigzag in the page's strip → the browser window comes forward on that tab. Expand → the page leaves the list for a Zigzag Mini of its own, and the panel goes.
  Test: InPageMiniHostTests.openInZigzagGivesTheBorrowedPageBackToItsTab
  Test: EdgeSidebarTests.expandingTheEdgePreviewLeavesAnIndependentMini
- Extensions hear nothing of the preview: it is a tab the browser already has.
  Test: EdgeSidebarTests.thePreviewIsNoWindowForExtensions
