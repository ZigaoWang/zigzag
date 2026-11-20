# Shortcuts

## Tabs and windows
- ⌘T → the command bar opens for a new tab; ⌘T again closes it.
  No test yet.
- ⌘N → a new window; with no window open, the last closed one comes back instead.
  No test yet.
- ⇧⌘N → a new private window.
  No test yet.
- ⌘W → closes the command bar, the overview card, floating content or the picked rows if one is up, else the tab (undoable); ⇧⌘W closes the window, ⌥⌘W the other tabs.
  No test yet.
- ⇧⌘T → the most recently closed tab or window comes back, across all windows.
  Test: ReopenLastClosedTests.theLatestClosedComesBackFirst
- ⌥⌘↓ / ⌥⌘↑ (or ⇧⌘] / ⇧⌘[) → next or previous row as the sidebar shows it, wrapping, staying in the space.
  Test: TabNavigationTests.goesDownTheSidebarAndWraps
- ⌥⌘→ / ⌥⌘← → next or previous space, stopping at the ends.
  No test yet.
- ⌃Tab / ⌃⇧Tab → recent-tabs switcher by default; sidebar order when Settings › Tabs says so.
  Test: TabNavigationTests.controlTabFollowsTheSetting
- ⌘1–⌘8 → that row of the sidebar; ⌘9, or a number past the end → the last row.
  Test: NumberHintsTests.numbersGoToTheirPlaceAndNineToTheLast
- ⌃1–⌃9 → that space; ⌃9 is the ninth, and a number with no space does nothing.
  Test: NumberHintsTests.spaceNumbersGoToTheirOwnSpaceAndNinthIsTheNinth
- ⌘Y → History, and ⌘, → Settings, each opens as a tab in the front window.
  No test yet.

## Page
- ⌘L → the command bar opens over the address with the current URL selected; Return on it unchanged reloads.
  No test yet.
- ⌘R → reload. ⇧⌘R → reload ignoring the cache.
  Test: DeveloperToolTests.shiftCommandRReloadsIgnoringTheCache
- ⌥⌘R → Reader on or off; on a loading page it waits, and ⌥⌘R again on that tab cancels the wait.
  Test: ReaderWaitTests.onlyTheSameTabCallsTheWaitOff
- ⌘[ / ⌘] (or ⌘← / ⌘→ when nothing is being edited) → back and forward.
  No test yet.
- ⌘F → the find bar; ⌘F again with its field focused hides it.
  No test yet.
- ⌘G / ⇧⌘G → next or previous match, opening the find bar if it's closed.
  Test: FindCountTests.findNextWithTheBarClosedStepsOnce
- ⌘D → Pin Tab: pins the page to the end of the space's pinned pages without asking.
  No test yet.
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

## Custom shortcuts
- Give an item keys in Settings › Shortcuts that another item had → yours win, and the other item has no shortcut.
  No test yet.
- Update to a version that ships an item on keys you gave to something else → that item comes in without them.
  Test: DeveloperToolTests.shippedKeysYouGaveAwayStayYours
- Press a ⌘ key a page also uses (⌘S, ⌘[) → the page gets it first, and the menu only if the page doesn't take it.
  Test: PageShortcutsTests.everythingElseIsThePagesFirst
- Press a tab, window or address key on a page (⌘T, ⌘W, ⇧⌘T) → it always goes to the browser.
  Test: PageShortcutsTests.theBrowsersOwnKeysStayItsOwn
