# Settings

## Panes
- Settings opened on one pane → only that pane's rows are made; another pane's are made the first time it's shown or searched.
  Test: SettingsLazyBuildTests.openingOnGeneralMakesNoRowsForTheOtherPanes
  Test: EverydayFlowsTests.settingsOpensOnEachPane

## Boxes that fold
- A folded box → its rows are made the first time it opens, or when a search has words they could match; a box with nothing inside has no chevron.
  Test: FoldBoxTests.aFoldedBoxMakesNothingUntilOpenedOrSearched
- Sites in Developer Mode, Trusted Certificates or Page Sizes with more than three → one box headed by how many, folded; Find a setting opens it to the rows that match.
  Test: SettingsFoldingTests.findASettingReachesAFoldedRowAndOpensItsBox
- Data from more than three profiles that are no longer listed, in Settings › Profiles → one box headed by how many, folded; Settings opens on Profiles at once however many there are.
  Test: SettingsUnlistedTests.manyUnlistedProfilesFoldIntoOneBoxAndShowAtOnce
- Feature Flags in Settings › Developer → a box for each kind (Stable, Preview and the rest), headed by how many flags it has, folded when it has more than three; its own search opens the boxes to the flags that match.
  No test yet.

## Appearance
- Show link address on hover, on by default → pointing at a link shows where it goes in the page's bottom-left corner: in browser windows, Zigzag Mini, web apps and the tab overview.
  Test: AppearanceSwitchesTests.theLinkAddressShowsUntilTurnedOff
- Show link address on hover off → nothing shows in that corner while pointing at a link; the choice is kept.
  Test: AppearanceSwitchesTests.offNoLinkAddressShowsAndTheChoiceIsKept
- Shorter floating sidebar, off by default → the sidebar that comes out over the page while hidden runs the window's height, a frame's inset from its edges.
  Test: AppearanceSwitchesTests.theFloatingSidebarIsFullHeightUntilTurnedOn
- Shorter floating sidebar on → it's two thirds of the window's height with a sixth free above and below, the same card; docked, it runs the window's height. It comes and goes as before, and the traffic lights stay out of it.
  Test: AppearanceSwitchesTests.onTheFloatingSidebarIsTwoThirdsHighInTheMiddle
- Shorter floating sidebar → the choice is kept.
  Test: AppearanceSwitchesTests.theShorterFloatingSidebarIsKept

## Installed Apps
- An installed app on a disk that isn't connected → it stays in Settings › General › Installed Apps and in what's saved, marked On a disk that isn't connected, with Open and Show in Finder off until the disk is back.
  Test: WebAppTests.anAppOnADiskThatIsntConnectedStaysListed
- A folder of apps linked to a disk that isn't connected, like ~/Applications on an external disk → its apps count as on that disk and stay listed.
  Test: WebAppTests.aFolderLinkedToADiskThatIsntThereCounts
- A disk connected or ejected → the list updates at once; an app back on its disk works again.
  Test: WebAppTests.connectingOrEjectingADiskUpdatesTheList
- An installed app deleted from a disk that is connected, or from the startup disk → it leaves the list the next time Settings shows it.
  Test: WebAppTests.anAppGoneFromAConnectedDiskLeaves
