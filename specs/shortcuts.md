# Shortcuts

## Tabs and windows
- ⌘T → the command bar opens for a new tab; ⌘T again closes it.
  Test: MenuShortcutsTests.commandTOpensTheNewTabBarAndAgainClosesIt
  Test: EverydayFlowsTests.commandTThenCommandWGoesBackToTheTabYouWereOn
- ⌘N → a new window; with no window open, the last closed one comes back instead.
  No test yet.
- ⇧⌘N → a new private window.
  No test yet.
- ⌘W → closes the command bar, the overview card, floating content or the picked rows if one is up, else the tab (undoable); ⇧⌘W closes the window, ⌥⌘W the other tabs.
  Test: MenuShortcutsTests.commandWClosesWhatIsUpFirstThenTheTab
- ⇧⌘T → the most recently closed tab or window comes back, across all windows.
  Test: ReopenLastClosedTests.theLatestClosedComesBackFirst
  Test: EverydayFlowsTests.shiftCommandTBringsBackAClosedWindow
- ⌥⌘↓ / ⌥⌘↑ (or ⇧⌘] / ⇧⌘[) → next or previous row as the sidebar shows it, wrapping, staying in the space.
  Test: TabNavigationTests.goesDownTheSidebarAndWraps
- ⌥⌘→ / ⌥⌘← → next or previous space, stopping at the ends.
  Test: MenuShortcutsTests.optionCommandArrowsGoThroughTheSpacesAndStopAtTheEnds
- With Settings › Tabs › Vim keys on, ⌃J / ⌃K → next or previous row, ⌃H / ⌃L → previous or next space, beside the keys above; with the command bar open, ⌃J / ⌃K step its list instead. Off by default, and then the keys are the page's.
  Test: TabNavigationTests.vimKeysGoThroughTabsAndSpacesWhenOn
- ⌃Tab / ⌃⇧Tab → recent-tabs switcher by default; sidebar order when Settings › Tabs says so.
  Test: TabNavigationTests.controlTabFollowsTheSetting
- ⌘1–⌘8 → that row of the sidebar; ⌘9, or a number past the end → the last row.
  Test: NumberHintsTests.numbersGoToTheirPlaceAndNineToTheLast
- ⌃1–⌃9 → that space; ⌃9 is the ninth, and a number with no space does nothing.
  Test: NumberHintsTests.spaceNumbersGoToTheirOwnSpaceAndNinthIsTheNinth
- Hold ⌘ or ⌃ a moment → the numbers show; pressing their own number keys keeps them up while the key is held, and any other key, a click or letting go hides them.
  Test: NumberHintsTests.theNumbersOwnKeysKeepThemShown
- ⌘Y → History, and ⌘, → Settings, each opens as a tab in the front window.
  No test yet.

## Page
- ⌘L → the command bar opens over the address with the current URL selected; Return on it unchanged reloads.
  Test: MenuShortcutsTests.commandLSelectsTheAddressAndReturnUnchangedReloads
  Test: EverydayFlowsTests.typingAnAddressAndReturnLoadsItInTheTab
- ⌘R → reload. ⇧⌘R → reload ignoring the cache.
  Test: DeveloperToolTests.shiftCommandRReloadsIgnoringTheCache
- ⌥⌘R → Reader on or off; on a loading page it waits, and ⌥⌘R again on that tab cancels the wait.
  Test: ReaderWaitTests.onlyTheSameTabCallsTheWaitOff
  Test: EverydayFlowsTests.readerComesOnOverThePageAndGoesOff
- ⌘[ / ⌘] (or ⌘← / ⌘→ when nothing is being edited) → back and forward.
  Test: MenuShortcutsTests.commandBracketsGoBackAndForward
- ⌘F → the find bar; ⌘F again with its field focused hides it.
  Test: MenuShortcutsTests.commandFShowsTheFindBarAndAgainHidesIt
  Test: EverydayFlowsTests.findInPageCountsWhatIsTyped
