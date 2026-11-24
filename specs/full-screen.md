# Full screen in a page

The browser handles a page's full-screen request. Settings › Tabs › Full screen videos fill, and a site's own choice
in Site Controls, decide only where the browser puts it. A page never takes the screen or a Space by itself; the
expand button is the one explicit hand-off to WebKit's own full screen.

- The Page fills the page's own area in the window — its pane in a split, the window on its own — with the bar and
  sidebar there, and no Space.
  Test: PageFullScreenTests.theElementFillsThePageAndThePageIsTold
- The Whole Screen fills the page and takes the browser into its own macOS full-screen space; the chrome autohides
  and comes back from the top. The page stays in the browser's window.
  Test: WholeScreenLayoutTests.theWholeScreenTakesTheBrowserSpaceOnlyAlone
- A page in a split fills its pane, not the browser's space.
  Test: WholeScreenLayoutTests.theWholeScreenTakesTheBrowserSpaceOnlyAlone
- The address stays in the bar while the page has The Whole Screen, whatever Settings › Appearance says.
  Test: WholeScreenLayoutTests.theAddressStaysInTheBarWhileThePageHasTheWholeScreen
- The Whole Screen gives the browser's space back when the page is no longer the one on screen, or when it is in a
  split. A split keeps the page's fill; a page that leaves takes its full screen with it.
  Test: WholeScreenLayoutTests.theWholeScreenEndsWhenThePageIsNoLongerAlone
- The setting and a site's choice are the browser's: the page script carries neither, and a change reaches the window.
  Test: PageFullScreenTests.theScriptIsOurs
  Test: PageFullScreenTests.aChoiceChangeTellsTheWindow
- The window hears when the page fills or leaves, so only the page on screen can take the browser's space.
  Test: WholeScreenLayoutTests.theWindowHearsWhenAPageFillsAndLeaves
- If the browser's own space cannot start, the chrome comes back and the page keeps its fill in the window.
  No test yet.
- The page script fills the element, tells the page it is in full screen, matches its :fullscreen rules and gives
  everything back on Esc or exitFullscreen.
  Test: PageFullScreenTests.theElementFillsThePageAndThePageIsTold
  Test: PageFullScreenTests.escLeavesAndSoDoesZigzag
  Test: PageFullScreenTests.aVideosOwnFullScreenFillsThePageToo
  Test: PageFullScreenTests.aFrameFillsThePageWithItself
- A request without a click is not filled; a frame without allowfullscreen cannot fill the page.
  Test: PageFullScreenTests.fillingThePageNeedsAClick
  Test: PageFullScreenTests.aFrameWithoutAllowFullscreenCantFillThePage
- Whatever the setting, the page's request is the page script's, not WebKit's.
  Test: PageFullScreenTests.thePageScriptAlwaysFillsThePage
- The expand button is the one hand-off to WebKit's own full screen: it leaves the fill and hands the same element
  to WebKit.
  Test: PageFullScreenTests.theExpandButtonHandsTheElementToWebKitsFullScreen
