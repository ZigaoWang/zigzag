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
- Rest the pointer on a tab's row → after a short rest, that tab's live page comes in beside the sidebar, in the same docked Mini that peeks over a page, sliding out from the sidebar's side; the panel widens by the page's third and the sidebar keeps its width and place.
  Test: EdgeSidebarTests.theEdgePreviewRestsLikeTheOneItReplaces
  Test: EdgeSidebarTests.thePreviewWidensThePanelAndLeavesTheSidebarWhereItIs
  Test: EdgeSidebarTests.thePreviewIsItsOwnFloorToCeilingPill
  Test: InPageMiniHostTests.theEdgePreviewBorrowsTheRowsLivePage
- A split view or a group of tiles → the part under the pointer is the page previewed, and moving to another part changes it.
  Test: EdgeSidebarTests.aMultiPageRowReportsThePartUnderThePointer
- Click the previewed row → the page stays, is locked, and takes the keyboard; leaving the rows comes back to it.
  Test: EdgeSidebarTests.aPickOpensReplacesOrLocksThePageOut
  No test yet for the lock itself.
- Rest on another row → that page takes the first one's place with the same fold from the sidebar's side.
  Test: InPageMiniHostTests.swappingThePreviewBorrowsTheNextPageAndGivesTheFirstBack
- Leave the rows without a pick, press Esc, or click away → the page folds back behind the sidebar and the panel narrows; the sidebar stays out.
  No test yet.
- Switch spaces in the panel while a page is out → the panel stays out and previews the new space's selected tab; a space with no page puts the preview away.
  Test: EdgeSidebarTests.aSpaceSwitchKeepsThePreviewAndKnowsWhichWayItSlides
- A page Zigzag serves itself, like Settings or History → its row stays greyed and takes no pick; the page area says “Zigzag's own pages only work in the browser window.” with Return to Zigzag, which brings the browser forward on that page.
  Test: EdgeSidebarTests.thePanelTakesWebPagesAndNotZigzagsOwn
  Test: EdgeSidebarTests.theNoteStandsInThePagePillAndOffersTheWindow
- A screen too narrow for the sidebar and the page's third → the panel stops at the screen and the page takes the room left.
  Test: EdgeSidebarTests.thePanelAndPageNeverWidenPastTheScreen
