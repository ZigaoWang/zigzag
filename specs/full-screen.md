# Full screen in a page

A page's full-screen request (a player's button, a video's own, `f` on YouTube) is the browser's. Settings › Tabs ›
Full screen videos fill, and a site's choice in Site Controls, decide where it goes. The expand button over a filled
page is the one hand-off to WebKit's own full screen.

## The Page
- A page asks for full screen → its element fills the page's own area, with the bar and sidebar still there, and no
  Space.
  Test: PageFullScreenTests.theElementFillsThePageAndThePageIsTold
- A page in a split asks → it fills its pane.
  Test: WholeScreenLayoutTests.theWholeScreenTakesTheBrowserSpaceOnlyAlone

## The Whole Screen
- A page on its own asks → it fills the page, and a windowed browser goes into its own full-screen Space, as with
  Enter Full Screen. The page stays in the browser's window.
  Test: WholeScreenLayoutTests.theWholeScreenTakesTheBrowserSpaceOnlyAlone
- A browser already in full screen, or on its way in or out → it stays as it is; only a windowed one enters its Space.
  Test: WholeScreenLayoutTests.theSpaceIsTakenOnlyFromAWindowedWindow
- A page in a split asks → it fills its pane; no Space.
  Test: WholeScreenLayoutTests.theWholeScreenTakesTheBrowserSpaceOnlyAlone
- While the page has it → the sidebar and bar are out of the way; the pointer at the top brings the bar down over the
  page, and the bar goes once the pointer is past it.
  Test: WholeScreenLayoutTests.theBarComesDownFromTheTop
- A panel from the bar is open, or the keyboard is in it → the bar stays down.
  Test: WholeScreenLayoutTests.theBarComesDownFromTheTop
- While the page has it → the address is in the bar, whatever Settings › Appearance says.
  Test: WholeScreenLayoutTests.theAddressStaysInTheBarWhileThePageHasTheWholeScreen
- Show Sidebar (⌃S) while the page has it → the sidebar slides out over the page; its setting stays as it was.
  No test yet.
- Esc, or the page's own exit → the page leaves, and the browser leaves the Space if the page took it there. One that
  was in full screen already stays.
  Test: PageFullScreenTests.escLeavesAndSoDoesZigzag
- View › Exit Full Screen (⌃⌘F) → the browser leaves its Space and the page leaves full screen with it.
  No test yet.
- Switch to another tab → the page leaves its full screen and the Space is given back.
  Test: WholeScreenLayoutTests.theWholeScreenEndsWhenThePageIsNoLongerAlone
- The page goes into a split → it keeps its fill in its pane and the Space is given back.
  Test: WholeScreenLayoutTests.theWholeScreenEndsWhenThePageIsNoLongerAlone
- Leave Zigzag for another app → the video stays in its page, not in the mini player.
  No test yet.
- Quit while the page has the Space → the window comes back windowed.
  Test: WholeScreenLayoutTests.aSpaceThePageTookIsntSaved
- macOS can't start the Space → the chrome comes back and the page keeps its fill in the window.
  No test yet.
- A page in the mini player asks → WebKit's own full screen.
  Test: WholeScreenLayoutTests.aPageOffScreenGoesToWebKit
- A page in a web app window or Zigzag Mini asks → WebKit's own full screen.
  No test yet.

## Both
- The setting or a site's choice changes → the window hears it; a page with The Whole Screen set to The Page gives
  the Space back and keeps its fill.
  Test: PageFullScreenTests.aChoiceChangeTellsTheWindow
- The window hears when a page fills and when it leaves.
  Test: WholeScreenLayoutTests.theWindowHearsWhenAPageFillsAndLeaves
- The page script carries neither the setting nor the site list; whatever the setting, a page's request is filled by
  it, not WebKit.
  Test: PageFullScreenTests.theScriptIsOurs
  Test: PageFullScreenTests.thePageScriptAlwaysFillsThePage
- Esc or exitFullscreen → everything is given back as it was; the page doesn't hear the Esc.
  Test: PageFullScreenTests.escLeavesAndSoDoesZigzag
- A video's own full screen button → it fills the same way.
  Test: PageFullScreenTests.aVideosOwnFullScreenFillsThePageToo
- While a page fills → nothing else on the page draws over the element (a fixed bar, a side column), as in WebKit's
  own full screen.
  Test: PageFullScreenTests.nothingOnThePageDrawsOverTheElement
- A frame with allowfullscreen asks → the page around it fills with the frame.
  Test: PageFullScreenTests.aFrameFillsThePageWithItself
- A request without a click, or from a frame without allowfullscreen → nothing fills.
  Test: PageFullScreenTests.fillingThePageNeedsAClick
  Test: PageFullScreenTests.aFrameWithoutAllowFullscreenCantFillThePage
- Click the expand button → the fill ends and the same element goes to WebKit's own full screen. In The Whole Screen
  the browser gives back the Space it took first; one that was in full screen already stays.
  Test: PageFullScreenTests.theExpandButtonHandsTheElementToWebKitsFullScreen
