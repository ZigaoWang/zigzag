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
- It shows the address, spaces, favorites, tabs and what's playing; its rows don't drag out, and it has no show/hide sidebar button of its own.
  Test: EdgeSidebarTests.theAddressRowCanBeHiddenForAList
- Its rows and buttons light up under the pointer with the other app still in front.
  Test: EdgeSidebarTests.itsControlsAnswerHoverWithAnotherAppInFront
- Click a tab or a pinned link → its tab becomes active in the browser window, but Zigzag doesn't come forward and the panel stays out.
  No test yet.
- The address opens the browser's command bar over the screen, in the panel, and ⌘T does too; typing, Return and Esc all work there without bringing Zigzag forward.
  No test yet.
- Downloads and Site Controls open in the panel, over its card, not in the window behind it.
  No test yet.
- The menu bar's tab and sidebar keys (⌘T, ⌘W, ⌘L, ⌘1–9 and the rest) act on the browser window while the panel or its preview has the keyboard.
  No test yet.
- Menus from the panel (New Tab, New Space, a row's menu) open beside it without stretching the sidebar.
  No test yet.
- The pointer moves off it, Esc, another app or another Space → it goes back, and the app in front keeps the keyboard unless the panel was clicked.
  Test: EdgeSidebarTests.thePanelRunsDownTheScreensEdgeAndStaysWhileThePointerIsOnIt

## The preview
- Rest the pointer on a tab's row → after a short rest, that tab's running page comes in beside the sidebar, in the same docked Mini that peeks over a page, taking the page's room. The panel takes its full width before the page is placed; the page is laid out once at its final size and only the fold moves, so its contents never reflow through a widening animation.
  Test: EdgeSidebarTests.theEdgePreviewRestsLikeTheOneItReplaces
  Test: EdgeSidebarTests.thePreviewWidensThePanelAndLeavesTheSidebarWhereItIs
  Test: EdgeSidebarTests.thePreviewIsItsOwnFloorToCeilingPill
  Test: InPageMiniHostTests.theEdgePreviewBorrowsTheRowsLivePage
- A row whose page isn't running — asleep, or not loaded since Zigzag reopened → the card shows the moon, the tab's name, why it isn't running and “Click the tab to wake it.” No page picture is drawn. Resting on the row never wakes the page; only a click loads it.
  Test: EdgeSidebarTests.aPageShowsItsCardWhileItIsNotRunning
- Move across a split's or a tile group's parts without leaving the row → each part previews as it comes under the pointer, in the one Mini already out. Only the edge panel follows the parts; the window's own hover card stays on the row's page.
  Test: EdgeSidebarTests.aMultiPageRowReportsThePartUnderThePointer
- Click a row, or a pinned link → the browser's tab becomes active there, but Zigzag doesn't come forward and the panel stays out. A sleeping or not-loaded tab wakes. The clicked page is the one a later hover comes back to.
  No test yet for the selection without bringing the window forward.
- Rest on another row → that page takes the picked page's place; leaving the rows returns to the picked page.
  Test: InPageMiniHostTests.swappingThePreviewBorrowsTheNextPageAndGivesTheFirstBack
- Leave the rows with nothing picked, press Esc, or click away → the page folds back behind the sidebar as the panel narrows; the sidebar stays out.
  No test yet.
- Switch spaces in the panel while a page or a card is out → the panel stays out and the new space's selected tab takes its place, folding from the side the list slid in on: right for the next space, left for the one before. A space with no page puts the preview away.
  Test: EdgeSidebarTests.aSpaceSwitchKeepsThePreviewAndKnowsWhichWayItSlides
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
