# History

## The list
- History → pages newest first under one heading per part of a day ("This morning", "Yesterday evening"); a heading never shows twice in a row.
  Test: HistoryClustersTests.aBreakEndsAStackAndEachPartOfTheDayHasOneHeading
- Three or more pages in a row on one site → one stack, with its page count and time span; a break of over 40 minutes ends a stack.
  Test: HistoryClustersTests.aBreakEndsAStackAndEachPartOfTheDayHasOneHeading
- Two pages in a row on one site → two rows, never a stack.
  Test: HistoryClustersTests.runsOfTwoStayRows
- A page with no title → named by its file name, else its site.
  Test: HistoryStoreTests.aPDFIsListedByItsFileName

## Search
- Words typed → pages with every word in the title or address, in any order, ignoring case, accents and full-width letters.
  Test: HistoryPageTests.searchMatchesEveryWordInAnyOrderInTitleOrAddress
- Chinese typed → found in titles, and in addresses, which are read decoded.
  Test: HistoryPageTests.searchFindsChineseInTitlesAndAddresses
- Matches → newest first, at most 1,000, each a row of its own: never folded in a stack.
  Test: HistoryPageTests.searchListsMatchesNewestFirst
  Test: HistoryClustersTests.searchResultsAreNeverStacked
- A search → the words typed are marked in each match, the first match is chosen, and Return opens it.
  Test: HistoryPageTests.searchNeverHidesAMatchInAStack
- A search over 50,000 pages → each one after the first answers in under a quarter of a second.
  Test: HistoryPageTests.searchOverFiftyThousandPagesStaysQuick

## Keyboard and pointer
- ↓ from the search field → the first row is chosen; ↑ and ↓ walk the rows, ⇧ adds to the choice, ↑ from the top goes back to the field.
  Test: HistoryPageTests.arrowsChooseExtendAndOpenStacks
- → on a stack → it opens; ← closes it, or goes from a page to its stack.
  Test: HistoryPageTests.arrowsChooseExtendAndOpenStacks
- Delete → the chosen rows (a stack: all its pages) leave History, the next row is chosen, and ⌘Z brings them back.
  Test: HistoryPageTests.deleteRemovesTheChosenAndCommandReturnOpensThem
- ⌘Return → the chosen pages open in tabs behind this one; typing on a row goes to the search field.
  Test: HistoryPageTests.deleteRemovesTheChosenAndCommandReturnOpensThem
- ⇧-click → every row from the last one chosen is chosen; ⌘-click opens the page in a tab behind, as on any page.
  No test yet.
- ⌘F → the History page's search field, not the find bar.
  No test yet.
- Right-click on a row → the link's own items, then Remove from History and Remove All Pages from the site.
  No test yet.
- Remove All Pages from a site → every page on it goes, with or without "www.", and ⌘Z brings them back.
  Test: HistoryPageTests.removingASiteTakesAllItsPagesAndComesBack

## Look
- History and the Archive → light or dark with the window, as Settings is, never with the Mac alone, and never darkened as a web page.
  Test: HistoryPageTests.ownPagesFollowTheWindow
