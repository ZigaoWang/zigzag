# Sidebar from the screen edge

Settings › Appearance › Sidebar from the screen edge (#363).

## The switch
- A new install → the switch is off, and nothing watches the pointer.
  Test: EdgeSidebarTests.theSwitchIsOffUntilTurnedOn

## Bringing it out
- With another app in front, push the pointer against the screen's edge on the sidebar's side and rest a moment → the last browser window's sidebar comes out over that app.
  Test: EdgeSidebarTests.onlyThePointerPushedAgainstTheSidebarsEdgeOpensIt
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
- Rest the pointer on a tab's row → after a short rest, that tab's running page comes in beside the sidebar, in the same docked Mini that peeks over a page. The page is at its final frame; the panel widens to it from the sidebar's side, so it opens in place rather than sliding over the sidebar.
  Test: EdgeSidebarTests.theEdgePreviewRestsLikeTheOneItReplaces
  Test: EdgeSidebarTests.thePreviewWidensThePanelAndLeavesTheSidebarWhereItIs
  Test: EdgeSidebarTests.thePreviewIsItsOwnFloorToCeilingPill
  Test: InPageMiniHostTests.theEdgePreviewBorrowsTheRowsLivePage
- A row whose page isn't running — asleep, or not loaded since Zigzag reopened → the page pill shows the tab's stored snapshot, blurred, with its name, why it isn't running and “Click the tab to wake it.” Resting on the row never wakes the page; only a click loads it.
  Test: EdgeSidebarTests.aPagePreviewsItsSnapshotWhileItIsNotRunning
- Move across a split's or a tile group's parts without leaving the row → each part previews as it comes under the pointer. Only the edge panel follows the parts; the window's own hover card stays on the row's page.
  Test: EdgeSidebarTests.aMultiPageRowReportsThePartUnderThePointer
- Click any row → today's behavior stays: the panel goes and the browser window comes forward on that tab. The preview is a hover only; a click neither locks it nor keeps it in the panel.
  No test yet.
- Rest on another row → that page takes the first one's place with the same fold from the sidebar's side.
  Test: InPageMiniHostTests.swappingThePreviewBorrowsTheNextPageAndGivesTheFirstBack
- Leave the rows, press Esc, or click away → the page folds back behind the sidebar as the panel narrows; the sidebar stays out.
  No test yet.
- Switch spaces in the panel while a page or a snapshot is out → the preview goes; it does not follow the space that comes next.
  No test yet.
- A page Zigzag serves itself, like Settings or History → it doesn't preview; the row behaves as before and a click opens it in the browser window.
  Test: EdgeSidebarTests.thePanelTakesWebPagesAndNotZigzagsOwn
- A borrowed page returns to its card working, even if the card had cleared it while the Mini had it (the “shown in another window” state).
  Test: InPageMiniHostTests.aBorrowedPageComesBackToACardThatHadClearedIt
- Reopening the same row while its preview folds out → the leaving Mini gives the page back at once, so the new Mini owns it and the tab never ends with no host.
  Test: InPageMiniHostTests.reopeningDuringTheFoldOutEndsTheOldBorrowFirst
- An edge preview borrows the tab already in the browser's list → extensions hear nothing of its window opening, closing or focus, and the preview's space chip stays hidden so it cannot move the tab behind the list's back.
  Test: InPageMiniHostTests.aBorrowedPreviewKeepsTheSpaceChipHidden
- A screen too narrow for the sidebar and the page's third → the panel stops at the screen and the page takes the room left.
  Test: EdgeSidebarTests.thePanelAndPageNeverWidenPastTheScreen
