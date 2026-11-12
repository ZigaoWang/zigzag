# Developer tools

Goal: the tools someone building a website reaches for, on the sites they build and nowhere else. Issue [#141](https://github.com/ZigaoWang/zigzag/issues/141). Branch `feat/developer-tools`, in small pull requests.

## What exists today

- View › Developer: Web Inspector (⌥⌘I, F12), JavaScript Console (⌥⌘J), Inspect Element (⌥⌘C), View Source (⌥⌘U). The inspector docks inside the page's own holder (`PageHolder`, #148).
- View › Reload Ignoring Cache (⌥⌘R).
- Site Controls › ⋯: Clear Cache for This Site…, Clear Cookies for This Site….
- `PageErrors` hears every page's uncaught errors and rejected promises, for Help › Report a Problem.
- Settings › Extensions › Developer mode is about extensions and stays where it is.

## What WebKit allows (tried in test web views on macOS 26.5; 15.4 by its headers only)

Public API:

- Sizing the page: the web view is a view, its holder gives it a size.
- `webView.appearance` for light or dark, `mediaType` for print styles, `customUserAgent`, `WKWebpagePreferences.allowsContentJavaScript` per navigation.
- Trusting a server's certificate, in the navigation delegate's challenge.

Private setters, left for later, one at a time, each guarded like the `_inspector` calls: shrink to fit (`_setLayoutMode`, `_setViewScale`), the pixel ratio, images and styles off.

Not possible from an app that hosts a `WKWebView`: touch events, network throttling (proxies are bypassed for loopback), emulating reduced motion or contrast, turning the cache off, choosing the inspector's tab or side.

The inspector and a narrow page (tried on `main` at 4c6dad22, a split in a 560-wide window and a window narrowed with the inspector docked):

- Opened in a holder under its minimum width, it doesn't dock: it opens in its own window.
- Already docked when its holder narrows, it stays docked and keeps its own width (500 here), whatever the holder's is; the page gets what is left, and under 500 the inspector hangs out of the holder.
- Its width doesn't depend on the holder's, and both are plain subviews of the holder. So a page given a size keeps it beside a docked inspector if the holder is made that size plus the inspector's room.

## Approach

One rule: a tab is a **development tab** while Developer tools is on and the page it shows is on the list of development sites (`DeveloperTools.applies(to:)`, `Tab.isDevelopment`). Every tool, mark and choice made with them exists only then.

- Off the list, the tools and the mark go and the tab's choices (a size, a look, a user agent, JavaScript off) stop applying, from the moment the other site's page arrives. They're kept and apply again when the tab comes back, a sign-in that passes through another site included, and are gone when the tab closes. Nothing about them is saved.
- Developer tools off: no tab is a development tab. The menu bar, Settings › Shortcuts, the window and every page are as they are without this feature.
- The page it shows is the one last committed; before any, the address the tab is going to. An address shown early changes nothing, so a redirect doesn't flicker the tools.

The list (`DevelopmentSites`) starts as `localhost` and `127.0.0.1`. A site is a host without "www.", whatever its port, and covers its subdomains, as every other choice for a site does. Nothing is written until the list is changed. It isn't changed from a private window.

Where the tools show: in the bar above the page, at its trailing end after the address (`TopBarView.accessory`). With the address kept in the sidebar the bar comes for the tools alone, on a development tab only: the address and the sidebar's rows stay where the setting puts them, so nothing in the sidebar moves. (Forcing the address itself up on development tabs was the first idea, and would have moved the sidebar's list under the pointer on every switch; a strip on the page card was the second, and gave the page two rows of chrome with the address above it.) In a split the row belongs to the panes' own strips, and the tools are in Site Controls, the menu bar and the command bar.

## Steps

