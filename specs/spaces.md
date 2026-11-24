# Spaces

## Making and switching
- New Space (⌥⌘N, or + in the sidebar) → a space at once, in the next unused palette color on glass (Slate, Fern, Coral first), with its editor open to name it.
  Test: SpaceDefaultColorsTests.defaultIsTheColorTheSpaceWasMadeWith
- ⌃1–⌃9 → that space; a number with no space does nothing.
  Test: NumberHintsTests.spaceNumbersGoToTheirOwnSpaceAndNinthIsTheNinth
- ⌥⌘→ / ⌥⌘← → next or previous space, stopping at the ends.
  Test: MenuShortcutsTests.optionCommandArrowsGoThroughTheSpacesAndStopAtTheEnds
- Swipe sideways on the sidebar → the next space slides in with your fingers, its color blending in; calling it off goes back.
  Test: SpaceSwitchLookTests.aSwipeBlendsWithTheFingersAndCallingItOffGoesBack
- Switch spaces → the window takes the new space's color before its page shows.
  Test: SpaceSwitchLookTests.aSwitchSaysTheSpaceBeforeThePage

## Colors and looks
- Use Default Colors in the space editor → the colors it was made with come back; its name, icon and pages stay.
  Test: SpaceDefaultColorsTests.useDefaultColorsPutsBackANewSpacesLook
- See-through above 0 → the desktop shows through and the color thins, never below half; with Reduce Transparency on, it stays solid.
  No test yet.
- Glass in the editor → Clear or Frosted, shown only for a see-through space on macOS 26 and later; Clear is the default.
  No test yet.
- Frosted → the window stays opaque; only clear glass makes it see-through.
  Test: SidebarSlideTests.onlyClearGlassMakesTheWindowSeeThrough
- Clear on battery or in Low Power Mode → shows frosted instead, and the editor says why under Glass until you plug in or turn it off.
  Test: SidebarSlideTests.theEditorSaysWhenClearShowsAsFrosted
- Pick a preset with a finish (Stone's linen, Smoke's or Coral's grain) → the finish comes with it; a plain preset takes it off.
  Test: SpacePaletteTests.aPresetBringsItsFinishAndAPlainOneTakesItOff

## Icons in the bottom bar
- Give a space an icon, a symbol or an emoji → its key shows it, with no dot under it.
  Test: SpaceSwitchLookTests.aSpaceKeyWithAnIconHidesItsDot
- Many spaces → the keys narrow down to the icon's size, then the row scrolls.
  Test: SpaceIconSizeTests.manySpacesScrollBeforeIconsShrink
- Drag a space's key along the bar → the space moves where the bar showed.
  Test: SpaceReorderTests.aDropMovesTheSpaceWhereTheBarShowed
- Hover or press a space key → the same washes as the toolbar's buttons; a press shrinks it in place.
  Test: SpaceSwitchLookTests.aSpaceKeyHoversAndPressesInPlace

## Sites that open in a space
- Rules in Settings › Spaces → tried top to bottom; the first enabled rule that matches wins.
  Test: SiteRoutesTests.reorderingChangesWinnerAndWarningsTogether
- Path and subpaths → matches whole segments on that one host, with or without www.; "github.com/org1" doesn't take /org10 or gist.github.com.
  Test: SiteRoutesTests.aPathRuleCoversTheSitesWWWAddress
- A port in a rule (localhost:3000) → accepted but dropped; the rule covers every port.
  Test: SiteRoutesTests.portsAreAcceptedButDoNotRestrictTheRule
- Type an address, click a link, or open one from another app → it opens in its rule's space, unless you're already there.
  Test: SiteRoutesTests.whatYouDoYourselfIsRouted
- A redirect, script, frame, form, pop-up, back, forward or reload → stays where it is.
  Test: SiteRoutesTests.whatThePageDoesOnItsOwnIsNot
- A link to a sign-in page → stays in the tab that sent you; typed, it still goes to its space.
  Test: SiteRoutesTests.aSignInALinkSendsYouToStaysPut
- Click a link that opens a new tab or window in an embed from another site (Watch on YouTube) → it opens in its rule's space.
  Test: SiteRoutesTests.anEmbedsClickedNewWindowIsRoutedLikeALink
- Private windows, Zigzag Mini and site apps → never sent anywhere; Open in Zigzag from Mini is.
  Test: SiteRoutesTests.miniAndAppsKeepTheirPages

## Profiles
- New Profile in the space editor → a profile named after the space, holding only that space.
  Test: SpaceProfileTests.aNewProfileForASpaceIsNamedAfterItAndHoldsIt
- Give new spaces their own profile in Settings › Spaces → off by default; on, each new space gets a profile with its name and color.
  Test: SpaceProfileTests.aNewSpaceCanComeWithItsOwnProfile
- Only one profile → no space names it; with two or more, every space says which it's on.
  Test: SpaceProfileTests.withOneProfileNothingNamesIt

## Sidebar
- Sidebar position in Settings › Appearance, or View › Move Sidebar to Right → Left or Right; Left until changed.
  Test: SidebarSideTests.sidebarPositionIsALeftRightMenuOnTheSamePreference
- Sidebar size in Settings › Appearance → Small, Medium, Large or Custom, a whole percentage from 80 to 150.
  Test: SplitRowAlignmentTests.theCustomSizeIsAWholePercentageWithinItsRange
- ⌃S → hides the sidebar, or shows it; while it's hidden, its toggle sits in the bar above the page.
  Test: TopBarTests.theSidebarsToggleIsInTheBarOnlyWhileTheSidebarIsHidden
- Pointer at the sidebar's edge of the window while it's hidden → it slides out once, and back when you leave it.
  Test: SidebarEdgeRevealTests.runningOnPastTheEdgeAndComingBackBringsItOutOnce
- Hover and press on sidebar rows and buttons → visible on every space color, white and black included, light and dark.
  Test: ContrastTokensTests.hoverShowsOnEverySpace
