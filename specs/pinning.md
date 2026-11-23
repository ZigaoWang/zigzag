# Pinning

## Pinning a page
- ⌘D, the star at the end of the address, or Pin Tab in a tab's menu → the page goes to the end of the space's Pinned pages, in no folder, with no question.
  Test: SavePathTests.aQuickSaveFromEachPathLandsAtTheEndOfPinned
- ⌘D or the star on a page that's pinned → it's unpinned; the star shows which at once.
  Test: SavePathTests.theQuickSaveTogglesAndTheStarFollows
- Pin or unpin from a tab's menu, by a drag or with ⌘Z → the star shows it at once too.
  Test: SavePathTests.theStarFollowsAPinMadeFromTheRow
- Pin a page that's already pinned → it's filed where asked, never a second copy.
  Test: SavePathTests.savingAgainNeverMakesASecondCopy
- Pin Link in a link's right-click menu → the link is pinned at the end of Pinned without being opened.
  Test: SavePathTests.aQuickSaveFromEachPathLandsAtTheEndOfPinned
- ⌘D or Pin Group on a tab in a group → the whole group is pinned as one folder named after it; one ⌘Z brings the group back.
  Test: PinnedGroupTests.commandDSavesTheWholeGroupAndUndoes
- Pin Split View on a page of a split → both pages are pinned and stay a split.
  Test: SavePathTests.aSplitViewMovesAsOne
- Pin Tab or Pin Tab to Folder… in the menu bar on Settings or History → off, as the star isn't there.
  Test: SavePathTests.theMenuBarsPinFollowsTheStarsRule

## Asking where
- ⇧ on the star, on a menu's Pin, on Pin Link, or ⇧⌘D → a sheet asks for the folder and the name.
  Test: SavePathTests.shiftOnEveryPathAsksWhere
- A key you gave Pin Tab in Settings that holds ⇧ → pins and unpins like ⌘D, never asks.
  Test: SavePathTests.pinTabsOwnKeysNeverAsk
- The sheet → offers Top of Pinned, the folders of the space you're in (never another space's) and New Folder…, opening on the last folder you used there.
  Test: SavePathTests.thePickerOffersOnlyThisSpacesFolders
- The sheet's title → Pin Page, Pin Split View or Pin Group; a page or split also gets an Add to Favorites switch, a group doesn't.
  Test: SavePathTests.thePickerNamesWhatItPins

## The Pinned toast
- After a pin → a Pinned toast whose menu lists Add to Favorites, Top of Pinned and the space's folders, ticked where the pin is, then New Folder… and Unpin Tab.
  Test: SavePathTests.thePlaceMenuTicksWhereThePageIs
- A move from that menu → it moves that pin in the space it was made in, even after you switch spaces; each move is one ⌘Z.
  Test: SavePathTests.theToastMovesItsOwnPinInItsOwnSpaceUndoably
- A pinned group moved from the toast or the sheet → its whole folder moves; it's never offered its own folder or Favorites.
  Test: SavePathTests.aPinnedGroupMovesAsItsFolder

## Folders
- New Folder in a space's menu, Add to New Folder on a pinned page, or New Folder Inside on a folder → a folder named New Folder, ready to rename.
  No test yet.
- Open All in Tabs on a folder → every page in it and its subfolders opens as new tabs in list order, the first shown; past 10 it asks first; ⌘Z closes them.
  Test: FolderBulkTests.openAllOpensThePagesAsNewTabsInOrderAndUndoes
- Expand All / Collapse All on a folder → it and every folder inside it; each is offered only when it would change something.
  Test: ArcFolderTests.expandAndCollapseAllReachEveryLevel
- Collapse All Folders / Expand All Folders in a space's menu → all of that space's folders at once.
  Test: FolderBulkTests.aSpacesFoldersFoldAtOnceWithTheMenuOfferingOnlyWhatChanges

## Importing from Arc
- Arc's folders inside folders → the same tree in Pinned, in Arc's order with their names, shut; empty ones stay behind.
  Test: ArcFolderTests.nestedFoldersKeepTheirTreeAndOrder
- A split view pinned in Arc, at the top or in a folder → a pinned split view of the same pages, up to four.
  Test: ArcFolderTests.pinnedSplitViewsStaySplit
- Folders nested deeper than eight levels → their pages go in the eighth folder; none is left out.
  Test: ArcFolderTests.foldersDeeperThanTheLimitKeepTheirPages
- Importing again into a space from an earlier import → its pages still side by side in one folder become Arc's split views again; nothing is added twice.
  Test: ArcFolderTests.importingAgainGainsSplitViews
- Importing again where those pages were moved apart or into another folder → they stay where they are, not split.
  Test: ArcFolderTests.importingAgainLeavesMovedPagesApart

## Favorites
- Add to Favorites on a pinned page → it shows in Favorites in every space of its profile, as the same page, not a copy.
  Test: SavePathTests.inEverySpaceIsATickOnASavedPage
- A favorite moved into a space's Pinned or a folder → it leaves Favorites; a page is never both.
  Test: SavePathTests.aFavoriteFiledInASpaceLeavesFavorites
- Move to Tabs on a favorite → it becomes a tab of the space you're in; Remove from Favorites → it's gone and its page closes.
  No test yet.

## Pinned tabs
- ⌘W on a pinned tab → it unloads and stays pinned.
  No test yet.
- A pinned tab that wandered off its address → its menu leads with Back to Pinned Page, Set Current Page as Pinned and Separate from Pinned Tab.
  Test: SidebarRowMenuTests.aPinnedPageThatWanderedOffLeadsWithGoingBackOrKeepingIt
- The × on a pinned tab that wandered off → it says Back to Pinned Page and goes back; a middle-click still unloads.
  No test yet.
- Unpin Tab → it goes back among the tabs, at the top; Remove Pinned Page → it's gone and its page closes, with Undo on the toast.
  No test yet.
- Unpin a page of a pinned group → the whole group comes back as a group of tabs.
  Test: PinnedGroupTests.pinningAGroupOfTabsKeepsItWholeAsOneFolder

## Private windows
- Pin from a private window, any way in → nothing is pinned; Pin Link isn't in a link's menu there.
  Test: SavePathTests.aPrivateWindowWritesNothing
- A private window's tab menu → no Pin Tab or Add to Favorites.
  Test: SidebarRowMenuTests.aPrivateWindowsTabKeepsOutOfSavesAndWindows
- A pinned page or favorite in a private window → no Add to Favorites, Rename or Change Icon, and File › Add to Favorites is off.
  Test: SidebarRowMenuTests.aPrivateWindowNeitherFavoritesNorRenamesYourPins
- Pinned pages and folders in a private window → no filing, moving or folder edits in their menus, and dragging them changes nothing.
  Test: SidebarRowMenuTests.aPrivateWindowLeavesYourPinsWhereTheyAre