1. **Settings › Developer, the list, the mark.** The switch, the list with Add Site… and Remove, and a hammer on a development tab's row in the sidebar.
2. **The tools Zigzag already has**, by the menu bar, the command bar and Site Controls: this site's cache and cookies, and Add This Site to Development Sites (⌥⇧⌘D) to put the site you're on on the list or take it off.
3. **The tools above the page**: Console, Inspect Element, reload's choices and More, giving way into More before the address gives up room; "Tools above the page" in Settings, and the console, inspecting and reloading as tiles in Site Controls wherever a development page has none above it. The bar has one place for a page's own tools (`TopBarView.accessory`) and knows nothing of what is in it; `DeveloperBarTools.shows` is the one rule for whether a page gets them above it or the tiles.
4. **The error count** on Console: uncaught errors and rejected promises since the page loaded. `PageErrors` already hears them on every page for Help › Report a Problem, and stops after 8 a page; past those its script only says how many more, at most twice a second, and the count is kept on a development tab alone (`Tab.pageErrorCount`). The script says how many more only where a listener is there for it (`PageErrors.counts(in:)`, put in a development tab's web view), so on every other page it does what it did before.
5. **Page appearance**: follow the Mac, light or dark, and print styles. The first of a tab's own choices (`DeveloperState`, read through `Tab.developerInEffect`, put on the page by `Tab.applyDeveloperState`). `DarkPages` owns the web view's appearance, so the choice goes through it (`chosenLook`, `lookChanged`): such a page gets the script config a page gets where dark pages are off, and teaches the site's dark list nothing. The page script is unchanged. What puts a choice on the page asks by the address the web view is going to (`developerInEffect(at:)`), so a page off the list never starts with it; a page and the pop-ups it opened share their scripts, so all of them get the stand-back script while any of them has a look chosen.
6. **Page size**: presets, a custom size, rotate. The card sizes the page's holder (`PageCardView.pageSize`, `pageRect`), and the holder says how much room the docked inspector takes (`PageHolder.dockedRoom`), so the card makes the holder the size plus that room and the page keeps its size. The page is in the middle of its room, both ways. A size larger than the room is cut to it: no scrolling ground, and shrink to fit needs a private setter. Not built: handles on the page's edges to drag it to a size, and shortcuts (Settings › Shortcuts lists only items that ship with a key).
7. **The rest of More**: JavaScript off, user agent, open in another browser, outline every element. JavaScript is decided per navigation for the address being gone to (`WKWebpagePreferences.allowsContentJavaScript`), the user agent is the web view's `customUserAgent`, and both reload the page when they change. The outline is one style element put into the page from a content world of its own. Nothing is learned for dark pages from a page with any choice in effect (`Tab.pageIsUntouched`). A page is asked for as the browser it is to be told it's in: a main-frame request made as another (leaving a development page for another site, or coming back to one) is refused and made again (`Tab.asksAgain`), so no site off the list is ever asked for as the browser chosen for your own. Checked with a server that logs the header, both ways.
8. **A development site's certificate**: trusted without the warning for a site on this Mac, off until turned on. The rule is beside `CertificateExceptions.allows`, where a server's trust is accepted (`allowsLocalServer`), and keeps what it trusts apart from what "Visit anyway" keeps: per data store, for the session, by host and port, pinned to the certificate first shown, and read only while the setting is on. Only a development page's own loads are trusted this way, so a page from anywhere else that reaches for a server on this Mac gets what it always got. "On this Mac" is `ErrorPage.isOnThisMac`, the check the error page already has, which now takes an address that starts with 127 and not a name that does.

Not in these: showing a size larger than the window smaller to fit (bounds scaling the holder makes WebKit lay the page out at the scaled width, so it needs `_setViewScale` or a snapshot approach), the listed sizes in View › Developer's Page Size submenu, the page on your phone (its address on the network, with a QR code), the private setters above, reloading when files change, counting `console.error`, a user agent typed by hand, tools in a split's panes, moving Extensions' Developer mode.

## Rules while doing it

- Public API only. Anything private waits for its own pull request.
- With Developer tools off, or on a site that isn't listed, nothing differs from `main`.
- No state moves anything in the sidebar or the address.
- Conventional commits, one small change each, no co-author lines.
