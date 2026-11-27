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
- A shut folder → it still shows the page you're on and its pages opened since it was shut, never the ones open when you shut it.
  Test: ShutFolderRowsTests.thePageYouAreOnStillShows
  Test: ShutFolderRowsTests.aPageOpenedSinceItWasShutShows
  Test: ShutFolderRowsTests.shuttingHidesThePagesOpenThen
- ⌘W or the × on a page shown under a shut folder → its row stays there, unloaded. It goes once you switch to another space, open or shut that folder again (Expand All and Collapse All too) or relaunch.
  Test: ShutFolderClosedPinTests.aClosedPageStaysUnderItsShutFolderUntilYouLeaveTheSpace
  Test: ShutFolderClosedPinTests.aClosedPageGoesWhenItsFolderIsOpenedAndShutAgain
  Test: ShutFolderClosedPinTests.anotherFolderOpenedOrShutKeepsTheClosedPage

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

## Importing from Dia
- Spaces and Pinned Tabs and Bookmarks from Dia → each Dia profile's pinned tabs are pinned in the space its bookmarks go in, in Dia's order; its favorites become favorites.
  Test: DiaImportTests.pinnedTabsAndFavoritesComeOver
- A split view pinned in Dia → a pinned split view of the same pages, up to four.
  Test: DiaImportTests.splitTabsStaySplit
- Tabs that aren't web pages and parts of Dia's sidebar Zigzag doesn't know → stay behind; the rest still comes over.
  Test: DiaImportTests.unknownPartsStayBehind
- Importing from Dia again → nothing is added twice.
  Test: DiaImportTests.importingAgainAddsNothingTwice

## Favorites
- Add to Favorites on a pinned page → it shows in Favorites in every space of its profile, as the same page, not a copy.
  Test: SavePathTests.inEverySpaceIsATickOnASavedPage
- A favorite moved into a space's Pinned or a folder → it leaves Favorites; a page is never both.
  Test: SavePathTests.aFavoriteFiledInASpaceLeavesFavorites
- A tab's menu in a group that can't be pinned whole (Settings is in it) → still offers Add to Favorites, as the menu bar and the command bar do.
  Test: SidebarRowMenuTests.aTabOfAnUnpinnableGroupStillAddsToFavorites
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
- The pinned section folded with the chevron by the space's name → only the pinned pages that are open and the page you're on show, each under the folders on its way.
  Test: PinnedGroupTests.foldedPinsShowOpenPagesUnderTheirFolders
- ⌘W or the × on a pinned page in a folded section → its row stays, unloaded, under its folders; a click opens it in place. It goes once you switch to another space, fold the section again or relaunch.
  Test: PinnedGroupTests.aClosedPinStaysInAFoldedSectionUntilYouLeaveTheSpace
  Test: PinnedGroupTests.aClosedPinInAFoldedSectionGoesWhenItsFoldedAgain
  Test: PinnedGroupTests.aClosedPinInAFolderStaysUnderItInAFoldedSection

## Private windows
- Pin from a private window, any way in → nothing is pinned; Pin Link isn't in a link's menu there.
  Test: SavePathTests.aPrivateWindowWritesNothing
- A private window's tab menu → no Pin Tab or Add to Favorites.
  Test: SidebarRowMenuTests.aPrivateWindowsTabKeepsOutOfSavesAndWindows
- A pinned page or favorite in a private window → no Add to Favorites, Rename or Change Icon, and File › Add to Favorites is off.
  Test: SidebarRowMenuTests.aPrivateWindowNeitherFavoritesNorRenamesYourPins
- Pinned pages and folders in a private window → no filing, moving or folder edits in their menus, and dragging them changes nothing.
  Test: SidebarRowMenuTests.aPrivateWindowLeavesYourPinsWhereTheyAre

## Live folders
- New Live Folder… in the sidebar's +, its empty space, a space's menu or a folder's menu → a sheet for a feed or site address, or a GitHub list and username; the folder is named after the feed unless you name it.
  Test: SidebarMenuTests.plusOffersTabFolderThenSpace
- A site's address instead of its feed's → the feed its page links to is found, used and kept.
  Test: LiveFoldersTests.aSitesAddressFindsItsFeed
- A live folder → its feed's pages, newest first, at most its count (10, 25 or 50), each new one with a dot.
  Test: LiveFoldersTests.aFetchFillsTheFolderNewestFirstWithDots
- A GitHub live folder → one of five lists for a username: pull requests opened, issues assigned, review requests, or the open issues or pull requests in repositories they own, whoever opened them.
  Test: LiveFeedTests.asksGitHubForTheListsOfAUser
- A live folder in the sidebar → its site's icon (GitHub's for a GitHub list) with a small live chip; the plain folder with the chip until an icon is there.
  Test: LiveFoldersTests.itWearsItsSitesIcon
- Opening one of its pages → it opens in place as a pinned page does, and its dot goes; Mark All as Read takes every dot off. A private window shows no live folders and reads nothing.
  Test: LiveFoldersTests.openingAPageReadsIt
