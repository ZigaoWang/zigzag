# Site Controls

## The first page
- Site Controls on a web page → top down: the site's name, its connection on a row under it, the page's actions, This Site, the lines into its other pages, then your extensions.
  Test: SitePanelLayoutTests.theFirstPageReadsTopDown
- This Site → Zoom, Ad blocking, Cookie banners, Dark page, Keep cookies and Always translate where they apply, a row for each permission the site asked for or has an answer kept, then Compatibility mode last.
  Test: SitePanelRowsTests.everydaySwitchesFirstAndTheRestOnMore
- A permission the site asked for → its row in This Site too; a choice there is the one the Permissions page shows.
  Test: SitePanelLayoutTests.anAskedPermissionIsOnTheFirstPageToo
- Opened by a finger → its rows 44 points tall; opened by the mouse, as before.
  Test: SitePanelLayoutTests.aFingerGetsTallRows

## More for This Site
- Keep tabs awake, User agent, Keep full screen in the window, Apps on this Mac and Open in → on More for This Site, a page of the panel with a way back, its line on the first page whenever one of them applies.
  Test: SitePanelLayoutTests.theRareChoicesAreOnTheirOwnPage
- A switch or choice there → kept for the site at once, as on the first page.
  Test: SitePanelLayoutTests.eachControlOnMoreStillWorks

## Extensions
- Your extensions in Site Controls → pinned ones first, then those that work on this site, then the rest, by name in each.
  Test: SiteExtensionsTests.pinnedAndWorkingOnesComeFirst
