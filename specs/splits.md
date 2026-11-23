# Splits

## Creating
- Drag a tab or pinned row onto a page → a split; a top or bottom edge stacks them, anywhere else takes the left or right half, at even halves.
  Test: TileLayoutTests.besideOnePageItIsHalvesAsBefore
- Drop a row onto a split → corners give quarters, an edge gives a half, up to four pages.
  Test: TileLayoutTests.besideTwoCornersAreQuartersAndEdgesHalves
- Drop onto a quarter, or onto a group of four → the new page takes that page's place, and the old one becomes a plain tab.
  Test: TileLayoutTests.aQuarterThatCannotSplitTakesTheNewPage
- Drop a row onto the middle of another sidebar row → the two open side by side.
  Test: SplitCloseTests.aRowDroppedOnAnotherRowsMiddleOpensBesideIt
- Drop a page of another split → no split; that split stays as it is.
  Test: SplitDropTests.aSplitIsNeverBrokenByADrop
- Drop a link or file on the page → it opens as a tab, not a split.
  Test: SplitCloseTests.aLinkDroppedOnThePageOpensATabNotASplit
- Open in Split View in a tab's sidebar menu or the command bar → it opens on the right of the current page.
  Test: SplitCloseTests.openInSplitViewFromTheMenuOpensOnTheRight
- Drag a tab or pinned row over the page → the half or quarter it would take is shaded, with a card naming the page and where it opens, kept clear of the pointer; it fades away off the page.
  Test: SplitDragTests.theHintFadesAndNamesThePageComingIn
- Touch and hold a tab, then drag it onto the page, across its menu or not → it opens there as with the mouse.
  Test: SplitDragTests.aFingerPastTheMenuStillReachesThePage

## The split row
- A split shows as one sidebar row with a part per page; clicking a part selects that page.
  Test: SplitDropTests.aSplitShowsInOneRow
- Click × on the row → closes only the page of the part it sits in.
  Test: SplitCloseTests.theRowsCloseButtonClosesOnePart
- A split of two, three or four pages draws the same row in the tab list and among the pinned pages.
  Test: PinnedGroupTests.bothSectionsDrawTheSameRow
- Middle-click the row → closes the page of the part under the pointer.
  Test: SplitCloseTests.aMiddleClickClosesThePartUnderThePointer
- Close Split View in the row's menu → closes every page; one ⌘Z brings them all back.
  Test: SplitCloseTests.theMenuOffersBoth
- Separate Split View (or ⌥⌘\ Separate Tabs) → every page becomes its own tab and the selection stays.
  Test: SidebarRowMenuTests.aSplitLeadsWithSeparatingItAndEachPageGetsItsOwnMenu
- Remove from Split View on one page of three or four → only that page leaves; the rest close up.
  Test: SidebarRowMenuTests.onePageOfThreeCanLeaveTheRestSideBySide
- ⌘Z after closing one page of a split → the split comes back on the same side at the same size.
  Test: SplitCloseTests.closingTheLeftPageLeavesTheOtherInItsPlace
- Stack Vertically on a split of two → one above the other; the item then reads Side by Side.
  Test: SplitCloseTests.stackVerticallyThenReadsSideBySide

## Pinned splits
- Pin a split of two, three or four pages → one pinned split with every page in its place; opened or unpinned, it comes back in that shape.
  Test: PinnedGroupTests.aSplitPinsReopensAndUnpinsWhole
- Drag a split of four into Pinned and back → the same four pages side by side, each step undoable.
  Test: PinnedGroupTests.aFourPageSplitDraggedToPinnedAndBack
- Remove from Split View on one page of a pinned split of three → that page stays pinned on its own; the other two stay a pinned split.
  Test: PinnedGroupTests.onePageLeavesAPinnedSplitOfThree
- Close one page of a pinned split → that page unloads; the pin keeps every page.
  Test: PinnedGroupTests.closingOnePinnedPageKeepsThePin
- A pinned split's row has the same × in each part as a split of tabs; click it → only that page unloads.
  Test: PinnedGroupTests.aPinnedPartsCloseButtonUnloadsOnlyIt