- A page that leaves the feed and comes back → it isn't new again.
  Test: LiveFoldersTests.newPagesAreUnreadOnceAndStayReadWhenTheyComeBack
- Feeds are fetched every half hour in the background, at most hourly in Low Power Mode, and later and later after failures; each fetch asks only for what changed.
  Test: LiveFoldersTests.fetchesEveryHalfHourAndBacksOffAfterFailures
- A feed that hasn't changed → nothing in the pins changes, so ⌘Z still undoes what you did last.
  Test: LiveFoldersTests.fetchesAgainOnlyForWhatChanged
- A fetch that fails → no alert; the folder's menu says Couldn’t Refresh with the reason and Try Again.
  Test: SidebarRowMenuTests.aLiveFoldersMenuReadsRefreshesEditsAndDeletes
- Dragging a page out of a live folder → it's pinned where it's dropped, and the folder keeps its own; nothing can be dropped into one.
  Test: LiveFoldersTests.itsPagesAreItsFeedsAlone
- Delete Live Folder → the folder and its pages go; ⌘Z brings them back.
  Test: SidebarRowMenuTests.aLiveFoldersMenuReadsRefreshesEditsAndDeletes
- A GitHub list → open pull requests, issues or review requests in public repositories for that username; when GitHub asks to wait, it waits.
  Test: LiveFoldersTests.gitHubListsComeFromItsSearchAndWaitWhenAsked
- A live folder's menu → first a line that can't be clicked saying when it last fetched, like Updated 5 Minutes Ago, or Updating… while it fetches; the last good time stays after a failure and is kept on disk.
  Test: LiveFoldersTests.itSaysWhenItWasLastUpdated
- Refresh Now in a live folder's menu → it fetches at once, and its menu says Updating… until it's done.
  Test: SidebarRowMenuTests.aLiveFoldersMenuSaysWhenItWasUpdated
- A live folder's menu open while it fetches → its first line follows the fetch without the menu closing, Updating… then Updated Just Now, or Couldn’t Refresh with Try Again; Mark All as Read turns on when new pages come; the item under the keys stays lit.
  Test: SidebarRowMenuTests.anOpenLiveFoldersMenuFollowsItsFetch
- While a live folder fetches → the chip on its icon's corner shows a turning ring in place of the feed mark, standing still with Reduce Motion, and the feed mark again the moment the fetch ends, done or failed; nothing turns while it's idle.
  Test: SidebarRowMenuTests.aLiveFoldersRowSpinsOnlyWhileItFetches
- The New and Edit Live Folder sheet → the source first (address, or username then list), then name and count, each control as wide as the fields; a note under them says what the folder shows and that it checks every 30 minutes, hourly in Low Power Mode; an empty name shows the name it will get; a username GitHub can't have is marked and keeps the button off.
  Test: SidebarRowMenuTests.theLiveFolderSheetSaysWhatItShowsAndHowOften
- The New and Edit Live Folder sheet's icon → the folder's own, as its sidebar row shows it (a chosen icon, else its site's), the feed mark while a new one has no source yet; clicking it opens the grid Change Icon… opens, and the icon picked there is kept on Save or Add.
  Test: SidebarRowMenuTests.theLiveFolderSheetsIconIsTheFoldersAndChangesIt

## Pinned tabs as tiles
- Settings › Appearance › Pinned tabs as tiles, off by default → pinned pages are rows under the space's name.
  Test: AppearanceSwitchesTests.pinnedTabsAreRowsUntilTurnedOn
- On → the pinned pages in no folder are tiles under the favorites, in the same grid, a fine line between the two; folders and their pages stay rows; ⌘1–⌘9 and ⌥⌘↓ count the tiles after the favorites. The choice is kept.
  Test: AppearanceSwitchesTests.onPagesOutsideFoldersAreTilesUnderTheFavorites
- A tile → a click opens it, × or a middle-click unloads it, and right-click has the pinned tab's menu.
  Test: AppearanceSwitchesTests.aTileOpensUnloadsAndHasThePinnedTabsMenu
- Drag a tile among the tiles → it moves among the pinned pages, in one ⌘Z; out of the grid it goes into a folder, among the tabs, into Favorites, onto a space or another window, as its row would.
  Test: AppearanceSwitchesTests.draggingATileReordersThePinnedPages
- A row dropped between tiles → pinned there, out of any folder; on a tile's middle, the two open side by side.
  Test: AppearanceSwitchesTests.aFoldersPageDroppedOnTheTilesIsPinnedThereOutOfItsFolder
- A favorite dropped between tiles → pinned there; it leaves Favorites.
  Test: AppearanceSwitchesTests.aFavoriteDroppedOnTheTilesIsPinnedThereAndLeavesFavorites
- A pinned split → one tile with its pages; with the pinned section folded, only the open tiles and the page you're on show.
  Test: AppearanceSwitchesTests.aPinnedSplitIsOneTileAndAFoldedSectionKeepsOnlyOpenOnes
- A slot between tiles → the place before that tile's first page among the pinned pages, or after the last tile.
  Test: AppearanceSwitchesTests.aTilesSlotIsAPlaceAmongThePinnedPages