- ⌘G / ⇧⌘G → next or previous match, opening the find bar if it's closed.
  Test: FindCountTests.findNextWithTheBarClosedStepsOnce
- ⌘D → Pin Tab: pins the page to the end of the space's pinned pages without asking.
  Test: MenuShortcutsTests.commandDPinsAtTheEndOfPinnedWithoutAsking
- ⇧⌘D → Pin Tab to Folder: always asks which folder of the space and what name.
  Test: SavePathTests.shiftOnEveryPathAsksWhere
- ⌘+ (or ⌘=) / ⌘− → zoom in or out by steps, saved per site; ⌘0 → back to the default page zoom in Settings.
  Test: ZoomStepperTests.stepsInAndOutThroughTheLevels
- ⌘P → print; a PDF prints as itself.
  No test yet.
- ⌘S → Save Page As: a web archive, or the file itself for a PDF, image or text.
  No test yet.
- ⌘O → pick a file; it opens in a new tab.
  No test yet.
- ⌥⌘I (or F12) → Web Inspector opens, or closes if open.
  Test: DeveloperToolsTests.developerMenuHasChromesKeys
- ⇧⌘2 → Capture dims the page; ⇧⌘2 again or Esc leaves it, and so does going to another tab.
  Test: MenuShortcutsTests.shiftCommandTwoOpensCaptureAndEscLeaves
- In Capture, a drag → an area kept inside the page, moved and resized by its grips, turning over past an edge.
  Test: PageCaptureGeometryTests.gripsResizeAndTurnOver
- In Capture's Element mode, a click → the element whole: as shown, scrolled into view and back, or drawn in one piece when it's taller than the window.
  Test: PageCaptureGeometryTests.anElementIsTakenWholeEvenOffScreen
- Capture… in the command bar → offered on a page that can be captured, found by "capture" or "screenshot".
  Test: CommandActionTests.captureIsOfferedWhereThePageCanBeTaken

## Custom shortcuts
- Give an item keys in Settings › Shortcuts that another item had → yours win, and the other item has no shortcut.
  No test yet.
- Update to a version that ships an item on keys you gave to something else → that item comes in without them.
  Test: DeveloperToolTests.shippedKeysYouGaveAwayStayYours
- Press a ⌘ key a page also uses (⌘S, ⌘[) → the page gets it first, and the menu only if the page doesn't take it.
  Test: PageShortcutsTests.everythingElseIsThePagesFirst
- Press a tab, window or address key on a page (⌘T, ⌘W, ⇧⌘T) → it always goes to the browser.
  Test: PageShortcutsTests.theBrowsersOwnKeysStayItsOwn
- Press ⌥⌘← or ⌥⌘→ on a page that uses those keys → the space still switches.
  Test: PageShortcutsTests.theSpaceKeysStayTheBrowsers
- Close Tabs Below in Settings › Shortcuts → listed, though it has no menu bar line or keys, and takes keys of yours.
  Test: SettingsSearchTests.closeTabsBelowCanHaveAShortcut
- Settings › Shortcuts → a box for each menu, headed by its name and how many shortcuts it has, folded when more than three menus are listed.
  Test: SettingsLazyBuildTests.shortcutsAreABoxForEachMenu
- Find a setting with a shortcut's name → its menu's box opens to it.
  Test: SettingsLazyBuildTests.findASettingOpensTheMenuAShortcutIsIn

## Menus
- An item in a sidebar menu, the + or the sidebar's empty space that the menu bar also has → it shows the menu bar's keys, as Settings › Shortcuts has them now.
  Test: SidebarRowMenuTests.everySidebarMenuShowsTheMenuBarsKeysForTheSameAction
- The menu bar as Zigzag ships it, the developer tools' items included → no two items share keys.
  Test: MenuShortcutsTests.noTwoMenuBarItemsShareKeys
- A command in the command bar that the menu bar also has → it has the menu bar item's name.
  Test: MenuShortcutsTests.theCommandBarsCommandsAreNamedAsInTheMenuBar