- Drop a tab or a pinned page on either half of a pinned split's row → it joins as a third or fourth page, as on a split of tabs; at four, the row only moves.
  Test: PinnedGroupTests.aDropGrowsAPinnedSplitAsATabSplit
- Drag one page of a pinned split out by its strip → into Pinned it stays pinned on its own there, into the tabs it's a tab; the rest stay a pinned split, or one pinned page.
  Test: PinnedGroupTests.aPagePulledOutOfAPinnedSplitOfThree
- A pinned split saved by an older Zigzag → reads and is written back as before.
  Test: PinnedGroupTests.olderPinnedSplitsReadAndWriteAsBefore

## Resizing
- Plain drag on a line → the whole line moves; in a grid of four, ⇧-drag on either line moves only the segment between two pages.
  Test: DragZoneTests.aPlainDragMovesTheWholeLineAndShiftMovesOneSegment
- In a grid of four, one line is parted at a time → a parted line's segments drag on their own; the other line moves whole, even with ⇧.
  Test: TileLayoutTests.onlyShiftOrAPartedLineMovesASegmentAlone
- Release a segment near the middle of a parted grid → it snaps to the middle, unless ⇧ is held.
  Test: DragZoneTests.aNearEvenLineSnapsOnReleaseUnlessShiftHoldsIt
- Release a segment near the other segment of its line → it snaps there instead, whichever is nearer.
  Test: TileLayoutTests.aSegmentSnapsToTheOtherColumnsLineAndTheMiddle
- Double-click a line → that line goes to the middle; lines the other way stay put.
  Test: DragZoneTests.aPlainDragOutsideAPartedGridIsTheDragItAlwaysWas
- Drag a corner where lines meet → both lines move together, keeping the grab offset.
  Test: DragZoneTests.aCornerIsEasyToCatchAndNeverJumps
- Reset Tile Layout on the pane strip (only when a line is parted) → every line back to the middle.
  Test: TileLayoutTests.evenAgainPutsEveryLineInTheMiddle
- Quit and reopen → each split comes back at the sizes it had; new splits always start even.
  Test: TileLayoutTests.aGroupsOwnLinesComeBackAsTheyWereSaved

## Pane strips
- Click a pane's address → that pane gets focus and the command bar opens over the address to edit it.
  Test: SplitCloseTests.aPanesAddressEditsThatPane
- Back, Forward and Reload on a strip → act on that pane's page only.
  Test: SplitCloseTests.aStripsButtonsActOnItsOwnPane
- Swap on a strip → the two pages trade places on screen at once; the page you're in stays yours, and a click on a pane picks the page shown there.
  Test: SplitCloseTests.swapMovesThePagesOnScreen
- Narrow a strip → its buttons move into ⋯ in stages; Back and × always stay.
  Test: PaneHeaderTests.fewerButtonsAsItNarrows
- Zoom on a strip (or ⇧⌘↩) → that pane fills the page; Zoom again puts it back.
  Test: PaneMoveTests.aPaneZoomsAndGoesBack
- Drag a pane's strip with a finger → it moves or leaves the split as with the mouse, with the same preview naming it.
  Test: SplitDragTests.aFingerDragsAPaneByItsStripAsTheMouseDoes
- An http page in a pane → its strip's address shows the not-secure mark, as the sidebar's does.
  Test: PaneHeaderTests.anHttpPageIsMarkedNotSecure
- A file or a Zigzag page (History, Settings) in a pane → its strip's address shows its name, never a cut "file:".
  Test: PaneHeaderTests.aFileShowsItsNameAndAWebPageItsAddress

## Closing and suspending one page
- Close one page of a split of two (⌘W, or × on its strip or row part) → the one left takes the split row's place as a plain tab.
  Test: SplitCloseTests.closingTheLeftPageLeavesTheOtherInItsPlace
- Suspend Page on one page of a split → that page leaves the split and sleeps; the other stays shown.
  Test: SidebarRowMenuTests.onePageOfASplitSleepsAndTheOtherStaysShown
