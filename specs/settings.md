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
- The link address never takes a click meant for the link under it → the pill is not part of hit testing, so the press reaches the page and the link opens, and hovering that link still reports it, in every window that shows the pill.
  Test: LinkStatusHitTests.aPressOnThePillReachesThePageUnderIt
  Test: LinkStatusHitTests.whereThePillStepsAsideThePressStillReachesThePage
- The pointer over the link address → the pill steps aside, faded back to a quarter, so the link under it reads and shows through; off it, or with the link under it changed, it comes back whole. The fade and the pass-through are one behaviour: it never fades while still taking the click.
  Test: LinkStatusHitTests.thePillStepsAsideWhileThePointerIsOverIt
  Test: LinkStatusHitTests.aStepAsideHoldsWhileThePointerStaysOnIt
  Test: LinkStatusHitTests.aPillPutAwayComesBackWhole
- Show link address on hover off → nothing shows in that corner while pointing at a link; the choice is kept.
  Test: AppearanceSwitchesTests.offNoLinkAddressShowsAndTheChoiceIsKept
- Shorter floating sidebar, off by default → the sidebar that comes out over the page while hidden runs the window's height, a frame's inset from its edges.
  Test: AppearanceSwitchesTests.theFloatingSidebarIsFullHeightUntilTurnedOn
- Shorter floating sidebar on → it's two thirds of the window's height with a sixth free above and below, the same card; docked, it runs the window's height. It comes and goes as before, and the traffic lights stay out of it.
  Test: AppearanceSwitchesTests.onTheFloatingSidebarIsTwoThirdsHighInTheMiddle
- Shorter floating sidebar → the choice is kept.
  Test: AppearanceSwitchesTests.theShorterFloatingSidebarIsKept
