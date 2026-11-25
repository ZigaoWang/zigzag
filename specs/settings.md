# Settings

## Panes
- Settings opened on one pane → only that pane's rows are made; another pane's are made the first time it's shown or searched.
  Test: SettingsLazyBuildTests.openingOnGeneralMakesNoRowsForTheOtherPanes

## Boxes that fold
- A folded box → its rows are made the first time it opens, or when a search has words they could match; a box with nothing inside has no chevron.
  Test: FoldBoxTests.aFoldedBoxMakesNothingUntilOpenedOrSearched
- Sites in Developer Mode, Trusted Certificates or Page Sizes with more than three → one box headed by how many, folded; Find a setting opens it to the rows that match.
  Test: SettingsFoldingTests.findASettingReachesAFoldedRowAndOpensItsBox
- Feature Flags in Settings › Developer → a box for each kind (Stable, Preview and the rest), headed by how many flags it has, folded when it has more than three; its own search opens the boxes to the flags that match.
  No test yet.

## Appearance
- Show link address on hover, on by default → pointing at a link shows where it goes in the page's bottom-left corner: in browser windows, Zigzag Mini, web apps and the tab overview.
  Test: AppearanceSwitchesTests.theLinkAddressShowsUntilTurnedOff
- Show link address on hover off → nothing shows in that corner while pointing at a link; the choice is kept.
  Test: AppearanceSwitchesTests.offNoLinkAddressShowsAndTheChoiceIsKept
